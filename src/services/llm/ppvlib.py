"""
llm/ppvlib.py — every PPV caption ever sent, how often it sold, and which to send next.

A "script" here is just a PPV caption: reusable text. The shift recorder already
keeps every PPV it sees (caption, price, "paid" / "not paid", who sent it), so the
library builds itself from userdata\\shiftlog\\chats\\ — nothing to type in.

    python ppvlib.py               rebuild userdata\\ppvlib.json and print the top
    python ppvlib.py --top 30      more of the ranking
    python ppvlib.py --now         recommend for the chat open in Infloww right now
    python ppvlib.py --now --json OUT   the same, as JSON for chat/ppvpick.ahk (^#p)
    python ppvlib.py --test        offline checks

Grouping. The same caption comes back from OCR slightly different every time
("TIDDIES" / "TIDDlES"), and a bubble scrolled half out of view gives only its
END (partial=True). So captions are grouped when one is a near copy of the other
(difflib >= SAME) or when a partial one is contained in a full one. The longest
full copy is the group's text.

Ranking. Raw "bought / sent" lies for small numbers: 1 of 1 is not a 100% caption.
The rate is pulled towards the account's average by PRIOR_SENDS imaginary sends
(a Bayesian average), and the score is that rate times its usual price: what one
send of it is expected to earn. Masses (sender "... PPV Technician / Engineer")
and your own 1:1 sends are counted apart, because a mass goes to everyone and a
1:1 PPV goes to a fan who is already talking — their rates are not comparable.

Known bias, said once here: the recorder only sees chats someone OPENED, and a
fan who replied is likelier to be opened, so every rate is higher than the true
one. It is the same bias for every caption, so the ORDER still means something.
"not paid" is the last state seen: a PPV sent ten minutes before the shift
ended may still sell.
"""
from __future__ import annotations

import difflib
import json
import re
import statistics
import sys
import time
from collections import Counter
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
CHATS = MMA_ROOT / "userdata" / "shiftlog" / "chats"
LIB = MMA_ROOT / "userdata" / "ppvlib.json"
REBUILD_AFTER_S = 3600                  # a press rebuilds a library older than this
SKIP_ACCOUNTS = {"TestFlow"}            # TestFlow's own practice chats are not sales

MIN_FANS = 2             # sent to this many different fans before it counts as a script
SAME = 0.85             # difflib ratio: the same caption, read twice
MIN_PART = 25            # a partial caption shorter than this is too little to place
PRIOR_SENDS = 5          # imaginary sends at the average rate (see the header)
_MASS = re.compile(r"ppv\s*(techn|engin)", re.I)
_WORD = re.compile(r"[a-z]{4,}")
# Words that say nothing about what a caption is about.
_STOP = set("""this that with your youre have just what when will want them they then
than there their been from into only some more like make made know think about
would could should really baby babe here just even ever every right still also
because while where which tonight today going gonna wanna dont cant isnt thats
tell show give take come back look feel need over very much such does doing""".split())


# The vault's tag overlay on the media is read into the caption: "00:03 Tags ·
# Techboy", "Tags : Sugma : sofia gomez : kira NIPPLE VAULT ...". The names change
# per post, so they are learned (learn_tags): every segment between separators
# before the last one is a name, and a caption that is ONLY an overlay is all name.
_OVERLAY = re.compile(r"^[\s\-\d:/|]*@?\s*tags\b\s*[:·.•]?\s*", re.I)
_TAG_SEP = re.compile(r"\s*[:·•]\s*")


def learn_tags(texts) -> set[str]:
    names = set()
    for t in texts:
        m = _OVERLAY.match(t or "")
        if not m:
            continue
        parts = [p for p in _TAG_SEP.split(t[m.end():].strip()) if p]
        names |= {p.lower() for p in parts[:-1] if len(p) <= 30}
        if len(parts) == 1 and len(parts[0]) <= 20:       # an overlay with no caption
            names.add(parts[0].lower())
    return names


def strip_overlay(text: str, names: set[str]) -> str:
    m = _OVERLAY.match(text or "")
    if not m:
        return (text or "").strip()
    rest = text[m.end():].strip()
    while True:
        low = rest.lower()
        for n in sorted(names, key=len, reverse=True):
            if low.startswith(n):
                rest = _TAG_SEP.sub(" ", rest[len(n):], count=1).strip() \
                    if _TAG_SEP.match(rest[len(n):]) else rest[len(n):].strip()
                break
        else:
            return rest


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9$ ]", " ", (s or "").lower())).strip()


