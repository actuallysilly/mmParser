#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "rail_scan.ahk"
#Include "../core/dpi.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  fansly_scan.ahk — the Fansly rail, as geometry. Reads config, reads pixels,
;                    writes nothing.
; ───────────────────────────────────────────────────────────────────────────────
;  THREE things need to agree about the Fansly rail down to the pixel:
;
;    • screen/fansly_detector.ahk   the background service that OCRs the name
;    • core/fansly_model.ahk        the hotkey path, reached from #HotIf
;    • tools/fansly_probe.ahk       the calibrator you tune the numbers with
;
;  and they agree by all including THIS file. That is not tidiness. On the
;  Infloww side the service and the hotkey path each grew their own copy of the
;  [Detector] block, and the two drifted; a calibrator with a third copy is worse
;  still, because you tune numbers that satisfy the tool while the service reads
;  the strip differently and stays wrong. One reader, three callers.
;
;  ─── THE GEOMETRY, AND WHY IT IS SHAPED LIKE THIS ────────────────────────────
;
;      RegionX ─┐
;      RegionY ─┼──► ┌───────────────┐  ◄─ row 1 top
;                    │   ( avatar )  │
;                    │   KB FANS…    │     RowHeight
;                    └───────────────┘
;                                          RowPitch (top of row 1 → top of row 2)
;                    ┌───────────────┐  ◄─ row 2 top
;               ┌───►│▓▓ ( avatar )  │     ▓▓ = SampleX..SampleX+SampleW,
;               │    │▓▓ Luxdo Fa…   │          the flat left margin of the card
;      the only │    └───────────────┘
;      pixels ──┘
;      we test
;
;  RegionH is deliberately NOT a setting: it is RowPitch × Rows. One less number
;  to get wrong, and the two that are left (origin and pitch) are the two the
;  probe can actually measure for you.
;
;  SampleX/SampleW is the whole reason this works — see the header of
;  rail_scan.ahk. The card contains a photograph; the left margin does not. Every
;  colour test below is confined to that margin, and widening it "to get a
;  stronger signal" is how an unselected model with a dark avatar starts reading
;  as selected.
;
;  ─── WHY THE TOLERANCE IS TIGHTER THAN INFLOWW'S ─────────────────────────────
;  Infloww lights its active tab with #2B2C30 on a #0D0D0D strip — 30 levels of
;  grey apart, so GreyTol=22 is comfortable. Fansly's selected card is a few
;  levels lighter than the rail behind it and nothing more. CardTol therefore
;  defaults small, and the failure mode of setting it too high is not "slightly
;  noisy": it is every row matching, the run spanning the rail, RAIL_Scan
;  refusing, and detection going permanently silent. Run the probe, use the
;  numbers it prints.
;
;  ─── EVERY DEFAULT BELOW IS A PLACEHOLDER ────────────────────────────────────
;  They are read off a screenshot of the rail, not off your screen: the ratios
;  (pitch ≈ 97, card ≈ 88 tall, rail ≈ 87 wide, avatar centred) are real, the
;  absolute screen coordinates cannot be. RegionX/RegionY especially are 0,0 and
;  will be wrong on every machine. Run tools/fansly_probe.ahk before expecting a
;  single correct answer from this.
; ═══════════════════════════════════════════════════════════════════════════════

; An int from [Fansly], via the logging reader. LOG_IniInt and not Integer(): this
; file is reached from #HotIf, which AHK re-evaluates on EVERY KEYSTROKE, so one
; hand-typed `RowPitch=ninety` would not be a mis-tuned rail — it would be an
; error dialog per character typed into a fan's chat. Same reasoning as the note
; on _IniInt in core/active_model.ahk, and the same reason the colour below goes
; through LOG_Int rather than being trusted.
_FAN_Int(key, default) {
    return LOG_IniInt(MMA_CFG, "Fansly", key, default, "fansly.cfg")
}

