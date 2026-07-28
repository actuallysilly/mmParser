#Requires AutoHotkey v2.0
#SingleInstance Force
; ═══════════════════════════════════════════════════════════════════════════════
;  nextfu_probe.ahk — what the one-key follow-up walker reads, and how long it
;  takes to read it.
; ───────────────────────────────────────────────────────────────────────────────
;  The walker OCRs the conversation pane and looks for the model's own follow-up
;  text. Two things can go wrong and neither announces itself:
;
;    the REGION is wrong  — it reads the chat list, or the composer, or nothing
;    the OCR is too slow  — it runs on a keypress, so a two-second read is two
;                           seconds of a dead keyboard mid-conversation
;
;  This shows both, plus which group it would pick and why. Nothing is sent.
;
;  USAGE: open a chat that already has a follow-up in it, then press Ctrl+Alt+F10.
;  Ctrl+Alt+F12 quits. Output goes to debuglogs\nextfu_probe.txt, and opens in
;  Notepad.
;
;  Modified keys, never a bare F10 or Esc. This probe is MEANT to be run while you
;  are working in Infloww, and a bare hotkey is swallowed globally — binding Esc
;  would mean Esc stopped closing Infloww's own dialogs for as long as the probe
;  was up, and the F-keys are spoken for. A probe must not cost you a key.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/runtime.ahk"

OUT := MMA_PROBE_NEXTFU

Say(s := "") {
    global OUT
    try FileAppend(s "`n", OUT, "UTF-8")
}

; ── the "I am running" badge ──────────────────────────────────────────────────
;  This used to be a ToolTip on a 4-second timer, and that is a bad way to say
;  "a hotkey now exists". The probe is a SEPARATE SCRIPT: Ctrl+Alt+F10 does
;  nothing at all unless this file is running. Four seconds later the tooltip is
;  gone, you have switched to a chat, and the screen looks identical whether the
;  probe is up or was never started — so a key that does nothing is impossible to
;  tell from a key that is not bound. That is a real support question already.
;
;  A small window instead: it stays, it says which keys, and it doubles as the
;  result readout. NoActivate so it never takes focus from the chat you are about
;  to sample, AlwaysOnTop so Infloww cannot bury it, and -Caption +ToolWindow so
;  it stays out of the taskbar and the alt-tab order.
;
;  It also keeps the script alive on its own — a visible Gui counts, where an
;  OnMessage handler or a hidden Gui would not.
;  badgeGui, not badge: a variable and a function whose names differ only by case
;  are THE SAME NAME to AHK, and the script then fails to load outright rather
;  than shadowing one with the other. Badge() below is the function.
badgeGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")  ; WS_EX_NOACTIVATE
badgeGui.BackColor := "1E1E1E"
badgeGui.SetFont("s10 Bold cWhite", "Segoe UI")
badgeGui.Add("Text", "x12 y10 w300", "Next-follow-up probe — running")
badgeGui.SetFont("s9 Norm c9A9A9A")
lblBadge := badgeGui.Add("Text", "x12 y34 w300",
                         "Ctrl+Alt+F10   sample the chat in front`n"
                       . "Ctrl+Alt+F12   quit")
badgeGui.Show("x" (A_ScreenWidth - 344) " y24 w324 h74 NoActivate")

Badge(s) {
    global lblBadge
    try lblBadge.Value := s
}

^!F10::Probe()
^!F12::ExitApp()

