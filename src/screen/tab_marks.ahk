#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  tab_marks.ahk — vertical divider bars you stick onto your own tab strip.
; ───────────────────────────────────────────────────────────────────────────────
;  A strip of eight near-identical browser tabs is hard to read at a glance, and no
;  amount of detection helps with that: the problem is not that MMA cannot tell them
;  apart, it is that YOU cannot, quickly, forty times an hour.
;
;  So this draws dividers on it. ONE hotkey puts a bar at the pointer. Everything
;  else is the bar itself:
;
;      left-drag a bar     move it
;      right-click a bar   menu — remove, colour, size, add another, hide the lot
;
;  ── ONE HOTKEY, AND WHY IT USED TO BE FOUR ───────────────────────────────────
;  There were four: place, drag-mode, remove, hide. Three of them existed to work
;  around a decision made at the top of this file — that the bars are CLICK-THROUGH
;  (WS_EX_TRANSPARENT), so every click lands on the tab underneath as if they were
;  not there. A window you cannot click is a window you cannot drag or right-click,
;  so every verb had to become a key, and moving one needed a whole mode to
;  temporarily turn the click-through off.
;
;  The reasoning was sound and the conclusion was wrong, because of the scale: a bar
;  is FIVE PIXELS WIDE, and it goes in the GAP between two tabs, which is where a
;  divider goes by definition. The thing being protected was a five-pixel stripe of a
;  180-pixel tab, in the one place on the strip you were never aiming at. That is not
;  worth three hotkeys and a mode.
;
;  So the bars are ordinary little windows now. They keep WS_EX_NOACTIVATE, which is
;  the half that genuinely matters — clicking one never takes focus off the chat box
;  you are typing in — and they lose WS_EX_TRANSPARENT, which is what makes a drag
;  and a right-click menu possible at all.
;
;      [Marks] ClickThrough=1 puts it back, for a strip where a five-pixel dead
;      stripe does turn out to matter. The cost is stated plainly: with it on, a bar
;      cannot be dragged or right-clicked, and the one hotkey is all there is.
;
;  ── THE DRAG IS THE OS's, NOT A TIMER ────────────────────────────────────────
;  WM_NCLBUTTONDOWN with HTCAPTION tells DefWindowProc "the user grabbed this window
;  by its title bar", and it runs the same modal move loop every window on the
;  desktop uses. Nothing to poll, nothing to smooth.
;
;  This replaced a "carry" mode where a picked-up bar chased the pointer on a 25ms
;  timer. It worked and it felt terrible, for a reason no tuning fixes: a timer
;  polls, a drag loop is driven by the mouse messages themselves, so forty ticks a
;  second still trails the cursor and the bar arrives after you stop.
;
;  ── ONE WINDOW PER BAR ───────────────────────────────────────────────────────
;  A bar is a solid rectangle a few pixels wide. So it is a WINDOW a few pixels wide,
;  filled with its own colour: no chroma key (nothing to punch out), no controls
;  (nothing to lay out), and moving one is a WinMove rather than a teardown.
;
;  The version before this drew every mark as a control inside ONE overlay window
;  spanning the full client width, keyed transparent with WinSetTransColor. Three
;  things went wrong with that, all structural rather than typos:
;
;    FLICKER. MARKS_Sync cached the client rect to avoid redrawing, then called
;    MARKS_Build, whose first act — MARKS_Hide — cleared that cache. The guard could
;    never hold, so a full-width always-on-top layered window was destroyed and
;    recreated every 400ms, forever, on top of a compositing browser.
;
;    A MAGENTA FLASH. WinSetTransColor can only be applied to a window that already
;    exists, so every rebuild showed a full-width magenta band for one frame.
;
;    PLACEMENT. The overlay had no -DPIScale. Gui.Show and WinMove multiply their
;    coordinates by the display scaling; MouseGetPos does not. At 125% every bar
;    landed a quarter of the way further right than the pointer that placed it. Same
;    trap and same fix as core/utils.ahk and screen/ocr_grab.ahk.
;
;  ── STARS ARE GONE ───────────────────────────────────────────────────────────
;  There used to be a second kind of mark, a gold ★, on its own key. Removed rather
;  than deprecated: a glyph needs a font and a transparent background, a transparent
;  background needs the chroma key, and the chroma key is where all three bugs above
;  came from. A rectangle needs none of it. Old `star,x,y` lines are dropped.
;
;  ── WHAT THIS DELIBERATELY IS NOT ────────────────────────────────────────────
;  It is NOT a readout. A bar means whatever you decided it means when you put it
;  there — not "the active model", not "the locked one", not "the one the detector
;  resolved". Nothing here reads a pixel, and nothing here writes a model setting.
;  Which model is live is the lock badge's job, and it looks nothing like this.
;
;  ── where a bar lives ────────────────────────────────────────────────────────
;  In the TARGET WINDOW's client coordinates, exactly where you put it. Two
;  consequences, both wanted: move or resize the window and the bars stay on their
;  tabs, and nothing has to be calibrated first — no TabOrigin, no TabPitch and no
;  working detector, which is what lets it work on a strip MMA cannot read at all.
;
;      mass_gui.cfg  [Marks]
;      Bar1 = 412,44
;      Bar2 = 338,44,4AC9FF      ← the third field is that ONE bar's colour
;
;  Hand-editable, and deleting the Bar lines is how you clear the lot.
;
;  ── the thing the bars must not do ───────────────────────────────────────────
;  BE READ AS A TAB. MMA's own pill scan BitBlts the screen at fixed coordinates
;  (screen/pill_scan.ahk), so anything drawn over the strip is a candidate for being
;  counted as tab-coloured pixels — a decoration silently breaking the detector,
;  which is the worst class of bug in this tree. SetWindowDisplayAffinity with
;  WDA_EXCLUDEFROMCAPTURE takes each bar out of screen capture, so a scan reads the
;  tabs and not the dividers. See MARKS_ExcludeFromCapture for what that does and
;  does not cover.
; ═══════════════════════════════════════════════════════════════════════════════

