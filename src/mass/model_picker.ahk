#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  model_picker.ahk — "I pick" mode with a window instead of a memory test.
; ───────────────────────────────────────────────────────────────────────────────
;  "I pick" (ModelMatch=manual) reads nothing off the screen: the active model is
;  whatever you last SAID it was, remembered in the cfg. That makes the shared
;  [mass.active] follow-up keys silent and blind — they send to a model chosen at
;  some earlier point, with nothing on screen saying which, so the failure mode is
;  model 2's follow-up going to model 1's fan and you finding out afterwards.
;
;  In that mode the shared follow-up keys now ASK, and the answer sends:
;
;      shared follow-up 1 key  →  window  →  follow-up 1 for the model you pick
;      shared follow-up 2 key  →  window  →  follow-up 2
;      shared follow-up 3 key  →  window  →  follow-up 3
;
;  With the stock [mass.active] bindings that is XButton2, XButton1 and Ctrl+middle
;  click — no new hotkeys, and nothing to rebind. NO key is named here or added to
;  hotkeys.ini: this changes what the keys you already have DO in one mode, which
;  is why there is no [mass.pick] section. The other modes are untouched — name and
;  position know the answer, so asking would be an insult.
;
;  Pick by mouse, by Tab + Enter, or by pressing 1 / 2 / 3. The number keys are
;  bound to THIS WINDOW ONLY (see _PickHotIf) — the engine owns a lot of keys and
;  a global "1" would be a catastrophe.
;
;  ── two things this has to get right ────────────────────────────────────────
;  FOCUS. The window takes the foreground, and the follow-up is typed into
;  whatever holds it — so sending while the picker is up would type into the
;  picker. The window that was in front is saved on open and re-activated before
;  a single character is sent.
;
;  THE HOTKEY THREAD. `mass.active.*` starts with "mass.", so _HK_IsSend counts it
;  as a send and _HK_Fire holds the anti-fumble "a send is in flight" flag for as
;  long as the handler runs. Waiting for your choice inside that handler would
;  therefore deaden every other key until you answered. So the handler SHOWS the
;  window and returns; the send happens later, from the choice, outside the
;  hotkey thread.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../core/theme.ahk"

global _pickGui     := 0    ; the window while it is open, else 0
global _pickHwnd    := 0    ; its hwnd, which is what scopes the number keys
global _pickGroup   := 0    ; which follow-up this pick will send (1-3)
global _pickPrevWin := 0    ; the window to give the keyboard back to

; Where the button grid starts, in window coords. Named because two things depend
; on agreeing about it: the layout, and the rule that the cursor must never open
; the window on top of a button (see the positioning note in MassPickThenFu).
global BTN_TOP := 38

; How many models are actually in play. Same shape as SelectNextModel's: the cfg
; holds the user's count, MASS_MODELS is the ceiling the tree is built for, and a
; cfg outside that range means the cfg is wrong, not the ceiling.
_PickModelCount() {
    global MMA_CFG, MASS_MODELS
    n := _IniInt(MMA_CFG, "Settings", "ModelCount", MASS_MODELS)
    return (n < 1 || n > MASS_MODELS) ? MASS_MODELS : n
}

; Which follow-up a [mass.active] slot means, or 0 for the slots that are not
; follow-ups (ppv, ppvFus, mass, nextFu — those keep manual mode's remembered
; model, because the ask belongs on the keys you press dozens of times an hour).
;
; Derived from the slot NAME rather than a second list of handlers: fu2, fu2short,
; mFu2 and altFu2 are four ids for one action, and a hand-kept list of them is the
; thing that goes stale the next time a slot is added.
PickGroupForSlot(slot) {
    if RegExMatch(slot, "i)^(?:m|alt)?fu([123])(?:short)?$", &m)
        return Integer(m[1])
    return 0
}

