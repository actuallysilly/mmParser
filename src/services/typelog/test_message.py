"""
Tests for message.py — the message-box model typelog records from.

    python -m unittest test_message.py      (from this folder)

Each case is a key sequence and what should be written for it. The first group
is the bugs the old recorder actually wrote into the logs.
"""
import unittest

from message import (CARET, EMOJI, HISTORY, MOD_SEND, PASTE, SELECT, START,
                     UNDO, VK_A, VK_OEM_PERIOD, VK_V, VK_X, VK_Z, WORD_DEL,
                     MessageBox, apply_key, escape, unescape)


class Keys:
    """Drives apply_key the way typelog.pyw does, with a fake clipboard."""

    def __init__(self, clipboard="CLIP"):
        self.box = MessageBox()
        self.clipboard = clipboard
        self.sent = []

    def _key(self, name=None, vk=None, ch=None, *mods):
        msg = apply_key(self.box, name, vk, ch, set(mods), lambda: self.clipboard)
        if msg is not None:
            self.sent.append(msg)
        return self

    def type(self, text):
        for c in text:
            if c == " ":
                self._key("space")
            else:
                self._key(None, ord(c.upper()), c)
        return self

    def key(self, name, *mods):
        return self._key(name, None, None, *mods)

    def ctrl(self, letter_vk):
        return self._key(None, letter_vk, None, "ctrl")

    def bs(self, n=1):
        for _ in range(n):
            self.key("backspace")
        return self

    def enter(self, *mods):
        return self.key("enter", *mods)

    @property
    def texts(self):
        return [m.text for m in self.sent]


class TheOldBugs(unittest.TestCase):
    def test_a_pause_does_not_commit_a_draft(self):
        # `Thank youWe are thank you!!!`: the 5s flush wrote the draft, and the
        # backspaces after it could not reach it.
        k = Keys().type("Thank you").bs(9).type("We are thank you!!!").enter()
        self.assertEqual(k.texts, ["We are thank you!!!"])
        self.assertTrue(k.sent[0].exact)

    def test_nothing_is_written_until_enter(self):
        k = Keys().type("half a thought")
        self.assertEqual(k.sent, [])

    def test_shift_enter_is_a_line_break_not_a_send(self):
        k = Keys().type("one").enter("shift").type("two").enter()
        self.assertEqual(k.texts, ["one\ntwo"])

    def test_empty_enter_writes_nothing(self):
        k = Keys().enter().type("   ").enter()
        self.assertEqual(k.sent, [])

    def test_hotstring_paste_is_recorded(self):
        # Snd(): AHK erases the trigger with injected backspaces, then Ctrl+V,
        # Enter. The old recorder ignored Ctrl+V and logged an empty line.
        k = Keys(clipboard="Thank you so much!").type("tysm").bs(4).ctrl(VK_V).enter()
        self.assertEqual(k.texts, ["Thank you so much!"])
        self.assertEqual(k.sent[0].kind, "pasted")
        self.assertTrue(k.sent[0].exact)

    def test_typed_and_pasted(self):
        k = Keys(clipboard="world").type("hello ").ctrl(VK_V).enter()
        self.assertEqual(k.texts, ["hello world"])
        self.assertEqual(k.sent[0].kind, "mixed")


class ClearingTheBox(unittest.TestCase):
    def test_select_all_then_type_replaces(self):
        k = Keys().type("draft").ctrl(VK_A).type("final").enter()
        self.assertEqual(k.texts, ["final"])

    def test_select_all_backspace_clears_and_forgives(self):
        # After a caret move the box is unknown — clearing it makes it known.
        k = Keys().type("abc").key("left").ctrl(VK_A).bs().type("new").enter()
        self.assertEqual(k.texts, ["new"])
        self.assertTrue(k.sent[0].exact)

    def test_select_all_delete_and_cut(self):
        self.assertEqual(Keys().type("x").ctrl(VK_A).key("delete").type("y").enter().texts, ["y"])
        self.assertEqual(Keys().type("x").ctrl(VK_A).ctrl(VK_X).type("y").enter().texts, ["y"])

    def test_select_all_then_right_collapses_without_loss(self):
        k = Keys().type("keep").ctrl(VK_A).key("end").type(" this").enter()
        self.assertEqual(k.texts, ["keep this"])
        self.assertTrue(k.sent[0].exact)

    def test_select_all_paste_replaces(self):
        k = Keys(clipboard="P").type("old").ctrl(VK_A).ctrl(VK_V).enter()
        self.assertEqual(k.texts, ["P"])

    def test_delete_at_end_does_nothing(self):
        k = Keys().type("abc").key("delete").enter()
        self.assertEqual(k.texts, ["abc"])
        self.assertTrue(k.sent[0].exact)


