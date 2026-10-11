"""Pass 8b: merge LLM corrections into the corpus, behind a guard.

    python p8_llm_merge.py

Reads every userdata/corpus/llm_repair/batch_NNN.out.tsv and writes
userdata/corpus/repaired/llm_v1.tsv: rules_v1.tsv with each corrected dirty line
replaced. autoword's corpus loader prefers llm_v1 when it exists.

THE GUARD. A repair may delete, may fix spelling, may collapse elongation. It may
not invent. Every word in the correction must be traceable to the raw line:
  * contained in it (apostrophes ignored: dont -> don't, im -> I'm), or
  * within 1 edit (3-letter words), 2 (4-7) or 3 (8+) of some stretch of it,
    which is what a typo fix looks like. Completing a cut-off word is not:
    `cheap and slu` -> `slutty` is 3 edits on a 6-letter word, and is refused.
Words of 1-2 letters are exempt (I, a, to: spelling fixes of these are free).
A correction that fails stays dirty and is listed in guard_rejects.tsv.

  ""   in the correction = not a message: the row is dropped
  "?"  = cannot be recovered: the row stays dirty, out of training
"""
import collections
import re

from common import CORPUS, load, scrub_patterns, sensitive
from repair import canon

DIR = CORPUS / "llm_repair"
WORDS = re.compile(r"[a-z]+(?:'[a-z]+)*")


def _edits_within(a: str, b: str, k: int) -> bool:
    """Is the edit distance from a to SOME substring of b at most k?"""
    # Sellers' algorithm: approximate substring match, free start and end in b.
    prev = [0] * (len(b) + 1)
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return min(prev) <= k


def traceable(fixed: str, raw: str) -> list[str]:
    """The words of `fixed` that cannot be traced to `raw` (empty = passes)."""
    r = raw.lower().replace("'", "")
    r_nospace = r.replace(" ", "")
    bad = []
    for w in WORDS.findall(canon(fixed).lower()):
        w0 = w.replace("'", "")
        if len(w0) <= 2 or w0 in r or w0 in r_nospace:
            continue
        k = 1 if len(w0) == 3 else 2 if len(w0) < 8 else 3
        if not _edits_within(w0, r, k):
            bad.append(w)
    return bad


def main():
    raw = {f"{ln.day}:{ln.idx}": ln.text for ln in load()}
    fixes: dict[str, str] = {}
    for path in sorted(DIR.glob("batch_*.out.tsv")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            key, _, text = line.partition("\t")
            fixes[key.strip()] = text.strip()

    stats = collections.Counter()
    rejects = []
    out = []
    patterns = scrub_patterns()
    for row in (CORPUS / "repaired" / "rules_v1.tsv").read_text(encoding="utf-8").splitlines():
        day, idx, src, dirty, text = row.split("\t", 4)
        key = f"{day}:{idx}"
        if sensitive(text, patterns) or sensitive(raw.get(key, ""), patterns):
            stats["scrubbed (sensitive)"] += 1
            continue
        if dirty != "1" or key not in fixes:
            stats["dirty, not repaired yet" if dirty == "1" else "clean, kept"] += 1
            out.append(row)
            continue
        fix = fixes[key]
        if fix == "":
            stats["dropped (not a message)"] += 1
            continue
        if fix == "?":
            stats["unrecoverable, left dirty"] += 1
            out.append(row)
            continue
        bad = traceable(fix, raw.get(key, ""))
        if bad:
            stats["guard rejected, left dirty"] += 1
            rejects.append(f"{key}\t{' '.join(bad)}\t{raw.get(key, '')}\t{fix}")
            out.append(row)
            continue
        stats["repaired"] += 1
        esc = canon(fix).replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        out.append(f"{day}\t{idx}\t{src}\t0\t{esc}")

    (CORPUS / "repaired" / "llm_v1.tsv").write_text("\n".join(out) + "\n", encoding="utf-8")
    (DIR / "guard_rejects.tsv").write_text("\n".join(rejects) + "\n", encoding="utf-8")
    for k, v in stats.most_common():
        print(f"  {k:<28} {v:>7,}")
    print(f"wrote {len(out):,} rows -> repaired/llm_v1.tsv; {len(rejects)} guard rejects")


if __name__ == "__main__":
    main()
