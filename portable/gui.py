#!/usr/bin/env python3
"""
gui.py — the MMA panel, laid out like the original.

    python gui.py

A close copy of the classic mass_gui.ahk panel: mass tabs down the left with
!mm / f1 / f1.5 / f1.7 / f2 … / ppv fields, single+edit checkboxes beside each
follow-up group, and the paste block with Parse / Clear / Export !mma on the
right, plus the massNo selector.

Scope is the BASE panel only — the 1.4-era additions (Settings, Add Hotkey,
Hotstrings, Pinger, Alt FUs, archive, or-or branching, OCR) are not here, and
neither is the "apply to <script>.ahk" plumbing: this build's fields live in
masses.txt, read by mma.py.

Tkinter, so it needs no dependency at all. Default (light) theme, to match the
original rather than the dark tools.
"""

from __future__ import annotations

import os
import shutil
import sys
import tkinter as tk
from tkinter import messagebox, ttk

import massparse
import paths
import settings as settings_mod

# Masses contain emoji, and a Windows console defaults to the locale codepage
# where printing one raises UnicodeEncodeError. Nothing here prints normally,
# but a traceback carrying message text would otherwise die on the way out.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

MASSES_FILE = paths.masses_file()          # see paths.py — differs when frozen

MIN_TABS = settings_mod.MODELS      # one tab per model — Mass 1/2/3
PART_SUFFIX = ["", ".5", ".7"]


# ── settings editor ──────────────────────────────────────────────────────────

