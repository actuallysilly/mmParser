#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
;  model_detect_test.ahk  —  ACTIVE-MODEL DETECTION TEST RIG
; ----------------------------------------------------------------------------
;  Detects which model TAB is active by its pill background colour:
;       ACTIVE tab   = grey  pill background (2b2c30)
;       INACTIVE tab = black pill background (0d0d0d)
;  (The little square icon is black in BOTH states, so it is ignored.)
;
;  Method: scan the top-left region, count the grey pixels, and take their
;  horizontal centre. The active pill is a big solid grey patch; the inactive
;  one has almost none. Grey centre on the LEFT => AW (model 1), on the RIGHT
;  => BUT (model 2). No setup, polls once a second.
;
;  The CURSOR line shows the colour+class under your mouse for inspection.
;  Ctrl+Alt+F12 = quit    Ctrl+Alt+F5 = reload
;
;  Modified keys, never a bare Esc or F5: this runs WHILE Infloww is focused, and
;  a bare hotkey is swallowed globally — it would take Esc away from Infloww's own
;  dialogs and F5 away from reloading the page, for as long as this was up.
; ============================================================================

; ---- CONFIG (tune from the live readout) -----------------------------------
REGION_X    := 0        ; scan area, screen px
REGION_Y    := 0
REGION_W    := 330
REGION_H    := 50
SPLIT_X     := 165      ; boundary between AW (left) and BUT (right) pills

GREY_ACTIVE := 0x2B2C30 ; active pill background
BLACK_INACT := 0x0D0D0D ; inactive pill background
GREY_TOL    := 22       ; how close to grey counts as "grey" (black is ~35 away, so it won't)
MIN_GREY    := 6        ; need at least this many grey samples to call anything active

SCAN_STEP   := 4        ; grid spacing for the count scan (smaller = finer/slower)
POLL_MS     := 1000     ; poll interval (once per second, as requested)
TIP_X       := 12       ; tooltip screen position
TIP_Y       := 70
; ----------------------------------------------------------------------------

HISTORY_MAX := 8        ; how many past 1-second captures to show

CoordMode "Pixel", "Screen"
CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

gTick    := 0           ; heartbeat: increments every capture
gHistory := []          ; rolling log of recent captures

Poll()                  ; run once immediately
SetTimer(Poll, POLL_MS)

Poll() {
    global REGION_X, REGION_Y, REGION_W, REGION_H, SPLIT_X
    global MIN_GREY, TIP_X, TIP_Y, HISTORY_MAX, gTick, gHistory

    gTick++

    x1  := REGION_X
    y1  := REGION_Y
    x2  := REGION_X + REGION_W
    y2  := REGION_Y + REGION_H
    mid := REGION_X + SPLIT_X

    res := ScanGrey(x1, y1, x2, y2)

    if (res.count < MIN_GREY)
        model := "NONE   "
    else if (res.avgX < mid)
        model := "MODEL 1 (AW)"
    else
        model := "MODEL 2 (BUT)"

    ; push this capture onto the rolling history
    stamp := A_Hour ":" A_Min ":" A_Sec
    gHistory.Push(stamp "  " model "   grey " res.count " (L" res.leftCount "/R" res.rightCount ")")
    while (gHistory.Length > HISTORY_MAX)
        gHistory.RemoveAt(1)

    histBlock := ""
    for i, line in gHistory
        histBlock .= (i = gHistory.Length ? "> " : "  ") line "`n"

    ; live cursor readout for inspection
    MouseGetPos(&mx, &my)
    cur := PixelGetColor(mx, my)

    ToolTip(
        "ACTIVE-MODEL DETECTOR  (capturing 1/s)  #" gTick "`n"
      . "==========================================`n"
      . "  >>> " model " <<<`n"
      . "  grey px: " res.count "   centreX: " (res.count ? res.avgX : "-") "   split: " mid "`n"
      . "  left grey: " res.leftCount "   right grey: " res.rightCount "`n"
      . "------------------------------------------`n"
      . "CURSOR @ " mx "," my " = #" Format("{:06X}", cur & 0xFFFFFF) "  " Classify(cur) "`n"
      . "------------------------------------------`n"
      . "HISTORY (newest last):`n"
      . histBlock
      . "------------------------------------------`n"
      . "region " REGION_X "," REGION_Y " " REGION_W "x" REGION_H
      . "   ^!F12=quit  ^!F5=reload",
        TIP_X, TIP_Y)
}

; Grid-scan the area; count grey pixels and their horizontal centroid.
; Also splits the count into left/right of SPLIT_X for diagnostics.
ScanGrey(x1, y1, x2, y2) {
    global GREY_ACTIVE, GREY_TOL, SCAN_STEP, REGION_X, SPLIT_X
    mid := REGION_X + SPLIT_X
    count := 0, sumX := 0, leftCount := 0, rightCount := 0
    y := y1
    while (y <= y2) {
        x := x1
        while (x <= x2) {
            if (ColorDist(PixelGetColor(x, y), GREY_ACTIVE) <= GREY_TOL) {
                count++
                sumX += x
                (x < mid) ? leftCount++ : rightCount++
            }
            x += SCAN_STEP
        }
        y += SCAN_STEP
    }
    return {count: count, avgX: (count ? Round(sumX/count) : -1),
            leftCount: leftCount, rightCount: rightCount}
}

; nearest-of-two label for the cursor readout
Classify(c) {
    global GREY_ACTIVE, BLACK_INACT, GREY_TOL
    dGrey  := ColorDist(c, GREY_ACTIVE)
    dBlack := ColorDist(c, BLACK_INACT)
    if (dGrey <= GREY_TOL)
        return "GREY/active"
    if (dBlack <= GREY_TOL)
        return "BLACK/inactive"
    return "other"
}

; per-channel max distance between two 0xRRGGBB colours
ColorDist(c1, c2) {
    r := Abs(((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    g := Abs(((c1 >>  8) & 0xFF) - ((c2 >>  8) & 0xFF))
    b := Abs(( c1        & 0xFF) - ( c2        & 0xFF))
    return Max(r, g, b)
}

^!F12::ExitApp
^!F5::Reload
