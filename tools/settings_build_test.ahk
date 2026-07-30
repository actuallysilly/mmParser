#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  settings_build_test.ahk — does the Settings window actually BUILD?
; ───────────────────────────────────────────────────────────────────────────────
;  Parsing clean and building are different questions, and the gap between them is
;  where a GUI fails: a control placed off its tab, a class constructed with the
;  wrong arity, a Map indexed with a key that isn't there. None of that is a syntax
;  error, and all of it throws the first time the window is opened — in front of
;  you, mid-shift.
;
;  So this builds the real thing: it includes settings_window.ahk itself and stubs
;  only what main_window.ahk owns (its globals, and the handful of functions Save
;  calls). The layout code under test is the shipping code, not a copy.
;
;  Prints to stdout. Exit 0 = the window built and holds what it should.
; ═══════════════════════════════════════════════════════════════════════════════

; Warnings to stdout, not to a dialog. A #Warn dialog is MODAL and arrives before
; the first line of this file runs, so from the outside it is indistinguishable
; from a hang: no output, no exit, nothing on stderr — a warning is not an error.
; That is exactly how the MASS_DOC declaration bug presented.
#Warn All, StdOut

; A third argument previews a theme — `settings_build_test.ahk hold 6 dark`.
;
; Through the environment, NOT by writing Theme into mass_gui.cfg: a tool that
; leaves your settings changed is a tool that has broken something, and this one
; is run casually. Set before the first THEME_ call, which is why it is up here
; with the includes rather than down with the rest of the argument handling.
if (A_Args.Length > 2)
    EnvSet("MMA_THEME", A_Args[3])

#Include "../src/core/paths.ahk"
#Include "../src/core/hotkeys.ahk"
#Include "../src/core/active_model.ahk"
#Include "../src/mass/archive.ahk"
#Include "../src/core/processes.ahk"

; `try`, because "*" is stdout and there ISN'T one when this is launched without a
; redirect — FileAppend then throws "the handle is invalid", which kills the run at
; whatever line it reached and looks exactly like the thing under test failing.
Out(s) {
    try FileAppend(s "`n", "*")
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    if (e.HasProp("Extra") && e.Extra != "")
        Out("   extra: " e.Extra)
    ExitApp(1)
}

pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── the stubs main_window.ahk would otherwise provide ─────────────────────────
; Values, not behaviour. Nothing here is exercised by BUILDING the window; the
; save path is the part that calls back into the main window, and this test does
; not save. They exist so the file loads.
global SCRIPT_DIR   := MMA_ROOT
global ACC_DIR      := MMA_ACC_DIR
global CFG_FILE     := MMA_CFG
global modelCount   := Integer(IniRead(CFG_FILE, "Settings", "ModelCount", "2"))
global model1Name   := IniRead(CFG_FILE, "Settings", "Model1", "Model 1")
global model2Name   := IniRead(CFG_FILE, "Settings", "Model2", "Model 2")
global model3Name   := IniRead(CFG_FILE, "Settings", "Model3", "Model 3")
global waitTime     := 350
global defaultHotkeyFile := IniRead(CFG_FILE, "Settings", "DefaultHotkeyFile", "TEMP.ahk")
global mouseControl := 1
global openTabFu2 := 0, openTabFu3 := 1, openTabPpv := 0
global walletCheckFu3 := 0, fastParseAutosave := 1, promptAltCtrl := 1
global autoRestart := 1, _doubleMM := false
global startupScripts := []
global hiddenScripts  := Map()
; archive.ahk reaches for these three when it loads a mass back into the editor.
; Never called here — declared only so #Warn does not stop the run with a modal
; "appears to never be assigned a value" dialog, which produces no output at all.
global edPaste := 0, tabs := 0, edCtrls := Map()

ModelNameForSlot(slot) {
    global model1Name, model2Name, model3Name
    return [model1Name, model2Name, model3Name][slot]
}
_EncodeMultiline(s) => StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "``n")
_DecodeMultiline(s) => StrReplace(s, "``n", "`n")
UpdateModelButtons() {
}
; Save calls this when the theme changes. Real one lives in main_window.ahk, since
; it repaints that window; theme.ahk itself is included for real, so the COLOURS
; under test are the shipping ones.
ApplyWindowTheme() {
}
WipeTemp(*) {
}
CheckUpdate(silent := false, *) {
}
_BroadcastWallet(val) {
}
ToggleDoubleMM() {
}

; The owner window OpenSettings hangs itself off. Never shown.
global g := Gui("+Resize", "stub main")

#Include "../src/ui/settings_window.ahk"

; ── build it ──────────────────────────────────────────────────────────────────
OpenSettings()

hwnd := WinExist("MMA Settings")
Ck("window exists", hwnd ? 1 : 0, 1)
if !hwnd {
    Out("0 passed, 1 failed — nothing else can be checked")
    ExitApp(1)
}

WinGetPos(, , &w, &h, "ahk_id " hwnd)
Out("built: " w "x" h)
Ck("width is the declared one",  w >= SW_W, 1)
Ck("height is the declared one", h >= SW_H, 1)

; ── what has to be on it ──────────────────────────────────────────────────────
; Counted by window class rather than by name, because the point is that every
; tab's controls got created. A loop that threw halfway, or a panel that was never
; constructed, shows up here as a count that is too low — and the whole reason for
; this test is that neither of those is a syntax error.
;
; Read off the live window with WinGetControls rather than from a Gui object: the
; Gui is a local inside OpenSettings and deliberately not exported, and the window
; is what the user actually gets.
; Note the class names below have lost their "32": WinGetControls returns ClassNN
; ("SysTabControl321" = class SysTabControl32 + instance 1), and stripping the
; trailing digits takes the 32 with it. Matching on "SysTabControl32" therefore
; matches nothing at all — which reads as "the tab control is missing" rather than
; "the test is wrong", so it is written down here.
kinds := Map()
for ctl in WinGetControls("ahk_id " hwnd) {
    cls := RegExReplace(ctl, "\d+$", "")
    kinds[cls] := kinds.Has(cls) ? kinds[cls] + 1 : 1
}
Cnt(cls) => kinds.Has(cls) ? kinds[cls] : 0
for cls, n in kinds
    Out("  " cls " x" n)

