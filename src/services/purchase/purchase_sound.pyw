"""
purchase/purchase_sound.pyw — play a sound the moment a fan buys a PPV.

When a fan pays, Infloww Messages shows a popup in its top-right corner for
about 7 seconds (longer while the pointer is on it), whichever chat is open:

    Sam @u100200300                                  (x)
    has purchased your message for $75.00!
    AW

This watches that corner. Every POLL_S it captures the window (PrintWindow:
never takes focus, works while the window is covered) and checks one box for the
popup's grey; only while a popup is up does it OCR it, and only a "has purchased
your ..." popup rings. The same spot also shows tips, new subscribers,
"restarted their subscription" and "Message Pro will go idle": all silent.

    purchase_sound.pyw --listen   run in the background (MMA starts it:
                                  Settings ▸ Features ▸ "Purchase sound")
    purchase_sound.pyw --stop     ask a running one to exit
    purchase_sound.pyw --status   is one running?
    purchase_sound.pyw --play     play the sound once
    purchase_sound.pyw --test     offline checks

Sound: userdata\\sounds\\purchase.wav if it exists, else Windows' tada.wav.
Each ring is logged as "purchase:" in debuglogs\\error_log.txt.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import importlib.util as _importlib
import re
import sys
import threading
import time
from pathlib import Path

import numpy as np

MMA_ROOT = Path(__file__).resolve().parents[3]
LOG_FILE = MMA_ROOT / "debuglogs" / "error_log.txt"
CUSTOM_SOUND = MMA_ROOT / "userdata" / "sounds" / "purchase.wav"
DEFAULT_SOUND = Path(r"C:\Windows\Media\tada.wav")

MUTEX_NAME = "Global\\MMA.purchase.mutex"
STOP_EVENT_NAME = "Global\\MMA.purchase.stop"
TITLE = "infloww messages"     # prefix, case-insensitive: "Infloww Messages - 333"
POLL_S = 0.7

# The pinger already captures this window without stealing it. A .pyw, so it
# loads by path.
_PINGER = Path(__file__).resolve().parent.parent / "pinger" / "pinger.pyw"
_spec = _importlib.spec_from_file_location("mma_pinger", _PINGER)
_pinger = _importlib.module_from_spec(_spec)
_spec.loader.exec_module(_pinger)

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32 = ctypes.WinDLL("user32", use_last_error=True)
k32.CreateMutexW.restype = wt.HANDLE
k32.CreateEventW.restype = wt.HANDLE
k32.OpenEventW.restype = wt.HANDLE
ERROR_ALREADY_EXISTS = 183
_stop = threading.Event()
_mutex = None


def log(msg: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [purchase] {msg}\n")
    except OSError:
        pass


# ------------------------------------------------------------------ the popup --
# "$" is unreliable in OCR, so it is optional, and so is the amount: a sale with
# an unreadable price still rings. So are the spaces: the popup has been read as
# "haspurchasedyourmessagefor $33.00".
SALE = re.compile(r"purchased\s*your(?:\s*\w*?\s*for\s*\$?\s*(?P<amt>\d[\d,]*(?:\.\d{1,2})?))?", re.I)
HANDLE = re.compile(r"@\s*([\w.\-]+)")

# Measured on a 3440-wide window: a #262626 card 464x150, 32px in from the right
# edge, 33px down. Infloww draws it at the same size at any window width.
TOAST_GREY = 38
TOAST_BOX = (40, 175, 480, 50)     # rows 40-175, cols from W-480 to W-50: inside the card
TOAST_CROP = (25, 190, 505, 20)    # a little more, for OCR
TOAST_FILL = 0.5                   # share of the box that must be that grey


def toast_shown(rgb: np.ndarray) -> bool:
    """Cheap test, every frame (~1ms): is a popup card in the top-right corner?"""
    y0, y1, l, r = TOAST_BOX
    w = rgb.shape[1]
    if rgb.shape[0] < y1 or w < l:
        return False
    box = rgb[y0:y1, w - l:w - r].astype(np.int16)
    return float((np.abs(box - TOAST_GREY).max(axis=2) <= 3).mean()) >= TOAST_FILL


_OCR = {"eng": None}


def read_toast(rgb: np.ndarray) -> str:
    """The popup's text, line by line (OCR, ~0.2s)."""
    if _OCR["eng"] is None:
        from rapidocr_onnxruntime import RapidOCR      # slow import: only once a popup shows
        _OCR["eng"] = RapidOCR()
    y0, y1, l, r = TOAST_CROP
    w = rgb.shape[1]
    crop = np.ascontiguousarray(rgb[y0:y1, w - l:w - r][:, :, ::-1])   # RGB -> BGR
    res, _ = _OCR["eng"](crop)
    return "\n".join(line[1] for line in sorted(res or [], key=lambda x: x[0][0][1]))