class SettingsWindow:
    """Edit hotkeys (per model), the safety gate and the timing.

    Hotkeys are per model, matching the AHK build's [mass.1]/[mass.2]/[mass.3]
    sections: each model has its own keys, so you send for model 2 without
    selecting it first.
    """

    ROWS = [("fu1", "follow-up 1"), ("fu2", "follow-up 2"),
            ("fu3", "follow-up 3"), ("mass", "paste mass body")]
    GLOBAL_ROWS = [("reload", "reload masses"), ("whoami", "which window"),
                   ("next", "next slot")]

    def __init__(self, parent: tk.Misc, app: "App"):
        self.app = app
        self.cfg = app.cfg
        self.win = tk.Toplevel(parent)
        self.win.title("MMA settings")
        self.win.transient(parent)
        self.win.grab_set()
        self.win.resizable(False, False)

        table = settings_mod.hotkeys(self.cfg)
        self.entries: dict[tuple[str, str], ttk.Entry] = {}

        frame = ttk.Frame(self.win, padding=12)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Hotkeys — one set per model",
                  font=("Segoe UI", 10, "bold")).grid(
                      row=0, column=0, columnspan=4, sticky="w", pady=(0, 2))
        ttk.Label(frame,
                  text="pynput syntax:  <ctrl>+1   <ctrl>+<alt>+m   <f9>   "
                       "•  blank = unbound",
                  foreground="#666666").grid(row=1, column=0, columnspan=4,
                                             sticky="w", pady=(0, 8))

        for col, model in enumerate(range(1, settings_mod.MODELS + 1), start=1):
            name = self.app.masses[model - 1].name if model - 1 < len(self.app.masses) else ""
            ttk.Label(frame, text=f"M{model}", font=("Segoe UI", 9, "bold")).grid(
                row=2, column=col, pady=(0, 0))
            ttk.Label(frame, text=(name or "")[:18], foreground="#888888").grid(
                row=3, column=col, pady=(0, 4))

        section_of = {m: settings_mod.model_key(m)
                      for m in range(1, settings_mod.MODELS + 1)}
        for r, (action, label) in enumerate(self.ROWS, start=4):
            ttk.Label(frame, text=label).grid(row=r, column=0, sticky="e",
                                              padx=(0, 8), pady=2)
            for col, model in enumerate(range(1, settings_mod.MODELS + 1), start=1):
                sec = section_of[model]
                e = ttk.Entry(frame, width=18)
                e.insert(0, table[sec].get(action, ""))
                e.grid(row=r, column=col, padx=2, pady=2)
                self.entries[(sec, action)] = e

        base = 4 + len(self.ROWS)
        ttk.Separator(frame, orient="horizontal").grid(
            row=base, column=0, columnspan=4, sticky="ew", pady=10)
        ttk.Label(frame, text="Global keys", font=("Segoe UI", 9, "bold")).grid(
            row=base + 1, column=0, columnspan=4, sticky="w")
        for i, (action, label) in enumerate(self.GLOBAL_ROWS):
            ttk.Label(frame, text=label).grid(row=base + 2 + i, column=0,
                                              sticky="e", padx=(0, 8), pady=2)
            e = ttk.Entry(frame, width=18)
            e.insert(0, table["global"].get(action, ""))
            e.grid(row=base + 2 + i, column=1, padx=2, pady=2)
            self.entries[("global", action)] = e

        base2 = base + 2 + len(self.GLOBAL_ROWS)
        ttk.Separator(frame, orient="horizontal").grid(
            row=base2, column=0, columnspan=4, sticky="ew", pady=10)

        ttk.Label(frame, text="Safety gate",
                  font=("Segoe UI", 9, "bold")).grid(row=base2 + 1, column=0,
                                                     columnspan=4, sticky="w")
        self.filter_on = tk.BooleanVar(value=bool(self.cfg.get("app_filter_enabled")))
        ttk.Checkbutton(frame, text="only send in the matching app",
                        variable=self.filter_on).grid(row=base2 + 2, column=0,
                                                      columnspan=2, sticky="w")
        ttk.Label(frame, text="match:").grid(row=base2 + 3, column=0, sticky="e",
                                             padx=(0, 8))
        self.e_filter = ttk.Entry(frame, width=28)
        self.e_filter.insert(0, self.cfg.get("app_filter") or "")
        self.e_filter.grid(row=base2 + 3, column=1, columnspan=2, sticky="w", pady=2)

        ttk.Label(frame, text="Timing", font=("Segoe UI", 9, "bold")).grid(
            row=base2 + 4, column=0, columnspan=4, sticky="w", pady=(10, 0))
        ttk.Label(frame, text="wait between messages (s):").grid(
            row=base2 + 5, column=0, sticky="e", padx=(0, 8))
        self.e_wait = ttk.Entry(frame, width=10)
        self.e_wait.insert(0, str(self.cfg.get("wait_time", 0.4)))
        self.e_wait.grid(row=base2 + 5, column=1, sticky="w", pady=2)
        ttk.Label(frame, text="clipboard settle (s):").grid(
            row=base2 + 6, column=0, sticky="e", padx=(0, 8))
        self.e_clip = ttk.Entry(frame, width=10)
        self.e_clip.insert(0, str(self.cfg.get("clip_delay", 0.06)))
        self.e_clip.grid(row=base2 + 6, column=1, sticky="w", pady=2)

        self.msg = ttk.Label(frame, text="", foreground="#a00000", wraplength=420)
        self.msg.grid(row=base2 + 7, column=0, columnspan=4, sticky="w", pady=(10, 0))

        bar = ttk.Frame(frame)
        bar.grid(row=base2 + 8, column=0, columnspan=4, sticky="e", pady=(10, 0))
        ttk.Button(bar, text="Restore defaults", command=self._defaults).pack(side="left")
        ttk.Button(bar, text="Cancel", command=self.win.destroy).pack(side="left", padx=6)
        ttk.Button(bar, text="Save", command=self._save).pack(side="left")

    # ── helpers ──────────────────────────────────────────────────────────────

    def _collect(self) -> dict[str, dict[str, str]]:
        out: dict[str, dict[str, str]] = {}
        for (section, action), entry in self.entries.items():
            out.setdefault(section, {})[action] = entry.get().strip()
        return out

    def _defaults(self) -> None:
        for model in range(1, settings_mod.MODELS + 1):
            sec = settings_mod.model_key(model)
            for action, combo in settings_mod.DEFAULT_MODEL_HOTKEYS[model].items():
                e = self.entries.get((sec, action))
                if e is not None:
                    e.delete(0, "end"); e.insert(0, combo)
        for action, combo in settings_mod.DEFAULT_GLOBAL_HOTKEYS.items():
            e = self.entries.get(("global", action))
            if e is not None:
                e.delete(0, "end"); e.insert(0, combo)
        self.msg.configure(text="defaults restored — not saved yet",
                           foreground="#666666")

    def _problems(self, table: dict[str, dict[str, str]]) -> list[str]:
        """Validate BEFORE writing. A bad combo would otherwise be found only at
        the next mma.py start, by which point the GUI has long since closed."""
        problems = []
        try:
            from pynput import keyboard
        except ImportError:
            keyboard = None
        if keyboard is not None:
            for section, binds in table.items():
                for action, combo in binds.items():
                    if not combo:
                        continue
                    try:
                        keyboard.HotKey.parse(combo)
                    except ValueError:
                        problems.append(f"{section}/{action}: {combo!r} is not "
                                        "valid pynput syntax")
        live = {s: {a: c for a, c in b.items() if c} for s, b in table.items()}
        for combo, who in settings_mod.conflicts(live).items():
            problems.append(f"{combo} is bound twice ({', '.join(who)}) — "
                            "only one would ever fire")
        return problems

    def _save(self) -> None:
        table = self._collect()
        problems = self._problems(table)
        if problems:
            self.msg.configure(text="  •  ".join(problems[:3]), foreground="#a00000")
            return
        try:
            wait = float(self.e_wait.get())
            clip = float(self.e_clip.get())
        except ValueError:
            self.msg.configure(text="timing values must be numbers",
                               foreground="#a00000")
            return

        self.cfg["hotkeys"] = table
        self.cfg["app_filter_enabled"] = self.filter_on.get()
        self.cfg["app_filter"] = self.e_filter.get().strip() or None
        self.cfg["wait_time"] = wait
        self.cfg["clip_delay"] = clip
        try:
            settings_mod.save(self.app.path, self.cfg)
        except OSError as e:
            messagebox.showerror("Settings", str(e))
            return
        self.app._sync_gate_widgets()
        self.app._set_status("settings saved — restart mma.py to apply hotkeys")
        messagebox.showinfo(
            "Saved",
            "Settings written.\n\nThe gate and timing apply within a second.\n"
            "HOTKEY changes need mma.py restarted — pynput binds them once at "
            "startup.")
        self.win.destroy()


