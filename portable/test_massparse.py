#!/usr/bin/env python3
"""
Tests for massparse.py — the same cases the Lua build was validated against,
ported one for one so the two implementations cannot silently diverge.

    python -m unittest test_massparse -v
    python test_massparse.py
"""

import os
import unittest

from massparse import (Mass, file_to_text, parse, parse_file, strip_prefix,
                       to_text)


class TestExportFormat(unittest.TestCase):
    """Exactly what the Windows 'Export !mma' button emits."""

    EXPORTED = (
        "!mma Are you feeling obedient?\n"
        "\n"
        "I'm in the mood to be quite dominant today\n"
        "Will it take more than 1 min?\n"
        "\n"
        "I've been fantasizing about controlling you\n"
        "Do you mind gripping it tightly?\n"
        "\n"
        "Give me 21 strokes now\n"
        "Tell me how it felt"
    )

    def setUp(self):
        self.r = parse(self.EXPORTED)

    def test_mass(self):
        self.assertEqual(self.r.mass, "Are you feeling obedient?")

    def test_fu1(self):
        self.assertEqual(self.r.fu[1], [
            "I'm in the mood to be quite dominant today",
            "Will it take more than 1 min?",
        ])

    def test_fu2(self):
        self.assertEqual(self.r.fu[2], [
            "I've been fantasizing about controlling you",
            "Do you mind gripping it tightly?",
        ])

    def test_fu3(self):
        self.assertEqual(self.r.fu[3], ["Give me 21 strokes now", "Tell me how it felt"])


class TestPrefixMode(unittest.TestCase):
    """Explicit labels — blank lines become irrelevant."""

    PREFIXED = (
        "!mm Beach or bedroom tonight?\n"
        "f1: I've been going back and forth all day\n"
        "f1.5 One of them involves less clothing\n"
        "f2: So which is it?\n"
        "f3.7 Don't leave me hanging"
    )

    def setUp(self):
        self.r = parse(self.PREFIXED)

    def test_mass(self):
        self.assertEqual(self.r.mass, "Beach or bedroom tonight?")

    def test_fu1_both_parts(self):
        self.assertEqual(self.r.fu[1], [
            "I've been going back and forth all day",
            "One of them involves less clothing",
        ])

    def test_fu2(self):
        self.assertEqual(self.r.fu[2], ["So which is it?"])

    def test_fu3_only_seven_slot(self):
        """f3.7 with no f3 still yields a dense single-part follow-up."""
        self.assertEqual(self.r.fu[3], ["Don't leave me hanging"])


class TestMassMarker(unittest.TestCase):
    def test_no_marker_first_line_becomes_mass(self):
        r = parse("Just a plain opener\n\nfollow up one\n\nfollow up two")
        self.assertEqual(r.mass, "Just a plain opener")
        self.assertEqual(r.fu[1], ["follow up one"])
        self.assertEqual(r.fu[2], ["follow up two"])

    def test_marker_variants(self):
        for form in ("!mma ", "!mm ", "mma ", "mm ", "!mma: ", "MMA "):
            with self.subTest(marker=form):
                self.assertEqual(parse(form + "hello there\n\nfu one").mass, "hello there")

    def test_mmap_is_not_a_marker(self):
        """'mmap' must not be mistaken for the 'mma' marker."""
        r = parse("mmap something\n\nfu one")
        self.assertEqual(r.mass, "mmap something")


class TestAltLines(unittest.TestCase):
    SRC = (
        "!mma opener\n"
        "\n"
        "base part one\n"
        "alt: a different wording\n"
        "alt0: numbered alternative\n"
        "\n"
        "second group"
    )

    def test_alts_dropped(self):
        self.assertEqual(parse(self.SRC).fu[1], ["base part one"])

    def test_alts_do_not_shift_groups(self):
        self.assertEqual(parse(self.SRC).fu[2], ["second group"])