def parse_toast(text: str) -> dict | None:
    """{'fan', 'handle', 'amount'} for a sale popup, None for any other popup.
    The name line is sometimes not read at all, or cut short ("Averyveryverylongna...")."""
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
        self.amounts: set[str] = set()      # sales rung while this popup is up
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


# -------------------------------------------------------------------- capture --
def infloww_windows() -> list[int]:
    """Every visible, not minimised "Infloww Messages ..." window. There can be
    more than one by that title (an empty decoy among them), and the popup is in
    only one, so each is checked."""
    found = []
    proc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def cb(hwnd, _):
        if u32.IsWindowVisible(hwnd) and not u32.IsIconic(hwnd):
            n = u32.GetWindowTextLengthW(hwnd)
            if n:
                buf = ctypes.create_unicode_buffer(n + 1)
                u32.GetWindowTextW(hwnd, buf, n + 1)
                if buf.value.lower().startswith(TITLE):
                    found.append(hwnd)
        return True

    u32.EnumWindows(proc(cb), 0)
    return found


def play() -> None:
    import winsound
    path = CUSTOM_SOUND if CUSTOM_SOUND.exists() else DEFAULT_SOUND
    try:
        winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
    except RuntimeError:
        winsound.MessageBeep(winsound.MB_ICONASTERISK)


def run() -> None:
    log("started")
    watches: dict[int, ToastWatch] = {}
    while not _stop.is_set():
        try:
            wins = infloww_windows()
            for hwnd in list(watches):
                if hwnd not in wins:
                    del watches[hwnd]
            for hwnd in wins:
                rgb = _pinger.print_window(hwnd)
                if rgb is None:
                    continue
                sale = watches.setdefault(hwnd, ToastWatch()).step(rgb)
                if sale:
                    log(f"purchase: {sale['fan'] or sale['handle'] or '?'} ${sale['amount'] or '?'}")
                    play()
        except Exception as e:                       # never die on one bad frame
            log(f"check failed: {e.__class__.__name__}: {e}")
            _stop.wait(2)
        _stop.wait(POLL_S)
    log("stopped")


# --------------------------------------------------------------- service bits --
def claim_single_instance() -> bool:
    global _mutex
    _mutex = k32.CreateMutexW(None, True, MUTEX_NAME)
    return ctypes.get_last_error() != ERROR_ALREADY_EXISTS


def watch_stop_event() -> None:
    ev = k32.CreateEventW(None, True, False, STOP_EVENT_NAME)

    def wait():
        k32.WaitForSingleObject(ev, 0xFFFFFFFF)
        _stop.set()

    threading.Thread(target=wait, daemon=True).start()


def _open_stop_event():
    EVENT_MODIFY_STATE = 0x0002
    return k32.OpenEventW(EVENT_MODIFY_STATE, False, STOP_EVENT_NAME)


def running() -> bool:
    h = _open_stop_event()
    if h:
        k32.CloseHandle(h)
        return True
    return False


def stop_running() -> bool:
    h = _open_stop_event()
    if not h:
        return False
    k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


