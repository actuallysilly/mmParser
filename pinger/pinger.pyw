#!/usr/bin/env python3
"""
MMA pinger — plays a sound when an Infloww fan tab goes unread.

Detects two things, both drawn in Infloww's single unread colour #ff7c71:

  * the 6x6 dot next to a fan tab's name
  * the 12x12 count badge on the tab-overflow chip ("7 v"), which is the only
    signal for tabs scrolled out of view

Scoped to the Infloww window (via PrintWindow, so it reads while the window is
occluded or unfocused) and to the fan tab strip only. The model tab strip
directly above carries permanent coral count badges of its own; including it is
what made the previous colour-range scan latch on and never fire again.

Geometry is measured per frame rather than hard-coded: the tab strip shrinks its
tab pitch as tabs are added (170px at 4 tabs, 130px at 13), so slot arithmetic
against a fixed pitch does not survive a real session. Note this contradicts the
fixed pitch 170 / `(x-3)//170` recorded in ../infloww ui elements/UI-ELEMENT-MAP.md,
which was measured on a 4-tab capture.

Runs headless under pythonw.exe (see pinger_start.vbs): no console, output goes
to MMA's error_log.txt. MMA launches and stops it from the Settings window the
same way it drives the automation listener.

    pinger_start.vbs        start it silently
    pinger.pyw --stop       ask a background pinger to exit
    pinger.pyw --status     is one running?
    pinger.pyw --once       one scan, printed (for debugging)
"""

import argparse
import ctypes
import ctypes.wintypes as wintypes
import os
import sys
import time
import winsound
from datetime import datetime

import cv2
import numpy as np

# ── Configuration ────────────────────────────────────────────────────────────

WINDOW_TITLE   = "Infloww"   # case-insensitive substring
POLL_INTERVAL  = 2.0         # seconds between scans
REPEAT_EVERY   = 15          # re-alert every N polls while anything stays unread

# Unread colour and how far a pixel may stray from it (sum of per-channel
# absolute difference). Measured cores are exactly #ff7c71; the slack covers
# antialiased edge pixels only.
CORAL          = (0xFF, 0x7C, 0x71)
CORAL_TOL      = 60

# Shape profiles. A blob must match one of these to count.
DOT_PX         = (12, 60)    # measured 24px in both reference captures
DOT_SIDE       = (4, 10)     # measured 6x6
# The badge is a pill that widens with digit count: 12x12 at "2", and the same
# control on a model tab measures 18x12 at one digit and 23x12 at two. Sized to
# accept a multi-digit overflow count. Safe to be this loose only because the
# model tab strip, which carries identical badges permanently, is cropped out
# before detection ever runs.
BADGE_PX       = (45, 210)   # measured 80px at "2"; 189px at a 2-digit pill
BADGE_SIDE_W   = (9, 26)
BADGE_SIDE_H   = (9, 16)     # height stays 12 regardless of digit count
MAX_ASPECT     = 2.6         # dots are round; badges stretch horizontally only

# The overflow chip is pinned to the right end of the strip, so its badge is
# always in the far right of the frame. Model tab badges sit at the left
# (measured x 87/235/385). Requiring this keeps the loose badge profile from
# matching a model badge even if the strip crop above ever fails.
BADGE_RIGHT_FRAC = 0.85

# Fan tab strip. Located per frame by colour; these are the fallback bounds and
# the search window for the locator.
STRIP_FILL     = ((0x2B, 0x2C, 0x30), (0x4D, 0x51, 0x59), (0x4D, 0x4E, 0x51))
STRIP_FALLBACK = (47, 82)
STRIP_SEARCH   = (20, 140)

# Alert sound. Set SOUND_FILE to an absolute .wav path to play a file instead.
SOUND_FILE     = None

# ─────────────────────────────────────────────────────────────────────────────

u32 = ctypes.windll.user32
g32 = ctypes.windll.gdi32
k32 = ctypes.windll.kernel32

PW_RENDERFULLCONTENT = 0x00000002

# Same scheme automation.py uses: one named event doubles as the "is it running?"
# flag (OpenEvent succeeds only while the pinger holds it) and the stop signal.
# It has no console to Ctrl+C and is not an AHK window, so MMA cannot otherwise
# see or close it.
MUTEX_NAME      = "Global\\MMA.pinger.mutex"
STOP_EVENT_NAME = "Global\\MMA.pinger.stop"
ERROR_ALREADY_EXISTS = 183

LOG_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "error_log.txt")


