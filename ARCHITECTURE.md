# MMA — architecture

**What this is:** a description of the code as it stands. Present tense throughout. If
something here does not match the tree, this file is wrong and the tree is right.

**What this is not:** the reasoning. Why there is one mass engine instead of three model
scripts, why `paths.ahk` exists at all, what breaks if you move a file — that is
[docs/decisions.md](docs/decisions.md), the design record this file was carved out of.

---

## 1. The shape of it, in one paragraph

MMA is **not one program**. It is a supervisor window plus up to a dozen small resident
processes, each owning a slice of behaviour, that never call each other. They coordinate
two ways only: **shared files** in `userdata\` say *what the data is*, and **window
messages** declared in [core/messages.ahk](src/core/messages.ahk) say *go and re-read it*.
That is why a setting saved in the GUI applies on the very next keypress in the mass
engine, with no restart — they share a file, not memory. Every process finds everything
through one anchor, [core/paths.ahk](src/core/paths.ahk); and AHK titles a script's main
window with its **full path**, which is how processes find and close each other.

---

## 2. The spine

Read in this order. Nothing here depends on anything below it.

| layer | files | what it establishes |
|---|---|---|
| 0 | [core/paths.ahk](src/core/paths.ahk) · [core/log.ahk](src/core/log.ahk) | every path from one anchor; one log for every process |
| 1 | [core/modes.ahk](src/core/modes.ahk) · [core/hotkeys.ahk](src/core/hotkeys.ahk) · [core/messages.ahk](src/core/messages.ahk) | the feature registry, the hotkey registry, the message bus |
| 2 | [mass/store.ahk](src/mass/store.ahk) · [mass/parser.ahk](src/mass/parser.ahk) | what a mass **is** — as data, and as text |
| 3 | [mass/runtime.ahk](src/mass/runtime.ahk) · [mass/engine.ahk](src/mass/engine.ahk) | what a mass **does** |
| 4 | [screen/pill_scan.ahk](src/screen/pill_scan.ahk) · [core/active_model.ahk](src/core/active_model.ahk) | which model is on screen |
| 5 | [ui/main_core.ahk](src/ui/main_core.ahk), then the shells | the app, then its windows |

Counted by `#Include` across the repo, five files carry the tree:

```
paths.ahk   47      store.ahk   11
hotkeys.ahk 14      utils.ahk   10
theme.ahk   13      dpi.ahk     10
```

`src/ui/` is 13,500 lines — a third of the codebase — and almost nothing includes it.
Windows are the outermost layer, not the centre.

---

## 3. Processes — what actually runs

Each is its own process. **AHK scripts** are found and closed by their window title
(`<full path> ahk_class AutoHotkey`). **Python services** have no AHK window, so each
signs its presence with a **named event**: opening it answers "is it up?" in one DllCall,
setting it means "please exit". That is why the Python children cannot ride on
`startupScripts` and are not closed by `KillAllScripts`.

`WatchdogTick` in [core/processes.ahk](src/core/processes.ahk) relaunches anything that
died, while `startupScripts` is on.

### Always up

| process | role |
|---|---|
| [ui/webview_main_window.ahk](src/ui/webview_main_window.ahk) *or* [ui/main_window.ahk](src/ui/main_window.ahk) | **The app.** One of the two shells, chosen by `MMA_ShellFor("main")`. WebView is the default; Win32 ("legacy") is still fully supported. Supervises every other process. Shared logic lives in [ui/main_core.ahk](src/ui/main_core.ahk). |
| [mass/engine.ahk](src/mass/engine.ahk) | **The mass process. One of them, for all models.** Loads the library, binds `[mass.1..3]`, the shared `[mass.active]` set, the `[mass.select]` keys, and the nav/chat keys. Re-reads the library on `MMA_MSG_MASSES_CHANGED`. |
| [sequences/sequences.ahk](src/sequences/sequences.ahk) | Recorded macros, and the Discord Ctrl+click import that OCRs the channel header to pick a model. **Deliberately not a registry feature** — it owns hotkeys, and the import is how masses get into MMA at all. |
| [content/general.ahk](content/general.ahk) · [content/accounts/](content/accounts/) | Message hotstrings, shared and per-account. Started from **Hotstrings ▸ Startup scripts**. `TEMP.ahk` is the scratch target for Add Hotkey. |
| [capitalizer.ahk](src/capitalizer.ahk) | Capitalizes after Enter and after `.!?`+space. |

