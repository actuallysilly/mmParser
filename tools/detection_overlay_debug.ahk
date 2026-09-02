#Requires AutoHotkey v2.0
#SingleInstance Force
; ═══════════════════════════════════════════════════════════════════════════════
;  detection_overlay_debug.ahk — everything MMA thinks it can see, on screen,
;  while you work.
; ───────────────────────────────────────────────────────────────────────────────
;  The other probes answer one question each and print a file: detector_probe
;  suggests colours, fansly_probe measures the rail, nextfu_probe explains one
;  read of one chat. All three are things you run, read, and close.
;
;  This is the other shape. It stays up, and it keeps saying — live — the five
;  facts every "why did that key send the wrong thing" question turns out to be
;  about:
;
;      platform   which site MMA believes you are looking at
;      tab / row  which tab (Infloww) or rail row (Fansly) reads as selected
;      model      what OCR reads off that tab, NEXT TO what it should read
;      resolved   which model slot and mass slot the shared keys would use
;      next_fu    which follow-up is already in the chat, and what f-next sends
;
;  ─── TWO VIEWS OF ONE STATE ─────────────────────────────────────────────────
;  STRIP (the default) is a flat 60px bar: five cells, a caption and a value
;  each, colour carrying the verdict. It is meant to be left on all shift beside
;  Infloww, so it says the answer and nothing else — no reasons, no counts, no
;  key hints.
;
;  DETAIL (Ctrl+Alt+F11) is the same five rows with the working shown underneath
;  each one: the per-slot pixel counts, which cfg section to add a name to, how
;  long the OCR took, why f1 is being held back. That is the half you want for
;  ten minutes when something is wrong, and the half that is noise for the other
;  seven hours.
;
;  ONE state function feeds both (DBG_State), so the strip can never disagree
;  with the panel — they are the same five answers rendered short and long. A
;  second copy of the logic behind a "compact mode" flag is how the two would
;  drift, and a diagnostic that contradicts itself is worse than no diagnostic.
;
;  ─── WHAT IS CHEAP AND WHAT IS NOT ──────────────────────────────────────────
;  Three of the five are free — a pixel scan, some arithmetic and an ini read —
;  so they refresh twice a second. The other two are OCR, which is expensive
;  enough to matter while you type, so they are rationed:
;
;      the model name  is re-read only when the lit tab/row CHANGES, exactly as
;                      the two detector services do it.
;      next_fu         is read ON DEMAND (Ctrl+Alt+F10), because it OCRs the
;                      whole conversation pane and that is most of a second.
;                      Ctrl+Alt+F8 turns on a 4-second auto-refresh when you
;                      would rather watch it than press a key; leave it off while
;                      typing.
;
;  ─── IT READS. IT DOES NOT DECIDE ───────────────────────────────────────────
;  Nothing here writes a cfg key, teaches a slot, or sends a message, and it
;  deliberately does not call FanslySeedCfg() the way the Fansly service does —
;  a diagnostic that edits the thing being diagnosed is how tools\test\ scripts
;  used to eat the live detector settings.
;
;  It also scans REGARDLESS of whether the matching detector feature is switched
;  on, and says so when it is off. That is the point: "is the feature even on"
;  and "would the scan find anything if it were" are different questions and you
;  want both answered at once.
;
;  ─── WHY IT SUSPENDS ITSELF ─────────────────────────────────────────────────
;  It includes mass\runtime.ahk, because next_fu is meaningless without the
;  model's actual follow-up text and CurMass() lives there. Including runtime
;  registers __mm, __1mm..__Nmm and every hotstring utils.ahk owns — in THIS
;  process, alongside the copies the real engine already has. Two processes
;  answering __mm means two pastes into a fan's chat.
;
;  So the auto-execute section suspends the lot on line one, and this file's own
;  four keys are declared #SuspendExempt. Nothing this script inherited can fire;
;  everything it declares can. (nextfu_probe.ahk has the same exposure and gets
;  away with it by being open for thirty seconds; this one is meant to stay up.)
;
;  USAGE: run it, leave it. Drag either view by its body if it is in the way, and
;  RIGHT-CLICK either view for all of the below as a menu — including Exit, which
;  is the only one you should have to find without being told.
;      Ctrl+Alt+F10  read the conversation now (name + next_fu)
;      Ctrl+Alt+F9   outline the regions it reads, for 3 seconds
;      Ctrl+Alt+F11  strip <-> detail
;      Ctrl+Alt+F8   auto-refresh next_fu every 4s, on/off
;      Ctrl+Alt+F5   quit  (not F12 — that is [recorder] toggle here)
;
;  Modified keys, never a bare F10 or Esc: this runs WHILE Infloww is focused and
;  a bare hotkey is swallowed globally, so Esc would stop closing Infloww's own
;  dialogs for as long as the overlay was up.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/runtime.ahk"

; Everything the includes above registered — __mm, the numbered mass triggers,
; the whole hotstring library — off, in this process, before the first line of
; this tool's own code. See the header. The four keys at the bottom are exempt.
Suspend true

CoordMode "Pixel", "Screen"

; ── palette ───────────────────────────────────────────────────────────────────
; The Tools / Hotstrings / Startup-scripts family, so the overlay reads as part
; of MMA rather than as a stray script.
DBG_BG     := "15141C"
DBG_TXT    := "E6E4EE"
DBG_MUTED  := "8E8AA6"
DBG_ACCENT := "B89CFF"
DBG_GOOD   := "9AE6A0"
DBG_WARN   := "E0B978"
DBG_BAD    := "E68A8A"

