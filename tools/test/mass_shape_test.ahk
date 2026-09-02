#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  mass_shape_test.ahk — what a mass sends, and the transcript that claims to
;  show it.
; ───────────────────────────────────────────────────────────────────────────────
;  mass\shape.ahk exists so the engine and the chat simulator cannot disagree
;  about what a mass sends. That promise is only worth something if the rules
;  themselves are pinned, because every one of them is invisible from the edit
;  boxes and every one of them is a real message to a real fan:
;
;    * a follow-up is THREE fields sent as THREE messages — unless
;      FuSingle_<model>_<group> joins them into one with line breaks
;    * f3, and only f3, falls back to the DefaultFu3 text when the mass has none
;    * the opener and the PPV blurb are PASTED, no Enter; everything else sends
;    * a branch answers the groups it has wording for, and the trunk answers the
;      rest — which is what TAB staging does at send time
;
;  Pure: it builds mass records in memory and never opens masses.json.
;
;  ─── IT WRITES TWO SETTINGS KEYS ─────────────────────────────────────
;  It has to: FuSingle and DefaultFu3 ARE the behaviour under test, and shape.ahk
;  reads them from mass_gui.cfg by design (per call, so an edit applies without a
;  restart). Both are snapshotted and put back in Finish(), which every exit path
;  goes through — including the error handler.
;
;  Prints to stdout. Exit 0 = all good.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn VarUnset, StdOut

#Include "../../src/mass/shape.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
pass := 0, fail := 0
Tck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ":`n     got  <" got ">`n     want <" want ">")
}
Ck(name, ok, detail := "") {
    global pass, fail
    if ok
        pass++
    else
        fail++, Out("FAIL " name (detail = "" ? "" : ": " detail))
}

; ── snapshot the two keys this test drives ────────────────────────────────────
global TEST_MODEL := 1
global SAVED := Map()
for _, k in ["FuSingle_" TEST_MODEL "_1", "FuSingle_" TEST_MODEL "_2",
             "FuSingle_" TEST_MODEL "_3", "DefaultFu3"]
    SAVED[k] := IniRead(MMA_CFG, "Settings", k, Chr(1) "unset")

Finish(code) {
    global SAVED
    for k, v in SAVED {
        ; Braces on both arms: `try X` is a statement, and an `else` after a
        ; braceless one is a parse error rather than the branch you meant.
        if (v = Chr(1) "unset") {
            try IniDelete(MMA_CFG, "Settings", k)
        } else {
            try IniWrite(v, MMA_CFG, "Settings", k)
        }
    }
    ExitApp(code)
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    Finish(1)
}
SetKeys(single1, defFu3) {
    global TEST_MODEL
    IniWrite(single1 ? "1" : "0", MMA_CFG, "Settings", "FuSingle_" TEST_MODEL "_1")
    IniWrite("0", MMA_CFG, "Settings", "FuSingle_" TEST_MODEL "_2")
    IniWrite("0", MMA_CFG, "Settings", "FuSingle_" TEST_MODEL "_3")
    IniWrite(defFu3, MMA_CFG, "Settings", "DefaultFu3")
}

Out("mass shape: what a mass sends, and the transcript of it")

; A mass is an OBJECT here, not a Map: shape.ahk reads it with HasOwnProp and
; m.%field%, which is what MASS_Load hands the engine.
Mass(fields*) {
    m := {}
    for f in MASS_Fields()
        m.%f% := ""
    i := 1
    while (i < fields.Length) {
        m.%fields[i]% := fields[i + 1]
        i += 2
    }
    return m
}
Beat(beats, key) {
    for _, b in beats
        if (b.key = key)
            return b
    return 0
}
Texts(beat) {
    out := ""
    for _, msg in beat.messages
        out .= (out = "" ? "" : " | ") StrReplace(msg.text, "`n", "\n")
    return out
}

; ═══════════════════════════════════════════════════════════════════════════════
;  1. the three parts of a follow-up
; ═══════════════════════════════════════════════════════════════════════════════
SetKeys(false, "")
m := Mass("mass", "the opener",
          "fu1", "one", "fu1_5", "two", "fu1_7", "three")
t := MASS_Transcript(m, TEST_MODEL, 0)

