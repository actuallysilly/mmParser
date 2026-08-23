#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  model_picker.ahk — one window, two questions, both of the form "which model?"
; ───────────────────────────────────────────────────────────────────────────────
;  ── question 2: __mm, in any mode ──────────────────────────────────────────
;  The mass is the message you send dozens of times a day, and with N models
;  there is no such thing as "the" mass — there are N of them, one live slot per
;  model. Bare __mm used to resolve that the same way every other shared key
;  does, which meant that away from the detector it pasted whichever model you
;  last selected, and finding out WHICH meant going back to Discord to read the
;  text you were about to paste.
;
;  So __mm asks, and the buttons carry a preview of the text they will paste:
;
;      one model configured   →  __mm  →  paste it, exactly as before
;      two or more            →  __mm  →  window  →  paste the one you pick
;
;  The preview is the point, not decoration. It is also the only place in MMA
;  that shows an EMPTY mass slot before you paste it — the "__mm does nothing"
;  complaint in DoMass is always a live massNo pointing at a slot nobody filled
;  in, and here that slot reads "(empty)" instead of failing after the keypress.
;
;  This pick aims one paste and nothing else — see _PickChoose.
;
;  ── question 1: the shared follow-up keys, in "I pick" mode ─────────────────
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
;      shared PPV key          →  window  →  that model's PPV base
;      shared PPV follow-ups   →  window  →  that model's PPV follow-ups
;
;  The PPV pair is behind its own FEAT switch (`ppvPicker`), because it fires a
;  handful of times a shift where the follow-ups fire constantly — wanting the
;  window on one and not the other is a reasonable position. Its buttons preview,
;  the follow-ups' do not; see _PickHasPreview for why.
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
; What this pick will do once you answer: 1/2/3 for a follow-up group, or the
; string "mass" for __mm. A string rather than a fourth number so that no arithmetic
; on it can ever be right by accident — every reader has to switch on it.
global _pickGroup   := 0
global _pickPrevWin := 0    ; the window to give the keyboard back to
; The "lock to the model I pick" checkbox, or 0 on the windows that do not offer
; one. Read at the moment of the choice, before the window is destroyed.
global _pickLockChk := 0

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

; What a [mass.active] slot should ASK about, or 0 for the slots that ask nothing
; and keep manual mode's remembered model.
;
;   fu1 / fu2short / mFu3 / altFu2 …  →  1, 2 or 3   the follow-up group
;   ppv / mPpv                        →  "ppv"
;   ppvFus / mPpvFus                  →  "ppvFus"
;   mass / nextFu / anything else     →  0
;
; Derived from the slot NAME rather than a second list of handlers: fu2, fu2short,
; mFu2 and altFu2 are four ids for one action, and a hand-kept list of them is the
; thing that goes stale the next time a slot is added.
;
; ── why PPV is here and `mass` is not ────────────────────────────────────────
; The PPV keys have the follow-up keys' exact failure shape — in "I pick" mode they
; send, confidently, to a model nothing on screen names — and a PPV goes out at a
; price attached to a specific model's account. It is behind its own FEAT switch
; because it fires a handful of times a shift where the follow-ups fire constantly,
; so wanting the window on one and not the other is a reasonable position.
;
; `mass` staying 0 is not the same thing as __mm never asking. The [mass.active]
; mass KEY keeps the remembered model; the __mm HOTSTRING has its own entry point
; (MassSendOrPick) and asks in every mode, not just this one. Two ways to paste a
; mass, and the one you reach for when you are unsure which model you are on asks.
;
; `nextFu` stays 0 for a different reason: it reads the chat to decide WHICH
; follow-up to send, so it is already looking at the screen you would be answering
; about, and it is the one shared key where a window would cost more than it saves.
PickGroupForSlot(slot) {
    if RegExMatch(slot, "i)^(?:m|alt)?fu([123])(?:short)?$", &m)
        return Integer(m[1])
    if FEAT("ppvPicker") {
        if RegExMatch(slot, "i)^m?ppv$")
            return "ppv"
        ; No b1Ppv here even though it runs DoPpvFus: it is a [mass.1] slot, model 1
        ; by definition, and never reaches _RunOnActiveModel to be asked about.
        if RegExMatch(slot, "i)^m?ppvFus$")
            return "ppvFus"
    }
    return 0
}

