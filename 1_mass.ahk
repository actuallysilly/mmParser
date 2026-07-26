#Requires AutoHotkey v2.0
#SingleInstance Force
; Model 1. The three mN blocks below are this file's only real content — the
; follow-up / alt / branch / PPV behaviour is shared, and lives in
; mass_runtime.ahk. Model 1 additionally owns the navigation, chat and utility
; keys (it is the script that is always running), which is the only reason this
; file has any code after the data at all.
#Include "mass_runtime.ahk"
#Include "sequences.ahk"
#Include "features.ahk"

massNo := 1
modelFileNo := 1

m1 := {
mass: "Are my buttox cute?",
fu1: "I reckon that I would be quite photogenic `"arse up face down`", what do you think?",
fu1_5: "",
fu1_7: "",

fu2: "And if I were to find myself in that kind of predicament would you `"slap it before you clap it`"?",
fu2_5: "Would you make my naked arsecheeks bright red 🥺?",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "Imagine having me in doggy just like this, with my naked arse cheeks in a close up, wiggling up and down your nose so you can give me a little kiss before you slap and clap me mercilessly ❤️",
ppv_f1: "Would that make you into a British patriot?",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

m2 := {
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
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
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
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

; ── Model 1 also owns navigation, chat and utility ────────────────────────────
; These keys belong to the app rather than to a model, and 1_mass.ahk is the
; script that is always running, so this is where they are bound. hotkeys.ahk
; lists them with owner "1_mass.ahk" for the conflict report.

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
    if A_Clipboard != ""
        _lastTyped := A_Clipboard
    A_Clipboard := saved
    Send "{Enter}"
}

; ── hotkey registrations ──────────────────────────────────────────────────────
; No keys here — every key lives in hotkeys.ini. These lines only say which
; function each feature runs.

; Follow-ups, alts, branches, PPV and the __mm hotstring, for this file's
; [mass.1] section — all of it lives in mass_runtime.ahk.
MassInit(1)

; navigation
HK_Bind("nav.unread",      Unread)
HK_Bind("nav.focusAuto",   focusAuto)
HK_Bind("nav.nextChat",    nextChat)
HK_Bind("nav.unreadLeft",  Unread)
HK_Bind("nav.focusTop",    focusTop)
HK_Bind("nav.clickUnread", ClickUnread)
HK_Bind("nav.clickHome",   ClickHome)
HK_Bind("nav.clickPpv",    ClickPpv)

; chat + utilities
HK_Bind("chat.captureEnter",    CaptureEnter)
HK_Bind("util.afkClick",        AfkClick)
HK_Bind("util.recoverMsg",      RecoverLastMsg)
HK_Bind("util.clickSecondGrey", ClickSecondGrey)
HK_Bind("util.debugGrey",       DebugGreySearch)
