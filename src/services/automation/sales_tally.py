"""
sales_tally.py — total one chatter's shift from Infloww's Notifications ▸ Purchases.

You open Notifications ▸ Purchases yourself, then press [automation] countSales
(^+#s by default). It scrolls the list from the top, reads every card, and stops
once STOP_AFTER cards IN A ROW were answered by someone other than the chatter on
the top card. A single card answered by someone else (a manager stepping in) does
not end the shift; it is totalled under that person's name instead.

MPPV sales are not the chatter's: any amount listed for the account under
[SalesTally] MppvN in mass_gui.cfg (N = the model's slot, set in the Tools window)
is set aside and shown on its own line, never silently dropped.

The panel is MEASURED on every frame, from the 1px #444444 rules between cards,
so it works at any window size or zoom: the 1920x1032 constants the first version
used are why it never ran on the real (2753x1105) window. Data comes from the
screen only, never Infloww's internals.

Run:
  python sales_tally.py --test        # offline: the fixture + the stop rule
  python sales_tally.py               # live: same as the hotkey, prints too
"""
from __future__ import annotations

import configparser
import ctypes
import hashlib
import re
import sys
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

import numpy as np

import automation as A

# --------------------------------------------------------------------- config --
DIVIDER_RGB = 0x44                  # the 1px rule between cards
DIVIDER_TOL = 18                    # summed over RGB
DIVIDER_MIN_W = 300                 # a real divider is ~460px at 1x, 779 at 1.65x
PANEL_BG = 0x26                     # the panel's fill, either side of every divider
PANEL_BG_TOL = 6
# The Quick reply box on an UNANSWERED card has a #444444 border too, ~0.72x the
# divider's width. Dividers all share one exact x-extent, so grouping by extent and
# taking the biggest group keeps them apart without a width threshold.
EXTENT_SNAP = 3

CARD_H_1X = 162                     # an answered card at 100% zoom; gives the scale
NOTCH_CSS_PX = 100                  # Chromium's wheel step, in CSS pixels
SCROLL_FRACTION = 0.5               # move at most half the visible list per pass
SETTLE_S = 0.9
LAZY_LOAD_WAIT_S = 1.5
IDLE_PASSES = 4                     # no new card AND the thumb still, this many times
MAX_PASSES = 400

STOP_AFTER = 3                      # cards in a row by someone else = shift over

SCROLLBAR_RGB = 0x66
SCROLLBAR_TOL = 40
SCROLLBAR_SEARCH = 90               # px right of the dividers to look for the thumb

HERE = Path(__file__).resolve().parent
MMA_CFG = A.MMA_USERDATA / "mass_gui.cfg"
ACTIVE_NOW = A.MMA_USERDATA / "active_now.ini"
RESULT_LOG = A.MMA_USERDATA / "sales_tally.txt"
FIXTURE = HERE / "testdata" / "purchases_panel.png"

PROGRESS_TITLE = "MMA_SALES_TALLY"


# ------------------------------------------------------------------- settings --
def _cfg() -> configparser.ConfigParser:
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    for enc in ("utf-16", "utf-8-sig"):          # AHK writes UTF-16; be lenient
        try:
            cp.read(MMA_CFG, encoding=enc)
            return cp
        except (UnicodeError, configparser.Error):
            cp = configparser.ConfigParser(interpolation=None, strict=False)
    return cp


def active_account() -> str:
    """The model MMA says is on screen (active_now.ini), or ""."""
    try:
        rows = ACTIVE_NOW.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return ""
    a = dict(r.split("=", 1) for r in rows if "=" in r)
    return a.get("name", "").strip() if a.get("state", "").strip() == "ok" else ""


def parse_prices(raw: str) -> set[Decimal]:
    """'20, 25.5' -> {Decimal('20.00'), Decimal('25.50')}. Junk is skipped."""
    out = set()
    for tok in re.split(r"[,\s;|]+", raw or ""):
        tok = tok.strip().lstrip("$")
        if not tok:
            continue
        try:
            out.add(Decimal(tok).quantize(Decimal("0.01")))
        except InvalidOperation:
            pass
    return out


