# MMA — Mass Message Automation

AHK v2 GUI for managing message templates and sending them instantly via hotkeys.

## Requirements

- **[AutoHotkey v2](https://www.autohotkey.com/)** — required, and the only hard requirement.
- **Python 3.9+** — *optional*, and only for two things:
  - `automation/automation.py`, which serves the `[automation]` hotkeys (hop kebabs,
    unsend last, count sales). Needs `numpy`; count-sales also needs `pillow`.
  - `pinger/pinger.pyw`, which beeps when a fan tab goes unread. Needs `numpy` and
    `opencv-python`.

Everything else is pure AutoHotkey — masses, follow-ups, alts, branches, PPV, the GUI,
the archive, the parser, the hotkey registry, and even the OCR: `lib/OCR.ahk` drives the
OCR engine already built into Windows, so model detection and the stats overlay need
nothing installed. **Without Python, MMA runs fine; you just lose those two features.**

## Installation

Run **`install.bat`**. It:

1. installs AutoHotkey v2 via `winget` if it is missing — existing installs are left
   alone, never silently upgraded;
2. asks whether you want the optional Python features, and installs Python plus
   `numpy`, `pillow` and `opencv-python` if you say yes;
3. **if you say no, switches those features off in `mass_gui.cfg`** so MMA does not try
   to start a Python it hasn't got;
4. creates a desktop shortcut.

```
install.bat                 interactive
install.bat -WithPython     assume yes to the optional Python features
install.bat -NoPython       assume no
```

Prefer to do it by hand? Install AutoHotkey v2, run `createShortcut.bat`, and launch
`mass_gui.ahk`. If you have no Python, turn **Automation listener** off in Settings.

## Features

- **Parse** — paste a mass message block and auto-fill all slots (opener, follow-ups, PPV)
- **Hotkeys** — F1–F5 / F9–F12 send follow-up sequences instantly via clipboard paste
- **Two model slots** — manage two separate accounts with independent hotkey sets
- **Script toggles** — enable/disable per-account scripts from the main window
- **Add Hotkey** — append new hotstrings to any script without opening the file
- **Auto-updater** — checks for updates silently on startup, installs via a separate updater process

## Paste format

```
Same as from the Discord! 
just copy paste and it works!
```

- `!mm` / `!mma` prefix on the opener is optional — if missing, the first line is used
- All follow-up slots are optional; separate groups with a blank line
- Prefix labels (`f1`, `f2.5`, etc.) are optional in positional mode

## Settings

Open via the **Settings** button:

| Option | Description |
|---|---|
| Model 1 / 2 | Display names for each account |
| Hotkeys | Remap F-key bindings per model |
| Wipe Temp | Clear `acc/TEMP.ahk` and reload it |
| Check Update | Manually trigger the updater |

## File structure

```
mass_gui.ahk      — main GUI
1_mass.ahk        — model 1 messages + hotkeys
2_mass.ahk        — model 2 messages + hotkeys
general.ahk       — always-on shared hotstrings
utils.ahk         — shared helpers (snd, afk, etc.)
updater.ahk       — handles downloading updates
acc/              — per-account script files
mass_gui.cfg      — saved settings (not synced)
```

> Do not change the folder structure. Add new per-account scripts inside `/acc`.
