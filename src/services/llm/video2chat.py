"""
llm/video2chat.py — turn a screen recording of Infloww into shift-log chats.

The live shift recorder (chatreader.pyw -> shiftlog.py) reads the Infloww
window as you work. This does the same to a VIDEO of it: OBS recordings, a
Discord screen share someone recorded (full screen or windowed), anything
where Infloww's three columns are visible. The output is the same raw reads and per-fan chat files, so the
Shift Viewer shows them with everything else.

How, and why that way:

  • EVERY FRAME IS LOCATED. A recorded Discord stream is not always
    Infloww (the text channel, a webcam grid, a posted screenshot) and not
    always full size (windowed beside Discord's sidebar: ~0.7x). Infloww is
    found by its own geometry: two long divider lines, the header line
    between them, the composer line a fixed 166px above the window's bottom,
    the window's left edge 400px left of the first divider (which gives the
    scale), and its exact background (grey 20) under both columns. Frames
    without that rectangle are never read. Once found, each frame is only
    checked against it (cheap); a NEW rectangle must show in 2 samples in a
    row before it is trusted. In video the 1px #444444 lines come out ~#2c2c2c
    and 1-2px wide, so they are found by CONTRAST, not colour. Bubble colours
    survive (#353535 stays 53), so the bubble finders work unchanged.
  • READ AT ONE SIZE. Infloww is cut out and enlarged so its text is always
    ~1.41x (full-screen 0.94 x 1.5, windowed 0.70 x 2). Below MIN_SCALE it is
    too small to read and is only flagged on the timeline.
  • A RETURN IS A FRESH OPEN. After Discord (or a moved window) the first read
    is marked `resumed`: what happened in between was never on screen, so a
    read that does not line up goes below the chat after a gap marker.
  • A POP-UP OVER THE COMPOSER (a scripts panel) draws its own line higher
    up; when one is there, the message pane is cut above it per frame.
  • THE SAME SETTLE RULE AS LIVE: the chat, header and fan panel must all
    hold still for SETTLE frames before a read, and everything is read from
    that one frame — a fan switch updates the three at different moments.
  • TIME: a read is stamped with the video's start time + its offset. The
    start is parsed from an OBS-style name ("2026-04-03 00-52-29.mp4") or
    taken as the file's modified time minus its length. The messages' own
    footer times are read as well, so nothing depends on this being exact.

    python video2chat.py VIDEO [--account NAME] [--every 0.5] [--from MIN] [--to MIN]
    python video2chat.py VIDEO --probe        the first read, nothing saved
    python video2chat.py VIDEO --scan         only where Infloww is (no OCR, ~1 min per 17)

Raw reads go to userdata/shiftlog/reads/<date>.video-<name>.jsonl. Running the
same video again replaces that file (and rebuilds the chats from scratch). The
timeline of what was and was not Infloww goes next to it (.timeline.txt).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import shiftlog                                   # noqa: E402
import transcript as T                            # noqa: E402

EVERY_S = 0.5            # sample a frame this often (seconds of video)
SETTLE = 2               # samples in a row with nothing moving before a read
CHANGED = 0.6            # thumb difference that counts as "changed" (as live)
LINE_CONTRAST = 3        # a divider is at least this much brighter than its neighbours
# Frames are enlarged before reading. A 1080p capture's text is ~13px and
# compressed; at that size the OCR drops the spaces ("ialsousedmyvoice") and
# loses the header name. Live text is ~1.4x bigger and reads clean.
# Full-screen 1080p was read at 1.5x (Infloww at 0.94 -> 1.41). A windowed
# stream is smaller, so the enlargement is whatever brings it to that same
# size: 0.70 -> 2x. Capped, since 2x of a full frame was worse (PP-OCRv5
# shrinks very large crops back down) and nothing below MIN_SCALE is read.
# The header name is kept only where it is near-white (the edit pencil after it is
# #9a9a9a). Compression darkens thin white strokes: 200 lost "Admiral Skorpion",
# 140 reads it.
NAME_INK = 140


# ── lines ────────────────────────────────────────────────────────────────────
def _hlines(g: np.ndarray, x0: int, x1: int) -> np.ndarray:
    """Per row: the share of the pane's width where it is a 1px bright line."""
    sp = g[:, x0 + 10:x1 - 10]
    d = np.minimum(sp[1:-1] - sp[:-2], sp[1:-1] - sp[2:])
    return np.r_[0, (d >= LINE_CONTRAST).mean(1), 0]


