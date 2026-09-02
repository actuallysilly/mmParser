#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/coords.ahk"
#Include "../core/utils.ahk"
#Include "../vendor/OCR.ahk"

DetectHiddenWindows true
; The GUI is addressed by MMA_GuiWin() at the moment it is needed, not by a
; MMA_GUI_WIN captured here. MMA has two front ends now and either can be the
; one running; a title resolved at load would also go stale the moment the
; shell preference changed. See MMA_GuiWin in core/paths.ahk.
; MMA_MSG_AUTOPARSE was `:= 0x8010` here. It is in core/messages.ahk now, reached
; through utils.ahk → hotkeys.ahk above, with the other nine.
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
    return {x: LOG_IniInt(SEQ_CFG, "Discord", "HeaderX", 460),
            y: LOG_IniInt(SEQ_CFG, "Discord", "HeaderY", 42),
            w: LOG_IniInt(SEQ_CFG, "Discord", "HeaderW", 500),
            h: LOG_IniInt(SEQ_CFG, "Discord", "HeaderH", 38)}
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
;   • The whole window is a lot of pixels to read for a menu that is always AT the
;     cursor, and this runs between your click and the paste. `box` narrows the
;     capture to a rectangle around the click (see SEQ_MENU_BOX), which is the
;     single biggest saving available here — OCR cost tracks area. Omit it and it
;     reads the window, which is the fallback when the boxed read comes up empty.
;
; Coordinates come back in the WINDOW's client space either way, box or no box:
; OCR.NormalizeCoordinates divides by `scale` and adds the region's x/y back on. So
; nothing here has to know whether it was given a box, and the caller's arithmetic
; is the same for both.
FindCopyTextRow(nearX, nearY, box := 0) {
    res := 0
    opts := box ? {x: box.x, y: box.y, w: box.w, h: box.h, scale: 2, mode: 4}
                : {scale: 2, mode: 4}
    try res := OCR.FromWindow("ahk_exe Discord.exe", opts)
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

; ── how long the menu gets, and how often we look ────────────────────────────
;  This was one flat `Sleep 250` and a single attempt. 250ms is a guess at the
;  slowest frame Discord might need, paid in full on every import even when the
;  menu was up in 60 — and if it was NOT up yet, the one attempt was spent on a
;  blank patch of chat and the whole import failed.
;
;  Polling fixes both ends: it starts looking almost immediately and keeps looking
;  until the deadline, so the common case is fast and the slow case still works.
global SEQ_MENU_FIRST_MS := 60     ; before the first look
global SEQ_MENU_STEP_MS  := 55     ; between looks
global SEQ_MENU_MAX_MS   := 600    ; give up after this, measured from the click

; The box the menu is looked for in, around the click. Discord opens its context
; menu AT the cursor and drops it up instead of down when there is no room below,
; so this is asymmetric-free: same reach each way, wider to the right because the
; menu opens rightwards.
global SEQ_MENU_BOX := {left: 40, right: 340, up: 380, down: 380}

; ── one look for the "Copy Text" row ─────────────────────────────────────────
;  Screen coords in, screen coords out (or 0). Called repeatedly, so everything in
;  it has to be cheap: two reads of a box around the cursor, no whole-window pass.
;
;  Sets CoordMode itself and leaves it set — the caller saves and restores around
;  the whole loop rather than paying for it per attempt.
_SeqFindMenu(mx, my) {
    global COPY_TEXT_IMG, SEQ_MENU_BOX
    b := SEQ_MENU_BOX

    ; Fast path: the original bitmap match, ~10ms, exact when it hits. It stops
    ; hitting the moment Discord restyles or rescales its menus — which is what
    ; happened here: it missed at *20, *50 AND *100 — so it is kept for installs
    ; whose menu still looks like assets\copy_text.png and nothing depends on it.
    ;
    ; The search box was 520x800 and is now 380x760 around the click: ImageSearch
    ; cost is per pixel, and 60px of chat to the left of the cursor cannot contain a
    ; menu that opens to the right of it.
    CoordMode "Pixel", "Screen"
    try {
        if ImageSearch(&fx, &fy, mx - b.left, my - b.up, mx + b.right, my + b.down,
                       "*20 " COPY_TEXT_IMG)
            return {sx: fx + 10, sy: fy + 10}
    }

    ; Robust path: read the menu. Boxed to the same rectangle, which is what makes
    ; it affordable to do more than once — the whole window at scale 2 was ~157ms.
    CoordMode "Pixel", "Client"
    ccx := 0, ccy := 0, ccw := 0, cch := 0
    try WinGetClientPos(&ccx, &ccy, &ccw, &cch, "ahk_exe Discord.exe")
    cx := mx - ccx, cy := my - ccy

    ; Clamped to the client area, and that is not defensive padding: a right-click
    ; near the top of the message list puts `cy - up` well below zero, and a capture
    ; region starting off the bitmap is not a smaller read — it is a throw, inside a
    ; try, which would look exactly like "the menu was not found".
    bx := Max(0, cx - b.left)
    by := Max(0, cy - b.up)
    bw := Min(b.left + b.right, (ccw ? ccw : bx + 1) - bx)
    bh := Min(b.up + b.down,    (cch ? cch : by + 1) - by)
    if (bw < 40 || bh < 40)          ; nothing worth reading (or no client size)
        return 0
    row := FindCopyTextRow(cx, cy, {x: bx, y: by, w: bw, h: bh})
    return row ? {sx: ccx + row.x, sy: ccy + row.y} : 0
}

copyDiscordMessageSeq() {
    global MMA_MSG_AUTOPARSE, COPY_TEXT_IMG
    global SEQ_MENU_FIRST_MS, SEQ_MENU_STEP_MS, SEQ_MENU_MAX_MS
    ; "The Discord import broke again" starts here. If this line is absent the key
    ; never reached the handler (script not running, key unbound, wrong window) —
    ; which has been the cause every time so far.
    LOGD("seq.discord", "Ctrl+click import fired — right-clicking to open the menu")
    t0 := A_TickCount
    A_Clipboard := ""
    Click "Right"

    prevHidden := A_DetectHiddenWindows
    prevPixel  := A_CoordModePixel
    prevMouse  := A_CoordModeMouse
    DetectHiddenWindows false    ; else "ahk_exe Discord.exe" can hit a hidden helper window

    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    hit := 0, tries := 0

    ; The menu is DOM-drawn and needs a frame to paint, so the first look is not
    ; instant — it is just far earlier than the 250ms this used to sleep.
    Sleep SEQ_MENU_FIRST_MS
    Loop {
        tries++
        hit := _SeqFindMenu(mx, my)
        if (hit || A_TickCount - t0 > SEQ_MENU_MAX_MS)
            break
        Sleep SEQ_MENU_STEP_MS
    }

    ; Last resort: read the WHOLE window once. Every attempt above looked only in a
    ; box around the cursor, which is where the menu is — unless the window is
    ; scaled, or Discord has put the menu somewhere this box does not reach, in
    ; which case one expensive read beats a failed import.
    if !hit {
        CoordMode "Pixel", "Client"
        ccx := 0, ccy := 0
        try WinGetClientPos(&ccx, &ccy, , , "ahk_exe Discord.exe")
        row := FindCopyTextRow(mx - ccx, my - ccy)
        if row {
            hit := {sx: ccx + row.x, sy: ccy + row.y}
            LOGW("seq.discord", "the 'Copy Text' row was not in the box around the"
                              . " click — found by reading the whole window instead."
                              . " If this line is common, SEQ_MENU_BOX is too small.")
        }
    }

    CoordMode "Pixel", prevPixel
    DetectHiddenWindows prevHidden

    if !hit {
        CoordMode "Mouse", prevMouse
        Send "{Escape}"          ; don't leave the menu hanging open over the chat
        ; Both routes failed. The bitmap one goes stale whenever Discord restyles
        ; its menus and the OCR one depends on the window being readable — naming
        ; which is which matters, because the fixes are completely different.
        LOGE("seq.discord", "neither the bitmap match nor the OCR read found a"
                          . " 'Copy Text' row in Discord's context menu — nothing"
                          . " imported",
                          "clicked at " mx "," my
                        . "; bitmap needle " COPY_TEXT_IMG
                        . " (goes stale when Discord restyles its menus)")
        ToolTip("Import: no 'Copy Text' in the menu")
        SetTimer(ClearImportTip, -2000)
        return
    }

    LOGI("seq.discord", "clicking 'Copy Text' at " hit.sx "," hit.sy
                      . "   (found after " tries " look(s), " (A_TickCount - t0)
                      . "ms from the right-click)")
    Click hit.sx, hit.sy
    CoordMode "Mouse", prevMouse

    if !ClipWait(1) {
        LOGE("seq.discord", "clicked 'Copy Text' but the clipboard stayed empty for"
                          . " a second — nothing imported",
                          "the click may have landed on the wrong menu row")
        return
    }
    if A_Clipboard = "" {
        LOG_Bail("seq.discord", "the clipboard is empty after the copy — nothing"
                              . " imported")
        return
    }

    ; Tag the paste with the channel's model. mass_gui's ExtractModelName() eats
    ; this line and routes the import by it; a name it does not know falls
    ; through to its import prompt — which is the conflict GUI, and can remember
    ; the name against a model so the next one from this channel is automatic.
    chan  := DiscordChannelName()
    model := chan != "" ? ModelFromChannel(chan) : ""
    if (model != "")
        A_Clipboard := "@model: " model "`n" A_Clipboard

    ; The routing decision, in full. "It imported into the wrong model" and "it
    ; did not recognise the channel" both start here, and the channel name is
    ; OCR'd off the VOICE channel header — so seeing the raw string it read is
    ; most of the answer.
    LOGI("seq.discord", "copied " StrLen(A_Clipboard) " chars"
                      . "  channel='" chan "'"
                      . "  → model='" (model = "" ? "(not recognised)" : model) "'")

    ToolTip(model != "" ? "Import -> " model "   (#" chan ")" : "Import: channel not recognised")
    SetTimer(ClearImportTip, -1600)

    ; The last link in the chain, and the one that fails silently: the text is on
    ; the clipboard, tagged and ready, and if the GUI is not running there is
    ; nothing to receive it. From Discord that looks exactly like the import
    ; having done nothing at all.
    _guiWin := MMA_GuiWin()
    if WinExist(_guiWin) {
        PostMessage MMA_MSG_AUTOPARSE, 0, 0, , _guiWin
        LOGI("seq.discord", "told the MMA window to auto-parse the clipboard")
    } else {
        LOGE("seq.discord", "the copied text is on the clipboard, but the MMA window"
                          . " is not running — nothing will parse it",
                          "looked for window title " _guiWin)
    }
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

; "The Discord import broke AGAIN" has been reported more than once, and the cause
; has never once been this file's logic — it was the script not running, or the
; key not bound. Both are now one line in the log, at the moment it starts.
HK_Summary("sequences")

