"""
llm/nextmove.py — the agent's read of a chat: how interested the fan is, and
what she should do next.

This is the "brain" half of the sexting writer. It does not write her message;
suggest.py does that, steered by what this returns:

    read(chat_text, tier) -> ({interest, mood, evidence, step, note}, error)

    step       what suggest.py is asked for
    tease      chat: a short flirty text, a light hint, no story yet
    sext       filler: pure roleplay that carries the story
    build      filler: one step of her mass funnel (plant, imagine, commit)
    pitch_ppv  ppv caption for the chatter's content; with none (a real chat),
               the funnel's last step instead: the PPV is the chatter's pick
    bump_ppv   filler that points him back at the PPV he hasn't opened
    yap        chat: normal talk, a text sized to his
    back_off   chat: he is confused by her last message; laugh it off, reset
    aftercare  chat: thank him for the fun

"chat" is suggest.py's texting mode (prompts/chat.md). Before 2026-10-15
every step went to filler, the sexting mode, so "wsp" got a story about
stars through a skylight; rated 1/10.
    hand_off   nothing: he is mad, weird, or asking if she's a bot, and the
               chatter takes over (Silly's rule; the agent never answers the
               bot question itself)

`chat_text` is one "fan:"/"her:" line per bubble, with a PPV written as
`[PPV <content> $<price> paid|not paid]`. TestFlow builds it from its own state
(ai.chat_text); in Infloww it will come from the chat reader.

The reply is forced into a JSON schema (Ollama `format`), so `step` is always
one of the names above.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import client
import suggest as S

PROMPT = Path(__file__).resolve().parent / "prompts" / "nextmove.md"

STEPS = {
    "tease":     "he is warming up or flirting back: a short flirty text with a light hint; no story yet",
    "build":     "he is flirty or sexual and no PPV is open: the next step of the funnel (plant, imagine, commit), ending on a question he answers yes to",
    "sext":      "keep the sexting roleplay going and carry the story forward",
    "pitch_ppv": "the build is done (he said yes to her order/dare): the PPV comes now, and the chatter attaches it",
    "bump_ppv":  "a [PPV ... not paid] is in the chat and he hasn't opened it: sext and point him back at it",
    "yap":       "talk normally, like a girl texting: greetings, small talk, his day; also the default at the start of a chat",
    "back_off":  "he is confused or put off by her last message (what, wtf, ??, huh): laugh it off and reset",
    "aftercare": "he finished or is done: thank him for the fun, warmly",
    "hand_off":  "mad, weird, asking if she's real or a bot, or talking price, discounts or which bundle to get: the chatter takes over",
}

# The direction each step hands to suggest.py, before the read's own note.
DIRECTION = {
    "tease":     "Flirty and playful. If he said what he likes about her, plant a small fantasy around it, slowly, as a hint rather than a description. Still a short text, no story. End with a question that pulls him in.",
    "build":     "Write the next step of her funnel: plant an idea, make him imagine it, or give him a small playful order. One step only, built on his words, ending on a question he answers yes to. Nothing about content or the PPV.",
    "sext":      "Carry the sexting story forward.",
    # Silly's unopened-PPV order (2026-10-15): bump -> sext -> point at it ->
    # sext -> order him to open -> give up. Her own bump on the 17th: "Look at mummy".
    "bump_ppv":  "He hasn't opened the PPV she sent. Either carry the fantasy one step and tie it to what's in it (\"why imagine when you can see it\"), or a short playful order to look. Never describe it as a product, never offer anything else or cheaper, never beg.",
    "yap":       "Talk to him normally like a girl texting. Reply to what he said, sized to his message, and lead lowkey: pick up his words and ask him something back (what brings him here, what he does, where he's from).",
    "back_off":  "He is confused by what she said last. Laugh it off in a few words and reset to normal talk. Do not repeat or explain it.",
    "aftercare": "Aftercare: he is done. Thank him warmly for the fun in a short text, no selling.",
    "pitch_ppv": "",
}

SCHEMA = {
    "type": "object",
    "properties": {
        "interest": {"type": "integer", "minimum": 1, "maximum": 5},
        "mood": {"type": "string"},
        "evidence": {"type": "string"},
        "step": {"type": "string", "enum": list(STEPS)},
        "note": {"type": "string"},
    },
    "required": ["interest", "mood", "evidence", "step", "note"],
}


def system_prompt() -> str:
    text = PROMPT.read_text(encoding="utf-8")
    text = re.sub(r"<!--.*?-->\s*", "", text, flags=re.S)
    steps = "\n".join(f"- {k}: {v}" for k, v in STEPS.items())
    return (text.replace("{{STEPS}}", steps)
                .replace("{{LADDER}}", " → ".join(S.TIERS[1:])))


def read(chat_text: str, tier: int = 0, model: str = "") -> tuple[dict, str]:
    """({interest, mood, evidence, step, note}, "") or ({}, error). Never raises."""
    if not chat_text.strip():
        return {}, "the chat is empty"
    tier = max(0, min(tier, len(S.TIERS) - 1))
    nxt = S.TIERS[tier + 1] if tier + 1 < len(S.TIERS) else S.TIERS[-1]
    user = (f"HE HAS BOUGHT UP TO: {tier} ({S.TIERS[tier]})\n"
            f"NEXT RUNG: {nxt}\n"
            f"CHAT (oldest first):\n{chat_text}\n\nRead the chat.")
    text, err = client.chat([{"role": "system", "content": system_prompt()},
                             {"role": "user", "content": user}],
                            temperature=0.3, max_tokens=200, use_model=model, fmt=SCHEMA)
    if err:
        return {}, err
    try:
        r = json.loads(text)
    except ValueError:
        return {}, "the read was not valid JSON"
    if r.get("step") not in STEPS:
        return {}, f"the read named an unknown step: {r.get('step')!r}"
    r["interest"] = max(1, min(5, int(r.get("interest") or 3)))
    for k in ("mood", "evidence", "note"):
        r[k] = str(r.get(k) or "").strip()
    return r, ""


def plan(r: dict, tier: int, content: str = "", direction: str = "",
         invent: bool = False) -> dict | None:
    """What to ask suggest.py for: {mode, tier, content, direction}, or None for
    hand_off. The chatter's own direction goes last, so it wins.
    `invent`: a pitch with no content may take the next ladder rung as its
    content. Only TestFlow's simulated chats do; on a real chat the chatter
    picks the PPV."""
    step = r.get("step")
    if step == "hand_off":
        return None
    parts = [DIRECTION.get(step, ""), r.get("note", ""), direction.strip()]
    if step == "pitch_ppv" and not content.strip() and not invent:
        # No content from the chatter: the model would invent one off the
        # ladder. On 2026-10-17 it pitched a "bikini" PPV, with a price, while
        # her real $29.69 PPV sat unopened. The PPV is the chatter's call; the
        # bot writes the funnel's last step (the order) and stops there.
        parts[0] = ("The build is done; the chatter sends the PPV next. Write the funnel's "
                    "last step: one small playful order or dare he answers yes to "
                    "(\"pull it out NOW\", \"think you could pass this test?\"). "
                    "Nothing about content or the PPV.")
        parts[1] = ""                       # the read's note names a rung to pitch
        return {"mode": "filler", "tier": tier, "content": "",
                "direction": " ".join(p for p in parts if p)}
    if step == "pitch_ppv":
        nxt = S.TIERS[min(tier + 1, len(S.TIERS) - 1)]
        return {"mode": "ppv", "tier": tier, "content": content.strip() or nxt,
                "direction": " ".join(p for p in parts if p)}
    # Talking, not sexting: suggest.py's chat mode (a text sized to his).
    mode = "chat" if step in ("yap", "tease", "back_off", "aftercare") else "filler"
    return {"mode": mode, "tier": tier, "content": "",
            "direction": " ".join(p for p in parts if p)}
