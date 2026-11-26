"""
Fan Viewer (was Shift Viewer) — every fan the recorders saved, laid out like Infloww.

    left     every fan recorded: spend, messages, and warnings (unconnected
             fragments, several name spellings folded together)
    centre   the chat exactly as recorded: bubbles, time, chatter, PPV price
             pill (paid / not paid), his likes, media. Fragments that never
             joined the chat (a scroll-back with a gap) are shown above it,
             marked, in the order they were read.
    right    the fan panel as last read, and every change to it with its time
             (spend before and after a pitch)

Two sources, switched by the banner's "Source" button: the FAN FILES of the
lore_gatherer fan recorder (default: [FanData] Root, one folder per @handle,
docs/proposals/lore-gatherer.md decision 19) and the old shift log, which runs
beside it for one shift and is then retired. It only READS userdata/shiftlog/chats/. "Rebuild" re-runs shiftlog.rebuild(),
which folds name spellings into one fan; run it after a shift, not during one.

THE TITLE MUST NEVER CONTAIN "Infloww Messages". The chat reader records every
window with that in its title, so a viewer called that would record itself.

Local only: the data is real chats, so it is never served beyond this machine.

    pythonw shiftview.pyw         open the viewer
    runner.pyw --start shiftview  same, how MMA's Tools window opens it
"""
from __future__ import annotations

import ctypes
import json
import sys
import time
from pathlib import Path

import os

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[1]
sys.path.insert(0, str(MMA_ROOT / "src" / "services" / "llm"))

# ONE-TIME VIEW (`--temp DIR`, opened by tools/videoimport): show a shift log
# that a video was converted into, in a temp folder, and delete that folder
# when the window closes. Set before shiftlog is imported: its paths are read
# once, at import. Only a folder carrying TEMP_MARK is ever deleted.
TEMP_MARK = ".mma-onetime"
TEMP: Path | None = None
if "--temp" in sys.argv[1:-1]:
    TEMP = Path(sys.argv[sys.argv.index("--temp") + 1]).resolve()
    os.environ["MMA_SHIFTLOG_ROOT"] = str(TEMP)

import shiftlog  # noqa: E402
import fanstore  # noqa: E402  (lore_gatherer fan files, the default source)

# The one-time title must NOT start with "MMA Fan Viewer": the Fan Viewer key
# raises any window whose title starts with that instead of opening the real one.
TITLE = "MMA Fan Viewer" if TEMP is None else f"MMA One-time View — {TEMP.name}"
MUTEX = "Global\\MMA.shiftview.mutex" if TEMP is None else ""


def log(msg: str) -> None:
    try:
        f = MMA_ROOT / "debuglogs" / "error_log.txt"
        f.parent.mkdir(exist_ok=True)
        with f.open("a", encoding="utf-8") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [shiftview] {msg}\n")
    except OSError:
        pass


def _spend_value(s: str) -> float:
    """"$1.04k" -> 1040.0, for sorting. 0 when unreadable."""
    import re
    m = re.search(r"\$\s?([\d.,]+)\s*(k?)", s or "")
    if not m:
        return 0.0
    try:
        return float(m[1].replace(",", "")) * (1000 if m[2] else 1)
    except ValueError:
        return 0.0


def summary(path: Path) -> dict:
    d = json.loads(path.read_text(encoding="utf-8"))
    turns = d.get("turns", [])
    islands = d.get("islands", [])
    every = turns + [t for i in islands for t in i.get("turns", [])]
    fields = ((d.get("panel") or {}).get("insights") or {}).get("fields") or {}
    spend = fields.get("Total spend", "")
    last = turns[-1] if turns else (every[-1] if every else None)
    return {
        "id": str(path.relative_to(shiftlog.CHATS)).replace("\\", "/"),
        "account": d.get("account", ""), "fan": d.get("fan", ""),
        "names": d.get("names", []),
        "messages": len(every), "fan_msgs": sum(t["who"] == "fan" for t in every),
        "timed": sum(bool(t.get("time")) for t in every),
        "islands": len(islands), "island_msgs": sum(len(i.get("turns", [])) for i in islands),
        "ppv": sum(bool(t.get("price")) for t in every),
        "paid": sum(t.get("paid") is True for t in every),
        "spend": spend, "spend_value": _spend_value(spend),
        "last_seen": d.get("last_seen") or 0, "reads": d.get("reads", 0),
        "has_panel": bool(d.get("panel")),
        # For the Infloww-style list row: his last line, and the sub status
        # (an expired sub gets Infloww's red ✕ avatar).
        "preview": (last.get("text") or "[media]") if last else "",
        "preview_who": last.get("who", "") if last else "",
        "status": fields.get("Status", ""),
    }


