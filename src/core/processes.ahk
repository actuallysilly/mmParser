#Requires AutoHotkey v2.0
; Named explicitly rather than inherited from main_window.ahk, which is the only
; file that includes this one today. Every function below now logs, and a file
; that depends on its INCLUDER having pulled in the logger first is one refactor
; away from failing to load — the include is free (AHK loads a file once however
; many times it is named) and it makes this file stand on its own.
#Include "paths.ahk"
; FEAT() decides whether every service below may start, and the service
; registry reads its labels out of FEAT_META. Included for the reason the
; header gives for the logger: a file that depends on its INCLUDER having
; pulled in the feature registry first is one refactor away from failing to
; load, and the include is free.
#Include "modes.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  processes.ahk — starting, stopping and watching everything MMA runs.
; ───────────────────────────────────────────────────────────────────────────────
;  Children of two kinds, and the count is not written down here on purpose —
;  it is however many rows SVC_ORDER has, plus the engine and sequences:
;    • AHK scripts (the engine, sequences.ahk, content\general.ahk, the account
;      files, and the AHK services) — found and closed by window title,
;      ahk_class AutoHotkey, because a script's main window IS its full path.
;    • Python (automation, pinger, typelog, autoword) — no AHK window to find,
;      so each signs its presence with a NAMED EVENT. Opening the event answers
;      "is it up?" in one DllCall; setting it means "please exit". That is why
;      these cannot ride on startupScripts or be closed by KillAllScripts.
;
;  The optional ones are declared once in the SERVICE REGISTRY below and are
;  never named individually anywhere else. The engine and sequences.ahk are the
;  exception and are hand-written further down: they have no switch.
;
;  WatchdogTick re-launches anything that has died. TWO switches gate that:
;  AutoRestart decides whether the 5-second timer runs at all (main_core.ahk
;  and the Settings checkbox start it), and the tick itself returns early
;  unless the startupScripts feature is on — which is how Easy mode stops the
;  watchdog restarting the children it just switched off.
;
;  Split out of main_window.ahk; included by BOTH shells (main_window.ahk and
;  webview_main_window.ahk) and shares their globals.
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
    ; The python services have no AutoHotkey window, so the loop below cannot see
    ; them and each has to be asked to leave. This was four named Stop* calls, one
    ; per service, which is exactly the list a fifth python service would have been
    ; forgotten from — and being forgotten HERE means it survives "close all" and
    ; goes on running after MMA is gone.
    SVC_StopPython()
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

