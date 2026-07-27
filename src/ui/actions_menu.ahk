#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  actions_menu.ahk — "what can MMA do, and what key was that again?"
; ───────────────────────────────────────────────────────────────────────────────
;  One searchable window over EVERY action in the registry, with the key that
;  runs it. Press Enter (or double-click) and it runs — including actions with no
;  key bound at all, which is the only way to reach those without editing the ini.
;
;  Nothing is listed here by hand. The rows come straight from hotkeys.ahk's
;  HK_ORDER / HK_META, so declaring a new HK_Def makes it appear, and rebinding a
;  key in the Hotkeys GUI updates what it shows. There is no second list to drift.
;
;  Included by main_window.ahk rather than run on its own: mass_gui is always up, so
;  the menu is always one key away, and it can reach every other script through
;  HK_Broadcast without being a startup script of its own.
;
;  How running an action works (see _HK_OnFire in hotkeys.ahk): we broadcast the
;  action's INDEX and whichever script bound it answers. Two things have to happen
;  before that, in order:
;    1. Un-suspend. While the window is open the other scripts are suspended, so
;       typing a search term cannot fire a hotstring and Up/Down cannot reach
;       1_mass's "Up" = focus-top-chat.
;    2. Give the focus back. Almost every action clicks or types into whatever was
;       in front — and the context gates (`when`) test the ACTIVE window, so a
;       Discord-only action must not be judged while this menu is in front.
; ═══════════════════════════════════════════════════════════════════════════════

; palette — matched to hotstrings_window.ahk so the two windows read as one app
global ACT_BG      := "15141C"
global ACT_LISTBG  := "1B1A24"
global ACT_FIELDBG := "2A2836"
global ACT_TXT     := "E6E4EE"
global ACT_MUTED   := "8E8AA6"
global ACT_ACCENT  := "B89CFF"

global ACT_CFG   := MMA_CFG
global _actGui   := 0
global _actLV    := 0
global _actFind  := 0
global _actCount := 0
global _actSends := 0
global _actOpen  := false
global _actPrev  := 0        ; window that had focus when we opened
global _actPinBtn := 0
global _actHint  := 0

; Quick Actions: the pinned subset, as big buttons.
global QA_MAX     := 12      ; buttons in the pool; pins past this are not shown
global _qaGui     := 0
global _qaBtns    := []
global _qaEmpty   := 0
global _qaFoot    := 0
global _qaOpen    := false
global _qaPrev    := 0
global _qaPins    := []      ; ids currently on the buttons, parallel to _qaBtns

HK_Bind("gui.actions", ActionsToggle)
HK_Bind("gui.quickActions", QuickToggle)

; ── pins ──────────────────────────────────────────────────────────────────────
;  The Quick Actions window (below) shows these as big buttons. Stored as an
;  ORDERED csv of ids rather than a key each, because the order is the button
;  order — that is the whole point of pinning something.
;
;  Ids, not indices: HK_ORDER positions shift the moment a HK_Def is added above
;  them, and a pin that silently starts pointing at a different action is worse
;  than one that disappears.

ActionsPins() {
    global ACT_CFG
    out := []
    for id in StrSplit(IniRead(ACT_CFG, "Actions", "Pinned", ""), ",") {
        id := Trim(id)
        ; Drop anything no longer declared, so a renamed action cannot leave a
        ; button that fires nothing.
        if (id != "" && HK_META.Has(id))
            out.Push(id)
    }
    return out
}

ActionsPinsSave(list) {
    global ACT_CFG
    csv := ""
    for id in list
        csv .= (csv = "" ? "" : ",") id
    try IniWrite(csv, ACT_CFG, "Actions", "Pinned")
}

ActionsIsPinned(id) {
    for p in ActionsPins()
        if (p = id)
            return true
    return false
}

; Toggle, keeping pin order: a re-pin goes to the end, never back to its old slot.
ActionsTogglePin(id) {
    pins := ActionsPins()
    kept := []
    found := false
    for p in pins {
        if (p = id)
            found := true
        else
            kept.Push(p)
    }
    if !found
        kept.Push(id)
    ActionsPinsSave(kept)
    return !found
}

