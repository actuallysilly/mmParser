#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/hotkeys.ahk"
#Include "../core/reply_tiers.ahk"
#Include "pill_scan.ahk"
#Include "rail_scan.ahk"
#Include "reply_scan.ahk"
#Include "ocr_grab.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  reply_box.ahk — a coloured frame round any conversation that has been waiting.
; ───────────────────────────────────────────────────────────────────────────────
;  Infloww's conversation list tells you a message arrived and when. It does not
;  tell you how long it has been sitting there, which is the number the shift is
;  actually judged on — and reading twelve wall-clock stamps and subtracting each
;  one from the current time, forty times an hour, is not something anybody does
;  reliably at minute three.
;
;  So MMA does the subtraction and paints the answer: rows past a threshold get a
;  thick border in that threshold's colour. Thresholds and colours are yours —
;  Settings ▸ General ▸ Reply timers, or [ReplyBox] in mass_gui.cfg.
;
;      under 3 min   nothing        4-6 min   red
;      3-4 min       yellow         6-10 min  pink        10 min+   white
;
;  Those are only the DEFAULTS. There is no "three tiers" anywhere in the code —
;  RB_Tiers reads Tier1..TierN, so a fifth colour is a fifth line in the cfg.
;
;  ─── ONLY ROWS THAT ARE WAITING ON YOU ───────────────────────────────────────
;  A box means "this fan is waiting", so the row has to be UNREAD. Infloww marks
;  those with a coral `#ff7c71` dot at the right-hand end of the row, and that dot
;  is what this scans for. The pay-off is that nothing has to notice you replying:
;  the dot goes when you open the conversation, so the box goes with it, on the
;  next tick, with no state kept anywhere.
;
;  Boxing every row instead was the alternative and it is much worse than it
;  sounds. The list is sorted by recency and runs off the bottom of the screen, so
;  every conversation you have already answered would keep a box until it scrolled
;  away — a screen of white frames, none of which need anything.
;
;  ─── WHY THE UNREAD DOT AND NOT THE PINGER'S ANSWER ──────────────────────────
;  services/pinger looks for the same colour and is a much cleverer detector —
;  blob extents, fill ratio, shape profiles. It is also looking at a different
;  thing: the FAN TAB STRIP along the top, where a `#ff7c71` blob might be a tab
;  dot, an overflow badge, or the pink-red ✕ close button it once fired on. In the
;  conversation list there is no ✕ and no badge, and this only ever looks at a
;  narrow band at the right-hand end of a row, so size and height are enough.
;
;  Do NOT copy the pinger's CORAL_TOL of 45 into DotTol. That number is a
;  SUM-OF-CHANNELS distance; PILL_ColorDist here is the per-channel MAXIMUM, so
;  the same 45 is a far looser filter than it looks. The dot is a solid block of
;  exactly #ff7c71 — the pinger measured it identical at every tolerance from 30
;  to 70 — so DotTol wants to be tight, and it ships at 20.
;
;  ─── TWO TICKS, BECAUSE OCR IS THE EXPENSIVE HALF ────────────────────────────
;  Finding the dots is one BitBlt and a walk over a 46px-wide band: sub-millisecond
;  memory reads, for the reasons written up at length in pill_scan.ahk. Reading the
;  timestamps is Windows OCR, which is tens of milliseconds.
;
;  So they run at different rates. The FAST tick (ScanMs, 400ms) only finds dots,
;  and its job is mostly to notice that the list SCROLLED — the moment the set of
;  dot positions changes, every box is hidden immediately, because a box that
;  lingers half a second on the row that slid into its place is worse than no box
;  at all. The FULL pass (PollMs, 5s) is the one that OCRs the stamps, does the
;  arithmetic and repaints, and it also runs straight away whenever the fast tick
;  saw something move.
;
;  ─── WHAT A BOX IS ───────────────────────────────────────────────────────────
;  One window per box, hollowed out with SetWindowRgn — an outer rectangle minus
;  an inner one — so the window IS the frame and there is nothing in the middle to
;  see through. No chroma key, which tab_marks.ahk explains at length is where its
;  three worst bugs came from.
;
;  It is CLICK-THROUGH (WS_EX_TRANSPARENT), and here that is not a preference the
;  way it is for the tab bars: a box surrounds a conversation row, and the whole
;  point of the row is that you click it. It also carries WS_EX_NOACTIVATE, so
;  nothing it does can take focus off the box you are typing in, and
;  WDA_EXCLUDEFROMCAPTURE, so the next tick's BitBlt reads Infloww's dots and not
;  MMA's own borders.
;
;  ─── WHAT THIS DELIBERATELY DOES NOT DO ──────────────────────────────────────
;  It does not click, open, reply, sort or reorder anything, and it never writes a
;  model setting. It reads pixels and paints frames over them. If it is wrong, it
;  is wrong in a way you can see and ignore.
; ═══════════════════════════════════════════════════════════════════════════════

