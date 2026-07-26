#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  modes_gui.ahk — the Easy/Advanced switch and the per-feature checkboxes.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own window rather than more rows in Settings: OpenSettings is already the
;  largest function in mass_gui.ahk, and this list grows every time a feature is
;  added. Everything shown is generated from the registry in modes.ahk, so a new
;  FEAT_Def line appears here automatically with no edit to this file.
;
;  In Easy mode the checkboxes are shown but disabled. They still display what
;  each feature is set to, so switching back to Advanced visibly restores your
;  choices instead of looking like a reset.
; ═══════════════════════════════════════════════════════════════════════════════

OpenModesWindow(*) {
    global g, FEAT_ORDER, FEAT_SECTIONS, FEAT_META

    mg := Gui("+Owner" g.Hwnd, "Mode & features")
    mg.SetFont("s9", "Segoe UI")

    mg.SetFont("s11 Bold")
    mg.Add("Text", "x14 y12 w420", "Mode")
    mg.SetFont("s9 Norm")

    isEasy := MODE_IsEasy()
    rbEasy := mg.Add("Radio", "x14 y40 w440" (isEasy ? " Checked" : ""),
                     "Easy — MMA as it was at v1.4.0. Nothing below runs.")
    rbAdv  := mg.Add("Radio", "x14 y62 w440" (isEasy ? "" : " Checked"),
                     "Advanced — everything, each switchable on its own.")

    mg.SetFont("s8")
    mg.Add("Text", "x32 y84 w430 cGray",
           "Easy does not just hide these — their hotkeys never register and their"
         . " background scripts never start.")
    mg.SetFont("s9")

    y := 112
    ctrls := Map()
    for _, section in FEAT_SECTIONS {
        mg.SetFont("s9 Bold")
        mg.Add("Text", "x14 y" y " w440", section)
        mg.SetFont("s9 Norm")
        y += 22
        for _, id in FEAT_ORDER {
            f := FEAT_META[id]
            if (f.section != section)
                continue
            cb := mg.Add("Checkbox", "x24 y" y " w430" (FEAT_Raw(id) ? " Checked" : ""), f.label)
            if isEasy
                cb.Enabled := false
            ctrls[id] := cb
            y += 21
        }
        y += 8
    }

    ; Toggling the mode greys the list immediately, so the relationship between
    ; the radio and the checkboxes is visible before saving.
    SyncEnabled(*) {
        for _, cb in ctrls
            cb.Enabled := !rbEasy.Value
    }
    rbEasy.OnEvent("Click", SyncEnabled)
    rbAdv.OnEvent("Click", SyncEnabled)

    y += 4
    btnSave := mg.Add("Button", "x14 y" y " w110 h28 Default", "Save")
    mg.Add("Button", "x134 y" y " w90 h28", "Cancel").OnEvent("Click", (*) => mg.Destroy())
    mg.SetFont("s8")
    mg.Add("Text", "x236 y" (y+7) " w230 cGray", "Scripts restart so the keys re-register.")
    mg.SetFont("s9")

    btnSave.OnEvent("Click", SaveModes)
    SaveModes(*) {
        MODE_Set(rbEasy.Value ? "easy" : "advanced")
        for id, cb in ctrls
            FEAT_SetRaw(id, cb.Value)
        mg.Destroy()
        ; A hotkey is registered at bind time, so a feature switched off keeps its
        ; key until its script reloads. Restarting is what makes the change real.
        RestartMassScripts()
        ApplyModeToRunning()
        MsgBox "Saved. Scripts were restarted so the hotkeys match.",
               "Mode & features", 0x40
    }

    try ArchiveDarkTheme(mg, [])
    mg.Show("AutoSize")
}

; Stop anything the current mode no longer allows, and start anything it now does.
; Called after a save so the running children match the checkboxes without needing
; a full restart of the panel.
ApplyModeToRunning() {
    if FEAT("automation")
        LaunchAutomationListener()
    else
        StopAutomationListener()

    if FEAT("pinger")
        LaunchPinger()
    else
        StopPinger()

    if FEAT("modelDetector")
        LaunchDetector()
    else
        StopDetector()

    if FEAT("statsOverlay")
        LaunchStatsOverlay()
    else
        StopStatsOverlay()

    ; The detector writes the active model name; with it stopped that file goes
    ; stale and ModelIsActive() would keep gating every model's keys off against a
    ; name nobody is updating. Clearing it disables gating, which is the correct
    ; "no detector" behaviour.
    if !FEAT("modelDetector")
        try IniWrite("", A_ScriptDir "\detector_status.ini", "detector", "active_model")

    try RefreshPingerLabel()
}
