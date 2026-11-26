"""
TestFlow — the local server both windows talk to.

Plain http.server on 127.0.0.1, a random port, nothing reachable from outside
the PC. It serves ui/ and a small JSON API, and holds the one copy of the state:
the clone window and the Lab window are two views of it, and each polls
/api/state for changes (a version number makes an unchanged poll nearly free).

Everything TestFlow records goes to userdata/testflow/, never to typelog or the
corpus. Test chats are written by an AI or by you pretending, and a fan line an
AI wrote must never end up training autoword.

    state.json      chats and settings, rewritten on every change
    ratings.jsonl   one line per annotation, append-only; a re-annotation is
                    a newer line for the same messages, and the newest wins.
                    kind "message" (schema 2): one message, rated/rewritten/
                    explained; kind "conversation": an end-of-chat review with
                    the full transcript. Older kinds: "reply" (schema 1),
                    "draft"/"read" (Advanced: blind drafts).
    archive/        a deleted chat, whole, so deleting never loses data
    export/         training files built by export.py (see its docstring)

TestFlow is an AI-training tool (2026-10-16). Both roles train something:
    role "fan"  you play the fan, the AI plays her: rate and rewrite HER
    role "her"  you play her, the AI plays the fan: your messages are gold
                examples of chatting; rate and rewrite HIM (the fan simulator)
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
# The shared Infloww clone (tools/inflowwclone), served at /ic/. The clone page
# is drawn by it; ui/ keeps TestFlow's own overlays and the Lab.
IC_DIR = HERE.parent / "inflowwclone"
DATA = ai.MMA_ROOT / "userdata" / "testflow"
STATE_FILE = DATA / "state.json"
RATINGS = DATA / "ratings.jsonl"
ARCHIVE = DATA / "archive"
SCHEMA = 2

# How a chat starts (Lab ▸ Start a chat).
SCENARIOS = ("cold", "welcome", "mass", "random")
DEFAULT_WELCOME = "hi (with bad intentions) 😈"

FIRST_NAMES = ["Steven Martin", "Adrian Crawley", "Mike Majerus", "Jason Holmes",
               "Mr. Scorpio", "Daniel Price", "Tom Becker", "Ryan Walsh", "Chris Doyle"]

_lock = threading.RLock()


def _now() -> float:
    return time.time()


def _id() -> str:
    return uuid.uuid4().hex[:10]


def _new_chat(name: str = "", persona: str = "regular", scenario: dict | None = None) -> dict:
    name = name.strip() or random.choice(FIRST_NAMES)
    handle = "@u" + str(random.randint(10**8, 10**9 - 1))
    return {"id": _id(), "fan": {"name": name, "handle": handle, "persona": persona},
            "tier": 0, "messages": [], "created": _now(), "unread": 0,
            "scenario": scenario or {"kind": "cold"}, "ended": False}


class State:
    def __init__(self):
        self.version = 1
        self.data = {
            "role": "fan",                 # who YOU are playing: "fan" or "her"
            "welcome_text": DEFAULT_WELCOME,  # the new-subscriber auto message
            "account": "TestFlow",         # the name on the model tab
            "auto_fan": True,              # the AI fan answers on his own
            "fan_delay": 4.0,              # seconds of quiet from her before he answers
            "fan_model": "",               # "" = llm.ini's model
            "auto_agent": False,           # I'm the fan: ask her agent once I go quiet
            "auto_her": True,              # I'm the fan: she just replies, no drafts
            "her_delay": 3.0,              # seconds of quiet from him before she does
            "her_model": "",               # "" = llm.ini's model (artemis since 2026-10-27)
            "agent_req": {},               # the Lab's last draft settings, for auto
            "active": "",
            "chats": {},
        }
        self.runtime = {"typing": "", "busy": "", "error": "", "drafts": None,
                        "review": ""}         # chat id whose review form is open
        self._load()
        if not self.data["chats"]:
            c = _new_chat()
            self.data["chats"][c["id"]] = c
            self.data["active"] = c["id"]

    # -- persistence --------------------------------------------------------
    def _load(self):
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

    # -- views --------------------------------------------------------------
    def chat(self, cid: str = "") -> dict | None:
        return self.data["chats"].get(cid or self.data["active"])

    def snapshot(self) -> dict:
        return {"version": self.version, **self.data, **self.runtime,
                "tiers": ai.TIERS, "steps": ai.nextmove.STEPS}


S = State()


# ── actions ──────────────────────────────────────────────────────────────────
def add_message(chat: dict, who: str, text: str = "", by: str = "user", **extra) -> dict:
    m = {"id": _id(), "who": who, "text": text, "ts": _now(), "by": by,
         "kind": extra.pop("kind", "text"), **extra}
    chat["messages"].append(m)
    if who == "fan" and chat["id"] != S.data["active"]:
        chat["unread"] = chat.get("unread", 0) + 1
    return m


def log_rating(rec: dict):
    DATA.mkdir(parents=True, exist_ok=True)
    with RATINGS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# The fan answers once she has gone quiet for fan_delay seconds, not after every
# line: one watcher per chat, restarted by each of her messages.
_fan_due: dict[str, float] = {}


def schedule_fan(cid: str):
    if not S.data["auto_fan"]:
        return
    with _lock:
        first = cid not in _fan_due
        _fan_due[cid] = _now() + float(S.data["fan_delay"]) + random.uniform(0, 2)
    if first:
        threading.Thread(target=_fan_watch, args=(cid,), daemon=True).start()


def _fan_watch(cid: str):
    while True:
        with _lock:
            due = _fan_due.get(cid)
            if due is None:
                return
            if _now() >= due:
                del _fan_due[cid]
                break
        time.sleep(0.2)
    fan_reply_now(cid)


def fan_reply_now(cid: str):
    with _lock:
        chat = S.chat(cid)
        if not chat:
            return
        S.runtime["typing"] = cid
        S.changed(persist=False)
        snapshot = json.loads(json.dumps(chat))
    text, bought, err, ctx = ai.fan_reply(snapshot, S.data["fan_model"])
    with _lock:
        S.runtime["typing"] = ""
        chat = S.chat(cid)
        if err or not chat:
            S.runtime["error"] = f"fan: {err}" if err else ""
            S.changed(persist=False)
            return
        S.runtime["error"] = ""
        open_ppv = next((m for m in reversed(chat["messages"])
                         if m.get("kind") == "ppv" and not m["ppv"].get("decided")), None)
        if open_ppv is not None and bought is not None:
            open_ppv["ppv"]["decided"] = True
            open_ppv["ppv"]["paid"] = bool(bought)
            if bought:
                chat["tier"] = max(chat.get("tier", 0), int(open_ppv["ppv"].get("tier", 0)))
        rid = _id()
        for i, line in enumerate([l for l in text.splitlines() if l.strip()] or [text]):
            extra = {"context": ctx} if i == 0 else {}
            add_message(chat, "fan", line, by="ai", reply=rid,
                        model=S.data["fan_model"] or ai.client.model(), **extra)
        S.changed()


# I'm the fan, plain: the AI fan's rule the other way round. You type as him,
# she waits for the quiet and her reply goes straight into the chat. No read,
# no drafts, nothing to rate — just the conversation.
_her_due: dict[str, float] = {}


def schedule_her(cid: str):
    with _lock:
        first = cid not in _her_due
        _her_due[cid] = _now() + float(S.data["her_delay"])
    if first:
        threading.Thread(target=_her_watch, args=(cid,), daemon=True).start()


def _her_watch(cid: str):
    while True:
        with _lock:
            due = _her_due.get(cid)
            if due is None:
                return
            if _now() >= due:
                del _her_due[cid]
                break
        time.sleep(0.2)
    her_reply_now(cid)


def her_reply_now(cid: str):
    with _lock:
        chat = S.chat(cid)
        if not chat:
            return
        S.runtime["typing"] = cid
        S.changed(persist=False)
        snapshot = json.loads(json.dumps(chat))
    model = S.data["her_model"] or ai.client.model()
    try:
        r = ai.her_reply(snapshot, model)
    except Exception as e:
        r = {"text": "", "error": f"{e.__class__.__name__}: {e}"}
    text, err, ctx, ppv = r["text"], r["error"], r.get("context"), r.get("ppv")
    with _lock:
        S.runtime["typing"] = ""
        chat = S.chat(cid)
        if err or not text or not chat:
            S.runtime["error"] = f"her: {err or 'no reply'}"
            S.changed(persist=False)
            return
        S.runtime["error"] = ""
        rid = _id()                         # one reply = one rating, however many lines
        lines = [l for l in text.splitlines() if l.strip()] or [text]
        if ppv:
            # A pitch is a locked PPV with its caption, then the question as
            # its own text: how the AI fan and the chat reader expect one.
            add_message(chat, "her", lines[0], by="ai", model=model, reply=rid,
                        kind="ppv", context=ctx,
                        ppv={**ppv, "paid": False, "decided": False})
            lines, ctx = lines[1:], None
        for i, line in enumerate(lines):
            extra = {"context": ctx} if i == 0 and ctx else {}   # once per reply
            add_message(chat, "her", line, by="ai", model=model, reply=rid, **extra)
        S.changed()


# I'm the fan, with the agent on: the same pause rule as the AI fan, the other way
# round. You send in pieces; the agent waits for the quiet, then reads and
# drafts with the Lab's last settings, mode forced to the agent.
_agent_due: dict[str, float] = {}


def schedule_agent(cid: str):
    with _lock:
        first = cid not in _agent_due
        _agent_due[cid] = _now() + float(S.data["fan_delay"])
    if first:
        threading.Thread(target=_agent_watch, args=(cid,), daemon=True).start()


def _agent_watch(cid: str):
    while True:
        with _lock:
            due = _agent_due.get(cid)
            if due is None:
                return
            if _now() >= due:
                del _agent_due[cid]
                break
        time.sleep(0.2)
    with _lock:
        if S.runtime["busy"] or S.data["active"] != cid:
            return
        S.runtime["busy"] = "drafting"     # claimed here, so a click can't race it
    run_drafts({**S.data.get("agent_req", {}), "mode": "agent"})


def run_drafts(req: dict):
    """make_drafts, but a crash says so instead of leaving "Drafting…" up forever."""
    try:
        make_drafts(req)
    except Exception as e:
        with _lock:
            S.runtime["busy"] = ""
            S.runtime["error"] = f"drafting failed: {e.__class__.__name__}: {e}"
            S.changed(persist=False)


def make_drafts(req: dict):
    cid = S.data["active"]
    with _lock:
        chat = S.chat(cid)
        if not chat:
            S.runtime["busy"] = ""          # the caller claimed it
            return
        S.runtime["busy"] = "drafting"
        S.runtime["drafts"] = None
        S.runtime["error"] = ""
        S.changed(persist=False)
        snapshot = json.loads(json.dumps(chat))
    mode = req.get("mode", "agent")
    tier = int(req.get("tier", snapshot.get("tier", 0)))
    content = req.get("content", "")
    direction = req.get("direction", "")
    models = req.get("models") or [ai.client.model()]
    per = max(1, min(3, int(req.get("per_model", 2))))
    # Agent: read the chat first (with the first ticked model), then draft the
    # step it picked. hand_off drafts nothing: that is the chatter's message.
    read, err = None, ""
    if mode == "agent":
        t0 = _now()
        read, err = ai.agent_read(snapshot, models[0])
        if read:
            read["model"] = models[0]
            read["ms"] = int((_now() - t0) * 1000)
            p = ai.nextmove.plan(read, tier, content, direction)
            if p is None:
                mode = "hand_off"
            else:
                mode, content, direction = p["mode"], p["content"], p["direction"]
    if mode in ("co", "filler", "ppv"):
        t0 = _now()
        drafts, derr = ai.her_drafts(snapshot, mode, tier, content, direction, models, per,
                                     S.data.get("account", ""))
        draft_ms = int((_now() - t0) * 1000)
        err = err or derr
    else:
        drafts, draft_ms = [], 0
    random.shuffle(drafts)
    run = _id()
    letters = "ABCDEFGHIJ"
    for i, d in enumerate(drafts):
        d.update({"id": _id(), "label": letters[i] if i < len(letters) else str(i + 1),
                  "rating": 0, "picked": False})
    with _lock:
        S.runtime["busy"] = ""
        S.runtime["error"] = err if not (drafts or read) else ""
        S.runtime["drafts"] = {"run": run, "chat": cid, "items": drafts, "read": read,
                               "judged": {}, "draft_ms": draft_ms,
                               "settings": {"mode": mode, "tier": tier, "content": content,
                                            "direction": direction, "models": models,
                                            "per_model": per},
                               "chat_text": ai.chat_text(snapshot, last=10**9), "revealed": False}
        S.changed(persist=False)


def _rating_record(d: dict, drafts: dict) -> dict:
    return {"ts": _now(), "run": drafts["run"], "draft": d["id"], "chat_id": drafts["chat"],
            "model": d["model"], "text": d["text"], "flags": d["flags"],
            "rating": d["rating"], "picked": d["picked"], "settings": drafts["settings"],
            "chat": drafts["chat_text"], "context": d.get("context")}


# ── HTTP ─────────────────────────────────────────────────────────────────────
TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml",
         ".png": "image/png", ".woff2": "font/woff2"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):            # quiet: pythonw has no console anyway
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
            # Long-poll up to 8 s for a change, so both windows update at once
            # without hammering the server.
            end = _now() + 8
            while S.version == since and _now() < end:
                time.sleep(0.1)
            with _lock:
                return self._json(S.snapshot())
        if path == "/api/models":
            names, err = ai.installed_models()
            return self._json({"models": names, "error": err, "default": ai.client.model()})
        if path == "/api/personas":
            return self._json(ai.personas())
        page = {"/": "clone.html", "/clone": "clone.html", "/lab": "lab.html"}.get(path)
        root = UI
        if path.startswith("/ic/"):
            root, path = IC_DIR, path[len("/ic"):]
        f = (root / page) if page else (root / path.lstrip("/"))
        try:
            f.resolve().relative_to(root.resolve())
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
        path = self.path.split("?", 1)[0]
        handler = ROUTES.get(path)
        if not handler:
            return self._json({"error": "no such route"}, 404)
        try:
            return self._json(handler(req) or {"ok": True})
        except Exception as e:
            return self._json({"error": f"{e.__class__.__name__}: {e}"}, 500)


def r_settings(req):
    with _lock:
        for k in ("role", "account", "auto_fan", "fan_delay", "fan_model", "auto_agent",
                  "auto_her", "her_delay", "her_model", "welcome_text"):
            if k in req:
                S.data[k] = req[k]
        S.changed()


def r_chat_new(req):
    """Start a chat with an opener:
        cold     nobody has written yet (as her you write first; as the fan
                 you write first; "Make him reply now" lets the AI fan open)
        welcome  a new subscriber: her automated welcome message goes first
        mass     he is replying to a mass message (req["mass"], or a random
                 one of her real ones from mass_archive.txt)
        random   one of the above, with a random persona and name
    Whoever the AI plays answers the opener on its own (after the usual pause)."""
    kind = req.get("scenario") if req.get("scenario") in SCENARIOS else "cold"
    persona = req.get("persona") or "regular"
    if kind == "random":
        kind = random.choice(["cold", "welcome", "mass"])
        persona = random.choice([p["id"] for p in ai.personas()])
    if persona == "random":
        persona = random.choice([p["id"] for p in ai.personas()])
    opener = ""
    if kind == "welcome":
        opener = (req.get("welcome") or S.data.get("welcome_text") or DEFAULT_WELCOME).strip()
    elif kind == "mass":
        opener = (req.get("mass") or "").strip() or ai.archive_mass()
        if not opener:
            return {"error": "no mass message given, and none found in mass_archive.txt"}
    with _lock:
        c = _new_chat(req.get("name", ""), persona, {"kind": kind, "opener": opener})
        if kind == "welcome":
            add_message(c, "her", opener, by="auto")
        elif kind == "mass":
            add_message(c, "her", opener, by="mass")
        S.data["chats"][c["id"]] = c
        S.data["active"] = c["id"]
        S.runtime["drafts"] = None
        S.changed()
        cid = c["id"]
    # The opener is hers, so the next message is his. If the AI plays him, he
    # answers it; if you do, the chat waits for you.
    if opener and S.data["role"] == "her":
        schedule_fan(cid)
    return {"id": cid, "scenario": kind, "persona": persona}


def r_chat_select(req):
    with _lock:
        if req.get("id") in S.data["chats"]:
            S.data["active"] = req["id"]
            S.data["chats"][req["id"]]["unread"] = 0
            S.runtime["drafts"] = None
            S.changed()


def r_chat_update(req):
    with _lock:
        c = S.chat(req.get("id", ""))
        if c:
            for k in ("name", "persona"):
                if k in req:
                    c["fan"][k] = req[k]
            if "tier" in req:
                c["tier"] = int(req["tier"])
            S.changed()


def r_chat_delete(req):
    with _lock:
        gone = S.data["chats"].pop(req.get("id", ""), None)
        if gone and gone["messages"]:
            # Deleting tidies the list; it never throws away training data.
            ARCHIVE.mkdir(parents=True, exist_ok=True)
            (ARCHIVE / f"{gone['id']}.json").write_text(
                json.dumps({**gone, "deleted": _now()}, ensure_ascii=False, indent=1),
                encoding="utf-8")
        if not S.data["chats"]:
            c = _new_chat()
            S.data["chats"][c["id"]] = c
        if S.data["active"] not in S.data["chats"]:
            S.data["active"] = next(iter(S.data["chats"]))
        S.changed()


def r_send(req):
    who = "fan" if req.get("who") == "fan" else "her"
    text = (req.get("text") or "").rstrip()
    if not text.strip():
        return {"error": "empty"}
    with _lock:
        chat = S.chat()
        if chat.get("ended"):
            return {"error": "this chat has ended and been reviewed: start a new one"}
        add_message(chat, who, text)
        S.changed()
        cid = chat["id"]
    if who == "her" and S.data["role"] == "her":
        schedule_fan(cid)
    if who == "fan" and S.data["role"] == "fan":
        # One or the other: both at once would swap two models through the GPU.
        if S.data["auto_her"]:
            schedule_her(cid)
        elif S.data["auto_agent"]:
            schedule_agent(cid)


def r_ppv(req):
    with _lock:
        chat = S.chat()
        add_message(chat, "her", (req.get("caption") or "").strip(), kind="ppv",
                    ppv={"content": req.get("content", "").strip() or "a bundle",
                         "price": req.get("price", "19.99"), "tier": int(req.get("tier", 0)),
                         "paid": False, "decided": False})
        S.changed()
        cid = chat["id"]
    if S.data["role"] == "her":
        schedule_fan(cid)


def r_fan_now(req):
    with _lock:
        cid = S.data["active"]
        _fan_due.pop(cid, None)
    threading.Thread(target=fan_reply_now, args=(cid,), daemon=True).start()


def r_her_now(req):
    with _lock:
        cid = S.data["active"]
        _her_due.pop(cid, None)
    threading.Thread(target=her_reply_now, args=(cid,), daemon=True).start()


def transcript(messages: list[dict]) -> list[dict]:
    """Messages as training data: who said it, who WROTE it, and what is known
    about it. `author`: "human" (you), "ai", "auto" (welcome message), "mass",
    or "human-edit" (your rewrite replaced the AI's message in the chat)."""
    out = []
    for m in messages:
        d = {"id": m["id"], "who": m["who"], "text": m.get("text", ""),
             "author": {"user": "human"}.get(m.get("by", "user"), m.get("by", "user")),
             "kind": m.get("kind", "text"), "ts": m["ts"]}
        for k in ("model", "ppv", "original", "ann"):
            if m.get(k):
                d[k] = m[k]
        out.append(d)
    return out


def r_annotate(req):
    """One annotation of one message (or the run of lines it was sent as).
        score        1-10 (the scale in common.js: TF.SCALE); none for your own
        tags         quick labels ("too long", "wrong move", ...)
        note         what was wrong, or right
        rewrite      what you would have sent instead
        replace      true: your rewrite takes the AI's place in the chat, so
                     the conversation carries on from a good message
        should_step  (her) the move it should have made, when the move was wrong
        rationale    (your own message) why you sent it
        skip         true: no annotation, just stop asking
    Stored on the messages (state.json) AND appended to ratings.jsonl with the
    chat before it, so the line is a complete training example on its own."""
    ids = list(req.get("ids") or [])
    with _lock:
        chat = S.chat(req.get("chat", ""))
        if not chat or not ids:
            return {"error": "no such message"}
        msgs = [m for m in chat["messages"] if m["id"] in ids]
        if not msgs:
            return {"error": "no such message"}
        first = chat["messages"].index(msgs[0])
        if req.get("skip"):
            for m in msgs:
                m["rated"] = "skipped"
            S.changed()
            return
        ann = {"ts": _now()}
        if req.get("score"):
            ann["score"] = max(1, min(10, int(req["score"])))
        for k in ("note", "rewrite", "rationale", "should_step"):
            v = (req.get(k) or "").strip()
            if v:
                ann[k] = v
        tags = [str(x) for x in (req.get("tags") or []) if str(x).strip()]
        if tags:
            ann["tags"] = tags
        author = transcript(msgs[:1])[0]["author"]
        text = "\n".join(m["text"] for m in msgs)
        replaced = bool(ann.get("rewrite") and req.get("replace") and author == "ai")
        p = ai.persona(chat["fan"].get("persona", ""))
        log_rating({"schema": SCHEMA, "kind": "message", "ts": ann["ts"],
                    "chat_id": chat["id"], "scenario": chat.get("scenario", {}),
                    "role": S.data["role"], "speaker": msgs[0]["who"], "author": author,
                    "msg_ids": [m["id"] for m in msgs], "text": text,
                    "model": msgs[0].get("model", ""), **ann, "rewrite_used": replaced,
                    "tier": chat.get("tier", 0),
                    "tier_name": ai.TIERS[int(chat.get("tier", 0))],
                    "fan": {"name": chat["fan"]["name"], "persona": p.get("id"),
                            "about": p.get("about", "")},
                    "chat": ai.chat_text({"messages": chat["messages"][:first]}, last=10**9),
                    "chat_messages": transcript(chat["messages"][:first]),
                    "context": msgs[0].get("context")})
        for m in msgs:
            m["rated"] = "yes"
        msgs[0]["ann"] = ann
        if replaced:
            # Swap the AI's lines for yours; the original and its annotation
            # stay on the first line, so nothing is lost.
            keep = {k: msgs[0][k] for k in ("model", "context", "reply") if msgs[0].get(k)}
            for m in msgs:
                chat["messages"].remove(m)
            lines = [l for l in ann["rewrite"].splitlines() if l.strip()]
            for i, line in enumerate(lines):
                m = {"id": _id(), "who": msgs[0]["who"], "text": line, "ts": msgs[0]["ts"],
                     "by": "human-edit", "kind": "text", "rated": "yes"}
                if i == 0:
                    m.update(keep, original=text, ann=ann)
                chat["messages"].insert(first + i, m)
        S.changed()


def r_review_open(req):
    with _lock:
        S.runtime["review"] = req.get("id") or S.data["active"]
        S.changed(persist=False)


def r_review(req):
    """End-of-conversation review: the whole interaction, scored and explained.
    Ends the chat (it becomes read-only) unless req["keep_open"]."""
    with _lock:
        chat = S.chat(req.get("id", ""))
        S.runtime["review"] = ""
        if req.get("cancel") or not chat:
            S.changed(persist=False)
            return
        rev = {"ts": _now()}
        for k in ("overall", "fan_realism"):
            if req.get(k):
                rev[k] = max(1, min(10, int(req[k])))
        for k in ("outcome", "best", "worst", "went_well", "went_wrong", "lesson"):
            v = (req.get(k) or "").strip()
            if v:
                rev[k] = v
        p = ai.persona(chat["fan"].get("persona", ""))
        log_rating({"schema": SCHEMA, "kind": "conversation", **rev, "chat_id": chat["id"],
                    "scenario": chat.get("scenario", {}), "role": S.data["role"],
                    "fan": {"name": chat["fan"]["name"], "persona": p.get("id"),
                            "about": p.get("about", "")},
                    "tier": chat.get("tier", 0),
                    "chat": ai.chat_text(chat, last=10**9),
                    "messages": transcript(chat["messages"])})
        chat["review"] = rev
        chat["ended"] = not req.get("keep_open")
        S.changed()


def r_export(req):
    import export
    return export.build()


def r_drafts(req):
    with _lock:
        if S.runtime["busy"]:
            return {"error": "already drafting"}
        S.runtime["busy"] = "drafting"
        S.data["agent_req"] = {k: req[k] for k in ("models", "per_model", "content", "direction")
                               if k in req}
    threading.Thread(target=run_drafts, args=(req,), daemon=True).start()


def r_rate(req):
    with _lock:
        drafts = S.runtime["drafts"]
        d = next((x for x in (drafts or {}).get("items", []) if x["id"] == req.get("id")), None)
        if not d:
            return {"error": "no such draft"}
        d["rating"] = max(0, min(5, int(req.get("rating", 0))))
        log_rating(_rating_record(d, drafts))
        S.changed(persist=False)


def r_pick(req):
    with _lock:
        drafts = S.runtime["drafts"]
        d = next((x for x in (drafts or {}).get("items", []) if x["id"] == req.get("id")), None)
        if not d:
            return {"error": "no such draft"}
        text = (req.get("text") or d["text"]).strip()
        d["picked"] = True
        d["edited"] = text != d["text"]
        drafts["revealed"] = True
        rec = _rating_record(d, drafts)
        rec["sent_text"] = text
        log_rating(rec)
        chat = S.chat(drafts["chat"])
        for line in [l for l in text.splitlines() if l.strip()]:
            add_message(chat, "her", line, by="ai", model=d["model"])
        S.changed()


def r_judge(req):
    """Your verdict on the agent's read. Fields arrive one at a time as you
    click; each click logs the whole verdict so far, and the newest line per
    run wins.
        interest   "low" | "right" | "high"   (his real interest vs its number)
        step_ok    true | false
        step       the step it should have been, when step_ok is false
        note       anything else"""
    with _lock:
        drafts = S.runtime["drafts"]
        if not drafts or not drafts.get("read"):
            return {"error": "no read to judge"}
        j = drafts["judged"]
        for k in ("interest", "step_ok", "step", "note"):
            if k in req:
                j[k] = req[k]
        if j.get("step_ok"):
            j.pop("step", None)
        log_rating({"ts": _now(), "kind": "read", "run": drafts["run"],
                    "chat_id": drafts["chat"], "read": drafts["read"], "verdict": dict(j),
                    "tier": drafts["settings"]["tier"], "chat": drafts["chat_text"]})
        S.changed(persist=False)


def r_reveal(req):
    with _lock:
        if S.runtime["drafts"]:
            S.runtime["drafts"]["revealed"] = True
            S.changed(persist=False)


def r_clear_error(req):
    with _lock:
        S.runtime["error"] = ""
        S.changed(persist=False)


def r_stats(req):
    """Average rating per model, newest rating per draft."""
    latest: dict[str, dict] = {}
    reads: dict[str, dict] = {}
    replies: dict[str, dict] = {}
    msgs: dict[str, dict] = {}
    convs: dict[str, dict] = {}
    try:
        for line in RATINGS.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            if r.get("kind") == "read":
                reads[r["run"]] = r
                continue
            if r.get("kind") == "reply":
                replies[r["reply"]] = r         # newest wins
                continue
            if r.get("kind") == "message":
                msgs[",".join(r["msg_ids"])] = r
                continue
            if r.get("kind") == "conversation":
                convs[r["chat_id"]] = r
                continue
            latest[r["draft"]] = r
    except (OSError, ValueError):
        pass
    by: dict[str, dict] = {}
    for r in latest.values():
        b = by.setdefault(r["model"], {"model": r["model"], "rated": 0, "sum": 0, "picked": 0})
        if r.get("rating"):
            b["rated"] += 1
            b["sum"] += r["rating"]
        if r.get("picked"):
            b["picked"] += 1
    rows = [{**b, "avg": round(b["sum"] / b["rated"], 2) if b["rated"] else None}
            for b in by.values()]
    v = [r["verdict"] for r in reads.values()]
    judged = [x for x in v if "step_ok" in x]
    rated = [x for x in v if "interest" in x]
    agent = {"reads": len(v),
             "step_right": sum(1 for x in judged if x["step_ok"]), "step_judged": len(judged),
             "interest_right": sum(1 for x in rated if x["interest"] == "right"),
             "interest_judged": len(rated)}
    rep: dict[tuple, list[int]] = {}
    for r in list(replies.values()) + [m for m in msgs.values() if m.get("author") == "ai"]:
        if r.get("score"):
            key = (r.get("speaker", "her"), r["model"] or "?")
            rep.setdefault(key, []).append(r["score"])
    reply_rows = [{"speaker": k[0], "model": k[1], "rated": len(s),
                   "avg": round(sum(s) / len(s), 1)} for k, s in sorted(rep.items())]
    data = {"annotated": len(replies) + len(msgs),
            "rewrites": sum(1 for m in msgs.values() if m.get("rewrite")),
            "explained": sum(1 for m in msgs.values() if m.get("rationale")),
            "reviews": len(convs)}
    return {"rows": sorted(rows, key=lambda b: -(b["avg"] or 0)), "agent": agent,
            "replies": reply_rows, "data": data,
            "file": str(RATINGS)}


ROUTES = {"/api/settings": r_settings, "/api/chat/new": r_chat_new,
          "/api/chat/select": r_chat_select, "/api/chat/update": r_chat_update,
          "/api/chat/delete": r_chat_delete, "/api/send": r_send, "/api/ppv": r_ppv,
          "/api/fan/now": r_fan_now, "/api/her/now": r_her_now, "/api/annotate": r_annotate, "/api/reply/rate": r_annotate,
          "/api/review": r_review, "/api/review/open": r_review_open, "/api/export": r_export, "/api/drafts": r_drafts, "/api/rate": r_rate,
          "/api/pick": r_pick, "/api/reveal": r_reveal, "/api/judge": r_judge, "/api/error/clear": r_clear_error,
          "/api/stats": r_stats}


def serve(port: int = 0) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd
