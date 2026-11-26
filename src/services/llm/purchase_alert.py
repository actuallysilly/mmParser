"""
llm/purchase_alert.py — play a sound when a fan buys something.

Infloww puts the sale INTO the open chat, as a grey bubble with a bell on the
left (seen on the 2026-04-09 recording, 2h10m in):

    Purchased
    has purchased your message for $199.99!
    9:11 PM

The chat reader already OCRs the pane every time it changes, so a new bubble
reaches us within ~1.5s. This only decides which bubbles are NEW: the same sale
is read again on every later scroll, and opening a fan who bought an hour ago
shows his old bubbles too. Neither should ring.

LIVE Infloww (every shift from 2026-10-22 on) never showed that bubble. Two
things happen instead:

  * a popup in the window's top-right corner, the moment the fan pays
    (seen on the 2026-10-30 recording, 04:14:39):

        Chris @u100000002                                  (x)
        has purchased your message for $75.00!
        AW

    for ANY fan, open chat or not. This is the trigger (ToastWatch).
  * the PPV's footer pill going "$40.00 not paid" -> "$40.00 paid". The chat
    reader only sees that when the chat is on screen, which is usually minutes
    later, when you go back to him. It rang then, which is too late to be
    useful (Silly, 2026-10-30), so it no longer rings; check() still tracks it.

    ToastWatch.step(rgb)          -> the sale in a popup on this frame, once
    PurchaseWatch.check(state) -> the new sales in one chat_now.json state
    python purchase_alert.py --test    offline checks
    python purchase_alert.py --play    play the sound once

Sound: userdata\\sounds\\purchase.wav if it exists, else Windows' tada.wav.
Switch: Settings ▸ Features ▸ "Purchase sound" (PurchaseSound).
"""
from __future__ import annotations

import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
CUSTOM_SOUND = MMA_ROOT / "userdata" / "sounds" / "purchase.wav"
DEFAULT_SOUND = Path(r"C:\Windows\Media\tada.wav")

# "$" is unreliable in OCR (see UI-ELEMENT-MAP.md, Purchases), so it is optional,
# and so is the amount: a sale with an unreadable price still rings. So are the
# spaces: the popup has been read as "haspurchasedyourmessagefor $33.00".
SALE = re.compile(r"purchased\s*your(?:\s*\w*?\s*for\s*\$?\s*(?P<amt>\d[\d,]*(?:\.\d{1,2})?))?", re.I)
CLOCK = re.compile(r"\b(?P<h>\d{1,2}):(?P<m>\d{2})\s*(?P<ap>[ap])\.?\s*m\b", re.I)

# A bubble whose own time is this close to now is new, wherever it sits.
RECENT_S = 180
# Without a readable time: new only if it sits among the last few turns of a
# chat we have already been watching (sales arrive at the bottom).
NEAR_BOTTOM = 3


def bubble_time(turns: list[dict], i: int, now: float) -> float | None:
    """Epoch of the clock in the sale bubble (or the line just under it), or None."""
    for t in turns[i:i + 2]:
        for field in ("text", "footer", "time"):
            m = CLOCK.search(t.get(field) or "")
            if m:
                h = int(m["h"]) % 12 + (12 if m["ap"].lower() == "p" else 0)
                n = datetime.fromtimestamp(now)
                at = n.replace(hour=h, minute=int(m["m"]), second=0, microsecond=0)
                if at - n > timedelta(minutes=5):    # 11:59 pm read at 00:01
                    at -= timedelta(days=1)
                return at.timestamp()
    return None


