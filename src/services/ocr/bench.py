"""
ocr/bench.py — the test bench: every engine reads the same pictures, scored the same.

    python bench.py --set userdata/ocr/synth/val --set userdata/ocr/real [--video] [--json OUT]

Scores per engine and per kind of text:
    exact     every character right (after the same normalisation as the labels)
    same name right after ignoring spaces, punctuation, case and emoji — what matters
              for telling fans apart
--video spoils each picture the way a screen recording does (the same spoiling the
reader was trained with, but with a fixed seed so every engine sees identical pixels).

Engines:
    infloww   ocr/reader.py — the new reader
    ppocr_v3  rapidocr_onnxruntime 1.2 (PP-OCRv3) — what MMA's live readers use today
    ppocr_v5  rapidocr 3 (PP-OCRv5, English) — what video2chat uses today
"""
from __future__ import annotations

import argparse
import io
import json
import random
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reader as RD                                          # noqa: E402
from synth import norm_label                                 # noqa: E402


def load_set(d: Path):
    items = []
    for tsv in sorted(d.glob("labels*.tsv")):
        for line in tsv.read_text(encoding="utf-8").splitlines():
            p = line.split("\t")
            if len(p) >= 3 and p[1]:
                items.append((d / p[0], p[1], p[2]))
    return items


def spoil(rgb: np.ndarray, seed: int) -> np.ndarray:
    r = random.Random(seed)
    im = Image.fromarray(rgb)
    k = r.uniform(0.5, 0.8)
    im = im.resize((max(4, round(im.width * k)), max(4, round(im.height * k))), Image.BILINEAR).resize(
        im.size, Image.BICUBIC)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=r.randint(35, 70))
    return np.asarray(Image.open(io.BytesIO(buf.getvalue())).convert("RGB"))


# ----------------------------------------------------------------- engines --
def _pp_join(res, pad: int) -> str:
    if not res:
        return ""
    boxes = sorted(res, key=lambda b: min(p[0] for p in b[0]))
    return " ".join(b[1].strip() for b in boxes if b[1].strip())


def _pad(rgb: np.ndarray, pad: int = 20) -> np.ndarray:
    bg = np.median(rgb.reshape(-1, 3), 0).astype(np.uint8)
    out = np.empty((rgb.shape[0] + 2 * pad, rgb.shape[1] + 2 * pad, 3), np.uint8)
    out[:] = bg
    out[pad:pad + rgb.shape[0], pad:pad + rgb.shape[1]] = rgb
    return out


class V3:
    name = "ppocr_v3"

    def __init__(self):
        from rapidocr_onnxruntime import RapidOCR
        self.eng = RapidOCR()

    def read(self, rgb):
        # Exactly how MMA's live readers call it: padded crop, detector + recogniser.
        res, _ = self.eng(_pad(rgb))
        return _pp_join(res, 20)


class V5:
    name = "ppocr_v5"

    def __init__(self):
        from rapidocr import RapidOCR, OCRVersion, ModelType, LangRec
        v5 = OCRVersion("PP-OCRv5")
        self.eng = RapidOCR(params={"Global.log_level": "error", "Det.ocr_version": v5,
                                    "Rec.ocr_version": v5, "Det.model_type": ModelType("mobile"),
                                    "Rec.model_type": ModelType("mobile"), "Rec.lang_type": LangRec("en")})

    def read(self, rgb):
        r = self.eng(np.ascontiguousarray(_pad(rgb)))
        if r.boxes is None or r.txts is None:
            return ""
        return _pp_join([[b.tolist(), t, s] for b, t, s in zip(r.boxes, r.txts, r.scores)], 20)


class Infloww:
    name = "infloww"

    def read(self, rgb):
        return RD.read_line(rgb).text


def run(engines, items, video: bool):
    rows = {}
    for e in engines:
        ok = same = n = 0
        by = {}
        t0 = time.time()
        misses = []
        for i, (path, label, style) in enumerate(items):
            rgb = np.asarray(Image.open(path).convert("RGB"))
            if video:
                rgb = spoil(rgb, i)
            got = norm_label(e.read(rgb))
            ex = got == label
            sm = RD.name_key(got) == RD.name_key(label)
            ok += ex
            same += sm
            n += 1
            a = by.setdefault(style, [0, 0, 0])
            a[0] += ex
            a[1] += sm
            a[2] += 1
            if not ex and len(misses) < 12:
                misses.append((label, got))
        ms = (time.time() - t0) * 1000 / max(1, n)
        rows[e.name] = {"exact": ok / n, "same": same / n, "n": n, "ms": ms,
                        "by": {k: {"exact": v[0] / v[2], "same": v[1] / v[2], "n": v[2]} for k, v in by.items()},
                        "misses": misses}
        print(f"  {e.name:9} exact {ok / n:6.1%}  same name {same / n:6.1%}  ({n} pictures, {ms:.0f} ms each)",
              flush=True)
        for k, v in sorted(by.items()):
            print(f"      {k:7} exact {v[0] / v[2]:6.1%}  same {v[1] / v[2]:6.1%}  n={v[2]}")
    return rows


def main(argv=None) -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", action="append", required=True)
    ap.add_argument("--video", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--engines", default="infloww,ppocr_v3,ppocr_v5")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    make = {"infloww": Infloww, "ppocr_v3": V3, "ppocr_v5": V5}
    engines = [make[n]() for n in a.engines.split(",")]
    report = {}
    for s in a.set:
        items = load_set(Path(s))
        if a.limit:
            items = random.Random(0).sample(items, min(a.limit, len(items)))
        tag = Path(s).name + (" (video-spoiled)" if a.video else "")
        print(f"== {tag}: {len(items)} pictures")
        report[tag] = run(engines, items, a.video)
    if a.json:
        Path(a.json).write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
