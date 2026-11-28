"""
ocr/reader.py — the Infloww reader: one line of Infloww text in, text + confidence out.

Trained only on Infloww's own font and colours (synth.py, train.py), so it does not
guess towards English words the way general OCR does. Runs with onnxruntime on the
CPU; no torch, no GPU needed.

    read_line(crop_rgb)                  -> Read(text, conf)
    header_line(rgb, header_region)      -> the fan-name line cut out of a header
    list_row_line(rgb, row_box)          -> the "name @handle" line of a list row
    split_header(text)                   -> (note, display)   "$171 Dan(Dan)" -> ("$171 Dan", "Dan")

Labels it was trained on are NFKC-normalised: a fancy 𝓙𝓪𝓶𝓲𝓮 reads as "Jamie", every
run of emoji reads as one ◆, and "…" reads as "...".
"""
from __future__ import annotations

import json
import re
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

MODEL_DIR = Path(__file__).resolve().parent / "model"
H = 32
EMOJI_MARK = "◆"

_lock = threading.Lock()
_sess = None
_chars: list[str] = []


def available() -> bool:
    return (MODEL_DIR / "infloww_rec.onnx").exists()


def _load():
    global _sess, _chars
    with _lock:
        if _sess is None:
            import onnxruntime as ort
            o = ort.SessionOptions()
            o.intra_op_num_threads = 2
            o.log_severity_level = 3
            _sess = ort.InferenceSession(str(MODEL_DIR / "infloww_rec.onnx"), o,
                                         providers=["CPUExecutionProvider"])
            _chars = json.loads((MODEL_DIR / "charset.json").read_text(encoding="utf-8"))
    return _sess


@dataclass
class Read:
    text: str
    conf: float          # 0..1: the WEAKEST letter's certainty — one unsure letter = unsure read

    @property
    def sure(self) -> bool:
        return self.conf >= SURE


SURE = 0.90


def _prep(rgb: np.ndarray) -> np.ndarray:
    im = Image.fromarray(np.ascontiguousarray(rgb)).convert("L")
    w = max(8, round(im.width * H / im.height))
    im = im.resize((w, H), Image.BILINEAR)
    return np.asarray(im, np.float32)[None, None] / 255.0


def read_line(rgb: np.ndarray) -> Read:
    """Read one cropped text line (any size, RGB)."""
    if rgb is None or rgb.size == 0 or rgb.shape[0] < 6 or rgb.shape[1] < 6:
        return Read("", 0.0)
    sess = _load()
    x = _prep(rgb)
    pad = (-x.shape[-1]) % 4
    if pad:
        x = np.pad(x, ((0, 0), (0, 0), (0, 0), (0, pad)))
    logits = sess.run(None, {"x": x})[0][0]                    # T,K
    e = np.exp(logits - logits.max(-1, keepdims=True))
    p = e / e.sum(-1, keepdims=True)
    best = p.argmax(-1)
    out, confs, prev = [], [], 0
    for t, k in enumerate(best):
        if k != prev and k != 0:
            out.append(_chars[k - 1])
            confs.append(float(p[t, k]))
        prev = k
    return Read("".join(out), min(confs) if confs else 0.0)


# ---------------------------------------------------------------- cropping --
ROW_CSS = 34                 # the practice pictures were cut 34 CSS px tall


def _band(rgb: np.ndarray, y_mid: float, scale: float) -> tuple[int, int]:
    half = ROW_CSS * scale / 2
    return max(0, round(y_mid - half)), min(rgb.shape[0], round(y_mid + half))


def _ink_runs(mask_rows: np.ndarray, gap: int) -> list[tuple[int, int]]:
    ys = np.flatnonzero(mask_rows)
    if not len(ys):
        return []
    runs, s, p = [], ys[0], ys[0]
    for y in ys[1:]:
        if y - p > gap:
            runs.append((s, p))
            s = y
        p = y
    runs.append((s, p))
    return runs


