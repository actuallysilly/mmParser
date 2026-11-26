"""
Live Trainer — the logic. No window in here, so all of it can be tested offline.

The chat reader (src/services/llm/chatreader.pyw) keeps userdata/chat_now.json
OCR'd: the turns on screen and, from the same frame, the fan's name. This
follows that file and keeps, per account + fan, the WHOLE conversation seen so
far, not just the screenful:

    every read is MERGED into the fan's saved history (merge()): the read is
    lined up against what is already known, new messages at the bottom are
    appended, older ones above (you scrolled up) are prepended, and a message
    that was cut off by the composer is replaced when it is read whole.

Then the loop, which is the point of the app:

    fan sends   -> once he pauses (FAN_PAUSE_S: fans send in pieces) the AI
                   drafts HER reply with TestFlow's pipeline (ai.her_reply:
                   nextmove reads the chat, suggest writes that step). The
                   draft is SHOWN, never typed or sent.
    you reply   -> your real message(s) are attached to that draft as
                   `actual`: the answer a chatter actually gave.
    you grade   -> 1-10 + an optional note on the draft.

Every change to a draft writes its full record to userdata/livetrainer/
ratings.jsonl (latest line per id wins): the whole chat before it, the context
it was made from, the grade and your actual reply. A graded draft with an actual
reply is a ready-made preference pair.

History lives in userdata/livetrainer/<account>/<fan>.json.
"""
from __future__ import annotations

import configparser
import difflib
import json
import re
import threading
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[1]
DATA = MMA_ROOT / "userdata" / "livetrainer"
RATINGS = DATA / "ratings.jsonl"
CHAT_NOW = MMA_ROOT / "userdata" / "chat_now.json"
ACTIVE_NOW = MMA_ROOT / "userdata" / "active_now.ini"
TESTFLOW_STATE = MMA_ROOT / "userdata" / "testflow" / "state.json"

FAN_PAUSE_S = 4.0       # quiet after his last message before drafting
SIMILAR = 0.8           # difflib ratio for "the same message, read twice"


