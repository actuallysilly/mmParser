# MMA — Mass Message Automation

AHK v2 GUI for managing message templates and sending them instantly via hotkeys.

## Requirements

- **[AutoHotkey v2](https://www.autohotkey.com/)** — required, and the only hard requirement.
- **Python 3.9+** — *optional*, and only for the four background services:
  - `src/services/automation/automation.py`, which serves the `[automation]` hotkeys (hop kebabs,
    unsend last, count sales). Needs `numpy`; count-sales also needs `pillow`. **On by default.**
  - `src/services/pinger/pinger.pyw`, which beeps when a fan tab goes unread. Needs `numpy` and
    `opencv-python`. Off by default.
  - `src/services/typelog/typelog.pyw`, which records what you type in Infloww so it can be mined
    for hotstrings. Needs `pynput`. **Off by default, and deliberately so** — it keeps the text.
  - `src/services/autoword/autoword.pyw`, next-word suggestions trained on that corpus, plus
    Ctrl+Tab to reword. Needs `pynput` 1.8+. Off by default, and ships drawing nothing until
    `userdata/autoword.ini` says otherwise.

The packages themselves are declared once, in
[`requirements.txt`](requirements.txt) at the root, which pulls in each service's own —
so both installers ask for the same thing and cannot drift apart.

Everything else is pure AutoHotkey — masses, follow-ups, alts, branches, PPV, the GUI,
the archive, the parser, the hotkey registry, and even the OCR: `src/vendor/OCR.ahk` drives the
OCR engine already built into Windows, so model detection and the stats overlay need
nothing installed. **Without Python, MMA runs fine; you just lose those four.** MMA checks for an interpreter at
startup and says so in the log rather than popping a dialog at you every launch.

## Installation

Run **`install.bat`**. It:

1. installs AutoHotkey v2 via `winget` if it is missing — existing installs are left
   alone, never silently upgraded;
2. asks whether you want the optional Python features, and if you say yes installs
   Python and then `pip install -r requirements.txt` — the one list, which pulls in
   each service's own `requirements.txt`;
3. **if you say no, switches those features off in `userdata/mass_gui.cfg`** so MMA does not try
   to start a Python it hasn't got;
4. creates a desktop shortcut.

```
install.bat                 interactive
install.bat -WithPython     assume yes to the optional Python features
install.bat -NoPython       assume no
```

Prefer to do it by hand? Install AutoHotkey v2, run `tools/install/createShortcut.bat`, and launch
`MMA.ahk`. If you have no Python, turn **Automation listener** off in Settings.

## Features

- **Parse** — paste a mass message block and auto-fill all slots (opener, follow-ups, PPV)
- **Hotkeys** — F1–F5 / F9–F12 send follow-up sequences instantly via clipboard paste
- **Three to twelve model slots** — independent hotkey sets per account (F1-F3 model 1,
  F9-F11 model 2), plus one shared set that follows whichever model is on screen. Three is the
  floor and twelve the ceiling; set the count in **Settings ▸ Models**
- **Script toggles** — enable/disable per-account scripts from the main window
- **Add Hotkey** — append new hotstrings to any script without opening the file
- **Chat simulator** — **Ctrl+Alt+C** opens your mass as the conversation it
  actually becomes: a mock chat where your messages are the bubbles, you type the
  next one into a composer at the bottom, and it lands in the next empty slot (opener → f1 → f2 → f3 → PPV). Edit any bubble in place. Write his replies in
  between so you are writing f2 against something. It shows what the boxes cannot:
  how many messages this really is, which ones PASTE rather than send, where the
  `DefaultFu3` fallback kicks in, and what a branch changes
- **Hotstrings quick menu** — **Ctrl+Alt+H** pops up your pinned and recently-used
  hotstrings at the cursor. Click one to send it, 1-9 for the first nine, shift-click to
  pin or unpin. Pins stay whatever the recency; the rest is what you last reached for
- **Hotstrings manager** — search 130+ triggers by name *or* by the words inside them,
  and **edit any of it in the window**: the trigger, `::` vs `:*:`, the message, how each
  line is sent, and which file it lives in. Also gives one a key, turns one into an
  overload (several wordings, one fires), or deletes it — every write takes a `.bak` first
- **Auto-updater** — installs via a separate updater process, so it can overwrite the GUI.
  The *startup* check is **off by default**: it prompts in front of whatever you were doing, on
  somebody else's release schedule. **Settings ▸ Models ▸ Check for updates** works regardless

## Paste format

```
Same as from the Discord! 
just copy paste and it works!
```

- `!mm` / `!mma` prefix on the opener is optional — if missing, the first line is used
- All follow-up slots are optional; separate groups with a blank line
- Prefix labels (`f1`, `f2.5`, etc.) are optional in positional mode

## Settings

Open via the **Settings** button. One window, eight tabs:

| Tab | What lives there |
|---|---|
| General | Wait times, reply timers, the default FU3 text, Wipe Temp |
| Models | Model names and count, how the active model is decided, Check for updates |
| Sending | Follow-up behaviour, PPV keys, the branch/alt picker |
| Features | **Easy vs Advanced, and every optional feature's on/off box** |
| Scripts | Which message scripts auto-start, and the restart watchdog |
| Hotkeys | Rebind every key in MMA |
| GUI | Theme, and whether each window is drawn by Edge or by Win32 |
| Debug | Logging switches, the probes, the self-tests, the diagnostic report |

**Features is the only tab that offers a feature's on/off box.** The others show a
feature's state read-only and point back at it — no key has a checkbox in two places.

## File structure

```
MMA.ahk        — the one thing you double-click
src/           — code. not yours to edit.
  core/          paths, the hotkey / feature / message / service registries, utils,
                 the logger, and the subprocess supervisor
  ui/            every window: main, settings, hotkeys, hotstrings, actions, tools
  mass/          the mass engine, its runtime, the parser, the archive, and
                 shape.ahk — what a mass sends, shared by the engine and the
                 chat simulator so the two cannot disagree
  chat/          Infloww navigation keys
  hotstrings/    the message index, the overload registry, the pinned/recent
                 store and the quick menu
  screen/        anything that reads pixels: OCR grab, the two detectors, overlays
  sequences/     recorded click/type macros, and the recorder
  activity/      the typing-stats recorder and the format it writes
  branch/        the conversation tree, and the compiler behind the branch builder
  services/      the four optional Python background services, plus llm/
  vendor/        third party (OCR.ahk, WebView2, json.ahk)
  autoword/      clean.py — the corpus prototype services/autoword grew out of
content/       — YOUR HOTSTRINGS. hand-written AHK, nothing generated.
  general.ahk    always-on shared hotstrings
  accounts/      per-account hotstring files
userdata/      — every setting, message and log. gitignored.
  masses.json    your masses — written by the GUI, read by the engine
tools/         — dev rigs, the installer, UI research
docs/          — the paste format and design notes
```

Add new per-account scripts inside `content/accounts/` — they are picked up
automatically; there is no list to update.

**Every path resolves from one anchor**, `src/core/paths.ahk`. Nothing else in the
repo hard-codes a folder, so moving a file means editing that one file. See
[ARCHITECTURE.md](ARCHITECTURE.md) for what each file does and why the tree is
shaped this way.