Ck("one tab control", Cnt("SysTabControl"), 1)
; Two lists: the hotkey editor's, and the Debug tab's self-test results.
Ck("both list views",  Cnt("SysListView"),  2)

; TCM_GETITEMCOUNT. Seven tabs is the contract this window is built around; six
; means a UseTab call went missing and a whole page's controls landed on its
; neighbour, which looks like a layout bug and is not one.
;
; Was six until the GUI tab went in between Hotkeys and Debug — and inserting
; rather than appending renumbered Debug from 6 to 7, which is exactly the kind of
; edit this assertion exists to catch.
Ck("seven tabs", SendMessage(0x1304, 0, 0, "SysTabControl321", "ahk_id " hwnd), 7)

; Three model names, the wait time, the four NextFu region fields, OCR scale,
; needle length, needle minimum, the default-FU3 box and the hotkey search box —
; plus the GUI tab's picker width and lift.
Ck("every edit field present", Cnt("Edit") >= 15, 1)

; 3 platform + "I pick" + the default hotkey file, then one per model for tab order.
Ck("every dropdown present", Cnt("ComboBox") >= 5 + modelCount, 1)

; The feature registry's checkboxes are generated, so this catches a section that
; silently produced nothing as well as a panel that was never built. Radios and
; checkboxes are both class Button, so this counts them together.
Ck("a button per feature, plus the rest",
   Cnt("Button") >= FEAT_ORDER.Length + 10, 1)

; ── the theme radios are ONE group ────────────────────────────────────────────
; Counting controls cannot see this, and it shipped: Windows groups radios by
; creation order, a group ends at the first control that is not a radio, and the
; GUI tab added each radio followed by its description Text. Every radio was
; therefore a group of one, a group of one never unchecks anything, all three
; themes could be lit at once, and Save wrote whichever it found first.
; It has to CLICK one. Counting what is checked after building proves nothing —
; the window opens with exactly one lit either way, because only the stored theme
; gets the Checked option. The grouping only shows itself when a second one is
; pressed, which is why this got as far as a screenshot from the user.
;
; BM_CLICK rather than a real click: these controls are on a tab page that is not
; the visible one, and a message does not care.
; Mode 3 = EXACT. The default matches a control whose text merely CONTAINS the
; string, and every radio here sits next to a description mentioning its own name
; — "Dark" matches the label AND "Dark windows and a dark picker…". Looking up the
; wrong control made this assertion report a failure against correct code, which
; is worse than not having it.
SetTitleMatchMode(3)

_ThemeLit() {
    global hwnd
    n := 0
    for _lbl in ["Pink", "Dark", "Classic"]
        try n += ControlGetChecked(_lbl, "ahk_id " hwnd) ? 1 : 0
    return n
}
Ck("one theme radio lit on open", _ThemeLit(), 1)
; Onto the GUI tab first. A Tab3 hides the pages you are not looking at, and a
; hidden auto-radio does not do the sibling-unchecking a visible one does — so
; clicking one on a hidden page reports two lit whether the grouping is right or
; not, which is a test that fails on correct code.
try SW_TAB.Value := 6
try {
    ; Control AND WinTitle. SendMessage's 4th parameter is the control, and giving
    ; it without a window leaves the target ambiguous — the same sharp edge as
    ; PostMessage's 4th parameter, which throws "Target window not found" when it
    ; is fed something it does not like.
    SendMessage(0x00F5, 0, 0, "Dark", "ahk_id " hwnd)                   ; BM_CLICK
    Ck("clicking a second theme unchecks the first", _ThemeLit(), 1)
    Ck("...and the clicked one is the one lit",
       ControlGetChecked("Dark", "ahk_id " hwnd) ? 1 : 0, 1)
} catch as e
    Ck("theme radios are clickable", "threw: " e.Message, "no throw")

Out("")
Out(pass " passed, " fail " failed")

; `settings_build_test.ahk hold` leaves the window up instead of exiting, so the
; layout can be looked at — colours, spacing, a label running off its column —
; none of which a control census can see. Same idea as altgui_test.ahk's `show`.
if (A_Args.Length && StrLower(A_Args[1]) = "hold") {
    ; Optional second arg: open on tab N. Ctrl+Tab rather than TCM_SETCURSEL,
    ; because setting the selection with a message does NOT make AHK swap the
    ; page — Tab3 does that off the control's notification, so a message-only
    ; switch lights the tab you asked for while still showing tab 1's controls.
    if (A_Args.Length > 1) {
        ; SW_TAB.Value, not Ctrl+Tab and not TCM_SETCURSEL. Ctrl+Tab needs the
        ; focus to already be inside the tab control and silently does nothing
        ; otherwise; the message lights the tab without swapping the page.
        ;
        ; Reported rather than swallowed: a silent `try` here is why two rounds of
        ; screenshots came back showing tab 1 while claiming to show tab 6.
        try {
            SW_TAB.Value := Integer(A_Args[2])
            Out("opened on tab " SW_TAB.Value)
        } catch as e
            Out("could not select tab " A_Args[2] ": " e.Message)
    }
    Out("holding the window open — close it, or it goes on its own in 60s")
    SetTimer(() => ExitApp(fail ? 1 : 0), -60000)
    Persistent
    return
}

ExitApp(fail ? 1 : 0)
