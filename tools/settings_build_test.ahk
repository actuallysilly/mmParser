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

#Include "../src/core/paths.ahk"
#Include "../src/core/hotkeys.ahk"
#Include "../src/core/active_model.ahk"
#Include "../src/mass/archive.ahk"
#Include "../src/core/processes.ahk"

Out(s) => FileAppend(s "`n", "*")
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

; TCM_GETITEMCOUNT. Six tabs is the contract this window is built around; five
; means a UseTab call went missing and a whole page's controls landed on its
; neighbour, which looks like a layout bug and is not one.
Ck("six tabs", SendMessage(0x1304, 0, 0, "SysTabControl321", "ahk_id " hwnd), 6)

; Three model names, the wait time, the four NextFu region fields, OCR scale,
; needle length, needle minimum, the default-FU3 box and the hotkey search box.
Ck("every edit field present", Cnt("Edit") >= 13, 1)

; 3 platform + "I pick" + the default hotkey file, then one per model for tab order.
Ck("every dropdown present", Cnt("ComboBox") >= 5 + modelCount, 1)

; The feature registry's checkboxes are generated, so this catches a section that
; silently produced nothing as well as a panel that was never built. Radios and
; checkboxes are both class Button, so this counts them together.
Ck("a button per feature, plus the rest",
   Cnt("Button") >= FEAT_ORDER.Length + 10, 1)

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
