#Include "coords.ahk"
#Include "utils.ahk"

DetectHiddenWindows true
MMA_GUI_WIN := A_ScriptDir "\mass_gui.ahk ahk_class AutoHotkey"
MMA_MSG_AUTOPARSE := 0x8010
COPY_TEXT_IMG := A_ScriptDir "\assets\copy_text.png"

openFarmolijerSeq() {
    Run "discord://"
    WinWaitActive "ahk_exe Discord.exe",, 5
    Sleep 400
    clickOn([24, 42]) ;DM icon
    Sleep 100
    clickOn([217, 46]) ;find or start a convo
    Sleep 500
    clickOn([815, 400]) ;Modal
    Send "Farmolijer"
    Sleep 100
    clickOn([724, 1021])

}

HK_Bind("seq.openFarmolijer", openFarmolijerSeq)

copyDiscordMessageSeq() {
    global MMA_GUI_WIN, MMA_MSG_AUTOPARSE, COPY_TEXT_IMG
    A_Clipboard := ""
    Click "Right"
    Sleep 150

    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    CoordMode "Pixel", "Screen"
    ; menu can open above or below the cursor depending on screen space, so search a box centered on the click
    found := ImageSearch(&fx, &fy, mx - 60, my - 400, mx + 460, my + 400, "*20 " COPY_TEXT_IMG)
    CoordMode "Mouse", "Window"
    if !found
        return

    CoordMode "Mouse", "Screen"
    Click fx + 10, fy + 10
    CoordMode "Mouse", "Window"

    ClipWait(1)
    if A_Clipboard = ""
        return
    if WinExist(MMA_GUI_WIN)
        PostMessage MMA_MSG_AUTOPARSE, 0, 0, , MMA_GUI_WIN
}

; Discord-only. The #HotIf directive that used to wrap this did nothing: it only
; applies to literal `::` hotkeys, while Hotkey() takes its criterion from the
; HotIf() *function* — so this was registered globally and fired in every app.
; The context now comes from the registry, which applies it the right way.
HK_Bind("seq.copyDiscordMsg", copyDiscordMessageSeq)

SelectTopPPVSeq() {
    clickOn([1531, 884])
    Sleep 500
    clickOn([865, 325])
    
}

HK_Bind("seq.selectTopPpv", SelectTopPPVSeq)