def _fan_files():
    base = fanstore.root()
    return sorted(p for p in base.glob("*/*/fan.json") if p.parent.parent.name != "_pending")         if base.exists() else []


def fan_summary(path: Path) -> dict:
    """A fan file in the shape summary() gives, so the page needs no second path."""
    d = json.loads(path.read_text(encoding="utf-8"))
    turns, islands = d.get("turns", []), d.get("islands", [])
    every = turns + [t for i in islands for t in i.get("turns", [])]
    last = turns[-1] if turns else (every[-1] if every else None)
    name = (d.get("names") or ["?"])[0]
    spend = (d.get("insights") or {}).get("Total spend", "")
    value = fanstore.spend_value(spend)
    return {
        "tier": fanstore.tier(value), "has_card": (path.parent / "summary.md").exists(),
        "id": "fans:" + path.parent.relative_to(fanstore.root()).as_posix(),
        "kind": "fan", "account": d.get("account", ""), "fan": f"{name} @{d.get('handle', '')}",
        "names": d.get("names", []), "handle": d.get("handle", ""), "tags": d.get("tags", []),
        "messages": len(every), "fan_msgs": sum(t["who"] == "fan" for t in every),
        "timed": sum(bool(t.get("time")) for t in every),
        "islands": len(islands), "island_msgs": sum(len(i.get("turns", [])) for i in islands),
        "ppv": sum(bool(t.get("price")) for t in every),
        "paid": sum(t.get("paid") is True for t in every),
        "spend": spend, "spend_value": value,
        "last_seen": d.get("last_seen") or 0, "reads": d.get("reads", 0), "has_panel": True,
        "preview": (last.get("text") or "[media]") if last else "",
        "preview_who": last.get("who", "") if last else "", "status": "",
    }


def fan_chat(folder: Path) -> dict:
    """fan.json as the page's chat(): day -> date, media -> a media() path."""
    d = json.loads((folder / "fan.json").read_text(encoding="utf-8"))
    rel = folder.relative_to(fanstore.root()).as_posix()

    def turn(t):
        t = dict(t)
        if t.get("day") and not t.get("date"):
            t["date"] = t["day"]
        if t.get("media"):
            t["media_img"] = f"fans:{rel}/{t['media']}"
        return t
    name = (d.get("names") or ["?"])[0]
    try:
        card = (folder / "summary.md").read_text(encoding="utf-8")
    except OSError:
        card = ""
    ins = {k: v for k, v in (d.get("insights") or {}).items() if k != "at"}
    return {**d, "fan": f"{name} @{d.get('handle', '')}", "card": card, "fields": ins,
            "tier": fanstore.tier(fanstore.spend_value(ins.get("Total spend", ""))),
            "turns": [turn(t) for t in d.get("turns", [])],
            "islands": [dict(i, turns=[turn(t) for t in i.get("turns", [])]) for i in d.get("islands", [])],
            "panel": {}, "panel_log": [], "tags": d.get("tags", []), "notes": d.get("notes", "")}


