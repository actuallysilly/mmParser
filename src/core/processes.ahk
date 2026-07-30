#Requires AutoHotkey v2.0
; Named explicitly rather than inherited from main_window.ahk, which is the only
; file that includes this one today. Every function below now logs, and a file
; that depends on its INCLUDER having pulled in the logger first is one refactor
; away from failing to load — the include is free (AHK loads a file once however
; many times it is named) and it makes this file stand on its own.
#Include "paths.ahk"
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
;  Split out of main_window.ahk; included by it and shares its globals.
; ═══════════════════════════════════════════════════════════════════════════════

; ─── Script toggles ──────────────────────────────────────────────────────────

MakeScriptToggle(spath, btn) {
    return (*) => ToggleScript(spath, btn)
}

ToggleScript(path, btn) {
    SplitPath path, &fname
    label := StrReplace(fname, ".ahk", "")
    if WinExist(path " ahk_class AutoHotkey") {
        ; TOCTOU: the script can exit between WinExist and WinGetPID, and then
        ; WinGetPID throws "Target window not found" — so clicking the toggle at
        ; the moment a script happens to be dying raised an error dialog and left
        ; the button's label lying about the state.
        try {
            pid := WinGetPID(path " ahk_class AutoHotkey")
            LOGI("proc.toggle", "stopping " fname " (pid " pid ") — clicked in the GUI")
            ProcessClose pid
        } catch as e {
            LOGW("proc.toggle", fname " vanished while we were closing it — treating"
                              . " it as stopped (" LOG_Err(e) ")")
        }
        btn.Text := "◻ " label
    } else {
        ; A missing file here is the whole failure: Run throws, the button still
        ; flips to "on", and the script is not running. Checked first so the log
        ; says which of those two things happened.
        if !FileExist(path) {
            LOGE("proc.toggle", fname " cannot start — the file does not exist", path)
            return
        }
        LOGI("proc.toggle", "starting " fname " — clicked in the GUI")
        LOG_Try("proc.toggle", "Run " fname, () => Run(path), &ok)
        if !ok
            return
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
    LOGI("proc.killall", "tearing down every MMA script under " SCRIPT_DIR)
    try SetTimer(WatchdogTick, 0)        ; stop watchdog first so it can't relaunch anything
    StopAutomationListener()             ; not an AHK window, so the loop below misses it
    StopPinger()                         ; likewise
    myPID := ProcessExist()
    DetectHiddenWindows true
    closed := 0
    ; The whole body is guarded PER WINDOW, not around the loop.
    ;
    ; WinGetList returns a snapshot, and closing scripts is exactly when its
    ; entries go stale — a script that exits while we are working down the list
    ; makes WinGetPID/WinGetTitle throw "Target window not found". Unguarded that
    ; escaped the loop, so "close all running scripts too?" on exit silently left
    ; every script after the vanished one still running: you answer Yes, the panel
    ; closes, and half your scripts are still in the tray.
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        try {
            pid := WinGetPID("ahk_id " hwnd)
            if pid = myPID
                continue
            title := WinGetTitle("ahk_id " hwnd)
            if InStr(title, SCRIPT_DIR) {
                LOGI("proc.killall", "closing " _LOG_BaseName(title) " (pid " pid ")")
                ProcessClose(pid)
                closed++
            }
        } catch as e {
            LOGV("proc.killall", "a script vanished while closing (already gone) — "
                               . LOG_Err(e))
        }
    }
    LOGI("proc.killall", closed " script(s) closed")
}

; The cfg stores BARE FILENAMES: StartupScripts=1_mass.ahk,ALIW.ahk,general.ahk.
; That was unambiguous while every script sat in one folder; those three now live
; in three different ones. The resolver in paths.ahk owns the folder list, so the
; cfg format never changes and nobody's existing settings break.
ResolveScriptPath(fname) {
    p := MMA_ScriptPath(fname)
    if FileExist(p)
        return p
    ; "" means LaunchStartupScripts skips this entry entirely and the script never
    ; starts. That is the exact failure paths.ahk's header describes, and it has
    ; happened at least twice in this repo's history — so it gets a FAIL, not a
    ; shrug. With popups on, the user is told the moment it bites instead of
    ; discovering it as a dead hotkey an hour later.
    LOGE("proc.resolve", "startup script '" fname "' was not found anywhere —"
                       . " it will NOT be started",
                       "searched acc\\, content\\ and the src\\ subfolders;"
                     . " last guess was " p)
    return ""
}