; ═══════════════════════════════════════════════════════════════════════════════
;  The service registry — one line per background service.
; ───────────────────────────────────────────────────────────────────────────────
;  There were eleven near-identical Launch*/Stop*/*Running triples here, 409 lines
;  of them, differing in four tokens: the feature id, the path, the log tag and
;  the noun. Three separate hand-written lists then decided WHEN each one ran —
;  CORE_BootServices in ui/main_core.ahk, the if/else chain in
;  ui/features_panel.ahk, and WatchdogTick below — plus a fourth, TOOLS_List in
;  ui/tools_window.ahk, restating ids the feature registry already held.
;
;  Four lists maintained by hand had drifted, and the drift was silent:
;
;    • fanslyDetector, activity and autoword were missing from the BOOT list, so
;      they did not start until the first watchdog tick five seconds later — and
;      never at all with startupScripts off.
;    • activity and autoword were missing from the FEATURES chain, so unticking
;      either wrote the cfg key and left the process running. Untick "Activity
;      tracker" and it kept counting your keystrokes until you restarted MMA,
;      with the checkbox saying it was off. For a feature whose whole defence is
;      "you switched it on deliberately", that is the wrong bug to have.
;
;  So the list moved to where the ids already lived. Every service is declared
;  ONCE below; everything that acts on services walks SVC_ORDER, and a service
;  that is declared cannot be missing from a list, because there are no lists.
;
;  ── Declaring one ────────────────────────────────────────────────────────────
;      SVC_Def(id, kind, path, tag, noun, extra)
;
;  id    — the FEATURE id from core/modes.ahk. Not a new name: the label, the cfg
;          key and the on/off switch all still come from FEAT_META, so a service
;          is a feature that happens to be a process.
;  kind  — "ahk"    : an AHK script, found and closed by its window title.
;          "python" : a .vbs launcher, found and closed by a named event.
;  path  — the .ahk file, or the .vbs that starts the Python.
;  tag   — the log tag, unchanged from when each of these was its own function.
;  noun  — what to call it in a log line: "the stats overlay".
;  extra — optional, and only where a service genuinely differs:
;            event    — python only. Must match the STOP_EVENT_NAME in the .py.
;            needText — python only. Shown when Python is missing AND the user
;                       just clicked this on by hand. `{key}` is replaced with
;                       the binding named by needKey.
;            needKey  — a hotkey id to name in needText.
;            onStop   — a function to run after stopping. Named, never a lambda:
;                       this table is meant to be read.
;
;  ── Adding one ───────────────────────────────────────────────────────────────
;  A FEAT_Def line in core/modes.ahk, an SVC_Def line here, and the file. That is
;  the whole change — boot, the Features tab, the Tools window, the Tools button
;  count and the watchdog all pick it up from SVC_ORDER.
;
;  NOT every child is here. The mass engine and sequences.ahk are further down
;  and stay hand-written, deliberately: they have no feature switch and must
;  start unconditionally, which is the one property this registry does not model.
;  Making them rows would mean inventing a "cannot be switched off" flag, and the
;  reason they are not switchable is that MMA lost each of them exactly once,
;  silently, to a switch.
; ═══════════════════════════════════════════════════════════════════════════════

global SVC_META  := Map()      ; id -> the record below
global SVC_ORDER := []         ; declaration order — boot order, and display order

SVC_Def(id, kind, path, tag, noun, extra := "") {
    s := {id: id, kind: kind, path: path, tag: tag, noun: noun,
          event: "", needText: "", needKey: "", onStop: ""}
    if IsObject(extra)
        for k, v in extra.OwnProps()
            s.%k% := v
    SVC_META[id] := s
    SVC_ORDER.Push(id)
}

; ─── The AHK services ─────────────────────────────────────────────────────────

; Pixel-scans the Infloww tab strip for the lit model pill and OCRs its name.
; Stopping it clears the status file: with nothing updating that name,
; ActiveModelNo() would go on gating every model's keys against a stale reading.
; Clearing it disables gating, which is the correct "no detector" behaviour.
SVC_Def("modelDetector", "ahk", MMA_SRC "\screen\model_detector.ahk",
        "proc.detector", "the model detector",
        {onStop: SVC_ClearDetectorStatus})

; A SECOND detector, running alongside the Infloww one rather than instead of it.
; They cannot collide: each refuses to scan unless its own window is in front, and
; each writes its own status file (see the note beside MMA_FANSLY in paths.ahk).
SVC_Def("fanslyDetector", "ahk", MMA_SRC "\screen\fansly_detector.ahk",
        "proc.fansly", "the Fansly rail detector",
        {onStop: SVC_ClearFanslyStatus})

; Owns the gui.toggleStats hotkey and the OCR overlay.
SVC_Def("statsOverlay", "ahk", MMA_SRC "\screen\stats_overlay.ahk",
        "proc.stats", "the stats overlay")

; Boxes conversation rows by how long they have waited. Holds gui.toggleReplyBox.
SVC_Def("replyBox", "ahk", MMA_SRC "\screen\reply_box.ahk",
        "proc.replybox", "the reply timers")

; Counts keystrokes, clicks and active seconds into userdata\activity\, and owns
; the gui.activity key that opens the chart. Stopping it is a real stop, not a
; pause: the minute in progress is flushed by its OnExit and nothing is recorded
; until it is back. That is why it is in the watchdog like the rest — a tracker
; that quietly died at 11am makes the afternoon look like a day off.
SVC_Def("activity", "ahk", MMA_SRC "\activity\tracker.ahk",
        "proc.activity", "the activity tracker")

; ─── The Python services ──────────────────────────────────────────────────────
;  None of these has an AHK window, so KillAllScripts cannot see them and they
;  cannot ride on startupScripts. Each signs its presence with a NAMED EVENT:
;  opening it answers "is it up?" in one DllCall instead of shelling out to
;  `--status` (which would spawn a whole Python every watchdog tick, every five
;  seconds), and setting it means "please exit".
;
;  All four start through a .vbs so there is no console window, and each is
;  single-instance on its own (a named mutex), so a double-launch is harmless —
;  the second copy just exits.

SVC_Def("automation", "python", MMA_SRC "\services\automation\automation_listen.vbs",
        "proc.automation", "the automation listener",
        {event: "Global\MMA.automation.listener.stop",
         needKey: "automation.unsendLast",
         needText: "The automation listener needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up, or leave this off — the "
                 . "[automation] hotkeys ({key} and friends) are the only thing "
                 . "that needs it."})

SVC_Def("pinger", "python", MMA_SRC "\services\pinger\pinger_start.vbs",
        "proc.pinger", "the pinger",
        {event: "Global\MMA.pinger.stop",
         needText: "The unread pinger needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up."})

SVC_Def("typelog", "python", MMA_SRC "\services\typelog\typelog_start.vbs",
        "proc.typelog", "the typelog recorder",
        {event: "Global\MMA.typelog.stop",
         needText: "The typelog recorder needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up."})

SVC_Def("autoword", "python", MMA_SRC "\services\autoword\autoword_start.vbs",
        "proc.autoword", "the autoword suggester",
        {event: "Global\MMA.autoword.stop",
         needText: "Autoword needs Python, which isn't installed.`n`n"
                 . "Run install.bat to set it up."})

; ─── The extra teardown two services need ─────────────────────────────────────
;  Named functions rather than lambdas in the table above, so the table stays
;  readable as data.

SVC_ClearDetectorStatus() {
    LOGI("proc.detector", "clearing detector_status.ini active_model — model gating"
                       . " is now off, so every model's keys respond again")
    try IniWrite("", MMA_DETECTOR, "detector", "active_model")
}

; The row index goes with the name: a stale active_index is worse than a stale
; name, because positional mode believes it without needing OCR.
SVC_ClearFanslyStatus() {
    LOGI("proc.fansly", "clearing fansly_status.ini — Fansly gating is now off")
    try IniWrite("", MMA_FANSLY, "fansly", "active_model")
    try IniWrite(0,  MMA_FANSLY, "fansly", "active_index")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  What you can do to a service. Every one of these takes an id and works for
;  both kinds — the kind only decides how "is it up?" and "go away" are spelled.
; ═══════════════════════════════════════════════════════════════════════════════

; The window title an AHK service answers to. An AHK script's hidden main window
; is titled with its FULL PATH, which is what makes this work at all.
SVC_Title(id) {
    return SVC_META[id].path " ahk_class AutoHotkey"
}

; A python service's stop event, or 0 when it is not running.
SVC_OpenEvent(id) {
    static EVENT_MODIFY_STATE := 0x0002
    return DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                   "Str", SVC_META[id].event, "Ptr")
}

SVC_Running(id) {
    if !SVC_META.Has(id)
        return false
    s := SVC_META[id]
    if (s.kind = "python") {
        h := SVC_OpenEvent(id)
        if !h
            return false
        DllCall("CloseHandle", "Ptr", h)
        return true
    }
    ; The AHK services are found through a HIDDEN window, so this only answers
    ; correctly with DetectHiddenWindows on. The shells set it at load and the
    ; old per-service Running() functions relied on that; setting it here means a
    ; caller that has not cannot get a false "everything is down".
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    up := WinExist(SVC_Title(id)) ? true : false
    DetectHiddenWindows prev
    return up
}

; Its label, from the FEATURE registry — never retyped here, so a service renamed
; in modes.ahk is renamed everywhere.
SVC_Label(id) {
    return FEAT_META.Has(id) ? FEAT_META[id].label : id
}

; Start it, if it is switched on and not already up.
;
; announce := true when the user just clicked this on by hand, so "nothing
; happened because Python is missing" gets said out loud instead of going to the
; log. Silent at startup and from the watchdog.
;
; The gates run feature → running → file, which is one order for both kinds where
; the python launchers used to check running first. Nothing starts either way;
; only the log line differs.
SVC_Launch(id, announce := false) {
    if !SVC_META.Has(id) {
        LOGW("proc.svc", "'" id "' is not a declared service — nothing started")
        return
    }
    s := SVC_META[id]
    if !FEAT(id) {
        LOG_Bail(s.tag, "feature '" id "' is off — " s.noun " was not started")
        return
    }
    if SVC_Running(id) {
        LOGV(s.tag, "already running")
        return
    }
    if (s.kind = "python") && !PythonAvailable() {
        LOG_Bail(s.tag, "no Python — " s.noun " not started")
        if (announce && s.needText != "") {
            msg := s.needText
            if (s.needKey != "")
                msg := StrReplace(msg, "{key}", HK_Key(s.needKey))
            MsgBox msg, "No Python found", 0x40
        }
        return
    }
    ; A missing file is the whole failure, and for a .vbs it is a SILENT one: a
    ; .vbs has nowhere to report anything, so without this the function returns
    ; having done nothing and looks exactly like success.
    if !FileExist(s.path) {
        LOGE(s.tag, s.noun " cannot start — the file does not exist", s.path)
        return
    }
    LOGI(s.tag, "starting " s.noun)
    if (s.kind = "python")
        LOG_Try(s.tag, "run " SVC_BaseName(s.path), SVC_RunVbs.Bind(s.path))
    else
        LOG_Try(s.tag, "Run " SVC_BaseName(s.path), SVC_RunAhk.Bind(s.path))
}

; The two ways to start something, as named functions so SVC_Launch above binds a
; name rather than carrying a lambda.
SVC_RunAhk(path) {
    Run(path)
}
SVC_RunVbs(path) {
    global SCRIPT_DIR
    Run('wscript.exe "' path '"', SCRIPT_DIR, "Hide")
}

SVC_BaseName(path) {
    SplitPath path, &fname
    return fname
}

; Stop it. For python that is a REQUEST — it has no console to Ctrl+C and no AHK
; window for KillAllScripts to find, so setting its event is the only way to ask.
SVC_Stop(id) {
    if !SVC_META.Has(id)
        return
    s := SVC_META[id]
    if (s.kind = "python") {
        h := SVC_OpenEvent(id)
        if h {
            LOGI(s.tag, "asking " s.noun " to exit (setting its stop event)")
            DllCall("SetEvent", "Ptr", h)
            DllCall("CloseHandle", "Ptr", h)
        }
    } else {
        prev := A_DetectHiddenWindows
        DetectHiddenWindows true
        if WinExist(SVC_Title(id)) {
            LOGI(s.tag, "stopping " s.noun)
            try ProcessClose(WinGetPID(SVC_Title(id)))
        } else
            LOGV(s.tag, "stop requested but it was not running")
        DetectHiddenWindows prev
    }
    ; Runs whether or not it was up: the status files these clear are on disk, and
    ; a service that died on its own leaves exactly the stale reading this removes.
    if (s.onStop != "")
        s.onStop.Call()
}

; Make the world match the switch — start it if it is on, stop it if it is off.
;
; This is what the Features tab wants, and having it as one function is what fixes
; the bug that tab had: its hand-written chain covered seven of the nine services,
; so two of them could be switched off and go on running.
SVC_Sync(id, announce := false) {
    if FEAT(id)
        SVC_Launch(id, announce)
    else
        SVC_Stop(id)
}

SVC_SyncAll(announce := false) {
    for id in SVC_ORDER
        SVC_Sync(id, announce)
}

; Start everything that is switched on, and leave everything else alone. Boot and
; the watchdog both want this rather than SyncAll: neither is a moment where the
; user changed a switch, so there is nothing to stop.
SVC_LaunchEnabled() {
    for id in SVC_ORDER
        if FEAT(id)
            SVC_Launch(id)
}

; The python services only, for KillAllScripts — it closes AutoHotkey windows, and
; these do not have one.
SVC_StopPython() {
    for id in SVC_ORDER
        if (SVC_META[id].kind = "python")
            SVC_Stop(id)
}

; How many are up right now. One pass with DetectHiddenWindows held on, rather
; than SVC_Running's save/restore per service.
SVC_RunningCount() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    n := 0
    for id in SVC_ORDER
        if SVC_Running(id)
            n++
    DetectHiddenWindows prev
    return n
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


; ═══════════════════════════════════════════════════════════════════════════════
;  The Tools button, and the watchdog.
; ═══════════════════════════════════════════════════════════════════════════════

; The main window's Tools button, which is a running indicator as well as a door:
; "Tools (2)" means two of the background services are up right now.
;
; TogglePinger used to live here — the Pinger button's click handler, writing the
; cfg key before launching because LaunchPinger gated on FEAT("pinger") and read
; that very key. That rule did not go away; it moved to TOOLS_Set in
; ui/tools_window.ahk, which applies it to all of them instead of one.
;
; The nine-service list that used to be spelled out here is gone: it was a
; hand-kept mirror of TOOLS_List() in the UI, with a comment explaining that
; going out of step costs a wrong number on one button. Both now read SVC_ORDER,
; so there is nothing left to keep in step.
RefreshToolsLabel() {
    global btnTools
    if !(IsSet(btnTools) && btnTools)
        return
    n := SVC_RunningCount()
    try btnTools.Text := n ? "Tools (" n ")" : "Tools"
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

    ; Every declared service that is switched on. This was eleven hand-written
    ; lines, each testing FEAT and calling one Launch* — and the FEAT test was not
    ; redundant with the one inside each launcher, it was a shortcut past it. The
    ; shortcut is now SVC_LaunchEnabled's business, and a service cannot be left
    ; out of it, because there is no list to leave it out of.
    SVC_LaunchEnabled()

    RefreshToolsLabel()
}
