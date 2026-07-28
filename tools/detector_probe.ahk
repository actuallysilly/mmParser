#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../src/core/paths.ahk"
#Include "../src/vendor/OCR.ahk"
#Include "../src/screen/pill_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  detector_probe.ahk — what the model detector is actually looking at.
; ───────────────────────────────────────────────────────────────────────────────
;  The detector reads two colours out of mass_gui.cfg [Detector] — GreyColor (the
;  ACTIVE tab's pill) and InactiveColor (the others) — and finds tabs by grouping
;  columns that hold either into runs. Both defaults were copied out of old notes
;  rather than measured, and when they are wrong the detector does not go quiet:
;  it groups the whole strip into ONE run and reports "tab 1 of 1" forever, so
;  every shared key sends model 1's messages whatever is on screen.
;
;  That is not a hypothesis. detector_status.ini said:
;      active_model=AW Bellarama      <- one run spanning two pills, OCR'd together
;      active_index=1  tab_count=1    <- ...so positional mode saw a single tab
;
;  This prints the numbers needed to fix that, from YOUR screen:
;    • the most common colours in the strip, so you can see what the pills
;      really are rather than what the cfg guesses,
;    • what the current settings find (runs, widths, gaps, which run wins),
;    • a suggested GreyColor / InactiveColor / GapTol.
;
;  USAGE: put Infloww Messages in front with the tab strip visible, then run this
;  and press Ctrl+Alt+F10; Ctrl+Alt+F12 quits. It never clicks or types; it only
;  reads pixels. Copy the suggested values into mass_gui.cfg [Detector] (or
;  Settings) and restart the detector.
;
;  Modified keys, never a bare F10 or Esc: this is run WHILE Infloww is focused,
;  and a bare hotkey is swallowed globally — Esc would stop closing Infloww's own
;  dialogs for as long as the probe was up, and the F-keys are spoken for.
; ═══════════════════════════════════════════════════════════════════════════════

CFG := MMA_CFG

RegionX  := IniInt("RegionX",  0)
RegionY  := IniInt("RegionY",  0)
RegionW  := IniInt("RegionW",  330)
RegionH  := IniInt("RegionH",  50)
GreyHex  := Trim(IniRead(CFG, "Detector", "GreyColor", "0x2B2C30"))
DarkHex  := Trim(IniRead(CFG, "Detector", "InactiveColor", "0x0D0D0D"))
GreyTol  := IniInt("GreyTol",  22)
ScanStep := IniInt("ScanStep", 4)
GapTol   := IniInt("GapTol",   12)

IniInt(key, default) {
    v := Trim(IniRead(MMA_CFG, "Detector", key, default))
    return IsInteger(v) ? Integer(v) : default
}

CoordMode "Pixel", "Screen"
OUT := MMA_PROBE_DETECT

Say(s := "") {
    global OUT
    try FileAppend(s "`n", OUT, "UTF-8")
}

Hex(c) => Format("0x{:06X}", c)

OcrRect(x1, x2) {
    global RegionY, RegionH
    w := x2 - x1
    if (w < 4)
        return "«too narrow»"
    try {
        res := OCR.FromRect(x1, RegionY, w, RegionH, {scale: 3, grayscale: 1})
        return Trim(RegExReplace(res.Text, "\s+", " "))
    } catch as e {
        return "«OCR failed: " e.Message "»"
    }
}

; This file's own ColorDist was deleted: pill_scan.ahk provides PILL_ColorDist,
; and two definitions of one name do not load in AHK. Sharing it is also the
; point — a probe that compares colours differently from the detector tells you
; about the probe.

; --now probes whatever is on screen immediately and exits, for scripted checks.
; The interactive path waits for a keypress because you have to put Infloww in
; front first, and launching this file from Explorer focuses Explorer.
global QUIET := false
for a in A_Args {
    if (a = "--now") {
        QUIET := true
        Probe()
        ExitApp(0)
    }
}

; A badge that STAYS, rather than a tooltip on a 4-second timer. This is a
; separate script, so Ctrl+Alt+F10 exists only while it is running — and once the
; tooltip faded there was nothing on screen to tell a probe that is up from one
; that was never started, which makes "the key did nothing" impossible to
; diagnose. NoActivate so focusing Infloww (which this probe REQUIRES) is not
; disturbed by it. Same treatment as nextfu_probe.ahk.
;
; badgeGui, not badge: a variable and a function differing only in case are one
; name to AHK, and the script fails to load rather than shadowing.
badgeGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")  ; WS_EX_NOACTIVATE
badgeGui.BackColor := "1E1E1E"
badgeGui.SetFont("s10 Bold cWhite", "Segoe UI")
badgeGui.Add("Text", "x12 y10 w300", "Detector probe — running")
badgeGui.SetFont("s9 Norm c9A9A9A")
lblBadge := badgeGui.Add("Text", "x12 y34 w300",
                         "Ctrl+Alt+F10   read the tab strip`n"
                       . "Ctrl+Alt+F12   quit")
badgeGui.Show("x" (A_ScreenWidth - 344) " y24 w324 h74 NoActivate")

Badge(s) {
    global lblBadge
    try lblBadge.Value := s
}

^!F10::Probe()
^!F12::ExitApp()

Probe() {
    global RegionX, RegionY, RegionW, RegionH, GreyHex, DarkHex, GreyTol, ScanStep, GapTol, OUT, QUIET
    ; Before the slow part, so the key never looks dead while it works.
    if !QUIET
        Badge("reading the tab strip…")

    try FileDelete(OUT)
    x2 := RegionX + RegionW, y2 := RegionY + RegionH
    Say("MMA detector probe — " FormatTime(, "yyyy-MM-dd HH:mm:ss"))
    Say("window: " (WinExist("A") ? WinGetTitle("A") : "?"))
    Say("region: x" RegionX " y" RegionY " w" RegionW " h" RegionH
      . "   step " ScanStep)
    Say("cfg:    GreyColor=" GreyHex "  InactiveColor=" DarkHex
      . "  GreyTol=" GreyTol "  GapTol=" GapTol)
    Say("")

    ; ── every pixel in the band, counted by colour ────────────────────────────
    ; The colours are the whole answer. A pill is a solid block, so the two most
    ; common non-background colours in a tab strip ARE the active and inactive
    ; pills — you do not have to guess them, you can read them off this list.
    ; One capture, then read from memory. Per-pixel PixelGetColor measured ~30ms
    ; a call here, so this loop alone used to take upwards of ten seconds — and a
    ; probe that slow reads a DIFFERENT screen at the start and the end of its own
    ; scan, which is why two consecutive runs disagreed about the palette.
    img := PILL_Grab(RegionX, RegionY, RegionW + 1, RegionH + 1)
    if !img {
        Say("SCREEN CAPTURE FAILED — cannot probe.")
        return
    }
    counts := Map()
    cols   := []
    x := RegionX
    while (x <= x2) {
        seen := Map()
        y := RegionY
        while (y <= y2) {
            c := PILL_Px(img, x, y)
            if (c >= 0) {
                counts[c] := counts.Has(c) ? counts[c] + 1 : 1
                seen[c]   := seen.Has(c) ? seen[c] + 1 : 1
            }
            y += ScanStep
        }
        cols.Push({x: x, seen: seen})
        x += ScanStep
    }

    ranked := []
    for c, n in counts
        ranked.Push({c: c, n: n})
    ; plain insertion sort: a dozen-ish distinct colours, and it keeps this file
    ; free of a sort helper nothing else here needs
    Loop ranked.Length {
        i := A_Index
        Loop ranked.Length - i {
            j := A_Index
            if (ranked[j].n < ranked[j + 1].n) {
                t := ranked[j], ranked[j] := ranked[j + 1], ranked[j + 1] := t
            }
        }
    }

    Say("most common colours in the strip (pixel count, and how many columns"
      . " they appear in):")
    Loop Min(10, ranked.Length) {
        c := ranked[A_Index].c
        wide := 0
        for col in cols
            if col.seen.Has(c)
                wide++
        Say(Format("  {:2}. {}  {:5} px   in {:3} of {} columns",
                   A_Index, Hex(c), ranked[A_Index].n, wide, cols.Length))
    }
    Say("")

    ; ── what the CURRENT settings see ─────────────────────────────────────────
    greyRGB := Integer(RegExMatch(GreyHex, "i)^0x") ? GreyHex : "0x" GreyHex)
    darkRGB := Integer(RegExMatch(DarkHex, "i)^0x") ? DarkHex : "0x" DarkHex)
    Report("CURRENT cfg", greyRGB, darkRGB, GreyTol, GapTol, cols)

    ; ── the ACTIVE pill on its own ────────────────────────────────────────────
    ; Passing the active colour as both means only active-coloured columns count,
    ; so this is the lit pill and nothing else. It is the measurement that matters
    ; most: many UIs draw inactive tabs in the page background, which makes them
    ; invisible to any colour scan, and then the ONLY thing findable is this. Its
    ; width is also the tab pitch, which is how the index can be worked out
    ; without ever seeing the other tabs.
    Report("ACTIVE ONLY (tol " GreyTol ")", greyRGB, greyRGB, GreyTol, GapTol, cols)
    Report("ACTIVE ONLY (tol 6)",           greyRGB, greyRGB, 6, GapTol, cols)

    ; ── what the measured colours would see ───────────────────────────────────
    ; A tab strip is mostly background, so the single most common colour is the
    ; strip behind the pills. The two after it are the pills — whichever covers
    ; FEWER columns is the active one, because there is only ever one of those
    ; and several of the other.
    if (ranked.Length >= 3) {
        a := ranked[2].c, b := ranked[3].c
        wa := 0, wb := 0
        for col in cols {
            if col.seen.Has(a)
                wa++
            if col.seen.Has(b)
                wb++
        }
        act := (wa <= wb) ? a : b
        ina := (wa <= wb) ? b : a
        Say("")
        Say("MEASURED guess: GreyColor=" Hex(act) "  InactiveColor=" Hex(ina))
        Say("  (background looks like " Hex(ranked[1].c) " — the most common colour)")
        Report("MEASURED guess", act, ina, 10, GapTol, cols)
    }

    Say("")
    Say("If tabs found = the number of tabs on screen and 'active run' is the lit")
    Say("one, those settings work. Put them in mass_gui.cfg [Detector] and restart")
    Say("the detector. If neither block gets it right, the region is probably")
    Say("wrong — RegionX/Y/W/H must cover the tab strip and nothing else.")

    if !QUIET {
        Badge("read at " FormatTime(, "HH:mm:ss") " — see the Notepad window`n"
            . "Ctrl+Alt+F10 again     Ctrl+Alt+F12 quit")
        Run('notepad.exe "' OUT '"')
    }
}

; Group columns into runs the way ScanPills does, and show the working.
Report(label, activeRGB, inactiveRGB, tol, gap, cols) {
    Say("")
    Say("── " label ": active=" Hex(activeRGB) " inactive=" Hex(inactiveRGB)
      . " tol=" tol " gap=" gap " ──")

    hits := []
    for col in cols {
        act := 0, any := 0
        for c, n in col.seen {
            if (PILL_ColorDist(c, activeRGB) <= tol)
                act += n, any += n
            else if (PILL_ColorDist(c, inactiveRGB) <= tol)
                any += n
        }
        if (any)
            hits.Push({x: col.x, act: act})
    }
    if !hits.Length {
        Say("  no pill-coloured columns at all — wrong colours, or wrong region.")
        return
    }

    runs := []
    run  := {act: 0, minX: hits[1].x, maxX: hits[1].x}
    prev := hits[1].x
    for h in hits {
        if (h.x - prev > gap) {
            runs.Push(run)
            run := {act: 0, minX: h.x, maxX: h.x}
        }
        run.act += h.act
        run.maxX := h.x
        prev := h.x
    }
    runs.Push(run)

    best := 0
    for i, r in runs
        if (!best || r.act > runs[best].act)
            best := i

    Say("  tabs found: " runs.Length "   active run: " (runs[best].act ? best : "none"))
    for i, r in runs
        Say(Format("    tab {:2}  x {:4}..{:4}  width {:3}  active px {:5}{}",
                   i, r.minX, r.maxX, r.maxX - r.minX, r.act,
                   (i = best && r.act) ? "   <- lit" : ""))

    ; The point of the whole exercise: the lit run is the rectangle the detector
    ; hands to OCR, so read it back. A settings block that finds one tidy run but
    ; OCRs two names has not worked — that is precisely how "AW Bellarama" got
    ; written to detector_status.ini and then matched two model slots at once.
    if (best && runs[best].act)
        Say("    OCR of the lit run: <" OcrRect(runs[best].minX, runs[best].maxX) ">")
    if (runs.Length = 1)
        Say("  ONE run for the whole strip. That is the failure that reports"
          . " 'tab 1 of 1'`n  forever: the colours match too much (try a smaller"
          . " tol) or GapTol is`n  wider than the space between your tabs.")
}