; ── the five things, and how wide each one is in the strip ────────────────────
; One list, so the two views cannot end up with different rows in a different
; order. The widths are the strip's; the panel ignores them.
DBG_ROWS := [{cap: "site",     w:  74},
             {cap: "tab",      w:  86},
             {cap: "model",    w: 210},
             {cap: "resolved", w: 122},
             {cap: "next",     w: 104}]

DBG_PAD  := 14                    ; gap between strip cells, and its left inset
DBG_PANW := 520                   ; detail panel width

; ── state ─────────────────────────────────────────────────────────────────────
; Assigned HERE, at the top, and not beside the functions that use them: top-level
; statements run in order and function bodies are skipped, so an initialiser that
; reads better next to its function has simply not run yet when the first Tick()
; fires a few lines below. That is what "_wIndex has not been assigned a value"
; was on the detector side.
DBG_view    := "strip"   ; "strip" or "detail"
DBG_ocrKey  := ""        ; "<platform>|<index>" the cached name belongs to
DBG_ocrName := ""        ; last name OCR read off the lit tab/row
DBG_ocrMs   := 0         ; how long that read took
DBG_fu      := 0         ; last next_fu result object, or 0 for "never sampled"
DBG_fuAt    := 0         ; A_TickCount of that sample
DBG_auto    := false     ; is the 4-second next_fu refresh on

; ── the strip: the default view ───────────────────────────────────────────────
;  60px tall, as wide as it needs to be, no title and no key hints — everything
;  in it is an ANSWER. It is the view that has to survive being looked at out of
;  the corner of an eye a hundred times a shift, so the caption is 7pt grey and
;  the value is the only thing with any weight.
;
;  +E0x08000000 is WS_EX_NOACTIVATE: clicking or dragging this must never take
;  focus off the chat, because half of what it reports is only true while Infloww
;  or Fansly is the ACTIVE window — an overlay that steals focus would change the
;  answer by being looked at.
;
;  stripGui, not strip: a variable and a function whose names differ only by case
;  are the SAME NAME to AHK, and the script then fails to load outright rather
;  than shadowing one with the other.
DBG_STRIPH := 60
stripGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
stripGui.BackColor := DBG_BG
stripGui.MarginX := 0, stripGui.MarginY := 0

DBG_CELL := []
x := DBG_PAD
for _, r in DBG_ROWS {
    stripGui.SetFont("s7 Norm c" DBG_MUTED, "Segoe UI")
    stripGui.Add("Text", "x" x " y11 w" r.w, r.cap)
    stripGui.SetFont("s10 Bold c" DBG_TXT, "Segoe UI")
    DBG_CELL.Push(stripGui.Add("Text", "x" x " y26 w" r.w " h22", ""))
    x += r.w + DBG_PAD
}
DBG_STRIPW := x
; A 3px accent rule along the bottom, which is the only decoration in here. It
; doubles as the auto-refresh lamp: it goes accent-coloured while ^!F8 is on, so
; "why is this OCRing the pane every four seconds" has a visible cause.
; No 0x10 here: that is SS_ETCHEDHORZ, which paints its own two-tone divider and
; ignores the background colour it is being asked to carry — the lamp would be
; permanently grey.
lampStrip := stripGui.Add("Text", "x0 y" (DBG_STRIPH - 3) " w" DBG_STRIPW
                                . " h3 Background" DBG_BG)

; ── the detail panel ──────────────────────────────────────────────────────────
;  The same five, with the working shown. Built up front rather than on demand so
;  ^!F11 is instant and neither view can be half-built when the timer fires.
dbgGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
dbgGui.BackColor := DBG_BG
dbgGui.MarginX := 0, dbgGui.MarginY := 0

dbgGui.SetFont("s10 Bold c" DBG_ACCENT, "Segoe UI")
dbgGui.Add("Text", "x14 y10 w300", "Detection overlay")
dbgGui.SetFont("s8 Norm c" DBG_MUTED, "Segoe UI")
lblAuto := dbgGui.Add("Text", "x" (DBG_PANW - 210) " y13 w196 Right", "")
dbgGui.Add("Text", "x14 y32 w" (DBG_PANW - 28) " h1 0x10")

; One row = a label, a value, and a detail line under it. The detail line is
; where the counts and the reasons go, and it is the half that turns "no answer"
; into something you can act on.
DBG_VAL := []
DBG_DET := []
y := 44
for _, r in DBG_ROWS {
    dbgGui.SetFont("s8 Norm c" DBG_MUTED, "Segoe UI")
    dbgGui.Add("Text", "x14 y" (y + 2) " w76", r.cap)
    dbgGui.SetFont("s9 Bold c" DBG_TXT, "Segoe UI")
    DBG_VAL.Push(dbgGui.Add("Text", "x94 y" y " w" (DBG_PANW - 108), ""))
    dbgGui.SetFont("s8 Norm c" DBG_MUTED, "Segoe UI")
    ; h34, and the row pitched at 56 to hold it: the detail line runs to two
    ; lines on the rows that have something to explain (next_fu prints what it
    ; actually read underneath its verdict), and a Text control sized to one line
    ; silently clips the second rather than growing.
    DBG_DET.Push(dbgGui.Add("Text", "x94 y" (y + 18) " w" (DBG_PANW - 108) " h34", ""))
    y += 56
}

dbgGui.Add("Text", "x14 y" y " w" (DBG_PANW - 28) " h1 0x10")
y += 10
dbgGui.SetFont("s8 Norm c" DBG_MUTED, "Segoe UI")
dbgGui.Add("Text", "x14 y" y " w" (DBG_PANW - 28),
           "^!F10 read chat   ^!F9 regions   ^!F11 strip   ^!F8 auto"
         . "   ^!F5 quit")