; The timers below are the only thing keeping this alive once auto-exec ends, and
; the fast one is stopped whenever the overlay is hidden. Without this the script
; would exit the moment you toggled it off.
Persistent

CFG := MMA_CFG

; ── seeding ───────────────────────────────────────────────────────────────────
;  Written out on first run so the whole section is visible and hand-editable,
;  the same way stats_overlay.ahk seeds its own. String literals rather than the
;  parsed values: writing a parsed float back leaves 0.29999… in the file.
;
;  Region is seeded EMPTY on purpose. There is no sensible default for it — it is
;  a rectangle on your screen, on your monitor, at your window size — and a made-up
;  one would put boxes over whatever happens to be at those coordinates. Empty
;  means "not calibrated", which RB_FullPass refuses to act on and Settings shows
;  as a red line telling you which button to press.
if (IniRead(CFG, "ReplyBox", "RowH", "") = "") {
    for k, v in Map("Region","", "WinMatch","Infloww Messages", "RowH","105"
                  , "RowOffsetY","-1", "BorderW","4", "TimeBandW","130"
                  , "DotBandW","46", "ExcludeFromCapture","1"
                  , "DotColor","FF7C71", "DotTol","20", "DotStep","2"
                  , "DotMinPx","4", "DotMaxPx","400", "DotMaxH","24", "DotGap","6"
                  , "PollMs","5000", "ScanMs","400", "OcrScale","2"
                  , "Visible","1"
                  , "Tier1","3,FFD24A", "Tier2","4,FF4A4A"
                  , "Tier3","6,FF7AD9", "Tier4","10,FFFFFF")
        try IniWrite(v, CFG, "ReplyBox", k)
    LOGI("replybox", "seeded [ReplyBox] defaults into mass_gui.cfg — the list"
                   . " region is still empty, so nothing is painted until you"
                   . " calibrate it under Settings > General > Reply timers")
}

SetTitleMatchMode 2      ; WinMatch is a substring criterion — the title has a suffix

; ── live state ────────────────────────────────────────────────────────────────
global _rbBoxes   := []      ; the window pool: [{gui, w, h, col}]
global _rbShown   := 0       ; how many of them are currently visible
global _rbSig     := ""      ; signature of the last dot scan, to notice a scroll
global _rbNextFull := 0      ; A_TickCount at which the next OCR pass is due
global _rbVisible := true    ; the layer's own on/off, remembered in the cfg
global _rbWarned  := false   ; has the "not calibrated" bail already been logged?
global _rbCfg     := 0       ; the last RB_Cfg()
global _rbCfgAt   := 0       ; A_TickCount when it was read

; ── configuration ─────────────────────────────────────────────────────────────
;  Re-read periodically rather than once at startup, which is what lets
;  calibrating the region or changing a colour take effect on its own instead of
;  needing Tools ▸ Restart.
;
;  Behind a TTL, and on a clock OF ITS OWN rather than on the full pass's. RB_Cfg
;  is twenty-odd IniReads plus one per tier, so at ScanMs it would be well over a
;  hundred file reads a second — forever — to notice a colour you change twice a
;  year.
;
;  Tying it to _rbNextFull was the obvious way to do that and it was wrong, in a
;  way worth recording: every early return in RB_Tick — the layer hidden, Infloww
;  not in front, the region off-screen, the grab failing — skips RB_FullPass, and
;  RB_FullPass is the only thing that moves _rbNextFull. So the "is a pass due?"
;  test stayed true on every tick and the re-read ran at ScanMs after all, in
;  precisely the states MMA spends most of its time in: another window in front,
;  or a fresh install with nothing calibrated yet.
RB_CfgCached() {
    global _rbCfg, _rbCfgAt
    if (_rbCfg && A_TickCount - _rbCfgAt < _rbCfg.pollMs)
        return _rbCfg
    _rbCfg   := RB_Cfg()
    _rbCfgAt := A_TickCount
    return _rbCfg
}

