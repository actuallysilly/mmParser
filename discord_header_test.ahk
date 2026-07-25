#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "lib/OCR.ahk"

; ============================================================================
;  discord_header_test.ahk — tune the Discord header band.
; ----------------------------------------------------------------------------
;  The Ctrl+click import (sequences.ahk) reads the open channel's name out of
;  Discord's header to decide which model a mass belongs to. That read is a
;  rectangle, and its X depends on how wide YOUR channel sidebar is.
;
;  Open the Discord channel you import from, run this, and press Re-read. The
;  band is correct when "channel" shows the slug and "model" shows the first
;  segment. Nudge X/Y/W/H until it does, then Save — sequences.ahk picks the
;  values up from mass_gui.cfg [Discord] on its next run.
;
;  Reads the window directly (PrintWindow), so Discord does NOT have to be in
;  front while you do this.
; ============================================================================

CFG := A_ScriptDir "\mass_gui.cfg"

g := Gui("+AlwaysOnTop", "Discord header band")
g.SetFont("s10", "Segoe UI")

g.Add("Text", "x12 y14 w20", "X:")
edX := g.Add("Edit", "x34 y11 w60", IniRead(CFG, "Discord", "HeaderX", "340"))
g.Add("Text", "x104 y14 w20", "Y:")
edY := g.Add("Edit", "x126 y11 w60", IniRead(CFG, "Discord", "HeaderY", "14"))
g.Add("Text", "x196 y14 w24", "W:")
edW := g.Add("Edit", "x222 y11 w60", IniRead(CFG, "Discord", "HeaderW", "620"))
g.Add("Text", "x292 y14 w24", "H:")
edH := g.Add("Edit", "x318 y11 w60", IniRead(CFG, "Discord", "HeaderH", "50"))

g.Add("Button", "x12 y44 w100 h28", "Re-read").OnEvent("Click", Reread)
g.Add("Button", "x120 y44 w100 h28", "Save").OnEvent("Click", SaveBand)
g.Add("Button", "x228 y44 w150 h28", "Widen to whole top").OnEvent("Click", WidenBand)

g.SetFont("s9", "Consolas")
outEd := g.Add("Edit", "x12 y82 w366 h150 ReadOnly +Multi")
g.Show("w390 h244")
Reread()

Band() {
    return {x: Integer(Trim(edX.Value)), y: Integer(Trim(edY.Value)),
            w: Integer(Trim(edW.Value)), h: Integer(Trim(edH.Value))}
}

Reread(*) {
    b := Band()
    if !WinExist("ahk_exe Discord.exe") {
        outEd.Value := "Discord is not running."
        return
    }
    CoordMode "Pixel", "Client"          ; match sequences.ahk exactly
    raw := ""
    err := ""
    try {
        res := OCR.FromWindow("ahk_exe Discord.exe",
                              {x: b.x, y: b.y, w: b.w, h: b.h,
                               scale: 3, grayscale: 1, mode: 4})
        raw := Trim(RegExReplace(res.Text, "\s+", " "))
    } catch as e {
        err := e.Message
    }
    chan := ""
    if RegExMatch(raw, "([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)", &m)
        chan := StrLower(m[1])
    model := ""
    if (chan != "" && RegExMatch(chan, "^([A-Za-z][A-Za-z0-9]*)", &mm))
        model := mm[1]

    WinGetClientPos(, , &cw, &ch, "ahk_exe Discord.exe")
    outEd.Value := "client   " cw "x" ch "`r`n"
                 . "band     " b.x "," b.y "  " b.w "x" b.h "`r`n`r`n"
                 . (err != "" ? "OCR ERROR: " err "`r`n`r`n" : "")
                 . "raw      " (raw = "" ? "(nothing)" : raw) "`r`n`r`n"
                 . "channel  " (chan = ""  ? "(no slug found)" : chan) "`r`n"
                 . "model    " (model = "" ? "(none - MMA will ask on import)" : model)
}

; When the band reads nothing, the usual cause is X sitting past the header.
; This drops back to the full window width so you can see what IS up there;
; the slug it finds then tells you roughly where to put X.
WidenBand(*) {
    WinGetClientPos(, , &cw, , "ahk_exe Discord.exe")
    edX.Value := 0, edY.Value := 0, edW.Value := cw ? cw : 1300, edH.Value := 90
    Reread()
}

SaveBand(*) {
    b := Band()
    for k, v in Map("HeaderX", b.x, "HeaderY", b.y, "HeaderW", b.w, "HeaderH", b.h)
        IniWrite(v, CFG, "Discord", k)
    outEd.Value := "Saved to mass_gui.cfg [Discord].`r`n`r`n"
                 . "Restart sequences.ahk (or MMA) to use it."
}