def is_mass(sender: str | None) -> bool:
    return bool(_MASS.search(sender or ""))


def words(s: str) -> set[str]:
    out = set()
    for w in _WORD.findall((s or "").lower()):
        if w in _STOP:
            continue
        for suf in ("ing", "ies", "es", "s"):         # tits/tit, licking/lick
            if w.endswith(suf) and len(w) - len(suf) >= 4:
                w = w[:-len(suf)]
                break
        out.add(w)
    return out


# ------------------------------------------------------------------ grouping --
def same_caption(a: str, b: str, a_partial: bool = False, b_partial: bool = False) -> bool:
    """Two normalised captions are the same script."""
    if not a or not b:
        return False
    if a == b:
        return True
    short, long_ = (a, b) if len(a) <= len(b) else (b, a)
    if len(short) >= MIN_PART and short in long_:
        return True
    if (a_partial or b_partial) and len(short) >= MIN_PART:
        # A partial caption is the END of the real one: compare it with the end.
        tail = long_[-len(short):]
        if difflib.SequenceMatcher(None, short, tail).ratio() >= SAME:
            return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= SAME


def _chat_files(chats: Path | None):
    """(file, fan id) of every chat to learn from. Default: the fan files (one per
    @handle, filed by the real account) PLUS the old shift-log chats, which are
    all filed under "333" (the title's badge count, not an account) and are only
    a fallback until that recorder retires: then drop the second loop."""
    if chats is not None:                   # tests pass one folder
        return [(f, f.stem) for f in sorted(chats.glob("*/*.json"))]
    out = []
    try:
        import fanstore
        root = fanstore.root()
        out += [(f, f.parent.name) for f in sorted(root.glob("*/*/fan.json"))
                if f.parent.parent.name != "_pending"] if root.exists() else []
    except Exception:
        pass
    out += [(f, f.stem) for f in sorted(CHATS.glob("*/*.json"))]
    return out


def collect(chats: Path | None = None) -> list[dict]:
    """Every PPV her side sent, one record per (fan, caption, price, time)."""
    raw = []
    for f, fid in _chat_files(chats):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        acct = d.get("account") or f.parent.name
        if acct in SKIP_ACCOUNTS:
            continue
        raw += [(f, fid, d, acct, t) for t in d.get("turns", [])
                if t.get("who") == "model" and t.get("price")]
    names = learn_tags(t.get("text") for *_x, t in raw)
    sends, seen = [], set()
    for f, fid, d, acct, t in raw:
        text = strip_overlay(t.get("text") or "", names)
        n = norm(text)
        if len(n) < 8:                      # media with no caption: no script to reuse
            continue
        # One PPV is one (fan, price, time); the text is only the key when
        # there is no time, because OCR reads the same bubble differently.
        key = (acct, fid, t["price"], t.get("time") or n[-40:])
        if key in seen:
            continue
        seen.add(key)
        sends.append({"account": acct, "fan": d.get("fan") or (d.get("names") or [fid])[0], "file": fid,
                      "text": text, "norm": n, "partial": bool(t.get("partial")),
                      "price": t["price"], "paid": bool(t.get("paid")),
                      "sender": t.get("sender") or "", "time": t.get("time"),
                      "shift": t.get("shift")})
    return sends


def group(sends: list[dict]) -> list[dict]:
    """Sends -> scripts. Full captions first, so partials land on a full one."""
    groups: list[dict] = []
    for s in sorted(sends, key=lambda s: (s["partial"], -len(s["norm"]))):
        for g in groups:
            if g["account"] == s["account"] and same_caption(g["norm"], s["norm"], False, s["partial"]):
                g["sends"].append(s)
                break
        else:
            groups.append({"account": s["account"], "norm": s["norm"], "text": s["text"],
                           "partial": s["partial"], "sends": [s]})
    return groups


# ------------------------------------------------------------------- ranking --
def _price(v: str) -> float:
    try:
        return float(str(v).replace(",", ""))
    except ValueError:
        return 0.0