RB_Cfg() {
    global CFG
    d := RBS_Defaults()
    rowH := Max(8, LOG_IniInt(CFG, "ReplyBox", "RowH", d.rowH))
    c := {win:      Trim(IniRead(CFG, "ReplyBox", "WinMatch", "Infloww Messages")),
          rowH:     rowH,
          rowOffY:  RB_RowOffset(rowH),
          ; Clamped away from zero: a border of 0 is a window with no frame at
          ; all, which reads as the feature being broken rather than as a setting.
          border:   Max(1,  Min(24, LOG_IniInt(CFG, "ReplyBox", "BorderW", d.border))),
          timeBand: Max(24, LOG_IniInt(CFG, "ReplyBox", "TimeBandW", 130)),
          ; 1 by default. It keeps the boxes out of screen capture, which is what
          ; stops the next tick's own BitBlt reading MMA's borders instead of
          ; Infloww's dots — but it also means the boxes do not appear in a
          ; screenshot, so there is no way to show anyone what you are looking at.
          ; Set 0 when you need that. Safe with the shipped palette: the nearest
          ; tier colour to the coral is red, 50 away by PILL_ColorDist against a
          ; DotTol of 20. Pick a coral-ish tier of your own and it stops being.
          hide:     LOG_IniInt(CFG, "ReplyBox", "ExcludeFromCapture", 1),
          ; A poll faster than a second buys nothing — the number it recomputes
          ; changes once a minute — and pays for it in an OCR per tick.
          pollMs:   Max(1000, LOG_IniInt(CFG, "ReplyBox", "PollMs",  5000)),
          scanMs:   Max(100,  LOG_IniInt(CFG, "ReplyBox", "ScanMs",   400)),
          ocrScale: Max(1,  Min(6, LOG_IniInt(CFG, "ReplyBox", "OcrScale", 2))),
          ; Everything the shared scan needs, in the shape RBS_FindDots takes.
          dot:      RB_DotOpts(d),
          rgn:      RB_Region(),
          tiers:    RB_Tiers()}
    return c
}

; The dot-scan options, defaulted from RBS_Defaults so the service and the
; Settings row calibrator cannot fall back to different numbers.
RB_DotOpts(d) {
    global CFG
    return {color: RB_DotRGB(),
            tol:   Max(0, LOG_IniInt(CFG, "ReplyBox", "DotTol",   d.tol)),
            band:  Max(8, LOG_IniInt(CFG, "ReplyBox", "DotBandW", d.band)),
            step:  Max(1, Min(4, LOG_IniInt(CFG, "ReplyBox", "DotStep", d.step))),
            minPx: Max(1, LOG_IniInt(CFG, "ReplyBox", "DotMinPx", d.minPx)),
            maxPx: Max(1, LOG_IniInt(CFG, "ReplyBox", "DotMaxPx", d.maxPx)),
            maxH:  Max(2, LOG_IniInt(CFG, "ReplyBox", "DotMaxH",  d.maxH)),
            gap:   Max(1, LOG_IniInt(CFG, "ReplyBox", "DotGap",   d.gap))}
}

; How far below the top of its row the unread dot sits, in pixels.
;
; -1 means "I have not been told", and then the dot is assumed to be halfway down
; — which is what the boxes did before there was a setting at all. It is not a
; good assumption: on Infloww the dot shares a line with the timestamp, which sits
; below the fan's name, so the true offset is a few pixels past halfway and every
; box came out that much high. "Calibrate a row…" replaces the guess with a
; measurement; this fallback only has to be sane until somebody presses it.
RB_RowOffset(rowH) {
    global CFG
    v := LOG_IniInt(CFG, "ReplyBox", "RowOffsetY", -1)
    if (v < 0)
        return rowH // 2
    ; Clamped INSIDE the row. A hand-edited offset larger than the row height
    ; would hang the box entirely above the dot it was drawn for, which looks like
    ; the boxes landing on the wrong conversations rather than like a bad number.
    return Min(v, rowH)
}

