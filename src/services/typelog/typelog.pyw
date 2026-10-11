#!/usr/bin/env python3
"""
MMA typelog — a passive keystroke-to-text recorder, scoped to Infloww.

It records the messages YOU send in Infloww Messages, one per line, into a daily
log (userdata\\typelog\\messages\\YYYY-MM-DD.log). The point is to mine your own
writing — for hotstrings, and as the training data for autoword.

ONLY SENT MESSAGES, AND ONLY WHEN THEY ARE SENT
Keystrokes go into a model of the message box (message.py), held in memory, and
nothing is written until a plain Enter sends it. Shift+Enter is a line break
inside the message. Backspace, Ctrl+Backspace and Ctrl+A-then-retype edit the
model, so a draft you delete never reaches the log. Pastes are read from the
clipboard, which is how hotstring and mass sends (Snd() = Ctrl+V, Enter) are
recorded at all.

Each message is tagged with the ACCOUNT it went out from and a CONVERSATION
number. Neither can be seen from the keyboard: the mass engine publishes MMA's
resolved account and the conversation list's screen rectangle to
userdata\\active_now.ini (core/active_publish.ahk), and a click inside that
rectangle is a switch to another fan. A conversation also ends when the account
changes or nothing has been sent for CONV_IDLE_S.

When the keystrokes stop describing the box — the caret moved, part of it was
selected, Ctrl+Z, Win+V — the message is written to YYYY-MM-DD.uncertain.log
instead, with the reason, so the main log only ever holds text we can vouch for.

This replaces a recorder that wrote its keystroke buffer to disk every five
seconds. Backspace could not reach anything already written, so every pause
committed the draft on screen, and the old logs (userdata\\typelog\\*.log, left
where they are) are full of abandoned drafts run into the sent text.

Same shape as the pinger and the automation listener (see core/processes.ahk):
a headless background process with no console and no AHK window, so MMA drives it
through a NAMED EVENT — its existence answers "is it up?", setting it means
"please exit" — and it is launched via a .vbs so nothing flashes on screen.

  typelog_start.vbs        start it silently (pythonw, no console)
  typelog.pyw --stop       ask a background recorder to exit
  typelog.pyw --status     is one running?
  typelog.pyw --listen     headless: log operational lines to MMA's error_log.txt

-------------------------------------------------------------------------------
SCOPE — only records while Infloww is in front
-------------------------------------------------------------------------------
It logs ONLY while the foreground window is Infloww (matched by process name,
title as a fallback — the same window the pinger and detector watch). It records
NOTHING while you are in your bank, password manager, DMs, or anywhere else.
Infloww is an Electron DESKTOP app on Windows, not a web app, so the primary
match is the foreground process's own .exe. Set SCOPE_ENABLED = False to record
everything (not recommended).

-------------------------------------------------------------------------------
PRIVACY  (read this — it is why the feature ships OFF)
-------------------------------------------------------------------------------
This is the one MMA tool that records WHAT you type, not just that you typed —
the activity tracker was built so it structurally cannot; this is built to. Within
Infloww it captures everything you enter there, and Infloww is where fan handles
and message text live. So:

  * it is OFF by default and must be switched on deliberately (Settings ▸ Features
    or the Tools window), exactly like the activity tracker and for a stronger
    reason;
  * the log is plain text on YOUR disk under userdata\\, which is gitignored and
    never leaves the machine;
  * PAUSE it (the [typelog] pause hotkey, default Ctrl+Alt+F9) before typing
    anything you would not want written down;
  * delete old logs once you have mined them for hotstrings.

Needs one package: pynput  (pip install pynput, or run install.bat WithPython).
"""

import argparse
import configparser
import queue
import ctypes
import datetime
import os
import re
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

try:
    from pynput import keyboard, mouse
except ImportError:                     # headless: say so in MMA's log, then give up
    keyboard = mouse = None

from message import START, MessageBox, apply_key, escape

