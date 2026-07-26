#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "hotkeys.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_gui.ahk — set every hotkey in MMA, grouped by feature.
;
;  This is a VIEW over hotkeys.ini; it never owns the values. Save writes the ini
;  and broadcasts HK_MSG_RELOAD, so running scripts pick changes up live. Editing
;  the ini by hand is just as valid — "Open hotkeys.ini" is right there.
; ═══════════════════════════════════════════════════════════════════════════════

WIN_W := 900
LV_H  := 520

pending := Map()      ; id -> key as edited, not yet saved
lvIds   := []         ; ListView row number -> id
dirty   := false

for id in HK_ORDER
    pending[id] := HK_Key(id)

g := Gui("+Resize", "MMA Hotkeys")
g.SetFont("s9", "Segoe UI")
g.OnEvent("Close", OnClose)
g.OnEvent("Escape", OnClose)
g.OnEvent("Size", OnSize)

g.Add("Text", "x12 y13", "Search:")
edSearch := g.Add("Edit", "x60 y10 w200")
edSearch.OnEvent("Change", (*) => Fill())
g.Add("Text", "x272 y13 w500 c808080",
      "Double-click a row (or press Set key) to assign · Blank = disabled")

lv := g.Add("ListView", "x12 y38 w" (WIN_W - 24) " h" LV_H " Grid -Multi",
            ["Feature", "Action", "Key", "Only in", "Conflict"])
lv.OnEvent("DoubleClick", (*) => SetKeyForSelected())

_y := LV_H + 48
btnSet := g.Add("Button", "x12  y" _y " w90  h30", "Set key")
btnSet.OnEvent("Click", (*) => SetKeyForSelected())
btnDefault := g.Add("Button", "x108 y" _y " w90  h30", "Default")
btnDefault.OnEvent("Click", (*) => ResetSelected())
btnDisable := g.Add("Button", "x204 y" _y " w90  h30", "Disable")
btnDisable.OnEvent("Click", (*) => ClearSelected())
btnResetAll := g.Add("Button", "x312 y" _y " w100 h30", "Reset all")
btnResetAll.OnEvent("Click", (*) => ResetAll())
btnOpenIni := g.Add("Button", "x418 y" _y " w130 h30", "Open hotkeys.ini")
btnOpenIni.OnEvent("Click", (*) => OpenIni())
btnSave := g.Add("Button", "x" (WIN_W - 210) " y" _y " w90 h30 Default", "Save")
btnSave.OnEvent("Click", (*) => SaveAll())
btnClose := g.Add("Button", "x" (WIN_W - 112) " y" _y " w90 h30", "Close")
btnClose.OnEvent("Click", OnClose)
txtStatus := g.Add("Text", "x12 y" (_y + 38) " w" (WIN_W - 24), "")

Fill()
g.Show("w" WIN_W " h" (_y + 62))

; The list is the window's whole point: give it every pixel gained by resizing,
; and keep the button row pinned to the bottom.
OnSize(gg, minMax, w, h) {
    if (minMax = -1)          ; minimised
        return
    lv.Move(, , w - 24, h - 106)
    for c in [btnSave, btnClose]
        c.Move(w - (c = btnSave ? 210 : 112), h - 40)
    for c in [btnSet, btnDefault, btnDisable, btnResetAll, btnOpenIni]
        c.Move(, h - 40)
    txtStatus.Move(, h - 22, w - 24)
}

; ── list ──────────────────────────────────────────────────────────────────────

Fill() {
    global lvIds, lv, edSearch
    filter := Trim(edSearch.Value)
    clash  := Conflicts()
    lv.Opt("-Redraw")
    lv.Delete()
    lvIds := []
    lastSec := ""
    for id in HK_ORDER {
        m   := HK_META[id]
        key := pending[id]
        if (filter != "" && !InStr(m.label, filter, false)
                         && !InStr(id, filter, false)
                         && !InStr(key, filter, false))
            continue
        sec := HK_Split(id).section
        ; only label the first row of each feature, so the column reads as a group
        secLbl := (sec = lastSec) ? "" : HK_SECTION_LABEL[sec]
        lastSec := sec
        lv.Add(, secLbl, m.label, KeyLabel(key), m.when, clash.Has(id) ? clash[id] : "")
        lvIds.Push(id)
    }
    Loop 5
        lv.ModifyCol(A_Index, "AutoHdr")
    lv.ModifyCol(2, 230)
    lv.ModifyCol(3, 150)
    lv.Opt("+Redraw")
}

KeyLabel(k) => (k = "" ? "—" : Pretty(k))

; ^!+# is how AHK writes it and what the ini stores; spell it out for the list.
Pretty(k) {
    out := ""
    while (k != "" && InStr("^!+#", SubStr(k, 1, 1))) {
        c := SubStr(k, 1, 1)
        out .= (c = "^") ? "Ctrl+" : (c = "!") ? "Alt+" : (c = "+") ? "Shift+" : "Win+"
        k := SubStr(k, 2)
    }
    return out k
}

