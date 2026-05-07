#Requires AutoHotkey v2.0


; config
waitTime := 300
waitTimeLong := 1500


afk := false
clearInterval := 1000*30 ; 60s


; # Win
; ^ CTRL
; ! ALT
; + shift


snd(arg){
    SendText(arg)
    Send("{Enter}")
    Sleep(waitTime)
}

; you can also provide a time in milliseconds 
sendt(arg,time){
    SendText(arg)
    Send("{Enter}")
    Sleep(time)
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

goAfk(){
    
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

SetTimer(CheckAFK, 1000) ; check every 1 second

checkAFK() {
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
