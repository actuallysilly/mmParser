"""
llm/lore.pyw — lore_gatherer: read a fan's chat UPWARDS, keep it, brief you on him.

Silly's ask (2026-11-24): "upon request, autoscroll that reads the whole chat,
captures it in reverse chrono order, then does a little LLM analysis", into "a
database of everyone I'm chatting to". Decisions: docs/proposals/lore-gatherer.md.

    __lore              (shortcuts.ini, typed in an Infloww window with the fan open)
    pythonw lore.pyw    the same, on the foreground Infloww window
    python lore.pyw --dev N     read N pages up and print the stitching, no picker

What one run does
    1. picker: how far up (decision 3/13/24). Enter = the last one used.
    2. who: the @handle. A window with a chat list shows it in the highlighted row;
       otherwise it clicks the fan's name, reads the modal, presses Esc (decision 8:
       brief real input is OK) and puts the cursor and focus back.
    3. reads upward with WHEEL MESSAGES posted to Infloww's render widget: no cursor,
       no focus, so you can work in another window (probe 2026-11-24). Every page is
       stitched into the fan's folder (fanstore: <Root>/<account>/<handle>/), so the
       chat is kept for good and the next run only reads what is new (decision 4).
    4. the card: who he is, what he's into, money, right now, reach-out ideas
       (decision 26), saved as summary.md beside his chat and shown here.

This replaces __analyse, which did the same with your REAL mouse (any hand
movement aborted it) and kept nothing but a markdown file.
"""
from __future__ import annotations

import ctypes
import json
import queue
import re
import sys
import threading
import time
from ctypes import wintypes as wt
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import autonote                                   # noqa: E402
import client                                     # noqa: E402
import fanid                                      # noqa: E402
import fanstore                                   # noqa: E402
import transcript as T                            # noqa: E402

MMA_ROOT = Path(__file__).resolve().parents[3]
LOG_FILE = MMA_ROOT / "debuglogs" / "lore.log"
STATE = MMA_ROOT / "userdata" / "lore_last.json"

u32 = ctypes.windll.user32
WM_MOUSEWHEEL, WM_KEYDOWN, WM_KEYUP, VK_ESCAPE = 0x020A, 0x0100, 0x0101, 0x1B

PAGE_SHARE = 0.55        # of the pane one step scrolls: the rest is overlap to stitch on
NOTCH_PX = 100           # Chromium: 100 CSS px per wheel notch
SETTLE_POLL_S = 0.2
SETTLE_DIFF = 0.4
SETTLE_MAX_S = 4.0
TOP_WAIT_S = 2.5         # nothing moved: older messages may still be loading
TOP_TRIES = 3            # ...this many times in a row = the top of the chat
FIRST_CHECK = 2          # pages before the LLM is first asked "enough?"
AI_MAX_PAGES = 40        # "AI decides" never reads further than this
EVENT_GAP_H = 6          # decision 14

RULES = [("ai", "AI decides it has enough (default)"),
         ("whole", "Whole chat, to the first message"),
         ("date", "Back to a date"),
         ("msgs", "Last N messages"),
         ("events", "Last N spending events (6h apart)")]


