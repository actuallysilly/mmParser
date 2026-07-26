; ============================================================================
;  MMA installer  —  Inno Setup script
; ----------------------------------------------------------------------------
;  Build it:  installer\build.bat        (output: installer\dist\MMA-Setup.exe)
;
;  This is a BOOTSTRAPPER. It carries no copy of MMA; it downloads the latest
;  main branch from GitHub while the wizard runs. So the .exe never goes stale,
;  and whoever you send it to never touches GitHub.
;
;  What the person running it gets to choose:
;    - where to install
;    - Easy or Advanced mode
;    - whether to set up the optional Python extras
;    - desktop shortcut or not
;
;  ---- THINGS YOU MIGHT WANT TO EDIT -------------------------------------
;    WELCOME.txt          the message shown before installing — plain text,
;                         edit it freely, no need to touch this file
;    MyPublisher          your name, shown in Add/Remove Programs
;    MyRepoZip            change if the repo or branch ever moves
;    MyFinishMessage      the last thing they read
;  ------------------------------------------------------------------------
; ============================================================================

#define MyAppName        "MMA"
#define MyAppVersion     "1.9.2"
#define MyPublisher      "actually.silly"
#define MyRepoZip        "https://github.com/actuallysilly/mmParser/archive/refs/heads/main.zip"
#define MyFinishMessage  "MMA is installed. Press the Settings button inside it to change anything you picked here."

[Setup]
; A stable GUID identifies the app across versions, so a reinstall upgrades in
; place instead of piling up entries in Add/Remove Programs.
AppId={{8F3A6C21-4B7E-4E2A-9D55-2C1A7E9B4D30}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyPublisher}
VersionInfoVersion={#MyAppVersion}

; MMA writes its config, hotkeys, archive and logs INTO ITS OWN FOLDER, so it
; must not land in Program Files — a normal user cannot write there, and the app
; would fail in confusing ways. Documents keeps it writable and keeps the whole
; install UAC-free.
DefaultDirName={userdocs}\MMA
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
AllowNoIcons=yes
; MUST be no. The default is "auto", which HIDES the folder page whenever a
; previous install of this AppId is found — so anyone reinstalling never gets to
; choose a path, and setup silently reuses the old one even if that folder has
; since been deleted.
DisableDirPage=no

InfoBeforeFile=WELCOME.txt
OutputDir=dist
OutputBaseFilename=MMA-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\icon.ico
UninstallDisplayIcon={app}\icon.ico
; Nothing is bundled, so this stays tiny.
DiskSpanning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Icons]
; Point the shortcut at the AutoHotkey interpreter with the script as an argument
; rather than at the .ahk itself — that works even when .ahk files are not
; associated, which is the usual state right after a fresh AutoHotkey install.
Name: "{group}\MMA";              Filename: "{code:GetAhkExe}"; Parameters: """{app}\mass_gui.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\icon.ico"
Name: "{autodesktop}\MMA";        Filename: "{code:GetAhkExe}"; Parameters: """{app}\mass_gui.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[Run]
Filename: "{code:GetAhkExe}"; Parameters: """{app}\mass_gui.ahk"""; WorkingDir: "{app}"; \
    Description: "Start MMA now"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
; Downloaded code only. The user's own files are listed in the uninstall notice
; and deliberately left behind.
Type: filesandordirs; Name: "{app}\lib"
Type: filesandordirs; Name: "{app}\automation"
Type: filesandordirs; Name: "{app}\assets"

[Code]
var
  ModePage: TInputOptionWizardPage;
  ReqPage: TOutputMsgWizardPage;
  PythonPage: TInputOptionWizardPage;
  DownloadPage: TDownloadWizardPage;
  CachedAhk: String;

// ---------------------------------------------------------------- detection
// Detect by asking the filesystem, never by asking winget: winget only knows
// what winget installed, and reports "not installed" for a perfectly good
// AutoHotkey or Python that arrived some other way.

