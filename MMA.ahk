#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  MMA.ahk — the one thing you double-click.
; ───────────────────────────────────────────────────────────────────────────────
;  A launcher, not the app. The GUI is src\ui\main_window.ahk; this only exists so
;  the front door stays at the top of the tree while the code lives in src\.
;
;  Why Run and not #Include: an AHK script's main window is TITLED WITH ITS FULL
;  PATH, and three things depend on that title being the GUI's real path —
;  HK_Broadcast (which finds MMA's scripts by it), processes.ahk (which closes
;  them by it) and sequences.ahk (which builds a WinTitle from MMA_SRC_GUI to post
;  the auto-parse message). #Include would run the GUI under the title "MMA.ahk"
;  and all three would quietly stop matching. Run keeps one canonical identity.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "src\core\paths.ahk"

if !FileExist(MMA_SRC_GUI) {
    MsgBox "Cannot find the main window at:`n`n" MMA_SRC_GUI
         . "`n`nMMA.ahk must sit in the repo root, beside src\.", "MMA", 0x10
    ExitApp
}

Run '"' A_AhkPath '" "' MMA_SRC_GUI '"'
ExitApp
