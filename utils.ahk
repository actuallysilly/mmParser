#Requires AutoHotkey v2.0


SetKeyDelay(-1, -1)

; config
WaitTime     := 400
WaitTimeLong := 1500
modelFileNo  := 0


Afk := false
ClearInterval := 1000*30 ; 60s


; # Win
; ^ CTRL
; ! ALT
; + shift

Snd(arg){
    if (arg = "")
        return
    A_Clipboard := ""
    A_Clipboard := arg
    ClipWait(1)
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

; you can also provide a time in milliseconds
Sendt(arg,time){
    if (arg = "")
        return
    A_Clipboard := arg
    ClipWait(0.1)
    Send("^v")
    Send("{Enter}")
    Sleep(time)
}



sndFu(group, parts*) {
    global waitTime, modelFileNo
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(p)
    if !nonEmpty.Length
        return
    fuSingle := IniRead(A_ScriptDir "\mass_gui.cfg", "Settings", "FuSingle_" modelFileNo "_" group, "0") = "1"
    if !fuSingle {
        for p in nonEmpty
            snd(p)
        return
    }
    combined := ""
    for p in nonEmpty
        combined .= (combined != "" ? "`n" : "") p
    A_Clipboard := ""
    A_Clipboard := combined
    ClipWait(1)
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

Unread() {
    MouseGetPos &cx, &cy
    CoordMode "Mouse", "Screen"
    MouseClickDrag "Left", cx, cy, cx - 300, cy, 5
    MouseMove cx - 50, cy + 60, 0
}



; AFK

CoordMode "Mouse", "Window"
^p::
{
    MouseMove 347, 208, 0
    Click
    Sleep(200)
    MouseMove 231, 352, 0
    Sleep(50)
    Click
}

GoAfk(){
    
    while(afk){
        MouseMove 347, 208, 0
        Click
        Sleep(200)
        MouseMove 231, 352, 0
        Sleep(50)
        Click
        Sleep(50)
        MouseMove 711, 481, 0
        Sleep(clearInterval)
    }
}

::_afk::{

   global afk
   afk := true
   goAfk()
}

::_offafk::{
    global afk
    afk := false
}

SetTimer(CheckAFK, 1000) ; cheque every 1 second

CheckAFK() {
    static afkTriggered := false  ; persistent state (like a private field)

    if (A_TimeIdle > 60000) {      ; 60,000 ms = 1 minute
        if (!afkTriggered) {
            afkTriggered := true
            goAfk()
        }
    } else {
        afkTriggered := false      ; reset when user becomes active again
    }
}

clickOn(coord){
    MouseMove coord[1], coord[2]
    Click
}

focusTextbox(){
    MouseMove 800, 950
    Click
}

focusTop(){
    MouseMove 220,315
    Click
}

_savedChatX := 220
_savedChatY := 315
topChat := [165, 320]

focusAuto(){
    global _savedChatX, _savedChatY
    MouseGetPos &mx, &my
    if (mx < 400) {
        _savedChatX := mx
        _savedChatY := my
        focusTextbox()
    } else {
        clickOn(topChat)
    }
}

nextChat(){
   MouseGetPos &cx, &cy
   MouseMove cx, cy + 100
   MouseClick
}