; The unread dot's colour as 0xRRGGBB. Falls back to Infloww's measured #ff7c71
; rather than to 0, which would be black and would match the list background in
; every row at any usable tolerance.
RB_DotRGB() {
    global CFG
    hex := RB_CleanHex(IniRead(CFG, "ReplyBox", "DotColor", "FF7C71"))
    if (hex = "") {
        LOGW("replybox", "[ReplyBox] DotColor is not a six-digit hex colour —"
                       . " falling back to FF7C71, Infloww's unread coral")
        return 0xFF7C71
    }
    try return Integer("0x" hex)
    return 0xFF7C71
}

; "x,y,w,h" → {x,y,w,h} in the target window's CLIENT coordinates, or 0.
;
; Client, not screen, for the same reason tab_marks.ahk stores its bars that way:
; move the window and the region has to come with it. A maximised window's rect
; also starts at -8,-8, which is exactly the offset that would put every box a few
; pixels off its row.
RB_Region() {
    global CFG
    raw := Trim(IniRead(CFG, "ReplyBox", "Region", ""))
    if (raw = "")
        return 0
    p := StrSplit(raw, ",")
    if (p.Length < 4) {
        LOGW("replybox", "[ReplyBox] Region is not 'x,y,w,h' — ignored (" raw ")")
        return 0
    }
    r := {x: LOG_Int(Trim(p[1]), 0, "[ReplyBox] Region x"),
          y: LOG_Int(Trim(p[2]), 0, "[ReplyBox] Region y"),
          w: LOG_Int(Trim(p[3]), 0, "[ReplyBox] Region w"),
          h: LOG_Int(Trim(p[4]), 0, "[ReplyBox] Region h")}
    if (r.w < 40 || r.h < 20) {
        LOGW("replybox", "[ReplyBox] Region is " r.w "x" r.h ", too small to hold a"
                       . " conversation row — ignored. Re-calibrate it under"
                       . " Settings > General > Reply timers.")
        return 0
    }
    return r
}

; Tier1..TierN → a sorted [{mins, col}]. Stops at the first missing number, so
; the list is contiguous and deleting Tier2 does not silently orphan Tier3.
RB_Tiers() {
    global CFG
    out := []
    i := 1
    loop 32 {
        raw := Trim(IniRead(CFG, "ReplyBox", "Tier" i, ""))
        if (raw = "")
            break
        t := RB_ParseTier(raw)
        if !t
            LOGW("replybox", "[ReplyBox] Tier" i " is not 'minutes,colour' —"
                           . " ignored (" raw ")")
        else
            out.Push(t)
        i++
    }
    return RB_SortTiers(out)
}

; ── the fast tick: has anything moved? ────────────────────────────────────────
;  Runs at ScanMs and does no OCR. Its real job is scroll detection — see the
;  header. The full pass is triggered from here rather than from a timer of its
;  own so that the two can never overlap, which matters because a full pass holds
;  the thread for the length of an OCR.
RB_Tick() {
    global _rbNextFull, _rbSig, _rbVisible, _rbWarned
    if !_rbVisible {
        RB_HideAll()
        return
    }
    cfg := RB_CfgCached()
    ; Not merely "the window exists". These are frames drawn at fixed offsets
    ; inside one window's client area; left up while something else is in front
    ; they would be coloured rectangles floating over somebody else's app. Same
    ; call, and the same reasoning, as MARKS_Sync.
    if !WinActive(cfg.win) {
        RB_HideAll()
        return
    }
    if !cfg.rgn {
        RB_BailUncalibrated(cfg)
        return
    }
    ; A region has appeared, so arm the bail again — calibrating and then clearing
    ; the region later has to be able to say so a second time.
    _rbWarned := false
    sx := 0, sy := 0
    if !RB_RegionOnScreen(cfg, &sx, &sy) {
        RB_HideAll()
        return
    }
    img := PILL_Grab(sx, sy, cfg.rgn.w, cfg.rgn.h)
    if !img {
        LOGV("replybox", "the screen grab failed this tick — nothing repainted")
        return
    }
    rows := RBS_FindDots(img, cfg.dot)
    sig  := RB_Signature(rows)
    if (sig != _rbSig) {
        ; The list moved, or a row was read or arrived. Take the boxes down NOW
        ; and let the full pass below put the right ones back — a stale frame
        ; sitting over the wrong conversation is the one failure this feature
        ; cannot afford, because it is indistinguishable from a correct one.
        RB_HideAll()
        _rbSig := sig
        _rbNextFull := 0
    }
    if (A_TickCount < _rbNextFull)
        return
    RB_FullPass(cfg, sx, sy, rows)
}

