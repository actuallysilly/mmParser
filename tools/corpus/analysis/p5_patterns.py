"""Pass 5a: common word combinations and sentence frames (clean lines only)."""
import collections
import json
import math
import re

from rcommon import OUT, load_repaired, wtoks

M = [m for m in load_repaired() if not m.dirty]
S = [wtoks(m.text) for m in M]
res = {"clean_messages": len(M)}


def ngrams(ws, n):
    return [tuple(ws[i:i + n]) for i in range(len(ws) - n + 1)]


for n in (2, 3, 4, 5, 6, 7):
    c = collections.Counter(g for ws in S for g in ngrams(ws, n))
    res[f"top_{n}grams"] = [(" ".join(g), k) for g, k in c.most_common(50)]

# collocations: PMI over adjacent pairs, min count 15
uni = collections.Counter(w for ws in S for w in ws)
bi = collections.Counter(g for ws in S for g in ngrams(ws, 2))
N = sum(uni.values())
pmi = []
for (a, b), k in bi.items():
    if k >= 15:
        pmi.append((math.log(k * N / (uni[a] * uni[b])), f"{a} {b}", k))
pmi.sort(reverse=True)
res["collocations_pmi"] = [(p, round(s, 2), k) for s, p, k in pmi[:70]]

# sentence frames: first three words -> how many distinct continuations, and how
# predictable the next word is from them
frames = collections.defaultdict(collections.Counter)
for ws in S:
    if len(ws) >= 4:
        frames[" ".join(ws[:3])][ws[3]] += 1
top_frames = sorted(frames.items(), key=lambda kv: -sum(kv[1].values()))[:40]
res["opening_frames"] = [(f, sum(c.values()), c.most_common(5)) for f, c in top_frames]

# "skeleton" templates: function words kept, content words -> X
FUNC = set("""i you me my your it the a an to and of in on for with so that this is are be
was will would can do don't i'm you're it's that's what how why if but not just like want
need going have get make tell let's we us our he she they them his her at as or all now then
when there here about up out down off over into too very really more much no yes oh mmm hmm
""".split())
skel = collections.Counter()
for ws in S:
    if 3 <= len(ws) <= 9:
        skel[" ".join(w if w in FUNC else "X" for w in ws)] += 1
res["skeletons"] = [(s, k) for s, k in skel.most_common(60) if "X" in s][:45]

# questions vs statements vs commands
q = sum(1 for m in M if m.text.rstrip().endswith("?") or re.match(r"(?i)(do|did|are|is|would|will|can|could|what|why|how|when|where|who|have|has|should)\b", m.text))
imp = sum(1 for m in M if re.match(r"(?i)(tell|show|open|make|send|take|keep|stroke|imagine|look|let|give|come|be|stop|go|get|say|touch|spread|edge)\b", m.text))
res["mood"] = {"question_like": q / len(M), "imperative_like": imp / len(M)}

(OUT / "p5_patterns.json").write_text(json.dumps(res, indent=1))
for k, v in res.items():
    if isinstance(v, list):
        print(f"\n## {k}")
        for x in v[:30]:
            print("  ", x)
    else:
        print(k, v)
