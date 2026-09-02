#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  tools_window.ahk — one row per background tool: is it up, switch it on or off.
; ───────────────────────────────────────────────────────────────────────────────
;  Replaces the "Pinger: ON / Pinger: OFF" button on the main window's bottom
;  strip, which was one background tool out of five getting a button because it
;  was the one people asked about most.
;
;  The others (stats overlay, both detectors, the automation listener) were
;  reachable only through Settings > Features — a window you open, click a tab in,
;  tick a box in, and press Save in, for something you switch on and off several
;  times a shift. So the strip had a fast path for one tool and no path at all for
;  the rest.
;
;  Same lesson as the old "◻ NAME" script toggles (see startup_scripts.ahk): the
;  Pinger button's LABEL was its state, refreshed on a timer that only ran while
;  the main window was up. Here every row's state is READ — the pinger and the
;  listener answer through their named stop events, the three AHK tools through
;  their hidden windows — and two buttons say what they do rather than what the
;  tool currently is.
;
;  ── Why this writes cfg keys ────────────────────────────────────────────────
;  Switching a tool on here writes exactly the key Settings > Features writes, and
;  that is the point in both directions:
;
;    * Launch* gates on FEAT(), which reads the key. Launching without writing it
;      first bails on the old value and the click does nothing — the bug the old
;      TogglePinger carried a comment about.
;    * the watchdog restarts anything whose feature is on, every five seconds. So
;      "off" that does not write the key is a tool that comes back by itself
;      within five seconds, looking like the button did nothing.
;
;  Which makes on/off here the SAME statement as the checkbox over there, not a
;  temporary override of it — open Settings afterwards and the box agrees. The one
;  way to disagree is to leave Settings open across a toggle here and then press
;  Save: that panel writes every feature key from checkboxes it read when it
;  opened. That is a pre-existing hazard of the Features panel, not of this window.
;
;  ── Why there is a third button ─────────────────────────────────────────────
;  Every one of these tools reads its settings once, at startup: the pinger its
;  interval, autoword its ini AND its trained model, the detectors their regions.
;  So editing any of that changes nothing until the tool goes round again, and
;  Off-then-On was the way to do it — two presses, with a stretch in between where
;  the feature key says off and the watchdog is entitled to act on it.
;
;  Restart is one press that never writes the key, so the tool is never "off" and
;  the watchdog never sees a reason to interfere. It also waits for the old
;  instance to actually be gone, which Off-then-On could not: click fast enough
;  and the launcher's own "already running" check swallows the On silently. Same
;  shape as Startup scripts ▸ Restart, which learned this first.
; ═══════════════════════════════════════════════════════════════════════════════

; The tools this window drives, in the order they appear.
;
; Each row is a feature id from the registry (modes.ahk) plus the three functions
; that make it real. The label comes from FEAT_META rather than being retyped, so
; a tool renamed in the registry is renamed here too.
;
; Only tools that are a PROCESS are here. The rest of the registry is hotkeys and
; behaviour — there is nothing to show a running state for, and Settings is the
; right place for a switch you set once. "startupScripts" is deliberately absent
; as well: it is the watchdog itself, and its scripts have their own window under
; Hotstrings > Startup scripts.
;
; start is bound with announce := true where the launcher takes it: a click here is
; deliberate, so "nothing happened because Python is missing" gets said out loud
; instead of going to the log.
TOOLS_List() {
    out := []
    for id in SVC_ORDER
        out.Push({id: id})
    return out
}

; A tool's label, from the registry.
TOOLS_Label(id) {
    return FEAT_META.Has(id) ? FEAT_META[id].label : id
}

; Is its switch on? FEAT() itself is no good here: it answers false for everything
; in Easy mode, so every row would read "off" and switching one on would show no
; change. FEAT_Raw (modes.ahk) is the feature's own checkbox, ignoring the mode —
; the same distinction the Settings checkboxes make.
TOOLS_On(id) {
    return FEAT_META.Has(id) ? FEAT_Raw(id) : false
}

; Write the switch, then act. Order matters — see the header.
;
; FEAT_SetRaw rather than IniWrite: modes.ahk is the single writer of feature keys
; and logs every CHANGE, so a tool switched on from here shows up in the log in the
; same shape as one switched on from Settings.
TOOLS_Set(t, on) {
    if !FEAT_META.Has(t.id)
        return
    FEAT_SetRaw(t.id, on)
    LOGI("ui.tools", (on ? "switching ON " : "switching OFF ") TOOLS_Label(t.id)
                   . " — clicked in the Tools window")
    ; Guarded: a launcher can throw on a missing interpreter or a locked file, and
    ; an unhandled throw here takes the whole main window down with it.
    try {
        if on
            SVC_Launch(t.id, true)
        else
            SVC_Stop(t.id)
    } catch as e {
        LOGE("ui.tools", "could not " (on ? "start " : "stop ") TOOLS_Label(t.id),
             LOG_Err(e))
        MsgBox("Could not " (on ? "start" : "stop") " " TOOLS_Label(t.id) ":`n`n"
             . e.Message, "Tools", 0x10)
    }
}