### Background services

| process | default | what it does |
|---|---|---|
| [screen/model_detector.ahk](src/screen/model_detector.ahk) | off | Pixel-scans the Infloww tab strip for the lit pill, OCRs its name on change, writes `detector_status.ini`. This is what lets one set of keys serve whichever model tab is focused. |
| [screen/fansly_detector.ahk](src/screen/fansly_detector.ahk) | off | The same job on the Fansly **vertical rail**. Its own switch and its own status file — two services writing one file is two services racing over `active_model`, and the loser wins about half the time. |
| [screen/stats_overlay.ahk](src/screen/stats_overlay.ahk) | off | OCRs Sales / PPVs / Fans off the Infloww **Home** window via PrintWindow — so, unfocused — and colour-grades the ratio. |
| [screen/reply_box.ahk](src/screen/reply_box.ahk) | off | Boxes conversations that are unread and have waited past a threshold. Needs **two** calibrations. Arithmetic in [core/reply_tiers.ahk](src/core/reply_tiers.ahk), dot-finding in [screen/reply_scan.ahk](src/screen/reply_scan.ahk). |
| [activity/tracker.ahk](src/activity/tracker.ahk) | off | Counts keys, clicks and active seconds into `userdata\activity\`. It counts, and is **built so that it cannot record what** — see [activity/record.ahk](src/activity/record.ahk). |
| [services/automation/automation.py](src/services/automation/automation.py) | on | Serves the `[automation]` keys by locating Infloww UI elements from a measured geometry map. |
| [services/pinger/pinger.pyw](src/services/pinger/pinger.pyw) | off | Beeps when a fan tab goes unread, by scanning for the `#ff7c71` dot. |
| [services/typelog/typelog.pyw](src/services/typelog/typelog.pyw) | off | Records the text you type while Infloww is in front, to mine for hotstrings. The mirror image of the activity tracker: that one is built so it cannot keep what you typed, this one exists to keep it. |
| [services/autoword/autoword.pyw](src/services/autoword/autoword.pyw) | off | Next-word suggestions trained on the typelog corpus, plus Ctrl+Tab to reword. Ships in `Render=off` — predicting, drawing nothing. |

**No Python on PATH silently disables four of these.** `PythonAvailable()` scans PATH
directly rather than shelling out to `where` (which would flash a console every startup),
and ignores zero-byte Microsoft Store aliases, which open the Store instead of running.

### Opened on a key, then gone

[ui/hotstrings_window.ahk](src/ui/hotstrings_window.ahk) ·
[ui/hotkeys_window.ahk](src/ui/hotkeys_window.ahk) /
[ui/hotkeys_webview.ahk](src/ui/hotkeys_webview.ahk) ·
[ui/settings_webview.ahk](src/ui/settings_webview.ahk) ·
[ui/branch_window.ahk](src/ui/branch_window.ahk) ·
[ui/activity_window.ahk](src/ui/activity_window.ahk) ·
[sequences/recorder.ahk](src/sequences/recorder.ahk) ·
[updater.ahk](src/updater.ahk)

The three WebView windows each carry an Edge runtime, so each is its own process — the
main window must never block waiting for one to open. That is the whole reason
`MMA_MSG_OPEN_SETTINGS` and `MMA_MSG_ADD_HOTKEY` exist: a separate process cannot call
into the main window's globals, so it asks the window that owns them.

---

## 4. The five registries

Everything declarative lives in exactly one file. This is the most useful thing to know
about the codebase.

| registry | file | declares |
|---|---|---|
| **Features** | [core/modes.ahk](src/core/modes.ahk) | `FEAT_Def(id, cfgKey, label, default, section)` — every optional feature, once. `FEAT(id)` is the only question the rest of the code asks. |
| **Hotkeys** | [core/hotkeys.ahk](src/core/hotkeys.ahk) | `HK_Section` / `HK_Def(id, label, when, owner)` — every key, its context, and which process owns it. |
| **Messages** | [core/messages.ahk](src/core/messages.ahk) | every `0x80xx` window message. Use the **name** at both ends; a literal is how `0x8002` came to mean two different things. |
| **Services** | [core/processes.ahk](src/core/processes.ahk) | `SVC_Def(id, kind, path, tag, noun, extra)` — every background service. `id` is a FEATURE id, so the label, the cfg key and the switch all still come from `FEAT_META`. |
| **Paths** | [core/paths.ahk](src/core/paths.ahk) | every path, derived from `A_LineFile` — never `A_ScriptDir`, which is the folder of whichever script you double-clicked. |

