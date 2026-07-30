#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  debug_panel.ahk — the Debug tab: launch the probes, run the tests, read the logs.
; ───────────────────────────────────────────────────────────────────────────────
;  Everything here already existed as a file in tools\ that you had to find in
;  Explorer and double-click. That is fine when you wrote them; it is useless at
;  2am when a key "does nothing" and you cannot remember whether the probe is a
;  separate script (it is) or part of MMA (it is not).
;
;  ─── THE ONE THING THIS TAB IS REALLY FOR ────────────────────────────────────
;  A probe is a SEPARATE PROCESS. Its hotkey exists only while it runs, so
;  pressing Ctrl+Alt+F10 with no probe up does nothing, silently, and looks
;  exactly like a broken feature. The probes now show a badge that stays on
;  screen, and this tab says so next to the button that starts them — because the
;  question "is it even running?" is the one that actually costs time.
;
;  ─── DIAGNOSTICS: THE THREE SWITCHES ─────────────────────────────────────────
;  This tab is the SOLE writer of mass_gui.cfg [Debug], the same ownership rule
;  the Features tab follows for its keys — one setting, one control, one place.
;
;  They are written the INSTANT you click, not on Save. Two reasons. The switches
;  are read by eight separate processes, none of which is this one, and all of
;  them re-read the cfg on a short timer (core\log.ahk) — so a click is live
;  everywhere within about a second and a half with no broadcast, no restart and
;  no Save. And a debugging switch you have to remember to Save is a switch that
;  is off in the log you finally go and read.
;
;  MMA_DEBUG in the environment overrides all three. When it does, the boxes are
;  DISABLED and say so — a checkbox that silently does nothing because something
;  outside the app is winning is precisely the failure this whole feature exists
;  to stamp out, and it would be embarrassing to ship it here.
; ═══════════════════════════════════════════════════════════════════════════════

class DebugPanel {
    ; The interactive probes: they register a hotkey and stay resident.
    ; {label, file, note}
    static PROBES := [
        {label: "Next follow-up",  file: "tools\nextfu_probe.ahk",
         note:  "OCRs the chat in front and shows which follow-up it would send."},
        {label: "Tab detector",    file: "tools\detector_probe.ahk",
         note:  "Reads the Infloww tab strip and suggests GreyColor / GapTol."},
        {label: "Model readout",   file: "tools\model_detect_test.ahk",
         note:  "Live colour readout under the cursor. ^!F5 reloads, ^!F12 quits."}]

    ; The self-tests: they print "N passed, M failed" to stdout and exit. No
    ; screen, no hotkeys, safe to run mid-shift — with one exception, noted.
    static TESTS := [
        ; First, because if the logger is broken every other diagnosis in this
        ; tab is being read off a file that cannot be trusted.
        {label: "logging",              file: "tools\log_test.ahk"},
        {label: "next follow-up logic", file: "tools\nextfu_test.ahk"},
        {label: "mass key binding",     file: "tools\mass_bind_test.ahk"},
        {label: "mass store",           file: "tools\store_test.ahk"},
        {label: "json",                 file: "tools\json_test.ahk"},
        {label: "active model",         file: "tools\active_model_test.ahk"},
        ; Builds a real Settings window and closes it, so a window flashes.
        {label: "settings window",      file: "tools\settings_build_test.ahk"}]

