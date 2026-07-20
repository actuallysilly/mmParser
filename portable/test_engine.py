#!/usr/bin/env python3
"""
Tests for mma.py's send engine, driven by FakeBackend so no real keystroke is
ever fired. Asserts the literal order of clipboard writes and key presses that
reaches the app — which is the whole product.

    python -m unittest test_engine -v
    python test_engine.py
"""

import json
import os
import tempfile
import time
import unittest

import massparse
import settings
from mma import Engine, FakeBackend

SAMPLE = """!mma the mass body

part one
part two

second follow up

third follow up
"""


class EngineTest(unittest.TestCase):
    """Base: an engine wired to a fake backend and an in-memory masses file."""

    def build(self, text=SAMPLE, app=("TestApp", "Test Window")):
        backend = FakeBackend(app=app)
        # sleep is stubbed out: the pacing is asserted separately, and real
        # sleeps would make this suite take 30 seconds for no benefit.
        self.slept = []
        engine = Engine(backend, masses_file="(memory)",
                        sleep=lambda s: self.slept.append(s))
        engine.masses = massparse.parse_file(text)
        engine.current = 0
        return engine, backend


class TestCoreSequence(EngineTest):
    def test_f1_sends_both_parts_in_order(self):
        engine, backend = self.build()
        engine.send_fu(1)
        self.assertEqual(backend.keys, [
            "clip:part one", "paste", "enter",
            "clip:part two", "paste", "enter",
        ])

    def test_f2_single_part(self):
        engine, backend = self.build()
        engine.send_fu(2)
        self.assertEqual(backend.keys, ["clip:second follow up", "paste", "enter"])

    def test_f3_single_part(self):
        engine, backend = self.build()
        engine.send_fu(3)
        self.assertEqual(backend.keys, ["clip:third follow up", "paste", "enter"])

    def test_pacing(self):
        """clip_delay before each paste, wait_time after each message."""
        engine, _ = self.build()
        engine.clip_delay, engine.wait_time = 0.06, 0.4
        engine.send_fu(1)
        self.assertEqual(self.slept, [0.06, 0.4, 0.06, 0.4])


class TestFuSingle(EngineTest):
    def test_parts_joined_into_one_message(self):
        engine, backend = self.build()
        engine.fu_single[1] = True
        engine.send_fu(1)
        self.assertEqual(backend.keys, ["clip:part one\npart two", "paste", "enter"])

    def test_single_part_group_unaffected(self):
        engine, backend = self.build()
        engine.fu_single[2] = True
        engine.send_fu(2)
        self.assertEqual(backend.keys, ["clip:second follow up", "paste", "enter"])


class TestAppGate(EngineTest):
    def test_wrong_app_sends_nothing(self):
        engine, backend = self.build(app=("Slack", "Slack | general"))
        engine.app_filter = "chrome"
        engine.send_fu(1)
        # Nothing SENT. A notify is expected and wanted: a gate that blocks in
        # silence is indistinguishable from a dead hotkey.
        self.assertEqual([e for e in backend.log if not e.startswith("notify:")], [])
        self.assertTrue(any(e.startswith("notify:blocked") for e in backend.log))

    def test_matching_app_name_sends(self):
        engine, backend = self.build(app=("chrome", "Infloww — Messages"))
        engine.app_filter = "chrome"
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:part one")

    def test_matching_window_title_sends(self):
        """Matching the title is what lets one filter work on both OSes, where
        the browser process is 'chrome' vs 'Google Chrome'."""
        engine, backend = self.build(app=("Google Chrome", "Infloww — Messages"))
        engine.app_filter = "infloww"
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:part one")

    def test_filter_is_case_insensitive(self):
        engine, backend = self.build(app=("Google Chrome", "INFLOWW"))
        engine.app_filter = "infloww"
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:part one")

    def test_no_filter_fires_anywhere(self):
        engine, backend = self.build(app=("Slack", "Slack"))
        engine.app_filter = None
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:part one")

    def test_gate_also_guards_paste_mass(self):
        engine, backend = self.build(app=("Slack", "Slack"))
        engine.app_filter = "chrome"
        engine.paste_mass()
        self.assertEqual([e for e in backend.log if not e.startswith("notify:")], [])
        self.assertTrue(any(e.startswith("notify:blocked") for e in backend.log))


