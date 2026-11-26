"""
TestFlow — turn what you recorded into training data.

    python export.py            build userdata/testflow/export/ and print counts
    (or Lab ▸ Your data ▸ Export)

Reads three sources, never writes to them:
    state.json       the chats you have now (your own messages live here)
    archive/*.json   chats you deleted (deleting never loses data)
    ratings.jsonl    every annotation and review, newest wins per message

Writes, one JSON object per line. Every example carries `chat`: the
conversation BEFORE the message, as [{"who": "fan"|"her", "text": ...}].

  her_sft.jsonl       GOOD messages from her, to imitate (supervised fine-tuning)
                      source "human": a message you wrote playing her
                      source "rewrite": what you'd have sent instead of the AI
                      source "ai_8plus": an AI message you scored 8-10
  her_dpo.jsonl       PAIRS for the same moment: chosen beats rejected (DPO)
                      "rewrite>ai": your rewrite over the AI message you rated
                      "rated>rule_rejected": an AI message you scored 7+ over a
                      draft the code rejected for that same moment
  fan_sft.jsonl       the same, for the fan simulator: your fan lines (when you
  fan_dpo.jsonl       play him), your rewrites of the AI fan, AI fan 8+
  scored.jsonl        every AI message with a 1-10 score, good or bad, with its
                      tags and notes: the raw material for a reward model
  rationales.jsonl    your own messages where you said WHY you sent them
  moves.jsonl         "wrong move" verdicts: the move the AI made vs the one it
                      should have made (for the read step)
  conversations.jsonl end-of-chat reviews, each with the full annotated chat
  summary.json        the counts above

Scores are the fixed scale in ui/common.js (TF.SCALE). Thresholds here:
SFT_MIN = 8 ("good: on voice, right move"), DPO_CHOSEN_MIN = 7.
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[1]
DATA = MMA_ROOT / "userdata" / "testflow"
OUT = DATA / "export"

SFT_MIN = 8
DPO_CHOSEN_MIN = 7


def _lines(path: Path) -> list[dict]:
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for r in rows:
        try:
            out.append(json.loads(r))
        except ValueError:
            pass
    return out


def _chats() -> list[dict]:
    chats = []
    try:
        chats += list(json.loads((DATA / "state.json").read_text(encoding="utf-8"))["chats"].values())
    except (OSError, ValueError, KeyError):
        pass
    for f in sorted((DATA / "archive").glob("*.json")):
        try:
            chats.append(json.loads(f.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            pass
    return chats


def _say(m: dict) -> dict:
    """One message as the model will read it: a PPV becomes a bracket note."""
    text = m.get("text", "")
    if m.get("kind") == "ppv" and m.get("ppv"):
        p = m["ppv"]
        note = f"[PPV {p.get('content', '')} ${p.get('price', '')} {'paid' if p.get('paid') else 'not paid'}]"
        text = f"{note} {text}".strip()
    return {"who": "fan" if m.get("who") == "fan" else "her", "text": text}


def _chat_from_text(s: str) -> list[dict]:
    """Schema-1 records only kept the chat as "fan: ..."/"her: ..." lines."""
    out = []
    for line in (s or "").splitlines():
        m = re.match(r"\s*(fan|her)\s*:\s*(.*)", line)
        if m:
            out.append({"who": m[1], "text": m[2]})
    return out


def _record_chat(r: dict) -> list[dict]:
    if r.get("chat_messages") is not None:
        return [_say(m) for m in r["chat_messages"]]
    return _chat_from_text(r.get("chat", ""))


def build() -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    files: dict[str, list[dict]] = {k: [] for k in (
        "her_sft", "her_dpo", "fan_sft", "fan_dpo", "scored", "rationales", "moves",
        "conversations")}
    seen_sft: set[tuple] = set()

    def sft(who: str, chat: list[dict], text: str, source: str, meta: dict):
        key = (who, json.dumps(chat, ensure_ascii=False), text)
        if text.strip() and key not in seen_sft:
            seen_sft.add(key)
            files[f"{who}_sft"].append({"chat": chat, "reply": text, "source": source, **meta})

    # Newest annotation per message wins (a re-annotation is a newer line).
    latest: dict[str, dict] = {}
    for r in _lines(DATA / "ratings.jsonl"):
        kind = r.get("kind", "draft")
        if kind == "message":
            latest["m:" + ",".join(r["msg_ids"])] = r
        elif kind == "reply":
            latest["r:" + str(r.get("reply"))] = r
        elif kind == "conversation":
            latest["c:" + r["chat_id"]] = r

    for r in latest.values():
        kind = r.get("kind")
        meta = {"chat_id": r.get("chat_id"), "tier": r.get("tier", 0),
                "persona": (r.get("fan") or {}).get("persona") or r.get("persona", ""),
                "scenario": (r.get("scenario") or {}).get("kind", "")}
        if kind == "conversation":
            files["conversations"].append(r)
            continue
        who = r.get("speaker", "her")
        author = r.get("author", "ai")
        chat = _record_chat(r)
        text = r.get("text", "")
        score = r.get("score")
        if author == "ai" and score:
            files["scored"].append({"who": who, "chat": chat, "reply": text, "score": score,
                                    "tags": r.get("tags", []), "note": r.get("note", ""),
                                    "model": r.get("model", ""), **meta})
        if author == "ai" and r.get("rewrite"):
            sft(who, chat, r["rewrite"], "rewrite", meta)
            files[f"{who}_dpo"].append({"chat": chat, "chosen": r["rewrite"], "rejected": text,
                                        "source": "rewrite>ai", "rejected_score": score,
                                        "note": r.get("note", ""), **meta})
        if author == "ai" and score and score >= SFT_MIN:
            sft(who, chat, text, "ai_8plus", meta)
        if author == "ai" and who == "her" and score and score >= DPO_CHOSEN_MIN:
            for rej in ((r.get("context") or {}).get("rejected") or []):
                files["her_dpo"].append({"chat": chat, "chosen": text, "rejected": rej["text"],
                                         "source": "rated>rule_rejected",
                                         "rejected_problems": rej.get("problems", []), **meta})
        if r.get("should_step"):
            made = ((r.get("context") or {}).get("read") or {}).get("step", "")
            files["moves"].append({"chat": chat, "reply": text, "made": made,
                                   "should": r["should_step"], "note": r.get("note", ""), **meta})
        if author in ("human", "human-edit") and r.get("rationale"):
            files["rationales"].append({"who": who, "chat": chat, "reply": text,
                                        "why": r["rationale"], **meta})

    # Your own messages are gold whether or not you annotated them.
    for c in _chats():
        sc = (c.get("scenario") or {}).get("kind", "")
        for i, m in enumerate(c.get("messages", [])):
            if m.get("by", "user") != "user" or not m.get("text", "").strip():
                continue
            who = "fan" if m["who"] == "fan" else "her"
            chat = [_say(x) for x in c["messages"][:i]]
            sft(who, chat, m["text"], "human",
                {"chat_id": c["id"], "tier": c.get("tier", 0),
                 "persona": c["fan"].get("persona", ""), "scenario": sc})

    counts = {}
    for name, rows in files.items():
        with (OUT / f"{name}.jsonl").open("w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        counts[name] = len(rows)
    summary = {"built": time.strftime("%Y-%m-%d %H:%M:%S"), "dir": str(OUT), "counts": counts}
    (OUT / "summary.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    return summary


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    s = build()
    print(f"wrote {s['dir']}")
    for k, v in s["counts"].items():
        print(f"  {k:<14} {v}")
