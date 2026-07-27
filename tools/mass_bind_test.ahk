#Requires AutoHotkey v2.0
; What the engine ACTUALLY registers, and which model each key resolves to.
; Parsing clean has never been the failing step here; this is the step that was.
; ═══════════════════════════════════════════════════════════════════════════════
;  mass_bind_test.ahk — what the engine ACTUALLY registers, and for which model.
; ───────────────────────────────────────────────────────────────────────────────
;  Every bug in this area so far has parsed cleanly and then done the wrong thing
;  at runtime: a mouse button declared under model 1 sending model 1's follow-up
;  in front of model 2; a closure in a bind loop giving three keys the same
;  model. Validation cannot see any of that. This runs the binders and reads the
;  registry back.
;
;  It registers real hotkeys for the fraction of a second before it exits, so do
;  not run it while you are mid-send.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/runtime.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError(Err)
Err(e, mode) {
    Out("ERROR: " e.Message " | " (e.HasProp("Extra") ? e.Extra : "") " @ " e.File ":" e.Line)
    ExitApp(1)
}

global MASS_DOC := MASS_Load()
pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

Loop MASS_MODELS
    MassBindModel(A_Index)
MassBindActive()
MassBindSelect()

BoundKey(id) {
    global _HK_BOUND
    return _HK_BOUND.Has(id) ? _HK_BOUND[id].key : "«not bound»"
}

; ── the reported bug: the mouse buttons must no longer belong to model 1 ──────
Ck("mass.1.mFu1 gone",  BoundKey("mass.1.mFu1"),  "«not bound»")
Ck("mass.1.mFu2 gone",  BoundKey("mass.1.mFu2"),  "«not bound»")
Ck("mass.1.mFu3 gone",  BoundKey("mass.1.mFu3"),  "«not bound»")
Ck("active mFu1", BoundKey("mass.active.mFu1"), "XButton2")
Ck("active mFu2", BoundKey("mass.active.mFu2"), "XButton1")
Ck("active mFu3", BoundKey("mass.active.mFu3"), "^MButton")

; the rest of the shared set is really there, not just declared
for id, want in Map("mass.active.fu1","F13", "mass.active.fu2","F14", "mass.active.fu3","F15",
                    "mass.active.ppv","F16", "mass.active.ppvFus","F17", "mass.active.mass","F18",
                    "mass.active.brPick","F19", "mass.active.brFu2","F20",
                    "mass.active.brFu3","F21", "mass.active.brPpv","F22",
                    "mass.active.altFu1","^F13", "mass.active.altFu2","^F14",
                    "mass.active.altFu3","^F15",
                    "mass.select.next","^!w", "mass.select.m1","^!1",
                    "mass.select.m2","^!2", "mass.select.m3","^!3")
    Ck(id, BoundKey(id), want)

; the manual per-model keys must be untouched — they are the reliable path
for id, want in Map("mass.1.fu1","F1", "mass.1.fu2","F2", "mass.1.fu3","F3",
                    "mass.2.fu1","F9", "mass.2.fu2","F10", "mass.2.fu3","F11",
                    "mass.3.fu1","F6")
    Ck(id, BoundKey(id), want)

; ── resolution: a shared key must follow the SELECTED model, not model 1 ─────
IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
noop := (*) => 0
Loop MASS_MODELS {
    n := A_Index
    SelectModel(n)
    _SetCurModel(0)
    _RunOnActiveModel(noop)
    Ck("shared key -> model " n, MASS_CUR_MODEL, n)
}

; ── and a NUMBERED key must ignore the selection entirely ────────────────────
SelectModel(3)
_SetCurModel(0)
_ModelFire(1, noop)()
Ck("mass.1.* stays model 1", MASS_CUR_MODEL, 1)
_ModelFire(2, noop)()
Ck("mass.2.* stays model 2", MASS_CUR_MODEL, 2)

; ── .Bind vs closure: each select key must mean its OWN model ────────────────
; A fat-arrow lambda in that loop would capture one shared `n`, so all three keys
; would select the last model. Fire the registered callbacks to prove otherwise.
Loop MASS_MODELS {
    n := A_Index
    SelectModel(Mod(n, MASS_MODELS) + 1)     ; park it somewhere else first
    cb := _HK_BOUND["mass.select.m" n].fn   ; via a local: obj.fn() would pass obj
    cb()
    Ck("select.m" n " selects " n, ManualModelNo(), n)
}

; ── cycling wraps at ModelCount, not MASS_MODELS ─────────────────────────────
IniWrite(2, MMA_CFG, "Settings", "ModelCount")
SelectModel(1), SelectNextModel()
Ck("cycle 1->2", ManualModelNo(), 2)
SelectNextModel()
Ck("cycle 2->1 (count=2)", ManualModelNo(), 1)

; ── select must not be treated as a send by the anti-fumble gate ─────────────
Ck("select is not a send", _HK_IsSend("mass.select.m2"), 0)
Ck("shared fu IS a send",  _HK_IsSend("mass.active.fu1"), 1)
Ck("mouse fu IS a send",   _HK_IsSend("mass.active.mFu1"), 1)

; restore
IniWrite(2, MMA_CFG, "Settings", "ModelCount")
SelectModel(1)
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
