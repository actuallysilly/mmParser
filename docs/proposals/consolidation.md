# Consolidation — what MMA has, and what stays

Fill in the **Verdict** column: `keep`, `cut`, `menu` (keep, but reach it from Quick Actions
instead of a key you have to remember), or `?`. "My read" is a guess from the code; usage
evidence is thin — `mma.log` only reaches back to this morning (it rotates at ~10 MB), and in
that window the only actions that fired were the active-model follow-up/PPV keys,
`nav.focusTop`, and two hotstring keys.

Keys are the defaults from `userdata/hotkeys.default.ini`; yours may differ.

---

## 0. The menus you already have

| Key | What | Notes |
|---|---|---|
| `^!m` | **Actions menu** — searchable list of *every* action, with its key. Enter runs it, even unbound ones. | Bound and live today. |
| `^!q` | **Quick Actions** — your *pinned* actions as big buttons (up to 12). | Bound and live. Empty until you pin: open `^!m`, select a row, press `Ctrl+P` (or the Pin / Unpin button). |
| `^!h` | **Hotstrings quick menu** — pinned + recent messages at the cursor; 1–9 to send. | |
| typed `..dorail`, `..dostats` | **Hotstring shortcuts** — type a trigger, run an action (`userdata/shortcuts.ini`). | Only two lines are live; the rest are commented out. |

So "a GUI for the stuff I forget" is `^!q` with pins. The open question is just *what to pin*,
which this list answers.

---

## 1. Core — not up for debate

Mass paste/parse, Save/Load, the active-model follow-up and PPV keys, branches (`::name`), the
model select/lock keys, the Discord Ctrl+click import, hotstrings + manager, archive.

---

## 2. Sending extras

| Feature | What it was for | How you reach it | My read | Verdict |
|---|---|---|---|---|
| Numbered mass keys `[mass.1/2/3]` | Fixed keys per model slot: F1–F3 / F9–F11 / F6–F8, PPV F4/F12/F8 | keys | **Superseded** by `[mass.active]` (F13–F17 + mouse), which follows the detected/selected model. Four parallel key sets is the single biggest pile here. | |
| "Second key" / "third key" variants | `fu1short` Ins/Home/PgUp, `altFu*` ^F1–^F3, `b1Ppv` !F4 — the same follow-up on another key | keys | Duplicates of duplicates. Today only `mass.active.altFu*` fired. | |
| Paste the mass — active model | Sends the mass text itself | F18 | | |
| Next follow-up (reads the chat) | OCRs the chat, picks f1/f2/f3 for you | ^XButton2 | Clever; risky failure mode (wrong follow-up). Do you use it? | |
| FuSingle grid | Per model/follow-up: join the parts into one message instead of three | checkboxes on main window | | |
| Editable follow-ups / wallet check | Pause before an fu so you can edit it; f3 checks the fan's wallet first | Settings | | |
| Default FU3 | A fallback f3 when the mass has none | Settings text | | |
| Open in new tab after a send | | Settings | | |
| Ask which model on PPV keys | Picker window on shared PPV keys in "I pick" mode | automatic | | |
| Click wall | Holds a chat-list click until a multi-part send finishes | automatic | Cheap insurance; keep. | |
| Send + remember / Recover last message | Enter remembers the text; ^+z puts it back | Enter, ^+z | | |

## 3. Navigation & utilities

| Feature | What it was for | Key | My read | Verdict |
|---|---|---|---|---|
| `nav.*` (8 keys) | Mark unread, focus textbox/top chat, next chat, click unread/home/PPV notification | !-, !Space, Down, +Left, Up, Del, End, PgDn | `focusTop` fired today; the rest? Up/Down/Del/End are grabbed globally. | |
| AFK click cycle | Keeps the session alive by clicking | ^p | | |
| Click 2nd grey icon / Debug grey search | Pixel-search helpers | F24 / F23 | Look like test tools. | |
| Open Farmolijer DM | Sequence: open one specific DM | ^!f | | |
| Select top PPV | Sequence | unbound | Never bound → cut? | |
| Coordinate recorder | Record clicks into a new sequence | ^!F12 | Dev tool. | |
| Open-fast / Open-and-rate pitch | Canned pitches in general.ahk | !+= / !+] | Hotstrings wearing hotkeys? | |
| Anti-CC amount | Types a random 199.00–200.00 | ^!a | | |
| Capitalizer | Enter capitalizes the next sentence | Enter | | |

## 4. Windows

| Window | What it was for | Key / button | My read | Verdict |
|---|---|---|---|---|
| Branch builder | Draw a conversation as a tree, compile it to a mass | ^!b | Alpha | |
| Chat simulator | Write a mass inside a fake chat | ^!c | Alpha | |
| Variants… | Edit branches/alt follow-ups for the open mass | button | | |
| Add Hotkey grab / OCR grab | Turn selected / on-screen text into a hotstring or a follow-up | !0 / ^+o | | |
| Activity chart | Typing stats | ^!g (needs the tracker on, off by default) | | |
| Tools window | On/off/restart each background service | button | | |
| Debug panel, Startup scripts | | Settings | | |
| **Two shells for everything** | WebView main window + Classic Win32 fallback; likewise `settings_window`/`settings_webview`, `hotkeys_window`/`hotkeys_webview` | Settings ▸ GUI | Every UI change is paid twice. Biggest maintenance cut available if WebView is reliable on your machine. | |

## 5. Overlays & background services

| Feature | What it was for | Default | My read | Verdict |
|---|---|---|---|---|
| Tab bars (**the separators**) | Divider bars on your tab strip; drag to move, right-click for colour/size/remove | `^!,` places one at the pointer | You forgot the key → pin it in Quick Actions. | |
| Stats overlay | Sales + PPV/fans ratio, read off Infloww Home | off; `..dostats` | | |
| Reply timers | Frames on chat rows showing how long a fan waited | off; needs calibration | | |
| Model detector (Infloww) | OCR the tab strip → active model | off | Garbled-name OCR was the blocker. | |
| Fansly detector + rail badge | Same for Fansly | off; `..dorail` | Known broken: only the selected row is detectable. Cut? | |
| Pinger | Alert on unread | off | | |
| Automation listener | Unsend last (^!u), count sales (^!s), hop kebabs (^!k, a test) | on | Hop kebabs is a test. | |
| Typelog | Records what you type, to mine for hotstrings | off | Corpus already mined? | |
| Autoword | Next-word suggestions + Ctrl+Tab reword | off, ships drawing nothing | Alpha | |
| Activity tracker | Counts keystrokes for the chart | off | | |
| Local AI reply drafter (`services/llm`) | Read the chat, offer replies via Ollama | CLI only, not wired into MMA | Phase-1 prototype. | |
| Auto-update at startup | | off | | |
| Easy / Advanced mode | Easy turns off every optional feature at once | Settings | | |

---

## Next step

Once the Verdict column is filled in: `cut` rows get removed (code, `HK_Def`, ini lines, Settings
checkbox), and `menu` rows get pinned to Quick Actions.
