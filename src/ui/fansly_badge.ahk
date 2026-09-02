#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  fansly_badge.ahk — a small strip beside the Fansly rail saying what it sees.
; ───────────────────────────────────────────────────────────────────────────────
;  The Fansly rail detector has exactly one failure mode that matters, and it is
;  not "it stops working". It is that it answers CONFIDENTLY and wrongly: for 541
;  logged resolutions it said "rail row 1 → model 2" no matter which card was up,
;  because the grey disc is only drawn on the SELECTED row, so the sweep found one
;  card and its position in that list was always 1 (see FanslyLitRow's refusal in
;  screen/fansly_scan.ahk).
;
;  Nothing on screen disagreed. The evidence existed the whole time — it was in
;  debuglogs\mma.log, which is not where anybody is looking while they work. This
;  badge is that evidence put where the question is asked: next to the rail, while
;  you are on the rail, naming the model the shared keys would send to right now.
;
;  ─── OFF BY DEFAULT, AND A DEBUG SWITCH RATHER THAN A FEATURE ────────────────
;  [Debug] FanslyRail, ticked in Settings ▸ Debug beside the logging switches, not
;  a FEAT in Settings ▸ Features. The distinction is the one debug_panel.ahk's
;  header draws: a feature is a thing MMA does for you, a debug switch is a thing
;  MMA shows you about itself, and this is the second. It also means it is written
;  the instant you click it and picked up everywhere within a second and a half,
;  with no Save and no restart — which is what you want from something you switch
;  on because a key just did the wrong thing.
;
;  ─── THREE THINGS IT MUST NOT DO ────────────────────────────────────────────
;  STEAL FOCUS. Every message you type goes into a chat box, so a window that took
;  the foreground when it appeared would eat the keystroke you were mid-way
;  through. WS_EX_NOACTIVATE (0x08000000).
;
;  EAT CLICKS. It parks beside the rail — the thing you click all day — so unlike
;  the lock badge it is WS_EX_TRANSPARENT (0x20) as well: clicks fall straight
;  through to Fansly underneath. That is also why it has no click action of its
;  own. A debug readout that can be dismissed by a mis-click beside the cards
;  would be off exactly when you finally reproduce the thing you turned it on for.
;
;  COST ANYTHING WHEN OFF. The tick below is one cached ini read until the switch
;  is on. Nothing is scanned, no window is built, and FanslyStatus() is not even
;  asked — see FANBADGE_Sync.
;
;  ─── IT READS, IT DOES NOT MEASURE ──────────────────────────────────────────
;  Every number shown comes out of FanslyStatus(), which is the same call every
;  [mass.active] key resolves through and is cached for 250ms. So the badge cannot
;  disagree with the keys — it is not a second opinion, it is the same answer made
;  visible — and it adds no pixel work of its own. That is the whole reason
;  _FanRes in core/fansly_model.ahk carries `why`, `row`, `cards` and `rows`: they
;  were already computed and thrown away.
; ═══════════════════════════════════════════════════════════════════════════════

global _fanBadgeGui  := 0    ; the badge while it is up, else 0
global _fanBadgeFace := ""   ; what it currently SAYS, so a repaint only happens
                             ; when the answer actually changed

global FANBADGE_BG    := "14141A"
global FANBADGE_OK    := "7FD68A"     ; resolved — the keys have an answer
global FANBADGE_WARN  := "FFC24D"     ; no answer — the keys will do nothing
global FANBADGE_DIM   := "8A8A94"
global FANBADGE_W     := 232
global FANBADGE_H     := 44

; ── the switch ────────────────────────────────────────────────────────────────
;  Cached for the same 1500ms the logging switches use, and for the same reason:
;  this is called from a timer, and an ini read per tick to answer a question
;  whose answer changes twice a week is a cost with nothing on the other side.
;  LOG_SETTINGS_TTL rather than a number of its own, so the two cannot drift into
;  "I ticked both boxes and one of them took effect".
global _FANBADGE_T  := 0
global _FANBADGE_ON := false

FANBADGE_On() {
    global _FANBADGE_T, _FANBADGE_ON, LOG_SETTINGS_TTL, MMA_CFG
    now := A_TickCount
    if (_FANBADGE_T && now - _FANBADGE_T < LOG_SETTINGS_TTL)
        return _FANBADGE_ON
    _FANBADGE_T := now
    ; Swallowed, like log.ahk's read of the same section: an unreadable cfg leaves
    ; the previous answer standing rather than flickering the badge off.
    try _FANBADGE_ON := Trim(IniRead(MMA_CFG, "Debug", "FanslyRail", "0")) = "1"
    return _FANBADGE_ON
}

