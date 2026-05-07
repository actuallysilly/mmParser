#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"

massNo := 2

m1 := {
mass: "will you bow before the goth queen?",
fu1: "good boy... youre so obedient, mommy enjoys that...",
fu1_5: "are you feeling needier for mommies perky titties or pale bare cheeks?",
fu1_7: "",

fu2: "",
fu2_5: "mommy wants you to fall down to you knees and look up at her holy titties",
fu2_7: "and imagine just how soft they would be as goth-themed pillows...",

fu3: "",
fu3_5: "mommy wants you to fall down to you knees and look up under her goth-skirt",
fu3_7: "theres so much in there that your lips viscerally need to touch.. should i let you?",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: ""
}

m2 := {
mass: "whats your fav color?",
fu1: "mine are pink and black... but also... whats wet, black on the outside and pink on the inside?",
fu1_5: "",
fu1_7: "",

fu2: "i was gonna say my lipstick but i guess goth girl pussy also works...",
fu2_5: "speaking of which... how badly do you need to taste whats under my skirt?",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "testtest1",
ppv_f1: "testtest2",
ppv_f2: "22222",
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
    switch massNo{
        case 1: SendText(m1.ppv_base)
        case 2: SendText(m2.ppv_base)
        case 3: SendText(m3.ppv_base) 
    }
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

