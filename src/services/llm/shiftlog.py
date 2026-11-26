"""
llm/shiftlog.py — record every chat you work in during a shift, passively.

The chat reader already OCRs the open Infloww chat every time it changes. This
keeps what it reads instead of throwing it away. It is training data for the
chatting model: the whole two-sided conversation, per fan, as you actually ran it.

Two layers, on purpose:

    userdata/shiftlog/reads/<date>.jsonl
        every read, raw, append-only: time, window title, fan name, turns.
        This is the truth. Nothing ever rewrites it, so a bug in the merge
        below costs nothing: rebuild() replays these files.

    userdata/shiftlog/chats/<account>/<fan>.json
        the reads merged into one conversation per fan (merge() below:
        new messages appended, scrolled-up ones prepended). A read that does not
        line up with what is saved (you scrolled far back) starts or grows an
        `islands` fragment instead of being guessed into the chat; an island
        joins the chat once a read bridges the gap.

Never takes focus, never touches Infloww: it only sees what the chat reader
already captured (PrintWindow). The OBS shift recording is the backup.

Each chat file also carries `panel` (the latest read of each fan-panel tab:
insights / sales / notes) and `panel_log` (every change, timed: spend before and
after a pitch). Each turn carries what its footer said when ShiftTimes is on:
time, date, sender (the chatter), price + paid (the PPV pill), liked; and
ppv_border on PPV media. With ShiftMedia, your media turns carry media_img: a
picture of the image (a PPV's first image) in userdata/shiftlog/media/.

Every read belongs to a SHIFT (shift_for below): a live shift starts at the first
read after 90+ minutes of none and is named by that moment ("2026-10-23 02:09");
a video is its own shift; TestFlow is "test". Turns carry the shift they were
first seen in, chat files list theirs, and shifts.json indexes them all with the
OBS recordings and typelog files of the same hours.

    python shiftlog.py --rebuild      redo every chats/ file (and shifts.json) from reads/
    python shiftlog.py --stats        fans, turns and reads so far
    python shiftlog.py --shifts       one line per shift
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
# MMA_SHIFTLOG_ROOT points a whole run somewhere else: the Video Import tool's
# one-time view converts into a temp folder so nothing reaches the real log.
ROOT = Path(os.environ.get("MMA_SHIFTLOG_ROOT") or MMA_ROOT / "userdata" / "shiftlog")
READS = ROOT / "reads"
CHATS = ROOT / "chats"
MEDIA = ROOT / "media"
SHIFTS = ROOT / "shifts.json"
RECORDINGS = Path(os.environ.get("MMA_SHIFT_RECORDINGS", r"D:\ShiftRecordings"))   # OBS "Shifts" profile
TYPELOG = MMA_ROOT / "userdata" / "typelog" / "messages"
RETRY_ISLANDS = 8

# Settings and stitching live in their own modules now (2026-11-24): mmacfg is
# how every Python tool reads mass_gui.cfg, stitch is the one copy of the merge.
# Re-exported, because the chat reader, purchase_alert etc. call shiftlog.feat().
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mmacfg import feat, setting                 # noqa: E402,F401
from stitch import merge, slug, same, is_newer as _is_newer  # noqa: E402,F401


# "Infloww Messages - AliceDoubleYew" -> "AliceDoubleYew". The title names the
# creator account the window is logged into, which is what a chat belongs to.
_TITLE_ACCOUNT = re.compile(r"Infloww Messages\s*[-–]\s*(.+)$", re.I)


def account_of(title: str) -> str:
    m = _TITLE_ACCOUNT.search(title or "")
    return m.group(1).strip() if m else "unknown"


def _chat_path(acct: str, fan: str) -> Path:
    return CHATS / slug(acct) / f"{slug(fan)}.json"


def _load(path: Path, acct: str, fan: str) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"account": acct, "fan": fan, "first_seen": None, "last_seen": None,
                "reads": 0, "turns": [], "islands": [], "panel": {}, "panel_log": []}


def _save(path: Path, d: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    # Windows refuses the swap while anything holds the file open for a moment
    # (an editor, the indexer, antivirus): WinError 5. Retry briefly.
    for attempt in range(20):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.1)


def _bridge(d: dict) -> None:
    """Join every island that now lines up with the chat (newest few only: each
    try is a full alignment)."""
    keep = d["islands"][:-RETRY_ISLANDS]
    for isl in d["islands"][-RETRY_ISLANDS:]:
        if not d["turns"]:
            d["turns"], isl = isl["turns"], None
        else:
            turns, _n, w = merge(d["turns"], isl["turns"])
            if w:
                keep.append(isl)
                continue
            d["turns"] = turns
    d["islands"] = keep


_prev = {"key": None}                            # the chat the last read came from


# ── shifts ──────────────────────────────────────────────────────────────────
# Measured on the first three live shifts: inside a shift the longest pause
# between reads was 11 minutes; between shifts, 3 hours and more. So a pause of
# SHIFT_GAP starts a new shift. Derived from the reads' own times, so old reads
# get shifts too and nothing raw is rewritten. A shift crossing midnight stays
# one shift (the journal's files are per calendar day; shifts are not).
SHIFT_GAP = 90 * 60
_shift = {"id": None, "last": 0.0, "loaded": False}
_index: dict[str, dict] = {}                     # shift id -> its shifts.json entry


def _load_index() -> None:
    """Live, after a restart: continue the shift in progress, not start one."""
    if _shift["loaded"]:
        return
    _shift["loaded"] = True
    try:
        for e in json.loads(SHIFTS.read_text(encoding="utf-8")):
            _index[e["id"]] = e
            if e.get("kind") == "live" and e["end"] > _shift["last"]:
                _shift["id"], _shift["last"] = e["id"], e["end"]
    except (OSError, ValueError, KeyError):
        pass


def shift_for(rec: dict) -> tuple[str, str]:
    """(shift id, kind) for one read, in replay order. kind: live | video | test."""
    src = rec.get("src") or ""
    if ".video-" in src:                         # reads/<date>.video-<name>.jsonl
        day, name = src.split(".video-", 1)
        return f"{day} video {name.rsplit('.', 1)[0]}", "video"
    if account_of(rec.get("title", "")).lower() == "testflow":
        return "test", "test"
    at = rec["at"]
    if _shift["id"] is None or at - _shift["last"] > SHIFT_GAP:
        _shift["id"] = time.strftime("%Y-%m-%d %H:%M", time.localtime(at))
    _shift["last"] = max(_shift["last"], at)
    return _shift["id"], "live"


def _note_shift(sid: str, kind: str, rec: dict) -> None:
    e = _index.setdefault(sid, {"id": sid, "kind": kind, "start": rec["at"], "end": rec["at"],
                                "source": rec.get("src", ""), "reads": 0, "panel_reads": 0,
                                "accounts": {}, "fans": []})
    e["start"], e["end"] = min(e["start"], rec["at"]), max(e["end"], rec["at"])
    if rec.get("kind") == "panel":
        e["panel_reads"] += 1
    else:
        e["reads"] += 1
        acct = account_of(rec.get("title", ""))
        e["accounts"][acct] = e["accounts"].get(acct, 0) + 1
        fan = (rec.get("fan") or "").strip()
        if fan and fan not in e["fans"]:
            e["fans"].append(fan)


def _files_for(e: dict) -> None:
    """The OBS recordings and typelog days that belong to one live shift."""
    if e["kind"] != "live":
        return
    recs = []
    for f in sorted(RECORDINGS.glob("shift_*.mkv")) if RECORDINGS.exists() else []:
        m = re.search(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})", f.name)
        if not m:
            continue
        t = time.mktime(tuple(int(x) for x in m.groups()) + (0, 0, -1))
        if e["start"] - 3600 <= t <= e["end"]:   # OBS splits hourly: one may start before
            recs.append(f.name)
    e["recordings"] = recs
    days = {time.strftime("%Y-%m-%d", time.localtime(t)) for t in (e["start"], e["end"])}
    e["typelog"] = sorted(f"{d}.log" for d in days if (TYPELOG / f"{d}.log").exists())


def save_index() -> None:
    out = []
    for e in sorted(_index.values(), key=lambda e: e["start"]):
        _files_for(e)
        out.append(e)
    SHIFTS.parent.mkdir(parents=True, exist_ok=True)
    tmp = SHIFTS.with_suffix(".tmp")
    tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, SHIFTS)


def _tag(rec: dict) -> str:
    """Give a read its shift: on the read, on each of its turns (kept as the
    turn's FIRST shift by the merge) and in the index."""
    _load_index()
    sid, kind = shift_for(rec)
    rec["shift"] = sid
    for t in rec.get("turns") or []:
        t.setdefault("shift", sid)
    _note_shift(sid, kind, rec)
    return sid


def _apply(rec: dict) -> str:
    """Merge one read into its fan's chat file. Returns a problem or ""."""
    acct, fan = account_of(rec.get("title", "")), (rec.get("fan") or "").strip()
    if not fan:
        fan = "_noname"                          # kept, so nothing is lost
    # Fresh = the chat was just opened, so the screen shows its bottom: you
    # switched fans, or (video) Infloww came back after Discord was on screen.
    fresh = _prev["key"] != (acct, fan) or bool(rec.get("resumed"))
    _prev["key"] = (acct, fan)
    sid = rec.get("shift") or _tag(rec)
    path = _chat_path(acct, fan)
    d = _load(path, acct, fan)
    shifts = d.setdefault("shifts", {})
    shifts[sid] = shifts.get(sid, 0) + 1         # reads of this fan per shift
    # A first read caught mid-load (one empty media bubble) has nothing to line
    # up against, so every later read would be "unplaced" for ever. Live
    # 2026-10-22: Morgan, 9 reads, 8 unplaced. Text-less history is no history.
    if not any(t.get("text") for t in d["turns"]):
        d["turns"] = []
    turns, _new, why = merge(d["turns"], rec["turns"])
    fresh_turns = merge([], rec["turns"])[0] if why else []
    if not why:
        d["turns"] = turns
        _bridge(d)
    elif any(t["text"] for t in fresh_turns) and _is_newer(d["turns"], fresh_turns, fresh):
        stamp = rec["at"]
        fresh_turns = [dict(t, at=stamp) for t in fresh_turns]
        fresh_turns[0]["gap_before"] = True
        d["turns"] = d["turns"] + fresh_turns
        why = ""
        _bridge(d)
    else:
        # It fits nowhere in the chat — you scrolled far back, past what is
        # saved. Live 2026-10-22, parking those reads one by one lost whole
        # scroll-backs (Morgan: 99 reads). Each read overlaps the one before it,
        # so they grow an ISLAND of their own, and the island joins the chat
        # once a read bridges the gap.
        for isl in d["islands"]:
            grown, _n, w = merge(isl["turns"], rec["turns"])
            if not w:
                isl["turns"], isl["last"] = grown, rec["at"]
                break
        else:
            fresh, _n, _w = merge([], rec["turns"])
            if any(t["text"] for t in fresh):
                d["islands"].append({"first": rec["at"], "last": rec["at"], "turns": fresh})
        _bridge(d)
    d["first_seen"] = d["first_seen"] or rec["at"]
    d["last_seen"] = rec["at"]
    d["reads"] += 1
    raw = rec.get("fan_read") or fan
    if raw not in d.setdefault("names", []):
        d["names"].append(raw)                  # every spelling folded in here
    _save(path, d)
    return why


def _append(rec: dict, reads_file: Path | None) -> None:
    """One raw line. The live reader writes reads/<date>.jsonl; a video
    extraction passes its own file (video2chat.py)."""
    READS.mkdir(parents=True, exist_ok=True)
    if reads_file is None:
        reads_file = READS / f"{time.strftime('%Y-%m-%d', time.localtime(rec['at']))}.jsonl"
    with reads_file.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ── the pictures you sent ───────────────────────────────────────────────────
# A PPV's caption is half the story; its first image is the other half (what
# was teased, what he was buying). Each of your media bubbles that is fully on
# screen is cropped from the SAME frame the turns were read from and kept once
# per fan: media/<account>/<fan>/<hash>.jpg. The turn carries the path
# (media_img), so the journal links it and a rebuild keeps it. A later read of
# the same picture (16x16 average hash, a few bits apart) reuses the file, and
# replaces it only with a bigger crop. Only YOUR side: the fan's are not kept.
MEDIA_MIN = 60           # px, either side: smaller is a sliver at the pane's edge
from fanstore import MEDIA_SAME, _ahash, _known    # noqa: E402  (one copy of the picture hashing)


def keep_media(rgb, state: dict) -> None:
    """Crop and save your media bubbles; sets turn["media_img"] (relative to MEDIA)."""
    from PIL import Image
    acct = account_of(state.get("title", ""))
    fan = (state.get("fan") or "").strip()
    if not fan or rgb is None:
        return
    folder = MEDIA / slug(acct) / slug(fan)
    for t in state.get("turns") or []:
        box = t.get("box")
        if t.get("text") or t.get("partial") or t.get("who") == "fan" or not box:
            continue
        x0, y0, x1, y1 = (int(v) for v in box)
        if x1 - x0 < MEDIA_MIN or y1 - y0 < MEDIA_MIN:
            continue
        img = rgb[max(0, y0):y1 + 1, max(0, x0):x1 + 1]
        h = _ahash(img)
        known = _known(folder)
        hit = next((p for kh, p in known if bin(kh ^ h).count("1") <= MEDIA_SAME), None)
        path = hit or folder / f"{h:064x}.jpg"
        try:
            bigger = hit is not None and img.shape[0] * img.shape[1] >                 Image.open(hit).size[0] * Image.open(hit).size[1]
        except OSError:
            bigger = True
        if hit is None or bigger:
            folder.mkdir(parents=True, exist_ok=True)
            Image.fromarray(img).save(path, "JPEG", quality=88)
            if hit is None:
                known.append((h, path))
        t["media_img"] = path.relative_to(MEDIA).as_posix()


def record(state: dict, reads_file: Path | None = None, rgb=None) -> None:
    """Called by the chat reader after every successful read. `rgb` is the
    frame the turns were read from (for keep_media)."""
    if rgb is not None and feat("ShiftMedia"):
        try:
            keep_media(rgb, state)
        except Exception:                        # a picture is never worth a lost read
            pass
    turns = [{k: v for k, v in t.items() if k not in ("box", "repaired")}
             for t in state.get("turns") or []]
    if not turns:
        return
    rec = {"at": state.get("read_at") or time.time(), "title": state.get("title", ""),
           "fan": state.get("fan", ""), "turns": turns}
    if state.get("resumed"):
        rec["resumed"] = True                    # video: Infloww was off screen before this
    _append(rec, reads_file)
    _apply(dict(rec, src=reads_file.name if reads_file else ""))
    save_index()


def _tidy_value(v: str) -> str:
    """transcript's panel-value cleanup, re-applied so a rebuild picks up fixes
    made after the read was taken. Loaded lazily: transcript pulls in the OCR."""
    if "tidy" not in _tv:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import transcript
            _tv["tidy"] = transcript._tidy_value
        except Exception:
            _tv["tidy"] = lambda s: s
    return _tv["tidy"](v)


_tv: dict = {}


def _panel_text(p: dict) -> str:
    return " ".join(q[2] for _y, parts in p.get("rows", []) for q in parts)


def _apply_panel(rec: dict) -> None:
    sid = rec.get("shift") or _tag(rec)
    acct, fan = account_of(rec.get("title", "")), (rec.get("fan") or "").strip() or "_noname"
    path = _chat_path(acct, fan)
    d = _load(path, acct, fan)
    d.setdefault("panel", {})
    d.setdefault("panel_log", [])
    p = dict(rec["panel"])
    if p.get("fields"):
        p["fields"] = {k: _tidy_value(v) for k, v in p["fields"].items()}
    tab = p.get("tab", "?")
    before = d["panel"].get(tab)
    d["panel"][tab] = {"at": rec["at"], **p}
    # The log is the point: spend before and after a pitch is the outcome label.
    if before is None or _panel_text(before) != _panel_text(p):
        d["panel_log"].append({"at": rec["at"], "tab": tab, "fields": p.get("fields", {}),
                               "text": _panel_text(p), "shift": sid})
    d["first_seen"] = d.get("first_seen") or rec["at"]
    _save(path, d)


def record_panel(title: str, fan: str, panel: dict, at: float | None = None,
                 reads_file: Path | None = None) -> None:
    """Called by the chat reader when the fan panel changed."""
    if not panel:
        return
    rec = {"kind": "panel", "at": at or time.time(), "title": title, "fan": fan, "panel": panel}
    _append(rec, reads_file)
    _apply_panel(dict(rec, src=reads_file.name if reads_file else ""))
    save_index()


def _all_reads():
    """Every raw read, with `src` = its journal file's name (in memory only).
    Live reads come back in time order across files, so shifts derive cleanly."""
    for p in sorted(READS.glob("*.jsonl")):
        for line in p.read_text(encoding="utf-8").splitlines():
            try:
                yield dict(json.loads(line), src=p.name)
            except ValueError:
                continue


# ── one fan, several names ──────────────────────────────────────────────────
# The header shows "<your nickname for him>(<his name>)", cut to the space and
# OCR'd a little differently each time: "Kit I Notes(Kit", "Kit I Notes:Kiti",
# "Kit I NotesiKit" are one fan. Names that are close AND whose panels show the
# same total spend are folded into the most-read spelling. The spend check is
# what keeps "Raul" ($364) and "Raul(M" ($12.34k) apart.
NAME_SIMILAR = 0.75


def _norm_name(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def _close(a: str, b: str, same_spend: bool) -> bool:
    import difflib
    na, nb = _norm_name(a), _norm_name(b)
    if min(len(na), len(nb)) < 4:
        return na == nb                          # "TW" is not "TW MAX RUDY"
    if difflib.SequenceMatcher(None, na, nb).ratio() >= NAME_SIMILAR:
        return True
    if min(len(na), len(nb)) >= 6 and (na in nb or nb in na):
        return True
    # A real spend shared to the cent plus the same start: the same man.
    return same_spend and na[:4] == nb[:4]


def canonical_names(recs: list[dict]) -> dict[tuple[str, str], str]:
    """(account, name as read) -> the name to file it under."""
    from collections import Counter
    stats: dict[tuple[str, str], dict] = {}
    for rec in recs:
        name = (rec.get("fan") or "").strip()
        if not name:
            continue
        s = stats.setdefault((account_of(rec.get("title", "")), name), {"n": 0, "spend": Counter()})
        s["n"] += 1
        if rec.get("kind") == "panel":
            sp = _tidy_value((rec["panel"].get("fields") or {}).get("Total spend", ""))
            if re.search(r"\d", sp):
                s["spend"][re.sub(r"[^\d]", "", sp)] += 1
    canon, heads = {}, []                        # heads: (account, name, spend)
    for key in sorted(stats, key=lambda k: -stats[k]["n"]):
        acct, name = key
        top = stats[key]["spend"].most_common(1)
        sp = top[0][0] if top else ""
        for h_acct, h_name, h_sp in heads:
            if h_acct != acct or (sp and h_sp and sp != h_sp):
                continue
            if _close(name, h_name, bool(sp and sp == h_sp and sp.strip("0"))):
                canon[key] = canon[(h_acct, h_name)]
                break
        else:
            canon[key] = name
            heads.append((acct, name, sp))
    return canon


def rebuild() -> int:
    """Throw chats/ away and replay every raw read into it, one file per fan."""
    import shutil
    if CHATS.exists():
        shutil.rmtree(CHATS)
    recs = list(_all_reads())
    canon = canonical_names(recs)
    _prev["key"] = None
    _shift.update(id=None, last=0.0, loaded=True)    # derive every shift afresh
    _index.clear()
    for rec in recs:
        raw = (rec.get("fan") or "").strip()
        key = (account_of(rec.get("title", "")), raw)
        rec = dict(rec, fan=canon.get(key, raw), fan_read=raw)
        (_apply_panel if rec.get("kind") == "panel" else _apply)(rec)
    save_index()
    return len(recs)


def shifts_report() -> str:
    try:
        rows = json.loads(SHIFTS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "no shifts.json yet: run --rebuild"
    out = []
    for e in rows:
        hrs = (e["end"] - e["start"]) / 3600
        end = time.strftime("%H:%M", time.localtime(e["end"]))
        out.append(f"  {e['id']:<34} {e['kind']:<5} to {end}  {hrs:4.1f}h  {e['reads']:>5} reads "
                   f"{e['panel_reads']:>4} panel  {len(e['fans']):>4} fans  "
                   f"{len(e.get('recordings', []))} recordings  {', '.join(e.get('typelog', []))}")
    return "\n".join(out)


def stats() -> str:
    reads = sum(1 for _ in _all_reads())
    rows = []
    for p in sorted(CHATS.glob("*/*.json")):
        d = json.loads(p.read_text(encoding="utf-8"))
        fan_n = sum(t["who"] == "fan" for t in d["turns"])
        timed = sum(bool(t.get("time")) for t in d["turns"])
        isl = sum(len(i["turns"]) for i in d.get("islands", []))
        spend = (d.get("panel", {}).get("insights", {}).get("fields", {}) or {}).get("Total spend", "-")
        rows.append(f"  {d['account']:<20} {d['fan']:<28} {len(d['turns']):>5} turns "
                    f"({fan_n} fan, {timed} timed)  spend {spend:<9} +{isl} in {len(d.get('islands', []))} islands")
    return f"{reads} reads, {len(rows)} chats\n" + "\n".join(rows)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if "--rebuild" in sys.argv:
        print(f"replayed {rebuild()} reads")
    if "--shifts" in sys.argv:
        print(shifts_report())
    else:
        print(stats())
