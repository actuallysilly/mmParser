# typelog

A passive keystroke-to-text recorder, **scoped to Infloww**. It reconstructs the
text you type in Infloww Messages into readable lines and appends it to a daily
log, so you can later mine your own repetitive phrases and turn them into
hotstrings — the same job the Hotstrings manager does from the other end.

Was its own project (`Chatting/typelog`); moved in here as an MMA background
service, driven the same way as the pinger and the automation listener.

## What it records, and where

- **Only while Infloww is the foreground window** — matched by process name
  (`infloww.exe`), with the window title (`infloww`) as a fallback. It records
  nothing while you are in your bank, a password manager, DMs, or anywhere else.
- Text lands in **`userdata\typelog\YYYY-MM-DD.log`** — one file per day, rolled
  over at midnight. `userdata\` is gitignored, so the logs never leave the machine.
- Backspace deletes the last character in the buffer, Enter/Tab/Space are kept,
  and control chars from shortcuts (Ctrl+C, etc.) are dropped.

## Why it is OFF by default

This is the **one** MMA tool that records *what* you type, not just that you
typed — the activity tracker (`src/activity/`) was deliberately built so it
structurally cannot, and this is built to. Within Infloww that includes fan
handles and message text. So it ships off and must be switched on deliberately
(Settings ▸ Features, or the Tools window), for a stronger version of the same
consent reason the activity tracker is off.

**Pause it** — the `[typelog] pause` hotkey (default `Ctrl+Alt+F9`) — before
typing anything you would not want written down, and delete old logs once you
have mined them.

## Running it

MMA drives it: **Settings ▸ Features ▸ Typelog** and the **Tools** window both
toggle it with a live running state, reading the same named stop-event the
process holds so they stay honest if it dies.

By hand:

    typelog_start.vbs          start silently (pythonw, no console)
    python typelog.pyw --stop     ask it to exit (flushes first)
    python typelog.pyw --status   is one running?
    python scope_debug.py         print what the scope check sees (records nothing)

Headless (via the .vbs) its operational lines — started, pauses, errors — go to
MMA's `debuglogs\error_log.txt`, tagged `[typelog]`. The recorded text never goes
there; that is `userdata\typelog\` only.

## The pause hotkey lives in the one ini

Like every MMA key, the pause hotkey is in `userdata\hotkeys.ini` under
`[typelog]` and is edited in the Hotkeys GUI. It is **bound here (pynput), not by
AHK** — same arrangement as `[automation]`: declared in `hotkeys.ahk` so the GUI
can list and conflict-check it, read and acted on by this process. `typelog.pyw`
converts the AHK key string (`^!F9`) into pynput's format (`<ctrl>+<alt>+<f9>`).
Blank = disabled, the same convention as everywhere else.

## Dependency

One package: `pynput` (global keyboard capture). The scope check and the
stop-event use ctypes from the standard library. `install.bat` with Python
installs it alongside the pinger/automation packages; by hand it is
`pip install -r requirements.txt`.