# ── where Infloww is, frame by frame ─────────────────────────────────────────
# A recorded Discord stream is not always Infloww, and not always full size:
# the text channel, a grid of webcams, an image someone posted, or the stream
# windowed with Discord's sidebar beside it (Infloww at ~0.7x). So every frame
# is LOCATED first: the two column dividers (long vertical lines, 1-2px once
# scaled), the conversation header line between them, the composer line under
# them, and the window's left edge for the scale (the list column is 400px at
# 100%). No such rectangle = not Infloww, and the frame is never read.
MIN_RUN = 0.18           # a divider is at least this share of the frame's height
RUN_GAP = 40             # rows a divider may break for (a pop-up, a highlighted row)...
RUN_DENSE = 0.55         # ...as long as it is a line on this share of its rows
BG = (14, 28)            # Infloww's list and pane background: grey 20 (#141414) in every
                         # recording, full or windowed; Discord's sidebar/channel is 40+
MIN_SCALE = 0.5          # below this the text is too small to read: flagged, skipped
                         # (real 0.71 Discord stream reads clean; shrunk tests fall apart <0.5)
H_SHARE = 0.3            # a scaled-down 1px line survives on ~30% of its width
COMPOSER = 166          # composer line -> window bottom, CSS px (measured: 157px at 0.94)
TARGET = 1.41            # effective scale to read at (0.94 full-screen x 1.5 upscale)


class Box:
    """Infloww's rectangle in one frame. scale = CSS px -> frame px."""
    __slots__ = ("x0", "xl", "xr", "x1", "top", "y0", "y1", "bottom", "scale")

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    def same(self, o: "Box | None") -> bool:
        return (o is not None and abs(self.xl - o.xl) <= 4 and abs(self.xr - o.xr) <= 4
                and abs(self.y0 - o.y0) <= 4 and abs(self.y1 - o.y1) <= 8
                and abs(self.scale / o.scale - 1) <= .06)

    def same_window(self, o: "Box | None") -> bool:
        """The same window, maybe part-covered (see Tracker): same dividers, same scale."""
        return (o is not None and abs(self.xl - o.xl) <= 4 and abs(self.xr - o.xr) <= 4
                and abs(self.scale / o.scale - 1) <= .06)

    def layout(self) -> T.Layout:
        return T.Layout(region=(self.xl, self.y0 + 2, self.xr - self.xl, self.y1 - self.y0 - 2),
                        scale=self.scale)

    def __repr__(self):
        return (f"Box(x {self.x0}|{self.xl}..{self.xr}|{self.x1}, y {self.top}|{self.y0}..{self.y1}|"
                f"{self.bottom}, scale {self.scale:.2f})")


def _line_map(g: np.ndarray, axis: int) -> np.ndarray:
    """Pixels on a thin bright line across `axis` (1 = vertical lines). Takes a
    1px line and one blurred over 2px."""
    a = np.moveaxis(g, axis, 0)
    out = np.zeros(a.shape, bool)
    one = np.minimum(a[1:-1] - a[:-2], a[1:-1] - a[2:])
    two = np.minimum(a[2:-2] - a[:-4], a[2:-2] - a[4:])
    out[1:-1] = one >= LINE_CONTRAST
    out[2:-2] |= two >= LINE_CONTRAST
    return np.moveaxis(out, 0, axis)


def _longest_run(col: np.ndarray) -> tuple[int, int]:
    """The longest stretch of a column that is a line, bridging gaps up to
    RUN_GAP while it stays a line on RUN_DENSE of its rows. Text never is:
    its strokes line up for a few rows at a time."""
    idx = np.flatnonzero(col)
    if not len(idx):
        return 0, 0
    br = np.flatnonzero(np.diff(idx) > RUN_GAP)
    starts, ends = np.r_[0, br + 1], np.r_[br, len(idx) - 1]
    best = (0, 0)
    for a, b in zip(starts, ends):
        lo, hi = int(idx[a]), int(idx[b])
        if hi - lo > best[1] - best[0] and (b - a + 1) >= RUN_DENSE * (hi - lo + 1):
            best = (lo, hi)
    return best


