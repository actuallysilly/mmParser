"""
automation.py — shared foundation for every Infloww UI automation.

This is the layer the automations sit on: find the window, capture it, locate
elements, drive the mouse. Geometry constants come from UI-ELEMENT-MAP.md; keep
them in sync with that file, which is the measured source of truth.

Two hard safety rules, both enforced in require_window():

  1. We only ever act while "Infloww Messages" is the ACTIVE window. Same gate as
     live_detector.py and `#HotIf WinActive("Infloww Messages")` on the AHK side.
     If you alt-tab away mid-run, the run stops.
  2. The reference geometry was measured on a 1920x1034 window (maximised, 1080p).
     Every coordinate here is WINDOW-RELATIVE and only valid at that size, so a
     different size is refused rather than silently mis-clicked. --force overrides
     if you know what you're doing.

Nothing here clicks. Movement only.

Hotkeys live in MMA's hotkeys.ini under [automation] — never in this file, same rule
as the AHK side. The ids are declared in hotkeys.ahk so the Hotkeys GUI lists, edits
and conflict-checks them, but no HK_Bind claims them: this listener owns them, so it
has to be running for them to fire. Edits apply live, no restart.

Run:
  automation_listen.vbs                         # background listener, no console
  python automation.py --stop                   # ... and end it
  python automation.py --status                 # ... is it up?

  python automation.py --listen                 # same, but in this console
  python automation.py --image "Whole UI.png"   # offline: detect + report, no mouse
  python automation.py --dry-run                # live: find + report, no mouse
  python automation.py --hop                    # live: find kebabs, hop the cursor

As a background listener it is headless (pythonw.exe): output goes to MMA's
error_log.txt in its format, and it is single-instance via a named mutex, the same
idea as #SingleInstance on the AHK side.

Requires: numpy, mss. Windows only (Win32 for window rect, DPI, cursor).
"""
from __future__ import annotations

import argparse
import configparser
import ctypes
import ctypes.wintypes          # NOT implied by `import ctypes` — RECT/POINT need this
import re
import sys
import time
import traceback
from pathlib import Path

import numpy as np

# --------------------------------------------------------------------- config --
TARGET_TITLE = "Infloww Messages"      # case-insensitive substring

# The live maximised window measures 1920x1032 (GetWindowRect). The reference capture
# Whole UI.png is 1920x1034 — those 2 extra rows are trailing border in the capture,
# NOT a layout difference: the composer dividers land on y=862/907 and the tab-strip
# bands on y=1/49/81 in both. So every coordinate below is valid for the live window,
# and --image against the 1034-tall reference agrees with it.
REF_W, REF_H = 1920, 1032              # live window the geometry is valid for
REF_IMG_SIZES = {(1920, 1032), (1920, 1034)}

# Window-relative regions, x, y, w, h  (see UI-ELEMENT-MAP.md)
R_MESSAGES = (401, 135, 1237, 727)     # message scroll area, below the conv header
R_TABS = (0, 0, 597, 48)
R_CHATS = (2, 263, 398, 769)

# The kebab (3-dot menu) beside a model message: 3x13 px, three #666666 dots on a
# 5px pitch, ~15 dot pixels. EVERY model message has one, and only model messages
# do — fan messages get pin/comment/heart/translate on their right instead.
KEBAB_RGB = (0x66, 0x66, 0x66)
KEBAB_TOL = 20
KEBAB_RUN_H = (1, 5)                   # one dot's height within a column
KEBAB_PITCH = (4, 6)                   # dot-to-dot spacing
KEBAB_SPAN = (8, 12)                   # first dot top -> last dot top
KEBAB_MIN_PX = 10                      # real ones carry ~15 dot pixels
KEBAB_MERGE_PX = 6                     # two hits this close are the same kebab
# A kebab is ISOLATED: nothing else #666666-ish within 6px of it. Measured ring of
# exactly 0 on every real kebab, vs 9-16 on every false positive — the fan row's
# comment icon (a speech bubble with dots in it) and antialiased italic quote text
# both fake the dot triplet on a dark neutral background, and this is what rejects
# them. Cheap, and a wider margin than any other filter here.
KEBAB_RING_MAX = 2

# The kebab is anchored to the bubble's BOTTOM-left corner, not its centre:
# centre only coincides for single-line bubbles. Measured dx=12 / dy=19 exactly, on
# every bubble in both the reference and the live app.
KEBAB_BUBBLE_DX = 12                   # kebab centre sits this far LEFT of bubble x0
KEBAB_BUBBLE_DY = 19                   # ... and this far ABOVE bubble y1

MODEL_BUBBLE_RGB = (0x35, 0x35, 0x35)
MODEL_BUBBLE_TOL = 6
MODEL_BUBBLE_XMAX = 1590               # bubbles end ~1585; the avatar photo starts 1592
MODEL_BUBBLE_FILL = 0.5                # a bubble column is >=this fraction of the band

FAN_BUBBLE_RGB = (0x26, 0x26, 0x26)
FAN_BUBBLE_TOL = 5
FAN_BUBBLE_XMIN = 460                  # the fan AVATAR is this colour too, at x 418..452
# A fan bubble is LEFT-ALIGNED: it starts at x~462. Requiring that is what keeps
# right-hand #262626 out of the fan set — the model avatar column (measured at
# x 1593..1626) and, critically, a WITHDRAWN model message. Without it an unsent
# message can register as a fan reply, which drags last_model_run()'s cutoff below
# the messages still to go and empties the run: "unsends one, then stops".
FAN_BUBBLE_X0_MAX = 520

# --- unsend flow -------------------------------------------------------------
# Only the LAST click (the modal's blue Unsend) is destructive; everything before
# it is reversible, so --dry-run walks the whole flow and cancels at the modal.
ACCENT_BLUE = (0x34, 0x67, 0xff)       # the modal's Unsend button; Cancel is grey
ACCENT_BLUE_TOL = 40
MENU_TIMEOUT_S = 3.0                   # kebab click -> menu appears AND settles
MODAL_TIMEOUT_S = 3.0                  # Unsend click -> confirm modal appears
GONE_TIMEOUT_S = 4.0                   # confirm -> message actually disappears
REFLOW_S = 2.0                         # let the list settle around the new placeholder
CHANGE_MIN_PX = 400                    # pixels that must change to count as "appeared"
STABLE_MAX_PX = 150                    # ... and this few may still differ frame-to-frame
                                       # (a live chat is never perfectly still)
CLICK_SETTLE_S = 0.12
ESC_HOLD_S = 0.6                       # HOLD Esc this long to cancel; a tap means "last"
PROMPT_TIMEOUT_S = 15.0
# Two short, independent phrases from the confirm modal. Either proves we are in it.
MODAL_NEEDLES = ("confirm unsend", "unsend this")
BTN_W, BTN_H = (50, 260), (20, 62)     # a clickable button, not a run of blue text
# The modal extends up-left of its Unsend button (~525x150 with the button bottom-right).
# We OCR only this box around a candidate, never the whole window: the full region
# upscaled 3x is enormous, which is why a modal check once took 7 seconds.
MODAL_VERIFY = (-540, -150, 100, 55)   # dx0, dy0, dx1, dy1 around the button centre
# The menu sits at a FIXED offset from the kebab (user's tip). Measured off the
# screenshot: kebab at (290,76), menu spanning x 10..556, y 22..54 — i.e. centred on
# the kebab (its centre 283 is 7px left of it) and always ABOVE. Offsets are padded
# well past that, since the panel's width breathes with the countdown text
# ("Unsend 23h 58m" vs "Unsend 5m").
#
# This replaces change-detection for the menu. A fixed box is not just simpler, it is
# what makes OCR work at all: the detector rescales anything over ~960px on its long
# side, so the old whole-window bbox upscaled 3x came back SMALLER than life-size
# (14px text -> 11px) and read as garbage.
MENU_BOX = (-340, -80, 340, -4)        # dx0, dy0, dx1, dy1 from the kebab centre
MENU_ANIM_S = 0.9                      # cap on the open animation

# The menu is a flat #424242 slab (13.4k px of it in a real capture). Finding the slab
# and clicking near its RIGHT end beats OCR outright: Unsend is always the last item,
# and the slab's own edges tell us where it ends — so the panel breathing with the
# countdown text ("Unsend 23h 58m" vs "Unsend 5m") stops mattering.
MENU_PANEL_RGB = (0x42, 0x42, 0x42)
MENU_PANEL_TOL = 6
MENU_PANEL_W = (250, 760)              # sanity bounds on the slab we accept
MENU_PANEL_H = (24, 56)
MENU_PANEL_FILL = 0.6                  # a slab column is >=this fraction of its height
# Measured: panel y 741..779 for a kebab at y=802 -> centre 42px above it, 39px tall.
# Unsend's text ended ~8px short of the panel edge, so a click this far in lands on it
# whatever the countdown says.
UNSEND_FROM_RIGHT = 30

# --- notifications > purchases -----------------------------------------------
# The Notifications flyout, opened by the teal button in the left sidebar. It is
# anchored to that button, so its box is fixed. NOTE: this lives in the MESSAGES
# app. Infloww Home has a bell too, but it opens an unrelated (empty) System
# Notifications page — with a "Clear all" beside it. Wrong app, and a costly misclick.
NOTIF_BTN = (293, 165)
NOTIF_PANEL = (219, 182, 781, 885)     # measured: bg #262626, page #141414 either side
NOTIF_TAB_Y = 245
NOTIF_TABS = {"subscriptions": 287, "tips": 391, "purchases": 485, "onlyfans": 594}
NOTIF_LIST_X = (285, 760)              # inside the panel: clear of avatars AND scrollbar
NOTIF_LIST_TOP = 265                   # below the tab row; content scrolls under this

