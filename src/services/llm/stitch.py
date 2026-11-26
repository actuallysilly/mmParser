"""
llm/stitch.py — line a screenful of OCR'd messages up with a saved chat.

The ONE copy (2026-11-24). It used to live three times over: Live Trainer's strict
merge, shiftlog's looser one built on top of it, and the fan store borrowing
shiftlog's. Everything that stitches imports from here: fanstore (the fan
recorder and __lore), shiftlog (until it retires) and Live Trainer.

    merge_exact(hist, read)  every overlapping message must agree (Live Trainer's)
    merge(hist, read)        exact first, else a diff-style fit that accepts a read
                             when most of the overlap agrees (shiftlog's: a strict
                             fit refused 45% of reads on a real shift)
    is_newer(hist, read, fresh)  does a read that fits nowhere go BELOW the chat?

Each returns (history, appended, problem); problem "" = placed. A read that
fits nowhere is never guessed into the chat.
"""
from __future__ import annotations

import difflib
import re
import time

SIMILAR = 0.8            # difflib ratio for "the same message, read twice"
MIN_ANCHORS = 2          # text messages that must match...
MIN_AGREE = 0.6          # ...and this share of the read's span between them
LOOSE_EDGE = 2           # media-only turns at the chat's edge that a read may replace

# Read-only layout facts, not part of the conversation.
DROP = ("partial", "box", "repaired", "cut")
# Footer facts that change after the fact: he pays for the PPV, he likes it.
LATEST = ("paid", "ppv_border", "liked", "footer")


def slug(s: str) -> str:
    return re.sub(r"[^\w.-]+", "_", s.strip()).strip("_")[:60] or "_"