; ── conflicts ─────────────────────────────────────────────────────────────────

; Two ids clash when they resolve to the same key AND can be live at the same
; time. Model send keys are exempt from each other: StartFuGating keeps only the
; active model's copy registered, which is precisely why three models can share
; F1-F3 — flagging those would be crying wolf.
Conflicts() {
    byKey := Map(), out := Map()
    for id in HK_ORDER {
        k := pending[id]
        if (k = "")
            continue
        if !byKey.Has(k)
            byKey[k] := []
        byKey[k].Push(id)
    }
    for k, ids in byKey {
        if (ids.Length < 2)
            continue
        for i, a in ids {
            names := ""
            for j, b in ids {
                if (i = j || !CanCollide(a, b))
                    continue
                names .= (names = "" ? "" : ", ") HK_META[b].label
            }
            if (names != "")
                out[a] := "⚠ " names
        }
    }
    return out
}

CanCollide(a, b) {
    ma := HK_META[a], mb := HK_META[b]
    ; different window contexts can never both be active
    if (ma.when != "" && mb.when != "" && ma.when != mb.when)
        return false
    ; Only *gated* send keys take turns. Being in a mass.* section isn't enough:
    ; the branch/ppv keys are never gated, so model 1's "Branch 2 follow-up 2" on
    ; F6 really does fire alongside model 3's gated "Follow-up 1" on F6.
    if (IsGatedSend(a) && IsGatedSend(b) && HK_Split(a).section != HK_Split(b).section)
        return false
    return true
}

IsGatedSend(id) {
    s := HK_Split(id)
    if (InStr(s.section, "mass.") != 1)
        return false
    for gid in HK_ModelSendIds(SubStr(s.section, 6))
        if (gid = id)
            return true
    return false
}

; ── capture ───────────────────────────────────────────────────────────────────

SelectedId() {
    global lv, lvIds
    r := lv.GetNext()
    return r ? lvIds[r] : ""
}

SetKeyForSelected() {
    global dirty                      ; assume-local: without this, `dirty := true`
                                      ; below would only set a throwaway local and
                                      ; OnClose would never warn about lost edits.
    id := SelectedId()
    if (id = "") {
        Status("Select a row first")
        return
    }
    ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" g.Hwnd)
    ov.BackColor := "1E1E1E"
    ov.SetFont("s11 cWhite", "Segoe UI")
    lblPrompt := ov.Add("Text", "x0 y18 w400 Center", "Press a key or mouse button…")
    ov.SetFont("s9 c9A9A9A")
    ov.Add("Text", "x0 y46 w400 Center", "Esc = cancel     Backspace = disable")
    ov.Show("w400 h80")

    ; Every other script holds fire while we listen, so pressing F1 to assign it
    ; doesn't also send model 1's follow-up. The un-suspend MUST run even if
    ; GrabKey throws — otherwise every hotkey in MMA stays dead with no clue why.
    Broadcast(HK_MSG_SUSPEND, 1)
    try
        k := GrabKey(lblPrompt)
    finally {
        Broadcast(HK_MSG_SUSPEND, 0)
        ov.Destroy()
    }

    if (k = "<cancel>")
        return
    pending[id] := (k = "<clear>") ? "" : k
    dirty := true
    Fill()
    Status(HK_META[id].label " → " KeyLabel(pending[id]) "   (not saved yet)")
}

