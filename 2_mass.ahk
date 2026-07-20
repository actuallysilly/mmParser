#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"


massNo := 2
modelFileNo := 2 
; dhbsj i


m1 := {
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
    switch massNo
    {
        case 1:
            sndFu(1, m1.fu1, m1.fu1_5, m1.fu1_7)
        case 2:
            sndFu(1, m2.fu1, m2.fu1_5, m2.fu1_7)
        case 3:
            sndFu(1, m3.fu1, m3.fu1_5, m3.fu1_7)
    }
}

DoFu2(){
    switch massNo
    {
        case 1:
            sndFu(2, m1.fu2, m1.fu2_5, m1.fu2_7)
        case 2:
            sndFu(2, m2.fu2, m2.fu2_5, m2.fu2_7)
        case 3:
            sndFu(2, m3.fu2, m3.fu2_5, m3.fu2_7)
    }
}

DoFu3(){
    switch massNo
    {
        case 1:
            sndFu(3, m1.fu3, m1.fu3_5, m1.fu3_7)
        case 2:
            sndFu(3, m2.fu3, m2.fu3_5, m2.fu3_7)
        case 3:
            sndFu(3, m3.fu3, m3.fu3_5, m3.fu3_7)
    }
}

DoPpv(){
    ppv := ""
    switch massNo{
        case 1: ppv := m1.ppv_base
        case 2: ppv := m2.ppv_base
        case 3: ppv := m3.ppv_base
    }
    A_Clipboard := ppv
    ClipWait(0.1)
    Send "^v"
}

DoPpvFus(){
    switch massNo
    {
        case 1:
            snd(m1.ppv_f1)
            snd(m1.ppv_f2)
            snd(m1.ppv_f3)
        case 2:
            snd(m2.ppv_f1)
            snd(m2.ppv_f2)
            snd(m2.ppv_f3)
        case 3:
            snd(m3.ppv_f1)
            snd(m3.ppv_f2)
            snd(m3.ppv_f3)
    }
}

; ── hotkey registrations ──────────────────────────────────────────────────────
; No keys here — every key lives in hotkeys.ini, under [mass.2].

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
    if !AltIntercept(CurMass(), 1, true, false)
        DoFu1()
}
DoAltFu2() {
    if !AltIntercept(CurMass(), 2, true, false)
        DoFu2()
}
DoAltFu3() {
    if !AltIntercept(CurMass(), 3, true, false)
        DoFu3()
}

HK_Bind("mass.2.fu1",    DoFu1)
HK_Bind("mass.2.fu2",    DoFu2)
HK_Bind("mass.2.fu3",    DoFu3)
HK_Bind("mass.2.smFu1",  DoFu1)
HK_Bind("mass.2.smFu2",  DoFu2)
HK_Bind("mass.2.smFu3",  DoFu3)
HK_Bind("mass.2.ppv",    DoPpv)
HK_Bind("mass.2.ppvFus", DoPpvFus)
HK_Bind("mass.2.altFu1", DoAltFu1)
HK_Bind("mass.2.altFu2", DoAltFu2)
HK_Bind("mass.2.altFu3", DoAltFu3)

; The Scimitar keys are the same F13-F15 that models 1 and 3 use, so without this
; one press fired every model's follow-up at once.
StartFuGating(HK_ModelSendIds(modelFileNo))