def _norm(t: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def same(a: dict, b: dict) -> bool:
    """Is read turn `b` the stored turn `a`? OCR is not exact twice running."""
    if a["who"] != b["who"]:
        return False
    na, nb = _norm(a["text"]), _norm(b["text"])
    if not na or not nb:
        return not na and not nb                 # media matches media
    if na == nb:
        return True
    # A message cut off by the composer is a prefix of itself read whole.
    if min(len(na), len(nb)) >= 8 and (na.startswith(nb) or nb.startswith(na)):
        return True
    return difflib.SequenceMatcher(None, na, nb).ratio() >= SIMILAR


def combine(old: dict, new: dict) -> dict:
    """One message read twice: keep the longer text, fill in what was missing."""
    d = dict(old)
    if len(new["text"]) > len(old["text"]):
        d["text"] = new["text"]
    for k, v in new.items():
        if k not in ("who", "text") and (k in LATEST or d.get(k) in (None, "")):
            d[k] = v
    return d


def clean(read: list[dict]) -> list[dict]:
    """Drop layout facts and top-clipped (half) messages."""
    return [{**{k: v for k, v in t.items() if k not in DROP}, "text": t.get("text", "")}
            for t in read if not t.get("partial")]


def merge_exact(hist: list[dict], read: list[dict]) -> tuple[list[dict], list[dict], str]:
    """Placed at the offset where ALL overlapping turns match and the most carry
    text; ties go to the LATEST offset (a repeated "ok" should be the new one)."""
    read = clean(read)
    if not read:
        return hist, [], ""
    if not hist:
        return list(read), [], ""                # first sight: history, not news
    best = None
    for o in range(-len(read) + 1, len(hist) + 1):
        matched = bad = 0
        for i, r in enumerate(read):
            j = o + i
            if 0 <= j < len(hist):
                if same(hist[j], r):
                    matched += bool(r["text"])
                else:
                    bad += 1
        if matched and not bad and (best is None or matched >= best[1]):
            best = (o, matched)
    if best is None:
        return hist, [], "this screen does not line up with the saved chat (scrolled far up?) — not saved"
    o = best[0]
    out = list(hist)
    for i, r in enumerate(read):                 # cut -> whole: keep the longer read
        j = o + i
        if 0 <= j < len(out):
            out[j] = combine(out[j], r)
    older = read[:max(0, -o)]
    newer = read[len(hist) - o:] if len(hist) - o < len(read) else []
    stamp = time.time()
    newer = [dict(t, at=stamp) for t in newer]
    return older + out + newer, newer, ""


def _lcs(hist: list[dict], read: list[dict]) -> list[tuple[int, int]]:
    """Matched (hist index, read index) pairs, in order."""
    n, m = len(hist), len(read)
    eq = [[same(hist[i], read[j]) for j in range(m)] for i in range(n)]
    L = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            # Text matches are anchors; a media match is worth a little, so two
            # [media] turns never outvote a real message.
            w = (2 if read[j]["text"] else 1) if eq[i][j] else 0
            L[i][j] = max(L[i + 1][j], L[i][j + 1], (L[i + 1][j + 1] + w) if w else 0)
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        w = (2 if read[j]["text"] else 1) if eq[i][j] else 0
        if w and L[i][j] == L[i + 1][j + 1] + w:
            pairs.append((i, j))
            i, j = i + 1, j + 1
        elif L[i + 1][j] >= L[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def merge(hist: list[dict], read: list[dict]) -> tuple[list[dict], list[dict], str]:
    """Exact first (it also takes a one-message overlap, all a quick scroll leaves);
    only when that fails, a diff-style fit that most of the overlap agrees with."""
    read = clean(read)
    if not read:
        return hist, [], ""
    if not hist:
        return list(read), [], ""
    exact = merge_exact(hist, read)
    if not exact[2]:
        return exact
    pairs = _lcs(hist, read)
    anchors = [(i, j) for i, j in pairs if read[j]["text"]]
    texts = sum(1 for t in read if t["text"])
    need = min(MIN_ANCHORS, texts)
    if not anchors or len(anchors) < need:
        return hist, [], "does not line up with the saved chat"
    (i0, j0), (i1, j1) = pairs[0], pairs[-1]
    span = sum(1 for t in read[j0:j1 + 1] if t["text"])
    if len(anchors) < MIN_AGREE * span:
        return hist, [], "lines up only partly with the saved chat"

    out = [dict(t) for t in hist]
    for i, j in pairs:
        out[i] = combine(out[i], read[j])
    # A message one read caught and the history missed: when the read has turns
    # between two matches that sit next to each other in the history, insert them.
    inserts = []
    for (ia, ja), (ib, jb) in zip(pairs, pairs[1:]):
        if ib == ia + 1 and jb > ja + 1:
            inserts.append((ib, read[ja + 1:jb]))
    for at, turns in reversed(inserts):
        out[at:at] = turns
        shift = len(turns)
        i1 += shift if at <= i1 else 0
        i0 += shift if at <= i0 else 0
    # Older turns above the first match: only when the match is at the top of
    # the history (or only media sits above it).
    older = read[:j0] if all(not t["text"] for t in out[:i0]) and i0 <= LOOSE_EDGE else []
    if older:
        out = out[i0:]
        i1 -= i0
    # Newer turns below the last match: only when it is the bottom of the
    # history (or only media sits below it).
    newer = []
    tail = out[i1 + 1:]
    if j1 + 1 < len(read) and len(tail) <= LOOSE_EDGE and all(not t["text"] for t in tail):
        stamp = time.time()
        newer = [dict(t, at=stamp) for t in read[j1 + 1:]]
        out = out[:i1 + 1]
    return older + out + newer, newer, ""


# ── reads that are NEWER than the saved chat ────────────────────────────────
# Infloww opens a chat at the bottom. Come back to a fan after more than a
# screen of new messages and nothing on screen overlaps what was saved. Live
# 2026-10-22 such reads froze every chat at its first gap, so a read that fits
# nowhere goes BELOW the chat (first message marked gap_before) when it is newer.
_TIME = re.compile(r"^(\d{1,2}):(\d{2})\s*([ap]m)$", re.I)


def _mins(t: dict) -> int | None:
    m = _TIME.match((t.get("time") or "").strip())
    day = (t.get("day") or "").strip().lower()   # from a day separator (fan recorder)
    if not m or t.get("date") or (day and day != "today"):
        return None                              # a dated message is not today's
    h = int(m.group(1)) % 12 + (12 if m.group(3).lower() == "pm" else 0)
    return h * 60 + int(m.group(2))


def is_newer(hist: list[dict], read: list[dict], fresh: bool) -> bool:
    """Footer times decide when both sides have one; otherwise only a read taken
    as the chat was opened (which is the bottom) counts as newer."""
    if any(t.get("date") for t in read):
        return False                             # dates only show on older days
    h = next((m for m in map(_mins, reversed(hist)) if m is not None), None)
    r = next((m for m in map(_mins, read) if m is not None), None)
    if h is not None and r is not None:
        return (r - h) % 1440 < 720              # midnight-safe
    return fresh
