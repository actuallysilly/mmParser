# Changelog

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

  Only keys that **run something** — open a chat, type an amount, drive the mouse — belong
  in `hotkeys.ini`.

### Bug fixes

- **The Settings window overlapped itself.** Rows were placed with hand-counted offsets
  (`y + 126`, `_sy + 102`), which held only while every label happened to fit on one line.
  Two of them had outgrown their width, wrapped onto a second line, and printed over the row
  beneath them and over the button strip. Rows are placed with a running cursor now, so a row
  that needs more height simply takes it. The per-script checkbox rows also wrap at the window
  width instead of marching off the edge once you have six acc scripts, and the status lights
  have their own column that the labels stop short of.

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