; The [Fansly] block, as numbers. Callers cache it — see FanslyStatus() — because
; an IniRead per keystroke is exactly the sort of cost that shows up as "MMA feels
; laggy" and never as an error.
FanslyCfg() {
    hex  := Trim(IniRead(MMA_CFG, "Fansly", "CardColor", "0x2B2B2F"))
    rail := Trim(IniRead(MMA_CFG, "Fansly", "RailColor", "0x1A1A1C"))
    rows := _FAN_Int("Rows", 0)
    if (rows < 1) {
        ; Default to however many model slots exist, clamped the same way
        ; MMA_ModelNames() clamps it. Read from [Settings] rather than taking
        ; MASS_MODELS as a global: the background service includes this file and
        ; deliberately does not include store.ahk, and a service that dies at load
        ; over an unset global is a service with no window and no error to show.
        rows := Max(1, Min(LOG_IniInt(MMA_CFG, "Settings", "ModelCount", 3,
                                      "fansly.cfg"), 12))
    }
    return {
        x:      _FAN_Int("RegionX",   0),     ; rail left edge, screen px
        y:      _FAN_Int("RegionY",   0),     ; TOP OF ROW 1, not top of the rail
        w:      _FAN_Int("RegionW",  87),
        ; ── anchored mode ────────────────────────────────────────────────────
        ;  RegionX/RegionY above are ABSOLUTE SCREEN COORDINATES, and that is a
        ;  bug waiting on a mouse drag: the Fansly window floats, so the day it
        ;  is moved or resized every number above points at bare rail and
        ;  detection goes silent with r1=0 r2=0 r3=0. Measured 2026-08-27 — the
        ;  window was nudged from 1802x2577 to 1800x3140 and that is exactly
        ;  what happened.
        ;
        ;  Anchor=window replaces both of them:
        ;
        ;    x  comes from the WINDOW, not the screen — the rail sits at
        ;       RailOffsetX into the Fansly window and stays there, which is the
        ;       one offset that did hold across the move.
        ;    y  is not stored AT ALL. The card is FOUND by sweeping the rail
        ;       column (FanslyLocateCards), because the vertical offset does NOT
        ;       hold: the same rail sat at window-relative y313 floating and
        ;       y200 snapped. Anything stored is a number that is right until the
        ;       window changes shape.
        ;
        ;  Sweeping also gets rail scrolling for free, which the fixed-slot path
        ;  never could.
        anchor: (StrLower(Trim(IniRead(MMA_CFG, "Fansly", "Anchor",
                                       "screen"))) = "window"),
        ox:     _FAN_Int("RailOffsetX",     1),   ; rail's x offset INTO the window
        swTop:  _FAN_Int("SweepTop",        0),   ; where to start looking, y
        swH:    _FAN_Int("SweepHeight",  1400),   ; and how far down
        ; Coarser than ScanStep on purpose. This walks the whole rail column on
        ; the keystroke path, and a disc is ~86px across — at step 4 it still
        ; lands ~21x21 hits on a card, which is a hundred times more evidence
        ; than the decision needs.
        swStep: _FAN_Int("SweepStep",       4),
        ; How close the runner-up card may score before this refuses to answer.
        ; Percent of the winner. See FanslyLocateCards for why refusing is the
        ; only honest option when two cards score alike.
        swAmb:  _FAN_Int("SweepAmbiguity", 75),
        ; How tall a run must be, as a percentage of RowHeight, to be a card.
        ;
        ; This is the filter that keeps the CONVERSATION TAB STRIP out of the
        ; answer. It runs along the top of the window in the same grey as the
        ; card, it is wide enough to clear MinCard, and measured it forms a 48px
        ; run against the disc's 84 — so with a loose bound it becomes a second
        ; "card", scores 242 against the real card's 258, and the ambiguity guard
        ; below correctly refuses to choose. The disc has a known diameter; a
        ; strip does not. Bounding on it is what separates them.
        swMin:  _FAN_Int("SweepMinPct",  75),
        swMax:  _FAN_Int("SweepMaxPct", 140),
        rows:   rows,
        pitch:  _FAN_Int("RowPitch", 97),
        rowH:   _FAN_Int("RowHeight", 88),
        ; How far into a row to start testing. Rounded corners are neither card
        ; colour nor rail colour, and they sit at exactly the rows a naive scan
        ; reaches first.
        inset:  _FAN_Int("RowInset",  10),
        sx:     _FAN_Int("SampleX",   10),    ; offset from RegionX — see the map
        sw:     _FAN_Int("SampleW",   10),
        tol:    _FAN_Int("CardTol",   12),
        min:    _FAN_Int("MinCard",   40),    ; px below which "nothing is lit"
        step:   _FAN_Int("ScanStep",   2),
        gap:    _FAN_Int("GapTol",    10),
        ; The label rectangle inside a row, for OCR. The name sits UNDER the
        ; avatar on Fansly, unlike Infloww where it is the tab itself, so this is
        ; a band near the bottom of the card rather than the whole card.
        lx:     _FAN_Int("LabelX",     2),
        lw:     _FAN_Int("LabelW",    83),
        ly:     _FAN_Int("LabelY",    66),
        lh:     _FAN_Int("LabelH",    20),
        scale:  _FAN_Int("OcrScale",   4),
        pollMs: _FAN_Int("PollMs",   500),
        rgb:    LOG_Int(RegExMatch(hex,  "i)^0x") ? hex  : "0x" hex,
                        0x2B2B2F, "[Fansly] CardColor"),
        bg:     LOG_Int(RegExMatch(rail, "i)^0x") ? rail : "0x" rail,
                        0x1A1A1C, "[Fansly] RailColor"),
        ; The foreground gate. It MUST default to something, never to "": every
        ; scan below is at FIXED SCREEN COORDINATES and with no gate it happily
        ; measures whatever window is sitting at those pixels. That is not
        ; hypothetical — the Infloww detector once read VS Code's menu bar and
        ; filed "File Edit Selection View Go R" as a model name, which then got
        ; auto-claimed into a slot and gated that model's keys off permanently.
        ;
        ; It is also what keeps the two platforms apart at runtime: Fansly
        ; answers only while the Fansly window is in front, Infloww only while
        ; Infloww is, and neither is ever asked to guess about the other.
        ; ── the visual cue ───────────────────────────────────────────────────
        ; A rectangle INSIDE the focused window, in window-relative coordinates,
        ; and a word that appears there on Fansly and nowhere else. See
        ; FanslyCueSays below for why this exists at all; CueW=0 (the shipped
        ; default) leaves it switched off and the title gate in charge.
        ;
        ; Window-relative, unlike every other number in this block, and that is
        ; the point: the cue has to answer "which site is this WINDOW" on a setup
        ; where both sites are the same executable, both windows carry the same
        ; title, and either one can be on either monitor. A screen coordinate
        ; cannot answer that question; an offset into the window can.
        cueX:     _FAN_Int("CueX", 0),
        cueY:     _FAN_Int("CueY", 0),
        cueW:     _FAN_Int("CueW", 0),
        cueH:     _FAN_Int("CueH", 0),
        cueScale: _FAN_Int("CueScale", 3),
        cueMs:    _FAN_Int("CueMs", 900),
        cue:      Trim(IniRead(MMA_CFG, "Fansly", "CueText", "")),
        ; The word that must NOT be there. Infloww's own sidebar says "All
        ; inboxes", which contains "Inbox" — so the obvious cue matches both
        ; sites, and the negative test is what makes it a discriminator rather
        ; than a coin flip that happens to be right half the time.
        cueNot:   Trim(IniRead(MMA_CFG, "Fansly", "CueNotText", "")),
        win:    Trim(IniRead(MMA_CFG, "Fansly", "WinMatch", "Fansly"))}
}

