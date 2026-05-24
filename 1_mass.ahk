#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"

massNo := 3

m1 := {
mass: "want me to tell u exactly how i want u to stroke it?",
fu1: "grip it tight at the base n hold",
fu1_5: "now slide up real slow for me",
fu1_7: "",

fu2: "dont speed up yet keep it steady",
fu2_5: "squeeze when u reach the tip",
fu2_7: "",

fu3: "pause n throb in ur hand",
fu3_5: "ready for what i say next?",
fu3_7: "",

ppv_base: "",
ppv_f1: "now, watch me bouncing my tits for you and FOLLOW THE RHYTHM",
ppv_f2: "this is where we get serious about your ruination",
ppv_f3: ""
}

m2 := {
mass: "should i undress? 🌙",
fu1: "i dress to impress, but i undress to completely RUIN...",
fu1_5: "are you sure u could handle me after dark?",
fu1_7: "",

fu2: "now imagine me topless and lustful.. like a midnight sex demon",
fu2_5: "would u fall on ur knees the second the bra was off?",
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
mass: "r u opposed to naked girls?",
fu1: "and how do you feel about me letting go of my limits for you... just tonight?",
fu1_5: "i wanna make you sin with me...",
fu1_7: "",

fu2: "just imagine the sinful taste of my titties after dark.. youd get beyond obsessed",
fu2_5: "and youd get them so wet riiight?",
fu2_7: "",

fu3: "",
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

