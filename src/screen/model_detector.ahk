#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../vendor/OCR.ahk"
#Include "pill_scan.ahk"

; ============================================================================
;  model_detector.ahk — active-model detector (hybrid CV + OCR)
; ----------------------------------------------------------------------------
;  Writes the on-screen active model tab's NAME to detector_status.ini, which
;  utils.ahk's ReadActiveModel()/ModelIsActive()/FuGate() read so a single set
;  of f1/f2/f3 hotkeys can serve whichever model tab is focused: each mass
;  script only fires while ITS model is the active one.
;
;  Hybrid: every poll a fast pixel scan finds the ACTIVE (grey) pill and its
;  horizontal span. OCR — the expensive part — runs ONLY when that pill moves
;  (a tab switch), then its name is cached. No active pill on screen (Infloww
;  not visible) clears the status, which disables gating so every model
;  responds again (safe fallback).
;
;  All tunables live in mass_gui.cfg [Detector]; edit there, no code changes.
;  Started/stopped by the "Auto-detect active model" toggle in mass_gui
;  Settings (or run directly while tuning). No hotkeys, no window.
; ============================================================================

CFG    := MMA_CFG
STATUS := MMA_DETECTOR

RegionX  := Integer(IniRead(CFG, "Detector", "RegionX",  "0"))
RegionY  := Integer(IniRead(CFG, "Detector", "RegionY",  "0"))
RegionW  := Integer(IniRead(CFG, "Detector", "RegionW",  "330"))
RegionH  := Integer(IniRead(CFG, "Detector", "RegionH",  "50"))
GreyHex  := Trim(IniRead(CFG, "Detector", "GreyColor", "0x2B2C30"))
GreyTol  := Integer(IniRead(CFG, "Detector", "GreyTol",  "22"))
MinGrey  := Integer(IniRead(CFG, "Detector", "MinGrey",  "6"))
ScanStep := Integer(IniRead(CFG, "Detector", "ScanStep", "4"))
PollMs   := Integer(IniRead(CFG, "Detector", "PollMs",   "500"))
OcrScale := Integer(IniRead(CFG, "Detector", "OcrScale", "3"))
MoveTol  := Integer(IniRead(CFG, "Detector", "MoveTol",  "20"))
; Widest gap in px that still counts as INSIDE one pill. A pill is a solid block
; of colour so its columns are contiguous; anything wider than this is the space
; between two tabs, and grouping across it is what produced "AW Bellarama".
GapTol   := Integer(IniRead(CFG, "Detector", "GapTol",   "12"))
; The INACTIVE pill colour. Needed only to count tabs, which is what positional
; mode reads instead of a name: a grey-only scan sees the lit tab but has no way
; to know whether it is the first of three or the third.
DarkHex  := Trim(IniRead(CFG, "Detector", "InactiveColor", "0x0D0D0D"))
DarkRGB  := Integer(RegExMatch(DarkHex, "i)^0x") ? DarkHex : "0x" DarkHex)
; Foreground gate. This MUST default to the Infloww window, not to "" — the scan
; below looks at a fixed screen rectangle, not at a window, so with no gate it
; happily OCRs whatever else is sitting at those coordinates. That is not
; hypothetical: with WinMatch empty it read VS Code's menu bar and wrote
; "File Edit Selection View Go R" as the active model, which then got auto-claimed
; into an [ActiveMap] slot and permanently gated that model's keys off.
; Same window as automation.py's TARGET_TITLE and the "chrome" hotkey context.
; Blank it deliberately only if you want no gate at all.
WinMatch := Trim(IniRead(CFG, "Detector", "WinMatch",  "Infloww Messages"))
GreyRGB  := Integer(RegExMatch(GreyHex, "i)^0x") ? GreyHex : "0x" GreyHex)

; Seed the [Detector] section on first run so the values are visible/editable.
if (IniRead(CFG, "Detector", "RegionW", "") = "") {
    for k, v in Map("RegionX",RegionX, "RegionY",RegionY, "RegionW",RegionW, "RegionH",RegionH,
                    "GreyColor",GreyHex, "GreyTol",GreyTol, "MinGrey",MinGrey, "ScanStep",ScanStep,
                    "PollMs",PollMs, "OcrScale",OcrScale, "MoveTol",MoveTol, "GapTol",GapTol,
                    "InactiveColor",DarkHex,
                    "WinMatch",WinMatch)
        try IniWrite(v, CFG, "Detector", k)
}

CoordMode "Pixel", "Screen"

