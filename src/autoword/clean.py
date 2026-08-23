#!/usr/bin/env python3
"""
MMA autoword — the cleanup layer.

The typelog corpus is a keystroke RECONSTRUCTION, not a transcript, so a large
share of it is not language. Measured on 21 days (162k words): 22,235 distinct
tokens, of which 15,978 appear exactly once and are overwhelmingly junk —
`throughjourney`, `uoryour`, `jpredible`, `ednlessendless`. Feeding that to a
completion index means offering garbage as suggestions, so it gets cleaned first.

-------------------------------------------------------------------------------
WHERE THE JUNK COMES FROM  (this is a typelog bug, not noise)
-------------------------------------------------------------------------------
typelog's on_press models Backspace as "pop one character" and ignores every
other non-printing key (see services/typelog/typelog.pyw, the comment ending
"all other special keys ... are ignored"). So Ctrl+Backspace, the arrow keys,
Home/End, and any mouse click that moves the caret all desynchronise its buffer
from what is actually in the box — and it keeps appending regardless. Two
signatures dominate:

    fusion    two real words run together        throughjourney, wetnaked
    retype    a typo, then the correction        uoryour  (uor -> your)

Both are recoverable, and this module recovers them rather than discarding the
tokens: see recover(). Fixing typelog to break the segment on a caret move would
stop them being created, but the 21 days already on disk would still need this.

-------------------------------------------------------------------------------
WHY IT TAKES BOTH A DICTIONARY AND THE CORPUS
-------------------------------------------------------------------------------
Neither signal is sufficient on its own, and each covers the other's blind spot:

  * Corpus statistics alone cannot tell a rare real word from a habitual typo.
    Frequency-and-spread filtering kept `bmy`, `thast`, `reveral` (typed often
    enough to look deliberate) while dropping `imagination`, `engulfed` and
    `bestow` (real, but rare here). It also tore `present` into `pre`+`sent`.

  * A dictionary alone rejects the vocabulary this job is made of — `onlyfans`,
    `cucky`, `papi`, `pussylips`, model names — plus every apostrophe-less
    contraction (`dont`, `isnt`) and every deliberate elongation (`yesss`).

So: the dictionary decides English, and corpus evidence admits domain words on
top of it. The dictionary is the one built into Windows (ISpellChecker, Win8+),
reached through ctypes — no bundled wordlist, and no new dependency in
requirements.txt. If it cannot be reached the module says so and runs
stats-only, which is materially worse but still better than raw.

-------------------------------------------------------------------------------
    python clean.py              report what it keeps and drops, write nothing
    python clean.py --verbose    also list the domain words and sample rejects
"""

from __future__ import annotations

import argparse
import collections
import configparser
import ctypes
import glob
import re
import sys
from ctypes import HRESULT, POINTER, byref, c_void_p, c_wchar_p, wintypes
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[2]
USERDATA = MMA_ROOT / "userdata"

# typelog wrote to its own project folder before it moved into MMA (see its
# README). Those 21 days are the bulk of the corpus, so both paths are read and
# nothing has to be migrated by hand.
LOG_DIRS = [
    USERDATA / "typelog",
    Path(r"D:\Software\Dev\Chatting\typelog\logs"),
]

# Hand corrections, in a file, editable — the same rule as every other MMA knob.
# [keep] admits a word the cleaner rejected; [drop] removes one it let through.
OVERRIDES = USERDATA / "autoword" / "overrides.ini"


# ══════════════════════════════════════════════════════════════════════════════
#  The Windows spell checker, through ctypes
# ══════════════════════════════════════════════════════════════════════════════
# ISpellChecker is a plain vtable interface, not IDispatch, so it is called by
# slot index rather than by name. Slots used:
#     ISpellCheckerFactory   5 = CreateSpellChecker
#     ISpellChecker          4 = Check          -> IEnumSpellingError
#     IEnumSpellingError     3 = Next           S_OK means it produced an error
#     IUnknown               2 = Release
# An empty error enumeration means the word is spelled correctly.

_CLSID_FACTORY = "{7AB36653-1796-484B-BDFA-E74F1DB7C1DC}"
_IID_FACTORY   = "{8E018A9D-2415-4677-BF08-794EA61F94BB}"


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


