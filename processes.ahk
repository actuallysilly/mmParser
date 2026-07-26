#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  processes.ahk — starting, stopping and watching everything MMA runs.
; ───────────────────────────────────────────────────────────────────────────────
;  Five children, two kinds:
;    • AHK scripts (the model files, general.ahk, acc\*.ahk) — found and closed
;      by window title, ahk_class AutoHotkey.
;    • Python (automation.py, pinger.pyw) — no AHK window to find, so each signs
;      its presence with a NAMED EVENT. Opening the event answers "is it up?" in
;      one DllCall; setting it means "please exit". That is why these cannot ride
;      on startupScripts or be closed by KillAllScripts.
;
;  WatchdogTick re-launches anything that has died, if AutoRestart is on.
;
;  Split out of mass_gui.ahk; included by it and shares its globals.
; ═══════════════════════════════════════════════════════════════════════════════

; ─── Script toggles ──────────────────────────────────────────────────────────

MakeScriptToggle(spath, btn) {
    return (*) => ToggleScript(spath, btn)
}

ToggleScript(path, btn) {
    SplitPath path, &fname
    label := StrReplace(fname, ".ahk", "")
    if WinExist(path " ahk_class AutoHotkey") {
        pid := WinGetPID(path " ahk_class AutoHotkey")
        ProcessClose pid
        btn.Text := "◻ " label
    } else {
        Run path
        btn.Text := "◼ " label
    }
}

; ─── Clean exit / startup / watchdog ──────────────────────────────────────────

; X on the panel: ask whether to also tear down the running scripts.
OnGuiClose(*) {
    r := MsgBox("Close all running scripts too?"
              . "`n`nYes = kill every script in this folder and exit"
              . "`nNo = exit this panel only"
              . "`nCancel = keep everything open", "Exit MMA", 0x23)  ; YesNoCancel + question icon
    if r = "Cancel"
        return true                      ; keep the window open
    if r = "Yes"
        KillAllScripts()
    ExitApp
}

KillAllAndExit(*) {
    KillAllScripts()
    ExitApp
}

; ProcessClose every AutoHotkey script launched from this folder (except this GUI).
KillAllScripts() {
    global SCRIPT_DIR
    try SetTimer(WatchdogTick, 0)        ; stop watchdog first so it can't relaunch anything
    StopAutomationListener()             ; not an AHK window, so the loop below misses it
    StopPinger()                         ; likewise
    myPID := ProcessExist()
    DetectHiddenWindows true
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        pid := WinGetPID("ahk_id " hwnd)
        if pid = myPID
            continue
        if InStr(WinGetTitle("ahk_id " hwnd), SCRIPT_DIR)
            try ProcessClose(pid)
    }
}

