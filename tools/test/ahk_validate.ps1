# ahk_validate.ps1 — parse AHK entry points and write every engine complaint to
# debuglogs\AHK_engine.log.
#
# Why this exists: a #Warn is a MODAL DIALOG that fires at LOAD, before MMA's own
# logger in core\log.ahk is alive, so nothing in the tree can catch it. The only
# way to get the text into a file is to re-point #Warn at StdOut and read the
# pipe. That is what the temp copy below is for — it is written NEXT TO the
# original so relative #Includes still resolve, and removed afterwards.
#
# Only ENTRY POINTS are meaningful. AHK resolves function calls across the whole
# include tree at load, so a library validated alone reports every name it did
# not include as unassigned — noise, not a bug.
#
#   powershell -ExecutionPolicy Bypass -File tools\test\ahk_validate.ps1
#   ... -Files src\ui\main_window.ahk        # or specific entry points
param(
  [string[]]$Files,
  [string]$Ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
  [int]$TimeoutMs = 30000
)
$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$log  = Join-Path $root "debuglogs\AHK_engine.log"
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null

if (-not $Files -or $Files.Count -eq 0) {
  $Files = @("MMA.ahk","src\mass\engine.ahk","src\ui\main_window.ahk",
             "src\ui\webview_main_window.ahk","src\updater.ahk")
}
if (-not (Test-Path $Ahk)) { Write-Host "AutoHotkey64.exe not found: $Ahk"; exit 9 }

function Log([string]$s) { Add-Content -Path $log -Value $s -Encoding utf8 }
Log ("=" * 78)
Log ("{0}  ahk_validate  ({1} file(s))" -f (Get-Date -f "yyyy-MM-dd HH:mm:ss"), $Files.Count)

$bad = 0
foreach ($rel in $Files) {
  $f = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $root $rel }
  if (-not (Test-Path $f)) { Write-Host "MISSING | $rel"; Log "MISSING | $rel"; $bad++; continue }

  # Temp copy beside the original with #Warn re-pointed at StdOut. VarUnset, not
  # All: All also prints the tree's ~80 "local has the same name as a global"
  # lines and buries the real output.
  $dir = Split-Path $f -Parent
  $tmp = Join-Path $dir ("_ahkval_" + (Split-Path $f -Leaf))
  # Line-based, and write the BOM ourselves. Get-Content -Raw keeps the source
  # BOM as a character and Set-Content -Encoding utf8 prepends a SECOND one; the
  # copy then opens with two, #Requires stops being the first directive, and
  # every file fails identically at line 1 with "Parameter #1 required".
  $lines = [Collections.Generic.List[string]](Get-Content $f)
  $at = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '#Requires') { $at = $i + 1; break }
  }
  $lines.Insert($at, '#Warn VarUnset, StdOut')
  $crlf = [string][char]13 + [string][char]10
  [IO.File]::WriteAllText($tmp, ($lines -join $crlf), (New-Object Text.UTF8Encoding $true))

  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName  = $Ahk
    $psi.Arguments = '/ErrorStdOut /validate "' + $tmp + '"'   # order matters
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p  = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch {}
      Write-Host "TIMEOUT | $rel"; Log "TIMEOUT | $rel  (a dialog opened anyway)"; $bad++; continue
    }
    # The captured TEXT is the verdict, never the exit code.
    $txt = ($so.Result + $se.Result).Trim() -replace [regex]::Escape($tmp), $f
    if ($txt) {
      $n = ([regex]::Matches($txt,'==>')).Count
      Write-Host "FAIL | $rel | $n complaint(s) -> debuglogs\AHK_engine.log"
      Log "FAIL | $rel"; $txt -split "`r?`n" | ForEach-Object { if ($_.Trim()) { Log ("    " + $_.Trim()) } }
      $bad++
    } else {
      Write-Host "ok   | $rel"; Log "ok   | $rel"
    }
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
Log ("done — {0} of {1} clean" -f ($Files.Count - $bad), $Files.Count)
exit $bad
