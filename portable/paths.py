#!/usr/bin/env python3
"""
paths.py — where masses.txt and settings.json live.

Two different answers, and getting it wrong is silent data loss:

RUNNING FROM SOURCE (your machine)
    Next to the .py files, exactly as before. Nothing about the dev workflow
    changes: edit portable/masses.txt and that is the file being used.

FROZEN INTO AN APP (what you hand someone else)
    A per-user data directory. PyInstaller's onefile mode extracts to a TEMP
    directory that it DELETES on exit, so `os.path.dirname(__file__)` there
    points at a folder that will not exist next launch — every mass and every
    setting would silently vanish on quit. onedir is barely better: inside a
    .app bundle those writes break the code signature, and under Program Files
    on Windows they need admin.

    macOS    ~/Library/Application Support/MMA
    Windows  %APPDATA%\\MMA
    other    ~/.config/mma   (XDG-ish; untested, nothing here targets Linux)

First run in frozen mode seeds masses.txt from the example bundled in the app,
so a new user opens the GUI to something rather than an error.
"""

from __future__ import annotations

import os
import shutil
import sys

APP_NAME = "MMA"


def is_frozen() -> bool:
    """True inside a PyInstaller (or similar) bundle."""
    return bool(getattr(sys, "frozen", False))


def bundle_dir() -> str:
    """Read-only directory holding files bundled WITH the app.

    sys._MEIPASS is PyInstaller's extraction dir. Fine to read from, never
    write to — onefile deletes it on exit.
    """
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        return meipass
    return os.path.dirname(os.path.abspath(__file__))


def source_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def data_dir() -> str:
    """Writable directory for the user's own masses and settings."""
    if not is_frozen():
        return source_dir()                      # dev: unchanged behaviour

    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    elif sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")

    path = os.path.join(base, APP_NAME)
    os.makedirs(path, exist_ok=True)
    return path


def masses_file() -> str:
    """The masses file to use, seeded on first run when frozen."""
    path = os.path.join(data_dir(), "masses.txt")
    if not os.path.exists(path) and is_frozen():
        seed = os.path.join(bundle_dir(), "masses.example.txt")
        try:
            if os.path.exists(seed):
                shutil.copyfile(seed, path)
            else:
                open(path, "w", encoding="utf-8").close()
        except OSError:
            pass                                 # a failed seed must not block startup
    return path
