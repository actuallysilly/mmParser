"""Pass 6a: n-gram baselines on every test position.

Reports top-1/top-3 with 0/1/2 typed characters, and keystroke savings (KSR),
for orders 1..5, with and without the previous message as context.
"""
import collections
import json
import time

from bench_common import keystrokes, positions, split, words_surface
from ngram import SEP, Ngram
from rcommon import OUT

train, test = split()


def seqs(msgs, with_prev):
    out = []
    prev = []
    prev_day = None
    for m in msgs:
        ws = [w.lower() for w in words_surface(m.text)]
        if with_prev and m.day == prev_day:
            out.append((prev[-6:] + [SEP], ws))
        else:
            out.append(([], ws))
        prev, prev_day = ws, m.day
    return out


def evaluate(model, test_seqs, sample=None):
    hit = collections.Counter()
    n = collections.Counter()
    cost = plain = 0
    by_pos = collections.defaultdict(lambda: [0, 0])
    items = sample if sample is not None else [(i, j) for i, (_, ws) in enumerate(test_seqs) for j in range(len(ws))]
    for i, j in items:
        pre, ws = test_seqs[i]
        ctx = pre + ws[:j]
        w = ws[j]
        for p in (0, 1, 2):
            if p and len(w) <= p:
                continue
            r = model.rank(ctx, w[:p], 3)
            n[p] += 1
            hit[(p, 1)] += bool(r) and r[0] == w
            hit[(p, 3)] += w in r
        c, pl = keystrokes(w, lambda pre_, ctx=ctx: model.rank(ctx, pre_, 3))
        cost += c
        plain += pl
        b = "first word" if j == 0 else "word 2-3" if j < 3 else "word 4+"
        by_pos[b][0] += model.rank(ctx, "", 1)[:1] == [w]
        by_pos[b][1] += 1
    res = {f"p{p}_top{k}": hit[(p, k)] / n[p] for p in (0, 1, 2) for k in (1, 3)}
    res["KSR"] = 1 - cost / plain
    res["top1_by_position_p0"] = {b: a / t for b, (a, t) in by_pos.items()}
    return res


if __name__ == "__main__":
    sample, total_pos = positions(test)
    results = {"train_messages": len(train), "test_messages": len(test), "test_positions": total_pos}
    for with_prev in (False, True):
        tr, te = seqs(train, with_prev), seqs(test, with_prev)
        for order in (1, 2, 3, 4, 5):
            if with_prev and order < 3:
                continue
            m = Ngram(order)
            m.train([pre + ws for pre, ws in tr])
            t = time.time()
            r = evaluate(m, te, sample)
            r["ms_per_position"] = (time.time() - t) / len(sample) * 1000
            key = f"{order}-gram{' +prev msg' if with_prev else ''}"
            results[key] = r
            print(key, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()})
    (OUT / "p6_ngram.json").write_text(json.dumps(results, indent=1))
