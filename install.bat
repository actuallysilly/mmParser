@echo off
REM MMA installer — double-click this.
REM
REM All the real work is in install.ps1; this exists so the installer is a
REM double-click rather than a "right-click > Run with PowerShell" (which is
REM blocked by the default execution policy on most machines).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install\install.ps1" %*
echo.
pause