# A word is English if ANY of these accepts it. The corpus is written in British
# English — `behaviour`, `realise`, `centre`, `favourite` — and an en-US-only
# checker calls every one of those a misspelling, which would drop real
# vocabulary from the index AND feed the typo layer a list of "corrections" that
# quietly Americanise the writing.
#
# en-CA, not en-GB, and this is a trap worth knowing about: en-GB is NOT
# installed on this machine, but BOTH ISpellCheckerFactory::IsSupported("en-GB")
# and CreateSpellChecker("en-GB") report success anyway and hand back a checker
# that is really en-US. There is no error to catch — the only way to see it is to
# ask get_SupportedLanguages, which lists en-CA/en-LR/en-PH/en-US and no en-GB.
# en-CA is genuinely present and takes British spellings (8/8 above; en-US: 1/8).
LANGUAGES = ("en-CA", "en-US")


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


# ══════════════════════════════════════════════════════════════════════════════
#  Corpus
# ══════════════════════════════════════════════════════════════════════════════
def read_days(dirs=LOG_DIRS) -> list[list[str]]:
    """One token list per daily log. Kept per-day because "appears across
    several days" is one of the signals that a token is deliberate."""
    days = []
    for d in dirs:
        for path in sorted(glob.glob(str(Path(d) / "*.log"))):
            text = Path(path).read_text(encoding="utf-8", errors="replace").lower()
            toks = [t.strip("'") for t in re.findall(r"[a-z']+", text)]
            toks = [t for t in toks if t]
            if toks:
                days.append(toks)
    return days


class Corpus:
    def __init__(self, days: list[list[str]]):
        self.days = days
        self.words = [w for d in days for w in d]
        self.count = collections.Counter(self.words)
        self.docfreq = collections.Counter()
        for d in days:
            for w in set(d):
                self.docfreq[w] += 1
        self.prev = collections.defaultdict(set)
        self.next = collections.defaultdict(set)
        for d in days:
            for a, b in zip(d, d[1:]):
                self.next[a].add(b)
                self.prev[b].add(a)

    def contexts(self, w: str) -> int:
        return len(self.prev[w]) + len(self.next[w])


# ══════════════════════════════════════════════════════════════════════════════
#  The cleaner
# ══════════════════════════════════════════════════════════════════════════════
VOWELS = set("aeiouy")
# Letters people genuinely stretch for emphasis in this register ("yesss",
# "ughhh", "riiight"). A run of anything else repeated is a stuck key.
STRETCHY = set("aeiouymhzsl")

# Thresholds for admitting a NON-dictionary word as domain vocabulary. High on
# purpose: a habitual typo also recurs, it just does not recur this hard.
DOMAIN_MIN_COUNT = 8
DOMAIN_MIN_DAYS  = 3
DOMAIN_MIN_CTX   = 6
# A word this common is a landmark: anything one edit away from it is a typo of
# it rather than a new word.
COMMON_MIN_COUNT = 40


