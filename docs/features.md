# MMA feature list

Every feature MMA has, grouped by what it's for. Keys are the defaults from
`userdata/hotkeys.default.ini`; yours may be rebound in the Hotkeys window. To mark what stays
and what goes, see [proposals/consolidation.md](proposals/consolidation.md).

---

## Core: sending masses

1. **Mass paste and parse.** Paste a mass into the main window and press Parse; MMA splits it
   into the mass, follow-ups f1–f3 (each in up to three parts), the PPV caption and the PPV
   follow-ups. `---` keeps a multi-line mass or PPV together. Format: [mass-format.md](mass-format.md).
2. **Save / Load / Export !mma / Archive.** Save writes the three mass tabs into the model's
   file; Load reads them back; Export rebuilds paste-format text from the fields. The Archive
   keeps past masses so you can browse and reload them.
3. **Active-model keys.** One set of keys that sends for whichever model is active (detected or
   picked): follow-ups F13–F15, PPV F16, PPV follow-ups F17, the mass itself F18, plus mouse
   buttons (XButton2/XButton1/Ctrl+MButton for f1–f3).
4. **Numbered model keys.** The older fixed-slot keys, one set per model tab: model 1 F1–F5,
   model 2 F9–F12, model 3 F6–F8. They send that tab's mass no matter which model is active.
5. **Several keys per action.** Any action can carry more than one key (`fu1 = F1 | ^F1 | Ins`
   in hotkeys.ini; Settings ▸ Hotkeys ▸ Add key…). The shipped defaults put Ins/Home/PgUp,
   Ctrl+F1–F3 and Alt+F4 on the follow-ups and PPV follow-ups this way.
6. **Branches and the Variants window.** `::name` lines give a follow-up alternative wordings;
   pressing the follow-up key shows them, Tab picks one, and the choice carries to f2/f3. The
   Variants window edits them.
7. **Next follow-up.** Reads the open chat, works out which follow-up comes next, and sends it
   (Ctrl+XButton2). Can be switched off on its own because a misread sends the wrong message.
8. **Model select and lock.** Say which model the active keys mean: Ctrl+Alt+1/2/3,
   Ctrl+Alt+W to cycle, Ctrl+Alt+L to lock it so the detector can't change it.
9. **FuSingle.** Per model and follow-up, send the parts joined as one message instead of
    three separate ones.
10. **Editable follow-ups / wallet check.** Pause before a follow-up so you can edit it, and
    check the fan's wallet before f3.
11. **Default f3.** A fallback third follow-up (set in Settings) for masses that have none.
12. **Open in new tab.** Opens the chat in a new tab after a send.
13. **Ask which model on PPV keys.** In "I pick" mode, the shared PPV keys pop a picker asking
    which model's PPV to send.
14. **Click wall.** While a multi-part send is running, a click on the chat list is held and
    replayed once the send lands, so a follow-up never gets split across two fans.

## Chat navigation

16. **Mark unread and focus keys.** Mark unread (Alt+-, or Shift+Left for the left variant),
    focus the textbox or the top chat (Alt+Space, Up), move to the next chat (Down).
17. **Click shortcuts.** Click the unread button (Del), home (End) or the PPV notification (PgDn).
18. **Send + remember / Recover.** Enter in Chrome remembers what you typed before sending it;
    Ctrl+Shift+Z puts the last message back.
19. **AFK click cycle.** Clicks periodically so the session doesn't idle out (Ctrl+P).
20. **Grey-icon click / debug search.** Pixel-search helpers that click the second grey icon
    (F24) or show what the search finds (F23).

## Hotstrings (messages)

21. **Message hotstrings and the Hotstrings manager.** ~117 typed triggers that send canned
    messages; the manager window searches, edits and organises them.
22. **Expiring hotstring keys.** Bind a key to a hotstring for a while; it drops the key when the
    expiry passes.
23. **Overloads.** One trigger with several wordings; MMA asks which or picks one at random.
24. **Hotstrings quick menu.** A popup at the cursor with your pinned and recent messages; click
    or press 1–9 to send (Ctrl+Alt+H).
25. **Shortcuts.** Type a trigger like `..dorail` or `..dostats` to run an action instead of
    sending text. Set in `userdata/shortcuts.ini`.