; How long to wait for a tool to actually exit before starting it again. Stops
; are a signal, not a kill — the Python services set a named event and leave on
; their own — so "stopped" and "gone" are a moment apart.
global TOOLS_STOP_WAIT_MS := 3000

; Guards the wait below: it Sleeps, and an AHK Gui event can interrupt a sleeping
; one, so a second click would otherwise start a restart inside a restart.
global TOOLS_BUSY := false

; Stop it, wait for it to really be gone, then start it — without touching the
; feature key, so the tool is never off and the watchdog never has a reason to
; step in. See the header for why this is not Off-then-On.
TOOLS_Restart(t) {
    global TOOLS_BUSY
    if TOOLS_BUSY || !FEAT_META.Has(t.id)
        return
    TOOLS_BUSY := true
    LOGI("ui.tools", "restarting " TOOLS_Label(t.id) " — clicked in the Tools window")
    ; Guarded for the same reason TOOLS_Set is: a launcher can throw on a missing
    ; interpreter or a locked file, and an unhandled throw takes the main window
    ; down with it.
    try {
        SVC_Stop(t.id)
        if !TOOLS_WaitDown(t)
            LOGW("ui.tools", TOOLS_Label(t.id) " has not exited after "
                           . TOOLS_STOP_WAIT_MS " ms — starting anyway, and the"
                           . " launcher may find the old one still holding the name")
        SVC_Launch(t.id, true)
    } catch as e {
        LOGE("ui.tools", "could not restart " TOOLS_Label(t.id), LOG_Err(e))
        MsgBox("Could not restart " TOOLS_Label(t.id) ":`n`n" e.Message, "Tools", 0x10)
    } finally {
        TOOLS_BUSY := false
    }
}

; Poll the row's own "is it up?" probe until it says no. That probe is the same
; thing the launcher checks to decide it should bail, so this waits on exactly
; the condition that would swallow the start.
TOOLS_WaitDown(t) {
    DetectHiddenWindows true          ; the AHK tools answer through a hidden window
    deadline := A_TickCount + TOOLS_STOP_WAIT_MS
    loop {
        if !SVC_Running(t.id)
            return true
        if A_TickCount > deadline
            return false
        Sleep 50
    }
}

; The count on the main window's Tools button — what is left of the old
; "Pinger: ON" label, except it is read rather than remembered and it covers all
; five instead of one — is RefreshToolsLabel in core/processes.ahk. It keeps its
; own copy of this list because processes.ahk has to load without the UI files.
;
; The one open instance, or 0. A plain global rather than a static, because the
; close handler is a nested closure that has to clear it — same reasoning as
; SS_WIN in startup_scripts.ahk.
global TOOLS_WIN := 0