class Cleaner:
    """Classifies every token in the corpus as one of:

        dict        in the Windows dictionary                      -> kept
        domain      not English, but unmistakably deliberate       -> kept
        structural  cannot be a word at all (no vowel, stuck key)  -> dropped
        fused       two real words run together, or a retype       -> dropped,
                    but the real word(s) inside are recovered
        reject      everything else                                -> dropped
    """

    def __init__(self, corpus: Corpus, spell: SpellChecker | None = None):
        self.c = corpus
        self.spell = spell if spell is not None else SpellChecker()
        self.keep_override, self.drop_override = _read_overrides()

        # Pass 1 — the dictionary words. This is the vocabulary that pass 2 uses
        # to recognise a fusion, so it must be built before anything else and
        # must contain only words we are certain of.
        self._dict_words = {w for w in self.c.count
                            if self._structural_ok(w) and self.spell.in_dict(w)}
        self._common = {w for w in self._dict_words
                        if self.c.count[w] >= COMMON_MIN_COUNT}

        # Pass 2 — classify everything.
        self.kind: dict[str, str] = {}
        self.recovered: dict[str, list[str]] = {}
        for w in self.c.count:
            k, rec = self._classify(w)
            self.kind[w] = k
            if rec:
                self.recovered[w] = rec

        self.kept = {w for w, k in self.kind.items() if k in ("dict", "domain")}

    # ── the layers, in the order they are applied ─────────────────────────────
    def _classify(self, w: str) -> tuple[str, list[str]]:
        if w in self.drop_override:
            return "reject", []
        if w in self.keep_override:
            return "domain", []
        if not self._structural_ok(w):
            return "structural", self._recover(w)
        if w in self._dict_words:
            return "dict", []
        # Fusion is tested BEFORE domain: `andand`, `toyou` and `openopen` all
        # clear the domain thresholds comfortably, and would be admitted as
        # vocabulary if this ran the other way round.
        rec = self._recover(w)
        if rec:
            return "fused", rec
        if self._near_common(w):
            return "reject", []
        if self._domain_ok(w):
            return "domain", []
        return "reject", []

    def _structural_ok(self, w: str) -> bool:
        if len(w) < 2:
            return w in ("a", "i")
        if len(w) > 20:
            return False
        if not (set(w) & VOWELS):
            return False
        for m in re.finditer(r"(.)\1{2,}", w):
            if m.group(1) not in STRETCHY:
                return False
        if re.search(r"[bcdfghjklmnpqrstvwxz]{5,}", w):
            return False
        return w.count("'") <= 1

    def _near_common(self, w: str) -> bool:
        """One edit away from a much commoner dictionary word, so it is that
        word mistyped. This is what separates `woul`/`yuou`/`thhat` from
        `cucky`/`chrissy` — the latter are near nothing."""
        if w in self._common:
            return False
        letters = "abcdefghijklmnopqrstuvwxyz"
        for i in range(len(w)):
            if w[:i] + w[i + 1:] in self._common:
                return True
        for i in range(len(w) - 1):
            if w[:i] + w[i + 1] + w[i] + w[i + 2:] in self._common:
                return True
        for i in range(len(w)):
            for ch in letters:
                if ch != w[i] and w[:i] + ch + w[i + 1:] in self._common:
                    return True
        for i in range(len(w) + 1):
            for ch in letters:
                if w[:i] + ch + w[i:] in self._common:
                    return True
        return False

    def _domain_ok(self, w: str) -> bool:
        return (len(w) >= 3
                and self.c.count[w] >= DOMAIN_MIN_COUNT
                and self.c.docfreq[w] >= DOMAIN_MIN_DAYS
                and self.c.contexts(w) >= DOMAIN_MIN_CTX)

    # How much rarer a fused token must be than its parts before we believe the
    # split. This is what protects real lexical items: `onlyfans` recurs at a
    # rate comparable to `only` and `fans`, so it is vocabulary; `toyou` is
    # hundreds of times rarer than `to` and `you`, so it is an accident.
    FUSION_RATIO = 20

    def _solid(self, part: str) -> bool:
        """A split is only believable if THIS corpus uses the part as a word in
        its own right. The dictionary alone accepts `toto`, `chi` and `din`, and
        will happily shred a token into them."""
        return (len(part) >= 4 and part in self._dict_words
                and self.c.count[part] >= 5)

    def _part_ok(self, part: str) -> bool:
        """Solid, or short but so common that its identity is not in doubt —
        `to`, `you`, `and`. Needed for the short fusions (`toyou`, `andand`)
        that a 4-character floor cannot see."""
        return self._solid(part) or (len(part) >= 2 and part in self._common)

    def _believable_split(self, w: str, parts: list[str]) -> bool:
        rarest_part = min(self.c.count[p] for p in parts)
        return (self.c.count[w] <= 5
                or rarest_part >= self.c.count[w] * self.FUSION_RATIO)

    def _recover(self, w: str) -> list[str]:
        """Pull the real word(s) out of a desync artifact. Three shapes, in
        descending order of confidence: one word typed twice, a fusion of two
        words, then a junk head followed by a retyped word."""
        # `youyou`, `andand`, `funnyfunny` — one word, keystrokes doubled.
        half = len(w) // 2
        if len(w) % 2 == 0 and w[:half] == w[half:] and self._part_ok(w[:half]):
            return [w[:half]]
        for i in range(2, len(w) - 1):
            head, tail = w[:i], w[i:]
            if (self._part_ok(head) and self._part_ok(tail)
                    and self._believable_split(w, [head, tail])):
                return [head, tail]
        for i in range(1, len(w) - 2):
            tail = w[i:]
            if (self._part_ok(tail) and self.c.count[tail] >= 15
                    and self._believable_split(w, [tail])):
                return [tail]
        return []

    # ── output ────────────────────────────────────────────────────────────────
    def clean_days(self) -> list[list[str]]:
        """The corpus with junk removed and artifacts repaired, still split by
        day. This is what the index builder counts."""
        out = []
        for day in self.days_source():
            row = []
            for w in day:
                if w in self.kept:
                    row.append(w)
                else:
                    row.extend(self.recovered.get(w, ()))
            out.append(row)
        return out

    def days_source(self):
        return self.c.days

    def report(self) -> dict:
        total = len(self.c.words)
        by_kind = collections.Counter(self.kind.values())
        tokens = collections.Counter()
        for w, k in self.kind.items():
            tokens[k] += self.c.count[w]
        return {
            "vocabulary": len(self.c.count),
            "tokens": total,
            "by_kind": by_kind,
            "token_share": {k: tokens[k] / total for k in by_kind},
            "kept_vocab": len(self.kept),
            "kept_share": sum(self.c.count[w] for w in self.kept) / total,
            "recovered": len(self.recovered),
        }


