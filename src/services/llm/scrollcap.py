"""
llm/scrollcap.py — capture a whole chat by scrolling, stitched by PIXELS, then read it once.

Why (2026-11-28, first live __lore): pages were stitched by their OCR TEXT, and the
wheel moved ~1.6x further than assumed, so no two pages overlapped and 29 of 30
pages were thrown away ("does not line up"). A static chat deserves a static
method:

    1. CAPTURE   scroll up page by page; after each step MEASURE how far the chat
                 really moved by matching pixel rows between the two pages
                 (register()). No overlap -> step back down and retry smaller.
                 The wheel is calibrated from what it actually did, every step.
    2. STITCH    every page is placed at its measured offset -> one tall, exact
                 picture of the whole conversation (Strip.image()).
    3. READ      that picture is read in overlapping windows with the chat reader's
                 own read_turns(); a message counts only from a window that holds it
                 WHOLE, and its position in the tall picture is its identity, so
                 order and de-duplication never depend on OCR text.
    4. VERIFY    each message is read again by the Infloww reader (src/services/ocr)
                 as a second opinion: agree -> "verified", else "disputed", and the
                 message's own picture is kept as evidence.

Infloww draws a chat identically on every frame, so the overlap between two pages
matches pixel for pixel. Rows that are plain background match anywhere, so they
don't vote. The hover icons and the scrollbar are masked out of the match.
"""
from __future__ import annotations

import difflib
import hashlib
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import transcript as T                                  # noqa: E402

# ----------------------------------------------------------------- matching --
QUANT = 8               # grey levels are compared //8: JPEG-free, but antialiasing jitters
MIN_ROW_STD = 6.0       # a row flatter than this is background: it would match anywhere
MIN_VOTES = 25          # distinct content rows that must agree on an offset
MIN_SHARE = 0.6         # ...and this share of the overlap's content rows
EDGE_MASK = 28          # px at the right of the pane: the scrollbar
TARGET_STEP = 0.45      # of the pane height per scroll step: 55% overlap
MAX_PAGES = 400
TOP_TRIES = 3
TOP_WAIT_S = 2.0


def _gray(pane: np.ndarray) -> np.ndarray:
    g = pane[:, : pane.shape[1] - EDGE_MASK].astype(np.int16)
    return (g[:, :, 0] * 3 + g[:, :, 1] * 6 + g[:, :, 2]) // 10


