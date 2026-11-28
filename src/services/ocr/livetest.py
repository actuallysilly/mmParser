"""
ocr/livetest.py — old engine vs the Infloww reader on the LIVE Infloww windows.

Read-only: PrintWindow captures (no focus, no clicks, no keys), like the Screen Map.

    python livetest.py [--out DIR]

For every open "Infloww Messages" window it reads, with BOTH engines:
    header   the open chat's fan name
    list     every visible chat-list row ("name @handle")
    chat     every text line of every message in the open chat (and, per message,
             the chat reader's own read_turns() text for comparison)
Every cut is saved as a PNG next to reads.tsv, so each reading can be checked by eye.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "screenmap"))
import reader as RD                                  # noqa: E402
import screenmap as S                                # noqa: E402
import transcript as T                               # noqa: E402  (path set by screenmap)
import fanid                                         # noqa: E402


def old_read(crop: np.ndarray) -> str:
    """Today's live engine (PP-OCR v3) on the SAME cut, the way MMA's readers call it."""
    boxes = fanid._ocr_lines(crop, np.median(crop.reshape(-1, 3), 0))
    return " ".join(b[2] for b in sorted(boxes, key=lambda b: b[1])).strip()


def list_rows(rgb: np.ndarray, m) -> list[tuple[int, int, int, int]]:
    """Row boxes of the chat list, found by their round avatars: a 40-CSS-px blob
    centred 39 px in. The spend tag under it is too short to pass for one."""
    x, y, w, h = m.regions["list"]
    s = m.scale
    # Avatars are #666 grey or coloured; every row background (#151515, the
    # selected #353535, hover #1b1b1b) and the spend tag (#262626) are darker.
    col = rgb[y:y + h, round(39 * s)].astype(np.int16)
    ink = col.max(1) >= 70
    out = []
    for r0, r1 in RD._ink_runs(ink, gap=2):
        # 40 px avatar; with the spend tag touching under it, up to ~62 px.
        if 32 * s <= r1 - r0 <= 66 * s:
            top = y + r0 - round(16 * s)                 # avatar sits 16 px into its row
            if top >= y and top + 34 * s < y + h:
                out.append((0, top, w, round(96 * s)))
    return out


def bubble_lines(rgb: np.ndarray, box, scale: float, bg) -> list[np.ndarray]:
    """Each text line of one message bubble, cut like a practice picture."""
    x0, y0, x1, y1 = box
    sub = rgb[y0:y1 + 1, x0:x1 + 1]
    out = []
    for by0, by1 in T.text_bands(sub):
        ix0, ix1 = T.ink_extent(sub[by0:by1])
        mid = y0 + (by0 + by1) / 2
        b0, b1 = RD._band(rgb, mid, scale)
        a0 = max(0, x0 + ix0 - round(6 * scale))
        crop = rgb[b0:b1, a0:x0 + ix1 + round(8 * scale)].copy()
        fill = np.array(bg, np.uint8)
        top, bot = (y0 + by0 - round(2 * scale)) - b0, (y0 + by1 + round(2 * scale)) - b0
        if top > 0:
            crop[:top] = fill
        if 0 < bot < crop.shape[0]:
            crop[bot:] = fill
        out.append(crop)
    return out


def main(argv=None) -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(S.MMA_ROOT / "userdata" / "ocr" / "live" / time.strftime("%Y%m%d-%H%M%S")))
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    T.A.set_dpi_aware()
    rows, k = [], 0

    def keep(kind: str, crop: np.ndarray, extra: dict | None = None):
        nonlocal k
        if crop is None or crop.size == 0:
            return
        name = f"{k:03d}_{kind}.png"
        k += 1
        Image.fromarray(crop).save(out / name)
        new = RD.read_line(crop)
        rec = {"file": name, "kind": kind, "new": new.text, "conf": round(new.conf, 3),
               "old": old_read(crop)}
        if extra:
            rec.update(extra)
        rows.append(rec)

    for hwnd, title in T._matching_windows("Infloww Messages"):
        rgb = T._pinger.print_window(hwnd)
        if rgb is None:
            continue
        m = S.measure(rgb, title)
        print(f"{hwnd:#x} {m.kind} {m.status} {m.reason} {rgb.shape[1]}x{rgb.shape[0]} scale {m.scale:.3f}")
        if m.status != "ok":
            continue
        Image.fromarray(rgb).save(out / f"window_{hwnd:x}.png")
        reg = m.regions
        if "header" in reg:
            keep("header", RD.header_line(rgb, reg["header"], m.scale),
                 {"old_full": T.read_fan_name(rgb, S.transcript_layout(m))})
        if "list" in reg:
            for box in list_rows(rgb, m):
                keep("list", RD.list_row_line(rgb, box, m.scale))
        lay = S.transcript_layout(m)
        if lay is not None:
            turns = T.read_turns(rgb, lay)
            found = ([(b, "fan") for b in T.A.find_fan_bubbles(rgb, lay.region, lay.fan_xmin, lay.fan_x0max)]
                     + [(b, "model") for b in T.A.find_model_bubbles(rgb, lay.region, lay.model_xmax)])
            found.sort(key=lambda p: p[0][1])
            for i, (box, who) in enumerate(found):
                bg = T.FAN_BG if who == "fan" else T.MODEL_BG
                old_turn = next((t.text for t in turns if t.box == box), "")
                for j, line in enumerate(bubble_lines(rgb, box, lay.scale, bg)):
                    keep("chat", line, {"msg": i, "line": j, "who": who,
                                        "old_turn": old_turn if j == 0 else ""})

    with open(out / "reads.tsv", "w", encoding="utf-8") as f:
        f.write(json.dumps(rows, ensure_ascii=False, indent=1))
    # a contact sheet per kind, numbered, for checking by eye
    for kind in ("header", "list", "chat"):
        sel = [r for r in rows if r["kind"] == kind]
        if not sel:
            continue
        ims = [Image.open(out / r["file"]) for r in sel]
        W = min(1400, max(i.width for i in ims) + 60)
        sheet = Image.new("RGB", (W, sum(i.height + 6 for i in ims)), (255, 0, 255))
        d = ImageDraw.Draw(sheet)
        yy = 0
        for r, im in zip(sel, ims):
            sheet.paste(im, (60, yy))
            d.text((4, yy + 4), r["file"][:3], fill=(0, 0, 0))
            yy += im.height + 6
        sheet.save(out / f"_sheet_{kind}.png")
    print(f"{len(rows)} cuts -> {out}")
    for r in rows:
        print(f"{r['file'][:3]} {r['kind']:6} conf {r['conf']:.2f} | new: {r['new']!r}\n{'':17}| old: {r['old']!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