; ── running an action ─────────────────────────────────────────────────────────
;  Shared by both windows. The caller has already hidden itself and un-suspended;
;  what is left is to make sure the target window is genuinely in front before the
;  action runs, because the context gates test the ACTIVE window and the handlers
;  click into it.
ActionsDispatch(idx, prevWin) {
    if (idx < 1 || idx > HK_ORDER.Length)
        return
    if prevWin {
        try WinActivate("ahk_id " prevWin)
        try WinWaitActive("ahk_id " prevWin, , 1)
    }
    Sleep 80
    HK_Broadcast(HK_MSG_FIRE, idx)
}

ActionsIndexOf(id) {
    for i, hid in HK_ORDER
        if (hid = id)
            return i
    return 0
}

ActionsToggle(*) {
    global _actOpen
    if _actOpen
        ActionsClose()
    else
        ActionsShow()
}

ActionsBuild() {
    global
    _actGui := Gui("+Resize +MinSize520x360 +AlwaysOnTop", "MMA Actions")
    _actGui.BackColor := ACT_BG
    _actGui.OnEvent("Close",  (*) => ActionsClose())
    _actGui.OnEvent("Escape", (*) => ActionsClose())
    _actGui.OnEvent("Size",   ActionsResize)

    _actGui.SetFont("s14 Bold c" ACT_ACCENT, "Segoe UI")
    _actGui.Add("Text", "x14 y10 w300", Chr(0x25B8) "  Actions")
    _actGui.SetFont("s10 Norm c" ACT_MUTED, "Segoe UI")
    _actCount := _actGui.Add("Text", "x320 y16 w260 Right", "")

    _actGui.SetFont("s11 c" ACT_TXT, "Segoe UI")
    _actFind := _actGui.Add("Edit", "x14 y42 w566 h30 Background" ACT_FIELDBG)
    _actFind.OnEvent("Change", (*) => ActionsFill(_actFind.Value))

    _actGui.SetFont("s10 c" ACT_TXT, "Segoe UI")
    _actLV := _actGui.Add("ListView", "x14 y82 w566 h250 Background" ACT_LISTBG " -Multi",
                          ["", "Action", "Key", "Where", "idx"])
    _actLV.OnEvent("DoubleClick", (*) => ActionsRunSelected())
    _actLV.ModifyCol(1, 26)            ; pin star
    _actLV.ModifyCol(2, 280)
    _actLV.ModifyCol(3, 110)
    _actLV.ModifyCol(4, 126)
    _actLV.ModifyCol(5, 0)             ; hidden: index into HK_ORDER, rides with the row

    _actGui.SetFont("s9 c" ACT_MUTED, "Segoe UI")
    _actSends := _actGui.Add("Checkbox", "x14 y344 w230",
                             "Show model send keys (F1-F4 etc.)")
    _actSends.Value := Integer(IniRead(ACT_CFG, "Actions", "ShowSends", "0"))
    _actSends.OnEvent("Click", ActionsToggleSends)
    _actPinBtn := _actGui.Add("Button", "x250 y338 w130 h26", "Pin / Unpin")
    _actPinBtn.OnEvent("Click", (*) => ActionsPinSelected())
    _actHint := _actGui.Add("Text", "x386 y344 w194 Right", "Enter runs     Ctrl+P pins")

    ; The default button is how Enter reaches us: an Edit does not report Enter,
    ; and the key must work while the search box still has focus.
    btn := _actGui.Add("Button", "x-200 y-200 w80 h24 +Default", "Run")
    btn.OnEvent("Click", (*) => ActionsRunSelected())

    ; Arrow keys, scoped to this window so they exist nowhere else. Without these
    ; you would have to leave the search box to change the selection.
    HotIfWinActive("ahk_id " _actGui.Hwnd)
    Hotkey "Up",   (*) => ActionsMove(-1), "On"
    Hotkey "Down", (*) => ActionsMove(1),  "On"
    Hotkey "^p",   (*) => ActionsPinSelected(), "On"
    HotIf()

    ActionsDarkTheme()
}