DBG_PANH := y + 30

for _, hwnd in [stripGui.Hwnd, dbgGui.Hwnd]
    for attr in [20, 19]            ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", attr,
                    "int*", 1, "int", 4)

; Drag by the body. -Caption means there is no title bar to grab, and a bar that
; cannot be moved will eventually be sitting on top of the one thing you need to
; see. PostMessage's fourth parameter is Control, not WinTitle — passing the
; window there throws "Target window not found", so it is left out.
stripGui.OnEvent("Close", DBG_Quit)
dbgGui.OnEvent("Close", DBG_Quit)
OnMessage(0x201, DBG_Drag)          ; WM_LBUTTONDOWN

DBG_Drag(wParam, lParam, msg, hwnd) {
    global stripGui, dbgGui
    try {
        root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
        if (root = stripGui.Hwnd || root = dbgGui.Hwnd)
            PostMessage(0xA1, 2, 0, , "ahk_id " root)      ; WM_NCLBUTTONDOWN
    }
}

; ── right-click, on either view ───────────────────────────────────────────────
;  The four chords are the fast path once you know them. This is how you find out
;  they exist — and, more to the point, how you CLOSE the thing without having to
;  remember that quit here is ^!F5 and not the ^!F12 every other probe uses. An
;  overlay with no visible way out is one you end up killing from Task Manager.
;
;  WM_RBUTTONUP rather than the Gui "ContextMenu" event, matching DBG_Drag above:
;  both views are almost entirely covered by Text controls, so the message arrives
;  addressed to whichever control was clicked, not to the window. GetAncestor
;  walks that back to the window it belongs to, which lets ONE handler serve every
;  control on both views instead of binding each of them.
;
;  The flash outlines are deliberately not covered: they carry E0x20
;  (WS_EX_TRANSPARENT), so clicks pass straight through them to Infloww and they
;  never see this message at all. That is what they are for.
OnMessage(0x0205, DBG_RightClick)

DBG_RightClick(wParam, lParam, msg, hwnd) {
    global stripGui, dbgGui
    try {
        root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
        if (root != stripGui.Hwnd && root != dbgGui.Hwnd)
            return
    } catch
        return
    DBG_ShowMenu()
    return 0
}

; Built fresh per click, not once at load: two of the items describe current state
; (which view you are in, whether auto-refresh is on) and a menu that names the
; wrong one is worse than no menu.
DBG_ShowMenu() {
    global DBG_view, DBG_auto
    autoItem := "Auto-refresh next_fu every 4s`t^!F8"
    m := Menu()
    m.Add("Read the conversation now`t^!F10", DBG_ReadNow)
    m.Add("Outline the regions it reads`t^!F9", DBG_FlashRegions)
    m.Add()
    if (DBG_view = "strip")
        m.Add("Show the detail panel`t^!F11", DBG_ToggleView)
    else
        m.Add("Back to the strip`t^!F11", DBG_ToggleView)
    m.Add(autoItem, DBG_ToggleAuto)
    if DBG_auto
        m.Check(autoItem)
    m.Add()
    m.Add("Exit`t^!F5", DBG_Quit)
    m.Show()
}

; ── the actions, named once and shared ────────────────────────────────────────
;  Both the menu and the hotkeys at the bottom of the file call these. They used to
;  live inline in the hotkey bodies; a menu item is a second caller, and two copies
;  of "turn auto-refresh on" is how one of them ends up not calling DBG_ShowAuto
;  and the lamp stops matching the setting it is there to report.

; Clearing DBG_ocrKey is what forces the NAME to be re-read too, not just next_fu:
; the name is cached against the lit tab and would otherwise survive a manual
; refresh, which is the one moment you are asking it to go and look again.
DBG_ReadNow(*) {
    global DBG_ocrKey
    DBG_ocrKey := ""
    DBG_ReadFu()
    Tick()
}

DBG_ToggleAuto(*) {
    global DBG_auto
    DBG_auto := !DBG_auto
    DBG_ShowAuto()
    if DBG_auto
        DBG_ReadFu()
    Tick()
}

; Top-right by default, high enough to clear Infloww's own header. Both views are
; shown at the same corner so ^!F11 does not move the thing you are looking at.
DBG_X := A_ScreenWidth - Max(DBG_STRIPW, DBG_PANW) - 24
DBG_Y := 120
stripGui.Show("x" DBG_X " y" DBG_Y " w" DBG_STRIPW " h" DBG_STRIPH " NoActivate")
DBG_Nudge(stripGui)

Tick()
SetTimer(Tick, 500)

; ── the cheap half, twice a second ────────────────────────────────────────────
;  A rail/strip scan is one BitBlt and a few dozen memory reads, an ini read is
;  an ini read, and neither touches OCR. Half a second is fast enough that
;  clicking a tab and looking at the bar feels immediate, and cheap enough to
;  leave running while you type.
;
;  Both views are painted every tick, including the hidden one. Fifteen Text
;  assignments cost nothing measurable, and it means ^!F11 shows a current
;  panel rather than one that catches up half a second later.
Tick() {
    global DBG_ocrKey, DBG_auto, DBG_fuAt, DBG_CELL, DBG_VAL, DBG_DET

    p   := DBG_Platform()
    lit := DBG_Lit(p)

    ; OCR only when the lit tab/row CHANGES — the same rationing both detector
    ; services use, and for the same reason: it is the expensive part and the
    ; answer cannot change while the selection has not.
    key := p.id "|" lit.index
    if (key != DBG_ocrKey) {
        DBG_ocrKey := key
        DBG_ReadName(p, lit)
    }

    rows := [p, lit, DBG_NameRow(p, lit), DBG_ResolvedRow(p), DBG_FuRow()]
    for i, r in rows
        DBG_Paint(i, r)

    if (DBG_auto && A_TickCount - DBG_fuAt > 4000)
        DBG_ReadFu()
}

