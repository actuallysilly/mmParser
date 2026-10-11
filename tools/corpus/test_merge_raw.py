"""Tests for merge_raw.py. The cases are real line pairs from the two raw copies.

    python -m unittest tools\\corpus\\test_merge_raw.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from merge_raw import _merge_by_line, merge_day, merge_text  # noqa: E402


class MergeText(unittest.TestCase):
    def test_junk_in_one_copy_falls_out(self):
        self.assertEqual(merge_text("Is there meaning behing d 5.03",
                                    "Is there meaning behind 5.03"),
                         "Is there meaning behind 5.03")
        self.assertEqual(merge_text("what does Mre  Smith want", "what does Mr Smith want"),
                         "what does Mr Smith want")

    def test_junk_in_each_copy_both_fall_out(self):
        self.assertEqual(merge_text("Later you nmight", "Later yxou might"),
                         "Later you might")

    def test_junk_in_both_copies_survives(self):
        # Both timers fired: nothing to tell it apart. Left for the LLM repair.
        self.assertEqual(merge_text("qucklquickly", "qucklquickly"), "qucklquickly")

    def test_a_break_in_one_copy_is_kept(self):
        self.assertEqual(merge_text("DiI'm here", "Di\nI'm here"), "Di\nI'm here")

    def test_identical(self):
        self.assertEqual(merge_text("same", "same"), "same")


class MergeDay(unittest.TestCase):
    def test_sources(self):
        old = ["hello", "Is there meaning behing d 5.03", "only old"]
        mma = ["hello", "Is there meaning behind 5.03", "only old", "only mma"]
        self.assertEqual(merge_day(old, mma), [
            ("both", "hello"),
            ("merged", "Is there meaning behind 5.03"),
            ("both", "only old"),
            ("mma", "only mma"),
        ])

    def test_split_line_merges_into_two(self):
        rows = merge_day(["x", "DiI'm here", "y"], ["x", "Di", "I'm here", "y"])
        self.assertEqual(rows, [("both", "x"), ("merged", "Di"),
                                ("merged", "I'm here"), ("both", "y")])

    def test_one_side_missing(self):
        self.assertEqual(merge_day(["a", "b"], []), [("old", "a"), ("old", "b")])

    def test_big_block_pairs_similar_lines(self):
        a = ["you will get to have fun", "totally different", "the end of it"]
        b = ["you will get to have ufun", "the end of it"]
        self.assertEqual(_merge_by_line(a, b), [
            ("merged", "you will get to have fun"),
            ("old", "totally different"),
            ("merged", "the end of it"),
        ])


if __name__ == "__main__":
    unittest.main()
