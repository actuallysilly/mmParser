# Changelog

## 2026-06-22

### Features

- **ACC script visibility** — Settings now has a "Visible scripts" row with a checkbox per `/acc` file. Unchecked scripts are hidden from the main GUI toggle bar. Hidden list stored as `HiddenScripts` in `[Settings]` cfg.

- **Double MM moved to Settings** — Removed from the main toggle bar. Now a live-toggle checkbox in the Settings window (same instant WM-message behavior as before). MButton hotkey still works.

- **Wallet check FU3** — New Settings toggle. When on, F3/Ctrl+MButton pastes the combined fu3+fu3_5+fu3_7 as one clipboard paste **without sending Enter**, so the text lands in the input box for review/edit before manual send. Live-toggled via WM message (0x8002) — no reload needed.

- **Editable FU toggles (F1/F2/F3)** — New "Ed" header row above the FuSingle M×F grid. Each checkbox makes that FU paste its combined parts without Enter, same logic as wallet check. Live-toggled via WM messages 0x8003–0x8005. Shared `SndFuEditable()` helper in `1_mass.ahk`.

- **Alt+0 custom-timing send** — Checkbox + numeric ms field added to the right panel ("Apply to file" row). When enabled, Alt+0 pastes the current clipboard and presses Enter, sleeping the exact ms typed in the field instead of the global `waitTime`.

### Bug fixes

- **PPV escape char insertion** — Refactored edCtrls to always store **raw** (unescaped) values. EscQ is now applied once, only in `BuildBlock`, when writing to the `.ahk` file. Previously, PPV fields typed directly into the GUI were written without escaping `"`, `` ` ``, and `;`, producing broken AHK syntax. `LoadFile` now applies `UnescQ` when reading back escaped strings from file so edCtrls stays raw.
