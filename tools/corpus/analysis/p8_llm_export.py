"""Pass 8a: export the lines still dirty after the rules, for LLM repair.

    python p8_llm_export.py [--size 400]

Writes userdata/corpus/llm_repair/batch_NNN.in.tsv, one `id <tab> raw` per line,
where id is `day:idx` and raw is the MERGED line (not the rules' output: the
rules sometimes cut at the wrong restart, and the repairer should see what was
actually typed). Corrections go in batch_NNN.out.tsv as `id <tab> text`, with
text empty for "not a message" and `?` for "cannot be recovered".
"""
import argparse

from common import CORPUS, load

ap = argparse.ArgumentParser()
ap.add_argument("--size", type=int, default=400)
args = ap.parse_args()

dirty = set()
for row in (CORPUS / "repaired" / "rules_v1.tsv").read_text(encoding="utf-8").splitlines():
    day, idx, _src, d, _text = row.split("\t", 4)
    if d == "1":
        dirty.add((day, int(idx)))

out_dir = CORPUS / "llm_repair"
out_dir.mkdir(exist_ok=True)
rows = [(ln.day, ln.idx, ln.text) for ln in load() if (ln.day, ln.idx) in dirty]
for b in range(0, len(rows), args.size):
    chunk = rows[b:b + args.size]
    path = out_dir / f"batch_{b // args.size:03d}.in.tsv"
    path.write_text("".join(f"{d}:{i}\t{t.replace(chr(9), ' ').replace(chr(10), ' / ')}\n"
                            for d, i, t in chunk), encoding="utf-8")
print(f"{len(rows)} dirty lines -> {(len(rows) + args.size - 1) // args.size} batches in {out_dir}")
