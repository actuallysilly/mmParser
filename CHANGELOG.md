# Changelog

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