; run each configured startup script that isn't already running (also used by the watchdog)
LaunchStartupScripts() {
    if !FEAT("startupScripts") {
        LOG_Bail("proc.startup", "startupScripts feature is off — no auto-start"
                               . " scripts will run, and the watchdog will not"
                               . " restart anything")
        return
    }
    global startupScripts
    started := 0, already := 0, missing := 0
    for fname in startupScripts {
        path := ResolveScriptPath(fname)
        if (path = "") {
            missing++
            continue
        }
        if WinExist(path " ahk_class AutoHotkey") {
            already++
            LOGV("proc.startup", fname " already running")
            continue
        }
        LOGI("proc.startup", "starting " fname " → " path)
        LOG_Try("proc.startup", "Run " fname, () => Run(path), &ok)
        if ok
            started++
    }
    ; One summary line even when nothing happened, because "the list was empty"
    ; and "the list ran" look identical in a log that only reports actions. An
    ; empty StartupScripts key is itself a known way to lose a script silently.
    LOG_Kv("proc.startup", Map("configured", startupScripts.Length,
                               "started", started,
                               "alreadyUp", already,
                               "missing", missing),
           started || missing ? "INFO" : "VERB")
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
                LOGI("proc.python", "interpreter found: " path)
                break 2
            }
        }
    }
    cached := found ? "1" : "0"
    ; Not an error — plenty of installs have no Python and do not want one — but
    ; it silently disables two whole features, so it is written down once per
    ; process rather than left to be inferred from their absence.
    if !found
        LOGW("proc.python", "no python.exe or pythonw.exe on PATH (zero-byte Store"
                          . " aliases ignored) — the automation listener and the"
                          . " unread pinger cannot start")
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
    global SCRIPT_DIR
    if AutomationListenerRunning() {
        LOGV("proc.automation", "already running (its named event exists)")
        return
    }
    ; FEAT reads the cfg key, so it is right the moment Settings writes it. This
    ; used to ALSO check an `automationListener` global that the old Settings
    ; window assigned on save — and once the Features tab became the only writer
    ; of that key, nothing assigned the global any more. It kept its startup value
    ; for the whole session, so switching the listener on and pressing Save
    ; returned here, read a stale 0, and silently did nothing.
    if !FEAT("automation") {
        LOG_Bail("proc.automation", "feature 'automation' is off — listener not started")
        return
    }
    if !PythonAvailable() {
        LOG_Bail("proc.automation", "no Python — listener not started, so every"
                                  . " [automation] hotkey is dead")
        if announce
            MsgBox "The automation listener needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up, or leave this off — the "
                 . "[automation] hotkeys (" HK_Key("automation.unsendLast") " and friends) "
                 . "are the only thing that needs it.", "No Python found", 0x40
        return
    }
    vbs := MMA_SRC "\services\automation\automation_listen.vbs"
    ; A .vbs has nowhere to report a failure, so if the file is not even there,
    ; this function returns having done nothing at all and looks like success.
    if !FileExist(vbs) {
        LOGE("proc.automation", "the launcher script is missing — the listener"
                              . " cannot start and the [automation] keys are dead", vbs)
        return
    }
    LOGI("proc.automation", "starting the listener via " vbs)
    LOG_Try("proc.automation", "run automation_listen.vbs",
            () => Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide"))
}

