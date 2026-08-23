"""
llm/draft.py — read the open conversation, offer replies. Types nothing.

The end of the phase-1 slice: transcript.py reads the screen, client.py talks to
Ollama, and this is the bit that decides what to ask and what to do with the
answer. Run it and it prints what it read and what it would say.

────────────────────────────────────────────────────────────────────────────────
IT OFFERS, IT NEVER TYPES
────────────────────────────────────────────────────────────────────────────────
This is the rule autoword already established, and an LLM makes it stricter
rather than looser. autoword may complete a word without being asked ONLY when
the completion is effectively certain — one continuation, seen five times, three
characters in — and it measured 97.2% before it was allowed to. A generative
model is never in that class: it is fluent, confident, and wrong often enough
that the number would be nowhere near it.

So a draft is always *asked for*, always *shown*, and always *chosen*. That is
also what makes it affordable to be interesting — the reword feature makes the
same trade in reverse: a suggestion you asked for can afford to be the fifth-best
word, because changing nothing is one keypress away.

Nothing in this module sends a keystroke. Handing a chosen draft to the message
box is a separate, deliberate step.

────────────────────────────────────────────────────────────────────────────────
WHAT THE MODEL IS TOLD, AND WHAT IT IS NOT
────────────────────────────────────────────────────────────────────────────────
It gets the visible conversation, attributed, and the persona line from
llm.ini. It does NOT get the fan's name, spend, or anything from the insights
panel — not because that would not help, but because none of it has been shown to
help yet, and every extra field is another thing that can be misread off the
screen and asserted to a paying customer as fact. Start with the conversation;
add a field when it earns its place.

The transcript is capped at MAX_TURNS. The whole visible pane is usually 5-10
bubbles, so this rarely bites — but a very long one costs prompt-eval time and
buries the message actually being answered.

────────────────────────────────────────────────────────────────────────────────
WHY IT REFUSES ON A NOTE
────────────────────────────────────────────────────────────────────────────────
`transcript.read_conversation` returns a note when the read is not usable — no
conversation open, nothing but our own messages on screen, the window the wrong
size. Every one of those still produces a *plausible* transcript, and a model
handed a plausible-but-wrong transcript writes a plausible-but-wrong reply. So a
note stops the draft rather than annotating it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client                                    # noqa: E402
import transcript as T                           # noqa: E402

# How many bubbles of history the model is shown, most recent last.
MAX_TURNS = 12

SYSTEM = (
    "You are {persona}. You are writing the creator's next message in a private "
    "chat with a fan who pays for her attention.\n"
    "\n"
    "Write ONLY that next message. Rules:\n"
    "- One or two short lines. Chat, not prose.\n"
    "- Lowercase, casual, the way people actually type in DMs.\n"
    "- No quotation marks, no asterisks, no stage directions, no narration.\n"
    "- Do not restate what he said. Move it forward.\n"
    "- Never mention being an AI and never break character.\n"
    "- Reply to the LAST thing he said."
)

# Models like to wrap a reply in quotes, prefix it with "Sure!", or add a stage
# direction in asterisks, no matter how the prompt is worded. Stripping is more
# reliable than asking again, and it is cheap.
_LEAD = re.compile(r"^\s*(sure|certainly|here(?:'s| is)[^:]*|reply|response)\s*[:,-]\s*",
                   re.I)
_ACTION = re.compile(r"\*[^*]*\*")


def clean(text: str) -> str:
    """Take off the wrapper the model puts round the thing you asked for."""
    t = text.strip()
    t = _LEAD.sub("", t)
    t = _ACTION.sub("", t)
    t = t.strip()
    # Matched quotes round the whole reply, single or double, straight or curly.
    for a, b in (('"', '"'), ("'", "'"), ("“", "”"), ("‘", "’")):
        if len(t) > 1 and t.startswith(a) and t.endswith(b):
            t = t[1:-1].strip()
    return t.strip()


def build_messages(turns: list[T.Turn], persona: str) -> list[dict]:
    """The prompt, exactly as sent."""
    recent = turns[-MAX_TURNS:]
    convo = T.as_prompt_text(recent)
    return [
        {"role": "system", "content": SYSTEM.format(persona=persona)},
        {"role": "user",
         "content": f"The conversation so far:\n\n{convo}\n\n"
                    f"Write her next message."},
    ]


def drafts(turns: list[T.Turn], count: int | None = None) -> tuple[list[str], str]:
    """`count` alternative replies for this conversation. Returns (replies, error).

    Each is its own request rather than one request asked for a numbered list.
    A list comes back as a list — the model writes three variations on one idea
    and numbers them — whereas separate samples at this temperature genuinely
    diverge. It costs three round trips, which at ~0.3s warm is not a reason to
    prefer the worse output.
    """
    persona = client.get("Draft", "Persona",
                         "a flirty, playful adult creator talking to a paying fan")
    n = count or client.get_int("Draft", "Count", 3)
    temp = client.get_float("Draft", "Temperature", 0.9)
    maxtok = client.get_int("Draft", "MaxTokens", 80)
    messages = build_messages(turns, persona)

    out, err = [], ""
    for _ in range(max(1, n)):
        text, e = client.chat(messages, temperature=temp, max_tokens=maxtok)
        if e:
            err = e
            break
        got = clean(text)
        if got and got not in out:
            out.append(got)
    return out, ("" if out else err)


def draft_from_screen(force: bool = False):
    """The whole feature: read the screen, offer replies.

    Returns (turns, replies, problem). `problem` non-empty means nothing was
    drafted and the reason is worth showing.
    """
    try:
        turns, note = T.read_conversation(force=force)
    except Exception as e:
        return [], [], str(e)
    if note:
        return turns, [], note
    replies, err = drafts(turns)
    return turns, replies, err


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    T.A.set_dpi_aware()

    if "--image" in sys.argv:
        img = sys.argv[sys.argv.index("--image") + 1]
        turns, note = T.read_image(img), None
        print(f"[offline] {img}")
        replies, problem = drafts(turns)
        problem = problem or ""
    else:
        turns, replies, problem = draft_from_screen(force="--force" in sys.argv)

    print("--- what it read ---")
    print(T.as_prompt_text(turns) if turns else "(nothing)")
    if problem:
        print(f"\n!! {problem}")
    else:
        print(f"\n--- {len(replies)} draft(s) ---")
        for i, r in enumerate(replies, 1):
            print(f"  {i}. {r}")
