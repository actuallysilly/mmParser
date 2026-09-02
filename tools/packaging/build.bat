@echo off
REM Build MMA-Setup.exe — the installer you send to someone who does not have
REM the repo. Output: tools\packaging\dist\MMA-Setup.exe
REM
REM Needs Inno Setup 6:  winget install --id JRSoftware.InnoSetup
REM winget installs it per-user, so it is under %LOCALAPPDATA%, not Program Files.

setlocal
set ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe
if not exist "%ISCC%" set ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe
if not exist "%ISCC%" set ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe

if not exist "%ISCC%" (
    echo.
    echo Inno Setup 6 not found. Install it with:
    echo     winget install --id JRSoftware.InnoSetup
    echo.
    exit /b 1
)

REM Delete the previous build FIRST, so a failed compile can never leave an old
REM exe sitting in dist\ looking like the one you just built. That has shipped
REM before: a build from before the v2 rename stayed here and was sent out, and
REM it wrote a desktop shortcut pointing at mass_gui.ahk — a file the tree it had
REM just installed no longer contained.
if exist "%~dp0dist\MMA-Setup.exe" (
    echo Removing the previous build...
    del /q "%~dp0dist\MMA-Setup.exe"
)

"%ISCC%" "%~dp0MMA.iss"
if errorlevel 1 (
    echo.
    echo BUILD FAILED — dist\ is empty, which is the correct outcome.
    exit /b 1
)

echo.
echo Built: %~dp0dist\MMA-Setup.exe