; A cheap value that changes whenever the set of unread rows does. Positions are
; rounded to 4px so a one-pixel wobble in the dot's centre — antialiasing, a
; hover state redrawing — does not read as a scroll and blank the layer forever.
RB_Signature(rows) {
    s := ""
    for _, r in rows
        s .= (r.cy // 4) ";"
    return s
}

; The region's top-left in SCREEN coordinates, and whether it is usable at all.
;
; The region was measured against a client area of some size; if the window has
; since been made smaller than the calibration, the bottom of the region is now
; outside the window and grabbing it would read whatever is behind. Refusing is
; the honest answer — the alternative is boxes drawn over the desktop.
RB_RegionOnScreen(cfg, &sx, &sy) {
    ccx := 0, ccy := 0, ccw := 0, cch := 0
    try WinGetClientPos(&ccx, &ccy, &ccw, &cch, cfg.win)
    catch as e {
        LOGV("replybox", "could not read the client rect of '" cfg.win "' — "
                       . LOG_Err(e))
        return false
    }
    if (!ccw || !cch)
        return false
    if (cfg.rgn.x + cfg.rgn.w > ccw || cfg.rgn.y + cfg.rgn.h > cch) {
        LOGV("replybox", "the window is smaller than the calibrated region ("
                       . ccw "x" cch " client vs a region ending at "
                       . (cfg.rgn.x + cfg.rgn.w) "," (cfg.rgn.y + cfg.rgn.h)
                       . ") — nothing painted until it is resized or re-calibrated")
        return false
    }
    sx := ccx + cfg.rgn.x
    sy := ccy + cfg.rgn.y
    return true
}

; Said once, not once per tick. An uncalibrated region is a standing state that
; lasts until somebody presses a button, and at 400ms it would otherwise write
; two and a half lines of log a second forever.
;
RB_BailUncalibrated(cfg) {
    global _rbWarned
    RB_HideAll()
    if _rbWarned
        return
    _rbWarned := true
    LOG_Bail("replybox", "[ReplyBox] Region is not set, so there is nowhere to look."
                       . " Settings > General > Reply timers > 'Calibrate the list…'"
                       . " draws a box round the conversation list and stores it.")
}

; ── the full pass: read the clocks, pick the colours, move the frames ─────────
RB_FullPass(cfg, sx, sy, rows) {
    global _rbNextFull
    _rbNextFull := A_TickCount + cfg.pollMs
    if !rows.Length {
        RB_HideAll()
        return
    }
    stamps := RB_ReadStamps(cfg, sx, sy)
    nowMin := RB_NowMin()
    boxes  := []
    for _, r in rows {
        ; The stamp belongs to the row whose vertical span contains it. Matching
        ; on the ROW rather than on the nearest stamp matters when a row has two
        ; OCR lines in the band — the time and a "2" unread count underneath it —
        ; because nearest-wins would happily award the count's line to the row
        ; below and read "2" as a clock.
        ;
        ; The box hangs off the DOT, offset by rowOffY, not centred on it. The dot
        ; is not in the middle of its row — measured on Infloww it sits a little
        ; BELOW centre, on the same line as the timestamp — so centring drew every
        ; box high by that difference. "Calibrate a row…" measures the offset by
        ; finding the dot inside the box you drew round one conversation, which is
        ; the only way to get it right on a list this file has never seen.
        top := r.cy - cfg.rowOffY
        bot := top + cfg.rowH
        text := RB_StampIn(stamps, top, bot)
        if (text = "")
            continue
        mins := RB_ElapsedMin(text, nowMin)
        col  := RB_Pick(cfg.tiers, mins)
        if (col = "")
            continue
        boxes.Push({top: top, col: col, mins: mins, text: text})
    }
    RB_Place(cfg, sx, boxes)
}

; OCR the timestamp column and hand back [{y, h, text}] in SCREEN coordinates.
;
; ONE call for the whole column, not one per row, and the difference is not small:
; Windows OCR costs tens of milliseconds a call whatever the rectangle, so a
; twelve-row list would be twelve times the price for the same pixels. The result
; carries a bounding rect per line, which is what puts each stamp back on its row.
;
; The band is the right-hand TimeBandW pixels, so the fan's name and the message
; preview are never in the picture. That is worth more than the speed: a preview
; reading "see you at 9:30" is a clock time in the same font as the stamp, and a
; wider box would have made it one.
RB_ReadStamps(cfg, sx, sy) {
    out := []
    rx := sx + cfg.rgn.w - cfg.timeBand
    try {
        res := OCR.FromRect(rx, sy, cfg.timeBand, cfg.rgn.h, {scale: cfg.ocrScale})
        for line in res.Lines {
            t := Trim(line.Text)
            if (t = "")
                continue
            out.Push({y: line.y, h: line.h, text: t})
        }
    } catch as e {
        ; Not fatal and not silent. OCR throws when the Windows language pack is
        ; missing, and a feature that quietly paints nothing forever is one you
        ; report as broken with no idea where to look.
        LOGW("replybox", "could not OCR the timestamp column — no boxes this pass."
                       . " This uses the OCR engine built into Windows; if it is"
                       . " missing, add an English language pack under Settings >"
                       . " Time & language. " LOG_Err(e))
    }
    return out
}

; The stamp for this row's vertical span, or "".
;
; A line COUNTS as inside when its centre is, rather than when the whole box is:
; OCR's bounding rect for "7:45 am" runs a pixel or two past the glyphs at both
; ends, and on a tight RowH that was enough to disqualify every stamp on the list.
;
; A CLOCK TIME WINS over any other line in the same row, which is why this makes
; two passes instead of returning the first hit. Two things put a second line in
; the band: OCR splitting "7:45 am" across lines, and an unread COUNT badge — and
; ocr_grab.ahk documents that Windows OCR returns lines grouped by layout block
; rather than top-to-bottom, so "first one inside the row" is not even reliably
; the upper one. Taking the first would therefore sometimes hand a row's arithmetic
; to its badge. RB_IsStamp refuses a digits-only line outright; this is the other
; half, and between them a row that HAS a readable time always uses it.
RB_StampIn(stamps, top, bot) {
    fallback := ""
    for _, s in stamps {
        cy := s.y + s.h // 2
        if (cy < top || cy >= bot)
            continue
        if (RB_ClockToMin(s.text) >= 0)
            return s.text
        if (fallback = "")
            fallback := s.text
    }
    return fallback
}

; ── the frames ────────────────────────────────────────────────────────────────

; Position, colour and show one frame per boxed row; hide whatever is left over.
;
; The pool is never torn down — windows are created once and thereafter only
; moved. tab_marks.ahk explains what the other way costs: it rebuilt its overlay
; every tick and that, not any one line of it, was the flicker.
RB_Place(cfg, sx, boxes) {
    global _rbBoxes, _rbShown
    w := cfg.rgn.w
    for i, b in boxes {
        while (_rbBoxes.Length < i)
            _rbBoxes.Push(RB_NewBox())
        box := _rbBoxes[i]
        try {
            ; Only when it actually changed. A BackColor write plus the WinRedraw
            ; it needs is a repaint of an always-on-top window sitting over a
            ; compositing browser, and doing it to every box every pass is a
            ; flicker on a five-second cycle for no change at all.
            recolour := (box.col != b.col)
            if recolour {
                box.gui.BackColor := b.col
                box.col := b.col
            }
            WinMove(sx, b.top, w, cfg.rowH, box.gui)
            ; The hollow only has to be re-cut when the SHAPE changes. Re-cutting
            ; it every pass would be two GDI objects per box per five seconds for
            ; a region identical to the one already installed.
            if (box.w != w || box.h != cfg.rowH || box.border != cfg.border) {
                RB_Hollow(box.gui.Hwnd, w, cfg.rowH, cfg.border)
                box.w := w, box.h := cfg.rowH, box.border := cfg.border
            }
            if (box.hide != cfg.hide) {
                RB_ExcludeFromCapture(box.gui.Hwnd, cfg.hide)
                box.hide := cfg.hide
            }
            WinShow(box.gui)
            ; A BackColor change on an already-shown window does not repaint on
            ; its own; a WinMove does.
            if recolour
                WinRedraw(box.gui)
        } catch as e
            LOGV("replybox", "could not place box " i " — " LOG_Err(e))
    }
    i := boxes.Length + 1
    while (i <= _rbBoxes.Length) {
        try WinHide(_rbBoxes[i].gui)
        i++
    }
    if (boxes.Length != _rbShown)
        LOGV("replybox", boxes.Length " row(s) boxed (was " _rbShown ")")
    _rbShown := boxes.Length
}

; One frame window.
;
; -DPIScale is load-bearing, not tidiness. Gui.Show and WinMove multiply their
; coordinates by the display scaling when it is on, and WinGetClientPos does not —
; so on any display above 100% every box would land proportionally down and right
; of the row it belongs to. Same trap, and the same fix, as core/utils.ahk,
; screen/ocr_grab.ahk and screen/tab_marks.ahk.
;
; WS_EX_TRANSPARENT (0x20) is NOT optional here, unlike on the tab bars where it
; is a cfg key. A box surrounds a conversation row and the entire purpose of that
; row is that you click it; a frame the mouse can hit is a frame that eats the
; click that opens the chat.
;
; WS_EX_NOACTIVATE (0x08000000): nothing this draws may ever take focus off the
; message you are typing.
RB_NewBox() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -SysMenu -DPIScale"
           . " +E0x08000000 +E0x20")
    g.MarginX := 0, g.MarginY := 0
    g.BackColor := "FFFFFF"
    ; Created hidden and positioned a moment later, so a new box never shows at
    ; 0,0 for a frame on its way to the row it belongs to.
    g.Show("NoActivate Hide x0 y0 w10 h10")
    ; hide := -1, never 0 or 1, so RB_Place's "has this changed?" test always
    ; fires once on a new window and applies whatever the cfg actually says.
    return {gui: g, w: 0, h: 0, border: 0, hide: -1, col: "FFFFFF"}
}

