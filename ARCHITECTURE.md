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

There are 69 tracked files. They fall into **seven roles**, and today all seven are
mixed together in the repo root. That is the whole problem: `paths.ahk` (a library that
never runs), `1_mass.ahk` (message data), `hotkeys.ini` (your settings) and
`model_detect_test.ahk` (a dev rig from 2026) are peers in the same folder, so nothing
about a filename tells you whether you may edit it, run it, or delete it.

### 1.1 Entry points — processes that actually run

Each of these is its own AHK process. AHK titles a script's main window with its **full
path**, which is how `HK_Broadcast` and `processes.ahk` find and close them.

| File | What it is |
|---|---|
| [mass_gui.ahk](mass_gui.ahk) | **The app.** 80 KB, the largest file here. The main window, the paste/parse box, the model tabs, Settings, Add Hotkey, Branches, the script toggles, and the block-rewriter that saves a parsed mass back into a model file. Supervises every other process. |
| [1_mass.ahk](1_mass.ahk) | Model 1. Three `mN := {...}` data blocks + `MassInit(1)`. Also owns the always-on nav/chat/utility keys, because it is the one model script always running. |
| [2_mass.ahk](2_mass.ahk) / [3_mass.ahk](3_mass.ahk) | Models 2 and 3. Pure data + `MassInit(n)`. |
| [general.ahk](general.ahk) | Always-on shared message hotstrings (`::_gns1::` etc.). |
| [acc/ALIW.ahk](acc/ALIW.ahk) [acc/BRI.ahk](acc/BRI.ahk) [acc/TEMP.ahk](acc/TEMP.ahk) [acc/UND.ahk](acc/UND.ahk) | Per-account message hotstrings. Toggled on/off from the main window; `TEMP.ahk` is the scratch target for Add Hotkey. |
| [sequences.ahk](sequences.ahk) | Recorded click/type macros — Discord open, and the Ctrl+click mass import that OCRs the Discord channel header to pick a model. |
| [capitalizer.ahk](capitalizer.ahk) | Capitalizes the first letter after Enter / `.!?`+space. |
| [model_detector.ahk](model_detector.ahk) | Background service. Pixel-scans the Infloww tab strip for the active model pill, OCRs its name on change, writes it to `detector_status.ini`. This is what lets one set of F-keys serve whichever model tab is focused. |
| [stats_overlay.ahk](stats_overlay.ahk) | Background service. OCRs Sales / PPVs-sent / Fans-chatted off the Infloww **Home** window (via PrintWindow, so unfocused) and shows a colour-graded ratio overlay. |
| [hotkeys_gui.ahk](hotkeys_gui.ahk) | Standalone window: rebind every hotkey. A pure view over `hotkeys.ini`. |
| [hotstrings_gui.ahk](hotstrings_gui.ahk) | Standalone window: search the whole message library by trigger *or* by the text inside, jump to source, create overloads. |
| [recorder.ahk](recorder.ahk) | Records mouse/keyboard into a new sequence and **writes AHK code into `sequences.ahk` and `hotkeys.ahk`**. |
| [updater.ahk](updater.ahk) | Pulls updates from the GitHub raw URL, then relaunches `mass_gui.ahk`. Separate process so it can overwrite the GUI. |
| [automation/automation.py](automation/automation.py) | Python background listener. Serves the `[automation]` hotkeys (hop kebabs, unsend last, count sales) by locating Infloww UI elements from a measured geometry map. Optional. |
| [pinger/pinger.pyw](pinger/pinger.pyw) | Python background service. Beeps when an Infloww fan tab goes unread, by scanning for the `#ff7c71` unread dot/badge. Optional. |

### 1.2 Libraries — `#Include`-only, never run alone

