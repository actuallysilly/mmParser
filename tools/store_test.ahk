#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  store_test.ahk — mass/store.ahk against the cases that would lose your masses.
;
;  Runs against a TEMP file, never userdata\masses.json. Exit 1 on any failure.
;
;  The headline case is the third one. The GUI only ever has ONE model on screen,
;  so "save" has to be read-modify-write; a document built from the edit boxes
;  alone would write three models where two are blank, and the first save after
;  switching tabs would quietly wipe the other two.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/store.ahk"

pass := 0, fail := 0
Out(s) => FileAppend(s "`n", "*")

Check(name, got, want) {
    global pass, fail
    if (got == want) {
        pass++
        return
    }
    fail++
    Out("FAIL  " name)
    Out("      want: " StrReplace(String(want), "`n", "\n"))
    Out("      got:  " StrReplace(String(got), "`n", "\n"))
}

; Point the store at a scratch file for the whole run.
global MMA_MASSES := A_Temp "\mma_store_test_" A_TickCount ".json"

; ── a blank library has full shape ───────────────────────────────────────────
d := MASS_Load()                                  ; no file yet
Check("models",     d["models"].Length,           MASS_MODELS)
Check("slots",      d["models"][1]["masses"].Length, MASS_SLOTS)
Check("massNo",     MASS_MassNo(d, 1),            1)
Check("field there", MASS_Get(d, 1, 1).Has("fu1"), 1)
Check("field empty", MASS_Get(d, 1, 1)["fu1"],    "")

; ── round trip through the file ──────────────────────────────────────────────
MASS_Get(d, 1, 1)["mass"] := 'Model 1 "slot 1" — 🍑'
MASS_Get(d, 2, 3)["fu2"]  := "line a`nline b"
MASS_Get(d, 3, 2)["ppv_base"] := "back\slash`tand tab"
MASS_SetMassNo(d, 2, 3)
Check("saved", MASS_Save(d), 1)

r := MASS_Load()
Check("rt m1s1 mass", MASS_Get(r, 1, 1)["mass"],     'Model 1 "slot 1" — 🍑')
Check("rt m2s3 fu2",  MASS_Get(r, 2, 3)["fu2"],      "line a`nline b")
Check("rt m3s2 ppv",  MASS_Get(r, 3, 2)["ppv_base"], "back\slash`tand tab")
Check("rt massNo",    MASS_MassNo(r, 2),             3)
Check("rt active",    MASS_Active(r, 2)["fu2"],      "line a`nline b")

; ── THE ONE THAT MATTERS: saving one model must not touch the others ─────────
; Simulates what the GUI does — load the whole library, replace only the model
; currently on screen, write it all back.
doc := MASS_Load()
Loop MASS_SLOTS {
    rec := MASS_Blank()
    rec["mass"] := "rewritten slot " A_Index
    MASS_Set(doc, 2, A_Index, rec)               ; model 2 only
}
MASS_Save(doc)

after := MASS_Load()
Check("model 1 survived", MASS_Get(after, 1, 1)["mass"], 'Model 1 "slot 1" — 🍑')
Check("model 3 survived", MASS_Get(after, 3, 2)["ppv_base"], "back\slash`tand tab")
Check("model 2 replaced", MASS_Get(after, 2, 1)["mass"], "rewritten slot 1")
Check("model 2 cleared",  MASS_Get(after, 2, 3)["fu2"],  "")

; ── normalise repairs anything short ─────────────────────────────────────────
n := MASS_Normalise(Map("models", [Map("masses", [Map("fu1", "only me")])]))
Check("short doc models", n["models"].Length,            MASS_MODELS)
Check("short doc slots",  n["models"][1]["masses"].Length, MASS_SLOTS)
Check("short doc kept",   MASS_Get(n, 1, 1)["fu1"],      "only me")
Check("short doc filled", MASS_Get(n, 1, 2)["fu1"],      "")
Check("short doc massNo", MASS_MassNo(n, 1),             1)

Check("junk doc",  MASS_Normalise("nonsense")["models"].Length, MASS_MODELS)
Check("bad massNo", MASS_MassNo(MASS_Normalise(
    Map("models", [Map("massNo", 99, "masses", [])])), 1), 1)

; unknown keys from a future or hand-edited file are dropped, not crashed on
u := MASS_Normalise(Map("models", [Map("masses", [Map("fu1", "keep", "nope", "drop")])]))
Check("unknown dropped", MASS_Get(u, 1, 1).Has("nope"), 0)
Check("known kept",      MASS_Get(u, 1, 1)["fu1"],      "keep")

; ── the Map -> object bridge the send path relies on ─────────────────────────
o := MASS_AsObject(MASS_Get(after, 1, 1))
Check("obj prop",   o.mass,                  'Model 1 "slot 1" — 🍑')
Check("obj dynamic", o.%"fu1"%,              "")
Check("obj hasprop", o.HasOwnProp("ppv_f3"), 1)

try FileDelete(MMA_MASSES)
Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