# Where the cursor waits while we capture. The wheel only goes to the window under the
# pointer, so scrolling must park it over the list — but LEAVING it there hovers a card
# in every single frame, and the hover restyle corrupts what OCR reads. "Open in new tab"
# (user's pick) is far from the panel and inert on hover.
NOTIF_PARK = (1508, 107)
NOTIF_UNHOVER_S = 0.25                 # let the hover restyle fade before capturing

# Scrollbar thumb: #666666, x 771..778, contiguous. Measured y 272..489 (218px) on
# Purchases, 272..452 on Subscriptions — i.e. it reports scroll progress directly.
SCROLLBAR_X = (771, 779)
SCROLLBAR_RGB = 0x66
SCROLLBAR_TOL = 18
SCROLLBAR_MIN_COLS = 4

# "Is the panel open" is decided by the header band, NOT by the tab pill. The chat
# list's own blue "Unread" pill sits at cx=250 in the same row, only 37px from the
# Subscriptions tab at 287 — a plausible tolerance reads it as "panel open, on
# Subscriptions" when the panel is shut. The header band has no such neighbour:
# measured 0.95 #262626 when open vs 0.04/0.24 when closed.
NOTIF_HEADER_BAND = (230, 190, 760, 226)
NOTIF_OPEN_FILL = 0.70
NOTIF_PILL_MIN_H = 14                  # a pill is a tall block, not a stray glyph pixel
NOTIF_PILL_MIN_W = 50                  # measured 94 (Purchases) / 113 (Subscriptions)
NOTIF_PILL_SNAP = 30                   # ... and this rejects the Unread pill at 37px

# Cards are delimited by a 1px #444444 rule. So is the border of the "Quick reply" box
# that UNANSWERED cards carry, which would otherwise split one card into three. They
# separate cleanly by width: measured 444-475px for a real divider, 334-337px for the
# reply box. Nothing lands between, so the threshold has ~100px of margin either side.
DIVIDER_RGB = (0x44, 0x44, 0x44)
DIVIDER_TOL = 6
DIVIDER_MIN_W = 400

# Card height is NOT fixed: 162px answered, 184px when the text wraps to two lines or an
# unanswered card carries a Quick reply box. Hence dividers rather than a grid.
#
# Scrolling deliberately has no px-per-notch constant. We never compute where a card
# WENT — each pass re-reads whatever is on screen and dedups by content, so the only
# requirement is that one step moves less than a panel-height (~620px of list). Three
# notches is ~300px at Chromium's default 100px/notch, leaving 2x margin; and if the
# app ever changes that, consecutive passes sharing no card at all is detectable, which
# is reported rather than silently skipping a sale.
SCROLL_NOTCHES = 3
SCROLL_SETTLE_S = 0.9
SCROLL_MAX_STEPS = 400                 # hard cap; ~1200 notches is far past any real list

# "No new cards" ALONE is a bad end-of-list test: it is also what a lazy-load fetch in
# flight looks like, so a short fuse quits early on a list that had more to give. The
# thumb tells the two apart — it keeps moving (or shrinks as items load) while there is
# more, and freezes only at the true bottom. Both must stall, repeatedly, with a pause
# between to let a fetch land.
SCROLL_IDLE_STEPS = 4
LAZY_LOAD_WAIT_S = 1.5
WHEEL_DELTA = 120
MOUSEEVENTF_WHEEL = 0x0800

MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
GWL_EXSTYLE = -20
WS_EX_LAYERED, WS_EX_TRANSPARENT = 0x00080000, 0x00000020
WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW = 0x08000000, 0x00000080
# A real kebab always sits on chat background, which is dark and perfectly neutral
# (page bg #151515 -> brightness 21, saturation 0). Photo content inside a media
# message can fake the dot triplet, but not the surround: the one false positive in
# Whole UI.png measured brightness 161 / saturation 51. Bounds are loose enough to
# also allow a bubble fill (#353535, brightness 53) behind a kebab.
KEBAB_BG_BRI_MAX = 60
KEBAB_BG_SAT_MAX = 8

VK_ESCAPE = 0x1B

# This file's own paths.ahk. MMA_ROOT is derived from THIS file's location, for
# the same reason the AHK side stopped using A_ScriptDir: a path relative to the
# working directory or to the wrong ancestor does not raise, it just resolves to
# a file that is not there — and configparser on a missing file returns an empty
# config, so the listener starts, binds nothing, and says "nothing bound".
#
# That is not hypothetical. `parent.parent` was right while this lived one level
# down; after the restructure it points at src/services/, so this read
# src/services/hotkeys.ini (absent) and wrote src/services/error_log.txt (a
# second, orphaned log). Every [automation] key — hopKebabs, unsendLast,
# countSales — was silently dead.
#
#   src/services/automation/automation.py  ->  parents[3] is the repo root
MMA_ROOT = Path(__file__).resolve().parents[3]
MMA_USERDATA = MMA_ROOT / "userdata"

# Hotkeys live in MMA's one ini, same as every AHK key — never in this file.
# See hotkeys.ahk: the [automation] ids are DECLARED there (so the Hotkeys GUI
# lists, edits and conflict-checks them) but deliberately not HK_Bind'd, because
# this listener owns them.
HOTKEYS_INI = MMA_USERDATA / "hotkeys.ini"
HOTKEY_SECTION = "automation"
POLL_S = 0.03

# Background listener plumbing. MMA's own log, format and single-instance rule.
MMA_LOG = MMA_USERDATA / "error_log.txt"
LOG_TAG = "automation.py"
MUTEX_NAME = "Global\\MMA.automation.listener"
STOP_EVENT_NAME = "Global\\MMA.automation.listener.stop"
ERROR_ALREADY_EXISTS = 183

u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
k32.CreateMutexW.restype = ctypes.c_void_p
k32.CreateEventW.restype = ctypes.c_void_p
k32.OpenEventW.restype = ctypes.c_void_p
k32.SetEvent.argtypes = [ctypes.c_void_p]
k32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
# 64-bit HWND handling: the default restype c_int truncates handles.
u32.GetForegroundWindow.restype = ctypes.c_void_p
u32.GetWindowTextLengthW.argtypes = [ctypes.c_void_p]
u32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
u32.GetWindowRect.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
u32.VkKeyScanW.argtypes = [ctypes.c_wchar]
u32.VkKeyScanW.restype = ctypes.c_short


class WindowNotReady(RuntimeError):
    """The Infloww window isn't active, or isn't the size the geometry assumes."""


# --------------------------------------------------------------- window/coords --
def set_dpi_aware():
    """Must run before any coordinate read, or Windows lies about pixels."""
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)      # per-monitor v2
    except Exception:
        try:
            u32.SetProcessDPIAware()
        except Exception:
            pass


def foreground_title() -> str:
    hwnd = u32.GetForegroundWindow()
    if not hwnd:
        return ""
    n = u32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    u32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def window_rect(hwnd) -> tuple[int, int, int, int]:
    r = ctypes.wintypes.RECT()
    u32.GetWindowRect(hwnd, ctypes.byref(r))
    return r.left, r.top, r.right - r.left, r.bottom - r.top


def require_window(force: bool = False):
    """Both safety gates. Returns (hwnd, rect) or raises WindowNotReady."""
    title = foreground_title()
    if TARGET_TITLE.lower() not in title.lower():
        raise WindowNotReady(
            f"{TARGET_TITLE!r} is not the active window (active: {title[:60]!r}).")
    hwnd = u32.GetForegroundWindow()
    rect = window_rect(hwnd)
    if not force and (rect[2], rect[3]) != (REF_W, REF_H):
        raise WindowNotReady(
            f"window is {rect[2]}x{rect[3]} but the geometry in UI-ELEMENT-MAP.md was "
            f"measured at {REF_W}x{REF_H}. Every coordinate would be wrong. "
            f"Maximise it, or pass --force if you have re-measured.")
    return hwnd, rect


def to_screen(rect, x: int, y: int) -> tuple[int, int]:
    """Window-relative -> absolute screen."""
    return rect[0] + x, rect[1] + y


def grab(rect) -> np.ndarray:
    """Capture a screen rect (x,y,w,h) -> RGB array."""
    import mss
    x, y, w, h = rect
    MSS = getattr(mss, "MSS", None) or mss.mss     # mss.mss deprecated in favour of MSS
    with MSS() as sct:
        raw = sct.grab({"left": x, "top": y, "width": w, "height": h})
    return np.asarray(raw)[:, :, :3][:, :, ::-1]           # BGRA -> RGB


# ------------------------------------------------------------------ detection --
def _neutral_surround(sub, cx, cy) -> bool:
    """A real kebab sits on chat background: dark and perfectly neutral (page bg
    #151515 -> brightness 21, saturation 0). Photo content inside a media message can
    fake the dot triplet but never the surround — the false positive this rejects
    measured brightness 161 / saturation 51."""
    box = sub[max(0, cy - 9):cy + 10, max(0, cx - 6):cx + 7]
    if box.size == 0:
        return False
    bg = np.abs(box - np.array(KEBAB_RGB)).max(2) > KEBAB_TOL          # exclude the dots
    if bg.sum() < 20:
        return False
    mx = box.max(2)
    sat = mx - box.min(2)
    return (np.median(mx[bg]) <= KEBAB_BG_BRI_MAX
            and np.median(sat[bg]) <= KEBAB_BG_SAT_MAX)