; How much of a mass a button shows. Long enough to tell two masses apart at a
; glance, short enough that the button is still a button.
global PREVIEW_CHARS := 46

; ── the two entry points ──────────────────────────────────────────────────────
;  Both open the same window. `group` is the whole of the difference, which is why
;  the window builder is not duplicated: the follow-up picker and the mass picker
;  are one question asked about two verbs.
MassPickThenFu(group, *) {
    _PickOpen(group)
}

; __mm. One model and there is nothing to ask, so it pastes, exactly as it always
; did. The count comes from the same _PickModelCount the grid is built from, so
; "the window would have had one button" and "no window at all" cannot disagree.
MassSendOrPick(*) {
    count := _PickModelCount()
    if (count <= 1) {
        LOGV("mass.pick", "__mm with " count " model configured — nothing to ask,"
                        . " pasting model 1's mass")
        _SetCurModel(1)
        DoMass()
        return
    }
    _PickOpen("mass")
}

; ── what each group is called, and whether its buttons carry a preview ────────
;  The follow-up groups do not preview. Their text depends on alts, branches and
;  the editable toggle, so whatever a button showed could differ from what the send
;  actually resolves to — a preview that is usually right is worse than none.
;  `mass` and `ppv` both paste one fixed field, so theirs cannot drift.
_PickHasPreview(group) {
    return (group = "mass") || (group = "ppv") || (group = "ppvFus")
}

; What this pick is FOR, in log prose. "__mm" rather than "the mass" because that
; is what you typed, and so what you will search the log for.
_PickWhat(group) {
    switch group {
        case "mass":   return "__mm"
        case "ppv":    return "the PPV"
        case "ppvFus": return "the PPV follow-ups"
    }
    return "follow-up " group
}

_PickTitle(group) {
    switch group {
        case "mass":   return "Paste mass"
        case "ppv":    return "Paste PPV"
        case "ppvFus": return "Send PPV follow-ups"
    }
    return "Send follow-up " group
}

_PickPrompt(group) {
    switch group {
        case "mass":   return "Which model's mass?"
        case "ppv":    return "Which model's PPV?"
        case "ppvFus": return "Whose PPV follow-ups?"
    }
    return "Follow-up " group " — which model?"
}

; The first line of what model n's button will actually paste.
;
; Runs while the window is being BUILT — off the hotkey thread — so a library that
; will not read shows as "(unreadable)" on one button instead of throwing somewhere
; nothing can catch it. "(empty)" is the one that earns its keep: the standing
; "__mm does nothing" complaint is a live massNo pointing at a slot that was never
; filled in, and this is the only place in MMA that says so BEFORE the keypress
; rather than in the log afterwards. The same is true of a PPV nobody wrote.
_PickPreview(n, group) {
    global MASS_DOC, PREVIEW_CHARS
    try {
        m := MASS_AsObject(MASS_Active(MASS_DOC, n))
        switch group {
            case "mass": text := m.mass
            case "ppv":  text := m.ppv_base
            case "ppvFus":
                ; The first one that has text, and how many follow it — DoPpvFus
                ; sends all three, so the count is the part worth knowing.
                text := "", have := 0
                for _, p in [m.ppv_f1, m.ppv_f2, m.ppv_f3] {
                    if (Trim(p) = "")
                        continue
                    have++
                    if (text = "")
                        text := Trim(p)
                }
                if (have > 1)
                    text := "(" have ") " text
            default: text := ""
        }
        text := Trim(text)
    } catch as e {
        LOGW("mass.pick", "could not read model " n "'s " group " for the preview — "
                        . LOG_Err(e))
        return "(unreadable)"
    }
    if (text = "")
        return "(empty)"
    ; One line. A mass is several paragraphs; a button face is a strip.
    text := RegExReplace(text, "\s+", " ")
    if (StrLen(text) > PREVIEW_CHARS)
        text := SubStr(text, 1, PREVIEW_CHARS - 1) "…"
    return text
}

