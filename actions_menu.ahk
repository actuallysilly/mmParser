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
;  Included by mass_gui.ahk rather than run on its own: mass_gui is always up, so
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

; palette — matched to hotstrings_gui.ahk so the two windows read as one app
global ACT_BG      := "15141C"
global ACT_LISTBG  := "1B1A24"
global ACT_FIELDBG := "2A2836"
global ACT_TXT     := "E6E4EE"
global ACT_MUTED   := "8E8AA6"
global ACT_ACCENT  := "B89CFF"

global ACT_CFG   := HK_DIR "\mass_gui.cfg"
global _actGui   := 0
global _actLV    := 0
global _actFind  := 0
global _actCount := 0
global _actSends := 0
global _actOpen  := false
global _actPrev  := 0        ; window that had focus when we opened

HK_Bind("gui.actions", ActionsToggle)

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
                          ["Action", "Key", "Where", "idx"])
    _actLV.OnEvent("DoubleClick", (*) => ActionsRunSelected())
    _actLV.ModifyCol(1, 300)
    _actLV.ModifyCol(2, 110)
    _actLV.ModifyCol(3, 130)
    _actLV.ModifyCol(4, 0)             ; hidden: index into HK_ORDER, rides with the row

    _actGui.SetFont("s9 c" ACT_MUTED, "Segoe UI")
    _actSends := _actGui.Add("Checkbox", "x14 y344 w250",
                             "Show model send keys (F1-F4 etc.)")
    _actSends.Value := Integer(IniRead(ACT_CFG, "Actions", "ShowSends", "0"))
    _actSends.OnEvent("Click", ActionsToggleSends)
    _actGui.Add("Text", "x300 y344 w280 Right", "Enter runs it     Esc closes")

    ; The default button is how Enter reaches us: an Edit does not report Enter,
    ; and the key must work while the search box still has focus.
    btn := _actGui.Add("Button", "x-200 y-200 w80 h24 +Default", "Run")
    btn.OnEvent("Click", (*) => ActionsRunSelected())

    ; Arrow keys, scoped to this window so they exist nowhere else. Without these
    ; you would have to leave the search box to change the selection.
    HotIfWinActive("ahk_id " _actGui.Hwnd)
    Hotkey "Up",   (*) => ActionsMove(-1), "On"
    Hotkey "Down", (*) => ActionsMove(1),  "On"
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
        _actLV.Add(, m.label, key = "" ? Chr(0x2014) : key, where, i)
        shown++
    }
    _actLV.Opt("+Redraw")
    _actCount.Value := (shown = total) ? total " actions" : shown " of " total
    if shown
        _actLV.Modify(1, "Select Focus Vis")
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
    idx := Integer(_actLV.GetText(row, 4))
    if (idx < 1 || idx > HK_ORDER.Length)
        return

    ActionsClose()                     ; hides, un-suspends, restores focus
    ; The target window needs to actually BE active before the action runs: the
    ; context gates test the active window, and the handlers click into it.
    if _actPrev {
        try WinWaitActive("ahk_id " _actPrev, , 1)
    }
    Sleep 80
    HK_Broadcast(HK_MSG_FIRE, idx)
}

ActionsResize(gObj, minMax, w, h) {
    global _actLV, _actFind, _actCount, _actSends
    if (minMax = -1)
        return
    m := 14, footer := 30
    _actCount.Move(w - 274, 16, 260)
    _actFind.Move(m, 42, w - 2 * m, 30)
    listH := h - 82 - footer - m
    if (listH < 120)
        listH := 120
    _actLV.Move(m, 82, w - 2 * m, listH)
    _actLV.ModifyCol(2, 110)
    _actLV.ModifyCol(3, 130)
    _actLV.ModifyCol(1, Max(160, w - 2 * m - 110 - 130 - 24))
    _actSends.Move(m, 82 + listH + 10)
}
