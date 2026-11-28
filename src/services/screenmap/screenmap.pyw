"""
screenmap/screenmap.pyw — the Screen Map service. Keeps userdata/layout/infloww.json
true for every open Infloww window. All the measuring is in screenmap.py.

    pythonw screenmap.pyw --listen    the service (MMA's runner starts this)
    python  screenmap.pyw --once      measure every window once and print the map
    python  screenmap.pyw --stop | --status

When it looks again (it never takes focus, never clicks, never types):
  * a window opened, moved or resized                       -> right away
  * the window you are in                                   -> every FOCUS_S
  * every other Infloww window                              -> every OTHER_S
  * a tool found the map wrong and asked (named event)      -> right away
A look is one PrintWindow capture (~40ms) plus a pixel check. The full measure
runs only if the pixel check fails; OCR (model name, tab names, fan) only when
the pixels it reads from actually changed.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import screenmap as S                              # noqa: E402
import transcript as T                             # noqa: E402  (path set by screenmap)

LOG_FILE = S.MMA_ROOT / "debuglogs" / "error_log.txt"
MUTEX_NAME = "Global\\MMA.screenmap.mutex"
STOP_EVENT_NAME = "Global\\MMA.screenmap.stop"
ERROR_ALREADY_EXISTS = 183

TICK_S = 0.25           # window list + focus
FOCUS_S = 1.0           # re-look at the window you're in
OTHER_S = 5.0           # re-look at the rest
HEARTBEAT_S = 2.0       # rewrite "updated" so readers know the service is alive

u32 = ctypes.windll.user32
k32 = ctypes.windll.kernel32
_mutex = None
_stop = threading.Event()
_poke = threading.Event()


def log(msg: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [screenmap] {msg}\n")
    except OSError:
        pass


# ------------------------------------------------------------------ windows --
def infloww_windows() -> list[dict]:
    """Every visible top-level Infloww window. The title is NOT an identity:
    every one says "Infloww Messages - 333" (333 = the agency's tag). The window
    handle is — it never changes while that window is open."""
    out = []
    for hwnd, title in T._matching_windows("Infloww"):
        if not title.startswith("Infloww"):
            continue
        cls = ctypes.create_unicode_buffer(64)
        u32.GetClassNameW(hwnd, cls, 64)
        if cls.value != "Chrome_WidgetWin_1":
            continue
        r = wintypes.RECT()
        u32.GetWindowRect(hwnd, ctypes.byref(r))
        out.append({"hwnd": int(hwnd), "title": title,
                    "rect": [r.left, r.top, r.right - r.left, r.bottom - r.top],
                    "minimised": bool(u32.IsIconic(hwnd)),
                    "monitor": int(u32.MonitorFromWindow(hwnd, 2) or 0)})
    return out


def _sig(rgb, region) -> str:
    """A cheap fingerprint of one region: changes when what's drawn there changes."""
    if not region:
        return ""
    x, y, w, h = region
    crop = rgb[y:y + h:2, x:x + w:2] // 16
    return hashlib.md5(crop.tobytes()).hexdigest()[:12]


# ------------------------------------------------------------------- state --
class Map:
    def __init__(self):
        self.recs: dict[int, dict] = {}         # hwnd -> published record
        self.priv: dict[int, dict] = {}         # hwnd -> sigs, timers (not published)
        self.focus = 0
        self.last_written = ""
        self.last_beat = 0.0

    def look(self, win: dict, force: bool = False) -> None:
        """Capture one window; re-measure / re-read only what changed."""
        hwnd = win["hwnd"]
        rec = self.recs.setdefault(hwnd, {"hwnd": hwnd, "last_focus": 0})
        p = self.priv.setdefault(hwnd, {})
        rec.update(title=win["title"], rect=win["rect"], monitor=win["monitor"])
        p["looked"] = time.time()
        if win["minimised"]:
            rec.update(status="unsure", reason="that Infloww window is minimised")
            return
        rgb = T._pinger.print_window(hwnd)
        if rgb is None:
            rec.update(status="unsure", reason="that Infloww window gave a blank picture")
            return
        if (not force and rec.get("status") == "ok" and p.get("size") == rgb.shape[:2]
                and S.check_pixels(rgb, rec.get("check"))):
            m = None                              # layout still holds
        else:
            m = S.measure(rgb, win["title"])
            p["size"] = rgb.shape[:2]
            prev = (rec.get("kind"), rec.get("status"), rec.get("regions"))
            rec.update(m.to_dict())
            rec["measured_at"] = round(time.time(), 2)
            if prev != (rec["kind"], rec["status"], rec["regions"]):
                log(f"{hwnd:#x} {rec['kind']} {rec['status']}"
                    f"{' (' + rec['reason'] + ')' if rec['reason'] else ''}"
                    f" {rgb.shape[1]}x{rgb.shape[0]} scale {rec['scale']}")
        if rec.get("kind") not in ("main", "fan") or not rec.get("regions"):
            return
        regions = rec["regions"]
        meas = S.Measured(rec["kind"], rec["status"], rec["reason"], rec["scale"],
                          regions, rec.get("chat_open", False), rec.get("check"))
        # OCR only when the pixels it reads from changed.
        s = _sig(rgb, regions.get("active_tab"))
        if s != p.get("tab_sig"):
            p["tab_sig"] = s
            name = S.read_model(rgb, meas)
            if name != rec.get("model"):
                log(f"{hwnd:#x} model: {rec.get('model')!r} -> {name!r}")
            rec["model"] = name
        s = _sig(rgb, regions.get("strip"))
        if s != p.get("strip_sig"):
            p["strip_sig"] = s
            rec["tabs"] = S.read_tabs(rgb, meas)
        s = _sig(rgb, regions.get("header"))
        if s != p.get("head_sig"):
            p["head_sig"] = s
            rec["fan"] = S.read_fan(rgb, meas)
        if rec["status"] == "ok" and not rec.get("model"):
            # Layout fine, name unreadable: tools that need the model must not guess.
            rec["model_status"] = "unsure"
        else:
            rec["model_status"] = "ok"

    def tick(self, force: bool = False) -> None:
        now = time.time()
        wins = infloww_windows()
        alive = {w["hwnd"] for w in wins}
        for h in list(self.recs):
            if h not in alive:
                log(f"{h:#x} closed")
                self.recs.pop(h)
                self.priv.pop(h, None)
        fg = int(u32.GetForegroundWindow() or 0)
        if fg in alive:
            self.focus = fg
        for w in wins:
            h = w["hwnd"]
            rec = self.recs.get(h)
            p = self.priv.get(h, {})
            if h == fg:
                self.recs.setdefault(h, {"hwnd": h, "last_focus": 0})["last_focus"] = round(now, 2)
            due = FOCUS_S if h == fg else OTHER_S
            if (force or rec is None or rec.get("rect") != w["rect"]
                    or now - p.get("looked", 0) >= due):
                try:
                    self.look(w, force=force or rec is None or rec.get("rect") != w["rect"])
                except Exception as e:                    # one bad frame never kills it
                    log(f"{h:#x} look failed: {e.__class__.__name__}: {e}")
        self.publish(now)

    def publish(self, now: float) -> None:
        doc = {"schema": S.SCHEMA, "focus_hwnd": self.focus if self.focus in self.recs else 0,
               "windows": sorted(self.recs.values(), key=lambda r: r["hwnd"])}
        body = repr(doc)
        if body != self.last_written or now - self.last_beat >= HEARTBEAT_S:
            doc["updated"] = round(now, 2)
            S.write_map(doc)
            self.last_written = body
            self.last_beat = now


def run() -> None:
    log("started")
    m = Map()
    while not _stop.is_set():
        force = _poke.is_set()
        _poke.clear()
        try:
            m.tick(force=force)
        except Exception as e:
            log(f"tick failed: {e.__class__.__name__}: {e}")
            time.sleep(1)
        _poke.wait(TICK_S)
    S.write_map({"schema": S.SCHEMA, "focus_hwnd": 0, "windows": [], "updated": 0})
    log("stopped")


# --------------------------------------------------------------- service bits --
def claim_single_instance() -> bool:
    global _mutex
    _mutex = k32.CreateMutexW(None, True, MUTEX_NAME)
    return k32.GetLastError() != ERROR_ALREADY_EXISTS


def _wait_on(name: str, then) -> None:
    ev = k32.CreateEventW(None, False if then is _poke.set else True, False, name)

    def wait():
        while True:
            k32.WaitForSingleObject(ev, 0xFFFFFFFF)
            then()
            if then is _stop.set:
                _poke.set()                 # wake the loop so it can exit
                return

    threading.Thread(target=wait, daemon=True).start()


def _event(name: str, set_it: bool) -> bool:
    h = k32.OpenEventW(0x0002, False, name)
    if not h:
        return False
    if set_it:
        k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA Screen Map")
    ap.add_argument("--listen", action="store_true", help="run in the background")
    ap.add_argument("--once", action="store_true", help="measure once and print")
    ap.add_argument("--stop", action="store_true")
    ap.add_argument("--status", action="store_true")
    a = ap.parse_args(argv)
    if a.stop:
        print("stopped" if _event(STOP_EVENT_NAME, True) else "not running")
        return 0
    if a.status:
        up = _event(STOP_EVENT_NAME, False)
        print("running" if up else "not running")
        return 0 if up else 1

    T.A.set_dpi_aware()                     # before ANY coordinate is read
    if a.once:
        sys.stdout = sys.__stdout__
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        m = Map()
        m.tick(force=True)
        for r in m.recs.values():
            print(f"{r['hwnd']:#x}  {r.get('kind')}  {r.get('status')}  "
                  f"{r.get('reason') or ''}")
            print(f"    model={r.get('model')!r} tabs={r.get('tabs')} fan={r.get('fan')}")
            print(f"    rect={r.get('rect')} scale={r.get('scale')} focus={r['hwnd'] == m.focus}")
            for k, v in (r.get("regions") or {}).items():
                print(f"      {k:13} {v}")
        print(f"written to {S.MAP_FILE}")
        return 0

    if not claim_single_instance():
        return 0
    _wait_on(STOP_EVENT_NAME, _stop.set)
    _wait_on(S.REMEASURE_EVENT, _poke.set)
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
