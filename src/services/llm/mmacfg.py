"""
llm/mmacfg.py — read MMA's settings (userdata/mass_gui.cfg) from Python.

    feat("FanRecorder")                 a Settings ▸ Features switch (FEAT_Def in modes.ahk)
    setting("FanData", "Root", "D:\\FanData")   any value

Re-read only when the file changes. Was shiftlog.feat/setting; moved here
(2026-11-24) so nothing has to import the shift recorder to read a setting.
"""
from __future__ import annotations

import configparser
from pathlib import Path

MMA_ROOT = Path(__file__).resolve().parents[3]
MMA_CFG = MMA_ROOT / "userdata" / "mass_gui.cfg"
_cfg = {"mtime": None, "cp": None}


def setting(section: str, key: str, default: str = "") -> str:
    try:
        m = MMA_CFG.stat().st_mtime
    except OSError:
        return default
    if m != _cfg["mtime"]:
        cp = configparser.ConfigParser(interpolation=None, strict=False)
        for enc in ("utf-16", "utf-8-sig"):      # AHK writes UTF-16; be lenient
            try:
                cp.read(MMA_CFG, encoding=enc)
                break
            except (UnicodeError, configparser.Error):
                cp = configparser.ConfigParser(interpolation=None, strict=False)
        _cfg.update(mtime=m, cp=cp)
    return _cfg["cp"].get(section, key, fallback=default).strip()


def feat(key: str, default: str = "1") -> bool:
    """A MMA feature switch."""
    return setting("Settings", key, default) == "1"
