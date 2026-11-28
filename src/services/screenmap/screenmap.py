"""
screenmap/screenmap.py — the Screen Map: which Infloww window is which, and where
everything is inside each one. One owner for every on-screen position in MMA.

Proposal: docs/proposals/layout-layer.html (decisions answered 2026-11-27).

    measure(rgb)        everything about ONE captured window (pure, offline-testable)
    load() / require()  what every other tool calls — read the published map

The service that keeps the map fresh is screenmap.pyw next to this file. It writes
userdata/layout/infloww.json; AHK reads the same file through src/core/screenmap.ahk.

Pixels only (memory: infloww-pixels-only): PrintWindow captures, never Infloww's
internals, never focus.

── What it measures, at scale 1 (tools/ui-research/Whole UI.png, 1920x1034) ──
    model tab strip     y 0..48    background #0D0D0D (13); the ACTIVE model tab
                                   is a #303030 (48) block, inactive tabs are bare
    fan-tab row         y 49..80   #303030 (48) bar ("Home", "Remy", "Nick"...)
    conversation header y 81..132
    divider             y 133      1px #444444 under the header
All of it scales with Windows' display scale; the STRIP HEIGHT gives the scale
(49px at scale 1, 67px on the 3441x1381 window at 1.37).

Every panel edge is the same 1px #444444 line (transcript.find_layout found this
first): chat list | conversation, conversation | Fan insights, under the header and
over the composer. A fan window ("Open in new tab") has no chat list, so its
conversation starts at the window's left border. A modal dims the whole window and
every divider disappears with it — that is "unsure", never a guess.

Coordinates in the map are WINDOW-RELATIVE PHYSICAL PIXELS — the same numbers as a
PrintWindow capture of that window. Turning them into screen positions happens in
one place per language (here: to_screen; AHK: SM_ToScreen).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

MMA_ROOT = Path(__file__).resolve().parents[3]
MAP_FILE = MMA_ROOT / "userdata" / "layout" / "infloww.json"
REMEASURE_EVENT = "Global\\MMA.screenmap.remeasure"
SCHEMA = 1

# The chat reader's OCR + capture helpers are the ones every reader shares.
_LLM = MMA_ROOT / "src" / "services" / "llm"
if str(_LLM) not in sys.path:
    sys.path.insert(0, str(_LLM))

# ------------------------------------------------------------------ colours --
STRIP_BG = 13           # #0D0D0D, the model tab strip
TAB_GREY = 48           # #303030, the active model tab and the fan-tab row
GREY_TOL = 5
DIVIDER = (0x44, 0x44, 0x44)
DIVIDER_TOL = 2

# ------------------------------------------------------------ scale-1 sizes --
REF_STRIP_H = 49        # y 0..48
REF_ROW2_H = 32         # the fan-tab row, y 49..80
MIN_TAB_W = 60          # an active model tab is ~154px wide at scale 1
MIN_PANE = 200          # a real panel is wider/taller than this (at any scale)

KINDS = ("main", "fan", "home", "other")


# ================================================================== measure ==
def _maxc(rgb: np.ndarray) -> np.ndarray:
    return rgb.max(2).astype(np.int16)


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """(start, end_inclusive) of every True run in a 1-D mask."""
    if not mask.any():
        return []
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1) - 1
    return list(zip(starts.tolist(), ends.tolist()))


def find_strip(g: np.ndarray) -> int | None:
    """Height of the model tab strip, from the empty middle of the window: rows of
    #0D0D0D, then the #303030 fan-tab row starts. None if that is not what the top
    of the window looks like (a modal dims it; a non-Messages page has no strip)."""
    h, w = g.shape
    ys = []
    for x in np.linspace(int(w * 0.35), int(w * 0.65), 9).astype(int):
        col = g[:min(h, 220), x]
        if abs(int(col[2]) - STRIP_BG) > GREY_TOL:
            continue
        grey = np.flatnonzero(np.abs(col - TAB_GREY) <= GREY_TOL)
        if not len(grey):
            continue
        y = int(grey[0])
        if (np.abs(col[2:y] - STRIP_BG) <= GREY_TOL).mean() > 0.9:
            ys.append(y)
    if len(ys) < 5:
        return None
    sh = int(np.median(ys))
    return sh if 30 <= sh <= 160 else None


def find_row2_end(g: np.ndarray, sh: int) -> int:
    """First row below the fan-tab row (where the conversation header begins).

    Fixed geometry, scaled from the strip: the row is 32 CSS px tall. It used to
    be found by colour, and with many fan tabs open ("Home", fan names...)
    the tabs' own colours ended it early — the "header" then began inside the tab
    row and the name reader cut a fan name off at its descender (2026-11-28)."""
    return sh + round(REF_ROW2_H * sh / REF_STRIP_H)


def find_active_tab(g: np.ndarray, sh: int, scale: float) -> tuple[int, int] | None:
    """(x0, x1) of the lit model tab: the one #303030 block in the strip."""
    w = g.shape[1]
    # The tab's bottom edge is solid grey: no avatar, name, badge or close button
    # reach that low (measured: y 60..64 of a 67px strip, 44..47 of a 49px one, is one clean run).
    band = g[round(sh * 0.90):round(sh * 0.95) + 1, :int(w * 0.7)]
    cols = (np.abs(band - TAB_GREY) <= GREY_TOL).mean(0) > 0.9
    runs = [(a, b) for a, b in _runs(cols) if b - a + 1 >= MIN_TAB_W * scale]
    if not runs:
        return None
    # Glyphs and the avatar break the band up; merge pieces closer than a gap
    # between two tabs (tabs are ~50px apart at scale 1, pieces a few px).
    merged = [list(runs[0])]
    for a, b in runs[1:]:
        if a - merged[-1][1] <= 12 * scale:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    a, b = max(merged, key=lambda r: r[1] - r[0])
    return int(a), int(b)