global _marks      := []    ; [{x, y, col}] — centres in CLIENT coords; col may be ""
global _marksWins  := []    ; one tiny Gui per bar, same indices as _marks
global _marksOn    := 1     ; the layer's own show/hide, remembered in the cfg
global _marksDrag  := 0     ; index of the bar inside Windows' move loop, or 0
global _marksMenu  := 0     ; index whose right-click menu is open, or 0
global _marksRect  := ""    ; the client rect the bars were last positioned for
global _marksShown := false ; are the bar windows currently visible?
global _marksLegacy := false ; did this load migrate old Mark<n> lines?

; The right-click palette. Eight, because a submenu you have to read is a submenu
; that costs more than the colour is worth — and because "Custom…" is one item away
; for anything not on it.
global MARKS_PALETTE := [["Coral",  "FF6B7A"], ["Blue",   "4AC9FF"],
                         ["Green",  "5BD98A"], ["Amber",  "FFC94A"],
                         ["Purple", "C08BFF"], ["Pink",   "FF7AD9"],
                         ["White",  "F0F0F0"], ["Grey",   "808A99"]]

; ── look ──────────────────────────────────────────────────────────────────────
;  Every one of these is a cfg key because "nicer" is a matter of taste and a taste
;  is not worth a code change — but none of them needs to be EDITED any more, because
;  the right-click menu writes them. The section is still the place to look when you
;  want to know what a bar is, and still hand-editable.
;
;  StarChar / StarColor / StarSize / ShadowColor / ChromaKey / EditColor / EditWidth
;  are no longer read. They are LEFT in any existing mass_gui.cfg rather than deleted
;  — they cost nothing there, and a downgrade finds its settings intact.
MARKS_Cfg() {
    global MMA_CFG
    return {win:  Trim(IniRead(MMA_CFG, "Marks", "WinMatch",
                               Trim(IniRead(MMA_CFG, "Detector", "WinMatch",
                                            "Infloww Messages")))),
            ; The colour of a bar that has not been given one of its own.
            col:  Trim(IniRead(MMA_CFG, "Marks", "SepColor", "FF6B7A")),
            ; Clamped, not trusted. These are the WIDTH AND HEIGHT OF A WINDOW: a
            ; hand-edited 0 would be a window with no pixels — invisible, and so
            ; impossible to right-click your way back out of — and a negative one
            ; throws inside a timer.
            w:    Max(3, LOG_IniInt(MMA_CFG, "Marks", "SepWidth",   5)),
            h:    Max(6, LOG_IniInt(MMA_CFG, "Marks", "SepHeight", 36)),
            ; The escape hatch. 1 restores WS_EX_TRANSPARENT — no dead stripe, and no
            ; drag and no menu either, because a window that cannot be clicked cannot
            ; offer them. See the header.
            thru: LOG_IniInt(MMA_CFG, "Marks", "ClickThrough", 0)}
}

