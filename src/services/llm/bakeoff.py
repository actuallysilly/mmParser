"""
llm/bakeoff.py — compare chat models on the suggestion key, blind.

Runs every fixed chat in userdata\\corpus\\bakeoff\\ through each model, in the
modes listed below, and writes two files there:

    blind_<stamp>.md   the drafts, model names hidden, order shuffled per case —
                       read this one and pick what sounds like you
    key_<stamp>.md     which letter was which model, and how many drafts per
                       model still broke a rule (the ⚠ flags)

    python bakeoff.py mistral-nemo:12b rocinante
"""
from __future__ import annotations

import random
import string
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client                                    # noqa: E402
import suggest as S                              # noqa: E402

DIR = S.MMA_ROOT / "userdata" / "corpus" / "bakeoff"

# (file, mode, tier, content) — the README in that folder says the same.
CASES = [
    ("1_tease_tier0.txt",   "filler", 0, ""),
    ("2_after_ppv1.txt",    "filler", 1, ""),
    ("2_after_ppv1.txt",    "ppv",    1, "topless, teasing her breasts"),
    ("3_low_effort.txt",    "filler", 0, ""),
    ("4_fan_has_ideas.txt", "filler", 1, ""),
    ("4_fan_has_ideas.txt", "ppv",    1, "bikini top coming off, hands covering"),
    ("5_late_tier.txt",     "filler", 4, ""),
]


def main(models: list[str]) -> int:
    if not models:
        print("usage: python bakeoff.py <model> <model> ...")
        return 2
    stamp = time.strftime("%Y-%m-%d_%H%M")
    blind, key = [f"# Blind bake-off {stamp}\n",
                  "Pick the drafts that read most like you. Letters are shuffled per case.\n"], \
                 [f"# Key for blind_{stamp}.md\n"]
    flags = {m: 0 for m in models}
    drafts = {m: 0 for m in models}
    times = {m: 0.0 for m in models}
    for n, (fname, mode, tier, content) in enumerate(CASES, 1):
        turns = S.turns_from_file(str(DIR / fname))
        head = f"{mode}, tier {tier} ({S.TIERS[tier]})" + (f", content: {content}" if content else "")
        blind.append(f"\n## Case {n}: {fname} — {head}\n\n```\n{S.T.as_prompt_text(turns)}\n```\n")
        key.append(f"\n## Case {n}\n")
        entries = []
        for m in models:
            client.MODEL_OVERRIDE = m
            t0 = time.time()
            out, err = S.suggest(turns, mode, tier, content, "", 3)
            times[m] += time.time() - t0
            fl = getattr(S.suggest, "flags", [[] for _ in out])
            if err:
                print(f"  {m}: {err}")
            for text, f in zip(out, fl):
                entries.append((m, text, f))
                drafts[m] += 1
                flags[m] += bool(f)
            print(f"case {n} {m}: {len(out)} drafts, {sum(bool(f) for f in fl)} flagged")
        random.shuffle(entries)
        for letter, (m, text, f) in zip(string.ascii_uppercase, entries):
            mark = f"  ⚠ {', '.join(f)}" if f else ""
            blind.append(f"**{letter}.** {text}{mark}\n")
            key.append(f"- {letter}: {m}\n")
    key.append("\n## Totals\n")
    for m in models:
        key.append(f"- **{m}**: {drafts[m]} drafts, {flags[m]} still broke a rule, "
                   f"{times[m]:.0f}s total\n")
    (DIR / f"blind_{stamp}.md").write_text("\n".join(blind), encoding="utf-8")
    (DIR / f"key_{stamp}.md").write_text("".join(key), encoding="utf-8")
    print(f"\nwrote blind_{stamp}.md and key_{stamp}.md in {DIR}")
    print("".join(key[key.index("\n## Totals\n"):]))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main(sys.argv[1:]))
