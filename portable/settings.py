#!/usr/bin/env python3
"""
settings.py — the per-group toggles and preferences, shared by gui.py and mma.py.

Kept OUT of masses.txt on purpose: that file is message content and wants to stay
readable and pasteable. This is machine state, so it lives in settings.json next
to it and is rewritten wholesale.

Mirrors the checkboxes on the Windows panel:
    single   send all parts of a follow-up as ONE message (FuSingle_<m>_<g>)
    edit     paste the combined parts but do NOT press Enter, so you can review
             before sending (SndFuEditable / the wallet-check + editable toggles)

Both are per mass slot and per follow-up group, exactly as on Windows, so model 1
can join its f2 while model 2 does not.
"""

from __future__ import annotations

import json
import os

DEFAULTS = {
    "current": 0,            # which mass slot the send keys use
    "app_filter": "infloww",
    # The gate is a SEPARATE toggle from the filter text, so the value you
    # normally want stays saved while you switch it off to test in a scratch
    # window. Default off: a fresh checkout should work in Notepad.
    "app_filter_enabled": False,
    "wait_time": 0.4,
    "clip_delay": 0.06,
    # keyed "<slot>.<group>" as strings, because JSON has no tuple keys
    "single": {},
    "editable": {},
    # action name -> pynput combo. Empty = fall back to DEFAULT_HOTKEYS.
    "hotkeys": {},
}

MODELS = 3                       # mass slots, one per model — Mass 1/2/3

# Actions bound PER MODEL. Each model gets its own keys, so you send for model 2
# without switching anything first — the same shape as the AHK build's
# [mass.1] / [mass.2] / [mass.3] sections in ../hotkeys.ini.
MODEL_ACTIONS = {
    "fu1":  ("fu", 1),
    "fu2":  ("fu", 2),
    "fu3":  ("fu", 3),
    "mass": ("mass", 0),         # paste that model's mass body, no Enter
}

# Actions that are not tied to a model.
GLOBAL_ACTIONS = {
    "next":   ("next", 0),       # move the GUI's selected slot
    "reload": ("reload", 0),
    "whoami": ("whoami", 0),
}

# Not the F-keys the Windows build uses: AHK owns F1/F2/F3 on Windows and
# consumes the press, and on macOS F1/F2 are brightness. See mma.py.
# Ctrl+digit is safe; Ctrl+letter arrives as a control character on Windows.
DEFAULT_MODEL_HOTKEYS = {
    1: {"fu1": "<ctrl>+1", "fu2": "<ctrl>+2", "fu3": "<ctrl>+3",
        "mass": "<ctrl>+<alt>+1"},
    2: {"fu1": "<ctrl>+4", "fu2": "<ctrl>+5", "fu3": "<ctrl>+6",
        "mass": "<ctrl>+<alt>+2"},
    3: {"fu1": "<ctrl>+7", "fu2": "<ctrl>+8", "fu3": "<ctrl>+9",
        "mass": "<ctrl>+<alt>+3"},
}

DEFAULT_GLOBAL_HOTKEYS = {
    "reload": "<ctrl>+<alt>+r",
    "whoami": "<ctrl>+<alt>+i",
    "next":   "<ctrl>+<alt>+n",
}


def model_key(model: int) -> str:
    """Config section name for a 1-based model number: 1 -> 'mass.1'."""
    return f"mass.{model}"


def path_for(masses_file: str) -> str:
    return os.path.join(os.path.dirname(os.path.abspath(masses_file)), "settings.json")


