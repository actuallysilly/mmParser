"""Score repair.py against the hand repairs in gold.py."""
import collections
import difflib
import json
import re

from common import OUT
import sys

sys.path.insert(0, str(OUT))      # gold.py is private data: it lives in userdata\, not the repo
from gold import GOLD  # noqa: E402
from repair import ALL_RULES, canon, repair

S = json.load(open(OUT / "gold_sample.json", encoding="utf-8"))


def norm(s):
    return canon(re.sub(r"\s+", " ", s).strip())


def score(fn, label):
    exact = sim = n = 0
    by_cat = collections.defaultdict(lambda: [0, 0])
    misses = []
    for row, (gold, cat) in zip(S, GOLD):
        if gold is None:
            continue
        got = norm(fn(row["text"]))
        g = norm(gold)
        n += 1
        ok = got == g
        exact += ok
        sim += difflib.SequenceMatcher(None, got, g).ratio() if (got or g) else 1
        by_cat[cat][0] += ok
        by_cat[cat][1] += 1
        if not ok:
            misses.append((cat, row["text"], got, g))
    print(f"{label:<28} exact {exact}/{n} = {exact / n:.1%}   mean char-similarity {sim / n:.3f}   "
          + "  ".join(f"{c}:{a}/{b}" for c, (a, b) in sorted(by_cat.items())))
    return misses


score(lambda t: t, "raw (no repair)")
for rules in [("nonmsg",), ("nonmsg", "echo"), ("nonmsg", "echo", "restart"),
              ("nonmsg", "echo", "restart", "fusion"), ALL_RULES]:
    score(lambda t, r=rules: repair(t, rules=r), "+".join(rules))
for mode in ("full", "frag", "smart"):
    m = score(lambda t, mode=mode: repair(t, restart_mode=mode), f"all, restart={mode}")
print("\nremaining misses (smart):")
for cat, raw, got, g in m:
    print(f"  [{cat}] {raw[:70]!r}\n      got  {got[:70]!r}\n      want {g[:70]!r}")
