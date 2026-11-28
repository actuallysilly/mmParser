"""
tools/usage_report.py — what you actually used, from userdata/usage/*.tsv.

    python tools/usage_report.py              last 14 days
    python tools/usage_report.py --days 30
    python tools/usage_report.py --all

Prints every key / hotstring / typed shortcut / tool with how often and when it
was last used, then the hotkeys in hotkeys.ini that were NOT used in that window
(candidates to cut). The log is written by src/core/usage.ahk.
"""
from __future__ import annotations

import argparse
import configparser
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
USAGE = ROOT / "userdata" / "usage"
HOTKEYS = ROOT / "userdata" / "hotkeys.ini"


def rows(since: datetime | None):
    for f in sorted(USAGE.glob("*.tsv")):
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            p = line.split("\t")
            if len(p) < 4:
                continue
            try:
                t = datetime.strptime(p[0], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            if since is None or t >= since:
                yield t, p[1], p[2], p[3]


def bound_keys() -> dict[str, str]:
    """hotkey id -> its keys, for every action that has a key."""
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    try:
        cp.read(HOTKEYS, encoding="utf-8-sig")
    except Exception:
        return {}
    out = {}
    for sec in cp.sections():
        if sec in ("meta", "hotstring"):
            continue
        for k, v in cp.items(sec):
            if v.strip():
                out[f"{sec}.{k}"] = v.strip()
    return out


def main(argv=None) -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args(argv)
    since = None if a.all else datetime.now() - timedelta(days=a.days)
    data = list(rows(since))
    span = "everything" if a.all else f"the last {a.days} days"
    if not data:
        print(f"No usage recorded in {span} yet ({USAGE}). Use MMA for a while, then run this again.")
        return 0
    first = min(t for t, *_ in data)
    print(f"Usage in {span} (recorded since {first:%Y-%m-%d %H:%M}), {len(data)} uses\n")
    count, last = Counter(), {}
    for t, _proc, kind, ident in data:
        count[(kind, ident)] += 1
        last[(kind, ident)] = max(t, last.get((kind, ident), t))
    for kind in ("key", "hotstring", "typed", "tool"):
        items = [(k, n) for k, n in count.items() if k[0] == kind]
        if not items:
            continue
        print(f"== {kind} ({sum(n for _, n in items)} uses, {len(items)} different)")
        for (_, ident), n in sorted(items, key=lambda x: -x[1]):
            print(f"  {n:6}  {ident:40}  last {last[(kind, ident)]:%Y-%m-%d %H:%M}")
        print()
    used = {ident for (kind, ident) in count if kind == "key"}
    unused = {k: v for k, v in bound_keys().items() if k not in used}
    if unused:
        print(f"== keys with a binding that were NOT pressed in {span} ({len(unused)})")
        for k, v in sorted(unused.items()):
            print(f"  {k:40}  {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