; ── the tick ──────────────────────────────────────────────────────────────────
;  The ONE entry point, from a timer in mass/engine.ahk. Ordered cheapest-first:
;  the switch, then the resolve, then the window.
;
;  state "off" means "Fansly is not the site you are looking at" — feature off, or
;  its window is not in front — and the badge goes away for it. That is not the
;  same as a failed resolve, which is precisely what the badge is FOR and stays up
;  saying. Conflating the two is how a debug overlay ends up hidden in the one
;  state worth showing.
FANBADGE_Sync() {
    if !FANBADGE_On() {
        FANBADGE_Hide()
        return
    }
    st := FanslyStatus()
    if (st.state = "off") {
        FANBADGE_Hide()
        return
    }
    FANBADGE_Show(st)
}

FANBADGE_Show(st) {
    global _fanBadgeGui, _fanBadgeFace
    global FANBADGE_BG, FANBADGE_OK, FANBADGE_WARN, FANBADGE_DIM
    global FANBADGE_W, FANBADGE_H

    ok    := st.state = "ok"
    line1 := ok ? ModelLabel(st.no) : "no answer"
    line2 := _FANBADGE_Detail(st)
    face  := line1 "`n" line2 "`n" (ok ? "1" : "0")

    ; ONCE per tick, and passed down. _FANBADGE_Pos builds a FanslyCfg(), which is
    ; ~45 ini reads; working it out again in the parking step below would double
    ; that on every tick for a number that cannot have changed in between.
    pos := _FANBADGE_Pos()

    ; Already up and saying the same thing: move it if the window moved, and
    ; otherwise do nothing at all. Without this the badge is re-set 85 times a
    ; minute, which on a click-through always-on-top window is a visible flicker
    ; over the rail.
    if (_fanBadgeGui && face = _fanBadgeFace) {
        _FANBADGE_Park(pos)
        return
    }

    if _fanBadgeGui {
        try {
            ; SetFont, not Opt("c…"). Colour on an already-created Text control is
            ; a FONT property in v2; Opt is for the style bits and quietly does
            ; nothing here, which would leave a refusal painted in the green that
            ; means "resolved" — the one colour it must never be.
            _fanBadgeGui["FanModel"].SetFont("c" (ok ? FANBADGE_OK : FANBADGE_WARN))
            _fanBadgeGui["FanModel"].Text := line1
            _fanBadgeGui["FanWhy"].Text   := line2
            _fanBadgeFace := face
            _FANBADGE_Park(pos)
            return
        }
        ; Its controls are gone but the handle is not — rebuild from scratch.
        FANBADGE_Hide()
    }

    ; -Caption for no title bar, +ToolWindow so it is in neither the taskbar nor
    ; Alt-Tab, +E0x08000020 for NOACTIVATE|TRANSPARENT — see the header.
    fg := Gui("+AlwaysOnTop -Caption +ToolWindow -SysMenu +E0x08000020")
    fg.BackColor := FANBADGE_BG
    fg.MarginX := 0, fg.MarginY := 0

    fg.SetFont("s7 Bold c" FANBADGE_DIM, "Segoe UI")
    fg.Add("Text", "x8 y3 w" (FANBADGE_W - 16) " BackgroundTrans", "FANSLY RAIL")

    fg.SetFont("s10 Bold c" (ok ? FANBADGE_OK : FANBADGE_WARN), "Segoe UI")
    fg.Add("Text", "vFanModel x8 y14 w" (FANBADGE_W - 16) " BackgroundTrans", line1)

    fg.SetFont("s7 Norm c" FANBADGE_DIM, "Segoe UI")
    fg.Add("Text", "vFanWhy x8 y31 w" (FANBADGE_W - 16) " BackgroundTrans", line2)

    fg.Show("x" pos.x " y" pos.y " w" FANBADGE_W " h" FANBADGE_H " NoActivate")
    _fanBadgeGui := fg, _fanBadgeFace := face
}

FANBADGE_Hide() {
    global _fanBadgeGui, _fanBadgeFace
    if _fanBadgeGui
        try _fanBadgeGui.Destroy()
    _fanBadgeGui := 0, _fanBadgeFace := ""
}

; ── the toggle ────────────────────────────────────────────────────────────────
;  The registry action `gui.toggleRailBadge`, bound in mass/engine.ahk. Ships with
;  no key: it is meant to be typed (`..dorail`, via hotstrings/shortcuts.ahk),
;  because reaching for a chord mid-shift to check a readout is most of the reason
;  the readout does not get checked.
;
;  Writes the SAME [Debug] FanslyRail key the Settings tick-box writes, rather
;  than holding a second in-memory flag beside it. Two switches over one state is
;  how a box you ticked in Settings reads as ticked while nothing is on screen —
;  and the cfg is what the other seven processes can see anyway.
;
;  The cache is cleared rather than waited out. FANBADGE_On() holds its answer for
;  LOG_SETTINGS_TTL, which is right for a timer and quite wrong for a keypress: a
;  toggle that takes up to a second and a half to do anything is one you press
;  twice. Everything else still picks it up on its own next read.
FANBADGE_Toggle(*) {
    global MMA_CFG, _FANBADGE_T, _FANBADGE_ON
    on := !FANBADGE_On()
    try IniWrite(on ? "1" : "0", MMA_CFG, "Debug", "FanslyRail")
    catch as e {
        LOGE("fansly.badge", "could not write [Debug] FanslyRail — the readout is"
                           . " unchanged", LOG_Err(e))
        return
    }
    _FANBADGE_ON := on, _FANBADGE_T := A_TickCount
    LOGI("fansly.badge", "rail readout " (on ? "ON" : "off")
                       . " — same switch as Settings ▸ Debug")
    SoundBeep(on ? 880 : 600, 70)
    FANBADGE_Sync()
}