    __New(hostGui, x, y, w, h) {
        this.gui     := hostGui
        this.queue   := []            ; tests still to run
        this.running := false

        y0 := y

        ; ══ diagnostics ═══════════════════════════════════════════════════════
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Diagnostics")
        hostGui.SetFont("s9 Norm")
        y0 += 22

        hostGui.SetFont("s8")
        hostGui.Add("Text", "x" x " y" y0 " w" w " cGray",
                    "Every MMA process writes to one file, debuglogs\mma.log — what it"
                  . " did, and every point where it deliberately did nothing. These"
                  . " apply within a second or two, everywhere, with no restart.")
        hostGui.SetFont("s9")
        y0 += 30

        forced := DebugPanel.Forced()

        this.cbLog := hostGui.Add("Checkbox", "x" x " y" y0 " w300"
                                            . (DebugPanel.Get("Logging", "1") ? " Checked" : ""),
                                  "Write a log file")
        this.cbPop := hostGui.Add("Checkbox", "x" (x + 310) " y" y0 " w" (w - 310)
                                            . (DebugPanel.Get("Popups", "0") ? " Checked" : ""),
                                  "Report errors with a pop-up")
        y0 += 22
        this.cbMax := hostGui.Add("Checkbox", "x" x " y" y0 " w300"
                                            . (DebugPanel.Get("MaxLogging", "0") ? " Checked" : ""),
                                  "Max logging (log absolutely everything)")
        hostGui.SetFont("s8")
        this.lblForced := hostGui.Add("Text", "x" (x + 310) " y" (y0 + 2) " w" (w - 310)
                                            . " cGray", "")
        hostGui.SetFont("s9")
        y0 += 26

        this.cbLog.OnEvent("Click", (*) => this.SetFlag("Logging", this.cbLog.Value))
        this.cbPop.OnEvent("Click", (*) => this.SetFlag("Popups", this.cbPop.Value))
        this.cbMax.OnEvent("Click", (*) => this.SetFlag("MaxLogging", this.cbMax.Value))

        ; The environment beats the cfg, so if it is set these boxes cannot do
        ; anything. Say that and grey them, rather than letting somebody tick a
        ; box and wonder why the log did not change.
        if (forced != "") {
            for _, cb in [this.cbLog, this.cbPop, this.cbMax]
                cb.Enabled := false
            this.lblForced.Text := "MMA_DEBUG=" forced " in the environment is"
                                 . " overriding all three."
        }

        bx := x
        for _, b in [["Open mma.log",  "log"],
                     ["Mark log",      "mark"],
                     ["Diagnostic report", "report"],
                     ["Error log",     "errlog"],
                     ["Open folder",   "folder"],
                     ["Clear logs",    "clear"]] {
            btn := hostGui.Add("Button", "x" bx " y" y0 " w118 h28", b[1])
            btn.OnEvent("Click", this.DiagAction.Bind(this, b[2]))
            bx += 124
        }
        y0 += 36

        hostGui.Add("Text", "x" x " y" y0 " w" w " h1 0x10")
        y0 += 12

        ; ── probes ────────────────────────────────────────────────────────────
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Probes")
        hostGui.SetFont("s9 Norm")
        y0 += 22
        hostGui.SetFont("s8")
        hostGui.Add("Text", "x" x " y" y0 " w" w " cGray",
                    "Each is a SEPARATE script. Its hotkey only exists while it runs —"
                  . " look for the badge in the top-right corner. Ctrl+Alt+F10 samples,"
                  . " Ctrl+Alt+F12 quits.")
        hostGui.SetFont("s9")
        y0 += 30
        ; One row each, with what it does written beside it rather than hidden in a
        ; tooltip — and note GuiCtrl has no .ToolTip property in AHK v2.0 anyway,
        ; so assigning one throws the moment this tab is built.
        for _, p in DebugPanel.PROBES {
            btn := hostGui.Add("Button", "x" x " y" y0 " w150 h26", p.label)
            btn.OnEvent("Click", this.RunFile.Bind(this, p.file))
            hostGui.SetFont("s8")
            hostGui.Add("Text", "x" (x + 160) " y" (y0 + 6) " w" (w - 160) " cGray", p.note)
            hostGui.SetFont("s9")
            y0 += 30
        }
        y0 += 6

        hostGui.Add("Text", "x" x " y" y0 " w" w " h1 0x10")
        y0 += 12

        ; ── self-tests ────────────────────────────────────────────────────────
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Self-tests")
        hostGui.SetFont("s9 Norm")
        y0 += 22
        this.btnRun := hostGui.Add("Button", "x" x " y" y0 " w130 h28", "Run all tests")
        this.btnRun.OnEvent("Click", (*) => this.StartTests())
        this.lblTests := hostGui.Add("Text", "x" (x + 140) " y" (y0 + 7) " w" (w - 140),
                                     "Not run yet.")
        y0 += 34
        this.lv := hostGui.Add("ListView", "x" x " y" y0 " w" w " h96 Grid -Multi",
                               ["Test", "Result", "File"])
        this.lv.ModifyCol(1, 200)
        this.lv.ModifyCol(2, 150)
        this.lv.ModifyCol(3, w - 380)
        y0 += 106

        hostGui.Add("Text", "x" x " y" y0 " w" w " h1 0x10")
        y0 += 12

        ; ── environment ───────────────────────────────────────────────────────
        ; The "Logs and files" row that stood here is gone — its four buttons were
        ; the same job as the Diagnostics row at the top of this tab, and two rows
        ; of file buttons at opposite ends of one page is how you end up clicking
        ; the wrong one. mass_gui.cfg and hotkeys.ini are both reproduced in full
        ; inside the diagnostic report, which is the thing you actually send.
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Environment")
        hostGui.SetFont("s9 Norm")
        y0 += 22
        this.lblEnv := hostGui.Add("Text", "x" x " y" y0 " w" w " h60", "")
        y0 += 64
        btnRefresh := hostGui.Add("Button", "x" x " y" y0 " w110 h28", "Refresh")
        btnRefresh.OnEvent("Click", (*) => this.PaintEnv())
        btnEngine := hostGui.Add("Button", "x" (x + 118) " y" y0 " w130 h28", "Restart engine")
        btnEngine.OnEvent("Click", (*) => this.RestartEngine())
        btnCfg := hostGui.Add("Button", "x" (x + 256) " y" y0 " w130 h28", "mass_gui.cfg")
        btnCfg.OnEvent("Click", this.Reveal.Bind(this, MMA_CFG))
        btnHk := hostGui.Add("Button", "x" (x + 394) " y" y0 " w130 h28", "hotkeys.ini")
        btnHk.OnEvent("Click", this.Reveal.Bind(this, MMA_HK_INI))

        this.PaintEnv()
    }

