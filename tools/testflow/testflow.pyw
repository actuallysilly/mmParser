"""
TestFlow — a local Infloww Messages clone for testing MMA and grading the AI.

Two windows over one local server (server.py):

    "Infloww Messages - TestFlow"   the clone. Pixel-faithful to the reference
                                    layout, so MMA's chat reader, detectors and
                                    autoword work on it as they do on Infloww.
    "TestFlow Lab"                  the controls: who you play, the AI fan's
                                    persona, PPVs, blind drafts and 1-5 ratings.

Why the title contains "Infloww Messages": that is what MMA's screen readers
match on (automation.TARGET_TITLE). The PROCESS is pythonw.exe, not infloww.exe,
on purpose: typelog is scoped to infloww.exe, so nothing typed here reaches your
corpus. Autoword is let in by title instead ([Scope] Titles = TestFlow).

Why Python + WebView2 and not Electron: both render with Chromium, which is what
the pixel readers care about; the AI side (suggest.py, client.py) is already
Python and is called directly; and it needs one pip package, not Node.

    pythonw testflow.pyw            open both windows
    python  testflow.pyw --browser  serve only, and open the pages in a browser
    python  testflow.pyw --port N   fixed port (default: any free one)

Needs: pip install pywebview  (and Ollama running for anything AI).
"""
from __future__ import annotations

import argparse
import ctypes
import sys
import time
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server  # noqa: E402

MUTEX = "Global\\MMA.testflow.mutex"
CLONE_TITLE = "Infloww Messages - TestFlow"
LAB_TITLE = "TestFlow Lab"


def log(msg: str) -> None:
    try:
        f = server.ai.MMA_ROOT / "debuglogs" / "error_log.txt"
        f.parent.mkdir(exist_ok=True)
        with f.open("a", encoding="utf-8") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [testflow] {msg}\n")
    except OSError:
        pass


def single_instance() -> bool:
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW(None, False, MUTEX)
    return k32.GetLastError() != 183          # ERROR_ALREADY_EXISTS


class WindowApi:
    """Called from the clone's own title-bar buttons (the window is frameless,
    like Infloww's, so the model tab strip IS the title bar)."""

    # Underscore names only: pywebview exposes every PUBLIC attribute of this
    # object to the page and walks into it, and a Window is a deep tree of .NET
    # objects it cannot touch off the UI thread (it floods the log and recurses).
    def __init__(self):
        self._window = None
        self._max = False

    def minimize(self):
        self._window.minimize()

    def toggle_maximize(self):
        if self._max:
            self._window.restore()
        else:
            self._window.maximize()
        self._max = not self._max

    def close(self):
        self._window.destroy()


def _show_lab(lab) -> None:
    """pywebview 6.2 creates the second window but never shows it: it sat there
    hidden (IsWindowVisible false) while the clone opened, so the Lab, the only
    place to switch modes, was unreachable. Show it ourselves, and if the
    wrapper's show() is not enough either, ask Windows directly."""
    time.sleep(0.8)
    try:
        lab.show()
    except Exception as e:
        log(f"lab.show failed: {e}")
    time.sleep(0.8)
    try:
        u32 = ctypes.windll.user32
        found = []
        proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

        def each(h, _):
            buf = ctypes.create_unicode_buffer(256)
            u32.GetWindowTextW(ctypes.c_void_p(h), buf, 256)
            if buf.value == LAB_TITLE:
                found.append(h)
                return False
            return True
        u32.EnumWindows(proc(each), None)
        if found and not u32.IsWindowVisible(ctypes.c_void_p(found[0])):
            u32.ShowWindow(ctypes.c_void_p(found[0]), 5)       # SW_SHOW
            log("lab was still hidden after show(); shown with ShowWindow")
    except Exception as e:
        log(f"lab visibility check failed: {e}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="TestFlow")
    ap.add_argument("--browser", action="store_true", help="no windows: open the pages in a browser")
    ap.add_argument("--port", type=int, default=0)
    a = ap.parse_args(argv)

    if not single_instance():
        log("already running")
        return 0
    httpd = server.serve(a.port)
    url = f"http://127.0.0.1:{httpd.server_address[1]}"
    log(f"serving on {url}")

    if a.browser:
        webbrowser.open(url + "/clone")
        webbrowser.open(url + "/lab")
        print(f"TestFlow on {url}  (Ctrl+C to stop)")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            return 0

    try:
        import webview
    except ImportError:
        log("pywebview is not installed (pip install pywebview); opening the browser instead")
        webbrowser.open(url + "/clone")
        webbrowser.open(url + "/lab")
        while True:
            time.sleep(1)

    api = WindowApi()
    # 1400x900 fits a 1080p screen and keeps the reference proportions; Infloww
    # is resizable and so is this. Maximise for the reference 1920x1032.
    # Side by side, the Lab to the right: left to Windows, the Lab opened on top
    # of the clone and hid behind it, and it is the only place to switch modes.
    clone = webview.create_window(CLONE_TITLE, url + "/clone", width=1400, height=900,
                                  x=20, y=20, frameless=True, easy_drag=False, js_api=api,
                                  background_color="#151515", min_size=(1000, 650))
    api._window = clone
    lab = webview.create_window(LAB_TITLE, url + "/lab", width=520, height=900,
                                x=1430, y=20, background_color="#121316", min_size=(420, 500))

    def on_clone_closed():
        try:
            lab.destroy()
        except Exception:
            pass
    clone.events.closed += on_clone_closed

    storage = server.ai.MMA_ROOT / "userdata" / "testflow" / "webview"
    storage.mkdir(parents=True, exist_ok=True)
    webview.start(_show_lab, (lab,), gui="edgechromium", private_mode=False,
                  storage_path=str(storage))
    log("closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
