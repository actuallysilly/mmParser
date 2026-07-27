#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../vendor/OCR.ahk"

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

Poll()
SetTimer(Poll, PollMs)

Poll() {
    global RegionX, RegionY, RegionW, RegionH, GreyRGB, GreyTol, MinGrey, ScanStep
    global OcrScale, MoveTol, GapTol, DarkRGB, WinMatch, _lastCentre, _lastName

    if (WinMatch != "" && !WinActive(WinMatch)) {
        WriteActive("")
        WritePos(0, 0)
        _lastCentre := -99999, _lastName := ""
        return
    }

    r := ScanPills(RegionX, RegionY, RegionX + RegionW, RegionY + RegionH,
                   GreyRGB, DarkRGB, GreyTol, ScanStep, GapTol)
    if (r.count < MinGrey) {
        WriteActive("")                      ; no active pill -> gating off
        WritePos(0, 0)
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

    ; Written every poll, and cheaply — unlike the name it needs no OCR, so
    ; positional mode keeps working even when OCR reads nothing at all.
    WritePos(r.index, r.total)
}

; Grid-scan the band and return the DOMINANT contiguous run of grey columns.
;
; This used to return the min/max X of EVERY grey pixel in the region, which is
; only correct when exactly one thing in the band is grey. It is not: a second
; tab's chrome, a hover state, or any grey UI at those coordinates gives a second
; blob, and min..max then spans BOTH pills. OCR duly read the pair as one string —
; "AW Bellarama" — and one string holding two model names cannot be resolved
; safely by anything downstream. It also dragged avgX to a point between the two
; blobs, so the "pill moved" check stopped tracking tab switches.
;
; A pill is a solid block of background colour, so its columns are contiguous;
; separate pills are separated by a real gap. Group the grey columns into runs,
; break on any gap wider than `gap` px, and keep the run holding the most grey.
; Also reports the active pill's POSITION in the strip, which is what positional
; mode uses instead of a name (see utils.ahk's ActiveModelNo).
;
; Position needs every tab, not just the lit one, so the scan matches BOTH pill
; colours: active pills are grey, inactive ones near-black. Columns holding either
; are grouped into runs — one run per tab — and the run carrying the most
; active-coloured pixels is the tab in front. Its rank left-to-right is the index.
;
; Counting tabs this way rather than dividing X by a tab pitch is deliberate: the
; strip SHRINKS its pitch as tabs are added (~170px at 4 tabs, ~130px at 13), so
; any fixed-pitch arithmetic is right until the day you open one more chat.
; The two colours are scanned into two SEPARATE column lists, and that separation
; is the fix for the bug this whole file exists to avoid.
;
; They used to share one list: a column counted if it held EITHER colour, and the
; runs — including the one handed to OCR — were grouped from that. It works only
; while the inactive colour really is the inactive pill. On Infloww it is not:
; a probe of the live strip (tools\detector_probe.ahk) found InactiveColor's
; 0x0D0D0D present in 82 of 83 columns, because that is the PAGE BACKGROUND —
; inactive tabs there are drawn with no fill at all. Every column therefore
; qualified, no gap ever appeared, and the single resulting run spanned the whole
; strip. OCR read that rectangle and returned both names as one string,
; "AW Bellarama", which is the exact value sitting in detector_status.ini.
;
; Grouping the LIT pill from active-coloured columns alone cannot merge with a
; neighbour, whatever the inactive colour turns out to be. The inactive colour is
; now used for one thing only — counting tabs for positional mode — and when it
; cannot do that it says so instead of guessing.
ScanPills(x1, y1, x2, y2, activeRGB, inactiveRGB, tol, step, gap) {
    actCols := []                 ; columns holding the ACTIVE pill colour
    anyCols := []                 ; columns holding either pill colour
    x := x1
    while (x <= x2) {
        act := 0, any := 0
        y := y1
        while (y <= y2) {
            c := PixelGetColor(x, y)
            if (ColorDist(c, activeRGB) <= tol)
                act++, any++
            else if (ColorDist(c, inactiveRGB) <= tol)
                any++
            y += step
        }
        if (act)
            actCols.Push({x: x, act: act})
        if (any)
            anyCols.Push({x: x, act: act})
        x += step
    }
    none := {count: 0, avgX: -1, minX: 0, maxX: -1, index: 0, total: 0}
    if !actCols.Length
        return none

    ; ── the lit pill ──────────────────────────────────────────────────────────
    actRuns := _GroupRuns(actCols, gap)
    best := 0
    for i, r in actRuns
        if (!best || r.act > actRuns[best].act)
            best := i
    if (!best || !actRuns[best].act)
        return none
    b := actRuns[best]

    ; A "pill" as wide as the region is not a pill. That is a tolerance loose
    ; enough to match something drawn straight across the strip — the same probe
    ; found 0x3D3D3D, a border line present in all 83 columns, sitting 17 apart
    ; from the pill colour and therefore inside the default GreyTol of 22. OCR of
    ; that rectangle is every tab at once, so refuse rather than name a model
    ; from it.
    if (b.maxX - b.minX >= (x2 - x1) * 0.8)
        return none

    ; ── how many tabs, and which one is lit ───────────────────────────────────
    tabRuns := _GroupRuns(anyCols, gap)
    total   := tabRuns.Length
    ; Same degenerate test, for the count. One run covering the whole strip means
    ; the inactive colour is matching the background, so the tabs are not
    ; separable and the honest answer is "I cannot count them" — NOT "there is
    ; one tab", which is what made positional mode resolve to model 1 forever
    ; however many models were open.
    if (total = 1 && tabRuns[1].maxX - tabRuns[1].minX >= (x2 - x1) * 0.8)
        total := 0

    avgX  := Round(b.sumX / b.act)
    index := 0
    if total {
        for i, r in tabRuns {
            if (avgX >= r.minX && avgX <= r.maxX) {
                index := i
                break
            }
        }
    }
    return {count: b.act, avgX: avgX, minX: b.minX, maxX: b.maxX,
            index: index, total: total}
}

; Columns -> contiguous runs, breaking wherever the gap exceeds `gap` px.
_GroupRuns(cols, gap) {
    runs := []
    if !cols.Length
        return runs
    run  := {act: 0, sumX: 0, minX: cols[1].x, maxX: cols[1].x}
    prev := cols[1].x
    for c in cols {
        if (c.x - prev > gap) {
            runs.Push(run)
            run := {act: 0, sumX: 0, minX: c.x, maxX: c.x}
        }
        run.act  += c.act
        run.sumX += c.x * c.act
        run.maxX := c.x
        prev := c.x
    }
    runs.Push(run)
    return runs
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

; per-channel max distance between two 0xRRGGBB colours
ColorDist(c1, c2) {
    r := Abs(((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    g := Abs(((c1 >>  8) & 0xFF) - ((c2 >>  8) & 0xFF))
    b := Abs(( c1        & 0xFF) - ( c2        & 0xFF))
    return Max(r, g, b)
}
