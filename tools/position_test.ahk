#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  position_test.ahk — tab index from screen x, and index to model.
; ───────────────────────────────────────────────────────────────────────────────
;  Positional mode is two steps and only the first touches the screen:
;
;    TabIndexFromX(x)  — WHICH TAB is lit. Fixed geometry, pure arithmetic.
;    TabModel(index)   — which MODEL that tab is. Straight from Settings.
;
;  Both are pure, so both are testable without Infloww on screen — which matters,
;  because every wrong-model bug in this feature has been in this arithmetic and
;  none of them were reachable by a test needing the live strip.
;
;  Writes to the REAL mass_gui.cfg [Positional] and restores it, since the order
;  round trip through the ini is part of what is under test.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/core/active_model.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError(Err)
Err(e, mode) {
    Out("ERROR: " e.Message " | " (e.HasProp("Extra") ? e.Extra : "") " @ " e.File ":" e.Line)
    Restore()
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

_savedMode  := IniRead(MMA_CFG, "Settings", "ModelMatch", "name")
_savedOrder := []
Loop MASS_MODELS
    _savedOrder.Push(IniRead(MMA_CFG, "Positional", "Pos" A_Index, ""))

Restore() {
    global _savedMode, _savedOrder
    try IniWrite(_savedMode, MMA_CFG, "Settings", "ModelMatch")
    ; Braces are load-bearing: `if X` / `try …` / `else` does not parse in AHK v2 —
    ; the try swallows the statement and the else has nothing to attach to.
    Loop MASS_MODELS {
        if (_savedOrder[A_Index] = "") {
            try IniDelete(MMA_CFG, "Positional", "Pos" A_Index)
        } else {
            try IniWrite(_savedOrder[A_Index], MMA_CFG, "Positional", "Pos" A_Index)
        }
    }
}

; The measured Infloww model-tab strip: starts at x30, each tab 150 wide.
;   tab 1 = x  30..179      tab 2 = x 180..329      tab 3 = x 330..479
G := {origin: 30, pitch: 150}

; ── x -> tab index ───────────────────────────────────────────────────────────
Ck("left edge of tab 1",  TabIndexFromX(30,  G), 1)
Ck("middle of tab 1",     TabIndexFromX(105, G), 1)
Ck("last px of tab 1",    TabIndexFromX(179, G), 1)
Ck("first px of tab 2",   TabIndexFromX(180, G), 2)
Ck("middle of tab 2",     TabIndexFromX(255, G), 2)
; The value measured off the live strip while Rama was in front. If this ever
; stops being tab 2, the geometry moved.
Ck("measured x=212 -> 2", TabIndexFromX(212, G), 2)
Ck("last px of tab 2",    TabIndexFromX(329, G), 2)
Ck("first px of tab 3",   TabIndexFromX(330, G), 3)

; Left of the strip is not tab 1. Something lit at x=0 is not a model tab at all,
; and calling it tab 1 is how every one of these bugs started.
Ck("left of the strip",   TabIndexFromX(29, G), 0)
Ck("x=0",                 TabIndexFromX(0,  G), 0)
Ck("no pill (-1)",        TabIndexFromX(-1, G), 0)
; Far right is a real index; the caller rejects it against MASS_MODELS, so the
; arithmetic must not silently clamp and hand back a valid-looking slot.
Ck("far right is a big index", TabIndexFromX(1200, G), 8)

; A broken pitch must not divide by zero or answer confidently.
Ck("pitch 0",  TabIndexFromX(200, {origin: 30, pitch: 0}), 0)
Ck("pitch -5", TabIndexFromX(200, {origin: 30, pitch: -5}), 0)

; A different zoom is a config change, not a code change.
H := {origin: 0, pitch: 100}
Ck("other geometry: tab 1", TabIndexFromX(50,  H), 1)
Ck("other geometry: tab 3", TabIndexFromX(250, H), 3)


; ── the decision, given per-tab pixel counts ─────────────────────────────────
; This is what actually runs on every keypress: sample each fixed slot, then pick.
Ck("tab 1 lit",       PILL_PickLit([40, 0, 0], 6), 1)
Ck("tab 2 lit",       PILL_PickLit([0, 40, 0], 6), 2)
Ck("tab 3 lit",       PILL_PickLit([0, 0, 40], 6), 3)
Ck("nothing lit",     PILL_PickLit([0, 0, 0], 6), 0)
Ck("under the floor", PILL_PickLit([5, 0, 0], 6), 0)
Ck("on the floor",    PILL_PickLit([6, 0, 0], 6), 1)
; Two slots both lit is one pill straddling them, i.e. TabPitch is wrong. That is
; not "the brighter one wins" — answering picks between two people's fans.
Ck("straddling",      PILL_PickLit([40, 40, 0], 6), 0)
Ck("straddling 40/30", PILL_PickLit([40, 30, 0], 6), 0)
Ck("runner-up half",  PILL_PickLit([40, 20, 0], 6), 1)
Ck("runner-up over half", PILL_PickLit([40, 21, 0], 6), 0)
Ck("clear winner",    PILL_PickLit([40, 4, 0], 6), 1)
Ck("three-way tie",   PILL_PickLit([30, 30, 30], 6), 0)

; ── the sampled range per tab ────────────────────────────────────────────────
; Inset, so a neighbouring tab's edge cannot leak into this one's count.
r1 := TabRange(1, G), r2 := TabRange(2, G)
Ck("tab1 x1", r1.x1, 38)
Ck("tab1 x2", r1.x2, 172)
Ck("tab2 x1", r2.x1, 188)
Ck("tab2 x2", r2.x2, 322)
Ck("ranges do not overlap", r1.x2 < r2.x1, 1)

; ── tab index -> model ───────────────────────────────────────────────────────
Loop MASS_MODELS
    try IniDelete(MMA_CFG, "Positional", "Pos" A_Index)
Ck("default order is identity 1", TabModel(1), 1)
Ck("default order is identity 2", TabModel(2), 2)
Ck("index 0 -> no model",         TabModel(0), 0)
Ck("index -1 -> no model",        TabModel(-1), 0)

; Reordered: leftmost tab is Rama, second is Aliw.
Ck("set tab1 = model 2", SetTabOrderFor(1, 2), 1)
Ck("set tab2 = model 1", SetTabOrderFor(2, 1), 1)
Ck("tab 1 is now model 2", TabModel(1), 2)
Ck("tab 2 is now model 1", TabModel(2), 1)

; And end to end: the x measured off the strip, through both steps.
Ck("x=105 -> model 2", TabModel(TabIndexFromX(105, G)), 2)
Ck("x=212 -> model 1", TabModel(TabIndexFromX(212, G)), 1)

Ck("order index 0 refused",  SetTabOrderFor(0, 1), 0)
Ck("order model 0 refused",  SetTabOrderFor(1, 0), 0)
Ck("order model 99 refused", SetTabOrderFor(1, 99), 0)
Ck("order survived refusals", TabModel(1), 2)

; An out-of-range stored value must read as "no model", not as itself.
IniWrite(99, MMA_CFG, "Positional", "Pos1")
Ck("stored 99 -> no model", TabModel(1), 0)
IniWrite("banana", MMA_CFG, "Positional", "Pos1")
Ck("stored garbage -> falls back", TabModel(1), 1)   ; default for Pos1 is 1

; ── manual mode is untouched by any of this ──────────────────────────────────
IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
SetManualModel(2)
Ck("manual still resolves", ActiveModelNo(), 2)

; ── the config reader ────────────────────────────────────────────────────────
cfg := DetectorCfg()
Ck("cfg colour",  cfg.rgb > 0, 1)
Ck("cfg origin",  cfg.origin >= 0, 1)
Ck("cfg pitch",   cfg.pitch > 0, 1)
Ck("cfg win set", cfg.win != "", 1)

Restore()
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