; ── the bars themselves ───────────────────────────────────────────────────────
; A list of {x, y, col}. Bad lines are dropped with a warning rather than throwing:
; this file is hand-editable by design, and one fat-fingered line must not take the
; engine down at load.
;
; Reads BOTH formats. `Bar<n> = x,y[,colour]` is what this writes; `Mark<n> =
; kind,x,y` is what the star-and-separator version wrote, and its `sep` entries are
; migrated while its `star` entries are dropped — the glyph they name does not exist
; any more, and keeping a coordinate for it would be keeping a promise MMA cannot
; make.
MARKS_Load() {
    global MMA_CFG, _marksLegacy
    out := [], legacy := []
    body := ""
    try body := IniRead(MMA_CFG, "Marks", , "")
    for line in StrSplit(body, "`n", "`r") {
        eq := InStr(line, "=")
        if !eq
            continue
        key := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (SubStr(key, 1, 3) = "Bar") {
            p := StrSplit(val, ",")
            if (p.Length < 2) {
                LOGW("marks", "[Marks] " key " is not 'x,y[,colour]' — ignored ("
                            . val ")")
                continue
            }
            ; The colour is OPTIONAL and per-bar. Absent means "whatever SepColor
            ; says", so changing the default still moves every bar that never had an
            ; opinion of its own.
            col := (p.Length >= 3) ? _MARKS_CleanHex(Trim(p[3])) : ""
            out.Push({x: LOG_Int(Trim(p[1]), 0, "[Marks] " key " x"),
                      y: LOG_Int(Trim(p[2]), 0, "[Marks] " key " y"),
                      col: col})
            continue
        }
        if (SubStr(key, 1, 4) != "Mark")            ; the look keys live here too
            continue
        p := StrSplit(val, ",")
        if (p.Length < 3)
            continue
        kind := StrLower(Trim(p[1]))
        if (kind = "star") {
            LOGI("marks", "[Marks] " key " is a star, which no longer exists —"
                        . " dropped. Place a bar where you want the divider.")
            continue
        }
        if (kind != "sep") {
            LOGW("marks", "[Marks] " key " has kind '" kind "', which is not sep —"
                        . " ignored")
            continue
        }
        legacy.Push({x: LOG_Int(Trim(p[2]), 0, "[Marks] " key " x"),
                     y: LOG_Int(Trim(p[3]), 0, "[Marks] " key " y"), col: ""})
    }
    ; Bar lines win outright. If both formats are present the Bar ones are the ones
    ; this version wrote, and re-adding the old separators underneath them would
    ; silently double every divider the user has already re-placed.
    if (out.Length || !legacy.Length)
        return out
    _marksLegacy := true
    LOGI("marks", "migrating " legacy.Length " separator(s) from the old [Marks]"
                . " Mark<n> format to Bar<n>")
    return legacy
}

; "#4AC9FF" / "4ac9ff" → "4AC9FF", or "" for anything that is not six hex digits.
; Returning "" rather than a guess matters: it means "no colour of its own", which
; is a real and common state, and a fallback to black would paint an invisible bar
; on a dark strip.
_MARKS_CleanHex(s) {
    s := Trim(s)
    if (SubStr(s, 1, 1) = "#")
        s := SubStr(s, 2)
    if !RegExMatch(s, "^[0-9A-Fa-f]{6}$") {
        if (s != "")
            LOGW("marks", "'" s "' is not a six-digit hex colour — ignored")
        return ""
    }
    return StrUpper(s)
}

; Rewritten whole, because a delete is a renumber. IniDelete of the section would
; take the look keys with it, so they are read first and put back. Old Mark<n>
; lines are NOT put back — this is where the migration becomes permanent.
MARKS_Save(marks) {
    global MMA_CFG
    keep := []
    body := ""
    try body := IniRead(MMA_CFG, "Marks", , "")
    for line in StrSplit(body, "`n", "`r") {
        t := Trim(line)
        if (t = "" || SubStr(t, 1, 3) = "Bar" || SubStr(t, 1, 4) = "Mark")
            continue
        keep.Push(t)
    }
    try IniDelete(MMA_CFG, "Marks")
    for line in keep {
        eq := InStr(line, "=")
        if eq
            try IniWrite(Trim(SubStr(line, eq + 1)), MMA_CFG, "Marks",
                         Trim(SubStr(line, 1, eq - 1)))
    }
    for i, m in marks
        try IniWrite(m.x "," m.y (m.col != "" ? "," m.col : ""),
                     MMA_CFG, "Marks", "Bar" i)
    LOGI("marks", marks.Length " bar(s) saved to [Marks] in mass_gui.cfg")
}

