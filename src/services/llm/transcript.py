"""
llm/transcript.py — read the open Infloww conversation as an attributed transcript.

This is the input side of the reply drafter, and it is deliberately its own file
with no model in it. A draft is only ever as good as the conversation it was
given, so "what did we read off the screen" has to be inspectable on its own —
run this module directly and it prints exactly what the model would be told,
with nothing generated and nothing sent.

────────────────────────────────────────────────────────────────────────────────
WHO SAID WHAT IS A FILL COLOUR, NOT A GUESS
────────────────────────────────────────────────────────────────────────────────
The hard part of reading a chat off pixels is normally attribution: a flat OCR of
the message pane gives a wall of text with no idea which half is yours. In
Infloww it is decided by two constants ../automation/UI-ELEMENT-MAP.md measured:

    #262626   fan bubble,   left-aligned, starts x ~465
    #353535   model bubble, right-aligned, ends  x ~1585

So attribution is exact rather than heuristic, and `automation.py` already has
both finders including their traps — `find_fan_bubbles` clamps to x >= 460
because THE FAN AVATAR IS THE SAME #262626, and `find_model_bubbles` requires a
substantially-filled column because a kebab's antialiasing once dragged x0 12px.
Neither is re-derived here.

────────────────────────────────────────────────────────────────────────────────
ONE OCR OF THE PANE, THEN BUCKET — NOT ONE OCR PER BUBBLE
────────────────────────────────────────────────────────────────────────────────
The obvious build is to crop each bubble and OCR it. It reads far WORSE, and the
reason is worth writing down because it is invisible from the outside:

**A text box touching the edge of the crop makes RapidOCR's detector return
nothing at all.** Not a partial read — zero boxes. A bubble is sized to its text,
so cropping to the bubble puts text against all four edges, which is the one
input the detector refuses. Measured on `Whole UI.png`: cropping the bubbles
individually read 3 of 5 and returned "" for two bubbles that are plainly full of
text, at every upscale from 1x to 6x. One OCR of the whole pane read 4 of 5,
because in the pane every bubble's text is interior.

It is also ~5x faster: one call at 1.5s instead of one per bubble.

So the pass is: OCR the pane once, then assign each returned box to a bubble by
which rect contains its centre. Attribution stays exact — it comes from the
bubble rects, not from the OCR.

────────────────────────────────────────────────────────────────────────────────
THE REPAIR PASS: LONG LINES ARE TRUNCATED BY THE RECOGNISER
────────────────────────────────────────────────────────────────────────────────
The 5th bubble is the reason there is a second pass. Its first line is a
full-bubble-width PPV caption — 777x23px, an aspect ratio of 34:1 — and the
recogniser silently drops its tail:

    read   'Just imagine ... for the tastiest desser'
    truth  'Just imagine ... for the tastiest dessert youve ever had..'

The DETECTOR found the line correctly; the RECOGNISER resizes each detected box
to a fixed height and cannot hold that many characters. No amount of upscaling
helps, because the aspect ratio is preserved. Long PPV captions are exactly the
shape that trips it, so this is a common case here, not an edge one.

The fix is to split an over-wide line AT A WORD GAP (a column of pure background
runs between words) and read the pieces. Two details are load-bearing and both
were measured:

  • **Horizontal padding only.** Padding the band vertically destroys the spacing
    in the result — 'Justimaginespreadingmy bare legs'. Padding it horizontally
    keeps it. Vertical padding is not a neutral safety margin here.
  • **Split at a gap, not at the midpoint.** A blind halfway cut sliced the `s`
    off `straight`. Word gaps are free, exact, and already visible in the
    column projection.

With both, the line above comes back character-perfect at every padding and
upscale tried. The repair only runs on bands the pane pass missed or truncated,
so the common case still costs one OCR call.

────────────────────────────────────────────────────────────────────────────────
WHAT IT REFUSES TO GUESS
────────────────────────────────────────────────────────────────────────────────
  • A bubble clipped by the top of the scroll area is `partial`. Its text is cut
    mid-sentence and a model handed a truncated line will answer the half it can
    see.
  • A bubble with no text at all is `[media]`, not "" — a photo or a PPV has no
    text, and that is a fact about the conversation rather than a failure.
  • `read_conversation` says when no fan bubble is in view. That means we are
    looking at a run of our own messages with no idea what prompted them, which
    is the one state where drafting a reply is nonsense.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

import importlib.util as _importlib
import numpy as np

# automation.py is the shared foundation for driving this UI (window gate, DPI,
# capture, detection). Importing it rather than copying primitives is the rule
# its own docs set: "future automations import from here rather than re-deriving".
_AUTOMATION = Path(__file__).resolve().parent.parent / "automation"
if str(_AUTOMATION) not in sys.path:
    sys.path.insert(0, str(_AUTOMATION))

import automation as A  # noqa: E402

# The pinger already solved capturing this window WITHOUT stealing it, which
# matters more here than anywhere else in MMA: the drafter fires while you are
# working in Infloww. automation.py's require_window() demands the FOREGROUND
# window and grabs the screen at its rect — that reads whatever is on top, so it
# would have to pull focus to be correct. PrintWindow reads the window's own
# surface while it is covered. pinger.pyw is a .pyw, so it loads by path.
_PINGER = Path(__file__).resolve().parent.parent / "pinger" / "pinger.pyw"
_spec = _importlib.spec_from_file_location("mma_pinger", _PINGER)
_pinger = _importlib.module_from_spec(_spec)
_spec.loader.exec_module(_pinger)

# The size UI-ELEMENT-MAP.md was measured at. The reader no longer depends on
# it — see find_layout() — but it is still what the offsets below were taken from.
REF_SIZE = (A.REF_W, A.REF_H)

# ------------------------------------------------------------------ layout --
# Every panel edge in Infloww is the same 1px #444444 line: the chat list | pane
# divider, the pane | insights divider, the line under the conversation header
# and the line over the composer. Finding those four gives the message pane at
# ANY window size, instead of the one rectangle measured at 1920x1032.
#
# Verified both ways: on the reference capture it reproduces A.R_MESSAGES
# exactly (401,135 + 1237x727), and on the live 2162x3770 window on the vertical
# monitor it finds 662..1699 x 220..3462.
#
# The SCALE matters as much as the edges. That monitor runs a higher display
# scale, so everything is ~1.65x bigger — the fan avatar's right edge sits 86px
# into the pane there, not 51. Scale is read off the header: the distance from
# the window top to the line under it is 133px at the reference.
DIVIDER = (0x44, 0x44, 0x44)
DIVIDER_TOL = 2
REF_HEADER_Y = 133
# Pane-relative versions of automation.py's window-absolute cutoffs, at scale 1:
# FAN_BUBBLE_XMIN 460, FAN_BUBBLE_X0_MAX 520, MODEL_BUBBLE_XMAX 1590, measured
# against a pane spanning 401..1638.
FAN_XMIN_DX = A.FAN_BUBBLE_XMIN - 401       # 59: past the fan avatar
FAN_X0MAX_DX = A.FAN_BUBBLE_X0_MAX - 401    # 119: a fan bubble starts this close
MODEL_XMAX_DX = 1638 - A.MODEL_BUBBLE_XMAX  # 48: before our own avatar


@dataclass
class Layout:
    region: tuple[int, int, int, int]       # (x, y, w, h), like A.R_MESSAGES
    scale: float

    @property
    def fan_xmin(self) -> int:
        return self.region[0] + round(FAN_XMIN_DX * self.scale)

    @property
    def fan_x0max(self) -> int:
        return self.region[0] + round(FAN_X0MAX_DX * self.scale)

    @property
    def model_xmax(self) -> int:
        return self.region[0] + self.region[2] - round(MODEL_XMAX_DX * self.scale)


def find_layout(rgb: np.ndarray) -> Layout | None:
    """The message pane and display scale of this capture, or None.

    None means the dividers are not where a conversation view puts them — the
    Inbox decoy window, a settings page, a half-painted frame. Not a guess.
    """
    h, w = rgb.shape[:2]
    line = np.abs(rgb.astype(int) - np.array(DIVIDER)).max(2) <= DIVIDER_TOL
    # Vertical dividers run (almost) the whole middle of the window.
    mid = line[int(h * 0.3):int(h * 0.7)]
    cols = [x for x in range(w) if mid[:, x].mean() > 0.95]
    if len(cols) < 2:
        return None
    x0, x1 = cols[0], cols[1]
    if x1 - x0 < 200:
        return None
    # Horizontal dividers span the pane between those two.
    span = line[:, x0 + 10:x1 - 10]
    rows = [y for y in range(h) if span[y].mean() > 0.95]
    if len(rows) < 2:
        return None
    y0, y1 = rows[0], rows[1]
    if y1 - y0 < 200:
        return None
    return Layout(region=(x0, y0 + 2, x1 - x0, y1 - y0 - 2),
                  scale=(y0 + 2) / (REF_HEADER_Y + 2))

FAN_BG = (0x26, 0x26, 0x26)
MODEL_BG = (0x35, 0x35, 0x35)

# Body text is #d9d9d9 (217) on a #262626/#353535 bubble (38/53). Anything over
# this is ink. The margin either side is enormous, so the value is not delicate.
INK = 120

# An OCR box belongs to a bubble if its centre is within the rect, plus this much
# slack for a glyph that overhangs the fill by an antialiased pixel or two.
BUCKET_PAD = 6

# Rows within this many pixels are the same text line.
ROW_TOL = 10

# Above this width:height the recogniser starts dropping the tail of a line.
# Measured: 34:1 truncated, and shorter lines in the same capture read whole.
# Set below the observed failure rather than at it.
MAX_REC_ASPECT = 26

# What to split an over-wide band down to. Comfortably under the limit above, so
# a chunk never lands near it.
CHUNK_ASPECT = 14

# Background columns needed to count as a gap between words.
MIN_GAP_PX = 4

# Horizontal-only padding round a chunk, so its text never touches an edge.
# NEVER pad vertically: it costs the spaces in the result.
CHUNK_PAD = 20

# A bubble whose top is within this of the scroll area's top edge is assumed cut
# off by it. Not zero: the bound is nominal and a bubble resting exactly on it is
# indistinguishable from one running under it.
CLIP_TOL = 3


@dataclass(frozen=True)
class Turn:
    who: str                    # "fan" | "model"
    text: str                   # "" for a bubble with no readable text
    box: tuple[int, int, int, int]
    partial: bool = False       # clipped by the top of the scroll area
    repaired: int = 0           # bands the second pass had to re-read
    cut: bool = False           # clipped by the BOTTOM (the composer covers it)
    reply_to: str = ""          # the quoted message, when this bubble is a reply
    # From the footer line under the bubble (read_turns(footers=True)) -------
    time: str = ""              # "6:51 pm"
    date: str = ""              # "Jan 27" when Infloww shows one, else ""
    sender: str = ""            # the chatter name under HER messages ("Silly")
    price: str = ""             # "49.49" — the PPV price pill
    paid: bool | None = None    # the pill: False "not paid", True paid, None no pill
    liked: bool = False         # the blue heart: he liked this message
    footer: str = ""            # the footer's raw OCR, so it can be re-parsed later
    # From the media itself (always read) ------------------------------------
    ppv_border: str = ""        # "unopened" (#ff7c71) / "opened" (#2bd4ac) / ""

    @property
    def is_media(self) -> bool:
        return not self.text

    _EXTRA = ("time", "date", "sender", "price", "paid", "liked", "footer", "ppv_border")

    def to_dict(self) -> dict:
        d = {"who": self.who, "text": self.text, "box": list(self.box),
             "partial": self.partial, "cut": self.cut, "reply_to": self.reply_to,
             "repaired": self.repaired}
        for k in self._EXTRA:
            v = getattr(self, k)
            if v is not None and v != "" and not (k == "liked" and not v):
                d[k] = v                    # paid=False is a fact; keep it
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Turn":
        return cls(who=d["who"], text=d["text"], box=tuple(d["box"]),
                   partial=d.get("partial", False), repaired=d.get("repaired", 0),
                   cut=d.get("cut", False), reply_to=d.get("reply_to", ""),
                   **{k: d[k] for k in cls._EXTRA if k in d})

    def render(self) -> str:
        """One line, the way the model will be shown it."""
        body = self.text or ("" if self.reply_to else "[media]")
        if self.partial:
            body = "..." + body
        if self.cut and body:
            body += "..."
        who = self.who
        if self.reply_to:
            q = self.reply_to if len(self.reply_to) <= 80 else self.reply_to[:77] + "..."
            who += f' (replying to "{q}")'
        return f"{who}: {body}".rstrip(": ") if not body else f"{who}: {body}"


# ------------------------------------------------------------------- tidy --
# What the OCR reads off a photo or PPV is its overlay, not words: the "1/10 · 3"
# counter and the onlyfans.com/<name> watermark. Strip those; if hardly any
# words are left, the bubble was media.
# (".com/", not "fans.com/": the overlay is half-transparent and reads as
# "ans.com/alicedoubleyew" as often as not.)
# Live (2026-10-22) it also reads "1/6 OnlyFans.co ofiiagomez" / "phiilagomez" —
# a different handle every read, which stopped the shift recorder lining reads up.
_MEDIA_JUNK = re.compile(r"\S*\.com/\S*|\S*\d+\s*/\s*\d+\s*[·.]\s*\S*\d+"
                         r"|\S*fans\.co\S*(?:\s+\S+)?|\b\d{1,2}\s*/\s*\d{1,2}\b|^18\+$", re.I)
# A reply shows the quoted message on top: "Name, Oct 11 9:17 AM <quote> View
# message <reply>". Without splitting it the model reads the quote as said NOW.
_QUOTE = re.compile(r"^.{1,40}?,\s*[A-Z0][a-z]{2}\s+\d{1,2}\s+\d{1,2}:\d{2}\s*[AP]M\s*"   # "0ct" = Oct
                    r"(?P<quote>.*?)\s*(?:\.\.\.\s*)?View message\s*(?P<body>.*)$", re.S)


def tidy(text: str) -> tuple[str, str]:
    """(body, reply_to) from a bubble's raw OCR text."""
    t, quote = text.strip(), ""
    m = _QUOTE.match(t)
    if m:
        quote, t = m.group("quote").strip(), m.group("body").strip()
    left = _MEDIA_JUNK.sub(" ", t)
    if len(re.findall(r"[A-Za-z]{2,}", left)) < 3 and _MEDIA_JUNK.search(t):
        t = ""
    elif _MEDIA_JUNK.search(t) and re.search(r"fans\.co", t, re.I):
        t = " ".join(left.split())          # caption under a photo: drop the watermark
    return t, quote