# ---------------------------------------------------------------------- tests --
def _test() -> int:
    fails = 0

    def ok(name, got, want):
        nonlocal fails
        print(("ok  " if got == want else "FAIL"), name, got if got != want else "")
        fails += got != want

    for text, want in [
        ("Sam @u100200300\nhas purchased your message for $75.00!\nAW",
         {"fan": "Sam", "handle": "u100200300", "amount": "75.00"}),
        ("big tipper $ notes notes ...\nhaspurchasedyourmessagefor $33.00\nAW",
         {"fan": "big tipper $ notes notes", "handle": "", "amount": "33.00"}),
        ("has purchased your message for $40.00!\nAW", {"fan": "", "handle": "", "amount": "40.00"}),
        ("Averyveryverylongna...\n@averyveryverylon..\nhas purchased your message for $55.00!\nAW",
         {"fan": "Averyveryverylongna", "handle": "averyveryverylon", "amount": "55.00"}),
        ("Robin\n@u55500011\nsubscribed to your profile!\nAW", None),
        ("VIP NOTES\n@u..\npaidyouatipof $.10.00\nAW", None),
        ("Message Pro will go idle in 0:09\nFaninsights", None),
        ("has purchased your message for 1999.99!\nAW",
         {"fan": "", "handle": "", "amount": "1999.99"}),
    ]:
        ok(f"popup {text.splitlines()[-2][:30]!r}", parse_toast(text), want)

    # A fake frame is the popup's text, None = no popup.
    tw = ToastWatch(shown=lambda f: f is not None, read=lambda f: f)
    steps = lambda *fs: [(s or {}).get("amount") for s in   # noqa: E731
                         (tw.step(f, t) for t, f in fs)]
    sale = "Sam @u100200300\nhas purchased your message for $75.00!\nAW"
    ok("popup rings once while it stays up",
       steps((0, None), (1, sale), (1.7, sale), (3.4, "has purchased your message for $75.00!"), (5, sale)),
       [None, "75.00", None, None, None])
    ok("gone and back: rings again", steps((6, None), (7, sale)), [None, "75.00"])
    ok("another sale in its place rings", steps((9, sale.replace("75.00", "40.00"))), ["40.00"])
    ok("a subscribe popup is silent", steps((11, None), (12, "subscribed to your profile!")), [None, None])

    # Real frames (top-right 640x240 of a recording). They show real fans, so
    # they are kept out of git: these checks run where the files exist.
    here = Path(__file__).resolve().parent / "testdata"
    if (here / "toast_sale.png").exists():
        from PIL import Image
        img = lambda n: np.asarray(Image.open(here / n).convert("RGB"))   # noqa: E731
        ok("frame: no popup", toast_shown(img("toast_none.png")), False)
        ok("frame: subscribe popup is a popup", toast_shown(img("toast_other.png")), True)
        ok("frame: subscribe popup is no sale", parse_toast(read_toast(img("toast_other.png"))), None)
        s = parse_toast(read_toast(img("toast_sale.png"))) or {}
        ok("frame: sale popup read", (s.get("amount"), bool(s.get("fan")), bool(s.get("handle"))),
           ("75.00", True, True))
    else:
        print("skip  frame checks (no testdata/)")
    return 1 if fails else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA purchase sound")
    ap.add_argument("--listen", action="store_true", help="run in the background")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--play", action="store_true", help="play the sound once")
    ap.add_argument("--test", action="store_true", help="offline checks")
    a = ap.parse_args(argv)

    if a.test:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        return _test()
    if a.play:
        play()
        time.sleep(3)          # SND_ASYNC: stay alive long enough to hear it
        return 0
    if a.stop:
        print("stopped" if stop_running() else "not running")
        return 0
    if a.status:
        up = running()
        print("running" if up else "not running")
        return 0 if up else 1
    if not a.listen:
        ap.print_help()
        return 0

    _pinger.set_dpi_aware()
    if not claim_single_instance():
        return 0                                    # one is already running
    watch_stop_event()
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
