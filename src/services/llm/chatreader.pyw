"""
llm/chatreader.pyw — keep a fresh transcript of the open Infloww chat, always.

Reading the chat costs ~2s of OCR (plus ~2.5s to load the OCR engine the first
time). A suggestion key that paid that on every press would be useless for
speed-handling, so this service pays it in the background instead:

    every POLL_S     capture the window (PrintWindow, ~40ms, never takes focus);
                     ring if Infloww's "has purchased your message" popup is up
                     in its top-right corner (purchase_alert.py, any fan);
                     compare a small grey thumbnail of the message pane;
    when it changed  wait for it to hold still for one more poll (a scroll or a
    and settled      message animating in), then OCR it;
                     write the result to userdata\\chat_now.json, and journal
                     it for training (shiftlog.py -> userdata\\shiftlog\\);
                     and ring if it shows a new sale (purchase_alert.py).
    every 5s         read the Unread pill's count, and ping once it reaches X
                     (unread_ping.py).

So the OCR runs only when the chat actually changes: a new message, a scroll,
a different fan. Typing in the composer does not count — the composer is below
the pane.

chat_now.json carries the thumbnail it was read from. A reader (suggest.py)
takes its own 40ms capture and compares: if they differ, the file is stale (you
switched fans a moment ago) and it waits for the next write instead of
suggesting for the wrong fan.

    runner.pyw --start chatReader   start it silently (MMA does this — Settings ▸
                                Features ▸ "Chat reader")
    chatreader.pyw --stop       ask a running one to exit
    chatreader.pyw --status     is one running?
    chatreader.pyw --once       one read, printed
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np                                # noqa: E402
import transcript as T                            # noqa: E402
import shiftlog                                   # noqa: E402
import purchase_alert                             # noqa: E402
import unread_ping                                # noqa: E402
import fanrec                                     # noqa: E402
import autonote                                   # noqa: E402

MMA_ROOT = Path(__file__).resolve().parents[3]
OUT = MMA_ROOT / "userdata" / "chat_now.json"
LOG_FILE = MMA_ROOT / "debuglogs" / "error_log.txt"

MUTEX_NAME = "Global\\MMA.chatreader.mutex"
STOP_EVENT_NAME = "Global\\MMA.chatreader.stop"
ERROR_ALREADY_EXISTS = 183

POLL_S = 0.7
# thumb_diff above this = the chat changed. Measured: the same screen twice is
# ~0.0; one new short message at the bottom moves it by well over 1.
CHANGED = 0.6
# Polls in a row with the chat, header AND fan panel all unchanged before a read
# (~1.4s). Infloww updates the three at different moments when you switch fans.
SETTLE_POLLS = 2
# How often the Unread pill's count is read for the unread ping (~45ms a read).
UNREAD_EVERY_S = 5

k32 = ctypes.windll.kernel32
_mutex = None
_stop = threading.Event()


def log(msg: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [chatreader] {msg}\n")
    except OSError:
        pass


def write_state(state: dict) -> None:
    """Atomic: a reader never sees half a file."""
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, OUT)


def thumb_to_json(t: np.ndarray) -> dict:
    return {"shape": list(t.shape), "b64": base64.b64encode(t.astype(np.float32).tobytes()).decode()}


def thumb_from_json(d: dict | None) -> np.ndarray | None:
    if not d:
        return None
    return np.frombuffer(base64.b64decode(d["b64"]), np.float32).reshape(d["shape"])


def load_state() -> dict | None:
    try:
        return json.loads(OUT.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def read_once(footers: bool = False) -> dict:
    """Capture + OCR now. Returns the state dict that would be written."""
    return read_frame(*T.capture_conversation(), footers=footers)


def read_frame(rgb, layout, title: str, footers: bool = False) -> dict:
    """OCR one captured frame. The loop passes the frame it checked for
    stillness, so the chat, the name and the panel all come from one moment."""
    t0 = time.time()
    turns = T.read_turns(rgb, layout, footers=footers)
    return {
        "read_at": time.time(),
        "read_ms": int((time.time() - t0) * 1000),
        "title": title,
        # Same frame as the turns, so the name and the chat can never disagree
        # (livetrainer keys its per-fan history on this).
        "fan": T.read_fan_name(rgb, layout),
        "window": [rgb.shape[1], rgb.shape[0]],
        "thumb": thumb_to_json(T.pane_thumb(rgb, layout)),
        "turns": [t.to_dict() for t in turns],
        "note": "",
    }


def sale_popup(popups: purchase_alert.ToastWatch, rgb: np.ndarray) -> None:
    """Ring for Infloww's "has purchased your message" popup: the moment of the
    sale, for any fan. Checked on every capture; OCR only while one is up."""
    if not shiftlog.feat("PurchaseSound"):
        return
    try:
        s = popups.step(rgb)
    except Exception as e:
        log(f"purchase popup failed: {e.__class__.__name__}: {e}")
        return
    if s:
        log(f"purchase: {s['fan'] or s['handle'] or '?'} ${s['amount'] or '?'} (popup)")
        purchase_alert.play()


def scan_modals(fans) -> None:
    """Hand every Infloww window's frame to the fan recorder's modal reader."""
    try:
        for hwnd, _t in T._matching_windows(T.A.TARGET_TITLE):
            if not T._pinger.u32.IsIconic(hwnd):
                fans.on_frame(T._pinger.print_window(hwnd))
    except Exception as e:
        log(f"fan recorder modal failed: {e.__class__.__name__}: {e}")


def run() -> None:
    log("started")
    # Infloww does not switch fans in one go: measured 2026-10-22, the fan panel
    # updates FIRST, the messages next, the header name LAST. Reading any one of
    # them as soon as IT settled pinned the next fan's panel, and a chat under
    # the previous fan's name. So: watch all three, and read only once all three
    # have held still for SETTLE_POLLS polls, all from that same frame.
    last_pane = last_head = None   # thumbs at the last chat read
    last_panel = None              # thumb at the last panel read
    prev = None                    # (pane, panel, header) thumbs of the previous poll
    still = 0                      # polls in a row with nothing moving
    last_note = None
    panel_fan = None               # whose panel was read last
    fan = None
    sales = purchase_alert.PurchaseWatch()
    popups = purchase_alert.ToastWatch()
    unread, unread_due = unread_ping.UnreadPing(), 0.0
    fans = fanrec.Recorder()       # lore_gatherer live recorder (FEAT FanRecorder)
    notes = autonote.AutoNote()    # writes each fan's note once you stop chatting him (FEAT AutoNote)
    fans.on_filed = notes.touch
    while not _stop.is_set():
        # The Unread pill's count: its own capture, because the pill is there
        # whether or not a conversation is open (capture_conversation needs one).
        if time.time() >= unread_due and shiftlog.feat("UnreadPing"):
            unread_due = time.time() + UNREAD_EVERY_S
            try:
                rgb = unread_ping.grab()
                n = None if rgb is None else unread_ping.read_unread(rgb)
                at = int(shiftlog.setting("UnreadPing", "At", "10") or 0)
                every = float(shiftlog.setting("UnreadPing", "EveryMin", "3") or 0) * 60
                if unread.step(n, time.time(), at, every):
                    log(f"unread ping: {n} unread (at {at})")
                    unread_ping.play()
            except Exception as e:
                log(f"unread ping failed: {e.__class__.__name__}: {e}")
        try:
            rgb, layout, title = T.capture_conversation()
            sale_popup(popups, rgb)
            cur = (T.pane_thumb(rgb, layout), T.panel_thumb(rgb, layout),
                   T.header_thumb(rgb, layout))
            moving = prev is None or any(T.thumb_diff(a, b) > CHANGED for a, b in zip(cur, prev))
            still = 0 if moving else still + 1
            prev = cur
            recording = shiftlog.feat("ShiftLog")
            filing = shiftlog.feat("FanRecorder")
            if filing and layout.region[0] < T.WORK_LIST_MIN_X:
                # Only a harvest window is readable: the work window is probably
                # covered by the name modal you just opened.
                scan_modals(fans)
            if still >= SETTLE_POLLS:
                if T.thumb_diff(cur[0], last_pane) > CHANGED or T.thumb_diff(cur[2], last_head) > CHANGED:
                    # The fan recorder always needs the footers: they are its times.
                    state = read_frame(rgb, layout, title,
                                       footers=filing or (recording and shiftlog.feat("ShiftTimes")))
                    last_pane, last_head = cur[0], cur[2]
                    fan = state["fan"]
                    if filing:
                        try:
                            # File it under his @handle FIRST, so chat_now.json
                            # carries the handle (Live Trainer keys on it).
                            state["handle"] = fans.on_read(rgb, layout, state)
                            state["account"] = fans.acct      # the real one ("CIN"), not the title's "333"
                        except Exception as e:
                            log(f"fan recorder failed: {e.__class__.__name__}: {e}")
                    write_state(state)
                    last_note = None
                    try:
                        # Always watched, so a sale seen while the sound is off
                        # does not ring later when it is switched back on.
                        new = sales.check(state)
                        for s in new:
                            log(f"purchase: {s['fan'] or '?'} ${s['amount'] or '?'} ({s['account']})")
                        if new and shiftlog.feat("PurchaseSound"):
                            purchase_alert.play()
                    except Exception as e:
                        log(f"purchase alert failed: {e.__class__.__name__}: {e}")
                    if recording:
                        try:
                            shiftlog.record(state, rgb=rgb)   # keep every read for training
                        except Exception as e:
                            log(f"shiftlog failed: {e.__class__.__name__}: {e}")
                # The fan panel: re-read when it changes, or when the fan does
                # (two new subs can have identical panels). ~1.5s of OCR, rarely.
                if recording and shiftlog.feat("ShiftPanel") and fan \
                        and (fan != panel_fan or T.thumb_diff(cur[1], last_panel) > CHANGED):
                    last_panel, panel_fan = cur[1], fan
                    try:
                        shiftlog.record_panel(title, fan, T.read_panel(rgb, layout))
                    except Exception as e:
                        log(f"shiftlog panel failed: {e.__class__.__name__}: {e}")
        except T.A.WindowNotReady as e:
            # No chat open, but the sale popup shows on any page.
            try:
                rgb = unread_ping.grab()
                if rgb is not None:
                    sale_popup(popups, rgb)
            except Exception as e2:
                log(f"purchase popup failed: {e2.__class__.__name__}: {e2}")
            # A name modal covers the chat (its overlay hides the dividers): the
            # fan recorder reads his @handle off it.
            if shiftlog.feat("FanRecorder"):
                scan_modals(fans)
            # Said once per change of reason, not every 0.7s.
            note = str(e)
            if note != last_note:
                write_state({"read_at": time.time(), "turns": [], "note": note,
                             "thumb": None})
                last_note = note
                last_pane = last_head = prev = None
                still = 0
        except Exception as e:                       # never die on one bad frame
            log(f"read failed: {e.__class__.__name__}: {e}")
            time.sleep(2)
        _stop.wait(POLL_S)
    log("stopped")


# --------------------------------------------------------------- service bits --
def claim_single_instance() -> bool:
    global _mutex
    _mutex = k32.CreateMutexW(None, True, MUTEX_NAME)
    return k32.GetLastError() != ERROR_ALREADY_EXISTS


def watch_stop_event() -> None:
    ev = k32.CreateEventW(None, True, False, STOP_EVENT_NAME)

    def wait():
        k32.WaitForSingleObject(ev, 0xFFFFFFFF)
        _stop.set()

    threading.Thread(target=wait, daemon=True).start()


def running() -> bool:
    EVENT_MODIFY_STATE = 0x0002
    h = k32.OpenEventW(EVENT_MODIFY_STATE, False, STOP_EVENT_NAME)
    if h:
        k32.CloseHandle(h)
        return True
    return False


def stop_running() -> bool:
    EVENT_MODIFY_STATE = 0x0002
    h = k32.OpenEventW(EVENT_MODIFY_STATE, False, STOP_EVENT_NAME)
    if not h:
        return False
    k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA chat reader")
    ap.add_argument("--listen", action="store_true", help="run in the background")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--once", action="store_true", help="read once and print")
    a = ap.parse_args(argv)

    if a.stop:
        print("stopped" if stop_running() else "not running")
        return 0
    if a.status:
        up = running()
        print("running" if up else "not running")
        return 0 if up else 1

    T.A.set_dpi_aware()
    if a.once:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        state = read_once()
        print(f"read in {state['read_ms']} ms from {state['title']!r}")
        print(T.as_prompt_text([T.Turn.from_dict(d) for d in state["turns"]]))
        return 0

    if not claim_single_instance():
        return 0                                    # one is already running
    watch_stop_event()
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