; Ask it to exit cleanly (it has no console to Ctrl+C, and it is not an AHK window
; so KillAllScripts cannot see it).
StopAutomationListener() {
    h := _AutomationOpenEvent()
    if !h
        return
    LOGI("proc.automation", "asking the listener to exit (setting its stop event)")
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
    if PingerRunning() {
        LOGV("proc.pinger", "already running (its named event exists)")
        return
    }
    if !FEAT("pinger") {
        LOG_Bail("proc.pinger", "feature 'pinger' is off — not started")
        return
    }
    if !PythonAvailable() {
        LOG_Bail("proc.pinger", "no Python — pinger not started")
        if announce
            MsgBox "The unread pinger needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up.", "No Python found", 0x40
        return
    }
    vbs := MMA_SRC "\services\pinger\pinger_start.vbs"
    if !FileExist(vbs) {
        LOGE("proc.pinger", "the launcher script is missing — the pinger cannot start", vbs)
        return
    }
    LOGI("proc.pinger", "starting the pinger via " vbs)
    LOG_Try("proc.pinger", "run pinger_start.vbs",
            () => Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide"))
}

StopPinger() {
    h := _PingerOpenEvent()
    if !h
        return
    LOGI("proc.pinger", "asking the pinger to exit (setting its stop event)")
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
}

; ─── Model detector ───────────────────────────────────────────────────────────
; An AHK script (not python), so its hidden main window — titled with its full
; path, class AutoHotkey — is both the "is it up?" probe and the kill target.
_DetectorTitle() {
    global SCRIPT_DIR
    return MMA_SRC "\screen\model_detector.ahk ahk_class AutoHotkey"
}

; ─── the mass engine ──────────────────────────────────────────────────────────
; NOT a startup script, deliberately.
;
; It was one, and it did not survive: SaveCfg rebuilds StartupScripts from the
; checkbox list, so one visit to Settings while engine.ahk was missing from that
; list wrote it straight out of the config, and every mass hotkey went dead with
; no error. Anything the app cannot function without must not be reachable by an
; unticked box.
;
; So it is launched like the GUI's other infrastructure — unconditionally, and
; kept alive by the watchdog.
_EngineFile() {
    return MMA_SRC "\mass\engine.ahk"
}
_EngineTitle() {
    return _EngineFile() " ahk_class AutoHotkey"
}
EngineRunning() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    up := WinExist(_EngineTitle()) ? true : false
    DetectHiddenWindows prev
    return up
}
LaunchEngine() {
    ; The engine carries EVERY mass hotkey. If it is not running, every follow-up
    ; key, PPV key and __mm trigger in MMA is dead — and that is exactly what it
    ; looks like from the outside: nothing happens, no error, no dialog. So a
    ; missing engine.ahk is a FAIL that pops up, not a quiet return.
    if !FileExist(_EngineFile()) {
        LOGE("proc.engine", "engine.ahk is MISSING — every mass hotkey is dead",
                            _EngineFile())
        return
    }
    if EngineRunning() {
        LOGV("proc.engine", "already running")
        return
    }
    LOGI("proc.engine", "starting the mass engine")
    LOG_Try("proc.engine", "Run engine.ahk", () => Run(_EngineFile()))
}
StopEngine() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    if WinExist(_EngineTitle()) {
        LOGI("proc.engine", "stopping the mass engine — every mass hotkey goes dead"
                         . " until it is back")
        try ProcessClose(WinGetPID(_EngineTitle()))
    } else
        LOGV("proc.engine", "stop requested but it was not running")
    DetectHiddenWindows prev
}

; ─── sequences.ahk ────────────────────────────────────────────────────────────
;  Launched exactly like the engine, and for exactly the same reason.
;
;  It owns the seq.* hotkeys — the Discord Ctrl+click import, Open Farmolijer,
;  Select top PPV. It was reached only through StartupScripts, which is a list of
;  CHECKBOXES, and the default when the key is absent is "general.ahk" alone. So:
;
;    • every fresh install had the Ctrl+click import dead on arrival, because a
;      new mass_gui.cfg has no StartupScripts key at all and never gets one until
;      something writes it;
;    • and on an install that did work, one untick — or one Save from a Settings
;      window that happened to load before the box was ticked — killed it
;      silently, with the key still listed in the Hotkeys tab.
;
;  That is the same failure the engine had ("it lost the engine exactly once,
;  silently"), and it has now been reported as "the Discord import broke AGAIN"
;  more than once. A script that owns hotkeys should not be a checkbox.
;
;  So it has no switch at all now — not StartupScripts, not the Hotkeys tab's
;  owner column, and not the Features tab either. The FEAT("sequences") gate that
;  stood at the top of LaunchSequences was the last one, and it made Easy mode a
;  silent killer: Easy switches off every feature in the registry at once, so the
;  import went dead there with no box to find and nothing to untick. The feature is
;  gone from the registry (see the note in core/modes.ahk) and this starts
;  unconditionally, exactly like the engine above.
_SequencesTitle() {
    return MMA_SRC_SEQUENCES " ahk_class AutoHotkey"
}
SequencesRunning() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    up := WinExist(_SequencesTitle()) ? true : false
    DetectHiddenWindows prev
    return up
}
LaunchSequences() {
    if !FileExist(MMA_SRC_SEQUENCES) {
        LOGE("proc.sequences", "sequences.ahk is MISSING — the Discord import and"
                             . " every seq.* key are dead", MMA_SRC_SEQUENCES)
        return
    }
    if SequencesRunning() {
        LOGV("proc.sequences", "already running")
        return
    }
    LOGI("proc.sequences", "starting sequences.ahk")
    LOG_Try("proc.sequences", "Run sequences.ahk", () => Run(MMA_SRC_SEQUENCES))
}
StopSequences() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    if WinExist(_SequencesTitle()) {
        LOGI("proc.sequences", "stopping sequences.ahk")
        try ProcessClose(WinGetPID(_SequencesTitle()))
    }
    DetectHiddenWindows prev
}

