#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  features_panel.ahk — the Easy/Advanced switch and every feature's on/off box.
; ───────────────────────────────────────────────────────────────────────────────
;  Was its own window ("Mode & features"), reached by a button inside Settings.
;  Two windows, both writing mass_gui.cfg, and six cfg keys that BOTH of them
;  offered a checkbox for — MouseControl, FastParseAutosave, AutomationListener,
;  Pinger, AutoDetectModel, StatsOverlay. Whichever you saved last won, so turning
;  the pinger on in one window and pressing Save in the other turned it back off.
;
;  Now it is the Features tab, and it is the SINGLE owner of every key in the
;  registry. The other tabs hold the detail settings for those features and show
;  their state read-only — no key is written from two places.
;
;  Everything shown is generated from the registry in modes.ahk, so a new FEAT_Def
;  line appears here with no edit to this file.
;
;  In Easy mode the checkboxes are shown but disabled. They still display what each
;  feature is set to, so switching back to Advanced visibly restores your choices
;  instead of looking like a reset.
; ═══════════════════════════════════════════════════════════════════════════════

class FeaturesPanel {
    static ROW_H  := 21
    static HEAD_H := 22
    static GAP    := 10

    __New(hostGui, x, y, w) {
        this.ctrls := Map()
        this.gui   := hostGui
        isEasy     := MODE_IsEasy()

        hostGui.SetFont("s9 Bold")
        hostGui.Add("Text", "x" x " y" y " w" w, "Mode")
        hostGui.SetFont("s9 Norm")

        this.rbEasy := hostGui.Add("Radio", "x" x " y" (y + 24) " w" (w - 8)
                                          . (isEasy ? " Checked" : ""),
                                   "Easy — MMA as it was at v1.4.0. Nothing below runs.")
        this.rbAdv  := hostGui.Add("Radio", "x" x " y" (y + 46) " w" (w - 8)
                                          . (isEasy ? "" : " Checked"),
                                   "Advanced — everything, each switchable on its own.")
        hostGui.SetFont("s8")
        hostGui.Add("Text", "x" (x + 18) " y" (y + 68) " w" (w - 26) " cGray",
                    "Easy does not just hide these — their hotkeys never register and"
                  . " their background scripts never start.")
        hostGui.SetFont("s9")

        ; ── the feature list, flowed into two balanced columns ────────────────
        ; Which section lands in which column is worked out from the row counts
        ; rather than written down, so adding a FEAT_Def cannot leave one column
        ; twice the height of the other.
        top   := y + 96
        colW  := (w - FeaturesPanel.GAP * 2) // 2
        colX  := [x, x + colW + FeaturesPanel.GAP * 2]
        colY  := [top, top]

        for _, section in FEAT_SECTIONS {
            ids := []
            for _, id in FEAT_ORDER
                if (FEAT_META[id].section = section)
                    ids.Push(id)
            if !ids.Length
                continue
            ; the shorter column takes the next section
            c := (colY[1] <= colY[2]) ? 1 : 2
            cy := colY[c]

            hostGui.SetFont("s9 Bold")
            hostGui.Add("Text", "x" colX[c] " y" cy " w" colW, section)
            hostGui.SetFont("s9 Norm")
            cy += FeaturesPanel.HEAD_H

            for _, id in ids {
                f  := FEAT_META[id]
                cb := hostGui.Add("Checkbox", "x" (colX[c] + 10) " y" cy " w" (colW - 10)
                                            . (FEAT_Raw(id) ? " Checked" : ""), f.label)
                if isEasy
                    cb.Enabled := false
                this.ctrls[id] := cb
                cy += FeaturesPanel.ROW_H
            }
            colY[c] := cy + FeaturesPanel.GAP
        }
        this.bottom := Max(colY[1], colY[2])

        ; Toggling the mode greys the list immediately, so the relationship between
        ; the radio and the checkboxes is visible before saving.
        this.rbEasy.OnEvent("Click", (*) => this.SyncEnabled())
        this.rbAdv.OnEvent("Click",  (*) => this.SyncEnabled())
    }

    SyncEnabled() {
        for _, cb in this.ctrls
            cb.Enabled := !this.rbEasy.Value
    }

    ; True when the mode or any checkbox differs from what is on disk. The host
    ; window uses this to decide whether a save has to restart the scripts —
    ; a hotkey is registered at BIND time, so a feature switched off keeps its key
    ; until its script reloads, and restarting is what makes the change real. Doing
    ; that on every Settings save regardless would restart the mass engine because
    ; you changed the wait time.
    Changed() {
        if ((this.rbEasy.Value ? "easy" : "advanced") != MODE_Current())
            return true
        for id, cb in this.ctrls
            if ((cb.Value ? 1 : 0) != (FEAT_Raw(id) ? 1 : 0))
                return true
        return false
    }

    ; Write the mode and every checkbox. Does NOT restart anything — the caller
    ; decides that, because it knows what else it just saved.
    Apply() {
        MODE_Set(this.rbEasy.Value ? "easy" : "advanced")
        for id, cb in this.ctrls
            FEAT_SetRaw(id, cb.Value)
    }
}

; Stop anything the current mode no longer allows, and start anything it now does.
; Called after a save so the running children match the checkboxes without needing
; a full restart of the panel.
ApplyModeToRunning() {
    global SCRIPT_DIR, modelCount

    ; The mass engine first, because it carries the hotkeys and the whole point of
    ; a mode change is which keys exist. Close it if it is up, then start it from
    ; scratch: a script that was NOT running (as after Easy) still has to be
    ; started, which is exactly what the old path missed.
    ;
    ; One engine now, not a loop over three model scripts — and those files no
    ; longer exist, so the loop had quietly become a no-op that left the old keys
    ; bound after switching modes.
    p := MMA_SRC "\mass\engine.ahk"
    if FileExist(p) {
        if WinExist(p " ahk_class AutoHotkey") {
            try ProcessClose(WinGetPID(p " ahk_class AutoHotkey"))
            Sleep 150
        }
        try Run(p)
    }

    ; Whatever else the user has configured to auto-start (general.ahk, acc
    ; scripts, sequences). Respects the startupScripts feature on its own, so Easy
    ; leaves them stopped and Advanced brings them back.
    LaunchStartupScripts()

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

    if FEAT("fanslyDetector")
        LaunchFanslyDetector()
    else
        StopFanslyDetector()

    if FEAT("statsOverlay")
        LaunchStatsOverlay()
    else
        StopStatsOverlay()

    if FEAT("typelog")
        LaunchTypelog()
    else
        StopTypelog()

    if FEAT("replyBox")
        LaunchReplyBox()
    else
        StopReplyBox()

    ; The detector writes the active model name; with it stopped that file goes
    ; stale and ModelIsActive() would keep gating every model's keys off against a
    ; name nobody is updating. Clearing it disables gating, which is the correct
    ; "no detector" behaviour.
    if !FEAT("modelDetector")
        try IniWrite("", MMA_DETECTOR, "detector", "active_model")

    try RefreshToolsLabel()
}
