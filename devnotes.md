# devnotes.md

Findings that cost real time to work out, kept so they only cost it once.

Not a changelog (that is `CHANGELOG.md`) and not a design doc (that is
`ARCHITECTURE.md`). This is the "we already tried that" file: symptoms, what they
actually turned out to be, how it was proven, and the theories that looked right
and were wrong.

Every number below was measured on this machine, not estimated. Where a theory was
disproven that is recorded too — a disproven theory is worth as much as a fix,
because it is the one somebody will otherwise re-chase.

---

## MULTI-MONITOR DPI — the root cause behind most "geometry is off" bugs

**Date:** 2026-08-27
**Status:** fixed for every pixel-reading path; deliberately *not* applied to the
GUI processes (see "Not converted" below).

### The symptom

Screen features drift. A selection box lands away from the cursor. An OCR grab
returns text clipped mid-word. A fixed-region scan reads pixels next to the thing
it was calibrated on. Everything looks *plausible*, which is what makes it slow to
find.

### The cause

AutoHotkey ships a **system-DPI-aware** manifest. On a desk where every monitor
shares the primary's scaling that is indistinguishable from being fully aware —
which is exactly why this hid for so long. Put a second monitor on a **different**
scale and Windows starts feeding the process invented numbers for anything on it:
`GetWindowRect`, `GetCursorPos`, the virtual screen, the origin a `BitBlt` reads
from, and where a `Gui` actually lands.

The nasty part is that the wrong numbers are **mutually consistent**. Inside the
process the mouse, the overlay and the capture rect all agree with each other and
disagree only with the screen. So nothing looks obviously broken — it just misses.

### Measured

Desk at the time: primary `1920x1080 @125%` (dpi 120), DISPLAY2 `2160x3840 @150%`
(dpi 144) at origin `(-2160,-323)`.

A `-DPIScale` box asked for at `(-1200,400) 400x200`, i.e. on the second display:

| context | result |
|---|---|
| system-aware (AHK default) | `x=-1008 y=545 480x240` |
| per-monitor aware | `x=-1200 y=400 400x200` |

Off by `144/120 = 1.2` in **both** size and position. `SysGet` virtual screen also
reads `4080x3200` instead of the true `4080x3840`, so a full-screen overlay stops
short of the tall monitor.

> Earlier the same day, on a **single** `3440x1440 @125%` monitor, the identical
> probes came back exact and everything checked out clean. This bug is invisible on
> a one-monitor desk. Never conclude "DPI is fine" from a single-monitor test.

### The fix — `src/core/dpi.ahk`

Two entry points, because the correct one differs by caller:

- **`DPI_ScriptWide()`** — one top-level statement, for a script whose whole job is
  reading pixels. No code path can miss it.
  Used by: `model_detector.ahk`, `fansly_detector.ahk`, `reply_box.ahk`.

- **`DpiScope`** — `_dpi := DpiScope()` as a function's first line, for a library
  `#Include`d into a process that also has a normal Gui. Thread-scoped and
  reversible.
  Used by: `active_model.ahk` (`GrabStrip`), `stats_overlay.ahk` (`OcrRect`),
  `next_fu.ahk` (`NFU_ReadChat`), `fansly_scan.ahk` (x3), `click_wall.ahk` (x4),
  `tab_marks.ahk` (x4), `ocr_grab.ahk` (`OcrGrabToText`).

`DpiScope` restores on a normal return **and** on an exception unwinding through
it — AHK v2 is reference counted, not garbage collected, so `__Delete` fires
deterministically at scope exit. Both paths were verified.

### Two traps inside the fix

**`SetProcessDpiAwarenessContext` does not work here.** It returns `0` with
`A_LastError = 5` (`ERROR_ACCESS_DENIED`), because `AutoHotkey.exe` already
declares awareness in its **manifest** and Windows will not let it be changed
afterwards. The first version of this fix used it and would have silently done
nothing at all.

Use `SetThreadDpiAwarenessContext`. That is sufficient: AHK "threads" are
pseudo-threads sharing one OS thread, so a context set at the top of a script is
still in force inside every hotkey and every `SetTimer` callback — verified two
levels deep.

**Do not put `DPI_ScriptWide()` in a process that builds a logical-unit Gui**
(main window, Settings, Add Hotkey). Those lay out in logical units against
`A_ScreenDPI`, which stays the **system** dpi regardless of awareness — so they
would render at the wrong size on a differently-scaled monitor, with nothing on
screen to say why.

### Not converted

- **The GUI processes**, for the reason directly above. Separate, larger job.
- `tools/detector_probe.ahk`, `tools/fansly_probe.ahk`,
  `tools/detection_overlay_debug.ahk`. These now read differently from the services
  they calibrate. **Treat their numbers with suspicion until converted.**

### Related, and separate: `Gui.Show` scaling

Independent of monitor awareness, `Gui.Show` multiplies **w and h** by
`A_ScreenDPI/96` unless the Gui carries `-DPIScale`. **x and y pass through
untouched.** Measured at 125%:

| Gui | asked | actual |
|---|---|---|
| `-DPIScale` | `700x250` | `700x250` |
| default `+DPIScale` | `700x250` | `875x313` |