def log(msg: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


class Stop(Exception):
    pass


# ── time of a turn ───────────────────────────────────────────────────────────
_HM = re.compile(r"(\d{1,2})\s*:\s*(\d{2})\s*([ap])", re.I)


def when(t: dict, now: datetime | None = None) -> datetime | None:
    """'Nov 20' + '9:10 am' -> a datetime (this year, or last year if that would
    be in the future). None when the day or time is unknown."""
    now = now or datetime.now()
    day = (t.get("day") or t.get("date") or "").strip()
    m = _HM.search(t.get("time") or "")
    if not day or not m:
        return None
    h = int(m.group(1)) % 12 + (12 if m.group(3).lower() == "p" else 0)
    if day.lower() == "today":
        d = now.date()
    elif day.lower() == "yesterday":
        d = (now - timedelta(days=1)).date()
    else:
        dm = re.match(r"([A-Za-z]{3})\w*\.?\s*(\d{1,2})(?:,\s*(\d{4}))?", day)
        if not dm:
            return None
        try:
            d = datetime.strptime(f"{dm.group(1)} {dm.group(2)} {dm.group(3) or now.year}", "%b %d %Y").date()
        except ValueError:
            return None
        if not dm.group(3) and d > now.date() + timedelta(days=1):
            d = d.replace(year=d.year - 1)
    return datetime(d.year, d.month, d.day, h, int(m.group(2)))


def spending_events(turns: list[dict]) -> list[datetime]:
    """Start of each burst of paid PPVs, newest last (decision 14: 6h gap)."""
    times = sorted(w for t in turns if t.get("price") and t.get("paid") is True
                   for w in [when(t)] if w)
    starts, last = [], None
    for w in times:
        if last is None or w - last > timedelta(hours=EVENT_GAP_H):
            starts.append(w)
        last = w
    return starts


def done(rule: str, arg: str, turns: list[dict]) -> bool:
    """Has the mechanical stop rule been met by what is stitched so far?"""
    if rule == "msgs":
        return len(turns) >= int(arg or 200)
    if rule == "date":
        target = when({"day": arg, "time": "12:00 am"})
        first = next((w for t in turns for w in [when(t)] if w), None)
        return bool(target and first and first <= target)
    if rule == "events":
        return len(spending_events(turns)) > int(arg or 2)   # one more = we're past the Nth
    return False


# ── the window ───────────────────────────────────────────────────────────────
class Win:
    def __init__(self, hwnd: int, title: str):
        self.hwnd, self.title = hwnd, title

    def grab(self):
        rgb = T._pinger.print_window(self.hwnd)
        if rgb is None:
            raise Stop("Infloww gave no pixels (minimised?)")
        layout = T.find_layout(rgb)
        r = wt.RECT()
        u32.GetWindowRect(self.hwnd, ctypes.byref(r))
        self.left, self.top = r.left, r.top
        return rgb, layout

    def widget(self) -> int:
        """Chrome_RenderWidgetHostHWND: the child that takes wheel messages. It can
        come and go, so it is looked up every time."""
        found = []

        @ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
        def cb(h, _):
            buf = ctypes.create_unicode_buffer(64)
            u32.GetClassNameW(h, buf, 64)
            if buf.value == "Chrome_RenderWidgetHostHWND":
                found.append(h)
                return False
            return True
        u32.EnumChildWindows(self.hwnd, cb, 0)
        return found[0] if found else 0

    def wheel(self, x: int, y: int, notches: int) -> None:
        """Background scroll: notches > 0 = up (older). Window-relative x, y."""
        sx, sy = self.left + int(x), self.top + int(y)
        lp = ((sy & 0xFFFF) << 16) | (sx & 0xFFFF)
        # Live 2026-11-24: posting to the render-widget child scrolls even a
        # covered window, but Chromium only keeps that child around some of the
        # time. Without it the top-level takes the wheel ONLY when Infloww is the
        # window actually under that point (Chromium re-routes wheel messages to
        # whatever is under the cursor position they carry). Covered = no scroll,
        # and no amount of keyboard or accessibility poking changes that.
        w = self.widget()
        if not w:
            under = u32.GetAncestor(u32.WindowFromPoint(wt.POINT(sx, sy)), 2)   # GA_ROOT
            if under != self.hwnd:
                raise Stop("the Infloww window is covered where the chat is. Put it where you "
                           "can see the chat (another monitor is perfect); it doesn't need focus.")
            w = self.hwnd
        step = 1 if notches > 0 else -1
        for _ in range(abs(notches)):
            u32.PostMessageW(w, WM_MOUSEWHEEL, ((120 * step) & 0xFFFF) << 16, lp)
            time.sleep(0.02)

    def esc(self) -> None:
        w = self.widget() or self.hwnd
        u32.PostMessageW(w, WM_KEYDOWN, VK_ESCAPE, 0x00010001)
        u32.PostMessageW(w, WM_KEYUP, VK_ESCAPE, 0xC0010001)


def settle(win: Win):
    """Grab until the pane holds still. (rgb, layout, thumb)."""
    prev, still, end = None, 0, time.time() + SETTLE_MAX_S
    while True:
        rgb, layout = win.grab()
        if layout is None:
            if time.time() > end:
                raise Stop("no conversation is showing")
            time.sleep(SETTLE_POLL_S)
            continue
        th = T.pane_thumb(rgb, layout)
        if prev is not None and T.thumb_diff(prev, th) < SETTLE_DIFF:
            still += 1
            if still >= 2:
                return rgb, layout, th
        else:
            still = 0
        if time.time() > end and prev is not None:
            return rgb, layout, th
        prev = th
        time.sleep(SETTLE_POLL_S)


def read_page(rgb, layout) -> list[dict]:
    turns = [t.to_dict() for t in T.read_turns(rgb, layout, footers=True)]
    seps = fanid.day_separators(rgb, layout)
    for t in turns:
        above = [d for y, d in seps if y < t["box"][1]]
        if above:
            t["day"] = above[-1]
    return turns


# ── who is he ────────────────────────────────────────────────────────────────
def _click(x: int, y: int) -> None:
    vx, vy = u32.GetSystemMetrics(76), u32.GetSystemMetrics(77)
    vw, vh = u32.GetSystemMetrics(78), u32.GetSystemMetrics(79)
    nx = round((int(x) - vx) * 65535 / max(1, vw - 1))
    ny = round((int(y) - vy) * 65535 / max(1, vh - 1))
    u32.mouse_event(0x0001 | 0x8000 | 0x4000, nx, ny, 0, 0)     # move, absolute, virtual desk
    time.sleep(0.05)
    u32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.03)
    u32.mouse_event(0x0004, 0, 0, 0, 0)