; The lock toggle's label, in whichever of its two states it is in — and it names
; the KEY that is actually bound, not the one this file would like to exist. An
; unbound lock key is a real state (HK_MergeDefaults only seeds hotkeys.ini, and any
; key can be blanked in the Hotkeys window), and naming a key that does nothing on
; this machine is how a safety valve becomes a rumour.
_PickLockLabel() {
    key := HK_Key("mass.select.lock")
    also := (key != "" ? "   (same as " key ")" : "")
    n := LockedModelNo()
    if n
        return "Locked to " ModelLabelShort(n) " — untick to unlock" also
    return "Lock to this model — stop asking" also
}

; The checkbox IS the lock, flipped the moment you click it. Ticking locks to the
; model the shared keys are currently aimed at; the buttons above then MOVE the lock
; if you pick a different one, which is the same thing SelectModel does.
;
; Immediate rather than on-pick, because that is what a toggle means, and because
; the sequence this exists for — pick, lock, work, unlock — has the lock going on
; AFTER the model is already settled.
_PickLockToggle(ctl, *) {
    if !ctl.Value {
        ClearMassLock()
        LOCKBADGE_Sync()
        SoundBeep(600, 70)
        ctl.Text := _PickLockLabel()
        return
    }
    ; The model this window's keys are already aimed at. This window only opens in
    ; "I pick" mode, where that is the one you last said — no screen is read, so
    ; there is nothing here that can fail or need refusing.
    if !LockToModel(ManualModelNo())
        ctl.Value := 0                  ; refused: do not leave a tick claiming a lock
    ctl.Text := _PickLockLabel()
}

