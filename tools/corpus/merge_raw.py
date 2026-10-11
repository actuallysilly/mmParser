r"""
Merge the two raw typelog copies into one corpus, day by day.

    python tools\corpus\merge_raw.py            writes userdata\corpus\merged\
    python -m unittest tools\corpus\test_merge_raw.py

THE DATA
Until 2026-10-10 two recorders logged the same typing at once: the July
standalone (D:\Software\Dev\Chatting\typelog\logs, every day from 07-20) and
MMA's typelog service (userdata\typelog\*.log, from 08-10). Both had the same
bug: they wrote their keystroke buffer to disk every five seconds and cleared it,
so a Backspace after a write could not delete what was already on disk. The
deleted letters stayed in the line: `behing d` for `behind`.

Each recorder ran its own five-second timer, out of step with the other. So
each copy is the real text with junk INSERTED at its own random places. A lost
Backspace only ever adds characters, never removes them.

THE MERGE
  * Lines identical in both copies are kept as they are.
  * Lines that differ are merged character by character: keep the longest
    sequence of characters both copies share, in order. Junk that is in only one
    copy falls out. Junk in BOTH copies (a pause long enough for both timers to
    fire) survives, and is left for the LLM repair.
  * Line breaks are the exception: a break in only one copy is kept. The old
    recorders broke the line when focus left Infloww, and only if their buffer
    was non-empty, so one copy can have a break the other lacks. Dropping it
    would fuse words (`DiI'm`).
  * Lines in only one copy are kept: that recorder was the only one running.

The raw files are never modified. Output, one file per day:

    source <tab> text

    both     identical in both copies
    merged   differed, merged as above
    old      only in the July standalone's copy, on a day both ran
    mma      only in MMA's copy, on a day both ran
    single   a day only one copy exists for

Tabs and line breaks inside text are escaped the way the new typelog does it
(src\services\typelog\message.py): \t, \n, \\.
"""
from __future__ import annotations

import collections
import difflib
import sys
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[2]
OLD_DIR = Path(r"D:\Software\Dev\Chatting\typelog\logs")
MMA_DIR = MMA_ROOT / "userdata" / "typelog"
OUT_DIR = MMA_ROOT / "userdata" / "corpus" / "merged"

# A merge block bigger than this (characters on one side x the other) is merged
# line by line instead of as one string, so the DP table stays small.
MAX_CELLS = 2_000_000
# Two lines inside a differing block are treated as the same line when they
# share at least this much (difflib ratio). Below it they are separate lines.
PAIR_RATIO = 0.5


def read_lines(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    return [line for line in raw.split("\n") if line.strip()]


def merge_text(a: str, b: str) -> str:
    """The characters both strings share, in order, plus every line break either
    one has. Longest common subsequence, with breaks kept from both sides."""
    n, m = len(a), len(b)
    # lcs[i][j] = LCS length of a[i:], b[j:]
    lcs = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        row, below = lcs[i], lcs[i + 1]
        ai = a[i]
        for j in range(m - 1, -1, -1):
            if ai == b[j]:
                row[j] = below[j + 1] + 1
            else:
                row[j] = row[j + 1] if row[j + 1] >= below[j] else below[j]
    out = []
    i = j = 0
    while i < n and j < m:
        if a[i] == b[j]:
            out.append(a[i])
            i += 1
            j += 1
        elif lcs[i + 1][j] >= lcs[i][j + 1]:
            if a[i] == "\n":
                out.append("\n")
            i += 1
        else:
            if b[j] == "\n":
                out.append("\n")
            j += 1
    out.extend(c for c in a[i:] if c == "\n")
    out.extend(c for c in b[j:] if c == "\n")
    return "".join(out)


def _merge_block(a: list[str], b: list[str]) -> list[tuple[str, str]]:
    """A run of lines that differ between the copies."""
    if not a:
        return [("mma", line) for line in b]
    if not b:
        return [("old", line) for line in a]
    ja, jb = "\n".join(a), "\n".join(b)
    if len(ja) * len(jb) <= MAX_CELLS:
        merged = merge_text(ja, jb)
        return [("merged", line) for line in merged.split("\n") if line.strip()]
    return _merge_by_line(a, b)


def _merge_by_line(a: list[str], b: list[str]) -> list[tuple[str, str]]:
    """For blocks too big to merge as one string: walk both sides in order,
    pairing a line with the next similar line on the other side."""
    out: list[tuple[str, str]] = []
    i = j = 0
    while i < len(a) and j < len(b):
        if difflib.SequenceMatcher(None, a[i], b[j], autojunk=False).ratio() >= PAIR_RATIO:
            out.extend(("merged", line) for line in merge_text(a[i], b[j]).split("\n")
                       if line.strip())
            i += 1
            j += 1
        elif len(a) - i >= len(b) - j:
            out.append(("old", a[i]))
            i += 1
        else:
            out.append(("mma", b[j]))
            j += 1
    out.extend(("old", line) for line in a[i:])
    out.extend(("mma", line) for line in b[j:])
    return out


def merge_day(old: list[str], mma: list[str]) -> list[tuple[str, str]]:
    sm = difflib.SequenceMatcher(None, old, mma, autojunk=False)
    out: list[tuple[str, str]] = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            out.extend(("both", line) for line in old[i1:i2])
        else:
            out.extend(_merge_block(old[i1:i2], mma[j1:j2]))
    return out


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def main(argv=None) -> int:
    dates = sorted({p.name for p in OLD_DIR.glob("*.log")} |
                   {p.name for p in MMA_DIR.glob("*.log")})
    if not dates:
        print(f"no logs in {OLD_DIR} or {MMA_DIR}")
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total = collections.Counter()
    print(f"{'date':<12}" + "".join(f"{k:>8}" for k in
                                     ("both", "merged", "old", "mma", "single", "lines")))
    for name in dates:
        po, pm = OLD_DIR / name, MMA_DIR / name
        if po.exists() and pm.exists():
            rows = merge_day(read_lines(po), read_lines(pm))
        else:
            rows = [("single", line) for line in read_lines(po if po.exists() else pm)]
        (OUT_DIR / name).write_text(
            "".join(f"{src}\t{escape(text)}\n" for src, text in rows), encoding="utf-8")
        counts = collections.Counter(src for src, _ in rows)
        total.update(counts)
        print(f"{name[:-4]:<12}" + "".join(f"{counts[k]:>8}" for k in
                                           ("both", "merged", "old", "mma", "single"))
              + f"{len(rows):>8}")
    print(f"{'total':<12}" + "".join(f"{total[k]:>8}" for k in
                                     ("both", "merged", "old", "mma", "single"))
          + f"{sum(total.values()):>8}")
    print(f"\nwrote {len(dates)} days to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
