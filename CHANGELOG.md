# Changelog

## 2.0.1 — 2026-07-30

### New: themes, and a Settings → GUI tab to switch them

Three: **Pink** (default), **Dark**, and **Classic** (what MMA looked like before — system
windows, dark picker).

Pink is `#FEF7F9`, white with a little pink in it rather than a pink window. Kept that pale on
purpose: MMA's windows are mostly **text**, and a real pink behind black text is tiring across a
whole shift. Measured on 2.0.26 — static controls (Text, Checkbox, Radio, GroupBox) follow
`Gui.BackColor` automatically, while Edit, ListView and Button keep system colours, so the light
themes need nothing but the one background.

Dark needs four colours, not one, because nothing inherits a *foreground*: set only the
background and you get black text on a black window. It splits in two, and the split is not
optional:

* **Labels get their colour from the window font, before any control exists** —
  `g.SetFont("s9" THEME_FontOpt(), …)`. Colouring them afterwards does not work, and fails two
  different ways depending on how you try it. A static **on a tab page** that is sent `SetFont`
  loses its inherited background and repaints with the system colour — a pale box behind every
  label on a dark window. Add `+Background` to fix that and the same static comes back
  `#000000`. Measured: an identical label *outside* the tab takes an explicit background
  correctly (`#1E1D26` as asked); on a tab page it is `#000000`. Tab children are painted
  through a different path and will not be told what to do after the fact.
* **Everything else is walked afterwards** by `THEME_ApplyTo()` — the tab control (which paints
  the whole panel), the Edit/ListView/dropdown interiors, and the title bar via
  `DWMWA_USE_IMMERSIVE_DARK_MODE`.

The tab pass runs on **every** theme that sets a colour, not just dark — without it the main
window's tab page was never pink either.

**Buttons and ListView headers stay light**: Windows draws those and ignores a colour unless the
whole control is owner-drawn. That is on the tin in the GUI tab rather than left as a surprise.

`core/theme.ahk` is the single source. It has to be a **name in the cfg**, not a variable —
the main window, Settings and the follow-up picker are three different *processes*, and the cfg
is the only thing they share. Each reads it per use, so switching applies without restarting
anything: the main window repaints immediately, Settings on its next open, the picker on the next
follow-up key. Adding a fourth theme is one edit in that file; the radio buttons are generated
from `THEME_List()`.

The GUI tab also holds the picker's `AltGuiWidth` and `AltGuiLift`, which were ini-only.

Three notes for anyone extending this. A `Tab3` paints its own page interior, and that page
covers everything but an 8px frame — so `sg.BackColor` alone changes a border you cannot see; the
tab control needs its own `Background` option. Setting a control's colour is not the same as
repainting with it: without `Redraw()` the Edit boxes keep the colours they were created with,
the same way the picker's highlight bar did. And **radio buttons group by creation order** — a
group ends at the first control that is not a radio, so adding each radio followed by its
description `Text` made every one a group of one, all three themes could be lit at once, and Save
wrote whichever it found first. The radios go in as one run now, descriptions afterwards, and
`settings_build_test.ahk` asserts that exactly one is checked, because a control census cannot
see this.

`settings_build_test.ahk` grew a `hold [tab] [theme]` mode for looking at the result — the theme
goes through the `MMA_THEME` environment variable, never into your cfg, because a tool that
leaves your settings changed has broken something.

### New: `docs/ahk-gui.html` — the advanced AHK v2 GUI reference

Self-contained page (inline CSS, nothing loaded from the network, light and dark) on the parts
of `Gui` that do something other than put a button on a form: `WS_EX_NOACTIVATE` overlays, the
DPI-scaling trap that silently clips a window's last control, measuring controls before showing
them, restyling in place, hotkeys scoped to one window, and how to build- and screenshot-test a
GUI without a pair of eyes on it. Claims are tagged **measured here** (demonstrated against
2.0.26 on this machine) or **capability** (documented behaviour), because they are not worth the
same. Ends in a symptom → cause trap sheet.

### Fixed: Enter could send EVERY variant instead of the one you picked

The staged preview went **into the chat box**. Enter then cleared the box (`Ctrl+A`, `Delete`),
pasted the marked variant and sent it — and that clear is not reliable. Infloww's composer is a
web editor, and `Ctrl+A` in one of those can be swallowed outright or select the page instead.
When it missed, the preview was still sitting there, the chosen variant was pasted onto the end
of it, and **Enter sent the lot to the fan**: every variant, the markers, the labels, as one
message.

