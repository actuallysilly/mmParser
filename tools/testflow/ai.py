"""
TestFlow — the two AI roles.

HER (you play the fan): drafts come from the SAME pipeline as the suggestion key
(src/services/llm/suggest.py): the same prompt file, the same voice examples, the
same rules checked in code and redrawn. Nothing here re-implements it, so what you
rate in TestFlow is what Ctrl+Alt+D would have offered. The only difference is
where the chat comes from: TestFlow hands over its own conversation instead of
the chat reader's OCR.

THE FAN (you play her): a prompted fan with a persona (personas.json), written by
prompts/fan.md. He answers once you stop sending: you send in pieces, the way you
do in Infloww, so he waits for a pause rather than answering every line.

Models are run one at a time (`_gpu`). Two 12B models do not fit in 16 GB of VRAM
together, so Ollama swaps them; asking for both at once would only make it thrash.
"""
from __future__ import annotations

import json
import re
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[1]
sys.path.insert(0, str(MMA_ROOT / "src" / "services" / "llm"))

import client                      # noqa: E402
import nextmove                    # noqa: E402
import suggest as S                # noqa: E402
import transcript as T             # noqa: E402

FAN_PROMPT = HERE / "prompts" / "fan.md"
PERSONAS = HERE / "personas.json"
TIERS = S.TIERS

_gpu = threading.Lock()