# ── MMA paths ────────────────────────────────────────────────────────────────
# MMA_ROOT from THIS file's location, never the working directory — the same rule
# the AHK side follows (paths.ahk) and the same bug the pinger and automation
# listener both hit: a wrong ancestor does not raise, it silently reads/writes the
# wrong file. This lives at src\services\typelog\typelog.pyw, so parents[3] is the
# repo root.
MMA_ROOT       = Path(__file__).resolve().parents[3]
MMA_USERDATA   = MMA_ROOT / "userdata"
MMA_DEBUGLOGS  = MMA_ROOT / "debuglogs"
MMA_DEBUGLOGS.mkdir(exist_ok=True)

# The recorded text — the product — lands in userdata\ beside the activity CSVs,
# gitignored like the rest of userdata\. NOT in debuglogs\: this is not a
# diagnostic you throw away, it is what the feature exists to produce.
# messages\ and not the folder itself: the old keystroke-dump logs live there and
# are a different format, so the two are never mixed in one file or one glob.
LOG_DIR        = MMA_USERDATA / "typelog" / "messages"

# Operational lines (started, scope changes, errors) go to MMA's shared log when
# headless, tagged [typelog] — the same file the pinger writes to.
MMA_LOG        = MMA_DEBUGLOGS / "error_log.txt"
LOG_TAG        = "typelog"

# The pause hotkey lives in MMA's one ini like every other key — never hard-coded
# here (config-in-ini). Declared in hotkeys.ahk [typelog] and edited in the
# Hotkeys GUI, but bound HERE (pynput), not by AHK, exactly like [automation].
HOTKEYS_INI    = MMA_USERDATA / "hotkeys.ini"

# Written by the mass engine (core/active_publish.ahk): which account MMA resolved,
# and where the conversation list is on screen. Absent when MMA is not running, in
# which case messages are tagged "?" and only idle time splits conversations.
ACTIVE_NOW     = MMA_USERDATA / "active_now.ini"
CONV_IDLE_S    = 600                   # nothing sent for this long = a new conversation
HOTKEY_SECTION = "typelog"
PAUSE_FALLBACK = "^!F9"                 # used only if the ini has no [typelog] pause

# ── config ───────────────────────────────────────────────────────────────────
SCOPE_ENABLED        = True
SCOPE_PROCESS_NAMES  = ["infloww.exe"]  # foreground exe (Task Manager ▸ Details)
SCOPE_TITLE_PATTERNS = ["infloww"]      # fallback: substring in the window title
SCOPE_POLL_INTERVAL  = 0.25            # seconds between foreground-window checks

# ── single-instance / stop, MMA's named-event scheme ─────────────────────────
MUTEX_NAME      = "Global\\MMA.typelog.mutex"
STOP_EVENT_NAME = "Global\\MMA.typelog.stop"
ERROR_ALREADY_EXISTS = 183

# ── state ────────────────────────────────────────────────────────────────────
_box      = MessageBox()
_held: set[str] = set()                 # modifier keys down, by pynput name
_lock     = threading.Lock()
_sent: queue.Queue = queue.Queue()      # (when, Message, account, conv), or None to stop
# The conversation being typed in: its id (the time it started, unique within a
# day and readable), the account it belongs to, and when it last sent anything.
# id None = the next send starts a new one.
_conv = {"id": None, "account": None, "last": 0.0}
_paused   = False
_in_scope = not SCOPE_ENABLED
_stop     = threading.Event()

_mutex      = None                      # module-level: must outlive the function
_stop_event = None

# ── window scope (Windows) ───────────────────────────────────────────────────
_SCOPE_SUPPORTED = SCOPE_ENABLED and sys.platform == "win32"
_TITLE_PATTERNS  = [p.lower() for p in SCOPE_TITLE_PATTERNS]
_PROCESS_NAMES   = [p.lower() for p in SCOPE_PROCESS_NAMES]

