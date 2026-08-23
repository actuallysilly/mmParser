"""
autoword — configuration.

Every knob lives in userdata\\autoword.ini, never in code. The file is written
with commented defaults the first time the service starts, so the ini itself is
the documentation and nothing has to be edited here to retune the feature.

The two mode knobs are the reason this file exists: `predict` and `render` each
select a strategy class at startup, so adding a mode never touches the engine.
"""
from __future__ import annotations

import configparser
from dataclasses import dataclass, field
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
MMA_USERDATA = MMA_ROOT / "userdata"
MMA_DEBUGLOGS = MMA_ROOT / "debuglogs"
INI = MMA_USERDATA / "autoword.ini"

DEFAULT_INI = """\
; autoword — next-word suggestions while you type.
; Written automatically with defaults. Edit freely; the service re-reads it on
; start. Delete the file to get these defaults back.

[Mode]
; what to predict:  nextword | completion | both
;   nextword   after MinChars of a word, suggest the whole word from context
;   completion complete the word you are typing, ignoring context
;   both       nextword, falling back to completion when context is unknown
Predict = nextword

; how to show it:  off | strip | ghost
;   off    predict but draw nothing — writes what it WOULD have said to
;          debuglogs\\autoword_shadow.log so accuracy can be measured before
;          committing to any UI. Start here.
;   strip  small always-on-top row of suggestions near the message box
;   ghost  grey text at the caret (not implemented yet — see README)
Render = off

[Suggest]
; characters of the target word typed before suggesting. 1 is the measured
; sweet spot: 0 fires on every word and is right 15% of the time, 1 is right
; 35%, 2 is right 45% but you have already typed most of a 3.7-char word.
MinChars = 1

; how many candidates to offer. Measured keystroke saving: 1 -> 14.8%,
; 2 -> 17.0%, 3 -> 17.6%, 5 -> 17.8%. Past 3 you are paying attention for
; nothing.
ListSize = 3

; never suggest unless it saves at least this many characters. Accepting costs
; one keystroke, so the payoff is (word - what you have typed) - 1 and it shrinks
; as you type. Threshold the SAVING, not the word length.
;
; Raising this looks like it should trade saving for precision. It does the
; opposite — measured held-out, both get worse, because the short words it cuts
; (`to`, `so`, `me`, `it`) are the most predictable words in the corpus:
;
;     MinSaving 1   20.5% saved   46.3% precision   <- default
;     MinSaving 2   18.5%         37.7%
;     MinSaving 3   12.7%         25.0%
;     MinSaving 4    6.0%         14.5%
MinSaving = 1

; drop candidates below this share of the context's total count
MinProbability = 0.03

; type the word with no keypress at all when it is obvious: when NO other word
; in your corpus has ever followed this context with this prefix, you have typed
; this many characters of it, and it has been seen AutoCompleteSeen times.
; 0 = off, and off is the shipped default — this one writes into a live message.
;
; "Obvious" is uniqueness, not probability. Measured held-out on 5 unseen days,
; a probability gate is a bad one (p >= 0.9 after one character is still wrong
; 37% of the time). Having no alternative at all is a good one:
;
;     chars  seen   fires/day  right   wrong/day
;       3     3        841     95.4%      39
;       3     5        609     97.2%      17     <- a sane place to start
;       3    10        391     98.1%       7
;       2     5        454     94.0%      27
;
; Typing the rest of the word yourself is free — those keystrokes are swallowed
; because the letters are already on screen. Backspace immediately after takes
; the whole insertion back and stops it re-firing on that word.
AutoCompleteChars = 0
AutoCompleteSeen = 5

; wait until you have stopped typing for this many milliseconds before it types
; anything. 0 = the instant it decides, which is what produced `feelinging`:
; the decision is made a keystroke or two behind your fingers, so `feel` -> `ing`
; arrived after you had already typed the `i` yourself. A gap in your typing is
; the only moment nothing of yours is in flight — and the only moment you would
; notice a word appear. Mid-word gaps are rarely over 200ms even at speed, so
; 250 costs you almost no completions; raise it if you still get caught out,
; lower it if completions feel late.
AutoCompleteIdleMs = 250

; never extend a word you had already finished. `do` -> `does`, `you` -> `your`,
; `leg` -> `legs`, `nothing` -> `nothingness`: right most of the time and still
; wrong to do, because you were done — you just had not typed the space yet.
; A word counts as finished when the Windows dictionary knows it AND either the
; completion only adds a suffix, or you demonstrably type it on its own (`you`
; 10,189 times against `your` 2,267). Both halves are needed: the dictionary
; alone calls `jus`, `wan` and `nee` words, and your own counts alone cannot,
; because the typelog leaves truncation debris that looks like short words.
; Fragments are untouched — `jus` -> `just`, `wou` -> `would`, `thi` -> `this`.
AutoCompleteOnlyFragments = true

; and never these, whatever the rules above decide. Comma separated, and it is
; the finished word that goes here, not what you typed: `does, your, legs`.
; userdata\autoword\vocabulary.tsv lists every word you use, commonest first —
; that is the file to skim when this list needs adding to.
AutoCompleteNever =

[Keys]
; accept the highlighted candidate. Swallowed only while a suggestion is on
; screen, so Tab still tabs everywhere else.
Accept = tab
; move the highlight down the list; wraps. Must NOT be the same key as Accept —
; one keydown cannot mean both "move the highlight" and "take it", and if they
; match, cycling is disabled and only the first candidate is reachable.
; Accepting rank k therefore costs k presses, which is what the saving table in
; the README is measured against.
; Recognised: tab, shift+tab, ctrl+tab. Empty turns cycling off.
Cycle = shift+tab

[Reword]
; Ctrl+Tab on the word you have just typed offers other words for it —
; `touched` -> `caressed`, `stroked`, `grazed`. Tab takes the highlighted one,
; Ctrl+Tab again moves the highlight, Esc puts the list away, and typing
; anything at all forgets it. Nothing is written until you take one.
;
; Swallowed only when there is something to offer, so Ctrl+Tab keeps doing
; whatever it normally does in the app the rest of the time. Empty = off.
Key = ctrl+tab

; how many alternatives to offer. Rank k costs k presses of Ctrl+Tab, but the
; whole list is on screen either way, so this is about what you can read at a
; glance rather than what you can reach.
ListSize = 5

; the words themselves live in userdatautowordeword.txt — one group per
; line, comma separated, symmetric, written with a starter set the first time
; the service runs. Edit it freely; it is re-read on start.

[Scope]
; only suggest while one of these is the foreground process (comma separated).
; Empty = everywhere.
Processes = infloww.exe

[Model]
; rebuild the n-gram model from the typelog corpus on every start. The corpus is
; ~190k words and trains in a couple of seconds, so this is usually fine.
RetrainOnStart = true
; extra corpus files (one sentence per line) to train on, comma separated
ExtraCorpora =

[Strip]
; position is relative to the foreground window, in pixels
OffsetX = 40
OffsetY = -90
FontSize = 11
FontName = Segoe UI
Background = #202020
Foreground = #b0b0b0
Highlight = #ffffff
"""


