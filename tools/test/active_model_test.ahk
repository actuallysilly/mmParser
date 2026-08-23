#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  active_model_test.ahk — which model the shared keys resolve to.
; ───────────────────────────────────────────────────────────────────────────────
;  Covers manual mode, the ini-reading that feeds it, and the feature gate that
;  decides whether a mass.active.* key may register at all.
;
;  It writes to the REAL mass_gui.cfg and puts it back at the end, because the
;  thing under test is exactly the ini round trip — a fake path would test the
;  wrong function. Run it when nothing is mid-edit in Settings.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../../src/core/active_model.ahk"
#Include "../../src/core/modes.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError(Err)
Err(e, mode) {
    Out("ERROR: " e.Message " | " (e.HasProp("Extra") ? e.Extra : "")
      . " @ " e.File ":" e.Line)
    ExitApp(1)
}
pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else {
        fail++
        Out("FAIL " name ": got <" got "> want <" want ">")
    }
}

; ── what this test is about to overwrite in the LIVE config ──────────────────
; Both of these are real user settings and this file rewrites both: ModelMatch to
; force manual resolution, CurrentModel to prove garbage and absence both fall
; back to 1. Snapshot them now and put them back at the end.
;
; The "restore" at the bottom used to hardcode ModelMatch = "manual", which is not
; a restore at all — it is a third write. Running the tests therefore left MMA in
; "I pick" mode no matter what the user had chosen, and manual mode always answers
; CurrentModel. That is the whole of "auto-detection is broken, it just sends
; model 1's mass": the detector was fine, the tests had switched it off.
_savedMatch   := IniRead(MMA_CFG, "Settings", "ModelMatch", "name")
_savedCurrent := IniRead(MMA_CFG, "Settings", "CurrentModel", "1")

; ── manual mode resolves without reading a single pixel ──────────────────────
IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
Loop MASS_MODELS {
    n := A_Index
    SetManualModel(n)
    st := ActiveModelStatus()
    Ck("manual m" n " .no",    st.no,    n)
    Ck("manual m" n " .state", st.state, "ok")
    Ck("manual m" n " ActiveModelNo", ActiveModelNo(), n)
}

; out-of-range is refused, and the stored value is left alone
SetManualModel(2)
Ck("SetManualModel(0) refused",  SetManualModel(0), 0)
Ck("SetManualModel(99) refused", SetManualModel(99), 0)
Ck("still model 2", ManualModelNo(), 2)

; a corrupt/absent value must not resolve to 0 — 0 means "no answer" and would
; silently kill every shared key
IniWrite("banana", MMA_CFG, "Settings", "CurrentModel")
Ck("garbage -> 1", ManualModelNo(), 1)
IniDelete(MMA_CFG, "Settings", "CurrentModel")
Ck("absent -> 1", ManualModelNo(), 1)

; ── __mm vs __1mm — nothing left to assert here ──────────────────────────────
; This block checked UniversalSendActive()/NumberedSendActive(): bare __mm live
; exactly when the numbered form was dead. Both functions are gone. The numbered
; trigger is __1mm now, which shares no prefix with __mm, so both are always live
; and there is no gate to test. See the note where they used to live in
; core/active_model.ahk.
;
; Nothing replaces it in THIS file. What would be worth testing — that __<n>mm
; aims model n and not the last one — means firing the bound handler, and that
; handler ends in DoMass(), which puts text on the clipboard and presses Ctrl+V
; into whatever window is in front. A test that types into the user's chat is not
; a test. It is why mass_bind_test.ahk fires everything through a `noop`.

; ── the feature gate now sees mass.active.* ──────────────────────────────────
Ck("feat mass.1.altFu1",      FEAT_ForHotkey("mass.1.altFu1"),      "altFollowups")
Ck("feat mass.active.altFu1", FEAT_ForHotkey("mass.active.altFu1"), "altFollowups")
Ck("feat mass.active.mFu1",   FEAT_ForHotkey("mass.active.mFu1"),   "mouseControl")
Ck("feat mass.active.mPpv",   FEAT_ForHotkey("mass.active.mPpvFus"),"mouseControl")
Ck("feat mass.active.brPick", FEAT_ForHotkey("mass.active.brPick"), "altFollowups")
Ck("feat mass.active.fu1",    FEAT_ForHotkey("mass.active.fu1"),    "")
Ck("feat mass.active.mass",   FEAT_ForHotkey("mass.active.mass"),   "")
Ck("feat mass.select.next",   FEAT_ForHotkey("mass.select.next"),   "")
Ck("feat mass.select.m2",     FEAT_ForHotkey("mass.select.m2"),     "")

; ── restore the user's real settings ─────────────────────────────────────────
; The values that were there when this started, not a guess at them. Written
; directly rather than via SetManualModel, which validates and would silently
; substitute 1 for a value this test deliberately corrupted mid-run.
IniWrite(_savedCurrent, MMA_CFG, "Settings", "CurrentModel")
IniWrite(_savedMatch,   MMA_CFG, "Settings", "ModelMatch")

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
