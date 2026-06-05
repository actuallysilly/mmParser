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

F6::{ ; send fu1
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

F7::{ ; send fu2
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

!F7::{ ; send fu3
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

F8::{ ; send ppv1
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

!F8::{ ; send ppv2
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