# ── reading the shared files ─────────────────────────────────────────────────
def load_chat_now() -> dict | None:
    try:
        return json.loads(CHAT_NOW.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def account() -> str:
    """"infloww:1:AW" from what the mass engine publishes, or "?"."""
    cp = configparser.ConfigParser(interpolation=None)
    try:
        cp.read(ACTIVE_NOW, encoding="utf-8-sig")
        a = cp["active"]
        if a.get("no", "0") != "0":
            return f"{a.get('site', '?')}:{a.get('no')}:{a.get('name', '')}"
    except (KeyError, configparser.Error):
        pass
    return "?"


def default_model() -> str:
    """TestFlow's "her" model, so what you grade here is what you grade there."""
    try:
        s = json.loads(TESTFLOW_STATE.read_text(encoding="utf-8"))
        m = (s.get("settings") or s).get("her_model", "")
        if m:
            return m
    except (OSError, ValueError, AttributeError):
        pass
    return "rocinante"


# Stitching is src/services/llm/stitch.py, the one copy (2026-11-24); this file
# used to hold its own. Live Trainer keeps the STRICT fit (every overlapping
# message must agree), which is stitch.merge_exact.
import sys as _sys                                                  # noqa: E402
_sys.path.insert(0, str(MMA_ROOT / "src" / "services" / "llm"))
from stitch import slug, same, _norm, combine as _combine, DROP as _DROP, LATEST as _LATEST  # noqa: E402,F401
from stitch import merge_exact as merge                             # noqa: E402,F401


# ── one fan's session ────────────────────────────────────────────────────────
class Session:
    def __init__(self, acct: str, fan: str, handle: str = ""):
        # Keyed on his @handle when the fan recorder resolved one (chat_now.json
        # "handle"): the header name is chatter-rewritten and split one fan into
        # several files. Old name-keyed files stay where they are.
        self.account, self.fan, self.handle = acct, fan, handle
        self.path = DATA / slug(acct) / (f"@{slug(handle)}.json" if handle else f"{slug(fan)}.json")
        self.turns: list[dict] = []
        self.drafts: list[dict] = []
        self.tier = 0
        self.due = 0.0                           # when to draft; 0 = nothing pending
        try:
            d = json.loads(self.path.read_text(encoding="utf-8"))
            self.turns, self.drafts, self.tier = d["turns"], d["drafts"], d.get("tier", 0)
        except (OSError, ValueError, KeyError):
            pass

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"account": self.account, "fan": self.fan, "tier": self.tier,
                                   "turns": self.turns, "drafts": self.drafts},
                                  ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)

    def open_draft(self) -> dict | None:
        """The latest draft no reply of yours has answered yet."""
        for d in reversed(self.drafts):
            return None if d.get("actual") or d.get("superseded") else d
        return None

    def apply(self, read: list[dict]) -> str:
        """Merge a read, fire the loop's events. Returns a problem or ""."""
        self.turns, new, why = merge(self.turns, read)
        if why or not new:
            return why
        for t in new:
            if t["who"] == "fan":
                self.due = time.time() + FAN_PAUSE_S
                # He wrote again before you answered: the draft for his previous
                # message is moot, and your next reply belongs to the next one.
                d = self.open_draft()
                if d is not None:
                    d["superseded"] = True
            else:
                # You replied. That answers the open draft, and a draft not yet
                # made for this fan message is no longer wanted.
                self.due = 0.0
                d = self.open_draft() or self._replied_after_last()
                if d is not None:
                    d.setdefault("actual_turns", []).append(t["text"] or "[media]")
                    d["actual"] = "\n".join(d["actual_turns"])
                    d["actual_at"] = t["at"]
                    log_record(self, d)
        self.save()
        return ""

    def _replied_after_last(self) -> dict | None:
        """Her 2nd/3rd piece of one reply goes on the same draft as the 1st."""
        if not self.drafts:
            return None
        d = self.drafts[-1]
        after = self.turns[d["at_turn"]:]
        return d if d.get("actual") and not any(t["who"] == "fan" for t in after) else None

    def chat_before(self, n: int) -> str:
        return "\n".join(("fan: " if t["who"] == "fan" else "her: ") + (t["text"] or "[media]")
                         for t in self.turns[:n])

    def as_testflow_chat(self, n: int | None = None) -> dict:
        """The first `n` turns (all by default) as a TestFlow chat."""
        msgs = []
        for t in self.turns[:n]:
            if t["who"] == "fan":
                if t["text"]:
                    msgs.append({"who": "fan", "text": t["text"]})
                continue
            m = her_message(t["text"])
            if m.get("kind") == "ppv" and self._ppv_seen_before(msgs, m):
                continue
            msgs.append(m)
        return {"messages": msgs, "tier": self.tier}

    @staticmethod
    def _ppv_seen_before(msgs: list[dict], ppv: dict) -> bool:
        """The bubble is often read first without its price line: watermark as
        one turn, caption as another, and his reply after. That earlier caption
        is where the PPV really was, so it becomes the PPV there (its watermark
        "[media]" goes) and this later copy is dropped. True if so."""
        cap = _norm(ppv["text"])
        for i in range(len(msgs) - 1, max(-1, len(msgs) - 6), -1):
            m = msgs[i]
            if m["who"] == "her" and m.get("kind") != "ppv" and _norm(m["text"]) \
                    and m["text"] != "[media]" and _norm(m["text"]) in cap:
                msgs[i] = ppv
                if i and msgs[i - 1] == {"who": "her", "text": "[media]"}:
                    del msgs[i - 1]
                return True
        return False