def build(chats: Path | None = None) -> dict:
    groups = group(collect(chats))
    # Each account's average rate, per kind: the prior every script is pulled to.
    base: dict[tuple, list[int]] = {}
    for g in groups:
        for s in g["sends"]:
            b = base.setdefault((g["account"], is_mass(s["sender"])), [0, 0])
            b[0] += s["paid"]
            b[1] += 1
    scripts = []
    for i, g in enumerate(groups):
        ss = g["sends"]
        kind = "mass" if sum(is_mass(s["sender"]) for s in ss) * 2 > len(ss) else "chat"
        b = base[(g["account"], kind == "mass")] if (g["account"], kind == "mass") in base \
            else [0, 1]
        prior = b[0] / b[1] if b[1] else 0.0
        bought = sum(s["paid"] for s in ss)
        rate = (bought + PRIOR_SENDS * prior) / (len(ss) + PRIOR_SENDS)
        prices = [_price(s["price"]) for s in ss]
        price = statistics.median(prices)
        scripts.append({
            "id": f"p{i + 1}", "account": g["account"], "kind": kind, "text": g["text"],
            "partial_only": g["partial"],
            "sent": len(ss), "bought": bought, "rate": round(rate, 4),
            "raw_rate": round(bought / len(ss), 4), "price": price,
            "earned": round(sum(p for p, s in zip(prices, ss) if s["paid"]), 2),
            "per_send": round(rate * price, 2),
            "prices": dict(Counter(s["price"] for s in ss).most_common()),
            "senders": dict(Counter(s["sender"] or "?" for s in ss).most_common()),
            "fans": sorted({s["file"] for s in ss}),
            # Sent to one fan only: a custom written for him, not a script.
            "reused": len({s["file"] for s in ss}) >= MIN_FANS,
            "words": sorted(words(g["text"])),
        })
    scripts.sort(key=lambda s: -s["per_send"])
    return {"built": time.time(), "sends": sum(s["sent"] for s in scripts),
            "base": {f"{a}|{'mass' if m else 'chat'}": round(v[0] / v[1], 4)
                     for (a, m), v in base.items()},
            "scripts": scripts}


