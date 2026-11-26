"""
TestFlow Arena — both sides are AI, you step in anywhere.

The AI fan (ai.fan_reply, a persona from personas.json) plays against her AI
(the co-chatter, suggest.py mode co, or the older agent, ai.her_reply). Press
Play and they take turns; at any point you can:

    type as either of them      your line goes in, the other side answers it
    edit any message            and replay from there (what came after is cut)
    re-roll an AI message       the same side writes that turn again
    cut after a message         rewind the chat to that point
    restore a cut               the cut-away tail comes back, the current one
                                is cut instead, so no branch is ever lost
    fork                        a new match from this point, to compare
    send a PPV as her           he decides, in character, whether to buy

Bundles and prices are the chatter's (docs/chatting-agent-spec): with the
co-chatter, PPVs are sent by you; set "next PPV" and she sets it up first.

State is userdata/testflow/arena.json, separate from TestFlow's state.json, so
the Arena and TestFlow can run side by side. Every edit, re-roll, cut and
thumb goes to userdata/testflow/arena.jsonl with the chat before it: an edit
is a better/worse pair, the same as TestFlow's rewrites.

Like TestFlow, nothing here reaches typelog or the corpus, and the window
title never contains "Infloww Messages", so MMA's screen readers ignore it.
"""
from __future__ import annotations

import json
import os
import random
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import ai

HERE = Path(__file__).resolve().parent
UI = HERE / "ui"
DATA = ai.MMA_ROOT / "userdata" / "testflow"
STATE_FILE = DATA / "arena.json"
LOG = DATA / "arena.jsonl"

ENGINES = ("co", "agent")          # her side: the co-chatter, or nextmove + suggest
FIRST_NAMES = ["Steven Martin", "Adrian Crawley", "Jason Holmes", "Daniel Price",
               "Tom Becker", "Ryan Walsh", "Chris Doyle", "Mike Majerus"]

_lock = threading.RLock()


def _now() -> float:
    return time.time()


def _id() -> str:
    return uuid.uuid4().hex[:10]


def voices() -> list[dict]:
    """The persona cards her co-chatter can speak as: [{account, name}]. A
    model's card by its first account code (AW), a category card by its name
    (basic, latina): both are what suggest.load_persona matches. Categories
    first, basic at the top, since most chatting should sound like it."""
    cards = ai.S.persona_cards()
    cat = [c for c in cards if not c["codes"]]
    cat.sort(key=lambda c: c["key"] != ai.S.DEFAULT_PERSONA)
    return ([{"account": c["key"], "name": f"{c['name']} (category)"} for c in cat]
            + [{"account": c["codes"][0], "name": c["name"]} for c in cards if c["codes"]])


class State:
    def __init__(self):
        self.version = 1
        self.data = {"active": "", "matches": {}, "delay": 1.0, "max_turns": 30}
        # playing: match id on autoplay ("" = paused). busy: "fan"/"her" while
        # a model writes. turns: AI turns since Play, for max_turns.
        self.runtime = {"playing": "", "busy": "", "error": "", "status": "", "turns": 0}
        try:
            saved = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            self.data.update({k: v for k, v in saved.items() if k in self.data})
        except (OSError, ValueError):
            pass

    def save(self):
        DATA.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, STATE_FILE)

    def changed(self, persist: bool = True):
        self.version += 1
        if persist:
            self.save()

    def match(self, mid: str = "") -> dict | None:
        return self.data["matches"].get(mid or self.data["active"])

    def snapshot(self) -> dict:
        return {"version": self.version, **self.data, **self.runtime,
                "tiers": ai.TIERS, "engines": ENGINES}


S = State()


def log(rec: dict):
    DATA.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": _now(), **rec}, ensure_ascii=False) + "\n")


