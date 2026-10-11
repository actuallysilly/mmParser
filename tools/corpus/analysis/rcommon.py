"""Loading the rule-repaired corpus (userdata/corpus/repaired/rules_v1.tsv)."""
from __future__ import annotations

import re
from dataclasses import dataclass

from common import CORPUS, OUT, unescape  # noqa: F401

TOK = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*|\d+|<3+|>\.<|[;:]3|[:;]\(|[:;]\)|xD|[!?.]+|[^\sA-Za-z\d]")


@dataclass
class Msg:
    day: str
    idx: int
    source: str
    dirty: bool
    text: str


def load_repaired() -> list[Msg]:
    out = []
    for line in (CORPUS / "repaired" / "rules_v1.tsv").read_text(encoding="utf-8").splitlines():
        day, idx, src, d, text = line.split("\t", 4)
        out.append(Msg(day, int(idx), src, d == "1", unescape(text)))
    return out


def toks(text: str) -> list[str]:
    """Lowercased word tokens, emoticons and punctuation kept as tokens."""
    return [t.lower() for t in TOK.findall(text)]


def wtoks(text: str) -> list[str]:
    return [t.lower() for t in re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)*", text)]