# ── file handling (pure, so it is testable without a display) ────────────────

def load_library(path: str) -> list[massparse.Mass]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return massparse.parse_file(f.read())


def save_library(masses: list[massparse.Mass], path: str) -> None:
    """Write the library, keeping one generation of backup.

    The .bak matters because Save rewrites the whole file from parsed objects:
    if anything about the round-trip were wrong, this is where a day's masses
    would quietly change shape.
    """
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(massparse.file_to_text(masses))
    os.replace(tmp, path)                 # atomic; never a half-written library


def blank_mass(n: int) -> massparse.Mass:
    return massparse.Mass(mass="", fu={1: [], 2: [], 3: []}, name=f"Mass {n}")


def pad_to(masses: list[massparse.Mass], n: int) -> list[massparse.Mass]:
    """The panel always shows at least MIN_TABS slots, like the original.

    Never truncates: a file with more masses than tabs keeps all of them, or
    Save would silently drop the extras.
    """
    out = list(masses)
    while len(out) < n:
        out.append(blank_mass(len(out) + 1))
    return out


# ── one tab ──────────────────────────────────────────────────────────────────

class MassTab:
    """The field column for a single mass slot."""

    def __init__(self, parent: tk.Widget, app: "App", slot: int):
        self.app = app
        self.slot = slot
        self.frame = ttk.Frame(parent, padding=(6, 8))
        self.frame.columnconfigure(2, weight=1)

        self.single: dict[int, tk.BooleanVar] = {}
        self.editable: dict[int, tk.BooleanVar] = {}
        self.parts: dict[int, list[ttk.Entry]] = {1: [], 2: [], 3: []}

        r = 0
        self.e_mass = self._field(r, "!mm:")
        r += 1

        for g in (1, 2, 3):
            r += 1                                     # blank line between groups
            self.single[g] = tk.BooleanVar(value=False)
            self.editable[g] = tk.BooleanVar(value=False)
            # the two checkboxes sit against the first two rows of the group,
            # exactly as on the original panel
            ttk.Checkbutton(self.frame, text="single", variable=self.single[g],
                            command=self.app._on_flag).grid(row=r, column=0, sticky="w")
            ttk.Checkbutton(self.frame, text="edit", variable=self.editable[g],
                            command=self.app._on_flag).grid(row=r + 1, column=0, sticky="w")
            for i, suffix in enumerate(PART_SUFFIX):
                self.parts[g].append(self._field(r + i, f"f{g}{suffix}:"))
            r += 3

        r += 1
        ttk.Label(self.frame, text="ppv:").grid(row=r, column=1, sticky="ne", padx=(0, 6))
        self.t_ppv = tk.Text(self.frame, height=5, wrap="word",
                             font=("Segoe UI", 9), relief="sunken", borderwidth=1)
        self.t_ppv.grid(row=r, column=2, sticky="ew", pady=1)
        self.t_ppv.bind("<KeyRelease>", self.app._on_edit)
        r += 1

        self.ppv_fus = [self._field(r + i, f"ppvfu{i + 1}:") for i in range(3)]

    def _field(self, row: int, label: str) -> ttk.Entry:
        ttk.Label(self.frame, text=label).grid(row=row, column=1, sticky="e", padx=(0, 6))
        e = ttk.Entry(self.frame)
        e.grid(row=row, column=2, sticky="ew", pady=1)
        e.bind("<KeyRelease>", self.app._on_edit)
        return e

    # ── data <-> widgets ─────────────────────────────────────────────────────

    def load(self, m: massparse.Mass, cfg: dict) -> None:
        self._set(self.e_mass, m.mass)
        for g in (1, 2, 3):
            parts = m.fu.get(g, [])
            for i, entry in enumerate(self.parts[g]):
                self._set(entry, parts[i] if i < len(parts) else "")
            self.single[g].set(settings_mod.get_flag(cfg, "single", self.slot, g))
            self.editable[g].set(settings_mod.get_flag(cfg, "editable", self.slot, g))
        self.t_ppv.delete("1.0", "end")
        if m.ppv.base:
            self.t_ppv.insert("1.0", m.ppv.base)
        for i, entry in enumerate(self.ppv_fus):
            self._set(entry, m.ppv.fus[i] if i < len(m.ppv.fus) else "")

    def collect(self, name: str) -> massparse.Mass:
        fu = {}
        for g in (1, 2, 3):
            # Blanks are dropped rather than kept as empty strings — filling only
            # f1.7 must yield one message, not two empty ones then the real one.
            # sndFu() in ../utils.ahk does exactly the same at send time.
            fu[g] = [e.get().strip() for e in self.parts[g] if e.get().strip()]
        ppv = massparse.PpvBlock(
            base=self.t_ppv.get("1.0", "end").strip(),
            fus=[e.get().strip() for e in self.ppv_fus if e.get().strip()],
        )
        return massparse.Mass(mass=self.e_mass.get().strip(), fu=fu, ppv=ppv, name=name)

    def write_flags(self, cfg: dict) -> None:
        for g in (1, 2, 3):
            settings_mod.set_flag(cfg, "single", self.slot, g, self.single[g].get())
            settings_mod.set_flag(cfg, "editable", self.slot, g, self.editable[g].get())

    @staticmethod
    def _set(entry: ttk.Entry, value: str) -> None:
        entry.delete(0, "end")
        entry.insert(0, value)


