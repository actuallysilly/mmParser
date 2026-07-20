# MMA portable — Windows + macOS

The three-follow-up send flow, one codebase, both machines. Press a key, paste a
message, press Enter, pause, repeat for each part of the follow-up. Bound to
**Ctrl+1/2/3** here rather than the original's F1/F2/F3 — see below for why.

This is a port of one function. The Windows original is `Snd()` in
[`../utils.ahk`](../utils.ahk), all eight lines of it — everything else in MMA's
9,800 lines is scaffolding around it, and none of that is here.

## Why Python and not Espanso

Espanso is a text *expander*: it fires when you **type a trigger string**, and
its model is "replace this text with that text". It has no first-class
hotkey→action binding and no way to express "paste, press Enter, wait 400ms,
paste again". The follow-up flow is three separate messages with pacing, which
is the one thing it cannot do.

Espanso would be an excellent fit for the **125 hotstrings** in `general.ahk` and
`acc/*.ahk` — those really are trigger→text expansions, and they'd port almost
mechanically. Different problem, worth doing separately.

## Status

| | Verified |
|---|---|
| Parser, engine, pacing, busy guard, app gate, single/edit, config | ✅ 136 tests |
| Save round-trips (`to_text` → `parse`) without drift | ✅ |
| GUI wiring, driven through the real widgets | ✅ |
| Windows clipboard (ascii, multiline, emoji, 5k chars) | ✅ round-tripped |
| Windows focused-window detection | ✅ reports `Infloww` |
| Windows keystroke delivery | ✅ 152 chars landed in a real focused window |
| Sending under a held modifier | ✅ fixed and verified (was: delivered nothing) |
| Delivery into **Infloww itself** | ❌ untested — pressing Enter there sends to a real person |
| **Everything macOS** | ❌ untested, no Mac available |

The logic is well covered, and keystrokes are now proven to land in a real
window. What is still unproven is Infloww specifically — that test can't be
automated, because a successful send is an irreversible message to a fan — and
all of the macOS half.

## Install

```sh
pip install pynput
```

That is the only dependency. The clipboard is done natively (ctypes on Windows,
`pbcopy` on macOS) rather than via `pyperclip`, so there's nothing else to
install on two machines.

### macOS only — do this or nothing works

**Accessibility.** `pynput` needs it to both *read* and *send* keys. Grant it to
whatever runs Python — if you launch from Terminal, it's **Terminal** that needs
the permission, not Python. System Settings → Privacy & Security →
Accessibility. It is read at startup, so quit and relaunch after granting it.

Windows needs nothing.

## Why Ctrl+1/2/3 and not F1/F2/F3

The Windows original sends on F1/F2/F3. This build deliberately does not, and it
is not a style choice — those keys are unavailable on *both* machines, for two
unrelated reasons:

- **Windows (the test box).** AutoHotkey and Python cannot share a key.
  `hotkeys.ini` binds `mass.1.fu1 = F1`, `fu2 = F2`, `fu3 = F3`, and while
  `1_mass.ahk` is running AHK registers those globally and *consumes* the
  keypress. Python's listener never sees it, so `mma.py` looks silently broken.
- **macOS (the target).** F1/F2 are brightness and F3 is Mission Control, so
  `pynput` receives a media key rather than `<f1>` unless you turn on System
  Settings → Keyboard → "Use F1, F2, etc. keys as standard function keys".

`Ctrl+1/2/3` clears both, and is claimed by no other MMA script. It also means
the AHK build and this one can run side by side on Windows without a fight.

**One caveat:** `pynput` does not *suppress* the key — it observes it, and the
press still reaches the focused app. Ctrl+1/2/3 is free in Infloww (a native
app, not a browser tab), but if you rebind, avoid combos the chat app itself
uses or you'll trigger both.

**The modifier has to be released before sending.** You cannot press Ctrl+1
without holding Ctrl, and it is still down when the send fires ~60ms later. A
send under a held Ctrl delivers **nothing at all** — measured into a real
focused window: 152 chars with no modifier held, 0 with Ctrl held. So `_send`
releases every modifier before each part. This is the one thing a modifier-based
hotkey needs that an F-key does not, and it is silent when it goes wrong: the
engine logs a perfectly normal send and the chat box stays empty.

To go back to F-keys anyway, edit `hotkeys` in `settings.json`. Startup
re-checks for running AHK scripts and warns loudly if you've picked a key it
owns, rather than leaving you with a dead key and no error.

