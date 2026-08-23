#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "../vendor/json.ahk"
#Include "../mass/store.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  tree.ahk — the conversation tree the branch builder draws, and the one thing
;  that turns it back into a mass.
; ───────────────────────────────────────────────────────────────────────────────
;  ── The insight this whole feature rests on ─────────────────────────────────
;  A branch in masses.json is NOT a tree. `::mexican` is a parallel WORDING of
;  f1/f2/f3 that TAB cycles through at send time — six columns beside the trunk,
;  no forking, no notion of what the fan said.
;
;  A conversation IS a tree, and it alternates:
;
;      !mm  →  fan replies  →  f1  →  fan replies  →  f2  →  f3
;
;  Those two shapes meet at exactly one place, and it is the reason this file is
;  short:
;
;      ONE ROOT-TO-LEAF PATH THROUGH THE TREE  =  ONE NAMED BRANCH.
;
;  Walk the tree, enumerate every path, and each path is a complete conversation
;  — a full f1/f2/f3/ppv column. The first path is the trunk; the rest are named
;  branches. Nothing in the engine has to change, nothing in the parser has to
;  change, and the format the builder emits is the format `Export !mma` already
;  writes today.
;
;  ── What a fan-reply node is for, given it sends nothing ────────────────────
;  It carries no message and it does not consume a follow-up level. It does two
;  jobs, and both are real:
;
;    * it NAMES the branch. `::plays-along` beats `::br2` when you are staring at
;      a picker window mid-shift trying to remember which is which.
;    * it is the only place the tree records WHY the fork exists. A branch whose
;      reason is not written down is a branch nobody dares delete.
;
;  ── Depth is the constraint, and it is hard ─────────────────────────────────
;  A path may hold at most MASS_FU_DEPTH `say` nodes, because there are exactly
;  three follow-up groups to put them in, and at most MASS_BRANCH_MAX branches
;  beside the trunk. Both are REPORTED, never silently truncated — a builder that
;  quietly drops the fourth message is a builder that loses work, and ARCHITECTURE
;  §4.8's rule applies just as much here as it does to a detector: the cost of
;  "no answer" is a message you have to move yourself, and the cost of a
;  confident wrong answer is a chain that sends three of its four steps.
;
;  ── Merging ─────────────────────────────────────────────────────────────────
;  Two paths that converge on one node duplicate that node's text into both
;  branches, which is correct: a branch stores its whole column, so the shared
;  tail has to appear in each. The tree keeps the fact that it was ONE node, so
;  editing the merge point still edits it once. That is the whole benefit —
;  storage duplicates, editing does not.
; ═══════════════════════════════════════════════════════════════════════════════

global BR_FILE       := MMA_USERDATA "\branch_trees.json"
global BR_SCHEMA     := 1
; How many `say` nodes one path may hold: f1, f2, f3. Named rather than written
; as `3` at each of its four use sites, because it is the same 3 as MASS_SLOTS
; and MASS_FU_PARTS and it is NOT the same number as either of them.
global MASS_FU_DEPTH := 3

; ═══════════════════════════════════════════════════════════════════════════════
;  Storage
; ═══════════════════════════════════════════════════════════════════════════════

BR_Default() {
    return Map("schema", BR_SCHEMA, "trees", [])
}

; Never throws. A corrupt tree file is kept, not overwritten — same rule as
; mass/store.ahk, and for the same reason: a text editor can still recover work
; that an empty replacement has destroyed.
BR_Load() {
    if !FileExist(BR_FILE) {
        LOGV("br.load", "no branch_trees.json yet — starting empty")
        return BR_Default()
    }
    try {
        raw := FileRead(BR_FILE, "UTF-8")
        if (SubStr(raw, 1, 1) = Chr(0xFEFF))
            raw := SubStr(raw, 2)
        doc := JSON.Parse(raw)
    } catch as e {
        bak := BR_FILE ".broken-" FormatTime(, "yyyyMMdd-HHmmss")
        try FileCopy(BR_FILE, bak, true)
        LOGE("br.load", "branch_trees.json is not valid JSON — started empty and"
                      . " kept a copy of the broken file", LOG_Err(e) "   copy: " bak)
        return BR_Default()
    }
    if !(doc is Map) || !doc.Has("trees") || !(doc["trees"] is Array) {
        LOGW("br.load", "branch_trees.json has no trees array — treated as empty")
        return BR_Default()
    }
    return doc
}

