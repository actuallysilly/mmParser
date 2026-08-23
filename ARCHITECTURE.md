# MMA — what every file is, and where it should live

> **Status: this is the target for 2.0.0.** Work lands on `dev` and merges to `main` at
> the 2.0.0 release. There is no installed base to protect, so v2 is a clean break —
> no legacy-path fallbacks, no migration shims, no compatibility aliases. Anywhere this
> document says "delete", it means delete, not deprecate.

Two halves — plus §5, which is the one design decision that changes the tree rather than
just rearranging it:

1. **[Inventory](#1-inventory)** — every file in the repo, one line each, grouped by the
   role it actually plays (not by where it currently sits).
2. **[Proposed tree](#3-proposed-tree)** — the restructure, the naming law behind it, and
   the six things that will silently break if you move files without fixing them first.
3. **[One mass engine](#5-v2-one-mass-engine-not-three-model-processes)** — why
   `1/2/3_mass.ahk` become one process reading one data file, and the five gating
   mechanisms that deletes.

---

## 1. Inventory

MMA had 69 tracked files falling into **seven roles**, all peers in the repo root. That
was the whole problem, and §3 is the fix. Reading this section as history: `paths.ahk` (a library that
never runs), `1_mass.ahk` (message data), `hotkeys.ini` (your settings) and
`model_detect_test.ahk` (a dev rig) sat side by side, so nothing about a filename told
you whether you could edit it, run it, or delete it. **Links below point at where each
file lives now.**

### 1.1 Entry points — processes that actually run

Each of these is its own AHK process. AHK titles a script's main window with its **full
path**, which is how `HK_Broadcast` and `processes.ahk` find and close them.

| File | What it is |
|---|---|
| [mass_gui.ahk](src/ui/main_window.ahk) | **The app.** 80 KB, the largest file here. The main window, the paste/parse box, the model tabs, Settings, Add Hotkey, Branches, the script toggles, and the block-rewriter that saves a parsed mass back into a model file. Supervises every other process. |
| [1_mass.ahk](content/models/1_mass.ahk) | Model 1. Three `mN := {...}` data blocks + `MassInit(1)`. Also owns the always-on nav/chat/utility keys, because it is the one model script always running. |
| [2_mass.ahk](content/models/2_mass.ahk) / [3_mass.ahk](content/models/3_mass.ahk) | Models 2 and 3. Pure data + `MassInit(n)`. |
| [general.ahk](content/general.ahk) | Always-on shared message hotstrings (`::_gns1::` etc.). |
| [acc/ALIW.ahk](content/accounts/ALIW.ahk) [acc/BRI.ahk](content/accounts/BRI.ahk) [acc/TEMP.ahk](content/accounts/TEMP.ahk) [acc/UND.ahk](content/accounts/UND.ahk) | Per-account message hotstrings. Started/stopped from **Hotstrings → Startup scripts**; `TEMP.ahk` is the scratch target for Add Hotkey. |
| [sequences.ahk](src/sequences/sequences.ahk) | Recorded click/type macros — Discord open, and the Ctrl+click mass import that OCRs the Discord channel header to pick a model. |
| [capitalizer.ahk](src/capitalizer.ahk) | Capitalizes the first letter after Enter / `.!?`+space. |
| [model_detector.ahk](src/screen/model_detector.ahk) | Background service. Pixel-scans the Infloww tab strip for the active model pill, OCRs its name on change, writes it to `detector_status.ini`. This is what lets one set of F-keys serve whichever model tab is focused. |
| [stats_overlay.ahk](src/screen/stats_overlay.ahk) | Background service. OCRs Sales / PPVs-sent / Fans-chatted off the Infloww **Home** window (via PrintWindow, so unfocused) and shows a colour-graded ratio overlay. |
| [reply_box.ahk](src/screen/reply_box.ahk) | Background service, **off by default**. Draws a coloured frame round any conversation in the Infloww list that is **unread** and has been waiting past a threshold — yellow at 3 minutes through white at 10, all of it in `[ReplyBox]`. Finds the rows by their coral `#ff7c71` unread dot (so replying clears the box with no state kept) and reads the stamps with one OCR of the timestamp column. Two ticks: a cheap dot scan at 400ms that exists to notice a **scroll** and blank the layer, and the OCR pass at 5s. Two files are split out for the reason `pill_scan.ahk` gives — the service and its calibrator must agree: the arithmetic is [reply_tiers.ahk](src/core/reply_tiers.ahk) and the dot scan is [reply_scan.ahk](src/screen/reply_scan.ahk). Needs **two** one-off calibrations (the list, then one row — the dot is not centred in its row, so the offset is measured rather than assumed); **Settings ▸ General ▸ Reply timers**. |
| [reply_scan.ahk](src/screen/reply_scan.ahk) | Pure. Finds the unread dots in a band at the right-hand end of the list — never the full row width, because an avatar is a photograph and contains every colour there is (`rail_scan.ahk` has the long version). Shared by the overlay and by Settings' "Calibrate a row…", which finds the dot inside the box you drew to measure how far below the row top it sits. `RBS_Defaults()` holds the shipped numbers so the two callers cannot fall back to different ones. |
| [activity/tracker.ahk](src/activity/tracker.ahk) | Background service, **off by default**. Counts keys, characters, backspaces, clicks and active seconds into `userdata\activity\`, one row per counter per minute. It counts and never records *what* — see §8. Owns the `gui.activity` key. |
| [branch_window.ahk](src/ui/branch_window.ahk) | **The branch builder.** Draws a conversation as a tree — your messages, what the fan says back, forks and merges — and compiles it into an ordinary mass. A WebView2 shell over [webview/branch_builder.html](src/ui/webview/branch_builder.html); the compiler is [branch/tree.ahk](src/branch/tree.ahk) and lives on this side, so the live preview and Save cannot disagree. See §9. |
| [activity_window.ahk](src/ui/activity_window.ahk) | The chart over what the tracker recorded — KPI tiles, a day timeline, a weekday×hour heatmap, the correction-rate curve. A WebView2 shell over [webview/activity.html](src/ui/webview/activity.html); its own process, opened by the key above, and closing it stops no recording. |
| [hotkeys_gui.ahk](src/ui/hotkeys_window.ahk) | Standalone window: rebind every hotkey. A pure view over `hotkeys.ini`. |
| [hotstrings_gui.ahk](src/ui/hotstrings_window.ahk) | Standalone window: search the whole message library by trigger *or* by the text inside, jump to source, create overloads. |
| [recorder.ahk](src/sequences/recorder.ahk) | Records mouse/keyboard into a new sequence and **writes AHK code into `sequences.ahk` and `hotkeys.ahk`**. |
| [updater.ahk](src/updater.ahk) | Pulls updates from the GitHub raw URL, then relaunches `mass_gui.ahk`. Separate process so it can overwrite the GUI. |
| [automation/automation.py](src/services/automation/automation.py) | Python background listener. Serves the `[automation]` hotkeys (hop kebabs, unsend last, count sales) by locating Infloww UI elements from a measured geometry map. Optional. |
| [pinger/pinger.pyw](src/services/pinger/pinger.pyw) | Python background service. Beeps when an Infloww fan tab goes unread, by scanning for the `#ff7c71` unread dot/badge. Optional. |
| [typelog/typelog.pyw](src/services/typelog/typelog.pyw) | Python background service, **off by default**. Records the text you type **while Infloww is in front** into `userdata\typelog\`, to mine for hotstrings. The mirror image of the activity tracker: that one is built so it *cannot* keep what you type, this one is built to. Same consent gate, stronger reason. Owns the `[typelog] pause` hotkey (bound by pynput, like the automation keys). Optional. |

### 1.2 Libraries — `#Include`-only, never run alone

| File | What it is |
|---|---|
| [paths.ahk](src/core/paths.ahk) | **The anchor.** Every path in MMA derived from `A_LineFile`, so nothing depends on which script is `A_ScriptDir`. Read its header before moving anything. |
| [hotkeys.ahk](src/core/hotkeys.ahk) | The central hotkey registry. Contains **no keys** — only `HK_Def` declarations (id, label, context, owner). Keys live in `hotkeys.ini`. Also owns `HK_Bind`, `HK_Broadcast` and the cross-process message protocol. |
| [modes.ahk](src/core/modes.ahk) | Easy vs Advanced, and the one registry (`FEAT_Def`) of every optional feature. In Easy mode features are switched **off**, not hidden. |
| [utils.ahk](src/core/utils.ahk) | 26 KB grab bag: `snd()`/`Sendt()` send helpers, AFK handling, the active-model gate (`FuGate`/`ModelIsActive`), plumbing hotstrings. Included by every message script. |
| [coords.ahk](src/core/coords.ahk) | Named screen coordinates + Corsair Scimitar button aliases. Written to by `recorder.ahk`. |
| [log.ahk](src/core/log.ahk) | **The logger every process gets for free.** Included at the end of `paths.ahk`, which everything already includes, so each process gets a boot line, an exit line and an `OnError` hook with no wiring of its own. Six levels; the one that matters is `LOG_Bail` — *"nothing happened, on purpose, here is which purpose"*. Switches live in `mass_gui.cfg [Debug]`. See §7. |
| [crashlog.ahk](src/core/crashlog.ahk) | A forwarder now. Its `OnError` → `error_log.txt` job moved into `log.ahk` (with the stack attached); the file survives because two scripts name it in an `#Include`. |
| [mass_runtime.ahk](src/mass/runtime.ahk) | **All model behaviour, once.** Follow-ups, alts, branches, PPV, the Settings toggles. Model files are data because this exists. |
| [mass_parser.ahk](src/mass/parser.ahk) | The `!mm` / `f1` / `--Branch` / `~alt` paste format: parse it in, escape it back out. |
| [archive.ahk](src/mass/archive.ahk) | `mass_archive.txt`'s format, its one parser, and the viewer window. |
| [processes.ahk](src/core/processes.ahk) | Start/stop/watch the five children. AHK ones are found by window title; the two Python ones sign in with a **named event** instead. |
| [actions_menu.ahk](src/ui/actions_menu.ahk) | Searchable window over every registered action, generated from `HK_ORDER`. Runs actions by broadcasting their index — including actions with no key bound. |
| [modes_gui.ahk](src/ui/modes_window.ahk) | The Easy/Advanced + per-feature checkbox window, generated from `modes.ahk`. |
| [tools_window.ahk](src/ui/tools_window.ahk) | The **Tools** button's window: one row per background tool (pinger, stats overlay, both detectors, automation listener), live running state on a timer, On/Off writing the same feature keys Settings does. |
| [startup_scripts.ahk](src/ui/startup_scripts.ahk) | **Hotstrings → Startup scripts**: one row per message script, live running state, Start/Restart/Stop. Replaced the `◻ NAME` toggles. |
| [credit.ahk](src/ui/credit.ahk) | The picture in the main window's empty corner. Finds `assets\decoration\anime_girl*.gif` (else `*.png`), scales it with GDI+ to whichever rung of heights fits the space the controls leave, and plays it frame by frame if it is animated. One Picture control, re-imaged with `STM_SETIMAGE` — replaced a ladder of hidden copies scaled at startup. Switched on and pointed at a file by **Settings ▸ GUI ▸ Corner picture** (`CreditPicture`, `CreditImage`); `CREDIT_Refresh()` applies both live, with no reload. |
| [lock_badge.ahk](src/ui/lock_badge.ahk) | The **LOCKED** strip that sits on screen for as long as lock mode is on (§5.1.2.2), naming the model every shared key is pinned to, and acting as the unlock button. Always-on-top, `WS_EX_NOACTIVATE` so it can never eat a keystroke meant for a chat box, deliberately un-themed. Owned by the **engine** (a poll, since the GUI's Lock button is another process) because the engine is what sends. It is not decoration: it is the reason a mode that re-aims every shared key is safe to offer at all. |
| [hotstring_index.ahk](src/hotstrings/index.ahk) | Parses `:*:trigger::{ snd("…") }` blocks out of the message `.ahk` files into records. The one writer is `HSI_DeleteBlock`. |
| [hotstring_overloads.ahk](src/hotstrings/overloads.ahk) | Lets one trigger have several variants (ask / random) **without ever rewriting your source files** — it re-points the trigger at runtime. |
| [tab_marks.ahk](src/screen/tab_marks.ahk) | **Stars and separators you stick on your own browser tabs.** Decoration, and firmly nothing else — a star means whatever you meant by it; MMA never moves one, reads one, or infers a model from one, because a mark it also *maintained* would be a second silent claim about which model is which (§4.8). Marks are stored in `[Marks]` as `kind,x,y` in the TARGET WINDOW's client coordinates, so they ride along when it moves and need no calibrated tab geometry at all. The overlay is click-through (`WS_EX_TRANSPARENT`) so the strip stays clickable, `WS_EX_NOACTIVATE` so it cannot eat a keystroke, and `WDA_EXCLUDEFROMCAPTURE` so MMA's own pill scan reads the tabs and not the stars. Two measured gotchas in its header: a near-black chroma key does not key at all, and `BackgroundTrans` on a click-through window paints black. Hosted by the engine. |
| [click_wall.ahk](src/screen/click_wall.ahk) | **The mouse half of the anti-fumble guards.** A follow-up is three messages with a `waitTime` pause between each, so one keypress owns the chat box for a second or more; click the next conversation inside that second and the parts still in flight land in the chat you moved to. `_HK_Fire`'s three guards (§5.1) cannot see that — a click on the list is not a hotkey. So while a send runs this claims `*LButton` over the list, **remembers** the click and plays it back when the send lands, so you click once and never re-click. A hotkey rather than a transparent window on purpose: a window outlives the process that raised it, so an engine that dies mid-send would leave an invisible wall nobody can see or lower, while a hotkey claim dies with its process. Before playing a click back it re-grabs a patch of pixels from under it and compares — Infloww sorts the list by most recent message, and the send holding your click is what makes a conversation most recent, so the rows can move underneath it. `[ClickWall]`, region falling back to `[ReplyBox] Region` and then to *everything left of `[NextFu]`*, so an ordinary install needs no calibration. Hosted by the engine, off the `HK_OnSend` hooks. |
| [ocr_grab.ahk](src/screen/ocr_grab.ahk) | Drag a box on screen → OCR it → text. Feeds Add Hotkey. |
| [features.ahk](src/sequences/composer.ahk) | 933 bytes, two functions: click the 2nd grey icon in the composer strip, plus a debug tooltip version. Included only by `1_mass.ahk`. Misnamed — nothing "features" about it. |
| [lib/OCR.ahk](src/vendor/OCR.ahk) | **Vendored third party** (`lib/OCR.LICENSE`). Wraps `Windows.Media.Ocr` — offline, nothing to install. |

### 1.3 Config that ships vs. state the machine owns

These are mixed together in the root today, and the git rules for them are inconsistent.

| File | Owner | Tracked? |
|---|---|---|
| [hotkeys.default.ini](userdata/hotkeys.default.ini) | ships | yes — correct |
| `hotkeys.ini` | user | no — correct, `HK_Init` creates it from the default |
| `userdata/mass_gui.cfg` | user | **was yes — wrong, now fixed.** Holds your model names, `StartupScripts`, calibrated OCR rects and the `DefaultFu3` message body. Same class of personal data as `hotkeys.ini`, which is correctly ignored. UTF-16LE. |
| `userdata/hotstring_overloads.ini` | user | **was yes — now untracked**, same rule as the rest |
| `detector_status.ini` | machine | no — correct |
| `mass_archive.txt` | user | no — correct |
| `error_log.txt` | machine | no — correct (130 KB locally) |
| [version.txt](version.txt) | ships | yes |

### 1.4 Dev rigs — never run in a real session

| File | What it is |
|---|---|
| [model_detect_test.ahk](tools/model_detect_test.ahk) | The prototype `model_detector.ahk` grew out of. Hard-codes "grey on the left = AW, right = BUT". Superseded. |
| [discord_header_test.ahk](tools/discord_header_test.ahk) | Still useful: tunes the `[Discord]` header band that the mass-import fallback OCRs. |
| [detection_overlay_debug.ahk](tools/detection_overlay_debug.ahk) | **What MMA thinks it can see, live, while you work.** Which platform is in front, which tab/row reads as selected, what OCR reads off it *next to what it should read*, which model+mass slot the `[mass.active]` keys would use, and which follow-up is already in the chat. Two views over one state function: a flat 60px **strip** (the default — five cells, colour carries the verdict, meant to be left up all shift beside Infloww) and a **detail** panel with the working shown under each row, `^!F11` between them. The cheap half refreshes twice a second; the two OCR reads are rationed (name on a tab change, `next_fu` on `^!F10`). Reads only — it never writes a cfg key, and unlike the services it does not seed `[Fansly]`. It includes `mass/runtime.ahk` for `CurMass()`, so it `Suspend`s itself at load and marks its own three keys `#SuspendExempt` — otherwise this process would answer `__mm` alongside the real engine. |
| [detector_probe.ahk](tools/detector_probe.ahk) | **Calibrates the model detector**, which cannot be calibrated by guessing — see §4.8. Put Infloww in front, press F10: it prints the colours actually in the tab strip, what the current `[Detector]` settings find, and what it would hand to OCR. Reads pixels only; never clicks or types. `--now` probes immediately, for scripted checks. |
| `infloww ui elements/` | Gitignored. Five Python detector prototypes, the sliced element bitmaps, annotated screenshots, and the technique write-ups. Contains **real fan handles** in the screenshots — that is why it is ignored. |
| [pinger/test_detect.py](src/services/pinger/test_detect.py) | Pinger's detection test against the reference PNGs. |

### 1.4.1 `tools/test/` — the self-tests, which are the opposite of the above

A rig or probe **binds a key and stays resident**, so you can look at your own screen
through it. A test **asserts, prints `N passed, M failed`, and exits**. They had nothing in
common except living in the same folder, and the only thing distinguishing them was the
filename — which lied in both directions: `model_detect_test.ahk` is a probe (and
`debug_panel.ahk` correctly lists it under `PROBES`), while `settings_build_test.ahk` is a
test that happens to flash a window.

The eleven assertion files are in [tools/test/](tools/test/) now, with a
[README](tools/test/README.md) covering how to run one by hand and which of them write real
settings. `DebugPanel.TESTS` in [debug_panel.ahk](src/ui/debug_panel.ahk) is the list
**Settings ▸ Debug ▸ Run all** walks — a test not in that list only ever runs by hand.

The two misnamed probes stayed in `tools/` with the other probes rather than being renamed,
because a rename is a separate change with its own links to fix. `*_probe.ahk` is the
convention the newer ones already follow.

Nothing broke in the move, and that is worth one line: `MMA_ROOT` comes from `A_LineFile` in
[paths.ahk](src/core/paths.ahk), not from `A_ScriptDir`, so a test one folder deeper still
resolves every path in MMA. Only the tests' own `#Include "../src/…"` lines needed the extra
`../`. That is exactly the property paths.ahk's header was written to promise.

### 1.5 Install / packaging

[install.bat](install.bat) → [install.ps1](tools/install/install.ps1) (installs AHK via winget, optionally
Python + deps, and **switches the Python features off in the cfg if you decline**),
[createShortcut.bat](tools/install/createShortcut.bat), [icon.ico](assets/icon.ico),
[installer/MMA.iss](tools/installer/MMA.iss) + [installer/build.bat](tools/installer/build.bat) (Inno Setup).

### 1.6 Docs

[README.md](README.md) (install + features; its "File structure" section is now out of date),
[CHANGELOG.md](CHANGELOG.md), **[docs/guide.html](docs/guide.html)** (the user guide — every
button, the paste format, the advanced features and a troubleshooting table; this is what the
Settings → Scripts' **How to Use** button opens),
[docs/mass-format.md](docs/mass-format.md) (the paste format alone, in markdown, for reading in
an editor), [branching_feature.md](docs/proposals/branching.md)
(the proposal the branch builder came from — **built**, see §9),
[automation/UI-ELEMENT-MAP.md](src/services/automation/UI-ELEMENT-MAP.md) (measured Infloww geometry —
the source of truth for `automation.py`), [pinger/README.md](src/services/pinger/README.md),
[typelog/README.md](src/services/typelog/README.md).

### 1.7 Delete

| File | Why |
|---|---|
| `Spellcheck` | 4 bytes. Contains the word `Tho`. Tracked in git. |
| `grey_debug.txt` | 12 KB of pixel-scan output from tuning `features.ahk`. Tracked in git. |
| `mass_gui.cfg.bak`, `mass_archive.txt.bak` | Already gitignored; stale local copies. |
| `automation/__pycache__/`, `pinger/__pycache__/`, `infloww ui elements/__pycache__/` | Ignored, but three of them is a smell. |
| `infloww ui elements/debug/` | 11 miss-screenshots from a past tuning session. |

---

## 2. Why it feels scattered

Not because there are too many files — 69 is fine. Three specific reasons:

1. **Role is invisible.** Nothing distinguishes "library you `#Include`" from "process
   that runs" from "message content you edit daily" from "dev rig you last opened in
   May". They are all `*.ahk` in one folder.
2. **A feature is spread across four roles and you have to know all four.** The stats
   overlay is: `stats_overlay.ahk` (the process) + a `FEAT_Def` in `modes.ahk` + a
   `HK_Def` in `hotkeys.ahk` + a launcher in `processes.ahk` + a `[StatsOverlay]` section
   in the cfg. That fan-out is *by design* and it is good design — the registries are what
   keep hotkeys and features from drifting. But it means the folder tree can never put a
   whole feature in one place, so it should at least make the **process** easy to find.
3. **Names carry no path information.** `mass_runtime` / `mass_parser` /
   `hotstring_index` / `hotstring_overloads` / `model_detector` are prefixes doing the job
   a folder should do.

---

## 3. Proposed tree

### The naming law

> **A folder's name is the global prefix its functions use.**

AHK v2 has no namespaces — every function is global, so this repo already namespaces by
prefix: `HK_`, `HSI_`, `OL_`, `FEAT_`/`MODE_`, `MMA_`. Making the folder match the prefix
means a path reads as a sentence and an LLM (or you, in three months) can go from
`HSI_Build` to `src/hotstrings/index.ahk` without a search. Two corollaries:

- **Drop the prefix from the filename once the folder carries it.**
  `mass_runtime.ahk` → `src/mass/runtime.ahk`.
- **Never name a file for what it *contains*; name it for what it *does*.**
  `features.ahk` fails this test; so does `guide.md`.

### The tree

```
MMA/
├── MMA.ahk                     ← the one thing you double-click (was mass_gui.ahk)
├── README.md
├── CHANGELOG.md
├── ARCHITECTURE.md             ← this file
├── version.txt
├── install.bat
│
├── src/                        code. nothing in here is yours to edit as a user.
│   ├── core/                   ─ shared plumbing; MMA_ / HK_ / FEAT_ / MODE_
│   │   ├── paths.ahk              every path in MMA, from one anchor
│   │   ├── hotkeys.ahk            the registry: HK_Def / HK_Bind / HK_Broadcast
│   │   ├── modes.ahk              Easy vs Advanced; FEAT_Def
│   │   ├── utils.ahk              snd/Sendt, AFK, the active-model gate
│   │   ├── coords.ahk             named screen coordinates
│   │   ├── crashlog.ahk           OnError → error_log.txt
│   │   ├── reply_tiers.ahk        how long is that wait, and what colour. pure
│   │   └── processes.ahk          start/stop/watch the children
│   │
│   ├── ui/                     ─ every window you look at
│   │   ├── main_window.ahk        the GUI (was mass_gui.ahk — see §4.6)
│   │   ├── actions_menu.ahk
│   │   ├── modes_window.ahk       (was modes_gui.ahk)
│   │   ├── tools_window.ahk       the Tools button: background tools, live state
│   │   ├── startup_scripts.ahk    Hotstrings ▸ Startup scripts: live state per script
│   │   ├── credit.ahk             the corner picture: GDI+ scaling + GIF playback
│   │   ├── lock_badge.ahk         the LOCKED strip, while lock mode is on (§5.1.2.2)
│   │   ├── activity_window.ahk    the typing-stats chart    ← standalone entry point
│   │   ├── webview/activity.html  the page it draws (SVG; no CDN, no libraries)
│   │   ├── hotkeys_window.ahk     (was hotkeys_gui.ahk)     ← standalone entry point
│   │   └── hotstrings_window.ahk  (was hotstrings_gui.ahk)  ← standalone entry point
│   │
│   ├── mass/                   ─ the mass-message feature
│   │   ├── engine.ahk             ← entry point. ONE process for all models (§5)
│   │   ├── runtime.ahk            what a mass does: follow-ups, alts, branches
│   │   ├── parser.ahk             the !mm / f1 / --Branch paste format → data
│   │   ├── store.ahk              read/write userdata/masses.json
│   │   └── archive.ahk            mass_archive.txt + its viewer
│   │
│   ├── chat/                   ─ Infloww navigation; nav.* and chat.*
│   │   └── nav.ahk                (was buried in 1_mass.ahk — see §5)
│   │
│   ├── hotstrings/             ─ HSI_ / OL_
│   │   ├── index.ahk              parse hotstrings out of the message sources
│   │   └── overloads.ahk          one trigger, several variants
│   │
│   ├── branch/                ─ the conversation tree behind the builder. BR_
│   │   └── tree.ahk              its file, its compiler, its !mma emitter
│   │
│   ├── activity/              ─ how you work, counted. ACT_
│   │   ├── tracker.ahk           the recorder                ← entry point
│   │   └── record.ahk            the per-minute counter format + its reader
│   │
│   ├── screen/                 ─ everything that reads pixels
│   │   ├── ocr_grab.ahk           drag a box → text
│   │   ├── tab_marks.ahk          stars + separators you stick on your own tabs
│   │   ├── click_wall.ahk         holds a click on the list while a send runs
│   │   ├── model_detector.ahk     which model tab is active   ← entry point
│   │   ├── stats_overlay.ahk      the KPI overlay             ← entry point
│   │   ├── reply_scan.ahk         the unread-dot scan. pure, shared
│   │   └── reply_box.ahk          boxes rows kept waiting     ← entry point
│   │
│   ├── vendor/                 ─ third party. never edited. LICENSE stays beside it.
│   │   ├── OCR.ahk  OCR.LICENSE   (was lib/)
│   │   └── json.ahk               needed by mass/store.ahk (§5)
│   │
│   ├── sequences/              ─ scripted click/type macros
│   │   ├── sequences.ahk          Discord open + mass import  ← entry point
│   │   ├── recorder.ahk           record one, write it back   ← entry point
│   │   └── composer.ahk           (was features.ahk — or fold into sequences.ahk)
│   │
│   ├── services/               ─ background processes with their own lifecycle
│   │   ├── automation/            automation.py + .vbs + UI-ELEMENT-MAP.md
│   │   ├── pinger/                pinger.pyw + .vbs + reference/ + requirements.txt
│   │   └── typelog/               typelog.pyw + .vbs + scope_debug.py + requirements.txt
│   │
│   ├── capitalizer.ahk         ← entry point; too small for a folder of its own
│   └── updater.ahk             ← entry point
│
├── content/                    HAND-WRITTEN AHK ONLY. nothing here is generated.
│   ├── general.ahk                always-on shared hotstrings
│   └── accounts/                  (was acc/) — toggled per account
│       └── ALIW.ahk  BRI.ahk  TEMP.ahk  UND.ahk
│
├── userdata/                   every setting, every message, every log, in one place.
│   ├── hotkeys.default.ini        ← THE ONE TRACKED FILE. what ships; seeds hotkeys.ini
│   ├── hotkeys.ini                your keys
│   ├── mass_gui.cfg               your settings + calibrated OCR rects
│   ├── masses.json                your masses — GUI-owned (§5, was 1/2/3_mass.ahk)
│   ├── hotstring_overloads.ini    your overload variants
│   ├── mass_archive.txt           every mass you have parsed
│   ├── branch_trees.json          the conversation trees the builder draws (§9)
│   ├── activity/                  one CSV per day per process — counts, never text
│   ├── detector_status.ini        machine state
│   └── error_log.txt              machine state
│
├── assets/                     copy_text.png, icon.ico, anime_girl*.gif|png (§ credit.ahk)
│
├── tools/                      dev only. never runs in a session.
│   ├── test/                   the self-tests. assert, print, exit. §1.4.1
│   ├── install/                install.ps1, createShortcut.bat
│   ├── installer/              MMA.iss, build.bat, WELCOME.txt
│   ├── *_probe.ahk             bind a key and stay resident. the opposite of a test
│   ├── discord_header_test.ahk (a probe, despite the name)
│   ├── model_detect_test.ahk   (a probe, despite the name — or delete, superseded)
│   └── ui-research/            (was "infloww ui elements" — the space is hostile)
│
└── docs/
    ├── guide.html              the user guide — Settings > Scripts > "How to Use"
    ├── mass-format.md          (was guide.md) — the paste format, in markdown
    └── proposals/branching.md  (was branching_feature.md)
```

### What this buys

- **"Where is X"** is one hop. Stats overlay → `src/screen/`. The paste format →
  `src/mass/parser.ahk`. Your messages → `content/`.
- **Blast radius is visible.** Everything under `content/` and `userdata/` is safe to
  edit and safe to lose; everything under `src/` is not.
- **Settings stop being scattered.** Six gitignore rules across the root collapse into
  one folder rule — and it closes the `mass_gui.cfg` leak in §1.3.
- **Entry points are marked**, which is the one thing a folder tree can't express on its
  own (they are mixed in with libraries by necessity, since AHK runs files, not modules).

#### Why `config/` and `userdata/` are one folder

The ships-vs-yours distinction is real, but it does not need a folder to carry it —
`.default` in the filename already carries it, and it carries it *better*: the seed now
sits directly beside the file it creates, so "where does `hotkeys.ini` come from" is
answerable by looking at one directory listing. One folder also means one answer to
"where are my settings", which is the question that actually gets asked.

The cost is that `userdata/` is no longer uniformly ignored, and **the obvious gitignore
rule silently fails**:

```gitignore
# WRONG — git never descends into an excluded directory, so the negation is dead
userdata/
!userdata/hotkeys.default.ini

# RIGHT — exclude the contents, not the directory
userdata/*
!userdata/hotkeys.default.ini
```

This is worth getting right the first time: the failure mode is that
`hotkeys.default.ini` quietly stops being tracked, and nobody notices until a fresh
clone has no keys to seed from.

---

## 4. What breaks if you just move files

`paths.ahk` already did the hard 80% — 37 uses of `A_ScriptDir "\…"` are gone. These five
are what is left, and **each fails silently**, which is the dangerous part: `IniRead` with
a default just returns the default, so settings quietly revert and nothing says why.
Fix all five *before* moving a single file.

**4.1 — `HK_Broadcast` matches on `HK_DIR`, and that stops being the repo root.**
[hotkeys.ahk:406](src/core/hotkeys.ahk#L406) finds MMA's scripts by testing whether a window title
starts with `HK_DIR "\"`. `HK_DIR` is hotkeys.ahk's own folder. Move it to `src/core/` and
that prefix becomes `…\MMA\src\core\`, which **no running script's path starts with** — so
every hotkey rebind, suspend, and Actions-menu fire silently stops reaching every other
process. Same shape of bug in `HSI_DIR` and `OL_DIR`.
*Fix:* delete all three local anchors and route them through `MMA_ROOT` from `paths.ahk`.
That is the single change that unblocks the whole restructure.

**4.2 — the cfg stores bare filenames.**
`StartupScripts=1_mass.ahk,ALIW.ahk,TEMP.ahk,general.ahk,sequences.ahk`,
`HiddenScripts=BRI.ahk,UND.ahk`, `DefaultHotkeyFile=TEMP.ahk`. Once those five live in
three different folders, a name no longer determines a path.
*Fix:* one resolver in `paths.ahk` — `MMA_ScriptPath(name)` searching the known script
folders — and keep the cfg storing bare names, so nobody's existing settings break.

**4.3 — `mass_gui.ahk` builds model paths by hand, in five places.**
`SCRIPT_DIR "\" A_Index "_mass.ahk"` at lines
[1639](src/ui/main_window.ahk#L1639), [1864](src/ui/main_window.ahk#L1864), [1897](src/ui/main_window.ahk#L1897),
[1981](src/ui/main_window.ahk#L1981), [1993](src/ui/main_window.ahk#L1993), plus four hard-coded
`["1_mass.ahk","2_mass.ahk","3_mass.ahk"]` arrays.
*Fix:* `MMA_ModelFile(n)` in `paths.ahk`, one definition.

**4.4 — `HSI_Files()` is a hard-coded list** ([hotstring_index.ahk:33](src/hotstrings/index.ahk#L33))
of `general.ahk` + four `acc\*.ahk` paths. Every one of those relative paths changes.
*Fix:* enumerate `content/` instead, which also stops the list going stale when you add
an account — the exact failure mode `HK_Broadcast`'s comment describes for the old
hotkeys_gui list.

**4.5 — three files are read as *text*, not `#Include`d.** `recorder.ahk` writes code into
`sequences.ahk` and `hotkeys.ahk`; `mass_gui.ahk` scrapes `waitTime` out of `utils.ahk`;
`sequences.ahk` builds a WinTitle from `mass_gui.ahk`'s path. All five already go through
`MMA_SRC_*` in `paths.ahk` — **just update those five constants** and they follow. This
one is already solved; don't re-solve it.

**4.6 — renaming `mass_gui.ahk` is the one risky move.** Its path is a WinTitle
(`MMA_SRC_GUI`), the updater relaunches it by name, `installer/MMA.iss` and
`createShortcut.bat` point at it, and every existing user's desktop shortcut names it.
Either keep the name, or ship a root `MMA.ahk` that is a two-line launcher for
`src/ui/main_window.ahk` and leave the old name working for a release.

**4.7 — no migration shim is needed.** Moving settings into `userdata/` would normally
reset every existing install silently (`IniRead` finds nothing, returns its default, and
your keys and archive are gone with no error). **MMA v2 has no installed base**, so this
is a clean break: no legacy-path fallback, no shim to carry, no `HK_CFG`-style "read only
for migration" comment to maintain. Three constants in `hotkeys.ahk` — `HK_INI`,
`HK_INI_DEFAULT`, `HK_CFG` — just become `MMA_*` names in `paths.ahk` pointing at
`userdata/`, and `HK_CFG`'s migration path can be deleted outright.

**4.8 — the model detector fails by lying, not by going quiet.** It found tabs by grouping
columns holding *either* pill colour into runs. `InactiveColor` defaulted to `0x0D0D0D`,
which a probe of the live strip ([detector_probe.ahk](tools/detector_probe.ahk)) found in
**82 of 83 columns** — it is the page background, because Infloww draws inactive tabs with
no fill at all. Every column therefore qualified, no gap ever appeared, and one run spanned
the whole strip. `GreyTol=22` compounded it by also matching `0x3D3D3D`, a border line
drawn across all 83 columns.

Two consequences, both silent:

- OCR was handed the whole strip and returned **`AW Bellarama`** — two model names in one
  string, which then matched two slots and resolved to none.
- The count was reported as **`tab 1 of 1`**, so positional mode answered "model 1" for
  every tab, forever. Every shared key sent model 1's messages.

Fixed in three parts. The lit pill is now grouped from **active-coloured columns only**, so
it cannot merge with a neighbour whatever `InactiveColor` turns out to be. A run as wide as
the region is rejected rather than OCR'd. And a tab count that collapses to one full-width
run is reported as **`0` — "cannot count"** — not as `1`, so positional mode returns *no
answer* and the shared keys do nothing instead of guessing.

That last one is the general rule this file keeps re-learning: **a detector that cannot see
must say so.** The cost of "no answer" is a key that does nothing. The cost of a confident
wrong answer is one model's message in another model's chat.

Calibration is still per-screen, and `detector_probe.ahk` is how you do it: it prints the
colours actually present, what the current settings find, and what it would OCR.

**4.9 — `PixelGetColor` costs ~30ms a call on this machine, and that was the whole
detector bug.** Measured, not estimated:

| | before (per-pixel) | after (one BitBlt) |
|---|---|---|
| sample 3 tab slots (~150 px) | **4632 ms** | 10 ms |
| sweep the 330×50 band (~1000 px) | **10828 ms** | 15 ms |

`model_detector.ahk` polls every 500ms and did a full sweep each time, so it ran
roughly **20× slower than its own poll interval** — permanently behind, never once
writing a current reading. That is the real reason auto-detection never worked, and it
is why every earlier explanation (wrong `InactiveColor`, wrong `GreyTol`, tab counting,
centroid matching) fitted the symptoms and fixed nothing: each was tested against data
that was seconds stale. Two consecutive runs of the probe disagreed about the strip's
whole palette, which should have been the tell.

`PixelGetColor` goes through GDI `GetPixel` on the screen DC; on a composited desktop
that can round-trip the GPU per call. `PILL_Grab` BitBlts the band into a memory DIB
once — about the cost of a single `GetPixel` — and every pixel after that is a memory
read. Everything that reads the strip now takes a captured buffer.

**The lesson worth keeping: measure the cost of a loop before theorising about its
output.** Four rounds of colour and geometry theories went by while the input was
stale, and none of them could have been right.

### Suggested order

All of it is done.

1. ~~Delete junk; fix `.gitignore`; untrack `mass_gui.cfg`.~~
2. ~~Anchors → `MMA_ROOT`; enumerate the hotstring sources.~~
3. ~~`MMA_ScriptPath`. No migration shim needed (4.7).~~
4. ~~Move `content/`, `userdata/`, `src/`, `tools/`, `docs/`; update README and the
   installer.~~
5. ~~§5: one engine, and the mass library as data.~~

What is NOT done is runtime testing against the live Infloww UI — everything
above is verified by parsing, by unit tests, and by running the engine, which is
not the same as watching a follow-up land in a chat box.

---

## 5. v2: one mass engine, not three model processes

**Decision: `1_mass.ahk` / `2_mass.ahk` / `3_mass.ahk` collapse into one process reading
one data file.** The manual-editability requirement that justified them being hand-shaped
AHK source is gone.

**Non-decision, stated explicitly because it is the easy mistake:** the *hotkeys* stay
per-model. Merging the processes and merging the id sets look like the same change and are
not — see [§5.1](#51-the-manual-scheme-survives-untouched-merging-ids-would-kill-it-merging-processes-doesnt).

### The split isn't costing three files — it's costing five mechanisms

The three model scripts are three *processes*, and all three try to bind the same physical
keys (the Scimitar F13–F15 especially). AHK registers a hotkey per process, so one press
fires all three. Everything below exists only to stop that:

| Mechanism | Where | What it's for |
|---|---|---|
| `StartFuGating` / `UpdateFuGating` | [utils.ahk:81](src/core/utils.ahk#L81) | A **350 ms timer, in each process**, re-reading `detector_status.ini` off disk to flip the other models' keys `Off` |
| ~~`UniversalSendActive`~~ | *removed* | Picked one process to answer `__mm` — "otherwise all three would expand the hotstring at once and triple-backspace the typed trigger". Moot since the three mass processes became one `engine.ahk`; deleted outright in §5.2 |
| `HK_ModelSendIds` | [hotkeys.ahk:359](src/core/hotkeys.ahk#L359) | Lists which ids are shared, so gating knows what to toggle |
| Conflict-report exemption | [hotkeys_gui.ahk:145](src/ui/hotkeys_window.ahk#L145) | Model send keys must be exempt from each other's duplicate check |
| `FuGate()` | [utils.ahk:60](src/core/utils.ahk#L60) | Per-handler re-check at fire time |

One process needs **none** of this. But note carefully what it does *not* mean — see §5.1.

### 5.1 The manual scheme survives untouched. Merging ids would kill it; merging processes doesn't.

**Do not collapse `mass.1.*` / `mass.2.*` / `mass.3.*` into one `mass.*` id set.** Those
three sections are not redundancy — they are MMA's *manual addressing scheme*, and
`hotkeys.ini` shows it is the primary one:

| | fu1 | fu2 | fu3 | ppv | smFu1-3 |
|---|---|---|---|---|---|
| `[mass.1]` | F1 | F2 | F3 | F4 | **F13 F14 F15** |
| `[mass.2]` | F9 | F10 | F11 | F12 | **F13 F14 F15** |
| `[mass.3]` | F6 | F7 | !F7 | F8 | **F13 F14 F15** |

Two schemes already coexist in that table, and the split is exactly where you would draw
it by hand:

- **Explicit / manual** — distinct keys per model. F1-F3 is model 1, F9-F11 is model 2.
  **The key you press *is* the model selector, so no detector is involved at all.**
- **Shared / detected** — `smFu1-3` on F13-F15, identical in all three sections, resolved
  at runtime by whichever model is on screen.

These are two independent decisions, and only the first is safe:

| Decision | Verdict |
|---|---|
| Three processes → **one process** | **Do it.** Kills the arbitration machinery above. |
| Three id sets → **one id set** | **Don't.** Deletes manual mode. |

They don't conflict, because per-model ids cost nothing in a single process:
`mass.1.fu1`=F1 and `mass.2.fu1`=F9 are different physical keys and coexist happily. Each
handler just carries its model number, and **no gate is involved**:

```autohotkey
HK_Bind("mass.1.fu1", (*) => DoFu(1, 1))
HK_Bind("mass.2.fu1", (*) => DoFu(2, 1))
```

That is already better than today, where `fu1`-`fu3` *are* in `HK_ModelSendIds` and
therefore gated — so with the detector on and model 2 in front, **F1 goes dead.** A manual
user who also runs the detector loses their manual keys, which is not a trade anyone asked
for.

The only ids that genuinely cannot stay per-model are the **shared** ones: registering
F13 three times in one process just overwrites it twice. Those become one explicit set:

```ini
[mass.1]       fu1=F1   fu2=F2   fu3=F3    …   ← manual. no detector needed.
[mass.2]       fu1=F9   fu2=F10  fu3=F11   …
[mass.3]       fu1=F6   fu2=F7   fu3=!F7   …
[mass.active]  fu1=F13  fu2=F14  fu3=F15       ← follows the active model
               mFu1=XButton2  mFu2=XButton1    ← same actions, mouse buttons
[mass.select]  m1=^!1   m2=^!2   next=^!w      ← say which model is active
```

### 5.1.1 The mouse buttons are shared keys, and were not

`mFu1`-`mFu3` shipped under `[mass.1]`. There is one XButton1 and it is under your thumb
whichever tab is open, so declaring it under a model means it sends **that** model's
follow-up forever: pressing it in front of model 2 sent model 1's message to model 2's fan.
Anything a per-model section declares must be a key you would only press *for that model*.
A mouse button never is. They live in `[mass.active]` now.

`[mass.active]` also carries the whole action set — PPV, branches, alts, the mass body —
not just `fu1`-`fu3`. A shared set that stops at follow-ups still leaves you working out
which numbered key owns the PPV for the model in front, which is the problem it exists to
remove.

### 5.1.2 `[mass.select]` — the third way to resolve the active model

Name and position both go through the screen detector, and the detector's failure mode is
not silence. It is a **confident wrong answer**: a scan that merges the strip into one run
reports "tab 1 of 1" forever, and every shared key then sends model 1 whatever is on
screen. That is what shipped — see §4.8.

`ModelMatch=manual` reads no pixels. A `[mass.select]` key names the model, MMA stores it
in `[Settings] CurrentModel`, and the shared keys follow it until you press another one.
Pressing one also switches `ModelMatch` to `manual`, because a key labelled "active model
= 2" that left the detector in charge would be lying about what it does.

The shared follow-up and PPV keys don't rely on that memory any more — in this mode they
open the picker window and send on your answer (§ `model_picker.ahk`). The remembered model
survives underneath it, for the two shared keys that don't ask and for the mixed-platform
fallback, which is why Settings has no dropdown for it: it is a consequence, not a setting.

### 5.1.2.1 Four keys, one section of Settings

Settings ▸ Models writes all four, and nothing else does:

| key | values | means |
|---|---|---|
| `[Settings] SharedKeys` | `1` / `0` | do the `[mass.active]` keys resolve a model at all. Off, they bail and log it; the numbered keys are unaffected. Read per keypress by `SharedKeysOn()` |
| `[Settings] ModelMatch` | `manual` / `name` / `position` | `manual` is the Strategy radio. The other two are the **OnlyFans (Infloww)** auto strategy — this key has only ever described that side |
| `[Fansly] Match` | `name` / `position` | the Fansly auto strategy. Defaults the other way round, because the rail truncates its labels — see `core/fansly_model.ahk` |
| `[Positional] Pos<i>` / `[FanslyPos] Pos<i>` | model slot | which model tab *i* / rail row *i* is. Two different windows, two orders, no reason to match |

### 5.1.2.2 Lock mode — the picker's answer, given once

The window in §5.1.2 asks *which model* on every shared follow-up key, and that is right for
the question it asks and wrong for the way the work arrives. A shift is worked one model at a
time: every message for Aliw, then every message for Rama. Asking per keypress means twenty
windows for one answer, and **a window you dismiss by reflex has stopped being a safeguard** —
it is a keystroke tax that also trains you to click without reading.

The shape it is built for, stated as the sequence it is:

> pick the model in the window → **lock** → clear that model's messages → **unlock** → next model

`[Settings] LockedModel` (0 = off) is that answer, stored once. While it is set, `_RunOnActiveModel`
returns the locked model **before the mode check and before any pixel is read**: no picker, no
detector, no fallback chain. Three entry points write the one key — the `mass.select.lock` key,
a **live toggle in the picker window** (a checkbox that flips the lock on click, not a promise about
the pick that follows: the sequence above locks *after* the model is settled), and the main window's
Lock button (a different process, hence a 700 ms poll rather than a message) — and none of them
needs to know the others exist.

Two decisions in it are worth keeping:

**A select key MOVES a lock.** `^!2` under a lock re-aims it rather than being ignored, because
"done with this model, on to the next" is the sentence the feature was asked for. Refusing would
cost three keys for one thought; ignoring it silently would print a toast naming a model the
shared keys were not going to send.

**It is not a fourth `ModelMatch` value.** A lock applies in name and position mode too, where it
overrides a working detector. That is a thing you would only ask for deliberately — and it is
only safe to offer because of the badge below.

#### The badge is the condition, not the decoration

This is a mode in which a key you press sends to a model **nothing on screen identifies** —
precisely the failure shape §4.8 is about, arrived at on purpose this time. So `ui/lock_badge.ahk`
puts a small always-on-top strip on screen for as long as the lock lasts, naming the model, not
taking focus (`WS_EX_NOACTIVATE` — every keystroke here belongs to a chat box), and acting as the
unlock button. A tooltip could not do it: tooltips expire and this state lasts twenty minutes.
MMA's own window could not either — it is behind Infloww all shift, which is the one place you are
not looking.

The general rule, stated once: **the visible indicator is what buys the shortcut.** Without it
this feature would be a silent re-aim of every shared key, and would not be worth shipping.

### 5.1.3 Positional mode: which TAB, then which MODEL

Two steps, and only one of them is a measurement:

| step | answered by | how |
|---|---|---|
| which **tab** is in front | the screen | colour, no OCR |
| which **model** that tab is | Settings | you said so |

Step 2 is not something a detector should ever try to work out. Tab 1 is Aliw because
you put it there, and no pixel carries that fact. Every round of this that went wrong
went wrong by trying to infer it — from OCR'd names, from tab counts, from taught
coordinates.

Step 1 is arithmetic, not a search, because model tab positions are **fixed**: the strip
starts at `TabOrigin` and each tab is `TabPitch` wide (measured: 30 and 150), so the lit
pill's x *is* the tab index. Only the tab you are ON has to be visible — which matters,
because inactive tabs are drawn in the page background and are invisible to a colour
scan. Counting them was never possible.

Set the order in Settings' dropdowns, or **by pointing at it**: pressing "active model =
2" while that tab is in front records "whatever tab index this is, is model 2". Nobody
knows their tab is index 2; everybody knows the tab they are looking at is Rama.

`PILL_PickLit` refuses rather than guesses in two cases, both returning "no answer":
nothing reaches `MinGrey` (no tab lit, or the colour/region is wrong), and the runner-up
is more than half the winner (one pill straddling two slots, i.e. `TabPitch` is wrong).

Verified live: pill at x116 spanning 28–184 — 156px, matching the 150 pitch — resolving
to tab 1, model 1, with OCR reading `AW` alone rather than `AW Bellarama`.

#### 5.1.3.1 Which site is in front — a title is not evidence

`FanslyWindowUp` and `DetectorWindowUp` both used to be one `WinActive(WinMatch)` call, on
the assumption that each site is its own application with its own title. On a real desk it
is not: **Infloww shows both sites**, so the two windows are the same executable, both
titled `Infloww Messages`, one per monitor — and the word `Fansly` that `[Fansly] WinMatch`
looks for turns up in the *OnlyFans* window too, because a model is named `KB FANSLY`.
Since `ActiveModelStatus` asks Fansly **first** and returns on any answer but `off`, that
one title took the shared keys away from the site you were working in, silently.

Two things fixed it, in order of authority:

| test | where | what it adds |
|---|---|---|
| **the visual cue** | `FanslyCueSays`, `screen/fansly_scan.ahk` | OCRs a **window-relative** band (`[Fansly] Cue*`) and looks for `CueText`, vetoed by `CueNotText`. The only test that can separate two windows of one program. Cached per window handle for `CueMs`, because this is on the keystroke path. `CueW=0` (shipped default) leaves it off. |
| **the geometry gate** | `PILL_ActiveHolds`, `screen/pill_scan.ahk` | the window in front must *cover* the region about to be scanned. A region that is not inside it is about to measure some other window's pixels. Decisive when the two sites are separate apps or separate monitors. |

The negative test is not decoration: Infloww's own sidebar says **"All inboxes"**, which
contains "Inbox". A cue of `Inbox` alone therefore fires on both sites, and being wrong in
that direction is the expensive one.

### 5.1.4 Mixed platforms — some models are somewhere MMA cannot see

Infloww has a tab strip the detector reads. Fansly is a different interface with nothing
calibrated for it, and there is no reason to assume every site a model works will ever
have a detector. So the platform is **per model**, in `[Settings] Platform<n>`:

| value | meaning |
|---|---|
| `infloww` (default) | the detector answers for this model |
| `manual` | nothing on screen identifies it — you say which model it is |

The numbered keys never needed this: `F1`-`F3` mean model 1 wherever you are. What needed
it is the **shared** set — the side mouse buttons — which follow "the active model" and
therefore had no answer off Infloww.

Resolution becomes:

| situation | answer |
|---|---|
| Infloww focused, a tab lit | that tab's model |
| Infloww focused, no tab lit | **nothing** — a real detection failure, do not guess |
| Infloww not focused, picked model is `manual` | that model |
| Infloww not focused, picked model is `infloww` | **nothing** |

That last row is the whole reason the flag exists rather than a blanket "fall back to the
last manual pick". Applied to an Infloww model, the fallback would turn a detection
failure into the wrong model's message, silently — the exact failure mode this area keeps
producing. Applied only to models marked invisible to the detector, it is not a guess at
all: it is the only thing they could mean.

Switching back to Infloww needs no keypress; the window being focused is the signal.

`SelectModel` also branches on it: for a `manual` model the press means "this is the model
now" and nothing else. Letting it reach `TeachPosition` would map whatever Infloww tab
happened to be lit to a Fansly model and quietly reroute that tab's sends.

### 5.2 `__mm` with N models — SUPERSEDED, then dissolved

`__mm` is a single hotstring, not a per-model key, so it has no model to read off the
keypress. v1's `UniversalSendActive` answered "detector off → model 1", unconditionally.
That did not mean a manual model-2 user got *nothing* when they typed `__mm` — it meant
they got **model 1's mass, sent to their fan.** A wrong mass is worse than no expansion.

**The shipped resolution was: manual mode disables bare `__mm` and answers with `__mm1` /
`__mm2` / `__mm3` instead.** The number selects the model because you said so, the same
contract the manual F-keys use (§5.1): the thing you type IS the model selector.

Those two schemes were mutually exclusive **by construction, not by policy**, and the
reason was the hotstring options. `__mm` is declared `:*X:`, and `*` means *fire as soon
as the trigger is typed, no ending character* — so while `__mm` was live it expanded the
instant you typed the second `m`, and the `1` in `__mm1` was never reached.
`NumberedSendActive` therefore gated on the same condition that silenced `__mm`, keeping
*what is registered* equal to *what can happen*.

#### What replaced it

Two things broke that answer.

**It capped at three.** `__mm1`/`__mm2`/`__mm3` were written out by hand, and 2.0.2 made
the model count a setting up to twelve. `__mm11` could not have been added even in
principle — the `__mm1` before it would have fired first.

**It went dead where it was wanted most.** The one situation in which you genuinely do
not know which model's mass you are about to paste is several models and no detector, and
that is exactly the state in which bare `__mm` expanded to nothing.

**The digit moved to the front.** `__1mm` shares no prefix with `__mm`, so the two are
live simultaneously, nothing has to be gated on anything, and the naming does not run out
at nine — `__11mm` is just another trigger. `UniversalSendActive` and
`NumberedSendActive` are **deleted**; a note at their old site in
[active_model.ahk](src/core/active_model.ahk) says where they went. The numbered triggers
are registered by a loop over `MASS_MODELS`, near the top of
[runtime.ahk](src/mass/runtime.ahk) rather than beside `__mm` — top-level code stops
running at the first hotstring definition in the script, so written next to `__mm` the
loop would parse and never execute.

**And bare `__mm` asks.** One model configured, it pastes that one. Two or more, it opens
[model_picker.ahk](src/mass/model_picker.ahk) — the "I pick" window, generalised from a
follow-up group to `group = "mass"` — with the first line of each model's live mass on the
button that will paste it. That preview is also the only place in MMA that shows an
**empty** mass slot before you paste it, which is the whole of the standing "`__mm` does
nothing" complaint.

The mass pick aims one paste and does **not** call `SetManualModel`. A follow-up pick
does: choosing a model for a follow-up is a statement about which model you are working
on, and the shared `[mass.active]` keys should follow it. Choosing one for `__mm` is not,
and making it stick would be a mode change wearing a convenience's clothes.

### What else collapses

- **`massNo` stops being source code.** Which of `m1`/`m2`/`m3` is live is *state*, and
  today the GUI stores it by rewriting a line of a running script. In v2 it is a cfg key.
- **`UniversalSendActive`'s model-1 special case** goes away with §5.2's answer — and in
  the end the function went with it.

The evidence that the split has already stopped earning its keep is in your own config:
`StartupScripts=1_mass.ahk,ALIW.ahk,TEMP.ahk,general.ahk,sequences.ahk` — **2_mass.ahk and
3_mass.ahk are not started at all.** All five mechanisms above are currently arbitrating
between one running process.

### Go one step further: data, not code

Since nobody hand-edits these any more, the merged file should not be AHK source.

Today `mass_gui.ahk` *generates* AHK by string-splicing — `EscQ` / `UnescQ` / `AHK_CHARS`
exist purely to make message text survive a round trip through AHK syntax. That is a
serializer written against a programming language's grammar, and its failure mode is
nasty: a save that produces subtly wrong source produces a file that **won't load, exits
0, and says nothing** — the exact class of bug already hit with `base` being a reserved
key. Data files do not have syntax errors that silently kill a process.

```
userdata/masses.json          ← models[].masses[].{mass,fu1,fu1_5,…,alts,branches,ppv}
```

Three further wins:

1. `src/mass/parser.ahk` keeps parsing the `!mm` paste format, but its output is a plain
   object instead of a source-code string. `EscQ`/`UnescQ` and `AHK_CHARS` are deleted.
2. Saving a mass stops meaning "rewrite executable code that is currently `#Include`d".
3. [branching_feature.md](docs/proposals/branching.md) wants a **web** editor that emits mass
   definitions. A browser tool emitting JSON that AHK reads is trivial; one emitting
   correct AHK source is grim.

Cost: AHK v2 has no built-in JSON, so this vendors a small JSON lib into `src/vendor/`,
alongside `OCR.ahk` — which is the precedent that makes vendoring uncontroversial. The
zero-dependency alternative is ini, which MMA already speaks, but ini has no nesting and
masses are nested three deep (model → mass → alts/branches); you would be escaping `\n`
by hand, which is the same trap in a new costume.

### Tree changes this implies

- `content/models/` **disappears.** `content/` is then a clean rule: *hand-written AHK
  only* — `general.ahk` and `accounts/`. Nothing in it is generated.
- `userdata/masses.json` sits next to `mass_archive.txt`, which is already "every mass you
  have parsed". Live masses beside archived masses is the obvious home.
- `src/mass/engine.ahk` becomes the entry point (was `1_mass.ahk` + `mass_runtime.ahk`).
- **The nav keys need a home.** `1_mass.ahk` owns `nav.*`, `chat.*` and the utility keys
  purely because it is "the script that is always running" — that is not a reason, it is
  an accident. They are Infloww chat navigation and have nothing to do with masses. Give
  them `src/chat/nav.ahk`, included by the engine rather than spawned separately, so no
  new process appears and `HK_Def`'s `owner` column finally tells the truth.

---

## 7. Logging: making a silent failure audible

MMA is up to eight processes talking through ini files and `PostMessage`. Nothing in
that arrangement produces a stack trace when it goes wrong — it produces **nothing**,
which is the actual bug report: *"it silently failed to do something on my friend's
machine."*

Read back through this document and the comments in the tree and the same shape keeps
recurring:

- a folder missing from `MMA_ScriptPath`'s list, so a startup script never runs —
  *"no error, no dialog, nothing in the log"*
- an `IniRead` with a default, so a setting quietly reverts
- a key absent from `hotkeys.ini`, so an action is simply unbound
- a feature switched off, so its hotkey never registers
- `engine.ahk` dropped out of `StartupScripts`, so every mass hotkey went dead

**Not one of those throws.** Every one is a branch that returned early, and the only way
to see a branch that returned early is to have written it down on the way past.

### 7.1 How it reaches everything

`src/core/paths.ahk` includes `src/core/log.ahk` **at its end**. `paths.ahk` is the one
file every entry point already includes, which makes it the only place a logger can be
added once and reach everything — including the scripts nobody remembers exist. The
include is circular (`log.ahk` names `paths.ahk` too, since it may be included directly)
and that is fine: AHK loads a given file once however many times it is named.

Each process therefore gets, with no code of its own:

| Line | When |
|---|---|
| `BOOT` | at load, before the script's own code can fail — so a script that dies during load still leaves proof it started |
| `EXIT` | on any exit, including `ProcessClose` from the watchdog and `#SingleInstance` replacement |
| `CRSH` | every uncaught error, **with its stack** |

### 7.2 The six levels

| Level | Call | Means |
|---|---|---|
| `INFO` | `LOGI` | something happened you would want in a timeline |
| `VERB` | `LOGV` | something happened, and there are thousands of them |
| `WARN` | `LOGW` | wrong, but survivable, and nobody is going to notice |
| `FAIL` | `LOGE` | it did not work — the only level that can raise a dialog |
| `BAIL` | `LOG_Bail` | **it deliberately did nothing, and here is why** |
| `DONE` | `LOG_Ok` | a thing that can fail finished |

`BAIL` is the level with no equivalent anywhere else and the reason this exists. A
feature that is off, a key that is unbound, a mass slot that is empty, a window that is
not in front — all correct behaviour, all identical from the user's chair (*nothing
happened*), and all exactly what *"why did it silently do nothing?"* is asking about.

### 7.3 The three switches

`mass_gui.cfg [Debug]`, owned by **Settings ▸ Debug** and written nowhere else — the
same one-control-one-place rule the Features tab follows (§1.3).

| Key | Default | What it does |
|---|---|---|
| `Logging` | **1** | write to `debuglogs\mma.log` at all |
| `Popups` | 0 | a failure also raises a dialog carrying the last 20 log lines |
| `MaxLogging` | 0 | also write the `VERB` firehose |

`Logging` defaults **on** because a log nobody switched on is a log that is empty on the
morning you need it. It costs one `FileAppend` per event.

`Popups` is the *debug on someone else's machine* switch. Off, a failure is a line in a
file they would have to find, open and send you. On, it is a dialog in front of them
carrying the context — which they can screenshot. Same information; only one of those
two actually arrives. Dialogs are budgeted (same message once per process, 15 per
process, 60s timeout) so a failure inside a 500ms timer cannot become a machine you have
to reboot.

They are written **the instant you click**, not on Save: the switches are read by eight
processes, all of which re-read the cfg on a 1.5s timer, so a click is live everywhere
within a second and a half with no broadcast and no restart. A debugging switch you have
to remember to Save is a switch that is off in the log you finally go and read.

`MMA_DEBUG=max|popups|off` in the **environment** overrides all three, for the machine
you cannot open Settings on. When it is set the checkboxes are disabled and say so —
a checkbox that silently does nothing because something outside the app is winning is
precisely the failure this whole feature exists to stamp out.

### 7.4 Two files, deliberately

| File | What |
|---|---|
| `debuglogs\mma.log` | the full timeline, every process, one line per event. Rotates at 8 MB to `mma.log.1`. |
| `debuglogs\error_log.txt` | `FAIL` and `CRSH` only, so it stays short enough to read top to bottom. |

*"What broke"* and *"what was happening when it broke"* are different questions and want
different files. `LOGE` writes both — and writes them **even when `Logging` is off**,
because a failure is never noise.

### 7.5 The diagnostic report

**Settings ▸ Debug ▸ Diagnostic report** writes one file to hand over:
environment, `mass_gui.cfg` and `hotkeys.ini` in full, `userdata\` file names and sizes,
and the last 400 log lines. Masses and message text are deliberately **excluded** — the
report gets sent to somebody, and those are the user's work, not diagnostic data.

*"Send me your log"* otherwise produces a log with no idea what version, what mode or
what settings produced it, and then a second round trip.

### 7.6 Two traps worth knowing

**`Log()` and `Ln()` are AutoHotkey built-ins** (base-10 and natural logarithm). A
user-defined `LOG()` shadows the built-in, so every file that includes the logger works
perfectly — and every file that does *not* silently binds to the built-in instead, where
`LOG("tag", "msg")` fails at **load** with *"Too many parameters passed to function"*.
The failure lands in a file that never mentioned logging. Hence `LOGI`, which collides
with nothing and makes the four levels symmetrical. Likewise never name a top-level
loop variable `ln`.

**A logger must never crash the thing it is logging for.** Every path in `log.ahk` is
inside a `try`, including the ones that look incapable of throwing. Nothing is buffered
either — the tail of the file before a crash is the whole reason you are reading it.

---

## 8. The activity tracker: counting without recording

`activity/tracker.ahk` installs a global keyboard hook. It sees every keystroke of a
working shift, which means it sees **every message sent to every fan** — so the only
version of this feature worth shipping is one that structurally cannot retain them.

### What makes that structural rather than a promise

The format has nowhere to put a character. `activity/record.ahk` writes
`minute,counter,value` and nothing else; the counter names are a closed list
(`keys`, `chars`, `bksp`, `mouse`, `active`, `max.gap`). There is no free-text
field to leak into, no window title, no hotstring trigger. The hook itself is handed
a virtual key code, adds one to a number, and drops it — `ActIsChar` deliberately
classifies by VK *range* rather than tracking modifier state, because modifier state
is a keylogger's data structure and refusing to build one is cheaper than being
careful with it.

Two supporting details:

- **`MinSendLevel := 1`** makes the hook ignore MMA's own sends. Without it a mass
  paste would land in `keys`, and the number the whole feature reports — how fast
  *you* type — would rise the more work MMA did for you.
- **`KeyOpt("{All}", "I")`** stops the InputHook accumulating text in its own buffer,
  with a once-a-second guard in `ActTick` that rebuilds the hook if it ever does
  anyway. That guard is the reason the "I" option is an optimisation rather than a
  load-bearing assumption.

### Off by default, and that is not a taste call

Every other `FEAT_Def` default is about whether a feature is *useful*. This one is
about consent: "counts your keystrokes" is a thing somebody switches on deliberately,
not something they discover already running. Its hotkey goes with it — a chart of
nothing is not a feature — which is why `gui.activity` is owned by the tracker rather
than the main window.

### Why one file per process per day (activity)

Only the tracker writes today. A single shared file would work right up until the
second writer arrives, at which point two processes append to one file and the loser
of the race silently loses a minute. Same reasoning that gave Fansly its own status
file (§ `MMA_FANSLY`), and it costs one `Loop Files` in the reader. A counter named
`max.<x>` merges by maximum rather than by sum — a stall is not a quantity you can add
up across two processes, and a reader that did would report a pause that never
happened. `tools/test/activity_test.ahk` is mostly about that one rule.

---

## 9. The branch builder: a tree that compiles into a mass

`docs/proposals/branching.md` asked for a web editor that draws conversation flows —
"fu1→resp1→fu2→resp2 … kind of like git?" — and said parsing it back was part 2 of the
problem. **There is no part 2**, and the reason is one sentence:

> **One root-to-leaf path through the tree = one named branch.**

### Why that works

A branch in `masses.json` is *not* a tree. `::mexican` is a parallel WORDING of
f1/f2/f3 that TAB cycles at send time — six columns beside the trunk, no forking, no
notion of what the fan said. A conversation, though, alternates:

```
!mm  →  fan replies  →  f1  →  fan replies  →  f2  →  f3
```

Enumerate every path through that and each one is a complete conversation — a full
f1/f2/f3/ppv column. The first path is the trunk; the rest become named branches. So
nothing in the engine changed, nothing in the parser changed, and the format the builder
emits is the format `Export !mma` already writes. The whole feature is a compiler
(`src/branch/tree.ahk`) plus a drawing surface.

### A fan-reply node sends nothing, and is not decoration

It costs no follow-up level — it is the fan talking, not you — and it does two jobs:

- it **names the branch**. `::plays-along` beats `::br2` when you are looking at a
  picker window mid-shift.
- it is the only place the tree records **why the fork exists**. A branch whose reason
  is not written down is a branch nobody dares delete.

A merge point is reached by several *different* replies, so the card shows one chip per
incoming route (`fan says` / `or says`). Showing only the first was a real bug: the tree
still held the second, nothing on screen said so, and the only way to change it was to
delete the merge.

### Limits are reported, never truncated

A path may hold at most `MASS_FU_DEPTH` (3) `say` nodes and there are at most
`MASS_BRANCH_MAX` (6) branches beside the trunk. Both are **errors with a count in
them**, not silent truncation — §4.8's rule applies exactly as it does to a detector.
The cost of "no answer" is a message you move yourself; the cost of a confident wrong
answer is a chain that sends three of its four steps and looks like it worked. The
builder makes the limit *visible* instead: one column per follow-up, so the room you
have left is on screen before you run out of it.

### One compiler, and the preview cannot lie

The page owns the tree while the window is open; AHK owns the file, the compiler, the
clipboard and `masses.json`. The page never works out what a tree compiles to — it asks,
on a 220 ms debounce, and renders the answer. So the preview pane is produced by the
same function that Save writes, and they cannot drift. A JavaScript copy of the rules
would have been faster and would have been wrong within a week — the same "two files
agreeing by hand about a record shape" this document already rejected for
`MassBlockProps` (§ store.ahk).

### Merging duplicates in storage, not in editing

Two paths that converge on one node write that node's text into both branches, because a
branch stores its whole column. The tree keeps the fact that it was one node, so you
still edit it once. That asymmetry *is* the benefit, and deleting one fork deliberately
does not gut the shared tail the other fork still reaches.

`tools/test/branch_tree_test.ahk` covers the compiler and then round-trips its output
through the **shipping** parser, because the builder's only real claim is "this pastes
into MMA and works".