def _new_match(req: dict) -> dict:
    persona = req.get("persona") or "regular"
    if persona == "random":
        persona = random.choice([p["id"] for p in ai.personas()])
    engine = req.get("engine") if req.get("engine") in ENGINES else "co"
    return {"id": _id(), "created": _now(), "rev": 0,
            "fan": {"name": (req.get("name") or "").strip() or random.choice(FIRST_NAMES),
                    "persona": persona, "model": req.get("fan_model", "")},
            "her": {"engine": engine, "account": req.get("account", ""),
                    "model": req.get("her_model", "")},
            "tier": 0, "next_ppv": (req.get("next_ppv") or "").strip(), "direction": "",
            "messages": [], "cuts": [], "parent": req.get("parent", "")}


def _transcript(match: dict, upto: int | None = None) -> str:
    """The chat as ai.chat_text writes it, for log lines."""
    msgs = [m for m in match["messages"][:upto] if m.get("kind") != "handoff"]
    return ai.chat_text({"messages": msgs}, last=10**9)


def _ai_chat(match: dict) -> dict:
    """The match in the shape ai.py's fan and agent take (TestFlow's chat).
    Handoff markers are the Arena's, not part of the conversation."""
    return {"fan": match["fan"], "tier": match["tier"],
            "messages": [m for m in match["messages"] if m.get("kind") != "handoff"]}


def _turns(match: dict) -> list:
    """The match as suggest.py Turns. A PPV carries its price and whether he
    bought it, which is what the co-chatter's PAYOFF/UNOPENED moves read."""
    out = []
    for m in match["messages"]:
        if m.get("kind") == "handoff":
            continue
        who = "fan" if m["who"] == "fan" else "model"
        if m.get("kind") == "ppv":
            p = m["ppv"]
            out.append(ai.T.Turn(who=who, text=m.get("text", ""), box=(0, 0, 0, 0),
                                 price=str(p.get("price", "")), paid=bool(p.get("paid"))))
        elif m.get("text"):
            out.append(ai.T.Turn(who=who, text=m["text"], box=(0, 0, 0, 0)))
    return out


def add(match: dict, who: str, text: str, by: str, **extra) -> dict:
    m = {"id": _id(), "who": who, "text": text, "ts": _now(), "by": by,
         "kind": extra.pop("kind", "text"), **extra}
    match["messages"].append(m)
    return m


def _touch(match: dict):
    """A change by you: anything a model is writing right now was written for
    the chat as it was, and is dropped when it lands."""
    match["rev"] = match.get("rev", 0) + 1


def _cut(match: dict, at: int, reason: str):
    """Keep messages[:at]; the rest is saved as a cut, never thrown away."""
    tail = match["messages"][at:]
    if tail:
        match["cuts"].append({"id": _id(), "at": at, "ts": _now(), "reason": reason,
                              "messages": tail})
        log({"kind": "cut", "match": match["id"], "reason": reason, "at": at,
             "chat": _transcript(match, at), "cut": ai.chat_text({"messages": tail}, last=10**9)})
    match["messages"] = match["messages"][:at]


# ── the two players ──────────────────────────────────────────────────────────
def _fan_turn(match: dict) -> tuple[list[dict], str]:
    """His next message(s), and a PPV decision on her open one. ([], error)."""
    snap = json.loads(json.dumps(_ai_chat(match)))
    text, bought, err, ctx = ai.fan_reply(snap, match["fan"].get("model", ""))
    if err:
        return [], err
    lines = [l for l in text.splitlines() if l.strip()] or ([text] if text else [])
    rid = _id()
    model = match["fan"].get("model") or ai.client.model()
    return ([{"who": "fan", "text": l, "by": "ai", "reply": rid, "model": model,
              **({"context": ctx, "bought": bought} if i == 0 else {})}
             for i, l in enumerate(lines)], "")


