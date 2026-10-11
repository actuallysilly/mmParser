"""Repair lines with a local Ollama model; score against gold.py like the rules.

    python llm_repair.py [model] [raw|rules]
"""
import difflib
import json
import re
import sys
import time
import urllib.request

from common import OUT
sys.path.insert(0, str(OUT))      # gold.py is private data: it lives in userdata\, not the repo
from gold import GOLD  # noqa: E402
from repair import canon, repair

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mistral-nemo:12b"
INPUT = sys.argv[2] if len(sys.argv) > 2 else "raw"

SYSTEM = """You clean up lines from a buggy keystroke logger. Each user turn gives ONE line
between <line> tags: a chat message a woman typed and sent on an adult creator platform.

The logger corrupted lines in these ways:
1. Abandoned drafts stay glued in front of the real text. A capital letter glued to a
   lowercase letter marks where she started over; the text before it was deleted.
2. A deleted attempt glued onto a real word (junk letters then the word).
3. The same text echoed in overlapping pieces; rebuild the single sentence.
4. Price entries and media-vault search codes are not messages.

Also fix misspellings and writing errors (dont -> don't, im -> I'm, i -> I, typos), but
keep the casual tone: slang (rn, lol, tysm, wdym), emoticons (<3 ;3 >.<), caps for
emphasis, elongations. Never add content, never rephrase, never censor, never comment.

Reply with ONLY the cleaned message. If the line is not a message, reply exactly <none>.
If it needs nothing, repeat it unchanged."""

SHOTS = [
    ("kniKnow somet thingHey Sam!!!", "Hey Sam!!!"),
    ("Literally amI'm in some senseform of undressing mania", "Literally I'm in some form of undressing mania"),
    ("Thank you so much <33", "Thank you so much <33"),
    ("im so wet rn and i dont know what to do", "I'm so wet rn and I don't know what to do"),
    ("879./779.79", "<none>"),
    ("Tell me qucklquickly what in particcularopparparticular you liked so much",
     "Tell me quickly what in particular you liked so much"),
]


def ask(line: str) -> str:
    msgs = [{"role": "system", "content": SYSTEM}]
    for a, b in SHOTS:
        msgs += [{"role": "user", "content": f"<line>{a}</line>"}, {"role": "assistant", "content": b}]
    msgs.append({"role": "user", "content": f"<line>{line}</line>"})
    body = json.dumps({"model": MODEL, "messages": msgs, "stream": False, "think": False,
                       "options": {"temperature": 0, "num_predict": 200}}).encode()
    req = urllib.request.Request("http://127.0.0.1:11434/api/chat", body,
                                 {"Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req, timeout=300).read())["message"]["content"]
    out = out.strip().strip('"')
    return "" if out == "<none>" else out


def norm(s):
    return canon(re.sub(r"\s+", " ", s).strip())


S = json.load(open(OUT / "gold_sample.json", encoding="utf-8"))
exact = sim = n = 0
broke_ok = 0
results = []
t0 = time.time()
for row, (gold, cat) in zip(S, GOLD):
    src = row["text"] if INPUT == "raw" else repair(row["text"])
    got = norm(ask(src)) if src.strip() else ""
    results.append({"raw": row["text"], "got": got, "gold": gold, "cat": cat})
    if gold is None:
        continue
    g = norm(gold)
    n += 1
    exact += got == g
    sim += difflib.SequenceMatcher(None, got, g).ratio() if (got or g) else 1
    broke_ok += cat == "ok" and got != g
dt = time.time() - t0
print(f"{MODEL} on {INPUT}: exact {exact}/{n} = {exact / n:.1%}  char-sim {sim / n:.3f}  "
      f"broke {broke_ok} clean lines  {dt / len(S) * 1000:.0f} ms/line")
(OUT / f"llm_repair_{MODEL.replace(':', '_')}_{INPUT}.json").write_text(
    json.dumps(results, ensure_ascii=False, indent=0), encoding="utf-8")