class TestHeldModifier(EngineTest):
    """Regression: a send under a held modifier delivered NOTHING.

    Ctrl+1 means Ctrl is still physically down when the send fires ~60ms later.
    Measured into a real focused window: 152 chars arrive with no modifier held,
    0 with Ctrl held. The F1/F2/F3 bindings never hit this — no modifier — so it
    appeared only after the move to Ctrl+digit.
    """

    def test_modifiers_released_before_every_part(self):
        engine, backend = self.build()
        engine.send_fu(1)                       # SAMPLE f1 has two parts
        self.assertEqual(len(engine.parts_for(1)), 2)
        self.assertEqual(backend.mods_cleared, 2,
                         "must release before EACH part, not just the first")

    def test_release_precedes_the_clipboard_write(self):
        """Order matters: releasing after the paste would be too late."""
        engine, backend = self.build()
        calls = []
        backend.clear_modifiers = lambda: calls.append(("clear", len(backend.keys)))
        engine.send_fu(2)
        self.assertEqual(calls[0][1], 0, "cleared before any keystroke was sent")

    def test_paste_mass_also_releases(self):
        engine, backend = self.build()
        engine.paste_mass()
        self.assertEqual(backend.mods_cleared, 1)

    def test_blocked_send_does_not_touch_the_keyboard(self):
        engine, backend = self.build(app=("Slack", "Slack"))
        engine.app_filter = "chrome"
        engine.send_fu(1)
        self.assertEqual(backend.mods_cleared, 0)


class TestModelRouting(EngineTest):
    """Each model has its own keys, so a send names its slot outright and must
    NOT depend on which slot happens to be selected."""

    THREE = ("# alpha\n!mma body A\n\na1\n\n===\n"
             "# beta\n!mma body B\n\nb1\n\n===\n"
             "# gamma\n!mma body C\n\nc1\n")

    def test_each_model_sends_its_own_text(self):
        engine, backend = self.build(text=self.THREE)
        for model, expected in enumerate(["a1", "b1", "c1"]):
            backend.log.clear()
            engine.send_fu(1, model)
            self.assertEqual(backend.keys[0], f"clip:{expected}")

    def test_selected_slot_does_not_affect_an_explicit_model(self):
        """The regression this design exists to prevent: M3's key sending M1's
        text because slot 1 was selected."""
        engine, backend = self.build(text=self.THREE)
        engine.current = 0
        engine.send_fu(1, 2)
        self.assertEqual(backend.keys[0], "clip:c1")
        self.assertEqual(engine.current, 0, "sending must not move the selection")

    def test_model_none_still_uses_the_selection(self):
        engine, backend = self.build(text=self.THREE)
        engine.current = 1
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:b1")

    def test_paste_mass_is_per_model(self):
        engine, backend = self.build(text=self.THREE)
        engine.paste_mass(2)
        self.assertEqual(backend.keys, ["clip:body C", "paste"])

    def test_notify_names_the_model(self):
        """With three sets of keys the useful question is always which fired."""
        engine, backend = self.build(text=self.THREE)
        engine.send_fu(1, 1)
        self.assertTrue(any(e.startswith("notify:M2") for e in backend.log),
                        backend.log)

    def test_flags_are_per_model(self):
        engine, backend = self.build(text=self.THREE)
        settings.set_flag(engine.settings, "editable", 2, 1, True)
        self.assertFalse(engine.is_editable(1, 0))
        self.assertTrue(engine.is_editable(1, 2))
        engine.send_fu(1, 2)
        self.assertNotIn("enter", backend.keys)     # edit mode: no Enter

    def test_out_of_range_model_is_reported_not_crashed(self):
        engine, backend = self.build(text=self.THREE)
        engine.send_fu(1, 9)
        self.assertEqual(backend.keys, [])
        self.assertIn("no such mass slot", backend.log[0])

    def test_dispatch_passes_the_model_through(self):
        engine, backend = self.build(text=self.THREE)
        engine.sleep = lambda s: None
        engine.dispatch("fu", 1, 2)
        for _ in range(100):                        # dispatch runs on a thread
            if backend.keys:
                break
            time.sleep(0.01)
        self.assertEqual(backend.keys[0], "clip:c1")

    def test_busy_guard_is_global_across_models(self):
        """Two models sending at once would interleave in the one focused
        window, so the lock is deliberately not per model."""
        engine, backend = self.build(text=self.THREE)
        engine._busy.acquire()
        try:
            engine.dispatch("fu", 1, 1)
            self.assertTrue(any("still sending" in e for e in backend.log))
        finally:
            engine._busy.release()


