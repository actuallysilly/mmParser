#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  pill_scan.ahk — find the lit model tab in a band of screen. No side effects.
; ───────────────────────────────────────────────────────────────────────────────
;  Pure functions, deliberately: model_detector.ahk (the background service),
;  core/active_model.ahk (the hotkey path) and tools/detector_probe.ahk (the
;  calibrator) ALL include this and have to agree down to the pixel. A calibrator
;  that reads the strip with its own copy of the scan is one you cannot trust —
;  you would tune numbers that satisfy the tool and leave the service wrong.
;
;  Nothing here reads an ini, writes a file, or starts a timer.
;
;  ─── WHY THERE IS A BITMAP CAPTURE IN HERE ───────────────────────────────────
;  Everything used to call PixelGetColor per pixel. On this machine that is
;  ~30 MILLISECONDS each. Measured, not estimated:
;
;      sampling 3 tab slots (~150 px)   4632 ms
;      one sweep of the 330x50 band    10828 ms
;
;  The background detector polls every 500ms and did a full sweep each time, so it
;  was roughly 20x slower than its own poll interval — permanently behind, never
;  once returning a current reading. That is the real reason auto-detection never
;  worked, and it is why every explanation before it (wrong colours, wrong
;  geometry, tab counting) fitted the symptoms without fixing anything: the data
;  those theories were tested against was stale by seconds.
;
;  PixelGetColor goes through GDI GetPixel on the screen DC, which on a composited
;  desktop can round-trip the GPU per call. One BitBlt of the whole band into a
;  memory DIB costs about the same as a single GetPixel, and every pixel after
;  that is a memory read. So: grab once, then read from the buffer.
; ═══════════════════════════════════════════════════════════════════════════════

; Capture a screen rectangle into memory. Returns an object to hand to PILL_Px and
; everything below, or 0 if the capture failed.
;
; 32bpp with a NEGATIVE height, which makes the DIB top-down so row 0 is the top
; row and the index arithmetic in PILL_Px is the obvious one. Bottom-up DIBs (the
; default) are the classic source of vertically mirrored reads.
PILL_Grab(x, y, w, h) {
    if (w < 1 || h < 1)
        return 0
    hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    if !hdcScreen
        return 0
    img := 0
    hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    if hdcMem {
        bi := Buffer(40, 0)
        NumPut("uint", 40, bi, 0)          ; biSize
        NumPut("int",   w, bi, 4)          ; biWidth
        NumPut("int",  -h, bi, 8)          ; biHeight, negative = top-down
        NumPut("ushort", 1, bi, 12)        ; biPlanes
        NumPut("ushort", 32, bi, 14)       ; biBitCount
        NumPut("uint", 0, bi, 16)          ; biCompression = BI_RGB
        pBits := 0
        hbm := DllCall("CreateDIBSection", "ptr", hdcMem, "ptr", bi, "uint", 0,
                       "ptr*", &pBits, "ptr", 0, "uint", 0, "ptr")
        if (hbm && pBits) {
            old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hbm, "ptr")
            ; SRCCOPY. CAPTUREBLT is deliberately NOT set: it pulls in layered
            ; windows (tooltips, overlays), and MMA's own toast can sit over the
            ; strip at exactly the moment a select key is pressed.
            ok := DllCall("gdi32\BitBlt", "ptr", hdcMem, "int", 0, "int", 0,
                          "int", w, "int", h, "ptr", hdcScreen,
                          "int", x, "int", y, "uint", 0x00CC0020)
            if ok {
                data := Buffer(w * h * 4)
                DllCall("RtlMoveMemory", "ptr", data, "ptr", pBits, "uptr", w * h * 4)
                img := {data: data, w: w, h: h, x: x, y: y}
            }
            DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
        }
        if hbm
            DllCall("DeleteObject", "ptr", hbm)
        DllCall("DeleteDC", "ptr", hdcMem)
    }
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    return img
}

; One pixel as 0xRRGGBB, addressed in SCREEN coordinates so callers never have to
; think about the capture's origin. -1 when outside the captured rectangle.
;
; A DIB row is B,G,R,A; little-endian NumGet of a uint therefore yields
; A<<24 | R<<16 | G<<8 | B, so masking off the alpha gives 0xRRGGBB directly —
; the same format PixelGetColor returns, which is what lets the [Detector] colours
; stay exactly as they were.
PILL_Px(img, sx, sy) {
    ix := sx - img.x, iy := sy - img.y
    if (ix < 0 || iy < 0 || ix >= img.w || iy >= img.h)
        return -1
    return NumGet(img.data, (iy * img.w + ix) * 4, "uint") & 0xFFFFFF
}

