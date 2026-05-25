#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"

massNo := 3

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
mass: "can u help me?",
fu1: "my tits are so lonely... they need someone to suck the soul out of them and make them perky",
fu1_5: "can u do that?",
fu1_7: "",

fu2: "and they also need someone to spit on them while groping them and making me moan",
fu2_5: "but beware once im in the mood im unstoppable... and u could not handle that?",
fu2_7: "",

fu3: "so u think u can handle me and my tits? u think u could handle me naked as well?",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: ""
}


F1::{ ; send fu1
    switch massNo
    {
        case 1:
            snd(m1.fu1)
            snd(m1.fu1_5)
            snd(m1.fu1_7)
        case 2:
            snd(m2.fu1)
            snd(m2.fu1_5)
            snd(m2.fu1_7)
        case 3:
            snd(m3.fu1)
            snd(m3.fu1_5)
            snd(m3.fu1_7)
    }
}

F2::{ ; send fu2
    switch massNo
    {
        case 1:
            snd(m1.fu2)
            snd(m1.fu2_5)
            snd(m1.fu2_7)
        case 2:
            snd(m2.fu2)
            snd(m2.fu2_5)
            snd(m2.fu2_7)
        case 3:
            snd(m3.fu2)
            snd(m3.fu2_5)
            snd(m3.fu2_7)
    }
}

F3::{ ; send fu3
    switch massNo
    {
        case 1:
            snd(m1.fu3)
            snd(m1.fu3_5)
            snd(m1.fu3_7)
        case 2:
            snd(m2.fu3)
            snd(m2.fu3_5)
            snd(m2.fu3_7)
        case 3:
            snd(m3.fu3)
            snd(m3.fu3_5)
            snd(m3.fu3_7)
    }
}

F4::{ ; send ppv1
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

F5::{ ; send ppv2
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

