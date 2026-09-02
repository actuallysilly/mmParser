#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  lock_badge.ahk — the little window that says a lock is on, and which model.
; ───────────────────────────────────────────────────────────────────────────────
;  Lock mode (core/active_model.ahk) takes the "which model?" picker away and aims
;  every [mass.active] key at one model. That is the whole point of it — and it is
;  also, stated plainly, a mode in which a key you press sends to a model nothing
;  on screen names. MMA has been wrong in exactly that direction before, and the
;  cost is one model's message in another model's chat (docs/decisions.md §4.8).
;
;  So the lock is not allowed to be invisible. The rule this file exists to keep:
;
;      the only silent mode change is the one you find out about from a fan.
;
;  A tooltip cannot do it — tooltips expire, and this state lasts twenty minutes.
;  MMA's window cannot do it either: it is behind Infloww all shift, which is the
;  one place you are not looking. So the badge is a small always-on-top strip that
;  stays up for as long as the lock does, naming the model, and it is also the
;  unlock button: click it and you are back to normal.
;
;  ── three things it must not do ──────────────────────────────────────────────
;  STEAL FOCUS. Every message you type goes into a chat box, so a window that
;  takes the foreground when it appears — or when you click it — would eat the
;  keystroke you were mid-way through. WS_EX_NOACTIVATE (0x08000000) is what
;  prevents that; it still receives the click.
;
;  SIT ON THE WORK. Bottom-right of the work area by default, which on this desk
;  is out of Infloww's way, and moveable with two cfg keys for a desk where it is
;  not: [Lock] BadgeX / BadgeY, in screen pixels. -1 means "the default corner".
;
;  BE THEMED. It is deliberately the same amber on near-black in every theme. This
;  is a warning light, not part of the furniture, and a warning light that blends
;  into the window behind it is decoration.
; ═══════════════════════════════════════════════════════════════════════════════

global _lockGui   := 0      ; the badge while it is up, else 0
global _lockShown := 0      ; which model it is currently NAMING, so a relabel is
                            ; only done when the answer actually changed

global LOCKBADGE_BG   := "1A1A1E"
global LOCKBADGE_INK  := "FFC24D"
global LOCKBADGE_W    := 220
global LOCKBADGE_H     := 46

; Bring the badge into line with the cfg: up and naming the locked model, or gone.
;
; The ONE entry point, called from a timer in mass/engine.ahk as well as straight
; after every lock change. Both, on purpose: the direct call is what makes the
; badge appear on the same keypress that locked, and the timer is what makes it
; appear when something OTHER than this process wrote the key — the GUI's Lock
; button is in main_window.ahk, a different process, and there is no message for
; it to send that this does not already cover.
LOCKBADGE_Sync() {
    global _lockShown
    n := LockedModelNo()
    if !n {
        if _lockShown
            LOCKBADGE_Hide()
        return
    }
    if (n = _lockShown)
        return
    LOCKBADGE_Show(n)
}

LOCKBADGE_Show(n) {
    global _lockGui, _lockShown, LOCKBADGE_BG, LOCKBADGE_INK, LOCKBADGE_W, LOCKBADGE_H

    ; Already up for another model: relabel rather than rebuild, so moving the lock
    ; from one model to the next does not flash a window at you mid-send.
    if _lockGui {
        try {
            _lockGui["LockName"].Text := _LOCKBADGE_Face(n)
            _lockShown := n
            return
        }
        ; Its controls are gone but the handle is not — rebuild from scratch.
        LOCKBADGE_Hide()
    }

    ; -Caption for no title bar, +ToolWindow so it is in neither the taskbar nor
    ; Alt-Tab — this is a light, not a window you switch to.
    lg := Gui("+AlwaysOnTop -Caption +ToolWindow -SysMenu +E0x08000000")
    lg.BackColor := LOCKBADGE_BG
    lg.MarginX := 0, lg.MarginY := 0
    lg.SetFont("s10 Bold c" LOCKBADGE_INK, "Segoe UI")
    t := lg.Add("Text", "vLockName x0 y7 w" LOCKBADGE_W " Center BackgroundTrans",
                _LOCKBADGE_Face(n))
    t.OnEvent("Click", LOCKBADGE_ClickUnlock)
    lg.SetFont("s8 Norm c9A9A9A", "Segoe UI")
    h := lg.Add("Text", "x0 y26 w" LOCKBADGE_W " Center BackgroundTrans",
                "click to unlock")
    h.OnEvent("Click", LOCKBADGE_ClickUnlock)

    pos := _LOCKBADGE_Pos()
    lg.Show("x" pos.x " y" pos.y " w" LOCKBADGE_W " h" LOCKBADGE_H " NoActivate")
    _lockGui := lg, _lockShown := n
    LOGV("model.lock", "badge up for model " n)
}