; Per-channel max distance between two 0xRRGGBB colours.
PILL_ColorDist(c1, c2) {
    r := Abs(((c1 >> 16) & 0xFF) - ((c2 >> 16) & 0xFF))
    g := Abs(((c1 >>  8) & 0xFF) - ((c2 >>  8) & 0xFF))
    b := Abs(( c1        & 0xFF) - ( c2        & 0xFF))
    return Max(r, g, b)
}

; How many active-coloured pixels sit in a rectangle, on a coarse grid.
;
; This is the whole of positional detection. Tab positions are FIXED, so there is
; nothing to search for: look at where tab 2 is and ask whether it is lit.
PILL_CountIn(img, x1, x2, y1, y2, rgb, tol, xstep, ystep) {
    n := 0
    x := x1
    while (x <= x2) {
        y := y1
        while (y <= y2) {
            c := PILL_Px(img, x, y)
            if (c >= 0 && PILL_ColorDist(c, rgb) <= tol)
                n++
            y += ystep
        }
        x += xstep
    }
    return n
}

; Given one active-pixel count per tab slot, which slot is lit?
;
; Split from the sampling so the DECISION is testable without a screen — every
; wrong-model bug here has been in the decision, and none were reachable by a test
; that needed the live Infloww strip in front of it.
;
; Returns 0 unless one slot is clearly lit. Two refusals, and both matter more
; than picking a winner:
;   • nothing reaches `minCount` — no tab is lit, or the colour/region is wrong
;   • the runner-up is more than half the winner — two slots both look lit, which
;     is not what one active tab looks like. It IS what a wrong TabPitch looks
;     like, with one pill straddling two slots.
PILL_PickLit(counts, minCount) {
    best := 0, bestN := 0, secondN := 0
    for i, n in counts {
        if (n < 0)
            continue
        if (n > bestN)
            secondN := bestN, best := i, bestN := n
        else if (n > secondN)
            secondN := n
    }
    if (!best || bestN < minCount)
        return 0
    if (secondN * 2 > bestN)
        return 0
    return best
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

; Sweep the whole band and report the LIT tab: pixel count, centre, extent.
;
; Used by the OCR path (which needs a rectangle to read a name out of) and by the
; probe. The hotkey path uses PILL_CountIn instead — it already knows where the
; tabs are and has no reason to search.
;
; The two colours go into two SEPARATE column lists, and that separation matters.
; They used to share one — a column counted if it held EITHER — and the runs,
; including the rectangle handed to OCR, came from that. It works only while the
; inactive colour really is the inactive pill and nothing else. On Infloww it is
; not: `#0d0d0d` is the inactive tab AND the empty strip either side of the tabs,
; measured in 82 of 83 columns. Every column qualified, no gap ever appeared, and
; the single run spanned everything — so OCR returned "AW Bellarama", two model
; names as one string, and the tab count came back 1.
;
; Returns {count, avgX, minX, maxX, index, total}. count = 0 means no answer, and
; callers must treat that as "I cannot see", never as "tab 1".
PILL_Scan(img, x1, y1, x2, y2, activeRGB, inactiveRGB, tol, step, gap) {
    none := {count: 0, avgX: -1, minX: 0, maxX: -1, index: 0, total: 0}
    if !img
        return none
    actCols := []                 ; columns holding the ACTIVE pill colour
    anyCols := []                 ; columns holding either pill colour
    x := x1
    while (x <= x2) {
        act := 0, any := 0
        y := y1
        while (y <= y2) {
            c := PILL_Px(img, x, y)
            if (c < 0) {
            } else if (PILL_ColorDist(c, activeRGB) <= tol)
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

    ; Tab COUNT, a much weaker measurement: it needs the inactive pills to be
    ; distinguishable, and on a theme that draws them as bare background they are
    ; not. One run covering the strip means exactly that, and the honest answer is
    ; 0, "cannot count". Reporting 1 is what made positional mode answer "model 1"
    ; for every tab, forever.
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