if sys.platform == "win32":
    _user32   = ctypes.windll.user32
    _kernel32 = ctypes.windll.kernel32

    # HWND/HANDLE are pointers; the default 32-bit int restype truncates them on
    # 64-bit Python.
    _user32.GetForegroundWindow.restype        = wintypes.HWND
    _user32.GetWindowTextLengthW.argtypes      = [wintypes.HWND]
    _user32.GetWindowTextLengthW.restype       = ctypes.c_int
    _user32.GetWindowTextW.argtypes            = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.GetWindowTextW.restype             = ctypes.c_int
    _user32.GetWindowThreadProcessId.argtypes  = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    _user32.GetWindowThreadProcessId.restype   = wintypes.DWORD

    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    _kernel32.OpenProcess.argtypes             = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.OpenProcess.restype              = wintypes.HANDLE
    _kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    _kernel32.QueryFullProcessImageNameW.restype  = wintypes.BOOL
    _kernel32.CloseHandle.argtypes             = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype              = wintypes.BOOL
    _user32.OpenClipboard.argtypes             = [wintypes.HWND]
    _user32.OpenClipboard.restype              = wintypes.BOOL
    _user32.GetClipboardData.argtypes          = [wintypes.UINT]
    _user32.GetClipboardData.restype           = wintypes.HANDLE
    _user32.CloseClipboard.restype             = wintypes.BOOL
    _user32.GetAsyncKeyState.argtypes          = [ctypes.c_int]
    _user32.GetAsyncKeyState.restype           = ctypes.c_short
    _kernel32.GlobalLock.argtypes              = [wintypes.HGLOBAL]
    _kernel32.GlobalLock.restype               = ctypes.c_void_p
    _kernel32.GlobalUnlock.argtypes            = [wintypes.HGLOBAL]
    _kernel32.CreateMutexW.restype             = ctypes.c_void_p
    _kernel32.CreateEventW.restype             = ctypes.c_void_p
    _kernel32.OpenEventW.restype               = ctypes.c_void_p
    _kernel32.SetEvent.argtypes                = [ctypes.c_void_p]
    _kernel32.WaitForSingleObject.argtypes     = [ctypes.c_void_p, ctypes.c_ulong]


def _foreground_title() -> str:
    hwnd = _user32.GetForegroundWindow()
    if not hwnd:
        return ""
    n = _user32.GetWindowTextLengthW(hwnd)
    if n <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(n + 1)
    _user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def _foreground_process() -> str:
    hwnd = _user32.GetForegroundWindow()
    if not hwnd:
        return ""
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if not pid.value:
        return ""
    h = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
    if not h:
        return ""
    try:
        size = wintypes.DWORD(260)
        buf = ctypes.create_unicode_buffer(size.value)
        if _kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return Path(buf.value).name
        return ""
    finally:
        _kernel32.CloseHandle(h)


def _window_in_scope() -> bool:
    """True if the foreground window is the app we're allowed to log."""
    if not SCOPE_ENABLED:
        return True
    if not _SCOPE_SUPPORTED:
        return True                      # can't inspect windows here -> log everything
    try:
        title = _foreground_title().lower()
        if any(p in title for p in _TITLE_PATTERNS):
            return True
        if _PROCESS_NAMES:
            proc = _foreground_process().lower()
            if any(p in proc for p in _PROCESS_NAMES):
                return True
    except Exception:
        return _in_scope                 # never let a window query take the recorder down
    return False


# ── single-instance / stop signalling (mirrors pinger.pyw) ───────────────────
def claim_single_instance() -> bool:
    """False if another typelog already holds the mutex. Two would double every
    keystroke into the log."""
    global _mutex
    _mutex = _kernel32.CreateMutexW(None, True, MUTEX_NAME)
    return _kernel32.GetLastError() != ERROR_ALREADY_EXISTS


def create_stop_event() -> None:
    global _stop_event
    _stop_event = _kernel32.CreateEventW(None, True, False, STOP_EVENT_NAME)