LOCKBADGE_Hide() {
    global _lockGui, _lockShown
    if _lockGui
        try _lockGui.Destroy()
    _lockGui := 0, _lockShown := 0
}

; The badge is the unlock button. Not only for convenience: the thing you notice
; when you realise the lock is still on IS the badge, so the fix has to be on it.
LOCKBADGE_ClickUnlock(*) {
    ClearMassLock()
    LOCKBADGE_Sync()
    SoundBeep(600, 70)
}

; ── right-click ───────────────────────────────────────────────────────────────
;  Its one item unlocks. There is deliberately NO "hide the badge" or "exit" here,
;  and that is not an omission — a dismissable badge is a locked MMA with nothing
;  on screen saying so, which is the exact state the whole file exists to make
;  impossible (see the header: "the only silent mode change is the one you find
;  out about from a fan"). So the way out of the badge stays the way out of the
;  LOCK, and right-click is a second, more explicit door to it than the bare
;  left-click.
;
;  It also cannot ExitApp. This file is #Included into mass/runtime.ahk, so the
;  process it would be quitting is the mass engine — or one of the account
;  scripts — not a badge.
;
;  WM_RBUTTONUP over the Gui "ContextMenu" event because the badge is two Text
;  controls filling the whole window, so the message lands on a control; the
;  GetAncestor hop is what lets one handler cover both without binding each.
LOCKBADGE_OnRButtonUp(wParam, lParam, msg, hwnd) {
    global _lockGui
    if !_lockGui
        return
    try {
        root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
        if (root != _lockGui.Hwnd)
            return
    } catch
        return
    m := Menu()
    m.Add("Unlock  (" _LOCKBADGE_Face(_lockShownNo()) ")", LOCKBADGE_ClickUnlock)
    try m.Show()
    return 0
}
OnMessage(0x0205, LOCKBADGE_OnRButtonUp)

; Which model the badge is currently naming. A tiny accessor rather than reading
; the global at the call site above, because _lockShown is 0 for "no badge" and the
; menu is only ever built while there is one — LockedModelNo() would re-read the
; ini for an answer this already knows.
_lockShownNo() {
    global _lockShown
    return _lockShown
}

_LOCKBADGE_Face(n) {
    return "LOCKED  ▸  " ModelLabel(n)
}

; Bottom-right of the work area the cursor is on, unless [Lock] BadgeX/BadgeY say
; otherwise. MonitorAreaAt is mass/model_picker.ahk's — same process, same need
; (do not be born half off the edge of a multi-monitor desk), so it is not defined
; twice.
_LOCKBADGE_Pos() {
    global MMA_CFG, LOCKBADGE_W, LOCKBADGE_H
    x := _IniInt(MMA_CFG, "Lock", "BadgeX", -1)
    y := _IniInt(MMA_CFG, "Lock", "BadgeY", -1)
    if (x >= 0 && y >= 0)
        return {x: x, y: y}
    ; CursorScreenPos, not MouseGetPos, and for the reason written out in full over
    ; in mass/model_picker.ahk: core/utils.ahk leaves this process defaulting to
    ; WINDOW-relative mouse coordinates, so a bare read here hands MonitorAreaAt a
    ; point measured from Infloww's top-left and the badge is parked in the corner of
    ; whichever monitor that number happens to land on.
    CursorScreenPos(&mx, &my)
    ma := MonitorAreaAt(mx, my)
    return {x: ma.r - LOCKBADGE_W - 24, y: ma.b - LOCKBADGE_H - 24}
}
