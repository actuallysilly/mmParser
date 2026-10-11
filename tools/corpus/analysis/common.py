"""Shared loading for the corpus analysis passes. Data lives in userdata\\corpus\\."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
CORPUS = MMA_ROOT / "userdata" / "corpus"
MERGED = CORPUS / "merged"
OUT = CORPUS / "analysis"
OUT.mkdir(parents=True, exist_ok=True)

WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
TOKEN_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*|\d+(?:[.,]\d+)*|[<>;:=xX][3DPpO()\[\]/\\|*]+|[^\sA-Za-z\d]+")


@dataclass
class Line:
    day: str
    idx: int
    source: str
    text: str


def unescape(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m[1], m[1]), text)


def load(folder: Path = MERGED) -> list[Line]:
    out = []
    for p in sorted(folder.glob("*.log")):
        for i, raw in enumerate(p.read_text(encoding="utf-8").splitlines()):
            src, _, text = raw.partition("\t")
            out.append(Line(p.stem, i, src, unescape(text)))
    return out


def words(text: str) -> list[str]:
    return WORD_RE.findall(text)


# THE SCRUB. The keystroke logs caught whatever was typed while Infloww was in
# front, which included a password and an email address. Every builder that
# writes a training file drops any row containing an email address or a string
# from the private blocklist (userdata/corpus/scrub.txt, one per line, never
# committed).
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
SCRUB_FILE = CORPUS / "scrub.txt"


def scrub_patterns() -> list[str]:
    if not SCRUB_FILE.exists():
        return []
    return [l.strip().lower() for l in SCRUB_FILE.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")]


def sensitive(text: str, patterns: list[str]) -> bool:
    low = text.lower()
    return bool(EMAIL.search(text)) or any(p in low for p in patterns)
