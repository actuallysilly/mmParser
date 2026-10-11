"""Pass 2b: rule-repair every merged line -> userdata/corpus/repaired/rules_v1.tsv

    day <tab> idx <tab> source <tab> dirty <tab> text

dirty = 1 when the repaired text still has an unknown, uncommon word or a glued
capital — the lines worth sending to an LLM in the repair phase. Dropped lines
(not messages) and scrubbed lines (see common.sensitive) are omitted.
"""
import collections
import re

from common import CORPUS, load, scrub_patterns, sensitive
from repair import counts, known, repair

OUT = CORPUS / "repaired"
OUT.mkdir(exist_ok=True)


def dirty(t: str) -> bool:
    toks = re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", t)
    return (any(not known(w.lower()) and counts()[w.lower()] < 30 for w in toks)
            or bool(re.search(r"[a-z][A-Z]", t)))


stats = collections.Counter()
patterns = scrub_patterns()
with open(OUT / "rules_v1.tsv", "w", encoding="utf-8") as fh:
    for ln in load():
        stats["in"] += 1
        if sensitive(ln.text, patterns):
            stats["scrubbed"] += 1
            continue
        t = repair(ln.text)
        if not t:
            stats["dropped"] += 1
            continue
        d = dirty(t)
        stats["dirty"] += d
        stats["kept"] += 1
        stats["changed"] += t != re.sub(r"\s+", " ", ln.text).strip()
        esc = t.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        fh.write(f"{ln.day}\t{ln.idx}\t{ln.source}\t{int(d)}\t{esc}\n")
print(dict(stats))
print(f"dirty share of kept: {stats['dirty'] / stats['kept']:.1%}")