OpenToolsWindow(ownerHwnd := 0) {
    global TOOLS_WIN
    ; Already open: raise it rather than stacking a second copy, whose timer would
    ; fight the first one's over the same rows.
    if TOOLS_WIN {
        try {
            TOOLS_WIN.Show()
            return
        }
        TOOLS_WIN := 0
    }

    tools := TOOLS_List()

    ; palette — the Hotstrings and Startup scripts windows', so the three read as
    ; one family
    BG_     := "15141C"
    TXT_    := "E6E4EE"
    MUTED_  := "8E8AA6"
    ACCENT_ := "B89CFF"

    ROW_H := 34
    winW  := 744
    top   := 92
    winH  := top + tools.Length * ROW_H + 66

    tg := Gui("+AlwaysOnTop" (ownerHwnd ? " +Owner" ownerHwnd : ""), "Tools")
    tg.BackColor := BG_
    TOOLS_WIN := tg

    tg.SetFont("s13 Bold c" ACCENT_, "Segoe UI")
    tg.Add("Text", "x16 y12 w400", "Tools")
    tg.SetFont("s9 Norm c" MUTED_, "Segoe UI")
    tg.Add("Text", "x16 y40 w" (winW - 32),
           "The background tools, and whether each one is running right now. "
         . "These are the same switches as Settings " Chr(0x25B8) " Features.")
    tg.Add("Text", "x16 y74 w" (winW - 32) " h1 0x10")

    rows := []
    y := top
    for _, t in tools {
        tg.SetFont("s10 c" TXT_, "Segoe UI")
        tg.Add("Text", "x16 y" (y + 6) " w290", TOOLS_Label(t.id))
        tg.SetFont("s9 c" MUTED_, "Segoe UI")
        lblState := tg.Add("Text", "x312 y" (y + 7) " w100", "")
        tg.SetFont("s9 c" TXT_, "Segoe UI")
        ; Two buttons rather than one toggle, and each greys out when the tool is
        ; already that way. A single button has to know the state to label itself,
        ; which is the thing that went wrong with "Pinger: ON".
        btnOn  := tg.Add("Button", "x420 y" (y + 2) " w96 h27", "On")
        btnOff := tg.Add("Button", "x524 y" (y + 2) " w96 h27", "Off")
        ; Restart last, so On and Off stay where the hands already expect them.
        btnRestart := tg.Add("Button", "x628 y" (y + 2) " w100 h27", "Restart")
        ; .Bind, not a closure: one function body means one set of locals, so a
        ; closure over `t` would give every row the last tool in the list.
        btnOn.OnEvent("Click",  ToolOn.Bind(t))
        btnOff.OnEvent("Click", ToolOff.Bind(t))
        btnRestart.OnEvent("Click", ToolRestart.Bind(t))
        rows.Push({tool: t, lblState: lblState, btnOn: btnOn, btnOff: btnOff,
                   btnRestart: btnRestart})
        y += ROW_H
    }

    y += 10
    tg.Add("Text", "x16 y" y " w" (winW - 32) " h1 0x10")
    y += 12
    tg.SetFont("s9 c" MUTED_, "Segoe UI")
    lblMode := tg.Add("Text", "x16 y" (y + 6) " w" (winW - 140), "")
    tg.SetFont("s9 c" TXT_, "Segoe UI")
    btnClose := tg.Add("Button", "x" (winW - 106) " y" y " w90 h28", "Close")
    btnClose.OnEvent("Click", Closed)

    tg.OnEvent("Close",  Closed)
    tg.OnEvent("Escape", Closed)

    for attr in [20, 19]                ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", tg.Hwnd, "int", attr,
                    "int*", 1, "int", 4)

    Refresh()
    ; Every second, because the interesting cases all happen without a click here:
    ; the watchdog restarting a tool, a detector exiting on a bad read, the pinger
    ; being stopped from its own tray.
    SetTimer(Refresh, 1000)
    tg.Show("w" winW " h" winH)

    ToolOn(t, *) {
        TOOLS_Set(t, true)
        Refresh()
        try RefreshToolsLabel()
    }
    ToolOff(t, *) {
        TOOLS_Set(t, false)
        Refresh()
        try RefreshToolsLabel()
    }
    ToolRestart(t, *) {
        TOOLS_Restart(t)
        Refresh()
        try RefreshToolsLabel()
    }

    Refresh() {
        ; The timer outlives a Destroy by up to a second. Touching a destroyed
        ; control throws, and a throw inside a timer raises a dialog on top of
        ; whatever the user moved on to.
        try {
            DetectHiddenWindows true
            for _, r in rows {
                on := TOOLS_On(r.tool.id)
                up := SVC_Running(r.tool.id)
                ; Three states, not two. "on but not running" is the one worth
                ; seeing: it is what a missing Python or a crashed detector looks
                ; like, and with a plain on/off it reads as working.
                if up {
                    r.lblState.SetFont("c9AE6A0")
                    r.lblState.Value := "running"
                } else if on {
                    r.lblState.SetFont("cE0B978")
                    r.lblState.Value := "on, not up"
                } else {
                    r.lblState.SetFont("c8E8AA6")
                    r.lblState.Value := "off"
                }
                r.btnOn.Enabled  := !on || !up
                r.btnOff.Enabled := on || up
                ; Restart is stop-then-start, so it needs something to be there:
                ; a tool that is off and down has nothing to restart, and On is
                ; the button for that.
                r.btnRestart.Enabled := on || up
            }
            ; Easy mode switches off every feature in the registry, so nothing
            ; started from here would survive the next FEAT() check. Say so, rather
            ; than let the buttons look broken.
            lblMode.Value := MODE_IsEasy()
                ? "MMA is in Easy mode, which keeps every tool off whatever these say."
                : ""
        } catch {
            SetTimer(Refresh, 0)
        }
    }

    Closed(*) {
        global TOOLS_WIN
        SetTimer(Refresh, 0)
        TOOLS_WIN := 0
        tg.Destroy()
        try RefreshToolsLabel()
    }
}