ActionsDarkTheme() {
    global _actGui, _actLV, _actFind
    for attr in [20, 19]              ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", _actGui.Hwnd, "int", attr, "int*", 1, "int", 4)
    for hwnd in [_actLV.Hwnd, _actFind.Hwnd]
        try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    hHdr := SendMessage(0x101F, 0, 0, _actLV)      ; LVM_GETHEADER
    if hHdr
        try DllCall("uxtheme\SetWindowTheme", "ptr", hHdr, "str", "DarkMode_Explorer", "ptr", 0)
}

ActionsShow() {
    global _actGui, _actFind, _actOpen, _actPrev
    _actPrev := WinExist("A")          ; whatever we are about to take focus from
    if !_actGui
        ActionsBuild()
    ActionsFill("")
    _actFind.Value := ""
    _actOpen := true
    ; Hold every OTHER script's fire while we are up. Ourselves excluded, or this
    ; window's own hotkey could not close it again.
    HK_Broadcast(HK_MSG_SUSPEND, 1, A_ScriptHwnd)
    _actGui.Show("w594 h374")
    try ControlFocus(_actFind)
}

ActionsClose() {
    global _actGui, _actOpen, _actPrev
    if !_actOpen
        return
    _actOpen := false
    try _actGui.Hide()
    HK_Broadcast(HK_MSG_SUSPEND, 0, A_ScriptHwnd)
    try WinActivate("ahk_id " _actPrev)
}

ActionsToggleSends(ctrl, *) {
    global ACT_CFG, _actFind
    try IniWrite(ctrl.Value ? 1 : 0, ACT_CFG, "Actions", "ShowSends")
    ActionsFill(_actFind.Value)
}

; The model send keys (mass.*) are the ones you press hundreds of times a day and
; never forget, and they are two thirds of the registry. Hiding them by default is
; what makes this a list of the things you DO forget; the checkbox brings them back.
ActionsSkip(id) {
    global _actSends
    if (id = "gui.actions")            ; the menu itself — listing it is just noise
        return true
    if (!_actSends.Value && SubStr(id, 1, 5) = "mass.")
        return true
    return false
}

ActionsSectionLabel(id) {
    s := HK_Split(id).section
    return HK_SECTION_LABEL.Has(s) ? HK_SECTION_LABEL[s] : s
}

ActionsFill(query) {
    global _actLV, _actCount
    terms := []
    for t in StrSplit(Trim(query), " ")
        if (t != "")
            terms.Push(t)
    pinned := Map()                     ; read the pins once, not once per row
    for p in ActionsPins()
        pinned[p] := true

    _actLV.Opt("-Redraw")
    _actLV.Delete()
    shown := 0, total := 0
    for i, id in HK_ORDER {
        if ActionsSkip(id)
            continue
        total++
        m     := HK_META[id]
        key   := HK_Key(id)
        where := ActionsSectionLabel(id)
        ; Search the key too, so "F4" finds what F4 does — the reverse lookup is
        ; half the reason for having this window.
        hay := m.label " " key " " where " " id
        ok := true
        for t in terms
            if !InStr(hay, t, false) {
                ok := false
                break
            }
        if !ok
            continue
        _actLV.Add(, pinned.Has(id) ? Chr(0x2605) : "", m.label,
                     key = "" ? Chr(0x2014) : key, where, i)
        shown++
    }
    _actLV.Opt("+Redraw")
    _actCount.Value := (shown = total) ? total " actions" : shown " of " total
    if shown
        _actLV.Modify(1, "Select Focus Vis")
}

