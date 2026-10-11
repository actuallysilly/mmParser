"""Pass 7: whole-phrase completion. Given the first k words of a test message,
offer the rest of it. How often is an offer right, and how many words does a
correct (or partly correct) offer save?

  retrieval  the most common continuation among TRAIN messages that started with
             exactly these k words (needs >= 2 such messages)
  ngram      greedy 3-gram generation until the model's best next word is weak

Measured for k = 1..4 on test messages with at least k+2 words. "Leading words
right" = how many words of the offer match the real message before the first
mismatch, i.e. what accepting it word-by-word would save.
"""
import collections
import json

from bench_common import split, words_surface
from ngram import Ngram
from rcommon import OUT

train, test = split()
tr = [[w.lower() for w in words_surface(m.text)] for m in train]
te = [[w.lower() for w in words_surface(m.text)] for m in test]

cont = collections.defaultdict(collections.Counter)
for ws in tr:
    for k in range(1, 5):
        if len(ws) > k:
            cont[tuple(ws[:k])][tuple(ws[k:])] += 1

ng = Ngram(3)
ng.train(tr)


def greedy(ctx, max_len=12, min_p=0.35):
    out = []
    for _ in range(max_len):
        s = ng.scores(ctx + out, "", limit=5)
        if not s:
            break
        w, sc = max(s.items(), key=lambda kv: kv[1])
        tot = sum(s.values())
        if sc / tot < min_p:
            break
        out.append(w)
    return out


def lead(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


res = {}
for method in ("retrieval", "ngram"):
    res[method] = {}
    for k in (1, 2, 3, 4):
        offered = exact = words_ok = words_total = 0
        n = 0
        for ws in te:
            if len(ws) < k + 2:
                continue
            n += 1
            rest = ws[k:]
            words_total += len(rest)
            if method == "retrieval":
                c = cont.get(tuple(ws[:k]))
                if not c:
                    continue
                guess, cnt = c.most_common(1)[0]
                if cnt < 2:
                    continue
                guess = list(guess)
            else:
                guess = greedy(ws[:k])
                if len(guess) < 2:
                    continue
            offered += 1
            exact += guess == rest
            words_ok += lead(guess, rest)
        res[method][f"k={k}"] = {"messages": n, "offered": offered / n,
                                 "exact_whole_rest": exact / n,
                                 "precision_when_offered": exact / max(1, offered),
                                 "share_of_remaining_words_from_correct_leading_part": words_ok / words_total}

(OUT / "p7_phrase.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
