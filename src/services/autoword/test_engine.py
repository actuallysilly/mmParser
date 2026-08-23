"""
autoword — engine tests.

No display, no keyboard hook, no corpus: the engine takes characters in and
emits decisions out, so all of it is testable with a stub predictor.

    python test_engine.py

NOTE this writes nothing to userdata\\ — unlike tools\\test\\*.ahk, which mutate
live config. Keep it that way.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from engine import Engine          # noqa: E402
from model import Candidate        # noqa: E402

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append(f"{name}: got {got!r}, want {want!r}")
    else:
        print(f"  ok   {name}")


class StubPredictor:
    """Answers from a fixed table so the tests describe the engine, not the model."""

    def __init__(self, table, counts=None, finished=()):
        self.table = table
        # how often each word was seen; 99 unless a test cares
        self.counts = counts or {}
        # prefixes that are words in their own right — the real one asks the
        # Windows dictionary and your own counts; see model.finished_word
        self.finished = set(finished)

    def finished_word(self, prefix, word):
        return prefix in self.finished

    def train(self, lines): ...
    def save(self, path): ...
    def load(self, path): return False

    def predict(self, context, prefix, k):
        key = (tuple(context[-2:]), prefix)
        words = self.table.get(key, [])
        return [Candidate(w, 1.0 / (i + 1), "stub", self.counts.get(w, 99))
                for i, w in enumerate(words)][:k]


def new_engine(table=None, counts=None, finished=(), **kw):
    kw.setdefault("min_saving", 2)
    return Engine(predictor=StubPredictor(table or {}, counts, finished), **kw)


def type_text(eng, text):
    last = None
    for ch in text:
        last = eng.on_char(ch)
    return last


# ── suggesting ────────────────────────────────────────────────────────────────
def test_suggests_after_min_chars():
    eng = new_engine({((), "w"): ["want", "with"]})
    check("no suggestion before min_chars", eng.on_char("") if False else eng.suggestion, None)
    s = type_text(eng, "w")
    check("suggests after 1 char", [c.word for c in s.candidates], ["want", "with"])


def test_context_is_previous_words():
    eng = new_engine({(("i", "want"), "y"): ["you"]})
    type_text(eng, "i want y")
    check("uses last two words as context",
          [c.word for c in eng.suggestion.candidates], ["you"])


def test_rejects_short_and_equal_candidates():
    eng = new_engine({((), "go"): ["go", "gone"]})
    type_text(eng, "go")
    check("drops candidate equal to the prefix",
          [c.word for c in eng.suggestion.candidates], ["gone"])


def test_no_suggestion_when_nothing_matches():
    eng = new_engine({})
    type_text(eng, "zz")
    check("silent when the model has nothing", eng.suggestion, None)


# ── accepting and cycling ─────────────────────────────────────────────────────
def test_accept_returns_remainder_only():
    eng = new_engine({((), "w"): ["want"]})
    type_text(eng, "w")
    check("accept types only the remainder plus a space", eng.accept(), "ant ")
    check("accepted word joins the context", eng.words, ["want"])
    check("partial cleared after accept", eng.partial, "")
    check("suggestion cleared after accept", eng.suggestion, None)


def test_cycle_wraps():
    eng = new_engine({((), "w"): ["want", "with", "was"]})
    type_text(eng, "w")
    check("starts on rank 1", eng.suggestion.current.word, "want")
    eng.cycle(); check("cycles to rank 2", eng.suggestion.current.word, "with")
    eng.cycle(); check("cycles to rank 3", eng.suggestion.current.word, "was")
    eng.cycle(); check("wraps to rank 1", eng.suggestion.current.word, "want")


def test_accept_after_cycle_uses_highlighted():
    eng = new_engine({((), "w"): ["want", "with"]})
    type_text(eng, "w")
    eng.cycle()
    check("accepts the highlighted candidate", eng.accept(), "ith ")


def test_accept_without_suggestion_is_none():
    eng = new_engine({})
    check("accept is a no-op with nothing on screen", eng.accept(), None)


# ── the buffer must go quiet rather than guess ────────────────────────────────
def test_caret_move_invalidates():
    eng = new_engine({((), "w"): ["want"]})
    type_text(eng, "w")
    eng.invalidate()
    check("suggestion dropped on invalidate", eng.suggestion, None)
    check("buffer marked untrustworthy", eng.valid, False)
    check("stays silent while invalid", type_text(eng, "an"), None)


def test_boundary_restores_trust():
    eng = new_engine({((), "w"): ["want"]})
    eng.invalidate()
    eng.on_boundary()
    check("Enter makes the buffer trustworthy again", eng.valid, True)
    s = type_text(eng, "w")
    check("suggests again after a new segment", [c.word for c in s.candidates], ["want"])


def test_space_recovers_after_a_click():
    """One click used to cost every suggestion until the next Enter. The next
    typed space is enough to know where the caret is again."""
    eng = new_engine({((), "w"): ["want"]})
    eng.invalidate()
    check("silent while blind", type_text(eng, "hi"), None)
    check("the space itself suggests nothing", eng.on_char(" "), None)
    check("trusted again", eng.valid, True)
    s = type_text(eng, "w")
    check("suggests on the word after the space", [c.word for c in s.candidates], ["want"])


def test_recovered_buffer_forgets_the_unseen_context():
    """`hi` was typed while blind, so it is NOT context — the words before the
    caret are unknown and the first prediction has to go in with none."""
    eng = new_engine({((), "w"): ["want"], (("hi",), "w"): ["wrong"]})
    eng.invalidate()
    type_text(eng, "hi w")
    check("blind words never enter the context", eng.words, [])
    check("predicts with no context",
          [c.word for c in eng.suggestion.candidates], ["want"])


def test_recovered_context_heals_as_you_type():
    eng = new_engine({(("do", "you"), "w"): ["want"]})
    eng.invalidate()
    type_text(eng, " do you w")
    check("words typed after recovery are real context",
          [c.word for c in eng.suggestion.candidates], ["want"])


def test_backspace_out_of_a_recovered_buffer_goes_blind():
    """Erasing the space we recovered on puts the caret back against text we
    never saw, so the next word would glue onto an unknown one."""
    eng = new_engine({((), "w"): ["want"]})
    eng.invalidate()
    eng.on_char(" ")
    eng.on_backspace()
    check("blind again", eng.valid, False)
    check("stays silent", type_text(eng, "w"), None)


def test_backspace_on_an_empty_anchored_buffer_is_harmless():
    """Same keystroke after Enter: the box is empty, backspace does nothing."""
    eng = new_engine({((), "w"): ["want"]})
    eng.on_backspace()
    check("still trusted", eng.valid, True)
    s = type_text(eng, "w")
    check("still suggesting", [c.word for c in s.candidates], ["want"])


def test_enter_re_anchors_a_recovered_buffer():
    eng = new_engine({})
    eng.invalidate()
    eng.on_char(" ")
    check("recovered but not anchored", eng.anchored, False)
    eng.on_boundary()
    check("Enter anchors it again", eng.anchored, True)


def test_backspace_into_previous_word_keeps_the_buffer():
    """The buffer is the segment as typed, so crossing a word boundary is just
    a shorter string — the box says `hi` and so do we."""
    eng = new_engine({((), "w"): ["want"]})
    type_text(eng, "hi ")
    eng.on_backspace()
    check("still trusted", eng.valid, True)
    check("back to typing the previous word", eng.partial, "hi")
    check("and it is no longer finished", eng.words, [])


def test_backspace_all_the_way_and_retype():
    """Deleting a whole phrase used to end suggestions until the next Enter."""
    eng = new_engine({(("i", "really"), "w"): ["want"]})
    type_text(eng, "i think ")
    for _ in range(len("think ")):
        eng.on_backspace()
    check("what is left is what the box shows", eng.text, "i ")
    s = type_text(eng, "really w")
    check("suggesting again with the corrected context",
          [c.word for c in s.candidates], ["want"])


def test_backspace_keeps_punctuation_between_words():
    eng = new_engine({})
    type_text(eng, "hi, there")
    for _ in range(len("there")):
        eng.on_backspace()
    check("the comma and space survive", eng.text, "hi, ")
    check("hi is still a finished word", eng.words, ["hi"])
    eng.on_backspace()
    check("now the space is gone too", eng.text, "hi,")
    check("and hi is still finished, the comma ended it", eng.words, ["hi"])


def test_buffer_keeps_your_capitals():
    eng = new_engine({((), "he"): ["hey"]})
    type_text(eng, "Hey Ho")
    check("text is what you typed", eng.text, "Hey Ho")
    check("but matching is lowercase", eng.words, ["hey"])


def test_backspace_within_word_is_fine():
    eng = new_engine({((), "w"): ["want"]})
    type_text(eng, "wa")
    eng.on_backspace()
    check("backspace inside a word keeps the buffer", eng.valid, True)
    check("partial shrank", eng.partial, "w")


def test_punctuation_ends_a_word_not_the_segment():
    eng = new_engine({})
    type_text(eng, "hi, there")
    check("punctuation closed the word", eng.words, ["hi", "there"] if not eng.partial
          else ["hi"])
    check("segment survived punctuation", eng.valid, True)


# ── completing without being asked ────────────────────────────────────────────
def auto_engine(table, counts=None, finished=(), **kw):
    # min_saving=1 like the shipped default: `jus` -> `just` is worth having.
    kw.setdefault("min_saving", 1)
    kw.setdefault("auto_min_chars", 3)
    kw.setdefault("auto_min_count", 5)
    return new_engine(table, counts, finished, **kw)


def test_obvious_word_completes_itself():
    eng = auto_engine({((), "jus"): ["just"]})
    check("not obvious yet", type_text(eng, "ju"), None)
    s = eng.on_char("s")
    check("marked auto", s.auto, True)
    check("types only the remainder, no space", eng.auto_complete(), "t")
    check("the word is what you are typing, not context yet", eng.partial, "just")
    check("nothing moved into the context", eng.words, [])


def test_a_second_candidate_means_it_is_not_obvious():
    eng = auto_engine({((), "jus"): ["just", "justin"]})
    s = type_text(eng, "jus")
    check("two continuations, so ask", s.auto, False)
    check("still offered on the strip", [c.word for c in s.candidates], ["just", "justin"])


def test_rare_word_is_not_obvious():
    eng = auto_engine({((), "jus"): ["just"]}, counts={"just": 4})
    check("seen 4 times, below the bar", type_text(eng, "jus").auto, False)


def test_short_prefix_is_not_obvious():
    eng = auto_engine({((), "j"): ["just"], ((), "ju"): ["just"]})
    check("one char is not enough", type_text(eng, "j").auto, False)
    check("two is not either", eng.on_char("u").auto, False)


def test_completion_never_chains():
    eng = auto_engine({((), "jus"): ["just"], ((), "just"): ["justice"]})
    type_text(eng, "jus")
    eng.auto_complete()
    check("paused for the rest of the word", eng.on_char("i"), None)
    check("and the next word is free again",
          (eng.on_char(" "), eng.auto_paused)[1], False)


def test_typing_the_word_yourself_is_not_double_counted():
    """The service swallows the echoed letters, so the engine must already hold
    the whole word — not the prefix it had when it fired."""
    eng = auto_engine({((), "jus"): ["just"]})
    type_text(eng, "jus")
    eng.auto_complete()
    check("partial is the finished word", eng.partial, "just")
    eng.on_char(" ")
    check("one word, spelled once", eng.words, ["just"])


def test_backspace_takes_the_whole_completion_back():
    eng = auto_engine({((), "ima"): ["imagine"]})
    type_text(eng, "ima")
    eng.auto_complete()
    check("four characters to delete", eng.undo_auto(), 4)
    check("back to what you typed", eng.partial, "ima")
    check("and it does not fire again", eng.on_char("g"), None)


def test_undo_window_closes_when_you_keep_typing():
    eng = auto_engine({((), "jus"): ["just"]})
    type_text(eng, "jus")
    eng.auto_complete()
    eng.on_char("!")
    check("nothing left to undo", eng.auto_undo, None)
    check("undo is a no-op", eng.undo_auto(), 0)


def test_a_finished_word_is_never_extended():
    """`do` -> `does` is right most of the time and still wrong to do."""
    eng = auto_engine({((), "do"): ["does"]}, finished={"do"}, auto_min_chars=2)
    s = type_text(eng, "do")
    check("not completed for you", s.auto, False)
    check("but still offered", [c.word for c in s.candidates], ["does"])


def test_fragments_are_still_completed():
    eng = auto_engine({((), "jus"): ["just"]}, finished={"do", "you", "leg"})
    check("`jus` is not a word, so finish it", type_text(eng, "jus").auto, True)


def test_never_list_wins():
    eng = auto_engine({((), "leg"): ["legs"]})
    check("fires without the list", type_text(eng, "leg").auto, True)
    eng = auto_engine({((), "leg"): ["legs"]}, auto_never={"legs"})
    check("and not with it", type_text(eng, "leg").auto, False)


def test_the_fragment_rule_can_be_switched_off():
    eng = auto_engine({((), "do"): ["does"]}, finished={"do"},
                      auto_min_chars=2, auto_only_fragments=False)
    check("extends again when asked to", type_text(eng, "do").auto, True)


def test_backspace_pauses_completion_until_the_next_space():
    """Correcting a mistake is the worst moment to type for someone."""
    eng = auto_engine({((), "jus"): ["just"]})
    type_text(eng, "juss")
    eng.on_backspace()
    check("paused while you fix it", eng.auto_paused, True)
    check("so no completion", eng.suggestion.auto, False)
    check("still offered on the strip",
          [c.word for c in eng.suggestion.candidates], ["just"])
    eng.on_char("t")
    eng.on_char(" ")
    check("the next word is free again", eng.auto_paused, False)


def test_off_by_default():
    eng = new_engine({((), "jus"): ["just"]}, min_saving=1)
    check("no auto-completion unless asked for", type_text(eng, "jus").auto, False)
    check("auto_complete refuses", eng.auto_complete(), None)


# ── modes ─────────────────────────────────────────────────────────────────────
def test_completion_mode_ignores_context():
    eng = new_engine({((), "y"): ["you"], (("i", "want"), "y"): ["yours"]},
                     predict_mode="completion")
    type_text(eng, "i want y")
    check("completion mode uses the empty context",
          [c.word for c in eng.suggestion.candidates], ["you"])


def test_both_mode_falls_back_to_no_context():
    eng = new_engine({((), "y"): ["you"]}, predict_mode="both")
    type_text(eng, "i want y")
    check("both mode falls back when context is unknown",
          [c.word for c in eng.suggestion.candidates], ["you"])


# ── rewording (Ctrl+Tab) ─────────────────────────────────────────────────────
class StubThesaurus:
    """The reword groups, without a file. Case matching is the real one's job,
    so this mimics it: the tests care that the engine asks with what you typed."""

    def __init__(self, table):
        self.table = table

    def alternatives(self, word, k=5):
        alts = self.table.get(word.lower(), [])[:k]
        if word[:1].isupper():
            return [a[:1].upper() + a[1:] for a in alts]
        return list(alts)


TOUCH = {"touched": ["caressed", "stroked", "grazed"]}


def reword_engine(table=TOUCH, **kw):
    return Engine(predictor=StubPredictor({}), thesaurus=StubThesaurus(table), **kw)


def test_reword_offers_the_last_word():
    eng = reword_engine()
    type_text(eng, "i touched you")           # the last word is `you`
    check("no group for it", eng.reword(), None)
    eng.reset(); type_text(eng, "i touched")
    check("alternatives for the last word",
          [c.word for c in eng.reword().candidates], ["caressed", "stroked", "grazed"])


def test_reword_reaches_over_a_space():
    eng = reword_engine()
    type_text(eng, "i touched ")
    suggestion = eng.reword()
    check("the word", suggestion.reword, "touched")
    check("and what trails it", suggestion.tail, " ")


def test_reword_keeps_your_capitals():
    eng = reword_engine()
    type_text(eng, "Touched")
    check("capitalised back", [c.word for c in eng.reword().candidates],
          ["Caressed", "Stroked", "Grazed"])


def test_swap_replaces_the_word_and_puts_the_tail_back():
    eng = reword_engine()
    type_text(eng, "i touched, ")
    eng.reword()
    check("delete the word and its tail, type the new one and the tail",
          eng.swap(), (9, "caressed, "))
    check("buffer follows the box", eng.text, "i caressed, ")


def test_swap_takes_the_highlighted_one():
    eng = reword_engine()
    type_text(eng, "i touched")
    eng.reword(); eng.cycle()
    check("rank 2", eng.swap(), (7, "stroked"))
    check("buffer follows the box", eng.text, "i stroked")


def test_a_keystroke_in_flight_cancels_the_swap():
    """The hook offers the list; the loop thread is a keystroke behind. When it
    lands, the list must stop being takeable — see _handle_reword."""
    eng = reword_engine()
    type_text(eng, "i touched")
    eng.reword()
    eng.on_char(" ")                          # the keystroke that was in flight
    check("suggestion dropped", eng.suggestion, None)
    check("and nothing to swap", eng.swap(), None)


def test_reword_is_never_automatic():
    eng = reword_engine(auto_min_chars=1, auto_min_count=1)
    type_text(eng, "i touched")
    check("asked for, never typed for you", eng.reword().auto, False)


def test_reword_goes_quiet_after_a_click():
    eng = reword_engine()
    type_text(eng, "i touched")
    eng.invalidate()                          # a click, a caret move
    check("we no longer know what the last word was", eng.reword(), None)


def test_reword_needs_a_thesaurus():
    eng = Engine(predictor=StubPredictor({}))
    type_text(eng, "i touched")
    check("off without one", eng.reword(), None)


def test_dismiss_keeps_the_buffer():
    eng = reword_engine()
    type_text(eng, "i touched")
    eng.reword(); eng.dismiss()
    check("list gone", eng.suggestion, None)
    check("buffer intact", eng.text, "i touched")
    check("and it can be asked again",
          [c.word for c in eng.reword().candidates], ["caressed", "stroked", "grazed"])


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            print(name)
            fn()
    print()
    if FAILED:
        print(f"{len(FAILED)} FAILED")
        for f in FAILED:
            print("  " + f)
        sys.exit(1)
    print("all passed")