def load(masses_file: str) -> dict:
    p = path_for(masses_file)
    data = dict(DEFAULTS)
    data["single"] = {}
    data["editable"] = {}
    if not os.path.exists(p):
        return data
    try:
        # utf-8-sig, not utf-8: anything that writes a BOM — Notepad, PowerShell's
        # Set-Content -Encoding UTF8, some editors — otherwise makes json.load
        # raise, and the except below would silently hand back DEFAULTS. Every
        # setting would revert with no error shown anywhere. utf-8-sig strips a
        # BOM when present and is identical to utf-8 when it is not.
        with open(p, encoding="utf-8-sig") as f:
            stored = json.load(f)
    except (OSError, ValueError):
        return data                      # a corrupt settings file must not stop MMA
    for k, v in stored.items():
        if k in DEFAULTS:
            data[k] = v
    for k in ("single", "editable"):
        if not isinstance(data.get(k), dict):
            data[k] = {}
    return data


def save(masses_file: str, data: dict) -> None:
    p = path_for(masses_file)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, p)


def _merge(defaults: dict, stored, allowed) -> dict[str, str]:
    """Overlay stored combos on defaults. Blank UNBINDS, like a blank value in
    the Windows build's hotkeys.ini. Unknown names are ignored rather than
    raising: a typo should cost you one key, not the whole app."""
    out = dict(defaults)
    if isinstance(stored, dict):
        for name, combo in stored.items():
            if name not in allowed or not isinstance(combo, str):
                continue
            if combo.strip():
                out[name] = combo.strip()
            else:
                out.pop(name, None)
    return out


def hotkeys(data: dict) -> dict[str, dict[str, str]]:
    """The whole binding table:

        {"mass.1": {"fu1": "<ctrl>+1", ...}, ..., "global": {"reload": ...}}

    Accepts the OLD flat format too ({"fu1": ..., "mass": ...}) and treats it as
    model 1, so an existing settings.json keeps working instead of silently
    reverting to defaults — which is exactly how a config change goes unnoticed.
    """
    stored = data.get("hotkeys")
    stored = stored if isinstance(stored, dict) else {}

    legacy_flat = {k: v for k, v in stored.items()
                   if k in MODEL_ACTIONS or k in GLOBAL_ACTIONS}

    out: dict[str, dict[str, str]] = {}
    for model in range(1, MODELS + 1):
        section = stored.get(model_key(model))
        if section is None and model == 1 and legacy_flat:
            section = legacy_flat                # migrate old flat config
        out[model_key(model)] = _merge(
            DEFAULT_MODEL_HOTKEYS[model], section, MODEL_ACTIONS)

    global_stored = stored.get("global")
    if global_stored is None and legacy_flat:
        global_stored = legacy_flat
    out["global"] = _merge(DEFAULT_GLOBAL_HOTKEYS, global_stored, GLOBAL_ACTIONS)
    return out


def is_legacy_hotkeys(data: dict) -> bool:
    """True when settings.json still uses the pre-model flat format."""
    stored = data.get("hotkeys")
    if not isinstance(stored, dict) or not stored:
        return False
    return not any(k == "global" or k.startswith("mass.") for k in stored)


def conflicts(table: dict[str, dict[str, str]]) -> dict[str, list[str]]:
    """combo -> the actions fighting over it.

    With three models the collision risk is real, and two actions on one combo
    is silent: pynput keeps only the last binding, so one of them just never
    fires.
    """
    seen: dict[str, list[str]] = {}
    for section, binds in table.items():
        for action, combo in binds.items():
            seen.setdefault(combo, []).append(f"{section}/{action}")
    return {c: who for c, who in seen.items() if len(who) > 1}


def app_filter(data: dict) -> str | None:
    """The window gate, or None when it is switched off.

    Returns None unless BOTH a filter string is set and the toggle is on, so
    'app_filter_enabled': false leaves the keys working everywhere — which is
    what you want while testing outside the chat app.
    """
    if not data.get("app_filter_enabled"):
        return None
    value = data.get("app_filter")
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def key(slot: int, group: int) -> str:
    return f"{slot}.{group}"


def get_flag(data: dict, which: str, slot: int, group: int) -> bool:
    return bool(data.get(which, {}).get(key(slot, group), False))


def set_flag(data: dict, which: str, slot: int, group: int, value: bool) -> None:
    data.setdefault(which, {})[key(slot, group)] = bool(value)
