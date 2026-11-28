"""
ocr/ghost.pyw — Ghost-OCR mode: what MMA read, drawn next to each message, live.

Silly (2026-11-28): "a debug mode where a ghost of the message is shown somewhere
next to it so I can live compare them, side by side".

    __ghost                 (shortcuts.ini: tool:ghost) toggles it on / off
    pythonw ghost.pyw       the same
    python ghost.pyw --preview OUT.png [--any]
                            one read of an Infloww window drawn into a picture
                            (no overlay) — for checking placement

Each message gets a small card in the empty space beside it — LEFT of her bubbles,
RIGHT of his — never over a message:
    OCR  what the chat reader read (what MMA stores and the AI sees)
    NEW  what the Infloww reader (src/services/ocr) read, as a second opinion
Edge colour: green = they agree · yellow = nearly · red = they disagree ·
grey = a picture/video with no text.

Rules it keeps:
  * shown ONLY while an Infloww Messages window is in front; hidden otherwise
  * click-through and never takes focus (WS_EX_TRANSPARENT | NOACTIVATE)
  * hidden while the chat is moving; redrawn once it has held still, so a card
    never points at the wrong message
  * pixels only (PrintWindow) — nothing inside Infloww is touched
  * its title never contains "Infloww Messages" (MMA's readers match that title)
"""
from __future__ import annotations

import ctypes
import difflib
import queue
import re
import sys
import threading
import time
from ctypes import wintypes as wt
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "screenmap"))
sys.path.insert(0, str(HERE.parent / "llm"))
import reader as RD                                 # noqa: E402
import screenmap as SM                              # noqa: E402
import transcript as T                              # noqa: E402

# Speed: the old reader (Windows OCR) costs ~1s per message. A message that has
# only moved is the same pixels, so each text band is read once and remembered.
import hashlib                                      # noqa: E402
_band_cache: dict = {}
_read_band = T.read_band


def _cached_read_band(band, bg):
    k = hashlib.md5(band.tobytes() + str(band.shape).encode() + str(bg).encode()).digest()
    if k not in _band_cache:
        if len(_band_cache) > 5000:
            _band_cache.clear()
        _band_cache[k] = _read_band(band, bg)
    return _band_cache[k]


T.read_band = _cached_read_band
_line_cache: dict = {}

TITLE = "MMA Ghost OCR"
MUTEX = "Global\\MMA.ghost.mutex"
STOP = "Global\\MMA.ghost.stop"
POLL_S = 0.35
MOVED = 0.6               # pane thumb difference that means "the chat moved"
STILL_POLLS = 2
KEY = "#010203"           # the overlay's see-through colour
CARD_BG = "#11161c"
COLOURS = {"verified": "#2bd4ac", "close": "#e9b453", "disputed": "#ff6b6b",
           "media": "#6b7280", "pending": "#3b4250", "": "#6b7280"}

u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32