; ALL of these must be assigned before the first Poll() below, not merely
; somewhere in the file. Top-level statements run in order and function bodies are
; skipped, so an initialiser sitting further down — next to the function that uses
; it, which reads better — has simply not run yet when Poll() fires on line one of
; the auto-execute section. That is what "_wPos has not been assigned a value"
; was: the very first poll, reading a variable initialised 130 lines later.
_lastCentre := -99999   ; centre X of the pill we last OCR'd
_lastName   := ""       ; cached OCR'd name for the current active pill
_written    := "«?»"    ; last value written to the ini (dedupes writes)
_wPos       := -1       ; last active_index written  (dedupes writes)
_wTot       := -1       ; last tab_count written
_wX         := -99999   ; last active_x written

Poll()
SetTimer(Poll, PollMs)

Poll() {
    global RegionX, RegionY, RegionW, RegionH, GreyRGB, GreyTol, MinGrey, ScanStep
    global OcrScale, MoveTol, GapTol, DarkRGB, WinMatch, _lastCentre, _lastName

    if (WinMatch != "" && !WinActive(WinMatch)) {
        WriteActive("")
        WritePos(0, 0)
        WriteX(-1)
        _lastCentre := -99999, _lastName := ""
        return
    }

    ; ONE BitBlt, then read from memory. This poll used to call PixelGetColor
    ; ~1000 times, which measured 10.8 SECONDS on this machine — twenty times the
    ; 500ms poll interval, so the service was permanently behind and never once
    ; wrote a current reading. Every theory about why auto-detection failed was
    ; tested against data that was seconds stale.
    img := PILL_Grab(RegionX, RegionY, RegionW + 1, RegionH + 1)
    r := PILL_Scan(img, RegionX, RegionY, RegionX + RegionW, RegionY + RegionH,
                   GreyRGB, DarkRGB, GreyTol, ScanStep, GapTol)
    if (r.count < MinGrey) {
        WriteActive("")                      ; no active pill -> gating off
        WritePos(0, 0)
        WriteX(-1)
        _lastCentre := -99999, _lastName := ""
        return
    }

    ; OCR only when the active pill has moved (a tab switch) or we have no name yet
    if (_lastName = "" || Abs(r.avgX - _lastCentre) > MoveTol) {
        name := OcrPill(r.minX, RegionY, r.maxX - r.minX, RegionH, OcrScale)
        if (name != "") {
            _lastName   := name
            _lastCentre := r.avgX
        }
    }
    if (_lastName != "")
        WriteActive(_lastName)

    ; Written every poll, and cheaply — unlike the name these need no OCR, so
    ; positional mode keeps working even when OCR reads nothing at all.
    WritePos(r.index, r.total)
    WriteX(r.avgX)
}

; The scan itself lives in screen/pill_scan.ahk — PILL_Scan / PILL_GroupRuns /
; PILL_ColorDist — because tools/detector_probe.ahk needs the SAME code. A
; calibrator with its own copy of the scan lets you tune numbers that satisfy the
; tool while the detector still reads the strip differently.
;
; What used to be documented here, kept because it is the failure this file keeps
; being bitten by: the scan must group the lit pill from ACTIVE-coloured columns
; only. Grouping on 'holds either pill colour' merged the whole strip into one run
; whenever the inactive colour also paints the background, which is what produced
; the OCR string 'AW Bellarama' and the permanent 'tab 1 of 1'.

; OCR a rectangle to a single cleaned line; "" on any failure.
OcrPill(x, y, w, h, scale) {
    if (w < 4 || h < 4)
        return ""
    try {
        res := OCR.FromRect(x, y, w, h, {scale: scale, grayscale: 1})
        return Trim(RegExReplace(res.Text, "\s+", " "))
    } catch {
        return ""
    }
}

WriteActive(name) {
    global STATUS, _written
    if (name = _written)
        return
    _written := name
    try IniWrite(name, STATUS, "detector", "active_model")
}

; _wPos / _wTot are initialised at the top of the script, beside _written — see
; the note there for why they cannot live next to this function.
WritePos(index, total) {
    global STATUS, _wPos, _wTot
    if (index = _wPos && total = _wTot)
        return
    _wPos := index, _wTot := total
    try IniWrite(index, STATUS, "detector", "active_index")
    try IniWrite(total, STATUS, "detector", "tab_count")
}

; Where the lit pill IS, in screen px. The single most useful thing this service
; produces, and the cheapest — it falls straight out of the scan, needs no OCR,
; and needs no inactive-pill colour.
;
; Counting tabs requires seeing the tabs you are NOT on, and on a theme that draws
; inactive tabs as bare background they cannot be seen at all. A POSITION requires
; only the tab you are on. So positional mode matches this against positions you
; taught it (see ActiveModelStatus) instead of counting anything.
;
; -1 = no pill found. Distinct from 0, which is a legitimate x coordinate.
WriteX(x) {
    global STATUS, _wX
    if (x = _wX)
        return
    _wX := x
    try IniWrite(x, STATUS, "detector", "active_x")
}
