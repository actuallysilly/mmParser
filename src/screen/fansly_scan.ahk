#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "rail_scan.ahk"
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
                    "PollMs",c.pollMs, "WinMatch",c.win)
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
    return PILL_ActiveHolds(cfg.x, cfg.y, cfg.w, cfg.pitch * cfg.rows)
}

; Grab the whole rail once. Everything else reads from the returned buffer.
;
; ONE BitBlt, then memory reads — see pill_scan.ahk's header for the measurements
; that forced this. The height is derived (pitch × rows) rather than configured,
; per the note at the top.
FanslyGrabRail(cfg := 0) {
    if !cfg
        cfg := FanslyCfg()
    return PILL_Grab(cfg.x, cfg.y, cfg.w + 1, cfg.pitch * cfg.rows + 1)
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

; The rectangle to OCR for row `i`'s name, in screen px.
FanslyLabelRect(i, cfg) {
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
    if !img
        img := FanslyGrabRail(cfg)
    counts := []
    if !img {
        Loop cfg.rows
            counts.Push(-1)
        return {index: 0, counts: counts}
    }
    band  := FanslySampleBand(cfg)
    xstep := Max(1, cfg.step)
    Loop cfg.rows {
        r := FanslyRowRange(A_Index, cfg)
        counts.Push(PILL_CountIn(img, band.x1, band.x2, r.y1, r.y2,
                                 cfg.rgb, cfg.tol, xstep, cfg.step))
    }
    return {index: PILL_PickLit(counts, cfg.min), counts: counts}
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
