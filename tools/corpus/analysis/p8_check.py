"""Pass 8c: check that a batch's corrections cover exactly its ids, then merge.

    python p8_check.py 002 [003 ...]
"""
import subprocess
import sys

from common import CORPUS

DIR = CORPUS / "llm_repair"
ok = True
for n in sys.argv[1:]:
    a = [l.split("\t")[0] for l in (DIR / f"batch_{n}.in.tsv").read_text(encoding="utf-8").splitlines()]
    b = [l.split("\t")[0] for l in (DIR / f"batch_{n}.out.tsv").read_text(encoding="utf-8").splitlines() if l.strip()]
    missing, extra = sorted(set(a) - set(b)), sorted(set(b) - set(a))
    print(f"batch {n}: {len(a)} in, {len(b)} out, missing {missing[:5]}, extra {extra[:5]}")
    ok &= not missing and not extra and len(b) == len(set(b))
out = subprocess.run([sys.executable, "p8_llm_merge.py"], capture_output=True, text=True).stdout
print(out.strip().splitlines()[-1])
rej = (DIR / "guard_rejects.tsv").read_text(encoding="utf-8").strip().splitlines()
print("guard rejects:", [r.split("\t")[:2] for r in rej])
sys.exit(0 if ok else 1)