Tck("f1 sends three separate messages", Texts(Beat(t, "fu1")), "one | two | three")
Tck("...and that is three messages",    Beat(t, "fu1").messages.Length, 3)
Tck("each part names its own field",    Beat(t, "fu1").messages[2].fields[1], "fu1_5")
Tck("the opener is one message",        Texts(Beat(t, "mass")), "the opener")
Tck("the opener PASTES",                Beat(t, "mass").kind, "paste")
Tck("a follow-up SENDS",                Beat(t, "fu1").kind, "send")
Tck("the PPV blurb PASTES",             Beat(t, "ppv").kind, "paste")
Tck("the PPV follow-ups SEND",          Beat(t, "ppvfus").kind, "send")

; A blank middle part is skipped, not sent as an empty message.
m := Mass("fu1", "one", "fu1_7", "three")
t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("a blank part is skipped", Texts(Beat(t, "fu1")), "one | three")
Tck("and its field goes with it", Beat(t, "fu1").messages[2].fields[1], "fu1_7")

; ═══════════════════════════════════════════════════════════════════════════════
;  2. FuSingle joins them into one
; ═══════════════════════════════════════════════════════════════════════════════
SetKeys(true, "")
m := Mass("fu1", "one", "fu1_5", "two", "fu1_7", "three",
          "fu2", "a", "fu2_5", "b")
t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("FuSingle makes f1 ONE message",   Beat(t, "fu1").messages.Length, 1)
Tck("...joined with line breaks",      Texts(Beat(t, "fu1")), "one\ntwo\nthree")
Ck("...and the note says which key",  InStr(Beat(t, "fu1").note, "FuSingle_1_1"),
    "note was: " Beat(t, "fu1").note)
Tck("the joined message names every field it came from",
    Beat(t, "fu1").messages[1].fields.Length, 3)
; Per model AND per group: f2 was left off, so it must still split.
Tck("f2 is untouched by f1's FuSingle", Beat(t, "fu2").messages.Length, 2)
SetKeys(false, "")

; ═══════════════════════════════════════════════════════════════════════════════
;  3. the f3 fallback
; ═══════════════════════════════════════════════════════════════════════════════
SetKeys(false, "are you still there?")
m := Mass("fu1", "one")                       ; no f3 at all
t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("an empty f3 falls back to DefaultFu3", Texts(Beat(t, "fu3")),
    "are you still there?")
Ck("...and says so",  InStr(Beat(t, "fu3").note, "DefaultFu3"),
    "note was: " Beat(t, "fu3").note)

m := Mass("fu3", "its own f3")
t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("a mass WITH an f3 keeps it", Texts(Beat(t, "fu3")), "its own f3")
Ck("...and is not labelled a fallback", !InStr(Beat(t, "fu3").note, "DefaultFu3"),
    "note was: " Beat(t, "fu3").note)

; f1 and f2 have no fallback, only f3.
m := Mass("fu3", "x")
t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("an empty f1 sends nothing", Beat(t, "fu1").messages.Length, 0)
SetKeys(false, "")

; ═══════════════════════════════════════════════════════════════════════════════
;  4. branches
; ═══════════════════════════════════════════════════════════════════════════════
;  A branch answers the groups it has wording for. For the rest the TRUNK's
;  wording goes out — TAB staging skips a group the branch does not answer, so
;  there is nothing else it could be.
m := Mass("mass", "opener",
          "fu1", "trunk f1", "fu2", "trunk f2", "fu3", "trunk f3",
          "ppv_base", "trunk ppv",
          "br1_name", "plays-along", "br1_fu1", "branch f1", "br1_ppv", "branch ppv")

Ck("the branch is found", BranchList(m).Length = 1)
Tck("...under its name",  BranchList(m)[1].name, "plays-along")

t := MASS_Transcript(m, TEST_MODEL, 1)
Tck("on the branch, f1 is the branch's",  Texts(Beat(t, "fu1")), "branch f1")
Tck("...and names the branch field",      Beat(t, "fu1").messages[1].fields[1], "br1_fu1")
Tck("f2 falls back to the trunk",         Texts(Beat(t, "fu2")), "trunk f2")
Ck("...and says why", InStr(Beat(t, "fu2").note, "no f2"),
    "note was: " Beat(t, "fu2").note)
Tck("the branch's PPV wins",              Texts(Beat(t, "ppv")), "branch ppv")

t := MASS_Transcript(m, TEST_MODEL, 0)
Tck("on the trunk, f1 is the trunk's",    Texts(Beat(t, "fu1")), "trunk f1")
Tck("...and the trunk's PPV",             Texts(Beat(t, "ppv")), "trunk ppv")