_mutex = None            # module-level: the handle must outlive the function
_stop_event = None


def claim_single_instance() -> bool:
    """False if another pinger already holds the mutex. Two of them would beep
    twice for every message."""
    global _mutex
    _mutex = k32.CreateMutexW(None, True, MUTEX_NAME)
    return k32.GetLastError() != ERROR_ALREADY_EXISTS


def create_stop_event() -> None:
    global _stop_event
    _stop_event = k32.CreateEventW(None, True, False, STOP_EVENT_NAME)


def stop_requested() -> bool:
    if not _stop_event:
        return False
    return k32.WaitForSingleObject(_stop_event, 0) == 0      # WAIT_OBJECT_0


def stop_running_pinger() -> bool:
    """Signal a background pinger to exit. True if one was running."""
    h = k32.OpenEventW(0x0002, False, STOP_EVENT_NAME)       # EVENT_MODIFY_STATE
    if not h:
        return False
    k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


def pinger_running() -> bool:
    h = k32.OpenEventW(0x0002, False, STOP_EVENT_NAME)
    if not h:
        return False
    k32.CloseHandle(h)
    return True


class _MmaLog:
    """Headless under pythonw there is no console, so stdout goes to MMA's log."""

    def __init__(self, tag="pinger"):
        self.tag, self._buf = tag, ""

    def write(self, s):
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._emit(line)

    def _emit(self, line):
        if not line.strip():
            return
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(f"{stamp}  [{self.tag}]  {line.rstrip()}\n")
        except OSError:
            pass                                   # a log write must never kill it

    def flush(self):
        if self._buf.strip():
            self._emit(self._buf)
            self._buf = ""


def set_dpi_aware() -> None:
    """Must run before any coordinate read, or Windows lies about pixels."""
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)      # per-monitor v2
    except Exception:
        try:
            u32.SetProcessDPIAware()
        except Exception:
            pass


# ------------------------------------------------------------------ capture --
def find_window(title: str):
    """First visible top-level window whose title contains `title`."""
    found = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        if not u32.IsWindowVisible(hwnd):
            return True
        n = u32.GetWindowTextLengthW(hwnd)
        if not n:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        u32.GetWindowTextW(hwnd, buf, n + 1)
        if title.lower() in buf.value.lower():
            found.append((hwnd, buf.value))
            return False
        return True

    u32.EnumWindows(cb, 0)
    return found[0] if found else (None, None)


def print_window(hwnd) -> "np.ndarray | None":
    """Capture a window's own pixels, even when it is behind another window.

    Returns RGB, or None if the window is minimised / gave us nothing.
    """
    r = wintypes.RECT()
    if not u32.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    w, h = r.right - r.left, r.bottom - r.top
    if w <= 0 or h <= 0:
        return None

    hdc = u32.GetWindowDC(hwnd)
    if not hdc:
        return None
    mem = bmp = None
    try:
        mem = g32.CreateCompatibleDC(hdc)
        bmp = g32.CreateCompatibleBitmap(hdc, w, h)
        g32.SelectObject(mem, bmp)
        # flag 2 is required for Chromium/Electron surfaces; 0 returns blank
        if not u32.PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT):
            return None

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long),
                        ("biHeight", ctypes.c_long), ("biPlanes", wintypes.WORD),
                        ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                        ("biSizeImage", wintypes.DWORD),
                        ("biXPelsPerMeter", ctypes.c_long),
                        ("biYPelsPerMeter", ctypes.c_long),
                        ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]

        bi = BITMAPINFOHEADER()
        bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bi.biWidth, bi.biHeight = w, -h      # negative = top-down
        bi.biPlanes, bi.biBitCount = 1, 32
        bi.biCompression = 0                 # BI_RGB

        buf = ctypes.create_string_buffer(w * h * 4)
        if not g32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bi), 0):
            return None
        arr = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4)
        return arr[:, :, 2::-1]              # BGRA -> RGB
    finally:
        if bmp:
            g32.DeleteObject(bmp)
        if mem:
            g32.DeleteDC(mem)
        u32.ReleaseDC(hwnd, hdc)