| File | What it is |
|---|---|
| [paths.ahk](paths.ahk) | **The anchor.** Every path in MMA derived from `A_LineFile`, so nothing depends on which script is `A_ScriptDir`. Read its header before moving anything. |
| [hotkeys.ahk](hotkeys.ahk) | The central hotkey registry. Contains **no keys** — only `HK_Def` declarations (id, label, context, owner). Keys live in `hotkeys.ini`. Also owns `HK_Bind`, `HK_Broadcast` and the cross-process message protocol. |
| [modes.ahk](modes.ahk) | Easy vs Advanced, and the one registry (`FEAT_Def`) of every optional feature. In Easy mode features are switched **off**, not hidden. |
| [utils.ahk](utils.ahk) | 26 KB grab bag: `snd()`/`Sendt()` send helpers, AFK handling, the active-model gate (`FuGate`/`ModelIsActive`), plumbing hotstrings. Included by every message script. |
| [coords.ahk](coords.ahk) | Named screen coordinates + Corsair Scimitar button aliases. Written to by `recorder.ahk`. |
| [crashlog.ahk](crashlog.ahk) | `OnError` → `error_log.txt`. Deliberately separate from `utils.ahk` so `mass_gui.ahk` can have crash logging without inheriting utils' hotstrings. |
| [mass_runtime.ahk](mass_runtime.ahk) | **All model behaviour, once.** Follow-ups, alts, branches, PPV, the Settings toggles. Model files are data because this exists. |
| [mass_parser.ahk](mass_parser.ahk) | The `!mm` / `f1` / `--Branch` / `~alt` paste format: parse it in, escape it back out. |
| [archive.ahk](archive.ahk) | `mass_archive.txt`'s format, its one parser, and the viewer window. |
| [processes.ahk](processes.ahk) | Start/stop/watch the five children. AHK ones are found by window title; the two Python ones sign in with a **named event** instead. |
| [actions_menu.ahk](actions_menu.ahk) | Searchable window over every registered action, generated from `HK_ORDER`. Runs actions by broadcasting their index — including actions with no key bound. |
| [modes_gui.ahk](modes_gui.ahk) | The Easy/Advanced + per-feature checkbox window, generated from `modes.ahk`. |
| [hotstring_index.ahk](hotstring_index.ahk) | Parses `:*:trigger::{ snd("…") }` blocks out of the message `.ahk` files into records. The one writer is `HSI_DeleteBlock`. |
| [hotstring_overloads.ahk](hotstring_overloads.ahk) | Lets one trigger have several variants (ask / random) **without ever rewriting your source files** — it re-points the trigger at runtime. |
| [ocr_grab.ahk](ocr_grab.ahk) | Drag a box on screen → OCR it → text. Feeds Add Hotkey. |
| [features.ahk](features.ahk) | 933 bytes, two functions: click the 2nd grey icon in the composer strip, plus a debug tooltip version. Included only by `1_mass.ahk`. Misnamed — nothing "features" about it. |
| [lib/OCR.ahk](lib/OCR.ahk) | **Vendored third party** (`lib/OCR.LICENSE`). Wraps `Windows.Media.Ocr` — offline, nothing to install. |

### 1.3 Config that ships vs. state the machine owns

These are mixed together in the root today, and the git rules for them are inconsistent.

| File | Owner | Tracked? |
|---|---|---|
| [hotkeys.default.ini](hotkeys.default.ini) | ships | yes — correct |
| `hotkeys.ini` | user | no — correct, `HK_Init` creates it from the default |
| [mass_gui.cfg](mass_gui.cfg) | user | **yes — wrong.** Holds your model names, `HiddenScripts`, calibrated OCR rects and the `DefaultFu3` message body. Same class of personal data as `hotkeys.ini`, which is correctly ignored. UTF-16LE. |
| [hotstring_overloads.ini](hotstring_overloads.ini) | user | yes — currently only a test entry |
| `detector_status.ini` | machine | no — correct |
| `mass_archive.txt` | user | no — correct |
| `error_log.txt` | machine | no — correct (130 KB locally) |
| [version.txt](version.txt) | ships | yes |

### 1.4 Dev rigs — never run in a real session

| File | What it is |
|---|---|
| [model_detect_test.ahk](model_detect_test.ahk) | The prototype `model_detector.ahk` grew out of. Hard-codes "grey on the left = AW, right = BUT". Superseded. |
| [discord_header_test.ahk](discord_header_test.ahk) | Still useful: tunes the `[Discord]` header band that the mass-import fallback OCRs. |
| `infloww ui elements/` | Gitignored. Five Python detector prototypes, the sliced element bitmaps, annotated screenshots, and the technique write-ups. Contains **real fan handles** in the screenshots — that is why it is ignored. |
| [pinger/test_detect.py](pinger/test_detect.py) | Pinger's detection test against the reference PNGs. |

### 1.5 Install / packaging