def row_sigs(pane: np.ndarray) -> tuple[list[bytes | None], np.ndarray]:
    """A signature per pixel row (None for a flat background row)."""
    g = _gray(pane)
    q = (g // QUANT).astype(np.uint8)
    std = g.std(1)
    sigs = [hashlib.md5(q[r].tobytes()).digest() if std[r] >= MIN_ROW_STD else None
            for r in range(g.shape[0])]
    return sigs, std


def register(prev: np.ndarray, new: np.ndarray) -> tuple[int | None, int, float]:
    """How far the content moved DOWN from `prev` to `new` (scrolling up moves it
    down). Returns (offset px or None, agreeing rows, share). Every content row of
    `prev` votes for each offset at which an identical row appears in `new`; the
    winner must be backed by most of the rows that COULD have matched there."""
    a, _ = row_sigs(prev)
    b, _ = row_sigs(new)
    h = prev.shape[0]
    where: dict[bytes, list[int]] = {}
    for r, s in enumerate(b):
        if s is not None:
            where.setdefault(s, []).append(r)
    votes: dict[int, int] = {}
    for ra, s in enumerate(a):
        rows = where.get(s) if s is not None else None
        if not rows or len(rows) > 12:          # a pattern repeated everywhere says nothing
            continue
        for rb in rows:
            d = rb - ra
            if d >= 0:
                votes[d] = votes.get(d, 0) + 1
    if not votes:
        return None, 0, 0.0
    d = max(votes, key=lambda k: (votes[k], -k))
    n = votes[d]
    # The rows of `prev` that land inside `new` at this offset and carry content.
    eligible = sum(1 for s in a[: h - d] if s is not None and len(where.get(s, ())) <= 12)
    share = n / max(1, eligible)
    if n < MIN_VOTES or share < MIN_SHARE:
        return None, n, share
    return d, n, share


TOL_MAD = 6.0           # tolerant match: mean grey difference allowed over the overlap
TOL_MIN_OVERLAP = 0.15  # ...over at least this share of the pane


def register_tolerant(prev: np.ndarray, new: np.ndarray) -> tuple[int | None, float]:
    """Fallback for pixels that are not bit-identical (video compression, an image
    still fading in, a hover icon): line the two pages up by their row-brightness
    profiles, then CHECK the candidate on the pixels themselves. (offset, MAD)."""
    a, b = _gray(prev).astype(np.float32), _gray(new).astype(np.float32)
    h = a.shape[0]
    # Downsample columns: compression noise averages out, content does not.
    a4 = a[:, : a.shape[1] // 8 * 8].reshape(h, -1, 8).mean(2)
    b4 = b[:, : b.shape[1] // 8 * 8].reshape(h, -1, 8).mean(2)
    pa, pb = a4.std(1), b4.std(1)
    best, best_mad = None, 1e9
    min_ov = int(h * TOL_MIN_OVERLAP)
    # coarse: profile correlation over every shift
    scores = []
    for d in range(0, h - min_ov):
        x, y = pa[: h - d], pb[d:]
        if x.std() < 1 or y.std() < 1:
            continue
        scores.append((float(np.corrcoef(x, y)[0, 1]), d))
    for _c, d in sorted(scores, reverse=True)[:8]:
        ov = h - d
        mad = float(np.abs(a4[:ov] - b4[d:d + ov]).mean())
        if mad < best_mad:
            best, best_mad = d, mad
    if best is None or best_mad > TOL_MAD:
        return None, best_mad
    return best, best_mad


def register_any(prev: np.ndarray, new: np.ndarray, mask=None) -> tuple[int | None, str]:
    """Exact row matching first (live captures are lossless); the tolerant check
    only when that finds nothing. `mask` = columns to ignore in both pictures (a
    video/GIF preview playing there)."""
    if mask is not None:
        prev, new = prev.copy(), new.copy()
        prev[:, mask] = 0
        new[:, mask] = 0
    d, n, share = register(prev, new)
    if d is not None:
        return d, f"exact: {n} rows agree ({share:.0%})"
    d2, mad = register_tolerant(prev, new)
    if d2 is not None:
        return d2, f"tolerant: mean difference {mad:.1f}"
    return None, f"no match (exact {n} rows/{share:.0%}, tolerant {mad:.1f})"


def locate(cur: np.ndarray, new: np.ndarray, mask=None) -> tuple[int | None, str]:
    """Like register_any but either direction: + = content moved down (we are
    higher up the chat than `cur`), - = moved up (we are lower)."""
    d, how = register_any(cur, new, mask)
    if d is not None:
        return d, how
    d2, how2 = register_any(new, cur, mask)
    if d2 is not None and d2 > 0:
        return -d2, how2
    return None, how


MOVE_DIFF = 20          # grey change that counts as "this pixel is moving"
MOVE_COL_SHARE = 0.01   # a column is moving if this share of its rows changed
MOVE_PAD = 12           # px around the moving columns, for the frame's edges
MOVE_GAP = 80           # moving columns closer than this are the same preview box
MOVE_MAX_SHARE = 0.6    # more moving than this = the whole pane moved, not a video
ANIM_WAIT_S = 0.5


def moving_cols(a: np.ndarray, b: np.ndarray):
    """Columns that changed between two pictures of the SAME scroll position: a
    PPV video/GIF preview playing. Boolean column mask, or None if nothing moves."""
    if a.shape != b.shape:
        return None
    ga = a.astype(np.int16).sum(2) // 3
    gb = b.astype(np.int16).sum(2) // 3
    cols = (np.abs(ga - gb) > MOVE_DIFF).mean(0) > MOVE_COL_SHARE
    if not cols.any() or cols.mean() > MOVE_MAX_SHARE:
        return None
    idx = np.flatnonzero(cols)
    out = np.zeros_like(cols)
    # A preview is one box: dark columns inside it that happened not to change
    # still belong to it. Join moving columns less than MOVE_GAP apart, then pad.
    start = prev = idx[0]
    for i in list(idx[1:]) + [None]:
        if i is not None and i - prev <= MOVE_GAP:
            prev = i
            continue
        out[max(0, start - MOVE_PAD): prev + MOVE_PAD + 1] = True
        if i is not None:
            start = prev = i
    if out.mean() > MOVE_MAX_SHARE:
        return None
    return out


def _union(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return a | b


# -------------------------------------------------------------------- strip --
@dataclass
class Strip:
    """Pages placed at measured offsets. y grows downwards; the newest page (the
    bottom of the chat when capture started) sits at the largest y."""
    pages: list[np.ndarray] = field(default_factory=list)
    tops: list[int] = field(default_factory=list)       # y of each page's top row
    reached_top: bool = False
    log: list[str] = field(default_factory=list)
    lost: tuple | None = None       # (last good page, the page that would not match)

    def add(self, pane: np.ndarray, top: int) -> None:
        self.pages.append(pane)
        self.tops.append(top)

    @property
    def height(self) -> int:
        return (max(self.tops) + self.pages[0].shape[0]) - min(self.tops) if self.pages else 0

    def image(self) -> np.ndarray:
        y0 = min(self.tops)
        h, w = self.height, self.pages[0].shape[1]
        out = np.zeros((h, w, 3), np.uint8)
        # Oldest page first, newer ones over it: a later frame has every image loaded.
        for pane, top in sorted(zip(self.pages, self.tops), key=lambda p: p[1]):
            out[top - y0: top - y0 + pane.shape[0]] = pane
        return out


def capture(grab, wheel, pane_of, max_pages: int = MAX_PAGES, enough=None,
            status=lambda s: None) -> Strip:
    """Scroll up page by page and stitch.

    grab()          -> (rgb, layout) of the window, settled
    wheel(n)        scroll n notches (n > 0 = up / older)
    pane_of(rgb, layout) -> the message pane pixels
    enough(strip)   optional early stop (the "AI decides" / date rules)
    """
    careful = 0                                 # pages left to check for moving previews

    def look(stable: bool):
        """The pane now; with `stable`, twice, to find columns that are playing."""
        r, la = grab()
        a = pane_of(r, la)
        if not stable:
            return a, None
        time.sleep(ANIM_WAIT_S)
        r, la = grab()
        b = pane_of(r, la)
        return b, moving_cols(a, b)

    cur, cmask = look(False)
    h = cur.shape[0]
    strip = Strip()
    strip.add(cur, 0)
    px_per_notch = 100.0 * grab()[1].scale      # Chromium's nominal; corrected after one step
    still = 0
    for page in range(1, max_pages + 1):
        notches = max(1, round(TARGET_STEP * h / px_per_notch))
        wheel(notches)
        new, nmask = look(careful > 0)
        d, how = locate(cur, new, _union(cmask, nmask))
        if d is not None and d < 0:
            d = None                            # scrolled up but content went up: not trusted here
        tries = 0
        while d is None and tries < 3 and notches > 0:   # overshot: no overlap. Come back down.
            tries += 1
            back = max(1, notches // 2)
            wheel(-back)
            notches -= back
            new, nmask = look(careful > 0)
            d, how = locate(cur, new, _union(cmask, nmask))
            strip.log.append(f"page {page}: no overlap, stepped back {back} notch(es)")
        recovered = False
        if d is None:
            # Back where the last good page was taken (or close) and STILL no match:
            # the chat changed under us. A preview playing, or the chat jumped
            # (an image grew, older messages loaded). Find our place again.
            d, new, nmask, how = _refind(cur, cmask, look, wheel, h, px_per_notch, strip, page)
            if d is None:
                strip.lost = (cur, new)
                strip.log.append(f"page {page}: lost the thread ({how}) — stopped")
                break
            recovered = True
            careful = 8
            notches = 0                         # this step's notch count means nothing now
        careful = max(0, careful - 1) if not recovered else careful
        if d == 0 and not recovered:
            still += 1
            if still >= TOP_TRIES:
                strip.reached_top = True
                strip.log.append(f"page {page}: top of the chat")
                break
            time.sleep(TOP_WAIT_S)               # older messages may be loading
            continue
        still = 0
        if notches > 0:
            px_per_notch = 0.5 * px_per_notch + 0.5 * (d / notches)
        if d != 0:
            strip.add(new, strip.tops[-1] - d)
        strip.log.append(f"page {page}: moved {d}px on {notches} notch(es), {how}, "
                         f"{px_per_notch:.0f}px/notch" + (" (masked a playing preview)"
                                                         if nmask is not None or cmask is not None else ""))
        cur, cmask = new, nmask
        status(f"capturing: page {page}, {strip.height}px of chat")
        if enough is not None and enough(strip):
            strip.log.append(f"page {page}: stop rule met")
            break
    return strip


REFIND_STEPS = 25       # steps searched each way when the chat jumped


def _refind(cur, cmask, look, wheel, h, px_per_notch, strip, page):
    """The last good page no longer matches the screen. 1) Look twice: if part of
    the pane is playing, ignore those columns. 2) Still nothing: the chat jumped,
    so walk DOWN, then UP, in small steps until the last good page shows again.
    Returns (offset vs cur, pane, mask, how) or (None, pane, None, why)."""
    new, nmask = look(True)
    mask = _union(cmask, nmask)
    d, how = locate(cur, new, mask)
    if nmask is not None:
        strip.log.append(f"page {page}: a preview is playing ({int(nmask.sum())} columns) — ignoring it")
    if d is not None:
        strip.log.append(f"page {page}: found my place again right here ({how})")
        return d, new, nmask, how
    step = max(1, round(0.3 * h / px_per_notch))
    for sign, name in ((-1, "down"), (1, "up")):
        for i in range(1, REFIND_STEPS + 1):
            wheel(sign * step)
            new, nmask = look(True)
            d, how = locate(cur, new, _union(cmask, nmask))
            if d is not None:
                strip.log.append(f"page {page}: the chat jumped — found my place again "
                                 f"{i * step} notch(es) {name} ({how})")
                return d, new, nmask, how
        wheel(-sign * step * REFIND_STEPS)       # back to where the search started
    strip.log.append(f"page {page}: searched {REFIND_STEPS * step} notches both ways, "
                     "last good page not found")
    return None, new, None, how


# --------------------------------------------------------------------- read --
@dataclass
class Message:
    y: int                       # top of the bubble in the strip = its identity and order
    turn: dict                   # the chat reader's turn (text, who, footer fields...)
    second: str = ""             # the Infloww reader's text
    second_conf: float = 0.0
    verdict: str = ""            # verified | close | disputed | media
    crop: np.ndarray | None = None


def _key(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def read(strip_rgb: np.ndarray, pane_h: int, scale: float, status=lambda s: None,
         second_opinion: bool = True) -> list[Message]:
    """Every message in the stitched picture, top (oldest) to bottom, each read from
    a window that holds it whole."""
    H, W = strip_rgb.shape[:2]
    step = max(1, pane_h // 2)
    found: dict[int, Message] = {}
    starts = list(range(0, max(1, H - pane_h + 1), step))
    if not starts or starts[-1] + pane_h < H:
        starts.append(max(0, H - pane_h))
    for i, y0 in enumerate(starts):
        status(f"reading: {i + 1}/{len(starts)}")
        win = np.ascontiguousarray(strip_rgb[y0:y0 + pane_h])
        lay = T.Layout(region=(0, 0, W, win.shape[0]), scale=scale)
        try:
            turns = T.read_turns(win, lay, footers=True)
        except Exception:
            continue
        for t in turns:
            if t.partial or t.cut:
                continue                         # not whole here; another window has it
            top = y0 + t.box[1]
            dup = next((k for k in found if abs(k - top) <= 4 * scale), None)
            if dup is not None:
                # Same bubble seen whole twice: keep the read further from the edges.
                old = found[dup]
                if len(t.text) > len(old.turn.get("text", "")):
                    found[dup] = Message(top, t.to_dict())
                continue
            m = Message(top, t.to_dict())
            x0, by0, x1, by1 = t.box
            m.crop = win[max(0, by0 - 2): by1 + 3, max(0, x0 - 2): x1 + 3].copy()
            found[top] = m
    msgs = [found[k] for k in sorted(found)]
    if second_opinion:
        _second(msgs, scale)
    return msgs


def _second(msgs: list[Message], scale: float) -> None:
    """The Infloww reader on each message's own lines; compare with the chat reader."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "ocr"))
        import reader as RD
        if not RD.available():
            return
    except Exception:
        return
    for m in msgs:
        text = m.turn.get("text", "")
        if not text or m.crop is None:
            m.verdict = "media" if not text else "unchecked"
            continue
        bg = T.FAN_BG if m.turn.get("who") == "fan" else T.MODEL_BG
        lines, confs = [], []
        sub = m.crop
        for by0, by1 in T.text_bands(sub):
            ix0, ix1 = T.ink_extent(sub[by0:by1])
            mid = (by0 + by1) / 2
            b0, b1 = max(0, round(mid - 17 * scale)), min(sub.shape[0], round(mid + 17 * scale))
            line = sub[b0:b1, max(0, ix0 - round(6 * scale)): ix1 + round(8 * scale)].copy()
            fill = np.array(bg, np.uint8)
            t0, t1 = by0 - round(2 * scale) - b0, by1 + round(2 * scale) - b0
            if t0 > 0:
                line[:t0] = fill
            if 0 < t1 < line.shape[0]:
                line[t1:] = fill
            r = RD.read_line(line)
            lines.append(r.text)
            confs.append(r.conf)
        m.second = " ".join(l for l in lines if l)
        m.second_conf = min(confs) if confs else 0.0
        a, b = _key(text), _key(m.second)
        if a == b:
            m.verdict = "verified"
        elif difflib.SequenceMatcher(None, a, b).ratio() >= 0.9:
            m.verdict = "close"
        else:
            m.verdict = "disputed"


def selftest() -> int:
    """Registration on real pixels: a saved live page, viewed at known offsets.
    `prev` shows pane rows 300..899; `new` shows the same chat scrolled so its
    content sits d px LOWER — exactly what one step up the chat produces."""
    from PIL import Image
    root = Path(__file__).resolve().parents[3]
    pages = sorted((root / "userdata" / "ocr" / "lore_pages").glob("*/page_000.png"))
    if not pages:
        print("no saved page to test on (userdata/ocr/lore_pages)")
        return 0
    full = np.asarray(Image.open(pages[0]).convert("RGB"))
    pane = full[185:1150, 551:3055]
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    h = 600
    prev = pane[300:300 + h]
    for d in (0, 37, 150, 290):
        new = pane[300 - d:300 - d + h]
        got, n, share = register(prev, new)
        check(f"moved {d}px ({n} rows, {share:.0%})", got, d)
    check("no overlap (overshoot) -> None", register(pane[600:900], pane[0:300])[0], None)
    blank = np.full_like(pane[:300], 21)
    check("plain background never matches", register(blank, blank)[0], None)
    noise = np.random.default_rng(1).integers(0, 255, pane[:300].shape, dtype=np.uint8)
    check("unrelated picture never matches", register(pane[:300], noise)[0], None)
    # stitching: three overlapping views rebuild the original exactly
    st = Strip()
    st.add(pane[400:965], 0)
    st.add(pane[200:765], -200)
    st.add(pane[0:565], -400)
    check("stitched picture == original pane", bool(np.array_equal(st.image(), pane)), True)
    # a preview playing across EVERY row of the overlap: no row is identical twice
    # (video frames = other, structured parts of the real page, bright as a photo)
    def frame(k):
        f = np.roll(pane, 97 * k, axis=0)[:600, 200 * k: 200 * k + 1200].astype(np.int16) * 3
        return np.clip(f, 0, 255).astype(np.uint8)
    prev, new = pane[300:900].copy(), pane[300 - 150:900 - 150].copy()
    prev[:, 400:1600] = frame(1)
    new[:, 400:1600] = frame(2)
    check("playing preview, no mask -> None", register_any(prev, new)[0], None)
    again = new.copy()
    again[:, 400:1600] = frame(3)
    mask = moving_cols(new, again)
    check("moving columns found (most of the box)", mask is not None and float(mask[400:1600].mean()) > 0.8, True)
    check("playing preview, masked -> 150", register_any(prev, again, mask)[0], 150)
    fails += simtest(check)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


def simtest(check) -> int:
    """A fake Infloww over a real stitched chat: scroll it with capture() while
    (a) a PPV preview plays (its pixels change on every grab) and (b) the chat
    jumps when 'older messages load' (content inserted above, view not anchored).
    The stitched result must equal the chat, minus the playing box."""
    from types import SimpleNamespace
    from PIL import Image
    root = Path(__file__).resolve().parents[3]
    import glob
    shots = sorted(glob.glob(str(Path("D:/FanData") / "*" / "*" / "lore" / "*" / "chat.jpg")))
    if not shots:
        print("no stitched chat to simulate on")
        return 0
    chat = np.asarray(Image.open(shots[-1]).convert("RGB"))
    chat = chat[:, :, :].copy()
    H = 965
    if chat.shape[0] < 4 * H:
        print("stitched chat too short to simulate on")
        return 0
    rng = np.random.default_rng(7)
    older, newer = chat[: chat.shape[0] // 3], chat[chat.shape[0] // 3:]
    vid_y, vid_x = newer.shape[0] // 2, (newer.shape[1] - 520, newer.shape[1] - 60)
    st = SimpleNamespace(world=newer.copy(), pos=newer.shape[0] - H, loaded=False, grabs=0,
                         vid=vid_y)
    lay = SimpleNamespace(scale=1.367)
    PX = 120

    def grab():
        st.grabs += 1
        view = st.world[st.pos: st.pos + H].copy()
        a, b = max(st.vid, st.pos) - st.pos, min(st.vid + 900, st.pos + H) - st.pos
        if a < b:                                # the playing preview is in view
            view[a:b, vid_x[0]:vid_x[1]] = rng.integers(0, 255, (b - a, vid_x[1] - vid_x[0], 3),
                                                       dtype=np.uint8)
        return view, lay

    def wheel(n):
        st.pos = int(np.clip(st.pos - n * PX, 0, st.world.shape[0] - H))
        if st.pos == 0 and not st.loaded:        # top of what is loaded: older messages arrive
            st.loaded = True
            st.world = np.concatenate([older, st.world])
            st.vid += older.shape[0]             # the view does NOT follow: the chat jumps

    import scrollcap as me                       # the module's own capture, sleeps off
    old_wait = me.ANIM_WAIT_S
    me.ANIM_WAIT_S = 0
    try:
        s = me.capture(grab, wheel, lambda r, la: r, max_pages=400)
    finally:
        me.ANIM_WAIT_S = old_wait
    img = s.image()
    want = np.concatenate([older, newer])
    same_size = img.shape == want.shape
    check("sim: reached the top", s.reached_top, True)
    check(f"sim: stitched height {img.shape[0]} == chat {want.shape[0]}", same_size, True)
    if same_size:
        keep = np.ones(want.shape[1], bool)
        keep[vid_x[0]:vid_x[1]] = False
        check("sim: stitched pixels == chat (outside the playing box)",
              bool(np.array_equal(img[:, keep], want[:, keep])), True)
    for line in s.log:
        if "jump" in line or "playing" in line or "lost" in line or "place" in line:
            print("     ", line)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(selftest())
