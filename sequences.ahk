#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "coords.ahk"
#Include "utils.ahk"
#Include "lib/OCR.ahk"

DetectHiddenWindows true
MMA_GUI_WIN := A_ScriptDir "\mass_gui.ahk ahk_class AutoHotkey"
MMA_MSG_AUTOPARSE := 0x8010
COPY_TEXT_IMG := A_ScriptDir "\assets\copy_text.png"
SEQ_CFG := A_ScriptDir "\mass_gui.cfg"

; Seed [Discord] so the band is visible and editable without reading this file.
if (IniRead(SEQ_CFG, "Discord", "HeaderW", "") = "") {
    for k, v in Map("HeaderX", 340, "HeaderY", 14, "HeaderW", 620, "HeaderH", 50)
        try IniWrite(v, SEQ_CFG, "Discord", k)
}

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

; ── Discord channel header ────────────────────────────────────────────────────
;  The Ctrl+click import routes a mass to the right model by reading the channel
;  name out of Discord's header: "#-aliw-staff-chat" -> "aliw" -> the Aliw model.
;
;  OCR, not the window title. Discord's title reports the VOICE channel you are
;  connected to ("(speaker) | N Training - Discord"), never the text channel you
;  are reading, so the title is useless for this.
;
;  The band is client-relative and lives in mass_gui.cfg [Discord] because its X
;  depends on how wide your channel sidebar is. discord_header_test.ahk shows
;  what the current band reads, for tuning.

DiscordHeaderBand() {
    global SEQ_CFG
    return {x: Integer(IniRead(SEQ_CFG, "Discord", "HeaderX", "340")),
            y: Integer(IniRead(SEQ_CFG, "Discord", "HeaderY", "14")),
            w: Integer(IniRead(SEQ_CFG, "Discord", "HeaderW", "620")),
            h: Integer(IniRead(SEQ_CFG, "Discord", "HeaderH", "50"))}
}

; The open channel's slug, e.g. "aliw-staff-chat"; "" if it cannot be read.
;
; Deliberately starts to the RIGHT of the sidebar: the channel LIST is full of
; other channel names, and OCR that wandered into it would happily report the
; wrong one with full confidence.
DiscordChannelName() {
    band := DiscordHeaderBand()
    prev := A_CoordModePixel
    ; Client coords, so a maximized window's invisible border (its rect starts at
    ; -8,-8) does not shift the band out from under the header.
    CoordMode "Pixel", "Client"
    txt := ""
    try {
        ; mode 4 = PrintWindow with PW_RENDERFULLCONTENT: the only capture mode
        ; that returns anything but black for a hardware-accelerated Electron
        ; window, and it reads Discord even when another window covers it.
        res := OCR.FromWindow("ahk_exe Discord.exe",
                              {x: band.x, y: band.y, w: band.w, h: band.h,
                               scale: 3, grayscale: 1, mode: 4})
        txt := Trim(RegExReplace(res.Text, "\s+", " "))
    }
    CoordMode "Pixel", prev
    ; Discord draws "# <emoji>-aliw-staff-chat" and OCR turns the emoji into
    ; junk, so match the channel-slug SHAPE rather than trusting the first
    ; characters. A slug needs at least one hyphen, which is what keeps prose in
    ; the header (banners, "Set a channel topic") from matching.
    if RegExMatch(txt, "([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)", &m)
        return StrLower(m[1])
    return ""
}

; Every model name MMA already knows: the three slots plus the aliases the import
; prompt has learned. Read from the cfg rather than hard-coded so renaming a model
; in Settings does not quietly break the routing.
KnownModelNamesFromCfg() {
    global SEQ_CFG
    names := []
    for key in ["Model1", "Model2", "Model3"] {
        n := Trim(IniRead(SEQ_CFG, "Settings", key, ""))
        if (n != "")
            names.Push(n)
    }
    sect := ""
    try sect := IniRead(SEQ_CFG, "ModelAliases")
    for line in StrSplit(sect, "`n") {
        p := InStr(line, "=")
        if p
            names.Push(Trim(SubStr(line, 1, p - 1)))
    }
    return names
}

; "aliw-staff-chat" -> "aliw".
;
; Not simply "the first segment": Discord puts an emoji immediately before the
; name and OCR renders it as a stray character or two, so the slug can arrive as
; "q-aliw-staff-chat". So a segment that matches a model MMA already knows wins
; outright, and only if none does do we fall back to the first segment long
; enough not to be OCR debris.
ModelFromChannel(chan) {
    segs := StrSplit(chan, "-")
    for known in KnownModelNamesFromCfg()
        for s in segs
            if (s != "" && StrLower(s) = StrLower(known))
                return s
    for s in segs
        if (StrLen(s) >= 3)
            return s
    return segs.Length ? segs[1] : ""
}

ClearImportTip() {
    ToolTip()
}

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

    ; Tag the paste with the channel's model. mass_gui's ExtractModelName() eats
    ; this line and routes the import by it; a name it does not know falls
    ; through to its import prompt — which is the conflict GUI, and can remember
    ; the name against a model so the next one from this channel is automatic.
    chan  := DiscordChannelName()
    model := chan != "" ? ModelFromChannel(chan) : ""
    if (model != "")
        A_Clipboard := "@model: " model "`n" A_Clipboard

    ToolTip(model != "" ? "Import -> " model "   (#" chan ")" : "Import: channel not recognised")
    SetTimer(ClearImportTip, -1600)

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

