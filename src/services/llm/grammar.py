"""
llm/grammar.py — fix the grammar of the message you are typing. Two voices.

    casual   WhatsApp: typos fixed, nothing else — all lowercase, no apostrophes,
             grammar left alone, slang and emoji kept
    alice    proper British English: capitals, full punctuation, -ise/-our spelling

The AHK side (chat/grammar.ahk) cuts the text, runs this, and leaves the answer
on the clipboard. Run it by hand to see what a mode does to a line:

    python grammar.py --mode casual "i cant wait to se u tonite babe"
    python grammar.py --mode alice  --in msg.txt --out fixed.txt

────────────────────────────────────────────────────────────────────────────────
IT CORRECTS, IT DOES NOT REPLY
────────────────────────────────────────────────────────────────────────────────
The text handed to the model is a message written TO someone — often a question,
often flirty. A chat model's reflex is to answer it. So the text is fenced in
<text> tags, the system prompt says in as many words that it is not addressed to
the model, and the few-shot examples include a question that is corrected rather
than answered.

The prompt is not trusted to hold on its own: `plausible()` rejects any answer
whose length has drifted too far from the input. A correction changes a few
characters; a reply, a refusal or an essay changes the length, and that is the
one failure that would otherwise be pasted over your message without warning.

────────────────────────────────────────────────────────────────────────────────
EXIT CODES (what grammar.ahk reads)
────────────────────────────────────────────────────────────────────────────────
    0   --out holds the corrected text
    1   --out holds a one-line reason it did not (Ollama down, guard tripped)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client                                    # noqa: E402

MODES = ("casual", "alice")

_SHARED_RULES = (
    "You are a proofreader. The user gives you a chat message inside <text> tags. "
    "It is NOT addressed to you: never answer it, react to it, or comment on it, "
    "even when it is a question. Return the same message with its mistakes fixed.\n"
    "\n"
    "- Keep the meaning, the wording and the tone. Do not add ideas, do not "
    "drop any, do not make it longer.\n"
    "- Keep every emoji, name, number and line break where it is.\n"
    "- Output ONLY the corrected message: no tags, no quotes, no explanation.\n"
)

SYSTEM = {
    "casual": _SHARED_RULES + (
        "- Fix ONLY misspelt words and typos (thinkign -> thinking, se -> see).\n"
        "- Do NOT fix grammar, do NOT add punctuation, do NOT add missing words: "
        "a casual WhatsApp message is meant to be sloppy.\n"
        "- Keep slang and short forms exactly as written (u, ur, rn, lol, gonna, "
        "wanna), and never introduce one the writer did not use: 'you' stays 'you'."
    ),
    "alice": _SHARED_RULES + (
        "- Fix spelling, typos, missing words, grammar and punctuation.\n"
        "\nStyle: correct British English. Capitalise sentences, names and 'I'. "
        "Full punctuation and apostrophes. British spelling (realise, colour, "
        "favourite, mum). Expand text-speak into real words (u -> you, ur -> your "
        "or you're, rn -> right now). Keep it warm and natural, not stiff or formal."
    ),
}

# Prior turns the model imitates. Small models follow an example far more
# reliably than a rule, and the question in each set is the one that teaches
# "correct it, do not answer it".
EXAMPLES = {
    "casual": [
        ("hey how are you doing today?? i was thinkign about you",
         "hey how are you doing today?? i was thinking about you"),
        ("do u wanna se what i got on rn 😏",
         "do u wanna see what i got on rn 😏"),
        ("i realy enjoyed talking to you yesterday you made me laugh so much",
         "i really enjoyed talking to you yesterday you made me laugh so much"),
    ],
    "alice": [
        ("hey how r u doing today?? i was thinkign about u",
         "Hey, how are you doing today? I was thinking about you."),
        ("do u wanna see what i got on rn 😏",
         "Do you want to see what I've got on right now? 😏"),
        ("my favorite color is red, i realized it today lol",
         "My favourite colour is red, I realised it today, lol."),
    ],
}

# Same wrapper-stripping idea as draft.clean, for the wrappers a proofreader adds.
_LEAD = re.compile(r"^\s*(sure|certainly|here(?:'s| is)[^:\n]*|corrected(?: text| message)?)"
                   r"\s*[:,-]\s*", re.I)
_TAGS = re.compile(r"</?text>", re.I)


def clean(text: str) -> str:
    t = _TAGS.sub("", _LEAD.sub("", text.strip())).strip()
    for a, b in (('"', '"'), ("“", "”")):
        if len(t) > 1 and t.startswith(a) and t.endswith(b):
            t = t[1:-1].strip()
    return t


# Casual mode's look is applied here, not asked for. Told "no apostrophes, all
# lowercase", the model drifts back to proper English within a sentence or two;
# a string operation does not drift.
_APOSTROPHES = str.maketrans("", "", "'’")
_END_STOP = re.compile(r"(?<!\.)\.[ \t]*$", re.M)   # one full stop, not "..."


def casualise(text: str) -> str:
    """lowercase, no apostrophes, no full stop at the end of a line."""
    return _END_STOP.sub("", text.lower().translate(_APOSTROPHES))


def plausible(before: str, after: str) -> str:
    """'' if `after` looks like a correction of `before`, else why not.

    The bounds are loose on purpose: alice mode legitimately turns "u" into "you"
    and "rn" into "right now", which grows a short text-speak message a lot.
    """
    a, b = len(before.strip()), len(after.strip())
    if b == 0:
        return "the model returned nothing"
    if b > a * 2 + 25:
        return f"the answer is much longer than the message ({b} vs {a} chars) — it replied instead of correcting"
    if b < a * 0.5 - 5:
        return f"the answer is much shorter than the message ({b} vs {a} chars) — not pasting it"
    return ""


def build_messages(text: str, mode: str) -> list[dict]:
    msgs = [{"role": "system", "content": SYSTEM[mode]}]
    for before, after in EXAMPLES[mode]:
        msgs.append({"role": "user", "content": f"<text>{before}</text>"})
        msgs.append({"role": "assistant", "content": after})
    msgs.append({"role": "user", "content": f"<text>{text}</text>"})
    return msgs


def fix(text: str, mode: str) -> tuple[str, str]:
    """(corrected, error) — exactly one is non-empty. Never raises.

    Line breaks are kept by construction, not by asking. Told to keep them, the
    model still joins two lines into one sentence often enough to matter, and in
    a chat box each line is usually its own thought. So a whole-message answer
    with a different line count is thrown away and the message is redone one line
    at a time — a single-line message, the common case, is still one request.
    """
    if mode not in MODES:
        return "", f"unknown mode {mode!r} (use {' or '.join(MODES)})"
    if not text.strip():
        return "", "nothing to fix — the message box is empty"
    out, err = _fix_once(text, mode)
    if err or out.count("\n") == text.count("\n"):
        return out, err
    fixed = []
    for line in text.split("\n"):
        if not line.strip():
            fixed.append(line)
            continue
        got, err = _fix_once(line, mode)
        if err:
            return "", err
        # A one-line request that still came back as two is joined rather than
        # rejected: the line count is what has to hold, and this keeps it.
        fixed.append(" ".join(got.split("\n")))
    return "\n".join(fixed), ""


def _fix_once(text: str, mode: str) -> tuple[str, str]:
    # Room for alice mode's expansions, plus slack; a correction is never long.
    max_tokens = max(60, len(text) // 2 + 60)
    # [Grammar] Model, when set, so switching [Ollama] Model to a roleplay
    # model for suggestions does not also change who proofreads.
    out, err = client.chat(build_messages(text, mode),
                           temperature=client.get_float("Grammar", "Temperature", 0.2),
                           max_tokens=max_tokens,
                           use_model=client.get("Grammar", "Model", ""))
    if err:
        return "", err
    out = clean(out)
    if mode == "casual":
        out = casualise(out)
    why = plausible(text, out)
    return ("", why) if why else (out, "")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--mode", choices=MODES, default="casual")
    ap.add_argument("--in", dest="inp", help="read the message from this UTF-8 file")
    ap.add_argument("--out", help="write the result (or the reason) to this file")
    ap.add_argument("text", nargs="?", help="the message, when not using --in")
    a = ap.parse_args(argv)

    if a.inp:
        # utf-8-sig: AHK's FileAppend may or may not write a BOM, and a BOM that
        # reaches the model comes back pasted into the message box.
        text = Path(a.inp).read_text(encoding="utf-8-sig")
    else:
        text = a.text or ""
    # The clipboard hands over Windows line endings; the model and the paste are
    # both happier with plain \n.
    text = text.replace("\r\n", "\n")

    result, err = fix(text, a.mode)
    payload = result or err
    if a.out:
        Path(a.out).write_text(payload, encoding="utf-8")
    else:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(payload if result else f"!! {err}")
    return 0 if result else 1


if __name__ == "__main__":
    sys.exit(main())