; ── the one hotkey ────────────────────────────────────────────────────────────
;  Put a bar where the pointer is. That is the whole keyboard surface of this
;  feature; move, colour, size, remove and hide are all on the bar's own right-click
;  menu.
;
;  It also UNHIDES the layer, which is what makes "hide all bars" safe to offer from
;  a menu that is itself only reachable by right-clicking a visible bar. Without
;  that, hiding would be a one-way door out of the feature.
MARKS_Place(*) {
    global _marks, _marksOn, MMA_CFG
    cfg := MARKS_Cfg()
    x := 0, y := 0
    if !_MARKS_PointerIn(cfg, &x, &y) {
        LOG_Bail("marks", "'" cfg.win "' is not open, so there is nothing to mark."
                        . " [Marks] WinMatch says which window bars belong to.")
        _MARKS_Toast("No " cfg.win " window")
        return
    }
    if !_marksOn {
        _marksOn := 1
        try IniWrite(1, MMA_CFG, "Marks", "Visible")
        LOGI("marks", "the layer was hidden; placing a bar brought it back")
    }
    _marks.Push({x: x, y: y, col: ""})
    MARKS_Save(_marks)
    LOGI("marks", "bar added at " x "," y " (client coords of '" cfg.win "')")
    _MARKS_Toast(cfg.thru ? "Bar placed"
                          : "Bar placed`ndrag it, or right-click it for the menu")
    MARKS_Sync()
}

; ── the pointer, in the target window's client coordinates ────────────────────
;  Client, not screen: a bar has to survive the window moving, and a maximized
;  window's rect starts at -8,-8 — the exact offset that would put every bar a few
;  pixels off its tab.
_MARKS_PointerIn(cfg, &x, &y) {
    if !WinExist(cfg.win)
        return false
    prev := A_CoordModeMouse
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    CoordMode "Mouse", prev
    ccx := 0, ccy := 0
    try WinGetClientPos(&ccx, &ccy, , , cfg.win)
    x := mx - ccx, y := my - ccy
    return true
}

; Which bar a window handle belongs to, or 0 for a window that is not one of ours.
_MARKS_IndexOfHwnd(hwnd) {
    global _marksWins
    for i, g in _marksWins
        if (g.Hwnd = hwnd)
            return i
    return 0
}

; ── the drag ──────────────────────────────────────────────────────────────────
;  Windows' own move loop, not a timer. See the header.

; Left button down on a bar → hand it straight to the OS.
;
; Returns 0 to swallow the click, so it cannot also do whatever a click on a
; caption-less window would otherwise do. Anything that is not one of our bars falls
; through untouched — this handler sees every WM_LBUTTONDOWN the script's windows
; get, including the main window's.
_MARKS_OnLButtonDown(wParam, lParam, msg, hwnd) {
    global _marksDrag
    idx := _MARKS_IndexOfHwnd(hwnd)
    if !idx
        return
    _marksDrag := idx
    ; 0xA1 = WM_NCLBUTTONDOWN, 2 = HTCAPTION.
    ;
    ; The Control parameter is OMITTED, not passed as 0. PostMessage's 4th parameter
    ; is the control, and a literal 0 there throws "Target window not found" — a
    ; trap this tree has already paid for once.
    try PostMessage(0xA1, 2, 0, , "ahk_id " hwnd)
    return 0
}
OnMessage(0x0201, _MARKS_OnLButtonDown)

