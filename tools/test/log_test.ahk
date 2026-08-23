#Requires AutoHotkey v2.0
#Include "../../src/core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  log_test.ahk — does the logger actually log, and does each switch switch?
; ───────────────────────────────────────────────────────────────────────────────
;  Prints "N passed, M failed", so Settings ▸ Debug ▸ Run all tests picks it up
;  like every other file in tools\.
;
;  ── IT WRITES TO A TEMP CFG, NOT YOURS ───────────────────────────────────────
;  Every switch here is read out of mass_gui.cfg [Debug], so testing them means
;  writing them — and tools\ has form for this: the test files in this folder
;  write real settings into real userdata\ and have broken model detection by
;  doing it. So this snapshots the three keys, restores them in a finally, and
;  restores them again from OnExit in case the process is killed mid-run.
;
;  It logs to the real mma.log deliberately. A logger tested against a fake sink
;  is a logger that has not been tested against the one thing that actually goes
;  wrong: eight processes appending to one file at once.
; ═══════════════════════════════════════════════════════════════════════════════

pass := 0, fail := 0

Check(label, cond) {
    global pass, fail
    if cond {
        pass++
        FileAppend("  ok    " label "`n", "*")
    } else {
        fail++
        FileAppend("  FAIL  " label "`n", "*")
    }
}

; ── snapshot, so this cannot leave the user's debug switches changed ──────────
snap := Map()
for k in ["Logging", "Popups", "MaxLogging"]
    snap[k] := Trim(IniRead(MMA_CFG, "Debug", k, ""))

Restore() {
    global snap
    for k, v in snap {
        try {
            if (v = "")
                IniDelete(MMA_CFG, "Debug", k)
            else
                IniWrite(v, MMA_CFG, "Debug", k)
        }
    }
}
OnExit((*) => Restore())

Set(key, val) {
    IniWrite(val, MMA_CFG, "Debug", key)
    ; The switches are cached for LOG_SETTINGS_TTL, so a write is not visible to
    ; the logger until the cache expires. Reaching in and expiring it is what
    ; keeps this test from taking nine seconds of Sleep.
    global _LOG_T := 0
}

; Everything below writes into the REAL log, so bracket it — a marker either side
; means a human reading mma.log later can see where the test's noise begins and
; ends rather than mistaking it for a real failure.
LOG_Marker("log_test.ahk BEGIN")

try {
    sizeBefore := FileExist(MMA_LOGFILE) ? FileGetSize(MMA_LOGFILE) : 0

    ; ── the file gets written at all ──────────────────────────────────────────
    Set("Logging", "1"), Set("MaxLogging", "0"), Set("Popups", "0")
    marker := "probe-" A_TickCount
    LOGI("test", marker)
    Sleep 30
    body := FileRead(MMA_LOGFILE, "UTF-8")
    Check("LOGI writes a line to mma.log", InStr(body, marker) > 0)
    Check("the line carries its level",    InStr(body, "INFO") > 0)
    Check("the line carries the script",   InStr(body, A_ScriptName) > 0)

    ; ── one event is one line, whatever the message contains ──────────────────
    m2 := "multi-" A_TickCount
    LOGI("test", m2 "`nsecond line`nthird line")
    Sleep 30
    body := FileRead(MMA_LOGFILE, "UTF-8")
    ; `rec`, not `ln`. At top level (not inside a function) a for-loop output
    ; variable named `ln` collides with AHK's built-in Ln() and the script will
    ; not load — the same trap that made this codebase's info level LOGI rather
    ; than LOG, since Log() is built in too.
    for rec in StrSplit(body, "`n", "`r")
        if InStr(rec, m2)
            found := rec
    Check("a newline in a message does not split the record",
          IsSet(found) && InStr(found, "second line") && InStr(found, "third line"))

    ; ── max logging is what gates VERB ────────────────────────────────────────
    Set("MaxLogging", "0")
    vOff := "verb-off-" A_TickCount
    LOGV("test", vOff)
    Sleep 30
    Check("VERB is suppressed with max logging off",
          !InStr(FileRead(MMA_LOGFILE, "UTF-8"), vOff))

    Set("MaxLogging", "1")
    vOn := "verb-on-" A_TickCount
    LOGV("test", vOn)
    Sleep 30
    Check("VERB is written with max logging on",
          InStr(FileRead(MMA_LOGFILE, "UTF-8"), vOn) > 0)
    Set("MaxLogging", "0")

    ; ── the master switch ─────────────────────────────────────────────────────
    Set("Logging", "0")
    off := "off-" A_TickCount
    LOGI("test", off)
    Sleep 30
    Check("INFO is suppressed with logging off",
          !InStr(FileRead(MMA_LOGFILE, "UTF-8"), off))

    ; A failure outlives the master switch on purpose — see LOGE's comment.
    ; Popups stay OFF here or this test would open a modal dialog and hang.
    efail := "fail-" A_TickCount
    LOGE("test", efail)
    Sleep 30
    body := FileRead(MMA_LOGFILE, "UTF-8")
    Check("FAIL is written even with logging off", InStr(body, efail) > 0)
    Check("FAIL is mirrored into error_log.txt",
          InStr(FileRead(MMA_ERRLOG, "UTF-8"), efail) > 0)
    Set("Logging", "1")

    ; ── the helpers ───────────────────────────────────────────────────────────
    threw := "threw-" A_TickCount
    r := LOG_Try("test", threw, () => 1 / 0, &ok)
    Sleep 30
    body := FileRead(MMA_LOGFILE, "UTF-8")
    Check("LOG_Try reports ok=false when the callback throws", !ok)
    Check("LOG_Try logs the failure",        InStr(body, threw) > 0)
    Check("LOG_Try names the actual error",  InStr(body, "Divide by zero") > 0)

    got := LOG_Try("test", "returns its value", () => 42, &ok2)
    Check("LOG_Try passes the return value through", got = 42 && ok2)

    bail := "bail-" A_TickCount
    LOG_Bail("test", bail)
    Sleep 30
    body := FileRead(MMA_LOGFILE, "UTF-8")
    Check("LOG_Bail writes at BAIL level",
          RegExMatch(body, "BAIL.*" bail) > 0)

    kv := "kv-" A_TickCount
    LOG_Kv("test", Map("marker", kv, "n", 7))
    Sleep 30
    Check("LOG_Kv writes key=value pairs",
          RegExMatch(FileRead(MMA_LOGFILE, "UTF-8"), "marker=" kv "\s+n=7") > 0)

    ; ── the log only ever grows on its own terms ──────────────────────────────
    Check("the log grew during this run",
          FileGetSize(MMA_LOGFILE) > sizeBefore)

    ; ── the diagnostic report ─────────────────────────────────────────────────
    rp := LOG_Report(20)
    Check("LOG_Report writes a file", rp != "" && FileExist(rp))
    if (rp != "") {
        rtext := FileRead(rp, "UTF-8")
        Check("the report carries the environment", InStr(rtext, "autohotkey") > 0)
        Check("the report carries mass_gui.cfg",    InStr(rtext, "mass_gui.cfg") > 0)
        Check("the report carries hotkeys.ini",     InStr(rtext, "hotkeys.ini") > 0)
        Check("the report carries the log tail",    InStr(rtext, "log lines") > 0)
    }
} catch as e {
    fail++
    FileAppend("  FAIL  the test itself threw: " LOG_Err(e) "`n", "*")
} finally {
    LOG_Marker("log_test.ahk END")
    Restore()
}

FileAppend("`n" pass " passed, " fail " failed`n", "*")
ExitApp fail ? 1 : 0