// Built from ENVIRONMENT VARIABLES, not from {commonpf}.
//
// PrivilegesRequired=lowest means setup runs as a 32-bit process, and there
// {commonpf} expands to "C:\Program Files (x86)" — where AutoHotkey is NOT. That
// is why a machine with a perfectly good AutoHotkey in C:\Program Files was told
// it was missing. ProgramW6432 always names the real 64-bit Program Files, even
// when read from a 32-bit process, so it is the one that can be trusted here.
function FindAhk(): String;
var
  Roots: array[0..3] of String;
  Names: array[0..1] of String;
  I, J: Integer;
  P: String;
begin
  Result := '';
  Roots[0] := GetEnv('ProgramW6432');                          // real Program Files
  Roots[1] := GetEnv('ProgramFiles');
  Roots[2] := GetEnv('ProgramFiles(x86)');
  Roots[3] := ExpandConstant('{localappdata}') + '\Programs';  // per-user install
  Names[0] := 'AutoHotkey64.exe';
  Names[1] := 'AutoHotkey32.exe';

  for I := 0 to 3 do
  begin
    if Roots[I] = '' then Continue;
    for J := 0 to 1 do
    begin
      P := RemoveBackslash(Roots[I]) + '\AutoHotkey\v2\' + Names[J];
      if FileExists(P) then
      begin
        Result := P;
        Exit;
      end;
    end;
  end;
end;

// Used by [Icons] and [Run]. Re-checked after the install step, because on a
// machine without AutoHotkey the path only exists once winget has finished.
function GetAhkExe(Param: String): String;
begin
  if CachedAhk = '' then
    CachedAhk := FindAhk;
  if CachedAhk = '' then
    // Same reason as FindAhk: {commonpf} would point at Program Files (x86).
    CachedAhk := RemoveBackslash(GetEnv('ProgramW6432')) + '\AutoHotkey\v2\AutoHotkey64.exe';
  Result := CachedAhk;
end;

function HaveAhk(): Boolean;
begin
  Result := FindAhk <> '';
end;

// A zero-byte python.exe on PATH is the Microsoft Store's App Execution Alias —
// a stub that opens the Store instead of running Python. Treating it as an
// interpreter is how you end up installing packages into nothing.
function HavePython(): Boolean;
var
  Paths: TArrayOfString;
  Dirs: String;
  I: Integer;
  P: String;
  Sz: Int64;
