#!/usr/bin/env python3
"""
platform_io.py — everything that differs between Windows and macOS.

Isolated here so mma.py contains no platform branches at all, and so the engine
can be tested against a fake backend instead of a real keyboard.

Three jobs:
    clipboard        set (and read back, for tests)
    keystrokes       paste and Enter, with the right modifier per OS
    frontmost app    for the "only fire in the right window" safety gate

The clipboard is done natively rather than via pyperclip: it is ~40 lines of
ctypes on Windows and one subprocess call on macOS, and the project already
leans on ctypes in pinger.pyw. One less dependency to install on two machines.
"""

from __future__ import annotations

import os
import subprocess
import sys

IS_WINDOWS = sys.platform == "win32"
IS_MAC = sys.platform == "darwin"

if not (IS_WINDOWS or IS_MAC):
    # Linux would need xclip/wl-copy and a different frontmost-window call.
    # Nothing here is Windows/macOS specific by accident, but it is untested.
    print(f"[mma] warning: {sys.platform} is not a supported platform", file=sys.stderr)


# ── clipboard ────────────────────────────────────────────────────────────────

if IS_WINDOWS:
    import ctypes
    import ctypes.wintypes as wintypes

    _u32 = ctypes.windll.user32
    _k32 = ctypes.windll.kernel32

    # Handles are pointer-sized. Without these the return value is truncated to
    # 32 bits on a 64-bit build and the clipboard write corrupts or crashes.
    _k32.GlobalAlloc.restype = wintypes.HGLOBAL
    _k32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    _k32.GlobalLock.restype = ctypes.c_void_p
    _k32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    _k32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    _u32.SetClipboardData.restype = wintypes.HANDLE
    _u32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    _u32.GetClipboardData.restype = wintypes.HANDLE
    _u32.GetClipboardData.argtypes = [wintypes.UINT]

    # Same reason: these return pointer-sized values and ctypes would otherwise
    # assume c_int, truncating every handle on a 64-bit build.
    _u32.GetForegroundWindow.restype = wintypes.HWND
    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]

    _CF_UNICODETEXT = 13
    _GMEM_MOVEABLE = 0x0002

    def _open_clipboard(retries: int = 10) -> None:
        """Another app can hold the clipboard for a few ms at a time; a single
        OpenClipboard failing is normal, not fatal."""
        import time
        for _ in range(retries):
            if _u32.OpenClipboard(None):
                return
            time.sleep(0.01)
        raise OSError("could not open the clipboard (held by another app)")

    def set_clipboard(text: str) -> None:
        _open_clipboard()
        try:
            _u32.EmptyClipboard()
            buf = ctypes.create_unicode_buffer(text)
            size = ctypes.sizeof(buf)
            handle = _k32.GlobalAlloc(_GMEM_MOVEABLE, size)
            if not handle:
                raise OSError("GlobalAlloc failed")
            ptr = _k32.GlobalLock(handle)
            ctypes.memmove(ptr, buf, size)
            _k32.GlobalUnlock(handle)
            # Ownership of `handle` passes to the system on success — it must
            # NOT be freed here.
            if not _u32.SetClipboardData(_CF_UNICODETEXT, handle):
                raise OSError("SetClipboardData failed")
        finally:
            _u32.CloseClipboard()

    def get_clipboard() -> str:
        _open_clipboard()
        try:
            handle = _u32.GetClipboardData(_CF_UNICODETEXT)
            if not handle:
                return ""
            ptr = _k32.GlobalLock(handle)
            try:
                return ctypes.c_wchar_p(ptr).value or ""
            finally:
                _k32.GlobalUnlock(handle)
        finally:
            _u32.CloseClipboard()

elif IS_MAC:
    def set_clipboard(text: str) -> None:
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)

    def get_clipboard() -> str:
        out = subprocess.run(["pbpaste"], capture_output=True, check=True)
        return out.stdout.decode("utf-8")

else:
    def set_clipboard(text: str) -> None:
        raise NotImplementedError(f"clipboard not implemented for {sys.platform}")

    def get_clipboard() -> str:
        raise NotImplementedError(f"clipboard not implemented for {sys.platform}")


# ── frontmost application ────────────────────────────────────────────────────

if IS_WINDOWS:
    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    def frontmost() -> tuple[str, str]:
        """(process name, window title) of the focused window."""
        hwnd = _u32.GetForegroundWindow()
        if not hwnd:
            return "", ""

        length = _u32.GetWindowTextLengthW(hwnd)
        buf = ctypes.create_unicode_buffer(length + 1)
        _u32.GetWindowTextW(hwnd, buf, length + 1)
        title = buf.value

        pid = wintypes.DWORD()
        _u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        name = ""
        h = _k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if h:
            try:
                size = wintypes.DWORD(260)
                path = ctypes.create_unicode_buffer(size.value)
                if _k32.QueryFullProcessImageNameW(h, 0, path, ctypes.byref(size)):
                    name = os.path.basename(path.value)
                    if name.lower().endswith(".exe"):
                        name = name[:-4]
            finally:
                _k32.CloseHandle(h)
        return name, title

elif IS_MAC:
    def frontmost() -> tuple[str, str]:
        """(app name, window title). Prefers PyObjC; falls back to osascript.

        The osascript path costs ~50-100ms, which is why it runs only when
        APP_FILTER is actually set.
        """
        try:
            from AppKit import NSWorkspace  # type: ignore
            app = NSWorkspace.sharedWorkspace().frontmostApplication()
            return (app.localizedName() or ""), ""
        except Exception:
            pass
        try:
            script = ('tell application "System Events" to get name of '
                      'first application process whose frontmost is true')
            out = subprocess.run(["osascript", "-e", script],
                                 capture_output=True, timeout=2)
            return out.stdout.decode("utf-8").strip(), ""
        except Exception:
            return "", ""

else:
    def frontmost() -> tuple[str, str]:
        return "", ""


# ── keystrokes ───────────────────────────────────────────────────────────────

def make_keyboard():
    """A pynput controller plus the paste modifier for this OS.

    Imported lazily: the parser and --check must work without pynput installed,
    and on macOS importing it can trigger the Accessibility prompt.
    """
    from pynput import keyboard

    controller = keyboard.Controller()
    paste_mod = keyboard.Key.cmd if IS_MAC else keyboard.Key.ctrl
    return controller, paste_mod, keyboard.Key.enter