DetectorRunning() {
    return WinExist(_DetectorTitle()) != 0
}
LaunchDetector() {
    if !FEAT("modelDetector") {
        LOG_Bail("proc.detector", "feature 'modelDetector' is off — the"
                                . " [mass.active] shared keys have nothing to follow")
        return
    }
    global SCRIPT_DIR
    path := MMA_SRC "\screen\model_detector.ahk"
    if !FileExist(path) {
        LOGE("proc.detector", "model_detector.ahk is missing", path)
        return
    }
    if DetectorRunning() {
        LOGV("proc.detector", "already running")
        return
    }
    LOGI("proc.detector", "starting the model detector")
    LOG_Try("proc.detector", "Run model_detector.ahk", () => Run(path))
}
StopDetector() {
    global SCRIPT_DIR
    if WinExist(_DetectorTitle()) {
        LOGI("proc.detector", "stopping the model detector")
        try ProcessClose(WinGetPID(_DetectorTitle()))
    }
    ; clear the gate so every model responds again once detection is off
    LOGI("proc.detector", "clearing detector_status.ini active_model — model gating"
                       . " is now off, so every model's keys respond again")
    try IniWrite("", MMA_DETECTOR, "detector", "active_model")
}

; ─── Stats overlay ────────────────────────────────────────────────────────────
; Resident AHK script that owns the gui.toggleStats hotkey and the OCR overlay.
_StatsTitle() {
    global SCRIPT_DIR
    return MMA_SRC "\screen\stats_overlay.ahk ahk_class AutoHotkey"
}
StatsOverlayRunning() {
    return WinExist(_StatsTitle()) != 0
}
LaunchStatsOverlay() {
    if !FEAT("statsOverlay") {
        LOG_Bail("proc.stats", "feature 'statsOverlay' is off — the overlay and its"
                             . " toggle key are dead")
        return
    }
    global SCRIPT_DIR
    path := MMA_SRC "\screen\stats_overlay.ahk"
    if !FileExist(path) {
        LOGE("proc.stats", "stats_overlay.ahk is missing", path)
        return
    }
    if StatsOverlayRunning() {
        LOGV("proc.stats", "already running")
        return
    }
    LOGI("proc.stats", "starting the stats overlay")
    LOG_Try("proc.stats", "Run stats_overlay.ahk", () => Run(path))
}
StopStatsOverlay() {
    if WinExist(_StatsTitle()) {
        LOGI("proc.stats", "stopping the stats overlay")
        try ProcessClose(WinGetPID(_StatsTitle()))
    }
}

TogglePinger(*) {
    global pinger, CFG_FILE
    if PingerRunning() {
        StopPinger()
        pinger := 0
        IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
    } else {
        ; Write the key BEFORE launching. LaunchPinger gates on FEAT("pinger"),
        ; which reads this very key — launching first meant it always bailed on
        ; the old value and the first click did nothing.
        pinger := 1
        IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
        ; announce: this is a deliberate click, so say something if Python is absent
        LaunchPinger(true)
    }
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
    if !FEAT("startupScripts") {
        LOGV("proc.watchdog", "tick skipped — startupScripts is off")
        return
    }
    ; Which of the two core children were DOWN when this tick started.
    ;
    ; The Launch* calls below already log a restart, but they cannot tell you it
    ; was a RE-start: on the first tick after launch "starting the engine" is
    ; normal, and on the twentieth it means the engine is crash-looping and every
    ; mass key is dying with it every five seconds. Sampling first is what makes
    ; those two distinguishable in the log.
    down := ""
    if !EngineRunning()
        down .= "engine "
    ; Unconditional, like the engine beside it: sequences.ahk has no feature switch
    ; any more, so "down" here always means it actually died.
    if !SequencesRunning()
        down .= "sequences "
    if (down != "")
        LOGW("proc.watchdog", "found down, restarting: " Trim(down))
    else
        LOG_Heartbeat("proc.watchdog", "alive; engine and sequences both up")

    LaunchEngine()                  ; core, not optional — see _EngineFile
    LaunchSequences()               ; likewise — it owns the seq.* hotkeys
    LaunchStartupScripts()
    LaunchAutomationListener()
    ; FEAT, not the pinger/autoDetect/statsOverlay globals these used to test.
    ; Each Launch* already refuses when its own feature is off, so the test here
    ; was only ever a shortcut — and a shortcut that went stale the moment the
    ; Features tab became the sole writer of those keys. A watchdog reading
    ; last-startup's values is worse than no watchdog: it silently stops
    ; restarting the thing you just switched on.
    if FEAT("pinger")
        LaunchPinger()
    if FEAT("modelDetector")
        LaunchDetector()
    if FEAT("statsOverlay")
        LaunchStatsOverlay()
    RefreshPingerLabel()
}