class Api:
    # Underscore names only: pywebview walks every PUBLIC attribute of this
    # object, and a Window is a .NET tree it cannot touch off the UI thread.
    def __init__(self):
        self._window = None
        self._src = "fans" if TEMP is None and "--shift" not in sys.argv else "shift"

    def source(self, which: str = "") -> str:
        """Switch between "fans" (fan files) and "shift" (the old shift log).
        A one-time view stays on its temp shift log."""
        if which in ("fans", "shift") and TEMP is None:
            self._src = which
        return self._src

    def fans(self) -> dict:
        if self._src == "fans":
            out, bad, reads = [], 0, 0
            for p in _fan_files():
                try:
                    out.append(fan_summary(p))
                    with (p.parent / "reads.jsonl").open(encoding="utf-8") as fh:
                        reads += sum(1 for _ in fh)
                except (OSError, ValueError, KeyError) as e:
                    bad += 1
                    log(f"skipped {p}: {e}")
            pending = sum(len(fanstore.pending_names(a.name)) for a in fanstore.root().glob("*")
                          if a.is_dir()) if fanstore.root().exists() else 0
            return {"fans": out, "unreadable": bad, "raw_reads": reads, "pending": pending,
                    "source": "fans", "folder": str(fanstore.root())}
        return self._shift_fans()

    def _shift_fans(self) -> dict:
        out, bad = [], 0
        for p in sorted(shiftlog.CHATS.rglob("*.json")):
            try:
                out.append(summary(p))
            except (OSError, ValueError, KeyError) as e:
                bad += 1
                log(f"skipped {p.name}: {e}")
        reads = 0
        for f in shiftlog.READS.glob("*.jsonl"):
            with f.open(encoding="utf-8") as fh:
                reads += sum(1 for _ in fh)
        return {"fans": out, "unreadable": bad, "raw_reads": reads, "pending": 0,
                "source": "shift", "folder": str(shiftlog.ROOT), "temp": TEMP is not None}

    def chat(self, rel: str) -> dict:
        if rel.startswith("fans:"):
            folder = (fanstore.root() / rel[5:]).resolve()
            if fanstore.root().resolve() not in folder.parents or not (folder / "fan.json").exists():
                return {"error": "not a fan file"}
            try:
                return fan_chat(folder)
            except (OSError, ValueError) as e:
                return {"error": str(e)}
        p = (shiftlog.CHATS / rel).resolve()
        # Only files inside chats/ — the id comes from the page.
        if shiftlog.CHATS.resolve() not in p.parents or p.suffix != ".json":
            return {"error": "not a shift log file"}
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            return {"error": str(e)}

    def media(self, rel: str) -> str:
        """One kept picture as a data: URL ("" if missing). Over the js bridge
        like the chats themselves, never the static server."""
        import base64
        if rel.startswith("fans:"):
            base = fanstore.root().resolve()
            p = (base / rel[5:]).resolve()
        else:
            base = shiftlog.MEDIA.resolve()
            p = (shiftlog.MEDIA / rel).resolve()
        if base not in p.parents or p.suffix != ".jpg":
            return ""
        try:
            return "data:image/jpeg;base64," + base64.b64encode(p.read_bytes()).decode()
        except OSError:
            return ""

    def rebuild(self) -> dict:
        try:
            if self._src == "fans":
                n = 0
                for p in _fan_files():
                    d = fanstore.rebuild(p.parent.parent.name, p.parent.name)
                    n += d.get("reads", 0)
                log(f"rebuilt fan files from {n} reads")
                return {"ok": True, "reads": n}
            n = shiftlog.rebuild()
            log(f"rebuilt from {n} reads")
            return {"ok": True, "reads": n}
        except Exception as e:                   # show it, never crash the viewer
            log(f"rebuild failed: {e.__class__.__name__}: {e}")
            return {"ok": False, "error": f"{e.__class__.__name__}: {e}"}


def serve_tools() -> str:
    """Serve tools/ on 127.0.0.1 and return its base URL.

    The page loads the shared Infloww clone from ../../inflowwclone/. pywebview's
    own server only serves the page's folder, so that path 404'd and the window
    came up blank. Static files only, bound to this machine; the chat DATA never
    goes through here — it comes from Api() over the js bridge.
    """
    import functools
    import threading
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *a):                # pythonw has no stdout
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0),
                              functools.partial(Quiet, directory=str(HERE.parent)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_address[1]}/"


def drop_temp() -> None:
    """Delete the one-time view's folder, only if the importer marked it."""
    import shutil
    if TEMP is not None and (TEMP / TEMP_MARK).exists():
        shutil.rmtree(TEMP, ignore_errors=True)
        log(f"one-time view closed, deleted {TEMP}")


def main() -> int:
    if MUTEX:                                    # one-time views may open side by side
        k32 = ctypes.windll.kernel32
        k32.CreateMutexW(None, False, MUTEX)
        if k32.GetLastError() == 183:            # already open
            return 0
    import webview
    api = Api()
    win = webview.create_window(TITLE, serve_tools() + "shiftview/ui/index.html", js_api=api,
                                width=1600, height=950, min_size=(1100, 600),
                                background_color="#151515")
    api._window = win
    try:
        webview.start()
    finally:
        drop_temp()
    return 0


if __name__ == "__main__":
    sys.exit(main())
