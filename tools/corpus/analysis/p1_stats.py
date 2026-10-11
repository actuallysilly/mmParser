"""Pass 1: volume, shape, and how much junk is left, by source."""
import collections
import json
import re
import statistics
import sys

from common import OUT, load, words

sys.path.insert(0, str(__import__("common").MMA_ROOT / "src" / "autoword"))
from clean import SpellChecker  # noqa: E402  Windows ISpellChecker binding

lines = load()
spell = SpellChecker()
cache = {}


def known(w):
    lw = w.lower()
    if lw not in cache:
        cache[lw] = spell.in_dict(lw)
    return cache[lw]


RESTART = re.compile(r"[a-z'][A-Z]")          # 'haveSo', 'WYou' handled below
CAPRUN = re.compile(r"\b[A-Z][A-Z][a-z]")      # 'WYou', 'SOlo'
NUMERIC = re.compile(r"^[\d\s.,/$:+-]+$")

by_src = collections.defaultdict(lambda: collections.Counter())
days = collections.Counter()
lens = []
for ln in lines:
    days[ln.day] += 1
    w = words(ln.text)
    c = by_src[ln.source]
    c["lines"] += 1
    c["words"] += len(w)
    c["oov"] += sum(1 for x in w if not known(x))
    c["restart_lines"] += bool(RESTART.search(ln.text) or CAPRUN.search(ln.text))
    c["numeric_lines"] += bool(NUMERIC.match(ln.text.strip()))
    c["one_word_lines"] += len(w) == 1
    lens.append(len(w))

tot = collections.Counter()
for c in by_src.values():
    tot.update(c)
by_src["ALL"] = tot

res = {
    "lines": len(lines),
    "days": len(days),
    "words": tot["words"],
    "chars": sum(len(l.text) for l in lines),
    "lines_per_day": {"mean": statistics.mean(days.values()), "median": statistics.median(days.values()),
                      "max": max(days.values()), "min": min(days.values())},
    "words_per_line": {"mean": statistics.mean(lens), "median": statistics.median(lens),
                       "p90": sorted(lens)[int(.9 * len(lens))], "p99": sorted(lens)[int(.99 * len(lens))]},
    "len_hist": {k: sum(1 for x in lens if lo <= x <= hi) / len(lens)
                 for k, (lo, hi) in {"0": (0, 0), "1": (1, 1), "2-3": (2, 3), "4-6": (4, 6), "7-10": (7, 10),
                                     "11-20": (11, 20), "21+": (21, 10**9)}.items()},
    "by_source": {s: {**c, "oov_rate": round(c["oov"] / max(1, c["words"]), 4),
                      "restart_rate": round(c["restart_lines"] / max(1, c["lines"]), 4)}
                  for s, c in by_src.items()},
}
(OUT / "p1_stats.json").write_text(json.dumps(res, indent=1))
(OUT / "known_words.json").write_text(json.dumps(cache))
print(json.dumps(res, indent=1))