def find_dividers(rgb: np.ndarray) -> tuple[list[int], np.ndarray]:
    """Full-height vertical divider columns, and the divider mask."""
    h, w = rgb.shape[:2]
    line = np.abs(rgb.astype(np.int16) - np.array(DIVIDER, np.int16)).max(2) <= DIVIDER_TOL
    mid = line[int(h * 0.3):int(h * 0.7)]
    cols = np.flatnonzero(mid.mean(0) > 0.95).tolist()
    # A 1px line can smear over two columns at a fractional position: keep one.
    out: list[int] = []
    for x in cols:
        if not out or x - out[-1] > 2:
            out.append(x)
    return out, line


def _rows_between(line: np.ndarray, x0: int, x1: int, y_from: int) -> list[int]:
    span = line[:, x0 + 10:x1 - 10]
    if span.shape[1] <= 0:
        return []
    rows = np.flatnonzero(span.mean(1) > 0.95)
    out: list[int] = []
    for y in rows.tolist():
        if y >= y_from and (not out or y - out[-1] > 2):
            out.append(y)
    return out


@dataclass
class Measured:
    kind: str                       # main | fan | home | other
    status: str                     # ok | unsure
    reason: str                     # why not ok, in plain words ("" when ok)
    scale: float = 0.0
    regions: dict | None = None     # name -> [x, y, w, h], window-relative
    chat_open: bool = False
    check: list | None = None       # spot-check pixels: [x, y, grey, tol]

    def to_dict(self) -> dict:
        return {"kind": self.kind, "status": self.status, "reason": self.reason,
                "scale": round(self.scale, 4), "regions": self.regions or {},
                "chat_open": self.chat_open, "check": self.check or []}


