"""
Live Trainer — grade the AI against your real chats, as they happen.

A separate window that mirrors the Infloww conversation you are in: the fan,
the whole chat seen so far (not just the screenful), and after each fan message
the reply the AI WOULD have sent. You grade it 1-10; your real reply is saved
next to it. Nothing is typed or sent into Infloww. The logic, and what is saved
where, is in trainer.py.

Needs the Chat reader running (Settings ▸ Features ▸ Chat reader): this reads its
userdata\\chat_now.json and never captures Infloww itself.

The window title must NOT contain "Infloww Messages": MMA's screen readers find
Infloww by that title and would read this window instead.

    pythonw livetrainer.pyw
"""
from __future__ import annotations

import ctypes
import functools
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "testflow"))
sys.path.insert(0, str(HERE.parents[1] / "src" / "services" / "llm"))

import trainer as TR                       # noqa: E402

MUTEX = "Global\\MMA.livetrainer.mutex"
TITLE = "MMA Live Trainer"
POLL_S = 0.4


def log(msg: str) -> None:
    try:
        f = TR.MMA_ROOT / "debuglogs" / "error_log.txt"
        f.parent.mkdir(exist_ok=True)
        with f.open("a", encoding="utf-8") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [livetrainer] {msg}\n")
    except OSError:
        pass


def single_instance() -> bool:
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW(None, False, MUTEX)
    return k32.GetLastError() != 183          # ERROR_ALREADY_EXISTS


def focus_existing() -> None:
    u32 = ctypes.windll.user32
    h = u32.FindWindowW(None, TITLE)
    if h:
        u32.ShowWindow(h, 9)                  # SW_RESTORE
        u32.SetForegroundWindow(h)


class Api:
    # Underscore names only: pywebview walks every PUBLIC attribute of this
    # object (see TestFlow's WindowApi).
    def __init__(self, trainer: TR.Trainer, tiers: list[str]):
        self._t = trainer
        self._tiers = tiers

    def state(self, since: int = -1):
        if since == self._t.version:
            return None
        snap = self._t.snapshot()
        snap["tiers"] = self._tiers
        return snap

    def grade(self, draft_id: str, score, note: str = ""):
        return self._t.grade(draft_id, None if score in (None, "") else int(score), note or "")

    def set_tier(self, tier):
        self._t.set_tier(int(tier))

    def draft_now(self):
        self._t.draft_now()

    def reset_history(self):
        self._t.reset_history()


def main() -> int:
    if not single_instance():
        focus_existing()
        return 0
    import webview
    import ai                               # TestFlow's: nextmove read -> suggest write
    import chatreader as CR

    # A real chat: the PPV is the chatter's pick, the bot never invents one.
    t = TR.Trainer(drafter=functools.partial(ai.her_reply, invent_ppv=False))

    def poll():
        while True:
            try:
                t.tick(CR.running())
            except Exception as e:          # one bad read must not stop the loop
                log(f"tick failed: {e.__class__.__name__}: {e}")
                time.sleep(2)
            time.sleep(POLL_S)

    threading.Thread(target=poll, daemon=True).start()
    webview.create_window(TITLE, str(HERE / "ui" / "index.html"), js_api=Api(t, list(ai.TIERS)),
                          width=560, height=900, min_size=(380, 500), background_color="#1b1b1b")
    webview.start(storage_path=str(TR.DATA / "webview"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log(f"crashed: {e.__class__.__name__}: {e}")
        raise
