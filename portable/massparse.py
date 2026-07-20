#!/usr/bin/env python3
"""
massparse.py — reads the !mma text format into follow-up parts.

A port of FillTab() in ../mass_gui.ahk, minus the features this build does not
carry (or-or branches, alt variants, b2_*). It accepts the same text the Windows
"Export !mma" button produces, so a mass can be authored anywhere and pasted in.

parse(text) -> Mass:
    mass  the opening message
    fu    {1: [part, ...], 2: [...], 3: [...]}  — dense, blanks removed
    ppv   PpvBlock(base, fus)

Three input modes, tried in this order — same as the Windows original:

  1. PREFIX      every line carries its own label, so blank lines don't matter
                     f1: hey there
                     f1.5 second part of the same follow-up
                     f2: next one

  2. POSITIONAL  blank-line-separated groups, in order f1 -> f2 -> f3. This is
     what "Export !mma" emits and what a pasted mass usually looks like.

  3. Either way the mass body comes from a !mm / !mma / mm / mma line, or —
     failing that — the first non-blank line.

Within a follow-up group the parts map to fuN, fuN_5, fuN_7: up to three messages
sent back to back. `alt:` / `altN:` lines are recognised only so they can be
DROPPED — this build sends the base variant, and letting an alt line fall through
would send it as a real extra message.

No third-party imports: the parser is pure stdlib so it can be tested anywhere.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Schemes that must survive strip_prefix: "https://x" must not lose its "https:".
PREFIX_EXCEPTIONS = {"http", "https", "ftp", "ftps", "mailto", "tel", "file"}

_MASS_PREFIX   = re.compile(r"^!?mma?[\s:]+", re.I)
_MASS_MARKER   = re.compile(r"^!?mma?[\s:]", re.I)
_FAN_RESPONSE  = re.compile(r"^fan\s+response[\s:]", re.I)
_HAS_FPREFIX   = re.compile(r"^fu?\s?\d", re.I)
_FSLOT_DECIMAL = re.compile(r"^fu?\s?(\d+)\.(\d+)[:\s]", re.I)
_FSLOT_PLAIN   = re.compile(r"^fu?\s?(\d+)[:\s]", re.I)
_STRIP_DECIMAL = re.compile(r"^fu?\s?\d+\.\d+[:\s]+", re.I)
_STRIP_PLAIN   = re.compile(r"^fu?\s?\d+[:\s]+", re.I)
_PPV_LABEL     = re.compile(r"^ppv[:\s]+", re.I)
_PPV_SPACED    = re.compile(r"^ppv\s+", re.I)
_PPV_ANY       = re.compile(r"^ppv", re.I)
_ALT_LINE      = re.compile(r"^alt\s*\d*\s*:", re.I)
_SCHEME        = re.compile(r"^([^\s:]+):")
_SCHEME_STRIP  = re.compile(r"^[^\s:]+:\s*")
_SEPARATOR     = re.compile(r"^\s*[=-]{3,}\s*$")


@dataclass
class PpvBlock:
    base: str = ""
    fus: list[str] = field(default_factory=list)


@dataclass
class Mass:
    mass: str = ""
    fu: dict[int, list[str]] = field(default_factory=lambda: {1: [], 2: [], 3: []})
    ppv: PpvBlock = field(default_factory=PpvBlock)
    name: str = ""


def f_prefix_slot(line: str) -> tuple[int, int] | None:
    """'f1' / 'fu1' / 'f 1' / 'f1.5:' -> (group, part).

    Mirrors FPrefixToSlot: only .5 and .7 are real sub-slots, so f1.3 is not a
    slot at all rather than being rounded to one.
    """
    m = _FSLOT_DECIMAL.match(line)
    if m:
        head = m.group(2)[:1]
        if head == "5":
            return int(m.group(1)), 2
        if head == "7":
            return int(m.group(1)), 3
        return None
    m = _FSLOT_PLAIN.match(line)
    if m:
        return int(m.group(1)), 1
    return None


def strip_prefix(line: str) -> str:
    """Drop a leading 'f1:' / 'fu2.5 ' label, or a bare 'word:' tag."""
    for pat in (_STRIP_DECIMAL, _STRIP_PLAIN):
        m = pat.match(line)
        if m:
            return line[m.end():]

    # A generic "scheme:" prefix, unless it is a URL or the colon opens a bracket
    # (an emoticon like ":(" must not be read as a label).
    m = _SCHEME.match(line)
    if m:
        scheme = m.group(1)
        nxt = line[len(scheme) + 1: len(scheme) + 2]
        if nxt not in ("(", ")") and scheme.lower() not in PREFIX_EXCEPTIONS:
            sm = _SCHEME_STRIP.match(line)
            if sm:
                return line[sm.end():]
    return line


def is_alt_line(line: str) -> bool:
    return _ALT_LINE.match(line) is not None


def _compact(slots: dict[int, str]) -> list[str]:
    """Parts land in fixed slots (1, 2, 3) but a mass may fill only 1 and 3.
    Collapse to a dense list so the sender can just walk it."""
    out = []
    for i in (1, 2, 3):
        v = slots.get(i)
        if v and v.strip():
            out.append(v.strip())
    return out


def parse(text: str | None) -> Mass:
    raw = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    lines = raw.split("\n")

    result = Mass()
    slots: dict[int, dict[int, str]] = {1: {}, 2: {}, 3: {}}
    ppv_slots: dict[int, str] = {}

    # ── the mass body ────────────────────────────────────────────────────────
    mass_found = False
    for line in lines:
        t = line.strip()
        m = _MASS_PREFIX.match(t)
        if m:
            result.mass = t[m.end():].strip()
            mass_found = True
            break

    # Drop the mass marker and the "Fan Response AI" header some pastes carry.
    filtered = [
        line.strip() for line in lines
        if not (_MASS_MARKER.match(line.strip()) or _FAN_RESPONSE.match(line.strip()))
    ]

    if not mass_found:
        for i, t in enumerate(filtered):
            if t:
                result.mass = t
                del filtered[i]
                # and the blank line that followed it, so group boundaries hold
                if i < len(filtered) and filtered[i] == "":
                    del filtered[i]
                break

    # ── mode 1: explicit f-prefixes ──────────────────────────────────────────
    if any(t and _HAS_FPREFIX.match(t) for t in filtered):
        for t in filtered:
            if not t or is_alt_line(t):
                continue
            m = _PPV_LABEL.match(t)
            if m:
                v = t[m.end():].strip()
                if v:
                    result.ppv.base = v
                continue
            slot = f_prefix_slot(t)
            if slot and slot[0] in slots:
                slots[slot[0]][slot[1]] = strip_prefix(t)
        for i in (1, 2, 3):
            result.fu[i] = _compact(slots[i])
        result.ppv.fus = _compact(ppv_slots)
        return result

    # ── mode 2: positional, blank-line separated ─────────────────────────────
    groups: list[list[str]] = []
    cur: list[str] = []
    for t in filtered:
        if t == "":
            if cur:
                groups.append(cur)
                cur = []
        else:
            cur.append(t)
    if cur:
        groups.append(cur)

    f_idx = 0
    skip_idx = -1
    for gi, grp in enumerate(groups):
        if gi == skip_idx:
            continue
        if _PPV_ANY.match(grp[0]):
            # The ppv block is its own base text, and the group AFTER it holds
            # that ppv's follow-ups — which is why the next group is skipped.
            parts = []
            m = _PPV_SPACED.match(grp[0])
            if m:
                v = grp[0][m.end():].strip()
                if v:
                    parts.append(v)
            parts.extend(strip_prefix(l) for l in grp[1:] if not is_alt_line(l))
            result.ppv.base = "\n".join(parts)
            if gi + 1 < len(groups):
                skip_idx = gi + 1
                si = 0
                for l in groups[gi + 1]:
                    if not is_alt_line(l) and si < 3:
                        si += 1
                        ppv_slots[si] = strip_prefix(l)
        else:
            f_idx += 1
            if f_idx <= 3:
                si = 0
                for l in grp:
                    if not is_alt_line(l) and si < 3:
                        si += 1
                        slots[f_idx][si] = strip_prefix(l)

    for i in (1, 2, 3):
        result.fu[i] = _compact(slots[i])
    result.ppv.fus = _compact(ppv_slots)
    return result


#: part index -> the label to write it under, per follow-up group
_PART_LABELS = {0: "f{g}:", 1: "f{g}.5:", 2: "f{g}.7:"}


def to_text(m: Mass, with_name: bool = True) -> str:
    """Serialise a Mass back to text the parser reads identically.

    Emits the LABELLED form ("f1:", "f1.5:") rather than the positional one the
    Windows Export button uses. Positional cannot represent a gap: a mass with
    an empty f1 but a filled f2 writes two blank-separated groups that read back
    as f1, shifting everything up a slot. Labels round-trip exactly, and the
    parser accepts both, so only what the GUI *writes* is affected.

    Known limitation: a multi-line ppv base is flattened to one line, because in
    labelled mode each 'ppv' line overwrites the previous (bug-compatible with
    mass_gui.ahk). Nothing in this build sends ppv, so it is carried, not used.
    """
    lines: list[str] = []
    if with_name and m.name:
        lines.append(f"# {m.name}")
    if m.mass:
        lines.append(f"!mma {m.mass}")
    for g in (1, 2, 3):
        for i, part in enumerate(m.fu.get(g, [])[:3]):
            lines.append(_PART_LABELS[i].format(g=g) + " " + part)
    if m.ppv.base:
        lines.append("ppv: " + m.ppv.base.replace("\n", " / "))
    return "\n".join(lines)


def file_to_text(masses: list[Mass]) -> str:
    """Serialise a whole library back to a masses.txt."""
    return "\n\n===\n\n".join(to_text(m) for m in masses) + "\n"


def split_header(chunk: str) -> tuple[str | None, str]:
    """Peel the leading comment block off a chunk: returns (label, body).

    Comments are recognised ONLY at the top of a chunk, never mid-body. A message
    may legitimately start with a hashtag ("#ad", "#linkinbio"), and treating "#"
    as a comment everywhere would swallow that line instead of sending it.
    """
    name = None
    lines = chunk.split("\n")
    i = 0
    while i < len(lines):
        t = lines[i].strip()
        if t.startswith("#"):
            if name is None:
                name = t[1:].strip()
            i += 1
        elif t == "":
            i += 1
        else:
            break
    return (name or None), "\n".join(lines[i:])


def parse_file(text: str | None) -> list[Mass]:
    """Several masses in one file, separated by a line of === or ---.

    A leading '# name' comment names the slot; without one the mass body's first
    30 characters stand in, so the on-screen indicator always says something.
    """
    raw = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    chunks: list[list[str]] = [[]]
    for line in raw.split("\n"):
        if _SEPARATOR.match(line):
            chunks.append([])
        else:
            chunks[-1].append(line)

    masses: list[Mass] = []
    for chunk in chunks:
        name, body = split_header("\n".join(chunk))
        if not body.strip():
            continue
        m = parse(body)
        m.name = name or (m.mass[:30] if m.mass else f"mass {len(masses) + 1}")
        masses.append(m)
    return masses