No settling delay fixes that, because it is not a race — it is the composer refusing the
keystroke. So the preview does not go in the chat box any more.

**The variants now show in a small window** above the composer: always on top, `WS_EX_NOACTIVATE`
so it never takes focus off the chat, one band per variant with the marked one lit. `TAB` walks
it, **`SHIFT+TAB` walks back** (new — `*Tab` fires on Shift+Tab too, so going backwards needed
its own binding), `Enter` sends, `Esc` cancels. The chat box is never written to and never
cleared, so the variants **cannot** be sent: they were never in the thing that sends.

Two consequences worth knowing:

* Anything you had typed in the composer stays. It is yours, and Escape no longer wipes it
  either. A chosen variant lands after it — visible while you pick, since the window sits above
  the composer rather than on it.
* The picker cannot outlive the chat. `Tab`/`Enter`/`Esc` are scoped to the window staging began
  in, which left a hole: switch away and **Escape stopped reaching the picker**, leaving an
  always-on-top window with no title bar and no key that worked until the 45-second timeout.
  A watchdog now closes it if that window is gone, and hides it while you are in another app —
  come back and it is where you left it, marker and all.

**Settings → Sending → "Don't use a GUI for alt FUs"** puts the preview back in the chat box, bug
and all. It is the way out if the window misbehaves on your setup, not a preference. Read per
keypress, so it applies to the next follow-up key with no restart. Two ini tunables come with it:
`AltGuiWidth` (default 560, "at 100% zoom") and `AltGuiLift` (default 150, how far above the
window's bottom edge it sits). A window that fails to build falls back to the chat box by itself.

`tools/altgui_test.ahk` covers the label/body rendering and the walk, and `… show` puts the
window up against a stand-in chat window so it can be looked at without Infloww.

### Fixed: the alt picker pasted `/` into a composer where `/` is a command

`AltStagePartSep` — the separator between the parts of one staged variant — defaulted to
`  /  `. The staged preview is **pasted into the Infloww composer**, and `/` is Infloww's
command trigger: it opened the slash-command menu over the box, which then swallowed the `Tab`
and `Enter` that the picker runs on. The picker looked frozen, and escaping it could send the
wrong variant.

Now `  |  `. Changing the default was not enough on its own — `AltStageSetting` *seeds* the cfg
the first time it reads a key, so every machine where a choice had ever been staged already had
`AltStagePartSep=\s\s/\s\s` on disk, and a stored value always beats the fallback. So there is a
one-time migration that rewrites **only the untouched original**; a separator you set yourself is
left exactly as it is, slash or not.

### "How to Use" is a real guide now

**`docs/guide.html`** — one self-contained page (CSS inline, nothing to install, nothing loaded
from the network), opened in the default browser by the main window's **How to Use** button.
Light and dark, with a sticky contents sidebar and **real screenshots** in `docs/img/`.

Written for somebody who has been chatting for months and needs to know where things are in
*this tool*, not what a follow-up is: the window control by control, a full key reference, the
paste format as reference rather than tutorial, the two footguns that eat afternoons
(`massNo` pointing at an empty slot, and load/save moving all three tabs at once), the three
ways MMA decides which model is on screen and why "I pick" exists, Tab-staging, the six
Settings tabs, the logging switches, and a symptom → cause table.

Screenshots are captured from the running app with the message fields pixelated — the copy in
them is live working text, not sample data.

That button previously dumped `docs/mass-format.md` into a read-only, non-wrapping Edit control
in a 600×480 window — and because nobody could stand to read it, nobody noticed the content had
gone stale: it still told you to open `1_mass.ahk` and `2_mass.ahk` to change your hotkeys, and
neither file has existed since the v2 tree. It also documented the follow-up part suffixes as
`.1` and `.2`, when the parser has only ever accepted **`.5` and `.7`** — so anyone following it
had parts silently dropped.

`docs/mass-format.md` survives as the markdown format reference, rewritten against what
`parser.ahk` actually does.

### Logging — every process, one file, and a switch that turns failures into dialogs

MMA is up to eight processes talking through ini files and `PostMessage`, and none of
that produces a stack trace when it goes wrong. It produces **nothing** — which is the
actual bug report this answers: *"it silently failed to do something on my friend's
machine."*

- **`src/core/log.ahk`**, included at the end of `paths.ahk` — the one file every entry
  point already includes. Every process now gets a `BOOT` line, an `EXIT` line (with the
  reason, so a `ProcessClose` from the watchdog is visible) and an `OnError` hook that
  records the **stack**, with no per-script wiring and no way to drift out of step.
- **A `BAIL` level**, which is the point of the exercise. `INFO`/`WARN`/`FAIL` were never
  the problem; the problem is the branch that returned early on purpose — feature off,
  key unbound, mass slot empty, window not in front. All correct, all invisible, all
  indistinguishable from a broken app. Roughly 200 of those now say which one they were.
- **Settings ▸ Debug** grew the three switches, and is their sole writer:
  *Write a log file* (default **on**), *Report errors with a pop-up*, *Max logging*.
  Written on click, not on Save — they are read by eight processes, all of which re-read
  the cfg on a 1.5s timer, so a click is live everywhere with no restart.
- **Pop-ups carry the last 20 log lines**, so a user on another machine can screenshot
  the context instead of finding, opening and sending a file. Budgeted — same message
  once per process, 15 per process, 60s timeout — so a failure inside a 500ms timer
  cannot become a machine you have to reboot.
- **`MMA_DEBUG=max|popups|off`** in the environment overrides all three, for the machine
  you cannot open Settings on. When set, the checkboxes disable themselves and say why.
- **Diagnostic report** button: one file to hand over — environment, both config files in
  full, and the last 400 log lines. Masses and message text are deliberately excluded.
- `error_log.txt` is now failures only (short enough to read top to bottom);
  `mma.log` is the full timeline and rotates at 8 MB.

Instrumented throughout: the hotkey registry (every bind, every refusal, every
anti-fumble drop and by how many milliseconds), the feature gate, every child process
launch and the watchdog, model resolution, the whole send path, the mass library,
next-follow-up, the Discord import, the detector's OCR, and the updater.

Every `ClipWait` on the send path is now a `FAIL` rather than an ignored return value —
a clipboard that does not take the text means Ctrl+V pastes **the previous clipboard**
into a real fan's chat and presses Enter, which was previously undetectable.

### The Discord Ctrl+click import has no switch left to lose

It has been reported broken four times, and the cause has never once been the import's own
code. Every time it was a switch somebody could turn off: the `StartupScripts` checkbox
(whose default list does not include it, so fresh installs never had it), the same box
unticked by a Settings save, and — after those were fixed — the **Features tab**, plus
**Easy mode**, which switches off every feature in the registry in one radio button and took
the import down with them, silently and with no box to look at.

So `sequences` is no longer a feature. It is gone from the registry in `core/modes.ahk`,
which is what makes it always-on: `FEAT()` answers true for any id it does not know, in Easy
mode as much as Advanced. Its hotkeys lost their `FEAT_HOTKEY_MAP` entry, so `HK_Bind`
registers them whatever the mode, and `LaunchSequences()` lost its gate. It is core now,
exactly like the mass engine — a script that owns hotkeys should not be a checkbox.

`sequences.ahk` and the engine also **start first** rather than last. Both used to be
launched at the bottom of `main_window.ahk`, after three tabs, the variants window and the
settings tabs had been built — 280–390 ms in which MMA is on screen with every hotkey it owns
dead, which is exactly when you would reach for one. Measured after the move: engine at
**38 ms**, `seq.copyDiscordMsg` bound and live at **223 ms**.

### Fixed

- `Clear logs` swept `*.txt` only, so it would have left `mma.log` — the one file that
  actually grows — behind.
- `MMA.ahk` had a stray word pasted after `ExitApp`, which is a **load-time** syntax error:
  the launcher — the one thing you double-click — put up an error dialog and started nothing.

## 2.0.0-alpha — 2026-07-27

First 2.0.0 pre-release. A clean break: no migration shims, no compatibility aliases.

### The tree

Seven roles that were all peers in the repo root are now `src/ content/ userdata/
assets/ tools/ docs/`. Every path resolves from **one anchor** (`src/core/paths.ahk`,
via `A_LineFile`), replacing 37 uses of `A_ScriptDir` that only worked while every entry
point sat in the root — and that fail *silently* from a subfolder, because `IniRead` with
a default just returns the default.

### One mass engine, and the data left the code

`1_mass.ahk` / `2_mass.ahk` / `3_mass.ahk` were three processes holding three copies of
the same behaviour around three blocks of data. The data is now `userdata/masses.json`
(`src/mass/store.ahk`); the behaviour was already shared. What was left was three
processes fighting over the same hotkeys, which took **five** separate arbitration
mechanisms — a 350ms timer per process, an in-handler re-check, a shared-id list, and a
conflict-report exemption to stop the GUI flagging three copies of one key. One process
needs none of them. All five are gone.

Migration was verified field by field before the old files were deleted.

### Sending

- **The mouse buttons stopped belonging to model 1.** `mFu1`-`mFu3` were declared under
  `[mass.1]`, so pressing XButton1 in front of model 2 sent *model 1's* follow-up to
  model 2's fan. There is one XButton1 and it is under your thumb whichever tab is open;
  shared keys live in `[mass.active]`, resolved at fire time.
- `[mass.active]` now covers the whole action set — PPV, branches, alts, the mass body —
  not just follow-ups, on the free Scimitar buttons.
- Per-model keys (`F1`-`F3`, `F9`-`F11`, …) are untouched and never gated. The key you
  press *is* the model selector, whether or not any detector is running.

### Knowing which model is on screen

Three ways, chosen per install, plus a platform flag chosen **per model** so an Infloww
model and a Fansly model can coexist. See ARCHITECTURE.md §5.1.

The detector itself was rebuilt around one measurement: **`PixelGetColor` costs ~30ms a
call on a composited desktop.** Sampling three tab slots took 4632ms; a full band sweep
took 10828ms against a 500ms poll interval. The service was ~20x slower than its own
poll — permanently behind, never once returning a current reading. Every earlier
explanation (wrong colours, wrong tolerance, tab counting) fitted the symptoms and fixed
nothing, because each was tested against data that was seconds stale. One BitBlt into a
memory DIB: 4632ms → 10ms.

With fresh input the rest is arithmetic. Tab positions are fixed, so the lit pill's x
*is* the tab index; which model that tab is comes from Settings, because no pixel carries
that fact.

Throughout, a detector that cannot see now **says so**. "No answer" costs a keypress; a
confident wrong answer costs one model's message in another model's chat.

### Also

- Hotstrings replace seven `acc/ALIW.ahk` functions that were canned messages wearing
  hotkeys (see Unreleased, below).
- `automation.py` resolved its root one folder short, so it read a `hotkeys.ini` that
  was not there — every `[automation]` key was silently dead — and wrote a second,
  tracked `error_log.txt`.
- The updater compared versions by **equality**, so any difference read as "update
  available", including an older remote. It compares order now; a pre-release no longer
  offers to downgrade itself to the last release.

### Known unverified

Detector geometry (`TabOrigin`/`TabPitch`) is measured Infloww at one zoom level.
`tools/detector_probe.ahk` prints what your strip actually contains.

## Unreleased

### Breaking

- **The `[aliw]` and `[temp]` hotkey sections are gone.** Seven messages in
  `acc/ALIW.ahk` were written as *functions* — `AliwIntro()`, `AliwWhatLoved()` and friends —
  each bound to an alt-key through `hotkeys.ini`. A canned message had been turned into a
  named, resident piece of code: invisible to the Hotstrings manager (which indexes
  `:trigger::` blocks, not functions), so it could not be searched, edited or overloaded,
  while every other message in the same file was plain data.

  They are hotstrings now, with the text unchanged:

  | was | now |
  |---|---|
  | `!I` `AliwIntro()` | `..intro` |
  | `!e` `AliwLoved()` | `..loved` |
  | `!F1` `AliwGlimpse()` | `..glimpse` |
  | `!L` `AliwWhatLoved()` | `..whatloved` |
  | `!F2` `AliwAscend()` | `..ascend` |
  | `!9` `AliwOpenThat()` | `..openthat` |
  | `!8` `AliwInfiniteLust()` | `..infinitelust` |

  (`..openthat`, not `_OPENTHAT` — `general.ahk` already owns that trigger, with a different
  message.) All seven now show up in the Hotstrings manager; the library went from 103
  indexed messages to 110. `temp.fantasy` went with them: it was declared in `hotkeys.ahk`
  and offered in the Hotkeys window, but `acc/TEMP.ahk` never bound it, so the key did
  nothing.

  `acc/TEMP.ahk` had the same thing spelled a third way: a bare `!1::` written straight into
  the file. Not data, and not declared in `hotkeys.ini` either — the one shape that escapes
  both. It is `Fu1` now, beside the `Fu2` under it.

  Only keys that **run something** — open a chat, type an amount, drive the mouse — belong
  in `hotkeys.ini`. The message library is at 111 indexed messages, and no trigger is
  shadowed by a shorter one (a `:*:` trigger fires the moment it is typed, so `..fu` would
  make `..fu1` unreachable — checked, none are).

### Bug fixes

- **The Settings window overlapped itself.** Rows were placed with hand-counted offsets
  (`y + 126`, `_sy + 102`), which held only while every label happened to fit on one line.
  Two of them had outgrown their width, wrapped onto a second line, and printed over the row
  beneath them and over the button strip. Rows are placed with a running cursor now, so a row
  that needs more height simply takes it. The per-script checkbox rows also wrap at the window
  width instead of marching off the edge once you have six acc scripts, and the status lights
  have their own column that the labels stop short of.

- **The Hotkeys window cut its buttons in half.** Two sets of hand-counted offsets that
  had to agree and didn't: the static layout put the button row at `LV_H+48` with the status
  line 38px below it, while `OnSize` put the buttons at `h-40` and the status at `h-22` —
  *inside* the button row. A Text control paints its background, so the status line erased
  the bottom 12px of all seven buttons. It looked right only until the first `WM_SIZE`, which
  arrives the moment the window is shown, so nobody ever saw the correct version. Laid out
  from the floor upwards in one place now.

  Two more in the same window: `AutoHdr` on all five columns overflowed the list and left a
  horizontal scrollbar hiding the Conflict column — four columns are fixed and Conflict takes
  the remainder, so widening the window widens the one column with variable-length text. And
  there was no `MinSize`, while the left button group ends at x548 and Save/Close are placed
  from the right edge, so under ~780px wide they walked into each other.

- **Resizing.** Three separate faults:
  - ~60 controls moved on every `WM_SIZE` with no redraw batching, so dragging an edge tore
    the window. Drawing is suppressed for the batch and the window repaints once.
  - The bottom button strip was positioned at fixed x, up to `TAB_X+745`. On any window
    narrower than ~1300px, "Alt FUs…" and "Branches…" slid underneath the paste panel. The
    strip now reflows: laid left to right, wrapped to the left panel's current width, and
    hidden controls are skipped so a switched-off feature closes the gap rather than leaving
    a hole.
  - The 66/34 split gave the right panel a couple of hundred pixels on a narrow window, for a
    column of 460px-wide rows — "Export !mma" and "Load from archive" ran off the edge. The
    split is now proportional only until a side would be squeezed below what its controls
    measure. `MinSize` was 750x500, which was wishful; it is 900x640, derived from those
    measurements.
  - The paste box kept a flat 52% of the height, pushing the massNo radios past the bottom
    edge on anything under ~650px tall. It is capped to what is left above the button stack.

### Removed

- **Report Bug.** The button opened a pre-filled GitHub issue.

## 1.9.2 — 2026-07-26

### Bug fixes

- **Hotkey capture ended on the modifier** — the Hotkeys window set every key as an
  InputHook end key (`KeyOpt("{All}", "E")`), modifiers included. Pressing Ctrl therefore
  finished the capture immediately with `EndKey = "LControl"`, while `Mods()` also saw Ctrl
  held — recording the chord as `^LControl`. The only way to enter a real chord was to hit
  both keys in the same instant, so it usually took several attempts.

  The eight modifier keys are now excluded from the end-key set, giving the behaviour every
  other application has: hold the modifiers and the capture waits for an actual key. The
  overlay also shows the chord as it builds ("Ctrl+Alt+…"), so holding a modifier visibly
  does something.

  The held modifiers are now read in `InputHook.OnEnd`, at the instant the end key arrives,
  rather than after the capture loop exits — releasing Ctrl a few milliseconds after F1 used
  to record plain `F1`.

## 1.9.1 — 2026-07-26

### Features

- **Easy vs Advanced mode** — Easy is MMA as it stood at **v1.4.0**, the last version
  before britishizer and the feature run after it: paste, Parse, Clear, Export, per-file
  load/save/massNo, the model tabs, the script toggles, and a Settings window with model
  count, Add Hotkey, How to Use, New Script, Wipe Temp, Report Bug and Check Update.
  Nothing else. For scale: v1.4.0 was 2,167 lines across 10 files; today is 11,599 across 33.

  Easy switches the extras **off**, it does not hide them. A hidden feature still
  interferes — the model detector quietly gating a model's send keys off (see below) is
  exactly the surprise this removes. In Easy, 52 hotkeys register; in Advanced, 92.

  Alt follow-ups, `--Name` branches, the archive, the hotstrings manager, the actions and
  quick-action menus, the recorder, the capitalizer, sequences/Discord import, editable
  follow-ups, open-in-new-tab, double-MM, the stats overlay, the model detector, the
  automation listener and the pinger are all Advanced-only.

- **A toggle for every optional feature** — new `modes.ahk` registry: one `FEAT_Def` line
  per feature carries its cfg key, label and default. Each can be switched off
  individually inside Advanced, and Easy switches all of them off **without touching those
  choices** — flip back and every checkbox is where you left it. Existing cfg keys are
  reused verbatim, so upgrading loses no settings. Settings gains a **Mode…** button;
  that window is generated from the registry, so new features appear in it automatically.

  Mode defaults to **Advanced** — an existing install has a workflow built on these
  features, and demoting it on upgrade would look like MMA had lost half of itself.

- **`install.bat`** — installs AutoHotkey v2 via winget (with `--no-upgrade`, so an
  existing install is never silently moved), optionally installs Python plus `numpy`,
  `pillow` and `opencv-python`, and creates the desktop shortcut. Detection asks the tools
  themselves rather than `winget list`, which only knows what winget installed.

### Bug fixes

- **The model detector read whatever was on screen** — `WinMatch` defaulted to empty,
  which disabled the foreground check entirely. The scan looks at a fixed screen
  *rectangle*, not a window, so it published other applications' titles as the active
  model. Because `ModelIsActive()` auto-claims the first unnamed `[ActiveMap]` slot, a
  junk reading could be captured permanently, after which that model's name never matched
  and **every one of its send keys was held off** — with nothing wrong in the model file
  or the hotkey registry. Now defaults to `Infloww Messages`, the same window
  `automation.py` gates on. Existing installs must also clear the poisoned `[ActiveMap]`
  entry; a code default cannot reach it.

- **MMA now runs cleanly with no Python** — only two optional features need it, but
  `AutomationListener` defaults on and its launcher ended in an unguarded `shell.Run`, so
  a machine without Python got a WScript error dialog on **every startup**. Both launcher
  `.vbs` files now resolve a real interpreter and exit quietly when there is none, and
  `PythonAvailable()` stops MMA spawning them at all. Switching a Python feature on by
  hand now explains itself instead of appearing to do nothing.

- **Python launchers picked the Microsoft Store stub** — `where` lists the zero-byte
  WindowsApps App Execution Alias *before* the real interpreter, so reading one line either
  opened the Store or wrongly concluded there was no Python. Both files now scan every
  match and take the first with a non-zero size. This also fixes a **duplicate automation
  listener**: one started through the stub could not see the real one's single-instance
  mutex across the Store's virtualised namespace, so `^!u` unsent twice.

## 1.9.0 — 2026-07-26

Structural release. No new features; the point is that a model file is now data,
the shared behaviour has one definition, and the Python listener is in the repo.

### Bug fixes

- **Settings did nothing for models 2 and 3** — `EditableFu1/2/3`, `WalletCheckFu3`,
  `OpenTabFu2/3` and `OpenTabPpv` existed only in `1_mass.ahk`. The Settings window
  broadcast every toggle to all three model scripts (`_BroadcastEditableFu`), but 2 and 3
  had no handler and passed a hard-coded `false` instead, so the checkboxes moved and
  nothing happened. All models now share one implementation and honour all of them.
  **If `OpenTabFu2` is on, models 2 and 3 will start opening a new tab after follow-up 2 —
  that is the fix, not a regression.**
- **Ctrl+follow-up was ungated on models 2 and 3** — their `DoAltFu*` skipped the
  `FuGate()` check that model 1 ran, so the key could fire while another model was active.
- **Regenerating a model file deleted its branches** — `BuildMassTemplate` emitted its own
  copy of `DoFu1/2/3` and `DoPpv` but never the alt or branch functions, so rebuilding a
  model silently dropped `--Name` branch support and the Settings-aware follow-ups. It now
  emits data plus one `MassInit()` call, identical in shape to a hand-written model file.
- **PPV pasted a stale clipboard** — `DoPpv` with an empty `ppv_base` cleared the clipboard,
  timed out on `ClipWait`, then pasted whatever was there before. It now returns early.

### Internal

- **`automation.py` is in version control** — the 1,705-line listener that serves the
  `[automation]` hotkeys lived in the gitignored `infloww ui elements/` folder, so a fresh
  clone produced a silently half-working install. Moved to `automation/` and tracked, with
  its launcher and UI map. Only the screenshots and detector prototypes stay ignored.
- **New `mass_runtime.ahk`** — every model's behaviour, once. `1_mass.ahk` 481→225 lines,
  `2_mass.ahk` 336→170, `3_mass.ahk` 331→170; message content untouched.
- **`mass_gui.ahk` split 2,971→1,757 lines** — `archive.ahk` (the archive file format, its
  readers and its window), `mass_parser.ahk` (the mass text format and its escaping) and
  `processes.ahk` (launching, stopping and watching the five child processes).

## 2026-07-20

### Features

- **Delete in the Mass Archive** — New **Delete** button in the archive viewer (`OpenArchive`, `mass_gui.ahk`). Confirms with the timestamp, model and message text first, then rewrites `mass_archive.txt` without that entry via a temp-file swap. The rewrite re-reads the file rather than dumping the viewer's in-memory list, so masses archived while the window sat open are not silently lost. Selection keeps its place across a delete instead of jumping back to the top.

- **Delete in the Hotstrings manager** — New **Delete** button in `hotstrings_gui.ahk`, backed by `HSI_DeleteBlock` in `hotstring_index.ahk`. This is the **only** path in MMA that writes to a message `.ahk` file, so it: re-derives the block's line span from the file (never trusts the index snapshot), refuses if the trigger on that line no longer matches, copies the file to `<name>.ahk.bak` first, and preserves the file's existing BOM and line endings. Also drops the trigger's overload entry — left behind, it would keep firing for a hotstring whose source is gone. The owning script must be restarted for the deletion to take effect.

- **Larger text in both windows** — Archive viewer and Hotstrings manager bumped roughly one step throughout (titles 14→15, search 11→12, lists 10→11, buttons 9→10), with control heights and resize math adjusted to match. The Hotstrings manager's own "Text size" control still governs the showcase pane independently.

- **Louder pinger alert** — `pinger.pyw` no longer uses the `SystemExclamation` alias, which plays at the Windows *System Sounds* mixer level (separate from master volume, easy to leave low, and unreachable from the script). It now synthesises a two-tone 880/1320 Hz square-wave beep at full scale and plays it on its own channel, tunable via `ALERT_VOLUME` / `ALERT_TONES` / `ALERT_BEEP_MS`. New `--test-sound` flag plays it once for tuning.

## 2026-06-22

### Features

- **ACC script visibility** — Settings now has a "Visible scripts" row with a checkbox per `/acc` file. Unchecked scripts are hidden from the main GUI toggle bar. Hidden list stored as `HiddenScripts` in `[Settings]` cfg.

- **Double MM moved to Settings** — Removed from the main toggle bar. Now a live-toggle checkbox in the Settings window (same instant WM-message behavior as before). MButton hotkey still works.

- **Wallet check FU3** — New Settings toggle. When on, F3/Ctrl+MButton pastes the combined fu3+fu3_5+fu3_7 as one clipboard paste **without sending Enter**, so the text lands in the input box for review/edit before manual send. Live-toggled via WM message (0x8002) — no reload needed.

- **Editable FU toggles (F1/F2/F3)** — New "Ed" header row above the FuSingle M×F grid. Each checkbox makes that FU paste its combined parts without Enter, same logic as wallet check. Live-toggled via WM messages 0x8003–0x8005. Shared `SndFuEditable()` helper in `1_mass.ahk`.

- **Alt+0 custom-timing send** — Checkbox + numeric ms field added to the right panel ("Apply to file" row). When enabled, Alt+0 pastes the current clipboard and presses Enter, sleeping the exact ms typed in the field instead of the global `waitTime`.

### Bug fixes

- **PPV escape char insertion** — Refactored edCtrls to always store **raw** (unescaped) values. EscQ is now applied once, only in `BuildBlock`, when writing to the `.ahk` file. Previously, PPV fields typed directly into the GUI were written without escaping `"`, `` ` ``, and `;`, producing broken AHK syntax. `LoadFile` now applies `UnescQ` when reading back escaped strings from file so edCtrls stays raw.
