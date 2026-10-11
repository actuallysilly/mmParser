"""
Tests for lm.py with a fake scorer, so they run without torch or a GPU.

    python -m unittest test_lm.py      (from this folder)

The fake LM "prefers" whichever words it is told to, so each test can say what
the sentence-level model thinks and check what reaches the list.
"""
import tempfile
import unittest
from pathlib import Path

from lm import LmPredictor, ShadowPredictor, surface
from model import NgramPredictor


class _Val:
    def __init__(self, v):
        self.v = v

    def item(self):
        return self.v


class FakeScorer:
    """Token id = the word itself; log-prob 0 for liked words, -10 otherwise."""

    def __init__(self, likes=()):
        self.likes = {w.lower() for w in likes}
        self.contexts = []
        self.forward_ms = [1.0]

    def logprobs(self, text):
        self.contexts.append(text)
        likes = self.likes

        class Row:
            def __getitem__(self, word):
                return _Val(0.0 if word.lower() in likes else -10.0)
        return Row()

    def first_token(self, word, lead_space):
        return word


def ngram(lines):
    p = NgramPredictor()
    p.train(lines)
    return p


TRAIN = ["i want you to see me", "i want you to know", "i want you to see it",
         "thank you so much", "you are so sweet", "you are so naked"]


class Ranking(unittest.TestCase):
    def test_the_lm_reorders_the_ngram_candidates(self):
        base = ngram(TRAIN)
        self.assertEqual(base.predict(["want", "you", "to"], "", 3)[0].word, "see")
        p = LmPredictor(base, FakeScorer(likes=["know"]), weight=0.5)
        self.assertEqual(p.predict(["want", "you", "to"], "", 3)[0].word, "know")

    def test_the_prefix_still_filters(self):
        p = LmPredictor(ngram(TRAIN), FakeScorer(likes=["know"]), weight=0.5)
        words = [c.word for c in p.predict(["you", "to"], "s", 3)]
        self.assertTrue(words and all(w.startswith("s") for w in words))

    def test_vocabulary_words_join_the_pool(self):
        # No message has ever started "you s...", so the n-gram falls back to raw
        # frequency; the vocabulary pool lets the LM pick 'sweet' anyway.
        p = LmPredictor(ngram(TRAIN + ["you look so sweet"]), FakeScorer(likes=["sweet"]))
        self.assertEqual(p.predict(["you"], "s", 3)[0].word, "sweet")

    def test_a_unique_ngram_answer_passes_through_untouched(self):
        # Auto-completion gates on "exactly one word ever followed this", so
        # the re-ranker must not add candidates to a unique answer.
        base = ngram(TRAIN)
        unique = base.predict(["thank", "you", "so"], "m", 3)
        self.assertEqual(len(unique), 1)
        p = LmPredictor(base, FakeScorer(likes=["more"]))
        self.assertEqual([c.word for c in p.predict(["thank", "you", "so"], "m", 3)], ["much"])

    def test_the_previous_message_is_context(self):
        s = FakeScorer()
        p = LmPredictor(ngram(TRAIN), s)
        p.segment_done("Hey there")
        p.rank(["i", "want"], "y", 3)
        self.assertEqual(s.contexts[-1], "Hey there\nI want")

    def test_surface_forms(self):
        self.assertEqual(surface("i'm", False), "I'm")
        self.assertEqual(surface("hey", True), "Hey")
        self.assertEqual(surface("hey", False), "hey")


class Shadow(unittest.TestCase):
    def test_shows_the_ngram_and_scores_both(self):
        base = ngram(TRAIN)
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "shadow.log"
            p = ShadowPredictor(base, FakeScorer(likes=["know"]), 0.5, log, list_size=1)
            shown = p.predict(["want", "you", "to"], "k", 3)
            self.assertEqual([c.word for c in shown], [c.word for c in base.predict(["want", "you", "to"], "k", 3)])
            p.predict(["want", "you", "to"], "", 3)     # no letters: not scored
            p.segment_done("want you to know")           # the word was "know"
            self.assertEqual(p.words, 1)
            self.assertEqual(p.hits[("lm", 1)], 1)
            p.write_summary()
            self.assertIn("LM 100%", log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