; One row into both views. The colour word, not a hex value, so the palette is
; decided in one place and a row cannot invent a sixth state.
DBG_Paint(i, r) {
    global DBG_CELL, DBG_VAL, DBG_DET
    global DBG_TXT, DBG_MUTED, DBG_GOOD, DBG_WARN, DBG_BAD
    c := DBG_TXT
    if (r.color = "good")
        c := DBG_GOOD
    else if (r.color = "warn")
        c := DBG_WARN
    else if (r.color = "bad")
        c := DBG_BAD
    else if (r.color = "muted")
        c := DBG_MUTED
    ; A timer outlives a Destroy, and touching a destroyed control throws — which
    ; from a timer means a dialog on top of whatever you moved on to.
    try {
        DBG_CELL[i].SetFont("c" c)
        DBG_CELL[i].Value := r.short
        DBG_VAL[i].SetFont("c" c)
        DBG_VAL[i].Value := r.value
        DBG_DET[i].Value := r.detail
    }
}

; ── row 1: which site ─────────────────────────────────────────────────────────
;  Routed by which window is in FRONT, because that is how core/active_model.ahk
;  routes it — FanslyStatus() first, falling through to the Infloww path when the
;  Fansly window is not up. Reporting it any other way would describe a program
;  that does not exist.
;
;  Both gates are reported even when they disagree with the feature switches, and
;  the switches are named separately in the detail line. "Fansly is in front but
;  its detector is off" is a complete explanation for dead shared keys, and it is
;  invisible everywhere else.
;  ─── WHY THE TITLE IS PRINTED, AND WHAT DECIDES ─────────────────────────────
;  Both gates were once SUBSTRING matches on the active window's title, and the
;  [Fansly] one is the single word "Fansly" — a word that turns up in titles with
;  nothing to do with the site: an editor holding fansly_scan.ahk, a browser tab,
;  and the one that actually bites, an Infloww window showing a model NAMED
;  "KB FANSLY". Since ActiveModelStatus asks Fansly first, that title took the
;  shared keys away from Infloww entirely, silently, for as long as it was up.
;
;  Both gates now also require the window in front to COVER the region about to
;  be scanned (PILL_ActiveHolds, screen/pill_scan.ahk). With one site per monitor
;  that is decisive and needs no patterns at all. The title is still printed on
;  every row, because when a gate does behave unexpectedly the title is the first
;  thing you want to see and the last thing MMA used to tell you.
DBG_Platform() {
    dcfg := DetectorCfg()
    fcfg := FanslyCfg()
    title := ""
    try title := WinGetTitle("A")
    seen := "in front: '" (title = "" ? "?" : SubStr(title, 1, 54)) "'"

    ; The engine's own gates, called rather than reimplemented.
    fanUp := FanslyWindowUp(fcfg)
    infUp := DetectorWindowUp(dcfg)

    ; What the visual cue said, verbatim. When one is configured it is the ONLY
    ; thing deciding the Fansly gate, so it is the first thing you want to see —
    ; and the text it read is the difference between "the cue is wrong" and "the
    ; cue rectangle has drifted off the word it was measured on", which are
    ; different repairs.
    cue := FanslyCueSays(fcfg)
    if (cue != "")
        seen .= "   |   cue at +" fcfg.cueX ",+" fcfg.cueY " read '"
              . (FanslyCueText() = "" ? "" : SubStr(FanslyCueText(), 1, 24))
              . "' -> " (cue = "fansly" ? "FANSLY" : "not Fansly")

    ; Both still true means the two regions are on the SAME window, which on a
    ; two-monitor setup means one of them has never been calibrated where it
    ; actually lives — almost always [Fansly] Region* left at 0,0, which puts the
    ; rail in the top-left corner of whatever screen you are on.
    if (fanUp && infUp)
        return {id: "fansly", cfg: fcfg, short: "Fansly?", value: "Fansly (?)",
                color: "bad",
                detail: seen "   |   BOTH gates pass on this one window: the"
                      . " [Fansly] rail at " fcfg.x "," fcfg.y " and the [Detector]"
                      . " strip at " dcfg.x "," dcfg.y " are both inside it. The"
                      . " engine asks Fansly first, so Fansly wins - calibrate"
                      . " [Fansly] Region* on the screen Fansly is actually on"
                      . " (tools\fansly_probe.ahk)."}

    if fanUp {
        det := FEAT("fanslyDetector")
        return {id: "fansly", cfg: fcfg,
                short: det ? "Fansly" : "Fansly!",
                value: "Fansly",
                color: det ? "" : "warn",
                detail: seen "   |   title matched '" fcfg.win "' and the window"
                      . " covers the rail at " fcfg.x "," fcfg.y
                      . "   |   detector feature: " (det ? "on" : "OFF - the shared"
                      . " keys will not use the rail")}
    }

    if infUp {
        det := FEAT("modelDetector")
        ok  := det && dcfg.win != ""
        gate := (dcfg.win = "")
            ? "[Detector] WinMatch is empty, so only the geometry gate applies"
            : "title matched '" dcfg.win "' and the window covers the strip at "
            . dcfg.x "," dcfg.y
        return {id: "infloww", cfg: dcfg,
                short: ok ? "OF" : "OF!",
                value: "OnlyFans (Infloww)",
                color: ok ? "" : "warn",
                detail: seen "   |   " gate "   |   detector feature: "
                      . (det ? "on" : "OFF - name mode has nothing to read")}
    }

    ; Neither. Not a failure — it is most of the day — but it IS the answer to
    ; "the shared keys do nothing", so it is stated as flatly as the other two.
    return {id: "none", cfg: 0, short: "-", value: "neither", color: "muted",
            detail: seen "   |   this window neither matches '" fcfg.win "' / '"
                  . dcfg.win "' nor covers either region, so nothing is being"
                  . " scanned and [mass.active] keys have no answer"}
}