def stop_requested() -> bool:
    if not _stop_event:
        return False
    return _kernel32.WaitForSingleObject(_stop_event, 0) == 0     # WAIT_OBJECT_0


def stop_running_typelog() -> bool:
    """Signal a background typelog to exit. True if one was running."""
    h = _kernel32.OpenEventW(0x0002, False, STOP_EVENT_NAME)      # EVENT_MODIFY_STATE
    if not h:
        return False
    _kernel32.SetEvent(h)
    _kernel32.CloseHandle(h)
    return True


def typelog_running() -> bool:
    h = _kernel32.OpenEventW(0x0002, False, STOP_EVENT_NAME)
    if not h:
        return False
    _kernel32.CloseHandle(h)
    return True


class _MmaLog:
    """Headless under pythonw there is no console, so stdout goes to MMA's log —
    the same error_log.txt format the pinger and automation listener write."""

    def __init__(self, tag=LOG_TAG):
        self.tag, self._buf = tag, ""

    def write(self, s):
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._emit(line)

    def _emit(self, line):
        if not line.strip():
            return
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(MMA_LOG, "a", encoding="utf-8") as f:
                f.write(f"{stamp}  [{self.tag}]  {line.rstrip()}\n")
        except OSError:
            pass                                   # a log write must never kill it

    def flush(self):
        if self._buf.strip():
            self._emit(self._buf)
            self._buf = ""


# ── the pause hotkey, read from MMA's one ini ────────────────────────────────
def _read_ini_text(path: Path) -> str:
    """The Hotkeys GUI writes this file through AHK/Win32, so it may be ANSI or
    UTF-16 rather than UTF-8. Decode defensively — a hotkey edit must not be able
    to kill the recorder. Same helper automation.py uses."""
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("cp1252", "replace")


def read_pause_key() -> str:
    """[typelog] pause from hotkeys.ini, as the raw AHK key string. '' if absent
    or blank (blank = deliberately disabled, the MMA convention)."""
    if not HOTKEYS_INI.exists():
        return PAUSE_FALLBACK
    cp = configparser.ConfigParser(strict=False)
    try:
        cp.read_string(_read_ini_text(HOTKEYS_INI))
    except configparser.Error as e:
        print(f"hotkeys.ini parse error: {e} — pause hotkey disabled")
        return ""
    if not cp.has_section(HOTKEY_SECTION):
        return PAUSE_FALLBACK           # not merged in yet; use the shipped default
    return (cp.get(HOTKEY_SECTION, "pause", fallback="") or "").strip()


_AHK_TO_PYNPUT_MOD = {"^": "<ctrl>", "!": "<alt>", "+": "<shift>", "#": "<cmd>"}
# Named keys pynput accepts as <name>; MMA's own names on the left.
_AHK_TO_PYNPUT_KEY = {
    "space": "<space>", "enter": "<enter>", "return": "<enter>",
    "esc": "<esc>", "escape": "<esc>", "tab": "<tab>",
    "backspace": "<backspace>", "bs": "<backspace>",
    "del": "<delete>", "delete": "<delete>", "ins": "<insert>", "insert": "<insert>",
    "home": "<home>", "end": "<end>", "pgup": "<page_up>", "pgdn": "<page_down>",
    "up": "<up>", "down": "<down>", "left": "<left>", "right": "<right>",
}


def ahk_to_pynput(spec: str) -> str:
    """Convert an AHK hotkey string (^!F9, ^+z, !Space) into pynput's
    GlobalHotKeys format (<ctrl>+<alt>+<f9>). '' if unconvertible."""
    s = (spec or "").strip()
    if not s:
        return ""
    mods, i = [], 0
    while i < len(s) and s[i] in _AHK_TO_PYNPUT_MOD:
        mods.append(_AHK_TO_PYNPUT_MOD[s[i]])
        i += 1
    key = s[i:].strip().lstrip("<>")     # <^ />! left/right variants: not distinguished
    if not key:
        return ""
    low = key.lower()
    if low in _AHK_TO_PYNPUT_KEY:
        token = _AHK_TO_PYNPUT_KEY[low]
    elif re.fullmatch(r"f\d{1,2}", low):
        token = f"<{low}>"               # F1..F24
    elif len(key) == 1:
        token = key.lower()
    else:
        return ""                        # a key we don't map — no pause rather than a wrong one
    return "+".join(mods + [token])