def measure(rgb: np.ndarray, title: str = "Infloww Messages") -> Measured:
    """Everything about one captured Infloww window that can be had WITHOUT OCR.
    Pure: same pixels in, same answer out (tests run it on saved captures)."""
    if title.startswith("Infloww Home"):
        return Measured("home", "unsure", "Infloww Home is not measured (Messages windows only)")
    h, w = rgb.shape[:2]
    g = _maxc(rgb)
    sh = find_strip(g)
    if sh is None:
        # Strip missing. Either a modal dims everything, or this is not a page
        # with model tabs (the Inbox look-alike). Neither is safe to act on.
        dim = int(np.median(g[2:20, int(w * 0.4):int(w * 0.6)]))
        why = ("a popup is open over Infloww (everything is dimmed)" if dim < STRIP_BG - GREY_TOL
               else "no model tabs at the top of this window")
        return Measured("other", "unsure", why)
    scale = sh / REF_STRIP_H
    r2 = find_row2_end(g, sh)
    regions: dict[str, list[int]] = {"strip": [0, 0, w, sh], "tabs_row": [0, sh, w, r2 - sh]}
    check = [[w // 2, sh // 2, STRIP_BG, GREY_TOL]]

    tab = find_active_tab(g, sh, scale)
    if tab:
        regions["active_tab"] = [tab[0], 0, tab[1] - tab[0] + 1, sh]
        # The bottom of the lit tab is clear of its name and badge.
        check.append([(tab[0] + tab[1]) // 2, round(sh * 0.92), TAB_GREY, GREY_TOL])

    vcols, line = find_dividers(rgb)
    if not vcols:
        return Measured("other", "unsure", "can't find Infloww's panel lines in this window",
                        scale, regions, False, check)

    if vcols[0] <= 3:
        # Fan window: the conversation starts at the window's own left border.
        kind, x0 = "fan", vcols[0]
        x1 = vcols[1] if len(vcols) > 1 else w - 1
    else:
        kind, x0 = "main", vcols[0]
        x1 = vcols[1] if len(vcols) > 1 else w - 1
        regions["list"] = [0, r2, x0, h - r2]
        regions["list_heading"] = [0, r2, x0, round(52 * scale)]
        check.append([x0, h // 2, 0x44, DIVIDER_TOL])
    if x1 - x0 < MIN_PANE:
        return Measured(kind, "unsure", "the conversation area is too narrow to be real",
                        scale, regions, False, check)
    if x1 < w - 1:
        regions["insights"] = [x1 + 1, r2, w - x1 - 1, h - r2]
        check.append([x1, h // 2, 0x44, DIVIDER_TOL])
    regions["conversation"] = [x0, r2, x1 - x0, h - r2]

    rows = _rows_between(line, x0, x1, r2)
    chat_open = False
    if len(rows) >= 2 and rows[1] - rows[0] >= MIN_PANE:
        y0, y1 = rows[0], rows[1]
        chat_open = True
        regions["header"] = [x0, r2, x1 - x0, y0 - r2]
        # Exactly transcript.find_layout's pane, which the chat reader is built on.
        regions["messages"] = [x0, y0 + 2, x1 - x0, y1 - y0 - 2]
        regions["composer"] = [x0, y1 + 1, x1 - x0, h - y1 - 1]
    return Measured(kind, "ok", "", scale, regions, chat_open, check)


def check_pixels(rgb: np.ndarray, check: list | None) -> bool:
    """Do the spot-check pixels still hold in this capture? Each entry is
    [x, y, grey, tol]: every channel of that pixel within tol of grey."""
    if not check:
        return False
    for x, y, want, tol in check:
        if not (0 <= y < rgb.shape[0] and 0 <= x < rgb.shape[1]):
            return False
        if np.abs(rgb[y, x].astype(int) - want).max() > tol:
            return False
    return True


# ======================================================= names (OCR) ==
def read_model(rgb: np.ndarray, m: Measured) -> str:
    """The NAME on the lit model tab ("CIN"). Name only — never the avatar
    (Silly, 2026-11-27). "" when it can't be read."""
    import fanid
    r = (m.regions or {}).get("active_tab")
    if not r:
        return ""
    x, y, w, h = r
    crop = rgb[y:y + h, x:x + w]
    if crop.size == 0:
        return ""
    best = None
    for yc, xl, t, *_ in fanid._ocr_lines(crop, (TAB_GREY, TAB_GREY, TAB_GREY)):
        t = t.strip()
        if len(re.findall(r"[A-Za-z]", t)) >= 2:
            if best is None or (yc, xl) < (best[0], best[1]):
                best = (yc, xl, t)
    return re.sub(r"[^\w .'-]", "", best[2]).strip() if best else ""


def read_tabs(rgb: np.ndarray, m: Measured) -> list[str]:
    """Every model tab name in the strip, left to right."""
    import fanid
    import transcript as T
    return fanid.account_tabs(rgb, T.Layout(region=(0, 0, 0, 0), scale=m.scale or 1.37))


def transcript_layout(m: Measured):
    """The chat reader's Layout for this window (None when no chat is open)."""
    import transcript as T
    r = (m.regions or {}).get("messages")
    if not r:
        return None
    return T.Layout(region=tuple(r), scale=(r[1]) / (T.REF_HEADER_Y + 2))


def read_fan(rgb: np.ndarray, m: Measured) -> dict:
    """Who the open chat is with: header name, and (main windows) the @handle off
    the highlighted chat-list row. Fan windows don't show a handle; the name is
    matched later, and stays unresolved when that is ambiguous (never a guess)."""
    out = {"name": "", "handle": "", "handle_cut": False}
    lay = transcript_layout(m)
    if lay is None:
        return out
    try:
        import transcript as T
        out["name"] = T.read_fan_name(rgb, lay)
    except Exception:
        pass
    if m.kind == "main":
        try:
            import fanid
            sel = fanid.list_selection(rgb, lay)
            if sel:
                out["handle"] = sel.get("handle", "") or ""
                out["handle_cut"] = bool(sel.get("truncated"))
        except Exception:
            pass
    return out


# ================================================================ the file ==
def write_map(doc: dict) -> None:
    """Atomic: a reader never sees half a file."""
    MAP_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = MAP_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, MAP_FILE)


def load() -> dict:
    try:
        return json.loads(MAP_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"schema": SCHEMA, "windows": [], "updated": 0}


class NotReady(Exception):
    """The map can't vouch for this window right now. str() is the plain reason."""


def _key(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower().replace("i", "l"))


def find(doc: dict | None = None, *, hwnd: int | None = None, model: str | None = None,
         kind: str | None = None) -> dict | None:
    """One window record. With `model`, the window showing that model that you used
    LAST wins (decision 2026-11-27), whatever its kind."""
    doc = doc or load()
    wins = [w for w in doc.get("windows", []) if w.get("kind") in ("main", "fan")]
    if hwnd is not None:
        return next((w for w in wins if w["hwnd"] == hwnd), None)
    if kind:
        wins = [w for w in wins if w["kind"] == kind]
    if model:
        wins = [w for w in wins if _key(w.get("model")) == _key(model)]
    if not wins:
        return None
    return max(wins, key=lambda w: w.get("last_focus", 0))


def focused(doc: dict | None = None) -> dict | None:
    doc = doc or load()
    return find(doc, hwnd=doc.get("focus_hwnd")) if doc.get("focus_hwnd") else None


MAX_AGE_S = 15          # an older map means the service isn't running


def require(rec: dict | None, region: str | None = None, doc: dict | None = None):
    """The window record (and the region in it) — or NotReady with the reason.
    THE gate: no tool reads or clicks inside Infloww without this passing."""
    doc = doc or load()
    if time.time() - doc.get("updated", 0) > MAX_AGE_S:
        raise NotReady("the Screen Map isn't running")
    if rec is None:
        raise NotReady("no Infloww window found for that")
    if rec.get("status") != "ok":
        raise NotReady(rec.get("reason") or "Infloww's layout isn't readable right now")
    if region is None:
        return rec, None
    r = rec.get("regions", {}).get(region)
    if not r:
        raise NotReady(f"this window has no {region.replace('_', ' ')} right now")
    return rec, r


def to_screen(rec: dict, x: int, y: int) -> tuple[int, int]:
    """Window-relative -> screen, in per-monitor-aware physical pixels. The ONE
    place this conversion happens on the Python side."""
    from ctypes import windll, wintypes, byref
    r = wintypes.RECT()
    if not windll.user32.GetWindowRect(rec["hwnd"], byref(r)):
        raise NotReady("that Infloww window has closed")
    return r.left + x, r.top + y


def request_remeasure() -> bool:
    """Ask the service to measure every window now. False if it isn't running."""
    from ctypes import windll
    h = windll.kernel32.OpenEventW(0x0002, False, REMEASURE_EVENT)
    if not h:
        return False
    windll.kernel32.SetEvent(h)
    windll.kernel32.CloseHandle(h)
    return True
