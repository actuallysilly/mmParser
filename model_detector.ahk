#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "lib/OCR.ahk"

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

CFG    := A_ScriptDir "\mass_gui.cfg"
STATUS := A_ScriptDir "\detector_status.ini"

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
                    "PollMs",PollMs, "OcrScale",OcrScale, "MoveTol",MoveTol, "WinMatch",WinMatch)
        try IniWrite(v, CFG, "Detector", k)
}

CoordMode "Pixel", "Screen"

_lastCentre := -99999   ; centre X of the pill we last OCR'd
_lastName   := ""       ; cached OCR'd name for the current active pill
_written    := "«?»"    ; last value written to the ini (dedupes writes)

Poll()
SetTimer(Poll, PollMs)

Poll() {
    global RegionX, RegionY, RegionW, RegionH, GreyRGB, GreyTol, MinGrey, ScanStep
    global OcrScale, MoveTol, WinMatch, _lastCentre, _lastName

    if (WinMatch != "" && !WinActive(WinMatch)) {
        WriteActive("")
        _lastCentre := -99999, _lastName := ""
        return
    }

    r := ScanGrey(RegionX, RegionY, RegionX + RegionW, RegionY + RegionH, GreyRGB, GreyTol, ScanStep)
    if (r.count < MinGrey) {
        WriteActive("")                      ; no active pill -> gating off
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
}

; Grid-scan; count grey pixels, their horizontal centroid, and their extent.
ScanGrey(x1, y1, x2, y2, target, tol, step) {
    count := 0, sumX := 0, minX := 0x7FFFFFFF, maxX := -1
    y := y1
    while (y <= y2) {
        x := x1
        while (x <= x2) {
            if (ColorDist(PixelGetColor(x, y), target) <= tol) {
                count++, sumX += x
                if (x < minX)
                    minX := x
                if (x > maxX)
                    maxX := x
            }
            x += step
        }
        y += step
    }
    return {count: count, avgX: (count ? Round(sumX / count) : -1), minX: minX, maxX: maxX}
}

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

; per-channel max distance between two 0xRRGGBB colours
ColorDist(c1, c2) {
    r := Abs(((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    g := Abs(((c1 >>  8) & 0xFF) - ((c2 >>  8) & 0xFF))
    b := Abs(( c1        & 0xFF) - ( c2        & 0xFF))
    return Max(r, g, b)
}
