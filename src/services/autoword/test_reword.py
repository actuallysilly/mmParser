"""
autoword — reword group tests.

No file, no dictionary, no service: groups go in as lines and alternatives come
out, so the spelling rules and the symmetry are testable on their own.

    python test_reword.py

Like test_engine.py, this writes nothing to userdata\\.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from reword import Thesaurus, match_case, spellings   # noqa: E402

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append(f"{name}: got {got!r}, want {want!r}")
    else:
        print(f"  ok   {name}")


LINES = [
    "; a comment",
    "",
    "touch, caress, stroke, graze",
    "cuddle, snuggle, curl up",
    "felt, sensed, noticed",
    "lonely",                      # a group of one is not a group
]

# Stands in for the Windows dictionary: everything the rules could produce from
# the groups above, spelled correctly, and nothing else.
REAL = {
    "touches", "touched", "touching", "caresses", "caressed", "caressing",
    "strokes", "stroked", "stroking", "grazes", "grazed", "grazing",
    "cuddles", "cuddled", "cuddling", "snuggles", "snuggled", "snuggling",
    "sensed", "senses", "sensing", "noticed", "notices", "noticing",
    "felts",
}


def loaded(in_dict=None):
    return Thesaurus.from_lines(LINES, in_dict)


# ── the groups ────────────────────────────────────────────────────────────────
def test_a_group_offers_the_rest_of_its_line():
    check("in file order", loaded().alternatives("touch"),
          ["caress", "stroke", "graze"])


def test_groups_are_symmetric():
    check("from the far end", loaded().alternatives("graze"),
          ["touch", "caress", "stroke"])


def test_a_word_of_its_own_is_not_a_group():
    check("nothing to offer", loaded().alternatives("lonely"), [])


def test_an_unknown_word_is_not_an_error():
    check("nothing to offer", loaded().alternatives("photosynthesis"), [])


def test_list_size_is_honoured():
    check("two of three", loaded().alternatives("touch", 2), ["caress", "stroke"])


def test_comments_and_blanks_are_skipped():
    check("groups read", loaded().groups, 3)


# ── inflection ────────────────────────────────────────────────────────────────
def test_inflections_are_generated():
    t = loaded(REAL.__contains__)
    check("past", t.alternatives("touched"), ["caressed", "stroked", "grazed"])
    check("present", t.alternatives("touching"),
          ["caressing", "stroking", "grazing"])
    check("plural", t.alternatives("touches"), ["caresses", "strokes", "grazes"])


def test_a_phrase_is_offered_but_never_inflected():
    t = loaded(REAL.__contains__)
    check("as written", t.alternatives("cuddle"), ["snuggle", "curl up"])
    check("and left out of the inflected group", t.alternatives("cuddled"),
          ["snuggled"])


def test_the_file_wins_over_the_rules():
    """`felt` is in the file because no rule would produce it. The generated
    `felts` group must not overwrite the line that was written by hand."""
    t = loaded(REAL.__contains__)
    check("the hand-written line", t.alternatives("felt"), ["sensed", "noticed"])


def test_a_word_the_dictionary_rejects_is_dropped():
    t = loaded(lambda w: w in REAL and w != "grazed")
    check("without the bad form", t.alternatives("touched"),
          ["caressed", "stroked"])


def test_without_a_dictionary_the_first_guess_is_taken():
    check("unchecked", loaded().alternatives("touched"),
          ["caressed", "stroked", "grazed"])


# ── spelling rules ────────────────────────────────────────────────────────────
def test_plural_rules():
    check("sibilant", spellings("kiss", "s"), ["kisses"])
    check("consonant + y", spellings("carry", "s"), ["carries"])
    check("vowel + y", spellings("play", "s"), ["plays"])
    check("plain", spellings("touch", "s"), ["touches"])


def test_final_e_is_dropped():
    check("past", spellings("stroke", "ed"), ["stroked"])
    check("present", spellings("stroke", "ing"), ["stroking"])
    check("but not from ee", spellings("see", "ing"), ["seeing"])


def test_doubling_is_offered_both_ways():
    """Whether a final consonant doubles depends on stress, which spelling does
    not record. Short words lead with the doubled form and long ones with the
    plain one, and the dictionary settles it."""
    check("short word", spellings("rub", "ed"), ["rubbed", "rubed"])
    check("long word", spellings("whisper", "ed"), ["whispered", "whisperred"])
    check("w never doubles", spellings("draw", "ing"), ["drawing"])


def test_case_comes_from_what_you_typed():
    check("lower", match_case("touched", "caressed"), "caressed")
    check("capitalised", match_case("Touched", "caressed"), "Caressed")
    check("shouted", match_case("TOUCHED", "caressed"), "CARESSED")
    check("a single capital is a capital", match_case("I", "me"), "Me")


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
