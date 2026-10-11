"""Rule-based repair of the merged corpus. Scored against gold.py by score_repair.py.

Rules, in order — each is the fingerprint of one recorder bug:
  echo      overlapping windows of the same text repeated inside a line
            ("who canneed a man who can last") -> rebuild the superstring
  restart   a capital glued to a lowercase letter ("haveSo we") -> the draft before
            it was deleted; the message starts at the capital
  fusion    an unknown lowercase token ending in a common word ("hagwant") -> the
            junk prefix is a deleted attempt; keep the word
  nonmsg    price entries and vault searches are not messages -> drop
"""
from __future__ import annotations

import collections
import json
import re

from common import OUT, load, words

MIN_ECHO = 10                  # an echo must repeat at least this many characters
MAX_FUSION_PREFIX = 5          # junk before a fused word is a short abandoned attempt
FREQ_WORD = 20                 # "a common word" for fusion: seen this often...
SELF_KEEP = 3                  # ...and a token seen this often is left alone

_known = json.loads((OUT / "known_words.json").read_text())


def known(w: str) -> bool:
    return _known.get(w.lower(), False)


_counts: collections.Counter | None = None


def counts() -> collections.Counter:
    global _counts
    if _counts is None:
        _counts = collections.Counter(w.lower() for ln in load() for w in words(ln.text))
    return _counts


# -- echo ---------------------------------------------------------------------
def de_echo(text: str) -> str:
    """Rebuild a line that repeats windows of itself. At each position, if what
    follows re-types a stretch that ends exactly at the current end of the
    output, it is an echo: skip it. A repeated phrase that does not end at the
    current end is ordinary repetition and is kept."""
    out = ""
    i = 0
    n = len(text)
    while i < n:
        skipped = False
        if len(out) >= MIN_ECHO:
            # longest L such that text[i:i+L] == out[-L':...] for some start j where
            # out[j:] is a prefix of text[i:]
            best = 0
            for j in range(0, len(out) - MIN_ECHO + 1):
                tail = out[j:]
                if text.startswith(tail, i):
                    best = len(tail)
                    break                       # earliest j = longest tail
            if best >= MIN_ECHO:
                i += best
                skipped = True
        if not skipped:
            out += text[i]
            i += 1
    return out


# -- restart ------------------------------------------------------------------
_RESTART = re.compile(r"(?<=[a-z'.!?,])(?=[A-Z][a-z']|[A-Z]\b|I')")
_I_WORD = re.compile(r"I(?:'[a-z]+)?\b")


def de_restart(text: str, mode: str = "smart") -> str:
    """Cut at the LAST glued capital. 'full' drops everything before it; 'frag'
    drops only the glued fragment; 'smart' uses frag for I/I'm (always capital,
    so a glued I is just a deleted word) and full for anything else."""
    last = None
    for m in _RESTART.finditer(text):
        last = m.start()
    if last is None:
        return text
    full = mode == "full" or (mode == "smart" and not _I_WORD.match(text, last))
    if full:
        return text[last:]
    k = last
    while k > 0 and not text[k - 1].isspace():
        k -= 1
    return text[:k] + text[last:]


def de_capstutter(text: str) -> str:
    """'WYou', 'SOlo' at a word start: a held-Shift double. Keep the second form."""
    return re.sub(r"\b([A-Z])([A-Z][a-z]{2,})", lambda m: m[2], text)


# -- fusion -------------------------------------------------------------------
def de_fuse_token(tok: str) -> str:
    c = counts()
    low = tok.lower()
    if not tok.islower() or known(low) or c[low] >= SELF_KEEP:
        return tok
    for k in range(1, min(MAX_FUSION_PREFIX, len(tok) - 3) + 1):
        suf = low[k:]
        if c[suf] >= FREQ_WORD and known(suf):
            return tok[k:]
    return tok


def de_fuse(text: str) -> str:
    return re.sub(r"[A-Za-z]+", lambda m: de_fuse_token(m[0]), text)


# -- retype and stutter -------------------------------------------------------
def _edits(a: str, b: str) -> int:
    """Levenshtein distance, small strings only."""
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _bad(tok: str) -> bool:
    return not known(tok) and counts()[tok.lower()] < SELF_KEEP


def de_retype(text: str) -> str:
    """'woth with', 'Mybe Maybe', 'Spirce Source': an unknown word followed by a
    known word within two edits of it is a typo that was abandoned and retyped."""
    toks = text.split(" ")
    out = []
    for i, t in enumerate(toks):
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        a, b = re.sub(r"\W", "", t), re.sub(r"\W", "", nxt)
        if a and b and _bad(a) and not _bad(b) and _edits(a.lower(), b.lower()) <= 2:
            continue
        out.append(t)
    return " ".join(out)


def de_stutter_token(tok: str) -> str:
    """'showowed' -> 'showed', 'keekeep' -> 'keep': an unknown token that becomes
    a known one by removing one doubled chunk."""
    if not _bad(tok):
        return tok
    for size in (2, 3, 4):
        for i in range(len(tok) - 2 * size + 1):
            chunk = tok[i:i + size].lower()
            if len(set(chunk)) == 1:
                continue                    # 'uwaaaaa', 'mmmm': elongation is voice, not junk
            if chunk == tok[i + size:i + 2 * size].lower():
                cand = tok[:i] + tok[i + size:]
                if not _bad(cand):
                    return cand
    return tok


def de_stutter(text: str) -> str:
    return re.sub(r"[A-Za-z]+", lambda m: de_stutter_token(m[0]), text)


