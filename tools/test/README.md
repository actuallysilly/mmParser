# tools\test — the self-tests

Every file in here **asserts and exits**: it prints `N passed, M failed` to stdout and
returns 0 or 1. No hotkeys, no resident window, nothing to close. That is the whole
entry requirement, and it is why they can be run from **Settings ▸ Debug** in the middle
of a shift.

Their siblings one folder up (`tools\*_probe.ahk`) are the opposite: a probe binds a key,
stays resident, and exists so you can look at your own screen through it. The only thing
that ever distinguished the two was the filename — and the filename lied. `model_detect_test.ahk`
and `discord_header_test.ahk` are **probes** despite their names; they stayed in `tools\`
with the other probes, and `debug_panel.ahk` has always listed the first of them under
PROBES. Renaming them is worth doing and is not done here.

## Running them

From MMA: **Settings ▸ Debug ▸ Run all**. That runs the list in `DebugPanel.TESTS`
([src/ui/debug_panel.ahk](../../src/ui/debug_panel.ahk)) — add a new test there or it will
only ever run by hand.

By hand, from anywhere:

```powershell
$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ahk; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
$psi.Arguments = '/ErrorStdOut "' + (Resolve-Path .\log_test.ahk) + '"'
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardOutput.ReadToEnd(); $p.WaitForExit(); $p.ExitCode
```

`Start-Process -RedirectStandardOutput` does **not** capture `/ErrorStdOut` — the text
lands on the parent console and the log file comes back empty, which reads as every test
passing. Use a real pipe, as above.

## `settings_parity_test.ahk` — the one that is a lint

Most files here exercise code. This one reads two files as **text** and compares them,
because the question it asks cannot be answered any other way.

MMA has two Settings front ends. Since the field table moved into
`src/ui/settings_core.ahk` they share one description of what a setting *is* — cfg
home, type, default, wording — but they do not share the **drawing**. The WebView page
renders `SETTINGS_Fields()` directly, so a new row appears there for free; the Win32
window hand-builds a control per setting, so a new row appears there only if somebody
remembers. A built Gui is a bag of controls with no way to ask *which setting is this
one for* — that link exists only in the source, in the `IniRead`/`IniWrite` that names
the key. So the source is what gets checked.

It is honest about being a lint: it proves the key is **named** in the file, not that a
control is drawn. That still catches the failure that actually happens — a row added to
the table and nowhere else — and it costs no GUI, so it runs in **Settings ▸ Debug ▸
Run all** with everything else.

Two families of exemption live at the top of the file, each named individually rather
than skipped by a pattern:

- `VIRTUAL` — rows with no cfg key of their own: `modelStrategy` and `inflowwMatch`
  are two halves of `[Settings] ModelMatch`. `waitTime` used to be here too — it was
  a literal inside `core/utils.ahk` that saving rewrote — and is an ordinary
  `[Settings] WaitTime` key now, so it is checked like every other row.
- `RECOMBINED` — the key those halves recombine into, which the Win32 window may name
  without a row of its own.

Generated names (`Model1`, `Platform2`, `Pos3`) are built by interpolation in both
windows, so the full literal appears in neither source and never can. Those are proven
by their stem.

## Some of them are not safe to run blind

| file | what it does to you |
|---|---|
| `hotstring_key_test.ahk` | **writes `hotkeys.ini`** — the `[hotstring]` section only, snapshotted and restored, including restoring "there was no such section at all". |
| `hotstring_edit_test.ahk` | **writes a file into `content\`** — one sandbox `.ahk` under a name nothing else uses, created and deleted by the test. Your `general.ahk` and account files are never opened for writing. It also writes and removes three test triggers in `hotstring_usage.ini`. |
| `mass_bind_test.ahk` / `position_test.ahk` / `active_model_test.ahk` | **write real settings** — `ModelMatch`, `CurrentModel`, the taught tab order. Each snapshots and restores what it touched, but a crash mid-run leaves your detector configured however the test left it. |
| `settings_build_test.ahk` | builds a real Settings window, so a window flashes. `hold [tab] [theme]` leaves it up to look at. |
| `settings_parity_test.ahk` | safe — reads two source files and exits. Builds no window, writes nothing. |
| `altfu_build_test.ahk` | builds the Add alt-FU window. Writes nothing outside its own stub controls. |
| `altgui_test.ahk` | `show` mode puts a real follow-up picker on screen. |

## The `#Warn` trap, which looks exactly like a slow pass

`#Warn VarUnset` is **on by default in v2** and fires at LOAD, and a warning is a modal
dialog *even under* `/ErrorStdOut`. So a test that includes a library expecting globals
from its includer — `core/processes.ahk` reads `SCRIPT_DIR` and `startupScripts`, which
only the main window assigns — hangs forever with no output, which reads as the test
passing slowly rather than as a failure.

`services_test.ahk` sets `#Warn VarUnset, StdOut` and then assigns both globals itself, so
the contract is stated rather than muted. `settings_build_test.ahk` uses `#Warn All,
StdOut` for the same reason. Prefer `VarUnset`: `All` also prints the tree's ~80
"local has the same name as a global" lines and buries the real output.

## Writing another one

Includes are relative to this folder, so they start `../../src/`. Nothing else needs to
know where the file lives: `MMA_ROOT` is derived from `A_LineFile` in
[core/paths.ahk](../../src/core/paths.ahk), not from `A_ScriptDir`, precisely so a test can
be moved between folders without every path in MMA quietly re-pointing.

Print with a `try FileAppend(s "\`n", "*")` helper — there is no stdout when the file is
double-clicked, and an unguarded `FileAppend` throws "the handle is invalid" and kills the
run at whatever line it reached, which looks exactly like the thing under test failing.
