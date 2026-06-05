#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "utils.ahk"

massNo := 2
modelFileNo := 1

m1 := {
mass: "did you like my recent animations?",
fu1: "I've had a bit of a creative block recently..",
fu1_5: "Which got me thinking, what's the best way to break through a wall?",
fu1_7: "Pierce it... Pierce it from the back, EUREKA!",

fu2: "The inspiration came to me because Techboy was really horny and couldn't wait for us to get to bed >.<",
fu2_5: "He's an impatient fellow.. Which got me very excited..",
fu2_7: "",

fu3: "The way it dripped out of me after we got done with it was even more insane... It was so messy and sloppy I had to draw it!",
fu3_5: "Would you... help me with some more inspiration?",
fu3_7: "",

ppv_base: "Would you give me backshots like what ive drawn?",
ppv_f1: "Give me the some backshots as well silly! Who knows what beautiful art I might create with the inspiration!",
ppv_f2: "",
ppv_f3: ""
}

m2 := {
mass: "What's your favourite position for bedroom activities?",
fu1: "I've been really enjoying rear entry lately, it has really nice geometry to it when it comes to hitting the perfect angles, and my G spot ^~^",
fu1_5: "",
fu1_7: "",

fu2: "I bet you would love to have me positioned like that, with my buttox staring you in the face... Challenging your cock to ram itself in, right?",
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


F1::{ ; send fu1
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

F2::{ ; send fu2
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

F3::{ ; send fu3
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

