#Requires AutoHotkey v2.0
#Include "../core/hotkeys.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_panel.ahk — the hotkey editor, as a panel that can live in any window.
; ───────────────────────────────────────────────────────────────────────────────
;  A VIEW over hotkeys.ini; it never owns the values. Save() writes the ini and
;  broadcasts HK_MSG_RELOAD, so running scripts pick changes up live. Editing the
;  ini by hand is just as valid — "Open hotkeys.ini" is right there.
;
;  ─── WHY A PANEL AND NOT A WINDOW ────────────────────────────────────────────
;  This was a whole separate PROCESS: its own Gui, its own #SingleInstance, its own
;  Save and Close. That is one more window to find, arrange and close for a thing
;  that is plainly a setting — and it made "settings" mean three windows that each
;  wrote mass_gui.cfg and hotkeys.ini with no idea the others existed.
;
;  Everything here is instance state on the class rather than script globals, which
;  is what makes embedding possible at all: the old file kept `g`, `lv`, `dirty`
;  and `pending` at the top level, and main_window.ahk already has a `g` and an
;  `lv` of its own. Two of those in one process is not a merge conflict, it is a
;  script that will not load.
;
;  ─── SUSPENDING WHILE CAPTURING ──────────────────────────────────────────────
;  Press F1 to assign it and F1 must not also send model 1's follow-up, so every
;  MMA script holds fire during a capture. Embedded, "every script" now includes
;  the one this panel is running inside — which is correct (the GUI has its own
;  hotkeys) but also nearly fatal: the mouse-button capture works by registering
;  temporary hotkeys, and a suspended script has no live hotkeys to capture with.
;
;  Hence the S option on those temporary keys: suspend-exempt, so the capture keeps
;  working while everything it is protecting you from stays held. Verified against
;  AutoHotkey 2.0.26, including registering one WHILE already suspended.
; ═══════════════════════════════════════════════════════════════════════════════

; Set by the capture hotkeys, read by HKP_GrabKey. Script-level rather than
; instance state because a Hotkey() callback has no `this` — and there is only
; ever one capture in flight, since the overlay is modal in practice.
global _HKP_GRABBED  := ""
global _HKP_GRABMODS := ""

class HotkeysPanel {
    ; hostGui   — the Gui to build into. When it is a Tab3 page, the caller has
    ;             already called UseTab, so the controls land on the right page.
    ; x,y,w,h   — the rectangle to fill. Re-layout later with Layout().
    ; showSave  — a standalone window wants its own Save/Close; a Settings tab is
    ;             saved by the window's own Save button, so it asks for neither.
    __New(hostGui, x, y, w, h, showSave := false) {
        this.gui      := hostGui
        this.hostHwnd := hostGui.Hwnd
        this.showSave := showSave
        this.dirty    := false
        this.lvIds    := []
        this.pending  := Map()          ; id -> key as edited, not yet saved
        for id in HK_ORDER
            this.pending[id] := HK_Key(id)

        g := hostGui
        this.lblSearch := g.Add("Text", "x" x " y" (y + 4), "Search:")
        this.edSearch  := g.Add("Edit", "x" (x + 48) " y" y " w200")
        this.edSearch.OnEvent("Change", (*) => this.Fill())
        this.lblHint := g.Add("Text", "x" (x + 260) " y" (y + 4) " w420 c808080",
                              "Double-click a row (or press Set key) to assign · Blank = disabled")

        this.lv := g.Add("ListView", "x" x " y" (y + 28) " w" w " h" (h - 100) " Grid -Multi",
                         ["Feature", "Action", "Key", "Only in", "Conflict"])
        this.lv.OnEvent("DoubleClick", (*) => this.SetKeyForSelected())

        by := y + h - 68
        this.btnSet     := g.Add("Button", "x" x         " y" by " w90  h30", "Set key")
        this.btnDefault := g.Add("Button", "x" (x + 96)  " y" by " w90  h30", "Default")
        this.btnDisable := g.Add("Button", "x" (x + 192) " y" by " w90  h30", "Disable")
        this.btnResetAll:= g.Add("Button", "x" (x + 300) " y" by " w100 h30", "Reset all")
        this.btnOpenIni := g.Add("Button", "x" (x + 406) " y" by " w130 h30", "Open hotkeys.ini")
        this.btnSet.OnEvent("Click",      (*) => this.SetKeyForSelected())
        this.btnDefault.OnEvent("Click",  (*) => this.ResetSelected())
        this.btnDisable.OnEvent("Click",  (*) => this.ClearSelected())
        this.btnResetAll.OnEvent("Click", (*) => this.ResetAll())
        this.btnOpenIni.OnEvent("Click",  (*) => this.OpenIni())

        this.btnSave := ""
        if showSave {
            this.btnSave := g.Add("Button", "x" (x + w - 98) " y" by " w90 h30 Default", "Save")
            this.btnSave.OnEvent("Click", (*) => this.SaveAndReport())
        }

        this.txtStatus := g.Add("Text", "x" x " y" (by + 36) " w" w, "")
        this.Fill()
    }

