#Requires AutoHotkey v2.0
#Include "paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  crashlog.ahk — every script's uncaught errors, in one place.
; ───────────────────────────────────────────────────────────────────────────────
;  A script that "randomly dies" should leave a breadcrumb. Without this, an
;  uncaught error shows AHK's dialog, the user dismisses it, the process is gone,
;  and error_log.txt says nothing at all.
;
;  This lived inside utils.ahk, which meant only the scripts that include utils
;  were covered — and main_window.ahk is not one of them. The GUI, the single most
;  complicated script here, was the one thing that could die without a trace.
;  Keeping it separate lets mass_gui have the logger without pulling in utils'
;  hotstrings and send helpers, which it has no business registering.
;
;  Behaviour is otherwise unchanged: returning 0 keeps AHK's default dialog.
; ═══════════════════════════════════════════════════════════════════════════════

OnError(_MMA_LogError)
_MMA_LogError(err, mode) {
    try {
        detail := IsObject(err) ? (err.HasProp("Message") ? err.Message : Type(err)) : err
        line   := (IsObject(err) && err.HasProp("Line")) ? "  (line " err.Line ")" : ""
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [" A_ScriptName "]  " detail line "`n",
                   MMA_ERRLOG, "UTF-8")
    }
    return 0   ; 0 = keep default behaviour (log only)
}