; Cut the middle out of the window, leaving a frame `t` pixels thick.
;
; RGN_DIFF of an outer rectangle and an inner one. This is what makes a solid
; coloured window read as a border: there is no transparency involved anywhere, so
; none of the chroma-key failures documented in tab_marks.ahk — the magenta flash,
; the black-painted glyph, the key that would not take — can happen here.
;
; SetWindowRgn takes OWNERSHIP of the region on success, so the handle must not be
; deleted afterwards; on failure it does not, and it must.
RB_Hollow(hwnd, w, h, t) {
    if (w <= t * 2 || h <= t * 2) {
        ; A frame thicker than the row is a solid block that hides the message it
        ; is drawing attention to. Leave the window unshaped and say so.
        LOGW("replybox", "BorderW " t " is too thick for a " w "x" h " row — the box"
                       . " would be solid. Lower [ReplyBox] BorderW or raise RowH.")
        return
    }
    outer := DllCall("gdi32\CreateRectRgn", "int", 0, "int", 0,
                     "int", w, "int", h, "ptr")
    inner := DllCall("gdi32\CreateRectRgn", "int", t, "int", t,
                     "int", w - t, "int", h - t, "ptr")
    if (!outer || !inner) {
        if outer
            DllCall("gdi32\DeleteObject", "ptr", outer)
        if inner
            DllCall("gdi32\DeleteObject", "ptr", inner)
        return
    }
    DllCall("gdi32\CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner,
            "int", 4)                                    ; RGN_DIFF
    DllCall("gdi32\DeleteObject", "ptr", inner)
    if !DllCall("SetWindowRgn", "ptr", hwnd, "ptr", outer, "int", 1)
        DllCall("gdi32\DeleteObject", "ptr", outer)      ; refused — still ours
}