26. **Add Hotkey / OCR grab.** Turn selected text (Alt+0) or text read off the screen
    (Ctrl+Shift+O) into a new hotstring or a replacement follow-up.
27. **Capitalizer.** After Enter, capitalizes the first letter of your next message.
    Shift+Enter and Ctrl+Enter pass through untouched.
28. **General pitches.** Canned pitches in `general.ahk`: open-fast (Alt+Shift+=),
    open-and-rate (Alt+Shift+]), and anti-CC, which types a random 199.00–200.00 amount
    (Ctrl+Alt+A).

## Sequences

29. **Discord Ctrl+click import.** Ctrl+click a mass in Discord; MMA copies it, reads the channel
    header to pick the model, and parses it into the right tab.
30. **Open Farmolijer DM / Select top PPV.** Recorded click sequences: open that DM (Ctrl+Alt+F)
    and select the top PPV (no key bound).
31. **Coordinate recorder.** Record a run of clicks and save it as a new sequence (Ctrl+Alt+F12).

## Windows

32. **Actions menu and Quick Actions.** The Actions menu (Ctrl+Alt+M) lists every action with
    its key and runs any of them, even unbound ones; Ctrl+P pins the selected one. Quick Actions
    (Ctrl+Alt+Q) shows the pinned ones as big buttons. Nothing is pinned yet.
33. **Branch builder.** Draw a conversation as a tree and compile it into a mass with branches
    (Ctrl+Alt+B).
34. **Chat simulator.** Write a mass inside a mock chat, so you see it the way a fan will
    (Ctrl+Alt+C).
35. **Activity chart.** Charts your typing stats from the activity tracker (Ctrl+Alt+G).
36. **Settings, Hotkeys, Tools, Debug panel, Startup scripts.** Settings holds every feature
    switch; Hotkeys rebinds keys; Tools turns each background service on, off or restarts it;
    the Debug panel shows what a mass will send and launches probes; Startup scripts picks
    what launches with MMA.
37. **Two styles of each window.** The main window, Settings and Hotkeys each exist in the new
    style (WebView) and the old style (Classic Win32). Settings ▸ GUI picks which.
38. **Easy / Advanced mode.** Easy switches every optional feature off at once.

## Overlays

39. **Tab bars (separators).** Divider bars you place on your browser tab strip
    (Ctrl+Alt+, places one at the pointer). Drag a bar to move it; right-click it for colour,
    size, remove or hide all.
40. **Stats overlay.** Shows sales and the PPV/fans ratio, read off the Infloww Home window in the
    background (`..dostats`).
41. **Reply timers.** Frames on chat rows showing how long each fan has waited. Needs a one-time
    calibration of the chat-list area.
42. **Lock badge and Fansly rail badge.** Small readouts of which model is active and whether it
    is locked; the rail badge does the same for Fansly (`..dorail`).

## Background services

43. **Infloww model detector.** Reads the model tab strip to work out the active model, so the
    active-model keys follow it.
44. **Fansly model detector.** The same for Fansly. Known broken: only the selected row can be
    detected, so Fansly is manual-only.
45. **Unread pinger.** Alerts you when an unread message arrives (needs Python).
46. **Automation.** Python helpers: unsend the last message, or the whole run on a second press
    (Ctrl+Alt+U); total your sales from Notifications ▸ Purchases (Ctrl+Alt+S); hop the cursor
    over the model menus, a test (Ctrl+Alt+K).
47. **Typelog.** Records what you type in Infloww, to mine for new hotstrings. Ctrl+Alt+F9
    pauses it.
48. **Autoword.** Next-word suggestions while you type, trained on the typelog, plus Ctrl+Tab to
    reword the last word. Ships drawing nothing until you switch its display on.
49. **Activity tracker.** Counts keystrokes (never what you typed) for the activity chart.
50. **Local AI reply drafter.** Reads the open chat and suggests replies with a local Ollama
    model. Command-line only; not connected to MMA yet.
51. **Auto-update.** Checks for a new version at startup. Settings ▸ Models has a manual check.
52. **Startup scripts and watchdog.** Launches the chosen scripts with MMA and restarts any
    enabled service that crashes.
