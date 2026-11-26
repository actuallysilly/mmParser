"""
llm/fanstore.py — one folder per fan, keyed on his @handle. lore_gatherer steps 2+3.

Spec: docs/proposals/lore-gatherer.md. Layout (decision 19):

    <Root>/<account>/<handle>/
        reads.jsonl     every read, raw, append-only. The truth: rebuild() replays it,
                        so a bug in the stitching below never loses anything.
        fan.json        the reads stitched into ONE ordered chat (`turns`), plus
                        `islands` (scroll-backs that don't join up yet), the names
                        and tags seen, notes.
        media/<hash>.jpg  a crop of every bubble OCR can't read (decision 16)
    <Root>/<account>/_pending/<name>.jsonl
        reads of a fan whose handle is not known yet (decision 30). Adopted, and
        replayed into his folder, once the name modal is read.

Root is `[FanData] Root` in mass_gui.cfg, default D:\\FanData (decision 18).

Stitching is stitch.py (the one copy: diff-style alignment, islands for
scroll-backs, the forward-gap rule), hardened on real shifts. Two things are new here:
  * `day`: each turn read below a day separator carries its date ("Nov 21");
    the stitched chat fills the rest downwards, never across a gap.
  * `media`: the crop of a text-less bubble, BOTH sides (shiftlog kept only hers).
"""
from __future__ import annotations

import difflib
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mmacfg                                     # noqa: E402
from stitch import merge, is_newer as _is_newer, slug  # noqa: E402

RETRY_ISLANDS = 8
MEDIA_MIN = 40          # px: smaller is a sliver at the pane edge, not a picture
MEDIA_SAME = 24         # of 256 hash bits: the same picture, read again
_setting = mmacfg.setting                        # tests point this at a temp folder


def root() -> Path:
    return Path(_setting("FanData", "Root", r"D:\FanData") or r"D:\FanData")


def fan_dir(acct: str, handle: str) -> Path:
    return root() / slug(acct or "unknown") / slug(handle)


def pending_path(acct: str, name: str) -> Path:
    return root() / slug(acct or "unknown") / "_pending" / f"{slug(name) or '_noname'}.jsonl"


# ── names ────────────────────────────────────────────────────────────────────
def norm_name(s: str) -> str:
    """'keefe | not into…' and 'keefe I not into' are one name: OCR reads | as I."""
    return re.sub(r"[^a-z0-9]", "", s.lower().replace("|", "i"))


def names_match(a: str, b: str) -> bool:
    """The list row cuts the name off ('…Xd retar...'); the header adds '(Insert
    name Here)'. So: the shorter must closely match the start of the longer."""
    na, nb = norm_name(a), norm_name(b)
    if not na or not nb:
        return False
    s, l = sorted((na, nb), key=len)
    if len(s) < 3:
        return s == l
    return difflib.SequenceMatcher(None, s, l[:len(s)]).ratio() >= 0.8


# ── files ────────────────────────────────────────────────────────────────────
def _save(path: Path, d: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    for attempt in range(20):                  # an editor/indexer can hold it a moment
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.1)


