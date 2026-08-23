#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  branch_tree_test.ahk — the branch builder's compiler, and the round trip.
; ───────────────────────────────────────────────────────────────────────────────
;  Two halves, and the second is the one that matters:
;
;   1. BR_Compile turns a conversation tree into a mass record. Every way that
;      can go wrong is a way to LOSE A MESSAGE you typed — a route too deep for
;      f1/f2/f3, more forks than a mass has branches, two forks with the same
;      name. All of those must be REPORTED, never silently truncated.
;
;   2. tree → BR_Compile → BR_EmitText → the SHIPPING parser → the same record.
;      The builder's whole output contract is "this pastes into MMA and works",
;      and the only way to know that is to run it through mass/parser.ahk rather
;      than against a copy of what the format is believed to be.
;
;  Top-level variables here are deliberately not called `t`, `r`, `out`, `rec`,
;  `nodes` or `i`: a script-level assignment makes a SUPER-GLOBAL, which then
;  collides by name with locals inside every file this includes and fills the
;  run with `#Warn All` noise that buries a real failure.
;
;  Prints to stdout. Exit 0 = every check passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn All, StdOut

#Include "../../src/branch/tree.ahk"

Say(s) {
    try FileAppend(s "`n", "*")
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Say("ERROR: " e.Message)
    Say("   at " e.File ":" e.Line)
    ExitApp(1)
}

passed := 0, failed := 0
Expect(name, got, want) {
    global passed, failed
    if (String(got) == String(want))
        passed++
    else
        failed++, Say("FAIL " name ": got <" Vis(got) "> want <" Vis(want) ">")
}
; CR and LF shown SEPARATELY. Collapsing both to one glyph made a real CRLF-vs-LF
; failure print as `got <x> want <x>` — identical text, and no way to see why.
Vis(s) {
    return StrReplace(StrReplace(String(s), "`r", Chr(0x240D)), "`n", Chr(0x2424))
}
Truthy(name, got) {
    Expect(name, got ? 1 : 0, 1)
}
; The parser writes into edit controls, which want CRLF — so a round-trip
; comparison normalises rather than pretending the parser is wrong to do it.
LF(s) {
    return StrReplace(String(s), "`r`n", "`n")
}

; ── building a tree by hand ───────────────────────────────────────────────────
MassN(id, text)  => Map("id", id, "kind", "mass",  "text", text)
SayN(id, text)   => Map("id", id, "kind", "say",   "text", text)
ReplyN(id, lbl)  => Map("id", id, "kind", "reply", "label", lbl)
PpvN(id, text)   => Map("id", id, "kind", "ppv",   "text", text)
Edge(a, b)       => Map("from", a, "to", b)
Tree(nodeArr, edgeArr) => Map("nodes", nodeArr, "edges", edgeArr)

; A straight chain a → b → c → …, for the many tests that need no fork.
Chain(items*) {
    es := []
    Loop items.Length - 1
        es.Push(Edge(items[A_Index]["id"], items[A_Index + 1]["id"]))
    ns := []
    for _, n in items
        ns.Push(n)
    return Tree(ns, es)
}

; ═══ 1. the flow this feature was asked for ═══════════════════════════════════
;   !mm → fan replies → "Now imagine…" → fan replies → "So you can reveal…"
;                                                      "Might as well…"
tr := Chain(
    MassN("n1", "hey you up?"),
    ReplyN("n2", "replies"),
    SayN("n3", "Now imagine if I let you snatch that bra off me"),
    ReplyN("n4", "keen"),
    SayN("n5", "So you can reveal all of my explicitness"
             . "`nMight as well take the panties off while we're there riiight?"))
comp := BR_Compile(tr)
Truthy("flow compiles",       comp["ok"])
Expect("flow paths",          comp["paths"], 1)
Expect("flow mass",           comp["record"]["mass"],  "hey you up?")
Expect("flow f1",             comp["record"]["fu1"],   "Now imagine if I let you snatch that bra off me")
Expect("flow f2",             comp["record"]["fu2"],   "So you can reveal all of my explicitness")
Expect("flow f2.5",           comp["record"]["fu2_5"], "Might as well take the panties off while we're there riiight?")
Expect("flow no branches",    comp["record"]["br1_name"], "")
; a fan-reply node must NOT consume a follow-up level — the whole reason it is
; its own kind. Two replies in this chain, and f3 is still free.
Expect("reply costs no depth", comp["record"]["fu3"], "")

; ═══ 2. a fork becomes a named branch ═════════════════════════════════════════
tr := Tree([
    MassN("m",  "opener"),
    ReplyN("r1", "plays along"), SayN("a1", "trunk f1"), SayN("a2", "trunk f2"),
    ReplyN("r2", "goes shy"),    SayN("b1", "shy f1"),   SayN("b2", "shy f2")],
   [Edge("m","r1"), Edge("r1","a1"), Edge("a1","a2"),
    Edge("m","r2"), Edge("r2","b1"), Edge("b1","b2")])