; The move loop ended. Read where the bar actually finished and write it down.
;
; WM_EXITSIZEMOVE rather than a mouse-up hook: the loop is modal and owns the mouse
; until it decides otherwise, so its own "I am finished" message is the only reading
; guaranteed to come after the final move.
_MARKS_OnExitSizeMove(wParam, lParam, msg, hwnd) {
    global _marksDrag, _marks, _marksRect
    if !_marksDrag
        return
    idx := _marksDrag
    _marksDrag := 0
    if (idx > _marks.Length || _MARKS_IndexOfHwnd(hwnd) != idx)
        return
    cfg := MARKS_Cfg()
    try {
        WinGetPos(&wx, &wy, , , hwnd)
        ccx := 0, ccy := 0
        WinGetClientPos(&ccx, &ccy, , , cfg.win)
        ; Back to the centre, in client coords — the inverse of what MARKS_Sync does
        ; when it positions one. Stored as a centre because that is what you aim at.
        _marks[idx].x := (wx - ccx) + cfg.w // 2
        _marks[idx].y := (wy - ccy) + cfg.h // 2
    } catch as e {
        LOGW("marks", "could not read where bar " idx " was dropped — it will snap"
                    . " back to where it was. " LOG_Err(e))
        _marksRect := ""
        MARKS_Sync()
        return
    }
    LOGI("marks", "bar " idx " dragged to " _marks[idx].x "," _marks[idx].y)
    MARKS_Save(_marks)
    ; The window is already where it belongs; this only refreshes the cached rect so
    ; the next tick does not think it has drifted.
    _marksRect := ""
    MARKS_Sync()
}
OnMessage(0x0232, _MARKS_OnExitSizeMove)

; ── the right-click menu ──────────────────────────────────────────────────────
;  Everything that is not "place a bar" lives here, which is what got the hotkey
;  count from four down to one. Built fresh on every click rather than once at load,
;  because half of it describes the bar you clicked — its colour is ticked, and the
;  hide item names the key that brings the layer back.
_MARKS_OnRButtonUp(wParam, lParam, msg, hwnd) {
    global _marksMenu, _marks
    idx := _MARKS_IndexOfHwnd(hwnd)
    if !idx
        return
    if (idx > _marks.Length)
        return
    _marksMenu := idx
    try _MARKS_ShowMenu(idx)
    catch as e
        LOGW("marks", "could not open the bar menu — " LOG_Err(e))
    _marksMenu := 0
    return 0
}
OnMessage(0x0205, _MARKS_OnRButtonUp)

_MARKS_ShowMenu(idx) {
    global _marks, MARKS_PALETTE
    cfg := MARKS_Cfg()
    cur := _marks[idx].col

    colours := Menu()
    for _, sw in MARKS_PALETTE {
        colours.Add(sw[1], _MARKS_SetColour.Bind(idx, sw[2], false))
        if (cur = sw[2])
            colours.Check(sw[1])
    }
    colours.Add()
    colours.Add("Custom…", _MARKS_CustomColour.Bind(idx, false))
    colours.Add()
    ; "Default" is not a ninth colour, it is the ABSENCE of one — the bar goes back
    ; to following [Marks] SepColor, so changing that later still moves it.
    colours.Add("Use the default (" cfg.col ")", _MARKS_SetColour.Bind(idx, "", false))
    if (cur = "")
        colours.Check("Use the default (" cfg.col ")")
    colours.Add()
    colours.Add("Apply this colour to ALL bars", _MARKS_ApplyColourToAll.Bind(idx))

    size := Menu()
    size.Add("Taller",    _MARKS_Resize.Bind("SepHeight",  6))
    size.Add("Shorter",   _MARKS_Resize.Bind("SepHeight", -6))
    size.Add()
    size.Add("Wider",     _MARKS_Resize.Bind("SepWidth",   2))
    size.Add("Narrower",  _MARKS_Resize.Bind("SepWidth",  -2))
    size.Add()
    ; Size is deliberately GLOBAL, not per bar. Dividers that are not all the same
    ; height do not read as a set of dividers, they read as a mistake.
    size.Add("Reset (5 × 36)", _MARKS_ResetSize)

    m := Menu()
    m.Add("Remove this bar", _MARKS_MenuRemove.Bind(idx))
    m.Add()
    m.Add("Colour", colours)
    m.Add("Size (all bars)", size)
    m.Add()
    m.Add("Add another bar here", _MARKS_MenuAddHere.Bind(idx))
    m.Add()
    m.Add("Hide all bars   (" HK_Key("marks.bar") " brings them back)",
          _MARKS_MenuHide)
    m.Show()
}

; ── what the menu does ────────────────────────────────────────────────────────
;  Every one of these ends the same way: change the list, save it, repaint. The save
;  is not deferred to a "done" step, because there is no such step — the menu closes
;  on the click and there would be nothing left to press.

_MARKS_MenuRemove(idx, *) {
    global _marks
    if (idx > _marks.Length)
        return
    _marks.RemoveAt(idx)
    MARKS_Save(_marks)
    LOGI("marks", "bar " idx " removed from its menu; " _marks.Length " left")
    MARKS_Sync()
}