def _her_co(match: dict) -> tuple[list[dict], str]:
    model = match["her"].get("model", "")
    with ai._gpu:
        ai.client.MODEL_OVERRIDE = model
        try:
            out, err = ai.S.suggest(_turns(match), "co", int(match["tier"]),
                                    match.get("next_ppv", ""), match.get("direction", ""),
                                    1, match["her"].get("account", ""))
            send = list(getattr(ai.S.suggest, "send", out))
            notes = list(getattr(ai.S.suggest, "notes", [[]]))
            hand = list(getattr(ai.S.suggest, "handoff", [""]))
            flags = list(getattr(ai.S.suggest, "flags", [[]]))
            ctxs = list(getattr(ai.S.suggest, "contexts", [None]))
        finally:
            ai.client.MODEL_OVERRIDE = ""
    if not out:
        return [], err or "the model returned nothing"
    meta = {"engine": "co", "model": model or ai.client.model(),
            "notes": notes[0] if notes else [], "flags": flags[0] if flags else []}
    if hand and hand[0]:
        return [{"who": "her", "text": hand[0], "by": "ai", "kind": "handoff", **meta,
                 "context": ctxs[0] if ctxs else None}], ""
    rid = _id()
    lines = [l for l in send[0].splitlines() if l.strip()]
    return ([{"who": "her", "text": l, "by": "ai", "reply": rid, **meta,
              **({"context": ctxs[0]} if i == 0 and ctxs else {})}
             for i, l in enumerate(lines)], "")


def _her_agent(match: dict) -> tuple[list[dict], str]:
    model = match["her"].get("model") or ai.client.model()
    r = ai.her_reply(json.loads(json.dumps(_ai_chat(match))), model)
    meta = {"engine": "agent", "model": model, "flags": r.get("flags", []),
            "read": (r.get("read") or {})}
    if not r["text"]:
        if r["error"].startswith("she'd hand"):
            return [{"who": "her", "text": r["error"].split(": ", 1)[-1], "by": "ai",
                     "kind": "handoff", **meta}], ""
        return [], r["error"] or "no reply"
    rid = _id()
    lines = [l for l in r["text"].splitlines() if l.strip()]
    out = []
    if r.get("ppv"):
        out.append({"who": "her", "text": lines[0], "by": "ai", "reply": rid, "kind": "ppv",
                    "ppv": {**r["ppv"], "paid": False, "decided": False}, **meta,
                    "context": r.get("context")})
        lines = lines[1:]
    for i, l in enumerate(lines):
        out.append({"who": "her", "text": l, "by": "ai", "reply": rid, **meta,
                    **({"context": r.get("context")} if i == 0 and not out else {})})
    return out, ""


def turn(mid: str, who: str) -> bool:
    """One AI turn for `who` in match `mid`. True if something was added."""
    with _lock:
        match = S.match(mid)
        if not match or S.runtime["busy"]:
            return False
        S.runtime["busy"] = who
        S.runtime["error"] = ""
        S.changed(persist=False)
        rev = match.get("rev", 0)
        snap = json.loads(json.dumps(match))
    try:
        if who == "fan":
            msgs, err = _fan_turn(snap)
        elif snap["her"]["engine"] == "agent":
            msgs, err = _her_agent(snap)
        else:
            msgs, err = _her_co(snap)
    except Exception as e:                  # a crash says so, never "typing…" forever
        msgs, err = [], f"{e.__class__.__name__}: {e}"
    with _lock:
        S.runtime["busy"] = ""
        match = S.match(mid)
        if not match:
            S.changed(persist=False)
            return False
        if match.get("rev", 0) != rev:
            # You changed the chat while it was writing: its answer was for the
            # old chat. Drop it; autoplay asks again for the new one.
            S.changed(persist=False)
            return False
        if err or not msgs:
            S.runtime["error"] = f"{who}: {err or 'nothing written'}"
            S.changed(persist=False)
            return False
        if who == "fan" and msgs[0].get("bought") is not None:
            open_ppv = next((m for m in reversed(match["messages"])
                             if m.get("kind") == "ppv" and not m["ppv"].get("decided")), None)
            if open_ppv:
                open_ppv["ppv"].update(decided=True, paid=bool(msgs[0]["bought"]))
                if open_ppv["ppv"]["paid"]:
                    match["tier"] = max(match["tier"], int(open_ppv["ppv"].get("tier", 0)))
        if who == "her":
            match["direction"] = ""        # a direction is for one reply
        for m in msgs:
            add(match, m.pop("who"), m.pop("text"), m.pop("by"), **m)
        if msgs[0].get("kind") == "handoff":
            # Her side gave this message to the chatter: stop and wait for you.
            S.runtime["playing"] = ""
            S.runtime["status"] = "her co-chatter handed this one to you"
        S.changed()
        return True