def identify(win: Win, rgb, layout, status) -> dict:
    """{'handle', 'name', 'tags'}; handle "" if it could not be read."""
    name = T.read_fan_name(rgb, layout)
    sel = fanid.list_selection(rgb, layout)
    if sel and sel["handle"] and not sel["truncated"] and fanstore.names_match(sel["name"], name):
        return {"handle": sel["handle"], "name": name, "tags": []}
    status("reading his @handle (clicking his name for a moment)…")
    x, y, _w, _h = layout.region
    k = layout.scale
    div = y - 2
    nx = x + round((T.NAME_DX0 + 30) * k)
    ny = div - round((T.NAME_DY0 + T.NAME_DY1) / 2 * k)
    cur = wt.POINT()
    u32.GetCursorPos(ctypes.byref(cur))
    fg = u32.GetForegroundWindow()
    found = None
    try:
        u32.SetForegroundWindow(win.hwnd)
        time.sleep(0.15)
        _click(win.left + nx, win.top + ny)
        end = time.time() + 2.5
        while time.time() < end and not found:
            time.sleep(0.25)
            m = fanid.name_modal(T._pinger.print_window(win.hwnd))
            if m and m["handle"]:
                found = m
    finally:
        for _ in range(3):                      # close it, whatever happened
            if not fanid._modal_box(T._pinger.print_window(win.hwnd)):
                break
            win.esc()
            time.sleep(0.3)
        u32.SetCursorPos(cur.x, cur.y)
        if fg and fg != win.hwnd:
            u32.SetForegroundWindow(fg)
    if not found:
        log(f"modal not read for {name!r}")
        return {"handle": "", "name": name, "tags": []}
    return {"handle": found["handle"], "name": found["name"] or name, "tags": found["tags"]}


# ── his notes (decision 20) ──────────────────────────────────────────────────
# Silly's rule: never change the Notes, ever. __analyse copied them with a click +
# Ctrl+A/C behind a keyboard guard; without that guard a keystroke of yours could
# land in the box. So this never touches it: the fan panel is scrolled down with
# background wheel messages, the Notes CARD (bottom of Insights) is OCR'd, and the
# panel is scrolled back up. Long notes may be cut where the card cuts them.
NOTES_HEAD_X0_MAX = 80   # the "Notes" heading sits at the card's left edge