; A new bar a little to the right of the one you clicked, rather than under the
; pointer. The pointer is ON a bar — that is how the menu opened — so placing there
; would stack two in the same pixel and you would drag one off the other to find out.
_MARKS_MenuAddHere(idx, *) {
    global _marks
    if (idx > _marks.Length)
        return
    src := _marks[idx]
    _marks.Push({x: src.x + 40, y: src.y, col: src.col})
    MARKS_Save(_marks)
    LOGI("marks", "bar added from bar " idx "'s menu, 40px to its right")
    _MARKS_Toast("Bar added — drag it where you want it")
    MARKS_Sync()
}

_MARKS_MenuHide(*) {
    global _marksOn, MMA_CFG
    _marksOn := 0
    try IniWrite(0, MMA_CFG, "Marks", "Visible")
    LOGI("marks", "all bars hidden from the menu — " HK_Key("marks.bar")
                . " places one and brings the layer back")
    _MARKS_Toast("Bars hidden`n" HK_Key("marks.bar") " brings them back")
    MARKS_Sync()
}

; col := "" means "no colour of its own", which is how a bar goes back to following
; SepColor. `quiet` is for the apply-to-all loop, which saves and repaints once at
; the end rather than once per bar.
_MARKS_SetColour(idx, col, quiet, *) {
    global _marks
    if (idx > _marks.Length)
        return
    _marks[idx].col := col
    if quiet
        return
    MARKS_Save(_marks)
    LOGI("marks", "bar " idx " colour → " (col = "" ? "default" : col))
    _MARKS_Repaint()
}

_MARKS_ApplyColourToAll(idx, *) {
    global _marks
    if (idx > _marks.Length)
        return
    col := _marks[idx].col
    for i, _ in _marks
        _marks[i].col := col
    MARKS_Save(_marks)
    LOGI("marks", _marks.Length " bar(s) set to " (col = "" ? "the default" : col))
    _MARKS_Repaint()
}

; The system colour dialog. Worth the DllCall rather than a longer palette: "change
; the colour" means the colour you want, and a fixed list is only ever an
; approximation of that.
_MARKS_CustomColour(idx, quiet, *) {
    global _marks
    if (idx > _marks.Length)
        return
    cfg := MARKS_Cfg()
    start := (_marks[idx].col != "") ? _marks[idx].col : cfg.col
    picked := _MARKS_ChooseColour(start)
    if (picked = "")            ; cancelled
        return
    _MARKS_SetColour(idx, picked, quiet)
}

; The system colour dialog now lives in core/theme.ahk as THEME_ChooseColour —
; the file that owns every colour in MMA — because the reply-timer tiers in
; ui/settings_window.ahk need the same dialog and a second copy of a 72-byte
; hand-packed struct is a second place to get the x64 offsets wrong.
;
; The engine reaches theme.ahk through mass/runtime.ahk → core/utils.ahk, so this
; costs no include. _MARKS_SwapRB and _MARKS_HexVal went with it.
_MARKS_ChooseColour(startHex) {
    return THEME_ChooseColour(startHex, "FF6B7A")
}

; Size lives in the cfg, so this nudges the cfg and rebuilds. Clamped at both ends:
; a bar with no pixels cannot be right-clicked, so it would take the menu — and
; therefore the only way back — with it.
_MARKS_Resize(key, delta, *) {
    global MMA_CFG
    def := (key = "SepWidth") ? 5 : 36
    lo  := (key = "SepWidth") ? 3 : 6
    hi  := (key = "SepWidth") ? 40 : 200
    cur := LOG_IniInt(MMA_CFG, "Marks", key, def)
    val := Max(lo, Min(hi, cur + delta))
    if (val = cur) {
        _MARKS_Toast("Already at the " (delta > 0 ? "biggest" : "smallest") " size")
        return
    }
    try IniWrite(val, MMA_CFG, "Marks", key)
    LOGI("marks", "[Marks] " key " " cur " → " val)
    MARKS_Rebuild()
}

_MARKS_ResetSize(*) {
    global MMA_CFG
    try IniWrite(5,  MMA_CFG, "Marks", "SepWidth")
    try IniWrite(36, MMA_CFG, "Marks", "SepHeight")
    LOGI("marks", "bar size reset to 5 x 36")
    MARKS_Rebuild()
}