; Write the block back on first run so the numbers are visible and editable
; instead of being invisible defaults buried in this file. Called by the service
; and by the probe; harmless to call twice.
FanslySeedCfg() {
    if (IniRead(MMA_CFG, "Fansly", "RowPitch", "") != "")
        return
    c := FanslyCfg()
    for k, v in Map("RegionX",c.x, "RegionY",c.y, "RegionW",c.w, "Rows",c.rows,
                    "RowPitch",c.pitch, "RowHeight",c.rowH, "RowInset",c.inset,
                    "SampleX",c.sx, "SampleW",c.sw,
                    "CardColor",Format("0x{:06X}", c.rgb),
                    "RailColor",Format("0x{:06X}", c.bg),
                    "CardTol",c.tol, "MinCard",c.min, "ScanStep",c.step,
                    "GapTol",c.gap, "LabelX",c.lx, "LabelW",c.lw,
                    "LabelY",c.ly, "LabelH",c.lh, "OcrScale",c.scale,
                    "PollMs",c.pollMs, "WinMatch",c.win,
                    "Anchor",(c.anchor ? "window" : "screen"),
                    "RailOffsetX",c.ox, "SweepTop",c.swTop,
                    "SweepHeight",c.swH, "SweepStep",c.swStep,
                    "SweepAmbiguity",c.swAmb,
                    "SweepMinPct",c.swMin, "SweepMaxPct",c.swMax)
        try IniWrite(v, MMA_CFG, "Fansly", k)
}

