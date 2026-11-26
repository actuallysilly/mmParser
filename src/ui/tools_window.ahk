#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  tools_window.ahk — switch a background tool on, off, or restart it.
; ───────────────────────────────────────────────────────────────────────────────
;  The logic only (TOOLS_*). The window that calls it is ui\tools_settings.ahk,
;  which grew out of this file's old one-row-per-tool window (2026-10-24) and
;  now carries every tool's settings as well. What follows is that window's
;  history, still true of the buttons.
;
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

; The window itself — every tool's settings on one scrolling page, with
; these On / Off / Restart buttons on each service — is ui\tools_settings.ahk.