def _columns(vm: np.ndarray, H: int) -> list[tuple[int, int, int]]:
    """Long vertical lines: [(x, top, bottom)], one per cluster of columns."""
    cand = np.flatnonzero(vm.sum(0) >= MIN_RUN * H * RUN_DENSE)
    found = []
    for x in cand:
        a, b = _longest_run(vm[:, x])
        if b - a >= MIN_RUN * H:
            found.append((int(x), a, b))
    out = []                                     # keep the longest of each cluster
    for c in found:
        if out and c[0] - out[-1][0] <= 3:
            if c[2] - c[1] > out[-1][2] - out[-1][1]:
                out[-1] = c
        else:
            out.append(c)
    return out


def _hrows(hm: np.ndarray, x0: int, x1: int, y0: int, y1: int, share: float = .5) -> np.ndarray:
    """Rows in [y0, y1) that are a line across most of x0..x1, strongest first."""
    y0, y1 = max(0, y0), min(hm.shape[0], y1)
    if x1 - x0 < 40 or y1 <= y0:
        return np.array([], int)
    s = hm[y0:y1, x0 + 8:x1 - 8].mean(1)
    rows = np.flatnonzero(s >= share)
    return rows[np.argsort(-s[rows], kind="stable")] + y0


def _header_line(hm: np.ndarray, x0: int, x1: int, y0: int, y1: int) -> int | None:
    """The line under the conversation header: of the lines in the header band
    nearly as strong as the strongest, the LOWEST. The tab strip's line above
    the header is as strong (taking the strongest picked either), and a faint
    bubble edge lower down is not strong enough to count."""
    y0, y1 = max(0, y0), min(hm.shape[0], y1)
    if x1 - x0 < 40 or y1 <= y0:
        return None
    s = hm[y0:y1, x0 + 8:x1 - 8].mean(1)
    if s.max() < H_SHARE:
        return None
    return y0 + int(np.flatnonzero(s >= max(H_SHARE, .7 * s.max()))[-1])


def _left_edge(g: np.ndarray, xl: int, y0: int, bottom: int) -> int:
    """The window's left edge: a vertical step down the whole list column, the
    one nearest the list. A full-screen capture has none: the frame's edge is it."""
    rows = slice(y0, max(y0 + 1, bottom))
    lo, hi = max(1, xl - int(400 * 1.7)), xl - int(400 * .3)
    if hi <= lo:
        return 0
    e = (np.abs(g[rows, lo + 1:hi + 1] - g[rows, lo - 1:hi - 1]) >= 8).mean(0)
    if not len(e) or e.max() < .7:
        return 0
    return lo + int(np.flatnonzero(e >= e.max() - .02)[-1])


def _box(g: np.ndarray, hm: np.ndarray, a: tuple, b: tuple, cols: list) -> Box | None:
    """The Infloww window these two lines would be its dividers of, if any."""
    H, W = g.shape
    (xl, ta, ba), (xr, tb, bb) = a, b
    if xr - xl < W * .15 or min(ba, bb) - max(ta, tb) < MIN_RUN * H * .8:
        return None
    top, bottom = min(ta, tb), max(ba, bb)
    span = bottom - top
    y0 = _header_line(hm, xl, xr, top - 20, top + int(span * .3))
    if y0 is None:
        return None
    # The message pane has no full-height line of its own: a pair with one
    # between them is Discord's sidebar edge and Infloww's real divider.
    for c, ct, cb in cols:
        if xl + 10 < c < xr - 10 and min(cb, bottom) - max(ct, top) > .6 * span:
            return None
    x0 = _left_edge(g, xl, y0, bottom)
    scale = (xl - x0) / 400
    if not .3 <= scale <= 1.7:
        return None
    # The composer is a fixed ~166px tall: its top line sits that far above the
    # window's bottom. Nothing else (a Discord channel, a webcam grid) has both.
    want = bottom - COMPOSER * scale
    low = _hrows(hm, xl, xr, int(want - 28 * scale), int(want + 28 * scale) + 1, H_SHARE)
    if not len(low):
        return None
    y1 = int(low[np.argmin(np.abs(low - want))])
    x1 = xr + int(round(281 * scale))
    if x1 > W + 12 or y1 - y0 < span * .45:
        return None                              # the right panel would not fit
    # Infloww's own background, under both columns. Discord's is not it.
    for part in (g[y0 + 3:y1 - 2, xl + 2:xr - 1], g[y0 + 3:y1 - 2, x0 + 2:xl - 1]):
        if not part.size or not BG[0] <= np.median(part) <= BG[1]:
            return None
    return Box(x0=x0, xl=xl, xr=xr, x1=min(W, x1), top=top, y0=y0, y1=y1, bottom=bottom, scale=scale)


