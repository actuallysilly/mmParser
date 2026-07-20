#!/usr/bin/env python3
"""
app.py — one process: the panel and the hotkey listener together.

From source you can keep running gui.py and mma.py separately; this exists
because a packaged app cannot ask someone to open a terminal and start two
things. Double-clicking MMA.app has to be the whole story.

The listener runs on pynput's own thread, the GUI owns the main thread, and
they coordinate through settings.json exactly as the two-process setup does —
no new interface between them.

    python app.py
"""

from __future__ import annotations

import sys
import threading
import tkinter as tk
from tkinter import messagebox

import gui
import mma
import paths
import settings

# Emoji in masses would otherwise raise UnicodeEncodeError on a Windows console.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


PERMISSION_HELP = (
    "MMA could not start listening for keys.\n\n"
    "On macOS this is almost always a missing permission. Open\n"
    "System Settings → Privacy & Security and switch MMA on under BOTH:\n\n"
    "    • Input Monitoring   (to notice your keys)\n"
    "    • Accessibility      (to type for you)\n\n"
    "Then QUIT MMA COMPLETELY and open it again — macOS only hands a\n"
    "permission to an app when it starts, so the running copy still has none.\n\n"
    "See docs/install-macos.html for the full walkthrough."
)


class Listener:
    """Owns the engine and the global hotkeys for the life of the window."""

    def __init__(self, status):
        self.status = status
        self.engine = None
        self.hotkeys = None
        self._stop = threading.Event()

    def start(self) -> str:
        try:
            from pynput import keyboard
        except ImportError:
            return "pynput is not installed — hotkeys are off"

        self.engine = mma.Engine(mma.RealBackend(), masses_file=paths.masses_file())
        self.engine.load(quiet=True)

        table = settings.hotkeys(self.engine.settings)
        bindings = {}
        for section, binds in table.items():
            is_global = section == "global"
            model = None if is_global else int(section.split(".")[1]) - 1
            catalogue = (settings.GLOBAL_ACTIONS if is_global
                         else settings.MODEL_ACTIONS)
            for name, combo in binds.items():
                action, arg = catalogue[name]
                try:
                    keyboard.HotKey.parse(combo)
                except ValueError:
                    continue          # reported in the panel, not fatal
                bindings[combo] = (
                    lambda a=action, g=arg, m=model:
                    self.engine.dispatch(a, g, m))

        if not bindings:
            return "no usable hotkeys — check Settings"

        try:
            self.hotkeys = keyboard.GlobalHotKeys(bindings)
            self.hotkeys.start()
        except Exception as e:
            # macOS raises here when Input Monitoring was never granted. Saying
            # so beats the app sitting there looking fine and doing nothing.
            return f"cannot listen for keys: {e}"

        threading.Thread(target=self._watch, daemon=True).start()
        n = settings.conflicts(table)
        warn = f"  •  {len(n)} duplicate key(s)" if n else ""
        return f"listening — {len(bindings)} hotkeys{warn}"

    def _watch(self):
        while not self._stop.wait(mma.RELOAD_POLL):
            try:
                self.engine.reload_if_changed()
            except Exception:
                pass              # a bad edit must not kill the watcher

    def stop(self):
        self._stop.set()
        if self.hotkeys is not None:
            try:
                self.hotkeys.stop()
            except Exception:
                pass


def main(argv=None) -> int:
    root = tk.Tk()
    app = gui.App(root, paths.masses_file())
    root.title("MMA")

    listener = Listener(app.status)
    message = listener.start()
    app._set_status(message)

    if message.startswith("cannot listen") or message.startswith("no usable"):
        # Non-fatal: the panel still edits masses. But say why the keys are dead
        # rather than leaving the user to discover it mid-conversation.
        root.after(200, lambda: messagebox.showwarning("MMA — hotkeys are off",
                                                       f"{message}\n\n{PERMISSION_HELP}"))

    close = root.protocol("WM_DELETE_WINDOW")

    def on_close():
        listener.stop()
        app._on_close()

    root.protocol("WM_DELETE_WINDOW", on_close)
    try:
        root.mainloop()
    finally:
        listener.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