def settings(account: str) -> dict:
    """{stop_after, mppv} for this account. The model's SLOT keys its prices."""
    cp = _cfg()
    st = "SalesTally"
    try:
        stop = max(1, int(cp.get(st, "StopAfter", fallback=str(STOP_AFTER))))
    except ValueError:
        stop = STOP_AFTER
    mppv: set = set()
    if account:
        for i in range(1, 13):
            if cp.get("Settings", f"Model{i}", fallback="").strip().lower() == account.lower():
                mppv = parse_prices(cp.get(st, f"Mppv{i}", fallback=""))
                break
    return {"stop_after": stop, "mppv": mppv}


# --------------------------------------------------------------------- layout --
def _runs(row: np.ndarray, min_len: int) -> list[tuple[int, int]]:
    """(x0, x1) of every True run at least min_len long."""
    xs = np.flatnonzero(row)
    if len(xs) < min_len:
        return []
    br = np.flatnonzero(np.diff(xs) > 1)
    starts = np.r_[xs[0], xs[br + 1]]
    ends = np.r_[xs[br], xs[-1]]
    return [(int(a), int(b)) for a, b in zip(starts, ends) if b - a + 1 >= min_len]


def _is_bg(px) -> bool:
    return bool(np.abs(px.astype(int) - PANEL_BG).sum() <= PANEL_BG_TOL * 3)


