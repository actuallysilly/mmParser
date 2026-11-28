"""
llm/fanid.py — who is this fan? Read his @handle, the one name chatters can't edit.

lore_gatherer step 1 (docs/proposals/lore-gatherer.md, decisions 7, 29, 30). The
header name is chatter-rewritten ("mike | likes feet dont pitch him"), so fan
files are keyed on the @handle instead. Two places show it:

    list_selection()  the highlighted row of the chat list in the WORK window:
                      "mike | likes feet dont pitc... @u123..." — the handle
                      is often cut off, so this returns a PREFIX + truncated flag.
    name_modal()      the modal that opens when the fan's name is clicked: the
                      full handle on the line under the name, plus the tag line
                      ("Exc till December • silly reach out • ..."). Silly opens
                      it by hand; the recorder never clicks in the work window.

Pixels only (memory: infloww-pixels-only). Measured 2026-11-24 on the live
3441x1381 window (tools/ui-research/work_window_list.png, name_modal.png):

    chat list background  #151515 (21)      selected row  #353535 (53/54), 132px tall
    modal box             #2f2f2f (47)      overlay under a modal  ~#060606 (6)

    python fanid.py --test     reads both reference captures
    python fanid.py --live     reads every Infloww Messages window now (no input)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import transcript as T                            # noqa: E402

LIST_BG = 21
ROW_SEL = 53
MODAL_BG = 47
OVERLAY_MAX = 10
TOL = 3
ROW_MIN_H = 60          # a selected row is 132px at this scale; at scale 1 ~77
EDGE_FRAC = 0.12        # handle ending in the last 12% of the list width = cut off
MODAL_MIN = 300         # the modal is ~880x830px; anything smaller is not it

# OCR of the handle: "@u12345678", "@examplefan", cut off as "@u123..." / "@u123…".
_HANDLE = re.compile(r"@\s?([A-Za-z0-9_.\-]{2,})(\s*(?:\.{2,}|…))?")


def _ocr_lines(img: np.ndarray, bg) -> list[tuple[float, float, str]]:
    """OCR a crop padded on every side; returns (y_centre, x_left, text) per box,
    top-to-bottom then left-to-right."""
    pad = T.CHUNK_PAD
    canvas = np.empty((img.shape[0] + 2 * pad, img.shape[1] + 2 * pad, 3), np.uint8)
    canvas[:, :] = np.array(bg, np.uint8)
    canvas[pad:pad + img.shape[0], pad:pad + img.shape[1]] = img
    try:
        res, _ = T.A.ocr_engine()(canvas)
    except Exception:
        return []
    out = []
    for pts, t, _s in res or []:
        if t.strip():
            ys = [p[1] for p in pts]
            out.append(((min(ys) + max(ys)) / 2 - pad, min(p[0] for p in pts) - pad, t.strip(),
                        max(p[0] for p in pts) - pad))
    return sorted(out, key=lambda b: (round(b[0] / 12), b[1]))


def _group_lines(boxes, tol=12) -> list[str]:
    """Boxes on the same row joined left-to-right, one string per text line."""
    lines: list[list] = []
    for y, x, t, *_ in sorted(boxes, key=lambda b: b[0]):
        if lines and abs(lines[-1][0] - y) <= tol:
            lines[-1][1].append((x, t))
        else:
            lines.append([y, [(x, t)]])
    return [" ".join(t for _x, t in sorted(parts)) for _y, parts in lines]


def parse_handle(text: str) -> tuple[str, bool] | None:
    """('u12345678', truncated) from an OCR'd line, or None."""
    m = _HANDLE.search(text)
    if not m:
        return None
    return m.group(1).rstrip("."), bool(m.group(2)) or text.rstrip().endswith(("...", "…"))


