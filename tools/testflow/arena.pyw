"""
TestFlow Arena — the AI fan against her AI, with you able to step in anywhere.
See arena.py for what it does and where it writes.

    pythonw arena.pyw            open the Arena window
    python  arena.pyw --browser  serve only, and open the page in a browser
    python  arena.pyw --port N   fixed port (default: any free one)

Its own process, server and state, so it runs beside TestFlow. The title is
"TestFlow Arena", never "Infloww Messages": MMA's screen readers must not
mistake it for a real chat.

Needs: pip install pywebview  (and Ollama running).
"""
from __future__ import annotations

import argparse
import ctypes
import sys
import time
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import arena  # noqa: E402

MUTEX = "Global\\MMA.testflow.arena.mutex"
TITLE = "TestFlow Arena"


def log(msg: str) -> None:
    try:
        f = arena.ai.MMA_ROOT / "debuglogs" / "error_log.txt"
        f.parent.mkdir(exist_ok=True)
        with f.open("a", encoding="utf-8") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [arena] {msg}\n")
    except OSError:
        pass


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="TestFlow Arena")
    ap.add_argument("--browser", action="store_true")
    ap.add_argument("--port", type=int, default=0)
    a = ap.parse_args(argv)

    k32 = ctypes.windll.kernel32
    k32.CreateMutexW(None, False, MUTEX)
    if k32.GetLastError() == 183:             # ERROR_ALREADY_EXISTS
        log("already running")
        return 0
    httpd = arena.serve(a.port)
    url = f"http://127.0.0.1:{httpd.server_address[1]}/"
    log(f"serving on {url}")

    try:
        import webview
    except ImportError:
        webview = None
        log("pywebview is not installed (pip install pywebview); opening the browser instead")
    if a.browser or webview is None:
        webbrowser.open(url)
        print(f"Arena on {url}  (Ctrl+C to stop)")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            return 0

    webview.create_window(TITLE, url, width=1500, height=920, background_color="#121316",
                          min_size=(760, 560))
    storage = arena.ai.MMA_ROOT / "userdata" / "testflow" / "webview"
    storage.mkdir(parents=True, exist_ok=True)
    webview.start(gui="edgechromium", private_mode=False, storage_path=str(storage))
    log("closed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