def find_list(rgb: np.ndarray) -> dict | None:
    """Locate the Purchases list on this frame, or None if it is not up.

    {x0, x1}  the divider extent — the card's text column (avatars sit left of it)
    ys        every divider's y, top to bottom
    scale     device pixels per CSS pixel, from the card height
    sb_x      the scrollbar's column, or None if the list does not overflow
    thumb     the scrollbar thumb's (y0, y1), or None
    """
    h, w, _ = rgb.shape
    m = np.abs(rgb.astype(np.int16) - DIVIDER_RGB).sum(2) <= DIVIDER_TOL
    groups: dict = {}
    for y in np.flatnonzero(m.sum(1) >= DIVIDER_MIN_W):
        for x0, x1 in _runs(m[y], DIVIDER_MIN_W):
            # Panel fill on all four sides: rejects the full-width rule under the
            # tab row (it touches the frame edge) and any long line in the chat pane.
            if x0 < 4 or x1 > w - 5 or y < 2 or y > h - 3:
                continue
            mid = (x0 + x1) // 2
            if not all(_is_bg(rgb[yy, xx]) for yy, xx in
                       ((y, x0 - 3), (y, x1 + 3), (y - 2, mid), (y + 2, mid))):
                continue
            key = next((k for k in groups if abs(k[0] - x0) <= EXTENT_SNAP
                        and abs(k[1] - x1) <= EXTENT_SNAP), (x0, x1))
            groups.setdefault(key, []).append(int(y))
    groups = {k: v for k, v in groups.items() if len(v) >= 2}
    if not groups:
        return None
    (x0, x1), ys = max(groups.items(), key=lambda kv: (len(kv[1]), kv[0][1] - kv[0][0]))
    ys = sorted(set(ys))
    scale = max(1.0, min(np.diff(ys)) / CARD_H_1X)

    sb_x, thumb = None, None
    band = rgb[ys[0]:ys[-1] + 1, x1 + 4:min(w, x1 + SCROLLBAR_SEARCH)].astype(np.int16)
    sm = np.abs(band - SCROLLBAR_RGB).sum(2) <= SCROLLBAR_TOL
    cols = np.flatnonzero(sm.sum(0) >= 20)
    if len(cols):
        sb_x = x1 + 4 + int(np.median(cols))
        rows = np.flatnonzero(sm[:, cols].sum(1) >= max(2, len(cols) // 2))
        if len(rows):
            thumb = (ys[0] + int(rows.min()), ys[0] + int(rows.max()))
    return {"x0": x0, "x1": x1, "ys": ys, "scale": float(scale),
            "sb_x": sb_x, "thumb": thumb}


# ---------------------------------------------------------------------- cards --
_OCR_CACHE: dict = {}


def read_cards(rgb: np.ndarray, lay: dict) -> list[dict]:
    """Every COMPLETE card on screen, top to bottom.

    Only bands between two dividers: the part-cards clipped at the top and bottom
    would parse short. A card fully in view is pixel-identical from pass to pass,
    so its OCR is cached by content — the list is read about twice per card.
    """
    out = []
    for a, b in zip(lay["ys"], lay["ys"][1:]):
        crop = rgb[a + 2:b - 1, lay["x0"]:lay["x1"] + 1]
        key = hashlib.md5(crop.tobytes() + bytes(str(crop.shape), "ascii")).hexdigest()
        if key not in _OCR_CACHE:
            c = A.parse_purchase_card(rgb, a + 2, b - 2, (lay["x0"], lay["x1"]))
            _OCR_CACHE[key] = c
        out.append(_OCR_CACHE[key])
    return out


def card_key(c: dict) -> tuple:
    """Who bought, when, how much. OCR spaces the date differently between reads
    ('Nov.1,2026at8:30PM' / 'Nov. 1, 2026 at 8:30 PM'), so it is normalised."""
    return (c["handle"], A._norm(c["ts"] or ""), str(c["amount"]))


def merge(seq: list, screen: list) -> tuple[int, bool]:
    """Append the cards of `screen` that `seq` has not got. Returns (added, overlapped).

    The list is ordered, so a new screen is the tail of what we have plus new cards
    below it. Aligning on the longest such overlap — rather than a set of seen keys —
    keeps two genuinely identical cards (same fan, same price, same minute).
    """
    if not seq:
        seq.extend(screen)
        return len(screen), True
    keys = [card_key(c) for c in screen]
    tail = [card_key(c) for c in seq[-len(screen):]]
    for k in range(min(len(keys), len(tail)), 0, -1):
        if tail[-k:] == keys[:k]:
            seq.extend(screen[k:])
            return len(screen) - k, True
    seq.extend(screen)
    return len(screen), False


# ---------------------------------------------------------------- attribution --
def attribute(cards: list, target: str | None, stop_after: int, mppv: set) -> dict:
    """Split the cards read so far into the shift's figures.

    target       whose shift; None = whoever answered the first card
    stop_after   this many cards IN A ROW by anyone else ends the shift; fewer
                 (a manager answering once) are credited to them by name
    mppv         prices that are mass PPVs, set aside for every chatter

    Unanswered cards neither extend nor break a run; they are listed apart,
    except ones that fell inside the run that ended the shift.
    """
    norm = A._norm
    by: dict = {}                       # display name -> [cards]
    unanswered, unreadable, mppv_cards = [], [], []
    run, run_unanswered = [], []
    stopped = None
    for c in cards:
        who = c["responder"]
        if not who:
            (run_unanswered if run else unanswered).append(c)
            continue
        if target is None:
            target = who
        if norm(who) == norm(target):
            for o in run:
                by.setdefault(o["responder"], []).append(o)
            unanswered += run_unanswered
            run, run_unanswered = [], []
            by.setdefault(target, []).append(c)
            continue
        run.append(c)
        if len(run) >= stop_after:
            stopped = run[0]
            break
    if not stopped:                     # the list ended inside a short run
        for o in run:
            by.setdefault(o["responder"], []).append(o)
        unanswered += run_unanswered

    totals = {}
    for name, cs in by.items():
        sales = []
        for c in cs:
            if c["amount"] is None:
                unreadable.append(c)
            elif c["amount"] in mppv:
                mppv_cards.append(c)
            else:
                sales.append(c)
        totals[name] = {"cards": sales, "total": sum((c["amount"] for c in sales), Decimal("0"))}
    mine = [c for c in by.get(target, [])] if target else []
    times = [c["ts"] for c in mine if c["ts"]]
    return {"target": target, "by": totals, "stopped_on": stopped,
            "mppv": mppv_cards, "mppv_total": sum((c["amount"] for c in mppv_cards), Decimal("0")),
            "unanswered": unanswered, "unreadable": unreadable,
            "first": times[-1] if times else None, "last": times[0] if times else None}


# ------------------------------------------------------------------------ run --
def tally(get_frame, scroll, target=None, stop_after=STOP_AFTER, mppv=frozenset(),
          should_stop=lambda: None, progress=lambda r: None) -> dict:
    """Read down the list until the shift ends or the list does.

    get_frame()     -> RGB array of the window
    scroll(lay)     scroll the list down about half a screen
    should_stop()   -> a reason string to abort (Esc, focus lost), or None
    """
    seq: list = []
    problems: list = []
    reason = f"hit the {MAX_PASSES}-pass safety cap"
    prev_thumb, idle, passes = None, 0, 0
    r = attribute([], target, stop_after, mppv)
    for passes in range(1, MAX_PASSES + 1):
        why = should_stop()
        if why:
            reason = why
            break
        rgb = get_frame()
        lay = find_list(rgb)
        if lay is None:
            reason = "the Purchases list is not on screen"
            if passes > 1:
                problems.append("the panel closed mid-run")
            break
        screen = read_cards(rgb, lay)
        if passes == 1 and not any("purchased" in A._norm(c["text"]) for c in screen):
            reason = "this is not the Purchases tab"
            break
        added, overlapped = merge(seq, screen)
        if not overlapped:
            problems.append(f"pass {passes}: no overlap with the previous screen - "
                            f"a card may have been skipped")
        r = attribute(seq, target, stop_after, mppv)
        progress(r)
        if r["stopped_on"]:
            reason = f"{stop_after} in a row answered by someone else"
            break
        # Both must stall: a lazy-load fetch in flight also adds no card, but the
        # thumb keeps moving or shrinking until the true bottom. No thumb at all =
        # the list fits on screen, so scrolling can never show more.
        thumb = lay["thumb"]
        if added == 0 and (thumb is None or thumb == prev_thumb):
            idle += 1
            if idle >= IDLE_PASSES or lay["sb_x"] is None:
                reason = "the end of the list"
                break
            time.sleep(LAZY_LOAD_WAIT_S)
        else:
            idle = 0
        prev_thumb = thumb
        scroll(lay)
    r.update(reason=reason, problems=problems, passes=passes, cards_read=len(seq))
    return r


def pretty_ts(ts: str | None) -> str:
    """'Nov.1,2026at8:30PM' -> 'Nov 1, 8:30 PM'; anything else unchanged."""
    m = re.search(r"([A-Z][a-z]{2})\.?\s*(\d{1,2}),\s*\d{4}\s*at\s*(\d{1,2}:\d{2})\s*([AP]M)", ts or "")
    return f"{m[1]} {m[2]}, {m[3]} {m[4]}" if m else (ts or "?")


def report(r: dict, account: str, mppv: set) -> str:
    def money(d):
        return f"${d:,.2f}"
    lines = []
    t = r["target"]
    if not t:
        return f"No answered purchases found ({r['reason']})."
    mine = r["by"].get(t, {"cards": [], "total": Decimal("0")})
    span = f"  {pretty_ts(r['first'])} - {pretty_ts(r['last'])}" if r["first"] else ""
    lines.append(f"{t}: {money(mine['total'])}  ({len(mine['cards'])} sales){span}")
    if account:
        lines.append(f"Account {account}")
    lines.append("")
    for name, v in r["by"].items():
        if name != t and v["cards"]:
            lines.append(f"Also in the shift - {name}: {money(v['total'])} ({len(v['cards'])})")
    if r["mppv"]:
        pr = ", ".join(f"${p}" for p in sorted(mppv))
        lines.append(f"MPPV, not counted ({pr}): {money(r['mppv_total'])} ({len(r['mppv'])})")
    elif not mppv:
        lines.append(f"No MPPV prices set for {account or 'this account'} - nothing excluded")
    if r["unanswered"]:
        u = sum((c["amount"] for c in r["unanswered"] if c["amount"]), Decimal("0"))
        lines.append(f"Nobody answered, not counted: {money(u)} ({len(r['unanswered'])})")
    for c in r["unreadable"]:
        lines.append(f"! unreadable amount: {c['handle']} {pretty_ts(c['ts'])}")
    for p in r["problems"]:
        lines.append(f"! {p}")
    s = r["stopped_on"]
    if s:
        lines.append(f"Stopped at {s['responder']} ({pretty_ts(s['ts'])}): {r['reason']}")
    else:
        lines.append(f"Stopped: {r['reason']}")
    lines.append("")
    for c in mine["cards"]:
        lines.append(f"  {money(c['amount']):>10}  {pretty_ts(c['ts']):<16} {c['handle'] or '?'}")
    return "\n".join(lines)


# ----------------------------------------------------------------------- live --
def _progress_window(rect):
    """A small non-activating box at the window's bottom right: it must never take
    focus from Infloww (the run stops when Infloww loses it), and it sits far from
    the panel, which opens on the left, so the capture never reads it."""
    import tkinter as tk
    win = tk.Tk()
    win.title(PROGRESS_TITLE)
    win.overrideredirect(True)
    win.attributes("-topmost", True)
    win.configure(bg="#151515")
    w, h = 420, 64
    win.geometry(f"{w}x{h}+{rect[0] + rect[2] - w - 40}+{rect[1] + rect[3] - h - 40}")
    var = tk.StringVar(value="Counting sales…")
    tk.Label(win, textvariable=var, bg="#151515", fg="#d9d9d9",
             font=("Segoe UI", 12, "bold")).pack(pady=(8, 0))
    tk.Label(win, text="Esc stops", bg="#151515", fg="#8a8a8a",
             font=("Segoe UI", 9)).pack()
    win.update()
    hwnd = A.u32.FindWindowW(None, PROGRESS_TITLE)
    if hwnd:
        ex = A.u32.GetWindowLongW(hwnd, A.GWL_EXSTYLE)
        A.u32.SetWindowLongW(hwnd, A.GWL_EXSTYLE, ex | A.WS_EX_NOACTIVATE | A.WS_EX_TOOLWINDOW)
    return win, var


def _result_window(text: str) -> None:
    import tkinter as tk
    win = tk.Tk()
    win.title("Sales tally")
    win.attributes("-topmost", True)
    win.configure(bg="#151515")
    head, _, rest = text.partition("\n")
    tk.Label(win, text=head, bg="#151515", fg="#7ee08a", font=("Segoe UI", 16, "bold"),
             anchor="w", justify="left").pack(fill="x", padx=16, pady=(14, 4))
    box = tk.Text(win, bg="#151515", fg="#d9d9d9", font=("Consolas", 10), relief="flat",
                  width=78, height=min(32, rest.count("\n") + 2))
    box.insert("1.0", rest)
    box.configure(state="disabled")
    box.pack(fill="both", expand=True, padx=16)
    bar = tk.Frame(win, bg="#151515")
    bar.pack(fill="x", padx=16, pady=12)

    def copy():
        win.clipboard_clear()
        win.clipboard_append(text)
    tk.Button(bar, text="Copy", command=copy, width=10).pack(side="left")
    tk.Button(bar, text="Close", command=win.destroy, width=10).pack(side="right")
    win.bind("<Escape>", lambda _e: win.destroy())
    win.mainloop()


def run_live(rect, target=None, show=True) -> str:
    account = active_account()
    cfg = settings(account)
    win, var = _progress_window(rect) if show else (None, None)

    def get_frame():
        return A.grab(rect)

    def scroll(lay):
        # The cursor rests on the SCROLLBAR, not a card: the wheel scrolls the list
        # from there, and no card is hovered, so none is repainted mid-capture.
        notch_px = NOTCH_CSS_PX * lay["scale"]
        visible = lay["ys"][-1] - lay["ys"][0]
        notches = max(1, int(visible * SCROLL_FRACTION // notch_px))
        A.u32.SetCursorPos(rect[0] + lay["sb_x"], rect[1] + (lay["ys"][0] + lay["ys"][-1]) // 2)
        time.sleep(0.05)
        for _ in range(notches):
            A.u32.mouse_event(A.MOUSEEVENTF_WHEEL, 0, 0, ctypes.c_int(-A.WHEEL_DELTA), 0)
            time.sleep(0.12)
        end = time.time() + SETTLE_S
        while time.time() < end:
            if win:
                win.update()
            time.sleep(0.05)

    def should_stop():
        if win:
            win.update()
        if A.abort_pressed():
            return "stopped by Esc"
        if A.TARGET_TITLE.lower() not in A.foreground_title().lower():
            return "Infloww Messages lost focus"
        return None

    def progress(r):
        if var is None or not r["target"]:
            return
        mine = r["by"].get(r["target"])
        if mine:
            var.set(f"{r['target']}: ${mine['total']:,.2f}  ·  {len(mine['cards'])} sales")
        win.update()

    _OCR_CACHE.clear()
    try:
        r = tally(get_frame, scroll, target, cfg["stop_after"], cfg["mppv"],
                  should_stop, progress)
    finally:
        if win:
            win.destroy()
    text = report(r, account, cfg["mppv"])
    try:
        with RESULT_LOG.open("a", encoding="utf-8") as f:
            f.write(f"=== {datetime.now():%Y-%m-%d %H:%M} ===\n{text}\n\n")
    except OSError as e:
        print(f"  ! could not write {RESULT_LOG}: {e}")
    print(text)
    if show:
        _result_window(text)
    return text


def action(rect, args) -> None:
    """[automation] countSales."""
    run_live(rect, getattr(args, "who", None))


# ---------------------------------------------------------------------- tests --
def _card(who, amount, ts="t", handle="@f"):
    return {"responder": who, "amount": None if amount is None else Decimal(amount),
            "ts": ts, "handle": handle, "text": ""}


def _test() -> int:
    fails = 0

    def ok(name, got, want):
        nonlocal fails
        print(("ok  " if got == want else "FAIL"), name, "" if got == want else f"got {got!r}")
        fails += got != want

    def tot(r, who):
        return str(r["by"].get(who, {"total": Decimal("0")})["total"])

    cs = [_card("smol", "61.00", "1"), _card("ann", "10.00", "2"), _card("smol", "33.00", "3"),
          _card("bob", "5.00", "4"), _card("bob", "7.00", "5"), _card("bob", "9.00", "6"),
          _card("smol", "100.00", "7")]
    r = attribute(cs, None, 3, set())
    ok("target = top responder", r["target"], "smol")
    ok("one card by someone else does not stop", tot(r, "smol"), "94.00")
    ok("... it is credited to them", tot(r, "ann"), "10.00")
    ok("three in a row stops", r["stopped_on"]["ts"], "4")
    ok("the stopping run is not counted", "bob" in r["by"], False)
    r = attribute(cs, None, 4, set())
    ok("StopAfter 4: bob's three are an interruption", tot(r, "smol"), "194.00")
    r = attribute(cs, None, 3, {Decimal("33.00")})
    ok("MPPV price set aside", (tot(r, "smol"), str(r["mppv_total"])), ("61.00", "33.00"))
    r = attribute([_card("smol", "5.00"), _card(None, "9.00"), _card("smol", "5.00"),
                   _card("x", "1.00"), _card(None, "2.00"), _card("x", "1.00"), _card("x", "1.00")],
                  None, 3, set())
    ok("unanswered inside the shift listed", [str(c["amount"]) for c in r["unanswered"]], ["9.00"])
    ok("parse_prices", sorted(map(str, parse_prices("20, $25.5 ;x"))), ["20.00", "25.50"])

    seq = [_card("a", "1.00", "1", "@a"), _card("a", "2.00", "2", "@b")]
    merge(seq, [_card("a", "2.00", "2", "@b"), _card("a", "3.00", "3", "@c")])
    ok("merge appends past the overlap", [c["ts"] for c in seq], ["1", "2", "3"])
    seq = [_card("a", "20.00", "1", "@a")]
    merge(seq, [_card("a", "20.00", "1", "@a"), _card("a", "20.00", "1", "@a")])
    ok("merge keeps a real duplicate", len(seq), 2)

    # The real panel (2026-11-02, 11 cards by smol), read through a 900px viewport
    # that scrolls down it, the way the live run sees it.
    from PIL import Image
    img = np.array(Image.open(FIXTURE).convert("RGB"))
    vh, off = 900, [0]

    def frame():
        return img[off[0]:off[0] + vh].copy()

    def scroll(lay):
        off[0] = min(img.shape[0] - vh, off[0] + int((lay["ys"][-1] - lay["ys"][0]) * SCROLL_FRACTION))

    lay = find_list(img)
    ok("fixture: 12 dividers", len(lay["ys"]), 12)
    ok("fixture: scrollbar found", lay["sb_x"] is not None, True)
    r = tally(frame, scroll, None, 3, {Decimal("20.00")})
    mine = r["by"].get("smol", {"cards": [], "total": None})
    ok("fixture: 11 cards read once each", r["cards_read"], 11)
    ok("fixture: smol's total without $20 MPPV", str(mine["total"]), "787.69")
    ok("fixture: MPPV", (len(r["mppv"]), str(r["mppv_total"])), (4, "80.00"))
    ok("fixture: no problems", r["problems"], [])
    print(report(r, "TEST", {Decimal("20.00")}))
    print("all ok" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--test", action="store_true", help="offline checks against the fixture")
    ap.add_argument("--who", help="whose shift (default: whoever answered the top card)")
    a = ap.parse_args(argv)
    if a.test:
        return _test()
    A.set_dpi_aware()
    try:
        _, rect = A.require_window(force=True)    # measured per frame; any size works
    except A.WindowNotReady as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    run_live(rect, a.who)
    return 0


if __name__ == "__main__":
    sys.exit(main())