    ; Every control repositioned for a new rectangle. The list is the panel's whole
    ; point: it takes every pixel a resize gains, and the button row stays pinned to
    ; the bottom of the rectangle.
    ;
    ; Laid out from the floor upwards, in ONE place. This used to be two sets of
    ; hand-counted offsets that had to agree and didn't: the static layout put the
    ; buttons at LV_H+48 and the status 38px under them, while the resize handler
    ; put the buttons at h-40 and the status at h-22 — inside the button row. A Text
    ; control paints its background, so the status line erased the bottom 12px of
    ; all seven buttons. That is what "the buttons are cut in half" was, and it
    ; appeared on the first WM_SIZE, which arrives the moment the window is shown.
    Layout(x, y, w, h) {
        by      := y + h - 68
        statusY := y + h - 26
        this.lblSearch.Move(x, y + 4)
        this.edSearch.Move(x + 48, y)
        this.lblHint.Move(x + 260, y + 4)
        this.lv.Move(x, y + 28, w, by - (y + 28) - 10)
        for i, c in [this.btnSet, this.btnDefault, this.btnDisable, this.btnResetAll, this.btnOpenIni]
            c.Move(x + [0, 96, 192, 300, 406][i], by)
        if this.btnSave
            this.btnSave.Move(x + w - 98, by)
        this.txtStatus.Move(x, statusY, w)
        this.SizeCols()
    }

    ; The five columns have to add up to the list's width, or Windows puts a
    ; horizontal scrollbar under them — which it did, since AutoHdr on all five
    ; overflowed. Four take what their content needs; Conflict gets the remainder,
    ; so widening the window widens the one column whose text has no fixed length.
    SizeCols() {
        this.lv.GetPos(, , &lvW)
        fixed := [130, 230, 150, 90]
        used  := 0
        for i, cw in fixed {
            this.lv.ModifyCol(i, cw)
            used += cw
        }
        ; grid lines, plus the vertical scrollbar this list always has
        this.lv.ModifyCol(5, Max(lvW - used - 26, 80))
    }

    ; ── list ──────────────────────────────────────────────────────────────────

    Fill() {
        filter := Trim(this.edSearch.Value)
        clash  := this.Conflicts()
        this.lv.Opt("-Redraw")
        this.lv.Delete()
        this.lvIds := []
        lastSec := ""
        for id in HK_ORDER {
            m   := HK_META[id]
            key := this.pending[id]
            if (filter != "" && !InStr(m.label, filter, false)
                             && !InStr(id, filter, false)
                             && !InStr(key, filter, false))
                continue
            sec := HK_Split(id).section
            ; only label the first row of each feature, so the column reads as a group
            secLbl := (sec = lastSec) ? "" : HK_SECTION_LABEL[sec]
            lastSec := sec
            this.lv.Add(, secLbl, m.label, HKP_KeyLabel(key), m.when,
                        clash.Has(id) ? clash[id] : "")
            this.lvIds.Push(id)
        }
        this.SizeCols()
        this.lv.Opt("+Redraw")
    }

    ; ── conflicts ─────────────────────────────────────────────────────────────

