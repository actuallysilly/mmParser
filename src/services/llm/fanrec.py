"""
llm/fanrec.py — the live fan recorder (lore_gatherer step 5). Spec: rows 27-33 of
docs/proposals/lore-gatherer.md.

The chat reader calls two hooks; this file never captures or clicks by itself:

    on_read(rgb, layout, state)   after every settled read of the WORK window
    on_frame(rgb)                 on frames where no conversation is readable,
                                  i.e. a modal is covering it (decision 30)

Who is it? (fanid + fanstore.match)
    1. the highlighted list row shows a FULL @handle            -> that fan
    2. a cut-off handle + the name match exactly one known fan  -> that fan (29)
    3. this session already resolved that header name           -> that fan
    4. otherwise: a PROVISIONAL file, "--u813--keefe" (handle start + name) or
       "----keefe" (name only), so nothing waits. When a full handle is read (the
       list row, his name popup if you open it, __lore), promote() folds it in.
       (Until 2026-11-26 this asked you by toast to click his name: 350 toasts in
       two days went unanswered and ~1,600 reads sat in _pending.)
Every filed read also pings AutoNote (autonote.py), which writes his note once
you have stopped chatting him.
Silly's own messages come from the screen only (31); the fan panel is ignored
live (32).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fanid                                      # noqa: E402
import fanstore                                   # noqa: E402
import transcript as T                            # noqa: E402

LOG = Path(__file__).resolve().parents[3] / "debuglogs" / "fanrec.log"


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def _days(turns: list[dict], seps: list[tuple[int, str]]) -> None:
    """A turn below a separator on this screen carries that separator's date."""
    for t in turns:
        box = t.get("box")
        if not box:
            continue
        above = [d for y, d in seps if y < box[1]]
        if above:
            t["day"] = above[-1]


