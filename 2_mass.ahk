#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"


massNo := 3 
; dhbsj i


m1 := {
mass: "bark if youre rly obedient?",
fu1: "good boy, thats what mommy wants... someone i can fully control and edge for hours...",
fu1_5: "can you even imagine getting JOI from the cosplay queen :)?",
fu1_7: "",

fu2: "now, mommy wants you to get that dick out and tell her...",
fu2_5: "do you want to be smothered by my ass or tits?",
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
mass: "r u needy for titties?",
fu1: "mommy knows you are.. and deep down.. youre needier than you can even imagine right?",
fu1_5: "how about you stop resisting so we can make tonight the day you saw them nakey",
fu1_7: "",

fu2: "imagine how pale they are... almost shiny, with 2 red little dots to draw of all ur attention",
fu2_5: "you really wanna suck on them right ?? hehe",
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
mass: "wanna swordfigth? ",
fu1: "but my sword is so fucking massive, can your sword really handle this light saber?",
fu1_5: "and in case u did win... would u put it in between my tits?",
fu1_7: "",

fu2: "just imagine how perky they and needy they are... ",
fu2_5: "would you ever recover from tittyfcking them...?",
fu2_7: " id give you 45 secs max, honestly",

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
    switch massNo{
        case 1: SendText(m1.ppv_base)
        case 2: SendText(m2.ppv_base)
        case 3: SendText(m3.ppv_base) 
    }
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

