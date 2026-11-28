"""
llm/autonote.py — AutoNote: every fan's recorded chat turned into a note, by itself.

Silly's name (2026-11-26) for the database part of the chatting suite: the fan
files in D:\\FanData plus a note per fan. Since 2026-11-27: AFTER THE SHIFT. Once
nothing has been recorded for [AutoNote] QuietMin minutes (default 30), every fan
whose chat grew since his last note gets one, newest first. [AutoNote] Mode=live
brings back the per-fan, mid-shift behaviour (AfterMin, default 3).

    the note   the card from prompts/lore.md (who, into, money, recently, right now,
               avoid, reach-out lines), from his whole kept chat + tags + notes +
               spend. Saved as <fan folder>/summary.md, shown in Fan Viewer.
    note.json  when it was written and how many messages it covered.

The chat reader owns one AutoNote and calls touch(acct, handle) for every read it
files; a worker thread writes notes one at a time, so the OCR loop never waits on
the LLM. __lore uses write_note() too: one note-writer, not two.

    python autonote.py --test          offline checks (no LLM)
    python autonote.py ACCT HANDLE     write one fan's note now
"""
from __future__ import annotations

import json
import re
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import client                                     # noqa: E402
import fanstore                                   # noqa: E402
import mmacfg                                     # noqa: E402

PROMPT = Path(__file__).resolve().parent / "prompts" / "lore.md"
LOG = Path(__file__).resolve().parents[3] / "debuglogs" / "autonote.log"
CARD_TOKENS = 600
CHAT_CHARS = 24000       # the newest this-many characters of chat go to the LLM
MIN_TURNS = 6            # fewer messages than this is not worth a note yet
MIN_NEW = 3              # ...and a refresh needs at least this many new ones
TICK_S = 20


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def render(turns: list[dict]) -> str:
    """The chat as the model sees it, oldest first."""
    out = []
    for t in turns:
        if t.get("gap_before"):
            out.append("[... not read ...]")
        who = "fan" if t.get("who") == "fan" else "her"
        body = t.get("text") or "[media]"
        if t.get("price"):
            state = {True: "paid", False: "not paid"}.get(t.get("paid"), "")
            body = f"[PPV ${t['price']} {state}]".replace(" ]", "]") + " " + (t.get("text") or "")
        w = " ".join(x for x in (t.get("day", ""), t.get("time", "")) if x)
        out.append(f"{who}: {body.strip()}" + (f"   ({w})" if w else ""))
    return "\n".join(out)


def write_card(fan: dict, fields: dict, chat: str) -> tuple[str, str]:
    system = re.sub(r"<!--.*?-->\s*", "", PROMPT.read_text(encoding="utf-8"), flags=re.S)
    ins = "\n".join(f"{k}: {v}" for k, v in fields.items() if k != "at") or "(not read)"
    tags = ", ".join(fan.get("tags") or []) or "(none)"
    return client.chat([
        {"role": "system", "content": system},
        {"role": "user", "content":
            f"TAGS:\n{tags}\n\nNOTES:\n{fan.get('notes') or '(none)'}\n\nINSIGHTS:\n{ins}\n\n"
            f"CHAT (oldest first):\n{chat[-CHAT_CHARS:]}"},
    ], temperature=0.3, max_tokens=CARD_TOKENS, use_model=client.get("Lore", "Model", ""),
        # Unload right after: a background note must never keep the model resident.
        keep_alive=mmacfg.setting("AutoNote", "KeepAlive", "0") or "0")


