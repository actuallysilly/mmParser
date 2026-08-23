"""
autoword — corpus reading and repair.

The typelog corpus is a keystroke RECONSTRUCTION, not a transcript. typelog
models Backspace as "pop one character" and ignores every other non-printing
key, so Ctrl+Backspace, the arrows, Home/End and any mouse click that moves the
caret desynchronise its buffer from the box — and it keeps appending regardless.
Measured over 22 days (192k words) that damages 14.7% of tokens.

Two signatures dominate, and both are recoverable rather than junk:

    fusion    two real words run together     filldepends -> fill + depends
    retype    a typo, then the correction     hjavhave    -> have

A third is not recoverable and is simply dropped: 5,179 tokens of stranded
single characters and two-letter fragments (`t`, `y`, `ou`, `ng`) — the residue
left each time the caret moved.

────────────────────────────────────────────────────────────────────────────────
THE GUARD IS LOAD-BEARING
────────────────────────────────────────────────────────────────────────────────
`is_domain` exists because without it the fusion rule destroys exactly the
vocabulary this job runs on: alice -> al + ice, papi -> pa + pi, onlyfans ->
only + fans. A token seen often enough across enough days is vocabulary whatever
the dictionary thinks. Do not "simplify" this away — it has been removed once
already and it cost the model every proper noun in the corpus.

The dictionary is the one built into Windows (ISpellChecker, Win8+), reached
through ctypes — no bundled wordlist and no new dependency. Without it the
module still runs, on corpus statistics alone, which keeps noticeably more junk.
"""
from __future__ import annotations

import collections
import ctypes
import glob
import re
import sys
from ctypes import HRESULT, POINTER, byref, c_void_p, c_wchar_p, wintypes
from pathlib import Path

from config import MMA_ROOT, MMA_USERDATA

LOG_DIRS = [
    MMA_USERDATA / "typelog",
    # typelog wrote to its own project folder before it moved into MMA. Those
    # days are the bulk of the corpus, so both paths are read and nothing has to
    # be migrated by hand.
    Path(r"D:\Software\Dev\Chatting\typelog\logs"),
]

WORD = re.compile(r"[a-z']+")
VOWELS = set("aeiouy")

# A token this well attested is deliberate vocabulary. See the header.
DOMAIN_MIN_COUNT = 8
DOMAIN_MIN_DAYS = 3
# How much commoner the stem must be before `word + stray char` is called debris
# rather than vocabulary. See is_domain.
DEBRIS_STEM_RATIO = 5


# ── Windows spell checker ─────────────────────────────────────────────────────
# Lifted verbatim from the src\autoword\clean.py prototype, which this service
# supersedes. Do not "tidy" the vtable slot numbers or the language list — both
# were established by testing against this machine and both have already been
# got wrong once by re-deriving them from the interface docs.
_CLSID_FACTORY = "{7AB36653-1796-484B-BDFA-E74F1DB7C1DC}"
_IID_FACTORY = "{8E018A9D-2415-4677-BF08-794EA61F94BB}"

# A word is English if ANY of these accepts it. The corpus is written in British
# English — `behaviour`, `realise`, `centre`, `favourite` — and an en-US-only
# checker calls every one of those a misspelling, which would drop real
# vocabulary from the model.
#
# en-CA, not en-GB, and this is a trap worth knowing about: en-GB is NOT
# installed on this machine, but BOTH ISpellCheckerFactory::IsSupported("en-GB")
# and CreateSpellChecker("en-GB") report success anyway and hand back a checker
# that is really en-US. There is no error to catch — the only way to see it is to
# ask get_SupportedLanguages, which lists en-CA/en-LR/en-PH/en-US and no en-GB.
# en-CA is genuinely present and takes British spellings (8/8 above; en-US: 1/8).
LANGUAGES = ("en-CA", "en-US")


class _GUID(ctypes.Structure):
    _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

    def __init__(self, text: str):
        super().__init__()
        ctypes.oledll.ole32.CLSIDFromString(text, byref(self))


