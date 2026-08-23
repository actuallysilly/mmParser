#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  altfu_build_test.ahk — does the Add alt-FU window build, and does it write
;  where it says it does?
; ───────────────────────────────────────────────────────────────────────────────
;  Two halves, and the second is the one that earns its keep.
;
;  The BUILD half is settings_build_test's argument: parsing clean and building
;  are different questions, and a control placed on the wrong tab or a Map indexed
;  with a key that is not there throws the first time the window is opened, in
;  front of you, mid-shift.
;
;  The WRITER half is the part a control census cannot see. _AFW_AddPart decides
;  which branch row a wording lands in, and getting that wrong is not a crash —
;  it is one model's alternative quietly filed under another branch's name, found
;  when the picker offers it in a real conversation. The naming rules ("alt", then
;  alt1/alt2; a typed name that exists ADDS to that branch) are the same shape.
;
;  Prints to stdout. Exit 0 = built and wrote correctly.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn All, StdOut

#Include "../../src/core/paths.ahk"
#Include "../../src/mass/store.ahk"
#Include "../../src/mass/parser.ahk"
#Include "../../src/core/theme.ahk"
#Include "../../src/mass/archive.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    ExitApp(1)
}

pass := 0, fail := 0
Tck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── the stubs main_window.ahk would otherwise provide ─────────────────────────
;  edCtrls is the real subject here, so it is NOT stubbed away: it is a Map of
;  objects with a .Value, which is the entire contract _AFW_AddPart has with the
;  window. Real Edit controls would work identically and cost a Gui per run.
class Box {
    Value := ""
}

global modelCount := 2
global edCtrls    := Map()
Loop modelCount {
    _m := A_Index
    for _, _f in MASS_Fields()
        edCtrls["m" _m "_" _f] := Box()
}

; Read for the model dropdown's initial value, and written by OnModel.
global varTabs := {Value: 1}
global tabs    := {Value: 1}

CueBannerFor(ctrl, text) {
}
; The mass dropdown routes straight through the real PickMassSlot in the app —
; the same call the mass radios make, prompt and all. Here it is a no-op: this
; test has no library on disk to switch between, and the behaviour under test is
; what gets WRITTEN, not what gets loaded.
PickMassSlot(modelNo, slot, *) {
}
MassNoForModel(modelNo) {
    return 1
}
; The library writer, called only by a CAPTURE (the window opened with text from
; Add Hotkey ▸ Replace follow-up). Stubbed rather than exercised: it belongs to
; main_window.ahk and it writes masses.json — the one file in MMA that must never
; be touched by a test run. `saved` is what proves it was reached.
global saved := ""
ApplyFile(fname, silent := false) {
    global saved
    saved := fname
}
VarRefresh() {
}
RefreshModelHeader(*) {
}
ModelLabel(n) {
    return n " — Model " n
}

#Include "../../src/ui/alt_fu_window.ahk"

; ══ 1. the writer ══════════════════════════════════════════════════════════════
Out("── writer ──")

; A wording with no branch name goes to "alt", in the first free row.
Tck("first add is ok",        _AFW_AddPart(1, "alt", "fu1", "hey there"), "ok")
Tck("...landed in row 1",     edCtrls["m1_br1_fu1"].Value, "hey there")
Tck("...and named the row",   edCtrls["m1_br1_name"].Value, "alt")

; The same name again is the SAME branch, one row, second part — not a new row.
Tck("second part is ok",      _AFW_AddPart(1, "alt", "fu1", "second part"), "ok")
Tck("...same row, two lines", edCtrls["m1_br1_fu1"].Value, "hey there`r`nsecond part")
Tck("...row 2 still empty",   edCtrls["m1_br2_name"].Value, "")

; Case is a typo, not a second branch.
Tck("case-insensitive name",  _AFW_AddPart(1, "ALT", "fu1", "third part"), "ok")
Tck("...still row 1",         MASS_SplitParts(edCtrls["m1_br1_fu1"].Value).Length, 3)

; Three parts is the ceiling — there is no fourth sub-slot to send a fourth in.
Tck("fourth part refused",
   InStr(_AFW_AddPart(1, "alt", "fu1", "fourth"), "already has") ? 1 : 0, 1)
Tck("...and nothing was written",
   MASS_SplitParts(edCtrls["m1_br1_fu1"].Value).Length, 3)

; A different group is a different column of the SAME row. This is the property
; that makes a branch a branch: picking it at f1 commits you to it at f2.
Tck("same branch, other group", _AFW_AddPart(1, "alt", "fu2", "fu2 wording"), "ok")
Tck("...same row 1",            edCtrls["m1_br1_fu2"].Value, "fu2 wording")
Tck("...row 2 still empty",     edCtrls["m1_br2_name"].Value, "")

; A new name takes the next free row.
Tck("new name, new row",      _AFW_AddPart(1, "mexican", "fu1", "mehico"), "ok")
Tck("...row 2",               edCtrls["m1_br2_name"].Value, "mexican")