# ------------------------------------------------------------------ capture --
def _matching_windows(title: str) -> list[tuple[int, str]]:
    """Every visible top-level window whose title contains `title`, in Z order."""
    u32 = _pinger.u32
    found = []

    @_pinger.ctypes.WINFUNCTYPE(_pinger.ctypes.c_bool, _pinger.wintypes.HWND,
                                _pinger.wintypes.LPARAM)
    def cb(hwnd, _):
        if u32.IsWindowVisible(hwnd):
            n = u32.GetWindowTextLengthW(hwnd)
            if n:
                buf = _pinger.ctypes.create_unicode_buffer(n + 1)
                u32.GetWindowTextW(hwnd, buf, n + 1)
                if title.lower() in buf.value.lower():
                    found.append((hwnd, buf.value))
        return True

    u32.EnumWindows(cb, 0)
    return found


WORK_LIST_MIN_X = 200       # pane further right than this = there is a chat list


def capture_conversation() -> tuple[np.ndarray, Layout, str]:
    """(pixels, layout, title) of the Infloww window showing a conversation.

    More than one window can be called "Infloww Messages": an Inbox page with no
    conversation answers to the same title (see the window-size note in
    UI-ELEMENT-MAP.md). Taking the first match read the decoy. So every match
    is tried and the one whose dividers make a message pane wins.
    """
    wins = _matching_windows(A.TARGET_TITLE)
    if not wins:
        raise A.WindowNotReady(
            f"no visible window matching {A.TARGET_TITLE!r} — is Infloww open?")
    minimised = 0
    # A harvest window ("Open in new tab", lore_gatherer) shows a conversation
    # too, but has no chat list: its pane starts at the window's left edge. The
    # WORK window (the one with the list) wins; a harvest window only if alone.
    spare = None
    for hwnd, title in wins:
        rgb = None if _pinger.u32.IsIconic(hwnd) else _pinger.print_window(hwnd)
        if rgb is None:
            minimised += 1              # no surface to read
            continue
        # A window closing mid-capture hands back a frame that is not a window
        # any more; that is "no window", not a crash.
        try:
            layout = find_layout(rgb)
        except Exception:
            continue
        if layout and layout.region[0] >= WORK_LIST_MIN_X:
            return rgb, layout, title
        if layout and spare is None:
            spare = (rgb, layout, title)
    if spare:
        return spare
    if minimised == len(wins):
        raise A.WindowNotReady("Infloww Messages is minimised — restore it (it can "
                               "sit behind other windows, just not minimised)")
    raise A.WindowNotReady("Infloww Messages is open but no conversation is showing")


