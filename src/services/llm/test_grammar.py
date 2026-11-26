"""Tests for grammar.py that need no model: the fake below stands in for Ollama."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import grammar  # noqa: E402


class FakeChat:
    """Answers each request with `answer(text_in_tags)`."""
    def __init__(self, answer):
        self.answer, self.calls = answer, 0

    def __call__(self, messages, **_kw):
        self.calls += 1
        body = messages[-1]["content"]
        return self.answer(body[len("<text>"):-len("</text>")]), ""


class GrammarTest(unittest.TestCase):
    def setUp(self):
        self.real = grammar.client.chat

    def tearDown(self):
        grammar.client.chat = self.real

    def use(self, answer):
        grammar.client.chat = fake = FakeChat(answer)
        return fake

    def test_single_line_is_one_request(self):
        fake = self.use(lambda t: t.replace("se", "see"))
        self.assertEqual(grammar.fix("wanna se", "casual"), ("wanna see", ""))
        self.assertEqual(fake.calls, 1)

    def test_joined_lines_are_redone_line_by_line(self):
        fake = self.use(lambda t: t.replace("\n", " ").upper())
        out, err = grammar.fix("hi\n\nthere", "alice")
        self.assertEqual((out, err), ("HI\n\nTHERE", ""))
        self.assertEqual(fake.calls, 3)   # whole message, then the two lines

    def test_a_reply_is_not_pasted(self):
        self.use(lambda t: "Oh I'm doing great thanks for asking! How about you, "
                           "what have you been up to all day long?")
        out, err = grammar.fix("how r u", "casual")
        self.assertEqual(out, "")
        self.assertIn("replied", err)

    def test_wrappers_are_stripped(self):
        self.use(lambda t: 'Here is the corrected text: "<text>see you</text>"')
        self.assertEqual(grammar.fix("se you", "alice"), ("see you", ""))

    def test_empty_and_unknown_mode(self):
        self.assertEqual(grammar.fix("  ", "casual")[0], "")
        self.assertIn("unknown mode", grammar.fix("x", "pirate")[1])

    def test_casual_drops_caps_apostrophes_and_end_stops(self):
        self.use(lambda t: "I can't wait, it's gonna be fun.\nDon't be late...")
        out, _ = grammar.fix("i cant wait its gona be fun\ndont be late...", "casual")
        self.assertEqual(out, "i cant wait, its gonna be fun\ndont be late...")

    def test_alice_keeps_its_apostrophes(self):
        self.use(lambda t: "I can't wait.")
        self.assertEqual(grammar.fix("i cant wait", "alice"), ("I can't wait.", ""))

    def test_text_speak_expansion_is_allowed(self):
        self.assertEqual(grammar.plausible("u ok rn", "Are you okay right now?"), "")


if __name__ == "__main__":
    unittest.main()