# -- style: elongation is not information ---------------------------------------
def canon(text: str) -> str:
    """The user's rule: how many a's are in 'uwaaaaa' is irrelevant. Any run of
    3+ of one letter becomes 2 (Mmmm -> Mm, Heyyy -> Heyy), !!!/??? become two,
    and 4+ dots become an ellipsis. Hey and Heyy stay different: elongated or
    not is tone, the length is not."""
    text = re.sub(r"([A-Za-z])\1{2,}", r"\1\1", text)
    text = re.sub(r"([!?])\1{2,}", r"\1\1", text)
    return re.sub(r"\.{4,}", "...", text)


# -- spelling: the user's rule is that misspellings and writing errors get fixed -
CONTRACTIONS = {
    "im": "I'm", "ive": "I've", "ill": "I'll", "i": "I", "dont": "don't", "cant": "can't",
    "wont": "won't", "didnt": "didn't", "doesnt": "doesn't", "isnt": "isn't",
    "wasnt": "wasn't", "werent": "weren't", "arent": "aren't", "havent": "haven't",
    "hasnt": "hasn't", "hadnt": "hadn't", "couldnt": "couldn't", "wouldnt": "wouldn't",
    "shouldnt": "shouldn't", "thats": "that's", "whats": "what's", "lets": "let's",
    "theres": "there's", "heres": "here's", "hes": "he's", "shes": "she's",
    "youre": "you're", "youve": "you've", "youll": "you'll", "youd": "you'd",
    "theyre": "they're", "theyve": "they've", "wheres": "where's", "whos": "who's",
    "hows": "how's", "aint": "ain't", "yall": "y'all",
}
MIN_SPELL_LEN = 4          # ur, rn, gm, lol: short tokens are slang, never "corrected"
GOOD_MIN = 2               # a dictionary word must be seen this often to be a target...
DOMAIN_MIN = 30            # ...and a non-dictionary token this often is vocabulary

_spell_index: dict | None = None


def _deletes(w: str, depth: int) -> set[str]:
    out, frontier = set(), {w}
    for _ in range(depth):
        frontier = {f[:i] + f[i + 1:] for f in frontier for i in range(len(f))}
        out |= frontier
    return out


def _index():
    """SymSpell-style: every good word, and every 1-2 character deletion of it."""
    global _spell_index
    if _spell_index is None:
        c = counts()
        good = {w: n for w, n in c.items()
                if (n >= GOOD_MIN and known(w)) or n >= DOMAIN_MIN}
        idx = collections.defaultdict(set)
        for w in good:
            if len(w) >= MIN_SPELL_LEN - 1:
                idx[w].add(w)
                for d in _deletes(w, 2):
                    idx[d].add(w)
        _spell_index = (good, idx)
    return _spell_index


def spell_token(tok: str) -> str:
    low = tok.lower()
    if low in CONTRACTIONS:
        fixed = CONTRACTIONS[low]
        return fixed if not tok[0].isupper() or fixed[0].isupper() else fixed[0].upper() + fixed[1:]
    good, idx = _index()
    if len(low) < MIN_SPELL_LEN or low in good or (tok[0].isupper() and not tok.isupper() and tok != tok.capitalize()):
        return tok
    # A real word is never "corrected", however rare it is here. Weighting by this
    # corpus pulls rare words toward the domain: corny -> horny, implied -> applied,
    # VIOLATING -> VIBRATING.
    if known(low):
        return tok
    # Elongation is tone, not a typo: Nopee, shoo, hemm.
    if re.search(r"(.)\1", low) or re.sub(r"(.)\1+", r"\1", low) in good:
        return tok
    if tok[0].isupper() and tok.lower() != low:      # never touch names
        return tok
    if tok[0].isupper() and counts()[low] == 0:
        return tok
    max_d = 1 if len(low) < 6 else 2
    cands = set()
    for d in {low} | _deletes(low, max_d):
        cands |= idx.get(d, set())
    best = None
    for w in cands:
        dist = _edits(low, w)
        if dist <= max_d:
            key = (dist, -good[w])
            if best is None or key < best[0]:
                best = (key, w)
    if best is None:
        return tok
    w = best[1]
    if tok.isupper():
        return w.upper()
    return w.capitalize() if tok[0].isupper() else w


def spell(text: str) -> str:
    return re.sub(r"[A-Za-z]+(?:'[A-Za-z]+)?", lambda m: spell_token(m[0]), text)


# -- not a message ------------------------------------------------------------
_NUMERIC = re.compile(r"^[\d\s.,/$:+*-]+$")
_VAULT = re.compile(r"\w*_\w+|\bMPPV\b|-MPPV", re.I)
_EMOTE = re.compile(r"^(?:<3+|>\.<|:\(|:\)|;3|:3|\?+|!+|x+d*|<#)$", re.I)


def is_nonmsg(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    if _NUMERIC.match(t):
        return True
    if len(t) == 1 and t.isalpha() and t not in "IiKk":
        return True
    return False


def strip_vault(text: str) -> str:
    """Vault search text glued before a message: keep what follows the last code."""
    ms = list(_VAULT.finditer(text))
    if not ms:
        return text
    return text[ms[-1].end():]


ALL_RULES = ("echo", "restart", "fusion", "nonmsg", "spell")


def repair(text: str, restart_mode: str = "smart", rules=ALL_RULES) -> str:
    t = re.sub(r"[ \t]+", " ", text).strip()
    if "nonmsg" in rules:
        t = strip_vault(t).strip()
    if "echo" in rules:
        t = de_echo(t)
    if "restart" in rules:
        t = de_capstutter(t)
        t = de_restart(t, restart_mode)
    if "fusion" in rules:
        t = de_stutter(t)
        t = de_fuse(t)
        t = de_retype(t)
    t = canon(t)
    if "spell" in rules:
        t = spell(t)
    t = re.sub(r" +", " ", t).strip()
    if "nonmsg" in rules and is_nonmsg(t):
        return ""
    return t