; Reads one chord. InputHook covers the keyboard (F13-F24 included); mouse
; buttons never reach it, so those get temporary hotkeys. Capturing XButton1/2
; and the Scimitar keys is exactly why this window is native AHK, not a web page.
GrabKey(fb := "") {
    static btns := ["LButton", "RButton", "MButton", "XButton1", "XButton2",
                    "WheelUp", "WheelDown"]
    ; The eight keys that are modifiers, never a chord's main key.
    static MOD_KEYS := "{LControl}{RControl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}"
    global _grabbed := ""

    for b in btns
        try Hotkey("*" b, MouseGrab.Bind(b), "On")

    ; L0 = no length limit; KeyOpt {All} E makes any key an end key, so this
    ; blocks until one arrives. No V, so the keypress is swallowed rather than
    ; typed into whatever is behind the overlay.
    ih := InputHook("L0")
    ; Which modifiers were down AT THE INSTANT the end key arrived. Reading them
    ; afterwards races the user's fingers: release Ctrl a few ms after F1 and the
    ; chord silently records as plain F1.
    global _grabMods := ""
    ih.OnEnd := GrabEndMods
    try {
        ih.KeyOpt("{All}", "E")
        ; ...but NOT the modifiers. With {All} E they ended the input too, so the
        ; instant you pressed Ctrl the capture finished with EndKey "LControl"
        ; while Mods() also saw Ctrl held — giving "^LControl" and leaving no way
        ; to type a chord unless you hit the second key in the same instant.
        ; Excluding them gives the behaviour every other app has: hold the
        ; modifiers, and the capture waits for a real key.
        ih.KeyOpt(MOD_KEYS, "-E")
        ih.Start()
        while (ih.InProgress && _grabbed = "") {
            ; Show the chord as it builds, so holding Ctrl visibly does something.
            if IsObject(fb) {
                m := Mods()
                fb.Value := (m = "") ? "Press a key or mouse button…" : Pretty(m) "…"
            }
            Sleep(15)
        }
    } finally {
        if ih.InProgress
            ih.Stop()
        for b in btns                ; always release, even if the above threw
            try Hotkey("*" b, "Off")
    }

    if (_grabbed != "") {
        got := _grabbed
        _grabbed := ""
        return got
    }
    ek := ih.EndKey
    if (ek = "" || ek = "Escape")
        return "<cancel>"
    if (ek = "Backspace")
        return "<clear>"
    ; OnEnd is the accurate reading; fall back to a live one if it never ran, so a
    ; missed callback costs the modifiers rather than the whole chord.
    return (_grabMods != "" ? _grabMods : Mods()) ek
}

; InputHook.OnEnd — the one moment the held modifiers are still true.
GrabEndMods(*) {
    global _grabMods := Mods()
}

MouseGrab(btn, *) {
    global _grabbed := Mods() btn
}

Mods() {
    s := ""
    if GetKeyState("Ctrl", "P")
        s .= "^"
    if GetKeyState("Alt", "P")
        s .= "!"
    if GetKeyState("Shift", "P")
        s .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        s .= "#"
    return s
}

; ── actions ───────────────────────────────────────────────────────────────────

DefaultKey(id) {
    s := HK_Split(id)
    v := IniRead(HK_INI_DEFAULT, s.section, s.key, HK_UNSET)
    return (v == HK_UNSET) ? HK_UNSET : Trim(v)
}

ResetSelected() {
    global dirty
    id := SelectedId()
    if (id = "")
        return
    d := DefaultKey(id)
    if (d == HK_UNSET) {
        Status("No default for " id)
        return
    }
    pending[id] := d
    dirty := true
    Fill()
    Status(HK_META[id].label " → default (" KeyLabel(d) ")")
}

ClearSelected() {
    global dirty
    id := SelectedId()
    if (id = "")
        return
    pending[id] := ""
    dirty := true
    Fill()
    Status(HK_META[id].label " disabled")
}

ResetAll() {
    global dirty
    if MsgBox("Reset every hotkey back to its default?", "Reset all", 0x24) != "Yes"
        return
    for id in HK_ORDER {
        d := DefaultKey(id)
        if (d != HK_UNSET)
            pending[id] := d
    }
    dirty := true
    Fill()
    Status("All hotkeys reset to defaults — press Save to apply")
}

SaveAll() {
    global dirty
    n := 0
    for id in HK_ORDER {
        s   := HK_Split(id)
        cur := IniRead(HK_INI, s.section, s.key, HK_UNSET)
        if (cur == HK_UNSET || Trim(cur) != pending[id]) {
            IniWrite(pending[id], HK_INI, s.section, s.key)
            n++
        }
    }
    ; Reset all pulls from hotkeys.default.ini, which carries no SchemaVersion —
    ; re-stamp it so the one-time cfg migration can't run again over a clean cfg.
    IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
    Broadcast(HK_MSG_RELOAD, 0)
    dirty := false
    Status(n = 0 ? "No changes" : n " hotkey(s) saved — applied live, no restart")
}

; Hand-editing the ini is a first-class path, so don't let a missing .ini file
; association turn "Open hotkeys.ini" into an error dialog — fall back to Notepad.
OpenIni(*) {
    try
        Run(Chr(34) HK_INI Chr(34))
    catch
        try Run("notepad.exe " Chr(34) HK_INI Chr(34))
}

OnClose(*) {
    if dirty && MsgBox("Discard unsaved hotkey changes?", "Unsaved", 0x24) != "Yes"
        return true          ; keep the window open
    ExitApp()
}

Status(s) {
    txtStatus.Value := s
}

; Every MMA script includes hotkeys.ahk, so they all answer these messages.
; Delegates to hotkeys.ahk. This used to be a hard-coded file list, and it had gone
; stale in both directions — it still named the deleted acc\britishizer.ahk and had
; never gained sequences.ahk, so rebinding the Discord import key silently failed to
; apply live. HK_Broadcast enumerates the running scripts instead.
Broadcast(msg, wparam) {
    HK_Broadcast(msg, wparam)
}
