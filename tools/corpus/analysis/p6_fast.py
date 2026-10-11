"""Pass 6d: the cheap way to use an LM — ONE forward pass per keystroke.

    .venv python p6_fast.py <model> --tag NAME [--n 2000]

88-91% of this corpus's words are a single token, so the next-token distribution
is nearly the next-word distribution. Score each candidate by the log-prob of
its FIRST token only (plus beta * log 3-gram), from a single forward pass over
the context. No batch of candidates, no boundary term. In a live service the
context is also cached between keystrokes (KV cache), so this is the upper
bound on cost.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from bench_common import WORD, positions, split, surface_forms, words_surface
from ngram import Ngram
from rcommon import OUT

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--tag", default="fast")
ap.add_argument("--n", type=int, default=2000)
ap.add_argument("--prev", action="store_true")
args = ap.parse_args()

train, test = split()
sample, _ = positions(test)
sample = sample[:args.n]
ng = Ngram(3)
ng.train([[w.lower() for w in words_surface(m.text)] for m in train])
surf = surface_forms(train)
tok = AutoTokenizer.from_pretrained(args.model)
lm = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).cuda().eval()
first_tok = {}


def ftok(word, lead):
    key = (word, lead)
    if key not in first_tok:
        first_tok[key] = tok(lead + surf.get(word, word), add_special_tokens=False).input_ids[0]
    return first_tok[key]


def pool(ctx, prefix):
    s = ng.scores(ctx, prefix, limit=40)
    top = [w for w, _ in sorted(s.items(), key=lambda kv: -kv[1])[:40]]
    extra = [w for w in ng.sorted_vocab if w.startswith(prefix)][:60]
    return list(dict.fromkeys(top + extra)), s


BETAS = (0.0, 0.5, 1.0)
hits = {b: collections.Counter() for b in BETAS}
n = collections.Counter()
cost = collections.Counter()
plain = 0
lat = []
for i, j in sample:
    m = test[i]
    spans = list(WORD.finditer(m.text))
    before = m.text[:spans[j].start()].rstrip(" ")
    wb = [w.lower() for w in words_surface(m.text)][:j]
    w = spans[j].group().lower()
    lead = "" if not before else " "
    ctx_text = before
    if args.prev and i > 0 and test[i - 1].day == m.day:
        ctx_text = test[i - 1].text + "\n" + before
    ids = tok(ctx_text if ctx_text else "\n", add_special_tokens=False).input_ids
    if tok.bos_token_id is not None:
        ids = [tok.bos_token_id] + ids
    torch.cuda.synchronize()
    t = time.perf_counter()
    with torch.inference_mode():
        lp = lm(input_ids=torch.tensor([ids]).cuda()).logits[0, -1].float().log_softmax(-1)
    torch.cuda.synchronize()
    lat.append(time.perf_counter() - t)
    lp = lp.cpu()
    ranked = {b: {} for b in BETAS}
    for pl in range(0, len(w)):
        cands, s = pool(wb, w[:pl])
        for b in BETAS:
            sc = {c: lp[ftok(c, lead)].item() + b * math.log(max(s.get(c, 0.0), 1e-12)) for c in cands}
            ranked[b][pl] = sorted(sc, key=lambda c: -sc[c])
    for pl in (0, 1, 2):
        if pl and len(w) <= pl:
            continue
        n[pl] += 1
        for b in BETAS:
            for k in (1, 3, 5):
                hits[b][(pl, k)] += w in ranked[b][pl][:k]
    plain += len(w) + 1
    for b in BETAS:
        for L in (3, 5):
            c = len(w) + 1
            for pl in range(0, len(w)):
                r = ranked[b][pl][:L]
                if w in r:
                    c = min(c, pl + r.index(w) + 1)
                    break
            cost[(b, L)] += c

res = {"model": args.model, "positions": len(sample),
       "forward_ms_median": sorted(lat)[len(lat) // 2] * 1000,
       "forward_ms_p95": sorted(lat)[int(len(lat) * .95)] * 1000}
for b in BETAS:
    res[f"beta={b}"] = {**{f"p{p}_top{k}": hits[b][(p, k)] / n[p] for p in (0, 1, 2) for k in (1, 3, 5)},
                        "KSR_list3": 1 - cost[(b, 3)] / plain, "KSR_list5": 1 - cost[(b, 5)] / plain}
(OUT / f"p6_fast_{args.tag}.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