This is why every overlay in MMA carries `-DPIScale`. It is load-bearing, not
tidiness.

---

## PAST OCR PROBLEMS AND SOLUTIONS

A running log. Newest first.

### 1. Chat text read back garbled — no `scale` on the call

**Date:** 2026-08-27 · **Fixed** in `src/screen/ocr_grab.ahk`

`OcrRegionToText` was the **only** `OCR.From*` call in the whole codebase passing
no options at all. Every other site passes a scale.

Sweep over one live chat rect (`1046,670 689x241`):

| options | lines | chars | result |
|---|---|---|---|
| *(none — what it did)* | 2 | 106 | `(.. •mag•ne tne nectar tnat would mow out…` |
| `grayscale: 1` alone | 2 | 106 | still garbled |
| `scale: 2, grayscale: 1` | 1 | 35 | **a whole line silently lost** |
| `scale: 3` alone | 1 | 35 | **a whole line silently lost** |
| `scale: 4` | 1 | 35 | **a whole line silently lost** |
| **`scale: 3, grayscale: 1`** | 2 | 105 | `Imagine the nectar that would flow out…` |

Reproduced identically across repeated passes.

Two things worth carrying:

- The recogniser fails by guessing `h→n`, `i→t`, `fl→m` at the glyph size Infloww
  renders at. **`grayscale` is what fixes that, not scale.**
- **`scale: 2` is worse than nothing.** It drops an entire line rather than
  garbling it — the failure you cannot see in a review box. Do not "try scale 2 and
  see how it looks".

`scale: 3, grayscale: 1` is the house standard, already used by
`model_detector.ahk` and `fansly_detector.ahk`. Match it.

### 2. The selection box hid what you were selecting

**Date:** 2026-08-27 · **Fixed** in `src/screen/ocr_grab.ahk` (`HollowBox`)

The drag rectangle was a **solid fill**, drawn on top of the very text being
framed, over a sheet that had already dimmed the desktop. From the moment the drag
started you could not read a word of what you were selecting, so the edges got
placed from memory — and an edge a few pixels out slices a line in half.

That comes back looking exactly like OCR "cutting" text. **It is not.** On a real
grab the box itself had clipped `…Imagine` to `k...` and `her ball` to `ter ball`
*before OCR ever ran* — the engine read every pixel it was given, correctly.

Fix: `SetWindowRgn` with `RGN_DIFF` of the outer rect against an inset one, giving
a hollow frame. Re-punched every drag tick, because a window region is in **window
coordinates** and does not follow a resize.

### 3. Add Hotkey dialog renders at 100% of screen width, not 80%

**Date:** 2026-08-27 · **Fixed** in `src/ui/main_core.ahk`

```ahk
W  := Round(A_ScreenWidth * 0.8)          ; A_ScreenWidth is PHYSICAL
ah := Gui("+Owner" g.Hwnd, "Add Hotkey")  ; no -DPIScale -> scaling ON
ah.Show("w" W " h245")                    ; Gui.Show takes LOGICAL, x1.25
```

`A_ScreenWidth` is physical; `Gui.Show` takes logical and multiplies. On a 3440px
display at 125% the "80%" dialog rendered at exactly 3440px, with `h245` arriving
as 306.

Fix: `W := Round(A_ScreenWidth * 0.8 * 96 / A_ScreenDPI)`. **Not** `-DPIScale` on
that Gui — that strips scaling from every control coordinate while the font stays
scaled, undersizing the whole dialog instead.

Pre-existing and byte-identical at `HEAD`, and correct at 100% scaling. It only
misbehaves above it.

### 4. Overlay teardown → capture race — **DISPROVEN, do not re-chase**

**Date:** 2026-08-27

Plausible theory: `OcrSelectRegion` destroys the sheet and box, then
`OcrRegionToText` BitBlts the screen microseconds later with no wait for the apps
underneath to repaint — and Infloww is Chromium, which repaints on its own
compositor schedule. So OCR could capture the dim sheet still on screen.

**Tested and false.** Reading the same rect immediately after `Destroy()` and again
400 ms later returned **byte-identical** text, three trials in a row. There is no
repaint race. Do not add a `Sleep` here.

### 5. `CleanOcrLine` / `SortByPosition` — verified correct, not a suspect

**Date:** 2026-08-27

Run against a real Infloww chat capture (`tools/ui-research/OCR_TEST.png`): 6 raw
engine lines → 4 messages kept, both timestamp rows correctly dropped, reading
order right. The post-processing is not where text goes missing.

### 6. `OCR.FromRect` reads exactly the rect it is handed

**Date:** 2026-08-27

Verified at 125% by OCR-ing a rect while independently BitBlt-ing the same rect in
physical pixels: the returned word bounding boxes land on the actual pixels
(`Phone` at `x=1345 y=646`, i.e. `345,46` within the crop, precisely where it
sits). The capture path is not a suspect — look at whatever produced the
*coordinates* instead.

---

## STILL OPEN

### Two windows answer to `"Infloww Messages"`

