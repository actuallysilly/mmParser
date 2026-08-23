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

# Every coordinate in UI-ELEMENT-MAP.md is window-relative and was measured at
# this size. A different size does not read a bit worse — it reads the wrong
# rectangles entirely, so it is refused rather than warned about.
REF_SIZE = (A.REF_W, A.REF_H)

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

    @property
    def is_media(self) -> bool:
        return not self.text

    def render(self) -> str:
        """One line, the way the model will be shown it."""
        body = self.text or "[media]"
        if self.partial:
            body = "..." + body
        return f"{self.who}: {body}"


# ------------------------------------------------------------------ capture --
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
    h, w = rgb.shape[:2]
    if not force and (w, h) != REF_SIZE:
        raise A.WindowNotReady(
            f"window is {w}x{h} but the geometry was measured at "
            f"{REF_SIZE[0]}x{REF_SIZE[1]}. Every coordinate would be wrong. "
            f"Maximise it, or pass --force if you have re-measured.")
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


# ------------------------------------------------------------------ the read --
def read_turns(rgb: np.ndarray, region=A.R_MESSAGES) -> list[Turn]:
    """Every visible message in the scroll area, top-to-bottom, attributed."""
    found = ([(b, "fan") for b in A.find_fan_bubbles(rgb, region)]
             + [(b, "model") for b in A.find_model_bubbles(rgb, region)])
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
                  if x0 - BUCKET_PAD <= cx <= x1 + BUCKET_PAD
                  and y0 - BUCKET_PAD <= cy <= y1 + BUCKET_PAD]

        lines, repaired = [], 0
        for (by0, by1) in text_bands(sub):
            # Crop to the ink, not to the bubble — see ink_extent().
            ix0, ix1 = ink_extent(sub[by0:by1])
            band = sub[by0:by1, ix0:ix1]
            mid = y0 + (by0 + by1) / 2
            hits = [t for (cx, cy), t in inside if abs(cy - mid) <= ROW_TOL]
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

        turns.append(Turn(who=who,
                          text=" ".join(l for l in lines if l).strip(),
                          box=box,
                          partial=(y0 - ry) <= CLIP_TOL,
                          repaired=repaired))
    return turns


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