def _nrm(s: str) -> str:
    return re.sub(r"[^a-z]", "", s.lower())


def find_notes(rows: list) -> str | None:
    """The Notes card's text from panel rows; None when no card is on screen,
    "" when it shows the empty placeholder. Not the bottom nav's Notes TAB."""
    tabs_y = None
    for y, parts in rows:
        if any(_nrm(p[2]) == "insights" for p in parts) and len(parts) >= 2:
            tabs_y = y
    head = None
    for y, parts in rows:
        words = [p for p in parts if _nrm(p[2])]
        if (len(words) == 1 and _nrm(words[0][2]) == "notes"
                and words[0][0] < NOTES_HEAD_X0_MAX and (tabs_y is None or y < tabs_y - 30)):
            head = y
    if head is None:
        return None
    lines = [" ".join(p[2] for p in parts) for y, parts in rows
             if y > head + 10 and (tabs_y is None or y < tabs_y - 10)]
    text = "\n".join(lines).strip()
    return "" if _nrm(text).startswith("addrelevantdetails") else text


def read_notes(win: Win, rgb, layout) -> str | None:
    """OCR the Notes card. None = couldn't find it (panel on another tab, etc.)."""
    if T.read_panel(rgb, layout).get("tab") not in (None, "insights"):
        return None
    box = T.panel_box(rgb, layout)
    px, py = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    found = None
    try:
        th = T.panel_thumb(rgb, layout)
        for _ in range(12):                      # to the bottom of the panel
            win.wheel(px, py, -5)
            time.sleep(0.4)
            rgb, layout = win.grab()
            th2 = T.panel_thumb(rgb, layout)
            if T.thumb_diff(th, th2) < SETTLE_DIFF:
                break
            th = th2
        found = find_notes(T._panel_rows(rgb, T.panel_box(rgb, layout), layout.scale))
    finally:
        try:
            win.wheel(px, py, 60)                # panel back to the top
        except Stop:
            pass
    return found


# ── the card ─────────────────────────────────────────────────────────────────
from autonote import render, CHAT_CHARS        # noqa: E402  (one note-writer: AutoNote's)


def ask_enough(chat: str) -> tuple[bool, str]:
    text, err = client.chat([
        {"role": "system", "content":
            "You decide if a chatter has read enough of an OnlyFans chat to be briefed on the "
            "fan: who he is, what he is into, what he buys and at what prices, what happened "
            "recently (went broke, got forgotten, argued, felt scammed), and inside jokes or "
            "roleplay worth bringing up. Answer JSON only."},
        {"role": "user", "content": f"CHAT (oldest first):\n{chat[-CHAT_CHARS:]}"},
    ], temperature=0.1, max_tokens=60, use_model=client.get("Lore", "Model", ""),
        fmt={"type": "object", "properties": {"enough": {"type": "boolean"},
                                              "missing": {"type": "string"}},
             "required": ["enough", "missing"]})
    if err:
        return False, err
    try:
        d = json.loads(text)
        return bool(d.get("enough")), str(d.get("missing", ""))
    except ValueError:
        return False, "unreadable answer"