`WinMatch` is a substring test and more than one window matches — same pid, same
`Chrome_WidgetWin_1` class, so neither `ahk_exe` nor `ahk_class` separates them:

| title | size | top-left strip |
|---|---|---|
| `Infloww Messages - 333` | `2616x1381` | the real model tab strip |
| `Infloww Messages` | `1760x1380` | an **Inbox** pill — no model strip at all |

Replaying the live config over PrintWindow captures: the real window gives
`pill x 44-248 avgX=160` (matching the healthy log line and `detector_status.ini`);
the decoy gives `pill x 24-136`.

The obvious discriminators are all dead:

- **Exact title match selects the WRONG one** — the real window's title carries the
  `- 333` unread badge, which changes and presumably vanishes at 0.
- **Colour cannot separate them** — the decoy's `#171717` is 10 away from
  `InactiveColor` `#0D0D0D`, inside `GreyTol=22`.

Candidate fix: capture **by hwnd** with
`OCR.FromWindow("ahk_id " hwnd, {..., mode: 4})` and window-relative coordinates,
so "which window" is explicit rather than "whatever is at those screen pixels";
plus validating the read against the names in `[ActiveMap]` / `[ModelAliases]` /
`[Settings] Model<n>` (`Inbox` is in none of them). Note `IsAskableModelName` is
only a *shape* check (non-empty, ≤24 chars, no whitespace) and would not reject it.

**Caveat:** the detector's failure bursts in the log (`pill x 220-236`,
`positional per-tab counts [0,0,0]`) were originally blamed on this. Multi-monitor
DPI is at least as likely an explanation. **Retest detection after the DPI fix
before building anything here.**

### Reference geometry vs the live window

`automation.py`'s `REF_W, REF_H = 1920, 1032` matches neither live Infloww window
(`2616x1381` / `1760x1380`), so `require_window()` refuses. Note `1920 × 1.25 =
2400`, not 2616 — this is **not** a scale factor, so it cannot be fixed by
dividing.

The Python half is otherwise already DPI-correct: `set_dpi_aware()` calls
`SetProcessDpiAwareness(2)` (per-monitor). Only the AHK side ever drifted.

---

## DIAGNOSING THIS STUFF — traps in the tooling

These cost more time than the bugs did.

### Running AHK from a shell

- **`& $exe script.ahk` in PowerShell returns immediately.** AutoHotkey is a
  GUI-subsystem app, so PowerShell does not wait. An empty result means *nothing* —
  the process may be sitting on a dialog. This produced a false "parses clean" in
  this very session. Use `Start-Process -Wait`, or `-PassThru` +
  `WaitForExit(ms)` so a hang is *reported* rather than silently passing.
- **Piping a GUI-subsystem exe deadlocks.** Both `... | Out-String` and
  `-RedirectStandardOutput` hung mid-loop. `cmd /c "... > file 2>&1"` is reliable.
- **`/ErrorStdOut` only redirects LOAD errors.** A runtime error — or a `#Warn` —
  still opens a dialog and blocks forever.
- **When something blocks, screenshot the dialog.** `PrintWindow` on the `#32770`
  window and read it. `GetWindowTextW` on its children returns only the button
  labels, not the message text.

### `/validate` on a library is meaningless

`ocr_grab.ahk` warns `This local variable appears to never be assigned a value:
LOGI`, because it calls `LOGI`/`LOGW` but does not include `paths.ahk` — it relies
on its host for those. `settings_window.ahk` does the same with
`LaunchStartupScripts` (defined in `core/processes.ahk`). Both are fine in
production.

**Validate the scripts that are actually launched** — `MMA.ahk`,
`main_window.ahk`, the services, an account script — not libraries in isolation.

### AHK name collisions (this bit twice in one session)

A variable whose name matches a function's — case-insensitively — fails at load.
Built-ins count:

- `for ln in res.Lines` collides with the built-in **`Ln()`** (natural log).
- A `W(s)` helper collides with `for w in res.Words`.

Check every new identifier before using it, built-ins included.

### Editing the source programmatically

- **Line endings are mixed across this repo.** `fansly_detector.ahk` and
  `fansly_scan.ahk` are CRLF; most others are LF. `model_detector.ahk` and
  `active_model.ahk` carry a **BOM**. Read and write with `newline=""` and preserve
  whatever was there.
- **A `\r?$` regex anchor inserts between the `\r` and the `\n`.** That leaves a
  stray bare CR and a bare LF per edit. AHK tolerates it, so validation passes and
  it slips through as "mixed line terminators". After any scripted edit, check
  `raw.count(b"\r\r\n")` and `raw.count(b"\n") - raw.count(b"\r\n")` — both should
  be 0.
- **`printf` eats escapes in paths.** `src\vendor` became `srcendor` (`\v` is a
  vertical tab) and produced a convincing but fake "cannot be opened" error. Use a
  heredoc or a real file writer.

### Reading the screen for calibration

Never copy a coordinate out of a PowerShell/PIL screenshot while the AHK side is
still system-aware — the two do not share a coordinate space. A PrintWindow capture
remains the fastest way to *see* a layout and understand what is drawn; just take
the numbers from inside a throwaway AHK script.
