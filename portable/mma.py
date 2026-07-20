#!/usr/bin/env python3
"""
mma.py — the Ctrl+1/2/3 send flow, on Windows and macOS from one codebase.

Press a key, paste a message, press Enter, pause, repeat for each part of the
follow-up. That is the whole product. The Windows original is Snd() in
../utils.ahk, all eight lines of it:

    A_Clipboard := ""        ClipWait(1)
    A_Clipboard := arg       Send("^v")  Send("{Enter}")  Sleep(waitTime)

Usage:
    python mma.py                 run it
    python mma.py --check         show how masses.txt parsed, then exit
    python mma.py --dry-run       run, but print what WOULD be sent
    python mma.py --send 1        send follow-up 1 once, then exit

--check and --dry-run are the whole test story on a machine where you cannot
safely fire keystrokes into a live chat. Use them first.

Everything adjustable is a constant just below, the same way pinger.pyw does it.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from datetime import datetime

import massparse
import paths
import settings

# Masses contain emoji. A Windows console defaults to the locale codepage
# (cp1252 here), where printing one raises UnicodeEncodeError — which would take
# down --check, and any notify() that echoes message text, on the very first
# real mass. Nothing about this is macOS-specific; it just never shows up there.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):        # already wrapped, or not a tty
        pass

# ── Configuration ────────────────────────────────────────────────────────────

# Next to the source when run from source; a per-user data directory when frozen
# into an app, because PyInstaller's extraction dir is deleted on exit. See
# paths.py — getting this wrong is silent loss of every mass.
MASSES_FILE = paths.masses_file()

# Pause after each message. Matches WaitTime := 400 in ../utils.ahk.
WAIT_TIME = 0.4

# Gap between writing the clipboard and pressing paste. The analogue of AHK's
# ClipWait(1): the write itself is synchronous, but the target app needs a
# moment to see it. Raise if a paste ever lands empty or stale.
CLIP_DELAY = 0.06

# Send all parts of a follow-up as ONE message instead of one each.
# Per group, matching the FuSingle_<model>_<group> settings on Windows.
FU_SINGLE = {1: False, 2: False, 3: False}

# SAFETY GATE fallback, used only when settings.json has none. The live value is
# settings.json's "app_filter" + "app_filter_enabled" pair — a string alone does
# nothing unless the toggle is on, so the keys keep working while you test in a
# scratch window. Compared case-insensitively as a substring against BOTH the
# process/app name and the window title, so "infloww" works on either OS.
# Run --check to see what the current window reports.
APP_FILTER: str | None = None

# HOTKEYS LIVE IN settings.json, under "hotkeys" — see settings.DEFAULT_HOTKEYS
# for the defaults and settings.ACTIONS for the bindable names. Kept there, not
# here, so keys are configured in one file rather than by editing code, the same
# way the AHK build uses hotkeys.ini. An empty value unbinds an action.
#
# The defaults are deliberately NOT the F-keys the Windows original uses,
# because those are taken on both machines for different reasons:
#   Windows (the test box) — 1_mass.ahk binds F1/F2/F3 via hotkeys.ini and
#     CONSUMES the press, so pynput never sees it and this looks dead.
#   macOS (the target)     — F1/F2 are brightness unless "use F-keys as standard
#     function keys" is on, so pynput gets a media key, not <f1>.
# Note pynput does not SUPPRESS the key: it still reaches the focused app, so
# avoid combos the chat app itself binds.

# How often to re-check masses.txt for edits, in seconds.
RELOAD_POLL = 1.0


# ── Backends ─────────────────────────────────────────────────────────────────
# The engine never touches the OS directly, so it can be driven by a fake in
# tests and by --dry-run without a single real keystroke.

class RealBackend:
    def __init__(self):
        import platform_io
        self._io = platform_io
        self._kb = None

    def _keyboard(self):
        if self._kb is None:
            self._kb = self._io.make_keyboard()
        return self._kb

    def set_clipboard(self, text: str) -> None:
        self._io.set_clipboard(text)

    def clear_modifiers(self) -> None:
        """Release any modifier still held from the hotkey that triggered us.

        Ctrl+1 means Ctrl is physically DOWN when the send starts ~60ms later,
        and a send under a held Ctrl delivers NOTHING — measured, not guessed:
        152 chars arrive with no modifier held, 0 with Ctrl held. The F-key
        bindings never hit this because F1 has no modifier.

        Releasing a key that is not pressed is harmless, so this is unconditional
        rather than trying to track which combo fired.
        """
        from pynput import keyboard
        controller, _, _ = self._keyboard()
        for k in (keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r,
                  keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r,
                  keyboard.Key.alt_gr, keyboard.Key.shift, keyboard.Key.shift_l,
                  keyboard.Key.shift_r, keyboard.Key.cmd):
            try:
                controller.release(k)
            except Exception:
                pass                     # not every key exists on every platform

    def paste(self) -> None:
        controller, mod, _ = self._keyboard()
        with controller.pressed(mod):
            controller.tap("v")

    def enter(self) -> None:
        controller, _, enter_key = self._keyboard()
        controller.tap(enter_key)

    def frontmost(self) -> tuple[str, str]:
        return self._io.frontmost()

    def notify(self, msg: str) -> None:
        print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


class DryRunBackend(RealBackend):
    """Everything real except the keystrokes and the clipboard — so the hotkeys,
    the gate, the parsing and the pacing are all genuinely exercised."""

    def set_clipboard(self, text: str) -> None:
        preview = text.replace("\n", " / ")
        if len(preview) > 70:
            preview = preview[:70] + "…"
        print(f"    would paste: {preview}", flush=True)

    def clear_modifiers(self) -> None:
        pass                             # --dry-run fires no key events at all

    def paste(self) -> None:
        pass

    def enter(self) -> None:
        print("    would press Enter", flush=True)


class FakeBackend:
    """Records everything, sleeps not at all. Used by the tests."""

    def __init__(self, app=("TestApp", "Test Window")):
        self.log: list[str] = []
        self.app = app
        # Counted separately, NOT in log: the tests assert the exact key/clipboard
        # sequence, and threading a bookkeeping entry through them would bury the
        # thing they exist to check.
        self.mods_cleared = 0

    @property
    def keys(self) -> list[str]:
        """log without the notifications — the keystroke sequence that actually
        reaches the app, which is what most of these tests are about."""
        return [e for e in self.log if not e.startswith("notify:")]

    def clear_modifiers(self):     self.mods_cleared += 1
    def set_clipboard(self, text): self.log.append(f"clip:{text}")
    def paste(self):               self.log.append("paste")
    def enter(self):               self.log.append("enter")
    def frontmost(self):           return self.app
    def notify(self, msg):         self.log.append(f"notify:{msg}")


# ── Engine ───────────────────────────────────────────────────────────────────

class Engine:
    def __init__(self, backend, masses_file=MASSES_FILE, sleep=time.sleep):
        self.backend = backend
        self.masses_file = masses_file
        self.sleep = sleep
        self.masses: list[massparse.Mass] = []
        self.current = 0
        self.wait_time = WAIT_TIME
        self.clip_delay = CLIP_DELAY
        self.fu_single = dict(FU_SINGLE)
        self.app_filter = APP_FILTER
        self.settings = settings.load(masses_file)
        self.current = int(self.settings.get("current", 0) or 0)
        self.app_filter = settings.app_filter(self.settings)
        self._busy = threading.Lock()
        self._mtime = None
        self._settings_mtime = None
        # Set when --app-filter was passed, so a settings.json reload does not
        # quietly undo an override the user chose for this run.
        self._cli_filter = False

    # ── loading ──────────────────────────────────────────────────────────────

    def load(self, quiet: bool = False) -> bool:
        try:
            with open(self.masses_file, encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            self.backend.notify(f"cannot read {self.masses_file}: {e}")
            self.masses = []
            return False
        try:
            self._mtime = os.path.getmtime(self.masses_file)
        except OSError:
            self._mtime = None

        self.masses = massparse.parse_file(text)
        if self.current >= len(self.masses):
            self.current = 0
        if not quiet:
            if not self.masses:
                self.backend.notify("masses file is empty")
            else:
                m = self.mass()
                self.backend.notify(
                    f"{len(self.masses)} mass(es) — [{self.current + 1}] {m.name}  "
                    f"(f1:{len(m.fu[1])} f2:{len(m.fu[2])} f3:{len(m.fu[3])})")
        return True

    def reload_if_changed(self) -> None:
        """Pick up edits made in gui.py without a restart — both the masses and
        the single/edit checkboxes, which the GUI writes to settings.json."""
        try:
            mtime = os.path.getmtime(self.masses_file)
        except OSError:
            return
        if self._mtime is not None and mtime != self._mtime:
            self.load()

        spath = settings.path_for(self.masses_file)
        try:
            smtime = os.path.getmtime(spath)
        except OSError:
            return
        if self._settings_mtime is None:
            self._settings_mtime = smtime
        elif smtime != self._settings_mtime:
            self._settings_mtime = smtime
            self.settings = settings.load(self.masses_file)
            new_slot = int(self.settings.get("current", self.current) or 0)
            if new_slot != self.current and 0 <= new_slot < len(self.masses):
                self.current = new_slot
                self.backend.notify(f"[{new_slot + 1}] {self.mass().name}")
            # The gate is picked up live, so it can be switched off mid-session
            # to test elsewhere without a restart. Hotkey CHANGES cannot be —
            # pynput binds them once at startup — so those still need a restart.
            new_filter = settings.app_filter(self.settings)
            if new_filter != self.app_filter and not self._cli_filter:
                self.app_filter = new_filter
                self.backend.notify(
                    f"app filter {'on: ' + repr(new_filter) if new_filter else 'OFF — keys fire anywhere'}")

    def slot(self, model: int | None) -> int:
        """Resolve a 0-based mass slot. None means 'whatever is selected'.

        Each model has its OWN hotkeys, so a send names its slot outright and
        never depends on which one happens to be selected — self.current is
        only the GUI's selection and the default for --send.
        """
        return self.current if model is None else model

    def mass(self, model: int | None = None) -> massparse.Mass | None:
        i = self.slot(model)
        if 0 <= i < len(self.masses):
            return self.masses[i]
        return None

    # ── gate ─────────────────────────────────────────────────────────────────

    def app_allowed(self, announce: bool = False) -> bool:
        if not self.app_filter:
            return True
        want = self.app_filter.lower()
        name, title = self.backend.frontmost()
        ok = want in (name or "").lower() or want in (title or "").lower()
        if not ok and announce:
            # Say why. A gate that blocks in silence is indistinguishable from a
            # dead hotkey, and that is a genuinely expensive thing to debug —
            # one wrong character in the filter and the app looks broken.
            self.backend.notify(
                f"blocked: app filter {self.app_filter!r} does not match "
                f"app={name!r} title={title!r}  (Ctrl+Alt+I to check)")
        return ok

    # ── sending ──────────────────────────────────────────────────────────────

    def is_single(self, group: int, model: int | None = None) -> bool:
        """The 'single' checkbox: all parts as one message. Per model AND group,
        matching FuSingle_<model>_<group> on Windows."""
        if settings.get_flag(self.settings, "single", self.slot(model), group):
            return True
        return bool(self.fu_single.get(group))       # module-level fallback

    def is_editable(self, group: int, model: int | None = None) -> bool:
        """The 'edit' checkbox: paste the combined parts but do not press Enter,
        so it can be reviewed first. Windows calls this SndFuEditable."""
        return settings.get_flag(self.settings, "editable", self.slot(model), group)

    def parts_for(self, group: int, model: int | None = None) -> list[str]:
        m = self.mass(model)
        if not m:
            return []
        parts = list(m.fu.get(group, []))
        # 'edit' implies joining: SndFuEditable combines every part into one
        # paste, because half a follow-up in the box is not reviewable.
        if (self.is_single(group, model) or self.is_editable(group, model)) \
                and len(parts) > 1:
            return ["\n".join(parts)]
        return parts

    def _send(self, parts: list[str], press_enter: bool = True) -> None:
        for part in parts:
            # Before EVERY part, not just the first: the hotkey's modifier can
            # still be held when part one goes out, and a send under a held Ctrl
            # delivers nothing at all.
            self.backend.clear_modifiers()
            self.backend.set_clipboard(part)
            self.sleep(self.clip_delay)
            self.backend.paste()
            if press_enter:
                self.backend.enter()
            self.sleep(self.wait_time)

    def label(self, model: int | None) -> str:
        """'M2' etc. Every message names the model, because with three sets of
        keys the useful question is always 'which one did I just fire'."""
        return f"M{self.slot(model) + 1}"

    def send_fu(self, group: int, model: int | None = None) -> None:
        if not self.app_allowed(announce=True):
            return
        who = self.label(model)
        m = self.mass(model)
        if not m:
            self.backend.notify(
                f"{who}: no such mass slot — check {self.masses_file}")
            return
        parts = self.parts_for(group, model)
        if not parts:
            self.backend.notify(f"{who}: nothing in follow-up {group}")
            return
        enter = not self.is_editable(group, model)
        # Say what happened. A live send was completely silent, which makes
        # "the key never fired" and "it fired and the paste went elsewhere"
        # indistinguishable from the outside — the two failures need opposite
        # fixes, and guessing between them is expensive.
        self.backend.notify(
            f"{who} sending f{group}: {len(parts)} part(s)"
            f"{'' if enter else ', no Enter (edit mode)'}")
        self._send(parts, press_enter=enter)
        self.backend.notify(f"{who} f{group} done")

    def paste_mass(self, model: int | None = None) -> None:
        """Paste the mass body without sending it, so it can be reviewed and
        edited first. Same behaviour as DoMass()/__mm on Windows."""
        if not self.app_allowed(announce=True):
            return
        who = self.label(model)
        m = self.mass(model)
        if not m or not m.mass:
            self.backend.notify(f"{who}: no mass body")
            return
        self.backend.clear_modifiers()       # the hotkey holds two modifiers
        self.backend.set_clipboard(m.mass)
        self.sleep(self.clip_delay)
        self.backend.paste()
        self.backend.notify(
            f"{who} pasted mass body ({len(m.mass)} chars), no Enter")

    def next_mass(self) -> None:
        if not self.masses:
            return
        self.current = (self.current + 1) % len(self.masses)
        self.backend.notify(
            f"[{self.current + 1}/{len(self.masses)}] {self.mass().name}")

    def whoami(self) -> None:
        name, title = self.backend.frontmost()
        self.backend.notify(f"focused: app={name!r} title={title!r}")

    # ── dispatch ─────────────────────────────────────────────────────────────

    def dispatch(self, action: str, arg: int, model: int | None = None) -> None:
        """Run an action off the hotkey thread.

        `model` is the 0-based slot the key belongs to, or None for the global
        keys. Sending takes about a second, and pynput delivers hotkeys on its
        own listener thread — doing the work there would stop every other hotkey
        being noticed until the send finished. The lock is what stops a second
        press mid-send from interleaving two follow-ups into the chat, and it is
        deliberately GLOBAL rather than per model: two models sending at once
        would interleave in whatever single window is focused.
        """
        if action in ("next", "reload", "whoami"):
            {"next": self.next_mass,
             "reload": self.load,
             "whoami": self.whoami}[action]()
            return

        if not self._busy.acquire(blocking=False):
            self.backend.notify(f"{self.label(model)}: still sending — ignored")
            return

        def worker():
            try:
                if action == "fu":
                    self.send_fu(arg, model)
                elif action == "mass":
                    self.paste_mass(model)
            except Exception as e:                  # never let the lock leak
                self.backend.notify(f"send failed: {e!r}")
            finally:
                self._busy.release()

        threading.Thread(target=worker, daemon=True).start()


# ── CLI ──────────────────────────────────────────────────────────────────────

def describe(engine: Engine) -> None:
    """Print exactly how every mass parsed. This is what stands in for the GUI:
    the one thing the text file cannot do is show you that your paste landed in
    the slots you meant."""
    if not engine.masses:
        print("No masses parsed.")
        return
    for i, m in enumerate(engine.masses, 1):
        marker = "->" if i - 1 == engine.current else "  "
        print(f"\n{marker} [{i}] {m.name}")
        print(f"     mass: {m.mass or '(none)'}")
        for g in (1, 2, 3):
            parts = m.fu[g]
            if not parts:
                print(f"     f{g}:   (empty)")
                continue
            single = " [joined into one message]" if engine.fu_single.get(g) else ""
            print(f"     f{g}:   {len(parts)} message(s){single}")
            for p in parts:
                flat = p.replace("\n", " / ")
                print(f"            - {flat}")
        if m.ppv.base:
            print(f"     ppv:  {m.ppv.base.splitlines()[0]}  (parsed, no key bound)")


def pretty(combo: str) -> str:
    """'<ctrl>+<alt>+m' -> 'Ctrl+Alt+M', for the startup banner."""
    out = []
    for part in combo.split("+"):
        part = part.strip().strip("<>")
        out.append(part.upper() if len(part) == 1 else part.capitalize())
    return "+".join(out)


def ahk_conflict() -> list[str]:
    """Which MMA AutoHotkey scripts are running, on the Windows test box.

    The AHK build owns F1/F2/F3 globally (hotkeys.ini: mass.1.fu1=F1) and
    CONSUMES the keypress, so pynput's listener never sees it and this looks
    silently broken. Nothing here can take a key off AHK — the two builds cannot
    share one key — so the only fix is to stop one or rebind the other.

    This build sidesteps it by binding Ctrl+1/2/3, which no MMA script claims,
    so a running AHK is now only a note. The check stays because the failure it
    catches is invisible: put an F-key back into HOTKEYS and the symptom is a
    dead key with no error anywhere.
    """
    if sys.platform != "win32":
        return []                      # no AHK on macOS; the whole issue is moot
    import subprocess

    # PowerShell first: wmic is REMOVED on Windows 11 24H2+ (verified absent on
    # 26200), so leading with it raised FileNotFoundError on every single call
    # and only worked by falling through to here anyway. wmic is kept second for
    # pre-PS-3.0 machines, where Get-CimInstance does not exist.
    out = ""
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"Name like 'AutoHotkey%'\" "
             "| Select-Object -ExpandProperty CommandLine"],
            capture_output=True, timeout=10).stdout.decode("utf-8", "replace")
    except Exception:
        pass
    if not out.strip():
        try:
            out = subprocess.run(
                ["wmic", "process", "where", "name like 'AutoHotkey%'", "get", "CommandLine"],
                capture_output=True, timeout=5).stdout.decode("utf-8", "replace")
        except Exception:
            return []
    found = []
    for script in ("1_mass.ahk", "2_mass.ahk", "3_mass.ahk", "mass_gui.ahk"):
        if script.lower() in out.lower():
            found.append(script)
    return found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="show how masses.txt parsed, then exit")
    ap.add_argument("--dry-run", action="store_true",
                    help="run normally but print instead of sending")
    ap.add_argument("--send", type=int, metavar="N",
                    help="send follow-up N once and exit (respects --dry-run)")
    ap.add_argument("--model", type=int, metavar="M",
                    help=f"which model 1-{settings.MODELS} --send uses "
                         "(default: the selected slot)")
    ap.add_argument("--file", default=MASSES_FILE, help="masses file to use")
    ap.add_argument("--app-filter", default=None,
                    help="only fire when the focused window matches this "
                         "(overrides app_filter in settings.json for this run)")
    args = ap.parse_args(argv)

    backend = DryRunBackend() if args.dry_run else RealBackend()
    engine = Engine(backend, masses_file=args.file)
    # ONLY when actually passed. Assigning unconditionally overwrote the
    # app_filter that Engine.__init__ had just read from settings.json with the
    # flag's default of None, so the safety gate could never be turned on from
    # the config file at all — it silently fell open on every run.
    if args.app_filter is not None:
        engine.app_filter = args.app_filter
        engine._cli_filter = True

    if args.check:
        engine.load(quiet=True)
        print(f"masses file: {engine.masses_file}")
        print(f"{len(engine.masses)} mass(es) parsed")
        describe(engine)
        try:
            name, title = backend.frontmost()
            print(f"\nfocused window right now: app={name!r} title={title!r}")
            print("APP_FILTER should be a substring of one of those.")
        except Exception as e:
            print(f"\n(could not read the focused window: {e})")
        return 0

    if not engine.load():
        return 1

    if args.send is not None:
        model = None
        if args.model is not None:
            if not 1 <= args.model <= settings.MODELS:
                print(f"--model must be 1-{settings.MODELS}", file=sys.stderr)
                return 2
            model = args.model - 1
        engine.send_fu(args.send, model)
        return 0

    try:
        from pynput import keyboard
    except ImportError:
        print("pynput is not installed:  pip install pynput", file=sys.stderr)
        return 2

    # settings.json holds the bindings, one section per model, so keys are
    # configured in one file rather than by editing code — the same reason the
    # AHK build keeps its bindings in hotkeys.ini.
    table = settings.hotkeys(engine.settings)
    bindings = {}
    bad = []
    for section, binds in table.items():
        is_global = section == "global"
        model = None if is_global else int(section.split(".")[1]) - 1
        catalogue = settings.GLOBAL_ACTIONS if is_global else settings.MODEL_ACTIONS
        for name, combo in binds.items():
            action, arg = catalogue[name]
            try:
                keyboard.HotKey.parse(combo)  # validate BEFORE GlobalHotKeys sees it
            except ValueError as e:
                # One malformed combo would otherwise raise inside GlobalHotKeys
                # and take every other key down with it.
                bad.append(f"{section}/{name}={combo!r} ({e})")
                continue
            bindings[combo] = (
                lambda a=action, g=arg, m=model: engine.dispatch(a, g, m))

    if not bindings:
        print("no usable hotkeys — check the 'hotkeys' block in settings.json",
              file=sys.stderr)
        return 2

    print(f"MMA  |  {len(engine.masses)} mass(es)  |  "
          f"{'DRY RUN — nothing will be sent' if args.dry_run else 'live'}")

    # Report the keys actually bound, not a hardcoded string — the whole point
    # of moving them into settings.json is that the banner can lie otherwise.
    order = ["fu1", "fu2", "fu3", "mass"]
    for model in range(1, settings.MODELS + 1):
        binds = table[settings.model_key(model)]
        name = engine.masses[model - 1].name if model - 1 < len(engine.masses) else "—"
        shown = [f"{pretty(binds[n])} {n}" for n in order if n in binds]
        print(f"      M{model} {name[:28]:<28} " +
              (" · ".join(shown) if shown else "(no keys bound)"))
    gl = table["global"]
    gnames = {"reload": "reload", "whoami": "which window", "next": "next slot"}
    print("      " + " · ".join(f"{pretty(gl[n])} {t}"
                                for n, t in gnames.items() if n in gl))

    # Two actions on one combo is silent — pynput keeps only the last binding,
    # so one of them simply never fires. With three models that is easy to do.
    clash_keys = settings.conflicts(table)
    for combo, who in clash_keys.items():
        print(f"      DUPLICATE {pretty(combo)}: {', '.join(who)} "
              f"— only the last one fires", file=sys.stderr)
    for b in bad:
        print(f"      IGNORED bad hotkey: {b}", file=sys.stderr)

    if settings.is_legacy_hotkeys(engine.settings):
        # Migrated in memory, not on disk — say so, or the old keys keep working
        # and the two extra models look broken for no visible reason.
        print("      NOTE: settings.json still uses the old single-model hotkey "
              "format;\n            it has been read as M1. Open the GUI's "
              "Settings to write the new layout.")

    if engine.app_filter:
        print(f"      app filter ON: {engine.app_filter!r} — keys only fire there.")
    else:
        print("      app filter OFF — keys fire into whatever is focused.")

    clash = ahk_conflict()
    if clash:
        # Only a real problem if we bound a key AHK already owns.
        stolen = sorted(c for c in bindings if "<f" in c)
        if stolen:
            print()
            print("  ┌─ AutoHotkey is running and owns these keys ─────────────────┐")
            print(f"  │  {', '.join(clash)}")
            print("  │  hotkeys.ini binds mass.1.fu1=F1, fu2=F2, fu3=F3, and AHK")
            print(f"  │  swallows the press — {', '.join(stolen)} here will do NOTHING.")
            print("  │")
            print("  │  Fix, either way round:")
            print("  │    * close those AHK scripts (right-click tray icon > Exit)")
            print("  │    * or change 'hotkeys' in settings.json to free keys")
            print("  │")
            print("  │  Not an issue on macOS: there is no AHK there.")
            print("  └─────────────────────────────────────────────────────────────┘")
            print()
        else:
            print(f"      (AutoHotkey running: {', '.join(clash)} — no clash, "
                  "this build is on Ctrl+1/2/3)")
    if sys.platform == "darwin":
        print("      macOS: needs Accessibility permission, and F-keys set to "
              "'standard function keys' in System Settings → Keyboard.")
    print("      Ctrl+C to stop.\n")

    stop = threading.Event()

    def watch():
        while not stop.wait(RELOAD_POLL):
            engine.reload_if_changed()

    threading.Thread(target=watch, daemon=True).start()

    try:
        with keyboard.GlobalHotKeys(bindings) as listener:
            listener.join()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    print("\nStopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