    ; Two ids clash when they resolve to the same key AND can be live at the same
    ; time.
    ;
    ; There used to be an exemption here: model send keys did not count as clashing
    ; with each other, because three model PROCESSES each bound the same key and
    ; StartFuGating kept only the active one registered — so three copies of F13
    ; were normal, and flagging them was crying wolf. One process shares keys
    ; through a single [mass.active] declaration instead, so there is nothing to
    ; exempt. Removing it makes the report honest, and it has something to report.
    Conflicts() {
        byKey := Map(), out := Map()
        for id in HK_ORDER {
            k := this.pending[id]
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
                    if (i = j || !HKP_CanCollide(a, b))
                        continue
                    names .= (names = "" ? "" : ", ") HK_META[b].label
                }
                if (names != "")
                    out[a] := "⚠ " names
            }
        }
        return out
    }

    ; ── actions ───────────────────────────────────────────────────────────────

    SelectedId() {
        r := this.lv.GetNext()
        return r ? this.lvIds[r] : ""
    }

    SetKeyForSelected() {
        id := this.SelectedId()
        if (id = "") {
            this.Status("Select a row first")
            return
        }
        ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" this.hostHwnd)
        ov.BackColor := "1E1E1E"
        ov.SetFont("s11 cWhite", "Segoe UI")
        lblPrompt := ov.Add("Text", "x0 y18 w400 Center", "Press a key or mouse button…")
        ov.SetFont("s9 c9A9A9A")
        ov.Add("Text", "x0 y46 w400 Center", "Esc = cancel     Backspace = disable")
        ov.Show("w400 h80")

        ; Every script holds fire while we listen — this one included, now that the
        ; panel lives inside a script that has hotkeys of its own. The un-suspend
        ; MUST run even if the grab throws, or every hotkey in MMA stays dead with
        ; no clue why.
        HK_Broadcast(HK_MSG_SUSPEND, 1)
        try
            k := HKP_GrabKey(lblPrompt)
        finally {
            HK_Broadcast(HK_MSG_SUSPEND, 0)
            ov.Destroy()
        }

        if (k = "<cancel>")
            return
        this.pending[id] := (k = "<clear>") ? "" : k
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label " → " HKP_KeyLabel(this.pending[id]) "   (not saved yet)")
    }

    ResetSelected() {
        id := this.SelectedId()
        if (id = "")
            return
        d := HKP_DefaultKey(id)
        if (d == HK_UNSET) {
            this.Status("No default for " id)
            return
        }
        this.pending[id] := d
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label " → default (" HKP_KeyLabel(d) ")")
    }

    ClearSelected() {
        id := this.SelectedId()
        if (id = "")
            return
        this.pending[id] := ""
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label " disabled")
    }

    ResetAll() {
        if MsgBox("Reset every hotkey back to its default?", "Reset all", 0x24) != "Yes"
            return
        for id in HK_ORDER {
            d := HKP_DefaultKey(id)
            if (d != HK_UNSET)
                this.pending[id] := d
        }
        this.dirty := true
        this.Fill()
        this.Status("All hotkeys reset to defaults — press Save to apply")
    }

    ; Writes the changed rows and applies them live. Returns how many changed, so
    ; a host window can fold this into its own save message instead of popping a
    ; second one. Safe to call when nothing changed — it writes nothing.
    Save() {
        n := 0
        for id in HK_ORDER {
            s   := HK_Split(id)
            cur := IniRead(HK_INI, s.section, s.key, HK_UNSET)
            if (cur == HK_UNSET || Trim(cur) != this.pending[id]) {
                IniWrite(this.pending[id], HK_INI, s.section, s.key)
                n++
            }
        }
        if (n = 0)
            return 0
        ; Reset all pulls from hotkeys.default.ini, which carries no SchemaVersion —
        ; re-stamp it so the one-time cfg migration can't run again over a clean cfg.
        IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
        HK_Broadcast(HK_MSG_RELOAD, 0)
        this.dirty := false
        return n
    }

    SaveAndReport() {
        n := this.Save()
        this.Status(n = 0 ? "No changes" : n " hotkey(s) saved — applied live, no restart")
    }

    ; Hand-editing the ini is a first-class path, so don't let a missing .ini file
    ; association turn "Open hotkeys.ini" into an error dialog — fall back to Notepad.
    OpenIni() {
        try
            Run(Chr(34) HK_INI Chr(34))
        catch
            try Run("notepad.exe " Chr(34) HK_INI Chr(34))
    }

    Status(s) {
        this.txtStatus.Value := s
    }

    ; True when there are edits the user has not saved. A host window asks this
    ; before closing.
    HasUnsaved() => this.dirty
}

; ── helpers ───────────────────────────────────────────────────────────────────
; Free functions, HKP_-prefixed. main_window.ahk's include graph is large and flat,
; and a plain `Pretty` or `Status` there would be a name collision — in AHK v2 a
; function and a variable that share a name (case-insensitively) do not merely
; shadow one another, the script fails to load.

