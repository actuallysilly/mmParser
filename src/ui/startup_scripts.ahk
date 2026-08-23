#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  startup_scripts.ahk — one row per message script: is it up, and start it again.
; ───────────────────────────────────────────────────────────────────────────────
;  Replaces the "◻ NAME" toggle buttons that used to sit on the main window's
;  bottom strip, and the "Visible scripts" checkboxes in Settings that decided
;  which of them appeared.
;
;  Those buttons had one honest use — a hotstring script stops responding, you
;  click it off and on again — and two problems doing it:
;
;    * the LABEL was the state. It only changed when you clicked, so a script that
;      died on its own (or was restarted by the watchdog, or by Add Hotkey's
;      append) left the button reading the opposite of the truth. The one moment
;      you go looking is the one moment it lies.
;    * the row was permanently on screen, at one button per account file, for
;      something you do a handful of times a year.
;
;  This window reads the state instead of remembering it, on a timer, and it is
;  only open while you are actually fixing something. It lives under Hotstrings
;  because these files ARE the hotstring library — the manager lists what is in
;  them, this lists whether they are running.
;
;  Deliberately NOT a copy of the Settings > Scripts tab: that tab is config (which
;  scripts auto-start, and the watchdog). This is the live view and the manual
;  override. The startup flag is shown here read-only, so the two cannot disagree.
; ═══════════════════════════════════════════════════════════════════════════════

; A script's PID, or 0. An AHK v2 script's main window is hidden and its title
; STARTS WITH its own full path, which is what makes this identification exact
; rather than a guess at a process name — every one of these is AutoHotkey64.exe.
;
; Match mode 1 (starts-with), not 3 (exact). The full title is
;   "D:\…\TEMP.ahk - AutoHotkey v2.0.26"
; so exact matches nothing at all, and every script reads as stopped forever —
; measured, before this shipped. Mode 1 rather than the default 2 (contains)
; because a path anchored at the start cannot collide the way a substring can.
;
; DetectHiddenWindows is set here rather than once at load: this runs from a timer
; thread as well as from a click, and AHK's per-thread settings start from the
; auto-execute defaults every time a timer fires.
SS_Pid(path) {
    DetectHiddenWindows true
    SetTitleMatchMode 1
    if !WinExist(path " ahk_class AutoHotkey")
        return 0
    ; TOCTOU: the script can exit between WinExist and WinGetPID, and WinGetPID
    ; then throws "Target window not found". Reporting "stopped" is both true by
    ; then and the answer this window exists to give.
    try return WinGetPID(path " ahk_class AutoHotkey")
    return 0
}

; general.ahk first, then every account file. The same enumeration Settings uses
; for its startup list, so the two windows can never show different scripts.
SS_Scripts() {
    list := []
    gen := MMA_CONTENT "\general.ahk"
    if FileExist(gen)
        list.Push({name: "general.ahk", path: gen})
    Loop Files, MMA_ACC_DIR "\*.ahk"
        list.Push({name: A_LoopFileName, path: A_LoopFilePath})
    return list
}

; Which ones Settings has ticked under "Run on startup". Read fresh on open, so a
; change over there shows here the next time this window is opened.
SS_StartupSet() {
    set := Map()
    for s in StrSplit(IniRead(MMA_CFG, "Settings", "StartupScripts", "general.ahk"), ",")
        if (Trim(s) != "")
            set[Trim(s)] := true
    return set
}

; The one open instance, or 0. A plain global rather than a static inside the
; function, because the close handler is a nested closure that has to clear it —
; and "which variable does a nested function's assignment reach" is not a question
; worth having in the code.
global SS_WIN := 0