def personas() -> list[dict]:
    try:
        return json.loads(PERSONAS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return [{"id": "regular", "name": "Regular", "about": "an ordinary fan"}]


def persona(pid: str) -> dict:
    for p in personas():
        if p["id"] == pid:
            return p
    return personas()[0]


def installed_models() -> tuple[list[str], str]:
    """Ollama's pulled models, or ([], why not)."""
    ok, why = client.reachable()
    try:
        import urllib.request
        tags = json.loads(urllib.request.urlopen(client.host() + "/api/tags", timeout=3).read())
        names = sorted(m.get("name", "") for m in tags.get("models", []))
        return [n.removesuffix(":latest") for n in names], ("" if ok else why)
    except Exception as e:
        return [], f"Ollama is not answering on {client.host()} ({e.__class__.__name__})"


# ── turning a TestFlow chat into what the models read ────────────────────────
def turns(chat: dict) -> list[T.Turn]:
    """The chat as transcript Turns, the shape suggest.py takes. A PPV is a media
    bubble (no text) followed by its caption, which is how the chat reader sees one."""
    out = []
    for m in chat["messages"]:
        who = "fan" if m["who"] == "fan" else "model"
        if m.get("kind") == "ppv":
            out.append(T.Turn(who=who, text="", box=(0, 0, 0, 0)))
            if m.get("text"):
                out.append(T.Turn(who=who, text=m["text"], box=(0, 0, 0, 0)))
        elif m.get("text"):
            out.append(T.Turn(who=who, text=m["text"], box=(0, 0, 0, 0)))
    return out


def chat_text(chat: dict, last: int = S.MAX_TURNS) -> str:
    """The chat as the rating log stores it: one "fan:"/"her:" line per bubble."""
    lines = []
    for m in chat["messages"][-last:]:
        who = "fan" if m["who"] == "fan" else "her"
        if m.get("kind") == "ppv":
            p = m["ppv"]
            # content is "" on a real chat (Live Trainer): the reader sees the
            # price and caption, not what the bundle holds.
            lines.append(f"{who}: [PPV {p['content'] + ' ' if p['content'] else ''}${p['price']}"
                         f" {'paid' if p.get('paid') else 'not paid'}]")
        if m.get("text"):
            lines.append(f"{who}: {m['text']}")
    return "\n".join(lines)


# ── her: drafts for you to rate ──────────────────────────────────────────────
def her_drafts(chat: dict, mode: str, tier: int, content: str, direction: str,
               models: list[str], per_model: int, account: str = "") -> tuple[list[dict], str]:
    """[{model, text, flags}] from each model in turn, and the last error if any.
    `account`: TestFlow's model tab name. Co-chatter takes its voice from the
    persona card listing it (name the tab AW or JES to try one); never from
    MMA's live Infloww account."""
    ts = turns(chat)
    if not ts:
        return [], "the chat is empty: write something as the fan first"
    out, err = [], ""
    with _gpu:
        for m in models:
            client.MODEL_OVERRIDE = m
            try:
                texts, e = S.suggest(ts, mode, tier, content, direction, per_model, account)
                flags = getattr(S.suggest, "flags", [])
                ctxs = getattr(S.suggest, "contexts", [])
            finally:
                client.MODEL_OVERRIDE = ""
            if e and not texts:
                err = f"{m}: {e}"
            for i, t in enumerate(texts):
                out.append({"model": m, "text": t,
                            "flags": flags[i] if i < len(flags) else [],
                            "context": ctxs[i] if i < len(ctxs) else None})
    return out, err


# ── her: just the reply ──────────────────────────────────────────────────────
# Price per rung for a PPV the agent pitches in TestFlow (the chatting spec's
# ladder, ~30 -> 60 -> 90 -> 120 ...). Test data only: in real chats the human
# picks bundles and prices.
PPV_PRICES = [30, 60, 90, 120, 150, 169, 200, 250]


def her_reply(chat: dict, model: str, invent_ppv: bool = True) -> dict:
    """Her next message, the way a chatter works: READ the chat first
    (nextmove: interest, mood, the step), then WRITE that step with suggest.py.

    Before 2026-10-15 this skipped the read and always asked for filler
    sexting, so a "wsp" got a 20-word scene and a "what the fuck" got more
    roleplay: three 1/10 ratings. Now greetings and small talk go to chat mode
    (a text sized to his), sexting waits for build-up, and confusion backs off.

    Returns {text, error, context, read, ppv, flags}. `ppv` is set when the step was a
    pitch ({content, price, tier}); `text` is then its caption. On hand_off,
    text is "" and error says why: the chatter would take this one.
    """
    out = {"text": "", "error": "", "context": None, "read": None, "ppv": None, "flags": []}
    ts = turns(chat)
    if not ts:
        out["error"] = "the chat is empty"
        return out
    tier = int(chat.get("tier", 0))
    with _gpu:
        read, err = nextmove.read(chat_text(chat), tier, model)
    if not read:
        # No read (model down, bad JSON): fall back to plain talk, which is
        # the safe default, rather than to sexting.
        read = {"step": "yap", "note": "", "error": err}
    out["read"] = read
    # invent_ppv: TestFlow's simulated chats have no vault, so a pitch takes
    # the next ladder rung. The Live Trainer passes False (real chats).
    p = nextmove.plan(read, tier, invent=invent_ppv)
    if p is None:
        out["error"] = f"she'd hand this to you: {read.get('note') or read.get('mood', '')}"
        return out
    with _gpu:
        client.MODEL_OVERRIDE = model
        try:
            texts, err = S.suggest(ts, p["mode"], p["tier"], p["content"], p["direction"], 1)
            ctxs = getattr(S.suggest, "contexts", [])
            flags = getattr(S.suggest, "flags", [])
        finally:
            client.MODEL_OVERRIDE = ""
    if not texts:
        out["error"] = err or "the model returned nothing"
        return out
    ctx = dict(ctxs[0]) if ctxs else {}
    ctx["read"] = read                      # why she wrote THIS, for the rating
    # Rules it still breaks: every draw failed and this was the least bad.
    # Shown, not hidden ("$30" and "baby boy" reached the screen unflagged).
    out.update(text=texts[0], context=ctx, flags=flags[0] if flags else [])
    if p["mode"] == "ppv":
        rung = min(tier + 1, len(S.TIERS) - 1)
        out["ppv"] = {"content": p["content"], "tier": rung,
                      "price": str(PPV_PRICES[min(rung - 1, len(PPV_PRICES) - 1)])}
    return out


# ── her agent: the read ──────────────────────────────────────────────────────
def agent_read(chat: dict, model: str) -> tuple[dict, str]:
    """nextmove.read on this chat: interest, mood, evidence, step, note."""
    with _gpu:
        return nextmove.read(chat_text(chat), int(chat.get("tier", 0)), model)


# ── the fan: his next message ────────────────────────────────────────────────
# "him: ...", "**Him:** ...", or the bare ": ..." a half-stripped label leaves.
_LABEL = re.compile(r"^\s*\**\s*((fan|him|he|user)\s*\**\s*)?:\s*\**\s*", re.I)
_DECISION = re.compile(r"^\s*\[(BUY|PASS)\]\s*", re.I)
# "[Mr. Scorpio] ..." at the start: him tagging himself. Not [BUY]/[PASS].
_NAMETAG = re.compile(r"^\s*\[(?!BUY\]|PASS\])[^\]\n]{1,30}\]\s*", re.I)
# Him writing her side: a PPV note, or her lines.
_AS_HER = re.compile(r"\[PPV\b|\(sends a PPV|^\s*\**\s*(her|she|you)\s*\**\s*:", re.I | re.M)


def _fan_system(chat: dict) -> str:
    p = persona(chat["fan"].get("persona", ""))
    text = FAN_PROMPT.read_text(encoding="utf-8")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S).strip()
    return (text.replace("{{NAME}}", chat["fan"]["name"])
                .replace("{{PERSONA}}", f"{p['name']}: {p['about']}"))