# ── one run ──────────────────────────────────────────────────────────────────
class Run:
    def __init__(self, q: queue.Queue, rule: str, arg: str, hwnd: int, title: str):
        self.q, self.rule, self.arg = q, rule, arg
        self.win = Win(hwnd, title)

    def status(self, s: str) -> None:
        self.q.put(("status", s))

    def go(self) -> None:
        try:
            self._go()
        except Stop as e:
            log(f"stopped: {e}")
            self.q.put(("card", f"Stopped: {e}"))
        except Exception as e:                   # the window must always say something
            log(f"crashed: {e.__class__.__name__}: {e}")
            self.q.put(("card", f"Lore gatherer crashed: {e.__class__.__name__}: {e}"))

    def _go(self) -> None:
        rgb, layout, th = settle(self.win)
        acct = fanid.account(rgb, layout) or "unknown"
        who = identify(self.win, rgb, layout, self.status)
        if not who["handle"]:
            raise Stop("couldn't read his @handle from the name popup. Nothing was saved. "
                       "Is the chat header visible?")
        handle = who["handle"]
        fanstore.set_identity(acct, handle, who["name"], who["tags"] or None)
        self.q.put(("fan", f"{who['name']} @{handle}"))
        log(f"start {acct}/@{handle} {who['name']!r} rule={self.rule} {self.arg}")
        fields = (T.read_panel(rgb, layout) or {}).get("fields", {}) \
            if layout.region[0] < T.WORK_LIST_MIN_X else {}
        fanstore.set_insights(acct, handle, fields)
        if layout.region[0] < T.WORK_LIST_MIN_X:     # harvest windows only: never your work pane
            self.status("reading his notes…")
            try:
                notes = read_notes(self.win, rgb, layout)
                if notes is not None:
                    fanstore.set_identity(acct, handle, notes=notes)   # latest copy only
            except Stop as e:
                log(f"notes skipped: {e}")

        moved = fanstore.promote(acct, handle, who["name"])   # his provisional file, if any
        if moved:
            log(f"promoted {moved} provisional read(s) into @{handle}")
        pages, stopped = self._read_up(acct, handle, who["name"])
        self.status(f"writing his note ({len(fanstore.load(acct, handle)['turns'])} messages)…")
        note, err = autonote.write_note(acct, handle, f"{pages} page(s) read this run · {stopped}")
        self.q.put(("card", note or f"No note: {err}"))

    def _read_up(self, acct: str, handle: str, name: str) -> tuple[int, str]:
        win = self.win
        rgb, layout, th = settle(win)
        x, y, w, h = layout.region
        px, py = x + w // 2, y + h // 2
        notches = max(2, round(PAGE_SHARE * h / (NOTCH_PX * layout.scale)))
        fanstore._prev["key"] = None             # the first page is the bottom: fresh
        fanstore.record(acct, handle, {"at": time.time(), "name": name, "fresh": True,
                                       "turns": [_strip(t) for t in read_page(rgb, layout)]})
        verdict: dict = {}
        checker = None
        checked = 0
        pages = stuck = 0
        while True:
            turns = fanstore.load(acct, handle)["turns"]
            if self.rule == "ai":
                if verdict.get("enough"):
                    return pages, "the AI had enough"
                if pages >= AI_MAX_PAGES:
                    return pages, f"stopped at {AI_MAX_PAGES} pages"
                if (checker is None or not checker.is_alive()) and pages >= FIRST_CHECK and pages > checked:
                    checked = pages
                    snap = render(turns)

                    def check(s=snap):
                        ok, missing = ask_enough(s)
                        verdict.update(enough=ok, missing=missing)
                    checker = threading.Thread(target=check, daemon=True)
                    checker.start()
            elif done(self.rule, self.arg, turns):
                return pages, "stop rule met"
            self.status(f"reading up: page {pages + 1}, {len(turns)} messages kept"
                        + (f" — still missing: {verdict['missing']}" if verdict.get("missing") else ""))
            win.wheel(px, py, notches)
            rgb, layout, th2 = settle(win)
            if T.thumb_diff(th, th2) < SETTLE_DIFF:
                stuck += 1
                if stuck >= TOP_TRIES:
                    return pages, "reached the first message"
                time.sleep(TOP_WAIT_S)           # older messages loading
                continue
            stuck = 0
            th = th2
            pages += 1
            why = fanstore.record(acct, handle, {"at": time.time(), "name": name,
                                                 "turns": [_strip(t) for t in read_page(rgb, layout)]})
            if why:
                log(f"page {pages}: {why}")


def _strip(t: dict) -> dict:
    return {k: v for k, v in t.items() if k not in ("box", "repaired")}


