"""
autoword — next-word suggestions while you type.

Background service, same shape as the pinger and typelog (see
core/processes.ahk): named mutex for single-instance, named event for stop,
operational lines to debuglogs\\error_log.txt tagged [autoword].

    python autoword.pyw                 run it
    python autoword.pyw --train         rebuild the model and exit
    python autoword.pyw --evaluate      held-out accuracy report, changes nothing

Wiring, and the only place the concrete classes are named:

    config.load()  ->  corpus.load_clean()  ->  NgramPredictor
                                                     |
                            Engine (buffer, candidates, accept/cycle)
                                                     |
                                        renderers.build()  -> off | strip | ghost

Swapping the model or the presentation means changing one line here.

────────────────────────────────────────────────────────────────────────────────
TWO THREADS, AND WHY A COMPLETION WAITS FOR A GAP
────────────────────────────────────────────────────────────────────────────────
pynput hands us the same keystroke twice, on two threads, at two different times:

    hook thread     win32_event_filter(msg, data)   synchronous, inside the
                                                    low-level hook, BEFORE the
                                                    app sees the key. The only
                                                    place a key can be swallowed.
    loop thread     on_press(key)                   posted to pynput's message
                                                    loop and handled later, AFTER
                                                    the key is already on screen.

The engine runs on the second one, so the decision to complete a word is always
a little behind your fingers — and while it is being made you have typed the next
letters yourself. That is where `feeling` became `feelinging`: the completion was
computed from `feel`, and by the time it typed `ing` your own `i` had already
landed. The echo swallow below cannot help, because it is only armed once the
completion has been decided.

So a completion is not typed when it is decided. It is held until you stop
typing (`AutoCompleteIdleMs`), which is the only moment nothing of yours is in
flight behind it — and, not by coincidence, the only moment you would notice it
appear. Any key you press first replaces the suggestion or cancels it outright.

The other half is telling your keys from ours: Windows stamps the events we
inject with LLKHF_INJECTED, and both callbacks check that flag rather than the
"are we injecting?" stopwatch this used to run, which went blind to real
keystrokes for 50ms after every completion — exactly when you are typing the
rest of the word.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime
import json
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config as cfgmod                                   # noqa: E402
import corpus                                             # noqa: E402
import renderers                                          # noqa: E402
from engine import Engine                                 # noqa: E402
from model import Candidate, NgramPredictor           # noqa: E402
from reword import Thesaurus                               # noqa: E402

try:
    from pynput import keyboard, mouse
except ImportError:                       # headless: say so in MMA's log, give up
    keyboard = mouse = None

MMA_LOG = cfgmod.MMA_DEBUGLOGS / "error_log.txt"
LOG_TAG = "autoword"
MODEL_PATH = cfgmod.MMA_USERDATA / "autoword" / "model.json"
DICT_CACHE = cfgmod.MMA_USERDATA / "autoword" / "dictionary.json"

MUTEX_NAME = "Global\\MMA.autoword.mutex"
STOP_EVENT_NAME = "Global\\MMA.autoword.stop"
ERROR_ALREADY_EXISTS = 183

VK_BACK, VK_TAB, VK_RETURN = 0x08, 0x09, 0x0D
VK_END, VK_HOME, VK_DELETE = 0x23, 0x24, 0x2E
VK_ARROWS = (0x25, 0x26, 0x27, 0x28)
VK_PRIOR, VK_NEXT = 0x21, 0x22
VK_SHIFT, VK_CONTROL = 0x10, 0x11
VK_ESCAPE = 0x1B
WM_KEYDOWN, WM_SYSKEYDOWN = 0x0100, 0x0104

# Windows stamps every event that came from SendInput rather than a key. Both
# bits mean injected; the lower-integrity one appears when the sender is less
# privileged than the hook. This is how we recognise our own completions.
LLKHF_INJECTED, LLKHF_LOWER_IL_INJECTED = 0x10, 0x02
INJECTED = LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED

# The only keys this service is willing to swallow. A typo in [Keys] must
# disable the binding, never silently eat some other key.
KEY_VK = {"tab": VK_TAB}

MAPVK_VK_TO_CHAR = 2

_user32 = ctypes.windll.user32 if sys.platform == "win32" else None
if _user32:
    _user32.GetAsyncKeyState.restype = ctypes.c_short
    _user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
    _user32.MapVirtualKeyW.restype = wintypes.UINT
    _user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
    _user32.GetForegroundWindow.restype = wintypes.HWND

_stop = threading.Event()
_mutex = None          # module level: must outlive the function that made it
_stop_event = None


MODIFIERS = ("shift", "ctrl", "control")


def parse_key(spec: str) -> tuple[int, bool, bool] | None:
    """`"ctrl+tab"` -> `(VK_TAB, False, True)`. None if it is not a key we hook.

    Modifiers are part of the identity, not decoration: the three bindings are
    the same physical key and only the modifier tells them apart. That is also
    why Ctrl is read at all — before rewording existed, Ctrl+Tab matched plain
    Tab and quietly accepted the suggestion instead of switching tabs.
    """
    parts = [p.strip() for p in spec.lower().split("+") if p.strip()]
    shift = "shift" in parts
    ctrl = "ctrl" in parts or "control" in parts
    names = [p for p in parts if p not in MODIFIERS]
    if len(names) != 1 or names[0] not in KEY_VK:
        return None
    return KEY_VK[names[0]], shift, ctrl


def key_char(vk: int) -> str:
    """The character a key types, unshifted and lowercased. '' if it types none.

    Only used to recognise you typing letters that are already on screen, so the
    unshifted reading is the right one: the corpus is lowercase, and holding
    shift does not make it a different word.
    """
    if not _user32:
        return ""
    ch = _user32.MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0xFFFF
    return chr(ch).lower() if ch else ""


def foreground_window() -> int:
    """The window with the caret in it, as a bare handle to compare against."""
    if not _user32:
        return 0
    return _user32.GetForegroundWindow() or 0


def pynput_reports_injected() -> bool:
    """Does this pynput tell `on_press` whether the key was injected?

    1.8 added the argument. Older versions cannot distinguish our completions
    from your typing on the loop thread, so they need the stopwatch fallback.
    """
    try:
        from importlib.metadata import version
        parts = version("pynput").split(".")
        return (int(parts[0]), int(parts[1])) >= (1, 8)
    except Exception:
        return False


def held(vk: int) -> bool:
    """Is that modifier physically down?

    GetAsyncKeyState, not GetKeyState: this is read from a low-level hook, which
    runs before the target thread has processed the key, so the synchronised
    state this thread would see is stale.
    """
    if not _user32:
        return False
    return bool(_user32.GetAsyncKeyState(vk) & 0x8000)


def shift_down() -> bool:
    return held(VK_SHIFT)


def ctrl_down() -> bool:
    return held(VK_CONTROL)


def log(message: str) -> None:
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] [{LOG_TAG}] {message}"
    try:
        cfgmod.MMA_DEBUGLOGS.mkdir(exist_ok=True)
        with MMA_LOG.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    print(line)


# ── window scope ──────────────────────────────────────────────────────────────
class Scope:
    """True when the foreground process is one we should suggest into."""

    def __init__(self, processes: list[str]):
        self.processes = processes
        self.ok = not processes
        self._last_check = 0.0
        if sys.platform == "win32":
            self.u = ctypes.windll.user32
            self.k = ctypes.windll.kernel32
            # HWND/HANDLE are pointers; the default int restype truncates on x64
            self.u.GetForegroundWindow.restype = wintypes.HWND
            self.u.GetWindowThreadProcessId.argtypes = [wintypes.HWND,
                                                        ctypes.POINTER(wintypes.DWORD)]
            self.k.OpenProcess.restype = wintypes.HANDLE

    def refresh(self) -> bool:
        if not self.processes or sys.platform != "win32":
            return True
        now = time.monotonic()
        if now - self._last_check < 0.25:
            return self.ok
        self._last_check = now
        self.ok = self._foreground_name() in self.processes
        return self.ok

    def _foreground_name(self) -> str:
        try:
            hwnd = self.u.GetForegroundWindow()
            if not hwnd:
                return ""
            pid = wintypes.DWORD()
            self.u.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            handle = self.k.OpenProcess(0x1000, False, pid.value)   # QUERY_LIMITED
            if not handle:
                return ""
            try:
                buf = ctypes.create_unicode_buffer(512)
                size = wintypes.DWORD(512)
                if self.k.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                    return Path(buf.value).name.lower()
            finally:
                self.k.CloseHandle(handle)
        except Exception:
            pass
        return ""


# ── dictionary lookups, remembered between runs ───────────────────────────────
class CachedDictionary:
    """`in_dict`, backed by a file, because the answers never change.

    Each lookup is a COM call costing about half a millisecond, and there is one
    per prefix of every word you know — tens of thousands, twenty seconds. With
    RetrainOnStart that is twenty seconds on every start of a background service,
    for a question whose answer is the same as yesterday's. Only genuinely new
    vocabulary reaches the checker after the first run.
    """

    def __init__(self, in_dict, path: Path = DICT_CACHE):
        self.in_dict = in_dict
        self.path = path
        self.asked = 0
        try:
            self.known = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.known = {}

    def __call__(self, word: str) -> bool:
        if word not in self.known:
            self.known[word] = bool(self.in_dict(word))
            self.asked += 1
        return self.known[word]

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.known), encoding="utf-8")
        except OSError as exc:
            log(f"! could not write the dictionary cache: {exc}")


# ── model ─────────────────────────────────────────────────────────────────────
def build_predictor(cfg: cfgmod.Config, force_train: bool = False) -> NgramPredictor:
    pred = NgramPredictor(min_probability=cfg.min_probability)
    if not force_train and not cfg.retrain_on_start and pred.load(MODEL_PATH):
        log(f"model loaded from {MODEL_PATH.name} ({pred.trained_on:,} tokens)")
        return pred

    lines, stats = corpus.load_clean(extra=cfg.extra_corpora)
    if not stats.get("spellcheck"):
        log("! Windows spell checker unreachable — repair is running on corpus "
            "statistics alone, which keeps noticeably more junk")
    pred.train(lines)

    # Which of your words are words in their own right, decided once, here.
    # finished_word needs this on the keyboard hook thread, and the only
    # dictionary available is COM — so it is answered at train time and stored
    # with the model. Without it every completion that merely adds a suffix
    # (`do` -> `does`, `leg` -> `legs`) fires like any other.
    speller = corpus.SpellChecker()
    if speller.available:
        cache = CachedDictionary(speller.in_dict)
        known = pred.learn_dictionary(cache)
        cache.save()
        log(f"dictionary: {known:,} of your words and word-starts are real words "
            f"({'/'.join(speller.languages)}; {cache.asked:,} new lookups)")
    else:
        log("! no Windows dictionary — cannot tell a finished word from a "
            "fragment, so auto-completion will extend words like `do` -> `does`")

    pred.save(MODEL_PATH)
    log(f"trained on {stats['days']} days / {len(lines):,} lines / "
        f"{pred.trained_on:,} tokens  "
        f"(repaired: fusion {stats.get('fusion', 0):,}, "
        f"retype {stats.get('retype', 0):,}, double {stats.get('double', 0):,}, "
        f"dropped {stats.get('junk', 0):,})")
    return pred


def build_thesaurus(cfg: cfgmod.Config) -> Thesaurus:
    """Load the reword groups, vetting generated inflections against Windows.

    Same dictionary and same cache file as the model uses for `finished_word`,
    so the second reader of it pays almost nothing: the answers to `is
    `whisperred` a word` do not change between runs either.
    """
    if not cfg.reword_key:
        return Thesaurus()
    speller = corpus.SpellChecker()
    if not speller.available:
        log("! no Windows dictionary — reword inflections are unchecked, so "
            "expect the odd `prefered` in the list")
        return Thesaurus.load()
    cache = CachedDictionary(speller.in_dict)
    thesaurus = Thesaurus.load(in_dict=cache)
    cache.save()
    return thesaurus


def evaluate(cfg: cfgmod.Config) -> None:
    """Held-out accuracy. Trains on all but the last N days, scores the rest."""
    days = corpus.read_raw()
    if len(days) < 4:
        log("not enough days to evaluate"); return
    rep = corpus.Repairer()
    for day, lines in days:
        for ln in lines:
            rep.observe(day, (t.strip("'") for t in corpus.WORD.findall(ln.lower())
                              if t.strip("'")))
    clean = {day: [t for t, _ in (rep.repair_line(l) for l in lines) if t]
             for day, lines in days}
    order = sorted(clean)
    split = max(1, int(len(order) * 0.8))
    train = [l for d in order[:split] for l in clean[d]]
    test = [l for d in order[split:] for l in clean[d]]

    pred = NgramPredictor(min_probability=0.0)
    pred.train(train)

    for k in (1, 2, 3, 5):
        hit = total = 0
        for line in test:
            words = line.split()
            for i, w in enumerate(words):
                ctx = words[max(0, i - 2):i]
                cands = pred.predict(ctx, w[:cfg.min_chars], k)
                total += 1
                if any(c.word == w for c in cands):
                    hit += 1
        print(f"  top-{k}: {hit / max(1, total):6.1%}")
    print(f"  perplexity: {pred.perplexity(test):,.0f}")
    print(f"  train {len(train):,} lines / test {len(test):,} lines "
          f"({order[split]}..{order[-1]})")


def demo(cfg: cfgmod.Config, seconds: float) -> int:
    """Draw the strip with sample candidates, ignoring scope and the keyboard.

    Exists because every gate in this service is silent: the feature switch, the
    render mode, and the foreground-process scope each make the UI simply not
    appear, and none of them says so. This answers "is it even working, and where
    does it draw?" without needing Infloww focused or a single keystroke — and it
    is how you tune [Strip] OffsetX / OffsetY, since the strip anchors to the
    foreground window and the shipped offsets are a guess.
    """
    if cfg.render in ("off", "ghost"):
        log(f"demo: Render={cfg.render} draws nothing — using 'strip' for this run")
        cfg.render = "strip"
    renderer = renderers.build(cfg)
    sample = [Candidate("going", 0.87, "trigram"),
              Candidate("get", 0.03, "trigram"),
              Candidate("good", 0.03, "trigram")]
    log(f"demo: showing the strip for {seconds:g}s at OffsetX={cfg.strip_offset_x} "
        f"OffsetY={cfg.strip_offset_y}, relative to whatever window is in front")
    deadline = time.monotonic() + seconds
    active = 0
    last = 0.0
    try:
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now - last > 1.2:                 # cycle so the highlight is obvious
                active = (active + 1) % len(sample)
                renderer.show(sample, active, "are you g")
                last = now
            renderer.pump()
            time.sleep(0.02)
    finally:
        renderer.hide()
        renderer.pump()
        renderer.close()
        renderer.pump()
    log("demo: done")
    return 0


# ── the running service ───────────────────────────────────────────────────────
class Service:
    def __init__(self, cfg: cfgmod.Config):
        self.cfg = cfg
        self.scope = Scope(cfg.processes)
        thesaurus = build_thesaurus(cfg)
        self.engine = Engine(
            predictor=build_predictor(cfg),
            thesaurus=thesaurus if thesaurus else None,
            reword_list_size=cfg.reword_list_size,
            min_chars=cfg.min_chars,
            list_size=cfg.list_size,
            min_saving=cfg.min_saving,
            predict_mode=cfg.predict,
            auto_min_chars=cfg.auto_chars,
            auto_min_count=cfg.auto_seen,
            auto_only_fragments=cfg.auto_only_fragments,
            auto_never=set(cfg.auto_never),
        )
        self.renderer = renderers.build(cfg)
        self.controller = keyboard.Controller() if keyboard else None
        self._echo = ""        # letters we just typed for you, that you may
                               # already be halfway through typing yourself
        self._lock = threading.RLock()   # the engine is now touched by three
                                         # threads: hook, loop, and the pump
                                         # below that fires held completions
        self._last_key = 0.0             # monotonic time of your last real key
        self._auto_delay = cfg.auto_idle_ms / 1000.0
        self._auto_hwnd = 0              # where the held completion belongs
        self._legacy = not pynput_reports_injected()
        self._injecting = False          # legacy pynput only; see _type
        self.accepted = 0
        self.cycled = 0
        self.reworded = 0
        self.swapped = 0
        self.completed = 0
        self.undone = 0
        self.shown = 0

        self.accept_key = parse_key(cfg.accept_key)
        self.cycle_key = parse_key(cfg.cycle_key)
        self.reword_key = parse_key(cfg.reword_key) if cfg.reword_key else None
        if self.accept_key is None:
            log(f"! Keys.Accept = {cfg.accept_key!r} is not a key this service "
                f"can swallow — using Tab")
            self.accept_key = (VK_TAB, False, False)
        if self.cycle_key is None and cfg.cycle_key:
            log(f"! Keys.Cycle = {cfg.cycle_key!r} is not a key this service can "
                f"swallow — cycling is off, only the first candidate is reachable")
        if self._legacy:
            log("! pynput is older than 1.8, so it cannot tell our own "
                "completions from your typing — falling back to a 50ms guess "
                "that goes blind to real keystrokes. pip install -U pynput")
        if self.cycle_key == self.accept_key:
            # One keydown cannot mean both "move the highlight" and "take it".
            log(f"! Keys.Cycle and Keys.Accept are both {cfg.accept_key!r} — "
                f"cycling is off, so only the first candidate is reachable. "
                f"Set Cycle = shift+tab in userdata\\autoword.ini")
            self.cycle_key = None
        if self.reword_key is None and cfg.reword_key:
            log(f"! Reword.Key = {cfg.reword_key!r} is not a key this service "
                f"can swallow — rewording is off")
        if self.reword_key and self.reword_key in (self.accept_key, self.cycle_key):
            log(f"! Reword.Key = {cfg.reword_key!r} is already Accept or Cycle — "
                f"rewording is off. Set Key = ctrl+tab in userdata\\autoword.ini")
            self.reword_key = None
        if self.reword_key and not thesaurus:
            log("! no reword groups — check userdata\\autoword\\reword.txt")
            self.reword_key = None
        if self.reword_key and cfg.render == "off":
            log("! Render = off draws no strip, so Ctrl+Tab will reword blind — "
                "the alternatives are only in the shadow log")

    # -- suppression decision, on the hook thread ------------------------------
    def event_filter(self, msg, data):
        """Swallow Tab, Shift+Tab and Ctrl+Tab ONLY when they would do something
        here, so all three keep their normal jobs in the app the rest of the
        time. This is why the feature can use Tab at all — pynput's blanket
        `suppress=True` would eat every key.

        Modifiers are matched exactly, so with the defaults Shift+Tab moves the
        highlight, Ctrl+Tab rewords, and neither accepts. suppress_event()
        raises, so it stays last.
        """
        if msg not in (WM_KEYDOWN, WM_SYSKEYDOWN):
            return
        if data.flags & INJECTED:
            return                       # our own completion, coming back at us
        # Stamped here rather than in on_press because this runs the moment you
        # press the key. It is what "you have stopped typing" is measured from,
        # so it has to be your key, not our reading of it half a beat later.
        self._last_key = time.monotonic()
        vk = data.vkCode

        with self._lock:
            # You are finishing a word we already finished for you. Those letters
            # are on screen — let them through and you get them twice.
            if self._echo:
                if key_char(vk) == self._echo[0]:
                    self._echo = self._echo[1:]
                    self.listener.suppress_event()
                elif vk != VK_BACK:
                    self._echo = ""

            # Backspace straight after an auto-completion undoes the whole thing.
            if vk == VK_BACK and self.engine.auto_undo:
                self._handle_undo()
                self.listener.suppress_event()

            # Ctrl+Tab comes first: rewording is the one thing that starts
            # from nothing on screen, and it is swallowed only if there was
            # something to offer — otherwise Ctrl+Tab goes on switching tabs.
            pressed = (vk, shift_down(), ctrl_down())
            if self.reword_key and pressed == self.reword_key:
                if not self._handle_reword():
                    return
                self.listener.suppress_event()

            if not self.engine.suggestion:
                return
            if pressed == self.cycle_key:
                self._handle_cycle()
            elif pressed == self.accept_key:
                self._handle_accept()
            else:
                return
        self.listener.suppress_event()

    def _handle_auto(self) -> None:
        remainder = self.engine.auto_complete()
        if not remainder or not self.controller:
            return
        self.completed += 1
        self._echo = remainder
        self._type(remainder)
        self.renderer.hide()

    def _handle_undo(self) -> None:
        n = self.engine.undo_auto()
        if not n or not self.controller:
            return
        self.undone += 1
        self._echo = ""
        self._backspace(n)
        self.renderer.hide()

    def _handle_reword(self) -> bool:
        """Open the list of other words, or move the highlight if it is open.

        Returns False to let Ctrl+Tab through untouched when there is no word
        or nothing to offer for it, so the key goes on doing whatever it does in
        the app.

        The buffer this reads can be a keystroke or two behind your fingers —
        `on_press` runs on the message-loop thread — and for a *replacement*
        that would be dangerous, since deleting the wrong number of characters
        eats a letter of the word before it. It cannot happen, and neither
        guard is here: the moment a keystroke in flight lands it clears the
        suggestion, and `swap` refuses unless the buffer still ends with exactly
        what it means to replace. A stale list can be shown; it can never be
        taken.
        """
        suggestion = self.engine.suggestion
        if suggestion and suggestion.reword:
            self._handle_cycle()
            return True
        suggestion = self.engine.reword()
        if not suggestion:
            return False
        self.reworded += 1
        self.renderer.show(suggestion.candidates, suggestion.active,
                           suggestion.reword)
        return True

    def _handle_swap(self) -> None:
        """Take the highlighted reword: delete the old word, type the new one."""
        edit = self.engine.swap()
        if not edit or not self.controller:
            return
        deleted, replacement = edit
        self.swapped += 1
        self._echo = ""
        self._backspace(deleted)
        self._type(replacement)
        self.renderer.hide()

    def _handle_cycle(self) -> None:
        suggestion = self.engine.cycle()
        if not suggestion:
            return
        self.cycled += 1
        # Not _emit(): this re-draws the suggestion already on screen with a new
        # highlight, it is not another suggestion shown.
        self.renderer.show(suggestion.candidates, suggestion.active,
                           self.engine.context_text)

    def _handle_accept(self) -> None:
        # Tab means "take the highlighted one" in both modes; only what that
        # costs the box differs — a remainder appended, or a word replaced.
        suggestion = self.engine.suggestion
        if suggestion and suggestion.reword:
            self._handle_swap()
            return
        remainder = self.engine.accept()
        if not remainder or not self.controller:
            return
        self.accepted += 1
        self._echo = ""
        self._type(remainder)
        self.renderer.hide()

    # -- typing on the user's behalf -------------------------------------------
    def _type(self, text: str) -> None:
        """Type on your behalf.

        Nothing is muted: what we send carries the injected flag, and both
        callbacks drop those on sight. Muting used to mean a 50ms window in
        which every real keystroke was thrown away too — unseen by the engine
        and unswallowed by the echo — which is the whole `feelinging` bug.
        """
        self._injecting = self._legacy
        try:
            self.controller.type(text)
        finally:
            if self._legacy:
                threading.Timer(0.05, self._clear_injecting).start()

    def _backspace(self, n: int) -> None:
        self._injecting = self._legacy
        try:
            for _ in range(n):
                self.controller.press(keyboard.Key.backspace)
                self.controller.release(keyboard.Key.backspace)
        finally:
            if self._legacy:
                threading.Timer(0.05, self._clear_injecting).start()

    def _clear_injecting(self) -> None:
        self._injecting = False

    # -- key stream ------------------------------------------------------------
    def on_press(self, key, injected: bool = False) -> None:
        # `injected` is pynput 1.8+; on older versions it is always False and
        # the stopwatch stands in. Either way these are our own keystrokes.
        if injected or (self._legacy and self._injecting):
            return
        with self._lock:
            self._on_press(key)

    def _on_press(self, key) -> None:
        if not self.scope.refresh():
            if self.engine.suggestion:
                self.renderer.hide()
            self._forget()
            return

        vk = getattr(key, "vk", None)

        if key == keyboard.Key.esc or vk == VK_ESCAPE:
            # Not swallowed — Esc means something in the app too. This only
            # takes the list off the screen.
            self.engine.dismiss(); self.renderer.hide(); return
        if key == keyboard.Key.enter or vk == VK_RETURN:
            self._echo = ""
            self.engine.on_boundary(); self.renderer.hide(); return
        if key == keyboard.Key.backspace or vk == VK_BACK:
            if ctrl_down():
                # Ctrl+Backspace eats a whole word, and how much of one depends
                # on the app. Modelling it as one character is how a buffer
                # silently goes stale.
                self._forget(); self.renderer.hide(); return
            self._emit(self.engine.on_backspace()); return
        # anything that moves the caret in a way we cannot model: go quiet
        if vk in VK_ARROWS or vk in (VK_HOME, VK_END, VK_DELETE, VK_PRIOR, VK_NEXT):
            self._forget(); self.renderer.hide(); return

        ch = getattr(key, "char", None)
        if ch is None:
            if key == keyboard.Key.space:
                ch = " "
            else:
                return                      # modifiers, F-keys: leave state alone
        self._emit(self.engine.on_char(ch))

    def on_click(self, x, y, button, pressed, injected: bool = False) -> None:
        """A click moves the caret somewhere we cannot see. Drop the buffer."""
        if pressed and not injected:
            with self._lock:
                self._forget()
            self.renderer.hide()

    def _forget(self) -> None:
        """Drop the buffer, and the echo with it.

        The echo is a promise about the characters at the caret. Once we no
        longer know where the caret is, keeping it means swallowing a letter you
        typed somewhere else entirely.
        """
        self.engine.invalidate()
        self._echo = ""

    def _emit(self, suggestion) -> None:
        if suggestion and suggestion.auto and self._auto_delay <= 0:
            self._handle_auto()             # AutoCompleteIdleMs = 0: fire at once
            return
        if suggestion and suggestion.candidates:
            self.shown += 1
            if suggestion.auto:
                # Held until you pause. Remember which box it belongs to, so a
                # pause that is really an Alt+Tab does not type it into the next
                # window along.
                self._auto_hwnd = foreground_window()
            self.renderer.show(suggestion.candidates, suggestion.active,
                               self.engine.context_text)
        else:
            self.renderer.hide()

    def _due_auto(self) -> None:
        """Type a held completion once you have stopped typing.

        Called from the main loop, ~50 times a second. Everything it checks can
        change under it — you are typing on another thread — so it re-checks
        under the lock before writing anything.
        """
        if self._auto_delay <= 0:
            return
        suggestion = self.engine.suggestion
        if not suggestion or not suggestion.auto:
            return
        if time.monotonic() - self._last_key < self._auto_delay:
            return                          # still typing; nothing is settled
        if self._auto_hwnd and foreground_window() != self._auto_hwnd:
            return                          # you left the box it was meant for
        if not self.scope.refresh():
            return
        with self._lock:
            suggestion = self.engine.suggestion
            if suggestion and suggestion.auto:
                self._handle_auto()

    # -- lifecycle -------------------------------------------------------------
    def run(self) -> None:
        self.listener = keyboard.Listener(on_press=self.on_press,
                                          win32_event_filter=self.event_filter)
        self.listener.start()
        self.mouse_listener = mouse.Listener(on_click=self.on_click)
        self.mouse_listener.start()
        reword = (f"{self.cfg.reword_key}/{self.cfg.reword_list_size}"
                  if self.reword_key else "off")
        auto = (f"{self.cfg.auto_chars} chars/{self.cfg.auto_seen} seen"
                + (f"/{self.cfg.auto_idle_ms}ms idle"
                   if self.cfg.auto_idle_ms else "/immediate")
                if self.cfg.auto_chars else "off")
        log(f"started — predict={self.cfg.predict} render={self.cfg.render} "
            f"list={self.cfg.list_size} minchars={self.cfg.min_chars} "
            f"accept={self.cfg.accept_key} "
            f"cycle={self.cfg.cycle_key if self.cycle_key else 'off'} "
            f"autocomplete={auto} reword={reword} "
            f"scope={','.join(self.cfg.processes) or 'everywhere'}")
        try:
            while not _stop.is_set():
                self._due_auto()
                self.renderer.pump()
                time.sleep(0.02)
        finally:
            self.renderer.close()
            self.listener.stop()
            self.mouse_listener.stop()
            log(f"stopped — {self.shown:,} suggestions shown, "
                f"{self.accepted:,} accepted, {self.cycled:,} cycles, "
                f"{self.reworded:,} rewords offered ({self.swapped:,} taken), "
                f"{self.completed:,} auto-completed ({self.undone:,} taken back)")


# ── single instance / stop, MMA's named-event scheme ──────────────────────────
def claim_single_instance() -> bool:
    global _mutex
    if sys.platform != "win32":
        return True
    _mutex = ctypes.windll.kernel32.CreateMutexW(None, False, MUTEX_NAME)
    return ctypes.windll.kernel32.GetLastError() != ERROR_ALREADY_EXISTS


def watch_stop_event() -> None:
    global _stop_event
    if sys.platform != "win32":
        return
    _stop_event = ctypes.windll.kernel32.CreateEventW(None, True, False, STOP_EVENT_NAME)

    def wait():
        ctypes.windll.kernel32.WaitForSingleObject(_stop_event, 0xFFFFFFFF)
        _stop.set()

    threading.Thread(target=wait, daemon=True).start()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="autoword — next-word suggestions")
    ap.add_argument("--train", action="store_true", help="rebuild the model and exit")
    ap.add_argument("--evaluate", action="store_true", help="held-out accuracy, no changes")
    ap.add_argument("--demo", type=float, nargs="?", const=15.0, metavar="SECONDS",
                    help="draw the strip with sample suggestions, ignoring scope, so you "
                         "can see where it lands and tune [Strip] OffsetX/OffsetY")
    args = ap.parse_args(argv)

    cfg = cfgmod.load()

    if args.train:
        build_predictor(cfg, force_train=True)
        return 0
    if args.evaluate:
        evaluate(cfg)
        return 0
    if args.demo:
        return demo(cfg, args.demo)

    if keyboard is None:
        log("! pynput is not installed — pip install -r requirements.txt")
        return 1
    if not claim_single_instance():
        log("already running")
        return 0

    watch_stop_event()
    try:
        Service(cfg).run()
    except Exception as exc:                       # never die silently
        log(f"! crashed: {exc!r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
