#Requires AutoHotkey v2.0
#Include "paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  runner.ahk — talking to the Python runner (src\services\runner\runner.pyw).
; ───────────────────────────────────────────────────────────────────────────────
;  Every Python tool MMA runs is started by ONE windowless pythonw process, the
;  runner. MMA starts it once and then sends it one-line commands over a named
;  pipe:  status | start <tool> | stop <tool> | restart <tool> | quit
;
;  This replaced ten .vbs launchers. Each one found Python by running
;  `cmd /c where pythonw.exe` through WScript's Exec, which ALWAYS opens a console,
;  so MMA's startup flashed one console window per service.
;
;  The runner owns restarts (backoff, kill-on-close job). MMA still decides WHAT
;  runs, from its feature switches. "Is it up?" is still answered by each tool's
;  own named stop event (SVC_Running), so the 5-second watchdog never has to make
;  a pipe round-trip just to look.
;
;  Included by core\processes.ahk (the GUI) and core\ai_suite.ahk (the GUI AND
;  the engine), so it must stand on its own: paths.ahk and nothing else.
; ═══════════════════════════════════════════════════════════════════════════════

global RUN_PIPE   := "\\.\pipe\MMA.runner"
global RUN_MUTEX  := "Global\MMA.runner.mutex"
global RUN_SCRIPT := MMA_SRC "\services\runner\runner.pyw"

; A real pythonw.exe from PATH, or "" when there is none. Cached per process.
;
; Scans PATH itself rather than asking `where`, which would flash a console. A
; zero-byte hit is the Microsoft Store's App Execution Alias, a stub that opens
; the Store instead of running Python, and on this machine it is listed FIRST, so
; it is skipped rather than trusted. Only python.exe in a folder means its
; pythonw.exe neighbour; python.exe itself is the last resort (Run hides it).
RUN_PythonExe() {
    static cached := 0
    if (cached != 0)
        return cached
    console := ""
    for _, dir in StrSplit(EnvGet("PATH"), ";") {
        dir := RTrim(Trim(dir, " `t`""), "\")
        if (dir = "")
            continue
        if _RUN_RealExe(dir "\pythonw.exe") {
            cached := dir "\pythonw.exe"
            break
        }
        if (console = "" && _RUN_RealExe(dir "\python.exe"))
            console := dir "\python.exe"
    }
    if (cached = 0)
        cached := console
    if (cached != "")
        LOGI("runner", "interpreter found: " cached)
    else
        LOGW("runner", "no python.exe or pythonw.exe on PATH (zero-byte Store aliases"
                     . " ignored), so no Python tool can start")
    return cached
}

_RUN_RealExe(path) {
    return FileExist(path) && FileGetSize(path) > 0
}

; Is a runner up? Its single-instance mutex answers in one DllCall.
RUN_Up() {
    static SYNCHRONIZE := 0x00100000
    h := DllCall("OpenMutexW", "UInt", SYNCHRONIZE, "Int", false, "Str", RUN_MUTEX, "Ptr")
    if !h
        return false
    DllCall("CloseHandle", "Ptr", h)
    return true
}

; Send one command, return the runner's one-line reply ("ok ..." / "err ..."),
; or "" when no runner answered.
;
; CallNamedPipeW is connect + write + read + close in one call. A brief "no such
; pipe" while the runner is coming up is retried, so a command sent right after
; RUN_Ensure is not lost.
RUN_Send(cmd, timeoutMs := 3000) {
    static ERROR_FILE_NOT_FOUND := 2
    len := StrPut(cmd, "UTF-8")                      ; includes the terminator
    inBuf := Buffer(len)
    StrPut(cmd, inBuf, "UTF-8")
    out := Buffer(65536, 0)
    loop 10 {
        got := 0
        if DllCall("CallNamedPipeW", "Str", RUN_PIPE, "Ptr", inBuf, "UInt", len - 1,
                   "Ptr", out, "UInt", out.Size, "UInt*", &got, "UInt", timeoutMs)
            return StrGet(out, got, "UTF-8")
        if (A_LastError != ERROR_FILE_NOT_FOUND || !RUN_Up())
            break
        Sleep 50
    }
    LOGV("runner", "'" cmd "' got no answer (error " A_LastError ")")
    return ""
}

; Start the runner if it is not up, and wait (up to ~5s) until its pipe answers.
; True when there is a runner to talk to.
RUN_Ensure() {
    if RUN_Up()
        return true
    py := RUN_PythonExe()
    if (py = "")
        return false
    if !FileExist(RUN_SCRIPT) {
        LOGE("runner", "runner.pyw is missing, so no Python tool can start", RUN_SCRIPT)
        return false
    }
    LOGI("runner", "starting the runner")
    try Run('"' py '" "' RUN_SCRIPT '"', MMA_ROOT, "Hide")
    catch as e {
        LOGE("runner", "could not start the runner", LOG_Err(e))
        return false
    }
    loop 100 {
        if DllCall("WaitNamedPipeW", "Str", RUN_PIPE, "UInt", 50)
            return true
        Sleep 50
    }
    LOGW("runner", "the runner did not open its pipe within 5s")
    return RUN_Up()
}

; Start a service (by its SVC id). Starts the runner first if need be.
RUN_Start(tool) {
    if !RUN_Ensure()
        return ""
    return RUN_Send("start " tool)
}

; Open a GUI tool (testflow, arena, livetrainer, shiftview, chatview, lore).
; Never starts a runner just for a window: with none up, `runner.pyw --start`
; opens the tool directly, the way its .vbs used to. True when something started.
RUN_Open(tool) {
    if (RUN_Up() && SubStr(RUN_Send("start " tool), 1, 2) = "ok")
        return true
    py := RUN_PythonExe()
    if (py = "")
        return false
    Run('"' py '" "' RUN_SCRIPT '" --start ' tool, MMA_ROOT)
    return true
}

; Ask the runner to stop a service: set its stop event, wait, then kill. False
; when no runner answered, so the caller can set the event itself.
RUN_Stop(tool) {
    if !RUN_Up()
        return false
    return SubStr(RUN_Send("stop " tool), 1, 2) = "ok"
}

RUN_Restart(tool) {
    if !RUN_Ensure()
        return ""
    return RUN_Send("restart " tool)
}

; The runner's view as JSON text after "ok ", or "" with no runner.
RUN_Status() {
    if !RUN_Up()
        return ""
    return RUN_Send("status")
}

; Stop every service and end the runner. GUI tools the user opened stay open.
RUN_Quit() {
    if !RUN_Up()
        return
    LOGI("runner", "asking the runner to quit")
    RUN_Send("quit")
}