; Pin/unpin the selected row, then refill in place. The selection is restored by
; row number rather than left to jump home: pinning several in a row is the
; normal way to use this, and a list that scrolls back to the top after each one
; makes that miserable.
ActionsPinSelected() {
    global _actLV, _actFind
    row := _actLV.GetNext(0, "F")
    if !row
        return
    idx := Integer(_actLV.GetText(row, 5))
    if (idx < 1 || idx > HK_ORDER.Length)
        return
    ActionsTogglePin(HK_ORDER[idx])
    ActionsFill(_actFind.Value)
    if (row <= _actLV.GetCount()) {
        _actLV.Modify(0, "-Select -Focus")
        _actLV.Modify(row, "Select Focus Vis")
    }
}

ActionsMove(delta) {
    global _actLV
    n := _actLV.GetCount()
    if !n
        return
    cur := _actLV.GetNext(0, "F")
    nxt := (cur ? cur : 1) + delta
    if (nxt < 1)
        nxt := 1
    else if (nxt > n)
        nxt := n
    _actLV.Modify(0, "-Select -Focus")
    _actLV.Modify(nxt, "Select Focus Vis")
}

ActionsRunSelected() {
    global _actLV, _actPrev
    row := _actLV.GetNext(0, "F")
    if !row
        row := _actLV.GetNext(0)
    if !row
        return
    idx := Integer(_actLV.GetText(row, 5))
    prev := _actPrev
    ActionsClose()                     ; hides, un-suspends, restores focus
    ActionsDispatch(idx, prev)
}

