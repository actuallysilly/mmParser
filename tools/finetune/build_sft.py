"""
tools/finetune/build_sft.py — the co-chatter's training set, from the shift log.

Each example is one real moment, in the shape the co-chatter is asked at run
time (suggest.py mode co):

    system     prompts/cochatter.md, with the voice card for her casing
               (the Alice card for capitalised bursts, basic for the rest) and
               no {{EXAMPLES}}: the examples are what training replaces
    user       FAN: bought so far / CHAT: the last 12 bubbles before her reply
    assistant  the burst Silly actually sent next, one text per line

Kept only when the burst is Silly's own (SIGNERS), follows a fan message, has no
gap in the read before or inside it, is not a PPV, is 1-4 texts of at most 30
words, and contains no fan name, money word, meet-up, email, blocklisted
string (userdata/corpus/scrub.txt) or OCR junk. Pasted scripts mostly fall out
on the length rule, so it learns her freestyle.

Chats are split train/eval by a hash of the chat file, so no chat is in both.

    python tools/finetune/build_sft.py           -> userdata/corpus/sft/co_v1/
"""
from __future__ import annotations

import hashlib
import json
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "services" / "llm"))
sys.path.insert(0, str(ROOT / "tools" / "corpus" / "analysis"))

import suggest as S                 # noqa: E402
import transcript as T              # noqa: E402
from common import scrub_patterns, sensitive   # noqa: E402

OUT = ROOT / "userdata" / "corpus" / "sft" / "co_v1"
CONTEXT = 12
EVAL_SHARE = 0.08
# OCR debris that is not her writing: quoted-reply headers, timestamps, the
# "1/6 sophie" watermark, links.
JUNK = re.compile(r"view ?message|\b\d{1,2}:\d{2}\s?(am|pm)\b|\b\d+\s?/\s?\d+\b|https?://|www\.|"
                  r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec) \d{1,2}\b", re.I)


def system_for(caps: bool) -> str:
    """A SHORT system prompt: who she is and her card, not the whole of
    cochatter.md. The full prompt is ~1,800 tokens, which made every example
    ~2,000 tokens long and pushed a 12B QLoRA past the 16 GB card (with the
    desktop's own ~4 GB) into shared memory, where it stalled (2026-10-27).
    The adapter learns her voice and moves from the replies; at run time it
    still gets the full rulebook."""
    persona, _ = S.load_persona("AW" if caps else S.DEFAULT_PERSONA)
    return ("You are her: a confident creator texting a subscriber on her OnlyFans. "
            "Write only her next texts, one per line, the way she really texts.\n\n"
            f"WHO SHE IS\n{persona}")


def turn(d: dict) -> T.Turn:
    return T.Turn(who="fan" if d["who"] == "fan" else "model", text=d.get("text", ""),
                  box=(0, 0, 0, 0), price=str(d.get("price") or ""),
                  paid=d.get("paid") if "paid" in d else None)


def names_of(d: dict) -> set[str]:
    return {w.lower() for n in [d.get("fan", "")] + list(d.get("names", []))
            for w in re.findall(r"[A-Za-z]{3,}", n or "")}


def build():
    scrub = scrub_patterns()
    systems = {True: system_for(True), False: system_for(False)}
    train, evals, seen = [], [], set()
    drop: dict[str, int] = {}

    def no(why):
        drop[why] = drop.get(why, 0) + 1

    for f in sorted(S.SHIFTLOG_CHATS.glob("*/*.json")):
        if f.parent.name.lower() == "testflow":
            continue                                   # TestFlow is AI-written
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        ts, names = d.get("turns", []), names_of(d)
        is_eval = int(hashlib.sha1(f.name.encode()).hexdigest(), 16) % 1000 < EVAL_SHARE * 1000
        j = 1
        while j < len(ts):
            if not (ts[j].get("who") == "model" and ts[j - 1].get("who") == "fan"):
                j += 1
                continue
            k = j
            while k < len(ts) and ts[k].get("who") == "model" and not (k > j and ts[k].get("gap_before")):
                k += 1
            her, start = ts[j:k], j
            j = k
            if ts[start].get("gap_before"):
                no("gap before her reply"); continue
            if any((t.get("sender") or "").strip().lower() not in S.SIGNERS for t in her):
                no("not Silly's"); continue
            if any(t.get("price") or not t.get("text") for t in her):
                no("PPV or picture"); continue
            lines = [" ".join(t["text"].split()) for t in her]
            words = sum(len(l.split()) for l in lines)
            if len(lines) > 4 or any(len(l.split()) > 30 for l in lines) or words < 2:
                no("shape (too many / too long / too short)"); continue
            said = "\n".join(lines)
            if names & {w.lower() for w in re.findall(r"[A-Za-z]{3,}", said)}:
                no("his name"); continue
            if S._BANNED.search(said) or S._MEETUP.search(said):
                no("money word or meet-up"); continue
            if JUNK.search(said):
                no("OCR junk"); continue
            # Context: back to the last gap in the read, at most CONTEXT bubbles.
            lo = start
            while lo > 0 and start - lo < CONTEXT and not ts[lo].get("gap_before"):
                lo -= 1
            ctx = ts[lo:start]
            chat = "\n".join(S._co_line(turn(t)) for t in ctx)
            if sensitive(chat + "\n" + said, scrub):
                no("blocklist / email"); continue
            key = (ctx[-1].get("text", "").lower(), said.lower())
            if key in seen:
                no("duplicate"); continue
            seen.add(key)
            bought = sum(1 for t in ts[:start] if t.get("price") and t.get("paid"))
            fan = "nothing bought yet" if not bought else f"has bought {bought} PPV{'s' if bought > 1 else ''}"
            caps = S._caps_voice(lines)
            ex = {"system_voice": "alice" if caps else "basic",
                  "user": f"FAN: bought so far: {fan}\nCHAT:\n{chat}\n\nWrite her next texts.",
                  "assistant": said, "chat_file": f"{f.parent.name}/{f.stem[:3]}…",
                  "shift": her[0].get("shift", "")}
            (evals if is_eval else train).append(ex)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "system_alice.txt").write_text(systems[True], encoding="utf-8")
    (OUT / "system_basic.txt").write_text(systems[False], encoding="utf-8")
    for name, rows in (("train", train), ("eval", evals)):
        with (OUT / f"{name}.jsonl").open("w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    random.seed(7)
    sample = random.sample(train, min(25, len(train)))
    md = ["# co_v1 sample (25 random training examples)\n",
          "Private: real chats. Each block is what the model is shown, then (→) what it learns to write.\n"]
    for r in sample:
        md.append(f"---\n`{r['system_voice']}` · {r['user'].splitlines()[0]}\n\n```\n"
                  + r["user"].split("CHAT:\n", 1)[1].replace("\n\nWrite her next texts.", "")
                  + "\n```\n→\n```\n" + r["assistant"] + "\n```\n")
    (OUT / "sample.md").write_text("\n".join(md), encoding="utf-8")
    stats = {"train": len(train), "eval": len(evals),
             "alice_voice": sum(r["system_voice"] == "alice" for r in train + evals),
             "dropped": dict(sorted(drop.items(), key=lambda x: -x[1]))}
    (OUT / "stats.json").write_text(json.dumps(stats, indent=1), encoding="utf-8")
    print(json.dumps(stats, indent=1))


if __name__ == "__main__":
    build()