; ── row 2: which tab, or which row ────────────────────────────────────────────
;  The per-slot counts are carried into the detail line rather than thrown away,
;  because they are the only thing that tells the two failures apart: all zeros
;  is a wrong colour or a wrong region, two large numbers is a wrong TabPitch /
;  RowPitch with one pill straddling two slots. The strip gets the number alone.
DBG_Lit(p) {
    if (p.id = "none")
        return {index: 0, short: "-", value: "-", detail: "nothing to scan",
                color: "muted"}

    if (p.id = "fansly") {
        lit := FanslyLitRow(p.cfg)
        counts := DBG_Counts(lit.counts, "r")
        if !lit.index
            return {index: 0, short: "none lit", value: "no row is lit",
                    color: "bad",
                    detail: counts "   MinCard=" p.cfg.min " CardTol=" p.cfg.tol
                          . "   -  run tools\fansly_probe.ahk"}
        return {index: lit.index, color: "",
                short: "row " lit.index,
                value: "row " lit.index " of " p.cfg.rows,
                detail: counts "   (y " (p.cfg.y + (lit.index - 1) * p.cfg.pitch) ")"}
    }

    lit := TabLitIndex(p.cfg)
    counts := DBG_Counts(lit.counts, "tab")
    if !lit.index
        return {index: 0, short: "none lit", value: "no tab is lit", color: "bad",
                detail: counts "   MinGrey=" p.cfg.min " GreyTol=" p.cfg.tol
                      . "   -  run tools\detector_probe.ahk"}
    return {index: lit.index, color: "",
            short: "tab " lit.index,
            value: "tab " lit.index,
            detail: counts "   (origin " p.cfg.origin " pitch " p.cfg.pitch ")"}
}

; ── row 3: what OCR reads, next to what it should read ────────────────────────
;  Two different questions that get asked as one. What the pixels say is a
;  MEASUREMENT; what it should say comes from the order you taught ([Positional]
;  Pos<n> / [FanslyPos] Pos<n>), and nothing on screen carries that fact. Putting
;  them side by side is the whole point of the row: a name that reads perfectly
;  and a position map that points somewhere else look identical from inside MMA
;  and completely different here.
;
;  In the strip only the EXPECTED name is shown, coloured by whether OCR agrees —
;  green means the two match, red means they do not and the panel will say why.
;  A cell that tried to fit both names would fit neither.
DBG_ReadName(p, lit) {
    global DBG_ocrName, DBG_ocrMs
    DBG_ocrName := "", DBG_ocrMs := 0
    if (p.id = "none" || !lit.index)
        return
    t := A_TickCount
    if (p.id = "fansly") {
        r := FanslyLabelRect(lit.index, p.cfg)
        DBG_ocrName := DBG_Ocr(r.x, r.y, r.w, r.h, p.cfg.scale)
    } else {
        ; The lit pill's own span where the sweep finds one, so this OCRs exactly
        ; what the service OCRs. The fixed slot is the fallback, and it is the
        ; better answer on a theme where the sweep finds nothing at all.
        scan := ScanLitPill(p.cfg)
        if (scan.count >= p.cfg.min && scan.maxX > scan.minX)
            x1 := scan.minX, w := scan.maxX - scan.minX
        else {
            rng := TabRange(lit.index, p.cfg)
            x1 := rng.x1, w := rng.x2 - rng.x1
        }
        DBG_ocrName := DBG_Ocr(x1, p.cfg.y, w, p.cfg.h,
                               LOG_IniInt(MMA_CFG, "Detector", "OcrScale", 3,
                                          "dbg.overlay"))
    }
    DBG_ocrMs := A_TickCount - t
}

DBG_NameRow(p, lit) {
    global DBG_ocrName, DBG_ocrMs
    if (p.id = "none" || !lit.index)
        return {short: "-", value: "-", color: "muted",
                detail: "nothing selected to read a name from"}

    ; What the taught order says this tab/row is. NOT what the name matcher says
    ; — that would be the OCR answer again, wearing a different hat.
    slot := (p.id = "fansly") ? FanslyPosSlot(lit.index) : TabModel(lit.index)
    want := slot ? ModelLabel(slot) : "(nothing mapped to this position)"
    disp := slot ? DBG_Short(ModelDisplayName(slot), slot) : "unmapped"
    got  := (DBG_ocrName = "") ? "(OCR read nothing)" : "'" DBG_ocrName "'"

    if (DBG_ocrName = "")
        return {short: disp " (no ocr)", value: got "  vs  " want, color: "warn",
                detail: "positional mode is unaffected by this and still works;"
                      . " name mode has no answer"}

    owns := false
    if slot {
        if (p.id = "fansly")
            owns := FanslySlotOwnsName(slot, DBG_ocrName)
        else
            owns := _SlotOwnsName(MMA_CFG, slot, DBG_ocrName)
    }
    if owns
        return {short: disp, value: got "  vs  " want, color: "good",
                detail: "match - model " slot " claims this text   ("
                      . DBG_ocrMs " ms)"}

    if !slot
        why := "teach this position: press a mass.select key on it"
    else {
        section := (p.id = "fansly") ? "FanslyMap" : "ActiveMap"
        why := "model " slot " does NOT claim this text - add it under ["
             . section "] File" slot " in mass_gui.cfg"
    }
    return {short: disp " != " SubStr(DBG_ocrName, 1, 12), color: "bad",
            value: got "  vs  " want, detail: why "   (" DBG_ocrMs " ms)"}
}