def _key(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def verdict(a: str, b: str) -> str:
    if not a and not b:
        return "media"
    ka, kb = _key(a), _key(b)
    if ka == kb:
        return "verified"
    if difflib.SequenceMatcher(None, ka, kb).ratio() >= 0.9:
        return "close"
    return "disputed"


def second_read(rgb: np.ndarray, box, who: str, scale: float) -> tuple[str, float]:
    """The Infloww reader on one bubble, line by line."""
    x0, y0, x1, y1 = box
    sub = rgb[y0:y1 + 1, x0:x1 + 1]
    bg = np.array(T.FAN_BG if who == "fan" else T.MODEL_BG, np.uint8)
    out, confs = [], []
    for by0, by1 in T.text_bands(sub):
        ix0, ix1 = T.ink_extent(sub[by0:by1])
        mid = y0 + (by0 + by1) / 2
        b0, b1 = RD._band(rgb, mid, scale)
        line = rgb[b0:b1, max(0, x0 + ix0 - round(6 * scale)):x0 + ix1 + round(8 * scale)].copy()
        t0, t1 = (y0 + by0 - round(2 * scale)) - b0, (y0 + by1 + round(2 * scale)) - b0
        if t0 > 0:
            line[:t0] = bg
        if 0 < t1 < line.shape[0]:
            line[t1:] = bg
        k = hashlib.md5(line.tobytes() + str(line.shape).encode()).digest()
        if k not in _line_cache:
            if len(_line_cache) > 5000:
                _line_cache.clear()
            _line_cache[k] = RD.read_line(line)
        r = _line_cache[k]
        out.append(r.text)
        confs.append(r.conf)
    return " ".join(o for o in out if o), (min(confs) if confs else 0.0)


def quick_window(rgb: np.ndarray, lay) -> dict:
    """Pass 1, under a second: find the messages (pure pixels) and run the NEW
    reader only. The old OCR's line says "…" until pass 2 fills it in."""
    region, k = lay.region, lay.scale
    rx, ry, rw, rh = region
    found = ([(b, "fan") for b in T.A.find_fan_bubbles(rgb, region, lay.fan_xmin, lay.fan_x0max)]
             + [(b, "model") for b in T.A.find_model_bubbles(rgb, region, lay.model_xmax)])
    found.sort(key=lambda p: p[0][1])
    cards = []
    for box, who in found:
        x0, y0, x1, y1 = box
        if (y0 - ry) <= T.CLIP_TOL * k or (ry + rh - 1 - y1) <= T.CLIP_TOL * k:
            continue                                  # half on screen
        new, conf = second_read(rgb, box, who, k)
        cards.append({"box": list(box), "who": who, "old": None, "new": new,
                      "conf": conf, "verdict": "pending"})
    return {"region": list(region), "scale": k, "cards": cards}


def read_window(rgb: np.ndarray) -> dict | None:
    """Everything the overlay draws for one frame (window-relative pixels)."""
    m = SM.measure(rgb)
    lay = SM.transcript_layout(m) if m.status == "ok" else None
    if lay is None:
        return None
    turns = T.read_turns(rgb, lay)
    cards = []
    for t in turns:
        if t.partial or t.cut:
            continue                                  # half on screen: nothing honest to show
        new, conf = second_read(rgb, t.box, t.who, lay.scale) if t.text else ("", 0.0)
        cards.append({"box": list(t.box), "who": t.who, "old": t.text, "new": new,
                      "conf": conf, "verdict": verdict(t.text, new)})
    return {"region": list(lay.region), "scale": lay.scale, "cards": cards}


# ------------------------------------------------------------------- layout --
CARD_W = 330              # CSS px
GAP = 10


def place(card: dict, region, scale: float) -> tuple[int, int, int] | None:
    """(x, y, width) of a card, in the empty space beside its message."""
    rx, ry, rw, rh = region
    x0, y0, x1, y1 = card["box"]
    gap = round(GAP * scale)
    if card["who"] == "model":                         # her bubble is on the right
        right = x0 - gap - round(40 * scale)           # clear of the kebab + translate icons
        w = min(round(CARD_W * scale), right - (rx + round(70 * scale)))
        x = right - w
    else:
        x = x1 + gap + round(70 * scale)               # clear of his hover icons
        w = min(round(CARD_W * scale), rx + rw - round(90 * scale) - x)
    if w < round(140 * scale):
        return None
    return x, y0, w


def shorten(s: str, n: int) -> str:
    s = s or ""
    return s if len(s) <= n else s[: n - 1] + "…"


# ------------------------------------------------------------------ preview --
def preview(out: str, any_window: bool) -> int:
    """One read drawn onto a capture — to check placement without an overlay."""
    from PIL import Image, ImageDraw, ImageFont
    SM_dpi()
    wins = T._matching_windows("Infloww Messages")
    for hwnd, title in wins:
        rgb = T._pinger.print_window(hwnd)
        if rgb is None:
            continue
        data = read_window(rgb)
        if not data:
            continue
        im = Image.fromarray(rgb)
        d = ImageDraw.Draw(im, "RGBA")
        s = data["scale"]
        try:
            f = ImageFont.truetype("segoeui.ttf", round(11 * s))
        except OSError:
            f = ImageFont.load_default()
        for c in data["cards"]:
            p = place(c, data["region"], s)
            if not p:
                continue
            x, y, w = p
            n = max(10, int(w / (6.2 * s)))
            lines = [("OCR  " + shorten(c["old"] or "[picture]", n), (230, 230, 230)),
                     ("NEW  " + shorten(c["new"] or "[picture]", n), (143, 180, 255))]
            hgt = round(2 * 16 * s + 8 * s)
            d.rectangle([x, y, x + w, y + hgt], fill=(17, 22, 28, 235),
                        outline=COLOURS[c["verdict"]], width=max(2, round(2 * s)))
            for i, (txt, col) in enumerate(lines):
                d.text((x + round(6 * s), y + round(4 * s) + i * round(16 * s)), txt, fill=col, font=f)
        im.save(out)
        from collections import Counter
        print(f"{len(data['cards'])} messages, {dict(Counter(c['verdict'] for c in data['cards']))} -> {out}")
        for c in data["cards"]:
            print(f"  [{c['verdict']:8}] OCR: {c['old'][:70]!r}\n             NEW: {c['new'][:70]!r}")
        return 0
    print("no Infloww Messages window with a chat open")
    return 1


def SM_dpi():
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        pass


# ------------------------------------------------------------------ overlay --
class Ghost:
    def __init__(self):
        import tkinter as tk
        self.tk = tk
        self.root = tk.Tk()
        self.root.title(TITLE)
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=KEY)
        self.root.attributes("-transparentcolor", KEY)
        self.cv = tk.Canvas(self.root, bg=KEY, highlightthickness=0, bd=0)
        self.cv.pack(fill="both", expand=True)
        self.root.update_idletasks()
        hwnd = int(self.root.wm_frame(), 16)
        GWL_EXSTYLE = -20
        ex = u32.GetWindowLongW(hwnd, GWL_EXSTYLE)
        # layered + click-through + no taskbar button + never activates
        u32.SetWindowLongW(hwnd, GWL_EXSTYLE, ex | 0x80000 | 0x20 | 0x80 | 0x08000000)
        self.root.withdraw()
        self.q: queue.Queue = queue.Queue()
        self.stop = threading.Event()
        self.shown = False
        threading.Thread(target=self.work, daemon=True).start()
        self.root.after(100, self.pump)

    # worker: decides WHAT to show
    def work(self):
        prev, still, last_key = None, 0, None
        while not self.stop.is_set():
            time.sleep(POLL_S)
            try:
                fg = u32.GetForegroundWindow()
                buf = ctypes.create_unicode_buffer(256)
                u32.GetWindowTextW(fg, buf, 256)
                if not buf.value.startswith("Infloww Messages"):
                    self.q.put(("hide", None))
                    prev, still, last_key = None, 0, None
                    continue
                rgb = T._pinger.print_window(fg)
                if rgb is None:
                    self.q.put(("hide", None))
                    continue
                m = SM.measure(rgb)
                lay = SM.transcript_layout(m) if m.status == "ok" else None
                if lay is None:
                    self.q.put(("hide", None))
                    prev = None
                    continue
                th = T.pane_thumb(rgb, lay)
                if prev is not None and T.thumb_diff(prev, th) > MOVED:
                    still = 0
                    self.q.put(("hide", None))           # moving: never point at the wrong message
                else:
                    still += 1
                prev = th
                if still < STILL_POLLS:
                    continue
                key = th.tobytes()
                r = wt.RECT()
                u32.GetWindowRect(fg, ctypes.byref(r))
                rect = (r.left, r.top, r.right - r.left, r.bottom - r.top)
                if key != last_key:
                    self.q.put(("reading", rect + ({"region": list(lay.region), "scale": lay.scale},)))
                    self.data = quick_window(rgb, lay)          # NEW reader: shown at once
                    self.q.put(("show", rect + (self.data, self._hover(rect, self.data))))
                    data = read_window(rgb)                     # then the old OCR fills in
                    last_key = key
                    self.data = data
                self.q.put(("show", rect + (self.data, self._hover(rect, self.data))))
            except Exception as e:                       # never die on one bad frame
                self.q.put(("hide", None))
                time.sleep(1)

    def _hover(self, rect, data):
        """Index of the card whose message (or card) the mouse is over, else None."""
        if not data:
            return None
        pt = wt.POINT()
        u32.GetCursorPos(ctypes.byref(pt))
        mx, my = pt.x - rect[0], pt.y - rect[1]
        s = data["scale"]
        for i, c in enumerate(data["cards"]):
            x0, y0, x1, y1 = c["box"]
            if x0 <= mx <= x1 and y0 <= my <= y1:
                return i
            p = place(c, data["region"], s)
            if p and p[0] <= mx <= p[0] + p[2] and p[1] <= my <= p[1] + round(40 * s):
                return i
        return None

    # UI thread: draws it
    def pump(self):
        if self.stop.is_set():
            self.root.destroy()
            return
        latest = None
        try:
            while True:
                latest = self.q.get_nowait()
        except queue.Empty:
            pass
        if latest:
            kind, val = latest
            if kind == "hide":
                if self.shown:
                    self.root.withdraw()
                    self.shown = False
            elif kind == "reading":
                self.draw_badge(*val)
            elif val[4]:
                self.draw(*val)
        self.root.after(120, self.pump)

    def draw_badge(self, wx, wy, ww, wh, data, text="GHOST OCR · reading…"):
        self.root.geometry(f"{ww}x{wh}+{wx}+{wy}")
        self.cv.delete("all")
        self._badge(data, text)
        if not self.shown:
            self.root.deiconify()
            self.shown = True

    def _badge(self, data, text):
        s = data["scale"]
        font = ("Segoe UI", max(7, round(8.5 * s / 1.37)))
        rx, ry, rw, rh = data["region"]
        bx, by = rx + rw - round(380 * s), ry + round(6 * s)
        self.cv.create_rectangle(bx, by, bx + round(370 * s), by + round(20 * s), fill=CARD_BG, outline="#3b4250")
        self.cv.create_text(bx + round(6 * s), by + round(3 * s), anchor="nw", fill="#c9d1d9", font=font, text=text)

    def draw(self, wx, wy, ww, wh, data, hover=None):
        self.root.geometry(f"{ww}x{wh}+{wx}+{wy}")
        cv = self.cv
        cv.delete("all")
        s = data["scale"]
        font = ("Segoe UI", max(7, round(8.5 * s / 1.37 * 1.0)))
        counts = {}
        pending = any(c["verdict"] == "pending" for c in data["cards"])
        for i, c in enumerate(data["cards"]):
            counts[c["verdict"]] = counts.get(c["verdict"], 0) + 1
            p = place(c, data["region"], s)
            if not p or i == hover:
                continue
            x, y, w = p
            n = max(10, int(w / (6.4 * s)))
            hgt = round(40 * s)
            cv.create_rectangle(x, y, x + w, y + hgt, fill=CARD_BG,
                                outline=COLOURS[c["verdict"]], width=max(2, round(2 * s)))
            cv.create_text(x + round(6 * s), y + round(5 * s), anchor="nw", fill="#e6e6e6", font=font,
                           text="OCR  " + ("…" if c["old"] is None else shorten(c["old"] or "[picture]", n)))
            cv.create_text(x + round(6 * s), y + round(21 * s), anchor="nw", fill="#8fb4ff", font=font,
                           text="NEW  " + shorten(c["new"] or "[picture]", n))
        if hover is not None and hover < len(data["cards"]):
            self._full(data["cards"][hover], data, font)   # last: on top of everything
        badge = (f"GHOST OCR · {len(data['cards'])} msgs · NEW shown, old OCR reading…" if pending else
                 f"GHOST OCR · {len(data['cards'])} msgs · "
                 f"{counts.get('verified', 0)} agree · {counts.get('close', 0)} nearly · "
                 f"{counts.get('disputed', 0)} differ")
        self._badge(data, badge)
        if not self.shown:
            self.root.deiconify()
            self.shown = True
        self.root.attributes("-topmost", True)

    def _full(self, c, data, font):
        """The hovered message: both readings in full, wrapped, grown downwards."""
        s = data["scale"]
        p = place(c, data["region"], s)
        if not p:                                  # no room beside it: show over the pane's middle
            rx, ry, rw, rh = data["region"]
            p = (rx + rw // 2 - round(200 * s), c["box"][1], round(400 * s))
        x, y, w = p
        w = max(w, round(360 * s))
        pad = round(6 * s)
        cv = self.cv
        t1 = cv.create_text(x + pad, y + pad, anchor="nw", fill="#e6e6e6", font=font, width=w - 2 * pad,
                            text="OCR  " + ("reading…" if c["old"] is None else (c["old"] or "[picture]")))
        y2 = cv.bbox(t1)[3] + pad
        t2 = cv.create_text(x + pad, y2, anchor="nw", fill="#8fb4ff", font=font, width=w - 2 * pad,
                            text="NEW  " + (c["new"] or "[picture]"))
        y3 = cv.bbox(t2)[3] + pad
        t3 = cv.create_text(x + pad, y3, anchor="nw", fill=COLOURS[c["verdict"]], font=font,
                            text=f"{c['verdict']} · sure {c['conf']:.0%}")
        bot = cv.bbox(t3)[3] + pad
        r = cv.create_rectangle(x, y, x + w, bot, fill=CARD_BG,
                                outline=COLOURS[c["verdict"]], width=max(2, round(3 * s)))
        cv.tag_lower(r, t1)

    def run(self):
        ev = k32.CreateEventW(None, True, False, STOP)

        def wait():
            k32.WaitForSingleObject(ev, 0xFFFFFFFF)
            self.stop.set()
        threading.Thread(target=wait, daemon=True).start()
        self.root.mainloop()


def main() -> int:
    if "--preview" in sys.argv:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        return preview(sys.argv[sys.argv.index("--preview") + 1], "--any" in sys.argv)
    SM_dpi()
    mutex = k32.CreateMutexW(None, True, MUTEX)
    if k32.GetLastError() == 183:                      # already on: this start turns it OFF
        h = k32.OpenEventW(0x0002, False, STOP)
        if h:
            k32.SetEvent(h)
            k32.CloseHandle(h)
        return 0
    Ghost().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