_MARKS_Toast(text) {
    ToolTip(text)
    SetTimer(_MARKS_ClearToast, -1600)
}
_MARKS_ClearToast() {
    ToolTip()
}

; ── the bar windows ───────────────────────────────────────────────────────────
;  One per bar, created once and thereafter only MOVED. See the header: the version
;  before this rebuilt its overlay on every tick, and that is what flickered.

; A single bar. The window IS the mark — no controls, no glyph, no transparency key,
; so there is nothing to lay out and nothing that can arrive wearing a black box.
;
; -DPIScale is load-bearing, not tidiness. Gui.Show and WinMove coordinates are
; multiplied by the display scaling when it is on, and MouseGetPos coordinates are
; not — so on any display above 100% every bar lands proportionally right of the
; pointer that placed it. Same reasoning as core/utils.ahk and screen/ocr_grab.ahk.
;
; WS_EX_NOACTIVATE (0x08000000) is always on: clicking a bar — to drag it, or to open
; its menu — must never take focus off the chat box you are typing into.
;
; WS_EX_TRANSPARENT (0x20) is only on when [Marks] ClickThrough says so. It is what
; makes a bar invisible to the mouse, and therefore what makes it undraggable and
; un-right-clickable. See the header for why the default flipped.
_MARKS_NewBar(cfg, colour) {
    opt := "+AlwaysOnTop -Caption +ToolWindow -SysMenu -DPIScale +E0x08000000"
    if cfg.thru
        opt .= " +E0x20"
    g := Gui(opt)
    g.BackColor := (colour != "") ? colour : cfg.col
    g.MarginX := 0, g.MarginY := 0
    ; Created hidden and positioned by MARKS_Sync a moment later, so a new bar never
    ; appears at 0,0 for a frame on its way to where you put it.
    g.Show("NoActivate Hide x0 y0 w" cfg.w " h" cfg.h)
    MARKS_ExcludeFromCapture(g.Hwnd)
    return g
}

; Push each bar's colour onto its window. Separate from positioning because a colour
; change moves nothing, and repainting on the 400ms tick would be a repaint per tick
; forever.
_MARKS_Repaint() {
    global _marks, _marksWins
    cfg := MARKS_Cfg()
    for i, g in _marksWins {
        if (i > _marks.Length)
            break
        try {
            g.BackColor := (_marks[i].col != "") ? _marks[i].col : cfg.col
            WinRedraw(g)
        } catch as e
            LOGV("marks", "could not repaint bar " i " — " LOG_Err(e))
    }
}

; Make the window list the same length as the bar list. The ONLY place a bar window
; is created or destroyed — the timer never does, which is the whole fix.
;
; Clearing _marksRect on a change is what tells MARKS_Sync its cached "nothing
; moved" answer is stale. That coupling used to run the other way (Build cleared the
; cache Sync had just set) and was the flicker.
_MARKS_Reconcile(cfg) {
    global _marks, _marksWins, _marksRect
    changed := false
    while (_marksWins.Length > _marks.Length) {
        try _marksWins[_marksWins.Length].Destroy()
        _marksWins.Pop()
        changed := true
    }
    while (_marksWins.Length < _marks.Length) {
        _marksWins.Push(_MARKS_NewBar(cfg, _marks[_marksWins.Length + 1].col))
        changed := true
    }
    if changed {
        _marksRect := ""
        ; A removal renumbers, so bar 2's window may now be showing bar 3's colour.
        _MARKS_Repaint()
    }
    return changed
}

