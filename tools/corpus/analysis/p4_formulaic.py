"""Pass 4: how much of the writing is formulaic, how much is new.

Everything is measured CAUSALLY where it matters: "repeated" means seen on an
EARLIER day, which is what a predictor running live could actually exploit.
"""
import collections
import json
import re

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer

from rcommon import OUT, load_repaired, wtoks

M = [m for m in load_repaired() if wtoks(m.text)]
days = sorted({m.day for m in M})
res = {}


def norm(t):
    return " ".join(wtoks(t))


def templ(t):
    """Fan names and numbers become slots."""
    t = re.sub(r"\d+([.,]\d+)?", "<num>", t)
    t = re.sub(r"(?<=[a-z,!.?] )[A-Z][a-z]+\b", "<name>", t)
    t = re.sub(r"^((?:hey+|hi+|hello+|oh hey+|omg)\s+)[A-Z][a-z]+", r"\1<name>", t, flags=re.I)
    return norm(t.replace("<name>", " NAMESLOT ").replace("<num>", " NUMSLOT "))


# -- 1. exact repeats --------------------------------------------------------
seen, seen_t = set(), set()
rep = rep_t = 0
rep_words = 0
total_words = 0
counts = collections.Counter(norm(m.text) for m in M)
for d in days:
    today = [m for m in M if m.day == d]
    for m in today:
        n, t = norm(m.text), templ(m.text)
        w = len(n.split())
        total_words += w
        if n in seen:
            rep += 1
            rep_words += w
        if t in seen_t:
            rep_t += 1
    seen |= {norm(m.text) for m in today}
    seen_t |= {templ(m.text) for m in today}
res["exact_repeat_of_earlier_day"] = {"messages": rep / len(M), "words": rep_words / total_words}
res["template_repeat_of_earlier_day"] = rep_t / len(M)
res["top_repeated_messages"] = counts.most_common(60)
multi = {k: v for k, v in counts.items() if v > 1}
res["distinct_messages"] = len(counts)
res["messages_that_occur_more_than_once_total"] = sum(multi.values()) / len(M)
res["repeated_by_length"] = {}
for lo, hi in [(1, 1), (2, 3), (4, 6), (7, 10), (11, 20), (21, 999)]:
    sel = [m for m in M if lo <= len(wtoks(m.text)) <= hi]
    r = sum(1 for m in sel if counts[norm(m.text)] > 1)
    res["repeated_by_length"][f"{lo}-{hi}"] = (len(sel), round(r / max(1, len(sel)), 3))

# -- 2. near-duplicates (char n-gram tf-idf cosine) against earlier days -----
texts = [norm(m.text) for m in M]
long_idx = [i for i, t in enumerate(texts) if len(t.split()) >= 5]
vec = TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), min_df=2, sublinear_tf=True)
X = vec.fit_transform([texts[i] for i in long_idx])
day_of = np.array([M[i].day for i in long_idx])
best = np.zeros(len(long_idx))
for k, d in enumerate(days):
    cur = np.where(day_of == d)[0]
    prev = np.where(day_of < d)[0]
    if not len(cur) or not len(prev):
        continue
    S = X[cur] @ X[prev].T
    best[cur] = S.max(axis=1).toarray().ravel()
res["near_dup_5plus_words"] = {f">={t}": float((best >= t).mean()) for t in (0.9, 0.8, 0.7, 0.6, 0.5)}
order = np.argsort(-best)
res["near_dup_examples_0.7_to_0.85"] = [texts[long_idx[i]] for i in order if 0.7 <= best[i] < 0.85][:25]

# -- 3. n-gram novelty: share of today's n-grams never seen on an earlier day --
def ngrams(ws, n):
    return [tuple(ws[i:i + n]) for i in range(len(ws) - n + 1)]


nov = {n: [] for n in (2, 3, 4, 5, 6)}
seen_ng = {n: set() for n in nov}
for d in days:
    today = [wtoks(m.text) for m in M if m.day == d]
    for n in nov:
        grams = [g for ws in today for g in ngrams(ws, n)]
        if grams and seen_ng[n]:
            nov[n].append((d, sum(1 for g in grams if g not in seen_ng[n]) / len(grams)))
        seen_ng[n] |= set(grams)
res["ngram_novelty_by_day"] = {n: v for n, v in nov.items()}
res["ngram_novelty_last10_mean"] = {n: float(np.mean([x for _, x in v[-10:]])) for n, v in nov.items()}

# -- 4. token coverage by repeated phrases (greedy longest match, causal) ------
def coverage(min_count, min_n=3, max_n=8):
    """Share of word tokens on the last 10 days covered by a phrase that occurred
    >= min_count times on EARLIER days. Greedy longest-first, no overlap."""
    split = days[-10]
    train = [wtoks(m.text) for m in M if m.day < split]
    test = [wtoks(m.text) for m in M if m.day >= split]
    c = collections.Counter(g for ws in train for n in range(min_n, max_n + 1) for g in ngrams(ws, n))
    covered = tot = 0
    for ws in test:
        tot += len(ws)
        i = 0
        while i < len(ws):
            for n in range(min(max_n, len(ws) - i), min_n - 1, -1):
                if c.get(tuple(ws[i:i + n]), 0) >= min_count:
                    covered += n
                    i += n
                    break
            else:
                i += 1
    return covered / tot


res["phrase_coverage_last10"] = {f"seen>={k}": coverage(k) for k in (2, 5, 10, 25)}

# -- 5. message-level: how many of a message's words are inside repeated phrases
split = days[-10]
train = [wtoks(m.text) for m in M if m.day < split]
c4 = collections.Counter(g for ws in train for g in ngrams(ws, 4))
c3 = collections.Counter(g for ws in train for g in ngrams(ws, 3))
buckets = collections.Counter()
for m in M:
    if m.day < split:
        continue
    ws = wtoks(m.text)
    if len(ws) < 4:
        buckets["short (<4 words)"] += 1
        continue
    g = ngrams(ws, 3)
    share = sum(1 for x in g if c3.get(x, 0) >= 2) / len(g)
    k = ("fully formulaic (100%)" if share == 1 else ">=75%" if share >= .75 else
         "50-75%" if share >= .5 else "25-50%" if share >= .25 else "<25% (unique)")
    buckets[k] += 1
res["message_formulaicness_last10"] = dict(buckets)

(OUT / "p4_formulaic.json").write_text(json.dumps(res, indent=1, default=str))
for k, v in res.items():
    if k == "ngram_novelty_by_day":
        for n, s in v.items():
            print(f"novelty {n}-gram:", " ".join(f"{x:.2f}" for _, x in s))
    elif k == "top_repeated_messages":
        print(k, v[:40])
    else:
        print(k, v)
