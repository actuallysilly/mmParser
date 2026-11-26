"""
llm/unread_ping.py — ping when too many fans are waiting.

Infloww's chat list has a row of filter pills (All · Pinned · Priority · Unread ·
With Tips), and the Unread pill carries a coral badge with how many chats are
unread: "5", "12", "99+". This reads that number and pings once it reaches X,
then again every N minutes while it stays there. It re-arms the moment the count
drops under X, so the next climb pings straight away.

    UnreadPing.step(count, now, at, every_s) -> True when it should ping
    read_unread(rgb) -> int | None         the badge in one capture
    python unread_ping.py --test    offline checks
    python unread_ping.py --once    read the live window once and print it
    python unread_ping.py --play    play the sound once

Measured 2026-10-30 on the live 333 window (PrintWindow, 2754 wide):
pills #262626, the selected one #3467ff, list background #151515, badges
#ff7c71 22x22 with white digits ("99+" is 38x22). The model tab's own badge
(top-left, 24x16) carries the same number but is not used: the pill is what was
asked for, and it is named, so a missing Priority badge cannot shift it.

Why the digits are not read like the rest of the chat: RapidOCR's DETECTOR drops a
lone digit in a small box (it found nothing on "5" at any padding), and its angle
classifier read "99+" upside down as "+66". So the badge's white ink is cropped
tight, scaled to 28px, put on white, and handed to the RECOGNISER alone: "5",
"5", "5", "99+" on all four badges in the reference frame, ~2ms each.

Sound: userdata\\sounds\\unread.wav if it exists, else Windows Notify Messaging.
Switch: Settings ▸ Features ▸ "Unread ping" (UnreadPing); X and N are in the
Tools window, [UnreadPing] At / EveryMin in mass_gui.cfg.
"""
from __future__ import annotations

import re
import sys
import time
import unicodedata
from pathlib import Path

import numpy as np

MMA_ROOT = Path(__file__).resolve().parents[3]
CUSTOM_SOUND = MMA_ROOT / "userdata" / "sounds" / "unread.wav"
DEFAULT_SOUND = Path(r"C:\Windows\Media\Windows Notify Messaging.wav")

BADGE = (0xff, 0x7c, 0x71)
PILL_FILLS = ((0x26, 0x26, 0x26), (0x34, 0x67, 0xff))
COLOUR_TOL = 12
# Only the left part of the window holds the chat list. Coral elsewhere (PPV
# pills, unread timestamps) must never be looked at.
LEFT_FRAC = 0.30
GLYPH_H = 28
# Two reads in a row must agree before a count is believed: a badge caught
# mid-repaint must not ping or re-arm.
AGREE = 2


def _mask(rgb, colour, tol=COLOUR_TOL):
    return np.abs(rgb.astype(np.int16) - np.array(colour, np.int16)).max(2) <= tol


def _blobs(mask, min_area):
    import cv2
    n, _lab, st, _c = cv2.connectedComponentsWithStats(mask.astype(np.uint8))
    return [tuple(int(v) for v in st[i]) for i in range(1, n) if st[i][4] >= min_area]


def _recognise(gray_ink: np.ndarray) -> str:
    """Text of one line of black-on-white ink, recogniser only (no detector)."""
    import cv2
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "automation"))
    import automation as A
    ys, xs = np.nonzero(gray_ink < 128)
    if not len(ys):
        return ""
    g = gray_ink[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    s = GLYPH_H / g.shape[0]
    g = cv2.resize(g, (max(1, round(g.shape[1] * s)), GLYPH_H), interpolation=cv2.INTER_AREA)
    g = np.pad(g, ((10, 10), (16, 16)), constant_values=255)
    res, _ = A.ocr_engine().text_recognizer([cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)])
    return unicodedata.normalize("NFKC", res[0][0]) if res else ""


def _badge_number(rgb, box) -> int | None:
    x, y, w, h = box
    c = rgb[y:y + h, x:x + w]
    ink = c.min(2) >= 180                       # the white digits
    if ink.sum() < 6:
        return None
    t = _recognise(np.where(ink, 0, 255).astype(np.uint8))
    m = re.fullmatch(r"\s*(\d{1,3})\s*\+?\s*", t)
    return int(m[1]) if m else None


