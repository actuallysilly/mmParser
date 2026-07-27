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

#Include "../src/core/active_model.ahk"
#Include "../src/core/modes.ahk"

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

; ── __mm vs __mm1: manual mode counts as "model known" ───────────────────────
SetManualModel(3)
Ck("__mm live in manual",       UniversalSendActive(), 1)
Ck("__mm3 dead in manual",      NumberedSendActive(3), 0)

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
IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
SetManualModel(1)

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
