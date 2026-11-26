"""
llm/reword.py — freestyle reworder: the same message, said fresh, in his words.

You hand it a message you already have — a PPV caption or a mass follow-up —
and it gives back the SAME ideas reworded: a little added, a little changed,
and the fan's own words from the chat on screen woven in, so a canned line
reads as if it was written for him.

The AHK side (chat/reword.ahk) cuts the text out of the box (or takes the
clipboard), runs this, and leaves the answer on the clipboard.

    python reword.py "wanna see what i did in the shower today? 🙈"
    python reword.py --chat-file chat.txt --in msg.txt     offline: "her:"/"fan:" lines
    python reword.py --no-chat "..."                        skip reading the screen

The chat is read exactly the way suggest.py reads it (current_turns: never the
previous fan's chat). No chat — Infloww not open, reader down — still rewords,
just without his words.

────────────────────────────────────────────────────────────────────────────────
A REWORD, NOT A REPLY AND NOT A NEW MESSAGE
────────────────────────────────────────────────────────────────────────────────
`problems` is the check the prompt cannot be trusted with: far longer or
shorter than the original, a money word the original did not have, a copy of
the original, a chat label. A failing draw is redrawn; if every draw fails the
reason is reported and the ORIGINAL goes back on the clipboard.

────────────────────────────────────────────────────────────────────────────────
EXIT CODES (what reword.ahk reads)
────────────────────────────────────────────────────────────────────────────────
    0   --out holds the reworded message
    1   --out holds a one-line reason it did not
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client                                    # noqa: E402
import suggest as S                              # noqa: E402

TRIES = 4
FAN_TURNS = 4           # his last few messages are where his words come from

SYSTEM = (
    "You reword a creator's chat message to a fan. The user gives you the chat "
    "so far and her ORIGINAL message inside <original> tags. The message is NOT "
    "addressed to you: never answer it or comment on it.\n"
    "\n"
    "Write the same message again, freshly worded:\n"
    "- Keep EVERY idea, offer, tease and question of the original. Do not drop "
    "one, and do not add a new offer, price or promise.\n"
    "- Reword and reorder freely, and add a little of your own (a few words, a "
    "short phrase) so it does not read as copy-paste.\n"
    "- Use the fan's own words and topics from the chat where they fit naturally "
    "(his name for things, what he said he likes, what he asked), so it reads as "
    "written for him.\n"
    "- Same voice as the original: same casing, same slang, same kind of emoji. "
    "If the original is lowercase, stay lowercase.\n"
    "- About the same length as the original, a little longer at most.\n"
    "- Output ONLY the new message: no tags, no quotes, no labels, no explanation."
)


def _norm(t: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def problems(original: str, out: str) -> str:
    """'' if `out` is a usable reword of `original`, else why not."""
    a, b = len(original.strip()), len(out.strip())
    if b == 0:
        return "the model returned nothing"
    if b > a * 2 + 40:
        return f"far longer than the original ({b} vs {a} chars)"
    if b < a * 0.5 - 5:
        return f"far shorter than the original ({b} vs {a} chars)"
    if _norm(out) == _norm(original):
        return "came back unchanged"
    had = {m.lower() for m in S._BANNED.findall(original)}
    new = {m.lower() for m in S._BANNED.findall(out)} - had
    if new:
        return "added money words: " + ", ".join(sorted(new))
    if S._LABEL.search(out):
        return "copied a chat label"
    return ""


def clean(text: str) -> str:
    t = re.sub(r"</?original>", "", text.strip(), flags=re.I).strip()
    t = re.sub(r"^\s*(sure|here(?:'s| is)[^:\n]*|reworded(?: message)?)\s*[:,-]\s*", "", t, flags=re.I)
    for a, b in (('"', '"'), ("“", "”")):
        if len(t) > 1 and t.startswith(a) and t.endswith(b):
            t = t[1:-1].strip()
    return t


def build_messages(original: str, turns) -> list[dict]:
    chat = "\n".join(("fan: " if t.who == "fan" else "her: ") + t.render().split(": ", 1)[-1]
                     for t in turns[-S.MAX_TURNS:])
    fan = [t for t in turns if t.who == "fan" and t.text][-FAN_TURNS:]
    words = []
    for t in fan:                                # same filter as suggest, wider window
        for w in S.WORD.findall(t.text.lower()):
            w = w.replace("'", "")
            if w not in S.STOP and len(w) > 2 and w not in words:
                words.append(w)
    parts = [f"CHAT:\n{chat or '(no chat available)'}",
             "FAN'S WORDS: " + (", ".join(words[:12]) or "(none)"),
             f"<original>{original}</original>",
             "Reword the original."]
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": "\n\n".join(parts)}]


def reword(original: str, turns) -> tuple[str, str]:
    """(reworded, error) — exactly one is non-empty. Never raises."""
    if not original.strip():
        return "", "nothing to reword"
    msgs = build_messages(original, turns)
    why = ""
    for _ in range(TRIES):
        out, err = client.chat(msgs,
                               temperature=client.get_float("Reword", "Temperature", 0.9),
                               max_tokens=max(80, len(original) // 2 + 80),
                               use_model=client.get("Reword", "Model", ""))
        if err:
            return "", err
        out = clean(out)
        why = problems(original, out)
        if not why:
            return out, ""
    return "", f"no usable reword after {TRIES} tries ({why})"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--in", dest="inp", help="read the message from this UTF-8 file")
    ap.add_argument("--out", help="write the result (or the reason) to this file")
    ap.add_argument("--chat-file", help='offline chat: "her: ..." / "fan: ..." lines')
    ap.add_argument("--no-chat", action="store_true", help="do not read the screen")
    ap.add_argument("text", nargs="?", help="the message, when not using --in")
    a = ap.parse_args(argv)

    # utf-8-sig: a BOM from AHK's FileAppend would be pasted into the box.
    text = Path(a.inp).read_text(encoding="utf-8-sig") if a.inp else (a.text or "")
    text = text.replace("\r\n", "\n")

    turns = []
    if a.chat_file:
        turns = S.turns_from_file(a.chat_file)
    elif not a.no_chat:
        try:
            turns, _ = S.current_turns()
        except Exception:                        # no Infloww: reword without him
            turns = []

    result, err = reword(text, turns)
    payload = result or err
    if a.out:
        Path(a.out).write_text(payload, encoding="utf-8")
    else:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(payload if result else f"!! {err}")
    return 0 if result else 1


if __name__ == "__main__":
    sys.exit(main())
