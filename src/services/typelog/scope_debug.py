#!/usr/bin/env python3
"""
scope_debug.py - show exactly what typelog's scoping sees.

This does NOT capture any keystrokes. It just reads the FOREGROUND window's
process name + title once a second and prints whether it would count as
"in scope" for the current patterns. Run it, then click into Infloww and read
the output.

    python scope_debug.py        (Ctrl+C to stop)
"""
import sys
import time
import ctypes
from ctypes import wintypes
from pathlib import Path

if sys.platform != "win32":
    sys.exit("Windows only.")

# --- keep these identical to typelog.pyw ---
SCOPE_PROCESS_NAMES  = ["infloww.exe"]
SCOPE_TITLE_PATTERNS = ["infloww"]

user32   = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

user32.GetForegroundWindow.restype       = wintypes.HWND
user32.GetWindowTextLengthW.argtypes     = [wintypes.HWND]
user32.GetWindowTextLengthW.restype      = ctypes.c_int
user32.GetWindowTextW.argtypes           = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype            = ctypes.c_int
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype  = wintypes.DWORD

_PQLI = 0x1000  # PROCESS_QUERY_LIMITED_INFORMATION
kernel32.OpenProcess.argtypes            = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype             = wintypes.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
kernel32.QueryFullProcessImageNameW.restype  = wintypes.BOOL
kernel32.CloseHandle.argtypes            = [wintypes.HANDLE]
kernel32.CloseHandle.restype             = wintypes.BOOL


def fg_title() -> str:
    h = user32.GetForegroundWindow()
    if not h:
        return ""
    n = user32.GetWindowTextLengthW(h)
    if n <= 0:
        return ""
    b = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(h, b, n + 1)
    return b.value


def fg_process() -> str:
    h = user32.GetForegroundWindow()
    if not h:
        return ""
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
    if not pid.value:
        return ""
    ph = kernel32.OpenProcess(_PQLI, False, pid.value)
    if not ph:
        return "<OpenProcess denied - Infloww may be running elevated/as admin>"
    try:
        size = wintypes.DWORD(260)
        b = ctypes.create_unicode_buffer(size.value)
        if kernel32.QueryFullProcessImageNameW(ph, 0, b, ctypes.byref(size)):
            return Path(b.value).name
        return ""
    finally:
        kernel32.CloseHandle(ph)


def main() -> None:
    print("Watching the foreground window (Ctrl+C to stop).")
    print("Click into Infloww's messaging window and watch IN_SCOPE flip to True.\n")
    last = None
    try:
        while True:
            p, t = fg_process(), fg_title()
            pm = any(x in p.lower() for x in SCOPE_PROCESS_NAMES)
            tm = any(x in t.lower() for x in SCOPE_TITLE_PATTERNS)
            line = (f"proc={p!r:60}  title={t!r:50}  "
                    f"process_match={pm}  title_match={tm}  IN_SCOPE={pm or tm}")
            if line != last:
                print(line)
                last = line
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nstopped.")


if __name__ == "__main__":
    main()