class TestPpv(unittest.TestCase):
    def test_positional_ppv_and_its_followups(self):
        r = parse(
            "!mma opener\n"
            "\n"
            "the first follow up\n"
            "\n"
            "ppv here is the ppv text\n"
            "\n"
            "ppv fu one\n"
            "ppv fu two"
        )
        self.assertEqual(r.ppv.base, "here is the ppv text")
        self.assertEqual(r.ppv.fus, ["ppv fu one", "ppv fu two"])
        self.assertEqual(r.fu[1], ["the first follow up"])

    def test_prefix_mode_last_ppv_line_wins(self):
        """Deliberately bug-compatible with mass_gui.ahk's hasFPrefix branch,
        which has no ppv-follow-up handling and lets each ppv line overwrite."""
        r = parse("!mma opener\nf1: hello\nppv first ppv line\nppv second ppv line")
        self.assertEqual(r.ppv.base, "second ppv line")
        self.assertEqual(r.fu[1], ["hello"])


class TestStripPrefix(unittest.TestCase):
    CASES = [
        ("f1: hello",           "hello"),
        ("fu2.5 hello",         "hello"),
        ("https://example.com", "https://example.com"),
        ("well:( that's sad",   "well:( that's sad"),
        ("note: remember this", "remember this"),
        ("no label at all",     "no label at all"),
    ]

    def test_cases(self):
        for src, want in self.CASES:
            with self.subTest(src=src):
                self.assertEqual(strip_prefix(src), want)


class TestWhitespace(unittest.TestCase):
    def test_crlf_and_blank_runs(self):
        r = parse("!mma  spaced out  \r\n\r\n  part one  \r\n\r\n\r\n  part two  \r\n")
        self.assertEqual(r.mass, "spaced out")
        self.assertEqual(r.fu[1], ["part one"])
        self.assertEqual(r.fu[2], ["part two"], "a run of blanks must not make an empty group")


class TestRobustness(unittest.TestCase):
    def test_more_than_three_groups(self):
        r = parse("!mma m\n\na\n\nb\n\nc\n\nd\n\ne")
        self.assertEqual(r.fu[3], ["c"], "extra groups are ignored, not crashed on")

    def test_empty_inputs(self):
        for src in ("", "\n\n\n", None):
            with self.subTest(src=repr(src)):
                self.assertEqual(parse(src).mass, "")

    def test_returns_a_mass(self):
        self.assertIsInstance(parse("!mma x"), Mass)


class TestParseFile(unittest.TestCase):
    SRC = (
        "# Domme night\n"
        "!mma Are you feeling obedient?\n"
        "\n"
        "f1 first\n"
        "\n"
        "===\n"
        "\n"
        "# Beach or bedroom\n"
        "!mma Beach or bedroom tonight?\n"
        "\n"
        "f1 second\n"
    )

    def setUp(self):
        self.masses = parse_file(self.SRC)

    def test_two_masses(self):
        self.assertEqual(len(self.masses), 2)

    def test_names(self):
        self.assertEqual(self.masses[0].name, "Domme night")
        self.assertEqual(self.masses[1].name, "Beach or bedroom")

    def test_bodies(self):
        self.assertEqual(self.masses[0].fu[1], ["first"])
        self.assertEqual(self.masses[1].mass, "Beach or bedroom tonight?")
        self.assertEqual(self.masses[1].fu[1], ["second"])


class TestHeaders(unittest.TestCase):
    def test_multiple_comment_lines_all_stripped(self):
        m = parse_file(
            "# The label\n"
            "# a second comment line\n"
            "# a third\n"
            "\n"
            "Opener with no marker\n"
            "\n"
            "follow up\n"
        )[0]
        self.assertEqual(m.mass, "Opener with no marker")
        self.assertEqual(m.name, "The label")
        self.assertEqual(m.fu[1], ["follow up"])

    def test_hashtag_in_body_is_kept(self):
        """A message starting with '#' is content, not a comment."""
        m = parse_file("!mma opener\n\n#ad this is sponsored\n\nsecond")[0]
        self.assertEqual(m.fu[1], ["#ad this is sponsored"])

    def test_unnamed_chunk_falls_back_to_mass_text(self):
        self.assertEqual(parse_file("!mma some opener text\n\nfu")[0].name, "some opener text")

    def test_dashes_also_separate(self):
        self.assertEqual(len(parse_file("!mma a\n\nx\n---\n!mma b\n\ny")), 2)


