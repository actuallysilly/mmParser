#Requires AutoHotkey v2.0
#Include "pill_scan.ahk"
#Include "rail_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  reply_scan.ahk — find the unread dots in a conversation list. No side effects.
; ───────────────────────────────────────────────────────────────────────────────
;  Pure functions, and this file exists for the reason pill_scan.ahk states at the
;  top of its own: the SERVICE and the CALIBRATOR have to agree down to the pixel.
;
;      screen/reply_box.ahk        paints the boxes
;      ui/settings_window.ahk      "Calibrate a row…" — measures one row by
;                                  finding the dot inside the box you drew
;
;  A calibrator that finds the dot with its own copy of the scan is one you cannot
;  trust. You would drag a box, it would report a row height measured against ITS
;  idea of where the dot is, and the service would then draw against a different
;  one — a calibration that makes the overlay worse the more carefully you do it.
;
;  Nothing here reads an ini, writes a file, or starts a timer. RBS_Defaults is the
;  one concession: it holds the DEFAULT VALUES so that both callers fall back to
;  the same numbers, but it does not go and read them from anywhere.
;
;  ─── WHY A NARROW BAND, AGAIN ────────────────────────────────────────────────
;  Only the right-hand end of a row is ever looked at. rail_scan.ahk has the long
;  version and it applies here word for word: sweep the full width of a row and
;  you cut straight through the fan's AVATAR, and a photograph contains every
;  colour there is — including, in any picture with warm skin or a sunset, a coral
;  close enough to #ff7c71 to count. There is no tolerance that fixes that,
;  because the avatar is not a wrong colour, it is an arbitrary one.
; ═══════════════════════════════════════════════════════════════════════════════

; The shipped defaults, in one place so reply_box.ahk and the Settings calibrator
; cannot drift apart on them. Values only — nothing here reads the cfg.
;
; DotTol is 20 and that is deliberately tight. Do NOT copy the pinger's CORAL_TOL
; of 45 into it: that number is a SUM-OF-CHANNELS distance while PILL_ColorDist is
; the per-channel MAXIMUM, so the same 45 is a far looser filter than it looks.
; The dot is a solid block of exactly #ff7c71 — the pinger measured it identical
; at every tolerance from 30 to 70 — so tight costs nothing.
RBS_Defaults() {
    return {color:  0xFF7C71,   ; Infloww's unread coral
            tol:    20,
            band:   46,         ; px in from the region's right edge
            step:   2,          ; sampling grid, both axes — see RBS_FindDots
            minPx:  4,
            maxPx:  400,
            maxH:   24,
            gap:    6,
            ; Measured on a real Infloww list: rows are 105px apart. It is still
            ; only a starting point — the pitch moves with zoom and display
            ; scaling, which is what "Calibrate a row…" is for.
            rowH:   105,
            border: 4}
}

; Find the unread dots in `img`, looking only at the right-hand `o.band` pixels.
;
; `img` is a PILL_Grab result; `o` is anything with the fields RBS_Defaults names.
; Returns [{cy, top, bottom, px}] with cy the dot's centre in SCREEN y, in the
; order they appear down the list.
;
;  ─── THE STEP IS THE WHOLE COST ──────────────────────────────────────────────
;  This runs on reply_box's fast tick. At a step of 1 a 46x800 band is ~37,000
;  PILL_Px calls EVERY TICK, which is tens of milliseconds of a 400ms budget spent
;  forever looking for a dot six pixels across. pill_scan.ahk's header is the long
;  version of why that matters — a scan that cannot finish inside its own poll is
;  how the model detector spent months returning readings that were seconds stale.
;
;  2 costs a quarter of that and still lands 3x3 samples inside a 6px dot. Raise
;  it and minPx has to come down with it: both count SAMPLED pixels, not real ones.
RBS_FindDots(img, o) {
    out := []
    if !img
        return out
    x1 := img.x + img.w - o.band
    x2 := img.x + img.w - 1
    hits := []
    y := img.y
    while (y < img.y + img.h) {
        act := 0
        x := x1
        while (x <= x2) {
            c := PILL_Px(img, x, y)
            if (c >= 0 && PILL_ColorDist(c, o.color) <= o.tol)
                act++
            x += o.step
        }
        if act
            hits.Push({y: y, act: act})
        y += o.step
    }
    if !hits.Length
        return out
    ; RAIL_GroupRuns, not a fresh copy of it: this is the same "rows into runs,
    ; broken on a y gap" the Fansly rail scan does, and having two of them is how
    ; two detectors drift apart.
    for _, run in RAIL_GroupRuns(hits, o.gap) {
        h := run.maxY - run.minY + 1
        ; Size and height, which is all that is needed here. A run taller than a
        ; dot is a coral EDGE of something — most likely a selected row's accent
        ; stripe — and a run of two pixels is noise.
        if (run.act < o.minPx || run.act > o.maxPx || h > o.maxH)
            continue
        out.Push({cy: Round(run.sumY / run.act), top: run.minY, bottom: run.maxY,
                  px: run.act})
    }
    return out
}

; The one dot nearest the vertical centre of the grab, or 0.
;
; For the row calibrator: you drag a box around ONE conversation, and this says
; which dot is that conversation's. Nearest-to-centre rather than first, because a
; box drawn generously round a row can clip the top of the dot belonging to the
; row below, and taking the first would then measure the wrong row — off by a full
; row height, in the direction that looks almost right.
RBS_DotNearestCentre(img, o) {
    dots := RBS_FindDots(img, o)
    if !dots.Length
        return 0
    mid  := img.y + img.h // 2
    best := 0, bestD := 0
    for _, d in dots {
        dist := Abs(d.cy - mid)
        if (!best || dist < bestD)
            best := d, bestD := dist
    }
    return best
}
