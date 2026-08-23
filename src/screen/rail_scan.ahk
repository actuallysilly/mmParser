#Requires AutoHotkey v2.0
#Include "pill_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  rail_scan.ahk — find the lit model card in a VERTICAL rail. No side effects.
; ───────────────────────────────────────────────────────────────────────────────
;  The Infloww half of MMA reads a horizontal strip of tabs: pill_scan.ahk walks
;  COLUMNS, groups them on an x gap, and every number it returns is an x. Fansly
;  stacks its models down the left edge instead, so none of that transposes — a
;  column of the Fansly rail cuts through every model at once and tells you
;  nothing about which one is selected. This is the same idea rotated: walk ROWS,
;  group on a y gap, return a y.
;
;  It is a separate file rather than a `vertical := true` parameter on PILL_Scan
;  ON PURPOSE. The two platforms are being kept apart at every level — separate
;  scan, separate service, separate status file, separate config section — so
;  that tuning Fansly can never move a number the Infloww detector reads. That
;  detector took a long time to get right and it is not going to be collateral
;  damage of Fansly calibration.
;
;  What IS shared, because sharing it is free of that risk: PILL_Grab (one BitBlt
;  into memory), PILL_Px, PILL_ColorDist, PILL_CountIn and PILL_PickLit. Those
;  four are orientation-agnostic — a rectangle is a rectangle, a colour distance
;  has no axis, and PILL_PickLit only ever sees an array of counts. Read the
;  header of pill_scan.ahk for why per-pixel PixelGetColor is not an option here
;  either: ~30ms per call on this machine, which is what made the first detector
;  permanently seconds behind its own poll.
;
;  Nothing here reads an ini, writes a file, or starts a timer.
;
;  ─── THE ONE THING FANSLY DOES THAT INFLOWW DOES NOT ─────────────────────────
;  An Infloww tab is a flat block of colour. A Fansly card is a rounded rectangle
;  wrapped around a PHOTOGRAPH — the model's avatar — and a photo contains every
;  colour there is. Count "pixels near the card colour" across the full width of
;  a row and an avatar with a dark grey background scores like a lit card, so an
;  unselected model reads as selected. There is no tolerance that fixes that,
;  because the avatar is not a wrong colour, it is an arbitrary one.
;
;  So the caller passes a NARROW x band — the card's left margin, outside the
;  avatar circle — as x1..x2. That band is flat colour again, and everything
;  below is back to the problem pill_scan already solves. This is why every
;  function here takes an x range it will not widen: the whole design depends on
;  not looking at the picture.
; ═══════════════════════════════════════════════════════════════════════════════

; Rows -> contiguous runs, breaking wherever the y gap exceeds `gap` px.
;
; The vertical twin of PILL_GroupRuns, and it exists for the same reason that one
; does: a card is a solid block so its rows are contiguous, and anything wider
; than `gap` is the space BETWEEN two cards. Grouping across that space is what
; produced "AW Bellarama" on the Infloww side — two tabs read as one name — and
; the Fansly equivalent would be one run covering the entire rail, i.e. "row 1 of
; 1" forever whichever model you are actually looking at.
RAIL_GroupRuns(rows, gap) {
    runs := []
    if !rows.Length
        return runs
    run  := {act: 0, sumY: 0, minY: rows[1].y, maxY: rows[1].y}
    prev := rows[1].y
    for r in rows {
        if (r.y - prev > gap) {
            runs.Push(run)
            run := {act: 0, sumY: 0, minY: r.y, maxY: r.y}
        }
        run.act  += r.act
        run.sumY += r.y * r.act
        run.maxY := r.y
        prev := r.y
    }
    runs.Push(run)
    return runs
}

; Sweep a band of the rail and report the LIT card: pixel count, centre, extent.
;
; x1..x2 must already be the narrow sample band described in the header — this
; function will not choose it for you, and handing it the full rail width is the
; avatar bug, not a tuning problem.
;
; Only ONE colour is taken, unlike PILL_Scan which also takes the inactive tab
; colour so it can count tabs. Counting is not needed here and taking a second
; colour would be actively harmful: on Fansly an unselected model is drawn
; straight onto the rail background, so "the inactive colour" IS the background,
; every row would qualify, no gap would ever appear and the single run would span
; the rail. pill_scan.ahk has that failure written up in full — it happened, it
; cost days, and the fix there was to stop grouping on the inactive colour. This
; file simply never learns it.
;
; Rows are found, not assumed, which is what makes this the PROBE's function: it
; answers "where is the lit card actually" for a rail nobody has calibrated yet.
; The hot path uses RAIL_CountIn against known row positions instead — see
; fansly_scan.ahk.
;
; Returns {count, avgY, minY, maxY}. count = 0 means NO ANSWER, and callers must
; treat it as "I cannot see", never as "row 1".
RAIL_Scan(img, x1, y1, x2, y2, activeRGB, tol, step, gap) {
    none := {count: 0, avgY: -1, minY: 0, maxY: -1}
    if !img
        return none
    actRows := []
    y := y1
    while (y <= y2) {
        act := 0
        x := x1
        while (x <= x2) {
            c := PILL_Px(img, x, y)
            if (c >= 0 && PILL_ColorDist(c, activeRGB) <= tol)
                act++
            x += step
        }
        if (act)
            actRows.Push({y: y, act: act})
        y += step
    }
    if !actRows.Length
        return none

    runs := RAIL_GroupRuns(actRows, gap)
    best := 0
    for i, r in runs
        if (!best || r.act > runs[best].act)
            best := i
    if (!best || !runs[best].act)
        return none
    b := runs[best]

    ; A "card" as tall as the rail is not a card. The horizontal version of this
    ; guard caught a 1px border that sat inside the default tolerance and matched
    ; in all 83 columns; the Fansly equivalent is the rail background itself
    ; landing inside CardTol, which is far more likely here because the selected
    ; card and the rail behind it differ by only a few levels of grey. Refusing is
    ; the right answer: a run that covers everything identifies nothing.
    if (b.maxY - b.minY >= (y2 - y1) * 0.8)
        return none

    return {count: b.act, avgY: Round(b.sumY / b.act),
            minY: b.minY, maxY: b.maxY}
}

; Screen y -> row index, 1-based, top to bottom. 0 = above the rail.
;
; The entire positional detection for Fansly, in one line of arithmetic, and for
; the same reason it is one line on the Infloww side: row positions are FIXED.
; The rail starts at `origin` and each card is `pitch` tall, so the lit card's y
; IS the row index. Nothing is searched for and nothing is counted — counting is
; the part that cannot work, since unselected models are drawn on bare background
; and a colour scan cannot see them at all.
RAIL_IndexFromY(y, origin, pitch) {
    if (y < 0 || pitch < 1 || y < origin)
        return 0
    return ((y - origin) // pitch) + 1
}