; ── which site am I looking at? ──────────────────────────────────────────────
;  "", "fansly" or "other". "" means no cue is configured (or it could not be
;  read), and the caller falls back to the title gate.
;
;  ─── WHY A TITLE CANNOT ANSWER THIS ─────────────────────────────────────────
;  The assumption underneath WinMatch was that each site is its own application
;  with its own window title. On a real desk it is not. Infloww shows BOTH sites,
;  so the two windows are the same executable, both titled "Infloww Messages",
;  one per monitor — and the word "Fansly" that WinMatch looks for turns up in
;  the OnlyFans window as well, because a model is NAMED "KB FANSLY". Every test
;  available to WinActive returns the same answer for two windows that are
;  showing completely different interfaces.
;
;  What actually differs is what is DRAWN. The Fansly view heads its conversation
;  list with "Inbox"; the OnlyFans view puts "All inboxes", "Online Fans" and a
;  Fan-insights panel in the same space. So: read the pixels, in the window, at a
;  fixed offset from its own top-left corner.
;
;  ─── THE NEGATIVE TEST IS NOT OPTIONAL ──────────────────────────────────────
;  "All inboxes" CONTAINS "Inbox". A cue of "Inbox" alone therefore fires on the
;  OnlyFans window too, and being wrong in that direction is the expensive one —
;  ActiveModelStatus asks Fansly first, so a false positive takes the shared keys
;  away from the site you are actually working in. CueNotText is checked first
;  and wins.
;
;  ─── CACHED, BECAUSE THIS IS ON THE KEYSTROKE PATH ──────────────────────────
;  Everything in this file is reachable from #HotIf, which AHK re-evaluates on
;  every key you type. An OCR per keystroke would be unusable, so the answer is
;  cached per window handle for CueMs. A window does not change which site it is
;  showing without you clicking something, and a cache keyed on the handle is
;  invalidated the instant you switch windows — which is the only moment the
;  answer can change out from under you.
global _FAN_CUE_T := 0        ; when the cached answer was read
global _FAN_CUE_R := ""       ; the cached answer
global _FAN_CUE_H := 0        ; the window it belongs to
global _FAN_CUE_TXT := ""     ; what OCR read, for the overlay to show