def load(acct: str, handle: str) -> dict:
    try:
        return json.loads((fan_dir(acct, handle) / "fan.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"account": acct, "handle": handle, "names": [], "tags": [], "notes": "",
                "first_seen": None, "last_seen": None, "reads": 0, "turns": [], "islands": []}


def known(acct: str) -> list[dict]:
    """{'handle', 'names'} of every fan filed under this account."""
    out = []
    base = root() / slug(acct or "unknown")
    for p in base.glob("*/fan.json") if base.exists() else []:
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
            out.append({"handle": d["handle"], "names": d.get("names", [])})
        except (OSError, ValueError, KeyError):
            continue
    return out


def match(acct: str, name: str, prefix: str) -> list[str]:
    """Handles of known fans whose handle starts with `prefix` and whose names
    match `name` (decision 29). One result = file it; none or several = ask."""
    p = prefix.lower()
    return [f["handle"] for f in known(acct)
            if p and f["handle"].lower().startswith(p)
            and (not name or any(names_match(name, n) for n in f["names"]))]


# ── days ─────────────────────────────────────────────────────────────────────
def fill_days(turns: list[dict]) -> None:
    """A turn with no separator above it on its own screen takes the day of the
    turn above it in the chat. Never across a gap: a day may hide in it."""
    day = ""
    for t in turns:
        if t.get("gap_before"):
            day = ""
        if t.get("day"):
            day = t["day"]
        elif day:
            t["day"] = day


# ── stitching (shiftlog._apply, keyed on handle) ─────────────────────────────
def _bridge(d: dict) -> None:
    keep = d["islands"][:-RETRY_ISLANDS]
    for isl in d["islands"][-RETRY_ISLANDS:]:
        if not d["turns"]:
            d["turns"] = isl["turns"]
            continue
        turns, _n, w = merge(d["turns"], isl["turns"])
        if w:
            keep.append(isl)
        else:
            d["turns"] = turns
    d["islands"] = keep


_prev = {"key": None}                           # the fan the last read came from


def apply(d: dict, rec: dict) -> str:
    """Stitch one read into a fan dict. Returns a problem ("" = placed)."""
    key = (d["account"], d["handle"])
    fresh = _prev["key"] != key or bool(rec.get("fresh"))
    _prev["key"] = key
    if not any(t.get("text") for t in d["turns"]):
        d["turns"] = []                         # text-less history is no history
    turns, _new, why = merge(d["turns"], rec["turns"])
    if not why:
        d["turns"] = turns
    else:
        alone = merge([], rec["turns"])[0]
        if any(t["text"] for t in alone) and _is_newer(d["turns"], alone, fresh):
            alone = [dict(t, at=rec["at"]) for t in alone]
            alone[0]["gap_before"] = True
            d["turns"] = d["turns"] + alone
            why = ""
        else:
            for isl in d["islands"]:
                grown, _n, w = merge(isl["turns"], rec["turns"])
                if not w:
                    isl["turns"], isl["last"] = grown, rec["at"]
                    break
            else:
                if any(t["text"] for t in alone):
                    d["islands"].append({"first": rec["at"], "last": rec["at"], "turns": alone})
    _bridge(d)
    fill_days(d["turns"])
    d["first_seen"] = d["first_seen"] or rec["at"]
    d["last_seen"] = rec["at"]
    d["reads"] += 1
    name = (rec.get("name") or "").strip()
    if name and name not in d["names"]:
        d["names"].append(name)
    return why


def record(acct: str, handle: str, rec: dict) -> str:
    """Append the raw read and stitch it in. Returns the stitch problem, if any."""
    folder = fan_dir(acct, handle)
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "reads.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    d = load(acct, handle)
    why = apply(d, rec)
    _save(folder / "fan.json", d)
    return why


# ── provisional fans (2026-11-26) ────────────────────────────────────────────
# Live over two days, 350 "click his name" toasts went unanswered and ~1,600
# reads sat in _pending. Silly's call: file every chat at once. A fan whose
# handle is cut off ("@u813...") or not on screen is filed under a PROVISIONAL
# id: "--u813--keefe" (handle start + name) or "----keefe" (name only). The moment a
# full handle is read (list row, name popup, __lore) promote() folds every
# provisional file of that fan into his real one, replaying the raw reads.
PROV = "--"            # slug() keeps it; a real handle never starts with it


def provisional_id(name: str, prefix: str = "") -> str:
    pre = re.sub(r"[^a-z0-9_.]", "", prefix.lower())
    return f"{PROV}{pre}{PROV}{norm_name(name)[:40] or 'noname'}"


def is_provisional(handle: str) -> bool:
    return handle.startswith(PROV)


def _prov_parts(handle: str) -> tuple[str, str]:
    """'--u813--keefe' -> ('u813', 'keefe'); '----keefe' -> ('', 'keefe')."""
    prefix, _, name = handle[len(PROV):].partition(PROV)
    return prefix, name


def find_provisional(acct: str, name: str, prefix: str = "") -> str:
    """An existing provisional file for this fan (names match, handle starts fit
    each other), so OCR's spelling of the name doesn't scatter him over several."""
    base = root() / slug(acct or "unknown")
    for p in sorted(base.glob("--*/fan.json")) if base.exists() else []:
        pp, pname = _prov_parts(p.parent.name)
        if prefix and pp and not (pp.startswith(prefix.lower()) or prefix.lower().startswith(pp)):
            continue
        try:
            names = json.loads(p.read_text(encoding="utf-8")).get("names", [])
        except (OSError, ValueError):
            names = []
        if any(names_match(name, x) for x in names + [pname]):
            return p.parent.name
    return ""


def move_reads(acct_from: str, handle_from: str, acct_to: str, handle_to: str) -> int:
    """Replay one folder's raw reads into another and delete the source. The
    source's names/tags/notes are kept. Returns how many reads moved."""
    import shutil
    src = fan_dir(acct_from, handle_from)
    if not (src / "reads.jsonl").exists() or src == fan_dir(acct_to, handle_to):
        return 0
    old = load(acct_from, handle_from)
    n = 0
    for line in (src / "reads.jsonl").read_text(encoding="utf-8").splitlines():
        try:
            record(acct_to, handle_to, json.loads(line))
            n += 1
        except ValueError:
            continue
    d = load(acct_to, handle_to)
    for nm in old.get("names", []):
        if nm not in d["names"]:
            d["names"].append(nm)
    d["tags"] = d.get("tags") or old.get("tags", [])
    d["notes"] = d.get("notes") or old.get("notes", "")
    _save(fan_dir(acct_to, handle_to) / "fan.json", d)
    if (src / "media").exists():                 # pictures travel too
        dst = fan_dir(acct_to, handle_to) / "media"
        dst.mkdir(parents=True, exist_ok=True)
        for p in (src / "media").glob("*.jpg"):
            if not (dst / p.name).exists():
                shutil.move(str(p), str(dst / p.name))
    shutil.rmtree(src, ignore_errors=True)
    return n


def promote(acct: str, handle: str, name: str) -> int:
    """A full handle is known: fold in his provisional files (same name, and a
    handle start that fits). Returns reads moved."""
    base = root() / slug(acct or "unknown")
    n = 0
    for p in base.glob("--*/fan.json") if base.exists() else []:
        prov = p.parent.name
        prefix, pname = _prov_parts(prov)
        if prefix and not handle.lower().startswith(prefix):
            continue
        d = load(acct, prov)
        if not any(names_match(name, x) for x in d.get("names", []) + [pname]):
            continue
        n += move_reads(acct, prov, acct, handle)
    return n


def set_identity(acct: str, handle: str, name: str = "", tags: list[str] | None = None,
                 notes: str | None = None) -> None:
    """What the name modal (or a harvest) says about him."""
    d = load(acct, handle)
    if name and name not in d["names"]:
        d["names"].append(name)
    if tags:
        d["tags"] = tags
    if notes is not None:
        d["notes"] = notes                      # decision 20: latest copy only
    d["identified"] = time.time()
    _save(fan_dir(acct, handle) / "fan.json", d)


def set_insights(acct: str, handle: str, fields: dict) -> None:
    """The fan panel's numbers as last read by a harvest (spend, sub, last purchase)."""
    if not fields:
        return
    d = load(acct, handle)
    d["insights"] = {"at": time.time(), **fields}
    _save(fan_dir(acct, handle) / "fan.json", d)


# Silly's baller tiers by total spend (answer file, 2026-11-20).
TIERS = [(10000, "insane baller"), (5000, "big baller"), (3000, "baller"),
         (2000, "small baller"), (1000, "very small baller")]


def spend_value(s: str) -> float:
    """"$2.03k" -> 2030.0; 0 when unreadable."""
    m = re.search(r"\$\s?([\d.,]+)\s*([kK]?)", s or "")
    if not m:
        return 0.0
    try:
        return float(m[1].replace(",", "")) * (1000 if m[2] else 1)
    except ValueError:
        return 0.0


def tier(spend: float) -> str:
    return next((name for floor, name in TIERS if spend >= floor), "")


def rebuild(acct: str, handle: str) -> dict:
    """Throw fan.json's chat away and replay reads.jsonl (identity kept)."""
    old = load(acct, handle)
    d = {**old, "turns": [], "islands": [], "reads": 0, "first_seen": None}
    _prev["key"] = None
    for line in (fan_dir(acct, handle) / "reads.jsonl").read_text(encoding="utf-8").splitlines():
        try:
            apply(d, json.loads(line))
        except ValueError:
            continue
    _save(fan_dir(acct, handle) / "fan.json", d)
    return d


# ── pending: fans whose handle isn't known yet ───────────────────────────────
def add_pending(acct: str, name: str, rec: dict) -> None:
    p = pending_path(acct, name)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def pending_names(acct: str) -> list[str]:
    base = root() / slug(acct or "unknown") / "_pending"
    out = []
    for p in sorted(base.glob("*.jsonl")) if base.exists() else []:
        try:
            first = json.loads(p.read_text(encoding="utf-8").splitlines()[0])
            out.append(first.get("name") or p.stem)
        except (OSError, ValueError, IndexError):
            out.append(p.stem)
    return out


def adopt_pending(acct: str, name: str, handle: str) -> int:
    """Move every pending read whose name matches into the fan's folder. Returns
    how many reads were adopted."""
    base = root() / slug(acct or "unknown") / "_pending"
    n = 0
    for p in sorted(base.glob("*.jsonl")) if base.exists() else []:
        lines = p.read_text(encoding="utf-8").splitlines()
        try:
            pname = json.loads(lines[0]).get("name", "")
        except (ValueError, IndexError):
            continue
        if not names_match(pname, name):
            continue
        for line in lines:
            try:
                record(acct, handle, json.loads(line))
                n += 1
            except ValueError:
                continue
        p.unlink()
    return n


# ── media crops ──────────────────────────────────────────────────────────────
# The one copy of the picture hashing (shiftlog imports it from here).
_hashes: dict[Path, list[tuple[int, Path]]] = {}


def _ahash(img) -> int:
    """16x16 average hash: the same picture read twice is a few bits apart."""
    import numpy as np
    from PIL import Image
    g = Image.fromarray(img).convert("L").resize((16, 16), Image.BILINEAR)
    a = np.asarray(g, dtype=np.float32)
    bits = (a > a.mean()).flatten()
    return int("".join("1" if b else "0" for b in bits), 2)


def _known(folder: Path) -> list[tuple[int, Path]]:
    if folder not in _hashes:
        _hashes[folder] = [(int(p.stem, 16), p) for p in folder.glob("*.jpg")
                           if re.fullmatch(r"[0-9a-f]{64}", p.stem)]
    return _hashes[folder]

def keep_crops(rgb, acct: str, handle: str, turns: list[dict]) -> None:
    """Crop every text-less bubble (both sides) into media/; sets turn['media']
    to its path relative to the fan folder. Same picture read again = same file
    (shiftlog's 16x16 average hash), replaced only by a bigger crop."""
    from PIL import Image
    folder = fan_dir(acct, handle) / "media"
    for t in turns:
        box = t.get("box")
        if t.get("text") or t.get("partial") or not box:
            continue
        x0, y0, x1, y1 = (int(v) for v in box)
        if x1 - x0 < MEDIA_MIN or y1 - y0 < MEDIA_MIN:
            continue
        img = rgb[max(0, y0):y1 + 1, max(0, x0):x1 + 1]
        h = _ahash(img)
        hit = next((p for kh, p in _known(folder) if bin(kh ^ h).count("1") <= MEDIA_SAME), None)
        path = hit or folder / f"{h:064x}.jpg"
        try:
            bigger = hit is not None and img.shape[0] * img.shape[1] > \
                Image.open(hit).size[0] * Image.open(hit).size[1]
        except OSError:
            bigger = True
        if hit is None or bigger:
            folder.mkdir(parents=True, exist_ok=True)
            Image.fromarray(img).save(path, "JPEG", quality=85)
            if hit is None:
                _known(folder).append((h, path))
        t["media"] = path.relative_to(folder.parent).as_posix()


# ── checks ───────────────────────────────────────────────────────────────────
def selftest() -> int:
    import tempfile
    fails = 0

    def check(label, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {label}: {got!r}" + ("" if ok else f" (want {want!r})"))

    tmp = Path(tempfile.mkdtemp(prefix="fanstore_"))
    global _setting
    _setting = lambda section, key, default="": str(tmp) if (section, key) == ("FanData", "Root") else default

    check("names: list vs header", names_match("keefe I not into sexting Xd retar",
                                               "keefe | not into sexting Xd retard(Insert name Here)"), True)
    check("names: different", names_match("Fred", "Daryen Stanley"), False)

    t = lambda who, text, **k: {"who": who, "text": text, **k}
    r1 = {"at": 1, "name": "keefe", "turns": [t("fan", "I gotta sleep", time="9:10 am", day="Nov 20"),
                                             t("model", "oh thats okat", time="9:10 am"),
                                             t("model", "wanna chat tomorrow then? same time", time="9:11 am")]}
    r2 = {"at": 2, "name": "keefe", "turns": [t("model", "wanna chat tomorrow then? same time", time="9:11 am"),
                                             t("fan", "Goodnight", time="9:11 am"),
                                             t("model", "chief keefe", time="3:52 am", day="Nov 21"),
                                             t("model", "wya", time="3:52 am")]}
    record("CIN", "u81384506", r1)
    why = record("CIN", "u81384506", r2)
    d = load("CIN", "u81384506")
    check("stitched placed", why, "")
    check("stitched order", [x["text"] for x in d["turns"]],
          ["I gotta sleep", "oh thats okat", "wanna chat tomorrow then? same time", "Goodnight", "chief keefe", "wya"])
    check("days filled", [x.get("day") for x in d["turns"]],
          ["Nov 20", "Nov 20", "Nov 20", "Nov 20", "Nov 21", "Nov 21"])
    check("match prefix+name", match("CIN", "keefe I not into", "u813"), ["u81384506"])
    check("match wrong name", match("CIN", "Fred", "u813"), [])
    add_pending("CIN", "Sudo", {"at": 3, "name": "Sudo", "turns": [t("fan", "hey there", time="1:00 am")]})
    check("pending listed", pending_names("CIN"), ["Sudo"])
    check("adopt", adopt_pending("CIN", "Sudo", "itssudo"), 1)
    check("adopted chat", [x["text"] for x in load("CIN", "itssudo")["turns"]], ["hey there"])
    check("pending empty", pending_names("CIN"), [])
    rb = rebuild("CIN", "u81384506")
    check("rebuild same", [x["text"] for x in rb["turns"]], [x["text"] for x in d["turns"]])
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    print("ALL OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(selftest())
