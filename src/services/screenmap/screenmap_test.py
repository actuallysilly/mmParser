"""
Offline checks for the Screen Map's measuring, on saved captures. Reads only
files in tools/ui-research; writes nothing (the map file is never touched).

    python src/services/screenmap/screenmap_test.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import screenmap as S  # noqa: E402

REF = S.MMA_ROOT / "tools" / "ui-research"
fails = 0


def check(what: str, got, want) -> None:
    global fails
    ok = got == want
    fails += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {what}: {got!r}" + ("" if ok else f" (want {want!r})"))


def img(name: str) -> np.ndarray:
    return np.asarray(Image.open(REF / name).convert("RGB"))


def main() -> int:
    sys.stdout = sys.__stdout__
    print("main window, 2 model tabs, CIN lit, chat open (3441x1381):")
    a = img("work_window_list.png")
    m = S.measure(a)
    check("kind", m.kind, "main")
    check("status", m.status, "ok")
    check("scale", round(m.scale, 2), 1.37)
    check("chat open", m.chat_open, True)
    check("list|conversation divider", m.regions["list"][2], 551)
    check("messages", m.regions["messages"], [551, 185, 2504, 965])
    check("active tab x", m.regions["active_tab"][0], 41)
    check("spot check holds", S.check_pixels(a, m.check), True)
    check("model", S.read_model(a, m), "CIN")
    check("tabs", S.read_tabs(a, m), ["CIN", "HAIL"])
    # The pane must agree with the chat reader's own finder, which it replaces.
    lay = S.transcript_layout(m)
    import transcript as T
    old = T.find_layout(a)
    check("same pane as transcript.find_layout", lay.region, old.region)

    print("fan window (Open in new tab), CIN (3441x1381):")
    a = img("harvest_scrolled.png")
    m = S.measure(a)
    check("kind", m.kind, "fan")
    check("status", m.status, "ok")
    check("no chat list", "list" in m.regions, False)
    check("model", S.read_model(a, m), "CIN")

    print("popup open over the window (everything dimmed):")
    a = img("name_modal.png")
    m = S.measure(a)
    check("status", m.status, "unsure")
    check("reason", m.reason, "a popup is open over Infloww (everything is dimmed)")

    print("old reference, 1920x1034, AW lit:")
    a = img("Whole UI.png")
    m = S.measure(a)
    check("kind", m.kind, "main")
    check("scale", m.scale, 1.0)
    check("messages = automation.py's R_MESSAGES", m.regions["messages"], [401, 135, 1237, 727])
    check("model (case-insensitive)", S.read_model(a, m).upper(), "AW")

    print("spot check catches a tab switch:")
    a = img("work_window_list.png").copy()
    m = S.measure(a)
    x, y, *_ = m.check[1]
    a[y, x] = (13, 13, 13)                  # the lit tab went dark
    check("fails after the tab changed", S.check_pixels(a, m.check), False)

    print("Infloww Home is not measured:")
    check("kind", S.measure(img("work_window_list.png"), "Infloww Home - 333").kind, "home")

    print(f"\n{'ALL PASSED' if not fails else f'{fails} FAILED'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