_PickOpen(group) {
    global _pickGui, _pickHwnd, _pickGroup, _pickPrevWin, _pickLockChk

    ; Set only on the rebuild path below. The window we must give the keyboard back
    ; to was captured when the FIRST picker opened; by the time a rebuild has closed
    ; that picker, "the active window" is whatever Windows fell back to — quite
    ; possibly the corpse of the picker itself — so it is carried over rather than
    ; measured again.
    rebuiltFrom := 0

    ; Already open: a second press re-aims the SAME window at the new follow-up
    ; rather than stacking a second one. Pressing fu1 then fu2 without picking is
    ; a change of mind, not two pending sends.
    ;
    ; Only within a shape, though. _PickRetitle rewrites the title and the prompt and
    ; NOTHING else — it cannot grow the buttons, and it cannot put a preview on them
    ; or change the one already there. Re-aiming a follow-up window at "ppv" would
    ; leave a grid of bare names under a heading promising PPV text; re-aiming a
    ; "mass" window at "ppv" would leave every button showing the wrong message
    ; entirely, which is the worse of the two by a distance. Across shapes the window
    ; is rebuilt: a flicker, in exchange for a window that means what it says.
    ;
    ; "Same shape" is per GROUP for the previewing ones, not just previewing-or-not,
    ; because their button faces are group-specific.
    if _pickGui {
        sameShape := _PickHasPreview(_pickGroup) || _PickHasPreview(group)
                        ? (_pickGroup = group)
                        : true                      ; two follow-up groups: interchangeable
        if sameShape {
            _pickGroup := group
            LOGI("mass.pick", "picker already open — now aimed at " _PickWhat(group))
            _PickRetitle()
            try WinActivate("ahk_id " _pickHwnd)
            return
        }
        LOGI("mass.pick", "picker was open for " _PickWhat(_pickGroup)
                        . " and is now wanted for " _PickWhat(group)
                        . " — rebuilding, the two are not the same window")
        rebuiltFrom := _pickPrevWin
        _PickClose()
    }

    count := _PickModelCount()
    wide := _PickHasPreview(group)
    _pickGroup   := group
    _pickPrevWin := rebuiltFrom ? rebuiltFrom : WinExist("A")   ; before we steal the foreground
    LOGI("mass.pick", _PickWhat(group)
                    . " — asking which of " count " model(s),"
                    . " over " (_pickPrevWin ? WinGetProcessName("ahk_id " _pickPrevWin)
                                             : "(nothing focused)"))

    ; Labels first: on a dark theme a static takes its colour from the window font
    ; at creation time and cannot be told afterwards (see core/theme.ahk).
    pg := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", _PickTitle(group))
    pg.BackColor := THEME_WindowBg()
    pg.SetFont("s10 Bold" THEME_FontOpt(), "Segoe UI")

    ; A grid, not a row. One row of N buttons is 150px per model — fine at three,
    ; 1.8 metres of window at twelve. Four to a row keeps the window roughly square
    ; and every button the same size, which is what makes it readable at a glance
    ; rather than a menu you have to parse.
    ;
    ; The previewing grids are wider and shorter-rowed for one reason: their buttons
    ; carry a second line of message text. A 150px button cannot show enough of a
    ; mass to tell it from another one, and a preview you have to squint at is the
    ; Discord trip it was meant to replace.
    BTN_W := wide ? 300 : 150
    BTN_H := wide ?  50 :  38
    GAP := 10, PAD := 12
    perRow := Min(count, wide ? 3 : 4)
    rows   := Ceil(count / perRow)
    winW   := PAD * 2 + perRow * BTN_W + (perRow - 1) * GAP
    lbl := pg.Add("Text", "x" PAD " y10 w" (winW - PAD * 2), _PickPrompt(group))

    ; s8 for the previewing buttons: two lines have to fit in 50px, and the second
    ; line is the longer of the two.
    pg.SetFont("s" (wide ? "8" : "10") " Norm" THEME_FontOpt(), "Segoe UI")
    Loop count {
        n := A_Index
        col := Mod(n - 1, perRow), row := (n - 1) // perRow
        x := PAD + col * (BTN_W + GAP)
        y := BTN_TOP + row * (BTN_H + GAP)
        ; "1  Aliw" — the number leads because the number is also the key, for the
        ; first nine. Past that the keyboard runs out and the mouse or Tab is the
        ; way; the label stops promising a key that does not exist.
        face := (n <= 9 ? n "   " : "") ModelLabelShort(n)
        if wide
            face .= "`n" _PickPreview(n, group)
        b := pg.Add("Button", "x" x " y" y " w" BTN_W " h" BTN_H
                            . (n = 1 ? " Default" : ""), face)
        b.OnEvent("Click", _PickChoose.Bind(n))
    }

    hintY := BTN_TOP + rows * (BTN_H + GAP) + 2
    pg.SetFont("s8 Norm" THEME_FontOpt(), "Segoe UI")

    ; ── the way out of being asked ────────────────────────────────────────────
    ; The working shape this whole feature exists for:
    ;
    ;     pick the model  →  LOCK  →  clear that model's messages  →  UNLOCK
    ;     →  next model
    ;
    ; This window is right for the first step and wrong for the third: answering
    ; forty messages for one model means forty windows asking a question that was
    ; settled at step one. So the lock is a TOGGLE, right here — the same toggle the
    ; lock key flips, not a promise about a later keypress. Tick it and the lock is
    ; on before you let go of the mouse; untick it and it is off.
    ;
    ; HERE and not only on a hotkey, because this is the window you are looking at
    ; at the exact moment the asking becomes the problem. A feature whose only
    ; entry point is a key you have to know about is a feature nobody finds. The key
    ; is still the one you will actually use mid-shift — the point of the checkbox is
    ; that it names the key, and that the state is visible somewhere other than the
    ; badge.
    ;
    ; Never on the `mass` window. __mm aims ONE paste and deliberately does not even
    ; move the remembered model (see _PickChoose); offering to make it re-aim every
    ; shared key for the next twenty minutes would be the same mode-change-in-
    ; convenience's-clothing, with a bigger blast radius.
    _pickLockChk := 0
    if (group != "mass") {
        ; Reads the live state rather than starting unticked. In practice a lock
        ; stops this window opening at all, so it is always off when you get here —
        ; but a control that shows a state must READ that state, or the day the two
        ; can differ is the day it starts lying.
        _pickLockChk := pg.Add("Checkbox", "x" PAD " y" hintY " w" (winW - PAD * 2)
                                         . " h20" (MassIsLocked() ? " Checked" : ""),
                               _PickLockLabel())
        _pickLockChk.OnEvent("Click", _PickLockToggle)
        hintY += 22
    }

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
        try _pickGui.Title := _PickTitle(_pickGroup)
        try _pickGui["Static1"].Text := _PickPrompt(_pickGroup)
    }
}