def _next_speaker(match: dict) -> str:
    real = [m for m in match["messages"] if m.get("kind") != "handoff"]
    return "her" if real and real[-1]["who"] == "fan" else "fan"


def _play_loop():
    """Autoplay: whoever did not speak last, until paused, max_turns, or a handoff."""
    while True:
        with _lock:
            mid = S.runtime["playing"]
            if not mid:
                return
            match = S.match(mid)
            if not match:
                S.runtime["playing"] = ""
                S.changed(persist=False)
                return
            if S.runtime["turns"] >= int(S.data["max_turns"]):
                S.runtime["playing"] = ""
                S.runtime["status"] = f"paused after {S.data['max_turns']} turns"
                S.changed(persist=False)
                return
            who = _next_speaker(match)
        if turn(mid, who):
            with _lock:
                S.runtime["turns"] += 1
        else:
            with _lock:
                if S.runtime["error"]:
                    S.runtime["playing"] = ""
                    S.changed(persist=False)
                    return
        time.sleep(max(0.2, float(S.data["delay"])))


def _start_play(mid: str):
    with _lock:
        was = S.runtime["playing"]
        S.runtime.update(playing=mid, turns=0, status="", error="")
        S.changed(persist=False)
    if not was:
        threading.Thread(target=_play_loop, daemon=True).start()


# ── the API ──────────────────────────────────────────────────────────────────
def _find(match: dict, msg_id: str) -> int:
    for i, m in enumerate(match["messages"]):
        if m["id"] == msg_id:
            return i
    raise KeyError("no such message")


def r_new(req):
    with _lock:
        m = _new_match(req)
        opener = (req.get("opener") or "cold")
        if opener == "welcome":
            add(m, "her", (req.get("welcome") or "hi (with bad intentions) 😈").strip(), "auto")
        elif opener == "mass":
            text = (req.get("mass") or "").strip() or ai.archive_mass()
            if text:
                add(m, "her", text, "mass")
        S.data["matches"][m["id"]] = m
        S.data["active"] = m["id"]
        S.changed()
        return {"id": m["id"]}


def r_select(req):
    with _lock:
        if req.get("id") in S.data["matches"]:
            S.data["active"] = req["id"]
            S.changed()


def r_update(req):
    """Match settings: fan persona/name/model, her engine/account/model, next
    PPV, a one-shot direction, tier."""
    with _lock:
        m = S.match(req.get("id", ""))
        if not m:
            return {"error": "no such match"}
        for k in ("name", "persona", "model"):
            if f"fan_{k}" in req:
                m["fan"][k] = req[f"fan_{k}"]
        for k in ("engine", "account", "model"):
            if f"her_{k}" in req:
                m["her"][k] = req[f"her_{k}"]
        for k in ("next_ppv", "direction"):
            if k in req:
                m[k] = str(req[k]).strip()
        if "tier" in req:
            m["tier"] = max(0, min(len(ai.TIERS) - 1, int(req["tier"])))
        S.changed()


def r_delete_match(req):
    with _lock:
        if S.data["matches"].pop(req.get("id", ""), None) and S.runtime["playing"] == req.get("id"):
            S.runtime["playing"] = ""
        if S.data["active"] not in S.data["matches"]:
            S.data["active"] = next(iter(S.data["matches"]), "")
        S.changed()


def r_settings(req):
    with _lock:
        if "delay" in req:
            S.data["delay"] = max(0.2, float(req["delay"]))
        if "max_turns" in req:
            S.data["max_turns"] = max(1, int(req["max_turns"]))
        S.changed()


def r_play(req):
    mid = req.get("id") or S.data["active"]
    if req.get("on", True):
        _start_play(mid)
    else:
        with _lock:
            S.runtime["playing"] = ""
            S.runtime["status"] = "paused"
            S.changed(persist=False)


