"""
autoword — the language-model predictor: the n-gram proposes, the LM ranks.

Measured on 9 held-out days (tools/corpus/analysis, userdata/corpus/Claude_Analysis.md
§6), with one letter typed: the right word is in the top 3 for 65% of words with
the n-gram alone and 74% with a fine-tuned Qwen2.5-0.5B mixed in, given the
previous message as context. The gain is content words; the n-gram already gets
function words.

HOW IT STAYS CHEAP
  * One forward pass per CONTEXT, cached. Typing the letters of a word does not
    change the context, only which candidates match, so the model runs once per
    word (about one keystroke in four) and every letter after that is a lookup.
  * Candidates are scored by their FIRST token. 88-91% of the corpus's words are a
    single token, so the next-token distribution is nearly the next-word one, and
    one pass replaces scoring a batch of whole candidates (~20 ms vs ~115 ms, for
    about a point of accuracy).
  * score = log P_lm(first token) + weight * log P_ngram. The n-gram carries your
    exact stock frames; the LM brings the rest of the sentence.

WHAT IT NEVER CHANGES
  When the n-gram has seen exactly ONE word follow this context with this prefix,
  its answer is passed through untouched. That uniqueness is what auto-completion
  gates on (engine._is_obvious, 97% precision), and a re-ranker that added
  candidates would quietly switch auto-completion off.

Imports torch lazily: only the `lm` and `shadow` modes need autoword's .venv
(requirements-lm.txt). Everything else runs on the plain Python as before.
"""
from __future__ import annotations

import collections
import math
import time
from pathlib import Path
from typing import Sequence

from model import Candidate, NgramPredictor

I_FORMS = {"i": "I", "i'm": "I'm", "i'll": "I'll", "i've": "I've", "i'd": "I'd"}
POOL = 60            # vocabulary words with the typed prefix, added to the n-gram's
CACHE = 8            # contexts kept (each is one row of next-token log-probs)


def surface(word: str, first: bool) -> str:
    """How the word would be written: I-forms capitalised, a message's first word
    capitalised, the rest as the lowercase n-gram stores them."""
    if word in I_FORMS:
        return I_FORMS[word]
    return word[:1].upper() + word[1:] if first else word


class LmScorer:
    """Loads the fine-tuned model once; returns next-token log-probs per context."""

    def __init__(self, model_dir: Path, device: str = "cuda"):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        if device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("no CUDA device visible to torch")
        self.torch = torch
        self.tok = AutoTokenizer.from_pretrained(model_dir)
        self.lm = AutoModelForCausalLM.from_pretrained(
            model_dir, dtype=torch.bfloat16).to(device).eval()
        self.device = device
        self._cache: collections.OrderedDict = collections.OrderedDict()
        self._first: dict[tuple[str, bool], int] = {}
        self.forward_ms: list[float] = []
        # The first pass on a fresh CUDA context costs ~10x a normal one (kernel
        # selection, allocator warm-up). Pay it here, at startup, not on the
        # first word you type.
        self.logprobs("Hey")
        self._cache.clear()
        self.forward_ms.clear()

    def logprobs(self, text: str):
        """Log-probs of the next token after `text` (CPU tensor), cached."""
        hit = self._cache.get(text)
        if hit is not None:
            self._cache.move_to_end(text)
            return hit
        ids = self.tok(text if text else "\n", add_special_tokens=False).input_ids[-256:]
        t = time.perf_counter()
        with self.torch.inference_mode():
            out = self.lm(input_ids=self.torch.tensor([ids], device=self.device))
            lp = out.logits[0, -1].float().log_softmax(-1).cpu()
        self.forward_ms.append((time.perf_counter() - t) * 1000)
        self._cache[text] = lp
        if len(self._cache) > CACHE:
            self._cache.popitem(last=False)
        return lp

    def first_token(self, word: str, lead_space: bool) -> int:
        key = (word, lead_space)
        if key not in self._first:
            self._first[key] = self.tok((" " if lead_space else "") + word,
                                        add_special_tokens=False).input_ids[0]
        return self._first[key]


