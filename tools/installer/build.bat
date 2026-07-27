@echo off
REM Build MMA-Setup.exe.  Output: installer\dist\MMA-Setup.exe
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

"%ISCC%" "%~dp0MMA.iss"
if errorlevel 1 (
    echo.
    echo BUILD FAILED
    exit /b 1
)

echo.
echo Built: %~dp0dist\MMA-Setup.exe
