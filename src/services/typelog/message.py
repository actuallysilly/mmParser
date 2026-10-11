"""
typelog — a model of the Infloww message box, rebuilt from keystrokes.

The recorder used to append every keystroke to a buffer and write that buffer to
disk every five seconds. Backspace could only delete what had not been written
yet, so every pause longer than five seconds committed whatever was on screen:
type `Thank you`, pause, delete it, type `We are thank you!!!` and the log said
`Thank youWe are thank you!!!`. Abandoned drafts, retypes and half-words all
ended up in the corpus as if they had been sent.

This module replaces that with one rule: **the message is the box, and the box
is only written down when it is sent.** Everything here is the box's content as
far as the keystrokes can tell, held in memory until a plain Enter.

EXACT OR UNCERTAIN, NEVER GUESSED
The box can only be tracked while the caret stays at the end of the text, which
is where it is when you just type. Anything that moves the caret (an arrow, Home,
a click), selects part of the text, undoes, or inserts text we cannot see (Win+V,
the emoji panel) means the keystrokes no longer describe the box. The message is
then still recorded, but flagged with the reason, and the recorder writes it to
a separate file. A missing message costs nothing; a wrong one poisons whatever is
trained on the log.

Things that make the box known again are modelled exactly rather than flagged:
Ctrl+A followed by Backspace, Delete, Ctrl+X or typing replaces everything, so
afterwards the box holds exactly what we think it does.

No pynput in here. typelog.pyw turns key events into the calls below, which is
what lets test_message.py drive it without a keyboard hook.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# Reasons a message's text cannot be vouched for. The names are what the
# uncertain log shows, so they are short.
CARET    = "caret"      # an arrow/Home/PageUp/click moved the caret off the end
SELECT   = "select"     # a Shift+arrow selection we cannot measure
UNDO     = "undo"       # Ctrl+Z / Ctrl+Y
PASTE    = "paste?"     # a paste whose text could not be read
HISTORY  = "win+v"      # clipboard history: the pasted text is unknown
EMOJI    = "emoji"      # the Win+. panel inserts text with no keystrokes
WORD_DEL = "ctrl+bs"    # Ctrl+Backspace across punctuation, which we cannot predict
MOD_SEND = "mod+enter"  # Ctrl/Alt+Enter: not known whether Infloww sends on it
START    = "start"      # the recorder started, or resumed, with the box unseen

# Ctrl+Backspace on a tail made of one plain word (and the spaces after it) is
# predictable: the word and its trailing spaces go. Anything with punctuation is
# left to Chromium's word-break rules, which we do not reproduce.
_PLAIN_WORD_TAIL = re.compile(r"(?:^|(?<=\s))[^\W_]+\s*$")


@dataclass
class Message:
    text: str
    pasted: bool                      # some of it came from the clipboard
    typed: bool                       # some of it came from keystrokes
    reasons: list[str] = field(default_factory=list)

    @property
    def exact(self) -> bool:
        return not self.reasons

    @property
    def kind(self) -> str:
        if self.pasted and self.typed:
            return "mixed"
        return "pasted" if self.pasted else "typed"


class MessageBox:
    """What is in the message box, as far as the keystrokes say."""

    def __init__(self) -> None:
        self.text = ""
        # Where each character of `text` came from, 't'yped or 'p'asted, always
        # the same length as `text`. "Pasted" must describe what is IN the box,
        # not its history: a hotstring's trigger is typed, then erased.
        self.source = ""
        self.all_selected = False     # after Ctrl+A, until something collapses it
        self.reasons: list[str] = []

    # -- state helpers ----------------------------------------------------------
    def _flag(self, reason: str) -> None:
        if reason not in self.reasons:
            self.reasons.append(reason)

    def _cut_to(self, n: int) -> None:
        n = max(0, n)
        self.text, self.source = self.text[:n], self.source[:n]

    def _append(self, text: str, src: str) -> None:
        if self.all_selected:
            self._clear()
        self.text += text
        self.source += src * len(text)

    def _clear(self) -> None:
        """The box was emptied, so it is known exactly again."""
        self.text = self.source = ""
        self.all_selected = False
        self.reasons = []

    def switch_chat(self) -> None:
        """A click on another fan in the conversation list. Whatever was in the
        box stays in the chat you left, unsent, so it is not part of the next
        message; the new chat's box is taken to be empty."""
        self._clear()

    def unseen(self, reason: str = START) -> None:
        """The box may hold text we never saw. Typing on is still recorded, but
        flagged, until the box is cleared or sent."""
        self._clear()
        self.reasons = [reason]

    # -- editing ----------------------------------------------------------------
    def type(self, ch: str) -> None:
        self._append(ch, "t")

    def newline(self) -> None:
        """Shift+Enter: a line break inside the message. Never a send."""
        self.type("\n")

    def backspace(self, word: bool = False) -> None:
        if self.all_selected:
            self._clear()
            return
        if not word:
            self._cut_to(len(self.text) - 1)
            return
        m = _PLAIN_WORD_TAIL.search(self.text)
        if m:
            self._cut_to(m.start())
        elif self.text:
            # A best guess, flagged: drop the trailing spaces, then one run of
            # word characters or one run of punctuation.
            self._flag(WORD_DEL)
            m = re.search(r"(?:[^\W_]+|[\W_]+?)\s*$", self.text)
            self._cut_to(m.start() if m else len(self.text) - 1)

    def delete(self) -> None:
        """Delete / Ctrl+Delete. At the end of the text there is nothing after the
        caret, so it only matters when everything is selected."""
        if self.all_selected:
            self._clear()

    def select_all(self) -> None:
        self.all_selected = True

    def cut(self) -> None:
        """Ctrl+X. With nothing selected Chromium cuts nothing."""
        if self.all_selected:
            self._clear()

    def paste(self, clip: str | None) -> None:
        """Ctrl+V / Shift+Insert. `clip` is the clipboard's text, None if unread."""
        if clip is None:
            self.all_selected = False
            self._flag(PASTE)
            return
        self._append(clip.replace("\r\n", "\n").replace("\r", "\n"), "p")

    def caret_to_end(self) -> None:
        """Right/End/Down/PageDown. The caret is already at the end; the only
        effect is collapsing a Ctrl+A selection onto it."""
        self.all_selected = False

    def caret_away(self) -> None:
        """Left/Home/Up/PageUp, or a mouse click: the caret may be mid-text now.
        In an empty box there is nowhere else for it to be."""
        self.all_selected = False
        if self.text:
            self._flag(CARET)

    def select_partial(self) -> None:
        """Shift+Left and friends: a selection we cannot measure."""
        if self.all_selected:
            return                          # still everything
        if self.text:
            self._flag(SELECT)

    def unknown_edit(self, reason: str) -> None:
        """Undo, clipboard history, the emoji panel — the box changed in a way
        the keystrokes do not describe."""
        self.all_selected = False
        self._flag(reason)

    # -- sending ----------------------------------------------------------------
    def send(self, modified: bool = False) -> Message | None:
        """Enter. Returns the message, or None if the box was empty; either way
        the box starts over, empty."""
        if modified:
            self._flag(MOD_SEND)
        msg = None
        if self.text.strip():
            msg = Message(self.text, "p" in self.source, "t" in self.source,
                          list(self.reasons))
        self._clear()
        return msg