FanslyCueSays(cfg := 0) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    global _FAN_CUE_T, _FAN_CUE_R, _FAN_CUE_H, _FAN_CUE_TXT
    if !cfg
        cfg := FanslyCfg()
    if (cfg.cueW < 4 || cfg.cueH < 4 || cfg.cue = "")
        return ""
    hwnd := WinExist("A")
    if !hwnd
        return ""
    now := A_TickCount
    if (hwnd = _FAN_CUE_H && now - _FAN_CUE_T < cfg.cueMs)
        return _FAN_CUE_R
    ; IsSet, because this file is included by the GUI as well as the engine and
    ; the GUI has no reason to load a 1500-line OCR vendor file. A process that
    ; cannot read the cue must say "no answer" and let the title gate decide, not
    ; throw on a global that was never defined.
    if !IsSet(OCR)
        return ""
    wx := 0, wy := 0, ww := 0, wh := 0
    try WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    catch
        return ""
    txt := ""
    try txt := OCR.FromRect(wx + cfg.cueX, wy + cfg.cueY, cfg.cueW, cfg.cueH,
                            {scale: cfg.cueScale, grayscale: 1}).Text
    txt := Trim(RegExReplace(txt, "\s+", " "))
    res := "other"
    if (cfg.cueNot != "" && InStr(txt, cfg.cueNot))
        res := "other"
    else if InStr(txt, cfg.cue)
        res := "fansly"
    _FAN_CUE_H := hwnd, _FAN_CUE_T := now, _FAN_CUE_R := res, _FAN_CUE_TXT := txt
    return res
}

; What the cue last read, verbatim. For the debug overlay: "the cue says other"
; is unactionable, "the cue read 'All inboxes'" is the whole answer.
FanslyCueText() {
    global _FAN_CUE_TXT
    return _FAN_CUE_TXT
}

; Is the Fansly window actually in front? Nothing below is safe without this.
;
; The cue decides when one is configured, and nothing else gets a vote — see
; FanslyCueSays for why a title is not evidence here. Without a cue this falls
; back to the original title test plus PILL_ActiveHolds, which asks the one
; question a title cannot: is the window in front actually covering the rail we
; are about to scan? That is enough when the two sites are separate applications
; or live on separate monitors, and it is not enough when they are two windows of
; one program — which is why the cue exists.
FanslyWindowUp(cfg := 0) {
    if !cfg
        cfg := FanslyCfg()
    cue := FanslyCueSays(cfg)
    if (cue != "")
        return cue = "fansly"
    if (cfg.win = "" || !WinActive(cfg.win))
        return false
    ; PILL_ActiveHolds asks "is the window in front actually covering the rail we
    ; are about to scan". Under Anchor=window that question answers itself — the
    ; rail is DEFINED as an offset into the active window, so the test is vacuous
    ; and the title is all that is left. Which is why the cue is not optional
    ; here: see FanslyCueSays for what a title is worth when both sites are one
    ; executable with one title.
    if cfg.anchor
        return true
    return PILL_ActiveHolds(cfg.x, cfg.y, cfg.w, cfg.pitch * cfg.rows)
}

; Grab the whole rail once. Everything else reads from the returned buffer.
;
; ONE BitBlt, then memory reads — see pill_scan.ahk's header for the measurements
; that forced this. The height is derived (pitch × rows) rather than configured,
; per the note at the top.
FanslyGrabRail(cfg := 0) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    if !cfg
        cfg := FanslyCfg()
    rect := FanslyRailRect(cfg)
    if !rect
        return 0
    return PILL_Grab(rect.x, rect.y, rect.w + 1, rect.h + 1)
}

; The y range row `i` occupies, inset at both ends so a neighbour's edge or this
; card's own rounded corner cannot contribute.
FanslyRowRange(i, cfg) {
    y1 := cfg.y + (i - 1) * cfg.pitch
    return {y1: y1 + cfg.inset, y2: y1 + cfg.rowH - cfg.inset}
}