Two couplings worth memorising:

- **`FEAT_HOTKEY_MAP`** (in `modes.ahk`) ties hotkey-id prefixes to features, so `HK_Bind`
  refuses to register a key whose feature is off. One central gate, instead of a guard in
  every script. Matched longest-prefix-first, so `mass.1.altFu1` finds `altFu` while plain
  `mass.1.fu1` matches nothing and stays unguarded.
- **Easy mode switches features off; it does not hide them.** A hidden feature still
  interferes — the detector silently gating a model's send keys is exactly the class of
  surprise Easy exists to remove. `FEAT()` is *the feature's own checkbox* **AND**
  *Advanced mode*, so flipping back to Advanced restores every choice untouched.

---

## 5. Data — the files that are the state

`userdata\` is gitignored except for `hotkeys.default.ini`. Note the `/*` in
[.gitignore](.gitignore): git never descends into an excluded *directory*, so `userdata/`
plus a negation would silently stop tracking the default, and nobody would notice until a
fresh clone had no keys to seed from.

| file | owner | what it holds |
|---|---|---|
| `masses.json` | GUI writes, engine reads | **The mass library.** The field list is `MASS_Fields()` in [mass/store.ahk](src/mass/store.ahk) — add a field there and the loader, writer, blank-record builder and migration all follow. |
| `mass_gui.cfg` | Settings | every `[Settings]` key, including each feature's `cfgKey`. Never tracked: it carries model names, calibrated rects and message bodies. |
| `hotkeys.ini` | the hotkey editor | every binding. `hotkeys.default.ini` **ships**, and `HK_MergeDefaults` folds in new keys without touching one that already has a value. |
| `detector_status.ini` / `fansly_status.ini` | the two detectors | the active model, per platform. Separate files on purpose. |
| `mass_archive.txt` · `branch_trees.json` · `hotstring_overloads.ini` | GUI | the archive, the branch builder's trees, hotstring overloads. |
| `chat_sim.json` | the chat simulator | the fan's half of the simulated conversation, per model+slot, plus where the window was last looking ([mass/sim_notes.ahk](src/mass/sim_notes.ahk)). Deliberately NOT in `masses.json`: everything in that file goes out to somebody. |
| `hotstring_usage.ini` | **every message script**, on each send | which hotstrings you use and which you pinned — the quick menu's whole memory ([hotstrings/usage.ahk](src/hotstrings/usage.ahk)). The one file in here written at keystroke rate, and the reason it is not another section of `hotstring_overloads.ini`. |
| `activity\` · `typelog\` · `autoword\` | their services | per-process per-day counters; recorded text; the trained model. |

`debuglogs\` is separate from `userdata\`, and that separation is load-bearing:
diagnostics are **throwaway**, and mixing them in put them next to `masses.json` and
`hotkeys.ini` — the two files you must never delete by mistake. `mma.log` is the full
timeline every process appends to; `error_log.txt` is the short, failures-only list. Both
are written by `LOGE`, deliberately: "what broke" and "what was happening when it broke"
want different files.

---

## 6. Layer by layer

**`src/core/`** — shared plumbing: `paths` `log` `crashlog` `modes` `hotkeys` `messages`
`theme` `dpi` `coords` `processes` `active_model` `fansly_model` `reply_tiers` `utils`.
`utils.ahk` is the odd one out: it holds `Snd`/`Sendt` and the whole alt/branch send
stage, so it is a *sending* file that lives in core because the hotstring content files
include it.

**`src/mass/`** — the product. `store` (shape) → `parser` (text format) → `runtime`
(behaviour) → `engine` (the process). Plus `archive`, `next_fu`, `model_picker`.

**`src/screen/`** — everything that reads pixels, split deliberately in two: **pure
scanners** with no side effects (`pill_scan`, `rail_scan`, `reply_scan`) and **services**
built on them (`model_detector`, `fansly_detector`, `reply_box`, `stats_overlay`). The
split exists so that a service and its Settings calibrator cannot disagree about geometry.
Also `ocr_grab`, `tab_marks`, `click_wall`.

**`src/ui/`** — every window. Each dual-shell window splits into a `*_core.ahk` (the logic,
with no window in it) and two shells: `*_window.ahk` (Win32) and `*_webview.ahk` (Edge over
a page in [ui/webview/](src/ui/webview/)). Panels — `features_panel`, `hotkeys_panel`,
`debug_panel` — are Guis built *inside* a parent window's process, not their own.

**`src/services/`** — the Python side. Each has its own `README.md` and
`requirements.txt`. `llm/` (Ollama reply drafting) is the newest and has no UI yet.

**`src/activity/` `src/branch/` `src/hotstrings/` `src/chat/` `src/sequences/`** — one
subsystem each, all small, each with its window (if it has one) over in `ui/`.

**`src/vendor/`** — thqby's WebView2 wrapper, OCR, json. Not yours. Never read it.

---

## 7. Dev rigs

**`tools/test/`** — the self-tests. Every file **asserts and exits**: it prints
`N passed, M failed`, returns 0 or 1, binds no keys and leaves no window. That is the whole
entry requirement, and it is why they can run from **Settings ▸ Debug ▸ Run all** in the
middle of a shift. That button runs `DebugPanel.TESTS` — *add a new test there, or it will
only ever run by hand.* Several write real settings and restore them;
[tools/test/README.md](tools/test/README.md) says which, and how to run one from PowerShell
without `/ErrorStdOut` silently swallowing the output.

**`tools/*_probe.ahk`** — the opposite of a test. A probe binds a key, stays resident, and
exists so you can look at your own screen through it. `model_detect_test.ahk` and
`discord_header_test.ahk` are probes despite their names.

**`tools/ui-research/`** — gitignored. It holds live screenshots with real fan handles.

---

## 8. Conventions

**A folder's name is the global prefix its functions use.** AHK v2 has no namespaces, so
the repo namespaces by prefix: `HK_`, `HSI_`, `OL_`, `FEAT_`/`MODE_`, `MASS_`, `MMA_`.
`HSI_Build` → `src/hotstrings/index.ahk`, with no search. Two corollaries: drop the prefix
from the filename once the folder carries it, and **name a file for what it does, never for
what it contains.**

**Three things reference source as paths rather than `#Include`ing it** — and all three
break silently when files move: `recorder.ahk` *writes code into* `sequences.ahk` and
`hotkeys.ahk`; `main_window.ahk` *scrapes* `utils.ahk` as text for its wait time;
`sequences.ahk` builds a WinTitle from the main window's path. The path constants for all
three sit together at the bottom of `paths.ahk` for exactly this reason.

**Logging is not decoration.** `LOG_Bail` records a feature gate that closed — "the feature
is off" is the correct answer to a startling number of "why did nothing happen" reports.
`FEAT()` logs at VERB and never higher, because it runs from `#HotIf` and from inside send
handlers, tens of times per keystroke.

---

## 9. Recipes

**Add an optional feature:** one `FEAT_Def` line in `modes.ahk`; guard its entry points
with `FEAT("id")`; if it has keys, add a prefix to `FEAT_HOTKEY_MAP`. The Features tab
draws itself from the registry.

**Add a hotkey:** `HK_Section` / `HK_Def` in `hotkeys.ahk`, `HK_Bind(id, fn)` in the
process that owns it, and a default in `hotkeys.default.ini`.

**Add a field to a mass:** add it to `MASS_Fields()` in `store.ahk`. That is the whole
change — the loader, the writer, the blank-record builder and the migration all read that
one list.

**Add a background service:** a `FEAT_Def` line in `modes.ahk`, an `SVC_Def` line in
`processes.ahk`, and the file. That is the whole change — boot, the Features tab, the
Tools window, the Tools button's count and the watchdog all walk `SVC_ORDER`.

It used to touch seven to ten files, because four separate hand-kept lists decided when
each service ran. They had drifted, silently: three services were missing from the boot
list and started five seconds late (never, in Easy mode), and two were missing from the
Features chain, so unticking them wrote the cfg key and left the process running.
`tools/test/services_test.ahk` is what stops a fifth list growing back.

---

## 10. Where else to look

| | |
|---|---|
| [docs/decisions.md](docs/decisions.md) | **why** the tree looks like this — the design record |
| [docs/mass-format.md](docs/mass-format.md) | the mass text format |
| [docs/guide.html](docs/guide.html) | the user-facing guide |
| [development.md](development.md) | working on MMA |
| [CHANGELOG.md](CHANGELOG.md) | what changed, release by release |