def _fan_messages(chat: dict) -> list[dict]:
    """The chat as ONE labelled transcript, then "write his next message".

    It used to pass her lines as the 'user' turns and his as the 'assistant'
    turns. mistral-nemo lost track of that and wrote HER side ("[PPV: Hi Jason,
    ready for bed?..]", "**Her:** hey Jason **You:** cant sleep"), or nothing.
    A plain transcript is what the her side uses, and it holds."""
    lines = []
    for m in chat["messages"]:
        if m["who"] == "fan":
            line = m.get("text", "")
            who = "him"
        else:
            who = "her"
            if m.get("kind") == "ppv":
                p = m["ppv"]
                line = (f"(sends a PPV: {p['content']}, ${p['price']}, "
                        f"{'you bought it' if p.get('paid') else 'locked'}) "
                        + (m.get("text") or ""))
            else:
                line = m.get("text", "")
        if line:
            lines.append(f"{who}: {line}")
    chat_txt = "\n".join(lines) or "(nothing yet: you are writing to her first)"
    return [{"role": "system", "content": _fan_system(chat)},
            {"role": "user", "content": f"CHAT SO FAR (oldest first):\n{chat_txt}\n\n"
                                        "Write HIS next message: only his words, one short line."}]


def fan_reply(chat: dict, model: str) -> tuple[str, bool | None, str, dict]:
    """(his message, bought the open PPV? or None if there was none, error,
    context). Context is what the fan model was given, saved with any rating
    of his message (the fan simulator is trained from those)."""
    open_ppv = next((m for m in reversed(chat["messages"])
                     if m.get("kind") == "ppv" and not m["ppv"].get("paid")
                     and not m["ppv"].get("decided")), None)
    msgs = _fan_messages(chat)
    ctx = {"model": model or client.model(), "temperature": 0.95, "messages": msgs,
           "persona": persona(chat["fan"].get("persona", ""))}
    # The fan model sometimes writes HER side ("[PPV: Hi Jason, ready for
    # bed?..]") or tags himself ("[Mr. Scorpio] obedient?"), copying the bracket
    # notes it is shown. Redraw those; a few tries, then keep the last.
    # And redraw an EMPTY answer: mistral-nemo returned "" for 2 of 4 draws on a
    # short chat (Arena, 2026-10-27), which stopped autoplay dead.
    for _try in range(6):
        with _gpu:
            text, err = client.chat(msgs, temperature=0.95, max_tokens=90, use_model=model)
        if err:
            return "", None, err, ctx
        text = _NAMETAG.sub("", text.strip())
        if _LABEL.sub("", _DECISION.sub("", text)).strip() and not _AS_HER.search(text):
            break
    ctx["raw"] = text
    bought = None
    d = _DECISION.match(text)
    if d:
        bought = d.group(1).upper() == "BUY"
        text = text[d.end():]
    if open_ppv is None:
        bought = None
    text = _LABEL.sub("", text).strip().strip('"').strip()
    text = "\n".join(l for l in text.splitlines() if l.strip())
    return text, bought, "", ctx


# ── openers: how a chat starts ───────────────────────────────────────────────
def archive_mass() -> str:
    """One of her real mass openers, for the "reply to a mass" opener. In
    userdata/mass_archive.txt each mass starts with a "!mma <text>" line ("!mma
    Are you a secret agent?"); what follows it are the follow-ups, which are
    not what a sub replies to. "" when the archive has none."""
    import random
    try:
        text = S.ARCHIVE.read_text(encoding="utf-8-sig")
    except OSError:
        return ""
    hooks = sorted({m.group(1).strip() for m in re.finditer(r"(?m)^!mma\s+(.+)$", text)
                    if len(m.group(1).split()) >= 2})
    return random.choice(hooks) if hooks else ""
