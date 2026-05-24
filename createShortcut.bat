@echo off
set SCRIPT_DIR=%~dp0
powershell -Command "$desktop = [Environment]::GetFolderPath('Desktop'); $ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut($desktop + '\MMA.lnk'); $s.TargetPath = '%SCRIPT_DIR%mass_gui.ahk'; $s.IconLocation = '%SCRIPT_DIR%icon.ico'; $s.WorkingDirectory = '%SCRIPT_DIR%'; $s.Save(); Write-Host 'Shortcut created at' $desktop"
pause