; ── row 4: what the shared keys would actually do ─────────────────────────────
;  ActiveModelStatus() is the function every [mass.active] key resolves through,
;  so this row is not a second opinion — it is the answer, asked the same way,
;  including its state word. "ambiguous" and "unlearned" are the two that look
;  identical from the keyboard (nothing happens) and are completely different
;  problems.
DBG_ResolvedRow(p) {
    ; This panel's OWN site's mode. It used to append "manual" whenever INFLOWW
    ; was manual, on both panels, because manual was a global that short-circuited
    ; the resolver before Fansly was asked. Each site carries its own now, so the
    ; Fansly panel showing Infloww's mode would be a readout of the wrong setting
    ; in exactly the mixed setup this overlay is opened to diagnose.
    mode := (p.id = "fansly") ? FanslyMatchMode() : ModelMatchMode()
    if (mode = "manual")
        mode := "manual (you pick; no pixels are read)"

    st := ActiveModelStatus()
    if !st.no
        return {short: "none", value: "no model - shared keys do nothing",
                color: "bad",
                detail: "state '" st.state "'   |   match mode: " mode
                      . "   |   the numbered [mass.N] keys still work"}

    massNo := MASS_MassNo(MASS_DOC, st.no)
    return {short: "m" st.no " / mass " massNo,
            value: ModelLabel(st.no) "   mass slot " massNo,
            color: (st.state = "ok") ? "good" : "warn",
            detail: "state '" st.state "'   |   match mode: " mode}
}

; ── row 5: the follow-up already in the conversation ──────────────────────────
;  The expensive one, and the reason it is on a key. NFU_ReadChat OCRs the whole
;  conversation pane; on this machine that is most of a second, and doing it on
;  the 500ms tick would put an OCR between you and every keystroke.
;
;  The f1..f3 search is NFU_LastGroup — the walker's own function, so this can
;  never report a decision the key would not make. PPV is searched here and not
;  there because the walker does not walk PPVs: f-next goes f1 -> f2 -> f3 and
;  stops. Seeing "ppv" means the PPV is in the chat, not that any key is about to
;  send one.
DBG_ReadFu() {
    global DBG_fu, DBG_fuAt
    DBG_fuAt := A_TickCount

    st := ActiveModelStatus()
    n  := st.no ? st.no : ManualModelNo()
    _SetCurModel(n)
    m   := CurMass()
    cfg := NFU_Cfg()

    t    := A_TickCount
    text := NFU_ReadChat(cfg)
    ms   := A_TickCount - t
    if (text = "") {
        DBG_fu := {ok: false, ms: ms, model: n,
                   why: "OCR read NOTHING from the chat pane - check [NextFu]"
                      . " Region* in mass_gui.cfg (" cfg.x "," cfg.y " "
                      . cfg.w "x" cfg.h ")"}
        return
    }

    hay  := NFU_Norm(text)
    r    := NFU_LastGroup(m, hay, cfg)
    ppv  := DBG_PpvAt(m, hay, cfg)
    seen := NFU_MassPresence(m, hay, cfg)
    ; The first line of what it READ, carried into the row. Without it, a region
    ; pointing at the wrong part of the screen and a region pointing at the right
    ; part of an empty chat produce the identical "nothing found" — and the first
    ; one is by far the more common. Seeing your editor's text here answers the
    ; question in one glance instead of a probe run.
    DBG_fu := {ok: true, ms: ms, model: n, chars: StrLen(text),
               head: SubStr(Trim(RegExReplace(text, "\s+", " ")), 1, 64),
               group: r.group, at: r.at, hits: r.hits, ppv: ppv, mass: seen,
               next: NFU_NextWithContent(m, r.group)}
}

; Where the PPV text was last seen in the pane, or 0. Same needles, same
; normalising and the same backwards InStr as NFU_GroupAt, over the four fields
; a PPV actually occupies (the base plus its own three follow-ups) — so the
; position is comparable with the f1..f3 positions and "which came last" is a
; number comparison rather than a guess.
DBG_PpvAt(m, hay, cfg) {
    best := 0
    for _, part in [m.ppv_base, m.ppv_f1, m.ppv_f2, m.ppv_f3] {
        if (Trim(part) = "")
            continue
        for needle in NFU_Needles(part, cfg) {
            at := InStr(hay, needle, true, -1)
            if (at > best)
                best := at
        }
    }
    return best
}

