@echo off
REM Creates the desktop shortcut. This file lives in tools\install\, so climb two
REM levels to the repo root — the shortcut must point at MMA.ahk in the root, not
REM at anything in here.
set ROOT=%~dp0..\..\
powershell -Command "$root = (Resolve-Path '%ROOT%').Path; $desktop = [Environment]::GetFolderPath('Desktop'); $ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut($desktop + '\MMA.lnk'); $s.TargetPath = (Join-Path $root 'MMA.ahk'); $s.IconLocation = (Join-Path $root 'assets\icon.ico'); $s.WorkingDirectory = $root; $s.Save(); Write-Host 'Shortcut created at' $desktop"
pause