def noted(acct: str, handle: str) -> dict:
    try:
        return json.loads((fanstore.fan_dir(acct, handle) / "note.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def due(acct: str, handle: str) -> bool:
    """Has his chat grown enough since his last note?"""
    n = len(fanstore.load(acct, handle)["turns"])
    last = noted(acct, handle).get("turns", 0)
    return n >= MIN_TURNS and (not last or n - last >= MIN_NEW)


def write_note(acct: str, handle: str, head_extra: str = "") -> tuple[str, str]:
    """Write his note now. (note text, error)."""
    d = fanstore.load(acct, handle)
    fields = d.get("insights") or {}
    card, err = write_card(d, fields, render(d["turns"]))
    if not card:
        return "", err or "empty answer"
    name = (d.get("names") or ["?"])[0]
    who = handle if fanstore.is_provisional(handle) else f"@{handle}"
    head = f"{name}  {who}  ·  {acct}  ·  {len(d['turns'])} messages" + (f"\n{head_extra}" if head_extra else "")
    folder = fanstore.fan_dir(acct, handle)
    (folder / "summary.md").write_text(
        f"# {head}\n\n{card}\n\n_written {time.strftime('%Y-%m-%d %H:%M')}_\n", encoding="utf-8")
    (folder / "note.json").write_text(json.dumps({"at": time.time(), "turns": len(d["turns"])}),
                                      encoding="utf-8")
    return f"{head}\n\n{card}", ""


def all_due() -> list[tuple[str, str]]:
    """Every fan on disk whose chat grew since his last note, most recent first.
    From the files, so nothing is lost if the chat reader restarts mid-shift."""
    out = []
    root = fanstore.root()
    for f in root.glob("*/*/fan.json") if root.exists() else []:
        acct, handle = f.parent.parent.name, f.parent.name
        try:
            if due(acct, handle):
                out.append((f.stat().st_mtime, acct, handle))
        except Exception as e:
            log(f"{acct}/{handle}: check failed: {e}")
    return [(a, h) for _t, a, h in sorted(out, reverse=True)]


class AutoNote:
    """Lives in the chat reader; touch() on every filed read.

    [AutoNote] Mode (mass_gui.cfg):
      aftershift (default, Silly 2026-11-27)  nothing is written while you work.
          Once no chat has been recorded for QuietMin minutes (default 30), every
          fan whose chat grew since his last note is noted, newest first. A new
          read (you're back) pauses the batch after the note in progress.
      live   a fan is noted AfterMin minutes (default 3) after you stop chatting
          him, mid-shift too (the 2026-11-26 behaviour).
    """

    def __init__(self) -> None:
        self.last: dict[tuple[str, str], float] = {}     # (acct, handle) -> last read
        self.last_any = time.time()                      # the newest read of any fan
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread: threading.Thread | None = None
        self.fail_until = 0.0                            # LLM down: back off
        self.batch: list[tuple[str, str]] = []
        self.ensure()

    def ensure(self) -> None:
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, name="autonote", daemon=True)
            self.thread.start()

    def touch(self, acct: str, handle: str) -> None:
        with self.lock:
            now = time.time()
            self.last[(acct, handle)] = now
            self.last_any = now
            self.batch = []                              # you're working: the batch waits
        self.ensure()

    def _mins(self, key: str, default: str) -> float:
        try:
            return float(mmacfg.setting("AutoNote", key, default) or default) * 60
        except ValueError:
            return float(default) * 60

    def _next_live(self) -> tuple[str, str] | None:
        now = time.time()
        with self.lock:
            quiet = [(t, k) for k, t in self.last.items() if now - t >= self._mins("AfterMin", "3")]
        for _t, (acct, handle) in sorted(quiet):
            try:
                if fanstore.fan_dir(acct, handle).exists() and due(acct, handle):
                    return acct, handle
            except Exception as e:
                log(f"{acct}/{handle}: check failed: {e}")
            with self.lock:                              # promoted, or nothing new: forget him
                self.last.pop((acct, handle), None)
        return None

    def _next_aftershift(self) -> tuple[str, str] | None:
        if time.time() - self.last_any < self._mins("QuietMin", "30"):
            return None                                  # the shift is still on
        if not self.batch:
            self.batch = all_due()
            if self.batch:
                log(f"after-shift batch: {len(self.batch)} fan(s) to note")
        while self.batch:
            acct, handle = self.batch.pop(0)
            if fanstore.fan_dir(acct, handle).exists() and due(acct, handle):
                return acct, handle
        return None

    def _run(self) -> None:
        while not self.stop.wait(TICK_S):
            if not mmacfg.feat("AutoNote") or time.time() < self.fail_until:
                continue
            live = mmacfg.setting("AutoNote", "Mode", "aftershift").lower() == "live"
            nxt = self._next_live() if live else self._next_aftershift()
            if not nxt:
                continue
            acct, handle = nxt
            t0 = time.time()
            try:
                _note, err = write_note(acct, handle)
            except Exception as e:
                err = f"{e.__class__.__name__}: {e}"
            if err:
                log(f"{acct}/{handle}: no note: {err}")
                self.fail_until = time.time() + 300      # don't hammer a down LLM
                with self.lock:
                    self.batch = []
                continue
            log(f"{acct}/{handle}: note written in {time.time() - t0:.0f}s")
            with self.lock:
                if self.last.get((acct, handle), 0) <= t0:
                    self.last.pop((acct, handle), None)


def selftest() -> int:
    import shutil
    import tempfile
    tmp = Path(tempfile.mkdtemp(prefix="autonote_"))
    fanstore._setting = lambda s, k, d="": str(tmp) if (s, k) == ("FanData", "Root") else d
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    words = ["hey you", "what are you up to", "just got home from work", "tell me more babe",
             "long day at the office", "come relax with me", "send me something", "check your dms"]
    turns = [{"who": "fan" if i % 2 else "model", "text": w, "time": "9:10 am"} for i, w in enumerate(words)]
    fanstore.record("CIN", "u1", {"at": 1, "name": "Joe", "turns": turns[:4]})
    check("too short to note", due("CIN", "u1"), False)
    fanstore.record("CIN", "u1", {"at": 2, "name": "Joe", "turns": turns[3:]})
    check("long enough", due("CIN", "u1"), True)
    global write_card
    real = write_card
    write_card = lambda fan, fields, chat: ("WHO: Joe\nREACH OUT: hey joe", "")
    note, err = write_note("CIN", "u1")
    write_card = real
    check("note written", err == "" and "REACH OUT" in note, True)
    check("summary.md saved", (fanstore.fan_dir("CIN", "u1") / "summary.md").exists(), True)
    check("not due right after", due("CIN", "u1"), False)
    check("render", render([{"who": "model", "text": "hi", "price": "20", "paid": True,
                             "day": "Nov 20", "time": "9:10 am"}]),
          "her: [PPV $20 paid] hi   (Nov 20 9:10 am)")
    fanstore.record("CIN", "u2", {"at": 3, "name": "Sam", "turns": turns})
    an = AutoNote()
    an.stop.set()                                # no worker: drive it by hand
    mmacfg.setting = lambda sec, key, d="": d    # defaults: aftershift, QuietMin 30
    an.touch("CIN", "u2")
    check("mid-shift: nothing", an._next_aftershift(), None)
    an.last_any = time.time() - 31 * 60
    check("30 min quiet: the batch starts", an._next_aftershift(), ("CIN", "u2"))
    an.touch("CIN", "u2")
    check("a new read pauses it", an._next_aftershift(), None)
    shutil.rmtree(tmp, ignore_errors=True)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if "--test" in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) == 3:
        text, err = write_note(sys.argv[1], sys.argv[2])
        print(text or f"no note: {err}")
        sys.exit(0 if text else 1)
    print(__doc__)