; Keep the boxes out of MMA's own screen reads.
;
; WDA_EXCLUDEFROMCAPTURE (0x11) leaves a window out of screen capture while
; keeping it visible to you. It matters more here than it looks: the fast tick
; BitBlts the region every 400ms looking for coral, and a box's own border runs
; along the row edges within pixels of the dot it was drawn for. Excluding them
; means the scan reads Infloww and never MMA — a detector that fed on its own
; output would latch, and it would look exactly like a working one.
;
; Windows 10 2004 and later, and a request to the compositor rather than a
; guarantee. Failure is logged at VERB and changes nothing else — same call, and
; the same caveat, as MARKS_ExcludeFromCapture.
;
; `on` comes from [ReplyBox] ExcludeFromCapture, because this has a cost nobody
; expects until they hit it: with it on, THE BOXES DO NOT APPEAR IN SCREENSHOTS.
; That is the feature working — but it also means you cannot show anyone what you
; are looking at, or send a picture of a misaligned box to whoever is fixing it.
; 0 puts them in captures at the price of MMA being able to see its own borders.
RB_ExcludeFromCapture(hwnd, on := 1) {
    try {
        ; WDA_EXCLUDEFROMCAPTURE (0x11) or WDA_NONE (0) — the same call sets and
        ; clears it, so turning it back off does not need the window rebuilt.
        if !DllCall("SetWindowDisplayAffinity", "ptr", hwnd, "uint", on ? 0x11 : 0)
            LOGV("replybox", "SetWindowDisplayAffinity refused — the boxes will"
                           . " appear in screen captures, including MMA's own")
    } catch as e
        LOGV("replybox", "SetWindowDisplayAffinity is not available here — "
                       . LOG_Err(e))
}