def _read_overrides(path: Path = OVERRIDES) -> tuple[set[str], set[str]]:
    """[keep] / [drop] one word per line, values ignored. Absent file = no
    overrides; a malformed one must never take the build down."""
    if not path.exists():
        return set(), set()
    cp = configparser.ConfigParser(strict=False, allow_no_value=True)
    try:
        cp.read_string(path.read_text(encoding="utf-8-sig", errors="replace"))
    except configparser.Error as exc:
        print(f"  ! overrides.ini ignored — {exc}")
        return set(), set()
    keep = {k.strip().lower() for k in cp["keep"]} if cp.has_section("keep") else set()
    drop = {k.strip().lower() for k in cp["drop"]} if cp.has_section("drop") else set()
    return keep, drop


# ══════════════════════════════════════════════════════════════════════════════
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA autoword cleanup layer")
    ap.add_argument("--verbose", action="store_true",
                    help="list the domain words and a sample of rejects")
    args = ap.parse_args(argv)

    days = read_days()
    if not days:
        print("no typelog files found in:")
        for d in LOG_DIRS:
            print(f"   {d}")
        return 1

    corpus = Corpus(days)
    spell = SpellChecker()
    if not spell.available:
        print("! the Windows spell checker could not be reached — running on")
        print("  corpus statistics alone, which keeps noticeably more junk.")
    cleaner = Cleaner(corpus, spell)
    r = cleaner.report()

    print(f"{len(days)} daily logs   {r['tokens']:,} tokens   "
          f"{r['vocabulary']:,} distinct")
    print()
    for kind in ("dict", "domain", "fused", "structural", "reject"):
        n = r["by_kind"].get(kind, 0)
        share = r["token_share"].get(kind, 0.0)
        print(f"  {kind:11} {n:6,} words   {share:6.1%} of tokens")
    print()
    print(f"  kept         {r['kept_vocab']:6,} words   {r['kept_share']:6.1%} of tokens")
    print(f"  recovered    {r['recovered']:6,} artifacts repaired into real words")

    if args.verbose:
        import random
        random.seed(7)
        dom = sorted(w for w, k in cleaner.kind.items() if k == "domain")
        rej = sorted(w for w, k in cleaner.kind.items() if k == "reject")
        print(f"\ndomain vocabulary kept ({len(dom)}):")
        print("   " + "  ".join(dom))
        print("\nrejected, sample:")
        print("   " + "  ".join(sorted(random.sample(rej, min(25, len(rej))))))
        print("\nrecoveries, sample:")
        for w in sorted(random.sample(sorted(cleaner.recovered),
                                      min(12, len(cleaner.recovered)))):
            print(f"   {w:26} -> {' + '.join(cleaner.recovered[w])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