## The GUI

```sh
python gui.py
```

Laid out like the original MMA panel: **Mass 1/2/3 tabs** down the left, each with
the `!mm` / `f1` / `f1.5` / `f1.7` / `f2` … / `ppv` / `ppvfu1-3` field column and
**single** + **edit** checkboxes beside each follow-up group. The paste block sits
on the right with **Parse / Clear / Export !mma**, above the **massNo** selector.

- **Parse** splits the paste block into the current tab's fields, so you can see
  where every line landed before it reaches a conversation.
- **Export !mma** goes the other way: the fields back into the paste block.
- **single** sends all parts of that follow-up as one message (`FuSingle` on
  Windows). **edit** pastes the joined parts *without* pressing Enter, for review
  first (`SndFuEditable`). Both are per tab and per group, and save immediately.
- **massNo** picks the slot used by `--send` and the GUI; the send keys are per model and ignore it.
- **Save** writes `masses.txt` (keeping a `.bak`); a running `mma.py` picks it up
  within a second.

Scope is the **base panel** only. The 1.4-era additions — Settings, Add Hotkey,
Hotstrings, Pinger, Alt FUs, the archive, or-or branching, OCR — are not here,
and neither is "apply to `<script>.ahk`": these fields live in `masses.txt`.

Two things worth knowing:

- **Save rewrites the file in the labelled form** (`f1:`, `f1.5:`) even if you
  pasted the positional form. Deliberate: positional cannot represent a gap — an
  empty f1 with a filled f2 reads back as f1 and shifts everything up a slot.
  Labels round-trip exactly. Both forms still parse on input.
- **Parse keeps the slot's existing name**, so pasting a new mass over an old
  slot can leave a stale label.

Machine state (the checkboxes, massNo, app filter) lives in `settings.json` next
to `masses.txt`, so the masses file stays pure message content.

## Use it

```sh
python app.py              # panel + hotkeys in one process (what ships)
python gui.py              # paste, check the split, save
python mma.py --check      # same check, from the terminal
python mma.py --dry-run    # real hotkeys, prints instead of sending
python mma.py              # live
```

`app.py` is the packaged entry point — one window, listener included. The split
`gui.py` / `mma.py` pair is still there and is better for development, because
`--check` and `--dry-run` have no equivalent inside the app.

**Run `--check` first, every time you change masses.txt.** It prints exactly
which lines became which messages — the one thing the GUI did that a text file
can't, and the place mistakes actually happen:

```
-> [1] Beach or bedroom
     mass: Beach or bedroom tonight? 🏖️
     f1:   1 message(s)
            - I've been going back and forth on it all day
```

Then `--dry-run` to check the keys fire without sending anything anywhere.

| Key | Does |
|---|---|
| **Ctrl+1/2/3** · **Ctrl+4/5/6** · **Ctrl+7/8/9** | Send follow-up 1/2/3 for M1 · M2 · M3 |
| **Ctrl+Alt+1 / 2 / 3** | Paste that model's mass body without sending (the `__mm` equivalent) |
| **Ctrl+Alt+N** | Next mass slot (only affects the GUI selection and `--send`) |
| **Ctrl+Alt+R** | Reload `masses.txt` |
| **Ctrl+Alt+I** | Report the focused window, for setting `app_filter` |

