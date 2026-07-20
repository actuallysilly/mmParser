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
mass: "Are you feeling obedient?",
fu1: "I'm in the mood to be quite dominant today, and for domination you need two things, a cute English girl and a naked boy... Will it take more than 1 min?",
fu1_5: "",
fu1_7: "",

fu2: "I've been fantasizing about controlling your cock and making it submit to my will, or my nudes, both work. Do you mind gripping it tightly and calling me mistress?",
fu2_5: "",
fu2_7: "",

fu3: "Give me 21 strokes now... Tight grip and tell me how it felt",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "I'm going all out tonight, it will be an insanely hard try not to cum and you will probably cum right away... But just try okay?",
ppv_f2: "",
ppv_f3: "",

orOr: "",
b1_label: "",
b2_label: "",
b2_fu1: "",
b2_fu1_5: "",
b2_fu1_7: "",

b2_fu2: "",
b2_fu2_5: "",
b2_fu2_7: "",

b2_fu3: "",
b2_fu3_5: "",
b2_fu3_7: "",

b2_ppv_base: "",
b2_ppv_f1: "",
b2_ppv_f2: "",
b2_ppv_f3: "",

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
mass: "Beach or bedroom tonight? 🏖️",
fu1: "I've been going back and forth on it all day",
fu1_5: "",
fu1_7: "",

fu2: "Because one of them involves a lot less clothing",
fu2_5: "",
fu2_7: "",

fu3: "So which is it, before I pick for you? 😌",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

orOr: "",
b1_label: "",
b2_label: "",
b2_fu1: "",
b2_fu1_5: "",
b2_fu1_7: "",

b2_fu2: "",
b2_fu2_5: "",
b2_fu2_7: "",

b2_fu3: "",
b2_fu3_5: "",
b2_fu3_7: "",

b2_ppv_base: "",
b2_ppv_f1: "",
b2_ppv_f2: "",
b2_ppv_f3: "",

fu1_alt0: "Honestly I've changed my mind about six times since this morning",
fu1_alt1: "You get to decide, I'm useless at picking",
fu1_alt2: "",

fu2_alt0: "One of those options has a strict no-clothing policy`nI'll let you guess which",
fu2_alt1: "Fair warning though`nOnly one of them has a door that locks`nChoose carefully x",
fu2_alt2: "",

fu3_alt0: "Don't leave me hanging, I'm already halfway packed",
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

orOr: "",
b1_label: "",
b2_label: "",
b2_fu1: "",
b2_fu1_5: "",
b2_fu1_7: "",

b2_fu2: "",
b2_fu2_5: "",
b2_fu2_7: "",

b2_fu3: "",
b2_fu3_5: "",
b2_fu3_7: "",

b2_ppv_base: "",
b2_ppv_f1: "",
b2_ppv_f2: "",
b2_ppv_f3: "",

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
        clickOn(openInNewTabButton)
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
        clickOn(openInNewTabButton)
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

IsOrOr() {
    global massNo, m1, m2, m3
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    return m.orOr
}

DoB2Fu1(){
    global massNo, m1, m2, m3
    switch massNo {
        case 1: sndFu(1, m1.b2_fu1, m1.b2_fu1_5, m1.b2_fu1_7)
        case 2: sndFu(1, m2.b2_fu1, m2.b2_fu1_5, m2.b2_fu1_7)
        case 3: sndFu(1, m3.b2_fu1, m3.b2_fu1_5, m3.b2_fu1_7)
    }
}
DoB2Fu2(){
    global massNo, m1, m2, m3
    switch massNo {
        case 1: sndFu(2, m1.b2_fu2, m1.b2_fu2_5, m1.b2_fu2_7)
        case 2: sndFu(2, m2.b2_fu2, m2.b2_fu2_5, m2.b2_fu2_7)
        case 3: sndFu(2, m3.b2_fu2, m3.b2_fu2_5, m3.b2_fu2_7)
    }
}
DoB2Fu3(){
    global massNo, m1, m2, m3
    switch massNo {
        case 1: sndFu(3, m1.b2_fu3, m1.b2_fu3_5, m1.b2_fu3_7)
        case 2: sndFu(3, m2.b2_fu3, m2.b2_fu3_5, m2.b2_fu3_7)
        case 3: sndFu(3, m3.b2_fu3, m3.b2_fu3_5, m3.b2_fu3_7)
    }
}

DoF4(){
    global massNo, m1, m2, m3, openTabPpv
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    A_Clipboard := m.ppv_base
    ClipWait(0.1)
    Send "^v"
    if openTabPpv
        clickOn(openInNewTabButton)
}

DoF5(){
    global massNo, m1, m2, m3
    if IsOrOr() {
        DoB2Fu1()
        return
    }
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

DoF6(){
    if IsOrOr()
        DoB2Fu2()
}

DoF7(){
    if IsOrOr()
        DoB2Fu3()
}

DoAltF4(){
    global massNo, m1, m2, m3
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

DoF8(){
    global massNo, m1, m2, m3
    if !IsOrOr()
        return
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    A_Clipboard := m.b2_ppv_base
    ClipWait(0.1)
    Send "^v"
}

DoAltF8(){
    global massNo, m1, m2, m3
    if !IsOrOr()
        return
    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3
    snd(m.b2_ppv_f1)
    snd(m.b2_ppv_f2)
    snd(m.b2_ppv_f3)
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
HK_Bind("mass.1.b2Fu2",    DoF6)
HK_Bind("mass.1.b2Fu3",    DoF7)
HK_Bind("mass.1.b1Ppv",    DoAltF4)
HK_Bind("mass.1.b2Ppv",    DoF8)
HK_Bind("mass.1.b2PpvFus", DoAltF8)
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

; type __mm to paste the current mass body (what follows !mm / !mma); review, then send.
:*X:__mm::DoMass()

