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
    def note_click(self) -> None: ...      # a click happened; where is up to it
    def owns_click(self) -> bool: ...      # was it on the renderer itself?
    col: int                                # chars before the word, on its line
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
        self.col = 0                         # Strip's placement hints; unused here

    def note_click(self) -> None:
        pass

    def owns_click(self) -> bool:
        return False

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
        # Follow = click. `col` is how many characters of the line come before
        # the word being typed — set by the service before each show. `_click`
        # is the last click, in the same (DPI-virtualised) coordinates as
        # GetWindowRect and this window's geometry.
        self.col = 0
        self._click: tuple[int, int] | None = None
        # The service sets this to its own log(). Follow = click explains, once
        # per click, why it fell back to the fixed spot.
        self.log = lambda message: None
        self._said = None

        # Draggable. Dropping it pins it there (Follow = window, the new
        # OffsetX/OffsetY written to the ini). `_rect` is where it is on screen,
        # kept as a plain tuple so the mouse hook's thread can ask "was that
        # click on the strip?" without touching tk.
        self._rect: tuple[int, int, int, int] | None = None
        self._grab: tuple[int, int] | None = None
        self._noactivate_done = False
        self.root.bind_all("<ButtonPress-1>", self._drag_start)
        self.root.bind_all("<B1-Motion>", self._drag_move)
        self.root.bind_all("<ButtonRelease-1>", self._drag_end)
        self.frame.configure(cursor="fleur")

    @staticmethod
    def _cursor() -> tuple[int, int] | None:
        """GetCursorPos rather than a hook's own x/y: hooks report physical
        pixels, and this process is not DPI aware, so on a scaled monitor those
        would not match GetWindowRect or where tk draws."""
        try:
            import ctypes
            from ctypes import wintypes
            pt = wintypes.POINT()
            if ctypes.windll.user32.GetCursorPos(ctypes.byref(pt)):
                return pt.x, pt.y
        except Exception:
            pass
        return None

    def note_click(self) -> None:
        """Called from the mouse hook: a click, somewhere other than the strip."""
        at = self._cursor()
        if at:
            self._click = at
            self._said = None

    def owns_click(self) -> bool:
        """Called from the mouse hook: is the pointer on the strip? A click
        there is a drag, not a caret move, so the buffer must survive it."""
        r, at = self._rect, self._cursor()
        if not (self._visible and r and at):
            return False
        x, y, w, h = r
        return x <= at[0] < x + w and y <= at[1] < y + h

    # -- dragging (main thread, tk events) ----------------------------------
    def _drag_start(self, event):
        self._grab = (event.x_root - self.root.winfo_x(),
                      event.y_root - self.root.winfo_y())

    def _drag_move(self, event):
        if not self._grab:
            return
        x, y = event.x_root - self._grab[0], event.y_root - self._grab[1]
        self.root.geometry(f"+{x}+{y}")
        self._remember_rect(x, y)

    def _drag_end(self, event):
        if not self._grab:
            return
        self._grab = None
        rect = self._foreground_rect()
        if not rect:
            return
        cfg = self.cfg
        cfg.strip_offset_x = self.root.winfo_x() - rect.left
        cfg.strip_offset_y = self.root.winfo_y() - rect.bottom
        cfg.strip_follow = "window"
        try:
            from config import save_keys
            save_keys("Strip", {"Follow": "window", "OffsetX": cfg.strip_offset_x,
                                "OffsetY": cfg.strip_offset_y})
            self.log(f"strip dragged: pinned at OffsetX={cfg.strip_offset_x} "
                     f"OffsetY={cfg.strip_offset_y} (Follow = window), saved")
        except Exception as exc:
            self.log(f"! strip dragged, but the ini could not be written: {exc}")

    def _remember_rect(self, x, y):
        self._rect = (x, y, self.root.winfo_reqwidth(), self.root.winfo_reqheight())

    def _noactivate(self):
        """WS_EX_NOACTIVATE: clicking (dragging) the strip must not take the
        focus off the message box you are typing in."""
        if self._noactivate_done:
            return
        try:
            import ctypes
            user32 = ctypes.windll.user32
            # Tk creates the outer window only when it is first mapped, so the
            # style has to wait for that — set on the inner one it does nothing.
            self.root.update_idletasks()
            hwnd = user32.GetParent(self.root.winfo_id())
            if not hwnd:
                return
            GWL_EXSTYLE, WS_EX_NOACTIVATE = -20, 0x08000000
            style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
            user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE)
            self._noactivate_done = True
        except Exception as exc:
            self.log(f"! strip: could not stop it taking focus ({exc})")

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

        if self._grab:
            return                          # mid-drag: new words, same spot
        x, y = self._anchor()
        self.root.geometry(f"+{x}+{y}")
        if not self._visible:
            self.root.deiconify()
            self.root.attributes("-topmost", True)
            self._noactivate()
            self._visible = True
        self.root.update_idletasks()
        self._remember_rect(x, y)

    def _hide(self):
        if self._visible:
            self.root.withdraw()
            self._visible = False

    def _follow(self, rect) -> tuple[int, int] | None:
        """Follow = click: over the word being typed, on the line last clicked.

        No caret API and no pixels — Infloww's internals are off limits, and
        this only has to be close. The click gives the line; the box's text
        starts at OffsetX; each character typed before the word moves it right
        by CharWidth. None when there is no usable click, so the caller falls
        back to the fixed spot.
        """
        cfg = self.cfg
        click = self._click
        if not click:
            self._why("no click yet")
            return None
        cx, cy = click
        left = rect.left + cfg.strip_offset_x
        # A click outside this window, or left of the message box (the fan list,
        # the sidebar), says nothing about where the line is.
        where = (f"click {cx},{cy}; window {rect.left},{rect.top}-{rect.right},"
                 f"{rect.bottom}; box text starts at x={left}")
        if not (rect.left <= cx < rect.right and rect.top <= cy < rect.bottom):
            self._why("the click was outside the window: " + where)
            return None
        if cx < left:
            self._why("the click was left of OffsetX: " + where)
            return None
        self.root.update_idletasks()
        w, h = self.root.winfo_reqwidth(), self.root.winfo_reqheight()
        x = left + int(self.col * cfg.strip_char_width)
        x = max(rect.left, min(x, rect.right - w))
        y = max(rect.top, cy - h - cfg.strip_gap)
        return x, y

    def _why(self, reason: str) -> None:
        if reason != self._said:
            self._said = reason
            self.log(f"strip: not following ({reason}); using the fixed spot")

    def _foreground_rect(self):
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            user32.GetForegroundWindow.restype = wintypes.HWND
            hwnd = user32.GetForegroundWindow()
            rect = wintypes.RECT()
            if hwnd and user32.GetWindowRect(hwnd, ctypes.byref(rect)):
                return rect
        except Exception:
            pass
        return None

    def _anchor(self) -> tuple[int, int]:
        """Bottom-left of the foreground window, plus the configured offset.

        Anchoring to the window rather than the caret is the whole reason this
        mode is the simple one: no accessibility API, no font metrics, nothing
        that breaks when the target app re-renders.
        """
        cfg = self.cfg
        rect = self._foreground_rect()
        if not rect:
            return 100, 100
        if cfg.strip_follow == "click":
            try:
                at = self._follow(rect)
            except Exception as exc:
                at = None
                self._why(f"it failed: {type(exc).__name__}: {exc}")
            if at:
                return at
        return rect.left + cfg.strip_offset_x, rect.bottom + cfg.strip_offset_y


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