comp := BR_Compile(tr)
Truthy("fork compiles",   comp["ok"])
Expect("fork paths",      comp["paths"], 2)
; The FIRST drawn route is the trunk, so "plays along" is f1/f2 and the SECOND
; route is the one that becomes br1. Traversal order must not decide this.
Expect("trunk f1",        comp["record"]["fu1"], "trunk f1")
Expect("trunk f2",        comp["record"]["fu2"], "trunk f2")
Expect("branch name",     comp["record"]["br1_name"], "goes-shy")
Expect("branch f1",       comp["record"]["br1_fu1"], "shy f1")
Expect("branch f2",       comp["record"]["br1_fu2"], "shy f2")

; ═══ 3. branch names are slugs — `::name` splits on whitespace ════════════════
tr := Tree([MassN("m","o"), ReplyN("r1","A"), SayN("a","x"),
                            ReplyN("r2","  Goes   SHY!! "), SayN("b","y")],
           [Edge("m","r1"), Edge("r1","a"), Edge("m","r2"), Edge("r2","b")])
comp := BR_Compile(tr)
Expect("slug", comp["record"]["br1_name"], "goes-shy")
Truthy("slug has no space", !InStr(comp["record"]["br1_name"], " "))

; an unnamed reply still yields a usable name
tr := Tree([MassN("m","o"), ReplyN("r1",""), SayN("a","x"),
                            ReplyN("r2",""), SayN("b","y")],
           [Edge("m","r1"), Edge("r1","a"), Edge("m","r2"), Edge("r2","b")])
comp := BR_Compile(tr)
Expect("unnamed branch", comp["record"]["br1_name"], "br1")

; ═══ 4. a route too deep is REPORTED, not truncated ═══════════════════════════
comp := BR_Compile(Chain(MassN("m","o"), SayN("a","1"), SayN("b","2"),
                        SayN("c","3"), SayN("d","4")))
Expect("too deep fails",     comp["ok"] ? 1 : 0, 0)
Truthy("too deep explains",  comp["errors"].Length > 0)
Truthy("names the count",    InStr(comp["errors"][1], "4") > 0)

; three is fine
comp := BR_Compile(Chain(MassN("m","o"), SayN("a","1"), SayN("b","2"), SayN("c","3")))
Truthy("three deep is fine", comp["ok"])
Expect("f3", comp["record"]["fu3"], "3")

; ═══ 5. more forks than a mass has branches ═══════════════════════════════════
nodeList := [MassN("m", "o")]
edgeList := []
Loop MASS_BRANCH_MAX + 3 {
    bi := A_Index
    nodeList.Push(ReplyN("r" bi, "route" bi))
    nodeList.Push(SayN("s" bi, "text" bi))
    edgeList.Push(Edge("m", "r" bi))
    edgeList.Push(Edge("r" bi, "s" bi))
}
comp := BR_Compile(Tree(nodeList, edgeList))
Expect("too many branches fails", comp["ok"] ? 1 : 0, 0)
Truthy("says how many routes",    InStr(comp["errors"][1], "routes") > 0)

; exactly trunk + MASS_BRANCH_MAX is the boundary, and must PASS
nodeList := [MassN("m", "o")]
edgeList := []
Loop MASS_BRANCH_MAX + 1 {
    bi := A_Index
    nodeList.Push(ReplyN("r" bi, "route" bi))
    nodeList.Push(SayN("s" bi, "text" bi))
    edgeList.Push(Edge("m", "r" bi))
    edgeList.Push(Edge("r" bi, "s" bi))
}
comp := BR_Compile(Tree(nodeList, edgeList))
Truthy("trunk + 6 branches is fine", comp["ok"])
Expect("last branch filled",
       comp["record"]["br" MASS_BRANCH_MAX "_fu1"], "text" (MASS_BRANCH_MAX + 1))

; ═══ 6. a malformed tree is refused, not guessed at ═══════════════════════════
comp := BR_Compile(Tree([SayN("a","x")], []))
Expect("no opener fails", comp["ok"] ? 1 : 0, 0)

comp := BR_Compile(Tree([MassN("m1","a"), MassN("m2","b")], []))
Expect("two openers fails", comp["ok"] ? 1 : 0, 0)

; a cycle must end in an error, not a hang
comp := BR_Compile(Tree([MassN("m","o"), SayN("a","1"), SayN("b","2")],
                       [Edge("m","a"), Edge("a","b"), Edge("b","a")]))
Expect("cycle fails", comp["ok"] ? 1 : 0, 0)
Truthy("cycle explained", InStr(comp["errors"][1], "loops") > 0)

; ═══ 7. merging — a shared tail lands in BOTH columns ═════════════════════════
;  Storage duplicates it; the tree keeps it as one node, so you still edit it once.
tr := Tree([
    MassN("m","o"),
    ReplyN("r1","yes"), SayN("a","yes f1"),
    ReplyN("r2","no"),  SayN("b","no f1"),
    SayN("tail","same ending for both")],
   [Edge("m","r1"), Edge("r1","a"), Edge("a","tail"),
    Edge("m","r2"), Edge("r2","b"), Edge("b","tail")])
