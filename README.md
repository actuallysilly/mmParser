# MMA — Mass Message Automation

AHK v2 GUI for writing mass messages once and sending them on a key.

## Install

Download **[MMA-Setup.exe](https://github.com/actuallysilly/mmParser/releases/latest)** and run it.

The exe is only a wizard — it pulls the current code from `main` while it runs, so it never
goes stale no matter which release you grabbed it from. It installs AutoHotkey v2 if you
haven't got it, asks whether you want the optional Python features, and makes a desktop
shortcut.

From a clone instead, run `install.bat` — same wizard, same questions:

```
install.bat                 interactive
install.bat -WithPython     assume yes to the Python features
install.bat -NoPython       assume no
```

**AutoHotkey v2 is the only hard requirement.** Python is optional and buys you four
background services: the automation listener (hop kebabs, unsend last, count sales, on by
default), the pinger (beeps when a fan tab goes unread), typelog (records what you type so it
can be mined for hotstrings — off, deliberately, it keeps the text) and autoword (next-word
suggestions trained on that corpus). Say no and MMA runs fine; you just lose those four. It
checks at startup and says so in the log instead of popping a dialog at you every launch.

Everything else is pure AutoHotkey, the OCR included — `src/vendor/OCR.ahk` drives the engine
already in Windows, so model detection and the stats overlay need nothing installed.

## What it does

- **Parse** — paste a mass block, it fills every slot: opener, follow-ups, PPV
- **Hotkeys** — F1–F5 and F9–F12 send the follow-ups, pasted through the clipboard
- **3 to 12 model slots** — separate keys per account, plus one shared set that follows
  whichever model is on screen
- **Chat simulator** (`Ctrl+Alt+C`) — your mass as the conversation it actually becomes.
  Type the next message into the composer and it lands in the next empty slot. Write his
  replies in between so you're writing f2 against something
- **Hotstrings quick menu** (`Ctrl+Alt+H`) — pinned and recently-used hotstrings at the
  cursor. Click to send, 1–9 for the first nine, shift-click to pin
- **Hotstrings manager** — search 137 triggers by name or by the words inside them, and edit
  any of it in the window. Every write takes a `.bak` first
- **Add Hotkey** — append a hotstring to any script without opening the file
- **Script toggles** — turn per-account scripts on and off from the main window
- **Updater** — the startup check is off by default; it prompts in front of whatever you were
  doing, on somebody else's schedule. **Settings ▸ Models ▸ Check for updates** works anyway

## Paste format

```
Same as from the Discord!
just copy paste and it works!
```

`!mm` / `!mma` on the opener is optional — without it the first line is the opener. Every
follow-up slot is optional, and a blank line separates groups.

## Settings

One window, eight tabs: **General** (wait times, reply timers, default FU3), **Models**
(names, count, how the active model is decided), **Sending** (follow-up behaviour, PPV keys,
the branch picker), **Features** (Easy vs Advanced, and every optional feature's on/off box),
**Scripts** (what auto-starts, the watchdog), **Hotkeys** (rebind everything), **GUI** (theme,
and whether a window is drawn by Edge or Win32), **Debug** (logging, probes, self-tests).

Features is the only tab that *offers* an on/off box — the rest show a feature's state
read-only and point back at it, so no key has a checkbox in two places.

## Layout

```
MMA.ahk        the one thing you double-click
src/           code. not yours to edit.
content/       YOUR HOTSTRINGS. hand-written AHK, nothing generated.
userdata/      every setting, message and log. gitignored.
tools/         dev rigs, the installer, the test scripts
docs/          the paste format, the decisions, the dev guide
```

Drop new per-account scripts into `content/accounts/` — they're picked up automatically,
there's no list to update.

**Every path resolves from one anchor**, `src/core/paths.ahk`. Nothing else hard-codes a
folder. [ARCHITECTURE.md](ARCHITECTURE.md) says what each file does;
[docs/decisions.md](docs/decisions.md) says why.