; An out-of-range branch is the trunk, not a crash. The simulator's dropdown and
; the saved selection can both outlive the branch they name.
t := MASS_Transcript(m, TEST_MODEL, 99)
Tck("a branch that does not exist is the trunk", Texts(Beat(t, "fu1")), "trunk f1")

; A branch with wording in no group at all is not a branch.
m2 := Mass("fu1", "x", "br1_name", "named but empty")
Tck("an empty branch is not listed", BranchList(m2).Length, 0)

; ═══════════════════════════════════════════════════════════════════════════════
;  5. AltVariants — the same question, the way the send path asks it
; ═══════════════════════════════════════════════════════════════════════════════
v := AltVariants(m, 1)
Tck("f1 offers trunk + branch", v.Length, 2)
Tck("the trunk is first",       v[1].label, "main")
Tck("...and commits to nothing", v[1].branch, 0)
Tck("the branch is second",     v[2].label, "plays-along")
Tck("...and commits to itself", v[2].branch, 1)

v := AltVariants(m, 2)
Tck("f2 offers only the trunk", v.Length, 1)

v := AltPpvVariants(m)
Tck("the PPV offers both",      v.Length, 2)

; ═══════════════════════════════════════════════════════════════════════════════
;  6. the counts the simulator puts at the top
; ═══════════════════════════════════════════════════════════════════════════════
m := Mass("mass", "opener", "fu1", "a", "fu1_5", "b", "fu2", "c",
          "ppv_base", "blurb", "ppv_f1", "d")
t := MASS_Transcript(m, TEST_MODEL, 0)
c := MASS_TranscriptCounts(t)
Tck("pasted: the opener and the blurb", c.pasted, 2)
Tck("sent: a, b, c, d",                 c.sent,   4)
Tck("chars counts every message",       c.chars,
    StrLen("opener") + StrLen("a") + StrLen("b") + StrLen("c")
  + StrLen("blurb") + StrLen("d"))

; ═══════════════════════════════════════════════════════════════════════════════
;  7. every beat is present, in send order, even when empty
; ───────────────────────────────────────────────────────────────────────────────
;  The simulator draws one row per beat whether or not it has a message, because
;  an f2 you never wrote is exactly the gap you opened the window to notice.
; ═══════════════════════════════════════════════════════════════════════════════
t := MASS_Transcript(Mass(), TEST_MODEL, 0)
order := ""
for _, b in t
    order .= (order = "" ? "" : ",") b.key
Tck("beat order", order, "mass,fu1,fu2,fu3,ppv,ppvfus")
n := 0
for _, b in t
    n += b.messages.Length
Tck("an empty mass sends nothing at all", n, 0)

; ═══════════════════════════════════════════════════════════════════════════════
;  8. the Map / object boundary, which the simulator is the first thing to cross
;     in both directions
; ───────────────────────────────────────────────────────────────────────────────
;  masses.json holds a record as a Map. Everything that READS a mass — every
;  function above this line — takes it as an object, because that is what the
;  send path was written against and MASS_AsObject converts at the boundary.
;
;  The engine never writes back, so for years the boundary only had to work one
;  way. A window that EDITS a record in object form has to cross it going the
;  other way too, and getting that wrong does not throw: MASS_Normalise keeps a
;  record only if it `is Map`, so the object form is silently replaced with a
;  blank one. The mass looks saved until you reopen it and find it gone.
;
;  In memory, no file: MASS_Normalise is what MASS_Save runs on the way to disk,
;  so putting a record through it proves the same thing without touching
;  masses.json.
; ═══════════════════════════════════════════════════════════════════════════════
doc := MASS_Normalise(Map())
Tck("a blank library has the models", doc["models"].Length >= MASS_MODELS, true)

rec := MASS_AsObject(MASS_Get(doc, 1, 1))
Ck("AsObject gives property access", rec.fu1 = "")
rec.fu1 := "typed in the simulator"
rec.mass := "an opener"

MASS_Set(doc, 1, 1, MASS_AsMap(rec))
doc := MASS_Normalise(doc)
Tck("an edit made through AsObject survives AsMap + normalise",
    MASS_Get(doc, 1, 1)["fu1"], "typed in the simulator")
Tck("...and so does the rest of the record",
    MASS_Get(doc, 1, 1)["mass"], "an opener")

