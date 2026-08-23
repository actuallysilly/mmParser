"""
autoword — the prediction model.

`Predictor` is the seam. The engine only ever sees this protocol, so swapping
the n-gram model for something bigger later (a neural model, a local LLM, a
server call) means writing one new class and changing one line in autoword.pyw.
Nothing in the engine or the renderers knows what is behind it.

`NgramPredictor` is the simple option: trigram -> bigram -> unigram backoff with
a first-character filter. It trains on 190k words in about two seconds, answers
in microseconds, and needs no dependencies.

WHY THE FIRST CHARACTER MATTERS (measured, held-out over 4 unseen days):

    context alone, no character typed     top-1  15.4%
    first character alone, no context     top-1  29.2%
    both together                         top-1  34.9%   top-3 44.2%

Neither signal is usable on its own. The character collapses the context's
candidate set to one letter's worth, and that is where the whole feature lives.
"""
from __future__ import annotations

import collections
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence

BOS = "<s>"          # start-of-segment marker, so the first word has context too
FORMAT_VERSION = 2   # 2 added `dictionary`, for finished_word

# Endings that make a longer word out of a whole one. Only consulted when what
# you typed is already a dictionary word, so `thi` -> `this` is untouched: `thi`
# is not a word, so the trailing `s` is not a plural.
# A bare "d" and "y" are deliberately absent: they are not suffix additions so
# much as coincidences — `nee` + `d` and `bod` + `y` are debris being finished,
# not `need` and `body` being extended. `love` -> `loved` is still caught, by the
# usage test below.
SUFFIXES = ("s", "es", "ed", "ing", "er", "ers", "est", "ly", "ness",
            "ies", "'s", "n't", "ment", "ful", "less")

# How much commoner the completion must be before a dictionary word is treated
# as truncation debris rather than something you actually type. `jus` is a word
# (a meat sauce) and appears 22 times against `just`'s 1,150 — that is residue.
# `you` appears 10,189 times against `your`'s 2,267 — that is a word. Same shape
# as corpus.py's DEBRIS_STEM_RATIO, and the separation is two orders of
# magnitude wide, so the exact value does not matter much.
DEBRIS_RATIO = 5


@dataclass(frozen=True)
class Candidate:
    word: str
    probability: float
    source: str      # trigram | bigram | unigram — for the shadow log
    count: int = 0   # times seen in this context. p=1.0 off one sighting is not
                     # evidence, so auto-completion gates on this, not p.


class Predictor(Protocol):
    """The seam. Implement this to swap in a different model."""

    def train(self, lines: Sequence[str]) -> None: ...

    def predict(self, context: Sequence[str], prefix: str, k: int) -> list[Candidate]:
        """Up to k candidates for the next word.

        context — the words already typed in this segment, most recent last.
        prefix  — the characters of the target word typed so far (may be empty).
        """
        ...

    def finished_word(self, prefix: str, word: str) -> bool:
        """Is `prefix` already a word, that `word` would merely extend?"""
        ...

    def save(self, path: Path) -> None: ...

    def load(self, path: Path) -> bool: ...


