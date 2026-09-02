@echo off
REM Creates the desktop shortcut and nothing else — for someone who installed
REM AutoHotkey by hand and does not want an installer touching anything.
REM
REM It does not create the shortcut itself. install.ps1 does, and this asks it
REM for that one step: two copies of "where does MMA.lnk point" is two copies
REM that can disagree, and the one that disagrees is a shortcut that silently
REM launches nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -ShortcutOnly
echo.
pause