class TestGateConfig(unittest.TestCase):
    """The toggle/filter pair in settings.json.

    Regression cover for a real bug: main() assigned engine.app_filter from the
    --app-filter flag unconditionally, so the flag's default of None overwrote
    whatever Engine.__init__ had just read from settings.json. The gate could
    never be switched on from the config file — it silently fell open.
    """

    def cfg(self, **kw):
        base = dict(settings.DEFAULTS)
        base.update(kw)
        return base

    def test_toggle_off_disables_the_gate(self):
        self.assertIsNone(
            settings.app_filter(self.cfg(app_filter="infloww",
                                         app_filter_enabled=False)))

    def test_toggle_on_returns_the_filter(self):
        self.assertEqual(
            settings.app_filter(self.cfg(app_filter="infloww",
                                         app_filter_enabled=True)),
            "infloww")

    def test_toggle_on_but_blank_filter_is_off(self):
        """An enabled gate with no text must not gate on the empty string, which
        substring-matches every window and would silently allow everything."""
        self.assertIsNone(
            settings.app_filter(self.cfg(app_filter="   ",
                                         app_filter_enabled=True)))

    def test_engine_honours_settings_gate(self):
        engine = Engine(FakeBackend(app=("Slack", "Slack")),
                        masses_file="(memory)", sleep=lambda s: None)
        engine.settings = self.cfg(app_filter="infloww", app_filter_enabled=True)
        engine.app_filter = settings.app_filter(engine.settings)
        self.assertFalse(engine.app_allowed())
        engine.backend.app = ("Infloww", "Infloww Messages")
        self.assertTrue(engine.app_allowed())