DBG_FuRow() {
    global DBG_fu, DBG_fuAt
    if !DBG_fu
        return {short: "?", value: "not read yet", color: "muted",
                detail: "press ^!F10 with the conversation in front (it OCRs the"
                      . " whole pane, so it is not on the timer)"}

    age := "read " ((A_TickCount - DBG_fuAt) // 1000) "s ago"
    if !DBG_fu.ok
        return {short: "no read", value: "could not read the chat", color: "bad",
                detail: DBG_fu.why "   (" age ")"}

    ; What is furthest DOWN the pane, not the highest number: the pane reads top
    ; to bottom, so position is recency. That is also how NFU_LastGroup picks,
    ; and it is what makes a deliberate re-send of an earlier follow-up read
    ; correctly instead of looking like the walker lost count.
    last := DBG_fu.group ? "f" DBG_fu.group : ""
    if (DBG_fu.ppv > DBG_fu.at)
        last := "ppv"
    onScreen := (last = "") ? "nothing" : last

    detail := "on screen: " onScreen
            . "   f1=" DBG_Pos(DBG_fu.hits[1])
            . " f2=" DBG_Pos(DBG_fu.hits[2])
            . " f3=" DBG_Pos(DBG_fu.hits[3])
            . " ppv=" DBG_Pos(DBG_fu.ppv)
            . "   mass " DBG_fu.mass
            . "   |   model " DBG_fu.model ", " DBG_fu.chars " chars in "
            . DBG_fu.ms " ms, " age
            . "`nread: " DBG_fu.head

    ; f1 is gated on the mass being visible, and that refusal is a decision worth
    ; showing as one: "no follow-up here AND no mass either" means either the
    ; pane is scrolled away from a thread already underway or this chat never got
    ; the mass, and f1 is wrong in both.
    if (!DBG_fu.group && DBG_fu.mass != "seen")
        return {short: onScreen " / -", value: "next_fu: nothing", color: "warn",
                detail: "the mass is " DBG_fu.mass ", so f1 is held back   |   "
                      . detail}
    if !DBG_fu.next
        return {short: onScreen " / -", value: "next_fu: nothing", color: "warn",
                detail: (DBG_fu.group
                    ? "f" DBG_fu.group " is the last follow-up this mass has, and"
                    . " it is already in this chat"
                    : "this mass has no follow-ups at all") "   |   " detail}

    gap := (DBG_fu.next > DBG_fu.group + 1)
         ? "   (this mass has no f" (DBG_fu.group + 1) ")" : ""
    ; "f1 > f2" in the strip: what the chat already holds, and what the key would
    ; send next. Both halves, because "next: f2" alone is unfalsifiable at a
    ; glance — you cannot tell a correct read from a stale one without seeing
    ; what it thinks is already there.
    return {short: onScreen " > f" DBG_fu.next,
            value: "next_fu: f" DBG_fu.next gap, color: "good", detail: detail}
}

; ── plumbing ──────────────────────────────────────────────────────────────────

; A model's name, short enough for a strip cell, falling back to the slot number
; for an unnamed slot — the same rule ModelLabel follows, so an unnamed slot is
; still identifiable here rather than blank.
DBG_Short(name, slot) {
    name := Trim(name)
    if (name = "")
        return "m" slot
    return StrLen(name) > 14 ? SubStr(name, 1, 13) "." : name
}

; "tab1:0 tab2:612 tab3:0" — the counts, spelled out, because they are the only
; useful diagnostic when the answer is "nothing is lit".
DBG_Counts(counts, prefix) {
    out := ""
    for i, n in counts
        out .= (out = "" ? "" : " ") prefix i ":" n
    return out = "" ? "(none)" : out
}

DBG_Pos(at) {
    return at ? at : "-"
}

; OCR a rectangle to one cleaned line; "" on any failure. Same shape as the two
; services' OcrPill/OcrLabel, under its own name because all three would
; otherwise be one name defined twice and AHK does not load that.
DBG_Ocr(x, y, w, h, scale) {
    if (w < 4 || h < 4)
        return ""
    try {
        res := OCR.FromRect(x, y, w, h, {scale: scale, grayscale: 1})
        return Trim(RegExReplace(res.Text, "\s+", " "))
    } catch {
        return ""
    }
}

; ── show me where you are looking ─────────────────────────────────────────────
;  Every region in this program is a FIXED SCREEN RECTANGLE out of mass_gui.cfg,
;  measured on somebody's screen at some point, and none of them announce
;  themselves. A region that has drifted off the thing it was measured on does
;  not fail — it reads whatever is sitting there and reports honestly about the
;  wrong pixels. `[NextFu]` shipping a 1237x727 rectangle from a 1920x1080 layout
;  onto a 3440x1440 screen is exactly that: it lands on the inbox list and the
;  fan's left-hand replies, never on the right-aligned messages MMA itself sent,
;  so the walker looks for its own follow-ups in a place they can never be.
;
;  So: draw the rectangles. Green is the tab/rail scan for whichever platform is
;  in front, accent is the conversation pane the follow-up walker OCRs. Three
;  seconds, click-through, gone.
;
;  -DPIScale on the bars, and it is not optional. Every number here is a PHYSICAL
;  screen pixel — that is what PixelGetColor and OCR.FromRect take — while Gui
;  coordinates are logical by default, so on this 125% display an outline of the
;  NextFu region would be drawn 25% too large and 25% too far out, which is a
;  calibration aid that lies.
global DBG_MARKS := []

DBG_Flash(x, y, w, h, col) {
    global DBG_MARKS
    if (w < 4 || h < 4)
        return
    ; +E0x20 is WS_EX_TRANSPARENT: clicks go straight through to Infloww. An
    ; overlay that eats clicks over the whole conversation pane is how the OCR
    ; region picker once locked the desktop with no way back.
    for _, r in [[x, y, w, 3], [x, y + h - 3, w, 3],
                 [x, y, 3, h], [x + w - 3, y, 3, h]] {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020")
        g.BackColor := col
        g.Show("x" r[1] " y" r[2] " w" r[3] " h" r[4] " NoActivate")
        DBG_MARKS.Push(g)
    }
    SetTimer(DBG_MarksOff, -3000)
}

DBG_MarksOff() {
    global DBG_MARKS
    for _, g in DBG_MARKS
        try g.Destroy()
    DBG_MARKS := []
}

; (*) so it can be a Menu callback as well as a hotkey — a menu hands its item
; name, position and object to whatever it calls, and a zero-parameter function
; throws on all three.
DBG_FlashRegions(*) {
    global DBG_ACCENT, DBG_GOOD, DBG_WARN, DBG_MUTED, MASS_MODELS
    DBG_MarksOff()
    p := DBG_Platform()
    if (p.id = "fansly")
        DBG_Flash(p.cfg.x, p.cfg.y, p.cfg.w, p.cfg.pitch * p.cfg.rows, DBG_GOOD)
    else if (p.id = "infloww") {
        ; The strip in grey, then EACH TAB SLOT inside it. The whole box on its own
        ; cannot show the failure this tool exists for: TabOrigin/TabPitch decide
        ; where slot 1 stops and slot 2 starts, and when they are wrong one pill
        ; straddles both — PILL_PickLit then refuses to pick, correctly, and the
        ; shared keys go dead with nothing on screen to explain it. Seeing the slot
        ; boundaries land in the middle of a tab IS the diagnosis.
        DBG_Flash(p.cfg.x, p.cfg.y, p.cfg.w, p.cfg.h, DBG_MUTED)
        lit := TabLitIndex(p.cfg)
        Loop MASS_MODELS {
            r := TabRange(A_Index, p.cfg)
            DBG_Flash(r.x1, p.cfg.y, r.x2 - r.x1, p.cfg.h,
                      A_Index = lit.index ? DBG_GOOD : DBG_WARN)
        }
    }
    c := NFU_Cfg()
    DBG_Flash(c.x, c.y, c.w, c.h, DBG_ACCENT)

    ; The cue, in amber, and drawn RELATIVE TO THE WINDOW IN FRONT — because that
    ; is how it is read. It is the only region here that is not a screen
    ; coordinate, and seeing it land on the sidebar of whichever window you just
    ; clicked is the whole confirmation that the site row is trustworthy.
    f := FanslyCfg()
    if (f.cueW >= 4 && f.cueH >= 4 && f.cue != "") {
        hwnd := WinExist("A")
        if hwnd {
            wx := 0, wy := 0
            try WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
            DBG_Flash(wx + f.cueX, wy + f.cueY, f.cueW, f.cueH, DBG_WARN)
        }
    }
}

; Keep a window fully on screen after Show. Gui width is DPI-SCALED and the
; screen is measured in physical pixels, so "screen width minus my width" is two
; different units on any display above 100% — at 125% the strip was placed 146px
; past the right edge and the last cell was simply not there.
DBG_Nudge(g) {
    x := 0, y := 0, w := 0, h := 0
    try WinGetPos(&x, &y, &w, &h, "ahk_id " g.Hwnd)
    nx := Max(0, Min(x, A_ScreenWidth  - w - 8))
    ny := Max(0, Min(y, A_ScreenHeight - h - 8))
    if (nx != x || ny != y)
        try WinMove(nx, ny, , , "ahk_id " g.Hwnd)
}

; Swap views in place. Both are shown at the same top-left, so the thing you were
; looking at does not move out from under you — and the one being hidden is
; hidden AFTER the other is up, or the corner flickers empty.
DBG_ToggleView(*) {
    global DBG_view, stripGui, dbgGui, DBG_STRIPW, DBG_STRIPH, DBG_PANW, DBG_PANH
    x := 0, y := 0
    cur := (DBG_view = "strip") ? stripGui : dbgGui
    try WinGetPos(&x, &y, , , "ahk_id " cur.Hwnd)
    if (DBG_view = "strip") {
        DBG_view := "detail"
        dbgGui.Show("x" x " y" y " w" DBG_PANW " h" DBG_PANH " NoActivate")
        DBG_Nudge(dbgGui)
        stripGui.Hide()
    } else {
        DBG_view := "strip"
        stripGui.Show("x" x " y" y " w" DBG_STRIPW " h" DBG_STRIPH " NoActivate")
        DBG_Nudge(stripGui)
        dbgGui.Hide()
    }
}

; The auto-refresh lamp, in both views: a coloured rule under the strip, and a
; sentence in the panel. ^!F8 makes this thing OCR the conversation pane every
; four seconds, which is the one setting here with a cost, so it is never on
; without something on screen saying so.
DBG_ShowAuto() {
    global DBG_auto, lampStrip, lblAuto, DBG_ACCENT, DBG_BG
    try lampStrip.Opt("Background" (DBG_auto ? DBG_ACCENT : DBG_BG))
    try lampStrip.Redraw()
    try lblAuto.Value := DBG_auto ? "auto next_fu: ON (every 4s)" : ""
}

DBG_Quit(*) {
    ExitApp()
}

; ── the keys ──────────────────────────────────────────────────────────────────
;  #SuspendExempt, because the auto-execute section suspended this whole process
;  to silence the hotstrings that came in with mass\runtime.ahk. Without it the
;  overlay would come up and answer none of its own keys.
;  Each one is a single call into the shared action above, which the right-click
;  menu calls too. The bodies used to be written out here; the `global DBG_ocrKey`
;  that DBG_ReadNow now carries is the reason that mattered — a hotkey body is a
;  function, so without the declaration the assignment makes a local, and the views
;  keep showing the cached name it was told to throw away. One copy, one place for
;  that to be right.
#SuspendExempt
^!F10::DBG_ReadNow()

^!F11::DBG_ToggleView()

^!F9::DBG_FlashRegions()

^!F8::DBG_ToggleAuto()

; ^!F5, NOT the ^!F12 the other three probes quit on. That chord is
; `[recorder] toggle` in the live hotkeys.ini, so every probe anyone has ever
; quit has also started or stopped the sequence recorder — silently, and the only
; symptom is the tray icon changing. A probe must not cost you a key, and quitting
; one must not arm something else.
^!F5::DBG_Quit()
#SuspendExempt False