# ── the recorder ─────────────────────────────────────────────────────────────
def _logfile(day: datetime.date, uncertain: bool) -> Path:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    return LOG_DIR / f"{day:%Y-%m-%d}{'.uncertain' if uncertain else ''}.log"


def _writer() -> None:
    """Writes each sent message as one line. Its own thread, so a slow disk never
    delays a keystroke. A None in the queue means drain and exit.

        main log        time <tab> kind <tab> account <tab> conv <tab> text
        uncertain log   time <tab> kind <tab> account <tab> conv <tab> reasons <tab> text

    kind is typed|pasted|mixed; account is "site:slot:name" or "?"; conv is the
    time its conversation started. Line breaks and tabs inside text are escaped
    (message.escape)."""
    while True:
        item = _sent.get()
        if item is None:
            return
        when, msg, account, conv = item
        cols = [f"{when:%H:%M:%S}", msg.kind, escape(account), conv]
        if not msg.exact:
            cols.append(",".join(msg.reasons))
        cols.append(escape(msg.text))
        try:
            with open(_logfile(when.date(), not msg.exact), "a", encoding="utf-8") as fh:
                fh.write("\t".join(cols) + "\n")
        except OSError as exc:
            print(f"write failed: {exc}")


_active_cache = {"mtime": None, "data": {}}


def _active() -> dict:
    """active_now.ini as a dict, re-read only when the file changed. {} when MMA is
    not running or the file is unreadable: tagging must never stop a recording."""
    try:
        mt = ACTIVE_NOW.stat().st_mtime_ns
    except OSError:
        return {}
    if mt != _active_cache["mtime"]:
        data = {}
        try:
            for line in ACTIVE_NOW.read_text(encoding="utf-8-sig").splitlines():
                k, sep, v = line.partition("=")
                if sep:
                    data[k.strip()] = v.strip()
        except OSError:
            return _active_cache["data"]
        _active_cache.update(mtime=mt, data=data)
    return _active_cache["data"]


def _account() -> str:
    """'infloww:1:tab 1', or '?' when MMA does not know which account is in front."""
    a = _active()
    if a.get("state") != "ok" or a.get("no", "0") in ("", "0"):
        return "?"
    return f"{a.get('site', '')}:{a['no']}:{a.get('name', '')}"


def _in_chat_list(x: int, y: int) -> bool:
    """Is a screen point inside the conversation list MMA published?"""
    try:
        lx, ly, lw, lh = (int(v) for v in _active().get("list", "").split(","))
    except ValueError:
        return False
    return lx <= x < lx + lw and ly <= y < ly + lh


def _tag(now: float) -> tuple[str, str]:
    """The account and conversation id for a message sent now, starting a new
    conversation if the account changed, a fan was clicked, or it went idle."""
    account = _account()
    if (_conv["id"] is None or account != _conv["account"]
            or now - _conv["last"] > CONV_IDLE_S):
        _conv["id"] = time.strftime("%H:%M:%S", time.localtime(now))
        _conv["account"] = account
    _conv["last"] = now
    return account, _conv["id"]


CF_UNICODETEXT = 13