def list_selection(rgb: np.ndarray, layout: T.Layout | None = None) -> dict | None:
    """The highlighted chat-list row: {'name', 'handle', 'truncated', 'raw'}.

    None when there is no chat list (an "Open in new tab" window) or no row is
    highlighted (it is scrolled out of view)."""
    layout = layout or T.find_layout(rgb)
    if layout is None:
        return None
    x_pane = layout.region[0]
    if x_pane < 200:                    # no list column: a harvest window
        return None
    # Probe a column near the list's left edge, clear of avatars and text.
    col = rgb[:, max(2, round(6 * layout.scale)), :].astype(int).mean(1)
    sel = np.abs(col - ROW_SEL) <= TOL
    best, s = None, None
    for y, v in enumerate(list(sel) + [False]):
        if v and s is None:
            s = y
        if not v and s is not None:
            if y - s >= ROW_MIN_H * layout.scale and (best is None or y - s > best[1] - best[0]):
                best = (s, y)
            s = None
    if best is None:
        return None
    y0, y1 = best
    row = rgb[y0:y1, :x_pane - 2]
    boxes = _ocr_lines(row, (ROW_SEL,) * 3)
    raw = _group_lines(boxes)
    # OCR often drops the "..." of a cut-off handle, so judge by position too:
    # a handle whose box runs into the list's right edge was cut there.
    at = [b for b in boxes if "@" in b[2]]
    edge = bool(at) and max(b[3] for b in at) >= row.shape[1] * (1 - EDGE_FRAC)
    for line in raw:
        h = parse_handle(line)
        if h:
            name = line[:line.find("@")].strip()
            return {"name": name.rstrip(". …"), "handle": h[0], "truncated": h[1] or edge,
                    "raw": raw, "row": [y0, y1]}
    return {"name": raw[0] if raw else "", "handle": "", "truncated": True,
            "raw": raw, "row": [y0, y1]}


def _run_through(mask: np.ndarray, at: int, bridge: int = 60) -> tuple[int, int]:
    """[start, end) of the True run covering `at`, jumping gaps up to `bridge`
    long (text and divider lines inside the box). (at, at) if `at` is False."""
    idx = np.where(mask)[0]
    if not len(idx):
        return at, at
    # Split the True positions into runs wherever the gap exceeds `bridge`.
    cuts = np.where(np.diff(idx) > bridge)[0]
    starts = np.r_[idx[0], idx[cuts + 1]]
    ends = np.r_[idx[cuts], idx[-1]] + 1
    for s, e in zip(starts, ends):
        if s <= at < e:
            return int(s), int(e)
    return at, at


