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
; ...and must be bound under the SHARED set instead — but only when mouse control
; is actually switched on. These three used to assert literal keys unconditionally,
; which made the whole suite fail in Easy mode: Easy switches every feature off, so
; the mFu keys correctly do not register and the test called that a regression.
; That is the same "assert the invariant, not the user's key" point the loop below
; is written around, so they are asserted the same way.
for _, id in ["mass.active.mFu1", "mass.active.mFu2", "mass.active.mFu3"] {
    if !FEAT_HotkeyAllowed(id) {
        Ck("mouse control off, so " id " is unbound", BoundKey(id), "«not bound»")
        continue
    }
    Ck("shared " id, BoundKey(id), HK_Key(id))
}

; Every declared mass key must be registered with EXACTLY what the ini says.
;
; Asserted as an invariant rather than against literal keys like "F13". Those are
; the user's to change — this test used to hardcode mass.3.fu1 = F6 and started
; failing the day it was rebound to ^z, which says nothing about the code. What
; must hold is that binding is faithful to the file.
;
; A blank ini value means "deliberately disabled" and must bind nothing, which is
; the same check.
for id in HK_ORDER {
    if (SubStr(id, 1, 5) != "mass." || SubStr(id, 1, 12) = "mass.select.")
        continue
    if !FEAT_HotkeyAllowed(id)
        continue                      ; feature off: correctly not bound at all
    want := HK_Key(id)
    got  := BoundKey(id)
    if (got = "«not bound»")
        got := ""
    Ck("faithful: " id, got, want)
}

; ── feature ownership of the mass slots ──────────────────────────────────────
; The invariant above SKIPS anything a switched-off feature owns, so a typo in
; FEAT_HOTKEY_MAP cannot fail it: an unowned key is simply never skipped and binds
; as normal. These name the ownership directly.
;
; The prefix match runs against the SLOT for mass.<n>.<slot> ids, which is what
; lets one map entry cover model 1, 2, 3 and the shared set at once.
Ck("nextFu is owned by its feature", FEAT_ForHotkey("mass.active.nextFu"), "nextFu")
Ck("...for numbered models too",     FEAT_ForHotkey("mass.2.nextFu"),      "nextFu")
; And it must not swallow its neighbours: a plain follow-up key belongs to no
; feature and has to stay bound whatever is switched off.
Ck("plain fu1 is owned by nothing",  FEAT_ForHotkey("mass.1.fu1"),         "")

; And the shared set must actually carry keys — an empty [mass.active] would pass
; the invariant above while leaving every mouse button dead.
liveShared := 0
for id in HK_ORDER
    if (SubStr(id, 1, 12) = "mass.active." && BoundKey(id) != "" && BoundKey(id) != "«not bound»")
        liveShared++
Ck("shared set has live keys", liveShared >= 6, 1)

; The select keys are bound too, or nothing can set the tab order.
for id in ["mass.select.next", "mass.select.m1", "mass.select.m2"]
    Ck("bound " id, BoundKey(id) != "«not bound»", 1)

; ── resolution: a shared key must follow the SELECTED model, not model 1 ─────
; Everything below calls SelectModel, which is a REAL user action with REAL side
; effects on the live mass_gui.cfg. Two of them, and both have bitten:
;
;   ModelMatch    forced to "manual" here so the resolver has a deterministic
;                 answer. Left unrestored, it silently converts a user set to
;                 "tab position" over to "I pick".
;
;   [Positional]  far worse. In POSITION mode SelectModel calls TeachPosition,
;                 which reads whichever Infloww tab is lit RIGHT NOW and files the
;                 named model under it. Run this with Infloww open on tab 2 and it
;                 writes Pos2=1 — after which tab 2 sends model 1's messages, and
;                 the detector looks broken while being perfectly correct.
;                 That is not hypothetical; it happened, because the ModelMatch
;                 restore was once placed BEFORE the final SelectModel(1) and so
;                 handed a teaching-capable mode to a call that then taught.
;
; Hence: snapshot both, and restore both at the very END, after the last
; SelectModel in the file. Order is the whole safety property here.
_savedMatch := IniRead(MMA_CFG, "Settings", "ModelMatch", "name")
_savedPos := []
Loop MASS_MODELS
    _savedPos.Push(IniRead(MMA_CFG, "Positional", "Pos" A_Index, A_Index))
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

; ── restore ──────────────────────────────────────────────────────────────────
; SelectModel FIRST, while ModelMatch is still "manual" — it cannot teach a
; position in that mode. Only then put the real settings back. Reversing these two
; lines is what wrote Pos2=1 into a live config; see the note above.
IniWrite(2, MMA_CFG, "Settings", "ModelCount")
SelectModel(1)
IniWrite(_savedMatch, MMA_CFG, "Settings", "ModelMatch")
for _i, _p in _savedPos
    IniWrite(_p, MMA_CFG, "Positional", "Pos" _i)
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