; Model 2 is untouched by every one of those. The control keys carry the model,
; and getting that wrong writes one model's wording into another's mass — which
; is the exact bug LoadFile's own comment describes.
Tck("model 2 untouched",      edCtrls["m2_br1_fu1"].Value, "")
Tck("model 2 unnamed",        edCtrls["m2_br1_name"].Value, "")

; Empty and unnamed are refused, not written as blanks. An empty message is a way
; to send silence to a real fan.
Tck("empty body refused",     _AFW_AddPart(1, "alt", "fu3", "   "), "empty")
Tck("no name refused",        _AFW_AddPart(1, "", "fu3", "text"), "no name")

; ══ 1b. the trunk writer ═══════════════════════════════════════════════════════
;  Replace is the destructive half — it overwrites the follow-up the plain key
;  sends — so what it leaves behind matters more than what it puts in.
Out("── replace ──")

Tck("replace writes part 1",
    _AFW_WriteTrunk(1, "fu3", ["new one", "new two"]), "ok")
Tck("...into fu3",            edCtrls["m1_fu3"].Value,   "new one")
Tck("...and fu3_5",           edCtrls["m1_fu3_5"].Value, "new two")

; The tail is CLEARED, not left. A replace that only overwrote what it filled
; would send the new first message followed by the OLD third one — a sequence
; nobody wrote, and one that reads in the chat as MMA inventing a line.
edCtrls["m1_fu3_7"].Value := "stale third message"
Tck("replace again",          _AFW_WriteTrunk(1, "fu3", ["only one"]), "ok")
Tck("...tail cleared",        edCtrls["m1_fu3_7"].Value, "")
Tck("...and the middle too",  edCtrls["m1_fu3_5"].Value, "")

; Four messages have nowhere to go: there are three sub-slots. Refused whole
; rather than silently truncated — the window asks first and trims the list.
Tck("four parts refused",
    InStr(_AFW_WriteTrunk(1, "fu3", ["a", "b", "c", "d"]), "not 4") ? 1 : 0, 1)
Tck("...and nothing was written", edCtrls["m1_fu3"].Value, "only one")
Tck("empty refused",          _AFW_WriteTrunk(1, "fu3", []), "empty")

; A PPV is ONE multiline field, so it takes the whole box and has no ceiling.
Tck("ppv joins its lines",
    _AFW_WriteTrunk(1, "ppv", ["line a", "line b", "line c", "line d"]), "ok")
Tck("...into ppv_base",       edCtrls["m1_ppv_base"].Value,
                              "line a`r`nline b`r`nline c`r`nline d")

; Model 2 is untouched by all of it — the same property the branch writer has.
Tck("model 2 untouched",      edCtrls["m2_fu3"].Value, "")

; What the confirm shows before it destroys anything.
Tck("trunk now reads back",   _AFW_TrunkNow(1, "fu3"), "only one")
edCtrls["m1_fu3_5"].Value := "and then this"
Tck("...both parts, in order", _AFW_TrunkNow(1, "fu3"), "only one  /  and then this")

; The group the cfg names, as a dropdown row. Anything it does not know is the
; first one rather than a throw: that value comes out of a hand-editable file.
Tck("fu2 is row 2",           _AFW_GroupIndex("fu2"), 2)
Tck("ppv is row 4",           _AFW_GroupIndex("ppv"), 4)
Tck("nonsense is row 1",      _AFW_GroupIndex("banana"), 1)

; ══ 2. the auto-name ═══════════════════════════════════════════════════════════
Out("── auto-name ──")
; Model 1 already has "alt" and "mexican" from above.
Tck("alt taken -> alt1",      _AFW_FreeAltName(1), "alt1")
Tck("model 2 is fresh",       _AFW_FreeAltName(2), "alt")
_AFW_AddPart(1, "alt1", "fu1", "x")
Tck("alt1 taken too -> alt2", _AFW_FreeAltName(1), "alt2")

; Full mass: every row named, so there is nowhere left to put a new branch.
Loop MASS_BRANCH_MAX
    edCtrls["m2_br" A_Index "_name"].Value := "b" A_Index
Tck("full mass refuses",
   InStr(_AFW_AddPart(2, "seventh", "fu1", "text"), "no free branch row") ? 1 : 0, 1)
Tck("...but an existing name still works",
   _AFW_AddPart(2, "b3", "fu1", "text"), "ok")

; ── the marker syntax is the parser's, not this window's ──────────────────────
; Asserted here because the window branches on it: a paste with markers is taken
; at its word and NOTHING is auto-named. If BranchMarker ever stops recognising a
; form, this window would silently start filing marked pastes under "alt".
Out("── markers ──")
Tck("::alt is a marker",      BranchMarker("::alt hello").name, "alt")
Tck("...body comes through",  BranchMarker("::alt hello there").body, "hello there")
Tck("plain line is not",      BranchMarker("just text") ? 1 : 0, 0)
Tck(":: alone is not",        BranchMarker("::") ? 1 : 0, 0)

; ══ what the paste box means ═══════════════════════════════════════════════════
;  The decision this window exists to make. Every case below is a paste someone
;  would plausibly produce.
Out("── plan ──")