def _modal_box(rgb: np.ndarray) -> tuple[int, int, int, int] | None:
    """(x0, y0, x1, y1) of an open fan modal, or None."""
    g = rgb.astype(int).mean(2)
    h, w = g.shape
    box = np.abs(g - MODAL_BG) <= TOL
    # The dimmed insights cards on the right are #2f2f2f too, so take only the
    # run through the window's centre, bridging the modal's own text/dividers.
    y0, y1 = _run_through(box[:, w // 2], h // 2)
    x0, x1 = _run_through(box[(y0 + y1) // 2 if y1 > y0 else h // 2], w // 2)
    if y1 - y0 < MODAL_MIN or x1 - x0 < MODAL_MIN:
        return None
    # A real modal sits on the dark overlay: just outside it is near-black.
    left = g[(y0 + y1) // 2, max(0, x0 - 40):max(1, x0 - 10)]
    if left.size == 0 or left.mean() > OVERLAY_MAX:
        return None
    return int(x0), int(y0), int(x1), int(y1)


def name_modal(rgb: np.ndarray) -> dict | None:
    """The open name modal: {'name', 'handle', 'tags', 'raw'}, or None if none is open."""
    b = _modal_box(rgb)
    if b is None:
        return None
    x0, y0, x1, y1 = b
    # Header: name, "custom @handle", then the tag line, above the buttons.
    head = rgb[y0:y0 + round((y1 - y0) * 0.16), x0:x1]
    raw = _group_lines(_ocr_lines(head, (MODAL_BG,) * 3))
    out = {"name": "", "handle": "", "tags": [], "raw": raw, "box": list(b)}
    for i, line in enumerate(raw):
        h = parse_handle(line)
        if h and not out["handle"]:
            out["handle"] = h[0]
            if i > 0:
                out["name"] = raw[i - 1].strip()
            if i + 1 < len(raw):            # the tag line sits right under it
                out["tags"] = parse_tags(raw[i + 1])
    return out


# The separator dot OCRs as "•", "·" or "-"; each tag's red ✕ icon as "X"/"XE",
# and the tool icon as a stray CJK glyph ("然"). Measured on name_modal.png.
_TAG_SEP = re.compile(r"\s+[-•·]\s+|[•·]")
_TAG_ICON = re.compile(r"^(?:(?:XE?|[xX×✕])\s+|[^\x00-\x7f]+\s*)+")


def parse_tags(line: str) -> list[str]:
    out = []
    for part in _TAG_SEP.split(line):
        t = _TAG_ICON.sub("", part.strip()).strip(" .…")
        if len(t) > 1:
            out.append(t)
    return out


# ----------------------------------------------------------------- account --
# The window title says "Infloww Messages - 333" for EVERY account: 333 is the agency's
# fixed tag, not the creator (shiftlog filed everything under "333"). The account is
# the heading at the top of the chat list ("CIN"), just above the conversation
# header's divider line. Only the work window has it.
ACCT_DY = (68, 20)      # the heading's band: this far above the divider, at scale 1.37


def account_tab(rgb: np.ndarray, layout: T.Layout | None = None) -> str:
    """The account in a window with NO chat list (a harvest window): the first
    account tab in the strip at the very top ("CIN"). Infloww opens "Open in new
    tab" windows with just that one account tab."""
    layout = layout or T.find_layout(rgb)
    k = (layout.scale if layout else 1.37) / 1.37
    band = rgb[round(8 * k):round(62 * k), round(80 * k):round(400 * k)]
    if band.size == 0:
        return ""
    boxes = [b for b in _ocr_lines(band, band[0, 0]) if re.search(r"[A-Za-z]", b[2])]
    return min(boxes, key=lambda b: b[1])[2].strip() if boxes else ""


def account_tabs(rgb: np.ndarray, layout: T.Layout | None = None) -> list[str]:
    """Every account tab in the strip at the top ("CIN", "HAIL"). This is the
    allowlist: live 2026-11-24..26 the list heading was also read as a fan's
    name or "Search", which made ~50 fake account folders. Read in 600px chunks
    (wider than ~700px and the recogniser returns nothing); badge digits dropped."""
    layout = layout or T.find_layout(rgb)
    k = (layout.scale if layout else 1.37) / 1.37
    y0, y1 = round(8 * k), round(62 * k)
    out: list[str] = []
    for x0 in range(80, 1720, 520):
        band = rgb[y0:y1, round(x0 * k):min(rgb.shape[1] // 2, round((x0 + 600) * k))]
        if band.size == 0:
            break
        for b in _ocr_lines(band, band[0, 0]):
            t = b[2].strip()
            if len(re.findall(r"[A-Za-z]", t)) >= 2 and t not in out:
                out.append(t)
    return out


def acct_key(s: str) -> str:
    """Compare account names the way OCR mixes them up: case, and I vs l."""
    return re.sub(r"[^a-z0-9]", "", s.lower().replace("i", "l"))


def account(rgb: np.ndarray, layout: T.Layout | None = None) -> str:
    layout = layout or T.find_layout(rgb)
    if layout is not None and layout.region[0] < 200:
        return account_tab(rgb, layout)
    if layout is None:
        return ""
    k = layout.scale / 1.37
    div = layout.region[1] - 2
    band = rgb[max(0, div - round(ACCT_DY[0] * k)):div - round(ACCT_DY[1] * k),
               :layout.region[0] // 2]
    if band.size == 0:
        return ""
    boxes = [b for b in _ocr_lines(band, band[0, 0]) if b[2].strip()]
    return min(boxes, key=lambda b: b[1])[2].strip() if boxes else ""


# --------------------------------------------------------------- separators --
# Between two days the pane draws a 2px #2b2b2b/#1f1f1f line across its whole
# width with the date in the middle ("Nov 21"). A fan bubble's #262626 fill is
# close in colour, but a bubble never covers BOTH the left and right quarters.
# The line is 1px #353535 (53); at a fractional position it smears over two rows
# (43 + 31). Her bubbles are #353535 too, but only ever on the right.
SEP_GREY = (26, 60)
SEP_FILL = 0.9


def day_separators(rgb: np.ndarray, layout: T.Layout) -> list[tuple[int, str]]:
    """[(y, 'Nov 21'), ...] top to bottom, in window pixels."""
    x, y, w, h = layout.region
    g = rgb[y:y + h, x:x + w].astype(int).mean(2)
    q = w // 4
    inr = (g >= SEP_GREY[0]) & (g <= SEP_GREY[1])
    left, right = inr[:, 20:q].mean(1), inr[:, w - q:w - 20].mean(1)
    hits = np.where((left >= SEP_FILL) & (right >= SEP_FILL))[0]
    out, last = [], -99
    k = layout.scale / 1.37
    for r in hits:
        if r - last <= 4:                   # the same 2px line
            last = r
            continue
        last = r
        cy = y + int(r)
        band = rgb[max(0, cy - round(12 * k)):cy + round(12 * k),
                   x + w // 2 - round(160 * k):x + w // 2 + round(160 * k)].copy()
        band[np.abs(band.astype(int).mean(2) - 21) < 30] = 21   # drop the line itself
        text = " ".join(b[2] for b in sorted(_ocr_lines(band, (21, 21, 21)), key=lambda b: b[1]))
        if text.strip():
            out.append((cy, text.strip()))
    return out


# ------------------------------------------------------------------- checks --
def _load(path: Path) -> np.ndarray:
    from PIL import Image
    return np.array(Image.open(path).convert("RGB"))


def selftest() -> int:
    ref = Path(__file__).resolve().parents[3] / "tools" / "ui-research"
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    check("parse full", parse_handle("Insert name Here @u12345678"), ("u12345678", False))
    check("parse cut ...", parse_handle("mike | likes @u123..."), ("u123", True))
    check("parse cut …", parse_handle("NO MONEY @u514…"), ("u514", True))
    check("parse none", parse_handle("no handle here"), None)

    work = _load(ref / "work_window_list.png")
    sel = list_selection(work)
    print("     list raw:", sel and sel["raw"])
    # The reference captures are local only (tools/ui-research is never pushed:
    # they show a real fan), so these check the SHAPE, not his handle or name.
    check("list handle prefix", bool(sel and re.fullmatch(r"u\d{3,}", sel["handle"])), True)
    check("list truncated", sel and sel["truncated"], True)
    check("list name", bool(sel and sel["name"].strip()), True)
    check("no modal in work window", name_modal(work), None)

    modal = _load(ref / "name_modal.png")
    m = name_modal(modal)
    print("     modal raw:", m and m["raw"])
    check("modal handle", bool(m and sel and re.fullmatch(r"u\d{6,}", m["handle"])
                               and m["handle"].startswith(sel["handle"])), True)
    check("modal name", bool(m and sel and m["name"].lower()[:4] == sel["name"].lower()[:4]), True)
    check("modal tags", m and len(m["tags"]) >= 3, True)
    check("no list in harvest window", list_selection(modal), None)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


def live() -> int:
    for hwnd, title in T._matching_windows("Infloww Messages"):
        rgb = T._pinger.print_window(hwnd)
        if rgb is None:
            print(hwnd, title, "minimised")
            continue
        print(hwnd, title, "list:", list_selection(rgb), "modal:", name_modal(rgb))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if "--live" in sys.argv:
        sys.exit(live())
    sys.exit(selftest())