# A small grey copy of the pane, for "has the chat changed?". Block means over a
# fixed grid, so it does not care about window size, and two captures of the
# same screen give the same thumb in two different processes.
THUMB = (96, 32)                            # rows, cols


def pane_thumb(rgb: np.ndarray, layout: Layout) -> np.ndarray:
    x, y, w, h = layout.region
    g = rgb[y:y + h, x:x + w].mean(2)
    r, c = THUMB
    g = g[:h - h % r, :w - w % c]
    return g.reshape(r, g.shape[0] // r, c, g.shape[1] // c).mean((1, 3)).astype(np.float32)


def thumb_diff(a: np.ndarray, b: np.ndarray) -> float:
    """Mean grey-level difference. ~0 for the same screen; a new message or a
    scroll moves it by several units."""
    if a is None or b is None or a.shape != b.shape:
        return 255.0
    return float(np.abs(a - b).mean())


def capture(force: bool = False) -> np.ndarray:
    """Infloww own pixels, without taking focus. Raises if it cannot be read."""
    hwnd, title = _pinger.find_window(A.TARGET_TITLE)
    if not hwnd:
        raise A.WindowNotReady(
            f"no visible window matching {A.TARGET_TITLE!r} — is Infloww open?")
    rgb = _pinger.print_window(hwnd)
    if rgb is None:
        # PrintWindow reads a covered window, but a MINIMISED one has no surface
        # at all — the pinger own known limitation, and the same answer applies:
        # say so rather than pretending to have read something.
        raise A.WindowNotReady(
            f"{title!r} gave no pixels — it is probably minimised. Restore it; "
            f"it can sit behind everything.")
    # Any size is fine now: read_turns finds the pane in the pixels. `force` is
    # kept so existing callers do not break; it no longer changes anything.
    return rgb


# -------------------------------------------------------------- band reading --
def text_bands(sub: np.ndarray) -> list[tuple[int, int]]:
    """Row ranges holding ink, i.e. the text lines inside a bubble."""
    rows = (sub.mean(2) > INK).sum(1)
    out, s = [], None
    for i, v in enumerate(list(rows) + [0]):
        if v and s is None:
            s = i
        if not v and s is not None:
            if i - s >= 4:                       # ignore single-row speckle
                out.append((s, i))
            s = None
    return out


def ink_extent(band: np.ndarray) -> tuple[int, int]:
    """First and last column holding ink, i.e. where the text actually is.

    This is measured rather than assumed because a band is sliced out of the
    BUBBLE, so it is always the bubble's full width — and a short line in a wide
    bubble would otherwise be judged by the bubble's aspect ratio and sent to the
    repair pass it does not need. That is not a harmless extra call: the repair
    reads a line in chunks, which is slightly worse at spacing than one clean
    read, so a needless repair actively degrades a line the pane pass got right.
    """
    cols = np.where((band.mean(2) > INK).sum(0) > 0)[0]
    if not len(cols):
        return 0, 0
    return int(cols.min()), int(cols.max()) + 1


def _word_gaps(band: np.ndarray) -> list[int]:
    """Mid-columns of the runs of pure background that separate words."""
    cols = (band.mean(2) > INK).sum(0)
    out, s = [], None
    for i, v in enumerate(list(cols) + [1]):
        if v == 0 and s is None:
            s = i
        if v != 0 and s is not None:
            if i - s >= MIN_GAP_PX:
                out.append((s + i) // 2)
            s = None
    return out


def _split_edges(band: np.ndarray) -> list[int]:
    """Column edges that cut `band` into chunks the recogniser can hold."""
    h, w = band.shape[0], band.shape[1]
    if h == 0 or w / h <= MAX_REC_ASPECT:
        return [0, w]
    n = max(2, int(np.ceil((w / h) / CHUNK_ASPECT)))
    gaps = _word_gaps(band)
    if not gaps:
        return [0, w]                            # no gap to cut at — read as is
    pts = {min(gaps, key=lambda g: abs(g - w * i / n)) for i in range(1, n)}
    return [0] + sorted(pts) + [w]


def _ocr_chunk(band: np.ndarray, a: int, b: int, bg) -> str:
    """One chunk, padded horizontally so its text touches no edge."""
    sub = band[:, a:b]
    if sub.size == 0:
        return ""
    canvas = np.empty((sub.shape[0], sub.shape[1] + 2 * CHUNK_PAD, 3), np.uint8)
    canvas[:, :] = np.array(bg, np.uint8)
    canvas[:, CHUNK_PAD:CHUNK_PAD + sub.shape[1]] = sub
    try:
        res, _ = A.ocr_engine()(canvas)
    except Exception:
        return ""
    return " ".join(t for _pts, t, _score in (res or []))


def read_band(band: np.ndarray, bg) -> str:
    """One text line, split at word gaps if it is too wide to recognise whole."""
    edges = _split_edges(band)
    parts = [_ocr_chunk(band, edges[i], edges[i + 1], bg)
             for i in range(len(edges) - 1)]
    return " ".join(p.strip() for p in parts if p.strip())


# ----------------------------------------------------------------- footers --
# Under every bubble is a footer line, and the pane OCR already reads it (it lands
# outside every bubble, so nothing above used it). Measured on Whole UI.png:
#
#     her PPV caption   "$49.49 not paid 6:51 pm  Silly"   pill #ff7c71, name blue
#     her text          "6:52 pm w silly"                  ✓✓ reads as "w"; heart #3467ff
#     his text          "6:52 pm"
#
# Its centre sits 13-14px under its bubble's bottom at scale 1. A footer with NO
# bubble above it is a photo/video sent with no caption: there is no #262626 /
# #353535 fill for the bubble finders to see, so until now it was dropped.
FOOTER_DY = (4, 32)             # footer centre this far below its bubble, scale 1
FOOTER_BAND = 9                 # half-height of the footer row, for colour checks
PILL_UNPAID = (0xff, 0x7c, 0x71)
PILL_PAID = (0x2b, 0xd4, 0xac)  # NOT measured: BallLore's "opened" border colour
LIKE_BLUE = (0x34, 0x67, 0xff)
COLOUR_TOL = 10
PILL_MIN_PX = 200               # the unpaid pill is ~900px at scale 1
LIKE_MIN_PX = 40                # the heart is ~115px; the blue name is #155ef0, out of tol
# The red/green frame round a PPV's media, drawn just outside the media bubble.
BORDER_W = 8

_PILL = re.compile(r"\$\s?(?P<price>\d[\d,]*(?:[.,]\d{2})?)\s*"
                   r"(?P<state>not\s*paid|unpaid|paid|purchased|opened|unlocked)?", re.I)
_TIME = re.compile(r"(?:(?P<date>(?:[A-Z][a-z]{2}\s*\d{1,2}(?:,\s*\d{4})?)|Yesterday|Today)[,\s]*)?"
                   r"(?P<time>\d{1,2}\s*:\s*\d{2})\s*(?P<ampm>[ap]\.?\s?m)?", re.I)
# What the ✓✓ (and a single ✓) OCR as, when it comes out as its own token.
_TICKS = re.compile(r"^(?:[wvW√✓✔]{1,2}|vv|w)(?:\s+|$)")


def parse_footer(text: str) -> dict | None:
    """The fields of one footer line, or None if it is not a footer (no time)."""
    t = " ".join(text.split())
    out: dict = {"footer": t}
    p = _PILL.search(t)
    rest = t
    if p:
        price = p.group("price")              # "49,49" is a decimal comma; "1,200" is not
        out["price"] = price.replace(",", ".") if re.fullmatch(r"\d+,\d{2}", price) \
            else price.replace(",", "")
        st = (p.group("state") or "").lower().replace(" ", "")
        if st in ("notpaid", "unpaid"):
            out["paid"] = False
        elif st:
            out["paid"] = True
        rest = (t[:p.start()] + " " + t[p.end():]).strip()
    m = _TIME.search(rest)
    if not m:
        return None
    out["time"] = re.sub(r"\s+", "", m.group("time")) + \
        (" " + m.group("ampm").replace(".", "").replace(" ", "").lower() if m.group("ampm") else "")
    if m.group("date"):
        out["date"] = m.group("date").strip()
    sender = _TICKS.sub("", rest[m.end():].strip()).strip(" .·-")
    if sender:
        out["sender"] = sender
    return out


def _count(rgb: np.ndarray, colour, tol=COLOUR_TOL) -> int:
    if rgb.size == 0:
        return 0
    return int((np.abs(rgb.astype(int) - np.array(colour)).max(2) <= tol).sum())


def _footer_colours(rgb, layout: Layout, side: str, cy: float) -> dict:
    """What the footer says in colour: the pill's paid state, and the heart."""
    rx, ry, rw, rh = layout.region
    k = layout.scale
    mid = rx + rw // 2
    y0, y1 = max(0, int(cy - FOOTER_BAND * k)), int(cy + FOOTER_BAND * k) + 1
    band = rgb[y0:y1, mid:rx + rw] if side == "model" else rgb[y0:y1, rx:mid]
    out = {}
    area = k * k
    unpaid, paid = _count(band, PILL_UNPAID), _count(band, PILL_PAID)
    if max(unpaid, paid) >= PILL_MIN_PX * area:
        out["paid"] = paid > unpaid
    if _count(band, LIKE_BLUE) >= LIKE_MIN_PX * area:
        out["liked"] = True
    return out


def ppv_border(rgb, box, k: float) -> str:
    """"unopened" / "opened" if a PPV frame runs down the sides of this box."""
    x0, y0, x1, y1 = box
    w = max(2, round(BORDER_W * k))
    sides = [rgb[y0:y1 + 1, max(0, x0 - w):x0], rgb[y0:y1 + 1, x1 + 1:x1 + 1 + w]]
    need = (y1 - y0)                         # ~one full-height column's worth
    red = sum(_count(s, PILL_UNPAID) for s in sides)
    green = sum(_count(s, PILL_PAID) for s in sides)
    if max(red, green) < need:
        return ""
    return "opened" if green > red else "unopened"


def _attach_footers(rgb, layout: Layout, found, pane, turns: list[Turn]) -> list[Turn]:
    """Give each bubble its footer; turn a footer with no bubble into a media turn."""
    from dataclasses import replace
    rx, ry, rw, rh = layout.region
    k = layout.scale
    mid = rx + rw / 2
    pad = BUCKET_PAD * k
    loose = [((cx, cy), t) for (cx, cy), t in pane
             if not any(b[0] - pad <= cx <= b[2] + pad and b[1] - pad <= cy <= b[3] + pad
                        for b, _w in found)]
    rows: list[list] = []                    # [side, cy, [(cx, text)]]
    for (cx, cy), t in sorted(loose, key=lambda p: p[0][1]):
        side = "fan" if cx < mid else "model"
        for r in rows:
            if r[0] == side and abs(r[1] - cy) <= ROW_TOL * k:
                r[2].append((cx, t))
                break
        else:
            rows.append([side, cy, [(cx, t)]])

    out, extra = list(turns), []
    for side, cy, parts in rows:
        f = parse_footer(" ".join(t.strip() for _cx, t in sorted(parts)))
        if not f:
            continue
        col = _footer_colours(rgb, layout, side, cy)
        if "paid" not in f and "paid" in col and f.get("price"):
            f["paid"] = col["paid"]
        if col.get("liked"):
            f["liked"] = True
        best = None
        for i, (b, who) in enumerate(found):
            dy = cy - b[3]
            if who == side and FOOTER_DY[0] * k <= dy <= FOOTER_DY[1] * k \
                    and (best is None or dy < best[1]):
                best = (i, dy)
        if best is not None:
            out[best[0]] = replace(out[best[0]], **f)
        else:
            # Media with no caption. Its top is unknown; place it just above its
            # footer, and call it partial if the footer is too close to the top
            # for the media to be fully in view.
            x0, x1 = (int(mid), rx + rw) if side == "model" else (rx, int(mid))
            top = int(cy - 20 * k)
            extra.append(Turn(who=side, text="", box=(x0, top, x1, int(cy - 15 * k)),
                              partial=(cy - ry) < 60 * k, **f))
    return sorted(out + extra, key=lambda t: t.box[1])


# ------------------------------------------------------------------ the read --
def read_turns(rgb: np.ndarray, layout: Layout | None = None,
               footers: bool = False) -> list[Turn]:
    """Every visible message in the scroll area, top-to-bottom, attributed.

    footers=True also reads the line under each bubble (time, chatter, PPV pill,
    heart) and recovers caption-less media from it. It costs no extra OCR.
    """
    layout = layout or find_layout(rgb)
    if layout is None:
        raise A.WindowNotReady("could not find the message pane — is a conversation "
                               "open in Infloww Messages (not the Inbox page)?")
    region, k = layout.region, layout.scale
    bucket_pad, row_tol = BUCKET_PAD * k, ROW_TOL * k
    found = ([(b, "fan") for b in A.find_fan_bubbles(rgb, region, layout.fan_xmin,
                                                      layout.fan_x0max)]
             + [(b, "model") for b in A.find_model_bubbles(rgb, region, layout.model_xmax)])
    found.sort(key=lambda p: p[0][1])            # by bubble top = reading order
    if not found:
        return []

    rx, ry, rw, rh = region
    pane = A.ocr_read(rgb, (rx, ry, rx + rw, ry + rh))

    turns = []
    for box, who in found:
        x0, y0, x1, y1 = box
        bg = FAN_BG if who == "fan" else MODEL_BG
        sub = rgb[y0:y1 + 1, x0:x1 + 1]
        inside = [((cx, cy), t) for (cx, cy), t in pane
                  if x0 - bucket_pad <= cx <= x1 + bucket_pad
                  and y0 - bucket_pad <= cy <= y1 + bucket_pad]

        lines, repaired = [], 0
        for (by0, by1) in text_bands(sub):
            # Crop to the ink, not to the bubble — see ink_extent().
            ix0, ix1 = ink_extent(sub[by0:by1])
            band = sub[by0:by1, ix0:ix1]
            mid = y0 + (by0 + by1) / 2
            hits = [t for (cx, cy), t in inside if abs(cy - mid) <= row_tol]
            wide = band.shape[0] and band.shape[1] / band.shape[0] > MAX_REC_ASPECT
            paned = " ".join(h.strip() for h in hits if h.strip())
            if paned and not wide:
                lines.append(paned)
                continue
            # The pane pass missed this line, or the line is wide enough that
            # what came back may be a truncated head. Read it again in chunks and
            # KEEP THE LONGER of the two.
            #
            # Longer-wins is the right tiebreak because the failure it guards
            # against only ever removes characters: the recogniser drops a tail,
            # it does not invent one. And it has to be a tiebreak rather than a
            # straight override, because the chunked read is very slightly worse
            # at spacing than one clean read — so on a line the pane pass got
            # right, blindly taking the repair costs a space or two for nothing.
            got = read_band(band, bg)
            if len(got) > len(paned):
                repaired += 1
                lines.append(got)
            elif paned:
                lines.append(paned)

        body, quote = tidy(" ".join(l for l in lines if l))
        turns.append(Turn(who=who, text=body, box=box,
                          partial=(y0 - ry) <= CLIP_TOL * k,
                          repaired=repaired,
                          cut=(ry + rh - 1 - y1) <= CLIP_TOL * k,
                          reply_to=quote,
                          ppv_border=ppv_border(rgb, box, k) if who == "model" else ""))
    if footers:
        turns = _attach_footers(rgb, layout, found, pane, turns)
    return turns


# ------------------------------------------------------------- the fan name --
# The conversation header (UI-ELEMENT-MAP.md §4): back arrow, then the fan's name
# at x ~452 / y ~99 with an edit pencil after it, "Available now" under it at
# y ~121, the divider at 132. Offsets are from the pane's left edge and from that
# divider, at scale 1, so they follow the window like the pane does.
NAME_DX0 = 40               # past the back arrow (it ends ~37px into the pane)
NAME_DX1 = 420              # well before "Open in new tab"; a long name still fits
NAME_DY0 = 50               # band top, above the divider: just under the header top
NAME_DY1 = 21               # band bottom: above the "Available now" line
# Pieces of one name are a space apart; the pencil sits ~8px after it and the
# icons further. A gap wider than this ends the name.
NAME_GAP = 14
NAME_INK = 200              # the name is #ffffff; the pencil #9a9a9a, the arrow #d9d9d9
# What the pencil and other glyphs tend to read as, hanging off the end.
_NAME_JUNK = re.compile(r"[\s/\\|<>()\[\]{}_~=+*#^`'\".,:;!?-]+$")


def read_fan_name(rgb: np.ndarray, layout: Layout | None = None) -> str:
    """The open conversation's fan name, from the header. "" when unreadable.

    Read in its own OCR call on a band padded so the text touches no edge (the
    detector returns nothing for text against the crop edge — see the module
    docstring), then the first run of boxes from the left is the name.
    """
    layout = layout or find_layout(rgb)
    if layout is None:
        return ""
    x, y, w, _h = layout.region
    k = layout.scale
    div = y - 2
    x0, x1 = x + round(NAME_DX0 * k), min(x + w - 1, x + round(NAME_DX1 * k))
    y0, y1 = max(0, div - round(NAME_DY0 * k)), div - round(NAME_DY1 * k)
    band = rgb[y0:y1, x0:x1]
    if band.size == 0:
        return ""
    bg = band[0, 0]                             # the header's own background
    # The name is white; the pencil after it is #9a9a9a and OCRs INTO the name's
    # box ("Al 0" — one box, so no box-level filter can drop it). Keep only
    # near-white ink. Measured on the clone: "Steven Martin 0" -> "Steven Martin".
    band = band.copy()
    band[band.min(2) < NAME_INK] = bg
    pad = round(CHUNK_PAD * k)
    canvas = np.empty((band.shape[0] + 2 * pad, band.shape[1] + 2 * pad, 3), np.uint8)
    canvas[:, :] = bg
    canvas[pad:pad + band.shape[0], pad:pad + band.shape[1]] = band
    try:
        res, _ = A.ocr_engine()(canvas)
    except Exception:
        return ""
    boxes = sorted(((min(p[0] for p in pts), max(p[0] for p in pts), t.strip())
                    for pts, t, _s in (res or []) if t.strip()), key=lambda b: b[0])
    if not boxes:
        return ""
    name, right = [boxes[0][2]], boxes[0][1]
    for bx0, bx1, t in boxes[1:]:
        if bx0 - right > NAME_GAP * k:
            break
        name.append(t)
        right = bx1
    return _NAME_JUNK.sub("", " ".join(name)).strip()


# --------------------------------------------------------------- fan panel --
# The right column (UI-ELEMENT-MAP.md §5): "Fan insights" cards — Spending
# behavior, Organization metrics, Subscription, Profile — or the Sales / Notes
# tab when one of those is picked at the bottom. It is what a chatter reads
# before answering: spend, last purchase, sub length, notes.
#
# Read as ROWS, raw, with positions: card order moves when a card is collapsed,
# and the Sales / Notes layouts are not measured yet, so the raw rows are the
# record and `fields` is only a best-effort parse of the Insights labels.
PANEL_LABELS = ("Total spend", "Last spend", "PPV", "Tip", "Highest spend",
                "Spending power", "Chargeback risk", "Status", "Cost", "Duration",
                "Auto-renewal", "Nickname", "Birthday", "Local time", "Source", "Salary")
_LABEL_KEY = {re.sub(r"[^a-z]", "", l.lower()): l for l in PANEL_LABELS}
# Card headings: never a field's value ("Highest spend" with no value took
# "Organization metrics" from the row under it).
_CARDS = ("fan insights", "spending behavior", "organization metrics", "subscription", "profile")
# Labels OCR'd in one box with their value ("Auto-renewal off"). Not PPV/Tip:
# "PPV | $59.44" is a VALUE under "Last spend".
_SPLIT_LABELS = sorted((l for l in PANEL_LABELS if l not in ("PPV", "Tip")), key=len, reverse=True)


def _split_label(part: list) -> list[list]:
    x0, x1, t = part
    for l in _SPLIT_LABELS:
        if t.lower().startswith(l.lower()) and len(t) > len(l) + 1:
            return [[x0, x0 + 1, l], [x1 - 1, x1, t[len(l):].strip(" :")]]
    return [part]


def panel_box(rgb: np.ndarray, layout: Layout) -> tuple[int, int, int, int]:
    """(x0, y0, x1, y1) of the right column, from the pane's right divider to
    the window edge, from the conversation header's top to the bottom."""
    x, y, w, _h = layout.region
    H, W = rgb.shape[:2]
    return (x + w + 2, max(0, y - 2 - round(50 * layout.scale)), W - 3, H - 4)


def panel_thumb(rgb: np.ndarray, layout: Layout) -> np.ndarray:
    return _box_thumb(rgb, panel_box(rgb, layout))


def header_thumb(rgb: np.ndarray, layout: Layout) -> np.ndarray:
    """The conversation header (the fan's name). Infloww updates it LATER than
    the messages when you switch fans, so a read must wait for it too."""
    x, y, w, _h = layout.region
    return _box_thumb(rgb, (x, max(0, y - 2 - round(50 * layout.scale)), x + w, y - 2))


def _box_thumb(rgb: np.ndarray, box) -> np.ndarray:
    x0, y0, x1, y1 = box
    g = rgb[y0:y1, x0:x1].mean(2)
    r, c = THUMB[0], 8
    if g.shape[0] < r or g.shape[1] < c:
        return np.zeros((r, c), np.float32)
    g = g[:g.shape[0] - g.shape[0] % r, :g.shape[1] - g.shape[1] % c]
    return g.reshape(r, g.shape[0] // r, c, g.shape[1] // c).mean((1, 3)).astype(np.float32)


def _panel_rows(rgb, box, k: float) -> list[list]:
    """[[y, [[x0, x1, text], ...]], ...] in scale-1 panel coordinates."""
    x0, y0, x1, y1 = box
    crop = rgb[y0:y1, x0:x1]
    if crop.size == 0:
        return []
    up = A._auto_upscale(crop)
    pad = 20
    bg = crop[2, 2]
    canvas = np.empty((crop.shape[0] + 2 * pad, crop.shape[1] + 2 * pad, 3), np.uint8)
    canvas[:, :] = bg
    canvas[pad:pad + crop.shape[0], pad:pad + crop.shape[1]] = crop
    if up > 1:
        from PIL import Image
        canvas = np.asarray(Image.fromarray(canvas).resize(
            (canvas.shape[1] * up, canvas.shape[0] * up), Image.LANCZOS))
    try:
        res, _ = A.ocr_engine()(canvas)
    except Exception:
        return []
    boxes = []
    for pts, t, _s in (res or []):
        if not t.strip():
            continue
        xs = [p[0] / up - pad for p in pts]
        ys = [p[1] / up - pad for p in pts]
        boxes.append((sum(ys) / len(ys) / k, min(xs) / k, max(xs) / k, t.strip()))
    rows: list[list] = []
    for cy, bx0, bx1, t in sorted(boxes):
        if rows and abs(rows[-1][0] - cy) <= 8:
            rows[-1][1].append([round(bx0), round(bx1), t])
        else:
            rows.append([cy, [[round(bx0), round(bx1), t]]])
    for r in rows:
        r[0] = round(r[0])
        r[1] = sorted(q for p in r[1] for q in _split_label(p))
    return rows


def _label(text: str) -> str:
    return _LABEL_KEY.get(re.sub(r"[^a-z]", "", text.lower()), "")


def _panel_fields(rows: list[list], width: float) -> dict:
    """Label -> value for the Insights labels. A label's value is the rest of its
    row ("Status  Active"), or, when the row has nothing else, what sits under it
    in its column ("Total spend" over "$93.66"). Lines under a value that belong
    to no label ("$46.83 Avg" under "$93.66 Total") are appended to it."""
    fields: dict[str, str] = {}
    last = ""
    for i, (_y, parts) in enumerate(rows):
        labels = [(p, _label(p[2])) for p in parts]
        if any(l for _p, l in labels):
            last = ""
            for n, (p, l) in enumerate(labels):
                if not l:
                    continue
                rest = [q[2] for q, ql in labels[n + 1:] if not ql]
                # Stop at the next label on the row: "Total spend | Last spend".
                nxt = next((m for m in range(n + 1, len(labels)) if labels[m][1]), None)
                if nxt is not None:
                    rest = [q[2] for q, _ in labels[n + 1:nxt]]
                if rest:
                    fields[l] = " ".join(rest)
                    last = l
                elif i + 1 < len(rows):
                    # The value is below, in the label's column.
                    lo = p[0] - 10
                    hi = labels[nxt][0][0] - 10 if nxt is not None else width
                    def value(q):
                        return lo <= q[0] < hi and not _label(q[2]) \
                            and not q[2].lower().startswith(_CARDS)
                    below = [q[2] for q in rows[i + 1][1] if value(q)]
                    for j in (i + 2,):           # a second line ("PPV | $59.44")
                        if below and j < len(rows) and not any(_label(q[2]) for q in rows[j][1]):
                            below += [q[2] for q in rows[j][1] if value(q)]
                    if below:
                        fields[l] = " ".join(below)
        elif last and all(p[0] > width * 0.4 for p in parts):
            fields[last] += " " + " ".join(p[2] for p in parts)
    return fields


def read_panel(rgb: np.ndarray, layout: Layout | None = None) -> dict:
    """The fan panel on the right: {"tab", "rows", "fields"}. {} if unreadable."""
    layout = layout or find_layout(rgb)
    if layout is None:
        return {}
    box = panel_box(rgb, layout)
    rows = _panel_rows(rgb, box, layout.scale)
    if not rows:
        return {}
    text = " ".join(p[2] for _y, ps in rows for p in ps).lower()
    if "insights" in text and ("spend" in text or "subscription" in text):
        tab = "insights"
    elif "notes" in rows[0][1][0][2].lower() or "note" in text[:40]:
        tab = "notes"
    elif "sales" in text[:40] or "purchase" in text:
        tab = "sales"
    else:
        tab = "?"
    width = (box[2] - box[0]) / layout.scale
    fields = _panel_fields(rows, width) if tab == "insights" else {}
    return {"tab": tab, "rows": rows, "fields": {k: _tidy_value(v) for k, v in fields.items()}}


def _tidy_value(v: str) -> str:
    """The panel's OCR slips, seen on Whole UI.png: "$o" for "$0", and the "|"
    in "PPV | $59.44" read as I or 1 ("PPVI$59.44", "PPV 1 Jul 15")."""
    v = re.sub(r"\$\s?[oO](?![a-z])", "$0", v)
    v = re.sub(r"^[sS$][oO0e](?=\s+Total\b)", "$0", v)          # "$Ø Total" read as "so"/"se"
    v = re.sub(r"^A\s+(?=(?:Low|Medium|High)\b)", "", v)     # the ⚠ icon in "⚠ Low"
    # A dropped decimal point (live, 2026-10-22: "$33795", "$5714k"). Infloww
    # writes cents, and "k" from $1000 up, so 4+ bare digits had a point.
    v = re.sub(r"\$(\d{3,})k\b", lambda m: f"${m[1][:-2]}.{m[1][-2:]}k", v)
    v = re.sub(r"\$(\d{4,})(?![\d.,k])", lambda m: f"${m[1][:-2]}.{m[1][-2:]}", v)
    v = re.sub(r"\b(PPV|Tip|Message|Sub\w*)\s*[I1l|]\s*(?=\$|[A-Z][a-z]{2}\b)", r"\1 | ", v)
    return " ".join(v.split())


def read_conversation(force: bool = False):
    """Capture Infloww and read the open conversation.

    Returns (turns, note) — `note` is None when the read is usable, or a string
    saying why it is not. The caller must not draft on a note.
    """
    turns = read_turns(capture(force=force))
    if not turns:
        return turns, "no message bubbles on screen — is a conversation open?"
    if not any(t.who == "fan" for t in turns):
        return turns, ("no fan message in view — only our own run is on screen, "
                       "so there is nothing to reply to. Scroll up.")
    return turns, None


def read_image(path: str) -> list[Turn]:
    """Read a saved capture. The offline half of the same code path — this is how
    the reader is regression-tested without Infloww open, and how a misread is
    reproduced after the fact from a dumped frame."""
    from PIL import Image
    return read_turns(np.asarray(Image.open(path).convert("RGB")))


def as_prompt_text(turns: list[Turn]) -> str:
    """The transcript exactly as the model will receive it."""
    return "\n".join(t.render() for t in turns)


if __name__ == "__main__":
    # Chat text is full of emoji and the Windows console is cp1252 by default, so
    # a bare print() on a real conversation dies on the first heart. Only the CLI
    # needs this — the library returns str and never prints.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    A.set_dpi_aware()
    if "--image" in sys.argv:
        img = sys.argv[sys.argv.index("--image") + 1]
        turns, note = read_image(img), None
        print(f"[offline] {img}")
    else:
        turns, note = read_conversation(force="--force" in sys.argv)

    print(f"--- {len(turns)} bubble(s) ---")
    for t in turns:
        flags = []
        if t.partial:
            flags.append("PARTIAL")
        if t.is_media:
            flags.append("MEDIA")
        if t.repaired:
            flags.append(f"repaired {t.repaired}")
        tag = ("  [" + ", ".join(flags) + "]") if flags else ""
        print(f"{t.who:>5} {str(t.box):<26} {t.text[:88]!r}{tag}")
    print("\n--- as the model would see it ---")
    print(as_prompt_text(turns))
    if note:
        print(f"\n!! {note}")