    ; ── the three switches ────────────────────────────────────────────────────
    ; Read and written straight through, with no caching in this class. The panel
    ; is built fresh each time Settings opens, and the cfg is the authority the
    ; other seven processes read — holding a second copy here would only give it
    ; something to disagree with.

    static Get(key, dflt) {
        return Trim(IniRead(MMA_CFG, "Debug", key, dflt)) = "1"
    }

    ; "" when nothing is overriding. _LOG_Forced() returns "-" for that case,
    ; which is an implementation detail of log.ahk and not something to show.
    static Forced() {
        f := ""
        try f := _LOG_Forced()
        return (f = "-" || f = "") ? "" : f
    }

    ; Written on click rather than on Save — see this file's header.
    SetFlag(key, on) {
        try {
            IniWrite(on ? "1" : "0", MMA_CFG, "Debug", key)
            ; Logged at FAIL level deliberately when logging is being switched
            ; OFF: it is the last line the file will get, and a log that simply
            ; stops with no explanation is a small mystery of its own. LOGE writes
            ; regardless of the master switch, which is exactly what is needed for
            ; the one message that has to outlive it.
            if (key = "Logging" && !on)
                LOGE("debug.switch", "logging switched OFF from Settings ▸ Debug —"
                                   . " this is the last line until it is switched"
                                   . " back on")
            else
                LOGI("debug.switch", key " → " (on ? "on" : "off"))
        } catch as e {
            MsgBox("Could not write to mass_gui.cfg:`n`n" e.Message
                 . "`n`n" MMA_CFG, "Debug", 0x10)
            return
        }
        this.PaintEnv()
    }

    ; ── the diagnostics buttons ───────────────────────────────────────────────
    DiagAction(what, *) {
        switch what {
        case "log":
            this.Reveal(MMA_LOGFILE)
        case "errlog":
            this.Reveal(MMA_ERRLOG)
        case "folder":
            this.Reveal(MMA_DEBUGLOGS)
        case "mark":
            ; A findable line, so a user can bracket a reproduction: press this,
            ; do the thing that fails, press it again. Then only the lines between
            ; the two marks matter, which turns "send me your log" from a 20,000
            ; line file into a paragraph.
            note := ""
            ib := InputBox("Write a marker line into the log, so you can find this"
                         . " moment again.`n`nPress this before AND after doing the"
                         . " thing that fails — then only the lines between the two"
                         . " markers matter.", "Mark the log", "w440 h170",
                           "about to reproduce the problem")
            if (ib.Result != "OK")
                return
            note := Trim(ib.Value)
            LOG_Marker(note)
            this.PaintEnv()
        case "report":
            p := LOG_Report()
            if (p = "") {
                MsgBox("The report could not be written. See " MMA_ERRLOG,
                       "Diagnostic report", 0x10)
                return
            }
            if MsgBox("Wrote:`n`n" p "`n`nIt contains this machine's environment,"
                    . " mass_gui.cfg and hotkeys.ini in full, and the last 400 log"
                    . " lines. No message text and no masses.`n`nThis is the single"
                    . " file to send when something misbehaves.`n`nOpen it now?",
                      "Diagnostic report", 0x24) = "Yes"
                this.Reveal(p)
        case "clear":
            this.ClearLogs()
        }
    }