class TestExampleFile(unittest.TestCase):
    """masses.example.txt is the fixture — a fixed file the tests own.

    Content assertions must NOT point at masses.txt: that is live user data, and
    the suite would fail the first time a real mass was saved into it (it did).
    """

    def setUp(self):
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "masses.example.txt"), encoding="utf-8") as f:
            self.masses = parse_file(f.read())

    def test_three_examples(self):
        self.assertEqual(len(self.masses), 3)

    def test_first(self):
        self.assertEqual(self.masses[0].name, "Beach or bedroom")
        self.assertEqual(self.masses[0].fu[1],
                         ["I've been going back and forth on it all day"])
        self.assertEqual(self.masses[0].fu[3],
                         ["So which is it, before I pick for you? 😌"])

    def test_second_labelled(self):
        self.assertEqual(self.masses[1].fu[1], [
            "first follow-up",
            "second part of the same follow-up, sent right after",
        ])

    def test_third_no_marker(self):
        self.assertEqual(self.masses[2].mass, "Just an opener with no marker")
        self.assertEqual(self.masses[2].fu[1], ["follow-up one", "and its second part"])


class TestLiveMassesFile(unittest.TestCase):
    """Your real masses.txt: checked that it PARSES, never what it contains."""

    def setUp(self):
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        self.path = os.path.join(here, "masses.txt")

    def test_parses_without_error(self):
        if not os.path.exists(self.path):
            self.skipTest("no masses.txt yet")
        with open(self.path, encoding="utf-8") as f:
            masses = parse_file(f.read())
        self.assertGreater(len(masses), 0, "masses.txt parsed to nothing")
        for m in masses:
            self.assertTrue(m.name, "a mass ended up with no name")
            total = sum(len(m.fu[g]) for g in (1, 2, 3))
            self.assertGreater(total, 0, f"“{m.name}” has no follow-ups at all")


class TestRoundTrip(unittest.TestCase):
    """to_text -> parse must give back exactly what went in. This is what the
    GUI's Save depends on: anything lossy here silently rewrites your masses."""

    def assert_round_trips(self, src: str):
        original = parse_file(src)
        reparsed = parse_file(file_to_text(original))
        self.assertEqual(len(original), len(reparsed))
        for a, b in zip(original, reparsed):
            self.assertEqual(a.name, b.name)
            self.assertEqual(a.mass, b.mass)
            for g in (1, 2, 3):
                self.assertEqual(a.fu[g], b.fu[g], f"follow-up {g} changed")

    def test_positional_source(self):
        self.assert_round_trips(TestExportFormat.EXPORTED)

    def test_labelled_source(self):
        self.assert_round_trips(TestPrefixMode.PREFIXED)

    def test_multi_mass_file(self):
        self.assert_round_trips(TestParseFile.SRC)

    def test_example_file(self):
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "masses.example.txt"), encoding="utf-8") as f:
            self.assert_round_trips(f.read())

    def test_gap_survives(self):
        """Empty f1 with a filled f2 is exactly what positional format loses."""
        m = Mass(mass="opener", fu={1: [], 2: ["only the second"], 3: []})
        back = parse(to_text(m))
        self.assertEqual(back.fu[1], [])
        self.assertEqual(back.fu[2], ["only the second"])

    def test_three_parts_use_all_three_labels(self):
        m = Mass(mass="opener", fu={1: ["a", "b", "c"], 2: [], 3: []})
        text = to_text(m)
        self.assertIn("f1: a", text)
        self.assertIn("f1.5: b", text)
        self.assertIn("f1.7: c", text)
        self.assertEqual(parse(text).fu[1], ["a", "b", "c"])

    def test_emoji_and_punctuation_survive(self):
        m = Mass(mass="Beach or bedroom? 🏖️", fu={1: ["so which is it? 😌"], 2: [], 3: []})
        back = parse(to_text(m))
        self.assertEqual(back.mass, "Beach or bedroom? 🏖️")
        self.assertEqual(back.fu[1], ["so which is it? 😌"])

    def test_name_is_written_as_a_comment(self):
        m = Mass(mass="x", fu={1: [], 2: [], 3: []}, name="My label")
        self.assertTrue(to_text(m).startswith("# My label"))
        self.assertEqual(parse_file(to_text(m))[0].name, "My label")


if __name__ == "__main__":
    unittest.main(verbosity=2)