; Hidden, not destroyed. Tabbing away from Infloww and back is constant, and
; tearing eight windows down for it is exactly the cost this shape avoids.
RB_HideAll() {
    global _rbBoxes, _rbShown
    if !_rbShown
        return
    for _, b in _rbBoxes
        try WinHide(b.gui)
    _rbShown := 0
}

; ── the toggle ────────────────────────────────────────────────────────────────
;  One key, and it is a SHOW/HIDE rather than a start/stop: the process staying up
;  is what makes turning it back on instant, and the Tools window is where you
;  stop it for real. Remembered in the cfg, so it comes back the way you left it.
RB_Toggle(*) {
    global _rbVisible, CFG, _rbSig, _rbNextFull
    _rbVisible := !_rbVisible
    try IniWrite(_rbVisible ? 1 : 0, CFG, "ReplyBox", "Visible")
    if _rbVisible {
        ; Forget what the last scan saw, so the next tick treats everything as new
        ; and repaints from scratch instead of matching a stale signature and
        ; deciding there is nothing to do.
        _rbSig := "", _rbNextFull := 0
        RB_Toast("Reply timers ON")
    } else {
        RB_HideAll()
        RB_Toast("Reply timers OFF")
    }
    LOGI("replybox", "toggled " (_rbVisible ? "ON" : "OFF") " from "
                   . HK_Key("gui.toggleReplyBox"))
}

RB_Toast(text) {
    ToolTip(text)
    SetTimer(RB_ClearToast, -1400)
}
RB_ClearToast() {
    ToolTip()
}

; ── start ─────────────────────────────────────────────────────────────────────
_rbVisible := LOG_IniInt(CFG, "ReplyBox", "Visible", 1) ? true : false
HK_Bind("gui.toggleReplyBox", RB_Toggle)
LOGI("replybox", "started — watching '"
               . Trim(IniRead(CFG, "ReplyBox", "WinMatch", "Infloww Messages"))
               . "', " (_rbVisible ? "visible" : "hidden (" HK_Key("gui.toggleReplyBox")
                                              . " shows it)"))
SetTimer(RB_Tick, Max(100, LOG_IniInt(CFG, "ReplyBox", "ScanMs", 400)))