    ; ── actions ───────────────────────────────────────────────────────────────

    ; Launch a tools\ script. A_AhkPath, never a bare Run(path): a bare path goes
    ; through the .ahk file association, which on this machine is the v2 UX
    ; launcher but on another might be v1, or missing entirely — and then this
    ; button fails in a way that looks like the probe is broken rather than
    ; unlaunchable. MMA.ahk avoids the association for the same reason.
    RunFile(rel, *) {
        p := MMA_ROOT "\" rel
        if !FileExist(p) {
            MsgBox("Not found:`n`n" p, "Debug", 0x10)
            return
        }
        try
            Run('"' A_AhkPath '" "' p '"')
        catch as e
            MsgBox("Could not start it.`n`n" e.Message, "Debug", 0x10)
    }

    ; Open a file, or select it in Explorer if it is a folder.
    Reveal(path, *) {
        if InStr(FileExist(path), "D") {
            try Run('explorer.exe "' path '"')
            return
        }
        if !FileExist(path) {
            MsgBox("Nothing there yet:`n`n" path, "Debug", 0x40)
            return
        }
        ; Notepad rather than the association: these are .ini/.cfg/.txt and the
        ; association for .cfg in particular is anybody's guess.
        try Run('notepad.exe "' path '"')
        catch
            try Run('explorer.exe /select,"' path '"')
    }

    ClearLogs(*) {
        if MsgBox("Delete the log, the error log and the probe dumps in debuglogs\ ?"
                . "`n`nStarting from an empty log is the easiest way to reproduce"
                . " something cleanly. Settings and messages are untouched — they"
                . " live in userdata\.", "Clear debug logs", 0x24) != "Yes"
            return
        n := 0
        ; *.log as well as *.txt. The old sweep was .txt only, so mma.log — the
        ; one file that actually grows — would have survived a "clear logs" and
        ; left the user staring at yesterday's run.
        for _, pattern in ["\*.txt", "\*.log", "\*.log.1"] {
            Loop Files, MMA_DEBUGLOGS pattern {
                try {
                    FileDelete(A_LoopFilePath)
                    n++
                }
            }
        }
        ; Straight back in, so the file exists and the next thing that happens is
        ; already in it — and so the log itself records that it was cleared, which
        ; explains the gap to whoever reads it later.
        LOG_Marker("logs cleared from Settings ▸ Debug")
        MsgBox(n " file(s) deleted.", "Clear debug logs", 0x40)
        this.PaintEnv()
    }

    ; ── the self-test runner ──────────────────────────────────────────────────
    ; One test per timer tick rather than a loop of RunWait. RunWait blocks the
    ; whole thread, so a plain loop would freeze this window for as long as every
    ; test takes together and show all six results at the end — indistinguishable
    ; from a hang. A tick each lets the window repaint and fill the list in.
    StartTests() {
        if this.running
            return
        this.running := true
        this.lv.Delete()
        this.queue := DebugPanel.TESTS.Clone()
        this.passed := 0
        this.failed := 0
        this.btnRun.Enabled := false
        this.lblTests.SetFont("cBlack")
        this.lblTests.Text := "Running…"
        SetTimer(this.NextTest.Bind(this), -50)
    }