def r_step(req):
    """One turn now. who: "fan" | "her" | "next" (whoever is due)."""
    mid = req.get("id") or S.data["active"]
    with _lock:
        m = S.match(mid)
        if not m:
            return {"error": "no such match"}
        who = req.get("who") if req.get("who") in ("fan", "her") else _next_speaker(m)
        if S.runtime["busy"]:
            return {"error": f"{S.runtime['busy']} is still writing"}
    threading.Thread(target=turn, args=(mid, who), daemon=True).start()


def r_send(req):
    """You, as either side. Lines become separate texts (a burst). A PPV is hers."""
    who = "fan" if req.get("who") == "fan" else "her"
    text = (req.get("text") or "").strip()
    with _lock:
        m = S.match(req.get("id", ""))
        if not m:
            return {"error": "no such match"}
        if req.get("ppv"):
            p = req["ppv"]
            add(m, "her", text, "you", kind="ppv",
                ppv={"content": (p.get("content") or "a bundle").strip(),
                     "price": str(p.get("price") or "30"), "tier": int(p.get("tier", 1)),
                     "paid": False, "decided": False})
        else:
            if not text:
                return {"error": "empty"}
            rid = _id()
            for line in [l for l in text.splitlines() if l.strip()]:
                add(m, who, line.strip(), "you", reply=rid)
        _touch(m)
        S.runtime["status"] = ""
        S.changed()


def r_edit(req):
    """Change one message. replay: cut everything after it and, if autoplay is
    on, carry on from there. An AI message keeps its original, and the pair is
    logged: what the model wrote, what you would have."""
    with _lock:
        m = S.match(req.get("id", ""))
        i = _find(m, req.get("msg", ""))
        msg = m["messages"][i]
        new = (req.get("text") or "").strip()
        if not new:
            return {"error": "empty: delete it instead"}
        if new != msg["text"]:
            log({"kind": "edit", "match": m["id"], "side": msg["who"], "author": msg["by"],
                 "engine": msg.get("engine", ""), "model": msg.get("model", ""),
                 "original": msg["text"], "edited": new, "tier": m["tier"],
                 "account": m["her"].get("account", ""), "persona": m["fan"]["persona"],
                 "chat": _transcript(m, i)})
            if msg["by"] == "ai":
                msg.setdefault("original", msg["text"])
                msg["by"] = "edit"
            msg["text"] = new
        if req.get("replay"):
            _cut(m, i + 1, "edited and replayed")
        _touch(m)
        S.changed()


def r_cut(req):
    """Rewind: keep up to and including this message."""
    with _lock:
        m = S.match(req.get("id", ""))
        _cut(m, _find(m, req.get("msg", "")) + 1, req.get("reason") or "rewound")
        _touch(m)
        S.runtime["status"] = ""
        S.changed()


def r_reroll(req):
    """Write this turn again: cut from the start of its reply (the whole burst),
    then the same side writes again."""
    with _lock:
        if S.runtime["busy"]:
            return {"error": f"{S.runtime['busy']} is still writing"}
        m = S.match(req.get("id", ""))
        i = _find(m, req.get("msg", ""))
        who = m["messages"][i]["who"]
        rid = m["messages"][i].get("reply")
        while rid and i > 0 and m["messages"][i - 1].get("reply") == rid:
            i -= 1
        _cut(m, i, "re-rolled")
        _touch(m)
        mid = m["id"]
        S.changed()
    threading.Thread(target=turn, args=(mid, who), daemon=True).start()


def r_delete(req):
    with _lock:
        m = S.match(req.get("id", ""))
        i = _find(m, req.get("msg", ""))
        gone = m["messages"].pop(i)
        m["cuts"].append({"id": _id(), "at": i, "ts": _now(), "reason": "deleted one",
                          "messages": [gone], "single": True})
        _touch(m)
        S.changed()


def r_restore(req):
    """Bring a cut back. The messages after its point are cut in its place, so
    switching between two branches is just restoring the other one."""
    with _lock:
        m = S.match(req.get("id", ""))
        c = next((x for x in m["cuts"] if x["id"] == req.get("cut")), None)
        if not c:
            return {"error": "no such cut"}
        m["cuts"].remove(c)
        at = min(c["at"], len(m["messages"]))
        if c.get("single"):
            m["messages"][at:at] = c["messages"]
        else:
            _cut(m, at, "swapped for a restored branch")
            m["messages"].extend(c["messages"])
        _touch(m)
        S.changed()