def _vcall(ptr, index, *args, restype=HRESULT, argtypes=None):
    vtbl = ctypes.cast(ptr, POINTER(POINTER(c_void_p)))[0]
    proto = ctypes.WINFUNCTYPE(restype, c_void_p, *(argtypes or ()))
    return proto(vtbl[index])(ptr, *args)


class SpellChecker:
    """in_dict(word) -> bool, across every installed language in LANGUAGES.
    `available` is False if Windows would give us no checker at all, in which
    case every lookup answers False and the caller falls back to corpus
    evidence alone."""

    def __init__(self, languages=LANGUAGES):
        self.available = False
        self.languages: list[str] = []
        self._checkers: list[c_void_p] = []
        self._cache: dict[str, bool] = {}
        if sys.platform != "win32":
            return
        try:
            ole32 = ctypes.oledll.ole32
            ole32.CoInitializeEx(None, 2)               # apartment threaded
            factory = c_void_p()
            ole32.CoCreateInstance(byref(_GUID(_CLSID_FACTORY)), None, 1,
                                   byref(_GUID(_IID_FACTORY)), byref(factory))
            if not factory:
                return
            for lang in languages:
                checker = c_void_p()
                # ISpellCheckerFactory::CreateSpellChecker is vtable slot 5
                hr = _vcall(factory, 5, c_wchar_p(lang), byref(checker),
                            argtypes=(c_wchar_p, POINTER(c_void_p)))
                if not hr and checker:
                    self._checkers.append(checker)
                    self.languages.append(lang)
            self.available = bool(self._checkers)
        except OSError:
            return                                      # no checker; stats-only

    def _check_one(self, checker, word: str) -> bool:
        enum = c_void_p()
        # ISpellChecker::Check is vtable slot 4
        hr = _vcall(checker, 4, c_wchar_p(word), byref(enum),
                    argtypes=(c_wchar_p, POINTER(c_void_p)))
        if hr or not enum:
            return False
        err = c_void_p()
        produced = _vcall(enum, 3, byref(err), argtypes=(POINTER(c_void_p),))
        ok = not (produced == 0 and err)
        if err:
            _vcall(err, 2, restype=ctypes.c_ulong)
        _vcall(enum, 2, restype=ctypes.c_ulong)
        return ok

    def in_dict(self, word: str) -> bool:
        if not self.available:
            return False
        hit = self._cache.get(word)
        if hit is not None:
            return hit
        ok = any(self._check_one(c, word) for c in self._checkers)
        self._cache[word] = ok
        return ok


