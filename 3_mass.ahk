#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"

massNo := 1
modelFileNo := 3

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
ppv_f3: ""
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
ppv_f3: ""
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
ppv_f3: ""
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
; No keys here — every key lives in hotkeys.ini, under [mass.3].

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

HK_Bind("mass.3.fu1",    DoFu1)
HK_Bind("mass.3.fu2",    DoFu2)
HK_Bind("mass.3.fu3",    DoFu3)
HK_Bind("mass.3.smFu1",  DoFu1)
HK_Bind("mass.3.smFu2",  DoFu2)
HK_Bind("mass.3.smFu3",  DoFu3)
HK_Bind("mass.3.ppv",    DoPpv)
HK_Bind("mass.3.ppvFus", DoPpvFus)
HK_Bind("mass.3.altFu1", DoAltFu1)
HK_Bind("mass.3.altFu2", DoAltFu2)
HK_Bind("mass.3.altFu3", DoAltFu3)

; The Scimitar keys are the same F13-F15 that models 1 and 2 use, so without this
; one press fired every model's follow-up at once.
StartFuGating(HK_ModelSendIds(modelFileNo))