; ── the second line: the evidence, not a restatement ─────────────────────────
;  "no answer" on its own is what the shared keys already tell you by doing
;  nothing. What this line has to carry is the one number that says which knob to
;  turn, and for the rail that is the CARD COUNT against the row count: fewer
;  cards than rows means the unselected discs are invisible to the sweep, which is
;  the state in which a row number cannot exist at all. It is also, when it reads
;  "1/3", the exact fingerprint of the bug this whole badge was built for.
_FANBADGE_Detail(st) {
    mode := st.mode = "" ? "?" : st.mode

    if (st.mode = "manual")
        return "manual · you said so, nothing is read"

    ; cards is -1 in fixed-slot mode, where the sweep does not run and "how many
    ; cards" is not a question that was asked. Saying "-1 cards" would be worse
    ; than saying nothing.
    ev := ""
    if (st.cards >= 0)
        ev := st.cards "/" st.rows " cards"
    if st.row
        ev := (ev = "" ? "" : ev " · ") "row " st.row

    if (st.state = "ok")
        return mode (ev = "" ? "" : " · " ev)

    ; A refusal. The EVIDENCE goes first and the sentence second, because the
    ; evidence is the part that fits: "1/3 cards" is the whole diagnosis in nine
    ; characters, and the sentence explaining it is in the log with the same
    ; wording to search for.
    ;
    ; Truncated on the COMPOSED line, not on `why` alone. Capping the reason at 46
    ; and then prefixing "1/3 cards · " to it produced 58 characters in a control
    ; that fits about 50, so the ellipsis that was supposed to mark the cut was
    ; itself cut off — the line just stopped mid-word with nothing saying so.
    ; Measured off a screenshot of the real badge, which is the only way to know.
    return _FANBADGE_Fit((ev = "" ? mode : ev) " · " st.why, 50)
}

; Cut to `n` characters with an ellipsis, on a word boundary where there is one
; close enough that the line does not lose a whole word to it.
_FANBADGE_Fit(s, n) {
    if (StrLen(s) <= n)
        return s
    cut := SubStr(s, 1, n - 1)
    sp  := InStr(cut, " ", , -1)
    if (sp > n - 12)
        cut := SubStr(cut, 1, sp - 1)
    return cut "…"
}

; ── where it goes ─────────────────────────────────────────────────────────────
;  Just right of the rail, at its top. NOT following the lit card: the card moves
;  every time you click one, and a readout that jumps around the screen while you
;  work is one you stop reading. The rail's top edge is the one anchor that holds
;  still while the thing it describes changes.
;
;  FanslyRailRect is the same function the scan uses, so the badge is beside the
;  strip that was actually measured rather than beside where the config says the
;  rail should be — which under Anchor=window are different places the moment the
;  window is moved.
;
;  [Fansly] BadgeX / BadgeY override both, in screen pixels, for a desk where the
;  right of the rail is where something else lives. -1 means "beside the rail".
_FANBADGE_Pos() {
    global MMA_CFG, FANBADGE_W
    x := LOG_IniInt(MMA_CFG, "Fansly", "BadgeX", -1, "fansly.cfg")
    y := LOG_IniInt(MMA_CFG, "Fansly", "BadgeY", -1, "fansly.cfg")
    if (x >= 0 && y >= 0)
        return {x: x, y: y}

    rect := 0
    try rect := FanslyRailRect(FanslyCfg())
    if !rect
        return {x: 24, y: 24}

    ; Off the right edge of the monitor the rail is on — a left-hand monitor with
    ; the rail against its right edge would otherwise put the badge on the next
    ; screen along, or nowhere. Fall back to the rail's LEFT in that case.
    bx := rect.x + rect.w + 8
    ma := MonitorAreaAt(rect.x, rect.y)
    if (bx + FANBADGE_W > ma.r)
        bx := rect.x - FANBADGE_W - 8
    return {x: bx, y: rect.y + 4}
}

; Keep it beside the rail as the window moves — a move only when the number
; actually changed. This is what stops the badge sitting in the middle of the
; screen after you drag Fansly, which for a window-anchored rail is a thing that
; happens (the rail sat at window y313 floating and y200 snapped, measured).
_FANBADGE_Park(pos) {
    global _fanBadgeGui
    static lastX := -99999, lastY := -99999
    if !_fanBadgeGui
        return
    if (pos.x = lastX && pos.y = lastY)
        return
    lastX := pos.x, lastY := pos.y
    try _fanBadgeGui.Move(pos.x, pos.y)
}