comp := BR_Compile(tr)
Truthy("merge compiles", comp["ok"])
Expect("merge paths",    comp["paths"], 2)
Expect("trunk tail",     comp["record"]["fu2"],     "same ending for both")
Expect("branch tail",    comp["record"]["br1_fu2"], "same ending for both")

; ═══ 8. a step with more lines than parts keeps them all ══════════════════════
comp := BR_Compile(Chain(MassN("m","o"), SayN("a", "one`ntwo`nthree`nfour")))
Expect("part 1", comp["record"]["fu1"],   "one")
Expect("part 2", comp["record"]["fu1_5"], "two")
Truthy("4th line not lost", InStr(comp["record"]["fu1_7"], "four") > 0)

; ═══════════════════════════════════════════════════════════════════════════════
;  9. THE ROUND TRIP — through the shipping parser
; ═══════════════════════════════════════════════════════════════════════════════
;  Everything above tests what the compiler believes. This tests whether MMA
;  agrees, which is the only claim the builder actually makes.

class FakeEdit {
    Value := ""
}
global edCtrls := Map()
global AHK_CHARS := ["``", Chr(34), ";"]
global PREFIX_EXCEPTIONS := Map("http",1, "https",1, "ftp",1, "ftps",1,
                                "mailto",1, "tel",1, "file",1)
global keyMap := Map(
    "!mm",    "mass",    "!mma",   "mass",    "mm",     "mass",    "mma",    "mass",
    "f1",     "fu1",     "f1.5",   "fu1_5",   "f1.7",   "fu1_7",
    "f2",     "fu2",     "f2.5",   "fu2_5",   "f2.7",   "fu2_7",
    "f3",     "fu3",     "f3.5",   "fu3_5",   "f3.7",   "fu3_7",
    "ppv",    "ppv_base",
    "ppvfu1", "ppv_f1",  "ppvfu2", "ppv_f2",  "ppvfu3", "ppv_f3")

#Include "../../src/mass/parser.ahk"

Reparse(text) {
    global edCtrls
    edCtrls := Map()
    for f in MASS_Fields()
        edCtrls["m1_" f] := FakeEdit()
    FillTab(StrSplit(StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n"), "`n"), 1)
}
Field(f) {
    global edCtrls
    return edCtrls.Has("m1_" f) ? edCtrls["m1_" f].Value : "(missing)"
}

; the flow from the top of this file, plus a fork and a PPV
tr := Tree([
    MassN("m",  "hey you up?"),
    ReplyN("r1","keen"),
    SayN("a1",  "Now imagine if I let you snatch that bra off me"),
    SayN("a2",  "So you can reveal all of my explicitness"
              . "`nMight as well take the panties off while we're there riiight?"),
    ReplyN("r2","goes shy"),
    SayN("b1",  "no rush babe"),
    PpvN("p",   "unlock this one")],
   [Edge("m","r1"), Edge("r1","a1"), Edge("a1","a2"), Edge("a2","p"),
    Edge("m","r2"), Edge("r2","b1")])
comp := BR_Compile(tr)
Truthy("rt compiles", comp["ok"])

emitted := BR_EmitText(comp["record"])
Reparse(emitted)

Expect("rt mass",    LF(Field("mass")), "hey you up?")
Expect("rt f1",      Field("fu1"),      "Now imagine if I let you snatch that bra off me")
Expect("rt f2",      Field("fu2"),      "So you can reveal all of my explicitness")
Expect("rt f2.5",    Field("fu2_5"),    "Might as well take the panties off while we're there riiight?")
Expect("rt ppv",     LF(Field("ppv_base")), "unlock this one")
Expect("rt br name", Field("br1_name"), "goes-shy")
Expect("rt br f1",   Field("br1_fu1"),  "no rush babe")

; ── the sparse case, which is why the emitter labels every line ──────────────
;  f1 and f3 with NO f2. In positional form this is two groups and the second
;  one parses back as f2 — the message moves. Labelled, the gap costs nothing.
;  Masses are legitimately sparse, so this is the normal case, not an edge one.
blank := MASS_Blank()
blank["mass"] := "opener"
blank["fu1"]  := "first"
blank["fu3"]  := "third"
Reparse(BR_EmitText(blank))
Expect("sparse f1", Field("fu1"), "first")
Expect("sparse f2", Field("fu2"), "")
Expect("sparse f3", Field("fu3"), "third")

; ── a multi-line mass survives the marker line ──────────────────────────────
blank := MASS_Blank()
blank["mass"] := "line one`n`nline two"
blank["fu1"]  := "after it"
Reparse(BR_EmitText(blank))
Expect("multiline mass", LF(Field("mass")), "line one`n`nline two")
Expect("fu after fence", Field("fu1"),      "after it")

Say(passed " passed, " failed " failed")
ExitApp(failed ? 1 : 0)