class LmPredictor:
    """Predictor protocol: the wrapped n-gram trains, saves and judges finished
    words; this only re-ranks what it proposes."""

    def __init__(self, base: NgramPredictor, scorer: LmScorer, weight: float = 0.5):
        self.base = base
        self.scorer = scorer
        self.weight = weight
        self.prev = ""                       # the last message sent, as typed
        self._by_letter: dict[str, list[str]] | None = None

    # -- delegated -------------------------------------------------------------
    def train(self, lines: Sequence[str]) -> None:
        self.base.train(lines)
        self._by_letter = None

    def finished_word(self, prefix: str, word: str) -> bool:
        return self.base.finished_word(prefix, word)

    def save(self, path: Path) -> None:
        self.base.save(path)

    def load(self, path: Path) -> bool:
        self._by_letter = None
        return self.base.load(path)

    @property
    def trained_on(self) -> int:
        return self.base.trained_on

    # -- context ---------------------------------------------------------------
    def segment_done(self, text: str) -> None:
        """The engine calls this on Enter: the message just sent becomes context."""
        if text.strip():
            self.prev = text.strip()

    def _context_text(self, context: Sequence[str]) -> str:
        words = [surface(w, i == 0) for i, w in enumerate(context)]
        cur = " ".join(words)
        return (self.prev + "\n" + cur) if self.prev else cur

    # -- ranking ---------------------------------------------------------------
    def _vocab(self, prefix: str) -> list[str]:
        """The POOL most frequent words starting with prefix, by first letter."""
        if self._by_letter is None:
            idx: dict[str, list[str]] = collections.defaultdict(list)
            for w, _ in self.base.uni.most_common():
                if w and w[0].isalpha():
                    idx[w[0]].append(w)
            self._by_letter = idx
        if not prefix:
            return [w for w, _ in self.base.uni.most_common(POOL)]
        out = []
        for w in self._by_letter.get(prefix[0], ()):
            if w.startswith(prefix) and w != prefix:
                out.append(w)
                if len(out) >= POOL:
                    break
        return out

    def rank(self, context: Sequence[str], prefix: str, k: int) -> list[Candidate]:
        base = self.base.predict(context, prefix, 40)
        known = {c.word: c for c in base}
        pool = list(known) + [w for w in self._vocab(prefix) if w not in known]
        if not pool:
            return []
        lp = self.scorer.logprobs(self._context_text(context))
        first = not context
        lead = bool(context)               # mid-message words follow a space
        scored = []
        for w in pool:
            c = known.get(w)
            p_ng = c.probability if c else 1e-6
            tid = self.scorer.first_token(surface(w, first), lead)
            scored.append((lp[tid].item() + self.weight * math.log(max(p_ng, 1e-12)), w))
        scored.sort(reverse=True)
        top = scored[:max(k, 1)]
        z = max(s for s, _ in top)
        norm = sum(math.exp(s - z) for s, _ in top)
        return [Candidate(w, math.exp(s - z) / norm, "lm", known[w].count if w in known else 0)
                for s, w in top]

    def predict(self, context: Sequence[str], prefix: str, k: int) -> list[Candidate]:
        base = self.base.predict(context, prefix, k)
        if len(base) == 1 and base[0].source != "unigram":
            return base                      # unique: auto-completion's ground
        return self.rank(context, prefix, k)


class ShadowPredictor(LmPredictor):
    """Shows the n-gram's suggestions, unchanged. Ranks with the LM silently, and
    when the word is finished scores both against what you actually typed. Every
    SUMMARY_EVERY words it appends the running hit rates to the shadow log."""

    SUMMARY_EVERY = 25

    def __init__(self, base, scorer, weight, log_path: Path, list_size: int = 3):
        super().__init__(base, scorer, weight)
        self.log_path = log_path
        self.list_size = list_size
        self.pending: dict[tuple[str, ...], dict[int, tuple[list[str], list[str]]]] = {}
        self.hits = collections.Counter()
        self.words = 0

    def predict(self, context, prefix, k):
        base = self.base.predict(context, prefix, k)
        self._score_finished(tuple(context))
        try:
            lm = [c.word for c in self.rank(context, prefix, self.list_size)]
        except Exception:                     # a shadow must never break the real thing
            return base
        if context and len(prefix) <= 3:
            self.pending.setdefault(tuple(context), {})[len(prefix)] = (
                [c.word for c in base[:self.list_size]], lm)
        return base

    def segment_done(self, text: str) -> None:
        words = [w.lower() for w in text.replace("\n", " ").split()]
        clean = ["".join(ch for ch in w if ch.isalnum() or ch == "'") for w in words]
        self._score_finished(tuple(w for w in clean if w))
        self.pending.clear()
        super().segment_done(text)

    def _score_finished(self, ctx: tuple[str, ...]) -> None:
        """A context one word longer than a pending one means that word is done."""
        if not ctx:
            return
        before, word = ctx[:-1], ctx[-1]
        seen = self.pending.pop(before, None)
        if not seen:
            return
        self.words += 1
        for p, (ng, lm) in seen.items():
            self.hits[("n", p)] += 1
            self.hits[("ngram", p)] += word in ng
            self.hits[("lm", p)] += word in lm
        if self.words % self.SUMMARY_EVERY == 0:
            self.write_summary()

    def write_summary(self) -> None:
        parts = []
        for p in (1, 2, 3):
            n = self.hits[("n", p)]
            if n:
                parts.append(f"{p} letter{'s' if p > 1 else ''}: n-gram {self.hits[('ngram', p)] / n:.0%}"
                             f" vs LM {self.hits[('lm', p)] / n:.0%} (n={n})")
        ms = sorted(self.scorer.forward_ms[-500:])
        lat = f"  LM pass p50 {ms[len(ms) // 2]:.0f} ms" if ms else ""
        line = (f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {self.words} words, word in top "
                f"{self.list_size}: " + "; ".join(parts) + lat + "\n")
        try:
            with open(self.log_path, "a", encoding="utf-8") as fh:
                fh.write(line)
        except OSError:
            pass
