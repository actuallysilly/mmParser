"""
autoword — the suggestion state machine.

Owns the reconstructed segment buffer and decides when a suggestion is on
screen. Knows nothing about keyboards or windows: it takes characters in and
emits `show`/`hide`/`type` decisions out, so it is testable without a display
and without a hook (see test_engine.py).

The buffer pays for itself twice. Forwards it is the next word (`predict`);
backwards it is the last one (`reword`), which is why Ctrl+Tab knows what to
replace and how much of it to delete. Both go quiet on the same signal, because
both are claims about text neither of them can see.

────────────────────────────────────────────────────────────────────────────────
THE BUFFER IS THE SAME BUFFER TYPELOG GETS WRONG
────────────────────────────────────────────────────────────────────────────────
This tracks what you have typed by watching keystrokes, which is exactly the
reconstruction typelog gets wrong when the caret moves: it models Backspace as
"pop one" and ignores arrows, Home/End, Ctrl+Backspace and mouse clicks. Here
that bug would be worse than a dirty corpus — it would predict from a context
that isn't on screen.

So this class does the opposite of typelog: any signal it cannot model is
treated as "I no longer know what is in the box" and the buffer is dropped
(`invalidate`). A missed suggestion costs nothing. A suggestion computed from a
stale buffer costs a wrong word in a message to a paying customer.

Coming back from that used to need Enter, which in practice meant one click —
on the conversation, on the box, anywhere at all — killed suggestions for the
whole message you were about to type. So `recover` takes the next *typed space*
as the cheaper re-entry: after it the caret sits somewhere we watched, the next
word is known from its first character, and since the model conditions on at
most two preceding words, two more words restore full context quality on their
own. The one thing still unknown is whatever sits to the RIGHT of the caret —
hence `anchored`, which keeps a backspace out of a recovered buffer from walking
blind into it.

────────────────────────────────────────────────────────────────────────────────
ONE STRING, NOT A WORD LIST
────────────────────────────────────────────────────────────────────────────────
The buffer is `text`: the segment exactly as typed. `words` and `partial` are
derived from it, never stored.

That is the difference between backspace working and backspace ending the
segment. Holding a list of finished words and a partial throws away the spaces
and punctuation between them, so a Backspace that crosses a word boundary has
nothing left to reconstruct — the old code had to invalidate there, which meant
deleting one character too many cost you every suggestion until the next space.
Keeping the string models the box, so deleting back into `to ` simply leaves you
typing `to` again, exactly as the box shows. It also keeps your capitalisation,
which the word list dropped.

What still cannot be modelled is unchanged: caret moves, clicks, and anything
that edits text we never saw.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Sequence

from model import Candidate, Predictor

WORDCHAR = re.compile(r"[A-Za-z']")
WORD = re.compile(r"[A-Za-z']+")
TRAILING_WORD = re.compile(r"[A-Za-z']*$")
# The last word in the buffer and whatever trails it — a space, a comma, both.
# Rewording has to put that tail back, or `touched, ` becomes `caressed`.
LAST_WORD = re.compile(r"([A-Za-z']+)([^A-Za-z']*)$")


@dataclass
class Suggestion:
    candidates: list[Candidate]
    active: int = 0
    auto: bool = False      # obvious enough to type without being asked
    reword: str = ""        # the word these replace, "" when finishing one
    tail: str = ""          # what followed it, to be put back after the swap

    @property
    def current(self) -> Candidate | None:
        if 0 <= self.active < len(self.candidates):
            return self.candidates[self.active]
        return None


@dataclass
class Engine:
    predictor: Predictor
    thesaurus: object | None = None   # reword.Thesaurus; None = Ctrl+Tab is off
    min_chars: int = 1
    list_size: int = 3
    min_saving: int = 1
    predict_mode: str = "nextword"
    auto_min_chars: int = 0          # 0 = never complete without a keypress
    auto_min_count: int = 5
    auto_only_fragments: bool = True                  # never extend a finished word
    auto_never: set[str] = field(default_factory=set) # and never these, ever
    reword_list_size: int = 5

    text: str = ""                                    # the segment, as typed
    suggestion: Suggestion | None = None
    valid: bool = True                                # is the buffer trustworthy?
    anchored: bool = True                             # does it start where the text does?
    auto_paused: bool = False                         # one auto-completion per word
    auto_undo: tuple[str, str] | None = None          # (word, prefix) we just typed

    # ── what the box says ────────────────────────────────────────────────────
    @property
    def partial(self) -> str:
        """The word being typed — the run of word characters at the caret."""
        return TRAILING_WORD.search(self.text).group(0).lower()

    @property
    def words(self) -> list[str]:
        """Completed words in this segment, oldest first."""
        found = [w.lower() for w in WORD.findall(self.text)]
        return found[:-1] if self.partial else found

    # ── buffer maintenance ───────────────────────────────────────────────────
    def reset(self) -> None:
        """New segment — Enter, or focus moved to a different box."""
        self.text = ""
        self.suggestion = None
        self.valid = True
        self.anchored = True
        self.auto_paused = False
        self.auto_undo = None

    def invalidate(self) -> None:
        """We can no longer model what is on screen. Go quiet until a space or a
        segment boundary rather than guess. See the header."""
        self.text = ""
        self.suggestion = None
        self.valid = False
        self.anchored = False
        self.auto_paused = False
        self.auto_undo = None

    def recover(self) -> None:
        """A space was typed while blind — trust the buffer again, from here.

        Not `reset`: the segment did not start here, so `anchored` stays False
        and there may be text to the right of the caret we have never seen.
        """
        self.text = ""
        self.suggestion = None
        self.valid = True

    # ── input ────────────────────────────────────────────────────────────────
    def on_char(self, ch: str) -> Suggestion | None:
        if not self.valid:
            # Blind since a click or a caret move. A space is the one signal
            # that puts us back on known ground — everything after it, we saw.
            if ch.isspace():
                self.recover()
            return None
        # Typing anything closes the undo window on the last auto-completion:
        # the correction you can make with one Backspace is the one you make
        # immediately.
        self.auto_undo = None
        if not WORDCHAR.match(ch):
            self.auto_paused = False        # a word ended; the next one is free
        self.text += ch
        return self._refresh()

    def on_backspace(self) -> Suggestion | None:
        if not self.valid:
            return None
        self.auto_undo = None
        # Any correction stops it completing until the next word boundary. While
        # you are fixing something is the worst possible moment to type for you,
        # and a mistake mid-word is exactly when a confident-looking prefix
        # appears out of nowhere.
        self.auto_paused = True
        if not self.text:
            # Nothing of ours left to delete. Either the box is empty and this
            # keystroke did nothing, or we recovered mid-message and it just ate
            # a character we never saw.
            if not self.anchored:
                self.invalidate()
            return None
        self.text = self.text[:-1]
        return self._refresh()

    def on_boundary(self) -> None:
        """Enter / Send — the segment is finished."""
        self.reset()

    # ── suggestion lifecycle ─────────────────────────────────────────────────
    def _refresh(self) -> Suggestion | None:
        self.suggestion = None
        if not self.valid:
            return None

        partial = self.partial
        if self.predict_mode == "completion":
            context: Sequence[str] = ()
        else:
            context = self.words

        # nextword needs at least min_chars of the target word; completion needs
        # at least one character to complete.
        needed = max(1, self.min_chars) if self.predict_mode != "nextword" else self.min_chars
        if len(partial) < needed:
            return None

        # Ask for two even when only one is displayed: "is there a second
        # candidate at all" is the whole auto-completion test.
        cands = self.predictor.predict(context, partial, max(2, self.list_size))

        if not cands and self.predict_mode == "both" and context:
            cands = self.predictor.predict((), partial, max(2, self.list_size))

        alone = len(cands) == 1
        cands = cands[:self.list_size]

        # Gate on characters SAVED, never on word length. Accepting costs one
        # keystroke, so the payoff is (word - prefix) - 1 and it shrinks as you
        # type. Thresholding length instead throws away `you`, `to`, `so` and
        # `me` — the highest-value predictions in the corpus — while still
        # offering a long word you have almost finished typing.
        cands = [c for c in cands
                 if len(c.word) - len(partial) >= self.min_saving]
        if not cands:
            return None

        self.suggestion = Suggestion(cands, 0, auto=self._is_obvious(alone, cands[0]))
        return self.suggestion

    def _is_obvious(self, alone: bool, top: Candidate) -> bool:
        """Should this be typed without being asked?

        "Obvious" is not "probable". Measured held-out on 5 unseen days, a
        probability threshold is a bad gate — p >= 0.9 after one character is
        still wrong 37% of the time, which is worse than useless when being
        wrong writes into a live message. What works is having no alternative
        at all, backed by enough sightings to mean something:

            one continuation, seen >=3, 3 chars typed    95.4%   39 wrong/day
            one continuation, seen >=5, 3 chars typed    97.2%   17 wrong/day
            one continuation, seen >=10, 3 chars typed   98.1%    7 wrong/day

        `alone` is the load-bearing term: it says nothing else in the corpus has
        ever followed this context with this prefix.

        Being right is not enough on its own, though. `do` -> `does` is right
        most of the time and still wrong to do, because you had finished the
        word — you just had not typed the space yet. Extending a word you have
        already completed is a different act from finishing a fragment, so
        `finished_word` refuses the whole class, and `auto_never` is the manual
        override for whatever it still gets wrong.
        """
        if self.auto_min_chars <= 0 or self.auto_paused or not alone:
            return False
        partial = self.partial
        if len(partial) < self.auto_min_chars or top.count < self.auto_min_count:
            return False
        if top.word in self.auto_never:
            return False
        if self.auto_only_fragments and self.predictor.finished_word(partial, top.word):
            return False
        return True

    def cycle(self) -> Suggestion | None:
        if not self.suggestion:
            return None
        self.suggestion.active = (self.suggestion.active + 1) % len(self.suggestion.candidates)
        return self.suggestion

    def accept(self) -> str | None:
        """Characters to type to complete the highlighted candidate, or None.

        Returns only the *remainder* — the prefix is already in the box — plus a
        trailing space, so accepting also moves you to the next word.
        """
        if not self.suggestion:
            return None
        cand = self.suggestion.current
        partial = self.partial
        if not cand or not cand.word.startswith(partial):
            return None
        remainder = cand.word[len(partial):] + " "
        self.text += remainder
        self.suggestion = None
        self.auto_paused = False
        return remainder

    def reword(self) -> Suggestion | None:
        """Ctrl+Tab: other words for the one you have just typed.

        The opposite end of the same feature. A completion has to be nearly
        certain because it types itself; this is asked for, shows its whole
        hand, and changes nothing until you take one — so it can offer the
        fifth-best word without having to defend it.

        Reads the buffer rather than the screen, so it goes quiet exactly where
        everything else does: after a click or a caret move we no longer know
        what the last word was, and guessing would replace the wrong text.
        """
        if not self.valid or not self.thesaurus:
            return None
        match = LAST_WORD.search(self.text)
        if not match:
            return None
        word, tail = match.group(1), match.group(2)
        words = self.thesaurus.alternatives(word, self.reword_list_size)
        if not words:
            return None
        cands = [Candidate(w, 0.0, "reword", 0) for w in words]
        self.suggestion = Suggestion(cands, 0, auto=False, reword=word, tail=tail)
        return self.suggestion

    def swap(self) -> tuple[int, str] | None:
        """Take the highlighted reword: (characters to delete, text to type).

        Backspaces rather than a selection, because we cannot select what we
        cannot see. The tail comes off and goes back on with it, so the caret
        lands where it started and `touched, ` reads `caressed, `.
        """
        suggestion = self.suggestion
        if not suggestion or not suggestion.reword:
            return None
        cand = suggestion.current
        target = suggestion.reword + suggestion.tail
        if not cand or not self.text.endswith(target):
            return None
        replacement = cand.word + suggestion.tail
        self.text = self.text[:-len(target)] + replacement
        self.suggestion = None
        # A backspace now is a backspace, not the undo of an auto-completion
        # two words ago that this has just written over.
        self.auto_undo = None
        return len(target), replacement

    def dismiss(self) -> None:
        """Esc — put the list away without touching the buffer or the box."""
        self.suggestion = None

    def auto_complete(self) -> str | None:
        """Characters to type for an obvious word, or None.

        Deliberately NOT `accept`: no trailing space, and the word stays the
        partial rather than moving into the context. You did not ask for this
        one, so it has to leave you exactly where typing it yourself would —
        free to add a comma, keep typing letters, or take it back.
        """
        if not self.suggestion or not self.suggestion.auto:
            return None
        cand = self.suggestion.current
        partial = self.partial
        if not cand or not cand.word.startswith(partial):
            return None
        remainder = cand.word[len(partial):]
        self.auto_undo = (cand.word, partial)
        self.text += remainder
        self.auto_paused = True          # never chain one completion into another
        self.suggestion = None
        return remainder

    def undo_auto(self) -> int:
        """Take back the last auto-completion. Returns characters to delete.

        The whole insertion goes, not one character of it: it is an undo of
        something you did not ask for, not an edit of something you typed.
        Auto-completion then stays off for the rest of this word, or the next
        keystroke would put it straight back.
        """
        if not self.auto_undo:
            return 0
        word, prefix = self.auto_undo
        self.auto_undo = None
        n = len(word) - len(prefix)
        self.text = self.text[:-n] if n else self.text
        self.suggestion = None
        self.auto_paused = True
        return n

    # ── introspection ────────────────────────────────────────────────────────
    @property
    def context_text(self) -> str:
        partial = self.partial
        return " ".join(self.words[-2:] + ([partial] if partial else []))
