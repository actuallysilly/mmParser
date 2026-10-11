"""Pass 6b: language-model reranking on the same test positions as p6_ngram.

    .venv python p6_lm.py <model id or path> [--prev] [--n 2000]

Candidates for typed prefix p: the 3-gram's top 40 with that prefix, plus the 60
most frequent vocabulary words with it. The LM scores every candidate as
log P(word | text so far) + log P(a word boundary follows) — the second term is
what stops 'want' scoring the probability mass of 'wanted'. Ranked by LM score
alone, and by LM + beta * log(3-gram score); both reported.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import string
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from bench_common import WORD, positions, split, surface_forms, words_surface
from ngram import Ngram
from rcommon import OUT

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--prev", action="store_true", help="prepend the previous message")
ap.add_argument("--n", type=int, default=2000)
ap.add_argument("--tag", default="run")
ap.add_argument("--maxp", type=int, default=4, help="LM ranks prefixes up to this length")
args = ap.parse_args()

train, test = split()
sample, _ = positions(test)
sample = sample[:args.n]
ng = Ngram(3)
ng.train([[w.lower() for w in words_surface(m.text)] for m in train])
surf = surface_forms(train)

tok = AutoTokenizer.from_pretrained(args.model)
lm = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).cuda().eval()
pad = tok.pad_token_id if tok.pad_token_id is not None else (tok.eos_token_id or 0)

# token ids that begin a new word: whitespace, punctuation, or end of text
BOUND = set()
for i in range(len(tok)):
    s = tok.decode([i])
    if s and (s[0].isspace() or s[0] in string.punctuation):
        BOUND.add(i)
if tok.eos_token_id is not None:
    BOUND.add(tok.eos_token_id)
BOUND = torch.tensor(sorted(BOUND), device="cuda")


def pool(context_words, prefix):
    s = ng.scores(context_words, prefix, limit=40)
    top = [w for w, _ in sorted(s.items(), key=lambda kv: -kv[1])[:40]]
    extra = [w for w in ng.sorted_vocab if w.startswith(prefix)][:60]
    return list(dict.fromkeys(top + extra)), s


@torch.inference_mode()
def lm_scores(context: str, cands: list[str]) -> dict[str, float]:
    ctx_ids = tok(context, add_special_tokens=False).input_ids if context else []
    if tok.bos_token_id is not None and (not ctx_ids or ctx_ids[0] != tok.bos_token_id):
        ctx_ids = [tok.bos_token_id] + ctx_ids
    if not ctx_ids:
        ctx_ids = tok("\n", add_special_tokens=False).input_ids
    lead = "" if (not context or context.endswith("\n")) else " "
    out = {}
    for k in range(0, len(cands), 64):
        chunk = cands[k:k + 64]
        seqs = [ctx_ids + tok(lead + surf.get(c, c), add_special_tokens=False).input_ids for c in chunk]
        T = max(len(s) for s in seqs)
        ids = torch.full((len(seqs), T), pad, dtype=torch.long)
        mask = torch.zeros_like(ids)
        for i, s in enumerate(seqs):
            ids[i, :len(s)] = torch.tensor(s)
            mask[i, :len(s)] = 1
        logits = lm(input_ids=ids.cuda(), attention_mask=mask.cuda()).logits
        L = len(ctx_ids)
        for i, (c, s) in enumerate(zip(chunk, seqs)):
            lp = logits[i, L - 1:len(s)].float().log_softmax(-1)      # predicts s[L:] and the boundary
            tgt = torch.tensor(s[L:], device="cuda")
            word = lp[:-1].gather(-1, tgt[:, None]).sum().item()
            bound = lp[-1, BOUND].logsumexp(-1).item()
            out[c] = word + bound
    return out


def contexts(i, j):
    m = test[i]
    spans = list(WORD.finditer(m.text))
    text_before = m.text[:spans[j].start()].rstrip(" ")
    if args.prev and i > 0 and test[i - 1].day == m.day:
        text_before = test[i - 1].text + "\n" + text_before
    words_before = [w.lower() for w in words_surface(m.text)][:j]
    return text_before, words_before, spans[j].group().lower()


BETAS = (0.0, 0.3, 0.6, 1.0)
METHODS = BETAS + ("ngram",)
hits = {b: collections.Counter() for b in METHODS}
n = collections.Counter()
recall = collections.Counter()
cost = collections.Counter()
plain = 0
lat = []
t0 = time.time()
for step, (i, j) in enumerate(sample):
    text_before, wb, w = contexts(i, j)
    prefs = [w[:p] for p in range(0, min(len(w), args.maxp + 1))]
    pools = {p: pool(wb, p) for p in prefs}
    union = list(dict.fromkeys(c for p in prefs for c in pools[p][0]))
    t = time.time()
    S = lm_scores(text_before, union)
    lat.append(time.time() - t)
    ranked = {}
    for b in BETAS:
        ranked[b] = {}
        for p in prefs:
            cands, ngs = pools[p]
            sc = {c: S[c] + b * math.log(max(ngs.get(c, 0.0), 1e-12)) for c in cands}
            ranked[b][p] = sorted(sc, key=lambda c: -sc[c])
    ranked["ngram"] = {p: ng.rank(wb, p, 5) for p in prefs}
    for pl in (0, 1, 2):
        if pl and len(w) <= pl:
            continue
        p = w[:pl]
        n[pl] += 1
        recall[pl] += w in pools[p][0]
        for b in METHODS:
            r = ranked[b][p]
            for k in (1, 3, 5):
                hits[b][(pl, k)] += w in r[:k]
    # keystrokes with a list of L shown: type pl chars until the word is listed at
    # rank r, then r presses take it with its space. LM ranking for the prefixes it
    # scored, 3-gram beyond.
    plain += len(w) + 1
    for b in METHODS:
        for L in (3, 5):
            c = len(w) + 1
            for pl in range(0, len(w)):
                r = ranked[b][w[:pl]] if w[:pl] in ranked[b] else ng.rank(wb, w[:pl], L)
                if w in r[:L]:
                    c = min(c, pl + r[:L].index(w) + 1)
                    break
            cost[(b, L)] += c
    if step % 250 == 0:
        print(f"  {step}/{len(sample)}  {time.time() - t0:.0f}s", flush=True)

res = {"model": args.model, "prev": args.prev, "positions": len(sample),
       "pool_recall": {f"p{p}": recall[p] / n[p] for p in (0, 1, 2)},
       "lm_ms_per_position_median": sorted(lat)[len(lat) // 2] * 1000,
       "mean_candidates": None}
for b in METHODS:
    res[b if b == "ngram" else f"beta={b}"] = {
        **{f"p{p}_top{k}": hits[b][(p, k)] / n[p] for p in (0, 1, 2) for k in (1, 3, 5)},
        "KSR_list3": 1 - cost[(b, 3)] / plain, "KSR_list5": 1 - cost[(b, 5)] / plain}
(OUT / f"p6_lm_{args.tag}.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
