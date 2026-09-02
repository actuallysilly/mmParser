#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  dpi.ahk — make AHK agree with the screen on a mixed-DPI desk.
; ───────────────────────────────────────────────────────────────────────────────
;  AutoHotkey ships a SYSTEM-DPI-aware manifest. On a machine where every monitor
;  shares the primary's scaling that is indistinguishable from being fully aware,
;  which is why this went unnoticed for so long. Put a second monitor on a
;  DIFFERENT scale and Windows starts handing this process invented numbers for
;  anything on it — GetWindowRect, GetCursorPos, the virtual screen, the origin a
;  BitBlt reads from, and where a Gui actually lands.
;
;  Measured on this desk (primary 1920x1080 @125%, second 2160x3840 @150%), a
;  -DPIScale box asked for at (-1200,400) 400x200 on the second display:
;
;      system-aware (the default) ->  x=-1008 y=545  480x240
;      per-monitor aware          ->  x=-1200 y=400  400x200
;
;  Off by 144/120 = 1.2 in BOTH size and position. SysGet's virtual screen comes
;  back 4080x3200 instead of 4080x3840, so a full-screen overlay stops short of
;  the tall monitor too.
;
;  The failure this produces is nastier than "everything is 20% off", because
;  within the process the wrong numbers are all CONSISTENT: the mouse, the overlay
;  and the capture rect agree with each other and disagree only with the screen.
;  So a selection box sits away from the cursor, a scan reads pixels next to the
;  thing it was calibrated on, and every reading looks plausible.
;
;  ─── THREAD or PROCESS ───────────────────────────────────────────────────────
;  Two entry points, and picking the wrong one is the only way to break something:
;
;   • DPI_ProcessWide() — for a script whose whole job is reading pixels and
;     drawing -DPIScale overlays. One call, no path can miss it. NOT for anything
;     that builds a normal Gui: a window laid out in logical units (x10 y45 w200,
;     with SetFont doing the scaling) still gets sized against A_ScreenDPI, which
;     stays the SYSTEM dpi regardless — so on a differently-scaled monitor it
;     would render at the wrong size with no way to notice.
;
;   • DPI_Enter() / DPI_Leave() — for a library that is #Included into a process
;     which does have such a Gui. Thread-scoped and reversible.
;
;  A window's awareness is fixed when it is CREATED, so overlays built between
;  Enter and Leave keep the correct behaviour for their whole life.
;
;  Always pair Enter with Leave in a `finally`, never a plain trailing call:
;  leaving the thread per-monitor aware silently resizes every Gui opened
;  afterwards, and that symptom appears nowhere near this file.
; ═══════════════════════════════════════════════════════════════════════════════

; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. -3 (v1) also works and is what
; OCR.ahk's own docs suggest; v2 additionally fixes child windows and dialogs.
global DPI_PER_MONITOR_V2 := -4

; Cover a WHOLE SCRIPT. Call once, as a top-level statement, before anything
; reads a coordinate.
;
; This deliberately uses the THREAD call, not SetProcessDpiAwarenessContext.
; Measured: the process form fails outright here, returning 0 with
; A_LastError = 5 (ERROR_ACCESS_DENIED), because AutoHotkey.exe already declares
; DPI awareness in its MANIFEST and Windows refuses to change it afterwards.
;
; The thread form works, and it is enough: AutoHotkey's "threads" are pseudo-
; threads sharing one OS thread, so a context set at the top of the script is
; still in force inside every hotkey, every SetTimer callback, and every callback
; nested inside those. Verified to that depth — virtual screen reads 4080x3840
; rather than 4080x3200 in all of them.
;
; Nothing restores it, on purpose: for a service whose whole job is pixels, the
; correct context is the one it should hold for its entire life.
DPI_ScriptWide() {
    return !!DPI_Enter()
}

; Make THIS THREAD per-monitor aware. Returns the previous context, to be handed
; back to DPI_Leave — 0 means the call is unavailable and Leave will do nothing.
DPI_Enter() {
    global DPI_PER_MONITOR_V2
    prev := 0
    try prev := DllCall("SetThreadDpiAwarenessContext",
                        "ptr", DPI_PER_MONITOR_V2, "ptr")
    return prev
}

; Restore what DPI_Enter returned. Safe to call with 0.
DPI_Leave(prev) {
    if prev
        try DllCall("SetThreadDpiAwarenessContext", "ptr", prev, "ptr")
}

; ── the one-liner form ────────────────────────────────────────────────────────
;  `scope := DpiScope()` as the first line of a function, and that is the whole
;  change — no restructuring the body, and no way to leak the context out of a
;  path somebody forgot. AHK v2 objects are REFERENCE COUNTED, not garbage
;  collected, so the local's last reference is released the moment the function
;  returns and __Delete runs there — on an early `return`, and on an exception
;  unwinding through it, which is exactly where a hand-written restore gets
;  missed.
;
;  Keep the result in a local. Assign it to a global, or capture it in a closure,
;  and the scope outlives the function — which is the one way to misuse this.
class DpiScope {
    __New() {
        this.prev := DPI_Enter()
    }
    __Delete() {
        DPI_Leave(this.prev)
    }
}
