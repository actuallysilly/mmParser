#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/coords.ahk"
#Include "../core/utils.ahk"
#Include "../vendor/OCR.ahk"

DetectHiddenWindows true
MMA_GUI_WIN := MMA_SRC_GUI " ahk_class AutoHotkey"
MMA_MSG_AUTOPARSE := 0x8010
COPY_TEXT_IMG := MMA_ASSETS "\copy_text.png"
SEQ_CFG := MMA_CFG

; Seed [Discord] so the band is visible and editable without reading this file.
; Measured against a maximized 1920x1032 client: the channel name sat at
; x=479 y=54, 121x13.
if (IniRead(SEQ_CFG, "Discord", "HeaderW", "") = "") {
    for k, v in Map("HeaderX", 460, "HeaderY", 42, "HeaderW", 500, "HeaderH", 38)
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
;  name Discord has open: "#-aliw-staff-chat" -> "aliw" -> the Aliw model.
;
;  Two readers, title first and OCR as backup, because neither covers everything:
;  the title is exact and instant but only names a TEXT channel, while the header
;  is on screen whatever the title says.

; A channel slug out of a string: at least one hyphen joining alphanumerics.
; Requiring the hyphen is what keeps prose ("Set a channel topic", a banner, a
; server name) from being read as a channel.
DiscordSlug(txt) {
    if RegExMatch(txt, "([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)", &m)
        return StrLower(m[1])
    return ""
}

; Discord titles a text channel "#<emoji>-aliw-staff-chat | ILTC - Discord".
;
; The leading "#" is the whole test: it marks a TEXT channel. A voice channel or
; the settings page titles itself without one ("(speaker) (game) | N Training -
; Discord"), and those have to fall through to the OCR read rather than have
; their SERVER name matched as if it were a channel.
DiscordChannelFromTitle() {
    t := ""
    try t := WinGetTitle("ahk_exe Discord.exe")
    if !RegExMatch(t, "^#(.+?)\s*\|", &m)
        return ""
    return DiscordSlug(m[1])
}

; Read the channel out of the header bar on screen. The band is client-relative
; and lives in mass_gui.cfg [Discord] because its X depends on how wide your
; channel sidebar is; discord_header_test.ahk tunes it.
;
; Deliberately starts to the RIGHT of the sidebar: the channel LIST is full of
; other channel names, and OCR that wandered into it would report the wrong one
; with full confidence.
DiscordHeaderBand() {
    global SEQ_CFG
    return {x: Integer(IniRead(SEQ_CFG, "Discord", "HeaderX", "460")),
            y: Integer(IniRead(SEQ_CFG, "Discord", "HeaderY", "42")),
            w: Integer(IniRead(SEQ_CFG, "Discord", "HeaderW", "500")),
            h: Integer(IniRead(SEQ_CFG, "Discord", "HeaderH", "38"))}
}

DiscordChannelFromHeader() {
    band := DiscordHeaderBand()
    txt  := ""
    try {
        ; mode 4 = PrintWindow with PW_RENDERFULLCONTENT: the only capture mode
        ; that returns anything but black for a hardware-accelerated Electron
        ; window, and it reads Discord even when another window covers it.
        res := OCR.FromWindow("ahk_exe Discord.exe",
                              {x: band.x, y: band.y, w: band.w, h: band.h,
                               scale: 3, grayscale: 1, mode: 4})
        txt := Trim(RegExReplace(res.Text, "\s+", " "))
    }
    ; Discord draws "# <emoji>-aliw-staff-chat" and OCR turns the emoji into
    ; junk, so match the slug SHAPE rather than trusting the first characters.
    return DiscordSlug(txt)
}

; The open channel's slug, e.g. "aliw-staff-chat"; "" if it cannot be read.
DiscordChannelName() {
    prevHidden := A_DetectHiddenWindows
    prevPixel  := A_CoordModePixel
    ; This script runs with DetectHiddenWindows ON (it needs it to PostMessage the
    ; MMA GUI). Left on, "ahk_exe Discord.exe" can resolve to one of Discord's
    ; hidden helper windows — blank title, nothing to capture.
    DetectHiddenWindows false
    ; Client coords, so a maximized window's invisible border (its rect starts at
    ; -8,-8) does not shift the band out from under the header.
    CoordMode "Pixel", "Client"

    chan := DiscordChannelFromTitle()
    if (chan = "")
        chan := DiscordChannelFromHeader()

    CoordMode "Pixel", prevPixel
    DetectHiddenWindows prevHidden
    return chan
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

; Locate the context menu's "Copy Text" row by READING the menu, in Discord
; client coordinates; 0 if it is not on screen.
;
; Discord renders its context menu inside its own window — there is no popup
; window of its own — so PrintWindow captures it along with everything else.
;
; Two traps this has to avoid:
;   • The same menu carries "Copy Message Link". Matching a lone "Copy" clicks
;     that about half the time, depending on which one OCR reports first. So a
;     "Text" word is required on the same row, immediately to its right.
;   • A message in the channel can itself contain the words "copy text". Ties
;     are broken by distance to the click, and the menu opens AT the click.
FindCopyTextRow(nearX, nearY) {
    res := 0
    try res := OCR.FromWindow("ahk_exe Discord.exe", {scale: 2, mode: 4})
    if !res
        return 0
    best := 0, bestDist := 0
    for w in res.Words {
        if (StrLower(w.Text) != "copy")
            continue
        a := w.BoundingRect
        for w2 in res.Words {
            if (StrLower(w2.Text) != "text")
                continue
            b := w2.BoundingRect
            if !(Abs(b.y - a.y) <= a.h && b.x > a.x && b.x - (a.x + a.w) < 40)
                continue
            row  := {x: (a.x + b.x + b.w) // 2, y: a.y + a.h // 2}
            dist := Abs(row.x - nearX) + Abs(row.y - nearY)
            if (!best || dist < bestDist)
                best := row, bestDist := dist
        }
    }
    return best
}

copyDiscordMessageSeq() {
    global MMA_GUI_WIN, MMA_MSG_AUTOPARSE, COPY_TEXT_IMG
    A_Clipboard := ""
    Click "Right"
    Sleep 250                    ; the menu is DOM-drawn; it needs a frame to paint

    prevHidden := A_DetectHiddenWindows
    prevPixel  := A_CoordModePixel
    prevMouse  := A_CoordModeMouse
    DetectHiddenWindows false    ; else "ahk_exe Discord.exe" can hit a hidden helper window

    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    hit := 0

    ; Fast path: the original bitmap match. ~10ms, exact when it hits, and it
    ; stops hitting the moment Discord restyles or rescales its menus — which is
    ; what happened here: it missed at *20, *50 AND *100, so this is kept only
    ; for installs whose menu still looks like assets\copy_text.png.
    CoordMode "Pixel", "Screen"
    try {
        ; the menu opens above or below the cursor depending on room, so search a
        ; box centred on the click
        if ImageSearch(&fx, &fy, mx - 60, my - 400, mx + 460, my + 400, "*20 " COPY_TEXT_IMG)
            hit := {sx: fx + 10, sy: fy + 10}
    }

    ; Robust path: read the menu (~157ms for the whole window).
    if !hit {
        CoordMode "Pixel", "Client"
        ccx := 0, ccy := 0
        try WinGetClientPos(&ccx, &ccy, , , "ahk_exe Discord.exe")
        row := FindCopyTextRow(mx - ccx, my - ccy)
        if row
            hit := {sx: ccx + row.x, sy: ccy + row.y}
    }

    CoordMode "Pixel", prevPixel
    DetectHiddenWindows prevHidden

    if !hit {
        CoordMode "Mouse", prevMouse
        Send "{Escape}"          ; don't leave the menu hanging open over the chat
        ToolTip("Import: no 'Copy Text' in the menu")
        SetTimer(ClearImportTip, -2000)
        return
    }

    Click hit.sx, hit.sy
    CoordMode "Mouse", prevMouse

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

