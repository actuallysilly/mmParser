#!/usr/bin/env python3
"""
Tests for gui.py and settings.py. Builds the real widgets in a hidden window and
drives them the way a click would, so the wiring is covered and not just the
pure helpers.

    python -m unittest test_gui -v

Skips the widget tests if no display is available (headless CI, ssh session).
"""

import json
import os
import tempfile
import unittest

import massparse
import settings as settings_mod

try:
    import tkinter as tk
    _probe = tk.Tk()
    _probe.withdraw()
    _probe.destroy()
    HAVE_TK = True
except Exception:                                    # no display, or no tkinter
    HAVE_TK = False

import gui

SAMPLE = """# First
!mma opener one

part a
part b

second follow up

===

# Second
!mma opener two

only one part
"""


class _Tmp(unittest.TestCase):
    """A scratch masses.txt that never touches the real one."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "masses.txt")
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(SAMPLE)

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)


# ── pure helpers ─────────────────────────────────────────────────────────────

class TestFileHelpers(_Tmp):
    def test_load(self):
        masses = gui.load_library(self.path)
        self.assertEqual([m.name for m in masses], ["First", "Second"])
        self.assertEqual(masses[0].fu[1], ["part a", "part b"])

    def test_missing_file_gives_empty_library(self):
        self.assertEqual(gui.load_library(os.path.join(self.dir, "nope.txt")), [])

    def test_save_round_trips(self):
        gui.save_library(gui.load_library(self.path), self.path)
        again = gui.load_library(self.path)
        self.assertEqual([m.name for m in again], ["First", "Second"])
        self.assertEqual(again[0].fu[1], ["part a", "part b"])

    def test_save_writes_a_backup(self):
        gui.save_library(gui.load_library(self.path), self.path)
        self.assertTrue(os.path.exists(self.path + ".bak"))

    def test_save_leaves_no_tmp_behind(self):
        gui.save_library(gui.load_library(self.path), self.path)
        self.assertFalse(os.path.exists(self.path + ".tmp"))

    def test_pad_to_never_truncates(self):
        """A file with more masses than tabs must keep every one of them."""
        five = [gui.blank_mass(i) for i in range(1, 6)]
        self.assertEqual(len(gui.pad_to(five, 3)), 5)

    def test_pad_to_fills_up_to_minimum(self):
        self.assertEqual(len(gui.pad_to([], 3)), 3)


class TestSettings(_Tmp):
    def test_defaults_when_absent(self):
        cfg = settings_mod.load(self.path)
        self.assertEqual(cfg["current"], 0)
        self.assertEqual(cfg["single"], {})

    def test_round_trip(self):
        cfg = settings_mod.load(self.path)
        settings_mod.set_flag(cfg, "single", 0, 2, True)
        settings_mod.set_flag(cfg, "editable", 1, 3, True)
        cfg["current"] = 1
        settings_mod.save(self.path, cfg)

        again = settings_mod.load(self.path)
        self.assertTrue(settings_mod.get_flag(again, "single", 0, 2))
        self.assertTrue(settings_mod.get_flag(again, "editable", 1, 3))
        self.assertFalse(settings_mod.get_flag(again, "single", 0, 1))
        self.assertEqual(again["current"], 1)

    def test_flags_are_per_slot_and_group(self):
        cfg = settings_mod.load(self.path)
        settings_mod.set_flag(cfg, "single", 0, 1, True)
        self.assertFalse(settings_mod.get_flag(cfg, "single", 1, 1), "slot leaked")
        self.assertFalse(settings_mod.get_flag(cfg, "single", 0, 2), "group leaked")

    def test_corrupt_file_falls_back_to_defaults(self):
        """A broken settings.json must not stop MMA starting."""
        with open(settings_mod.path_for(self.path), "w", encoding="utf-8") as f:
            f.write("{not json at all")
        cfg = settings_mod.load(self.path)
        self.assertEqual(cfg["current"], 0)

    def test_sits_beside_the_masses_file(self):
        self.assertEqual(os.path.dirname(settings_mod.path_for(self.path)), self.dir)


# ── widgets ──────────────────────────────────────────────────────────────────

@unittest.skipUnless(HAVE_TK, "no display available")
class TestApp(_Tmp):
    def setUp(self):
        super().setUp()
        self.root = tk.Tk()
        self.root.withdraw()                         # never actually show it
        self.app = gui.App(self.root, self.path)

    def tearDown(self):
        self.root.destroy()
        super().tearDown()

    # layout

    def test_three_tabs_minimum(self):
        self.assertEqual(self.app.notebook.index("end"), 3)
        self.assertEqual(self.app.notebook.tab(0, "text"), "Mass 1")

    def test_each_group_has_three_part_boxes(self):
        tab = self.app.tabs[0]
        for g in (1, 2, 3):
            self.assertEqual(len(tab.parts[g]), 3)

    def test_fields_populated_from_file(self):
        tab = self.app.tabs[0]
        self.assertEqual(tab.e_mass.get(), "opener one")
        self.assertEqual(tab.parts[1][0].get(), "part a")
        self.assertEqual(tab.parts[1][1].get(), "part b")
        self.assertEqual(tab.parts[2][0].get(), "second follow up")

    def test_second_tab_has_its_own_mass(self):
        self.assertEqual(self.app.tabs[1].e_mass.get(), "opener two")

    def test_third_tab_is_blank(self):
        self.assertEqual(self.app.tabs[2].e_mass.get(), "")

    # editing

    def test_collect_drops_blank_parts(self):
        tab = self.app.tabs[0]
        tab.parts[1][0].delete(0, "end")
        tab.parts[1][1].delete(0, "end")
        tab.parts[1][2].insert(0, "only the last box")
        self.assertEqual(tab.collect("x").fu[1], ["only the last box"])

    def test_parse_fills_the_current_tab(self):
        self.app.notebook.select(1)
        self.app.paste.insert("1.0", "!mma pasted\n\nnew one\nnew two\n\nnew three")
        self.app._on_parse()
        tab = self.app.tabs[1]
        self.assertEqual(tab.e_mass.get(), "pasted")
        self.assertEqual(tab.parts[1][0].get(), "new one")
        self.assertEqual(tab.parts[1][1].get(), "new two")
        self.assertEqual(tab.parts[2][0].get(), "new three")
        self.assertEqual(self.app.tabs[0].e_mass.get(), "opener one", "other tab touched")

    def test_export_puts_text_back_in_the_paste_box(self):
        self.app.notebook.select(0)
        self.app._on_export()
        text = self.app.paste.get("1.0", "end")
        self.assertIn("!mma opener one", text)
        self.assertIn("f1: part a", text)
        self.assertIn("f1.5: part b", text)

    def test_export_then_parse_is_lossless(self):
        self.app.notebook.select(0)
        self.app._on_export()
        self.app._on_parse()
        tab = self.app.tabs[0]
        self.assertEqual(tab.e_mass.get(), "opener one")
        self.assertEqual(tab.parts[1][0].get(), "part a")
        self.assertEqual(tab.parts[1][1].get(), "part b")

    def test_clear_empties_the_paste_box(self):
        self.app.paste.insert("1.0", "something")
        self.app._on_clear()
        self.assertEqual(self.app.paste.get("1.0", "end").strip(), "")

    # persistence

    def test_save_then_reload(self):
        self.app.tabs[0].e_mass.delete(0, "end")
        self.app.tabs[0].e_mass.insert(0, "persisted opener")
        with _silence():
            self.app._on_save()
        self.assertFalse(self.app.dirty)
        self.app._on_reload()
        self.assertEqual(self.app.tabs[0].e_mass.get(), "persisted opener")

    def test_save_survives_emoji(self):
        tab = self.app.tabs[0]
        tab.e_mass.delete(0, "end")
        tab.e_mass.insert(0, "Beach or bedroom? 🏖️")
        with _silence():
            self.app._on_save()
        self.assertEqual(gui.load_library(self.path)[0].mass, "Beach or bedroom? 🏖️")

    def test_blank_tabs_do_not_add_junk_masses(self):
        with _silence():
            self.app._on_save()
        again = gui.load_library(self.path)
        with_content = [m for m in again if m.mass or any(m.fu[g] for g in (1, 2, 3))]
        self.assertEqual(len(with_content), 2)

    # toggles

    def test_single_checkbox_writes_settings(self):
        self.app.notebook.select(0)
        self.app.tabs[0].single[2].set(True)
        self.app._on_flag()
        cfg = settings_mod.load(self.path)
        self.assertTrue(settings_mod.get_flag(cfg, "single", 0, 2))

    def test_edit_checkbox_writes_settings(self):
        self.app.notebook.select(0)
        self.app.tabs[0].editable[1].set(True)
        self.app._on_flag()
        cfg = settings_mod.load(self.path)
        self.assertTrue(settings_mod.get_flag(cfg, "editable", 0, 1))

    def test_toggles_reload_into_the_boxes(self):
        self.app.tabs[0].single[3].set(True)
        self.app._on_flag()
        self.app._on_reload()
        self.assertTrue(self.app.tabs[0].single[3].get())

    def test_massno_writes_settings(self):
        self.app.massno.set(2)
        self.app._on_massno()
        with open(settings_mod.path_for(self.path), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["current"], 1)

    # the handover to the engine

    def test_saved_file_is_what_the_engine_sends(self):
        """The GUI and mma.py must agree, or Save silently breaks the thing the
        GUI exists to prepare."""
        with _silence():
            self.app._on_save()
        from mma import Engine, FakeBackend
        engine = Engine(FakeBackend(), masses_file=self.path, sleep=lambda s: None)
        engine.load(quiet=True)
        engine.send_fu(1)
        self.assertEqual(engine.backend.keys, [
            "clip:part a", "paste", "enter",
            "clip:part b", "paste", "enter",
        ])

    def test_single_toggle_reaches_the_engine(self):
        self.app.tabs[0].single[1].set(True)
        self.app._on_flag()
        with _silence():
            self.app._on_save()
        from mma import Engine, FakeBackend
        engine = Engine(FakeBackend(), masses_file=self.path, sleep=lambda s: None)
        engine.load(quiet=True)
        engine.send_fu(1)
        self.assertEqual(engine.backend.keys,
                         ["clip:part a\npart b", "paste", "enter"])

    def test_edit_toggle_reaches_the_engine(self):
        self.app.tabs[0].editable[1].set(True)
        self.app._on_flag()
        with _silence():
            self.app._on_save()
        from mma import Engine, FakeBackend
        engine = Engine(FakeBackend(), masses_file=self.path, sleep=lambda s: None)
        engine.load(quiet=True)
        engine.send_fu(1)
        self.assertEqual(engine.backend.keys, ["clip:part a\npart b", "paste"],
                         "edit must paste the joined parts and NOT press Enter")

    def test_massno_reaches_the_engine(self):
        self.app.massno.set(2)
        self.app._on_massno()
        with _silence():
            self.app._on_save()
        from mma import Engine, FakeBackend
        engine = Engine(FakeBackend(), masses_file=self.path, sleep=lambda s: None)
        engine.load(quiet=True)
        engine.send_fu(1)
        self.assertEqual(engine.backend.keys[0], "clip:only one part")


class _silence:
    """messagebox would block on a real dialog; stub it for the duration."""

    def __init__(self, answer=True):
        self.answer = answer

    def __enter__(self):
        self._saved = (gui.messagebox.showinfo, gui.messagebox.showerror,
                       gui.messagebox.askyesno)
        gui.messagebox.showinfo = lambda *a, **k: None
        gui.messagebox.showerror = lambda *a, **k: None
        gui.messagebox.askyesno = lambda *a, **k: self.answer
        return self

    def __exit__(self, *exc):
        (gui.messagebox.showinfo, gui.messagebox.showerror,
         gui.messagebox.askyesno) = self._saved


@unittest.skipUnless(HAVE_TK, "no display")
class TestSettingsWindow(_Tmp):
    """The settings editor, driven through the real widgets."""

    def open(self):
        root = tk.Tk()
        root.withdraw()
        app = gui.App(root, self.path)
        with _silence():
            win = gui.SettingsWindow(root, app)
        return root, app, win

    def m(self, n):
        return settings_mod.model_key(n)

    def test_prefills_every_model_from_settings(self):
        root, _, win = self.open()
        try:
            for n in range(1, settings_mod.MODELS + 1):
                got = win.entries[(self.m(n), "fu1")].get()
                self.assertEqual(got, settings_mod.DEFAULT_MODEL_HOTKEYS[n]["fu1"])
        finally:
            root.destroy()

    def test_legacy_config_prefills_into_model_1(self):
        """An existing single-model settings.json must show up as M1, not be
        silently replaced by defaults."""
        settings_mod.save(self.path, {"hotkeys": {"fu1": "<alt>+1"}})
        root, _, win = self.open()
        try:
            self.assertEqual(win.entries[(self.m(1), "fu1")].get(), "<alt>+1")
            self.assertEqual(win.entries[(self.m(2), "fu1")].get(),
                             settings_mod.DEFAULT_MODEL_HOTKEYS[2]["fu1"])
        finally:
            root.destroy()

    def test_duplicate_across_models_is_refused(self):
        """Two actions on one combo is silent at runtime — pynput keeps only the
        last binding — so it has to be caught here, at the point of editing."""
        root, _, win = self.open()
        try:
            e = win.entries[(self.m(2), "fu1")]
            e.delete(0, "end")
            e.insert(0, win.entries[(self.m(1), "fu1")].get())
            with _silence():
                win._save()
            self.assertTrue(win.win.winfo_exists(), "window should stay open")
            self.assertIn("bound twice", win.msg.cget("text"))
            saved = settings_mod.load(self.path)
            self.assertNotEqual(
                settings_mod.hotkeys(saved)[self.m(2)]["fu1"],
                settings_mod.hotkeys(saved)[self.m(1)]["fu1"])
        finally:
            root.destroy()

    def test_unparseable_combo_is_refused(self):
        root, _, win = self.open()
        try:
            e = win.entries[(self.m(3), "fu2")]
            e.delete(0, "end")
            e.insert(0, "<nonsense>+q")
            with _silence():
                win._save()
            self.assertIn("not valid pynput syntax", win.msg.cget("text"))
        finally:
            root.destroy()

    def test_save_writes_the_per_model_format(self):
        root, _, win = self.open()
        try:
            e = win.entries[(self.m(2), "fu1")]
            e.delete(0, "end")
            e.insert(0, "<ctrl>+<shift>+2")
            with _silence():
                win._save()
            saved = settings_mod.load(self.path)
            self.assertFalse(settings_mod.is_legacy_hotkeys(saved))
            table = settings_mod.hotkeys(saved)
            self.assertEqual(table[self.m(2)]["fu1"], "<ctrl>+<shift>+2")
            self.assertEqual(settings_mod.conflicts(table), {})
        finally:
            root.destroy()

    def test_blank_entry_unbinds(self):
        root, _, win = self.open()
        try:
            e = win.entries[(self.m(3), "mass")]
            e.delete(0, "end")
            with _silence():
                win._save()
            table = settings_mod.hotkeys(settings_mod.load(self.path))
            self.assertNotIn("mass", table[self.m(3)])
        finally:
            root.destroy()

    def test_gate_and_timing_round_trip(self):
        root, app, win = self.open()
        try:
            win.filter_on.set(True)
            win.e_filter.delete(0, "end"); win.e_filter.insert(0, "infloww")
            win.e_wait.delete(0, "end");   win.e_wait.insert(0, "0.9")
            with _silence():
                win._save()
            saved = settings_mod.load(self.path)
            self.assertEqual(settings_mod.app_filter(saved), "infloww")
            self.assertEqual(saved["wait_time"], 0.9)
            # the main panel's own gate widgets must not still show the old value
            self.assertTrue(app.filter_on.get())
            self.assertEqual(app.e_filter.get(), "infloww")
        finally:
            root.destroy()

    def test_non_numeric_timing_is_refused(self):
        root, _, win = self.open()
        try:
            win.e_wait.delete(0, "end"); win.e_wait.insert(0, "soon")
            with _silence():
                win._save()
            self.assertIn("must be numbers", win.msg.cget("text"))
        finally:
            root.destroy()


if __name__ == "__main__":
    unittest.main(verbosity=2)
