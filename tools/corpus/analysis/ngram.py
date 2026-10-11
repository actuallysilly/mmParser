"""A count-based next-word model with a typed-prefix filter.

Stupid backoff over orders 1..N (Brants et al. 2007): the score of word w after
context c is count(c,w)/count(c) at the longest order that has seen c, plus
alpha^k times the same at each shorter order. Unnormalised, which is fine for
ranking. Context may include the previous message, joined by a boundary token.
"""
from __future__ import annotations

import collections

BOS = "<s>"
SEP = "</m>"          # boundary between the previous message and this one


class Ngram:
    def __init__(self, order: int = 3, alpha: float = 0.4):
        self.N = order
        self.alpha = alpha
        self.c = [collections.defaultdict(collections.Counter) for _ in range(order)]
        self.by_prefix: dict[str, list[str]] = {}

    def train(self, sequences):
        uni = collections.Counter()
        for seq in sequences:
            padded = [BOS] * (self.N - 1) + seq
            for i in range(self.N - 1, len(padded)):
                w = padded[i]
                uni[w] += 1
                for k in range(self.N):          # k = context length
                    ctx = tuple(padded[i - k:i])
                    self.c[k][ctx][w] += 1
        # for prefix queries with no context support: words by frequency
        self.uni = uni
        self.sorted_vocab = [w for w, _ in uni.most_common() if w not in (BOS, SEP)]

    def scores(self, context, prefix: str = "", limit: int = 50) -> dict[str, float]:
        ctx = [BOS] * (self.N - 1) + list(context)
        out: dict[str, float] = {}
        weight = 1.0
        for k in range(self.N - 1, -1, -1):
            dist = self.c[k].get(tuple(ctx[len(ctx) - k:]) if k else (), None)
            if dist:
                tot = sum(dist.values())
                for w, n in dist.items():
                    if w.startswith(prefix) and w not in (BOS, SEP):
                        out[w] = out.get(w, 0.0) + weight * n / tot
                weight *= self.alpha
        if len(out) < limit and prefix:
            for w in self.sorted_vocab:
                if w.startswith(prefix) and w not in out:
                    out[w] = 1e-9 * self.uni[w]
                    if len(out) >= limit:
                        break
        return out

    def rank(self, context, prefix: str = "", k: int = 3) -> list[str]:
        s = self.scores(context, prefix, limit=max(k, 50))
        s.pop(prefix, None) if False else None
        return [w for w, _ in sorted(s.items(), key=lambda kv: (-kv[1], kv[0]))[:k]]