def locate(frame_rgb: np.ndarray) -> Box | None:
    """Infloww's rectangle in this frame, or None when it is not there."""
    g = frame_rgb.astype(np.float32).mean(2)
    H, _W = g.shape
    cols = _columns(_line_map(g, 1), H)
    if len(cols) < 2:
        return None
    hm = _line_map(g, 0)
    boxes = [bx for i, a in enumerate(cols) for b in cols[i + 1:] if (bx := _box(g, hm, a, b, cols))]
    # The window's own border is a bright line too. A line that is another
    # box's left EDGE is not a divider.
    edges = [bx.x0 for bx in boxes if bx.x0 > 0]
    boxes = [bx for bx in boxes if not any(abs(bx.xl - e) <= 4 for e in edges)]
    return max(boxes, key=lambda bx: (bx.y1 - bx.y0) + (bx.xr - bx.xl), default=None)


def frame_layout(rgb: np.ndarray, base: T.Layout) -> T.Layout:
    """The base layout, with the pane cut above a pop-up if one is open."""
    x, y, w, h = base.region
    g = rgb[y:y + h].astype(np.float32).mean(2)
    hl = _hlines(np.vstack([g[:1], g, g[-1:]]), x, x + w)[1:-1]
    cut = [r for r in np.where(hl >= .8)[0] if r > 150 * base.scale and r < h - 5]
    if cut:
        return T.Layout(region=(x, y, w, int(cut[0]) - 2), scale=base.scale)
    return base


# ── following Infloww through a video ─────────────────────────────────────
CONFIRM = 2              # samples a NEW rectangle must show up in before it is trusted
AWAY = 4                 # samples without Infloww that end a stretch (2s at 0.5s)
MOVED = 6                # samples a same-place window with new top/bottom needs (3s)


def still_there(g: np.ndarray, box: Box) -> bool:
    """Cheap: is this frame the same Infloww window? Its background under both
    columns and its left divider, at the known place. Everything that covers
    them (Discord, a modal, a fade) fails, and the frame is located afresh."""
    rows = slice(box.y0 + 5, box.y1 - 5, 3)
    for part in (g[rows, box.xl + 3:box.xr - 2:4], g[rows, box.x0 + 3:box.xl - 2:4]):
        if not part.size or not BG[0] <= np.median(part) <= BG[1]:
            return False
    strip = g[box.y0 + 5:box.y1 - 5, max(0, box.xl - 4):box.xl + 5]
    line = _line_map(strip, 1)[:, 2:7].any(1)
    return line.mean() >= .5


class Tracker:
    """Where Infloww is, sample by sample. see() -> (box or None, resumed):
    `resumed` is True on the first sample of a new stretch, a new window
    position or a return after AWAY, since whatever happened in between was
    never on screen."""

    def __init__(self):
        self.box = self.pending = None
        self.pend_n = self.away = self.moved = 0
        self.started = False

    def see(self, frame_rgb: np.ndarray) -> tuple[Box | None, bool]:
        g = frame_rgb.astype(np.float32).mean(2)
        if self.box is not None and still_there(g, self.box):
            return self._back(self.box)
        b = locate(frame_rgb)
        if b is not None and b.same(self.box):
            return self._back(self.box)
        # Same dividers and scale, different top or bottom: the same window with
        # part of it covered. Discord shades the stream's bottom (and draws its
        # call controls there) while the mouse is over it, a pop-up hides the
        # header line; both cut lines short, and covering only ever SHRINKS the
        # box. So: inside the known box = covered, skip the frame; containing
        # it = the known box was the covered one, take the bigger. Anything else
        # (the window really moved) must hold for MOVED samples to be believed.
        if b is not None and b.same_window(self.box):
            bx = self.box
            if b.y0 >= bx.y0 - 4 and b.y1 <= bx.y1 + 6:
                self.away += 1
                return None, False
            if b.y0 <= bx.y0 + 4 and b.y1 >= bx.y1 - 6:
                self.box = b
                return self._back(b)
            self.moved = self.moved + 1 if b.same(self.pending) else 1
            self.pending = b
            if self.moved < MOVED:
                self.away += 1
                return None, False
            self.box, self.pending, self.moved = b, None, 0
            return self._back(b)
        self.away += 1
        if b is None:
            self.pend_n, self.pending = 0, None
            return None, False
        if b.same(self.pending):
            self.pend_n += 1
        else:
            self.pending, self.pend_n = b, 1
        if self.pend_n < CONFIRM:
            return None, False
        self.box, self.pending, self.pend_n = self.pending, None, 0
        self.away, self.started = 0, True
        return self.box, True

    def _back(self, box: Box) -> tuple[Box, bool]:
        resumed = self.away >= AWAY or not self.started
        self.away, self.started = 0, True
        return box, resumed