MassPickThenFu(group, *) {
    global _pickGui, _pickHwnd, _pickGroup, _pickPrevWin

    ; Already open: a second press re-aims the SAME window at the new follow-up
    ; rather than stacking a second one. Pressing fu1 then fu2 without picking is
    ; a change of mind, not two pending sends.
    if _pickGui {
        _pickGroup := group
        LOGI("mass.pick", "picker already open — now aimed at follow-up " group)
        _PickRetitle()
        try WinActivate("ahk_id " _pickHwnd)
        return
    }

    count := _PickModelCount()
    _pickGroup   := group
    _pickPrevWin := WinExist("A")     ; before we steal the foreground
    LOGI("mass.pick", "follow-up " group " — asking which of " count " model(s),"
                    . " over " (_pickPrevWin ? WinGetProcessName("ahk_id " _pickPrevWin)
                                             : "(nothing focused)"))

    ; Labels first: on a dark theme a static takes its colour from the window font
    ; at creation time and cannot be told afterwards (see core/theme.ahk).
    pg := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Send follow-up " group)
    pg.BackColor := THEME_WindowBg()
    pg.SetFont("s10 Bold" THEME_FontOpt(), "Segoe UI")

    ; A grid, not a row. One row of N buttons is 150px per model — fine at three,
    ; 1.8 metres of window at twelve. Four to a row keeps the window roughly square
    ; and every button the same size, which is what makes it readable at a glance
    ; rather than a menu you have to parse.
    BTN_W := 150, BTN_H := 38, GAP := 10, PAD := 12
    perRow := Min(count, 4)
    rows   := Ceil(count / perRow)
    winW   := PAD * 2 + perRow * BTN_W + (perRow - 1) * GAP
    lbl := pg.Add("Text", "x" PAD " y10 w" (winW - PAD * 2), "Follow-up " group " — which model?")

    pg.SetFont("s10 Norm" THEME_FontOpt(), "Segoe UI")
    Loop count {
        n := A_Index
        col := Mod(n - 1, perRow), row := (n - 1) // perRow
        x := PAD + col * (BTN_W + GAP)
        y := BTN_TOP + row * (BTN_H + GAP)
        ; "1  Aliw" — the number leads because the number is also the key, for the
        ; first nine. Past that the keyboard runs out and the mouse or Tab is the
        ; way; the label stops promising a key that does not exist.
        b := pg.Add("Button", "x" x " y" y " w" BTN_W " h" BTN_H
                            . (n = 1 ? " Default" : ""),
                    (n <= 9 ? n "   " : "") ModelLabelShort(n))
        b.OnEvent("Click", _PickChoose.Bind(n))
    }

    hintY := BTN_TOP + rows * (BTN_H + GAP) + 2
    pg.SetFont("s8 Norm" THEME_FontOpt(), "Segoe UI")
    pg.Add("Text", "x" PAD " y" hintY " w" (winW - PAD * 2),
           "Click, or Tab then Enter"
         . (count > 1 ? ", or press 1-" Min(count, 9) : ", or press 1")
         . ".    Esc cancels.")

    pg.OnEvent("Escape", (*) => _PickCancel())
    pg.OnEvent("Close",  (*) => _PickCancel())
    THEME_ApplyTo(pg)

    _pickGui := pg
    ; Near the cursor: this is a key you press mid-conversation and the pointer is
    ; already where you are looking. Clamped to the work area so it is never born
    ; half off-screen on the right-hand monitor edge.
    ;
    ; NOT centred on the cursor, and that is the whole of this comment's purpose.
    ; Centred, the pointer lands INSIDE a model button — the first row starts at
    ; BTN_TOP — so the window would open with a live Send under the mouse. The
    ; first end-to-end test of this file sent a real follow-up into a real
    ; conversation that way, off the release of the very button that opened the
    ; window. The cursor belongs on the HEADER strip above the grid, so that every
    ; route to a send (click, Tab and Enter, or a number key) is a deliberate act.
    winH := hintY + 24
    MouseGetPos(&mx, &my)
    x := mx - winW // 2, y := my - 14
    ma := MonitorAreaAt(mx, my)
    x := Max(ma.l, Min(x, ma.r - winW))
    y := Max(ma.t, Min(y, ma.b - winH))
    pg.Show("x" x " y" y " w" winW " h" winH)
    _pickHwnd := pg.Hwnd
}

; "1 — Aliw" is the label everything else uses, but it is already prefixed with
; the number on the button, so this drops the number and keeps the name.
ModelLabelShort(n) {
    disp := ModelDisplayName(n)
    return disp = "" ? "Model " n : disp
}

; The work area of whichever monitor the cursor is on, so the clamp above is
; right on a multi-monitor desk and does not assume monitor 1.
MonitorAreaAt(x, y) {
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return {l: l, t: t, r: r, b: b}
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    return {l: l, t: t, r: r, b: b}
}