class CtrlBackspace(unittest.TestCase):
    def test_deletes_the_last_word_and_its_spaces(self):
        k = Keys().type("hello world ").key("backspace", "ctrl").type("there").enter()
        self.assertEqual(k.texts, ["hello there"])
        self.assertTrue(k.sent[0].exact)

    def test_whole_single_word(self):
        k = Keys().type("hello").key("backspace", "ctrl").type("hi").enter()
        self.assertEqual(k.texts, ["hi"])

    def test_punctuation_is_flagged(self):
        k = Keys().type("ok, don't").key("backspace", "ctrl").enter()
        self.assertIn(WORD_DEL, k.sent[0].reasons)


class Uncertain(unittest.TestCase):
    def test_caret_move_is_flagged(self):
        k = Keys().type("helo").key("left").type("l").enter()
        self.assertEqual(k.sent[0].reasons, [CARET])
        self.assertFalse(k.sent[0].exact)

    def test_caret_move_in_empty_box_is_harmless(self):
        k = Keys().key("left").key("home").type("hi").enter()
        self.assertTrue(k.sent[0].exact)

    def test_shift_selection_is_flagged(self):
        k = Keys().type("hello").key("left", "shift").type("x").enter()
        self.assertEqual(k.sent[0].reasons, [SELECT])

    def test_undo_win_v_emoji(self):
        self.assertEqual(Keys().type("a").ctrl(VK_Z).enter().sent[0].reasons, [UNDO])
        k = Keys()
        k.type("a")._key(None, VK_V, "v", "win")
        self.assertEqual(k.enter().sent[0].reasons, [HISTORY])
        k = Keys()
        k.type("a")._key(None, VK_OEM_PERIOD, ".", "win")
        self.assertEqual(k.enter().sent[0].reasons, [EMOJI])

    def test_unreadable_clipboard(self):
        k = Keys(clipboard=None).type("a ").ctrl(VK_V).enter()
        self.assertEqual(k.sent[0].reasons, [PASTE])

    def test_ctrl_enter(self):
        k = Keys().type("hi").enter("ctrl")
        self.assertEqual(k.sent[0].reasons, [MOD_SEND])

    def test_flags_do_not_leak_into_the_next_message(self):
        k = Keys().type("ab").key("left").enter().type("clean").enter()
        self.assertTrue(k.sent[1].exact)

    def test_unseen_box_after_start(self):
        k = Keys()
        k.box.unseen()
        k.type("hi").enter()
        self.assertEqual(k.sent[0].reasons, [START])


class Shortcuts(unittest.TestCase):
    def test_ctrl_letters_are_not_text(self):
        k = Keys().type("hi")._key(None, 0x43, "\x03", "ctrl").enter()   # Ctrl+C
        self.assertEqual(k.texts, ["hi"])

    def test_altgr_characters_are_text(self):
        k = Keys().type("a")._key(None, 0x51, "@", "ctrl", "alt").enter()
        self.assertEqual(k.texts, ["a@"])

    def test_alt_letters_are_not_text(self):
        k = Keys().type("a")._key(None, 0x46, "f", "alt").enter()
        self.assertEqual(k.texts, ["a"])

    def test_tab_and_escape_do_nothing(self):
        k = Keys().type("a").key("tab").key("esc").type("b").enter()
        self.assertEqual(k.texts, ["ab"])
        self.assertTrue(k.sent[0].exact)

    def test_shift_insert_pastes(self):
        k = Keys(clipboard="X").key("insert", "shift").enter()
        self.assertEqual(k.texts, ["X"])


class LineFormat(unittest.TestCase):
    def test_round_trip(self):
        for s in ["plain", "two\nlines", "tab\there", r"back\slash", "lit\\n", ""]:
            self.assertEqual(unescape(escape(s)), s)
        self.assertNotIn("\n", escape("a\nb"))


if __name__ == "__main__":
    unittest.main()