def read_view(frame_bgr: np.ndarray, box: Box, upscale: float = 0) -> tuple[np.ndarray, T.Layout]:
    """Infloww cut out of the frame and enlarged to the size it reads best at,
    with its layout (pane cut above a pop-up). Lines are measured on the
    native pixels: enlarging smears them."""
    import cv2
    H, W = frame_bgr.shape[:2]
    cx, cy = box.x0, max(0, int(box.y0 - 150 * box.scale))
    crop = np.ascontiguousarray(frame_bgr[cy:min(H, box.bottom + 3), cx:box.x1, ::-1])
    lay = box.layout()
    x, y, w, h = lay.region
    lay = frame_layout(crop, T.Layout(region=(x - cx, y - cy, w, h), scale=box.scale))
    k = upscale or min(3.0, max(1.0, TARGET / box.scale))
    if k != 1:
        crop = cv2.resize(crop, None, fx=k, fy=k, interpolation=cv2.INTER_CUBIC)
    x, y, w, h = lay.region
    return crop, T.Layout(region=(round(x * k), round(y * k), round(w * k), round(h * k)),
                          scale=box.scale * k)


class Timeline:
    """What each stretch of the video was: Infloww (at what size), Infloww
    too small to read, or something else."""

    def __init__(self):
        self.parts: list[list] = []              # [kind, start s, end s, scale]

    def add(self, t: float, box: Box | None) -> str:
        kind = "other" if box is None else ("small" if box.scale < MIN_SCALE else "infloww")
        sc = box.scale if box else 0
        last = self.parts[-1] if self.parts else None
        if last and last[0] == kind and (kind == "other" or abs(last[3] - sc) < .03):
            last[2] = t
        else:
            self.parts.append([kind, t, t, sc])
        return kind

    def report(self, min_s: float = 5) -> str:
        label = {"infloww": "Infloww", "small": "Infloww, too small to read", "other": "not Infloww"}
        tot = {}
        out = []
        for kind, a, b, sc in self.parts:
            tot[kind] = tot.get(kind, 0) + (b - a)
            if b - a >= min_s:
                size = f" at {sc:.2f}x" if kind != "other" else ""
                out.append(f"  {_hms(a)} – {_hms(b)}  {label[kind]}{size}")
        out.append("  total: " + ", ".join(f"{label[k]} {v / 60:.1f} min" for k, v in tot.items()))
        return "\n".join(out)


def _hms(t: float) -> str:
    t = int(t)
    return f"{t // 3600}:{t // 60 % 60:02d}:{t % 60:02d}"


# ── time ─────────────────────────────────────────────────────────────────────
_OBS_NAME = re.compile(r"(\d{4})-(\d{2})-(\d{2})[ _](\d{2})-(\d{2})-(\d{2})")


def video_start(path: Path, duration_s: float) -> float:
    m = _OBS_NAME.search(path.stem)
    if m:
        return time.mktime(tuple(int(x) for x in m.groups()) + (0, 0, -1))
    return os.path.getmtime(path) - duration_s


# ── the run ──────────────────────────────────────────────────────────────────
def open_video(path: Path):
    import cv2
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    return cap, fps, n


