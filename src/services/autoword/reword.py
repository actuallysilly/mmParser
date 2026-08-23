"""
autoword — saying it another way.

Ctrl+Tab takes the word you have just typed and offers other words for it:
`touched` -> `caressed`, `stroked`, `grazed`. Nothing is typed until you take
one, which is the whole difference between this and auto-completion — a reword
is something you asked for, so it can afford to be a suggestion rather than a
near-certainty.

────────────────────────────────────────────────────────────────────────────────
A FILE YOU OWN, NOT A THESAURUS
────────────────────────────────────────────────────────────────────────────────
The groups live in `userdata\\autoword\\reword.txt`, one group per line, written
with a starter set the first time this loads. A general thesaurus would answer
`touched` with `affected`, `moved` and `impinged`: correct, and useless here.
The words worth reaching for are the ones that suit how you write, so the source
has to be something you can edit in ten seconds — and the order you write them
in is the order they are offered.

Groups are symmetric. Every word in a line offers the others, so `caressed` gets
you back to `touched` without a second entry.

────────────────────────────────────────────────────────────────────────────────
WHY IT INFLECTS
────────────────────────────────────────────────────────────────────────────────
You do not type base forms. You type `touched`, `touching`, `touches` — so a
file of base forms alone would answer almost nothing you actually write, and
writing every group out three more times by hand is how a file like this stops
being maintained.

So each group is expanded with -s, -ed and -ing at load time. English spelling
makes that a guess (`stroke` + `ed` is `stroked`, `rub` + `ed` is `rubbed`,
`whisper` + `ed` is neither `whisperred` nor a doubling rule anyone can state in
three lines), so every plausible spelling is generated and the Windows
dictionary says which is a word. Nothing that fails that check is offered.
Without a dictionary the first guess is taken and the file is the fallback: an
irregular form gets its own line, `felt, sensed, noticed`.
"""
from __future__ import annotations

import re
from pathlib import Path

from config import MMA_USERDATA

GROUPS = MMA_USERDATA / "autoword" / "reword.txt"

WORD = re.compile(r"^[A-Za-z']+$")
VOWELS = "aeiou"

DEFAULT_GROUPS = """\
; autoword — reword groups. Ctrl+Tab on a word offers the rest of its line.
;
; One group per line, comma separated, in the order you want them offered.
; Groups are symmetric: every word in a line offers the others.
;
; Write base forms. -s, -ed and -ing are generated at load time and checked
; against the Windows dictionary, so `touch` covers `touched` and `touching`
; too. Irregular forms need their own line (`felt, sensed, noticed`), and so do
; phrases — `wind up` is offered as it stands and is never inflected.
;
; This is a starter set. Cut what does not sound like you; that is the point.

; ── touch and hold ───────────────────────────────────────────────────────────
touch, caress, stroke, graze, brush, trace
hold, hug, embrace, squeeze, cradle
cuddle, snuggle, curl up, nestle
kiss, peck, smooch
pull, tug, drag, draw
press, push, pin, lean
bite, nibble, nip
tease, taunt, torment, wind up
whisper, murmur, breathe, purr
felt, sensed, noticed

; ── wanting ──────────────────────────────────────────────────────────────────
want, crave, need, fancy, long for
like, love, adore, treasure, worship
miss, pine for, ache for
tempt, entice, lure, draw in
excite, thrill, electrify, light up
please, satisfy, delight, spoil
imagine, picture, envision, daydream
think, wonder, ponder, muse
enjoy, relish, savour, revel in

; ── how it feels ─────────────────────────────────────────────────────────────
hot, gorgeous, stunning, breathtaking, irresistible
sexy, alluring, seductive, tempting, magnetic
cute, adorable, sweet, precious, darling
good, great, amazing, incredible, wonderful
nice, lovely, delightful, pleasant
big, huge, massive, enormous
small, tiny, little, petite
soft, smooth, silky, delicate, tender
warm, cosy, snug, toasty
slow, gentle, unhurried, lazy
rough, hard, firm, intense
naughty, cheeky, mischievous, wicked
shy, timid, bashful, coy
eager, keen, desperate, dying
tired, exhausted, drained, spent, worn out
happy, thrilled, delighted, over the moon
sad, down, blue, low, gutted
bored, restless, listless, fed up

; ── talking ──────────────────────────────────────────────────────────────────
say, tell, mention
talk, chat, catch up
ask, wonder, question
send, share, drop
show, reveal, flash, unveil
look, gaze, stare, watch, admire
smile, grin, beam, smirk
laugh, giggle, chuckle, cackle
know, realise, understand
remember, recall, think back
forget, overlook, blank

; ── doing ────────────────────────────────────────────────────────────────────
start, begin, kick off
finish, end, wrap up
try, attempt, have a go
make, create, craft
get, receive, grab
go, head, wander, slip away
come, arrive, drop by, swing by
stay, linger, hang around
wait, hold on, hang tight
rest, relax, unwind, wind down

; ── odds and ends ────────────────────────────────────────────────────────────
very, really, incredibly, seriously, absolutely
maybe, perhaps, possibly
always, constantly, forever
message, text, note, dm
photo, pic, picture, shot, snap
video, clip, vid
body, figure, frame, curves
lips, mouth
hands, fingers, palms
eyes, gaze
voice, tone
"""


