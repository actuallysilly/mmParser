#Requires AutoHotkey v2.0
#Include "../core/hotkeys.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_core.ahk — the hotkey editor's rules, with no window attached.
; ───────────────────────────────────────────────────────────────────────────────
;  There are two hotkey editors now — the Win32 panel (ui\hotkeys_panel.ahk, which
;  is also the Settings window's Hotkeys tab) and the WebView one
;  (ui\hotkeys_webview.ahk). They draw nothing alike. They must nevertheless agree
;  on every question that is not about drawing:
;
;      • what a stored key is CALLED on screen        HKP_Pretty / HKP_KeyLabel
;      • what hotkeys.default.ini asks for            HKP_DefaultKey
;      • whether a row is still the default           HKP_IsChanged
;      • whether two ids can actually collide         HKP_CanCollide
;      • which ids clash, given a set of keys         HKP_Conflicts
;      • how a keystroke is READ off the keyboard     HKP_GrabKey
;
;  All six live here, and neither editor has a copy. That last one is the reason
;  this file exists at all: the capture is an InputHook plus seven temporary mouse
;  hotkeys plus a suspend-exemption flag, worked out against a specific AutoHotkey
;  build, and a second implementation of it would be wrong in ways nobody would
;  notice until a Scimitar button stopped recording.
;
;  Same rule as ui\main_core.ahk states for the main window: if a function does
;  not touch a control's POSITION, SIZE or CREATION, it belongs in here. What
;  stayed behind in hotkeys_panel.ahk is exactly the two things that do —
;  HKP_Cue (an Edit's cue banner) and HKP_DarkList (a ListView's dark theme).
; ═══════════════════════════════════════════════════════════════════════════════

; Set by the capture hotkeys, read by HKP_GrabKey. Script-level rather than
; instance state because a Hotkey() callback has no `this` — and there is only
; ever one capture in flight, since the overlay is modal in practice.
global _HKP_GRABBED  := ""
global _HKP_GRABMODS := ""

; An em dash for "no key", not an empty cell: a blank column reads as a row that
; failed to draw, and this one is a deliberate state you can put a hotkey into.
HKP_KeyLabel(k) => (k = "" ? Chr(0x2014) : HKP_Pretty(k))

; ^!+# is how AHK writes it and what the ini stores. Spelled out as a LIST of
; parts rather than one string, because the WebView editor draws each part as its
; own keycap and splitting "Ctrl+Alt+NumpadAdd" back apart on "+" is a guess that
; is wrong for the keys that contain one.
HKP_KeyTokens(k) {
    ; Mouse buttons under the name they have on the mouse. "XButton1" is the API's
    ; word for it and nobody else's, and this label is read by someone deciding
    ; whether the button they just pressed is the one they meant. Shared with the
    ; hotstrings window and the main window's Add Hotkey, both of which show a
    ; captured key back to you the same way.
    static NICE := Map("LButton", "Left click", "RButton", "Right click",
                       "MButton", "Middle click", "XButton1", "Mouse 4",
                       "XButton2", "Mouse 5", "WheelUp", "Wheel up",
                       "WheelDown", "Wheel down")
    out := []
    while (k != "" && InStr("^!+#", SubStr(k, 1, 1))) {
        c := SubStr(k, 1, 1)
        out.Push((c = "^") ? "Ctrl" : (c = "!") ? "Alt" : (c = "+") ? "Shift" : "Win")
        k := SubStr(k, 2)
    }
    out.Push(NICE.Has(k) ? NICE[k] : k)
    return out
}

; The same thing as one string, for a ListView cell and for searching.
HKP_Pretty(k) {
    out := ""
    for _, t in HKP_KeyTokens(k)
        out .= (out = "" ? "" : "+") t
    return out
}

; Centre a window over another one, as a Show() option string. WinGetPos cannot see
; a HIDDEN window and the host is always visible when this is called — but a throw
; here would take the whole capture down for a cosmetic reason, so it falls back to
; letting Windows centre it on the screen.
HKP_CenterOn(hwnd, w, h) {
    try {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        return "x" (wx + (ww - w) // 2) " y" (wy + (wh - h) // 2) " w" w " h" h
    }
    return "w" w " h" h
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

; ── what counts as changed, and what counts as a clash ────────────────────────

; An id with no line in hotkeys.default.ini counts as changed as soon as it has a
; key at all — there is nothing for it to match, so "same as the default" cannot
; be true of it. Takes the two keys rather than an id, because the two editors
; hold their pending edits in different shapes and neither one's is this file's
; business.
HKP_IsChanged(pendingKey, defaultKey) {
    return (defaultKey == HK_UNSET) ? (pendingKey != "") : (pendingKey != defaultKey)
}

; Which ids share a key with another id that could actually fire at the same time.
; `pending` is id -> key, covering the whole registry: the answer for one row
; depends on every other row, which is why this takes the lot and not a pair.
;
; There used to be an exemption here: model send keys did not count as clashing
; with each other, because three model PROCESSES each bound the same key and
; StartFuGating kept only the active one registered — so three copies of F13
; were normal, and flagging them was crying wolf. One process shares keys
; through a single [mass.active] declaration instead, so there is nothing to
; exempt. Removing it makes the report honest, and it has something to report.
;
; Returns id -> the OTHER actions' labels, joined. The warning glyph the Win32
; list prefixes is not added here: the WebView draws the same fact as a coloured
; line and would have to strip it back off.
HKP_Conflicts(pending) {
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
                if (i = j || !HKP_CanCollide(a, b))
                    continue
                names .= (names = "" ? "" : ", ") HK_META[b].label
            }
            if (names != "")
                out[a] := names
        }
    }
    return out
}

; ── the two things that TOUCH something ───────────────────────────────────────

; A capture, with every MMA script held. Press F1 to assign it and F1 must not
; also send model 1's follow-up, so the suspend goes out before the grab — and
; the un-suspend MUST run even when the grab throws, or every hotkey in MMA
; stays dead with no clue why. That `finally` is the whole reason this is a
; function and not two lines at each call site.
;
; The suspend reaches THIS script too, which is why HKP_GrabKey registers its
; mouse hotkeys with the S (suspend-exempt) option — see there.
HKP_Capture(fb := "") {
    HK_Broadcast(HK_MSG_SUSPEND, 1)
    try
        return HKP_GrabKey(fb)
    finally
        HK_Broadcast(HK_MSG_SUSPEND, 0)
}

; Write the changed rows to hotkeys.ini and apply them live. Returns how many
; changed, so a window can fold this into its own message instead of popping a
; second one. Safe to call when nothing changed — it writes nothing, and in
; particular does not re-stamp the schema or wake every other process for no
; reason.
;
; Rows are compared against the INI rather than against what the window thinks
; it loaded: hand-editing hotkeys.ini while the editor is open is a supported
; path ("Open hotkeys.ini" is a button), and a stale in-memory copy must not
; silently write the file back to how it looked when the window opened.
HKP_SaveKeys(pending) {
    n := 0
    for id in HK_ORDER {
        s   := HK_Split(id)
        cur := IniRead(HK_INI, s.section, s.key, HK_UNSET)
        if (cur == HK_UNSET || Trim(cur) != pending[id]) {
            IniWrite(pending[id], HK_INI, s.section, s.key)
            n++
        }
    }
    if (n = 0)
        return 0
    ; Reset all pulls from hotkeys.default.ini, which carries no SchemaVersion —
    ; re-stamp it so the one-time cfg migration can't run again over a clean cfg.
    IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
    HK_Broadcast(HK_MSG_RELOAD, 0)
    return n
}