# What the chat reader makes of a PPV bubble, read 2026-10-17 on a real chat:
#   "AliceDoubleYew,Oct 173:10 AM Mummy really likes ... $29.69 View message"
# and of the media thumbnail's watermark: "1 /8.3 DnlyFans.con/alicedoubleyew",
# "8·1/3 Onlyh cott". Passed on as plain text, the model never knew a PPV was
# open: it invented a "bikini" one and pitched it for $30 over the real one.
_PPV_PRICE = re.compile(r"\$\s?(\d{1,4}(?:[.,]\d{2})?)\s*View\s*message", re.I)
_PPV_HEADER = re.compile(r"^\S+,\s*[A-Z][a-z]{2}\s*\d{1,2}\s*\d{1,2}:\d{2}\s*[AP]M\s*")
_WATERMARK = re.compile(r"[o0d]nly\s*[fh]|fans\s*\.\s*co", re.I)


def her_message(text: str) -> dict:
    """One of her turns as a TestFlow message: text, [media], or a PPV."""
    if not text:
        return {"who": "her", "text": "[media]"}
    p = _PPV_PRICE.search(text)
    if p:
        caption = _PPV_HEADER.sub("", text[:p.start()]).strip()
        # Infloww's own wording for a paid PPV isn't known yet; "not paid" is
        # the safe read (it gets bumped, not followed by a second pitch).
        paid = bool(re.search(r"\b(?<!un)paid\b|purchased", text[p.end():], re.I))
        return {"who": "her", "kind": "ppv", "text": caption,
                "ppv": {"content": "", "price": p.group(1).replace(",", "."), "paid": paid}}
    if _WATERMARK.search(text) and len(text.split()) <= 6:
        return {"who": "her", "text": "[media]"}
    return {"who": "her", "text": text}


def log_record(s: Session, d: dict) -> None:
    """The draft's full, self-standing record. Latest line per id wins."""
    rec = {"kind": "live_draft", "id": d["id"], "logged": time.time(),
           "account": s.account, "fan": s.fan, "tier": s.tier,
           "chat_before": s.chat_before(d["at_turn"]),
           **{k: d.get(k) for k in ("text", "error", "flags", "model", "score", "note",
                                    "actual", "created", "actual_at", "context")}}
    DATA.mkdir(parents=True, exist_ok=True)
    with RATINGS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ── the app's state machine ──────────────────────────────────────────────────