Probe() {
    global OUT
    ; Say so on screen BEFORE the slow part. The OCR plus opening Notepad is a
    ; second or two, and without this the key looks dead for exactly as long as it
    ; takes to wonder whether it worked.
    Badge("sampling the window in front…")
    try FileDelete(OUT)
    cfg := NFU_Cfg()

    Say("MMA next-follow-up probe — " FormatTime(, "yyyy-MM-dd HH:mm:ss"))
    Say("window: " (WinExist("A") ? WinGetTitle("A") : "?"))
    Say("region: x" cfg.x " y" cfg.y " w" cfg.w " h" cfg.h "   scale " cfg.scale)
    Say("needle: " cfg.needleLen " chars, minimum " cfg.minNeedle)
    Say("")

    ; ── which model, and therefore which follow-ups to look for ───────────────
    n := ActiveModelNo()
    if !n {
        Say("No active model — the shared keys would do nothing here, so the")
        Say("walker would not run either. Fix that first (Settings ▸ Detector).")
        Say("Falling back to model 1 for this probe.")
        n := 1
    }
    _SetCurModel(n)
    Say("active model: " ModelLabel(n))
    m := CurMass()
    Loop 3 {
        g := A_Index
        parts := []
        for f in ["fu" g, "fu" g "_5", "fu" g "_7"]
            if (Trim(m.%f%) != "")
                parts.Push(SubStr(Trim(m.%f%), 1, 60))
        Say("  f" g ": " (parts.Length ? parts.Length " part(s)  «" parts[1] "…»" : "(empty)"))
    }
    Say("")

    ; ── the read, timed ───────────────────────────────────────────────────────
    t := A_TickCount
    text := NFU_ReadChat(cfg)
    ms := A_TickCount - t
    Say("OCR took " ms " ms" (ms > 1200 ? "   <- SLOW. This runs on a keypress;"
                                        . " shrink the region or drop Scale." : ""))
    if (text = "") {
        Say("OCR returned NOTHING. The region is almost certainly wrong.")
        Badge("read NOTHING — the region is almost certainly wrong.`n"
            . "Ctrl+Alt+F10 retry     Ctrl+Alt+F12 quit")
        Run('notepad.exe "' OUT '"')
        return
    }

    hay := NFU_Norm(text)
    Say("read " StrLen(text) " chars (" StrLen(hay) " after normalising)")
    Say("")
    Say("─── what it read ───────────────────────────────────────────────────")
    Say(text)
    Say("─── end ───────────────────────────────────────────────────────────")
    Say("")

    ; ── the decision, with the working shown ──────────────────────────────────
    r := NFU_LastGroup(m, hay, cfg)
    Loop 3 {
        g := A_Index
        Say("f" g ": " (r.hits[g] ? "found at position " r.hits[g] : "not found"))
    }
    Say("")
    ; Ask the SAME functions the key asks, in the same order, so this can never
    ; report a decision the key would not make.
    next := NFU_NextWithContent(m, r.group)
    if !r.group {
        seen := NFU_MassPresence(m, hay, cfg)
        Say("mass on screen : " seen)
        if (seen != "seen") {
            Say("last sent  : none found")
            Say("would send : NOTHING — f1 is gated on the mass being visible")
            Say((seen = "absent")
                ? "  The mass is not in what was read. Either the pane is scrolled"
                . "`n  away from a thread already underway, or this chat never got"
                . "`n  the mass. f1 is wrong in both, so it waits for you."
                : "  No mass text is stored for this model, so there is nothing to"
                . "`n  check against.")
            Badge("no follow-up AND no mass visible  →  would send NOTHING`n"
                . "Ctrl+Alt+F10 again     Ctrl+Alt+F12 quit")
            Run('notepad.exe "' OUT '"')
            return
        }
    }
    if !next {
        Say("last sent  : " (r.group ? "f" r.group : "none found"))
        Say("would send : NOTHING — " (r.group
            ? "f" r.group " is the last follow-up this mass has"
            : "this mass has no follow-ups at all"))
        Badge("would send NOTHING — nothing left to walk`n"
            . "Ctrl+Alt+F10 again     Ctrl+Alt+F12 quit")
    } else {
        gap := (next > r.group + 1) ? "   (no f" (r.group + 1) " in this mass)" : ""
        Say("last sent  : " (r.group ? "f" r.group : "none found, and the mass IS visible"))
        Say("would send : f" next gap)
        Badge((r.group ? "last sent f" r.group : "mass visible, no follow-up yet")
            . "  →  would send f" next gap "`n"
            . "Ctrl+Alt+F10 again     Ctrl+Alt+F12 quit")
    }
    Say("")
    Say("If 'what it read' is not this conversation, fix [NextFu] Region* in")
    Say("mass_gui.cfg. If it IS the conversation but a follow-up you can see was")
    Say("'not found', OCR mangled it — paste the line above next to the mass text")
    Say("and compare; NeedleLen may need lowering.")

    Run('notepad.exe "' OUT '"')
}
