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
;  USAGE: open a chat that already has a follow-up in it, then press F10.
;  Output goes to userdata\nextfu_probe.txt and opens in Notepad.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/runtime.ahk"

OUT := MMA_USERDATA "\nextfu_probe.txt"

Say(s := "") {
    global OUT
    try FileAppend(s "`n", OUT, "UTF-8")
}

ToolTip("Next-follow-up probe.`nOpen a chat, then press F10.`nEsc quits.")
SetTimer(() => ToolTip(), -4000)

F10::Probe()
Esc::ExitApp()

Probe() {
    global OUT
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
    if r.group {
        Say("last sent  : f" r.group)
        Say("would send : " (r.group >= 3 ? "NOTHING (f3 is the last one)" : "f" (r.group + 1)))
    } else {
        Say("last sent  : none found")
        Say("would send : f1")
    }
    Say("")
    Say("If 'what it read' is not this conversation, fix [NextFu] Region* in")
    Say("mass_gui.cfg. If it IS the conversation but a follow-up you can see was")
    Say("'not found', OCR mangled it — paste the line above next to the mass text")
    Say("and compare; NeedleLen may need lowering.")

    Run('notepad.exe "' OUT '"')
}
