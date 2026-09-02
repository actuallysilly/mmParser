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
        ; First, because it is the only one that answers "what does MMA think it
        ; can see" without you having to know which of the other three to reach
        ; for — platform, tab, name, model and next follow-up, live, in one panel.
        {label: "Detection overlay", file: "tools\detection_overlay_debug.ahk",
         note:  "Live strip: platform, tab/row, OCR'd name vs expected, next_fu."
              . " ^!F11 for the detailed view."},
        {label: "Next follow-up",  file: "tools\nextfu_probe.ahk",
         note:  "OCRs the chat in front and shows which follow-up it would send."},
        {label: "Tab detector",    file: "tools\detector_probe.ahk",
         note:  "Reads the Infloww tab strip and suggests GreyColor / GapTol."},
        {label: "Model readout",   file: "tools\model_detect_test.ahk",
         note:  "Live colour readout under the cursor. ^!F5 reloads, ^!F12 quits."}]

    ; The self-tests: they print "N passed, M failed" to stdout and exit. No
    ; screen, no hotkeys, safe to run mid-shift — with one exception, noted.
    ;
    ; They live in tools\test\ now, apart from the probes above. The two sets are
    ; opposites — a probe binds a key and stays resident so you can look at your
    ; screen through it, a test asserts and exits — and the only thing that ever
    ; said which was which was the filename, which lied: model_detect_test.ahk is
    ; a probe, and it is listed as one directly above this comment.
    static TESTS := [
        ; First, because if the logger is broken every other diagnosis in this
        ; tab is being read off a file that cannot be trusted.
        {label: "logging",              file: "tools\test\log_test.ahk"},
        {label: "next follow-up logic", file: "tools\test\nextfu_test.ahk"},
        {label: "mass key binding",     file: "tools\test\mass_bind_test.ahk"},
        {label: "mass store",           file: "tools\test\store_test.ahk"},
        ; The `::branch` paste format, against the shipping parser. Added to this
        ; list when the tests moved: it was written, it is pure parsing with no
        ; screen and no config, and it covers the format every mass is written in
        ; — there was no reason for it to be the one you had to run by hand.
        {label: "branch parsing",       file: "tools\test\branch_parse_test.ahk"},
        {label: "json",                 file: "tools\test\json_test.ahk"},
        ; The activity recorder's format. Runs entirely in a temp folder — it
        ; never touches userdata\activity\ — and it is in this list because the
        ; failure it guards is silent by nature: a counter merged the wrong way
        ; makes the chart wrong, not broken, and nothing anywhere says so.
        {label: "activity record",      file: "tools\test\activity_test.ahk"},
        ; The branch builder's compiler, and its output round-tripped through the
        ; SHIPPING parser. Listed because the builder's only claim is "this
        ; pastes into MMA and works", and that claim is one parser change away
        ; from quietly stopping being true.
        {label: "branch tree",          file: "tools\test\branch_tree_test.ahk"},
        ; Writes the [hotstring] section of hotkeys.ini and puts it back — see the
        ; header there. Listed anyway: the property it guards (hotstring ids come
        ; LAST in HK_ORDER) is what stops the Actions menu firing the wrong action
        ; in a script that started before you bound one.
        {label: "hotstring keys",       file: "tools\test\hotstring_key_test.ahk"},
        ; The manager's WRITERS — the round trip from a message you typed, out to
        ; AHK source and back. Listed because that round trip is the only thing
        ; standing between an edit and a quietly different message: an escape that
        ; does not survive it truncates a block at the first quote in your own
        ; words, which still loads and still fires. Writes only to a sandbox file
        ; it creates and deletes in content\.
        {label: "hotstring editing",    file: "tools\test\hotstring_edit_test.ahk"},
        ; What a mass SENDS — the part order, the FuSingle join, the f3 fallback,
        ; what a branch contributes — plus where the chat simulator's composer
        ; writes. Listed because the engine and that window now read one set of
        ; rules (mass\shape.ahk), and the whole value of doing it that way is
        ; that the rules are pinned. Pure: builds records in memory, and puts
        ; back the two Settings keys it has to drive.
        {label: "mass shape",           file: "tools\test\mass_shape_test.ahk"},
        {label: "active model",         file: "tools\test\active_model_test.ahk"},
        ; The background-service registry. Pure — it reads SVC_META and the
        ; filesystem, and starts nothing. Listed because the bugs it guards were
        ; invisible in exactly the way this tab exists for: a service missing from
        ; one of the four hand-kept lists started five seconds late, or never
        ; stopped when you unticked it, and said nothing either way.
        {label: "service registry",     file: "tools\test\services_test.ahk"},
        ; The click wall's decisions — which rectangle, in which coordinate space,
        ; and whether the list moved while a click was held. Listed because every
        ; way this can be wrong is silent: a client region read as a screen one
        ; walls a plausible rectangle a few hundred pixels from the list, and a
        ; moved-list check that says SAME too easily opens a different fan's chat
        ; with a click you made a second earlier. Runs against a temp cfg, binds
        ; no keys, and never clicks anything.
        {label: "click wall",           file: "tools\test\click_wall_test.ahk"},
        ; The reply-timer arithmetic. Pure — no screen, no config, and the clock
        ; is an argument rather than A_Now, so midnight is testable at any hour.
        ; Listed because both ways of being wrong are quiet: too quiet and a fan
        ; waiting twelve minutes gets no box at all, too loud and the NEWEST row
        ; in the list wears the loudest colour, which trains you to ignore them.
        {label: "reply timers",         file: "tools\test\reply_tiers_test.ahk"},
        ; The two Settings front ends offer the same settings. Pure text - it
        ; reads the field table and settings_window.ahk as a file, builds no
        ; window and touches no config. Listed because the drift it catches is
        ; silent AND lands on the DEFAULT window: a setting added to the shared
        ; table without a control in the Win32 tab simply is not there for
        ; anyone who switched shells, and nothing anywhere says so.
        {label: "settings parity",      file: "tools\test\settings_parity_test.ahk"},
        ; Builds a real Settings window and closes it, so a window flashes.
        {label: "settings window",      file: "tools\test\settings_build_test.ahk"},
        ; Same — builds the Add alt-FU window. Also covers what that window
        ; WRITES, which is the half a control census cannot see.
        {label: "add alt-FU",           file: "tools\test\altfu_build_test.ahk"},
        ; Builds the hotkey editor and scrolls it, so a window flashes here too.
        ; Listed because what it guards is invisible to a control census and
        ; unmissable in use: that list is rebuilt on every edit, and it has to come
        ; back with your place still in it. Writes nothing — the edits it makes die
        ; with the window, and Save is never called.
        {label: "hotkey editor",        file: "tools\test\hotkeys_panel_test.ahk"},
        ; The shortcuts file, end to end. Listed because two of the three things
        ; it guards are invisible from inside a running MMA: whether the file it
        ; seeds can be read back by the WINDOWS ini parser (a different parser
        ; from the one that wrote it), and whether the COMMENTED-OUT examples
        ; still name real actions — which nothing reads until the day you
        ; uncomment one. Writes only to A_Temp.
        {label: "hotstring shortcuts",  file: "tools\test\shortcuts_test.ahk"}]

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

        ; ── four switches in two rows of three columns ────────────────────────
        ; THREE columns, not two, and no new row — measured, because this tab has
        ; no room for one. The page is 622px tall and the Environment buttons at
        ; the bottom already ended within 4px of it (the note on the probe-row
        ; pitch further down is about the same wall). A fourth switch on a row of
        ; its own plus a help line under it came to 52px and pushed those buttons
        ; 48px off the page — invisible in the source, obvious the moment you open
        ; the tab. tools\ has no fixture for this; it was measured by building the
        ; panel into an unshown Gui and comparing the lowest control's bottom
        ; against CY+CH. Do that again before adding a fifth.
        this.cbLog := hostGui.Add("Checkbox", "x" x " y" y0 " w300"
                                            . (DebugPanel.Get("Logging", "1") ? " Checked" : ""),
                                  "Write a log file")
        this.cbPop := hostGui.Add("Checkbox", "x" (x + 310) " y" y0 " w300"
                                            . (DebugPanel.Get("Popups", "0") ? " Checked" : ""),
                                  "Report errors with a pop-up")

        ; ── the Fansly rail readout ───────────────────────────────────────────
        ; The only one of the four that puts something ON SCREEN rather than into
        ; a file. It belongs here anyway, for the reason the other three do: it is
        ; a thing MMA shows you about itself, not a thing MMA does for you, so it
        ; is a debug switch and not a Feature (see this file's header).
        ;
        ; It also has to be reachable while the rail is misbehaving, which is
        ; exactly when you do not want to be hunting through Features — and being
        ; written on click means it is live in the engine within a second and a
        ; half, with no Save and no restart.
        ;
        ; What it shows and how to read it is on the badge itself, not here: green
        ; names the model, amber says the shared keys have no answer with the
        ; reason on the line under it. A legend in Settings for a thing that is
        ; already on screen explaining itself is a legend nobody reads.
        this.cbRail := hostGui.Add("Checkbox", "x" (x + 620) " y" y0 " w" (w - 620)
                                             . (DebugPanel.Get("FanslyRail", "0") ? " Checked" : ""),
                                   "Fansly rail readout")
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
        this.cbRail.OnEvent("Click", (*) => this.SetFlag("FanslyRail", this.cbRail.Value))

        ; The environment beats the cfg, so if it is set these boxes cannot do
        ; anything. Say that and grey them, rather than letting somebody tick a
        ; box and wonder why the log did not change.
        ;
        ; The rail readout is deliberately NOT in this list. MMA_DEBUG forces the
        ; three LOGGING levels and has no opinion about an overlay, so grey it and
        ; you have taken away a working switch to report an override that is not
        ; overriding it — which is the same "silently does nothing" failure this
        ; branch exists to prevent, pointed the other way.
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
            ; 28, not 30. This tab is placed absolutely inside a fixed 720px window
            ; and the Environment buttons at the bottom already sat 4px clear of it
            ; — a fourth probe row at the old pitch pushed them off the page, which
            ; is a layout bug that only shows up on the LAST row added.
            y0 += 28
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
        btnLnk := hostGui.Add("Button", "x" (x + 532) " y" y0 " w150 h28", "Desktop shortcut")
        btnLnk.OnEvent("Click", (*) => this.MakeShortcut())

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

    ; A desktop shortcut to MMA.
    ;
    ; It points at AutoHotkey64.exe with MMA.ahk as the argument, NOT at MMA.ahk
    ; itself. A bare .ahk shortcut goes through the file association, which on this
    ; machine is the v2 launcher and on another might be v1, or missing — and then
    ; the shortcut fails in a way that looks like MMA is broken rather than
    ; unlaunchable. Same reasoning as RunFile above and MMA.ahk's own header.
    ;
    ; Working directory is the repo root, because every path MMA resolves is
    ; relative to where MMA.ahk sits.
    MakeShortcut(*) {
        src := MMA_ROOT "\MMA.ahk"
        if !FileExist(src) {
            MsgBox("Cannot find MMA.ahk at:`n`n" src, "Desktop shortcut", 0x10)
            return
        }
        lnk := A_Desktop "\MMA.lnk"
        ico := MMA_ASSETS "\icon.ico"
        try {
            FileCreateShortcut(A_AhkPath, lnk, MMA_ROOT, '"' src '"',
                               "MMA — the mass tooling",
                               FileExist(ico) ? ico : A_AhkPath)
        } catch as e {
            LOGE("gui.debug", "could not write the desktop shortcut", LOG_Err(e))
            MsgBox("Could not write:`n`n" lnk "`n`n" e.Message,
                   "Desktop shortcut", 0x10)
            return
        }
        LOGI("gui.debug", "wrote a desktop shortcut at " lnk)
        MsgBox("Shortcut created:`n`n" lnk, "Desktop shortcut", 0x40)
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
        up.Push("engine" (EngineRunning() ? " ●" : " ○"))
        ; Every declared service, in registry order, rather than the four this
        ; picked out by hand — a readout whose whole job is answering "is it
        ; running?" should not have services it cannot see.
        for _svc in SVC_ORDER
            up.Push(_svc (SVC_Running(_svc) ? " ●" : " ○"))

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
