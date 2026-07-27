#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  pill_scan.ahk — find the lit model tab in a band of screen. No side effects.
; ───────────────────────────────────────────────────────────────────────────────
;  Pure functions, deliberately: model_detector.ahk (the background service) and
;  detector_probe.ahk (the calibrator) BOTH include this, and they have to agree
;  down to the pixel. A calibrator that reads the strip with its own copy of the
;  scan is a calibrator you cannot trust — you would tune numbers that make the
;  tool happy and the detector still wrong. There was such a copy; this is it,
;  once.
;
;  Nothing here reads an ini, writes a file, or starts a timer. Include it from
;  anywhere.
; ═══════════════════════════════════════════════════════════════════════════════

; Per-channel max distance between two 0xRRGGBB colours.
PILL_ColorDist(c1, c2) {
    r := Abs(((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    g := Abs(((c1 >>  8) & 0xFF) - ((c2 >>  8) & 0xFF))
    b := Abs(( c1        & 0xFF) - ( c2        & 0xFF))
    return Max(r, g, b)
}

; Columns -> contiguous runs, breaking wherever the x gap exceeds `gap` px.
PILL_GroupRuns(cols, gap) {
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

; Scan the band and report the LIT tab: its pixel count, centre, and extent.
;
; The two colours go into two SEPARATE column lists, and that separation is the
; whole fix. They used to share one — a column counted if it held EITHER — and
; the runs, including the rectangle handed to OCR, came from that. It works only
; while the inactive colour really is the inactive pill and nothing else. On
; Infloww it is not: `#0d0d0d` is the inactive tab AND the empty strip either
; side of the tabs, measured in 82 of 83 columns. Every column qualified, no gap
; ever appeared, and the single run spanned everything — so OCR returned
; "AW Bellarama", two model names as one string, and the tab count came back 1.
;
; Grouping the lit pill from active-coloured columns ALONE cannot merge with a
; neighbour, whatever the inactive colour turns out to be on your theme.
;
; Returns {count, avgX, minX, maxX, index, total}. count = 0 means no answer, and
; callers must treat that as "I cannot see", never as "tab 1".
PILL_Scan(x1, y1, x2, y2, activeRGB, inactiveRGB, tol, step, gap) {
    actCols := []                 ; columns holding the ACTIVE pill colour
    anyCols := []                 ; columns holding either pill colour
    x := x1
    while (x <= x2) {
        act := 0, any := 0
        y := y1
        while (y <= y2) {
            c := PixelGetColor(x, y)
            if (PILL_ColorDist(c, activeRGB) <= tol)
                act++, any++
            else if (PILL_ColorDist(c, inactiveRGB) <= tol)
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

    actRuns := PILL_GroupRuns(actCols, gap)
    best := 0
    for i, r in actRuns
        if (!best || r.act > actRuns[best].act)
            best := i
    if (!best || !actRuns[best].act)
        return none
    b := actRuns[best]

    ; A "pill" as wide as the band is not a pill. That is a tolerance loose enough
    ; to match something drawn straight across the strip — measured: `#3d3d3d`, a
    ; border in all 83 columns, sitting 18 from the pill colour and so inside the
    ; default GreyTol of 22. Refuse rather than name a model from it.
    if (b.maxX - b.minX >= (x2 - x1) * 0.8)
        return none

    ; Tab COUNT, which is a different and much weaker measurement — it needs the
    ; inactive pills to be distinguishable, and on a theme that draws them as bare
    ; background they are not. One run covering the strip means exactly that, and
    ; the honest answer is 0, "cannot count". Reporting 1 is what made positional
    ; mode answer "model 1" for every tab, forever.
    tabRuns := PILL_GroupRuns(anyCols, gap)
    total   := tabRuns.Length
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