def save(lib: dict, path: Path = LIB) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(lib, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def load(path: Path = LIB) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


# ------------------------------------------------------------ recommending --
KEYWORD_BONUS = 0.35     # per caption word the fan used himself, up to MAX_HITS
MAX_HITS = 3
FAN_TURNS = 20           # how far back his words count
# Price fit. A fan whose biggest purchase was $33 is not sent a $199 first: the
# ceiling is STRETCH x his highest spend, or FIRST_BUY for one who never bought.
# Over it the script is not hidden, only pushed down (and flagged).
STRETCH = 2.0
FIRST_BUY = 35.0
OVER_CEILING = 0.25
_MONEY = re.compile(r"\$\s*(\d[\d,]*(?:\.\d+)?)\s*(k)?", re.I)


def highest_spend(chat: dict) -> float | None:
    """His biggest single purchase from the fan panel; 0 for a fan who never
    bought; None when the panel was never read."""
    f = ((chat.get("panel") or {}).get("insights") or {}).get("fields")         or chat.get("insights") or {}          # fan files keep the fields flat
    for key in ("Highest spend", "Total spend"):
        m = _MONEY.search(f.get(key) or "")
        if m:
            v = float(m[1].replace(",", "")) * (1000 if m[2] else 1)
            if key == "Highest spend" or v == 0:
                return v
    return None


def recommend(lib: dict, account: str, fan_file: str, turns: list[dict],
              history: list[dict] | None = None, n: int = 5, kind: str | None = None,
              customs: bool = False, highest: float | None = None) -> list[dict]:
    """The scripts to send this fan next, best first.

    Leaves out what he has already been sent (in this read or in his saved chat),
    and lifts captions that use words he used: mirroring his words is the rule.
    """
    sent = [norm(t.get("text") or "") for t in (history or []) + turns
            if t.get("who") == "model" and t.get("price")]
    his = set()
    for t in [t for t in (history or []) + turns if t.get("who") == "fan"][-FAN_TURNS:]:
        his |= words(t.get("text") or "")
    out = []
    for s in lib["scripts"]:
        if s["account"] != account or (kind and s["kind"] != kind):
            continue
        if not (s["reused"] or customs):
            continue
        if fan_file in s["fans"] or any(same_caption(norm(s["text"]), x) for x in sent if x):
            continue
        hits = sorted(his & set(s["words"]))
        score = s["per_send"] * (1 + KEYWORD_BONUS * min(len(hits), MAX_HITS))
        over = highest is not None and s["price"] > max(STRETCH * highest, FIRST_BUY)
        if over:
            score *= OVER_CEILING
        out.append(dict(s, score=round(score, 2), hits=hits, over=over))
    out.sort(key=lambda s: -s["score"])
    return out[:n]


def recommend_now(lib: dict, n: int = 5) -> tuple[dict, list[dict]]:
    """For the chat in userdata\\chat_now.json (the chat reader keeps it fresh)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import shiftlog
    state = json.loads((MMA_ROOT / "userdata" / "chat_now.json").read_text(encoding="utf-8"))
    legacy = shiftlog.account_of(state.get("title") or "")
    turns = state.get("turns") or []
    # The fan recorder publishes his @handle and the real account (chat reader).
    if state.get("handle") and state.get("account"):
        import fanstore
        acct, fid = state["account"], state["handle"]
        path = fanstore.fan_dir(acct, fid) / "fan.json"
        chat = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        out = recommend(lib, acct, fid, turns, chat.get("turns", []), n, highest=highest_spend(chat))
        if out:
            return state, out
        hist, high = chat.get("turns", []), highest_spend(chat)
    else:
        hist, high = [], None
    # Fallback: the old shift log, all under "333".
    path = shiftlog._chat_path(legacy, state.get("fan") or "")
    chat = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    return state, recommend(lib, legacy, path.stem, turns, hist or chat.get("turns", []), n,
                            highest=high if high is not None else highest_spend(chat))


# ---------------------------------------------------------------------- tests --
def _test() -> int:
    fails = 0

    def ok(name, got, want):
        nonlocal fails
        print(("ok  " if got == want else "FAIL"), name, got if got != want else "")
        fails += got != want

    full = norm("$300 OFF Notification! U GOT CAUGHT STROKING TO MY BIG TIDDIES i'm not mad")
    ok("OCR variant is the same", same_caption(full, norm("$300 OFF Notification! U GOT CAUGHT "
                                                         "STROKING TO MY BIG TIDDlES im not mad")), True)
    ok("partial end is the same", same_caption(full, norm("STROKING TO MY BIG TIDDIES i'm not mad"),
                                               False, True), True)
    ok("different caption is not", same_caption(full, norm("3 ball slaps before bed tonight ok")), False)
    ok("short partial is not placed", same_caption(full, norm("not mad"), False, True), False)

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "A").mkdir()
        cap = "i want ur eyes on me and only me tonight, enjoying every touch of my thighs"
        other = "my bra is coming off and you get to watch every second of it"

        def chat(fan, *turns):
            (root / "A" / f"{fan}.json").write_text(json.dumps(
                {"account": "A", "fan": fan, "turns": list(turns)}), encoding="utf-8")
        ppv = lambda text, paid, price="30.00", sender="silly", partial=False: {  # noqa: E731
            "who": "model", "text": text, "price": price, "paid": paid, "sender": sender,
            "partial": partial, "time": "1:00 am"}
        chat("f1", ppv(cap, True), ppv(other, False, "20.00"))
        chat("f2", ppv(cap.replace("thighs", "thlghs"), True))
        chat("f3", ppv(cap[-40:], False, partial=True))
        chat("f4", ppv(other, False, "20.00"))
        lib = build(root)
        by = {s["text"][:10]: s for s in lib["scripts"]}
        ok("two scripts", len(lib["scripts"]), 2)
        ok("variant + partial grouped: 3 sent", by[cap[:10]]["sent"], 3)
        ok("2 of them bought", by[cap[:10]]["bought"], 2)
        ok("the seller ranks first", lib["scripts"][0]["text"][:10], cap[:10])
        recs = recommend(lib, "A", "f5", [{"who": "fan", "text": "your thighs are unreal"}])
        ok("new fan gets both, seller first", [r["text"][:10] for r in recs], [cap[:10], other[:10]])
        ok("his word is a hit", recs[0]["hits"], ["thigh"])
        ok("already sent is left out",
           [r["text"][:10] for r in recommend(lib, "A", "f1", [])], [])
        ok("sent in this read is left out",
           [r["text"][:10] for r in recommend(lib, "A", "f9", [ppv(other, False)])], [cap[:10]])
        ok("big spender: no penalty",
           [r["over"] for r in recommend(lib, "A", "f9", [], highest=100.0)], [False, False])
        ok("never bought: $30 fits under the first-buy ceiling",
           [r["over"] for r in recommend(lib, "A", "f9", [], highest=0.0)], [False, False])
        pricey = dict(lib, scripts=[dict(s, price=s["price"] * 5) for s in lib["scripts"]])
        ok("never bought: $100 and $150 are both over",
           sorted((r["price"], r["over"]) for r in recommend(pricey, "A", "f9", [], highest=0.0)),
           [(100.0, True), (150.0, True)])
        ok("$60 buyer: ceiling $120, so $100 fits and $150 is over",
           sorted((r["price"], r["over"]) for r in recommend(pricey, "A", "f9", [], highest=60.0)),
           [(100.0, False), (150.0, True)])

    names = learn_tags(["00:03 Tags · Techboy", "Tags : Sugma : sofia gomez : kira NIPPLE VAULT"])
    ok("tag names learned", sorted(names), ["sofia gomez", "sugma", "techboy"])
    ok("overlay stripped", strip_overlay("Tags · Techboy PoV: Feeding me", names), "PoV: Feeding me")
    ok("overlay-only caption is empty", strip_overlay("-00:04 Tags · Techboy", names), "")
    ok("no overlay: untouched", strip_overlay("Tagged you in my dreams", names), "Tagged you in my dreams")
    ok("highest spend parsed", highest_spend({"panel": {"insights": {"fields": {
        "Highest spend": "$33.33 PPV | Oct 23, 2026"}}}}), 33.33)
    ok("never bought = 0", highest_spend({"panel": {"insights": {"fields": {"Total spend": "$0"}}}}), 0.0)
    ok("no panel = None", highest_spend({}), None)
    return 1 if fails else 0


def _print(scripts: list[dict], base: dict | None = None) -> None:
    for s in scripts:
        hits = f"  his words: {', '.join(s['hits'])}" if s.get("hits") else ""
        hits += "  (over his usual price)" if s.get("over") else ""
        print(f"${s['per_send']:>6.2f}/send  {s['bought']:>2}/{s['sent']:<3} sold  "
              f"${s['price']:<6g} {s['kind']:<4} {s['text'][:90]!r}{hits}")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if "--test" in sys.argv:
        sys.exit(_test())
    if "--now" in sys.argv:
        # --json OUT: the answer for chat/ppvpick.ahk, written whole (tmp + rename)
        # so the window never reads half a file.
        out = Path(sys.argv[sys.argv.index("--json") + 1]) if "--json" in sys.argv else None
        if not LIB.exists():
            save(build())                   # first press ever: ~30s
        lib = load()
        try:
            state, recs = recommend_now(lib, n=int(sys.argv[sys.argv.index("--n") + 1])
                                        if "--n" in sys.argv else 8)
            ans = {"fan": state.get("fan") or "", "title": state.get("title") or "",
                   "note": state.get("note") or "", "built": lib["built"], "recs": recs}
        except Exception as e:              # no chat_now.json yet, a bad read
            ans = {"fan": "", "title": "", "note": f"{e.__class__.__name__}: {e}",
                   "built": lib["built"], "recs": []}
        if out:
            out.with_suffix(".tmp").write_text(json.dumps(ans, ensure_ascii=False), encoding="utf-8")
            out.with_suffix(".tmp").replace(out)
        else:
            print(f"{ans['title']} / {ans['fan']}: {ans['note']}")
            _print(ans["recs"])
        # The library is rebuilt AFTER answering, so a press never waits for it:
        # this one gets the hour-old ranking, the next gets the fresh one.
        if time.time() - lib["built"] > REBUILD_AFTER_S:
            save(build())
        sys.exit(0)
    lib = build()
    save(lib)
    top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 15
    print(f"{len(lib['scripts'])} scripts from {lib['sends']} sends -> {LIB}")
    print("average sold:", lib["base"])
    reused = [s for s in lib["scripts"] if s["reused"]]
    print(f"{len(reused)} sent to {MIN_FANS}+ fans (scripts); the rest are one-off customs")
    for kind in ("chat", "mass"):
        print(f"\n-- {kind} scripts --")
        _print([s for s in reused if s["kind"] == kind][:top])
