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
mass: "What's your favourite animal?",
fu1: "My favourite animals are ducks, dolphins and the beast I'm going to awaken within you once I show you all of my body ❤️",
fu1_5: "",
fu1_7: "",

fu2: "How would you feel if I were to shove my magnificent fae titties into your face, feral style of course and say `"You need to suck on them for the ritual to work`"?",
fu2_5: "Also I forgot to note, your trousers need to be off too, for the ritual..",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "But... Do you think depositing large amounts of saliva onto my bare skin while holding me tight will get something else wet?",
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
b2_ppv_f3: ""
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
b2_ppv_f3: ""
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
b2_ppv_f3: ""
}


DoFu1(){
    global massNo, m1, m2, m3, doubleMM, editableFu1
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

; navigation
Bind Key("Unread",      "!-"),     (*) => Unread()
Bind Key("FocusAuto",   "!Space"), (*) => focusAuto()
Bind Key("NextChat",    "Down"),   (*) => nextChat()
Bind Key("UnreadLeft",  "+Left"),  (*) => Unread()
Bind Key("FocusTop",    "Up"),     (*) => focusTop()
Bind Key("ClickUnread", "Del"),    (*) => clickOn(unreadBtn)
Bind Key("ClickHome",   "End"),    (*) => clickOn(home)
Bind Key("ClickPpv",    "PgDn"),   (*) => clickOn(ppvOpenNotif)

; send — shortcut keys
Bind Key("Fu1",  "Ins"),  (*) => DoFu1()
Bind Key("Fu2",  "Home"), (*) => DoFu2()
Bind Key("Fu3",  "PgUp"), (*) => DoFu3()

; send — primary keys
Bind Key("PFu1",     "F1"),  (*) => DoFu1()
Bind Key("PFu2",     "F2"),  (*) => DoFu2()
Bind Key("PFu3",     "F3"),  (*) => DoFu3()
Bind Key("Ppv",      "F4"),  (*) => DoF4()
Bind Key("PpvFus",   "F5"),  (*) => DoF5()
Bind Key("B2Fu2",    "F6"),  (*) => DoF6()
Bind Key("B2Fu3",    "F7"),  (*) => DoF7()
Bind Key("B1Ppv",    "!F4"), (*) => DoAltF4()
Bind Key("B2Ppv",    "F8"),  (*) => DoF8()
Bind Key("B2PpvFus", "!F8"), (*) => DoAltF8()

; send — mouse
Bind Key("MFu1", "XButton2"), (*) => DoFu1()
Bind Key("MFu2", "XButton1"), (*) => DoFu2()
Bind Key("MFu3", "^MButton"), (*) => DoFu3()
Bind SM_1, (*) => DoFu1()
Bind SM_2, (*) => DoFu2()
Bind SM_3, (*) => DoFu3()

if !mouseControl {
    for _mk in [Key("MFu1", "XButton2"), Key("MFu2", "XButton1"), Key("MFu3", "^MButton")] {
        try Hotkey _mk, "Off"
    }
}

Bind Key("RecoverMsg",      "^+z"), (*) => RecoverLastMsg()
Bind Key("ClickSecondGrey", SM_12), (*) => ClickSecondGrey()
Bind SM_11, (*) => DebugGreySearch()

#HotIf WinActive("ahk_exe chrome.exe")
Enter:: {
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
#HotIf

