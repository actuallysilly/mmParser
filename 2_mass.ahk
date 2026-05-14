#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"


massNo := 3 
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
mass: "is it time i take complete control?",
fu1: "i don't think there's any answer i wanna hear other than `"YES MA`'AM`"",
fu1_5: "and i don't like to be disobeyed when i'm in such a needy mood c`;",
fu1_7: "so will u do exactly as i say?",

fu2: "this body of mine tends to cause throbbing sensations, especially as it gets fully bare~",
fu2_5: "are you gonna satisfy me like no one else can so i can spoil that cock completely?",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: ""
}


F9::{ ; send fu1
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

F10::{ ; send fu2
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

F11::{ ; send fu3
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

F12::{ ; send ppv1
    ppv := ""
    switch massNo{
        case 1: ppv := m1.ppv_base
        case 2: ppv := m2.ppv_base
        case 3: ppv := m3.ppv_base
    }
    A_Clipboard := ppv
    ClipWait(1)
    Send "^v"
}

!F12::{ ; send ppv2
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

