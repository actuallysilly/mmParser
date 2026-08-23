"""
autoword — how a suggestion gets on screen.

`Renderer` is the second seam. The engine hands it a list of candidates and an
active index and never learns what happened to them, so the three modes below —
and the ghost-text mode that isn't built yet — are interchangeable at startup.

    NullRenderer   draws nothing, writes what it WOULD have suggested to
                   debuglogs\\autoword_shadow.log. This is the mode to run first:
                   it measures real accuracy against live typing with no UI risk
                   and no chance of a wrong suggestion costing a keystroke.
    StripRenderer  a small always-on-top row near the message box. tkinter, one
                   toplevel, no focus stealing.
    GhostRenderer  grey text at the caret. Not implemented — see README for why
                   it is harder than it looks and what would have to be true.

All rendering happens on the Tk main thread. The keyboard hook calls show/hide
from the listener thread, so StripRenderer marshals through a queue rather than
touching widgets directly — Tk is not thread-safe and will crash days later if
you do it the obvious way.
"""
from __future__ import annotations

import datetime
import queue
import threading
from pathlib import Path
from typing import Protocol, Sequence

from config import MMA_DEBUGLOGS, Config
from model import Candidate


class Renderer(Protocol):
    def show(self, candidates: Sequence[Candidate], active: int, context: str) -> None: ...
    def hide(self) -> None: ...
    def close(self) -> None: ...
    def pump(self) -> None:
        """Called on the main thread. Renderers that own a UI loop do work here."""
        ...


# ── off ───────────────────────────────────────────────────────────────────────
class NullRenderer:
    """Predict, draw nothing, record. The safe way to earn the UI."""

    def __init__(self, cfg: Config):
        self.path = MMA_DEBUGLOGS / "autoword_shadow.log"
        self.path.parent.mkdir(exist_ok=True)
        self._lock = threading.Lock()
        self._last: tuple[str, ...] = ()

    def show(self, candidates, active, context):
        words = tuple(c.word for c in candidates)
        if words == self._last:
            return
        self._last = words
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        line = (f"{stamp}\t{context}\t"
                + "\t".join(f"{c.word}:{c.probability:.3f}:{c.source}" for c in candidates))
        with self._lock:
            try:
                with self.path.open("a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except OSError:
                pass

    def hide(self):
        self._last = ()

    def close(self):
        pass

    def pump(self):
        pass


# ── strip ─────────────────────────────────────────────────────────────────────
class StripRenderer:
    """A borderless always-on-top row of candidates, positioned near the caret's
    window. Deliberately dumb: it never takes focus, never resizes the target,
    and disappears the moment the engine says so."""

    def __init__(self, cfg: Config):
        import tkinter as tk  # imported here so `off` mode needs no display

        self.cfg = cfg
        self.tk = tk
        self._q: queue.Queue = queue.Queue()
        self._visible = False

        self.root = tk.Tk()
        self.root.withdraw()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        # never take focus — the target app must keep the caret
        self.root.attributes("-alpha", 0.92)
        self.root.configure(bg=cfg.strip_bg)

        self.frame = tk.Frame(self.root, bg=cfg.strip_bg)
        self.frame.pack(padx=6, pady=3)
        self.labels: list = []

    # -- called from the hook thread -------------------------------------------
    def show(self, candidates, active, context):
        self._q.put(("show", [c.word for c in candidates], active))

    def hide(self):
        self._q.put(("hide", None, 0))

    def close(self):
        self._q.put(("close", None, 0))

    # -- called on the main thread ---------------------------------------------
    def pump(self):
        try:
            while True:
                op, payload, active = self._q.get_nowait()
                if op == "show":
                    self._draw(payload, active)
                elif op == "hide":
                    self._hide()
                elif op == "close":
                    self.root.destroy()
                    return
        except queue.Empty:
            pass
        self.root.update_idletasks()
        self.root.update()

    def _draw(self, words, active):
        cfg = self.cfg
        for lbl in self.labels:
            lbl.destroy()
        self.labels = []
        for i, word in enumerate(words):
            lbl = self.tk.Label(
                self.frame, text=word,
                bg=cfg.strip_hl if i == active else cfg.strip_bg,
                fg=cfg.strip_bg if i == active else cfg.strip_fg,
                font=(cfg.strip_font_name, cfg.strip_font_size,
                      "bold" if i == active else "normal"),
                padx=6, pady=1)
            lbl.pack(side="left", padx=2)
            self.labels.append(lbl)

        x, y = self._anchor()
        self.root.geometry(f"+{x}+{y}")
        if not self._visible:
            self.root.deiconify()
            self.root.attributes("-topmost", True)
            self._visible = True

    def _hide(self):
        if self._visible:
            self.root.withdraw()
            self._visible = False

    def _anchor(self) -> tuple[int, int]:
        """Bottom-left of the foreground window, plus the configured offset.

        Anchoring to the window rather than the caret is the whole reason this
        mode is the simple one: no accessibility API, no font metrics, nothing
        that breaks when the target app re-renders.
        """
        cfg = self.cfg
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            user32.GetForegroundWindow.restype = wintypes.HWND
            hwnd = user32.GetForegroundWindow()
            rect = wintypes.RECT()
            if hwnd and user32.GetWindowRect(hwnd, ctypes.byref(rect)):
                return rect.left + cfg.strip_offset_x, rect.bottom + cfg.strip_offset_y
        except Exception:
            pass
        return 100, 100


# ── ghost (not implemented) ───────────────────────────────────────────────────
class GhostRenderer:
    """Grey text at the caret, inside the target's textbox.

    Deliberately unimplemented rather than half-built. Getting the caret's pixel
    position out of Infloww (an Electron app) needs one of:

      * UIA TextPattern -> GetSelection -> GetBoundingRectangles. Chromium
        exposes an accessibility tree but enables it lazily, and attaching a UIA
        client makes the host app pay for it. Untested against Infloww.exe.
      * Computing it: the engine already knows the segment buffer, so caret x is
        textbox_left + text_width(buffer) once the box rect and font are
        measured. No accessibility API, but it breaks on word wrap and zoom.

    Both are real options and neither is a guess worth shipping blind. Implement
    `show`/`hide` here and set Render=ghost — nothing else in the service has to
    change, which is the point of this file.
    """

    def __init__(self, cfg: Config):
        raise NotImplementedError(
            "Render=ghost is not built yet. Use Render=strip, or Render=off to "
            "measure accuracy first. See src/services/autoword/README.md.")

    def show(self, candidates, active, context): ...
    def hide(self): ...
    def close(self): ...
    def pump(self): ...


RENDERERS = {"off": NullRenderer, "strip": StripRenderer, "ghost": GhostRenderer}


def build(cfg: Config) -> Renderer:
    try:
        factory = RENDERERS[cfg.render]
    except KeyError:
        factory = NullRenderer
    return factory(cfg)