BR_Save(doc) {
    try {
        doc["schema"] := BR_SCHEMA
        FileOpen(BR_FILE, "w", "UTF-8").Write(JSON.Stringify(doc, "  ")).Close()
        LOGV("br.save", "wrote " doc["trees"].Length " tree(s)")
        return true
    } catch as e {
        LOGE("br.save", "could not write branch_trees.json — the tree you are"
                      . " editing is NOT saved", LOG_Err(e))
        return false
    }
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Walking
; ═══════════════════════════════════════════════════════════════════════════════

_BR_NodeMap(tree) {
    m := Map()
    for _, n in tree["nodes"]
        m[n["id"]] := n
    return m
}

_BR_ChildMap(tree) {
    m := Map()
    for _, e in tree["edges"] {
        f := e["from"]
        if !m.Has(f)
            m[f] := []
        m[f].Push(e["to"])
    }
    return m
}

_BR_Kind(node) {
    return node.Has("kind") ? node["kind"] : "say"
}
_BR_Text(node) {
    return node.Has("text") ? node["text"] : ""
}
_BR_Label(node) {
    return node.Has("label") ? node["label"] : ""
}

; The root: the one `mass` node. Reported rather than guessed at — a tree with
; two roots is a tree the builder let you build wrong, and picking one silently
; would compile half your work.
BR_Root(tree) {
    found := ""
    for _, n in tree["nodes"] {
        if (_BR_Kind(n) = "mass") {
            if (found != "")
                return ""              ; more than one — caller reports it
            found := n["id"]
        }
    }
    return found
}

; Every root-to-leaf path, as arrays of node ids.
;
; Depth-first, and deliberately iterative rather than recursive: a cycle in the
; graph would blow the stack, and this returns an error instead. The builder
; cannot draw a cycle, but a hand-edited file can hold one and this is the layer
; that reads hand-edited files.
BR_Paths(tree, &err) {
    err := ""
    root := BR_Root(tree)
    if (root = "") {
        err := "the tree needs exactly one opening message (!mm) — it has "
             . _BR_CountKind(tree, "mass")
        return []
    }
    kids := _BR_ChildMap(tree)
    out  := []
    ; stack of {path: [...ids], seen: Map(id->1)}
    stack := [Map("path", [root], "seen", Map(root, 1))]
    guard := 0
    while (stack.Length) {
        cur  := stack.Pop()
        path := cur["path"]
        last := path[path.Length]
        if (++guard > 20000) {
            err := "this tree has too many paths through it to compile — simplify"
                 . " it, or split it into two masses"
            return []
        }
        if !kids.Has(last) || !kids[last].Length {
            out.Push(path)
            continue
        }
        for _, childId in kids[last] {
            if cur["seen"].Has(childId) {
                err := "the tree loops back on itself, so it has no end — remove"
                     . " the connection that goes backwards"
                return []
            }
            np := path.Clone()
            np.Push(childId)
            ns := Map()
            for k, v in cur["seen"]
                ns[k] := v
            ns[childId] := 1
            stack.Push(Map("path", np, "seen", ns))
        }
    }
    ; Pop order reverses the branches relative to how they were drawn, and which
    ; path lands on the trunk is the most visible decision this file makes — so
    ; the order is restored rather than left to the traversal.
    _BR_ReversePaths(out)
    return out
}

_BR_ReversePaths(arr) {
    i := 1, j := arr.Length
    while (i < j) {
        tmp := arr[i], arr[i] := arr[j], arr[j] := tmp
        i++, j--
    }
}

_BR_CountKind(tree, kind) {
    n := 0
    for _, node in tree["nodes"]
        if (_BR_Kind(node) = kind)
            n++
    return n
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Compiling — the tree becomes one mass record
; ═══════════════════════════════════════════════════════════════════════════════

; A path's branch name, from the fan replies along it: "plays along → shy"
; becomes `plays-along`. The FIRST reply is what names it — that is the fork the
; branch is actually about, and a name made of every reply joined together is
; too long to read on a picker button.
_BR_PathName(path, nodes, index) {
    for _, id in path {
        n := nodes[id]
        if (_BR_Kind(n) = "reply") {
            lbl := Trim(_BR_Label(n))
            if (lbl != "")
                return _BR_Slug(lbl)
        }
    }
    return "br" index
}

; A branch name has to survive being written as `::name text` and read back, so
; it cannot contain whitespace — BranchMarker in mass/parser.ahk splits on it.
_BR_Slug(s) {
    out := ""
    for _, ch in StrSplit(s) {
        if InStr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", ch)
            out .= ch
        else if (ch = " " || ch = "-" || ch = "_")
            out .= "-"
    }
    out := Trim(out, "-")
    while InStr(out, "--")
        out := StrReplace(out, "--", "-")
    return (out = "") ? "br" : StrLower(out)
}

; One path → {says: [text,…], ppv: text, name: "…"}.
_BR_PathColumn(path, nodes) {
    says := [], ppv := ""
    for _, id in path {
        n := nodes[id]
        k := _BR_Kind(n)
        if (k = "say")
            says.Push(_BR_Text(n))
        else if (k = "ppv")
            ppv := _BR_Text(n)
    }
    return Map("says", says, "ppv", ppv)
}

; The whole compile. Returns
;     {ok, record, warnings: [...], errors: [...], paths: n, trunk: name}
;
; `record` is a MASS_Blank() filled in, ready for MASS_Set — the same shape the
; GUI edits, so nothing downstream knows this file exists.
BR_Compile(tree) {
    res := Map("ok", false, "record", MASS_Blank(), "warnings", [], "errors", [],
               "paths", 0, "trunk", "")
    if !(tree is Map) || !tree.Has("nodes") || !tree.Has("edges") {
        res["errors"].Push("that is not a tree")
        return res
    }
    nodes := _BR_NodeMap(tree)
    paths := BR_Paths(tree, &err)
    if (err != "") {
        res["errors"].Push(err)
        return res
    }
    if !paths.Length {
        res["errors"].Push("the tree has no complete path from the opener to an end")
        return res
    }

    rec  := MASS_Blank()
    root := BR_Root(tree)
    rec["mass"] := _BR_Text(nodes[root])
    if (Trim(rec["mass"]) = "")
        res["warnings"].Push("the opening message (!mm) is empty")

    res["paths"] := paths.Length
    used := Map()               ; branch names already taken
    brNo := 0

    for pi, path in paths {
        col  := _BR_PathColumn(path, nodes)
        says := col["says"]

        if (says.Length > MASS_FU_DEPTH) {
            ; Named, counted, and NOT truncated silently. This is the one failure
            ; a builder can hand you that looks like success.
            res["errors"].Push("one route sends " says.Length " messages after the"
                             . " opener, and a mass has room for " MASS_FU_DEPTH
                             . " (f1, f2, f3). Shorten that route, or move the tail"
                             . " into a second mass.")
            continue
        }

        if (pi = 1) {
            ; The first path is the trunk — the route taken when nothing special
            ; happened, which is what f1/f2/f3 mean.
            res["trunk"] := "trunk"
            for si, txt in says
                _BR_SetTrunkGroup(rec, si, txt)
            rec["ppv_base"] := col["ppv"]
            continue
        }

        brNo++
        if (brNo > MASS_BRANCH_MAX) {
            res["errors"].Push("the tree has " paths.Length " routes, and a mass"
                             . " holds a trunk plus " MASS_BRANCH_MAX " branches."
                             . " Remove a fork, or split this into two masses.")
            break
        }
        name := _BR_PathName(path, nodes, brNo)
        if used.Has(name) {
            ; Two forks answering the same fan reply would otherwise merge into
            ; one branch at send time and silently lose one of them.
            n2 := name "-" brNo
            res["warnings"].Push("two routes are both called '" name "' — the"
                               . " second is now '" n2 "'")
            name := n2
        }
        used[name] := 1
        rec["br" brNo "_name"] := name
        for si, txt in says
            rec["br" brNo "_fu" si] := _BR_Joined(txt)
        rec["br" brNo "_ppv"] := _BR_Joined(col["ppv"])
    }

    res["record"] := rec
    res["ok"] := (res["errors"].Length = 0)
    return res
}

; A trunk follow-up group holds three SEPARATE fields (f1 / f1.5 / f1.7); a
; branch holds one newline-joined field. Same three messages, two storage shapes
; — that asymmetry is in store.ahk, not invented here.
_BR_SetTrunkGroup(rec, grp, text) {
    parts := MASS_SplitParts(text)
    suffix := ["", "_5", "_7"]
    Loop MASS_FU_PARTS {
        rec["fu" grp suffix[A_Index]] := (A_Index <= parts.Length) ? parts[A_Index] : ""
    }
    if (parts.Length > MASS_FU_PARTS) {
        ; The 4th line of a step has nowhere to go. Folded onto the last part
        ; rather than dropped — losing a line the user typed is worse than a
        ; long third message, and the builder warns about it separately.
        extra := ""
        Loop parts.Length - MASS_FU_PARTS
            extra .= "`n" parts[MASS_FU_PARTS + A_Index]
        rec["fu" grp "_7"] .= extra
    }
}

_BR_Joined(text) {
    parts := MASS_SplitParts(text)
    out := ""
    for _, p in parts
        out .= (out = "" ? "" : "`n") p
    return out
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Emitting — the record as pasteable !mma text
; ═══════════════════════════════════════════════════════════════════════════════
;  LABELLED form (`f1`, `f1.5`, `ppv`), not the positional form ExportMMA writes.
;  Positional routes by ORDER, and masses are legitimately sparse — an f1+f3 mass
;  with no f2 has two groups, and the second one parses back as f2. A generated
;  artifact must not depend on the reader counting blank lines correctly, so
;  every line here carries its own field name and gaps cost nothing.
BR_EmitText(rec) {
    out := ""
    mass := _BR_Norm(rec["mass"])
    if (mass != "") {
        ; A multi-line mass cannot ride the marker line — the line ends at the
        ; first break and the rest comes back as follow-ups. Block form, closed
        ; with a fence so what follows is still read as follow-ups.
        out .= InStr(mass, "`n") ? "!mma`n" mass "`n---`n" : "!mma " mass "`n"
    }

    suffix := ["", ".5", ".7"]
    Loop MASS_FU_DEPTH {
        grp := A_Index
        Loop MASS_FU_PARTS {
            v := _BR_Norm(rec["fu" grp (A_Index = 1 ? "" : (A_Index = 2 ? "_5" : "_7"))])
            if (v != "")
                out .= "f" grp suffix[A_Index] " " v "`n"
        }
        out .= _BR_BranchLines(rec, "fu" grp)
    }

    ppv := _BR_Norm(rec["ppv_base"])
    ppvBr := _BR_BranchLines(rec, "ppv")
    if (ppv != "" || ppvBr != "") {
        if (ppv != "")
            out .= InStr(ppv, "`n") ? "ppv " ppv "`n---`n" : "ppv " ppv "`n"
        else
            out .= "ppv`n"
        out .= ppvBr
    }
    Loop 3 {
        v := _BR_Norm(rec["ppv_f" A_Index])
        if (v != "")
            out .= "ppvfu" A_Index " " v "`n"
    }
    return Trim(out, "`n")
}

_BR_BranchLines(rec, grp) {
    out := ""
    Loop MASS_BRANCH_MAX {
        k  := A_Index
        nm := Trim(rec["br" k "_name"])
        if (nm = "")
            nm := "br" k
        for _, part in MASS_SplitParts(rec["br" k "_" grp])
            out .= "::" nm " " part "`n"
    }
    return out
}

_BR_Norm(s) {
    return Trim(StrReplace(StrReplace(s, "`r`n", "`n"), "`r", "`n"), "`n `t")
}
