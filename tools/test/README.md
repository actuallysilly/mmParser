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

## Some of them are not safe to run blind

| file | what it does to you |
|---|---|
| `hotstring_key_test.ahk` | **writes `hotkeys.ini`** — the `[hotstring]` section only, snapshotted and restored, including restoring "there was no such section at all". |
| `mass_bind_test.ahk` / `position_test.ahk` / `active_model_test.ahk` | **write real settings** — `ModelMatch`, `CurrentModel`, the taught tab order. Each snapshots and restores what it touched, but a crash mid-run leaves your detector configured however the test left it. |
| `settings_build_test.ahk` | builds a real Settings window, so a window flashes. `hold [tab] [theme]` leaves it up to look at. |
| `altfu_build_test.ahk` | builds the Add alt-FU window. Writes nothing outside its own stub controls. |
| `altgui_test.ahk` | `show` mode puts a real follow-up picker on screen. |

## Writing another one

Includes are relative to this folder, so they start `../../src/`. Nothing else needs to
know where the file lives: `MMA_ROOT` is derived from `A_LineFile` in
[core/paths.ahk](../../src/core/paths.ahk), not from `A_ScriptDir`, precisely so a test can
be moved between folders without every path in MMA quietly re-pointing.

Print with a `try FileAppend(s "\`n", "*")` helper — there is no stdout when the file is
double-clicked, and an unguarded `FileAppend` throws "the handle is invalid" and kills the
run at whatever line it reached, which looks exactly like the thing under test failing.