; Follows the target window and is up only while that window is ACTIVE. Not merely
; "exists": these are dividers drawn at fixed offsets inside one window's client
; area, and left up while something else is in front they would be coloured bars
; floating over somebody else's application.
;
; Clicking a bar does NOT break that test, which is the quiet reward for keeping
; WS_EX_NOACTIVATE: the browser stays the active window throughout a drag and for as
; long as the menu is open, so nothing has to be special-cased for either.
MARKS_Sync(*) {
    global _marks, _marksWins, _marksOn, _marksDrag, _marksMenu, _marksRect
    global _marksShown
    ; Windows owns the mouse and the bar's position for the length of a drag, and the
    ; menu is modal. A WinMove or a WinHide from this timer in the middle of either
    ; would fight it and snap the bar out from under the user's hand.
    if (_marksDrag || _marksMenu)
        return
    cfg := MARKS_Cfg()
    if (!_marksOn || !WinActive(cfg.win)) {
        _MARKS_HideAll()
        return
    }
    ccx := 0, ccy := 0, ccw := 0, cch := 0
    try WinGetClientPos(&ccx, &ccy, &ccw, &cch, cfg.win)
    if (!ccw || !cch) {
        _MARKS_HideAll()
        return
    }

    _MARKS_Reconcile(cfg)

    rect := ccx "," ccy "," ccw "," cch
    ; The guard that could never hold before. Nothing below this line clears
    ; _marksRect, so a still window with a settled bar list costs one WinActive and
    ; one WinGetClientPos per tick and touches no window at all.
    if (_marksShown && rect = _marksRect)
        return
    _marksRect := rect

    for i, m in _marks {
        try {
            WinMove(ccx + m.x - cfg.w // 2, ccy + m.y - cfg.h // 2, cfg.w, cfg.h,
                    _marksWins[i])
            if !_marksShown
                WinShow(_marksWins[i])
        } catch as e
            LOGV("marks", "could not position bar " i " — " LOG_Err(e))
    }
    _marksShown := true
    LOGV("marks", _marks.Length " bar(s) positioned over '" cfg.win "'")
}

; Hidden, not destroyed. Tabbing away from the browser and back is constant, and
; tearing the windows down for it is exactly the cost this rework removes.
_MARKS_HideAll() {
    global _marksWins, _marksShown, _marksRect
    if !_marksShown
        return
    for _, g in _marksWins
        try WinHide(g)
    _marksShown := false
    _marksRect  := ""
}

; Throw the windows away and let the next Sync build them again. For a change of
; size or click-through, which are baked into the window rather than into a control.
MARKS_Rebuild() {
    global _marksWins, _marksShown, _marksRect
    for _, g in _marksWins
        try g.Destroy()
    _marksWins := [], _marksShown := false, _marksRect := ""
    MARKS_Sync()
}

; ── keeping the bars out of MMA's own screen reads ────────────────────────────
;  WDA_EXCLUDEFROMCAPTURE (0x11) tells the compositor to leave a window out of
;  screen capture: it stays visible to you and disappears from anything that grabs
;  the desktop. That matters here more than it looks, because MMA reads the tab
;  strip by BitBlt-ing those exact pixels (screen/pill_scan.ahk) — a bar parked on
;  a tab is otherwise a decoration that silently changes what the detector counts.
;
;  What it does NOT do: it is Windows 10 2004 and later, and it is a request to the
;  compositor rather than a guarantee about every capture path ever written. So it
;  is belt and braces, not a licence to stop thinking — if the tab detector starts
;  miscounting on a machine with bars on the strip, take the bars off the strip
;  first and say so in the report.
MARKS_ExcludeFromCapture(hwnd) {
    ; Failure is fine and is logged at VERB only: on an older build the call simply
    ; does not exist, and the bars are still perfectly usable.
    try {
        if !DllCall("SetWindowDisplayAffinity", "ptr", hwnd, "uint", 0x11)
            LOGV("marks", "SetWindowDisplayAffinity refused — the bars will appear"
                        . " in screen captures, including MMA's own tab-strip scan")
    } catch as e
        LOGV("marks", "SetWindowDisplayAffinity is not available here — " LOG_Err(e))
}

; ── wiring ────────────────────────────────────────────────────────────────────
;  Called by whoever owns the process this runs in; the engine does it, next to the
;  lock badge's timer, because the engine is the process that is always up and
;  already owns the key.
MARKS_Start() {
    global MMA_CFG, _marksOn, _marks, _marksLegacy
    _marksOn := LOG_IniInt(MMA_CFG, "Marks", "Visible", 1)
    _marks   := MARKS_Load()
    ; Write the migration through immediately rather than waiting for the first edit.
    ; Left unsaved it would re-run on every start, and the old star lines would sit
    ; in the cfg looking like marks that ought to be on screen.
    if _marksLegacy
        MARKS_Save(_marks)
    ; ONE key. marks.edit, marks.remove and marks.visible were retired into the
    ; right-click menu; an old hotkeys.ini keeps their lines and nothing reads them.
    HK_Bind("marks.bar", MARKS_Place)
    MARKS_Sync()
    ; 400ms, and nothing faster is ever needed: the only thing this tick does is
    ; notice that the browser window moved. Dragging a bar does not come through here
    ; at all — Windows' own move loop owns that, which is the point of using it.
    SetTimer(MARKS_Sync, 400)
}