; The x band that is tested for every row: the card's flat left margin, and
; nothing else. See the header, and rail_scan.ahk's.
FanslySampleBand(cfg) {
    return {x1: cfg.x + cfg.sx, x2: cfg.x + cfg.sx + cfg.sw}
}

; ── anchored mode ────────────────────────────────────────────────────────────

; Where the rail is RIGHT NOW, derived from the window rather than remembered.
;
; Anchored to the ACTIVE window, and that is exact rather than convenient:
; nothing below is ever reached unless FanslyWindowUp said the Fansly window is
; in front, and "in front" means active. The cue already works this way and for
; the same reason (see FanslyCueSays) — an offset into the window is the only
; thing that survives the window being somewhere else.
;
; Returns 0 when there is no active window to anchor to, which callers must treat
; as "no answer" rather than falling back to the stored coordinates: a stale
; absolute rect is how the wrong monitor gets scanned.
FanslyRailRect(cfg := 0) {
    if !cfg
        cfg := FanslyCfg()
    if !cfg.anchor
        return {x: cfg.x, y: cfg.y, w: cfg.w, h: cfg.pitch * cfg.rows}
    hwnd := WinExist("A")
    if !hwnd
        return 0
    wx := 0, wy := 0, ww := 0, wh := 0
    try WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    catch
        return 0
    if (ww < 1 || wh < 1)
        return 0
    ; Clamp the sweep to the window. A band that runs off the bottom is not an
    ; error worth refusing over — the window simply is not as tall as
    ; SweepHeight assumed — but reading past it would be reading the desktop.
    h := Min(cfg.swH, wh - cfg.swTop)
    if (h < cfg.rowH)
        return 0
    return {x: wx + cfg.ox, y: wy + cfg.swTop, w: cfg.w, h: h}
}

; Every card-shaped run of card-coloured pixels down the rail, top to bottom.
;
; This replaces "look at where row N is and ask whether it is lit" with "find the
; cards". It costs more — it walks the column instead of sampling fixed slots —
; and it buys the three things the fixed slots cannot survive: the window moving,
; the window changing shape (the rail sat at window y313 floating and y200
; snapped, measured), and the rail scrolling.
;
; ─── THE REFUSAL, WHICH IS THE POINT ─────────────────────────────────────────
; It is STILL not established whether the grey disc is the SELECTED state or is
; drawn behind every avatar on the rail — there has only ever been one Fansly
; account on this rail to look at. If it turns out to be decoration, this finds
; every card and the strongest run is a coin flip. So: when the runner-up scores
; within SweepAmbiguity percent of the winner, this answers 0 and says why.
; Detection going quiet with a line in the log is recoverable; one model's mass
; in another model's chat is not.
FanslyLocateCards(cfg := 0, img := 0) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    if !cfg
        cfg := FanslyCfg()
    rect := FanslyRailRect(cfg)
    if !rect
        return {found: [], best: 0, why: "no window to anchor to"}
    if !img
        img := PILL_Grab(rect.x, rect.y, rect.w + 1, rect.h + 1)
    if !img
        return {found: [], best: 0, why: "capture failed"}

    step := Max(1, cfg.swStep)
    rows := []
    y := rect.y
    while (y <= rect.y + rect.h) {
        act := 0
        x := rect.x + 2
        while (x <= rect.x + rect.w - 2) {
            c := PILL_Px(img, x, y)
            if (c >= 0 && PILL_ColorDist(c, cfg.rgb) <= cfg.tol)
                act++
            x += step
        }
        if act
            rows.Push({y: y, act: act})
        y += step
    }
    if !rows.Length
        return {found: [], best: 0, why: "no card-coloured pixels on the rail"}

    ; Keep only runs that are actually card-SHAPED. The rail also carries
    ; dividers and the odd icon in the same grey, and a 1px rule is not a model.
    keep := []
    for r in RAIL_GroupRuns(rows, Max(cfg.gap, step * 2)) {
        tall := r.maxY - r.minY
        if (r.act < cfg.min
            || tall < cfg.rowH * cfg.swMin / 100
            || tall > cfg.rowH * cfg.swMax / 100)
            continue
        keep.Push({minY: r.minY, maxY: r.maxY, act: r.act,
                   avgY: Round(r.sumY / r.act)})
    }
    if !keep.Length
        return {found: [], best: 0, why: "nothing card-shaped found"}

    ; Top to bottom, so the index IS the rail position.
    Loop keep.Length {
        i := A_Index
        Loop keep.Length - i {
            j := A_Index
            if (keep[j].minY > keep[j + 1].minY) {
                t := keep[j], keep[j] := keep[j + 1], keep[j + 1] := t
            }
        }
    }
    best := 1, bestN := 0, secondN := 0
    for i, r in keep {
        if (r.act > bestN)
            secondN := bestN, best := i, bestN := r.act
        else if (r.act > secondN)
            secondN := r.act
    }
    if (keep.Length > 1 && secondN * 100 >= bestN * cfg.swAmb) {
        return {found: keep, best: 0,
                why: "two cards score alike (" bestN " vs " secondN ") — the grey"
                   . " disc is not telling selected from unselected on this"
                   . " theme, so positional mode has no signal. Set [Fansly]"
                   . " Match=name, or find the colour that does differ."}
    }
    return {found: keep, best: best, why: ""}
}