; No markers: the whole box is one branch, one message per line, and the NAME is
; left to the caller (it depends on which mass you are writing into).
_p := _AFW_Plan("first line`r`nsecond line")
Tck("unmarked is not marked", _p.marked, 0)
Tck("...two parts",           _p.parts.Length, 2)
Tck("...no name of its own",  _p.parts[1].name, "")
Tck("...text kept in order",  _p.parts[2].text, "second line")

; Blank lines are separators, not messages. An empty message is silence sent to a
; real fan.
_p := _AFW_Plan("one`r`n`r`n`r`ntwo`r`n   ")
Tck("blank lines dropped",    _p.parts.Length, 2)

; Marked: taken at its word, several branches at once, nothing auto-named.
_p := _AFW_Plan("::alt hello`r`n::mexican hola`r`n::alt second alt line")
Tck("marked is marked",       _p.marked, 1)
Tck("...three parts",         _p.parts.Length, 3)
Tck("...first is alt",        _p.parts[1].name, "alt")
Tck("...second is mexican",   _p.parts[2].name, "mexican")
Tck("...body without marker", _p.parts[2].text, "hola")

; An unmarked line under a marker CONTINUES that branch — the parser's own rule,
; so a block copied out of a real mass behaves here as it did there.
_p := _AFW_Plan("::german eins`r`nzwei`r`n::alt other")
Tck("bare line continues",    _p.parts[2].name, "german")
Tck("...with its own text",   _p.parts[2].text, "zwei")
Tck("...next marker switches", _p.parts[3].name, "alt")

; The trunk line copied along with its alternatives is DROPPED, not filed as an
; alternative of itself — that would double a message in the chat while looking
; correct in the grid.
_p := _AFW_Plan("the trunk follow-up`r`n::alt an alternative")
Tck("text before the first marker is dropped", _p.parts.Length, 1)
Tck("...and it is the marked one",             _p.parts[1].name, "alt")

; `::name` with nothing after it opens a branch that says nothing HERE. It is a
; real thing to write and it must not become an empty message.
_p := _AFW_Plan("::mexican`r`n::alt hi")
Tck("bare marker contributes nothing", _p.parts.Length, 1)
Tck("...and it is not mexican",        _p.parts[1].name, "alt")

; ══ 3. the window ══════════════════════════════════════════════════════════════
Out("── build ──")
OpenAddAltFu()
hwnd := WinExist("Add alt-FU")
Tck("window exists", hwnd ? 1 : 0, 1)
if !hwnd {
    Out(pass " passed, " (fail + 1) " failed — the window never opened")
    ExitApp(1)
}

kinds := Map()
for ctl in WinGetControls("ahk_id " hwnd) {
    cls := RegExReplace(ctl, "\d+$", "")
    kinds[cls] := kinds.Has(cls) ? kinds[cls] + 1 : 1
}
Cnt(cls) => kinds.Has(cls) ? kinds[cls] : 0
for cls, n in kinds
    Out("  " cls " x" n)

; model, mass, follow-up
Tck("three dropdowns", Cnt("ComboBox"), 3)
; preview, branch name, paste box
Tck("three edits",     Cnt("Edit"),     3)
; Replace + Add + Close
Tck("three buttons",   Cnt("Button") >= 3, 1)

; The preview is filled at build time, not on the first change — a blank pane on
; open reads as a broken window rather than an empty mass.
prev := ControlGetText("Edit1", "ahk_id " hwnd)
Tck("preview is populated", Trim(prev) != "" ? 1 : 0, 1)
Tck("preview shows the branch we added", InStr(prev, "alt") ? 1 : 0, 1)

; A second open must not stack a second window.
OpenAddAltFu()
n := 0
for w in WinGetList("Add alt-FU")
    n++
Tck("one window only", n, 1)

; ══ 4. the capture window ══════════════════════════════════════════════════════
;  The other way in: text grabbed off the screen and handed over by Add Hotkey ▸
;  Replace follow-up. It is a different window from the one above — different
;  title, different default button, and its buttons SAVE — so arriving with a
;  capture while the editor's version is open must rebuild rather than re-use.
Out("── capture ──")
OpenAddAltFu("captured line one`ncaptured line two")
chwnd := WinExist("Replace follow-up")
Tck("capture window exists",     chwnd ? 1 : 0, 1)
Tck("the editor window is gone", WinExist("Add alt-FU") ? 1 : 0, 0)
if chwnd {
    ; Edit1 preview, Edit2 branch name, Edit3 the paste box.
    Tck("the grab is in the box",
        InStr(ControlGetText("Edit3", "ahk_id " chwnd), "captured line one") ? 1 : 0, 1)
}

; A control object arriving where the captured TEXT should be is what happens if
; anyone ever binds this straight to a button — OnEvent hands a handler the
; control as its first argument. It must open the editor's window, not put a
; GuiControl in the paste box.
OpenAddAltFu({Value: "not a string"})
Tck("a non-string prefill is not a capture", WinExist("Add alt-FU") ? 1 : 0, 1)

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