ActionsResize(gObj, minMax, w, h) {
    global _actLV, _actFind, _actCount, _actSends, _actPinBtn, _actHint
    if (minMax = -1)
        return
    m := 14, footer := 30
    _actCount.Move(w - 274, 16, 260)
    _actFind.Move(m, 42, w - 2 * m, 30)
    listH := h - 82 - footer - m
    if (listH < 120)
        listH := 120
    _actLV.Move(m, 82, w - 2 * m, listH)
    _actLV.ModifyCol(1, 26)
    _actLV.ModifyCol(3, 110)
    _actLV.ModifyCol(4, 126)
    _actLV.ModifyCol(2, Max(160, w - 2 * m - 26 - 110 - 126 - 24))
    by := 82 + listH + 10
    _actSends.Move(m, by)
    _actPinBtn.Move(w - m - 330, by - 6)
    _actHint.Move(w - m - 194, by, 194)
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Quick Actions — the pinned subset, as one column of big buttons.
; ───────────────────────────────────────────────────────────────────────────────
;  The other window is for FINDING things; this one is for doing the handful you
;  do constantly. Full-width rows, two lines each (what it does, and the key), so
;  it stays readable at a glance and is a large target to click.
;
;  The buttons are a fixed POOL created once and re-labelled on each open, rather
;  than built fresh each time. The window keeps one hwnd for its whole life that
;  way, which is what lets the 1-9 shortcuts stay registered against it — a
;  rebuilt window gets a new hwnd and the scoped hotkeys would go stale.
; ═══════════════════════════════════════════════════════════════════════════════

QuickToggle(*) {
    global _qaOpen
    if _qaOpen
        QuickClose()
    else
        QuickShow()
}

QuickBuild() {
    global
    _qaGui := Gui("+AlwaysOnTop -MaximizeBox", "Quick Actions")
    _qaGui.BackColor := ACT_BG
    _qaGui.OnEvent("Close",  (*) => QuickClose())
    _qaGui.OnEvent("Escape", (*) => QuickClose())

    _qaGui.SetFont("s14 Bold c" ACT_ACCENT, "Segoe UI")
    _qaGui.Add("Text", "x18 y12 w300", Chr(0x2726) "  Quick Actions")

    ; "Norm" is not optional: SetFont keeps the previous style, so without it this
    ; inherits the title's Bold and the hint reads as another heading.
    _qaGui.SetFont("s10 Norm c" ACT_MUTED, "Segoe UI")
    ; Explicit height: the text is set later, and a Text control created empty
    ; auto-sizes to ONE line, which then clips everything after the first.
    _qaEmpty := _qaGui.Add("Text", "x18 y52 w404 h96", "")  ; filled in QuickLayout

    ; One button per slot. Two lines of text: the label, then the key that also
    ; runs it — the reminder is half the reason this window exists.
    _qaGui.SetFont("s11 Norm c" ACT_TXT, "Segoe UI")
    _qaBtns := []
    Loop QA_MAX {
        b := _qaGui.Add("Button", "x18 y" (46 + (A_Index - 1) * 62) " w404 h54 Hidden", "")
        b.OnEvent("Click", QuickMakeHandler(A_Index))
        _qaBtns.Push(b)
    }

    _qaGui.SetFont("s9 c" ACT_MUTED, "Segoe UI")
    _qaFoot := _qaGui.Add("Text", "x18 y0 w404 Center", "1-9 runs     Esc closes")

    ; Number keys, scoped to this window so they exist nowhere else.
    HotIfWinActive("ahk_id " _qaGui.Hwnd)
    Loop 9
        Hotkey String(A_Index), QuickMakeHandler(A_Index), "On"
    HotIf()

    for attr in [20, 19]
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", _qaGui.Hwnd, "int", attr, "int*", 1, "int", 4)
    for b in _qaBtns
        try DllCall("uxtheme\SetWindowTheme", "ptr", b.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
}

; A closure per slot. Written as a factory rather than inline in the loop because
; an inline lambda would capture the loop variable itself, leaving every button
; pointing at the last slot.
QuickMakeHandler(slot) {
    return (*) => QuickRun(slot)
}

QuickShow() {
    global _qaGui, _qaOpen, _qaPrev
    _qaPrev := WinExist("A")
    if !_qaGui
        QuickBuild()
    h := QuickLayout()
    _qaOpen := true
    HK_Broadcast(HK_MSG_SUSPEND, 1, A_ScriptHwnd)
    _qaGui.Show("w440 h" h)
}

; Label the button pool from the current pins and size the window to fit.
; Returns the height. Split out from QuickShow so the layout can be exercised
; on its own, without the suspend broadcast reaching the live scripts.
QuickLayout() {
    global _qaBtns, _qaEmpty, _qaFoot, _qaPins, QA_MAX
    _qaPins := ActionsPins()
    n := Min(_qaPins.Length, QA_MAX)

    Loop QA_MAX {
        b := _qaBtns[A_Index]
        if (A_Index > n) {
            b.Visible := false
            continue
        }
        id  := _qaPins[A_Index]
        m   := HK_META[id]
        key := HK_Key(id)
        ; Numbered up to 9 only — past that there is no shortcut to advertise.
        lead := A_Index <= 9 ? A_Index ".  " : "     "
        b.Text := lead m.label "`n" (key = "" ? "no key" : key)
        b.Visible := true
    }
    if (n = 0) {
        ; Name the key it is actually bound to, read live, so this stays true
        ; after a rebind instead of pointing at a key that no longer opens it.
        k := HK_Key("gui.actions")
        _qaEmpty.Value := "Nothing pinned yet.`n`n"
                        . "Open the Actions menu" (k = "" ? "" : "  (" k ")") ", pick an action,`n"
                        . "and press Ctrl+P to put it here."
    }
    _qaEmpty.Visible := (n = 0)

    h := n ? 46 + n * 62 + 34 : 190
    _qaFoot.Move(18, h - 26)
    _qaFoot.Visible := (n > 0)
    return h
}

QuickClose() {
    global _qaGui, _qaOpen, _qaPrev
    if !_qaOpen
        return
    _qaOpen := false
    try _qaGui.Hide()
    HK_Broadcast(HK_MSG_SUSPEND, 0, A_ScriptHwnd)
    try WinActivate("ahk_id " _qaPrev)
}

QuickRun(slot) {
    global _qaPins, _qaPrev, _qaOpen
    if (!_qaOpen || slot < 1 || slot > _qaPins.Length)
        return
    idx  := ActionsIndexOf(_qaPins[slot])
    prev := _qaPrev
    QuickClose()
    ActionsDispatch(idx, prev)
}
