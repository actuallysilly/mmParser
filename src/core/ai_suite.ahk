#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "runner.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  ai_suite.ahk — open the AI tools: TestFlow, the Arena, Live Trainer, Fan Viewer and
;  the "what's on screen" debug view.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own file because two processes need it: the engine binds the hotkeys
;  ([util] testFlow / liveTrainer / shiftViewer / chatView, see chat\nav.ahk),
;  and the main window's Tools window has a button for each. A launcher that
;  lived in the engine's chat\suggest.ahk was one the Tools window could not call.
;
;  Each opens through the runner (core\runner.ahk), which starts it with no
;  console window; with no runner up, `runner.pyw --start <tool>` opens it
;  directly. A press while the tool is already open brings its window forward
;  instead of starting a second copy.
; ═══════════════════════════════════════════════════════════════════════════════

TestFlowOpen(*) {
    ; The Lab, not the clone: the clone's title contains "Infloww Messages",
    ; which is what MMA's own screen readers look for, so it is not one to raise.
    AIS_Open("TestFlow Lab ahk_exe pythonw.exe", "testflow")
}

; Both sides AI, you step in anywhere (tools/testflow/arena.py). Its title is
; never "Infloww Messages", so it is safe to raise.
ArenaOpen(*) {
    AIS_Open("TestFlow Arena ahk_exe pythonw.exe", "arena")
}

LiveTrainerOpen(*) {
    AIS_Open("MMA Live Trainer ahk_exe pythonw.exe", "livetrainer")
}

ShiftViewerOpen(*) {
    AIS_Open("MMA Fan Viewer ahk_exe pythonw.exe", "shiftview")
}

; The chat reader's read drawn as an Infloww-style chat beside the real pane,
; plus the exact text the model is given.
ChatViewOpen(*) {
    AIS_Open("What's on screen ahk_exe pythonw.exe", "chatview")
}

; Pick a screen recording and turn it into chats (tools/videoimport), saved to
; the shift log or shown once in a throwaway Fan Viewer.
VideoImportOpen(*) {
    AIS_Open("MMA Video Import ahk_exe pythonw.exe", "videoimport")
}

; `tool` is the runner's name for it (TOOLS in src\services\runner\runner.pyw).
AIS_Open(win, tool) {
    if WinExist(win) {
        WinActivate(win)
        return
    }
    try
        ok := RUN_Open(tool)
    catch as e {
        LOGW("ai.suite", "could not open " tool ": " e.Message)
        ok := false
    }
    if !ok {
        ToolTip("Could not start " tool " (no Python found?) — see the log")
        SetTimer(() => ToolTip(), -3000)
    }
}

; One desktop shortcut per tool: pythonw running `runner.pyw --start <tool>`.
; The interpreter is named in full because .pyw has no file association on this
; machine. The shortcut goes to the running runner, or opens the tool directly.
AIS_MakeShortcuts() {
    made := []
    py := RUN_PythonExe()
    if (py = "" || !FileExist(RUN_SCRIPT))
        return ""
    for t in [["TestFlow",     "testflow"],
              ["Arena",        "arena"],
              ["Live Trainer", "livetrainer"],
              ["Fan Viewer",   "shiftview"]] {
        lnk := A_Desktop "\MMA " t[1] ".lnk"
        ico := MMA_ASSETS "\icon.ico"
        try {
            FileCreateShortcut(py, lnk, MMA_ROOT,
                               '"' RUN_SCRIPT '" --start ' t[2], "MMA " t[1],
                               FileExist(ico) ? ico : "")
            made.Push(t[1])
        } catch as e
            LOGE("ai.suite", "could not write " lnk, LOG_Err(e))
    }
    out := ""
    for n in made
        out .= (out = "" ? "" : ", ") n
    LOGI("ai.suite", "desktop shortcuts written: " out)
    return out
}