# ── window choice ────────────────────────────────────────────────────────────
def target_window() -> tuple[int, str] | None:
    """The Infloww window it was run from (foreground), else a harvest window."""
    fg = u32.GetForegroundWindow()
    wins = T._matching_windows("Infloww Messages")
    for hwnd, title in wins:
        if hwnd == fg:
            return hwnd, title
    for hwnd, title in wins:                     # a window with no chat list
        rgb = T._pinger.print_window(hwnd)
        lay = rgb is not None and T.find_layout(rgb)
        if lay and lay.region[0] < T.WORK_LIST_MIN_X:
            return hwnd, title
    return None


# ── ui ───────────────────────────────────────────────────────────────────────
def _last() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"rule": "ai", "arg": ""}


def show() -> None:
    import tkinter as tk
    T.A.set_dpi_aware()
    target = target_window()
    root = tk.Tk()
    root.title("MMA Lore")                       # never "Infloww Messages"
    root.configure(bg="#1b1b1b")
    root.attributes("-topmost", True)
    root.geometry("520x620+40+80")
    bg, fg = "#1b1b1b", "#d9d9d9"
    if target is None:
        tk.Label(root, text="No Infloww Messages window with a chat open.", bg=bg, fg=fg).pack(pady=20)
        root.mainloop()
        return

    last = _last()
    pick = tk.Frame(root, bg=bg)
    pick.pack(fill="both", expand=True, padx=12, pady=10)
    tk.Label(pick, text="How far up?", bg=bg, fg="#8aa4ff", font=("Segoe UI", 11, "bold")).pack(anchor="w")
    var = tk.StringVar(value=last.get("rule", "ai"))
    for rid, label in RULES:
        tk.Radiobutton(pick, text=label, value=rid, variable=var, bg=bg, fg=fg, selectcolor="#2b2b2b",
                       activebackground=bg, activeforeground=fg, anchor="w").pack(fill="x")
    tk.Label(pick, text="N or date (e.g. 200, 3, Nov 1):", bg=bg, fg="#9a9a9a").pack(anchor="w", pady=(8, 0))
    arg = tk.Entry(pick, bg="#151515", fg=fg, insertbackground=fg, relief="flat")
    arg.insert(0, last.get("arg", ""))
    arg.pack(fill="x")
    tk.Label(pick, text="Enter = start · Esc = cancel", bg=bg, fg="#6a6a6a").pack(anchor="w", pady=(8, 0))

    status = tk.Label(root, text="", bg=bg, fg="#8aa4ff", anchor="w", justify="left", wraplength=496)
    txt = tk.Text(root, bg="#151515", fg=fg, wrap="word", relief="flat", font=("Segoe UI", 10), padx=8, pady=6)
    q: queue.Queue = queue.Queue()

    def start(_e=None):
        rule, a = var.get(), arg.get().strip()
        try:
            STATE.parent.mkdir(parents=True, exist_ok=True)
            STATE.write_text(json.dumps({"rule": rule, "arg": a}), encoding="utf-8")
        except OSError:
            pass
        pick.destroy()
        status.pack(fill="x", padx=10, pady=(8, 4))
        txt.pack(fill="both", expand=True, padx=10, pady=(0, 6))
        bar = tk.Frame(root, bg=bg)
        bar.pack(fill="x", padx=10, pady=(0, 8))

        def copy():
            root.clipboard_clear()
            root.clipboard_append(txt.get("1.0", "end").strip())
        tk.Button(bar, text="Copy", command=copy, bg="#2b2b2b", fg=fg, relief="flat", padx=12).pack(side="left")
        tk.Button(bar, text="Close", command=root.destroy, bg="#2b2b2b", fg=fg, relief="flat", padx=12).pack(side="right")
        root.unbind("<Return>")
        status.config(text="starting…")
        threading.Thread(target=Run(q, rule, a, *target).go, daemon=True).start()

    root.bind("<Return>", start)
    root.bind("<Escape>", lambda e: root.destroy())
    arg.focus_set()

    def pump():
        try:
            while True:
                kind, val = q.get_nowait()
                if kind == "status":
                    status.config(text=val)
                elif kind == "fan":
                    root.title(f"MMA Lore — {val}")
                elif kind == "card":
                    status.config(text="done")
                    txt.delete("1.0", "end")
                    txt.insert("1.0", val)
        except queue.Empty:
            pass
        root.after(150, pump)

    root.after(150, pump)
    root.mainloop()