def _kebab_dots(mask, cx, cy) -> int:
    """#666666 pixels in the kebab-sized box at (cx, cy). ~15 for a real one."""
    return int(mask[max(0, cy - 8):cy + 9, max(0, cx - 2):cx + 3].sum())


def _isolated(mask, cx, cy) -> bool:
    """Nothing else #666666-ish just outside the kebab. See KEBAB_RING_MAX."""
    core = _kebab_dots(mask, cx, cy)
    wide = int(mask[max(0, cy - 9):cy + 10, max(0, cx - 6):cx + 7].sum())
    return wide - core <= KEBAB_RING_MAX


def _is_kebab(mask, sub, cx, cy) -> bool:
    """All three checks a candidate must pass, wherever it came from."""
    return (_kebab_dots(mask, cx, cy) >= KEBAB_MIN_PX
            and _isolated(mask, cx, cy)
            and _neutral_surround(sub, cx, cy))


def _scan_kebabs(mask, sub) -> list[tuple[int, int]]:
    """Direct scan: columns holding three short #666666 runs on a ~5px pitch.

    The y-locality here is load-bearing. An earlier version grouped every dot sharing
    an x-column across the whole region and demanded exactly three — but the region
    holds ~626 dot-sized blobs from text antialiasing and photo content, so one stray
    dot anywhere in a kebab's column silently rejected it. That found 3/3 on the
    sparse reference and 0/4 on a busy conversation. Runs are matched within a ~10px
    window instead, so strays elsewhere in the column are irrelevant.
    """
    cand = []
    for x in range(mask.shape[1]):
        col = mask[:, x]
        if col.sum() < 6:
            continue
        idx = np.flatnonzero(col)
        runs, s = [], idx[0]
        for i in range(1, len(idx)):
            if idx[i] != idx[i - 1] + 1:
                runs.append((s, idx[i - 1]))
                s = idx[i]
        runs.append((s, idx[-1]))
        runs = [r for r in runs if KEBAB_RUN_H[0] <= r[1] - r[0] + 1 <= KEBAB_RUN_H[1]]
        for i in range(len(runs) - 2):
            r1, r2, r3 = runs[i], runs[i + 1], runs[i + 2]
            if (KEBAB_PITCH[0] <= r2[0] - r1[0] <= KEBAB_PITCH[1]
                    and KEBAB_PITCH[0] <= r3[0] - r2[0] <= KEBAB_PITCH[1]
                    and KEBAB_SPAN[0] <= r3[0] - r1[0] <= KEBAB_SPAN[1]):
                cand.append((x, (r1[0] + r3[1]) // 2))

    out, used = [], set()
    for i, (x, y) in enumerate(cand):                  # cluster the ~3 columns of one kebab
        if i in used:
            continue
        grp = [(x, y)]
        for j in range(i + 1, len(cand)):
            if j not in used and abs(cand[j][0] - x) <= 3 and abs(cand[j][1] - y) <= 3:
                grp.append(cand[j])
                used.add(j)
        cx = int(round(sum(p[0] for p in grp) / len(grp)))
        cy = int(round(sum(p[1] for p in grp) / len(grp)))
        if _is_kebab(mask, sub, cx, cy):
            out.append((cx, cy))
    return out


def find_model_bubbles(rgb: np.ndarray, region=R_MESSAGES) -> list[tuple[int, int, int, int]]:
    """Model message bubbles (#353535 fill), as window-relative (x0, y0, x1, y1).

    NOT one per model message: a media+caption message shows up as two bands (the
    media container and the caption), and a standalone media message has no flat fill
    at all so it does not appear here. Use find_model_kebabs() to count messages.
    """
    rx, ry, rw, rh = region
    sub = rgb[ry:ry + rh, rx:rx + rw].astype(int)
    m = np.abs(sub - np.array(MODEL_BUBBLE_RGB)).max(2) <= MODEL_BUBBLE_TOL
    m[:, max(0, MODEL_BUBBLE_XMAX - rx):] = False      # the avatar photo is not a bubble
    on = m.sum(1) > 8
    out, s = [], None
    for i, v in enumerate(list(on) + [False]):
        if v and s is None:
            s = i
        if not v and s is not None:
            if i - s >= 12:
                # A column only counts as bubble if it is SUBSTANTIALLY filled. A bare
                # "> 2" rule let the kebab's own antialiasing define x0: live capture
                # sits a shade off the reference PNG (border #3d3d3d vs #3a3a3a), so a
                # few icon edge pixels land inside #353535+/-6 and dragged x0 12px left
                # - exactly onto the kebab, making the anchor miss by 12. Real bubble
                # columns run 59-64 of 64 rows; contamination is ~3.
                thresh = max(3, int(MODEL_BUBBLE_FILL * (i - s)))
                cols = np.where(m[s:i].sum(0) >= thresh)[0]
                if not len(cols):
                    s = None
                    continue
                out.append((rx + int(cols.min()), ry + s, rx + int(cols.max()), ry + i - 1))
            s = None
    return out


def find_model_kebabs(rgb: np.ndarray, region=R_MESSAGES) -> list[tuple[int, int]]:
    """Every model-message kebab in `rgb`, window-relative (cx, cy), top-to-bottom.

    Two passes, because neither alone is complete:

    1. Direct scan for the dot triplet. Catches every kebab including the ones beside
       standalone media messages, which have no bubble to anchor to.
    2. Bubble-anchored: for each #353535 bubble, look at (x0-12, y1-19). That offset
       is exact on every bubble measured, and it rescues kebabs the direct scan drops
       when antialiasing breaks a dot run.

    Anchored hits are VERIFIED, never trusted: the media half of a media+caption
    message is a #353535 bubble with no kebab of its own (the caption owns it), so a
    blind offset would invent one. Both passes go through the same dot-count and
    neutral-surround checks, and results are merged within KEBAB_MERGE_PX.
    """
    rx, ry, rw, rh = region
    sub = rgb[ry:ry + rh, rx:rx + rw].astype(int)
    mask = np.abs(sub - np.array(KEBAB_RGB)).max(2) <= KEBAB_TOL

    found = _scan_kebabs(mask, sub)

    for x0, _y0, _x1, y1 in find_model_bubbles(rgb, region):
        ax, ay = x0 - KEBAB_BUBBLE_DX - rx, y1 - KEBAB_BUBBLE_DY - ry
        # A bubble clipped by the region edge anchors outside it (x0=0 -> ax=-12).
        # Guard explicitly: a negative index would wrap and slice half the region.
        if not (0 <= ax < rw and 0 <= ay < rh):
            continue
        if any(abs(ax - cx) <= KEBAB_MERGE_PX and abs(ay - cy) <= KEBAB_MERGE_PX
               for cx, cy in found):
            continue                                   # direct scan already has it
        ys, xs = np.where(mask[max(0, ay - 5):ay + 6, max(0, ax - 5):ax + 6])
        if len(xs) < KEBAB_MIN_PX:
            continue                                   # no kebab here (media container)
        cx = max(0, ax - 5) + int(round(xs.mean()))
        cy = max(0, ay - 5) + int(round(ys.mean()))
        if _is_kebab(mask, sub, cx, cy):
            found.append((cx, cy))

    return sorted(((x + rx, y + ry) for x, y in found), key=lambda p: (p[1], p[0]))


# ---------------------------------------------------------------------- mouse --
def _ease(t: float) -> float:
    """ease-in-out cubic — starts and stops gently, so a hop reads as deliberate."""
    return 4 * t ** 3 if t < 0.5 else 1 - ((-2 * t + 2) ** 3) / 2


def abort_pressed() -> bool:
    return bool(u32.GetAsyncKeyState(VK_ESCAPE) & 0x8000)


def move_smooth(x: int, y: int, duration: float = 0.7, steps: int = 60) -> bool:
    """Glide the cursor to (x, y) in screen coords. False if Esc aborted."""
    pt = ctypes.wintypes.POINT()
    u32.GetCursorPos(ctypes.byref(pt))
    x0, y0 = pt.x, pt.y
    for i in range(1, steps + 1):
        if abort_pressed():
            return False
        t = _ease(i / steps)
        u32.SetCursorPos(int(round(x0 + (x - x0) * t)), int(round(y0 + (y - y0) * t)))
        time.sleep(duration / steps)
    return True


def hop(points, rect, duration: float = 0.7, dwell: float = 0.6) -> bool:
    """Visit each window-relative point in turn, slowly. Movement only — no clicks.
    Esc aborts. Re-checks the window gate at every stop, so alt-tabbing stops it."""
    for i, (x, y) in enumerate(points, 1):
        if TARGET_TITLE.lower() not in foreground_title().lower():
            print("  ! window lost focus - stopping")
            return False
        sx, sy = to_screen(rect, x, y)
        print(f"  [{i}/{len(points)}] window ({x},{y}) -> screen ({sx},{sy})")
        if not move_smooth(sx, sy, duration=duration):
            print("  ! aborted (Esc)")
            return False
        time.sleep(dwell)
    return True


# ----------------------------------------------------------- fan / last run --
def find_fan_bubbles(rgb: np.ndarray, region=R_MESSAGES) -> list[tuple[int, int, int, int]]:
    """Fan message bubbles (#262626), window-relative (x0, y0, x1, y1).

    Clamped to x >= FAN_BUBBLE_XMIN because the fan AVATAR is the same #262626 and
    would otherwise merge into the bubble. Same fill rule as find_model_bubbles.
    """
    rx, ry, rw, rh = region
    sub = rgb[ry:ry + rh, rx:rx + rw].astype(int)
    m = np.abs(sub - np.array(FAN_BUBBLE_RGB)).max(2) <= FAN_BUBBLE_TOL
    m[:, :max(0, FAN_BUBBLE_XMIN - rx)] = False
    on = m.sum(1) > 8
    out, s = [], None
    for i, v in enumerate(list(on) + [False]):
        if v and s is None:
            s = i
        if not v and s is not None:
            if i - s >= 12:
                cols = np.where(m[s:i].sum(0) >= max(3, int(MODEL_BUBBLE_FILL * (i - s))))[0]
                if len(cols) and rx + int(cols.min()) <= FAN_BUBBLE_X0_MAX:
                    out.append((rx + int(cols.min()), ry + s, rx + int(cols.max()), ry + i - 1))
            s = None
    return out


def last_model_run(rgb: np.ndarray, region=R_MESSAGES) -> list[tuple[int, int]]:
    """The kebabs of your last unbroken run of messages — everything you sent since
    the fan last replied — top-to-bottom.

    This is the scope of "unsend ALL" (user's call). Anything above the fan's last
    reply is deliberately out of reach: a normal conversation always shows several of
    your messages, so "every model message on screen" would be both a constant prompt
    and a foot-gun.

    FAILS SAFE. With no fan bubble in view there is no boundary to measure, so the
    run is unknowable — and we return only the bottom-most message rather than
    assuming every message on screen qualifies. Returning them all would quietly turn
    one missed detection into "unsend the entire conversation", which is precisely
    what scoping to the last run is meant to prevent. Scroll a fan reply into view to
    unsend a whole run.
    """
    kebabs = find_model_kebabs(rgb, region)
    if not kebabs:
        return []
    fans = find_fan_bubbles(rgb, region)
    if not fans:
        return kebabs[-1:]                  # boundary unknown -> the last one only
    cutoff = max(f[3] for f in fans)        # bottom of the last fan bubble
    return [k for k in kebabs if k[1] > cutoff]


# ---------------------------------------------------------------- unsend --
def click(x: int, y: int, settle: float = CLICK_SETTLE_S) -> None:
    """Left click at absolute screen (x, y). The only clicking primitive here."""
    u32.SetCursorPos(int(x), int(y))
    time.sleep(0.04)
    u32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    time.sleep(0.02)
    u32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(settle)


def wait_for_change(rect, before, timeout=MENU_TIMEOUT_S, min_px=CHANGE_MIN_PX, box=None):
    """Wait for the window to change AND SETTLE; return (after_rgb, changed_bbox).

    Change detection rather than hardcoded coordinates: the kebab menu opens relative
    to whichever message you clicked, so its position is not fixed. Diffing tells us
    both THAT it opened and WHERE, and doubles as proof the click landed.

    Two conditions, not one: it must differ from `before` by min_px AND be stable
    against the previous frame. Menus animate in, and returning on first difference
    handed OCR a half-faded menu — which read as empty and aborted the flow ~1s after
    the click, too fast for OCR to have even run properly.

    `box` restricts the diff. Pass one whenever you know roughly where to look: the
    fan chat list re-sorts constantly as messages arrive, and a whole-window diff
    happily reported THAT as "the menu" — OCR then read
    ['JD0425', '@u471410856', '$247', '6:11 pm', ...] out of the chat list.
    """
    x0, y0, x1, y1 = box if box else (0, 0, before.shape[1] - 1, before.shape[0] - 1)
    deadline = time.time() + timeout
    b = before[y0:y1 + 1, x0:x1 + 1].astype(np.int16)
    prev = None
    while time.time() < deadline:
        after = grab(rect)
        c = after[y0:y1 + 1, x0:x1 + 1].astype(np.int16)
        changed = np.abs(c - b).max(2) > 12
        if changed.sum() > min_px:
            if prev is not None and int((np.abs(c - prev).max(2) > 12).sum()) < STABLE_MAX_PX:
                ys, xs = np.where(changed)
                return after, (x0 + int(xs.min()), y0 + int(ys.min()),
                               x0 + int(xs.max()), y0 + int(ys.max()))
            prev = c
        time.sleep(0.06)
    return None, None


def wait_stable(rect, box, timeout=MENU_ANIM_S, max_px=STABLE_MAX_PX):
    """Grab until `box` stops changing, then return that frame.

    For a known box we do not need a before-image — only for the open animation to
    finish. Capturing mid-fade handed OCR a half-drawn menu, which read as empty and
    aborted ~1s after the click.
    """
    x0, y0, x1, y1 = box
    deadline = time.time() + timeout
    prev, last = None, grab(rect)
    while time.time() < deadline:
        cur = grab(rect)
        c = cur[y0:y1 + 1, x0:x1 + 1].astype(np.int16)
        if prev is not None and int((np.abs(c - prev).max(2) > 12).sum()) < max_px:
            return cur
        prev, last = c, cur
        time.sleep(0.06)
    return last


_OCR = {"eng": None}


def ocr_engine():
    if _OCR["eng"] is None:
        from rapidocr_onnxruntime import RapidOCR      # lazy: slow import, only if used
        _OCR["eng"] = RapidOCR()
    return _OCR["eng"]


def _norm(s: str) -> str:
    """Squash text to letters+digits for matching.

    RapidOCR drops spaces — the menu's "Unsend 23h 56m" came back as 'y/Unsend23h59m'.
    A literal needle like "unsend this message" can therefore never match the modal's
    real text, which reads as 'areyousureyouwanttounsendthismessage'. Normalising both
    sides makes the match immune to OCR's spacing and punctuation entirely.
    """
    return re.sub(r"[^a-z0-9]", "", s.lower())


OCR_TARGET_LONG = 1400                 # aim the upscaled crop at roughly this


def _auto_upscale(crop) -> int:
    """Scale a crop TOWARDS the detector's sweet spot, never past it.

    RapidOCR's detector resizes anything over ~960px on the long side back down, so a
    blind upscale on a big crop shrinks the text: a 1200x700 region at 3x came back at
    0.27x, turning 14px menu text into 11px — smaller than the original, and unreadable.
    """
    long = max(crop.shape[0], crop.shape[1])
    if long <= 0:
        return 1
    return int(max(1, min(4, round(OCR_TARGET_LONG / long))))


def ocr_read(rgb, box, upscale: int | None = None):
    """Every OCR box in `box`, as [(centre_point, text)] in window coords."""
    from PIL import Image as _Image
    x0, y0, x1, y1 = box
    crop = rgb[y0:y1 + 1, x0:x1 + 1]
    if crop.size == 0:
        return []
    if upscale is None:
        upscale = _auto_upscale(crop)
    big = np.asarray(_Image.fromarray(crop.astype(np.uint8)).resize(
        (crop.shape[1] * upscale, crop.shape[0] * upscale), _Image.LANCZOS))
    try:
        res, _ = ocr_engine()(big)
    except Exception as e:
        print(f"  ! OCR failed: {e}")
        return []
    out = []
    for pts, txt, _score in (res or []):
        cx = sum(p[0] for p in pts) / len(pts) / upscale + x0
        cy = sum(p[1] for p in pts) / len(pts) / upscale + y0
        out.append(((int(round(cx)), int(round(cy))), txt))
    return out


DEBUG_DIR = Path(__file__).with_name("debug")


def _dump(rgb, box, tag: str) -> None:
    """Save the crop OCR just failed on. A text log tells you WHAT it read but never
    WHY; the picture does. Cheap, and only written on failure."""
    try:
        from PIL import Image as _Image
        DEBUG_DIR.mkdir(exist_ok=True)
        x0, y0, x1, y1 = box
        p = DEBUG_DIR / f"{tag}_{time.strftime('%H%M%S')}.png"
        _Image.fromarray(rgb[y0:y1 + 1, x0:x1 + 1].astype(np.uint8)).save(p)
        print(f"  - saved {p.name} ({x1 - x0 + 1}x{y1 - y0 + 1} at {x0},{y0})")
    except Exception as e:
        print(f"  - could not save debug crop: {e}")


def ocr_find(rgb, box, needle: str, upscale: int | None = None, quiet: bool = False):
    """Centre of the first OCR box whose text contains `needle`, ignoring spacing.
    Returns (point, text) or (None, None). On a miss it logs what it DID read and
    saves the crop — a silent abort tells you nothing about why. `quiet` suppresses
    that for a speculative probe the caller expects to fail."""
    found = ocr_read(rgb, box, upscale)
    n = _norm(needle)
    for pt, txt in found:
        if n in _norm(txt):
            return pt, txt
    if not quiet:
        print(f"  - OCR saw {[t for _, t in found]!r} - no {needle!r}")
        _dump(rgb, box, f"miss-{_norm(needle)[:10]}")
    return None, None


def ocr_contains(rgb, box, needles, upscale: int | None = None) -> bool:
    """True if ANY needle appears anywhere in `box`. Verification only — no click point.

    Matches against ALL the text joined together, because OCR splits a sentence across
    boxes unpredictably, and takes several short needles rather than one long one: a
    single mis-read character kills an exact match, and a 44-character sentence offers
    plenty of chances for one. Two short independent phrases are far harder to lose.
    """
    found = ocr_read(rgb, box, upscale)
    blob = _norm(" ".join(t for _, t in found))
    if any(_norm(n) in blob for n in needles):
        return True
    print(f"  - OCR saw {[t for _, t in found]!r} - none of {list(needles)!r}")
    _dump(rgb, box, "miss-modal")
    return False


def find_menu_panel(rgb, box):
    """The kebab menu's flat #424242 slab inside `box`, as (x0, y0, x1, y1), or None.

    Cheap, exact, and no OCR: the slab is a big block of one colour, and its right
    edge is all we need — Unsend is always the last item on it.
    """
    x0, y0, x1, y1 = box
    sub = rgb[y0:y1 + 1, x0:x1 + 1].astype(int)
    m = np.abs(sub - np.array(MENU_PANEL_RGB)).max(2) <= MENU_PANEL_TOL
    if m.sum() < 2000:
        return None
    rows = np.where(m.sum(1) > 40)[0]
    if not len(rows):
        return None
    ry0, ry1 = int(rows.min()), int(rows.max())
    band = m[ry0:ry1 + 1]
    h = ry1 - ry0 + 1
    # SOLID columns only. The slab runs the full height; stray #424242 pixels (the
    # model avatar is a PHOTO at x 1592..1627 and can hold any colour) contribute a
    # row or two, but a bare cols.max() lets them stretch the right edge ~25px — which
    # pushed the Unsend click clean off the item and shut the menu instead.
    # Measured: a good panel reads 540 wide, the contaminated one 565.
    cols = np.where(band.sum(0) >= max(4, int(MENU_PANEL_FILL * h)))[0]
    if not len(cols):
        return None
    px0, py0 = x0 + int(cols.min()), y0 + ry0
    px1, py1 = x0 + int(cols.max()), y0 + ry1
    w, h = px1 - px0 + 1, py1 - py0 + 1
    if not (MENU_PANEL_W[0] <= w <= MENU_PANEL_W[1] and MENU_PANEL_H[0] <= h <= MENU_PANEL_H[1]):
        print(f"  - panel candidate {w}x{h} outside expected bounds")
        return None
    return (px0, py0, px1, py1)


def _blue_buttons(rgb, box):
    """Every button-shaped accent-blue block inside `box`, biggest first, as
    (cx, cy, w, h) in window coords.

    Plural, and shape-filtered, on purpose. Averaging ALL blue pixels was badly wrong:
    the window holds ~6.6k accent-blue pixels spread from x10 to x1583 (Online Fans,
    the active filter pill, "Open in new tab", the blue chatter name), and their
    centroid is (315,241) — empty space in the chat list. If the confirm modal dims
    the page, the changed region is the whole window and that centroid is what we
    would have clicked. Callers must confirm a candidate by the text around it.
    """
    x0, y0, x1, y1 = box
    sub = rgb[y0:y1 + 1, x0:x1 + 1].astype(int)
    m = np.abs(sub - np.array(ACCENT_BLUE)).max(2) <= ACCENT_BLUE_TOL
    out, s = [], None
    on = m.sum(1) > 8
    for i, v in enumerate(list(on) + [False]):
        if v and s is None:
            s = i
        if not v and s is not None:
            band, h = m[s:i], i - s
            cols = np.where(band.sum(0) >= max(3, int(0.5 * h)))[0]
            if len(cols):
                w = int(cols.max() - cols.min() + 1)
                if (BTN_W[0] <= w <= BTN_W[1] and BTN_H[0] <= h <= BTN_H[1]
                        and band.sum() >= 0.5 * w * h):          # solid, not blue text
                    out.append((x0 + int(cols.min()) + w // 2, y0 + s + h // 2, w, h,
                                int(band.sum())))
            s = None
    out.sort(key=lambda b: -b[4])
    return [(c[0], c[1], c[2], c[3]) for c in out]


def unsend_last_message(rect, args) -> bool:
    """Unsend the bottom-most model message. True if it went.

    Verifies at every step and aborts rather than guessing, because the final click
    cannot be undone:
      kebab found -> menu opened -> menu really says "Unsend" -> modal opened ->
      modal really says "unsend this message" -> blue button found -> click.

    The "Unsend 23h 56m" countdown in the menu means the option EXPIRES, so the last
    menu item is not reliably Unsend — we read it rather than assume its position.
    """
    before = grab(rect)
    kebabs = find_model_kebabs(before)
    if not kebabs:
        print("  no model message found")
        return False
    kx, ky = kebabs[-1]                                  # sorted by y -> bottom-most
    print(f"  kebab {len(kebabs)} visible; targeting bottom at ({kx},{ky})")

    H, W = before.shape[:2]
    box = (max(0, kx + MENU_BOX[0]), max(0, ky + MENU_BOX[1]),
           min(W - 1, kx + MENU_BOX[2]), min(H - 1, ky + MENU_BOX[3]))

    # 1. open the menu -----------------------------------------------------------
    click(*to_screen(rect, kx, ky))
    # Must wait for it to APPEAR, not merely to be still: an unopened menu is
    # perfectly still, so a stability-only wait returned instantly on empty pixels.
    menu_img, _ = wait_for_change(rect, before, MENU_TIMEOUT_S, box=box)
    if menu_img is None:
        print(f"  ! menu did not open in {box} - aborting. NOT sending Esc: nothing "
              f"is open, so it would reach the app and navigate it")
        return False

    # 2. click Unsend, located off the menu panel itself --------------------------
    panel = find_menu_panel(menu_img, box)
    if panel is None:
        print("  ! menu panel (#424242) not found - see the saved crop")
        _dump(menu_img, box, "miss-panel")
        _send_escape()
        return False
    px0, py0, px1, py1 = panel
    ux, uy = px1 - UNSEND_FROM_RIGHT, (py0 + py1) // 2
    print(f"  panel {panel} {px1-px0+1}x{py1-py0+1} -> Unsend ({ux},{uy}) "
          f"= kebab+({ux-kx:+d},{uy-ky:+d})")
    click(*to_screen(rect, ux, uy))

    # 3. confirm modal -----------------------------------------------------------
    modal_img, modal_box = wait_for_change(rect, menu_img, MODAL_TIMEOUT_S)
    if modal_box is None:
        print("  ! confirm modal did not appear - aborting")
        _send_escape()
        return False

    cands = _blue_buttons(modal_img, modal_box)
    if not cands:
        print("  ! no blue button in the modal - aborting")
        _dump(modal_img, modal_box, "miss-modalbtn")
        _send_escape()
        return False
    # The modal is centred, so of the button-shaped blue blocks take the one nearest
    # the middle. Never the plain centroid of all blue: that averages Online Fans, the
    # active pill and the chatter name into (315,241) - empty chat-list space.
    cands.sort(key=lambda c: (c[0] - W // 2) ** 2 + (c[1] - H // 2) ** 2)
    cx, cy, bw, bh = cands[0]
    btn = (cx, cy)
    print(f"  modal button {bw}x{bh} at {btn}")

    if args.dry_run:
        print(f"  DRY RUN: would click Unsend at {btn} - cancelling instead")
        _send_escape()
        return False

    print(f"  clicking Unsend at {btn}")
    click(*to_screen(rect, *btn))

    gone, _ = wait_for_change(rect, modal_img, GONE_TIMEOUT_S)
    if gone is None:
        print("  ! modal did not close - did it work?")
        return False
    return True


def _send_escape() -> None:
    """Close a menu/modal without clicking anything.

    ONLY call this when something is definitely open. Escape with no menu up goes
    straight to Infloww, which navigates — that is what "it randomly switched windows"
    was: an abort path fired Esc after the menu had failed to open at all.
    """
    u32.keybd_event(VK_ESCAPE, 0, 0, 0)
    u32.keybd_event(VK_ESCAPE, 0, 2, 0)                  # KEYEVENTF_KEYUP
    time.sleep(0.15)


PROMPT_TITLE = "MMA_UNSEND_PROMPT"


def prompt_unsend_choice(hk, n: int, rect) -> str:
    """Ask what to unsend when the last run has more than one message.
    Returns "all" | "last" | "cancel".

        <hotkey> again   -> all
        tap Esc          -> just the last
        HOLD Esc         -> cancel
        no answer        -> cancel

    The window is WS_EX_NOACTIVATE: if it stole focus, Infloww would stop being the
    foreground window and every gate downstream would refuse. Keys are read with
    GetAsyncKeyState, so it never needs focus anyway.
    """
    import tkinter as tk

    win = tk.Tk()
    win.title(PROMPT_TITLE)
    win.overrideredirect(True)
    win.attributes("-topmost", True)
    win.configure(bg="#151515")
    w, h = 560, 132
    cx = rect[0] + rect[2] // 2 - w // 2
    cy = rect[1] + rect[3] // 2 - h // 2
    win.geometry(f"{w}x{h}+{cx}+{cy}")

    tk.Label(win, text=f"{n} messages in your last run",
             bg="#151515", fg="#ff7c71", font=("Segoe UI", 15, "bold")).pack(pady=(14, 2))
    tk.Label(win, text=f"Press  {hk.raw}  again  →  unsend ALL {n}",
             bg="#151515", fg="#d9d9d9", font=("Segoe UI", 11)).pack()
    tk.Label(win, text="Tap Esc  →  unsend just the last     ·     Hold Esc  →  cancel",
             bg="#151515", fg="#8a8a8a", font=("Segoe UI", 10)).pack(pady=(4, 0))
    win.update_idletasks()
    win.update()

    hwnd = u32.FindWindowW(None, PROMPT_TITLE)
    if hwnd:
        ex = u32.GetWindowLongW(hwnd, GWL_EXSTYLE)
        u32.SetWindowLongW(hwnd, GWL_EXSTYLE, ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)

    choice, armed, esc_at = None, False, None
    deadline = time.time() + PROMPT_TIMEOUT_S
    try:
        while choice is None and time.time() < deadline:
            win.update()
            down = hotkey_down(hk)
            if not down:
                armed = True                     # they are still holding it from the trigger
            elif armed:
                choice = "all"
                break
            esc = _down(VK_ESCAPE)
            if esc and esc_at is None:
                esc_at = time.time()
            elif esc and time.time() - esc_at >= ESC_HOLD_S:
                choice = "cancel"
            elif not esc and esc_at is not None:
                choice = "last"                  # pressed and released = a tap
            time.sleep(0.02)
    finally:
        win.destroy()
    return choice or "cancel"


def unsend_run(rect, args) -> int:
    """Unsend the whole last run, bottom-up. Returns how many went.

    Re-detects before every step instead of reusing the first scan: each unsend
    reflows the conversation, so coordinates captured up front go stale immediately
    (a live scroll already moved every kebab by 156px between two calls this session).
    Bounded by the initial count so a silent failure cannot loop forever.
    """
    pane = (R_MESSAGES[0], R_MESSAGES[1],
            R_MESSAGES[0] + R_MESSAGES[2] - 1, R_MESSAGES[1] + R_MESSAGES[3] - 1)
    n = len(last_model_run(grab(rect)))
    done = 0
    for i in range(n):
        run = last_model_run(grab(rect))
        print(f"  [{i + 1}/{n}] {len(run)} still in the run: {run}")
        if not run:
            print("  run is empty - stopping")
            break
        if not unsend_last_message(rect, args):
            print("  ! stopping: a step did not confirm")
            break
        done += 1
        # Let the conversation settle before re-detecting. The unsent message turns into
        # a "Message withdrawn by Silly" placeholder and the list reflows around it; a
        # flat sleep read the list mid-update.
        wait_stable(rect, pane, REFLOW_S)
    return done


# ------------------------------------------------------- background listener --
class _MmaLog:
    """A stdout stand-in that writes MMA's log format:

        2026-07-16 20:15:00  [automation.py]  listening

    Under pythonw.exe there is no console and `sys.stdout` is None, so a bare
    print() raises AttributeError — every print in this module would be a landmine
    in the background. Swapping stdout for this keeps the existing prints working
    and lands them in the same error_log.txt the AHK side already writes to.
    Re-opened per line (like AHK's FileAppend) so the log stays tailable.
    """

    def __init__(self, path: Path, tag: str):
        self.path, self.tag, self._buf = path, tag, ""

    def write(self, s: str) -> int:
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._emit(line)
        return len(s)

    def _emit(self, line: str) -> None:
        if not line.strip():
            return
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(f"{ts}  [{self.tag}]  {line.rstrip()}\n")
        except OSError:
            pass                                   # a log write must never kill the listener

    def flush(self) -> None:
        if self._buf.strip():
            self._emit(self._buf)
            self._buf = ""


_mutex = None            # module-level: the handle must outlive the function


def claim_single_instance() -> bool:
    """False if another listener already holds the mutex. Mirrors #SingleInstance
    on the AHK side — two listeners would run every action twice."""
    global _mutex
    _mutex = k32.CreateMutexW(None, True, MUTEX_NAME)
    return k32.GetLastError() != ERROR_ALREADY_EXISTS


def stop_running_listener() -> bool:
    """Signal a background listener to exit. True if one was listening."""
    h = k32.OpenEventW(0x0002, False, STOP_EVENT_NAME)     # EVENT_MODIFY_STATE
    if not h:
        return False
    k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


def listener_running() -> bool:
    h = k32.OpenEventW(0x0002, False, STOP_EVENT_NAME)
    if not h:
        return False
    k32.CloseHandle(h)
    return True


# -------------------------------------------------------------------- hotkeys --
AHK_MODS = {"^": "ctrl", "!": "alt", "+": "shift", "#": "win"}
MOD_VKS = {"ctrl": (0x11,), "alt": (0x12,), "shift": (0x10,), "win": (0x5B, 0x5C)}

VK_NAMED = {
    "space": 0x20, "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B,
    "tab": 0x09, "backspace": 0x08, "bs": 0x08, "capslock": 0x14,
    "del": 0x2E, "delete": 0x2E, "ins": 0x2D, "insert": 0x2D,
    "home": 0x24, "end": 0x23, "pgup": 0x21, "pgdn": 0x22,
    "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
    "lbutton": 0x01, "rbutton": 0x02, "mbutton": 0x04,
    "xbutton1": 0x05, "xbutton2": 0x06,
}
for _i in range(1, 25):                       # F1..F24 are contiguous from 0x70
    VK_NAMED[f"f{_i}"] = 0x70 + _i - 1


class Hotkey:
    __slots__ = ("raw", "mods", "vk")

    def __init__(self, raw, mods, vk):
        self.raw, self.mods, self.vk = raw, frozenset(mods), vk

    def __repr__(self):
        return f"<Hotkey {self.raw!r} vk=0x{self.vk:02X} mods={sorted(self.mods)}>"


def parse_hotkey(s: str):
    """AHK hotkey syntax -> Hotkey, or None if blank/unsupported.

    Handles the subset hotkeys.ini actually uses: the ^ ! + # prefixes, named keys
    (F1-F24, Space, Del, XButton2, ...) and single characters. Characters go through
    VkKeyScanW so punctuation resolves on the user's real keyboard layout rather
    than a hardcoded US table — that is what makes `!-`, `!+=` and `!+]` work.
    Blank means deliberately disabled, the same convention as the AHK side.
    """
    s = (s or "").strip()
    if not s:
        return None
    mods, i = set(), 0
    while i < len(s) and s[i] in AHK_MODS:
        mods.add(AHK_MODS[s[i]])
        i += 1
    key = s[i:].strip().lstrip("<>")           # <^ / >! left-right variants: not distinguished
    if not key:
        return None
    low = key.lower()
    if low in VK_NAMED:
        return Hotkey(s, mods, VK_NAMED[low])
    if len(key) == 1:
        r = u32.VkKeyScanW(key)
        if r != -1:
            return Hotkey(s, mods, r & 0xFF)
    return None


def _down(vk) -> bool:
    return bool(u32.GetAsyncKeyState(vk) & 0x8000)


def hotkey_down(hk: Hotkey) -> bool:
    """Exact match: ^!k must NOT fire while ^!+k is held, or a key would trigger
    two actions at once."""
    if not _down(hk.vk):
        return False
    for mod, vks in MOD_VKS.items():
        if (mod in hk.mods) != any(_down(v) for v in vks):
            return False
    return True


def _read_ini_text(path: Path) -> str:
    """The Hotkeys GUI writes this file through AHK/Win32, which may leave it ANSI
    or UTF-16 rather than UTF-8. Decode defensively so a hotkey edit can't kill the
    listener."""
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("cp1252", "replace")


def read_hotkeys() -> dict:
    """[automation] from hotkeys.ini -> {action name: raw key string}."""
    if not HOTKEYS_INI.exists():
        return {}
    cp = configparser.ConfigParser(strict=False)
    try:
        cp.read_string(_read_ini_text(HOTKEYS_INI))
    except configparser.Error as e:
        print(f"  ! hotkeys.ini parse error: {e}")
        return {}
    if not cp.has_section(HOTKEY_SECTION):
        return {}
    return {k: v for k, v in cp.items(HOTKEY_SECTION)}


# --- actions: the Python-side equivalent of HK_Bind. Add an entry here, a line in
# --- hotkeys.ini [automation], and an HK_Def in hotkeys.ahk.
# ---------------------------------------------------- notifications > purchases --
def notif_panel_open(rgb) -> bool:
    """Is the Notifications flyout up? Decided on the header band — see NOTIF_OPEN_FILL."""
    x0, y0, x1, y1 = NOTIF_HEADER_BAND
    band = rgb[y0:y1, x0:x1].astype(int)
    return float((np.abs(band - 0x26).sum(2) <= 12).mean()) >= NOTIF_OPEN_FILL


def active_notif_tab(rgb) -> str | None:
    """Which tab is selected, or None. Assumes the panel is open — check that first.

    Takes the widest CONTIGUOUS RUN of accent blue, never cols.min()..cols.max(): the
    tab row holds several blue things, and an extent spanning between two of them
    reported cx=396 for a pill actually centred at 486. That exact mistake (a bare
    max() stretched by unrelated pixels) is what put the Unsend click 25px off target.
    """
    band = rgb[NOTIF_TAB_Y - 14:NOTIF_TAB_Y + 14, NOTIF_PANEL[0]:NOTIF_PANEL[2]].astype(int)
    m = np.abs(band - np.array(ACCENT_BLUE)).sum(2) <= ACCENT_BLUE_TOL * 3
    solid = m.sum(0) >= NOTIF_PILL_MIN_H
    best, run, start = None, 0, 0
    for i, v in enumerate(list(solid) + [False]):
        if v and run == 0:
            start, run = i, 1
        elif v:
            run += 1
        elif run:
            if run >= NOTIF_PILL_MIN_W and (best is None or run > best[1]):
                best = (NOTIF_PANEL[0] + start + run // 2, run)
            run = 0
    if best is None:
        return None
    name, x = min(NOTIF_TABS.items(), key=lambda kv: abs(kv[1] - best[0]))
    return name if abs(x - best[0]) <= NOTIF_PILL_SNAP else None


def find_notif_dividers(rgb) -> list[int]:
    """y of every card divider in the panel, top to bottom. See DIVIDER_MIN_W."""
    x0, x1 = NOTIF_LIST_X
    band = rgb[NOTIF_PANEL[1]:NOTIF_PANEL[3], x0:x1].astype(int)
    m = np.abs(band - np.array(DIVIDER_RGB)).sum(2) <= DIVIDER_TOL * 3
    return [NOTIF_PANEL[1] + i for i, n in enumerate(m.sum(1)) if n >= DIVIDER_MIN_W]


def _card_amount(text: str):
    """Decimal from 'has purchased your message for $25.00!', or None.

    The '$' is NOT part of the match: OCR reads it as 's' perhaps half the time
    ('for s49.49!'), non-deterministically. Anchor on 'for ... !' instead and keep only
    digits and the dot.

    Returns None rather than a guess. This figure is money: a total that is silently
    wrong is worse than one that loudly refuses, so anything not shaped exactly like
    NN.NN is rejected for the caller to report.
    """
    m = re.search(r"for\s*(\S{1,16}?)\s*!", text)
    if not m:
        return None
    raw = re.sub(r"[^\d.]", "", m.group(1).replace(",", ""))
    if not re.fullmatch(r"\d+\.\d{2}", raw):
        return None
    from decimal import Decimal, InvalidOperation
    try:
        return Decimal(raw)
    except InvalidOperation:
        return None


def parse_purchase_card(rgb, y0: int, y1: int) -> dict:
    """One purchase card -> {handle, amount, ts, responder, text}. Any field may be None."""
    boxes = ocr_read(rgb, (NOTIF_LIST_X[0], y0, NOTIF_LIST_X[1], y1))
    text = " ".join(t for _, t in boxes)

    m = re.search(r"@([A-Za-z0-9_]+)", text)
    handle = "@" + m.group(1) if m else None

    m = re.search(r"([A-Z][a-z]{2}\.?\s*\d{1,2},\s*\d{4}\s*at\s*\d{1,2}:\d{2}\s*[AP]M)", text)
    ts = re.sub(r"\s+", " ", m.group(1)) if m else None

    # The responder's NAME is its own OCR box, to the LEFT of ' responded to the
    # notification' on the same line — measured 'silly' at (315,400), the phrase at
    # (417,399). Splitting the phrase's own text yields nothing, so find the phrase
    # then take its left neighbour. Names with spaces survive this; a regex on the
    # joined text would keep only the last word.
    responder = None
    for (px, py), txt in boxes:
        if "respondedtothenotification" in _norm(txt):
            lead = re.split(r"\s*responded\s*to\s*the", txt)[0].strip()
            if lead:
                responder = lead
            else:
                left = [(qx, t) for (qx, qy), t in boxes
                        if abs(qy - py) <= 8 and qx < px and _norm(t)]
                if left:
                    responder = max(left)[1].strip()
            break

    return {"handle": handle, "amount": _card_amount(text), "ts": ts,
            "responder": responder, "text": text}


def read_visible_cards(rgb) -> list[dict]:
    """Every COMPLETE card on screen, top to bottom.

    Only bands between two dividers qualify. The part-cards clipped at the top and
    bottom of the viewport are skipped deliberately: their text is cut, so their
    amount would parse short or not at all. Scrolling brings each into full view.
    """
    ys = find_notif_dividers(rgb)
    return [parse_purchase_card(rgb, a, b) for a, b in zip(ys, ys[1:])]


def notif_thumb(rgb) -> tuple[int, int] | None:
    """Scrollbar thumb as (y0, y1), or None if the list doesn't overflow."""
    col = rgb[NOTIF_PANEL[1]:NOTIF_PANEL[3], SCROLLBAR_X[0]:SCROLLBAR_X[1]].astype(int)
    m = (np.abs(col - SCROLLBAR_RGB).sum(2) <= SCROLLBAR_TOL).sum(1) >= SCROLLBAR_MIN_COLS
    ys = np.where(m)[0]
    if not len(ys):
        return None
    return (NOTIF_PANEL[1] + int(ys.min()), NOTIF_PANEL[1] + int(ys.max()))


def park_cursor(rect) -> None:
    """Move the pointer off the list so nothing is hovered while we capture.

    The hover restyle repaints the card under the cursor, which is what corrupts OCR —
    and the wheel forces us to put the cursor there in the first place. So scroll, then
    leave. See NOTIF_PARK.
    """
    u32.SetCursorPos(rect[0] + NOTIF_PARK[0], rect[1] + NOTIF_PARK[1])
    time.sleep(NOTIF_UNHOVER_S)


def scroll_notif_list(rect, notches: int = SCROLL_NOTCHES) -> None:
    """Wheel the list down, then get the cursor off it before anyone captures."""
    x, y, _, _ = rect
    u32.SetCursorPos(x + (NOTIF_PANEL[0] + NOTIF_PANEL[2]) // 2,
                     y + (NOTIF_LIST_TOP + NOTIF_PANEL[3]) // 2)
    time.sleep(0.05)
    for _ in range(notches):
        u32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, ctypes.c_int(-WHEEL_DELTA), 0)
        time.sleep(0.12)
    park_cursor(rect)
    time.sleep(SCROLL_SETTLE_S)


def _card_key(c: dict):
    return (c["handle"], c["ts"], str(c["amount"]))


def collect_purchase_run(rect, target: str | None = None) -> dict:
    """Walk Purchases from the top, summing one person's sales until someone else appears.

    The run ends at the first card responded to by a DIFFERENT person — that is the
    user's stop rule, and it bounds the work to their shift rather than the whole list.
    `target` defaults to whoever answered the top card.

    Cards with NO responder (nobody replied yet) do NOT end the run — nobody is not
    somebody else — but they are reported separately rather than folded into the total,
    because whether an unanswered sale is "yours" is a judgement call, not ours.
    """
    from decimal import Decimal
    seen: dict = {}
    order: list = []
    unattributed: list = []
    problems: list = []
    stopped_on = None
    reason = f"hit the {SCROLL_MAX_STEPS}-pass safety cap"     # only if we never break
    prev_keys: set = set()
    prev_thumb = None
    idle = 0

    park_cursor(rect)                    # nothing hovered for the FIRST capture either
    for step in range(SCROLL_MAX_STEPS):
        rgb = grab(rect)
        if not notif_panel_open(rgb):
            reason = "the Notifications panel closed mid-run"
            problems.append(reason)
            break
        cards = read_visible_cards(rgb)
        keys = {_card_key(c) for c in cards}

        # Consecutive passes MUST overlap: one step moves ~300px, a viewport holds ~4
        # cards. Sharing nothing means the list jumped further than we can account for
        # and a sale may have passed unseen — worth saying out loud, not swallowing.
        if step and prev_keys and keys and not (keys & prev_keys):
            problems.append(f"pass {step}: no overlap with the previous screen - "
                            f"a card may have been skipped")
        prev_keys = keys

        fresh = 0
        for c in cards:
            k = _card_key(c)
            if k in seen:
                continue
            seen[k] = c
            fresh += 1
            who = c["responder"]
            if who is None:
                unattributed.append(c)
                continue
            if target is None:
                target = who
            if _norm(who) != _norm(target):
                stopped_on = c
                break
            if c["amount"] is None:
                problems.append(f"unreadable amount for {c['handle']} at {c['ts']}: "
                                f"{c['text'][:70]!r}")
                continue
            order.append(c)
        if stopped_on:
            reason = "a different person"
            break

        # Progress = a new card OR the thumb moving. Requiring both to stall is what
        # separates the true bottom from a lazy-load fetch in flight; the pause gives
        # that fetch time to land before we count the pass as idle.
        #
        # No thumb at all means the list is too short to overflow, so scrolling can
        # never reveal anything: that has to count as stalled too, or a short list
        # spins the full safety cap holding the user's cursor hostage for minutes.
        thumb = notif_thumb(rgb)
        if fresh == 0 and (thumb is None or thumb == prev_thumb):
            idle += 1
            if idle >= SCROLL_IDLE_STEPS:
                reason = "the end of the list (nobody else found)"
                break
            time.sleep(LAZY_LOAD_WAIT_S)
        else:
            idle = 0
        prev_thumb = thumb
        scroll_notif_list(rect)

    total = sum((c["amount"] for c in order), Decimal("0"))
    return {"target": target, "sales": order, "total": total,
            "unattributed": unattributed, "problems": problems,
            "stopped_on": stopped_on, "reason": reason, "passes": step + 1}


def action_count_sales(rect, args) -> None:
    """Total one person's sales in Notifications > Purchases, newest first."""
    from decimal import Decimal
    rgb = grab(rect)
    if not notif_panel_open(rgb):
        print("  opening Notifications")
        click(rect[0] + NOTIF_BTN[0], rect[1] + NOTIF_BTN[1], settle=1.2)
        rgb = grab(rect)
        if not notif_panel_open(rgb):
            print("  ! could not open the Notifications panel")
            return
    tab = active_notif_tab(rgb)
    if tab != "purchases":
        print(f"  switching tab: {tab} -> purchases")
        click(rect[0] + NOTIF_TABS["purchases"], rect[1] + NOTIF_TAB_Y, settle=1.2)
        rgb = grab(rect)
        if active_notif_tab(rgb) != "purchases":
            print("  ! Purchases tab did not activate")
            return

    r = collect_purchase_run(rect, getattr(args, "who", None))
    if r["target"] is None:
        print("  no purchases with a responder found")
        return

    print(f"\n  {r['target']}: {len(r['sales'])} sale(s)  =  ${r['total']}")
    for c in r["sales"]:
        print(f"    ${str(c['amount']):>9}  {c['ts']:<26} {c['handle']}")
    if r["stopped_on"]:
        s = r["stopped_on"]
        print(f"  stopped on {r['reason']}: {s['responder']!r} answered {s['handle']} "
              f"at {s['ts']}  ({r['passes']} passes)")
    else:
        # Always say WHY it ended. "Reached the end" and "gave up early" produce the same
        # tidy total, and only one of them is trustworthy.
        print(f"  stopped: {r['reason']}  ({r['passes']} passes)")
    if r["unattributed"]:
        u = sum((c["amount"] for c in r["unattributed"] if c["amount"]), Decimal("0"))
        print(f"  NOT counted - {len(r['unattributed'])} purchase(s) with no responder, "
              f"${u}")
        for c in r["unattributed"]:
            print(f"    ${str(c['amount']):>9}  {c['ts']:<26} {c['handle']}")
    for p in r["problems"]:
        print(f"  ! {p}")


def action_hop_kebabs(rect, args) -> None:
    rgb = grab(rect)
    kebabs = find_model_kebabs(rgb)
    print(f"  {len(kebabs)} kebab(s): {kebabs}")
    if kebabs:
        hop(kebabs, rect, duration=args.duration, dwell=args.dwell)


def action_unsend_last(rect, args) -> None:
    """Unsend your last message. If your last run has more than one, ask first."""
    run = last_model_run(grab(rect))
    if not run:
        print("  nothing of yours to unsend since the fan's last reply")
        return
    if len(run) == 1:
        unsend_last_message(rect, args)
        return
    hk = getattr(args, "_hotkey", None)           # set by the listener; absent via CLI
    choice = prompt_unsend_choice(hk, len(run), rect) if hk else "last"
    print(f"  {len(run)} in the last run -> {choice}")
    if choice == "cancel":
        return
    if choice == "all":
        print(f"  unsent {unsend_run(rect, args)}")
    else:
        unsend_last_message(rect, args)


ACTIONS = {                                    # configparser lowercases keys
    "hopkebabs": action_hop_kebabs,
    "unsendlast": action_unsend_last,
    "countsales": action_count_sales,
}


def listen(args) -> int:
    """Poll for the [automation] hotkeys and run their actions.

    Polling (GetAsyncKeyState), not RegisterHotKey, and deliberately: RegisterHotKey
    is global and would swallow the key from every other app even when Infloww is not
    active. Polling only observes, so the key still reaches whatever you are using.
    It also matches live_detector.py, which polls Esc/F8 the same way.

    Runs headless under pythonw.exe (see automation_listen.vbs): output goes to MMA's
    error_log.txt, and `--stop` ends it since there is no console to Ctrl+C.
    """
    # Route output BEFORE anything prints. Under pythonw sys.stdout is None and the
    # first print() would raise; with a console we keep it and just stop it
    # block-buffering, which otherwise hides progress behind a pipe.
    headless = sys.stdout is None
    if headless or args.log:
        sys.stdout = sys.stderr = _MmaLog(MMA_LOG, LOG_TAG)
    else:
        try:
            sys.stdout.reconfigure(line_buffering=True)
        except Exception:
            pass

    if not claim_single_instance():
        print("another listener is already running - not starting a second")
        return 1

    # Created (not opened) here: its existence is also how --status/--stop find us.
    # CreateEventW returns the EXISTING object if the name is still live, and it is
    # manual-reset — so a stale, still-set event from the previous listener would make
    # this one exit instantly. Reset it: our own start is the only thing that clears it.
    stop_evt = k32.CreateEventW(None, True, False, STOP_EVENT_NAME)
    k32.ResetEvent(stop_evt)

    keys, mtime, bound = {}, None, {}

    def refresh():
        nonlocal keys, bound
        keys = read_hotkeys()
        bound = {}
        for name, raw in keys.items():
            if name not in ACTIONS:
                print(f"  ! [automation] {name!r} has no action in ACTIONS - ignored")
                continue
            hk = parse_hotkey(raw)
            if hk is None:
                print(f"  - {name}: {'disabled (blank)' if not raw.strip() else f'unsupported key {raw!r}'}")
                continue
            bound[name] = hk
            print(f"  - {name} = {hk.raw}")
        for name in ACTIONS:
            if name not in keys:
                print(f"  ! ACTIONS has {name!r} but hotkeys.ini [automation] does not")

    print(f"reading {HOTKEYS_INI}")
    refresh()
    mtime = HOTKEYS_INI.stat().st_mtime if HOTKEYS_INI.exists() else None
    if not bound:
        print("nothing bound - add a key under [automation] in hotkeys.ini")
    how = "--stop to end" if headless else "Ctrl+C or --stop to end"
    print(f"listening (only while {TARGET_TITLE!r} is active) - {how}")

    prev = {}
    try:
        while True:
            if k32.WaitForSingleObject(stop_evt, 0) == 0:      # WAIT_OBJECT_0
                print("stop requested - exiting")
                break

            # hot-reload, matching the ini's own promise: "Changes apply live"
            if HOTKEYS_INI.exists():
                m = HOTKEYS_INI.stat().st_mtime
                if m != mtime:
                    mtime = m
                    print("hotkeys.ini changed - reloading")
                    refresh()

            active = TARGET_TITLE.lower() in foreground_title().lower()
            for name, hk in bound.items():
                now = hotkey_down(hk)
                if now and not prev.get(name) and active:
                    print(f"{hk.raw} -> {name}")
                    try:
                        _, rect = require_window(force=args.force)
                        args._hotkey = hk          # so an action can offer "press again"
                        ACTIONS[name](rect, args)
                    except WindowNotReady as e:
                        print(f"  ! {e}")
                    except Exception:
                        # One bad action must never kill the listener. Only
                        # WindowNotReady was caught before, so any surprise (tkinter,
                        # OCR, numpy) took the whole background process down with it.
                        print("  ! action crashed - listener survives:")
                        print(traceback.format_exc())
                    now = hotkey_down(hk)          # re-read: the action took seconds
                prev[name] = now
            time.sleep(POLL_S)
    except KeyboardInterrupt:
        print("stopped (Ctrl+C)")
    finally:
        k32.CloseHandle(stop_evt)
        sys.stdout.flush()
    return 0


# ------------------------------------------------------------------------ cli --
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", metavar="PNG",
                    help="detect against a saved window capture instead of the live app")
    ap.add_argument("--hop", action="store_true", help="hop the cursor over each kebab")
    ap.add_argument("--unsend", action="store_true",
                    help="unsend your last message (use with --dry-run first)")
    ap.add_argument("--count-sales", action="store_true",
                    help="total one person's sales in Notifications > Purchases")
    ap.add_argument("--who", metavar="NAME",
                    help="whose sales to count (default: whoever answered the top card)")
    ap.add_argument("--listen", action="store_true",
                    help="stay resident and run [automation] hotkeys from hotkeys.ini")
    ap.add_argument("--stop", action="store_true",
                    help="end a background listener (it has no console to Ctrl+C)")
    ap.add_argument("--status", action="store_true", help="is a listener running?")
    ap.add_argument("--log", action="store_true",
                    help="force logging to error_log.txt even with a console")
    ap.add_argument("--dry-run", action="store_true", help="detect + report, never move")
    ap.add_argument("--force", action="store_true", help="skip the window-size check")
    ap.add_argument("--duration", type=float, default=0.7, help="seconds per hop")
    ap.add_argument("--dwell", type=float, default=0.6, help="seconds paused on each")
    a = ap.parse_args(argv)

    set_dpi_aware()

    if a.status:
        print("listener: RUNNING" if listener_running() else "listener: not running")
        return 0

    if a.stop:
        if stop_running_listener():
            print("stop signalled")
            return 0
        print("no listener running")
        return 1

    if a.listen:
        return listen(a)

    if a.image:
        from PIL import Image
        rgb = np.array(Image.open(a.image).convert("RGB"))
        if (rgb.shape[1], rgb.shape[0]) not in REF_IMG_SIZES:
            print(f"note: {a.image} is {rgb.shape[1]}x{rgb.shape[0]}, not a full-window "
                  f"capture ({REF_W}x{REF_H}) — region offsets will not line up")
        kebabs = find_model_kebabs(rgb)
        print(f"{len(kebabs)} model kebab(s) in {a.image}:")
        for i, (x, y) in enumerate(kebabs, 1):
            print(f"  [{i}] window ({x},{y})")
        return 0

    try:
        _, rect = require_window(force=a.force)
    except WindowNotReady as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if a.count_sales:
        action_count_sales(rect, a)              # reads the panel; no kebabs involved
        return 0

    rgb = grab(rect)
    kebabs = find_model_kebabs(rgb)
    run = last_model_run(rgb)
    print(f"{len(kebabs)} model kebab(s) found (window {rect[2]}x{rect[3]} at "
          f"{rect[0]},{rect[1]}); {len(run)} in your last run:")
    for i, (x, y) in enumerate(kebabs, 1):
        tag = "  <- last run" if (x, y) in run else ""
        print(f"  [{i}] window ({x},{y}) -> screen {to_screen(rect, x, y)}{tag}")

    if a.unsend:
        a._hotkey = None
        if a.dry_run:
            print("dry run: walks the whole flow and cancels at the modal "
                  "(only the modal click is destructive)")
        action_unsend_last(rect, a)
        return 0

    if not kebabs:
        return 0
    if a.dry_run or not a.hop:
        if not a.hop:
            print("(pass --hop to move the cursor)")
        return 0

    print(f"hopping {len(kebabs)} point(s) - Esc aborts")
    hop(kebabs, rect, duration=a.duration, dwell=a.dwell)
    return 0


if __name__ == "__main__":
    sys.exit(main())