# ── spelling ──────────────────────────────────────────────────────────────────
def match_case(sample: str, word: str) -> str:
    """Give `word` the capitalisation of `sample`.

    You typed the word, so the case is yours: `Touched` must come back
    `Caressed`, not `caressed` at the start of your sentence.
    """
    if sample.isupper() and len(sample) > 1:
        return word.upper()
    if sample[:1].isupper():
        return word[:1].upper() + word[1:]
    return word


def spellings(base: str, suffix: str) -> list[str]:
    """Every plausible spelling of base+suffix, likeliest first.

    Plurals are a rule. The past and the participle are not: dropping a final
    `e` and doubling a final consonant both depend on stress, which is not
    recoverable from spelling — `whisper` does not double and `prefer` does — so
    both spellings are offered and the dictionary decides. Short words lead with
    the doubled form, long ones with the plain one, which is the right guess
    when there is no dictionary to ask.
    """
    if suffix == "s":
        if base.endswith(("s", "x", "z", "ch", "sh")):
            return [base + "es"]
        if len(base) > 1 and base.endswith("y") and base[-2] not in VOWELS:
            return [base[:-1] + "ies"]
        return [base + "s"]

    out = []
    if suffix == "ed":
        if base.endswith("e"):
            out.append(base + "d")
        elif len(base) > 1 and base.endswith("y") and base[-2] not in VOWELS:
            out.append(base[:-1] + "ied")
        else:
            out.append(base + "ed")
    else:                                       # ing
        if base.endswith("e") and not base.endswith(("ee", "oe", "ye")):
            out.append(base[:-1] + "ing")
        else:
            out.append(base + "ing")

    if _doubles(base):
        out.insert(0 if len(base) <= 4 else 1, base + base[-1] + suffix)
    return out


def _doubles(base: str) -> bool:
    """Consonant-vowel-consonant, the shape that can double: `rub`, `slip`.

    `w`, `x` and `y` never double, and a word already ending in a doubled
    consonant has nothing to add.
    """
    if len(base) < 3 or base[-1] in "wxy":
        return False
    return (base[-1] not in VOWELS and base[-2] in VOWELS
            and base[-3] not in VOWELS and base[-1] != base[-2])


# ── the groups ────────────────────────────────────────────────────────────────
class Thesaurus:
    """`alternatives(word)` — the rest of that word's line, inflected to match."""

    def __init__(self, by_word: dict[str, list[str]] | None = None):
        self.by_word = by_word if by_word is not None else {}
        self.groups = 0

    # -- lookup ---------------------------------------------------------------
    def alternatives(self, word: str, k: int = 5) -> list[str]:
        alts = self.by_word.get(word.lower(), ())
        return [match_case(word, a) for a in alts[:k]]

    def __bool__(self) -> bool:
        return bool(self.by_word)

    # -- building -------------------------------------------------------------
    @classmethod
    def load(cls, path: Path = GROUPS, in_dict=None) -> "Thesaurus":
        """Read the file, writing it with the starter set first if it is missing.

        `in_dict(word) -> bool` vets generated inflections. Pass None and the
        first guess is taken on trust — a wrong one costs you an odd-looking
        option in a list you are reading, never a word in your message.
        """
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(DEFAULT_GROUPS, encoding="utf-8")
        try:
            raw = path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            return cls()
        return cls.from_lines(raw.splitlines(), in_dict)

    @classmethod
    def from_lines(cls, lines, in_dict=None) -> "Thesaurus":
        self = cls()
        groups = []
        for line in lines:
            line = line.strip()
            if not line or line[0] in ";#":
                continue
            words = [w.strip().lower() for w in line.split(",")]
            words = [w for w in words if w]
            if len(words) > 1:
                groups.append(words)
        self.groups = len(groups)

        # The file wins over anything generated: an explicit line for `felt` is
        # there precisely because the rules would not have produced it.
        for group in groups:
            self._add(group, overwrite=True)
        for group in groups:
            for suffix in ("s", "ed", "ing"):
                self._add(self._inflect(group, suffix, in_dict), overwrite=False)
        return self

    @staticmethod
    def _inflect(group: list[str], suffix: str, in_dict) -> list[str]:
        """The group with `suffix` on every member that can take one.

        A member that produces no real word drops out rather than dragging the
        group down — `curl up` takes no suffix and is still a perfectly good
        thing to offer for `cuddled`.
        """
        out = []
        for word in group:
            if not WORD.match(word):
                continue                        # phrases are offered as written
            forms = spellings(word, suffix)
            if in_dict:
                forms = [f for f in forms if in_dict(f)]
            if forms:
                out.append(forms[0])
        return out

    def _add(self, group: list[str], overwrite: bool) -> None:
        if len(group) < 2:
            return
        for i, word in enumerate(group):
            if not overwrite and word in self.by_word:
                continue
            self.by_word[word] = group[i + 1:] + group[:i]