# ── checks ───────────────────────────────────────────────────────────────────
def selftest() -> int:
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    now = datetime(2026, 11, 24, 12, 0)
    check("when", when({"day": "Nov 20", "time": "9:10 am"}, now), datetime(2026, 11, 20, 9, 10))
    check("when pm", when({"day": "Nov 21", "time": "3:52 pm"}, now), datetime(2026, 11, 21, 15, 52))
    check("when last year", when({"day": "Dec 30", "time": "1:00 am"}, now), datetime(2025, 12, 30, 1, 0))
    check("when unknown", when({"time": "9:10 am"}, now), None)
    p = lambda day, tm: {"price": "20", "paid": True, "day": day, "time": tm}
    turns = [p("Nov 1", "1:00 am"), p("Nov 1", "3:00 am"), p("Nov 5", "1:00 am"), p("Nov 20", "9:00 pm")]
    check("events", len(spending_events(turns)), 3)
    check("done msgs", done("msgs", "3", turns), True)
    check("done events (2 wanted, 3 seen)", done("events", "2", turns), True)
    check("done events (3 wanted)", done("events", "3", turns), False)
    check("done date", done("date", "Nov 2", turns), True)
    check("done date earlier", done("date", "Oct 20", turns), False)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


def dev(pages: int) -> int:
    """Read `pages` pages up in the background on a harvest window, printing how
    each page stitched. Uses a temp FanData; no click, no LLM."""
    import tempfile
    T.A.set_dpi_aware()
    tmp = Path(tempfile.mkdtemp(prefix="lore_dev_"))
    fanstore._setting = lambda s, k, d="": str(tmp) if (s, k) == ("FanData", "Root") else d
    tgt = None
    for hwnd, title in T._matching_windows("Infloww Messages"):
        rgb = T._pinger.print_window(hwnd)
        lay = rgb is not None and T.find_layout(rgb)
        if lay and lay.region[0] < T.WORK_LIST_MIN_X and hwnd != u32.GetForegroundWindow():
            tgt = (hwnd, title)
    if not tgt:
        print("no background harvest window ('Open in new tab') found")
        return 1
    run = Run(queue.Queue(), "whole", "", *tgt)
    orig = fanstore.record

    def rec(acct, handle, r):
        why = orig(acct, handle, r)
        print(f"page: {len(r['turns'])} turns read -> {why or 'stitched'}; "
              f"{len(fanstore.load(acct, handle)['turns'])} kept, "
              f"{len(fanstore.load(acct, handle)['islands'])} islands")
        return why
    fanstore.record = rec
    left = {"n": pages}
    real = fanstore.load

    def load(a, h):
        d = real(a, h)
        left["n"] -= 1
        if left["n"] < 0:
            raise Stop("dev page limit")
        return d
    fanstore.load = load
    rgb, layout, _ = settle(run.win)
    try:
        run._read_up(fanid.account(rgb, layout) or "dev", "dev", T.read_fan_name(rgb, layout))
    except Stop as e:
        print("stop:", e)
    fanstore.load = real
    d = real(fanid.account(rgb, layout) or "dev", "dev")
    print("\n".join(render(d["turns"]).splitlines()[:60]))
    print(f"... {len(d['turns'])} turns, {len(d['islands'])} islands, folder {tmp}")
    return 0


if __name__ == "__main__":
    if "--test" in sys.argv:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.exit(selftest())
    if "--dev" in sys.argv:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.exit(dev(int(sys.argv[sys.argv.index("--dev") + 1])))
    show()