def _read_clipboard() -> str | None:
    """The clipboard's text at the moment of a paste, or None if it cannot be read.

    Runs on pynput's listener thread, after the hook has already passed the key on,
    so a short retry here delays our bookkeeping, never your typing. Snd() fills
    the clipboard and waits for it before pressing Ctrl+V, and does not touch it
    again until after its Enter, so what is read here is what was pasted."""
    for _ in range(5):
        if _user32.OpenClipboard(None):
            break
        time.sleep(0.01)                 # someone else has it open; brief, then retry
    else:
        return None
    try:
        handle = _user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None                  # an image, a file list — no text
        ptr = _kernel32.GlobalLock(handle)
        if not ptr:
            return None
        try:
            return ctypes.wstring_at(ptr)
        finally:
            _kernel32.GlobalUnlock(handle)
    finally:
        _user32.CloseClipboard()


# pynput's names for the modifier keys, by what they mean. Left and right are
# tracked separately in _held, so releasing one Ctrl while holding the other does
# not drop Ctrl. AltGr arrives as alt_gr plus a ctrl_l Windows synthesises.
_MODIFIERS = {
    "ctrl": "ctrl", "ctrl_l": "ctrl", "ctrl_r": "ctrl",
    "shift": "shift", "shift_l": "shift", "shift_r": "shift",
    "alt": "alt", "alt_l": "alt", "alt_r": "alt", "alt_gr": "alt",
    "cmd": "win", "cmd_l": "win", "cmd_r": "win",
}
# For resyncing _held from Windows when focus changes (see _resync_modifiers).
_MODIFIER_VKS = {"ctrl_l": 0xA2, "ctrl_r": 0xA3, "shift_l": 0xA0, "shift_r": 0xA1,
                 "alt_l": 0xA4, "alt_r": 0xA5, "cmd_l": 0x5B, "cmd_r": 0x5C}


def _key_name(key) -> str | None:
    return key.name if isinstance(key, keyboard.Key) else None


def on_press(key) -> None:
    # Modifiers are tracked from the event stream itself, in or out of scope.
    # pynput calls this AFTER the hook has let the key through, so asking Windows
    # "is Ctrl down?" here would describe some later moment — Snd()'s Ctrl is
    # released long before its V is handled here.
    name = _key_name(key)
    if name in _MODIFIERS:
        _held.add(name)
        return
    if _paused or not _in_scope:
        return
    mods = {_MODIFIERS[n] for n in _held}
    with _lock:
        msg = apply_key(_box, name, getattr(key, "vk", None),
                        getattr(key, "char", None), mods, _read_clipboard)
    if msg is not None:
        now = time.time()
        account, conv = _tag(now)
        _sent.put((datetime.datetime.fromtimestamp(now), msg, account, conv))


def on_release(key) -> None:
    _held.discard(_key_name(key))


def on_click(x, y, button, pressed, *_injected) -> None:
    """Any click may have put the caret somewhere else in the box — including the
    click that brings Infloww back to the front, which lands while another window
    is still foreground. So clicks count whatever is in front."""
    if pressed and not _paused:
        switched = _in_chat_list(x, y)
        with _lock:
            if switched:
                # Another fan: a new conversation, and the box you left keeps its
                # unsent draft — the next message starts from empty.
                _box.switch_chat()
                _conv["id"] = None
            else:
                _box.caret_away()


def _resync_modifiers() -> None:
    """A release that happened while we were not looking (Win+L, a UAC prompt)
    would leave a modifier stuck down forever. Rebuild from Windows' own state
    whenever focus changes."""
    held = {n for n, vk in _MODIFIER_VKS.items() if _user32.GetAsyncKeyState(vk) & 0x8000}
    _held.clear()
    _held.update(held)


def _toggle_pause() -> None:
    global _paused
    _paused = not _paused
    with _lock:
        # Whatever is typed while paused is unseen: resume as if just started.
        _box.unseen(START)
    print("PAUSED  — logging is OFF" if _paused else "RESUMED — logging is ON")


