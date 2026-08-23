#!/usr/bin/env python3
"""
MMA typelog — a passive keystroke-to-text recorder, scoped to Infloww.

It reconstructs the text YOU type in Infloww Messages into readable lines and
appends it to a daily log (userdata\\typelog\\YYYY-MM-DD.log). The point is to
mine your own repetitive phrases and turn them into hotstrings — the same job the
Hotstrings manager does from the other end.

Same shape as the pinger and the automation listener (see core/processes.ahk):
a headless background process with no console and no AHK window, so MMA drives it
through a NAMED EVENT — its existence answers "is it up?", setting it means
"please exit" — and it is launched via a .vbs so nothing flashes on screen.

  typelog_start.vbs        start it silently (pythonw, no console)
  typelog.pyw --stop       ask a background recorder to exit (flushes first)
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
    from pynput import keyboard
except ImportError:                     # headless: say so in MMA's log, then give up
    keyboard = None

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
LOG_DIR        = MMA_USERDATA / "typelog"

# Operational lines (started, scope changes, errors) go to MMA's shared log when
# headless, tagged [typelog] — the same file the pinger writes to.
MMA_LOG        = MMA_DEBUGLOGS / "error_log.txt"
LOG_TAG        = "typelog"

# The pause hotkey lives in MMA's one ini like every other key — never hard-coded
# here (config-in-ini). Declared in hotkeys.ahk [typelog] and edited in the
# Hotkeys GUI, but bound HERE (pynput), not by AHK, exactly like [automation].
HOTKEYS_INI    = MMA_USERDATA / "hotkeys.ini"
HOTKEY_SECTION = "typelog"
PAUSE_FALLBACK = "^!F9"                 # used only if the ini has no [typelog] pause

# ── config ───────────────────────────────────────────────────────────────────
FLUSH_INTERVAL       = 5.0              # seconds between automatic disk writes
SCOPE_ENABLED        = True
SCOPE_PROCESS_NAMES  = ["infloww.exe"]  # foreground exe (Task Manager ▸ Details)
SCOPE_TITLE_PATTERNS = ["infloww"]      # fallback: substring in the window title
SCOPE_POLL_INTERVAL  = 0.25            # seconds between foreground-window checks

# ── single-instance / stop, MMA's named-event scheme ─────────────────────────
MUTEX_NAME      = "Global\\MMA.typelog.mutex"
STOP_EVENT_NAME = "Global\\MMA.typelog.stop"
ERROR_ALREADY_EXISTS = 183

# ── state ────────────────────────────────────────────────────────────────────
_buf      = []
_lock     = threading.Lock()
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
def _logfile() -> Path:
    """Today's log (rolls over at midnight)."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    return LOG_DIR / f"{datetime.date.today():%Y-%m-%d}.log"


def _flush() -> None:
    """Append the buffered text to today's log and clear the buffer."""
    global _buf
    with _lock:
        if not _buf:
            return
        text = "".join(_buf)
        _buf = []
    try:
        with open(_logfile(), "a", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as exc:
        print(f"write failed: {exc}")


def on_press(key) -> None:
    if _paused or not _in_scope:
        return
    try:
        ch = key.char                    # printable keys expose .char
    except AttributeError:
        ch = None

    with _lock:
        if ch is not None:
            # ch.isprintable() keeps normal text + AltGr chars (@, {, [, č, ć...)
            # while silently dropping control chars from shortcuts (Ctrl+C -> '\x03').
            if ch.isprintable():
                _buf.append(ch)
        elif key == keyboard.Key.space:
            _buf.append(" ")
        elif key == keyboard.Key.enter:
            _buf.append("\n")
        elif key == keyboard.Key.tab:
            _buf.append("\t")
        elif key == keyboard.Key.backspace:
            if _buf:
                _buf.pop()
        # all other special keys (shift, arrows, F-keys, ...) are ignored

    # This runs on the low-level keyboard hook, i.e. on the input path, so it does
    # NOTHING slow — just lock + append. Disk I/O is on the flush thread and the
    # foreground window is inspected on the scope thread, never here.


def _toggle_pause() -> None:
    global _paused
    _paused = not _paused
    _flush()
    print("PAUSED  — logging is OFF" if _paused else "RESUMED — logging is ON")


def _periodic_flush() -> None:
    while not _stop.wait(FLUSH_INTERVAL):
        _flush()


def _scope_poll() -> None:
    """Watch the foreground window and flip _in_scope. On leaving Infloww we close
    the current segment with a newline and flush, so phrases from different focus
    sessions never run together."""
    global _in_scope
    while not _stop.wait(SCOPE_POLL_INTERVAL):
        now = _window_in_scope()
        if now == _in_scope:
            continue
        if not now:                      # just left the scoped app
            with _lock:
                if _buf and _buf[-1] != "\n":
                    _buf.append("\n")
            _flush()
        _in_scope = now


def run_recorder(interval: float = 0.5) -> int:
    """Start the hooks and record until the stop event is set (or Ctrl+C)."""
    global _in_scope
    if keyboard is None:
        print("pynput is not installed — cannot record. Run install.bat WithPython,"
              " or: pip install pynput")
        return 2

    print(f"recording to {LOG_DIR}")
    if SCOPE_ENABLED:
        scope = ", ".join(SCOPE_TITLE_PATTERNS + SCOPE_PROCESS_NAMES) or "(nothing)"
        if _SCOPE_SUPPORTED:
            print(f"scoped: only logging while the active window matches: {scope}")
            _in_scope = _window_in_scope()     # evaluate once so we don't wait a full poll
        else:
            print(f"scope requested ({scope}) but this platform can't inspect"
                  " windows — logging EVERYTHING instead.")

    flusher = threading.Thread(target=_periodic_flush, daemon=True)
    flusher.start()
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

    listener = keyboard.Listener(on_press=on_press)
    listener.start()

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
        if hotkeys:
            hotkeys.stop()
        _flush()
        print("stopped, buffer flushed.")
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