The startup banner lists what is actually bound, per model — see
[Three models](#three-models-three-sets-of-keys).

`masses.txt` is also re-read automatically about a second after you save it.

## The safety gate

With it off, Ctrl+1 fires into **whatever is focused** — including Slack, or a DM
to someone who is not a fan. It's compared case-insensitively as a substring
against both the process name and the window title.

It's a **toggle and a value**, deliberately separate, so the filter you normally
want stays saved while you switch the gate off to test in a scratch window:

```json
"app_filter": "infloww",
"app_filter_enabled": false
```

Default is **off**, so a fresh checkout works in Notepad. Turn it on before
going live — from the GUI's *Safety gate* checkbox, or by hand. A running
`mma.py` picks the change up within a second, no restart.

On this machine `--check` reports `app='Infloww' title='Infloww Messages - 333'`,
so `"infloww"` matches. Matching the *title* as well as the process is what lets
one value work on both OSes, where a browser is `chrome` on Windows and
`Google Chrome` on macOS.

When the gate blocks a keypress it **says so** rather than doing nothing — a
silent gate is indistinguishable from a dead hotkey, which is a genuinely
expensive thing to debug.

This is the equivalent of AHK's `#HotIf` gating, and the only thing between a
mistimed Ctrl+1 and a very bad paste.

## Three models, three sets of keys

Mass 1/2/3 are **models**, and each has its own send keys — the same shape as
the AHK build's `[mass.1]` / `[mass.2]` / `[mass.3]` sections in
`../hotkeys.ini`. Pressing M2's key sends M2's follow-up, whatever tab the GUI
happens to be showing. There is no "select the model first" step.

| | f1 | f2 | f3 | mass body |
|---|---|---|---|---|
| **M1** | Ctrl+1 | Ctrl+2 | Ctrl+3 | Ctrl+Alt+1 |
| **M2** | Ctrl+4 | Ctrl+5 | Ctrl+6 | Ctrl+Alt+2 |
| **M3** | Ctrl+7 | Ctrl+8 | Ctrl+9 | Ctrl+Alt+3 |

Global: **Ctrl+Alt+R** reload · **Ctrl+Alt+I** which window · **Ctrl+Alt+N**
next slot. The `single` and `edit` checkboxes are per model and group already,
so M1 can join its f2 while M2 does not.

Every message names the model it came from (`M2 sending f1: 2 part(s)`), because
with three sets of keys the useful question is always which one just fired.

**The busy lock is global, not per model.** Two models sending at once would
interleave into whatever single window is focused, so a press during another
model's send is refused rather than queued.

### Editing them

Use the GUI: **Settings / Hotkeys…**. It validates before writing — an
unparseable combo and a combo bound twice are both refused with a message,
because at runtime a duplicate is *silent*: pynput keeps only the last binding
and the other action simply never fires.

Or by hand in `settings.json`:

```json
"hotkeys": {
  "mass.1": {"fu1": "<ctrl>+1", "fu2": "<ctrl>+2", "fu3": "<ctrl>+3",
             "mass": "<ctrl>+<alt>+1"},
  "mass.2": {"fu1": "<ctrl>+4", "...": "..."},
  "mass.3": {"fu1": "<ctrl>+7", "...": "..."},
  "global": {"reload": "<ctrl>+<alt>+r", "whoami": "<ctrl>+<alt>+i",
             "next": "<ctrl>+<alt>+n"}
}
```

pynput syntax: `<ctrl>`, `<alt>`, `<shift>`, `<cmd>`, `<f1>`, and bare
characters. An **empty value unbinds** an action, like a blank in `hotkeys.ini`.
A combo pynput can't parse is reported and skipped at startup rather than taking
every other key down with it.

An **older single-model `settings.json` still works** — the flat `{"fu1": ...}`
form is read as M1 and M2/M3 get defaults, with a note at startup. Saving from
the Settings window writes the new layout.

Unlike the gate, hotkey changes need a **restart** — pynput binds them once when
the listener starts.

One caveat: pynput *observes* keys, it does not suppress them, so the press also
reaches the focused app. Avoid combos the chat app itself uses. Ctrl+*digit* is
safe; note that Ctrl+*letter* arrives as a control character on Windows and is a
poor choice for a hotkey here.

## Writing masses

Edit `masses.txt`. Three input styles, all accepted — the same ones the Windows
GUI takes, so you can paste straight from "Export !mma".

**Positional** — blank lines separate the follow-ups, in order f1 → f2 → f3.
Lines within a group become separate messages, sent back to back:

```
!mma Beach or bedroom tonight?

I've been going back and forth on it all day

Because one of them involves a lot less clothing

So which is it, before I pick for you?
```

**Labelled** — every line says where it goes, so blank lines stop mattering:

```
!mma Beach or bedroom tonight?
f1: I've been going back and forth all day
f1.5 and this goes out right after it
f2: Because one involves less clothing
f3: So which is it?
```

**No marker** — with no `!mma` line the first line is taken as the mass.

Several masses in one file, separated by `===`, each optionally named with
`# name`. Comments are only recognised at the top of a block, so a message
starting with a hashtag is still sent as a message.

## Configuration

**`settings.json`**, written by the GUI and re-read by a running `mma.py`:

| Setting | Default | Notes |
|---|---|---|
| `hotkeys` | per model | `mass.1`/`mass.2`/`mass.3`/`global` → action → combo. Blank unbinds. Restart to apply. |
| `app_filter` | `"infloww"` | Substring matched against app name and window title. |
| `app_filter_enabled` | `false` | The gate toggle. Off = keys fire anywhere, for testing. Live. |
| `current` | `0` | Which mass slot the send keys use. Live. |
| `single` / `editable` | `{}` | Per slot and group, keyed `"<slot>.<group>"`. Live. |

Save it as plain UTF-8. A **BOM** is tolerated on read, but the file is rewritten
without one — settings silently reverting to defaults is the failure a BOM used
to cause here.

**Constants at the top of `mma.py`**, the convention `pinger.pyw` uses:

| Setting | Default | Notes |
|---|---|---|
| `WAIT_TIME` | `0.4` | Pause between messages. Matches `WaitTime := 400`. |
| `CLIP_DELAY` | `0.06` | Gap between writing the clipboard and pasting. Raise if a paste lands stale. |
| `FU_SINGLE` | all `False` | Per group fallback: send all parts as **one** message. `settings.json` wins. |
| `APP_FILTER` | `None` | Fallback only, used when `settings.json` has no gate. |

## Shipping it to someone else

```sh
./build_macos.sh            # ON A MAC. produces dist/MMA.dmg
```

`docs/install-macos.html` is the guide the recipient gets — Gatekeeper, both
permissions, and the relaunch step. It goes inside the DMG as
*READ ME FIRST.html*, and it is also what `app.py` points at when the listener
cannot start.

Three things about this that are not negotiable:

- **The build must run on macOS.** PyInstaller cannot cross-compile; there is no
  flag for it. From a Windows box, use a macOS CI runner.
- **Accessibility and Input Monitoring cannot be granted programmatically.** No
  installer can do it. The recipient ticks two boxes by hand, then relaunches —
  and until they do, the app looks completely fine and does nothing.
- **Gatekeeper will block an unsigned app.** `build_macos.sh` signs ad-hoc,
  which does *not* remove the warning; only a paid Apple Developer account
  ($99/yr) plus notarisation does. Ad-hoc signing is still worth it for a
  different reason: macOS ties granted permissions to a binary's signature, and
  an unsigned binary gets a new identity every rebuild, forcing a re-grant after
  every update.

Config does **not** live next to the app once frozen — see `paths.py`. It moves
to `~/Library/Application Support/MMA` (macOS) or `%APPDATA%\MMA` (Windows),
because PyInstaller's extraction directory is deleted on exit and every mass
would vanish on quit. Running from source is unchanged.

## Testing

```sh
python -m unittest discover -v      # 136 tests, no keystrokes fired
```

`test_engine.py` drives the engine through a fake backend and asserts the
literal order of clipboard writes and key presses, plus pacing, the busy guard,
app gating, and that a failing send can't wedge the lock. `test_massparse.py`
covers the `!mma` format and the shipped `masses.txt`.

Nothing in the suite touches a real keyboard, so it is safe to run while you are
working.

## Two differences from the Windows behaviour

**Sending happens on a worker thread.** `pynput` delivers hotkeys on its own
listener thread; doing a second of pasting there would stop every other hotkey
being noticed until it finished.

**There is a busy guard.** Because of the above, a second Ctrl+1 pressed mid-send
would interleave two follow-ups into the chat. The second press is dropped with
a note instead. A failing send releases the lock rather than wedging it.

The clipboard is *not* restored after sending, matching the Windows original.

## What is deliberately not here

The GUI, the archive, the 125 hotstrings, OCR, the pinger, alt follow-ups, or-or
branches, PPV keys, double-MM, model gating across three scripts. PPV text *is*
parsed and kept — it just has no key bound, so wiring it up is a one-liner.

Masses are authored by editing a text file and checked with `--check` rather than
in a GUI. If that becomes the bottleneck, the GUI is the next thing to port, not
the sending.

## If it does not work

1. **macOS: F-keys and Accessibility.** Start here, both of them.
2. **Nothing pastes** — raise `CLIP_DELAY`. Some apps read the clipboard lazily.
3. **Alerts but nothing sends** — `APP_FILTER` doesn't match. Press Ctrl+Alt+I.
4. **Wrong key fires** — check `hotkeys` in `settings.json` uses pynput syntax,
   not AHK's.
5. Run `--dry-run` to see whether the problem is the hotkey or the sending.