# ------------------------------------------------------------------ geometry --
def locate_strip(rgb: np.ndarray) -> tuple[int, int]:
    """Find the fan tab strip's row range by its fill colours.

    Resolution- and chrome-independent, which a hard-coded y 49..80 is not.
    Falls back to the measured bounds if the signature is not found.
    """
    lo, hi = STRIP_SEARCH
    hi = min(hi, rgb.shape[0])
    rows = []
    for y in range(lo, hi):
        row = rgb[y].astype(int)
        for fill in STRIP_FILL:
            if (np.abs(row - np.array(fill)).sum(axis=1) <= 24).mean() > 0.30:
                rows.append(y)
                break
    if not rows:
        return STRIP_FALLBACK
    # longest contiguous run
    best = run = [rows[0]]
    for y in rows[1:]:
        if y == run[-1] + 1:
            run.append(y)
        else:
            run = [y]
        if len(run) > len(best):
            best = run
    # pad by 2 so the overflow badge, which sits flush with the strip's top
    # edge at y49, is never clipped by a 1px window shift
    return max(0, best[0] - 2), min(rgb.shape[0], best[-1] + 2)


def tab_edges(band: np.ndarray) -> list[int]:
    """x of each inter-tab gap, read from the strip background showing through.

    Derived per frame because tab pitch depends on how many tabs are open.
    """
    y = min(band.shape[0] - 1, int(band.shape[0] * 0.85))
    row = band[y].astype(int)
    gap = np.abs(row - np.array(STRIP_FILL[0])).sum(axis=1) <= 24
    edges, run = [], []
    for x, is_gap in enumerate(gap):
        if is_gap:
            run.append(x)
        elif run:
            edges.append(sum(run) // len(run))
            run = []
    if run:
        edges.append(sum(run) // len(run))
    return edges


# ----------------------------------------------------------------- detection --
def find_markers(band: np.ndarray) -> list[dict]:
    """Coral blobs in the strip that are shaped like an unread marker."""
    d = np.abs(band.astype(np.int16) - np.array(CORAL, np.int16)).sum(axis=2)
    mask = (d <= CORAL_TOL).astype(np.uint8)
    n, _, stats, cent = cv2.connectedComponentsWithStats(mask, connectivity=8)

    out = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        if h == 0 or w == 0:
            continue
        if max(w / h, h / w) > MAX_ASPECT:
            continue
        if (DOT_PX[0] <= area <= DOT_PX[1]
                and DOT_SIDE[0] <= w <= DOT_SIDE[1]
                and DOT_SIDE[0] <= h <= DOT_SIDE[1]):
            kind = "dot"
        elif (BADGE_PX[0] <= area <= BADGE_PX[1]
                and BADGE_SIDE_W[0] <= w <= BADGE_SIDE_W[1]
                and BADGE_SIDE_H[0] <= h <= BADGE_SIDE_H[1]
                and (x + w / 2) >= band.shape[1] * BADGE_RIGHT_FRAC):
            kind = "badge"
        else:
            continue
        out.append({"kind": kind, "x": int(cent[i][0]), "y": int(cent[i][1]),
                    "px": int(area), "w": int(w), "h": int(h)})
    return sorted(out, key=lambda m: m["x"])


def label_markers(markers: list[dict], edges: list[int]) -> list[dict]:
    """Attach a tab slot index to each dot, for readable logging."""
    for m in markers:
        if m["kind"] == "badge":
            m["slot"] = "overflow"
        else:
            m["slot"] = sum(1 for e in edges if e < m["x"])
    return markers


# --------------------------------------------------------------------- alert --
def play_alert() -> None:
    if SOUND_FILE and os.path.exists(SOUND_FILE):
        winsound.PlaySound(SOUND_FILE, winsound.SND_FILENAME | winsound.SND_ASYNC)
        return
    winsound.PlaySound("SystemExclamation", winsound.SND_ALIAS | winsound.SND_ASYNC)


def ts() -> str:
    return datetime.now().strftime("%H:%M:%S")


def describe(markers: list[dict]) -> str:
    dots = [str(m["slot"]) for m in markers if m["kind"] == "dot"]
    parts = []
    if dots:
        parts.append("tab " + ", ".join(dots))
    if any(m["kind"] == "badge" for m in markers):
        parts.append("hidden tabs (overflow badge)")
    return " + ".join(parts)


# ---------------------------------------------------------------------- main --
def scan(hwnd, debug=False, save=None):
    rgb = print_window(hwnd)
    if rgb is None or rgb.shape[0] < STRIP_SEARCH[1] or int(rgb.max()) < 12:
        return None                       # minimised, or capture came back blank

    top, bot = locate_strip(rgb)
    band = rgb[top:bot]
    markers = label_markers(find_markers(band), tab_edges(band))

    if save:
        vis = cv2.cvtColor(band, cv2.COLOR_RGB2BGR).copy()
        for m in markers:
            cv2.rectangle(vis, (m["x"] - 8, m["y"] - 8), (m["x"] + 8, m["y"] + 8),
                          (0, 255, 0), 1)
        cv2.imwrite(save, vis)
    if debug:
        print(f"[{ts()}]  strip y{top}..{bot}  "
              f"{len(tab_edges(band))} gaps  {len(markers)} marker(s)"
              + (f"  -> {describe(markers)}" if markers else ""))
    return markers


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--once", action="store_true", help="scan once and exit")
    ap.add_argument("--debug", action="store_true", help="log every poll")
    ap.add_argument("--save", metavar="PNG", help="write annotated strip each poll")
    ap.add_argument("--interval", type=float, default=POLL_INTERVAL)
    ap.add_argument("--title", default=WINDOW_TITLE)
    ap.add_argument("--stop", action="store_true", help="stop a running pinger")
    ap.add_argument("--status", action="store_true", help="report whether one runs")
    ap.add_argument("--listen", action="store_true",
                    help="headless mode: log to MMA's error_log.txt")
    args = ap.parse_args(argv)

    if args.stop:
        print("stopped" if stop_running_pinger() else "not running")
        return 0
    if args.status:
        running = pinger_running()
        print("running" if running else "not running")
        return 0 if running else 1

    if args.listen:
        sys.stdout = sys.stderr = _MmaLog()

    set_dpi_aware()

    if not args.once and not claim_single_instance():
        print("another pinger is already running — exiting")
        return 0
    if not args.once:
        create_stop_event()

    hwnd, title = find_window(args.title)

    if args.once and not hwnd:
        print(f"No visible window matching {args.title!r}. Is Infloww running?")
        return 1

    if args.once:
        markers = scan(hwnd, debug=True, save=args.save)
        if markers is None:
            why = ("is minimised — restore it (it may stay behind other windows)"
                   if u32.IsIconic(hwnd) else "returned a blank frame")
            print(f"Cannot read the window: it {why}.")
            return 1
        print(f"{len(markers)} unread marker(s)"
              + (f": {describe(markers)}" if markers else ""))
        for m in markers:
            print(f"   {m['kind']:5s} slot={m['slot']} x={m['x']} y={m['y']} "
                  f"{m['px']}px {m['w']}x{m['h']}")
        return 0

    # Infloww not being open is a normal waiting state, NOT a startup failure.
    # Exiting here made MMA's 5s watchdog respawn the pinger forever: each run
    # spawned wscript -> pythonw, printed this line, and died. The poll loop
    # already waits for the window and reattaches, so just start it with no
    # window and let it do that.
    if hwnd:
        print(f"MMA pinger  |  watching {title!r}  every {args.interval}s")
    else:
        print(f"MMA pinger  |  waiting for a window matching {args.title!r}")

    print(f"Re-alerting every {REPEAT_EVERY} polls while unread. Ctrl+C to stop.\n")
    prev = 0
    since = 0
    blind = not hwnd            # already reported above; don't repeat it each poll

    while True:
        if stop_requested():
            print("stop requested — exiting")
            sys.stdout.flush()
            return 0

        markers = scan(hwnd, debug=args.debug, save=args.save)

        if markers is None:                       # cannot read the window this poll
            if not u32.IsWindow(hwnd):
                hwnd, title = find_window(args.title)
                if hwnd:
                    print(f"[{ts()}]  reattached to {title!r}")
                    blind = False
                elif not blind:
                    print(f"[{ts()}]  window gone — waiting for it to come back")
                    blind = True
            elif not blind:
                # PrintWindow reads a window that is merely covered by another,
                # but a minimised window has no surface to read at all.
                why = ("minimised — restore it (it may stay behind other windows)"
                       if u32.IsIconic(hwnd) else "returned a blank frame")
                print(f"[{ts()}]  BLIND: window {why}. Not watching.")
                blind = True
            time.sleep(args.interval)
            continue

        if blind:
            print(f"[{ts()}]  window readable again — watching")
            blind = False

        count = len(markers)
        if count > prev:
            print(f"[{ts()}]  unread: {describe(markers)} — alerting")
            play_alert()
            since = 0
        elif count > 0:
            since += 1
            if since >= REPEAT_EVERY:
                print(f"[{ts()}]  still unread: {describe(markers)} — re-alerting")
                play_alert()
                since = 0
        elif prev > 0:
            print(f"[{ts()}]  all clear — watching")
            since = 0

        prev = count
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(0)
