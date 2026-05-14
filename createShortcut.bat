@echo off
set SCRIPT_DIR=%~dp0
set SHORTCUT=%USERPROFILE%\Desktop\MMA.lnk

powershell -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%SHORTCUT%'); $s.TargetPath = '%SCRIPT_DIR%mass_gui.ahk'; $s.IconLocation = '%SCRIPT_DIR%icon.ico'; $s.WorkingDirectory = '%SCRIPT_DIR%'; $s.Save()"

echo Shortcut created on Desktop.
pause