OpenStartupScripts(ownerHwnd := 0) {
    global SS_WIN
    ; Already open: raise it rather than stacking a second copy, whose timer would
    ; then fight the first one's over the same rows.
    if SS_WIN {
        try {
            SS_WIN.Show()
            return
        }
        SS_WIN := 0
    }

    scripts := SS_Scripts()
    if !scripts.Length {
        MsgBox("No message scripts found in`n`n" MMA_ACC_DIR
             . "`n`nMake one with Add Hotkey > New Script.",
               "Startup scripts", 0x30)
        return
    }
    startSet := SS_StartupSet()

    ; palette — the Hotstrings window's, so this reads as part of it
    BG_     := "15141C"
    TXT_    := "E6E4EE"
    MUTED_  := "8E8AA6"
    ACCENT_ := "B89CFF"

    ROW_H := 34
    winW  := 560
    top   := 92
    winH  := top + scripts.Length * ROW_H + 66

    sg := Gui("+AlwaysOnTop" (ownerHwnd ? " +Owner" ownerHwnd : ""),
              "Startup scripts")
    sg.BackColor := BG_
    SS_WIN := sg

    sg.SetFont("s13 Bold c" ACCENT_, "Segoe UI")
    sg.Add("Text", "x16 y12 w400", "Startup scripts")
    sg.SetFont("s9 Norm c" MUTED_, "Segoe UI")
    sg.Add("Text", "x16 y40 w" (winW - 32),
           "Every message script and whether it is running right now. "
         . Chr(0x25CF) " marks the ones Settings > Scripts auto-starts.")
    sg.Add("Text", "x16 y74 w" (winW - 32) " h1 0x10")

    ; row controls, kept so the refresh can rewrite them in place
    rows := []
    y := top
    for _, s in scripts {
        sg.SetFont("s10 c" TXT_, "Segoe UI")
        lblName := sg.Add("Text", "x16 y" (y + 6) " w190",
                          (startSet.Has(s.name) ? Chr(0x25CF) " " : "     ")
                        . StrReplace(s.name, ".ahk", ""))
        sg.SetFont("s9 c" MUTED_, "Segoe UI")
        lblState := sg.Add("Text", "x210 y" (y + 7) " w120", "")
        sg.SetFont("s9 c" TXT_, "Segoe UI")
        ; Two buttons, not one toggle. A toggle has to know the current state to
        ; label itself, which is exactly what went wrong with the old strip — and
        ; "restart it" is one press here instead of two guesses.
        btnRun := sg.Add("Button", "x336 y" (y + 2) " w96 h27", "Start")
        btnStop := sg.Add("Button", "x440 y" (y + 2) " w96 h27", "Stop")
        ; .Bind, not a closure: one function body means one set of locals, so a
        ; closure over `s` would give every row the last script in the list.
        btnRun.OnEvent("Click",  SS_Restart.Bind(s.path))
        btnStop.OnEvent("Click", SS_Stop.Bind(s.path))
        rows.Push({path: s.path, name: s.name,
                   lblState: lblState, btnRun: btnRun, btnStop: btnStop})
        y += ROW_H
    }

    y += 10
    sg.Add("Text", "x16 y" y " w" (winW - 32) " h1 0x10")
    y += 12
    sg.SetFont("s9 c" TXT_, "Segoe UI")
    btnAll := sg.Add("Button", "x16 y" y " w150 h28", "Restart all")
    btnAll.OnEvent("Click", RestartAll)
    btnClose := sg.Add("Button", "x" (winW - 106) " y" y " w90 h28", "Close")
    btnClose.OnEvent("Click", Closed)

    sg.OnEvent("Close",  Closed)
    sg.OnEvent("Escape", Closed)

    for attr in [20, 19]                ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", sg.Hwnd, "int", attr,
                    "int*", 1, "int", 4)

    Refresh()
    ; Every second, because the interesting cases all happen without a click:
    ; a script dies, the watchdog puts it back, Add Hotkey restarts one to pick up
    ; an appended block.
    SetTimer(Refresh, 1000)
    sg.Show("w" winW " h" winH)

    Refresh() {
        ; The timer outlives a Destroy by up to a second. Touching a destroyed
        ; control throws, and a throw inside a timer raises a dialog on top of
        ; whatever the user moved on to.
        try {
            for _, r in rows {
                pid := SS_Pid(r.path)
                r.lblState.SetFont(pid ? "c9AE6A0" : "c" MUTED_)
                r.lblState.Value  := pid ? "running  " pid : "stopped"
                r.btnRun.Text     := pid ? "Restart" : "Start"
                r.btnStop.Enabled := pid ? true : false
            }
        } catch {
            SetTimer(Refresh, 0)
        }
    }

    RestartAll(*) {
        for _, r in rows
            SS_Restart(r.path)
        Refresh()
    }

    Closed(*) {
        global SS_WIN
        SetTimer(Refresh, 0)
        SS_WIN := 0
        sg.Destroy()
    }
}

; Stop it if it is up, then start it. One press for the thing this window is for —
; "it has stopped responding" — which the old toggle needed two presses and a
; correct label to do.
SS_Restart(path, *) {
    SplitPath path, &fname
    if !FileExist(path) {
        LOGE("ui.startupscripts", fname " cannot start — the file does not exist", path)
        MsgBox("That file is gone:`n`n" path, "Startup scripts", 0x10)
        return
    }
    SS_Stop(path)
    LOGI("ui.startupscripts", "starting " fname " — clicked in Startup scripts")
    ; Guarded: Run throws on a locked or blocked file, and an unhandled throw here
    ; kills the whole Hotstrings process, taking the manager down with it.
    try Run(path)
    catch as e {
        LOGE("ui.startupscripts", "could not start " fname, LOG_Err(e))
        MsgBox("Could not start " fname ":`n`n" e.Message, "Startup scripts", 0x10)
    }
}

SS_Stop(path, *) {
    SplitPath path, &fname
    pid := SS_Pid(path)
    if !pid
        return
    LOGI("ui.startupscripts", "stopping " fname " (pid " pid ")"
                            . " — clicked in Startup scripts")
    try ProcessClose(pid)
    ; ProcessClose returns as soon as the kill is issued; the window can outlive it
    ; by a few milliseconds, which is long enough for a Restart's Run to land while
    ; the old instance is still around.
    ProcessWaitClose(pid, 2)
}
