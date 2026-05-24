# MMA — Mass Message Automation

AHK v2 GUI for managing message templates and sending them instantly via hotkeys.

## Requirements

- [AutoHotkey v2](https://www.autohotkey.com/)

## Installation

1. Download and extract the repo
2. Run `createShortcut.bat` to create a desktop shortcut
3. Launch `mass_gui.ahk`

## Features

- **Parse** — paste a mass message block and auto-fill all slots (opener, follow-ups, PPV)
- **Hotkeys** — F1–F5 / F9–F12 send follow-up sequences instantly via clipboard paste
- **Two model slots** — manage two separate accounts with independent hotkey sets
- **Script toggles** — enable/disable per-account scripts from the main window
- **Add Hotkey** — append new hotstrings to any script without opening the file
- **Auto-updater** — checks for updates silently on startup, installs via a separate updater process

## Paste format

```
your opener / mass

f1 first follow-up line
f1.5 optional second line

f2 second follow-up
f2.5 optional second line

f3 third follow-up

ppv your ppv caption

ppvfu1 first ppv follow-up
ppvfu2 second
ppvfu3 third
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
| Report Bug | Opens a pre-filled GitHub issue |
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
