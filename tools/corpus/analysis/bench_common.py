"""Shared setup for the next-word benchmark (pass 6).

Split by day, so nothing about the test days leaks into training: test = every
clean message from 2026-10-01 on, train = every clean message before. Dirty
lines (still junk after the rules) are left out of both.

A test POSITION is (message, word index). At each position the user has typed
`p` characters of the word (p = 0, 1, 2) and the model offers its top 3.
"""
from __future__ import annotations

import collections
import random
import re

from rcommon import load_repaired

SPLIT = "2026-10-01"
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")


def split():
    msgs = [m for m in load_repaired() if not m.dirty and WORD.search(m.text)]
    train = [m for m in msgs if m.day < SPLIT]
    test = [m for m in msgs if m.day >= SPLIT]
    return train, test


def words_surface(text: str) -> list[str]:
    return WORD.findall(text)


def positions(test, n=3000, seed=0):
    """A fixed random sample of (msg_index, word_index) over the test set."""
    allpos = [(i, j) for i, m in enumerate(test) for j in range(len(words_surface(m.text)))]
    random.Random(seed).shuffle(allpos)
    return allpos[:n], len(allpos)


def surface_forms(train):
    """lowercase word -> its most common written form ('i' -> 'I', 'alice' -> 'Alice')."""
    c = collections.defaultdict(collections.Counter)
    for m in train:
        for w in words_surface(m.text):
            c[w.lower()][w] += 1
    return {k: v.most_common(1)[0][0] for k, v in c.items()}


def keystrokes(word: str, ranked_by_prefix) -> tuple[int, int]:
    """(cost, plain_cost) for one word. plain = typing it + a space. With
    suggestions: type p chars until the word shows in the top 3 at rank r, then r
    presses to take it (the space comes with it)."""
    plain = len(word) + 1
    for p in range(0, len(word)):
        ranked = ranked_by_prefix(word[:p])
        if word in ranked[:3]:
            return min(plain, p + ranked.index(word) + 1), plain
    return plain, plain