class PurchaseWatch:
    def __init__(self) -> None:
        self.counts: dict[tuple, int] = {}    # (title, fan, amount) -> most seen in one read
        self.chats: set[tuple] = set()        # (title, fan) read at least once
        self.unpaid: set[tuple] = set()       # (title, fan, price, time) seen "not paid"
        self.rung: set[tuple] = set()         # PPVs already rung for

    def check(self, state: dict, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        turns = state.get("turns") or []
        chat = (state.get("title") or "", state.get("fan") or "")
        known = chat in self.chats
        self.chats.add(chat)

        hits: dict[str, list[int]] = {}
        for i, t in enumerate(turns):
            m = SALE.search(t.get("text") or "")
            if m:
                amt = (m["amt"] or "").replace(",", "")
                hits.setdefault(amt, []).append(i)

        new = []
        for t in turns:
            if not t.get("price") or "paid" not in t:
                continue
            key = chat + (t["price"], t.get("time") or "")
            if not t["paid"]:
                self.unpaid.add(key)
            elif key in self.unpaid and key not in self.rung:
                # Seen only once the chat is back on screen: too late to ring.
                self.rung.add(key)

        for amt, idx in hits.items():
            key = chat + (amt,)
            before = self.counts.get(key, 0)
            if len(idx) <= before:
                continue
            self.counts[key] = len(idx)
            # Two same-price sales in one chat: the extra one is the newest.
            for i in idx[before:]:
                at = bubble_time(turns, i, now)
                if at is not None:
                    fresh = abs(now - at) <= RECENT_S
                else:
                    fresh = known and i >= len(turns) - NEAR_BOTTOM
                if fresh:
                    new.append({"account": chat[0], "fan": chat[1], "amount": amt})
        return new


# ------------------------------------------------------------------ the popup --
# Measured on the 3440-wide recording: a #262626 card 464x150, 32px in from the
# right edge, 33px down. Infloww draws it at the same size at any window width.
TOAST_GREY = 38
TOAST_BOX = (40, 175, 480, 50)     # rows 40-175, cols from W-480 to W-50: inside the card
TOAST_CROP = (25, 190, 505, 20)    # a little more, for OCR
TOAST_FILL = 0.5                   # share of the box that must be that grey
HANDLE = re.compile(r"@\s*([\w.\-]+)")


def toast_shown(rgb) -> bool:
    """Cheap test, every frame: is a popup card in the top-right corner?"""
    import numpy as np
    y0, y1, l, r = TOAST_BOX
    w = rgb.shape[1]
    if rgb.shape[0] < y1 or w < l:
        return False
    box = rgb[y0:y1, w - l:w - r].astype(np.int16)
    return float((np.abs(box - TOAST_GREY).max(axis=2) <= 3).mean()) >= TOAST_FILL


def read_toast(rgb) -> str:
    """The popup's text, line by line (OCR, ~0.2s)."""
    import numpy as np
    import transcript as T
    y0, y1, l, r = TOAST_CROP
    w = rgb.shape[1]
    crop = np.ascontiguousarray(rgb[y0:y1, w - l:w - r][:, :, ::-1])   # RGB -> BGR
    res, _ = T.A.ocr_engine()(crop)
    return "\n".join(line[1] for line in sorted(res or [], key=lambda x: x[0][0][1]))


def parse_toast(text: str) -> dict | None:
    """{'fan', 'handle', 'amount'} for a sale popup, None for any other popup
    ("Message Pro will go idle in 0:09" shows up in the same spot). The name
    line is sometimes not read at all, or cut short ("Someonelongnarne...")."""
    m = SALE.search(text)
    if not m:
        return None
    head = " ".join(text[:m.start()].split())
    head = re.sub(r"\s*has\s*$", "", head, flags=re.I)
    h = HANDLE.search(head)
    fan = (head[:h.start()] if h else head).strip().rstrip(".…").strip()
    return {"fan": fan, "handle": (h[1].rstrip(".") if h else ""),
            "amount": (m["amt"] or "").replace(",", "")}


class ToastWatch:
    """Rings once per popup. One stays up ~7s, so it is on many frames in a
    row: it is read as soon as it appears, then every REREAD_S while it stays,
    in case another sale took its place. The name line is not always read, so
    within one popup the same AMOUNT counts as the same sale."""
    REREAD_S = 1.5

    def __init__(self, shown=toast_shown, read=read_toast) -> None:
        self._shown, self._read = shown, read
        self.amounts: set[str] = set()     # sales rung while this popup is up
        self.read_at: float | None = None   # None: this popup not read yet

    def step(self, rgb, now: float | None = None) -> dict | None:
        now = time.time() if now is None else now
        if not self._shown(rgb):
            self.amounts.clear()
            self.read_at = None
            return None
        if self.read_at is not None and now - self.read_at < self.REREAD_S:
            return None
        self.read_at = now
        sale = parse_toast(self._read(rgb))
        if sale is None or sale["amount"] in self.amounts:
            return None
        self.amounts.add(sale["amount"])
        return sale


def play() -> None:
    import winsound
    path = CUSTOM_SOUND if CUSTOM_SOUND.exists() else DEFAULT_SOUND
    try:
        winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
    except RuntimeError:
        winsound.MessageBeep(winsound.MB_ICONASTERISK)


# ---------------------------------------------------------------------- tests --
def _test() -> int:
    now = datetime(2026, 10, 24, 21, 12).timestamp()
    sale = {"who": "model", "text": "Purchased has purchased your message for $199.99! 9:11 PM"}
    old = {"who": "model", "text": "has purchased your message for $25.00!", "footer": "7:02 pm"}
    notime = {"who": "model", "text": "has purchased your message for 50.00!"}
    msg = lambda s: {"who": "fan", "text": s}                                    # noqa: E731
    st = lambda fan, *turns: {"title": "Infloww Messages - 333", "fan": fan,   # noqa: E731
                              "turns": list(turns)}
    fails = 0

    def ok(name, got, want):
        nonlocal fails
        print(("ok  " if got == want else "FAIL"), name, got if got != want else "")
        fails += got != want

    w = PurchaseWatch()
    ok("opening a chat with an old sale is silent", len(w.check(st("Atlas", msg("hi"), old), now)), 0)
    ok("a fresh sale rings, even on first open", [s["amount"] for s in w.check(st("Bo", msg("hi"), sale), now)], ["199.99"])
    ok("the same sale read again is silent", len(w.check(st("Bo", sale, msg("ty")), now)), 0)
    ok("scrolled out and back is silent", len(w.check(st("Bo", msg("x")), now) + w.check(st("Bo", sale), now)), 0)
    w.check(st("Cy", msg("hey"), msg("u there")), now)
    ok("no time, at the bottom of a watched chat: rings",
       [s["amount"] for s in w.check(st("Cy", msg("hey"), msg("u there"), notime), now)], ["50.00"])
    w.check(st("Di", msg("a"), msg("b"), msg("c"), msg("d")), now)
    ok("no time, scrolled up into view: silent",
       len(w.check(st("Di", notime, msg("a"), msg("b"), msg("c"), msg("d")), now)), 0)
    two = dict(sale, text="has purchased your message for $199.99! 9:12 PM")
    ok("a second same-price sale rings once", len(w.check(st("Bo", sale, msg("ty"), two), now)), 1)
    ok("midnight: 11:59 pm read at 00:01 is fresh",
       bubble_time([{"text": "11:59 PM"}], 0, datetime(2026, 10, 25, 0, 1).timestamp())
       == datetime(2026, 10, 24, 23, 59).timestamp(), True)
    ppv = lambda paid, price="40.00": {"who": "model", "text": "", "price": price,   # noqa: E731
                                       "paid": paid, "time": "9:41 pm"}
    w = PurchaseWatch()
    ok("a PPV first seen paid is silent", len(w.check(st("Ed", ppv(True, "15.00")), now)), 0)
    ok("a PPV seen unpaid is silent", len(w.check(st("Ed", ppv(False)), now)), 0)
    ok("the same PPV turning paid: silent (too late, the popup rang)",
       len(w.check(st("Ed", msg("hi"), ppv(True)), now)), 0)

    # The popup.
    for text, want in [
        ("Chris @u100000002\nhas purchased your message for $75.00!\nAW",
         {"fan": "Chris", "handle": "u100000002", "amount": "75.00"}),
        ("1300/mo $ notes notes notes ...\nhaspurchasedyourmessagefor $33.00\nAW",
         {"fan": "1300/mo $ notes notes notes", "handle": "", "amount": "33.00"}),
        ("has purchased your message for $40.00!\nAW", {"fan": "", "handle": "", "amount": "40.00"}),
        ("Someonelongnarne...\n@someonelongnarne..\nhas purchased your message for $55.00!\nAW",
         {"fan": "Someonelongnarne", "handle": "someonelongnarne", "amount": "55.00"}),
        ("Fanname\n@u100000003\nsubscribed to your profile!\nAW", None),
        ("Message Pro will go idle in 0:09\nFaninsights", None),
    ]:
        ok(f"popup {text.splitlines()[-2][:30]!r}", parse_toast(text), want)
    # A fake frame is the popup's text, None = no popup.
    tw = ToastWatch(shown=lambda f: f is not None, read=lambda f: f)
    steps = lambda *fs: [(s or {}).get("amount") for s in   # noqa: E731
                         (tw.step(f, t) for t, f in fs)]
    sale = "Chris @u100000002\nhas purchased your message for $75.00!\nAW"
    ok("popup rings once while it stays up",
       steps((0, None), (1, sale), (1.7, sale), (3.4, "has purchased your message for $75.00!"), (5, sale)),
       [None, "75.00", None, None, None])
    ok("gone and back: rings again", steps((6, None), (7, sale)), [None, "75.00"])
    ok("another sale in its place rings",
       steps((9, sale.replace("75.00", "40.00"))), ["40.00"])
    ok("a subscribe popup is silent", steps((11, None), (12, "subscribed to your profile!")), [None, None])

    # Real frames off the 2026-10-30 recording (top-right 640x240).
    try:
        import cv2
        here = Path(__file__).resolve().parent / "testdata"
        img = lambda n: cv2.imread(str(here / n))[:, :, ::-1]        # noqa: E731
        ok("frame: no popup", toast_shown(img("toast_none.png")), False)
        ok("frame: subscribe popup is a popup", toast_shown(img("toast_other.png")), True)
        ok("frame: subscribe popup is no sale", parse_toast(read_toast(img("toast_other.png"))), None)
        # testdata/ is local only (a real fan's popup), so the handle is
        # checked for its shape, not its value.
        got = parse_toast(read_toast(img("toast_sale.png"))) or {}
        ok("frame: sale popup read",
           (got.get("fan"), bool(re.fullmatch(r"u\d{6,}", got.get("handle", ""))), got.get("amount")),
           ("Chris", True, "75.00"))
    except ImportError as e:
        print("skip frame tests:", e)
    ok("OCR without $", SALE.search("has purchased your message for 1999.99!")["amt"], "1999.99")
    return 1 if fails else 0


if __name__ == "__main__":
    if "--test" in sys.argv:
        sys.exit(_test())
    if "--play" in sys.argv:
        play()
        time.sleep(3)          # SND_ASYNC: stay alive long enough to hear it
