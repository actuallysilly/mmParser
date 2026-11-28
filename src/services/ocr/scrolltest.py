"""
ocr/scrolltest.py — test the pixel-stitched capture on REAL scrolling: Silly's OBS
shift recordings of the Infloww Messages window (5 fps). Wherever she scrolled up
through a chat, consecutive frames are exactly the overlapping pages __lore takes.

    python scrolltest.py VIDEO [--minutes A B] [--out DIR]

1. scan: find runs of frames where the chat moved UP (older) frame to frame
2. for the longest runs: stitch the frames by pixels (scrollcap), read the strip
   once, and ALSO read every frame on its own and text-stitch them the old way
   (stitch.merge, what __lore did) — then compare the two
Writes evidence (the stitched picture, both message lists) to --out.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "llm"))
sys.path.insert(0, str(HERE.parent / "screenmap"))
import scrollcap as SC                     # noqa: E402
import screenmap as SM                     # noqa: E402
import stitch                              # noqa: E402
import transcript as T                     # noqa: E402


def frames(path: str, t0: float, t1: float | None, every: int = 1):
    import cv2
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 5.0
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    first = int(t0 * 60 * fps)
    last = n if t1 is None else min(n, int(t1 * 60 * fps))
    cap.set(cv2.CAP_PROP_POS_FRAMES, first)
    for i in range(first, last):
        ok, f = cap.read()
        if not ok:
            break
        if (i - first) % every == 0:
            yield i / fps, np.ascontiguousarray(f[:, :, ::-1])
    cap.release()


def pane(rgb, m):
    x, y, w, h = m.regions["messages"]
    return rgb[y:y + h, x:x + w]


def scan(path, t0, t1):
    """Runs of consecutive UP-scrolls: [(start_s, [(t, rgb, m, d), ...]), ...]."""
    runs, cur, prev, prev_m = [], [], None, None
    lay_cache = None
    for t, rgb in frames(path, t0, t1):
        if lay_cache is None or lay_cache[0] != rgb.shape:
            m = SM.measure(rgb)
            lay_cache = (rgb.shape, m)
        m = lay_cache[1]
        if m.status != "ok" or "messages" not in m.regions:
            lay_cache = None
            if len(cur) >= 4:
                runs.append(cur)
            cur, prev = [], None
            continue
        p = pane(rgb, m)
        if prev is not None and prev.shape == p.shape:
            small = np.abs(prev[::8, ::8].astype(np.int16) - p[::8, ::8]).mean()
            if small < 1.0:
                continue                                 # nothing moved: skip the frame
            d, how = SC.register_any(prev, p)
            if d is not None and d > 0:
                if not cur:
                    cur = [(t, prev_rgb, m, 0)]
                cur.append((t, rgb, m, d))
            else:
                if len(cur) >= 4:
                    runs.append(cur)
                cur = []
        prev, prev_rgb = p, rgb
    if len(cur) >= 4:
        runs.append(cur)
    return runs


def stitch_run(run) -> SC.Strip:
    st = SC.Strip()
    top = 0
    for i, (t, rgb, m, d) in enumerate(run):
        top -= d
        st.add(pane(rgb, m).copy(), top)
    st.reached_top = False
    return st


def old_way(run) -> list[dict]:
    """What __lore did: read each page, stitch by text."""
    hist: list[dict] = []
    for t, rgb, m, d in run:
        lay = SM.transcript_layout(m)
        read = [x.to_dict() for x in T.read_turns(rgb, lay)]
        if not hist:
            hist = stitch.clean(read)
            continue
        merged, _new, why = stitch.merge(hist, read)     # exactly how __lore stitched each page
        if not why:
            hist = merged
    return hist


def main(argv=None) -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--minutes", nargs=2, type=float, default=[0, None])
    ap.add_argument("--out", default=str(SM.MMA_ROOT / "userdata" / "ocr" / "scrolltest"))
    ap.add_argument("--runs", type=int, default=2)
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t = time.time()
    runs = scan(a.video, a.minutes[0], a.minutes[1])
    runs.sort(key=len, reverse=True)
    print(f"scan: {len(runs)} upward-scroll runs in {time.time() - t:.0f}s; "
          f"longest: {[len(r) for r in runs[:6]]} frames")
    report = []
    for k, run in enumerate(runs[: a.runs]):
        st = stitch_run(run)
        img = st.image()
        m = run[0][2]
        t1 = time.time()
        msgs = SC.read(img, pane(run[0][1], m).shape[0], m.scale)
        t_new = time.time() - t1
        t2 = time.time()
        old = old_way(run)
        t_old = time.time() - t2
        from PIL import Image
        Image.fromarray(img).save(out / f"run{k}_strip.jpg", quality=88)
        rec = {"run": k, "from_s": run[0][0], "to_s": run[-1][0], "frames": len(run),
               "strip_px": int(img.shape[0]), "new_messages": len(msgs), "new_s": round(t_new),
               "old_messages": len(old), "old_s": round(t_old),
               "verdicts": {v: sum(1 for x in msgs if x.verdict == v) for v in
                            ("verified", "close", "disputed", "media", "unchecked")},
               "new": [{"who": x.turn.get("who"), "text": x.turn.get("text", ""), "second": x.second,
                        "verdict": x.verdict} for x in msgs],
               "old": [{"who": x.get("who"), "text": x.get("text", "")} for x in old]}
        report.append(rec)
        for i, x in enumerate(msgs):
            if x.crop is not None:
                Image.fromarray(x.crop).save(out / f"run{k}_msg{i:03d}.png")
        print(f"run {k}: {run[0][0] / 60:.1f}-{run[-1][0] / 60:.1f} min, {len(run)} frames, "
              f"{img.shape[0]}px stitched -> NEW {len(msgs)} messages ({t_new:.0f}s) "
              f"vs OLD text-stitch {len(old)} ({t_old:.0f}s); {rec['verdicts']}")
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