# -- keys -> box --------------------------------------------------------------
# Virtual-key codes for the Ctrl/Win shortcuts. Matched by vk, not by character:
# with Ctrl held, Windows hands pynput a control character (Ctrl+V -> '\x16').
VK_A, VK_V, VK_X, VK_Y, VK_Z = 0x41, 0x56, 0x58, 0x59, 0x5A
VK_OEM_1, VK_OEM_PERIOD = 0xBA, 0xBE        # ; and . — Win+; / Win+. open emoji

_TO_END  = {"right", "end", "down", "page_down"}
_AWAY    = {"left", "home", "up", "page_up"}


def apply_key(box: MessageBox, name: str | None, vk: int | None, ch: str | None,
              mods: set[str], read_clipboard) -> Message | None:
    """Route one key press into `box`. Returns a Message when it was a send.

    name — pynput's special-key name ('enter', 'backspace', ...), None for a
           character key.
    vk   — the virtual-key code of a character key.
    ch   — the character it produced, if any.
    mods — the subset of {'ctrl', 'shift', 'alt', 'win'} held down.
    read_clipboard — called on a paste; returns the clipboard text or None.
    """
    ctrl, shift, alt, win = ("ctrl" in mods, "shift" in mods,
                             "alt" in mods, "win" in mods)
    altgr = ctrl and alt                     # Windows reports AltGr as Ctrl+Alt

    if name == "enter":
        if shift and not (ctrl or alt):
            box.newline()
            return None
        return box.send(modified=ctrl or alt)
    if name == "backspace":
        box.backspace(word=ctrl and not alt)
        return None
    if name == "delete":
        box.delete()
        return None
    if name == "insert":
        if shift and not ctrl:
            box.paste(read_clipboard())
        return None
    if name == "space":
        if not (ctrl or alt or win) or altgr:
            box.type(" ")
        return None
    if name in _TO_END:
        if not shift:
            box.caret_to_end()
        return None
    if name in _AWAY:
        if shift:
            box.select_partial()
        else:
            box.caret_away()
        return None
    if name is not None:
        return None                          # Tab, Esc, F-keys, modifiers: no edit

    if win:
        if vk == VK_V:
            box.unknown_edit(HISTORY)
        elif vk in (VK_OEM_PERIOD, VK_OEM_1):
            box.unknown_edit(EMOJI)
        return None
    if ctrl and not altgr:
        if vk == VK_A:
            box.select_all()
        elif vk == VK_V:
            box.paste(read_clipboard())
        elif vk == VK_X:
            box.cut()
        elif vk in (VK_Z, VK_Y):
            box.unknown_edit(UNDO)
        return None                          # Ctrl+C, Ctrl+F, ...: no edit
    if alt and not altgr:
        return None                          # menu accelerators
    if ch and ch.isprintable():
        box.type(ch)
    return None


# -- the on-disk line format --------------------------------------------------
# One message per line, tab-separated, so a message containing a line break
# (Shift+Enter) or a tab must be escaped. Backslash first, or `\n` typed as two
# characters would come back as a newline.
def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def unescape(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m[1], m[1]), text)