def header_line(rgb: np.ndarray, region, scale: float) -> np.ndarray | None:
    """The fan-name line of a conversation header, cut like a practice picture.

    region = the header (x, y, w, h) in this frame. The name is the top text line;
    the icon row (star, bell, Gallery, Find) is below it. The back arrow on the left
    and the edit pencil on the right are LEFT OUT: the name is #fff/#e6e6e6, both
    icons are dimmer grey, so the line's extent is taken from bright ink only."""
    x, y, w, h = [int(v) for v in region]
    hdr = rgb[y:y + h, x:x + w].astype(np.int16)
    if hdr.size == 0:
        return None
    # White / light-grey ink only: EVERY channel high. The blue "Open in new tab"
    # link has a bright blue channel but a dark red one, so it doesn't count.
    # The cut-off is RELATIVE to the brightest text: a recording dims and smears
    # everything, so the #e6e6e6 "(display)" part can fall under any fixed number,
    # while the #9a9a9a pencil stays well under 78% of the white note.
    lo = hdr[: int(h * 0.62)].min(2)
    peak = np.percentile(lo, 99.5) if lo.size else 255
    bright = hdr.min(2) >= max(120, 0.78 * peak)
    top = bright[: int(h * 0.62)]
    runs = _ink_runs(top.any(1), gap=max(2, round(3 * scale)))
    if not runs:
        return None
    # The name is the FIRST text line of the header (the icon row is below it).
    y0, y1 = runs[0]
    colmask = bright[y0:y1 + 1].any(0)
    cols = np.flatnonzero(colmask)
    if not len(cols):
        return None
    # A main window has a back arrow left of the name; a fan window doesn't. The
    # arrow is a short run of ink inside the first ~45 CSS px with a clear gap
    # after it — drop it only when it is actually there.
    # Split at gaps wider than a letter gap (the pencil sits ~7 CSS px after the
    # name; letters are 1-2 px apart, spaces ~4).
    pieces = _ink_runs(colmask, gap=max(2, round(5 * scale)))
    # In a main window the arrow sits ~19-35 CSS px in and the name starts at ~49;
    # in a fan window the name itself starts ~10 px in. So it's the arrow only if
    # what follows starts where a main window's name starts.
    if (len(pieces) > 1 and pieces[0][0] >= 12 * scale and pieces[0][1] < 42 * scale
            and pieces[1][0] >= 44 * scale):
        pieces = pieces[1:]
    # The name ends at the first wide gap: the refresh / menu icons at the far
    # right are white too, but a name never has 30 CSS px of nothing inside it.
    keep = [pieces[0]]
    for (a0, a1), (b0_, _b1) in zip(pieces, pieces[1:]):
        if b0_ - a1 > 30 * scale:
            break
        keep.append((b0_, _b1))
    # The edit pencil right after the name: a small piece clearly dimmer than the
    # word before it. On video it dims along with the text, so it can pass the
    # brightness cut-off; its RELATIVE dimness gives it away (#9a vs #e6/#ff).
    if len(keep) > 1:
        (p0, p1), (q0, q1) = keep[-2], keep[-1]
        band_lo = lo[y0:y1 + 1]
        if (q1 - q0 < 16 * scale
                and band_lo[:, q0:q1 + 1].max() < 0.8 * band_lo[:, p0:p1 + 1].max()):
            keep.pop()
    end = keep[-1][1]
    cols = cols[(cols >= pieces[0][0]) & (cols <= end)]
    b0, b1 = _band(rgb, (y0 + y1) / 2 + y, scale)
    pad_l, pad_r = round(6 * scale), round(8 * scale)
    crop = rgb[b0:b1, max(x, x + cols[0] - pad_l):x + cols[-1] + pad_r].copy()
    # The icon row starts right under the name; its tops reach into the band.
    # Paint everything below the name's own ink with the header background, so
    # the line looks like the practice pictures (one line, nothing else).
    cut = (y + y1 + round(3 * scale)) - b0
    if 0 < cut < crop.shape[0]:
        crop[cut:] = np.median(hdr[h - 2:h].reshape(-1, 3), 0).astype(np.uint8)
    if not _looks_like_header(crop, scale):
        return None
    return crop