    NextTest() {
        if !this.queue.Length {
            this.running := false
            this.btnRun.Enabled := true
            ok := (this.failed = 0)
            this.lblTests.SetFont(ok ? "cGreen" : "cRed")
            this.lblTests.Text := ok
                ? this.passed " test file(s) green."
                : this.failed " of " (this.passed + this.failed) " test file(s) FAILED — double-click a row."
            return
        }
        t := this.queue.RemoveAt(1)
        r := DebugPanel.RunTest(MMA_ROOT "\" t.file)
        if (r.ok)
            this.passed++
        else
            this.failed++
        this.lv.Add(, t.label, r.verdict, t.file)
        this.lv.Modify(this.lv.GetCount(), "Vis")
        SetTimer(this.NextTest.Bind(this), -50)
    }

    ; Run one test file and read its verdict off stdout.
    ;
    ; Via cmd with redirection, because AutoHotkey64.exe is a GUI-subsystem binary:
    ; started directly it returns immediately and its /ErrorStdOut text arrives
    ; afterwards, on nobody's pipe. cmd holds the handle, so the file has the
    ; output by the time RunWait returns.
    static RunTest(path) {
        if !FileExist(path)
            return {ok: false, verdict: "file missing"}
        tmp := A_Temp "\mma_test_" A_TickCount ".txt"
        try {
            RunWait(A_ComSpec ' /c ""' A_AhkPath '" /ErrorStdOut "' path '" > "' tmp '" 2>&1"',
                    , "Hide")
        } catch as e {
            return {ok: false, verdict: "could not run"}
        }
        out := ""
        try out := FileRead(tmp, "UTF-8")
        try FileDelete(tmp)
        ; "31 passed, 0 failed" — the line every test file ends with.
        if RegExMatch(out, "(\d+) passed, (\d+) failed", &m)
            return {ok: (m[2] = "0"), verdict: m[1] " passed, " m[2] " failed"}
        if InStr(out, "ERROR")
            return {ok: false, verdict: "errored"}
        return {ok: false, verdict: "no verdict printed"}
    }

    ; ── environment ───────────────────────────────────────────────────────────

    PaintEnv(*) {
        up := []
        for _, s in [["engine", EngineRunning()], ["detector", DetectorRunning()],
                     ["pinger", PingerRunning()], ["stats", StatsOverlayRunning()],
                     ["automation", AutomationListenerRunning()]]
            up.Push(s[1] (s[2] ? " ●" : " ○"))

        logs := 0, bytes := 0
        for _, pattern in ["\*.txt", "\*.log"] {
            Loop Files, MMA_DEBUGLOGS pattern {
                logs++
                bytes += A_LoopFileSize
            }
        }

        ; The state of the log itself, in the words somebody would use to describe
        ; it. "off" here is the answer to "I did what you said and the file was
        ; empty", so it is worth showing even though the checkbox is six rows up.
        state := DebugPanel.Get("Logging", "1") ? "on" : "OFF"
        if DebugPanel.Get("MaxLogging", "0")
            state .= ", max"
        if DebugPanel.Get("Popups", "0")
            state .= ", pop-ups"
        if (DebugPanel.Forced() != "")
            state .= "   (forced by MMA_DEBUG)"

        logSize := "not written yet"
        try if FileExist(MMA_LOGFILE)
            logSize := Round(FileGetSize(MMA_LOGFILE) / 1024) " KB"

        ver := "?"
        try ver := Trim(FileRead(MMA_VERSION, "UTF-8"))
        this.lblEnv.Text := "MMA v" ver "   ·   AutoHotkey " A_AhkVersion
                          . "   ·   mode: " MODE_Current()
                          . "`n" MMA_ROOT
                          . "`nchildren:  " DebugPanel.Join(up, "    ")
                          . "`nlogging:   " state "   ·   mma.log " logSize
                          . "   ·   debuglogs: " logs " file(s), "
                          . Round(bytes / 1024) " KB"
    }

    RestartEngine(*) {
        if MsgBox("Restart the mass engine?`n`nEvery mass hotkey is dead for about a"
                . " second, so not mid-send.", "Debug", 0x24) != "Yes"
            return
        try {
            StopEngine()
            Sleep 200
            LaunchEngine()
        }
        SetTimer((*) => this.PaintEnv(), -800)
    }

    static Join(arr, sep) {
        out := ""
        for i, v in arr
            out .= (i > 1 ? sep : "") v
        return out
    }
}