# ── OCR engine ───────────────────────────────────────────────────────────────
# The live reader keeps RapidOCR 1.x (PP-OCRv3): on clean live captures the
# 2026-10-21 bake-off was a draw. On VIDEO it is not: compressed 1080p text came
# back as "ialsousedmyvoice..." and the header name as nothing, where PP-OCRv5's
# English model read both cleanly (2026-10-22). So this tool swaps v5 in, through
# the one door every reader uses (automation.ocr_engine), in this process only.
def use_v5() -> bool:
    try:
        from rapidocr import RapidOCR, OCRVersion, ModelType, LangRec
    except ImportError:
        print("! rapidocr 3 is not installed; reading with the live engine "
              "(pip install --no-deps rapidocr colorlog omegaconf)")
        return False
    v5 = OCRVersion("PP-OCRv5")
    eng = RapidOCR(params={"Global.log_level": "error",
                           "Det.ocr_version": v5, "Rec.ocr_version": v5,
                           "Det.model_type": ModelType("mobile"), "Rec.model_type": ModelType("mobile"),
                           "Rec.lang_type": LangRec("en")})

    def legacy(img):
        """RapidOCR 1.x's shape: ([[points, text, score], ...], elapsed)."""
        r = eng(np.ascontiguousarray(img))
        if r.boxes is None or r.txts is None:
            return None, 0
        return [[b.tolist(), t, s] for b, t, s in zip(r.boxes, r.txts, r.scores)], 0

    T.A._OCR["eng"] = legacy
    return True


def _frames(cap, fps: float, first: int, last: int, every: float):
    """(frame index, BGR frame) every `every` seconds: decoding is the cost,
    so the frames in between are only grabbed."""
    step = max(1, round(fps * every))
    i = first
    while i < last:
        if (i - first) % step:
            if not cap.grab():
                return
            i += 1
            continue
        ok, f = cap.read()
        i += 1
        if not ok:
            return
        yield i, f


def scan(path: Path, every: float, t_from: float, t_to: float | None) -> Timeline:
    """Only find where Infloww is: no OCR, so a whole video takes minutes."""
    import cv2
    cap, fps, n = open_video(path)
    first, last = int(t_from * 60 * fps), int(min(n, (t_to * 60 * fps) if t_to else n))
    cap.set(cv2.CAP_PROP_POS_FRAMES, first)
    tr, tl = Tracker(), Timeline()
    for i, f in _frames(cap, fps, first, last, every):
        box, _r = tr.see(np.ascontiguousarray(f[:, :, ::-1]))
        tl.add(i / fps, box)
    cap.release()
    return tl


