"""
autoword — the open chat as context for the language model ([Model] Context = chat).

The screenshot -> OCR -> transcript pipeline already runs: the chat reader
(src/services/llm/chatreader.pyw, Settings > Features > "Chat reader") OCRs the
open Infloww chat whenever it changes and keeps the result in
userdata/chat_now.json. This only READS that file. No capture, no OCR and no
numpy here: autoword's hook thread cannot afford the ~2 s an OCR costs, and the
reader has already paid it.

What the LM gets in front of the message being typed: the last few bubbles,
oldest first, one per line, each as its text alone. That is the shape it was
fine-tuned on (the previous message, a newline, then the message being typed),
just longer. There are no "fan:"/"model:" labels, because the fine-tune never saw
any.

WHEN IT IS NOT USED (the caller falls back to the previous typed message):
  * the reader is not running (its mutex is gone), so the file is a leftover;
  * the file is for another window (its title is not the foreground's);
  * the read failed (it carries a note and no bubbles).
It can still be a second or two behind after you switch fans. The reader waits
for the pane to settle before it reads. That costs one word's ranking, not a
wrong word typed, so it is not worth a capture of our own to rule out.
"""
from __future__ import annotations

import ctypes
import json
from ctypes import wintypes
from pathlib import Path

from config import MMA_ROOT

CHAT_NOW = MMA_ROOT / "userdata" / "chat_now.json"
READER_MUTEX = "Global\\MMA.chatreader.mutex"
TURNS = 6                 # bubbles of context
MAX_CHARS = 600           # and no more than this, cut from the old end

_k32 = ctypes.windll.kernel32
_u32 = ctypes.windll.user32
_k32.OpenMutexW.restype = wintypes.HANDLE
_u32.GetForegroundWindow.restype = wintypes.HWND
SYNCHRONIZE = 0x00100000


def reader_running() -> bool:
    h = _k32.OpenMutexW(SYNCHRONIZE, False, READER_MUTEX)
    if h:
        _k32.CloseHandle(h)
        return True
    return False


def foreground_title() -> str:
    hwnd = _u32.GetForegroundWindow()
    if not hwnd:
        return ""
    n = _u32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    _u32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


class ChatContext:
    """Reads chat_now.json when it changes; `text()` is the context or ""."""

    def __init__(self, path: Path = CHAT_NOW, turns: int = TURNS):
        self.path = path
        self.turns = turns
        self._mtime = None
        self._title = ""
        self._text = ""
        self.why = "not read yet"        # why text() is "" (for the log)

    def _reload(self) -> None:
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            self._mtime, self._text, self.why = None, "", "no chat_now.json"
            return
        if mtime == self._mtime:
            return
        self._mtime = mtime
        try:
            state = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self._text, self.why = "", "chat_now.json unreadable"
            return
        self._title = state.get("title") or ""
        lines = []
        for t in state.get("turns") or []:
            text = (t.get("text") or "").strip()
            if not text:
                continue                 # media, or a bubble the OCR found empty
            lines.append(text)
        lines = lines[-self.turns:]
        out = "\n".join(lines)
        if len(out) > MAX_CHARS:
            out = out[-MAX_CHARS:].split("\n", 1)[-1]
        self._text = out
        self.why = "" if out else (state.get("note") or "no bubbles read")

    def text(self) -> str:
        if not reader_running():
            self.why = "the chat reader is not running"
            return ""
        self._reload()
        if not self._text:
            return ""
        if self._title and foreground_title() != self._title:
            self.why = "chat_now.json is for another window"
            return ""
        return self._text
