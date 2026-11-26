"""
llm/suggest.py — suggest her next sexting message from what is on screen.

The AI's one job in chatting is SEXTING (docs/chatting-process.md). Sales —
whether to progress, stay or heat the story up — is always the chatter's call,
and yapping and damage control stay human. So the chatter tells this what is
needed and it writes the words:

    MODE     co      the co-chatter (prompts/cochatter.md): it reads the moment
                     itself and drafts her next burst of 1-3 short texts, in the
                     voice of the account in front (userdata/personas), with
                     real moments from her shift log as examples. A "NOTE:" line
                     is for the chatter; a lone "HANDOFF:" means "yours, send
                     nothing". CONTENT is the next PPV, if one is picked.
             filler  pure roleplay between PPVs, nothing salesy
             ppv     a caption setting up CONTENT, then one click-baity question
    TIER     the highest content the fan has bought — sets how explicit to be
    CONTENT  (ppv) what the bundle shows
    DIRECTION (optional) a note from the chatter

plus what it works out itself:

    CHAT          from the chat reader (userdata\\chat_now.json)
    FAN KEYWORDS  from his last message — she always mirrors his words
    EXAMPLES      a few of her own archived masses that fit the moment

The prompt the model gets is prompts/sexting.md: plain text, edit it freely.

    python suggest.py                                   filler, tier 0, chat on screen
    python suggest.py --mode ppv --tier 2 --content "topless, hands covering"
    python suggest.py --chat-file chat.txt               offline: "her:"/"fan:" lines
    python suggest.py --model <ollama model>             try another model
    python suggest.py --request r.json --out s.json      what suggest.ahk uses

────────────────────────────────────────────────────────────────────────────────
NEVER FOR THE WRONG FAN
────────────────────────────────────────────────────────────────────────────────
chat_now.json can be a second or two old — you clicked to another fan and
pressed the key at once. Suggestions for the previous fan's chat would be the
worst possible output, so the file is only trusted when its thumbnail matches a
capture taken NOW. Otherwise this waits for the reader to catch up, and if the
reader is not running, it reads the screen itself (slow, but right).

────────────────────────────────────────────────────────────────────────────────
THE RULES THE PROMPT CANNOT BE TRUSTED WITH ARE CHECKED HERE
────────────────────────────────────────────────────────────────────────────────
A 12B model follows a prompt most of the time. The rules whose failure would
reach a fan are checked in code (`problems`) and a failing draft is redrawn:
money words, the fan's keywords missing, far too short or too long, a ppv
caption with no question. A draft that still fails after the retries is shown
anyway, last, so the window is never empty — the chatter is the final check.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client                                    # noqa: E402
import draft                                     # noqa: E402
import transcript as T                           # noqa: E402

MMA_ROOT = Path(__file__).resolve().parents[3]
PROMPT = Path(__file__).resolve().parent / "prompts" / "sexting.md"
# MODE chat: her texting normally (greetings, small talk, backing off). Its
# examples are real lines she typed, not masses: the right shape for a text.
CHAT_PROMPT = Path(__file__).resolve().parent / "prompts" / "chat.md"
CORPUS = MMA_ROOT / "userdata" / "corpus" / "repaired" / "llm_v1.tsv"
N_LINES = 16            # real typed lines shown as voice examples in chat mode
ARCHIVE = MMA_ROOT / "userdata" / "mass_archive.txt"
# The last real run, kept whole for chatview.pyw to show and grade. suggest.ahk
# deletes its --out file once read, so this is the copy that survives.
LAST = MMA_ROOT / "userdata" / "suggest_last.json"
# Grades and picks, one JSON object per line: {"id", "n", "grade"|"picked", ...}.
# Read latest-wins per (id, n). Kept for the bake-off and the fine-tune.
RATINGS = MMA_ROOT / "userdata" / "suggest_ratings.jsonl"

MODES = ("co", "filler", "ppv")   # what --mode / a --request may ask for
MAX_TURNS = 12          # bubbles of history shown to the model
N_EXAMPLES = 5          # archived masses shown as extra voice examples
WAIT_S = 6.0            # how long to wait for the chat reader to catch up
TRIES = 5               # draws per suggestion before a failing draft is kept
                        # (was 3: a tier-0 sext failed all 3 and was posted anyway)
# Chat mode posts straight into a conversation (TestFlow's auto-reply), where a
# kept failure is a sent failure. Draws are ~1s; usability beats speed.
TRIES_CHAT = 8

# The content ladder, docs/chatting-process.md. TIER is an index into it.
TIERS = ["nothing bought yet", "bikini", "hand-bra", "pasties / stickers",
         "nipples visible", "full nudes", "genitals visible", "solo play",
         "with other creators"]

WORD = re.compile(r"[a-z']+")
STOP = set("""i me my you your u ur a an the and or but to of in on at for with is
am are was were be been it its it's that this so just im i'm i'll you're youre do
don't dont not no yes oh what how when if as by up out all can will would could
should have has had get got go going gonna wanna want like really very too much
more some any there here then than them they he she his her him we us our baby
babe fuck fucking fuckk fuckkk omg lol yeah yess yes okay ok probably maybe those
these never ever let sounds sound while also still even every after before
about again into from over then just only really totally honestly literally
right now well know think thing things make made take took see saw say said tell
feel felt need way something anything everything one two because gonna wanna
ill id ive youd youll hes shes thats theres whats lets
course definitely sure guess bit lot pretty kinda sorta""".split())
# ("course" etc.: "Of course!" counted as picking up his words and let a
# dead-end reply through, rated 6/10.)

# Money and selling words. The prompt forbids them; this makes sure.
# 2026-10-17, Live Trainer on a real chat: "Let's start with something small.
# Like, my bikini pictures. For $30." Bundles, previews and "start small" are
# shop talk; her 311 archived masses use none of it.
_BANNED = re.compile(r"\b(buy|bought|unlock\w*|purchas\w*|price\w*|tip|tips|"
                     r"subscri\w*|link|pay|paid|dollars?|bundles?|previews?|"
                     r"something small|start (off )?small|for \d+)\b|\$", re.I)
# Content as a product. "picture" stays allowed: she says "picture this".
_SHOP = re.compile(r"\b(pics?|videos?|vids?|photos?|content|selfies?|nudes)\b", re.I)
# Tier 0 filler is a tease: none of these yet (docs/chatting-process.md).
_EXPLICIT = re.compile(r"\b(cock|dick|pussy|clit|cum|cumming|tits|titties|nipples?|"
                       r"fuck(ing)? (me|you|your|my)|eat(ing)? (me|you) out)\b", re.I)
# How a chatbot starts a message, not how she does.
_OPENER = re.compile(r"^\s*(oh+\b|mm+\b|hm+\b|ah+\b|well\b|baby\b)", re.I)
# Stock "AI erotica" phrases the first versions kept reaching for.
_CLICHE = re.compile(r"\b(nectar|good boy|i must warn you|knows what he wants|"
                     r"core\b|ministrations|tantaliz\w*)", re.I)
# Roleplay narration: the model describing her instead of texting as her
# ("I'd say 'haha' to you with a smirk", "my voice dripping with honey").
# Rated 1/10 three times on 2026-10-15. Dialogue tags and stage directions only:
# "I'd sit on your face" is a fantasy she TEXTS, and stays allowed.
_NARRATION = re.compile(r"\bI'?d (say|ask|whisper|reply|murmur|purr|giggle|smirk)\b|"
                        r"\bwith a (smirk|grin|wink|coy smile|playful)|\bas if to say\b|"
                        r"\bmy voice\b|\bmy eyes (dancing|sparkling|glinting)|"
                        r"\b(toss|flip)(es|ing)? (of )?my hair\b|\"[^\"]{3,}\"", re.I)
# On OnlyFans they never meet. In a TEXT, an invitation is the model forgetting
# where it is ("Why don't you come over and give me a kiss?", rated 1/10). The
# sexting modes may still IMAGINE being in his room: that is the fantasy.
_MEETUP = re.compile(r"\bcome (over|round|by|see me)\b|\bmeet (up|you|me)\b|"
                     r"\b(my|your) place\b|\bhang out\b|\b(a )?date\b|\bpick (you|me) up\b", re.I)
# Pet names, in every mode. First only before she knew him ("What's going on
# with you today, cutie?", rated 6/10), then 2026-10-17: "lover", "baby boy" is
# parasocial. Her 311 archived masses: "baby" 0, "babe" 0, "lover" 0. She may
# name herself ("mummy"); she never names HIM.
_PETNAME = re.compile(r"\b(cutie|babe|baby(\s*(boy|girl))?|babyboy|lover|handsome|hun|honey|"
                      r"sweetie|sweetheart|darling|naughty boy|my love)\b", re.I)
# Handing his compliment back ("I think you're pretty cute yourself"): she is
# the prize, she takes compliments, she does not return them.
_RETURNED = re.compile(r"(cute|hot|handsome|pretty|gorgeous|sexy|beautiful) (too|yourself)\b|"
                       r"\byou('re| are) (so |really |pretty |kinda )?(cute|hot|handsome|gorgeous|sexy)\b|"
                       r"\byou('re| are)\b[^.?!\n]{0,20}\byourself\b", re.I)   # "not so bad yourself"
_ECHO = re.compile(r"(?i)^\s*(\(?write (her|your|the|my) next message\.?\)?|\[\s*(\.\.\.|…)\s*\])\s*$")
# (also a bare "[...]" line: the model's "and so on", posted as a text once)
# The model copies the transcript's labels and opens quotes it never closes.
_LABEL = re.compile(r"^\s*(her|she|model|creator|alice)\s*:\s*", re.I | re.M)

# ── MODE co: the co-chatter (prompts/cochatter.md) ─────────────────────────────
# One prompt for every moment, built 2026-10-27 from the two-sided shift log
# (userdata/corpus/Chat_Analysis.md). It drafts; the chatter edits and sends.
# Its rules differ from the old modes on purpose, because her real chats do:
# bursts of short texts instead of a 20-40 word block, "good boy" allowed (101x
# in her chats, always when he obeys), no fan-keyword quota (she reuses his
# exact words in 23% of lines), tits/ass teasing allowed before a purchase.
CO_PROMPT = Path(__file__).resolve().parent / "prompts" / "cochatter.md"
PERSONAS = MMA_ROOT / "userdata" / "personas"
SHIFTLOG_CHATS = MMA_ROOT / "userdata" / "shiftlog" / "chats"
ACTIVE_NOW = MMA_ROOT / "userdata" / "active_now.ini"
N_PAIRS = 6             # real (his message -> her burst) moments per draw
# Her own signature under a message, as the reader OCRs it. Only her bursts
# are examples: the other chatters on the account write differently.
SIGNERS = {"silly", "s silly"}
_CO_PETNAME = re.compile(r"\b(cutie|babe|baby(\s*(boy|girl))?|babyboy|lover|handsome|hun|honey|"
                         r"sweetie|sweetheart|sweet cheeks|darling|my love|dear)\b", re.I)
_CO_CLICHE = re.compile(r"\b(nectar|i must warn you|knows what he wants|core\b|"
                        r"ministrations|tantaliz\w*)", re.I)
# Before his first purchase: tits and ass teasing is hers, these are not.
_CO_EXPLICIT = re.compile(r"\b(cock|dick|pussy|clit|cum|cumming|"
                          r"fuck(ing)? (me|you|your|my)|eat(ing)? (me|you) out)\b", re.I)
# What he says that makes the message the chatter's, whatever the model would
# write. Checked in code BEFORE any draw: on the first test (2026-10-27) all
# three drafts answered "are you even real or is this some chatter" with "Oh
# I'm real alright", none handed off.
_FAN_HANDOFF = re.compile(r"\b(bots?|a\.i\.?|ai|chat ?gpt|chatters?|real person|"
                          r"(are|r) (you|u) (even )?real|is (this|it) (really|actually) (you|her)|"
                          r"refunds?|charge ?backs?|scam\w*|ripped off|report (you|u|this))\b", re.I)
# A slot the model left unfilled ("Oh hey there <name>"), and the prompt's own
# examples leaking in ("So, Colorado huh?" to a fan who never said Colorado).
_CO_PLACEHOLDER = re.compile(r"<\s*[a-z][a-z ]*>|\[(name|his name|fan)\]", re.I)
_CO_EXAMPLE_WORDS = ("colorado", "cancer", "scientist", "research", "wife")
# Asking HIM for pictures, a pic swap, or claiming she sent something she did
# not (Arena 2026-10-27: "ok i sent mine, now its ur turn mister"). Content
# goes out only as a PPV the chatter sends.
_CO_FAKE = re.compile(r"\bi (just |already )?sent (it|mine|you|u|one)\b|\b(send|show) me (a |some |ur |your )?"
                      r"(pic|pics|photo|selfie|dick|cock)|\b(i'?d love|i want|gimme) (a )?(pic|photo)|"
                      r"\b(ur|your) turn\b|\bpic for (a )?pic\b|\bswap (pics|photos)\b", re.I)
# Alice's fairy-tale bits. Real, but Silly 2026-10-27: "the model is
# overforcing alice ... dont force the wonderland thing". Six examples full of
# them taught every draft to open a realm, so a draw gets one at most.
_THEME = re.compile(r"wonderland|realm|travell?er|spells?\b|magic|enchant|fairy|wizard|potion", re.I)
_CO_SENT = re.compile(r"\bwhat i (just |already )?sent\b|\bi (just |already )?sent (u|you|it|something)\b|"
                      r"\bopen (it|this|that|what)\b|\bcheck (ur|your) (dms|messages|inbox)\b|"
                      r"\bunlock (it|this)\b", re.I)
# Another language's script mid-text. Artemis (Gemma 4) wrote "Long day xứng
# với long夜 lmao" on 2026-10-27. Spanish accents (Latin-1) stay allowed.
_FOREIGN = re.compile("[Ā-ɏḀ-ỿͰ-ϿЀ-ӿ֐-ۿ"
                      "฀-๿぀-ヿ㐀-鿿가-힯]")
_NOTE = re.compile(r"^\s*NOTE\s*:\s*(.*)$", re.I)
_HANDOFF = re.compile(r"^\s*HANDOFF\s*:\s*(.*)$", re.I)


# ------------------------------------------------------------------ prompt --
def system_prompt(examples: list[str], mode: str = "filler", persona: str = "") -> str:
    path = {"chat": CHAT_PROMPT, "co": CO_PROMPT}.get(mode, PROMPT)
    text = re.sub(r"<!--.*?-->\s*", "", path.read_text(encoding="utf-8"), flags=re.S)
    if mode == "co":
        # Examples here are whole moments, already "fan:"/"her:" blocks.
        text = text.replace("{{PERSONA}}", persona or
                            "(no card for this account: match the casing and marks of her texts in CHAT)")
        return text.replace("{{EXAMPLES}}", "\n\n".join(examples) or "(none)")
    block = "\n".join(f"- {e}" for e in examples) or "- (none)"
    if "{{EXAMPLES}}" in text:
        return text.replace("{{EXAMPLES}}", block)
    return text + "\n\n" + block


# ---------------------------------------------------------------- examples --
def load_archive() -> tuple[list[str], list[str]]:
    """(story paragraphs, ppv captions) from userdata\\mass_archive.txt.

    The masses are the right SHAPE of example: 1-3 sentences of story writing,
    which is what she wants from the AI. Her typelog lines are short fragments,
    because she sends in pieces, and handing those to the model taught it the
    wrong length. Test entries ("lalala") fall out on the length rule.
    """
    if not ARCHIVE.exists():
        return [], []
    story, ppv = set(), set()
    for entry in ARCHIVE.read_text(encoding="utf-8-sig").split("===END==="):
        body = re.sub(r"^\s*\[[^\]]*\]\s*\[[^\]]*\]\s*", "", entry.strip())
        is_ppv = False
        for p in re.split(r"\n\s*\n", body):
            p = p.strip()
            if re.match(r"(?i)^ppv\s*:", p):
                p, is_ppv = re.sub(r"(?i)^ppv\s*:\s*", "", p).strip(), True
            p = re.sub(r"^!\S+\s*", "", p)                 # the !mma trigger
            if p.startswith("--"):                          # an authoring comment
                continue
            p = re.sub(r"^::\S+\s*", "", p).replace("---", " ")
            p = " ".join(p.split())
            if len(p) >= 80 and len(p.split()) >= 14:
                (ppv if is_ppv else story).add(p)
                is_ppv = False
    return sorted(story), sorted(ppv)


def _words(t: str) -> set[str]:
    return {w for w in WORD.findall(t.lower()) if w not in STOP and len(w) > 2}


_lines_cache: list[str] | None = None
# Broader than _EXPLICIT: chat-mode examples are how she talks BEFORE sexting,
# so anything sexual stays out of them entirely.
_SEXUAL = re.compile(r"slut|whore|masturbat|cunnil|drain|undress|naked|nude|horny|wet\b|"
                     r"\bsex|moan|orgasm|\bass\b|boob|panties|bra\b|lick|suck|spank|"
                     r"mommy|daddy|kinky|naughty|submissive|dominat", re.I)


def load_lines() -> list[str]:
    """Short lines she really typed, for MODE chat. From the repaired corpus:
    junk-flagged lines and the "mma" source (pasted masses, not typing) are
    left out, and so is anything explicit or about money, because these show
    how she TEXTS, not how she sexts."""
    global _lines_cache
    if _lines_cache is not None:
        return _lines_cache
    try:
        rows = CORPUS.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        rows = []
    lines, count = [], {}
    for row in rows:
        f = row.split("\t")
        if len(f) < 5 or f[3] != "0" or f[2] == "mma":
            continue
        line = f[4].strip()
        key = line.lower()
        count[key] = count.get(key, 0) + 1
        if count[key] == 1:
            lines.append(line)
    out = []
    for line in lines:
        words = line.split()
        # Typed at least twice: she sends in pieces, so a one-off line is often
        # half a message ("We don't wan"); a repeated one is a phrase she uses.
        if count[line.lower()] < 2 or not (1 <= len(words) <= 14):
            continue
        if len(words) == 1 and len(line) < 4:          # "hat", "es": stubs
            continue
        if len(words) == 1 and line.isalpha() and line[0].isupper():   # "Tony": a name
            continue
        if (not re.search(r"[A-Za-z]{2}", line) or _EXPLICIT.search(line)
                or _SEXUAL.search(line) or _BANNED.search(line)):
            continue
        # A capitalised word after the first is usually a fan's name ("Hey
        # Ian"); she must never learn to use names.
        if any(w[:1].isupper() and not re.match(r"I\b|I'", w) for w in words[1:]):
            continue
        out.append(line)
    _lines_cache = out
    return out


def pick_lines(query: str, n: int = N_LINES) -> list[str]:
    """Real lines that share words with this moment, plus random ones so the
    voice is broad rather than an echo of his words."""
    pool = load_lines()
    if not pool:
        return []
    q = _words(query)
    near = [l for l in pool if _words(l) & q] if q else []
    random.shuffle(near)
    out = near[: n // 2]
    out += random.sample(pool, min(n - len(out), len(pool)))
    return out


def pick_examples(story: list[str], ppv: list[str], mode: str, query: str,
                  n: int = N_EXAMPLES) -> list[str]:
    """Her own masses that share the most words with this moment, plus a
    couple at random so three suggestions are not shown the same five."""
    pool = (ppv + story) if mode == "ppv" else story
    q = _words(query)
    ranked = sorted(pool, key=lambda t: len(_words(t) & q), reverse=True)
    top = [t for t in ranked[: n * 3] if _words(t) & q]
    random.shuffle(top)
    out = top[: n - 2]
    rest = [t for t in pool if t not in out]
    out += random.sample(rest, min(n - len(out), len(rest)))
    if mode == "ppv" and ppv and not any(t in ppv for t in out):
        out[-1] = random.choice(ppv)
    return out


def active_account() -> str:
    """The account MMA says is in front ("AW", "JES"), or "" when it does not know."""
    try:
        rows = ACTIVE_NOW.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return ""
    a = dict(r.split("=", 1) for r in rows if "=" in r)
    return a.get("name", "").strip() if a.get("state", "").strip() == "ok" else ""


DEFAULT_PERSONA = "basic"     # the card for any account without its own (Sophie-style)


def persona_cards() -> list[dict]:
    """Every card in userdata/personas: {key, name, codes, based, body}.

    The first line is the card's header, never shown to the model:
        Alice. Typelog accounts AW / ALIW.
        Sophie. Typelog account SOF. BASED ON: basic
        Latina. Category card. BASED ON: basic
    key is the file name (basic, latina, alice); codes are the accounts that
    use it; BASED ON names a category card it builds on. Lines still waiting
    for Silly ("(Silly to fill...)") are left out of body.
    """
    out = []
    for f in sorted(PERSONAS.glob("*.md")):
        try:
            lines = f.read_text(encoding="utf-8-sig").splitlines()
        except OSError:
            continue
        head = lines[0] if lines else ""
        m = re.search(r"Typelog accounts?\s+([A-Za-z0-9 /,]+?)\s*(\.|$)", head, re.I)
        b = re.search(r"BASED ON:\s*([\w-]+)", head, re.I)
        out.append({"key": f.stem.lower(), "name": head.split(".", 1)[0].strip() or f.stem,
                    "codes": [c for c in re.split(r"[\s/,]+", m[1]) if c and c.lower() != "and"] if m else [],
                    "based": b[1].lower() if b else "",
                    "body": [l for l in lines[1:] if l.strip() and "(Silly to fill" not in l]})
    return out


def load_persona(account: str) -> tuple[str, bool | None]:
    """(voice card, capitalised?) for this account, from userdata/personas.

    Matched by account code (AW) or card name (latina); an account with no
    card gets DEFAULT_PERSONA, because most chatting should read like Sophie
    (Silly, 2026-10-27). A card BASED ON a category gets the category's lines
    first, minus any label (VOICE:) it sets itself; CHARACTER lines add up.
    capitalised: True for the Alice voice, False for the lowercase ones, None
    when there are no cards at all.
    """
    cards = persona_cards()
    by_key = {c["key"]: c for c in cards}
    acct = account.strip().lower()
    card = next((c for c in cards if acct and (acct == c["key"]
                                               or acct in (x.lower() for x in c["codes"]))),
                by_key.get(DEFAULT_PERSONA))
    if not card:
        return "", None
    label = lambda l: l.split(":", 1)[0].strip().upper() if ":" in l[:20] else ""
    body = list(card["body"])
    base = by_key.get(card["based"]) if card["based"] != card["key"] else None
    if base:
        own = {label(l) for l in body} - {"CHARACTER", ""}
        body = [l for l in base["body"] if label(l) not in own] + body
    voice = next((l for l in body if label(l) == "VOICE"), "")
    caps = None if not voice else not re.search(r"lowercase", voice, re.I)
    return "\n".join(body), caps


def _caps_voice(lines: list[str]) -> bool:
    """Does this burst read as the capitalised voice (Alice) or a lowercase one?"""
    starts = [l[:1].isupper() for l in lines if l[:1].isalpha()]
    lower_u = any(re.search(r"\b(u|ur)\b", l) for l in lines)
    return bool(starts) and sum(starts) * 2 >= len(starts) and not lower_u


_pairs_cache: list[tuple[str, list[str], bool]] | None = None


def load_pairs() -> list[tuple[str, list[str], bool]]:
    """Real moments from the shift log: (his last texts, her burst back, caps?).

    Only her own bursts (SIGNERS), never across a gap in the read, never a PPV
    or a picture, and nothing with his name, money or a meet-up in it. Read
    once per process; the files are private and only ever reach the local model.
    """
    global _pairs_cache
    if _pairs_cache is not None:
        return _pairs_cache
    out = []
    for f in SHIFTLOG_CHATS.glob("*/*.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        names = {w.lower() for n in [d.get("fan", "")] + list(d.get("names", []))
                 for w in re.findall(r"[A-Za-z]{3,}", n or "")}
        ts = d.get("turns", [])
        i = 0
        while i < len(ts):
            if ts[i].get("who") != "fan":
                i += 1
                continue
            j = i
            while j < len(ts) and ts[j].get("who") == "fan" and not (j > i and ts[j].get("gap_before")):
                j += 1
            fan = [t["text"] for t in ts[i:j] if t.get("text")][-2:]
            k = j
            while (k < len(ts) and ts[k].get("who") == "model" and k - j < 5
                   and not ts[k].get("gap_before")):
                k += 1
            her = ts[j:k]
            i = max(k, i + 1)
            if not fan or not her or k - j > 4 or (j < len(ts) and ts[j].get("gap_before")):
                continue
            if any((t.get("sender") or "").strip().lower() not in SIGNERS
                   or not t.get("text") or t.get("price") for t in her):
                continue
            lines = [" ".join(t["text"].split()) for t in her]
            said = " ".join(fan + lines)
            # Under 3 words ("why", "inglesss") shows the model nothing to copy.
            if (any(len(l.split()) > 25 for l in lines) or len(" ".join(fan).split()) > 40
                    or len(" ".join(lines).split()) < 3
                    or _BANNED.search(said) or _MEETUP.search(" ".join(lines))
                    or names & {w.lower() for w in re.findall(r"[A-Za-z]{3,}", said)}):
                continue
            out.append((" ".join(fan), lines, _caps_voice(lines)))
    _pairs_cache = out
    return out


def pick_pairs(query: str, caps: bool | None, n: int = N_PAIRS) -> list[str]:
    """Moments in this creator's casing, half sharing words with his message,
    half at random, as "fan:"/"her:" blocks for {{EXAMPLES}}. At most one
    themed moment (_THEME) per draw, unless he brought the theme up."""
    pool = [p for p in load_pairs() if caps is None or p[2] == caps]
    if not pool:
        return []
    if not _THEME.search(query):
        themed = [p for p in pool if _THEME.search(" ".join(p[1]))]
        pool = [p for p in pool if p not in themed] + random.sample(themed, min(1, len(themed)))
    q = _words(query)
    near = [p for p in pool if _words(p[0]) & q] if q else []
    random.shuffle(near)
    got = near[: n // 2]
    got += random.sample([p for p in pool if p not in got], min(n - len(got), len(pool) - len(got)))
    return ["fan: " + fan + "\n" + "\n".join("her: " + l for l in lines) for fan, lines, _ in got]


def split_co(text: str) -> tuple[str, list[str], str]:
    """A co-chatter draft as (what to send, notes for the chatter, handoff reason).
    A handoff means send nothing: the chatter takes this message."""
    send, notes, handoff = [], [], ""
    for line in text.splitlines():
        if m := _HANDOFF.match(line):
            handoff = m[1].strip() or "the chatter should take this one"
        elif m := _NOTE.match(line):
            notes.append(m[1].strip())
        elif line.strip():
            send.append(line.strip())
    return ("" if handoff else "\n".join(send)), notes, handoff


def fan_keywords(turns: list[T.Turn], n: int = 8) -> list[str]:
    """Words from his last message(s) for her to mirror, in his order."""
    fan = [t.text for t in turns if t.who == "fan" and t.text]
    seen, out = set(), []
    for text in fan[-1:] or []:
        for w in WORD.findall(text.lower()):
            w = w.replace("'", "")             # "i'd" -> "id", caught by STOP
            if w not in STOP and len(w) > 2 and w not in seen:
                seen.add(w)
                out.append(w)
    return out[:n]


# ------------------------------------------------------------- the chat now --
def current_turns(wait_s: float = WAIT_S) -> tuple[list[T.Turn], str]:
    """The chat on screen RIGHT NOW. (turns, problem)."""
    import chatreader as CR
    try:
        rgb, layout, _ = T.capture_conversation()
    except T.A.WindowNotReady as e:
        return [], str(e)
    taken = time.time()
    now = T.pane_thumb(rgb, layout)
    deadline = taken + wait_s
    while CR.running() and time.time() < deadline:
        s = CR.load_state()
        if s and s.get("thumb"):
            same = T.thumb_diff(now, CR.thumb_from_json(s["thumb"])) <= CR.CHANGED
            # A read that finished after our capture is at least as current.
            if same or s.get("read_at", 0) > taken + 0.5:
                return [T.Turn.from_dict(d) for d in s["turns"]], ""
        time.sleep(0.15)
    # No reader, or it did not catch up: read it here. Slow, but never stale.
    return T.read_turns(rgb, layout), ""


def turns_from_file(path: str) -> list[T.Turn]:
    """Offline chat for testing: one "her: ..." or "fan: ..." per line."""
    out = []
    for line in Path(path).read_text(encoding="utf-8-sig").splitlines():
        m = re.match(r"\s*(her|model|fan)\s*:\s*(.*)", line, re.I)
        if m:
            who = "fan" if m[1].lower() == "fan" else "model"
            out.append(T.Turn(who=who, text=m[2].strip(), box=(0, 0, 0, 0)))
    return out


# --------------------------------------------------------------- generation --
def _co_line(t: T.Turn) -> str:
    """One bubble for the co-chatter. A PPV says whether he bought it (the moves
    PAYOFF and UNOPENED hang on that) but never its price: she never names one."""
    who = "fan" if t.who == "fan" else "her"
    body = t.render().split(": ", 1)[-1]
    if t.price or t.ppv_border:
        state = ("he bought it" if t.paid or t.ppv_border == "opened"
                 else "not bought yet" if t.paid is False or t.ppv_border == "unopened" else "")
        body = f"[PPV{', ' + state if state else ''}] " + (t.text or "")
    return f"{who}: {body.strip()}"


def co_input_block(turns, tier, content, direction) -> str:
    """The user message prompts/cochatter.md expects: FAN / NEXT PPV / DIRECTION / CHAT."""
    lines = [f"FAN: bought so far: {TIERS[tier]}"]
    if content.strip():
        lines.append(f"NEXT PPV: {content.strip()}")
    if direction.strip():
        lines.append(f"DIRECTION: {direction.strip()}")
    lines.append("CHAT:\n" + "\n".join(_co_line(t) for t in turns[-MAX_TURNS:]))
    lines.append("\nWrite her next texts.")
    return "\n".join(lines)


def input_block(turns, mode, tier, content, direction, keywords) -> str:
    if mode == "co":
        return co_input_block(turns, tier, content, direction)
    chat ="\n".join(("fan: " if t.who == "fan" else "her: ") + t.render().split(": ", 1)[-1]
                     for t in turns[-MAX_TURNS:])
    lines = [f"MODE: {mode}",
             f"TIER: {tier} ({TIERS[tier]})"]
    if mode == "ppv":
        lines.append(f"CONTENT: {content or '(not given: keep it to the current story)'}")
    lines.append("FAN KEYWORDS: " + (", ".join(keywords) or "(none)"))
    if direction.strip():
        lines.append(f"DIRECTION: {direction.strip()}")
    lines.append(f"CHAT:\n{chat}")
    lines.append("\nWrite her next message.")
    return "\n".join(lines)


def tidy(text: str, mode: str = "filler") -> str:
    """Fix in code what a 12B model gets wrong however it is asked: labels,
    quotes, chatbot openers, a trailing "hmm?", and a PPV question that should
    be its own message but was left at the end of the caption."""
    t = draft.clean(_LABEL.sub("", text))
    t = "\n".join(l.strip().strip('"“”') for l in t.splitlines() if l.strip()
                  # The input's last line, echoed back ("Write your next message.").
                  and not _ECHO.match(l))
    if mode == "co":
        # Her casing is the persona's, and a lone HANDOFF wins over any texts
        # the model wrote around it.
        t = "\n".join(re.sub(r"^\s*[-*•]\s+|^\s*\d+[.)]\s+", "", l) for l in t.splitlines())
        h = next((l for l in t.splitlines() if _HANDOFF.match(l)), "")
        return h.strip() if h else t
    if mode == "chat":
        # A text keeps its "hmm" and its lowercase: that is how she texts.
        return t
    while _OPENER.match(t):
        t = re.sub(r"^\s*\w+[,!.…]*\s*", "", t, count=1)
    t = re.sub(r",?\s*hm+\?", "?", t)
    if mode == "ppv" and "\n" not in t and t.rstrip().endswith("?"):
        # The LAST sentence break before the closing question, so a caption
        # with several sentences keeps them all on the first line.
        cuts = [m.end() for m in re.finditer(r"(?:[.!…]+|<3|;3|:3)\s+", t)]
        if cuts:
            t = t[:cuts[-1]].strip() + "\n" + t[cuts[-1]:].strip()
    return t[:1].upper() + t[1:] if t else t


def problems(text: str, mode: str, keywords: list[str], tier: int = 0,
             content: str = "", fan_n: int = 0, her_n: int = 99) -> list[str]:
    """What is wrong with a draft, in code. Empty = it passes.
    `fan_n`: words in his last message; chat mode is judged against it.
    `her_n`: how many messages she has sent so far (unused since pet names
    became a rule in every mode, 2026-10-17; kept for callers)."""
    if mode == "co":
        return co_problems(text, tier)          # suggest() also passes the direction
    out = []
    if _NARRATION.search(text):
        out.append("narrates instead of texting")
    lines = text.splitlines()
    words = set(WORD.findall(text.lower()))
    if _BANNED.search(text):
        out.append("money/selling word")
    if _OPENER.match(text):
        out.append("stock opener")
    if _CLICHE.search(text):
        out.append("cliché")
    if _PETNAME.search(text):
        out.append("pet name")
    # Outside a caption the fantasy is about her and him, not about content
    # ("I might even consider pulling out my bikini pics", 2026-10-17 replay).
    if mode in ("filler", "chat") and _SHOP.search(text):
        out.append("talks about content")
    # Tier 0 filler is teasing only. (A tier 0 PPV caption may go further — her
    # own first caption does — because the bundle is what he is being shown.)
    if mode in ("filler", "chat") and tier == 0 and _EXPLICIT.search(text):
        out.append("explicit before any purchase")
    if mode == "chat":
        # A text, sized to his: a few words back for a few words, and never a
        # paragraph. No keyword rule here: echoing "cant stop thinking" back at
        # him is the bot tell, not the cure.
        n = len(text.split())
        if n > max(14, 3 * fan_n):
            out.append("too long for a text")
        if len(lines) > 2:
            out.append("more than two texts")
        if _MEETUP.search(text):
            out.append("suggests meeting (they never meet)")
        if _RETURNED.search(text):
            out.append("returns his compliment")
        # She leads, lowkey: a question back, or one of his own words picked up.
        # Either is enough; a reply with neither ("thank youu <3" and nothing
        # else) is the dead end Silly asked her to avoid.
        if "?" not in text and not (words & set(keywords)):
            out.append("dead end: no question, none of his words")
        return out
    if keywords and not (words & set(keywords)):
        out.append("none of his words")
    if mode == "ppv":
        caption = " ".join(lines[:-1])
        if len(lines) < 2 or "?" not in lines[-1] or len(lines[-1].split()) > 22:
            out.append("ppv needs a caption, then a short question on its own line")
        n = len(caption.split())
        cwords = _words(content)
        if cwords and not (_words(caption) & cwords):
            out.append("caption ignores the content")
    else:
        n = len(text.split())
    if n < 12:
        out.append("too short")
    # Was 60. In TestFlow the sexts grew 33 -> 45 -> 62 words and Silly found
    # them "a little long"; the prompt now asks for 20-40.
    if n > 45:
        out.append("too long")
    return out


def _shingles(text: str, k: int = 5) -> set[tuple]:
    w = WORD.findall(text.lower())
    return {tuple(w[i:i + k]) for i in range(len(w) - k + 1)}


def co_problems(text: str, tier: int = 0, direction: str = "", caps: bool | None = None,
                chat: str = "", system: str = "") -> list[str]:
    """The co-chatter's rules, checked on what would be SENT (NOTE lines are for
    the chatter). A handoff passes: not answering is the right answer.
    `caps`: the persona's casing (load_persona); `chat`: the chat as shown;
    `system`: the system prompt it was given, to catch it being copied."""
    send, _, handoff = split_co(text)
    if handoff:
        return []
    out = []
    if not send:
        return ["nothing to send"]
    lines = send.splitlines()
    n = len(send.split())
    # Five words in a row from the prompt: its instructions ("Write your next
    # line here...", "One question back."), a card's sample line, or a real
    # example. Rocinante did all three on 2026-10-27. His words are fair game.
    if system and (_shingles(send) & _shingles(system)) - _shingles(chat):
        out.append("copies the prompt")
    if re.search(r"(?i)\b(write (your|her) next|one question back|normal girl answer|"
                  r"next (line|text|message) here)\b", send):
        out.append("copies the prompt")
    if _FOREIGN.search(send) and not _FOREIGN.search(chat):
        out.append("another language's script")
    # Pointing at content that does not exist. With a PPV in the chat, "open
    # it" is the UNOPENED move; without one it is a lie (Arena, Artemis:
    # "Open what I just sent" with nothing sent).
    if "[PPV" not in chat and _CO_SENT.search(send):
        out.append("points at content that was never sent")
    if _CO_FAKE.search(send):
        out.append("asks him for pics / claims she sent something")
    if _CO_PLACEHOLDER.search(send):
        out.append("left a placeholder")
    low_chat = chat.lower()
    if any(w in send.lower() and w not in low_chat for w in _CO_EXAMPLE_WORDS):
        out.append("copies the prompt's example")
    # The Alice voice spells out "you"; the lowercase voices do not start
    # every text with a capital.
    starts = [l[:1].isupper() for l in lines if l[:1].isalpha()]
    if caps is True and (re.search(r"\b(u|ur)\b", send) or (starts and sum(starts) * 2 < len(starts))):
        out.append("wrong voice: lowercase / \"u\" for an account that writes \"You\"")
    if caps is False and len(lines) > 1 and all(l[:1].isupper() for l in lines if l[:1].isalpha()):
        out.append("wrong voice: capitalised for a lowercase account")
    if _NARRATION.search(send):
        out.append("narrates instead of texting")
    if _BANNED.search(send):
        out.append("money/selling word")
    if _MEETUP.search(send):
        out.append("suggests meeting (they never meet)")
    if _CO_PETNAME.search(send):
        out.append("pet name")
    if _RETURNED.search(send):
        out.append("returns his compliment")
    if _CO_CLICHE.search(send):
        out.append("cliché")
    if tier == 0 and _CO_EXPLICIT.search(send):
        out.append("explicit before any purchase")
    if len(lines) > 4:
        out.append("more than 4 texts")
    if re.search(r"\bcaption\b", direction, re.I):
        # A PPV caption: one 20-60 word text, maybe a short challenge after it.
        if not 15 <= len(lines[0].split()) <= 65:
            out.append("caption should be 20-60 words")
    else:
        if any(len(l.split()) > 20 for l in lines):
            out.append("a text over 20 words")
        if n > 45:
            out.append("burst too long")
    return out


def suggest(turns, mode="filler", tier=0, content="", direction="",
            count=3, account=None) -> tuple[list[str], str]:
    """`count` drafts. Mode co returns each draft whole, NOTE/HANDOFF lines
    included (split_co separates them); `suggest.send` / `.notes` / `.handoff`
    hold the split, in the same order. `account`: whose voice, for mode co;
    None asks MMA which account is in front."""
    if not turns:
        return [], "nothing read from the chat"
    story, ppv = load_archive()
    keywords = fan_keywords(turns)
    if tier == 0:
        # Before his first purchase his explicit words are not hers to mirror:
        # "use his words" + "nothing explicit yet" made every draw fail one rule
        # or the other when he said "tits", and the failure got posted.
        keywords = [k for k in keywords if not _EXPLICIT.search(k) and not _SEXUAL.search(k)]
    fan_last = next((t.text for t in reversed(turns) if t.who == "fan" and t.text), "")
    # His whole last run of texts: "Hey" + "wsp" is one message sent in pieces.
    fan_run = []
    for tt in reversed(turns):
        if tt.who != "fan":
            break
        fan_run.append(tt.text)
    fan_n = len(" ".join(fan_run).split())
    her_n = sum(1 for tt in turns if tt.who == "model")
    query = " ".join([fan_last, content, direction])
    user = input_block(turns, mode, tier, content, direction, keywords)
    temp = client.get_float("Suggest", "Temperature", 0.9)

    model = client.model()
    if mode == "co":
        if account is None:
            account = active_account()
        persona, caps = load_persona(account)
        m = _FAN_HANDOFF.search(" ".join(reversed(fan_run)))
        if m and not direction.strip():
            # His message is the chatter's, so no draw at all. A DIRECTION
            # means the chatter has seen it and wants a draft anyway.
            h = f'HANDOFF: he said "{m[0]}" (bot / refund / chargeback question)'
            suggest.flags, suggest.contexts = [[]], [{"mode": mode, "account": account or "",
                                                     "handoff_rule": m[0], "user": user}]
            suggest.send, suggest.notes, suggest.handoff = [""], [[]], [h.split(": ", 1)[1]]
            return [h], ""

    # A time budget on redraws. Artemis-31B writes ~4 tok/s (a third of it on
    # the CPU), so 3 drafts x 5 redraws ran past the 300 s client timeout and
    # returned nothing (2026-10-27). After the budget, the best draft so far is
    # kept (flagged, as always) instead of drawing again.
    deadline = time.time() + client.get_float("Suggest", "BudgetS", 90.0)

    def one(_):
        best, tried = None, []              # tried: every draw that broke a rule
        for attempt in range(1, (TRIES_CHAT if mode == "chat" else TRIES) + 1):
            if best is not None and time.time() > deadline:
                break
            # Fresh examples per draw: three suggestions shown different lines
            # come out different, not just re-rolled.
            if mode == "chat":
                sys_p = system_prompt(pick_lines(fan_last), "chat")
            elif mode == "co":
                sys_p = system_prompt(pick_pairs(fan_last, caps), "co", persona)
            else:
                sys_p = system_prompt(pick_examples(story, ppv, mode, query))
            text, err = client.chat([{"role": "system", "content": sys_p},
                                     {"role": "user", "content": user}],
                                    temperature=temp,
                                    max_tokens=60 if mode == "chat" else 160)
            if err:
                return "", err, [], None
            got = tidy(text, mode)
            bad = (co_problems(got, tier, direction, caps, user, sys_p) if mode == "co"
                   else problems(got, mode, keywords, tier, content, fan_n, her_n))
            # Exactly what this draft was made from, so a rating of it can be
            # traced back to the prompt, the examples drawn and the raw output.
            ctx = {"model": model, "temperature": temp, "attempt": attempt,
                   "system": sys_p, "user": user, "raw": text, "keywords": keywords,
                   "mode": mode, "tier": tier, "content": content, "direction": direction,
                   "account": account or "", "rejected": list(tried)}
            if not bad:
                return got, "", [], ctx
            tried.append({"text": got, "problems": bad})
            if best is None or len(bad) < len(best[1]):
                best = (got, bad, ctx)
        best[2]["rejected"] = [x for x in tried if x["text"] != best[0]]
        return best[0], "", best[1], best[2]

    good, flawed, err = [], [], ""
    with ThreadPoolExecutor(max_workers=count) as pool:
        for text, e, bad, ctx in pool.map(one, range(count)):
            if e:
                err = e
            elif text and text not in [g for g, _ in good] + [f for f, _, _ in flawed]:
                (flawed.append((text, bad, ctx)) if bad else good.append((text, ctx)))
    out = [g for g, _ in good] + [t for t, _, _ in flawed]
    # Which rules each kept draft still breaks, in the same order — so the
    # window (and a test run) can say so instead of passing it off as clean.
    suggest.flags = [[] for _ in good] + [b for _, b, _ in flawed]
    # And what each one was made from (see one()), in the same order.
    suggest.contexts = [c for _, c in good] + [c for _, _, c in flawed]
    split = [split_co(t) for t in out] if mode == "co" else [(t, [], "") for t in out]
    suggest.send = [s for s, _, _ in split]
    suggest.notes = [n for _, n, _ in split]
    suggest.handoff = [h for _, _, h in split]
    return out, ("" if out else err or "the model returned nothing")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="suggest her next sexting message")
    ap.add_argument("--mode", choices=MODES, default="filler")
    ap.add_argument("--account", default=None,
                    help="co: whose voice (AW, JES...); default: the account MMA has in front")
    ap.add_argument("--tier", type=int, default=0, help=f"0-{len(TIERS) - 1}: {', '.join(TIERS)}")
    ap.add_argument("--content", default="", help="ppv: what the bundle shows")
    ap.add_argument("--prompt", default="", help="a direction from the chatter")
    ap.add_argument("--request", help="JSON {mode, tier, content, prompt} (suggest.ahk)")
    ap.add_argument("--chat-file", help="read the chat from this file, not the screen")
    ap.add_argument("--out", help="write JSON {suggestions, error, chat} here")
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--model", default="", help="Ollama model to use instead of llm.ini's")
    a = ap.parse_args(argv)
    if a.model:
        client.MODEL_OVERRIDE = a.model

    mode, tier, content, direction = a.mode, a.tier, a.content, a.prompt
    if a.request:
        r = json.loads(Path(a.request).read_text(encoding="utf-8-sig"))
        mode = r.get("mode", mode) if r.get("mode") in MODES else mode
        tier = int(r.get("tier", tier))
        content = r.get("content", content)
        direction = r.get("prompt", direction)
    tier = max(0, min(len(TIERS) - 1, tier))

    t0 = time.time()
    if a.chat_file:
        turns, problem = turns_from_file(a.chat_file), ""
    else:
        T.A.set_dpi_aware()
        turns, problem = current_turns()
    t1 = time.time()
    sugg, err = ([], problem) if problem else suggest(turns, mode, tier, content,
                                                      direction, a.count, a.account)
    timing = {"read_ms": int((t1 - t0) * 1000), "gen_ms": int((time.time() - t1) * 1000)}

    if a.out:
        run_id = time.strftime("%Y%m%d-%H%M%S-") + f"{int(time.time() * 1000) % 1000:03d}"
        res = {"id": run_id, "suggestions": sugg, "error": err,
               "flags": getattr(suggest, "flags", []),
               # Mode co: what each draft would send, its notes for the chatter,
               # and its handoff reason ("" = none). Same order as suggestions.
               "send": getattr(suggest, "send", sugg) if sugg else [],
               "notes": getattr(suggest, "notes", []) if sugg else [],
               "handoff": getattr(suggest, "handoff", []) if sugg else [],
               "contexts": getattr(suggest, "contexts", []),
               "chat": T.as_prompt_text(turns[-MAX_TURNS:]), **timing}
        tmp = Path(a.out + ".tmp")
        tmp.write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
        tmp.replace(a.out)
        if sugg:
            try:
                LAST.parent.mkdir(parents=True, exist_ok=True)
                tmp = LAST.with_suffix(".tmp")
                tmp.write_text(json.dumps({
                    **res, "at": time.time(), "model": client.model(),
                    "mode": mode, "tier": tier, "tier_name": TIERS[tier],
                    "content": content, "direction": direction,
                    "keywords": fan_keywords(turns)}, ensure_ascii=False, indent=1),
                    encoding="utf-8")
                tmp.replace(LAST)
            except OSError:
                pass                          # the viewer is a nicety, never a blocker
    else:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        print(T.as_prompt_text(turns[-MAX_TURNS:]))
        print(f"\n--- {mode}, tier {tier} ({TIERS[tier]}), keywords "
              f"{fan_keywords(turns)}  {timing} ---")
        flags = getattr(suggest, "flags", [])
        for i, s in enumerate(sugg, 1):
            f = flags[i - 1] if i <= len(flags) else []
            print(f"{i}. {s}" + (f"\n   !! still: {', '.join(f)}" if f else "") + "\n")
        if err:
            print(f"!! {err}")
    return 0 if sugg else 1


if __name__ == "__main__":
    sys.exit(main())