def run(path: Path, account: str, every: float, t_from: float, t_to: float | None,
        probe: bool = False, upscale: float = 0) -> None:
    import cv2
    engine = "PP-OCRv5 en" if use_v5() else "PP-OCRv3 (live engine)"
    T.NAME_INK = NAME_INK
    cap, fps, n = open_video(path)
    duration = n / fps
    start = video_start(path, duration)
    print(f"{path.name}: {duration / 60:.1f} min at {fps:.0f} fps, starts "
          f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(start))}  ({engine})")

    first = int(t_from * 60 * fps)
    last = int(min(n, (t_to * 60 * fps) if t_to else n))
    cap.set(cv2.CAP_PROP_POS_FRAMES, first)

    # The creator label at the top-left is NOT dependable from video (the same
    # strip showed a fan's name in another frame), so the default is the file's
    # name; pass --account for the real one.
    account = account or path.stem
    title = f"Infloww Messages - {account}"      # shiftlog files by the title's account
    print(f"account: {account}")

    day = time.strftime("%Y-%m-%d", time.localtime(start))
    reads_file = shiftlog.READS / f"{day}.video-{shiftlog.slug(path.stem)}.jsonl"
    if not probe:
        shiftlog.READS.mkdir(parents=True, exist_ok=True)
        if reads_file.exists():
            reads_file.unlink()                  # a rerun replaces, never doubles

    tracker, timeline = Tracker(), Timeline()
    prev = last_pane = last_head = last_panel = None
    still, fan, panel_fan, resumed, box_now = 0, None, None, False, None
    reads = panels = skipped = 0
    t0 = time.time()
    for i, f in _frames(cap, fps, first, last, every):
        box, back = tracker.see(np.ascontiguousarray(f[:, :, ::-1]))
        kind = timeline.add(i / fps, box)
        if kind != "infloww":
            prev, still = None, 0                # Discord, a modal, too small: not read
            continue
        if back or box is not box_now:
            # A new stretch: nothing seen in between, so the settle rule starts
            # over and the next read counts as opening the chat fresh.
            box_now, prev, still, last_pane, last_head, last_panel = box, None, 0, None, None, None
            resumed = True
            print(f"  {_hms(i / fps)}  Infloww {box!r}", flush=True)
        rgb, lay = read_view(f, box, upscale)
        cur = (T.pane_thumb(rgb, lay), T.panel_thumb(rgb, lay), T.header_thumb(rgb, lay))
        moving = prev is None or any(T.thumb_diff(a, b) > CHANGED for a, b in zip(cur, prev))
        still = 0 if moving else still + 1
        prev = cur
        if still < SETTLE:
            continue
        at = start + i / fps
        if T.thumb_diff(cur[0], last_pane) > CHANGED or T.thumb_diff(cur[2], last_head) > CHANGED:
            last_pane, last_head = cur[0], cur[2]
            turns = T.read_turns(rgb, lay, footers=True)
            fan = T.read_fan_name(rgb, lay)
            state = {"read_at": at, "title": title, "fan": fan, "resumed": resumed,
                     "turns": [t.to_dict() for t in turns]}
            # No name in the header = no conversation open (the chat LIST, a
            # pop-up): from video those reads were all junk, so skip them.
            # A "name" with fewer than 2 letters ("1 1") is the header half-covered.
            if len(re.findall(r"[A-Za-z]", fan or "")) < 2 and not probe:
                skipped += 1
                continue
            if probe:
                print(f"\n[probe] {time.strftime('%H:%M:%S', time.localtime(at))} fan={fan!r} "
                      f"read at {lay.scale:.2f}x")
                for t in turns:
                    print(f"  {t.who:>5} {t.text[:70]!r} {t.time} {t.sender} "
                          f"{'$' + t.price if t.price else ''} {'' if t.paid is None else ('paid' if t.paid else 'not paid')}")
                p = T.read_panel(rgb, lay)
                print("  panel:", p.get("tab"), p.get("fields"))
                return
            shiftlog.record(state, reads_file=reads_file, rgb=rgb)
            reads, resumed = reads + 1, False
        if fan and (fan != panel_fan or T.thumb_diff(cur[1], last_panel) > CHANGED):
            last_panel, panel_fan = cur[1], fan
            shiftlog.record_panel(title, fan, T.read_panel(rgb, lay), at=at, reads_file=reads_file)
            panels += 1
        if reads and reads % 25 == 0 and still == SETTLE:
            done = (i - first) / max(1, last - first)
            el = time.time() - t0
            print(f"  {done:5.1%}  video {i / fps / 60:6.1f} min  reads {reads}  panels {panels}  "
                  f"elapsed {el / 60:.1f} min  eta {el / max(done, 1e-6) * (1 - done) / 60:.0f} min",
                  flush=True)
    cap.release()
    print("timeline:")
    print(timeline.report())
    if not probe:
        reads_file.with_suffix(".timeline.txt").write_text(timeline.report() + "\n", encoding="utf-8")
    print(f"skipped {skipped} reads with no fan name (no conversation open)")
    print(f"done: {reads} chat reads, {panels} panel reads in {(time.time() - t0) / 60:.1f} min -> {reads_file.name}")


def main(argv=None) -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description="Infloww screen recording -> shift-log chats")
    ap.add_argument("video")
    ap.add_argument("--account", default="", help="creator account name (default: the file's name)")
    ap.add_argument("--every", type=float, default=None,
                    help=f"seconds between sampled frames (default {EVERY_S}, --scan 1)")
    ap.add_argument("--from", dest="t_from", type=float, default=0, help="start at this minute")
    ap.add_argument("--to", dest="t_to", type=float, default=None, help="stop at this minute")
    ap.add_argument("--scan", action="store_true", help="only print where Infloww is in the video (no OCR)")
    ap.add_argument("--probe", action="store_true", help="print the first read, save nothing")
    ap.add_argument("--upscale", type=float, default=0,
                    help=f"fixed enlargement before reading (default: whatever reaches {TARGET}x)")
    ap.add_argument("--no-rebuild", action="store_true", help="skip rebuilding the chats at the end")
    a = ap.parse_args(argv)
    if a.scan:
        print(scan(Path(a.video), a.every or 1.0, a.t_from, a.t_to).report())
        return 0
    run(Path(a.video), a.account, a.every or EVERY_S, a.t_from, a.t_to, a.probe, a.upscale)
    if not a.probe and not a.no_rebuild:
        print("rebuilding chats (folds name spellings)…")
        shiftlog.rebuild()
        print(shiftlog.stats().splitlines()[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