class NgramPredictor:
    """Trigram -> bigram -> unigram backoff with a first-character filter."""

    def __init__(self, min_probability: float = 0.0):
        self.min_probability = min_probability
        self.uni: collections.Counter[str] = collections.Counter()
        self.bi: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
        self.tri: dict[tuple[str, str], collections.Counter[str]] = collections.defaultdict(
            collections.Counter)
        self.trained_on = 0
        # Everything the Windows dictionary recognises, out of the corpus
        # vocabulary and its prefixes. Filled by learn_dictionary at train time
        # and stored with the model, so nothing at runtime touches COM.
        self.dictionary: set[str] = set()

    # -- training --------------------------------------------------------------
    def train(self, lines: Sequence[str]) -> None:
        for line in lines:
            words = line.split()
            if not words:
                continue
            padded = [BOS, BOS] + words
            for w in words:
                self.uni[w] += 1
            for a, b in zip(padded, padded[1:]):
                self.bi[a][b] += 1
            for a, b, c in zip(padded, padded[1:], padded[2:]):
                self.tri[(a, b)][c] += 1
        self.trained_on = sum(self.uni.values())

    # -- prediction ------------------------------------------------------------
    def _distribution(self, context: Sequence[str]):
        """Most specific context with any evidence wins. Returns (counter, source)."""
        a = context[-2] if len(context) >= 2 else BOS
        b = context[-1] if len(context) >= 1 else BOS
        if self.tri.get((a, b)):
            return self.tri[(a, b)], "trigram"
        if self.bi.get(b):
            return self.bi[b], "bigram"
        return self.uni, "unigram"

    def predict(self, context: Sequence[str], prefix: str, k: int) -> list[Candidate]:
        counts, source = self._distribution(context)
        if not counts:
            return []

        if prefix:
            pool = {w: n for w, n in counts.items() if w.startswith(prefix)}
            # Nothing in context starts that way — fall back to raw frequency so
            # a rare bigram doesn't silently kill an obvious completion.
            if not pool:
                pool = {w: n for w, n in self.uni.items() if w.startswith(prefix)}
                source = "unigram"
        else:
            pool = dict(counts)

        pool.pop(BOS, None)
        if not pool:
            return []

        total = sum(pool.values())
        out: list[Candidate] = []
        for word, n in sorted(pool.items(), key=lambda kv: (-kv[1], kv[0])):
            if word == prefix:
                continue
            p = n / total
            if p < self.min_probability and out:
                break
            out.append(Candidate(word, p, source, n))
            if len(out) >= k:
                break
        return out

    # -- is the prefix already a word? -----------------------------------------
    def learn_dictionary(self, in_dict) -> int:
        """Ask `in_dict` about every prefix of every word we know, once.

        Done here, at train time, because the answer is needed on the keyboard
        hook thread and the only dictionary available is COM. Thousands of
        lookups now beat one lookup at the wrong moment.
        """
        candidates = set()
        for word in self.uni:
            for n in range(2, len(word) + 1):
                candidates.add(word[:n])
        self.dictionary = {w for w in candidates if in_dict(w)}
        return len(self.dictionary)

    def finished_word(self, prefix: str, word: str) -> bool:
        """Is `prefix` a word in its own right, that `word` would merely extend?

        Two ways to be one, and both are needed — neither test works alone:

          * `word` only adds a suffix to it: `leg` -> `legs`, `do` -> `does`,
            `nothing` -> `nothingness`. The dictionary check is what keeps this
            from firing on `thi` -> `this`, where the `s` is not a plural
            because `thi` is not a word.
          * you demonstrably type it as a word: `you` 10,189 against `your`
            2,267. Truncation debris looks the opposite way round — `jus` 22
            against `just` 1,150 — and the corpus is full of it, because the
            typelog breaks words when the caret moves.
        """
        if prefix not in self.dictionary:
            return False
        added = word[len(prefix):]
        if added in SUFFIXES:
            return True
        return self.uni.get(prefix, 0) * DEBRIS_RATIO >= self.uni.get(word, 0)

    # -- persistence -----------------------------------------------------------
    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        blob = {
            "version": FORMAT_VERSION,
            "trained_on": self.trained_on,
            "uni": self.uni,
            "bi": {k: dict(v) for k, v in self.bi.items() if v},
            # JSON keys must be strings; the tuple is rejoined on load
            "tri": {f"{a}\t{b}": dict(v) for (a, b), v in self.tri.items() if v},
            "dictionary": sorted(self.dictionary),
        }
        path.write_text(json.dumps(blob), encoding="utf-8")

    def load(self, path: Path) -> bool:
        if not path.exists():
            return False
        try:
            blob = json.loads(path.read_text(encoding="utf-8"))
            if blob.get("version") != FORMAT_VERSION:
                return False
            self.uni = collections.Counter(blob["uni"])
            self.bi = collections.defaultdict(collections.Counter,
                                              {k: collections.Counter(v)
                                               for k, v in blob["bi"].items()})
            self.tri = collections.defaultdict(collections.Counter)
            for key, v in blob["tri"].items():
                a, _, b = key.partition("\t")
                self.tri[(a, b)] = collections.Counter(v)
            self.trained_on = blob.get("trained_on", 0)
            self.dictionary = set(blob.get("dictionary", ()))
            return True
        except (ValueError, KeyError, OSError):
            return False

    # -- diagnostics -----------------------------------------------------------
    def perplexity(self, lines: Sequence[str]) -> float:
        """Held-out perplexity. Lower is better; only meaningful compared to itself."""
        total = 0.0
        n = 0
        for line in lines:
            words = line.split()
            padded = [BOS, BOS] + words
            for i, w in enumerate(words):
                counts, _ = self._distribution(padded[i:i + 2])
                p = counts.get(w, 0) / max(1, sum(counts.values()))
                total += math.log(p) if p > 0 else math.log(1e-9)
                n += 1
        return math.exp(-total / max(1, n))