HEADER_BG_MAX = 34      # the header is #151515 (21); a message bubble is #262626/#353535
NAME_PEAK_MIN = 170     # the name is white; timestamps and previews are #9a9a9a grey
NAME_MIN_W = 18         # CSS px: narrower than any name = a lone icon or a scrap
COLOUR_MAX = 0.12       # share of strongly coloured pixels above which it's a pill, not a name


def _looks_like_header(crop: np.ndarray, scale: float) -> bool:
    """Is this really a fan name on the header? On video, a pop-up or a mis-found
    layout hands the cutter a chat line, a timestamp or the lone edit pencil — those
    became fake fans ("now be"). Refusing them here means no name, never a wrong one."""
    if crop is None or crop.size == 0 or crop.shape[1] < NAME_MIN_W * scale:
        return False
    g = crop.min(2)
    edge = np.concatenate([g[0], g[-1], g[:, 0], g[:, -1]])
    if np.median(edge) > HEADER_BG_MAX:
        return False
    # A name is white/grey ink; a "$200.00 not paid" price pill is a block of red
    # (or teal). Emoji in a name are small; a pill covers much of the line.
    c = crop.astype(np.int16)
    colourful = (c.max(2) - c.min(2)) > 80
    if colourful.mean() > COLOUR_MAX:
        return False
    return np.percentile(g, 99.5) >= NAME_PEAK_MIN


def list_row_line(rgb: np.ndarray, row_box, scale: float) -> np.ndarray | None:
    """The 'name @handle' line of one chat-list row (top text line, right of the
    avatar)."""
    x, y, w, h = [int(v) for v in row_box]
    x0 = x + round(64 * scale)
    row = rgb[y:y + round(34 * scale), x0:x + w].astype(np.int16)
    if row.size == 0:
        return None
    bg = np.median(row.reshape(-1, 3), 0)
    ink = np.abs(row - bg).max(2) > 50
    # Only the FIRST text line: the marks line (🔥, ❌) sits right under the name,
    # and centring on both put the name at the top edge of the cut.
    runs = _ink_runs(ink.any(1), gap=max(2, round(2 * scale)))
    if not runs:
        return None
    r0, r1 = runs[0]
    ink = ink[r0:r1 + 1]
    cols = np.flatnonzero(ink.any(0))
    if not len(cols):
        return None
    b0, b1 = _band(rgb, y + (r0 + r1) / 2, scale)
    crop = rgb[b0:b1, max(x0, x0 + cols[0] - round(6 * scale)):x0 + cols[-1] + round(8 * scale)].copy()
    # Blank anything outside the name's own line (the marks line's tops below it,
    # the row above's tails), the way a practice picture has nothing else in it.
    top = (y + r0 - round(3 * scale)) - b0
    bot = (y + r1 + round(3 * scale)) - b0
    fill = bg.astype(np.uint8)
    if top > 0:
        crop[:top] = fill
    if 0 < bot < crop.shape[0]:
        crop[bot:] = fill
    return crop


# ------------------------------------------------------------------ parsing --
def clean_header(text: str) -> str:
    """A header read without anything the line cutter let through after the name:
    the edit pencil on video reads as a stray symbol. A name ends in a letter,
    digit, ')' or an emoji mark."""
    return re.sub(r"[^\w)◆]+$", "", text.strip()).strip()


def split_header(text: str) -> tuple[str, str]:
    """'Sam | big tipper(Sam Smith)' -> ('Sam | big tipper', 'Sam Smith').
    The note is the agency's (Silly: keep it with the fan); the display name is the
    fan's own. No '(' = the header is the display name alone."""
    m = re.match(r"^(.*)\(([^()]*)\)?\s*$", text)
    if not m:
        return "", text.strip()
    return m.group(1).strip(), m.group(2).strip()


def name_key(s: str) -> str:
    """Compare names without emoji, spaces, case or punctuation."""
    s = s.replace(EMOJI_MARK, "").lower()
    return re.sub(r"[^a-z0-9]", "", s)