; The rectangle to OCR for row `i`'s name, in screen px.
;
; `cardAt` is {x, y} of the located card in anchored mode. Pass it and the label
; follows the card wherever the sweep found it; leave it 0 and the old fixed-slot
; arithmetic applies. The label sits UNDER the avatar on Fansly, so it is
; measured from the card's top either way.
FanslyLabelRect(i, cfg, cardAt := 0) {
    if cardAt
        return {x: cardAt.x + cfg.lx, y: cardAt.y + cfg.ly, w: cfg.lw, h: cfg.lh}
    top := cfg.y + (i - 1) * cfg.pitch
    return {x: cfg.x + cfg.lx, y: top + cfg.ly, w: cfg.lw, h: cfg.lh}
}

; WHICH ROW is lit, sampled at the fixed slots. 0 = no clear answer.
;
; This is the hot path — reached from #HotIf, i.e. on every keystroke — which is
; why it tests a handful of pixels per row instead of sweeping the rail. It also
; needs no rail colour, no run grouping and no OCR, so it keeps working on a
; theme where unselected cards are invisible and on a machine where OCR reads
; nothing at all.
;
; Returns the counts as well as the index, because the counts are the only useful
; diagnostic when the answer is 0: two rows both scoring high means one card is
; straddling two slots, i.e. RowPitch is wrong. PILL_PickLit's own refusal rules
; (nothing reaches MinCard; the runner-up is more than half the winner) are what
; turn that into an honest "no answer" rather than a coin flip.
FanslyLitRow(cfg := 0, img := 0) {
    if !cfg
        cfg := FanslyCfg()

    ; ── anchored: find the cards, do not assume where they are ───────────────
    ;  The stored slots are only meaningful while the window has not moved and
    ;  has not changed shape, and neither of those holds on a floating window.
    ;  `card` is the located card's rect, which the caller passes on to
    ;  FanslyLabelRect so the OCR follows it too.
    if cfg.anchor {
        loc    := FanslyLocateCards(cfg, img)
        counts := []
        for r in loc.found
            counts.Push(r.act)
        if !loc.best
            return {index: 0, counts: counts, card: 0, why: loc.why,
                    cards: loc.found.Length}

        ; ── the ordinal is not the row unless the whole rail was seen ────────
        ;  loc.best is the winner's place in the list of cards the sweep FOUND,
        ;  top to bottom. That equals the rail row only if the sweep found every
        ;  card. If the grey disc is drawn behind the SELECTED avatar and not the
        ;  others, the sweep finds exactly ONE card whichever model is up, best
        ;  is 1, and this reports "row 1" forever.
        ;
        ;  That is not a hypothetical. Measured in debuglogs\mma.log over two
        ;  sessions: 541 resolutions, every one of them "rail row 1", zero
        ;  ambiguity refusals — because the ambiguity guard in FanslyLocateCards
        ;  only fires with more than one card and there was never more than one.
        ;  [FanslyPos] Pos1 was then rewritten by every teach press, so each
        ;  model in turn became "row 1" and every Fansly card sent whichever
        ;  model was taught last.
        ;
        ;  So: require the sweep to have seen at least as many cards as the rail
        ;  has rows before believing the ordinal. Fewer means the unselected
        ;  cards are invisible to it, and the honest answer is no answer — the
        ;  same refusal the ambiguity guard makes, for the same reason. Fansly's
        ;  own Manual mode is the working setup while this is true; see the mode
        ;  header in core\fansly_model.ahk.
        if (loc.found.Length < cfg.rows)
            return {index: 0, counts: counts, card: 0, cards: loc.found.Length,
                    why: "the sweep found " loc.found.Length " card"
                       . (loc.found.Length = 1 ? "" : "s") " on a rail with "
                       . cfg.rows " rows, so its position in that list is NOT the"
                       . " row number — with only the selected card visible this"
                       . " would answer 'row 1' whichever model is up. MMA will"
                       . " not guess. Either CardColor/CardTol must find every"
                       . " card (run tools\fansly_probe.ahk), or set Fansly to"
                       . " Manual in Settings ▸ Models."}

        c := loc.found[loc.best]
        return {index: loc.best, counts: counts, why: "", cards: loc.found.Length,
                card: {x: FanslyRailRect(cfg).x, y: c.minY,
                       w: cfg.w, h: c.maxY - c.minY}}
    }

    if !img
        img := FanslyGrabRail(cfg)
    counts := []
    if !img {
        Loop cfg.rows
            counts.Push(-1)
        return {index: 0, counts: counts, card: 0, why: "capture failed",
                cards: -1}
    }
    band  := FanslySampleBand(cfg)
    xstep := Max(1, cfg.step)
    Loop cfg.rows {
        r := FanslyRowRange(A_Index, cfg)
        counts.Push(PILL_CountIn(img, band.x1, band.x2, r.y1, r.y2,
                                 cfg.rgb, cfg.tol, xstep, cfg.step))
    }
    ; cards is -1, not counts.Length. In the ANCHORED branch above, counts has one
    ; entry per card the sweep found, so its length IS the card count; here it has
    ; one entry per configured ROW whether or not anything is there, so the same
    ; expression would report "3 cards found" on a rail showing nothing. A number
    ; that means two different things in two branches is worse than no number, and
    ; the badge that displays it has to be able to say "not applicable".
    return {index: PILL_PickLit(counts, cfg.min), counts: counts,
            card: 0, why: "", cards: -1}
}

; Find the lit card by SWEEPING, without trusting RowPitch or RowHeight.
;
; The calibrator's function, and the service's fallback: it answers "where is the
; lit card" on a rail whose row geometry has not been measured yet, which is
; exactly the state you are in when you first run the probe. The hot path above
; does not use it — it already knows where the rows are and has no reason to
; search.
FanslySweep(cfg := 0, img := 0) {
    if !cfg
        cfg := FanslyCfg()
    if !img
        img := FanslyGrabRail(cfg)
    if !img
        return {count: 0, avgY: -1, minY: 0, maxY: -1}
    band := FanslySampleBand(cfg)
    return RAIL_Scan(img, band.x1, cfg.y, band.x2,
                     cfg.y + cfg.pitch * cfg.rows,
                     cfg.rgb, cfg.tol, cfg.step, cfg.gap)
}