; The trap, asserted so it stays documented: this is what MASS_AsMap exists to
; prevent, and it fails silently rather than loudly.
doc2 := MASS_Normalise(Map())
bad := MASS_AsObject(MASS_Get(doc2, 1, 1))
bad.fu1 := "this will be lost"
MASS_Set(doc2, 1, 1, bad)                  ; the object form, on purpose
doc2 := MASS_Normalise(doc2)
Tck("storing the OBJECT form silently loses the record (hence MASS_AsMap)",
    MASS_Get(doc2, 1, 1)["fu1"], "")

; AsMap is idempotent, so a caller that already has a Map is not punished for
; passing it through.
Ck("AsMap leaves a Map alone", MASS_AsMap(MASS_Get(doc, 1, 1)) is Map)

; ═══════════════════════════════════════════════════════════════════════════════
;  9. where the composer writes
; ───────────────────────────────────────────────────────────────────────────────
;  The chat simulator's Send has to land in the right field, and "the right
;  field" is not the same question on the trunk as on a branch: the trunk keeps
;  its three parts in three FIELDS, a branch keeps all of its in ONE, newline
;  separated. Getting that wrong writes a message into a field nothing sends.
; ═══════════════════════════════════════════════════════════════════════════════
SetKeys(false, "")
m := Mass()
sl := MASS_WriteSlots(m, 0)
ids := ""
for _, x in sl
    ids .= (ids = "" ? "" : ",") x.id
Tck("the trunk's fourteen slots, in send order", ids,
    "mass,fu1,fu1_5,fu1_7,fu2,fu2_5,fu2_7,fu3,fu3_5,fu3_7,ppv,ppv_f1,ppv_f2,ppv_f3")
Tck("every trunk slot replaces its field", sl[2].mode, "field")
Tck("the opener pastes",                   sl[1].kind, "paste")
Tck("a follow-up part sends",              sl[2].kind, "send")

Tck("an empty mass starts at the opener", MASS_NextEmptySlot(m, 0).id, "mass")
m.mass := "written"
Tck("...then the first follow-up part",   MASS_NextEmptySlot(m, 0).id, "fu1")
m.fu1 := "written"
Tck("...then the second",                 MASS_NextEmptySlot(m, 0).id, "fu1_5")

; A full mass has nowhere left to go, and must say so rather than overwriting.
full := Mass()
for _, x in MASS_WriteSlots(full, 0)
    full.%x.field% := "x"
Ck("a full mass has no next slot", !IsObject(MASS_NextEmptySlot(full, 0)))

; ── on a branch ───────────────────────────────────────────────────────────────
mb := Mass("fu1", "trunk f1", "br1_name", "plays-along", "br1_fu1", "branch f1")
sl := MASS_WriteSlots(mb, 1)
ids := ""
for _, x in sl
    ids .= (ids = "" ? "" : ",") x.id
Tck("a branch has one slot per group, not three", ids,
    "mass,fu1,fu2,fu3,ppv,ppv_f1,ppv_f2,ppv_f3")
for _, x in sl {
    if (x.id = "fu1") {
        Tck("a branch group writes the branch's field", x.field, "br1_fu1")
        Tck("...by appending a line",                   x.mode,  "line")
    }
    if (x.id = "mass")
        Tck("the opener is still the trunk's", x.field, "mass")
    if (x.id = "ppv_f2")
        Tck("PPV follow-ups are still the trunk's", x.field, "ppv_f2")
}

; The two write modes, which is the whole reason `mode` is carried around.
Tck("a field slot is replaced",        MASS_SlotWrite("old", "new", "field"), "new")
Tck("a line slot appends",             MASS_SlotWrite("one", "two", "line"), "one`ntwo")
Tck("...and starts clean when empty",  MASS_SlotWrite("", "one", "line"), "one")
Tck("...without leaving a blank line", MASS_SlotWrite("one`n", "two", "line"), "one`ntwo")

; What the composer just wrote has to come back out as a message. This is the
; round trip the window is: type, store, and read it back through the same
; transcript the engine sends from.
mb2 := Mass("br1_name", "plays-along")
mb2.br1_fu1 := MASS_SlotWrite(mb2.br1_fu1, "first", "line")
mb2.br1_fu1 := MASS_SlotWrite(mb2.br1_fu1, "second", "line")
t := MASS_Transcript(mb2, TEST_MODEL, 1)
Tck("two composed lines are two messages on the branch",
    Texts(Beat(t, "fu1")), "first | second")

Out("")
Out(pass " passed, " fail " failed")
Finish(fail ? 1 : 0)