class TestHotkeyConfig(unittest.TestCase):
    def m(self, n):
        return settings.model_key(n)

    def test_defaults_when_unset(self):
        table = settings.hotkeys({})
        self.assertEqual(table[self.m(1)]["fu1"], "<ctrl>+1")
        self.assertEqual(table[self.m(2)]["fu1"], "<ctrl>+4")
        self.assertEqual(table[self.m(3)]["fu1"], "<ctrl>+7")
        expected = {self.m(n) for n in range(1, settings.MODELS + 1)} | {"global"}
        self.assertEqual(set(table), expected)

    def test_each_model_keeps_its_own_keys(self):
        """The whole point: M2's keys must not be M1's."""
        table = settings.hotkeys({})
        firsts = {table[self.m(n)]["fu1"] for n in range(1, settings.MODELS + 1)}
        self.assertEqual(len(firsts), settings.MODELS)

    def test_defaults_have_no_collisions(self):
        """Two actions on one combo is silent — pynput keeps only the last."""
        self.assertEqual(settings.conflicts(settings.hotkeys({})), {})

    def test_override_one_model_only(self):
        table = settings.hotkeys({"hotkeys": {self.m(2): {"fu1": "<f9>"}}})
        self.assertEqual(table[self.m(2)]["fu1"], "<f9>")
        self.assertEqual(table[self.m(1)]["fu1"], "<ctrl>+1")   # untouched
        self.assertEqual(table[self.m(2)]["fu2"], "<ctrl>+5")   # sibling default

    def test_blank_unbinds(self):
        table = settings.hotkeys({"hotkeys": {self.m(1): {"fu3": ""}}})
        self.assertNotIn("fu3", table[self.m(1)])
        self.assertIn("fu3", table[self.m(2)])

    def test_unknown_action_ignored(self):
        table = settings.hotkeys({"hotkeys": {self.m(1): {"nonsense": "<ctrl>+9"}}})
        self.assertEqual(set(table[self.m(1)]), set(settings.MODEL_ACTIONS))

    def test_legacy_flat_config_becomes_model_1(self):
        """An existing settings.json predates models. It must keep working, not
        silently revert to defaults — that is how a config change goes unseen."""
        old = {"hotkeys": {"fu1": "<alt>+1", "fu2": "<ctrl>+2",
                           "reload": "<ctrl>+<alt>+r"}}
        self.assertTrue(settings.is_legacy_hotkeys(old))
        table = settings.hotkeys(old)
        self.assertEqual(table[self.m(1)]["fu1"], "<alt>+1")
        self.assertEqual(table["global"]["reload"], "<ctrl>+<alt>+r")
        self.assertEqual(table[self.m(2)]["fu1"], "<ctrl>+4")   # M2 gets defaults

    def test_new_format_is_not_flagged_legacy(self):
        self.assertFalse(settings.is_legacy_hotkeys(
            {"hotkeys": {self.m(1): {"fu1": "<ctrl>+1"}}}))
        self.assertFalse(settings.is_legacy_hotkeys({}))

    def test_conflicts_are_detected_across_models(self):
        table = settings.hotkeys({"hotkeys": {self.m(2): {"fu1": "<ctrl>+1"}}})
        clash = settings.conflicts(table)
        self.assertIn("<ctrl>+1", clash)
        self.assertEqual(len(clash["<ctrl>+1"]), 2)

    def test_every_default_is_a_known_action(self):
        for n in range(1, settings.MODELS + 1):
            self.assertEqual(set(settings.DEFAULT_MODEL_HOTKEYS[n]),
                             set(settings.MODEL_ACTIONS))
        self.assertEqual(set(settings.DEFAULT_GLOBAL_HOTKEYS),
                         set(settings.GLOBAL_ACTIONS))

    def test_every_default_parses_in_pynput(self):
        """A default that pynput cannot parse would kill every hotkey at once."""
        try:
            from pynput import keyboard
        except ImportError:
            self.skipTest("pynput not installed")
        table = settings.hotkeys({})
        for section, binds in table.items():
            for name, combo in binds.items():
                with self.subTest(action=f"{section}/{name}"):
                    keyboard.HotKey.parse(combo)

    def test_bom_does_not_wipe_settings(self):
        """A BOM used to make json.load raise, and load() would hand back
        DEFAULTS — every setting silently reverting with no error shown."""
        with tempfile.TemporaryDirectory() as d:
            masses = os.path.join(d, "masses.txt")
            open(masses, "w").close()
            body = json.dumps({"app_filter": "infloww",
                               "app_filter_enabled": True,
                               "hotkeys": {settings.model_key(1): {"fu1": "<f9>"}}})
            with open(settings.path_for(masses), "w", encoding="utf-8-sig") as f:
                f.write(body)

            cfg = settings.load(masses)
            self.assertTrue(cfg["app_filter_enabled"])
            self.assertEqual(settings.app_filter(cfg), "infloww")
            self.assertEqual(settings.hotkeys(cfg)[self.m(1)]["fu1"], "<f9>")

    def test_settings_round_trip_keeps_new_keys(self):
        """load() only copies keys present in DEFAULTS, so a new setting that is
        not registered there is silently dropped on the next load."""
        with tempfile.TemporaryDirectory() as d:
            masses = os.path.join(d, "masses.txt")
            open(masses, "w").close()
            cfg = settings.load(masses)
            cfg["app_filter_enabled"] = True
            cfg["app_filter"] = "infloww"
            cfg["hotkeys"] = {settings.model_key(3): {"fu1": "<f9>"}}
            settings.save(masses, cfg)

            back = settings.load(masses)
            self.assertTrue(back["app_filter_enabled"])
            self.assertEqual(back["app_filter"], "infloww")
            self.assertEqual(settings.app_filter(back), "infloww")
            self.assertEqual(settings.hotkeys(back)[self.m(3)]["fu1"], "<f9>")


class TestPasteMass(EngineTest):
    def test_pastes_without_enter(self):
        engine, backend = self.build()
        engine.paste_mass()
        self.assertEqual(backend.keys, ["clip:the mass body", "paste"])

    def test_reports_when_absent(self):
        engine, backend = self.build(text="x\n\nfu one")
        engine.masses[0].mass = ""
        engine.paste_mass()
        self.assertIn("no mass body", backend.log[0])


