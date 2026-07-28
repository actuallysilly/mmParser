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
        y0 += 32
        ; One row each, with what it does written beside it rather than hidden in a
        ; tooltip — and note GuiCtrl has no .ToolTip property in AHK v2.0 anyway,
        ; so assigning one throws the moment this tab is built.
        for _, p in DebugPanel.PROBES {
            btn := hostGui.Add("Button", "x" x " y" y0 " w150 h26", p.label)
            btn.OnEvent("Click", this.RunFile.Bind(this, p.file))
            hostGui.SetFont("s8")
            hostGui.Add("Text", "x" (x + 160) " y" (y0 + 6) " w" (w - 160) " cGray", p.note)
            hostGui.SetFont("s9")
            y0 += 32
        }
        y0 += 8

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
        y0 += 36
        this.lv := hostGui.Add("ListView", "x" x " y" y0 " w" w " h138 Grid -Multi",
                               ["Test", "Result", "File"])
        this.lv.ModifyCol(1, 200)
        this.lv.ModifyCol(2, 150)
        this.lv.ModifyCol(3, w - 380)
        y0 += 148

        hostGui.Add("Text", "x" x " y" y0 " w" w " h1 0x10")
        y0 += 12

        ; ── logs and files ────────────────────────────────────────────────────
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Logs and files")
        hostGui.SetFont("s9 Norm")
        y0 += 22
        opens := [["Open debuglogs", MMA_DEBUGLOGS],
                  ["Error log",      MMA_ERRLOG],
                  ["mass_gui.cfg",   MMA_CFG],
                  ["hotkeys.ini",    MMA_HK_INI]]
        bx := x
        for _, o in opens {
            btn := hostGui.Add("Button", "x" bx " y" y0 " w110 h28", o[1])
            btn.OnEvent("Click", this.Reveal.Bind(this, o[2]))
            bx += 118
        }
        btnClear := hostGui.Add("Button", "x" bx " y" y0 " w110 h28", "Clear logs")
        btnClear.OnEvent("Click", (*) => this.ClearLogs())
        y0 += 38

        hostGui.Add("Text", "x" x " y" y0 " w" w " h1 0x10")
        y0 += 12

        ; ── environment ───────────────────────────────────────────────────────
        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y0 " w" w, "Environment")
        hostGui.SetFont("s9 Norm")
        y0 += 22
        this.lblEnv := hostGui.Add("Text", "x" x " y" y0 " w" w " h72", "")
        y0 += 78
        btnRefresh := hostGui.Add("Button", "x" x " y" y0 " w110 h28", "Refresh")
        btnRefresh.OnEvent("Click", (*) => this.PaintEnv())
        btnEngine := hostGui.Add("Button", "x" (x + 118) " y" y0 " w130 h28", "Restart engine")
        btnEngine.OnEvent("Click", (*) => this.RestartEngine())

        this.PaintEnv()
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
        if MsgBox("Delete every .txt in debuglogs\ ?`n`nThe crash log and the probe"
                . " dumps go with it. Settings and messages are untouched — they"
                . " live in userdata\.", "Clear debug logs", 0x24) != "Yes"
            return
        n := 0
        Loop Files, MMA_DEBUGLOGS "\*.txt" {
            try {
                FileDelete(A_LoopFilePath)
                n++
            }
        }
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
        Loop Files, MMA_DEBUGLOGS "\*.txt" {
            logs++
            bytes += A_LoopFileSize
        }

        ver := "?"
        try ver := Trim(FileRead(MMA_VERSION, "UTF-8"))
        this.lblEnv.Text := "MMA v" ver "   ·   AutoHotkey " A_AhkVersion
                          . "   ·   mode: " MODE_Current()
                          . "`n" MMA_ROOT
                          . "`nchildren:  " DebugPanel.Join(up, "    ")
                          . "`ndebuglogs: " logs " file(s), " Round(bytes / 1024) " KB"
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