# ── repair ────────────────────────────────────────────────────────────────────
class Repairer:
    """Repairs one corpus. Holds the corpus evidence the rules consult."""

    def __init__(self, spell: SpellChecker | None = None):
        self.spell = spell if spell is not None else SpellChecker()
        self.count: collections.Counter[str] = collections.Counter()
        self.days: dict[str, set[str]] = {}
        self._known: dict[str, bool] = {}

    # -- vocabulary tests ------------------------------------------------------
    def is_word(self, w: str) -> bool:
        if w not in self._known:
            if len(w) == 1:
                self._known[w] = w in ("a", "i")
            else:
                self._known[w] = bool(set(w) & VOWELS) and self.spell.in_dict(w)
        return self._known[w]

    def is_domain(self, w: str) -> bool:
        if (len(w) <= 2
                or self.count[w] < DOMAIN_MIN_COUNT
                or len(self.days.get(w, ())) < DOMAIN_MIN_DAYS):
            return False
        # A common word with one character stranded on the end is desync debris,
        # not vocabulary — `youi`, `andd`, `thet`. It clears the thresholds above
        # because the debris recurs every time the caret moves, so without this
        # it is protected from the fusion rule and reaches the model as a word.
        # Requiring the stem to be far commoner keeps real vocabulary that merely
        # ends in a letter (`alice`, `papi`, `cucky`) — their stems are not words.
        stem = w[:-1]
        if self.is_word(stem) and self.count[stem] >= DEBRIS_STEM_RATIO * self.count[w]:
            return False
        return True

    def observe(self, day: str, tokens) -> None:
        """Record corpus evidence. Must run over the whole corpus before repair."""
        for t in tokens:
            self.count[t] += 1
            self.days.setdefault(t, set()).add(day)

    # -- the rules, in the order they are applied ------------------------------
    def repair_word(self, w: str) -> tuple[str, list[str]]:
        """(kind, words). kind: ok | double | domain | fusion | retype | junk"""
        if self.is_word(w):
            return "ok", [w]

        n = len(w)

        # exact doubling: pussypussy, uhmuhm
        if n % 2 == 0 and w[:n // 2] == w[n // 2:] and self.is_word(w[:n // 2]):
            return "double", [w[:n // 2]]

        # prefix doubling: youyou're — the longer, complete form wins
        for i in range(2, n - 1):
            if w[i:].startswith(w[:i]) and self.is_word(w[i:]):
                return "double", [w[i:]]

        # attested often enough to be vocabulary. MUST precede fusion.
        if self.is_domain(w):
            return "domain", [w]

        # fusion: two real words run together; prefer the most balanced split
        best_fusion = None
        for i in range(2, n - 1):
            a, b = w[:i], w[i:]
            if self.is_word(a) and self.is_word(b):
                skew = abs(len(a) - len(b))
                if best_fusion is None or skew < best_fusion[0]:
                    best_fusion = (skew, [a, b])
        if best_fusion:
            return "fusion", best_fusion[1]

        # retype: a garbled attempt followed by the correction. The tail is a
        # real word and the head is a plausible stab at it.
        best = None
        for i in range(1, n - 1):
            a, b = w[:i], w[i:]
            if len(b) < 3 or not self.is_word(b):
                continue
            shared = sum(1 for x, y in zip(a, b) if x == y)
            if a[0] == b[0] or shared >= max(1, len(a) // 2):
                if best is None or len(b) > len(best):
                    best = b
        if best:
            return "retype", [best]

        return "junk", []

    def repair_line(self, line: str) -> tuple[str, collections.Counter]:
        out: list[str] = []
        kinds: collections.Counter[str] = collections.Counter()
        for tok in WORD.findall(line.lower()):
            tok = tok.strip("'")
            if not tok:
                continue
            kind, words = self.repair_word(tok)
            kinds[kind] += 1
            out.extend(words)
        return " ".join(out), kinds


# ── entry point ───────────────────────────────────────────────────────────────
def read_raw(dirs=None) -> list[tuple[str, list[str]]]:
    """[(day, [raw lines])] — one line per typed segment."""
    days = []
    for d in dirs or LOG_DIRS:
        for path in sorted(glob.glob(str(Path(d) / "*.log"))):
            text = Path(path).read_text(encoding="utf-8-sig", errors="replace")
            lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
            if lines:
                days.append((Path(path).stem, lines))
    return days


def load_clean(dirs=None, extra: list[str] | None = None):
    """(cleaned lines, stats). Two passes: evidence, then repair."""
    days = read_raw(dirs)
    rep = Repairer()

    for day, lines in days:
        for ln in lines:
            rep.observe(day, (t.strip("'") for t in WORD.findall(ln.lower()) if t.strip("'")))

    cleaned: list[str] = []
    kinds: collections.Counter[str] = collections.Counter()
    for _day, lines in days:
        for ln in lines:
            text, k = rep.repair_line(ln)
            kinds += k
            if text:
                cleaned.append(text)

    for path in extra or []:
        p = Path(path)
        if p.exists():
            for ln in p.read_text(encoding="utf-8-sig", errors="replace").splitlines():
                ln = " ".join(WORD.findall(ln.lower()))
                if ln:
                    cleaned.append(ln)

    stats = {
        "days": len(days),
        "lines": sum(len(v) for _, v in days),
        "clean_lines": len(cleaned),
        "spellcheck": rep.spell.available,
        **kinds,
    }
    return cleaned, stats
