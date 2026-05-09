#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"


massNo := 1 
; dhbsj i


m1 := {
mass: "are backshots boring?",
fu1: "as much as i love em, sometimes they feel a little played out",
fu1_5: "or u think u'd never get tired of my big booty bouncing? lol",
fu1_7: "",

fu2: "i can already picture ur hands on my hips",
fu2_5: "pulling me back while u give me those hard backshots",
fu2_7: "how would u feel in that moment?",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "hope u got the endurance to keep up with these spread butt cheeks tho�",
ppv_f1: "like be honest.. how long u think u'd last?",
ppv_f2: "",
ppv_f3: ""
}

m2 := {
mass: "can i ask u a weird question?",
fu1: "do u ever think abt grabbing a girls titty during sex?",
fu1_5: "like really gripping it hard?",
fu1_7: "",

fu2: "would u wanna grip mine rn tho?",
fu2_5: "",
fu2_7: "",

fu3: "but only if u tell me how hard u'd squeeze",
fu3_5: "id prob even let you suck on them but...",
fu3_7: "would you truly be the most obedient boy if i let you do it?",

ppv_base: "fuck theyre perky, theyre exposed and theyre asking for you to squeeze and pinch them mercilessly",
ppv_f1: "are you gonna treat me so bad...",
ppv_f2: "i just have to take revenge against ur cock?",
ppv_f3: ""
}

m3 := {
mass: "want some cake?",
fu1: "be honest with me.. youre imagining my bubble butt cheeks rn... right?",
fu1_5: "",
fu1_7: "",

fu2: "theyre sooo shiny and juicy...",
fu2_5: "but would you honestly slap them hard before you lick n clap them?",
fu2_7: "",

fu3: "and if i ordered you to do it completely naked and leaking",
fu3_5: "would i get a YES MISTRESS?",
fu3_7: "",

ppv_base: "im bending over, ass in ur face, and ordering you to put ur tongue in between my naked thighs and ass cheeks...",
ppv_f1: "i expect you to serve as my personal vibrator...",
ppv_f2: "and not fuck up getting me wet, understood?",
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

