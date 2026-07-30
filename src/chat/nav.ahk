#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  chat/nav.ahk — moving around Infloww: unread, next chat, focus, the click keys.
; ───────────────────────────────────────────────────────────────────────────────
;  These belong to the APP, not to any model. They lived at the bottom of
;  1_mass.ahk for one reason, stated in that file's own comment: it "is the script
;  that is always running". That is an accident of deployment, not a reason — and
;  it made hotkeys.ahk's owner column say "1_mass.ahk" for keys that have nothing
;  to do with masses, which is exactly the question the owner column exists to
;  answer.
;
;  Included by mass/engine.ahk rather than run on its own: the engine is the
;  always-on process now, so this needs no process of its own and no entry in
;  StartupScripts.
;
;  The heavy lifting is elsewhere — Unread/focusAuto/nextChat/focusTop/AfkClick/
;  RecoverLastMsg are in core/utils.ahk, the named coordinates are in
;  core/coords.ahk, and the composer-strip clicks are in sequences/composer.ahk.
;  This file is the bindings plus the three one-liners that had nowhere better.
; ═══════════════════════════════════════════════════════════════════════════════

ClickUnread() {
    clickOn(unreadBtn)
}
ClickHome() {
    clickOn(home)
}
ClickPpv() {
    clickOn(ppvOpenNotif)
}

; Remembers what was typed before Enter sends it, so util.recoverMsg can put it
; back. Chrome only — see hotkeys.ahk's "chrome" context.
CaptureEnter() {
    global _lastTyped
    saved := A_Clipboard
    A_Clipboard := ""
    Send "^a"
    Sleep 30
    Send "^c"
    ClipWait 0.3
    if A_Clipboard != "" {
        _lastTyped := A_Clipboard
        LOGV("nav.capture", "remembered " StrLen(A_Clipboard) " chars before Enter")
    } else {
        ; The Enter still goes through, so the message sends either way — but
        ; util.recoverMsg will hand back the PREVIOUS message, or nothing, and
        ; that only becomes apparent at the moment you need it most.
        LOGW("nav.capture", "could not copy the message before sending it —"
                          . " 'recover last message' will not have this one")
    }
    A_Clipboard := saved
    Send "{Enter}"
}

; ── bindings ──────────────────────────────────────────────────────────────────
; No keys here — every key lives in hotkeys.ini. These lines only say which
; function each id runs.
NavBind() {
    HK_Bind("nav.unread",      Unread)
    HK_Bind("nav.focusAuto",   focusAuto)
    HK_Bind("nav.nextChat",    nextChat)
    HK_Bind("nav.unreadLeft",  Unread)
    HK_Bind("nav.focusTop",    focusTop)
    HK_Bind("nav.clickUnread", ClickUnread)
    HK_Bind("nav.clickHome",   ClickHome)
    HK_Bind("nav.clickPpv",    ClickPpv)

    HK_Bind("chat.captureEnter",    CaptureEnter)
    HK_Bind("util.afkClick",        AfkClick)
    HK_Bind("util.recoverMsg",      RecoverLastMsg)
    HK_Bind("util.clickSecondGrey", ClickSecondGrey)
    HK_Bind("util.debugGrey",       DebugGreySearch)
}
