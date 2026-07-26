<#
    MMA installer.

    Installs what MMA needs and, just as importantly, CONFIGURES MMA for what you
    chose to skip. Run it by double-clicking install.bat.

    What MMA actually needs
    ───────────────────────
      AutoHotkey v2   REQUIRED. Everything core is AHK: masses, follow-ups, alts,
                      branches, PPV, the GUI, the archive, the parser, and even the
                      OCR — lib\OCR.ahk drives the OCR engine already built into
                      Windows, so model detection and the stats overlay need nothing
                      extra.

      Python          OPTIONAL, for exactly two things:
                        • automation\automation.py — the ^!k / ^!u / ^!s hotkeys.
                          Needs numpy; ^!s (count sales) also needs Pillow.
                        • pinger\pinger.pyw — beeps when a fan tab goes unread.
                          Needs numpy and opencv-python.

    Decline Python and this script writes AutomationListener=0 and Pinger=0 into
    mass_gui.cfg. That matters: those default to ON, and MMA launches the listener
    at startup, so on a machine with no Python you would otherwise get a WScript
    error box every single time MMA starts.

    Usage:
        install.bat                 interactive
        install.bat -WithPython     assume yes to the optional Python features
        install.bat -NoPython       assume no  (configures MMA to not ask for them)
#>
[CmdletBinding()]
param(
    [switch]$WithPython,
    [switch]$NoPython
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Say    { param($m) Write-Host $m }
function Step   { param($m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok     { param($m) Write-Host "    OK   $m" -ForegroundColor Green }
function Warn   { param($m) Write-Host "    WARN $m" -ForegroundColor Yellow }
function Fail   { param($m) Write-Host "    FAIL $m" -ForegroundColor Red }

# ── capability probes ────────────────────────────────────────────────────────
# Detect by CAPABILITY, never by `winget list`. winget only knows what winget
# installed: this very machine has a working Python 3.14 on PATH that
# `winget list --id Python.Python.3.12` reports as "no installed package found".
# Asking the tool itself is the only answer that is actually true.

function Find-AutoHotkey {
    $candidates = @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    # Fall back to PATH, but only accept a v2 binary — a v1 AutoHotkey.exe would
    # load every MMA script and fail on the first line, which looks like MMA is
    # broken rather than like the wrong AHK is installed.
    $cmd = Get-Command 'AutoHotkey64.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-AhkVersion {
    param($exe)
    try { return (Get-Item $exe).VersionInfo.ProductVersion } catch { return '?' }
}

function Find-Python {
    # The launcher first: `py -3` picks a real install and ignores the Store stub.
    # Then plain python. A bare WindowsApps\python.exe is often an App Execution
    # Alias that opens the Microsoft Store and prints nothing — running it with
    # --version is what tells the difference.
    foreach ($try in @(@{exe='py'; args=@('-3','--version')}, @{exe='python'; args=@('--version')})) {
        $cmd = Get-Command $try.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            $out = & $try.exe $try.args 2>&1 | Out-String
        } catch { continue }
        if ($out -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if ($major -eq 3 -and $minor -ge 9) {
                if ($try.exe -eq 'py') { return @{ Cmd = 'py'; Prefix = @('-3'); Version = "$major.$minor.$($Matches[3])" } }
                return @{ Cmd = 'python'; Prefix = @(); Version = "$major.$minor.$($Matches[3])" }
            }
            Warn "found Python $major.$minor, but MMA's dependencies want 3.9+"
        }
    }
    return $null
}

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    # A winget install edits the PATH in the registry, but THIS process keeps the
    # environment it started with — so a freshly installed python is invisible
    # until we re-read it. Without this the script installs Python and then
    # reports it cannot find Python.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Invoke-Winget {
    <#
      --no-upgrade is the important flag. WITHOUT it, `winget install <id>` on a
      package you already have does NOT no-op: it finds the existing install and
      tries to UPGRADE it, so someone with a working AutoHotkey 2.0.19 would get
      silently moved to 2.0.26 by an installer they ran to set up something else.
      With it, an existing install is left completely alone.

      Exit codes are not worth decoding here (an "already installed, nothing to
      do" run exits non-zero, e.g. 0x8A15002B). The caller re-probes for the tool
      afterwards instead, which is the thing we actually care about.
    #>
    param([string]$Id, [string]$Label)

    Say "    installing $Label via winget (existing installs are left alone)..."
    # NOT $args — that is an automatic variable in PowerShell.
    $wgArgs = @(
        'install', '--id', $Id, '--exact',
        '--no-upgrade',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    & winget @wgArgs 2>&1 | ForEach-Object { Say "      $_" }
}

# ── ini writing ──────────────────────────────────────────────────────────────
# mass_gui.cfg is UTF-16LE. Set-Content/Add-Content would write UTF-8 or ANSI and
# corrupt it, so use the same Win32 call AHK's IniWrite uses — it respects the
# file's existing encoding.
if (-not ([System.Management.Automation.PSTypeName]'MmaIni').Type) {
    Add-Type -Namespace '' -Name 'MmaIni' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool WritePrivateProfileString(string section, string key, string val, string filePath);
'@
}

function Set-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "Set-IniValue needs a full path (Windows resolves a bare name against the Windows directory)"
    }
    [void][MmaIni]::WritePrivateProfileString($Section, $Key, $Value, $Path)
}

# ── run ──────────────────────────────────────────────────────────────────────
Say ''
Say '  MMA installer'
Say '  ============='
Say "  folder: $root"

if ($WithPython -and $NoPython) {
    Fail 'pass either -WithPython or -NoPython, not both'
    exit 1
}

$hasWinget = Test-Winget
if (-not $hasWinget) {
    Warn 'winget not found (needs Windows 10 1809+ / Windows 11, or "App Installer" from the Store).'
    Warn 'Nothing can be installed automatically — the checks below still tell you what is missing.'
}

# ── 1. AutoHotkey v2 (required) ──────────────────────────────────────────────
Step 'AutoHotkey v2  (required)'
$ahk = Find-AutoHotkey
if ($ahk) {
    Ok "already installed: $ahk  (v$(Get-AhkVersion $ahk)) — left untouched"
} elseif ($hasWinget) {
    Invoke-Winget -Id 'AutoHotkey.AutoHotkey' -Label 'AutoHotkey v2'
    Update-SessionPath
    $ahk = Find-AutoHotkey
    if ($ahk) { Ok "installed: $ahk  (v$(Get-AhkVersion $ahk))" }
    else       { Fail 'AutoHotkey still not found after the install attempt.' }
} else {
    Fail 'not installed. Get it from https://www.autohotkey.com/  (choose v2)'
}

# ── 2. optional Python features ──────────────────────────────────────────────
Step 'Python  (optional — 3 automation hotkeys + the unread pinger)'
Say '    Skipping this is fine. Everything else in MMA works without it:'
Say '    masses, follow-ups, alts, branches, PPV, archive, parser, hotkeys,'
Say '    model detection and the stats overlay are all pure AutoHotkey.'
Say ''

$wantPython = $false
if ($WithPython)   { $wantPython = $true }
elseif ($NoPython) { $wantPython = $false }
else {
    $answer = Read-Host '    Install the optional Python features? [y/N]'
    $wantPython = ($answer -match '^[Yy]')
}

$pythonReady = $false
if ($wantPython) {
    $py = Find-Python
    if ($py) {
        Ok "already installed: Python $($py.Version) — left untouched"
    } elseif ($hasWinget) {
        Invoke-Winget -Id 'Python.Python.3.12' -Label 'Python 3.12'
        Update-SessionPath
        $py = Find-Python
        if ($py) { Ok "installed: Python $($py.Version)" }
        else     { Fail 'Python still not found after the install attempt.' }
    } else {
        Fail 'not installed. Get it from https://www.python.org/downloads/'
    }

    if ($py) {
        Say '    installing packages: numpy, pillow, opencv-python ...'
        # numpy  -> automation.py imports it at module level; without it the
        #           listener cannot start at all.
        # pillow -> automation.py's ocr_read(), i.e. the ^!s count-sales hotkey.
        # opencv -> pinger.pyw only.
        # Deliberately NOT --upgrade: if numpy/opencv are already present and
        # working, moving them to a new major version is a good way to break
        # automation.py for someone who only ran this to get a shortcut.
        $pipArgs = @($py.Prefix) + @('-m', 'pip', 'install', '--quiet', 'numpy', 'pillow', 'opencv-python')

        # Two PowerShell 5.1 traps in these four lines:
        #  • `2>&1` on a NATIVE command wraps each stderr line in an ErrorRecord,
        #    which with $ErrorActionPreference='Stop' throws — so a pip that merely
        #    prints a warning would be reported as a hard failure. Drop to
        #    'Continue' for the duration of the native calls.
        #  • Embedded double quotes are STRIPPED on the way to a native command:
        #    -c 'import x; print("ok")' arrives as print(ok) and dies with a
        #    SyntaxError. So the probe carries no quotes and is judged by its
        #    exit code instead.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $py.Cmd @pipArgs 2>&1 | ForEach-Object { Say "      $_" }
            $pipCode = $LASTEXITCODE

            $probe = @($py.Prefix) + @('-c', 'import numpy, PIL, cv2')
            & $py.Cmd @probe 2>&1 | ForEach-Object { Say "      $_" }
            if ($LASTEXITCODE -eq 0) {
                Ok 'numpy, pillow and opencv-python are importable'
                $pythonReady = $true
            } elseif ($pipCode -ne 0) {
                Fail "pip install failed (exit $pipCode) - are you online?"
            } else {
                Fail 'packages installed but could not be imported'
            }
        } catch {
            Fail "pip failed: $($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }
} else {
    Say '    skipping Python.'
}

# ── 3. configure MMA to match ────────────────────────────────────────────────
Step 'Configuring MMA'
$cfg = Join-Path $root 'mass_gui.cfg'
if (-not (Test-Path $cfg)) {
    Warn 'mass_gui.cfg not found — MMA will create it with defaults on first run.'
    if (-not $pythonReady) {
        Warn 'Without Python, turn OFF "Automation listener" in Settings on first launch.'
    }
} elseif ($pythonReady) {
    Set-IniValue -Path $cfg -Section 'Settings' -Key 'AutomationListener' -Value '1'
    Ok 'automation listener enabled (AutomationListener=1)'
    Say '    The unread pinger stays off by default — it makes noise. Turn it on in Settings.'
} else {
    # This is the whole reason the installer touches the cfg. Both default to on
    # for the listener, and MMA launches it at startup, so a Python-less machine
    # gets a WScript error dialog on every single launch until this is set.
    Set-IniValue -Path $cfg -Section 'Settings' -Key 'AutomationListener' -Value '0'
    Set-IniValue -Path $cfg -Section 'Settings' -Key 'Pinger' -Value '0'
    Ok 'automation listener and pinger disabled (no Python) — no startup error box'
    Say '    Re-run this installer with -WithPython later to turn them on.'
}

# ── 4. desktop shortcut ──────────────────────────────────────────────────────
Step 'Desktop shortcut'
try {
    $target = Join-Path $root 'mass_gui.ahk'
    if (-not (Test-Path $target)) { throw "mass_gui.ahk not found in $root" }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut((Join-Path $desktop 'MMA.lnk'))
    $sc.TargetPath       = $target
    $sc.WorkingDirectory = $root
    $icon = Join-Path $root 'icon.ico'
    if (Test-Path $icon) { $sc.IconLocation = $icon }
    $sc.Save()
    Ok "created: $(Join-Path $desktop 'MMA.lnk')"
} catch {
    Warn "could not create the shortcut: $($_.Exception.Message)"
}

# ── summary ──────────────────────────────────────────────────────────────────
Say ''
Say '  --------------------------------------------------------------'
if ($ahk) {
    Say '  MMA is ready. Launch it from the desktop shortcut, or run mass_gui.ahk.'
    if ($pythonReady) {
        Say '  Automation hotkeys (^!k / ^!u / ^!s) are available.'
        Say '  The unread pinger is installed but off — enable it in Settings.'
    } else {
        Say '  Running without the Python extras: the 3 automation hotkeys and the'
        Say '  unread pinger are off. Everything else works.'
    }
} else {
    Say '  AutoHotkey v2 is still missing — MMA cannot run until it is installed.'
}
Say '  --------------------------------------------------------------'

if (-not $ahk) { exit 1 }
exit 0