def read_unread(rgb: np.ndarray) -> int | None:
    """The number on the Unread pill's badge; 0 when the pill has no badge;
    None when the pill row is not found (not the Messages list, or covered)."""
    h, w = rgb.shape[:2]
    left = rgb[:, :int(w * LEFT_FRAC)]
    # Badges: solid coral, about square, 14-32px tall.
    badges = [b for b in _blobs(_mask(left, BADGE), 60)
              if 12 <= b[3] <= 34 and 0.8 <= b[2] / b[3] <= 2.6 and b[4] / (b[2] * b[3]) >= 0.5]
    # Pills: a filled run 26-60px tall, wider than tall. They sit in a row.
    pills = []
    for fill in PILL_FILLS:
        pills += [b for b in _blobs(_mask(left, fill, 4 if fill[2] == 0x26 else COLOUR_TOL), 400)
                  if 24 <= b[3] <= 64 and b[2] >= 1.3 * b[3] and b[2] < left.shape[1] * 0.6]
    import cv2
    for px, py, pw, ph, _a in sorted(pills, key=lambda b: (b[1], b[0])):
        # The pill's word, without the badge that may overlap its corner.
        inner = rgb[py + 4:py + ph - 4, px + 6:px + pw - 6].astype(np.int16)
        fill = rgb[py + ph // 2, px + 3].astype(np.int16)
        ink = (np.abs(inner - fill).max(2) > 60) & ~_mask(inner, BADGE, 40)
        if ink.sum() < 20:
            continue
        word = _recognise(np.where(ink, 0, 255).astype(np.uint8))
        if re.sub(r"[^a-z]", "", word.lower()) != "unread":
            continue
        # Its badge overlaps the top-right corner.
        for bx, by, bw, bh, _ in badges:
            cx, cy = bx + bw / 2, by + bh / 2
            if px + pw - 1.5 * bh <= cx <= px + pw + bh and py - bh <= cy <= py + ph / 2:
                return _badge_number(rgb, (bx, by, bw, bh))
        return 0
    return None


class UnreadPing:
    """When to ping, given a stream of counts. No I/O, so it can be tested."""

    def __init__(self) -> None:
        self.last_ping = None       # epoch of the last ping, None = armed
        self.seen: list = []        # the last AGREE raw reads

    def step(self, count: int | None, now: float, at: int, every_s: float) -> bool:
        self.seen = (self.seen + [count])[-AGREE:]
        if len(self.seen) < AGREE or len(set(self.seen)) != 1 or count is None:
            return False                        # not settled, or not readable
        if at <= 0 or count < at:
            self.last_ping = None               # re-arm under X
            return False
        if self.last_ping is None or (every_s > 0 and now - self.last_ping >= every_s):
            self.last_ping = now
            return True
        return False


def play() -> None:
    import winsound
    path = CUSTOM_SOUND if CUSTOM_SOUND.exists() else DEFAULT_SOUND
    try:
        winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
    except RuntimeError:
        winsound.MessageBeep(winsound.MB_ICONASTERISK)


def grab() -> np.ndarray | None:
    """One PrintWindow capture of the Infloww Messages window, or None."""
    import transcript as T
    first = None
    for hwnd, _title in T._matching_windows(T.A.TARGET_TITLE):
        if T._pinger.u32.IsIconic(hwnd):
            continue
        rgb = T._pinger.print_window(hwnd)
        if rgb is None:
            continue
        # The Unread pill is in the chat list, which only the WORK window has; a
        # harvest window ("Open in new tab") must not be read instead.
        try:
            lay = T.find_layout(rgb)
        except Exception:
            lay = None
        if lay is None or lay.region[0] >= T.WORK_LIST_MIN_X:
            return rgb                  # no layout: a page with no chat open; keep old behaviour
        first = first if first is not None else rgb
    return first


# ---------------------------------------------------------------------- tests --
def _test() -> int:
    fails = 0

    def ok(name, got, want):
        nonlocal fails
        print(("ok  " if got == want else "FAIL"), name, got if got != want else "")
        fails += got != want

    p, m = UnreadPing(), 60
    run = lambda counts, at=10, every=5 * m: [p.step(c, t * m, at, every)   # noqa: E731
                                              for t, c in counts]
    ok("under X: silent", run([(0, 3), (1, 3)]), [False, False])
    ok("reaches X: pings once both reads agree", run([(2, 10), (3, 10)]), [False, True])
    ok("stays over X: silent until N minutes", run([(4, 12), (5, 12), (7, 12)]), [False, False, False])
    ok("N minutes later: pings again", run([(8, 12), (9, 12)]), [True, False])
    ok("one flicker under X does not re-arm", run([(10, 4), (11, 12)]), [False, False])
    ok("drops under X, climbs back: pings at once", run([(12, 4), (13, 4), (14, 11), (15, 11)]),
       [False, False, False, True])
    ok("unreadable reads never ping", run([(30, None), (31, None)]), [False, False])
    p = UnreadPing()
    ok("every 0 = once per climb", run([(0, 10), (1, 10), (60, 10)], every=0), [False, True, False])

    # The real pill row (2026-10-30: 99+ / 5 / 5), set back into a window-wide
    # strip of list background, since the search only looks at the left part.
    import cv2
    row = cv2.cvtColor(cv2.imread(str(Path(__file__).with_name("testdata") / "unread_pill_row.png")),
                       cv2.COLOR_BGR2RGB)
    canvas = np.full((row.shape[0] + 40, 2754, 3), 0x15, np.uint8)
    canvas[20:20 + row.shape[0], :row.shape[1]] = row
    ok("real pill row: Unread badge reads 5", read_unread(canvas), 5)
    canvas[:, :, :] = 0x15
    ok("no pill row: None", read_unread(canvas), None)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    if "--test" in sys.argv:
        sys.exit(_test())
    if "--once" in sys.argv:
        rgb = grab()
        print("no Infloww Messages window" if rgb is None else f"unread: {read_unread(rgb)}")
    if "--play" in sys.argv:
        play()
        time.sleep(3)