class TestEmptyAndMissing(EngineTest):
    def test_empty_followup_is_reported(self):
        engine, backend = self.build(text="!mma only a mass here")
        engine.send_fu(2)
        self.assertIn("nothing in follow-up 2", backend.log[0])

    def test_no_masses_loaded(self):
        engine, backend = self.build(text="")
        engine.send_fu(1)
        self.assertEqual(len(backend.log), 1)
        self.assertIn("no such mass slot", backend.log[0])


class TestMassSwitching(EngineTest):
    TWO = "# one\n!mma first\n\na\n\n===\n\n# two\n!mma second\n\nb"

    def test_cycles(self):
        engine, backend = self.build(text=self.TWO)
        self.assertEqual(len(engine.masses), 2)
        engine.next_mass()
        self.assertEqual(engine.current, 1)
        engine.send_fu(1)
        self.assertEqual(backend.keys[0], "clip:b")
        engine.next_mass()
        self.assertEqual(engine.current, 0)

    def test_switch_is_announced(self):
        engine, backend = self.build(text=self.TWO)
        engine.next_mass()
        self.assertEqual(backend.log[0], "notify:[2/2] two")


class TestBusyGuard(EngineTest):
    """dispatch() runs sends on a worker thread; the lock stops two follow-ups
    interleaving in the chat if F1 is pressed twice."""

    def test_second_dispatch_refused_while_locked(self):
        engine, backend = self.build()
        engine._busy.acquire()          # simulate a send already in flight
        try:
            engine.dispatch("fu", 1)
        finally:
            engine._busy.release()
        self.assertIn("still sending", backend.log[0])

    def test_lock_released_after_send(self):
        engine, backend = self.build()
        engine.dispatch("fu", 1)
        for _ in range(200):            # worker is a real thread; wait for it
            if engine._busy.acquire(blocking=False):
                engine._busy.release()
                break
            import time
            time.sleep(0.01)
        else:
            self.fail("busy lock was never released")
        self.assertEqual(backend.keys, [
            "clip:part one", "paste", "enter",
            "clip:part two", "paste", "enter",
        ])

    def test_lock_released_even_when_send_raises(self):
        engine, backend = self.build()

        def boom(_group):
            raise RuntimeError("kaboom")

        engine.send_fu = boom
        engine.dispatch("fu", 1)
        import time
        for _ in range(200):
            if engine._busy.acquire(blocking=False):
                engine._busy.release()
                break
            time.sleep(0.01)
        else:
            self.fail("a failing send wedged the busy lock")
        self.assertTrue(any("send failed" in x for x in backend.log))

    def test_non_send_actions_bypass_the_lock(self):
        """reload/next/whoami must still work while a send is in flight."""
        engine, backend = self.build(text=TestMassSwitching.TWO)
        engine._busy.acquire()
        try:
            engine.dispatch("next", 0)
        finally:
            engine._busy.release()
        self.assertEqual(engine.current, 1)


class TestFileLoading(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".txt")
        os.close(fd)
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(SAMPLE)
        self.backend = FakeBackend()
        self.engine = Engine(self.backend, masses_file=self.path, sleep=lambda s: None)

    def tearDown(self):
        os.unlink(self.path)

    def test_loads_from_disk(self):
        self.assertTrue(self.engine.load(quiet=True))
        self.assertEqual(self.engine.masses[0].fu[1], ["part one", "part two"])

    def test_reload_on_change(self):
        self.engine.load(quiet=True)
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("!mma changed\n\nbrand new part")
        os.utime(self.path, (0, 0))          # force a different mtime
        self.engine.reload_if_changed()
        self.assertEqual(self.engine.masses[0].fu[1], ["brand new part"])

    def test_missing_file_is_reported_not_raised(self):
        engine = Engine(self.backend, masses_file="/no/such/file.txt",
                        sleep=lambda s: None)
        self.assertFalse(engine.load())
        self.assertEqual(engine.masses, [])
        self.assertTrue(any("cannot read" in x for x in self.backend.log))


if __name__ == "__main__":
    unittest.main(verbosity=2)