[install.bat](install.bat) → [install.ps1](install.ps1) (installs AHK via winget, optionally
Python + deps, and **switches the Python features off in the cfg if you decline**),
[createShortcut.bat](createShortcut.bat), [icon.ico](icon.ico),
[installer/MMA.iss](installer/MMA.iss) + [installer/build.bat](installer/build.bat) (Inno Setup).

### 1.6 Docs

[README.md](README.md) (install + features; its "File structure" section is now out of date),
[CHANGELOG.md](CHANGELOG.md), [guide.md](guide.md) (the paste format — this is *user*
documentation with a developer-ish name), [branching_feature.md](branching_feature.md)
(unimplemented proposal for a web branch editor),
[automation/UI-ELEMENT-MAP.md](automation/UI-ELEMENT-MAP.md) (measured Infloww geometry —
the source of truth for `automation.py`), [pinger/README.md](pinger/README.md).

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
│   │   └── processes.ahk          start/stop/watch the children
│   │
│   ├── ui/                     ─ every window you look at
│   │   ├── main_window.ahk        the GUI (was mass_gui.ahk — see §4.6)
│   │   ├── actions_menu.ahk
│   │   ├── modes_window.ahk       (was modes_gui.ahk)
│   │   ├── hotkeys_window.ahk     (was hotkeys_gui.ahk)     ← standalone entry point
│   │   └── hotstrings_window.ahk  (was hotstrings_gui.ahk)  ← standalone entry point
│   │
│   ├── mass/                   ─ the mass-message feature
│   │   ├── engine.ahk             ← entry point. ONE process for all models (§5)
│   │   ├── parser.ahk             the !mm / f1 / --Branch format → data
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
│   ├── screen/                 ─ everything that reads pixels
│   │   ├── ocr_grab.ahk           drag a box → text
│   │   ├── model_detector.ahk     which model tab is active   ← entry point
│   │   └── stats_overlay.ahk      the KPI overlay             ← entry point
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
│   │   └── pinger/                pinger.pyw + .vbs + reference/ + requirements.txt
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
│   ├── detector_status.ini        machine state
│   └── error_log.txt              machine state
│
├── assets/                     copy_text.png, icon.ico
│
├── tools/                      dev only. never runs in a session.
│   ├── install/                install.ps1, createShortcut.bat
│   ├── installer/              MMA.iss, build.bat, WELCOME.txt
│   ├── discord_header_test.ahk
│   ├── model_detect_test.ahk   (or delete — superseded)
│   └── ui-research/            (was "infloww ui elements" — the space is hostile)
│
└── docs/
    ├── mass-format.md          (was guide.md) — the paste format
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
[hotkeys.ahk:406](hotkeys.ahk#L406) finds MMA's scripts by testing whether a window title
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
[1639](mass_gui.ahk#L1639), [1864](mass_gui.ahk#L1864), [1897](mass_gui.ahk#L1897),
[1981](mass_gui.ahk#L1981), [1993](mass_gui.ahk#L1993), plus four hard-coded
`["1_mass.ahk","2_mass.ahk","3_mass.ahk"]` arrays.
*Fix:* `MMA_ModelFile(n)` in `paths.ahk`, one definition.

**4.4 — `HSI_Files()` is a hard-coded list** ([hotstring_index.ahk:33](hotstring_index.ahk#L33))
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

### Suggested order

1. ~~Delete junk; fix `.gitignore` (`userdata/*` + `!userdata/hotkeys.default.ini`);
   untrack `mass_gui.cfg`.~~ **done**
2. ~~Fix 4.1 (anchors → `MMA_ROOT`), 4.3 (`MMA_ModelFile`), 4.4 (enumerate).~~ **done**
3. ~~Add `MMA_ScriptPath` (4.2). No migration shim needed (4.7).~~ **done**
4. ~~Move `content/`, `userdata/`, `src/`, `tools/`, `docs/`; update README and
   `installer/MMA.iss`.~~ **done** — all 19 entry points validate clean.
5. **Next: §5 proper.** Collapse the three model processes into one engine and move the
   mass data out of `.ahk` source into `userdata/masses.json`. §5.1's hotkey scheme and
   §5.2's `__mm` decision are already in place, so this step is now only about the
   process merge and the data format — not about paths, and not about key semantics.

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
| `StartFuGating` / `UpdateFuGating` | [utils.ahk:81](utils.ahk#L81) | A **350 ms timer, in each process**, re-reading `detector_status.ini` off disk to flip the other models' keys `Off` |
| `UniversalSendActive` | [utils.ahk:67](utils.ahk#L67) | Picks one process to answer `__mm` — "otherwise all three would expand the hotstring at once and triple-backspace the typed trigger" |
| `HK_ModelSendIds` | [hotkeys.ahk:359](hotkeys.ahk#L359) | Lists which ids are shared, so gating knows what to toggle |
| Conflict-report exemption | [hotkeys_gui.ahk:145](hotkeys_gui.ahk#L145) | Model send keys must be exempt from each other's duplicate check |
| `FuGate()` | [utils.ahk:60](utils.ahk#L60) | Per-handler re-check at fire time |

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
[mass.active]  fu1=F13  fu2=F14  fu3=F15       ← follows the detected model
```

`[mass.active]` is precisely what `StartFuGating` is *simulating* today by flipping three
copies on and off every 350 ms. Naming it directly buys three things:

1. The timer, `HK_ModelSendIds`, and the whole gating layer are deleted.
2. **The conflict report becomes honest.** `CanCollide`/`IsGatedSend` exist only to stop
   the GUI crying wolf about three copies of a shared key. One real binding needs no
   exemption.
3. **A real conflict stops being hidden.** `[mass.1] brPick=F6` and `[mass.3] fu1=F6` are
   the same key, and [hotkeys.ahk:352](hotkeys.ahk#L352) already knows it. Because
   `HK_ModelSendIds` lists `brPick`, `IsGatedSend` returns true for both, so `CanCollide`
   exempts the pair and the GUI **never reports it** — even though the comment at
   [hotkeys_gui.ahk:181](hotkeys_gui.ahk#L181) claims the branch keys are "never gated"
   and this case *is* flagged. The code and its own comment disagree; with an explicit
   `[mass.active]`, the ambiguity that produced that disagreement is gone.

### Correction to the file-count argument

Merging does **not** reduce declaration count. 52 per-model `HK_Def`s minus the 9 shared
(`smFu1-3` × 3) leaves 43, plus a small `mass.active.*` set — call it even. Likewise
`MassInit`'s "models 2 and 3 have no mouse or short-key variants" asymmetry does not
vanish for free; giving them those slots still costs per-model declarations, it is just no
longer *blocked* by process arithmetic.

The win was never fewer lines. It is: **one process instead of three, no polling timer, no
cross-process arbitration, honest conflict reporting, and manual mode that keeps working
whether the detector is on or off.**

### 5.2 `__mm` in manual mode — DECIDED, and shipped

`__mm` is a single hotstring, not a per-model key, so it has no model to read off the
keypress. v1's `UniversalSendActive` answered "detector off → model 1", unconditionally.
That did not mean a manual model-2 user got *nothing* when they typed `__mm` — it meant
they got **model 1's mass, sent to their fan.** A wrong mass is worse than no expansion.

**Resolution: manual mode disables bare `__mm` and answers with `__mm1` / `__mm2` /
`__mm3` instead.** The number selects the model because you said so, which is the same
contract the manual F-keys already use (§5.1): the thing you type IS the model selector.

The two schemes are mutually exclusive **by construction, not by policy**, and the reason
is the hotstring options. `__mm` is declared `:*X:`, and `*` means *fire as soon as the
trigger is typed, no ending character* — so while `__mm` is live it expands the instant
you type the second `m`, and the `1` in `__mm1` is never reached. `NumberedSendActive`
therefore gates on the same condition that silences `__mm`. Registering the numbered
triggers in automatic mode anyway would leave three hotstrings that look bound, appear in
the manager, and can never fire; gating them keeps *what is registered* equal to *what can
happen*.

Both gates live in [utils.ahk](src/core/utils.ahk); the triggers are at the bottom of
[runtime.ahk](src/mass/runtime.ahk).

### What else collapses

- **`massNo` stops being source code.** Which of `m1`/`m2`/`m3` is live is *state*, and
  today the GUI stores it by rewriting a line of a running script. In v2 it is a cfg key.
- **`UniversalSendActive`'s model-1 special case** goes away with §5.2's answer.

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
3. [branching_feature.md](branching_feature.md) wants a **web** editor that emits mass
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