@dataclass
class Config:
    predict: str = "nextword"
    render: str = "off"

    min_chars: int = 1
    list_size: int = 3
    min_saving: int = 1
    min_probability: float = 0.03
    auto_chars: int = 0
    auto_seen: int = 5
    auto_idle_ms: int = 250
    auto_only_fragments: bool = True
    auto_never: list[str] = field(default_factory=list)

    accept_key: str = "tab"
    cycle_key: str = "shift+tab"
    reword_key: str = "ctrl+tab"
    reword_list_size: int = 5

    processes: list[str] = field(default_factory=lambda: ["infloww.exe"])

    retrain_on_start: bool = True
    extra_corpora: list[str] = field(default_factory=list)

    strip_offset_x: int = 40
    strip_offset_y: int = -90
    strip_font_size: int = 11
    strip_font_name: str = "Segoe UI"
    strip_bg: str = "#202020"
    strip_fg: str = "#b0b0b0"
    strip_hl: str = "#ffffff"


def _csv(raw: str) -> list[str]:
    return [p.strip() for p in raw.split(",") if p.strip()]


def load(path: Path = INI) -> Config:
    """Read the ini, writing it with defaults first if it is missing.

    A malformed ini must never take the service down — it falls back to defaults
    and the caller logs it, the same rule clean.py uses for overrides.ini.
    """
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(DEFAULT_INI, encoding="utf-8")

    cp = configparser.ConfigParser(strict=False, inline_comment_prefixes=(";",))
    try:
        cp.read_string(path.read_text(encoding="utf-8-sig", errors="replace"))
    except configparser.Error:
        return Config()

    def get(sec, key, fallback):
        try:
            return cp.get(sec, key)
        except (configparser.NoSectionError, configparser.NoOptionError):
            return fallback

    def num(sec, key, fallback, cast=int):
        try:
            return cast(get(sec, key, fallback))
        except (TypeError, ValueError):
            return fallback

    return Config(
        predict=get("Mode", "Predict", "nextword").strip().lower(),
        render=get("Mode", "Render", "off").strip().lower(),
        min_chars=num("Suggest", "MinChars", 1),
        list_size=max(1, num("Suggest", "ListSize", 3)),
        min_saving=num("Suggest", "MinSaving", 1),
        min_probability=num("Suggest", "MinProbability", 0.03, float),
        auto_chars=max(0, num("Suggest", "AutoCompleteChars", 0)),
        auto_seen=max(1, num("Suggest", "AutoCompleteSeen", 5)),
        auto_idle_ms=max(0, num("Suggest", "AutoCompleteIdleMs", 250)),
        auto_only_fragments=get("Suggest", "AutoCompleteOnlyFragments", "true")
        .strip().lower() in ("1", "true", "yes", "on"),
        auto_never=[w.lower() for w in _csv(get("Suggest", "AutoCompleteNever", ""))],
        accept_key=get("Keys", "Accept", "tab").strip().lower(),
        cycle_key=get("Keys", "Cycle", "shift+tab").strip().lower(),
        reword_key=get("Reword", "Key", "ctrl+tab").strip().lower(),
        reword_list_size=max(1, num("Reword", "ListSize", 5)),
        processes=[p.lower() for p in _csv(get("Scope", "Processes", "infloww.exe"))],
        retrain_on_start=get("Model", "RetrainOnStart", "true").strip().lower()
        in ("1", "true", "yes", "on"),
        extra_corpora=_csv(get("Model", "ExtraCorpora", "")),
        strip_offset_x=num("Strip", "OffsetX", 40),
        strip_offset_y=num("Strip", "OffsetY", -90),
        strip_font_size=num("Strip", "FontSize", 11),
        strip_font_name=get("Strip", "FontName", "Segoe UI"),
        strip_bg=get("Strip", "Background", "#202020"),
        strip_fg=get("Strip", "Foreground", "#b0b0b0"),
        strip_hl=get("Strip", "Highlight", "#ffffff"),
    )
