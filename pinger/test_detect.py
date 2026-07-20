"""Regression test for the pinger's unread detection.

Runs the detector over every reference capture we have and asserts the marker
count. Worth keeping because the thing this detector depends on -- Infloww's tab
strip geometry -- has already drifted once: UI-ELEMENT-MAP.md records a fixed tab
pitch of 170px measured on a 4-tab capture, but a real 13-tab strip is 130px.

    python test_detect.py
"""

import importlib.util
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "reference")
UI = os.path.join(os.path.dirname(HERE), "infloww ui elements")

spec = importlib.util.spec_from_file_location("pinger", os.path.join(HERE, "pinger.pyw"))
pinger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinger)

# (path, description, expected marker count). None = informational only.
CASES = [
    (f"{REF}/tabs_clean.png",     "13 tabs, nothing unread",              0),
    (f"{REF}/tab_unread.png",     "tab dot, unread",                      1),
    (f"{REF}/overflow_badge.png", "overflow chip badge, 2 hidden unread", 1),
    (f"{UI}/Whole UI.png",        "full window, one tab unread",          1),
    (f"{UI}/Chat subwindow 1.png", "chat subwindow, no strip",            0),
    (f"{UI}/3 Model tabs open.png", "model strip, red count badges",      0),
    (f"{UI}/two model tabs open.png", "model strip, red + green badges",  0),
    (f"{UI}/contact_sheet.png",   "contact sheet of every UI element",    0),
]


def run() -> int:
    fails = 0
    for path, desc, expect in CASES:
        if not os.path.exists(path):
            print(f"SKIP  {desc:38s} (missing {os.path.basename(path)})")
            continue
        rgb = np.asarray(Image.open(path).convert("RGB"))

        # Bare crops shorter than the strip locator's search window have no strip
        # to find; scan them whole so the shape and position filters still get
        # exercised. A full window capture always takes the locate_strip path.
        if rgb.shape[0] < pinger.STRIP_SEARCH[1]:
            top, bot = 0, rgb.shape[0]
        else:
            top, bot = pinger.locate_strip(rgb)

        band = rgb[top:bot]
        markers = pinger.label_markers(pinger.find_markers(band), pinger.tab_edges(band))
        n = len(markers)
        ok = expect is None or n == expect
        fails += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'}  {desc:38s} -> {n} marker(s)"
              + ("" if ok else f", expected {expect}"))
        for m in markers:
            print(f"          {m['kind']:5s} slot={m['slot']} x={m['x']} "
                  f"{m['px']}px {m['w']}x{m['h']}")

    print("\nALL PASS" if not fails else f"\n{fails} FAILURE(S)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(run())