# ── the window ───────────────────────────────────────────────────────────────

class App:
    def __init__(self, root: tk.Tk, path: str = MASSES_FILE):
        self.root = root
        self.path = path
        self.cfg = settings_mod.load(path)
        self.masses = pad_to(load_library(path), MIN_TABS)
        self.dirty = False

        root.title("MMA")
        root.geometry("1180x720")
        root.minsize(980, 620)
        root.columnconfigure(0, weight=3)
        root.columnconfigure(1, weight=2)
        root.rowconfigure(0, weight=1)

        self._build_left()
        self._build_right()
        self._build_footer()
        self._load_all()

    # ── construction ─────────────────────────────────────────────────────────

    def _build_left(self) -> None:
        self.notebook = ttk.Notebook(self.root)
        self.notebook.grid(row=0, column=0, sticky="nsew", padx=(8, 4), pady=(8, 0))
        self.tabs: list[MassTab] = []
        for i in range(len(self.masses)):
            tab = MassTab(self.notebook, self, i)
            self.notebook.add(tab.frame, text=f"Mass {i + 1}")
            self.tabs.append(tab)

    def _build_right(self) -> None:
        right = ttk.Frame(self.root, padding=(4, 8))
        right.grid(row=0, column=1, sticky="nsew", padx=(4, 8), pady=(8, 0))
        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)

        head = ttk.Frame(right)
        head.grid(row=0, column=0, sticky="ew")
        ttk.Label(head, text="Paste block:").pack(side="left")
        ttk.Label(head, text="   (blank = group sep  •  ppv = ppv section)",
                  foreground="#666666").pack(side="left")

        self.paste = tk.Text(right, wrap="word", font=("Segoe UI", 9),
                             relief="sunken", borderwidth=1)
        self.paste.grid(row=1, column=0, sticky="nsew", pady=(4, 6))

        bar = ttk.Frame(right)
        bar.grid(row=2, column=0, sticky="ew")
        ttk.Button(bar, text="Parse", width=12, command=self._on_parse).pack(side="left")
        ttk.Button(bar, text="Clear", width=12, command=self._on_clear).pack(side="left", padx=4)
        ttk.Button(bar, text="Export !mma", width=14,
                   command=self._on_export).pack(side="left")

        ttk.Separator(right, orient="horizontal").grid(row=3, column=0, sticky="ew", pady=10)

        ttk.Label(right, text="-- Apply to file --",
                  foreground="#666666").grid(row=4, column=0, sticky="w")
        ttk.Button(right, text="Save masses.txt",
                   command=self._on_save).grid(row=5, column=0, sticky="ew", pady=(2, 8))
        ttk.Button(right, text="Reload from disk",
                   command=self._on_reload).grid(row=6, column=0, sticky="ew")

        ttk.Separator(right, orient="horizontal").grid(row=7, column=0, sticky="ew", pady=10)

        ttk.Label(right, text="-- Set massNo --",
                  foreground="#666666").grid(row=8, column=0, sticky="w")
        picker = ttk.Frame(right)
        picker.grid(row=9, column=0, sticky="w", pady=(2, 0))
        ttk.Label(picker, text="active:").pack(side="left", padx=(0, 6))
        self.massno = tk.IntVar(value=int(self.cfg.get("current", 0)) + 1)
        self.radios: list[ttk.Radiobutton] = []
        for i in range(len(self.masses)):
            rb = ttk.Radiobutton(picker, text=str(i + 1), value=i + 1,
                                 variable=self.massno, command=self._on_massno)
            rb.pack(side="left")
            self.radios.append(rb)
        ttk.Label(right, text="the slot the send keys use",
                  foreground="#888888").grid(row=10, column=0, sticky="w")

        ttk.Separator(right, orient="horizontal").grid(row=11, column=0, sticky="ew", pady=10)

        ttk.Label(right, text="-- Safety gate --",
                  foreground="#666666").grid(row=12, column=0, sticky="w")
        self.filter_on = tk.BooleanVar(value=bool(self.cfg.get("app_filter_enabled")))
        ttk.Checkbutton(right, text="only send in the matching app",
                        variable=self.filter_on,
                        command=self._on_filter).grid(row=13, column=0, sticky="w")
        fr = ttk.Frame(right)
        fr.grid(row=14, column=0, sticky="ew", pady=(2, 0))
        fr.columnconfigure(1, weight=1)
        ttk.Label(fr, text="match:").grid(row=0, column=0, padx=(0, 6))
        self.e_filter = ttk.Entry(fr)
        self.e_filter.insert(0, self.cfg.get("app_filter") or "")
        self.e_filter.grid(row=0, column=1, sticky="ew")
        self.e_filter.bind("<FocusOut>", self._on_filter)
        self.e_filter.bind("<Return>", self._on_filter)
        ttk.Label(right, text="off = keys fire anywhere, for testing",
                  foreground="#888888").grid(row=15, column=0, sticky="w")

        ttk.Separator(right, orient="horizontal").grid(row=16, column=0,
                                                       sticky="ew", pady=10)
        ttk.Button(right, text="Settings / Hotkeys…",
                   command=self._on_settings).grid(row=17, column=0, sticky="ew")
        ttk.Label(right, text="each model has its own send keys",
                  foreground="#888888").grid(row=18, column=0, sticky="w")

    def _build_footer(self) -> None:
        foot = ttk.Frame(self.root, padding=(8, 6))
        foot.grid(row=1, column=0, columnspan=2, sticky="ew")
        self.status = ttk.Label(foot, text="")
        self.status.pack(side="left")
        ttk.Label(foot, text=os.path.basename(self.path),
                  foreground="#888888").pack(side="right")
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ── state ────────────────────────────────────────────────────────────────

    def _tab(self) -> MassTab:
        return self.tabs[self.notebook.index("current")]

    def _load_all(self) -> None:
        for i, tab in enumerate(self.tabs):
            tab.load(self.masses[i], self.cfg)
        self._set_status()

    def _commit_all(self) -> None:
        """Fold every tab's visible state back into the library and settings."""
        for i, tab in enumerate(self.tabs):
            self.masses[i] = tab.collect(self.masses[i].name or f"Mass {i + 1}")
            tab.write_flags(self.cfg)
        self.cfg["current"] = self.massno.get() - 1
        # Also fold in the gate, so a filter typed but not yet blurred is not
        # silently dropped by Save.
        self.cfg["app_filter_enabled"] = self.filter_on.get()
        self.cfg["app_filter"] = self.e_filter.get().strip() or None

    def _set_status(self, msg: str = "") -> None:
        n = sum(1 for m in self.masses if m.mass or any(m.fu[g] for g in (1, 2, 3)))
        mark = "   •   unsaved changes" if self.dirty else ""
        self.status.configure(text=(msg or f"{n} mass(es) with content") + mark)

    # ── events ───────────────────────────────────────────────────────────────

    def _on_edit(self, _event=None) -> None:
        self.dirty = True
        self._set_status()

    def _on_flag(self) -> None:
        """single/edit are machine state, so they save immediately — the engine
        picks them up on its next poll without a masses.txt write."""
        self._tab().write_flags(self.cfg)
        try:
            settings_mod.save(self.path, self.cfg)
        except OSError as e:
            messagebox.showerror("Settings", str(e))
            return
        self._set_status("toggles saved")

    def _on_settings(self) -> None:
        SettingsWindow(self.root, self)

    def _sync_gate_widgets(self) -> None:
        """Pull the gate widgets back from cfg — the settings window can change
        the same two values, and a stale checkbox here would silently undo it
        the next time anything on this panel saves."""
        self.filter_on.set(bool(self.cfg.get("app_filter_enabled")))
        self.e_filter.delete(0, "end")
        self.e_filter.insert(0, self.cfg.get("app_filter") or "")

    def _on_filter(self, _event=None) -> None:
        """The gate saves immediately, like the other machine-state toggles —
        a running mma.py picks it up on its next poll, no restart."""
        self.cfg["app_filter_enabled"] = self.filter_on.get()
        self.cfg["app_filter"] = self.e_filter.get().strip() or None
        try:
            settings_mod.save(self.path, self.cfg)
        except OSError as e:
            messagebox.showerror("Settings", str(e))
            return
        state = f"on ({self.cfg['app_filter']})" if self.filter_on.get() else "off"
        self._set_status(f"app filter {state}")

    def _on_massno(self) -> None:
        self.cfg["current"] = self.massno.get() - 1
        try:
            settings_mod.save(self.path, self.cfg)
        except OSError as e:
            messagebox.showerror("Settings", str(e))
            return
        self._set_status(f"massNo = {self.massno.get()}")

    def _on_clear(self) -> None:
        self.paste.delete("1.0", "end")

    def _on_parse(self) -> None:
        raw = self.paste.get("1.0", "end").strip()
        if not raw:
            messagebox.showinfo("Parse", "Paste a mass into the box first.")
            return
        parsed = massparse.parse(raw)
        i = self.notebook.index("current")
        parsed.name = self.masses[i].name or f"Mass {i + 1}"
        self.masses[i] = parsed
        self.tabs[i].load(parsed, self.cfg)
        self.dirty = True
        counts = "  ".join(f"f{g}:{len(parsed.fu[g])}" for g in (1, 2, 3))
        self._set_status(f"parsed into Mass {i + 1}  —  {counts}")

    def _on_export(self) -> None:
        """Put this tab's fields back into the paste box as !mma text."""
        i = self.notebook.index("current")
        m = self.tabs[i].collect(self.masses[i].name)
        self.paste.delete("1.0", "end")
        self.paste.insert("1.0", massparse.to_text(m, with_name=False))
        self._set_status("exported to the paste block")

    def _on_save(self) -> None:
        self._commit_all()
        try:
            save_library(self.masses, self.path)
            settings_mod.save(self.path, self.cfg)
        except OSError as e:
            messagebox.showerror("Save failed", str(e))
            return
        self.dirty = False
        self._set_status("saved")
        messagebox.showinfo(
            "Saved",
            f"Wrote {len(self.masses)} mass slot(s) to\n{self.path}\n\n"
            f"Previous file kept as {os.path.basename(self.path)}.bak\n"
            "A running mma.py picks this up within a second.")

    def _on_reload(self) -> None:
        if self.dirty and not messagebox.askyesno(
                "Reload", "Discard unsaved changes and re-read the file?"):
            return
        self.cfg = settings_mod.load(self.path)
        self.masses = pad_to(load_library(self.path), max(MIN_TABS, len(self.tabs)))
        self.massno.set(int(self.cfg.get("current", 0)) + 1)
        self._sync_gate_widgets()
        self.dirty = False
        self._load_all()
        self._set_status("reloaded")

    def _on_close(self) -> None:
        if self.dirty and not messagebox.askyesno(
                "Unsaved changes", "Close without saving?"):
            return
        self.root.destroy()


def main(argv=None) -> int:
    path = argv[0] if argv else MASSES_FILE
    root = tk.Tk()
    App(root, path)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