class Trainer:
    def __init__(self, drafter=None):
        self.lock = threading.RLock()
        self.sessions: dict[tuple[str, str], Session] = {}
        self.current: Session | None = None
        self.status = "starting…"
        self.model = default_model()
        self.version = 0
        self._read_at = None
        self._queue: list[tuple[Session, int]] = []
        self._busy = False
        # Injected for tests; the real one is TestFlow's ai.her_reply.
        self._drafter = drafter

    def bump(self) -> None:
        self.version += 1

    def session(self, acct: str, fan: str, handle: str = "") -> Session:
        key = (acct, "@" + handle if handle else fan)
        if key not in self.sessions:
            self.sessions[key] = Session(acct, fan, handle)
        return self.sessions[key]

    # called every poll
    def tick(self, reader_running: bool) -> None:
        with self.lock:
            st = load_chat_now()
            if st is None:
                self._set_status("no chat yet — turn on the Chat reader (Settings ▸ Features)")
            elif not reader_running:
                self._set_status("the Chat reader is not running — Settings ▸ Features ▸ Chat reader")
            elif st.get("note"):
                self._set_status(st["note"])
            elif st.get("read_at") != self._read_at:
                self._read_at = st.get("read_at")
                fan = (st.get("fan") or "").strip()
                if not fan:
                    self._set_status("can't read the fan's name in the chat header — not saved")
                else:
                    s = self.session(account(), fan, st.get("handle", ""))
                    if s is not self.current:
                        self.current = s
                        self.bump()
                    why = s.apply(st.get("turns", []))
                    self._set_status(why or "following")
                    self.bump()
            for s in self.sessions.values():         # drafts due, any fan
                if s.due and time.time() >= s.due:
                    s.due = 0.0
                    self.request_draft(s)

    def _set_status(self, text: str) -> None:
        if text != self.status:
            self.status = text
            self.bump()

    def request_draft(self, s: Session) -> None:
        with self.lock:
            if not s.turns:
                return
            n = len(s.turns)
            if any(d["at_turn"] == n for d in s.drafts) or (s, n) in self._queue:
                return                               # already drafted for this chat
            self._queue.append((s, n))
            self.bump()
            if not self._busy:
                self._busy = True
                threading.Thread(target=self._work, daemon=True).start()

    def _work(self) -> None:
        while True:
            with self.lock:
                if not self._queue:
                    self._busy = False
                    self.bump()
                    return
                s, n = self._queue[0]
                # Only what was there when this draft was asked for.
                chat = s.as_testflow_chat(n)
                model = self.model
            t0 = time.time()
            try:
                out = self._drafter(chat, model)
            except Exception as e:                   # never kill the worker
                out = {"text": "", "error": f"{e.__class__.__name__}: {e}"}
            with self.lock:
                self._queue.pop(0)
                for d in s.drafts:                   # an older unanswered draft is moot now
                    if not d.get("actual"):
                        d["superseded"] = True
                d = {"id": uuid.uuid4().hex[:12], "at_turn": n, "created": time.time(),
                     "ms": int((time.time() - t0) * 1000), "model": model,
                     "text": out.get("text", ""), "error": out.get("error", ""),
                     "step": (out.get("read") or {}).get("step", ""),
                     "flags": out.get("flags") or [],
                     "context": out.get("context"), "score": None, "note": ""}
                # You may have answered while it was thinking: your reply belongs
                # to this draft, since this is the one made for that fan message.
                mine = [t for t in s.turns[n:] if t["who"] != "fan"]
                if mine and not any(t["who"] == "fan" for t in s.turns[n:]):
                    d["actual_turns"] = [t["text"] or "[media]" for t in mine]
                    d["actual"] = "\n".join(d["actual_turns"])
                    d["actual_at"] = mine[-1].get("at")
                elif any(t["who"] == "fan" for t in s.turns[n:]):
                    d["superseded"] = True           # he wrote again; a newer one is coming
                s.drafts.append(d)
                s.save()
                log_record(s, d)
                self.bump()

    def grade(self, draft_id: str, score: int | None, note: str) -> bool:
        with self.lock:
            for s in self.sessions.values():
                for d in s.drafts:
                    if d["id"] == draft_id:
                        d["score"], d["note"] = score, note.strip()
                        s.save()
                        log_record(s, d)
                        self.bump()
                        return True
        return False

    def set_tier(self, tier: int) -> None:
        with self.lock:
            if self.current:
                self.current.tier = int(tier)
                self.current.save()
                self.bump()

    def draft_now(self) -> None:
        with self.lock:
            if self.current:
                self.current.due = 0.0
                self.request_draft(self.current)

    def reset_history(self) -> None:
        """Forget the saved chat and take the screen as it is now."""
        with self.lock:
            s, st = self.current, load_chat_now()
            if s and st:
                s.turns = [{"who": t["who"], "text": t.get("text", "")}
                           for t in st.get("turns", []) if not t.get("partial")]
                s.save()
                self._set_status("history reset to the screen")
                self.bump()

    def snapshot(self) -> dict:
        with self.lock:
            s = self.current
            pending = [n for q, n in self._queue if q is s]
            return {"version": self.version, "status": self.status, "model": self.model,
                    "fan": s.fan if s else "", "account": s.account if s else "",
                    "tier": s.tier if s else 0,
                    "turns": s.turns if s else [],
                    "drafts": s.drafts if s else [],
                    "pending": pending, "due": bool(s and s.due)}