_PickRetitle() {
    global _pickGui, _pickGroup
    if _pickGui {
        try _pickGui.Title := "Send follow-up " _pickGroup
        try _pickGui["Static1"].Text := "Follow-up " _pickGroup " — which model?"
    }
}

_PickClose() {
    global _pickGui, _pickHwnd
    if _pickGui
        try _pickGui.Destroy()
    _pickGui := 0, _pickHwnd := 0
}

_PickCancel() {
    global _pickGroup
    LOGI("mass.pick", "cancelled — follow-up " _pickGroup " not sent")
    _PickClose()
    _PickRestoreFocus()
}

; Hand the keyboard back to whatever we took it from. Not optional: the follow-up
; is TYPED, so sending with the picker still focused would type into the picker,
; and sending after a plain Destroy would race whatever Windows decides to focus
; next. WinWaitActive is the difference between "usually works" and "works".
_PickRestoreFocus() {
    global _pickPrevWin
    if !_pickPrevWin
        return
    try {
        WinActivate("ahk_id " _pickPrevWin)
        if !WinWaitActive("ahk_id " _pickPrevWin, , 1)
            LOGW("mass.pick", "the window that was in front (hwnd " _pickPrevWin ")"
                            . " did not come back within a second — a send now goes"
                            . " to whatever has focus instead")
    } catch as e
        LOGW("mass.pick", "could not re-activate the window that was in front — "
                        . LOG_Err(e))
}

; The whole point of the file: model chosen, so put the keyboard back and send.
_PickChoose(n, *) {
    global _pickGroup, _pickGui

    if !_pickGui                       ; a stray number key with no window open
        return
    count := _PickModelCount()
    ; "3 only when there are three" — the number keys are registered once, but the
    ; window may only be offering two. Refused loudly rather than sending model 3's
    ; text out of a slot the user does not consider live.
    if (n < 1 || n > count) {
        LOG_Bail("mass.pick", "model " n " was asked for but only " count " model(s)"
                            . " are active — nothing sent")
        _MassToast("No model " n)
        return
    }

    group := _pickGroup
    _PickClose()
    _PickRestoreFocus()

    ; Both, for the same reason SelectModel does both: _SetCurModel aims THIS send,
    ; SetManualModel makes the choice stick so the shared [mass.active] keys follow
    ; the model you just picked instead of the one before it.
    _SetCurModel(n)
    SetManualModel(n)
    LOGI("mass.pick", "model " n " (" ModelLabel(n) ") picked — sending follow-up " group)

    switch group {
        case 1: DoFu1()
        case 2: DoFu2()
        case 3: DoFu3()
        default:
            LOGE("mass.pick", "follow-up " group " is not 1-3 — nothing sent")
    }
}

; ── 1 / 2 / 3, scoped to the picker ───────────────────────────────────────────
;  Registered ONCE at load, never toggled. The criterion is a function, which is
;  what Hotkey() reads (a #HotIf directive would not apply to it at all — it only
;  governs literal `::` hotkeys). With no window open _pickHwnd is 0, WinActive
;  is false, and these keys do not exist as far as the rest of Windows is
;  concerned — which is the only safe way to own a key called "1".
;  `(*)`, not `()`. AHK hands the criterion the HOTKEY'S OWN NAME, so a zero-
;  parameter function throws "Too many parameters passed to function" the moment
;  you press 1 — a runtime failure that no parse check can see, and one that
;  would have looked like the number keys simply not working. Same reason every
;  HK_Context criterion in core/hotkeys.ahk is written `(*) =>`.
_PickHotIf(*) {
    global _pickHwnd
    return _pickHwnd && WinActive("ahk_id " _pickHwnd)
}
;  1-9, not 1-3: the ceiling is the KEYBOARD's, not the model list's. Registering
;  "10" would be the 1 key followed by the 0 key, which is not a hotkey — models
;  past nine are reached with the mouse or with Tab, and the hint line says so.
;  _PickChoose refuses anything above the count in force, so registering nine keys
;  on a two-model setup is safe.
HotIf(_PickHotIf)
Loop 9
    Hotkey(String(A_Index), _PickChoose.Bind(A_Index), "On")
Hotkey("Escape", (*) => _PickCancel(), "On")
HotIf()
