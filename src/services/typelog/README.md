# typelog

Records the messages you **send** in Infloww Messages, one per line, scoped to
Infloww. Mined for hotstrings, and the training data for autoword.

Was its own project (`Chatting/typelog`); moved in here as an MMA background
service, driven the same way as the pinger and the automation listener.

## What it records, and where

- **Only while Infloww is the foreground window** — matched by process name
  (`infloww.exe`), with the window title (`infloww`) as a fallback. It records
  nothing while you are in your bank, a password manager, DMs, or anywhere else.
- Messages land in **`userdata\typelog\messages\`**, one file per day.
  `userdata\` is gitignored, so the logs never leave the machine.

| file | holds |
|---|---|
| `YYYY-MM-DD.log` | messages whose text is exact: `time <tab> kind <tab> text` |
| `YYYY-MM-DD.uncertain.log` | messages it cannot vouch for: `time <tab> kind <tab> reasons <tab> text` |

`kind` is `typed`, `pasted` or `mixed`. Hotstrings and masses send by pasting
(`Snd()` is Ctrl+V then Enter), so they show up as `pasted`. A line break inside
a message (Shift+Enter) is written as `\n`, a tab as `\t`, a backslash as `\\`.

## Only what was sent

Keystrokes edit a model of the message box (`message.py`), held in memory.
**Nothing is written until a plain Enter sends it**, so a draft you delete, a
half-word you retype, or a message you abandon never reaches the log.

| key | effect |
|---|---|
| Enter | sends: the message is written, the box starts over |
| Shift+Enter | a line break inside the message, never a send |
| Backspace / Ctrl+Backspace | deletes a character / the last word |
| Ctrl+A, then Backspace, Delete, Ctrl+X, typing or a paste | replaces everything, which also makes an uncertain box exact again |
| Ctrl+V, Shift+Insert | the clipboard's text is read and added |
| Tab, Esc, Ctrl+C, F-keys, Alt+letter | nothing |

The model only holds while the caret stays at the end of the text, where it is
when you just type. These make a message **uncertain** (the reason is written
with it): an arrow/Home/PageUp or a mouse click with text in the box (`caret`), a
Shift+arrow selection (`select`), Ctrl+Z/Y (`undo`), Win+V (`win+v`), the Win+.
emoji panel (`emoji`), Ctrl+Backspace across punctuation (`ctrl+bs`), Ctrl/Alt+Enter
(`mod+enter`), a clipboard with no text (`paste?`), and the first message after
starting or resuming (`start`), because the box may already have held a draft.

Leaving Infloww does not end a message: the draft stays in Infloww's box, so
typing on after Alt+Tab continues it.

**Known limits.** An Enter that Infloww does not act on, for example while a popup
is open, still counts as a send. Text typed into other Infloww fields (search, a
PPV price box) and sent with Enter looks like a message. Only reading the box
itself (UI Automation) would fix both.

## The old logs

`userdata\typelog\*.log` and `D:\Software\Dev\Chatting\typelog\logs\` hold the
previous format: a raw keystroke dump written every five seconds, with
abandoned drafts run into the sent text. They are left where they are, as raw
data, and the new recorder never writes there.

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
    python typelog.pyw --stop     ask it to exit (an unsent draft is dropped)
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