_PickClose() {
    global _pickGui, _pickHwnd, _pickLockChk
    if _pickGui
        try _pickGui.Destroy()
    ; The checkbox goes with the window it belonged to. Left pointing at a destroyed
    ; control it is a live-looking handle that answers every question with a throw.
    _pickGui := 0, _pickHwnd := 0, _pickLockChk := 0
}

_PickCancel() {
    global _pickGroup
    LOGI("mass.pick", "cancelled — " _PickWhat(_pickGroup) " not sent")
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
    global _pickGroup, _pickGui, _pickLockChk

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
    ; Read BEFORE the window is destroyed. Obvious written down, and the sort of
    ; thing that reads fine three lines lower and throws on a dead control.
    ;
    ; Ticked means a lock is ALREADY on (the checkbox flips it on click, see
    ; _PickLockToggle) — aimed at whatever the shared keys were pointing at when it
    ; was ticked. Choosing a model here MOVES it, exactly as a select key does.
    wantLock := false
    if _pickLockChk
        try wantLock := _pickLockChk.Value ? true : false
    _PickClose()
    _PickRestoreFocus()

    ; _SetCurModel aims THIS send and is unconditional.
    ;
    ; SetManualModel is not, and the split is the whole difference between the two
    ; questions. Picking a model for a FOLLOW-UP is a statement about which model
    ; you are working on — it is the answer the shared [mass.active] keys will keep
    ; asking for — so it sticks, for the same reason SelectModel does both.
    ;
    ; Picking one for __mm is not. You paste one model's mass into one chat; making
    ; that silently re-aim fu1, the PPV key and next-follow-up would be a mode change
    ; wearing a convenience's clothes, and you would find out from the follow-up that
    ; went to the wrong fan afterwards.
    ;
    ; The PPV groups stick, WITH the follow-ups and not with __mm. They are
    ; [mass.active] keys — you pressed the shared key, whose whole contract is "the
    ; model I am working on" — and a PPV opens an exchange the follow-ups then
    ; continue. Answering "model 3" for the PPV and then having the next fu1 go
    ; elsewhere would be the wrong-fan bug with extra steps. __mm is the odd one out
    ; because it is a hotstring you type, not a shared key you bound.
    _SetCurModel(n)
    if (group != "mass")
        SetManualModel(n)

    LOGI("mass.pick", "model " n " (" ModelLabel(n) ") picked — " _PickWhat(group)
                    . (group = "mass" ? "; the remembered active model is unchanged"
                                      : "")
                    . (wantLock ? "; the lock toggle was ticked" : ""))

    ; Before the send, not after: the lock is the answer to the NEXT twenty
    ; keypresses, and it should be recorded whether or not this one goes out
    ; cleanly. LockToModel puts the badge up and confirms, so the window closing and
    ; a lock quietly appearing cannot happen.
    ;
    ; Guarded on the model actually CHANGING, or ticking the box and then clicking
    ; the model it already locked to would beep and toast a second time about
    ; nothing.
    if (wantLock && LockedModelNo() != n)
        LockToModel(n)

    switch group {
        case "mass":   DoMass()
        case "ppv":    DoPpv()
        case "ppvFus": DoPpvFus()
        case 1: DoFu1()
        case 2: DoFu2()
        case 3: DoFu3()
        default:
            LOGE("mass.pick", "group " group " is not one this picker knows how to"
                            . " send — nothing sent")
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