; startup scripts may live in the root or in acc\
ResolveScriptPath(fname) {
    global SCRIPT_DIR, ACC_DIR
    if FileExist(SCRIPT_DIR "\" fname)
        return SCRIPT_DIR "\" fname
    if FileExist(ACC_DIR "\" fname)
        return ACC_DIR "\" fname
    return ""
}

; run each configured startup script that isn't already running (also used by the watchdog)
LaunchStartupScripts() {
    if !FEAT("startupScripts")
        return
    global startupScripts
    for fname in startupScripts {
        path := ResolveScriptPath(fname)
        if path != "" && !WinExist(path " ahk_class AutoHotkey")
            try Run(path)
    }
}

; ── is there a Python to run the Python children with? ───────────────────────
; Both Python children start through a .vbs, and a .vbs has nowhere to report a
; failure except its own error dialog. The listener starts automatically at
; STARTUP and defaults to ON, so on a machine with no Python that dialog used to
; greet you on EVERY launch. The .vbs files now quit quietly when they cannot
; find an interpreter; this stops us even spawning them, and lets the Settings
; toggles say something useful instead of appearing to do nothing.
;
; Scans PATH directly rather than shelling out to `where`, which would flash a
; console window every startup.
PythonAvailable() {
    static cached := ""
    if cached != ""
        return cached = "1"

    found := false
    for _, dir in StrSplit(EnvGet("PATH"), ";") {
        dir := Trim(dir, " `t`"")
        if dir = ""
            continue
        for _, exe in ["pythonw.exe", "python.exe"] {
            path := RTrim(dir, "\") "\" exe
            ; A zero-byte hit is the Microsoft Store's App Execution Alias — a
            ; reparse-point stub that opens the Store instead of running Python.
            ; Treating it as an interpreter is how you get the Store popping up
            ; instead of the listener starting.
            if FileExist(path) && FileGetSize(path) > 0 {
                found := true
                break 2
            }
        }
    }
    cached := found ? "1" : "0"
    return found
}

; ── the Python automation listener ────────────────────────────────────────────
;  automation.py serves the [automation] hotkeys. It cannot ride on startupScripts:
;  that path tests WinExist("… ahk_class AutoHotkey") and KillAllScripts only closes
;  AutoHotkey windows, neither of which sees a Python process.
;
;  It signs its presence with a named event, so we can ask "is it up?" with one
;  DllCall instead of shelling out to `--status` (which would spawn a whole Python
;  every watchdog tick, every 5 seconds).
;
;  Launched via the .vbs so there is no console window; it is single-instance on its
;  own (a named mutex), so a double-launch is harmless — the second copy just exits.

; Open the listener's own named event. Its mere existence means "a listener is up";
; setting it means "please exit". Must match STOP_EVENT_NAME in automation.py.
_AutomationOpenEvent() {
    static EVENT_MODIFY_STATE := 0x0002
    static EVENT_NAME := "Global\MMA.automation.listener.stop"
    return DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                   "Str", EVENT_NAME, "Ptr")
}

AutomationListenerRunning() {
    h := _AutomationOpenEvent()
    if !h
        return false
    DllCall("CloseHandle", "Ptr", h)
    return true
}

; announce := true when the user just switched this on by hand, so "nothing
; happened" gets an explanation. Silent at startup — see PythonAvailable().
LaunchAutomationListener(announce := false) {
    global SCRIPT_DIR, automationListener
    if !automationListener || AutomationListenerRunning()
        return
    if !FEAT("automation")
        return
    if !PythonAvailable() {
        if announce
            MsgBox "The automation listener needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up, or leave this off — the "
                 . "[automation] hotkeys (" HK_Key("automation.unsendLast") " and friends) "
                 . "are the only thing that needs it.", "No Python found", 0x40
        return
    }
    vbs := SCRIPT_DIR "\automation\automation_listen.vbs"
    if FileExist(vbs)
        try Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide")
}

; Ask it to exit cleanly (it has no console to Ctrl+C, and it is not an AHK window
; so KillAllScripts cannot see it).
StopAutomationListener() {
    h := _AutomationOpenEvent()
    if !h
        return
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
}

; ─── Pinger ───────────────────────────────────────────────────────────────────
; Beeps when an Infloww fan tab goes unread. Same shape as the automation
; listener above: a python process with no console and no AHK window, so the
; named event is both the "is it up?" probe and the only way to close it.

_PingerOpenEvent() {
    static EVENT_MODIFY_STATE := 0x0002
    static EVENT_NAME := "Global\MMA.pinger.stop"
    return DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                   "Str", EVENT_NAME, "Ptr")
}

PingerRunning() {
    h := _PingerOpenEvent()
    if !h
        return false
    DllCall("CloseHandle", "Ptr", h)
    return true
}

LaunchPinger(announce := false) {
    global SCRIPT_DIR
    if PingerRunning()
        return
    if !FEAT("pinger")
        return
    if !PythonAvailable() {
        if announce
            MsgBox "The unread pinger needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up.", "No Python found", 0x40
        return
    }
    vbs := SCRIPT_DIR "\pinger\pinger_start.vbs"
    if FileExist(vbs)
        try Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide")
}

StopPinger() {
    h := _PingerOpenEvent()
    if !h
        return
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
}

; ─── Model detector ───────────────────────────────────────────────────────────
; An AHK script (not python), so its hidden main window — titled with its full
; path, class AutoHotkey — is both the "is it up?" probe and the kill target.
_DetectorTitle() {
    global SCRIPT_DIR
    return SCRIPT_DIR "\model_detector.ahk ahk_class AutoHotkey"
}
DetectorRunning() {
    return WinExist(_DetectorTitle()) != 0
}
LaunchDetector() {
    if !FEAT("modelDetector")
        return
    global SCRIPT_DIR
    path := SCRIPT_DIR "\model_detector.ahk"
    if !FileExist(path) || DetectorRunning()
        return
    try Run(path)
}
StopDetector() {
    global SCRIPT_DIR
    if WinExist(_DetectorTitle())
        try ProcessClose(WinGetPID(_DetectorTitle()))
    ; clear the gate so every model responds again once detection is off
    try IniWrite("", SCRIPT_DIR "\detector_status.ini", "detector", "active_model")
}

; ─── Stats overlay ────────────────────────────────────────────────────────────
; Resident AHK script that owns the gui.toggleStats hotkey and the OCR overlay.
_StatsTitle() {
    global SCRIPT_DIR
    return SCRIPT_DIR "\stats_overlay.ahk ahk_class AutoHotkey"
}
StatsOverlayRunning() {
    return WinExist(_StatsTitle()) != 0
}
LaunchStatsOverlay() {
    if !FEAT("statsOverlay")
        return
    global SCRIPT_DIR
    path := SCRIPT_DIR "\stats_overlay.ahk"
    if !FileExist(path) || StatsOverlayRunning()
        return
    try Run(path)
}
StopStatsOverlay() {
    if WinExist(_StatsTitle())
        try ProcessClose(WinGetPID(_StatsTitle()))
}

TogglePinger(*) {
    global pinger, CFG_FILE
    if PingerRunning() {
        StopPinger()
        pinger := 0
    } else {
        LaunchPinger()
        pinger := 1
    }
    IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
    ; the python side takes a moment to claim or release the event
    SetTimer(RefreshPingerLabel, -600)
}

RefreshPingerLabel() {
    global btnPinger
    if IsSet(btnPinger) && btnPinger
        try btnPinger.Text := PingerRunning() ? "Pinger: ON" : "Pinger: OFF"
}

WatchdogTick() {
    ; Easy mode runs no children, so the watchdog has nothing to restart.
    if !FEAT("startupScripts")
        return
    global pinger, autoDetect, statsOverlay
    LaunchStartupScripts()
    LaunchAutomationListener()
    if pinger
        LaunchPinger()
    if autoDetect
        LaunchDetector()
    if statsOverlay
        LaunchStatsOverlay()
    RefreshPingerLabel()
}