HKP_KeyLabel(k) => (k = "" ? "—" : HKP_Pretty(k))

; ^!+# is how AHK writes it and what the ini stores; spell it out for the list.
HKP_Pretty(k) {
    out := ""
    while (k != "" && InStr("^!+#", SubStr(k, 1, 1))) {
        c := SubStr(k, 1, 1)
        out .= (c = "^") ? "Ctrl+" : (c = "!") ? "Alt+" : (c = "+") ? "Shift+" : "Win+"
        k := SubStr(k, 2)
    }
    return out k
}

HKP_CanCollide(a, b) {
    ma := HK_META[a], mb := HK_META[b]
    ; different window contexts can never both be active
    if (ma.when != "" && mb.when != "" && ma.when != mb.when)
        return false
    return true
}

HKP_DefaultKey(id) {
    s := HK_Split(id)
    v := IniRead(HK_INI_DEFAULT, s.section, s.key, HK_UNSET)
    return (v == HK_UNSET) ? HK_UNSET : Trim(v)
}

; Reads one chord. InputHook covers the keyboard (F13-F24 included); mouse buttons
; never reach it, so those get temporary hotkeys. Capturing XButton1/2 and the
; Scimitar keys is exactly why this editor is native AHK, not a web page.
HKP_GrabKey(fb := "") {
    static btns := ["LButton", "RButton", "MButton", "XButton1", "XButton2",
                    "WheelUp", "WheelDown"]
    ; The eight keys that are modifiers, never a chord's main key.
    static MOD_KEYS := "{LControl}{RControl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}"
    global _HKP_GRABBED  := ""
    global _HKP_GRABMODS := ""

    ; "S" = exempt from Suspend. The suspend broadcast that protects you from
    ; firing a real hotkey mid-capture now reaches this script too, and without
    ; the exemption it would switch off the very keys doing the capturing.
    for b in btns
        try Hotkey("*" b, HKP_MouseGrab.Bind(b), "On S")

    ; L0 = no length limit; KeyOpt {All} E makes any key an end key, so this blocks
    ; until one arrives. No V, so the keypress is swallowed rather than typed into
    ; whatever is behind the overlay.
    ih := InputHook("L0")
    ; Which modifiers were down AT THE INSTANT the end key arrived. Reading them
    ; afterwards races the user's fingers: release Ctrl a few ms after F1 and the
    ; chord silently records as plain F1.
    ih.OnEnd := HKP_GrabEndMods
    try {
        ih.KeyOpt("{All}", "E")
        ; ...but NOT the modifiers. With {All} E they ended the input too, so the
        ; instant you pressed Ctrl the capture finished with EndKey "LControl"
        ; while the modifier read also saw Ctrl held — giving "^LControl" and
        ; leaving no way to type a chord unless you hit the second key in the same
        ; instant. Excluding them gives the behaviour every other app has: hold the
        ; modifiers, and the capture waits for a real key.
        ih.KeyOpt(MOD_KEYS, "-E")
        ih.Start()
        while (ih.InProgress && _HKP_GRABBED = "") {
            ; Show the chord as it builds, so holding Ctrl visibly does something.
            if IsObject(fb) {
                m := HKP_Mods()
                fb.Value := (m = "") ? "Press a key or mouse button…" : HKP_Pretty(m) "…"
            }
            Sleep(15)
        }
    } finally {
        if ih.InProgress
            ih.Stop()
        for b in btns                ; always release, even if the above threw
            try Hotkey("*" b, "Off")
    }

    if (_HKP_GRABBED != "") {
        got := _HKP_GRABBED
        _HKP_GRABBED := ""
        return got
    }
    ek := ih.EndKey
    if (ek = "" || ek = "Escape")
        return "<cancel>"
    if (ek = "Backspace")
        return "<clear>"
    ; OnEnd is the accurate reading; fall back to a live one if it never ran, so a
    ; missed callback costs the modifiers rather than the whole chord.
    return (_HKP_GRABMODS != "" ? _HKP_GRABMODS : HKP_Mods()) ek
}

; InputHook.OnEnd — the one moment the held modifiers are still true.
HKP_GrabEndMods(*) {
    global _HKP_GRABMODS := HKP_Mods()
}

HKP_MouseGrab(btn, *) {
    global _HKP_GRABBED := HKP_Mods() btn
}

HKP_Mods() {
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