begin
  Result := False;
  Dirs := GetEnv('PATH');
  Paths := StringSplitEx(Dirs, [';'], #0, stExcludeEmpty);
  for I := 0 to GetArrayLength(Paths) - 1 do
  begin
    P := RemoveBackslash(Trim(Paths[I]));
    if P = '' then Continue;
    if FileExists(P + '\python.exe') and FileSize64(P + '\python.exe', Sz) and (Sz > 0) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function HaveWinget(): Boolean;
begin
  Result := FileExists(ExpandConstant('{localappdata}\Microsoft\WindowsApps\winget.exe'));
end;

// ------------------------------------------------------------------- wizard

procedure InitializeWizard;
var
  S: String;
begin
  // What we found, stated plainly, before anything is touched.
  S := 'MMA needs AutoHotkey v2. Everything else is optional.' + #13#10 + #13#10;

  if HaveAhk then
    S := S + '  [ok]      AutoHotkey v2 is already installed — it will be left alone.' + #13#10
  else if HaveWinget then
    S := S + '  [install] AutoHotkey v2 is missing. It will be installed for you.' + #13#10
  else
    S := S + '  [!]       AutoHotkey v2 is missing, and this PC has no winget to' + #13#10 +
             '            install it with. Get it from autohotkey.com first,' + #13#10 +
             '            then run this installer again.' + #13#10;

  if HavePython then
    S := S + '  [ok]      Python is already installed.' + #13#10
  else
    S := S + '  [--]      Python is not installed. Only two optional extras use it;' + #13#10 +
             '            you can skip them on the next page.' + #13#10;

  S := S + #13#10 + 'Nothing has been changed yet.';

  ReqPage := CreateOutputMsgPage(wpInfoBefore,
    'What this PC already has', 'Checking requirements', S);

  ModePage := CreateInputOptionPage(ReqPage.ID,
    'How much of MMA do you want?',
    'You can change this later in Settings.',
    'Advanced turns on everything. Easy is the simple version: masses, follow-ups, ' +
    'PPV and the hotkeys, and nothing else running in the background.',
    True, False);
  ModePage.Add('Easy — the simple version. Recommended if you are new to MMA.');
  ModePage.Add('Advanced — every feature, each one switchable on its own.');
  ModePage.SelectedValueIndex := 0;

  PythonPage := CreateInputOptionPage(ModePage.ID,
    'Python extras',
    'Two of MMA''s features need Python. This is set up for you by default.',
    'These are the automation hotkeys (unsend last message, count sales) and the ' +
    'pinger that beeps when a fan tab goes unread. Leave the first option selected ' +
    'unless you have a reason not to — opting out only costs you those two features, ' +
    'and you can run this installer again later to add them.',
    True, False);
  PythonPage.Add('Set up the Python extras  (recommended)');
  PythonPage.Add('Do not install Python — skip those two features');
  PythonPage.SelectedValueIndex := 0;   // installing is the default

  DownloadPage := CreateDownloadPage('Downloading MMA',
    'Fetching the latest version from GitHub', nil);
end;

function WantAdvanced(): Boolean;
begin
  Result := ModePage.SelectedValueIndex = 1;
end;

// Option 0 is "set them up", so installing is what happens unless they opt out.
function WantPython(): Boolean;
begin
  Result := PythonPage.SelectedValueIndex = 0;
end;

// Grab the repo between the last wizard page and the install step, so a failed
// download cancels cleanly instead of leaving a half-made install folder.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpReady then
  begin
    DownloadPage.Clear;
    DownloadPage.Add('{#MyRepoZip}', 'mma.zip', '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        SuppressibleMsgBox('Could not download MMA from GitHub.' + #13#10 + #13#10 +
          GetExceptionMessage + #13#10 + #13#10 +
          'Check your internet connection and try again.',
          mbCriticalError, MB_OK, IDOK);
        Result := False;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

// -------------------------------------------------------------- install step

// A silent install (/VERYSILENT) never shows a wizard, so NextButtonClick never
// fires and the download above never happens. Without this the whole install
// would be a no-op — which is also how it gets tested unattended.
procedure EnsurePayload;
begin
  if FileExists(ExpandConstant('{tmp}\mma.zip')) then
    Exit;
  WizardForm.StatusLabel.Caption := 'Downloading MMA...';
  DownloadTemporaryFile('{#MyRepoZip}', 'mma.zip', '', nil);
end;

procedure InstallDependencies;
var
  Code: Integer;    // Exec needs somewhere to put the exit code; winget's is not
                    // actionable here (an "already installed" run exits non-zero).
begin
  if (not HaveAhk) and HaveWinget then
  begin
    WizardForm.StatusLabel.Caption := 'Installing AutoHotkey v2...';
    // --no-upgrade matters: without it, winget "installs" an already-present
    // package by UPGRADING it, which would move someone's working AutoHotkey
    // because they ran an installer for something else.
    Exec(ExpandConstant('{cmd}'), '/c winget install --id AutoHotkey.AutoHotkey --exact ' +
      '--no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
    CachedAhk := '';   // re-detect: it exists now
  end;

  if WantPython then
  begin
    if (not HavePython) and HaveWinget then
    begin
      WizardForm.StatusLabel.Caption := 'Installing Python...';
      Exec(ExpandConstant('{cmd}'), '/c winget install --id Python.Python.3.12 --exact ' +
        '--no-upgrade --accept-package-agreements --accept-source-agreements --disable-interactivity',
        '', SW_HIDE, ewWaitUntilTerminated, Code);
    end;
    WizardForm.StatusLabel.Caption := 'Installing Python packages...';
    // Not --upgrade: moving an existing numpy to a new major version is a good
    // way to break something the person already relies on.
    Exec(ExpandConstant('{cmd}'), '/c python -m pip install --quiet numpy pillow opencv-python',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
end;

procedure ExtractPayload;
var
  Zip, Tmp, Code: String;
  R: Integer;
begin
  Zip := ExpandConstant('{tmp}\mma.zip');
  Tmp := ExpandConstant('{tmp}\repo');
  CreateDir(Tmp);

  WizardForm.StatusLabel.Caption := 'Unpacking...';
  // Windows ships bsdtar, which reads zip. --strip-components drops GitHub's
  // "mmParser-main\" wrapper folder.
  Exec(ExpandConstant('{sys}\tar.exe'), '-xf "' + Zip + '" -C "' + Tmp + '" --strip-components=1',
    '', SW_HIDE, ewWaitUntilTerminated, R);

  WizardForm.StatusLabel.Caption := 'Installing files...';

  // Pass 1: all the code, explicitly excluding anything that belongs to the
  // person rather than to the release. On a reinstall this is what stops an
  // upgrade from eating their messages, keys and settings.
  Exec(ExpandConstant('{sys}\robocopy.exe'),
    '"' + Tmp + '" "' + ExpandConstant('{app}') + '" /E /NFL /NDL /NJH /NJS /NP ' +
    '/XF mass_gui.cfg hotkeys.ini mass_archive.txt error_log.txt detector_status.ini ' +
    '1_mass.ahk 2_mass.ahk 3_mass.ahk general.ahk /XD acc',
    '', SW_HIDE, ewWaitUntilTerminated, R);

  // Pass 2: the user-owned files, but ONLY where they are missing.
  // /XC /XN /XO together mean "skip anything that already exists", regardless of
  // which copy is newer.
  Exec(ExpandConstant('{sys}\robocopy.exe'),
    '"' + Tmp + '" "' + ExpandConstant('{app}') + '" ' +
    '1_mass.ahk 2_mass.ahk 3_mass.ahk general.ahk /XC /XN /XO /NFL /NDL /NJH /NJS /NP',
    '', SW_HIDE, ewWaitUntilTerminated, R);

  Exec(ExpandConstant('{sys}\robocopy.exe'),
    '"' + Tmp + '\acc" "' + ExpandConstant('{app}\acc') + '" /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP',
    '', SW_HIDE, ewWaitUntilTerminated, R);
end;

procedure ApplyChoices;
var
  Cfg: String;
begin
  Cfg := ExpandConstant('{app}\mass_gui.cfg');

  // mass_gui.cfg is deliberately NOT copied from the repo: the tracked copy
  // carries the maintainer's own model names and window position. A fresh
  // install starts from MMA's built-in defaults plus the two answers given here.
  if WantAdvanced then
    SetIniString('Settings', 'Mode', 'advanced', Cfg)
  else
    SetIniString('Settings', 'Mode', 'easy', Cfg);

  // Without Python these would start on every launch and fail. Easy mode turns
  // them off anyway; this covers someone who picked Advanced but skipped Python.
  if not WantPython then
  begin
    SetIniString('Settings', 'AutomationListener', '0', Cfg);
    SetIniString('Settings', 'Pinger', '0', Cfg);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    EnsurePayload;
    InstallDependencies;
    ExtractPayload;
    ApplyChoices;
    CachedAhk := '';    // so [Icons]/[Run] resolve against what is now installed
  end;
end;

// The uninstaller removes the program, never the person's work.
function InitializeUninstall(): Boolean;
begin
  Result := MsgBox('Remove MMA?' + #13#10 + #13#10 +
    'Your own files are KEPT:' + #13#10 +
    '  - your messages (1_mass.ahk and the rest)' + #13#10 +
    '  - your hotkeys (hotkeys.ini)' + #13#10 +
    '  - your settings (mass_gui.cfg)' + #13#10 +
    '  - your archive (mass_archive.txt)' + #13#10 + #13#10 +
    'Delete the folder by hand if you want those gone too.',
    mbConfirmation, MB_YESNO) = IDYES;
end;