class Recorder:
    def __init__(self) -> None:
        self.acct = ""
        self.acct_thumb = None
        self.tabs: list[str] = []                        # real accounts, from the tab strip
        self.tabs_thumb = None
        self.session: dict[tuple[str, str], str] = {}    # (acct, norm name) -> handle
        self.modal_done = None                           # thumb of the last modal read
        self.on_filed = None                             # AutoNote's hook: (acct, handle)

    # ── account: only names that are real account tabs ───────────────────────
    # Live 2026-11-24..26 the list heading was sometimes read as a fan's name or
    # "Search": ~50 fake account folders. Now the heading only counts when it is
    # one of the account tabs along the top; otherwise the last good one stays.
    def _account(self, rgb, layout) -> str:
        k = layout.scale / 1.37
        strip = rgb[round(8 * k):round(62 * k), :rgb.shape[1] // 2]
        st = strip[::6, ::6].astype(int).mean()
        if self.tabs_thumb is None or abs(st - self.tabs_thumb) >= 0.5 or not self.tabs:
            tabs = fanid.account_tabs(rgb, layout)
            if tabs:
                self.tabs, self.tabs_thumb = tabs, st
        x, y = layout.region[0], layout.region[1]
        band = rgb[max(0, y - 120):y, :max(1, x // 2)]
        thumb = band[::8, ::8].astype(int).mean()
        if self.acct and self.acct_thumb is not None and abs(thumb - self.acct_thumb) < 0.5:
            return self.acct
        a = fanid.account(rgb, layout)
        real = next((t for t in self.tabs if fanid.acct_key(t) == fanid.acct_key(a)), "") if a else ""
        if real:
            if real != self.acct:
                log(f"account: {real}")
            self.acct, self.acct_thumb = real, thumb
        elif a:
            log(f"ignored heading {a!r}: not an account tab {self.tabs}")
        return self.acct

    def resolve(self, acct: str, name: str, sel: dict | None) -> tuple[str, str]:
        """(handle, how). Never "" any more: an unknown fan gets a provisional id."""
        key = (acct, fanstore.norm_name(name))
        prefix = ""
        if sel and sel.get("handle") and (not name or fanstore.names_match(sel["name"], name)):
            if not sel["truncated"]:
                self.session[key] = sel["handle"]
                moved = fanstore.promote(acct, sel["handle"], name or sel["name"])
                if moved:
                    log(f"{acct}: promoted provisional -> @{sel['handle']} ({moved} reads)")
                return sel["handle"], "list"
            prefix = sel["handle"]
            hits = fanstore.match(acct, name, prefix)
            if len(hits) == 1:
                self.session[key] = hits[0]
                return hits[0], "prefix"
        if key in self.session:
            return self.session[key], "session"
        prov = fanstore.find_provisional(acct, name, prefix) or fanstore.provisional_id(name, prefix)
        self.session[key] = prov
        return prov, "provisional"

    def on_read(self, rgb, layout, state: dict) -> str:
        """File one read. Returns his @handle (provisional ids start with "--"),
        which the chat reader publishes in chat_now.json for Live Trainer."""
        turns = [dict(t) for t in state.get("turns") or []]
        if not turns or layout is None or layout.region[0] < 200:
            return ""                           # nothing read, or not the work window
        acct = self._account(rgb, layout)
        if not acct:
            return ""                           # no real account yet: don't invent one
        name = (state.get("fan") or "").strip()
        sel = fanid.list_selection(rgb, layout)
        _days(turns, fanid.day_separators(rgb, layout))
        handle, how = self.resolve(acct, name, sel)
        rec = {"at": state.get("read_at") or time.time(), "name": name,
               "list": sel and {k: sel[k] for k in ("name", "handle", "truncated")}}
        try:
            fanstore.keep_crops(rgb, acct, handle, turns)
        except Exception as e:                  # a picture is never worth a lost read
            log(f"crops failed: {e.__class__.__name__}: {e}")
        rec["turns"] = [{k: v for k, v in t.items() if k not in ("box", "repaired")} for t in turns]
        why = fanstore.record(acct, handle, rec)
        if why:
            log(f"{acct}/{handle} ({how}): {why}")
        if self.on_filed:
            try:
                self.on_filed(acct, handle)
            except Exception as e:
                log(f"autonote hook failed: {e.__class__.__name__}: {e}")
        return "" if fanstore.is_provisional(handle) else handle

    def on_frame(self, rgb) -> None:
        """A name popup open over the chat (you clicked his name): file him by his
        full handle and fold his provisional file in."""
        if rgb is None:
            return
        thumb = rgb[::16, ::16].astype(int).mean()
        if self.modal_done is not None and abs(thumb - self.modal_done) < 0.5:
            return                              # this modal was already read
        m = fanid.name_modal(rgb)
        if not m or not m["handle"] or not self.acct:
            return
        self.modal_done = thumb
        acct = self.acct
        fanstore.set_identity(acct, m["handle"], m["name"], m["tags"])
        n = fanstore.promote(acct, m["handle"], m["name"])
        self.session[(acct, fanstore.norm_name(m["name"]))] = m["handle"]
        log(f"{acct}: modal -> @{m['handle']} {m['name']!r}, promoted {n} read(s)")


def selftest() -> int:
    """Replays the reference captures through a Recorder into a temp FanData."""
    import shutil
    import tempfile
    tmp = Path(tempfile.mkdtemp(prefix="fanrec_"))
    fanstore._setting = lambda s, k, d="": str(tmp) if (s, k) == ("FanData", "Root") else d
    ref = Path(__file__).resolve().parents[3] / "tools" / "ui-research"
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    rec = Recorder()
    work = fanid._load(ref / "work_window_list.png")
    lay = T.find_layout(work)
    state = {"read_at": time.time(), "fan": T.read_fan_name(work, lay),
             "turns": [t.to_dict() for t in T.read_turns(work, lay, footers=True)]}
    filed = []
    rec.on_filed = lambda a, h: filed.append((a, h))
    rec.on_read(work, lay, state)
    prov = [p.parent.name for p in (tmp / "CIN").glob("--*/fan.json")]
    check("cut-off handle -> provisional file", len(prov) == 1 and prov[0].startswith("--u813--"), True)
    check("autonote hook called", filed[0][0], "CIN")
    rec.on_frame(fanid._load(ref / "name_modal.png"))
    d = fanstore.load("CIN", "u81384506")
    check("modal promoted provisional", [p.parent.name for p in (tmp / "CIN").glob("--*/fan.json")], [])
    check("fan file turns", len(d["turns"]) > 5, True)
    check("tags saved", "silly reach out" in d["tags"], True)
    check("last turn day", d["turns"][-1].get("day"), "Nov 21")
    rec2 = Recorder()                            # a new session: prefix + name must find him
    h = rec2.on_read(work, lay, dict(state, read_at=time.time() + 5))
    check("prefix match finds the real file", h, "u81384506")
    check("account from the tab allowlist", rec2.acct, "CIN")
    rec2.acct_thumb = None
    real = fanid.account
    fanid.account = lambda *a: "Search"          # a misread heading must not become an account
    rec2._account(work, lay)
    fanid.account = real
    check("misread heading ignored", rec2.acct, "CIN")
    print("     turns:", [(t["who"], t["text"][:20], t.get("time"), t.get("day")) for t in d["turns"]])
    shutil.rmtree(tmp, ignore_errors=True)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(selftest())