def r_fork(req):
    """A new match with this one's chat up to and including the message."""
    with _lock:
        src = S.match(req.get("id", ""))
        i = _find(src, req.get("msg", "")) + 1 if req.get("msg") else len(src["messages"])
        m = json.loads(json.dumps(src))
        m.update(id=_id(), created=_now(), rev=0, cuts=[], parent=src["id"],
                 messages=m["messages"][:i])
        S.data["matches"][m["id"]] = m
        S.data["active"] = m["id"]
        S.changed()
        return {"id": m["id"]}


def r_thumb(req):
    """👍 / 👎 (and a note) on a message, logged with the chat before it."""
    with _lock:
        m = S.match(req.get("id", ""))
        i = _find(m, req.get("msg", ""))
        msg = m["messages"][i]
        v = req.get("value")
        msg["thumb"] = v if v in ("up", "down") else ""
        if req.get("note") is not None:
            msg["note"] = str(req["note"]).strip()
        log({"kind": "thumb", "match": m["id"], "side": msg["who"], "author": msg["by"],
             "engine": msg.get("engine", ""), "model": msg.get("model", ""),
             "text": msg["text"], "value": msg["thumb"], "note": msg.get("note", ""),
             "tier": m["tier"], "account": m["her"].get("account", ""),
             "persona": m["fan"]["persona"], "chat": _transcript(m, i)})
        S.changed()


def r_ppv_paid(req):
    """Set his decision on a PPV by hand: paid true/false, or null = undecided."""
    with _lock:
        m = S.match(req.get("id", ""))
        p = m["messages"][_find(m, req.get("msg", ""))]["ppv"]
        paid = req.get("paid")
        p.update(decided=paid is not None, paid=bool(paid))
        if paid:
            m["tier"] = max(m["tier"], int(p.get("tier", 0)))
        _touch(m)
        S.changed()


def r_clear(req):
    with _lock:
        S.runtime["error"] = ""
        S.runtime["status"] = ""
        S.changed(persist=False)


ROUTES = {"/api/new": r_new, "/api/select": r_select, "/api/update": r_update,
          "/api/match/delete": r_delete_match, "/api/settings": r_settings,
          "/api/play": r_play, "/api/step": r_step, "/api/send": r_send, "/api/edit": r_edit,
          "/api/cut": r_cut, "/api/reroll": r_reroll, "/api/delete": r_delete,
          "/api/restore": r_restore, "/api/fork": r_fork, "/api/thumb": r_thumb,
          "/api/ppv/paid": r_ppv_paid, "/api/clear": r_clear}

TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            since = 0
            if "since=" in self.path:
                try:
                    since = int(self.path.split("since=", 1)[1].split("&")[0])
                except ValueError:
                    pass
            end = _now() + 8                 # long-poll, as TestFlow does
            while S.version == since and _now() < end:
                time.sleep(0.1)
            with _lock:
                return self._json(S.snapshot())
        if path == "/api/options":
            names, err = ai.installed_models()
            return self._json({"models": names, "error": err, "default": ai.client.model(),
                               "personas": ai.personas(), "voices": voices()})
        name = {"/": "arena.html"}.get(path, path.lstrip("/"))
        f = UI / name
        try:
            f.resolve().relative_to(UI.resolve())
        except ValueError:
            return self._send(404, b"not found", "text/plain")
        if f.is_file():
            return self._send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        handler = ROUTES.get(self.path.split("?", 1)[0])
        if not handler:
            return self._json({"error": "no such route"}, 404)
        try:
            return self._json(handler(req) or {"ok": True})
        except KeyError as e:
            return self._json({"error": str(e).strip("'")}, 404)
        except Exception as e:
            return self._json({"error": f"{e.__class__.__name__}: {e}"}, 500)


def serve(port: int = 0) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd
