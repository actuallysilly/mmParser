#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "coords.ahk"
#Include "utils.ahk"
#Include "sequences.ahk"
#Include "features.ahk"

mouseControl := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "MouseControl", "1"))
openTabFu2   := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "OpenTabFu2",   "0"))
openTabFu3   := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "OpenTabFu3",   "0"))
openTabPpv     := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "OpenTabPpv",     "0"))
walletCheckFu3 := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "WalletCheckFu3", "0"))
editableFu1    := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "EditableFu1",    "0"))
editableFu2    := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "EditableFu2",    "0"))
editableFu3    := Integer(IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "EditableFu3",    "0"))

massNo := 1
modelFileNo := 1
doubleMM := false

ToggleDMMMsg(wParam, lParam, msg, hwnd) {
    global doubleMM
    doubleMM := !doubleMM
}
OnMessage(0x8001, ToggleDMMMsg)

SetWalletMsg(wParam, lParam, msg, hwnd) {
    global walletCheckFu3
    walletCheckFu3 := wParam
}
OnMessage(0x8002, SetWalletMsg)

SetEditableFuMsg(wParam, lParam, msg, hwnd) {
    global editableFu1, editableFu2, editableFu3
    fuIdx := msg - 0x8002   ; 0x8003→1, 0x8004→2, 0x8005→3
    if fuIdx = 1
        editableFu1 := wParam
    else if fuIdx = 2
        editableFu2 := wParam
    else if fuIdx = 3
        editableFu3 := wParam
}
OnMessage(0x8003, SetEditableFuMsg)
OnMessage(0x8004, SetEditableFuMsg)
OnMessage(0x8005, SetEditableFuMsg)

SndFuEditable(parts*) {
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(Trim(p))
    if !nonEmpty.Length
        return
    combined := ""
    for p in nonEmpty
        combined .= (combined != "" ? "`n" : "") p
    A_Clipboard := ""
    A_Clipboard := combined
    ClipWait(1)
    Send "^v"
}

m1 := {
mass: "Are my buttox cute?",
fu1: "I reckon that I would be quite photogenic `"arse up face down`", what do you think?",
fu1_5: "",
fu1_7: "",

fu2: "And if I were to find myself in that kind of predicament would you `"slap it before you clap it`"?",
fu2_5: "Would you make my naked arsecheeks bright red 🥺?",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "Imagine having me in doggy just like this, with my naked arse cheeks in a close up, wiggling up and down your nose so you can give me a little kiss before you slap and clap me mercilessly ❤️",
ppv_f1: "Would that make you into a British patriot?",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

m2 := {
mass: "",
fu1: "",
fu1_5: "",
fu1_7: "",

fu2: "",
fu2_5: "",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

m3 := {
mass: "",
fu1: "",
fu1_5: "",
fu1_7: "",

fu2: "",
fu2_5: "",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}


DoFu1(){
    global massNo, m1, m2, m3, doubleMM, editableFu1
    if !FuGate()
        return
    if AltIntercept(CurMass(), 1, false, editableFu1)
        return
    if editableFu1 {
        m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
        SndFuEditable(m.fu1, m.fu1_5, m.fu1_7)
        return
    }
    if doubleMM {
        sndFu(1, m1.fu1, m1.fu1_5, m1.fu1_7)
        sndFu(1, m2.fu1, m2.fu1_5, m2.fu1_7)
        return
    }
    switch massNo
    {
        case 1: sndFu(1, m1.fu1, m1.fu1_5, m1.fu1_7)
        case 2: sndFu(1, m2.fu1, m2.fu1_5, m2.fu1_7)
        case 3: sndFu(1, m3.fu1, m3.fu1_5, m3.fu1_7)
    }
}
DoFu2(){
    global massNo, m1, m2, m3, doubleMM, editableFu2, openTabFu2
    if !FuGate()
        return
    if AltIntercept(CurMass(), 2, false, editableFu2)
        return
    if editableFu2 {
        m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
        SndFuEditable(m.fu2, m.fu2_5, m.fu2_7)
        return
    }
    if doubleMM {
        sndFu(2, m1.fu2, m1.fu2_5, m1.fu2_7)
        sndFu(2, m2.fu2, m2.fu2_5, m2.fu2_7)
    } else {
        switch massNo {
            case 1: sndFu(2, m1.fu2, m1.fu2_5, m1.fu2_7)
            case 2: sndFu(2, m2.fu2, m2.fu2_5, m2.fu2_7)
            case 3: sndFu(2, m3.fu2, m3.fu2_5, m3.fu2_7)
        }
    }
    if openTabFu2
        clickReturn(openInNewTabButton)
}
DoFu3(){
    global massNo, m1, m2, m3, doubleMM, walletCheckFu3, editableFu3, openTabFu3
    if !FuGate()
        return
    if AltIntercept(CurMass(), 3, false, walletCheckFu3 || editableFu3)
        return
    if walletCheckFu3 || editableFu3 {
        m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
        SndFuEditable(m.fu3, m.fu3_5, m.fu3_7)
        return
    }
    if doubleMM {
        sndFu(3, m1.fu3, m1.fu3_5, m1.fu3_7)
        sndFu(3, m2.fu3, m2.fu3_5, m2.fu3_7)
    } else {
        switch massNo {
            case 1: sndFu(3, m1.fu3, m1.fu3_5, m1.fu3_7)
            case 2: sndFu(3, m2.fu3, m2.fu3_5, m2.fu3_7)
            case 3: sndFu(3, m3.fu3, m3.fu3_5, m3.fu3_7)
        }
    }
    if openTabFu3
        clickReturn(openInNewTabButton)
}

; sends the mass body itself (the text that follows !mm / !mma) — pastes only, so
; you can review before sending, matching the ppv-base behaviour of DoF4.
DoMass(){
    global massNo, m1, m2, m3
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    if m.mass = ""
        return
    A_Clipboard := m.mass
    ClipWait(0.5)
    Send "^v"
}

DoF4(){
    global massNo, m1, m2, m3, openTabPpv
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    A_Clipboard := m.ppv_base
    ClipWait(0.1)
    Send "^v"
    if openTabPpv
        clickReturn(openInNewTabButton)
}

DoF5(){
    global massNo, m1, m2, m3
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

DoAltF4(){
    global massNo, m1, m2, m3
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

; ── hotkey registrations ──────────────────────────────────────────────────────
; No keys here — every key lives in hotkeys.ini. These lines only say which
; function each feature runs.

ClickUnread()  => clickOn(unreadBtn)
ClickHome()    => clickOn(home)
ClickPpv()     => clickOn(ppvOpenNotif)

; Remembers what was typed before Enter sends it, so util.recoverMsg can put it
; back. Chrome only — see hotkeys.ahk's "chrome" context.
CaptureEnter() {
    global _lastTyped
    saved := A_Clipboard
    A_Clipboard := ""
    Send "^a"
    Sleep 30
    Send "^c"
    ClipWait 0.3
    if A_Clipboard != ""
        _lastTyped := A_Clipboard
    A_Clipboard := saved
    Send "{Enter}"
}

; navigation
; ── Alt follow-ups ────────────────────────────────────────────────────────────
; The mass currently selected by massNo. Alt handling needs the whole object,
; not one field, so the chooser can read every variant of a group.
CurMass() {
    global massNo, m1, m2, m3
    return massNo = 1 ? m1 : massNo = 2 ? m2 : m3
}

; ctrl+<follow-up key>. Offers the alternatives; with nothing to choose between
; it just does what the plain key does, so the ctrl variant is never a dead key.
DoAltFu1() {
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 1, true, editableFu1)
        DoFu1()
}
DoAltFu2() {
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 2, true, editableFu2)
        DoFu2()
}
DoAltFu3() {
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 3, true, walletCheckFu3 || editableFu3)
        DoFu3()
}

; ── --Name branches ───────────────────────────────────────────────────────────
; The trunk (base fu1/fu2/fu3) sends on the normal keys. A branch is a continuation
; you switch to: pick one, then walk its follow-ups and ppv. The chosen branch is
; remembered per mass (_activeBranch) so fu2/fu3/ppv keep sending the same one.
DoBranchPick() {
    global _activeBranch, massNo
    if !FuGate()
        return
    brs := BranchList(CurMass())
    if !brs.Length
        return
    idx := 1
    if brs.Length > 1 {
        labels := []
        for b in brs
            labels.Push(b.name (b.fu[1].Length ? "  —  " b.fu[1][1] : ""))
        idx := Overload_Choose(labels)
        if !idx
            return
    }
    _activeBranch[massNo] := idx
    BranchSendGroup(brs[idx].fu[1])
}
DoBranchFu2() => BranchSendActiveGroup(2)
DoBranchFu3() => BranchSendActiveGroup(3)
DoBranchPpv() {
    global _activeBranch, massNo
    brs := BranchList(CurMass())
    if _activeBranch.Has(massNo) && _activeBranch[massNo] <= brs.Length
        BranchSendPpv(brs[_activeBranch[massNo]].ppv)
}
BranchSendActiveGroup(g) {
    global _activeBranch, massNo
    if !FuGate()
        return
    brs := BranchList(CurMass())
    if _activeBranch.Has(massNo) && _activeBranch[massNo] <= brs.Length
        BranchSendGroup(brs[_activeBranch[massNo]].fu[g])
}

HK_Bind("nav.unread",      Unread)
HK_Bind("nav.focusAuto",   focusAuto)
HK_Bind("nav.nextChat",    nextChat)
HK_Bind("nav.unreadLeft",  Unread)
HK_Bind("nav.focusTop",    focusTop)
HK_Bind("nav.clickUnread", ClickUnread)
HK_Bind("nav.clickHome",   ClickHome)
HK_Bind("nav.clickPpv",    ClickPpv)

; send
HK_Bind("mass.1.fu1",      DoFu1)
HK_Bind("mass.1.fu2",      DoFu2)
HK_Bind("mass.1.fu3",      DoFu3)
HK_Bind("mass.1.fu1short", DoFu1)
HK_Bind("mass.1.fu2short", DoFu2)
HK_Bind("mass.1.fu3short", DoFu3)
HK_Bind("mass.1.mFu1",     DoFu1)
HK_Bind("mass.1.mFu2",     DoFu2)
HK_Bind("mass.1.mFu3",     DoFu3)
HK_Bind("mass.1.smFu1",    DoFu1)
HK_Bind("mass.1.smFu2",    DoFu2)
HK_Bind("mass.1.smFu3",    DoFu3)
HK_Bind("mass.1.ppv",      DoF4)
HK_Bind("mass.1.ppvFus",   DoF5)
HK_Bind("mass.1.b1Ppv",    DoAltF4)
; --Name branches. brPick picks a branch + sends its fu1; brFu2/brFu3 walk that
; branch's fu2/fu3; brPpv pastes its ppv. Gated to the active model (like the
; follow-ups), so these keys can overlap another model's keys without clashing.
HK_Bind("mass.1.brPick", DoBranchPick)
HK_Bind("mass.1.brFu2",  DoBranchFu2)
HK_Bind("mass.1.brFu3",  DoBranchFu3)
HK_Bind("mass.1.brPpv",  DoBranchPpv)
HK_Bind("mass.1.altFu1", DoAltFu1)
HK_Bind("mass.1.altFu2", DoAltFu2)
HK_Bind("mass.1.altFu3", DoAltFu3)

; chat + utilities
HK_Bind("chat.captureEnter",   CaptureEnter)
HK_Bind("util.afkClick",       AfkClick)
HK_Bind("util.recoverMsg",     RecoverLastMsg)
HK_Bind("util.clickSecondGrey", ClickSecondGrey)
HK_Bind("util.debugGrey",      DebugGreySearch)

if !mouseControl {
    for _id in ["mass.1.mFu1", "mass.1.mFu2", "mass.1.mFu3"]
        HK_SetState(_id, "Off")
}

; Share send keys across model scripts: only this model's copy stays registered
; while its tab is active.
StartFuGating(HK_ModelSendIds(modelFileNo))

; type __mm to paste the ACTIVE model's mass body (review, then send). Gated so
; only the focused model's script fires it — see UniversalSendActive in utils.ahk.
#HotIf UniversalSendActive()
:*X:__mm::DoMass()
#HotIf