def _scope_poll() -> None:
    """Watch the foreground window and flip _in_scope. Leaving Infloww does NOT
    end the message: the draft stays in Infloww's box, and the caret with it, so
    typing on after an Alt+Tab back continues the same message."""
    global _in_scope
    while not _stop.wait(SCOPE_POLL_INTERVAL):
        now = _window_in_scope()
        if now == _in_scope:
            continue
        _resync_modifiers()
        _in_scope = now


def run_recorder(interval: float = 0.5) -> int:
    """Start the hooks and record until the stop event is set (or Ctrl+C)."""
    global _in_scope
    if keyboard is None:
        print("pynput is not installed — cannot record. Run install.bat WithPython,"
              " or: pip install pynput")
        return 2

    # Physical pixels, like AHK's: the conversation-list rectangle MMA publishes is
    # in them, and a DPI-unaware process can be handed scaled coordinates on a
    # mixed-DPI desk. Before any listener starts.
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)      # per-monitor aware
    except (AttributeError, OSError):
        pass
    print(f"recording to {LOG_DIR}")
    a = _active()
    print(f"account tagging: {_account()}" + ("" if a else
          "  (no active_now.ini yet: MMA's mass engine writes it)"))
    if SCOPE_ENABLED:
        scope = ", ".join(SCOPE_TITLE_PATTERNS + SCOPE_PROCESS_NAMES) or "(nothing)"
        if _SCOPE_SUPPORTED:
            print(f"scoped: only logging while the active window matches: {scope}")
            _in_scope = _window_in_scope()     # evaluate once so we don't wait a full poll
        else:
            print(f"scope requested ({scope}) but this platform can't inspect"
                  " windows — logging EVERYTHING instead.")

    with _lock:
        _box.unseen(START)               # the box may already hold a draft
    writer = threading.Thread(target=_writer, daemon=True)
    writer.start()
    if _SCOPE_SUPPORTED:
        threading.Thread(target=_scope_poll, daemon=True).start()

    raw = read_pause_key()
    spec = ahk_to_pynput(raw)
    hotkeys = None
    if spec:
        try:
            hotkeys = keyboard.GlobalHotKeys({spec: _toggle_pause})
            hotkeys.start()
            print(f"pause/resume: {raw}   (Settings ▸ Hotkeys ▸ [typelog] pause)")
        except Exception as e:
            print(f"could not register pause hotkey {raw!r} ({spec!r}): {e}"
                  " — recording without a pause key")
            hotkeys = None
    else:
        print(f"no usable [typelog] pause hotkey ({raw!r}) — recording without one")

    listener = keyboard.Listener(on_press=on_press, on_release=on_release)
    listener.start()
    clicks = mouse.Listener(on_click=on_click)
    clicks.start()

    print("recording. Stop with: typelog.pyw --stop   (or Ctrl+C)")
    try:
        while not stop_requested():
            time.sleep(interval)
        print("stop requested — exiting")
    except KeyboardInterrupt:
        pass
    finally:
        _stop.set()
        listener.stop()
        clicks.stop()
        if hotkeys:
            hotkeys.stop()
        _sent.put(None)                  # drain what was sent; an unsent draft is not a message
        writer.join(timeout=5)
        print("stopped.")
    return 0


# ── entry point ──────────────────────────────────────────────────────────────
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA typelog — Infloww keystroke recorder")
    ap.add_argument("--stop", action="store_true", help="stop a running typelog")
    ap.add_argument("--status", action="store_true", help="report whether one runs")
    ap.add_argument("--listen", action="store_true",
                    help="headless: log operational lines to MMA's error_log.txt")
    args = ap.parse_args(argv)

    if args.stop:
        print("stopped" if stop_running_typelog() else "not running")
        return 0
    if args.status:
        running = typelog_running()
        print("running" if running else "not running")
        return 0 if running else 1

    if args.listen:
        sys.stdout = sys.stderr = _MmaLog()

    if not claim_single_instance():
        print("another typelog is already running — exiting")
        return 0
    create_stop_event()

    return run_recorder()


if __name__ == "__main__":
    sys.exit(main())
