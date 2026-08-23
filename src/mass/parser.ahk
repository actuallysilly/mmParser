#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/parser.ahk — the mass text format: parse it, and escape it back out.
; ───────────────────────────────────────────────────────────────────────────────
;  Turns a pasted mass (the !mm / f1 / `::branch` shorthand) into the tab fields,
;  and escapes strings on the way back into a model .ahk file.
;
;  ONE marker for alternatives: `::name text`. It replaced two — `alt:` / `alt0:`
;  for another wording of this follow-up, and a `--Name` block for a whole
;  alternate sequence — which were two spellings of the same question. See
;  BranchMarker below, and the record-shape note in mass/store.ahk.
;
;  FillTab is the entry point; PositionalGroups decides which lines belong to
;  which follow-up when the paste has no explicit prefixes. EscQ/UnescQ are the
;  serialiser half — BuildBlock in main_window.ahk writes what EscQ produces.
;
;  Kept apart from the GUI so the format has one definition. Included by
;  main_window.ahk and shares its globals.
; ═══════════════════════════════════════════════════════════════════════════════

EscQ(s) {
    for _, ch in AHK_CHARS
        s := StrReplace(s, ch, "``" ch)
    return s
}

StripPrefix(s) {
    global PREFIX_EXCEPTIONS
    if RegExMatch(s, "i)^[Ff][Uu]?\s?\d+(?:\.\d+)?[:\s]+", &m)
        return SubStr(s, m.Len + 1)
    if RegExMatch(s, "^\S+:(?![)(])\s*", &m) {
        scheme := SubStr(s, 1, InStr(s, ":") - 1)   ; word before the first colon
        if PREFIX_EXCEPTIONS.Has(StrLower(scheme))  ; e.g. https:  → leave the URL intact
            return s
        return SubStr(s, m.Len + 1)
    }
    return s
}

; Does this line carry a label of its OWN — an exact field name, an f-prefix, a
; `ppv` marker or a `::branch`? MassHeaderBlock uses it to know where a bare
; `!mma` block stops: a labelled line is the next field, never more of the mass.
LabelledLine(s) {
    global keyMap
    t := Trim(s)
    if RegExMatch(t, "^(\S+)", &m) && keyMap.Has(StrLower(m[1]))
        return true
    if RegExMatch(t, "i)^[Ff][Uu]?\s?\d+(?:\.\d+)?[:\s]")
        return true
    if RegExMatch(t, "i)^ppv([:\s]|$)")
        return true
    if BranchMarker(t)
        return true
    return false
}

; ── `!mma` ALONE on its line: everything under it is the mass ─────────────────
;  The header form, which is how a long mass actually gets written:
;
;      !mma:
;
;      If you were my artist, how would you picture me? 🎨
;
;      Would my curves take over the entire canvas...
;      Or would you only sketch the parts you couldn't stop thinking about? :3
;
;      Would your artwork be bold enough to leave people speechless? ♡
;
;  That is ONE message — paragraph breaks and all. Every other form puts the mass
;  ON the marker line, so a marker with nothing after it set the mass to "" and
;  left the paragraphs to positional mode, which read them as f1, f2 and f3 and
;  dropped the fourth. The mass went out in pieces, as follow-ups, or not at all.
;
;  Where the block ENDS, in order:
;    * a `---` fence, which is eaten with the block — write one when follow-ups
;      come after the mass, since they have no label to stop the block themselves
;    * a labelled line (a field name, an f-prefix, `ppv`, or a `::branch`), which
;      is the next field's and is left for the rest of the parse
;    * the end of the paste
;
;  Blank lines INSIDE are kept as paragraph breaks; leading and trailing ones go.
;
;  Returns {text, rest} — `rest` is the paste with the header and its block
;  removed, for the ordinary modes to carry on with — or 0 when no bodiless
;  marker is there.
MassHeaderBlock(lines) {
    hi := 0
    for i, rawLn in lines {
        if RegExMatch(Trim(rawLn), "i)^!?mm[a]?\s*:?\s*$") {
            hi := i
            break
        }
    }
    if !hi
        return 0

    block := []
    stop  := lines.Length + 1
    i := hi
    while ++i <= lines.Length {
        t := Trim(lines[i])
        if RegExMatch(t, "^-{3,}$") {
            stop := i + 1              ; the fence closes the block and goes with it
            break
        }
        if (t != "" && LabelledLine(t)) {
            stop := i                  ; that line names a field — leave it alone
            break
        }
        block.Push(t)
    }

    while block.Length && block[1] = ""
        block.RemoveAt(1)
    while block.Length && block[block.Length] = ""
        block.RemoveAt(block.Length)

    text := ""
    for _, l in block
        text .= (A_Index = 1 ? "" : "`r`n") l

    rest := []
    for ri, rawLn in lines
        if (ri < hi || ri >= stop)
            rest.Push(rawLn)
    return {text: text, rest: rest}
}

UnescQ(s) {
    s := StrReplace(s, Chr(96) Chr(34), Chr(34))
    s := StrReplace(s, Chr(96) Chr(59), Chr(59))
    s := StrReplace(s, Chr(96) Chr(96), Chr(96))
    return s
}

; Maps an f-prefix line to a slot name: "fu1", "fu2_5", "fu3_7", etc.
; Returns "" if the line doesn't start with a recognised f-prefix.
FPrefixToSlot(s) {
    if !RegExMatch(s, "i)^[Ff][Uu]?\s?(\d+)(?:\.(\d+))?[:\s]", &m)
        return ""
    n := m[1]
    d := m[2]
    if d = ""
        return "fu" n
    if SubStr(d, 1, 1) = "5"
        return "fu" n "_5"
    if SubStr(d, 1, 1) = "7"
        return "fu" n "_7"
    return ""
}

; Blank-line-separated groups, honouring `---` multiline fences. Returns
; {groups, fenced}: `fenced` maps a group index → true when that group is a
; fenced multiline block (its internal blanks are kept as paragraph breaks and it
; must go to ppv_base, never a ppv follow-up). Shared by the trunk parser and
; FillBranch so both split text the same way.
PositionalGroups(filtered) {
    groups := [], cur := []
    groupStart := []
    fenced := Map()
    curStart := 0
    prevFenceEnd := 0
    fi := 0
    while fi < filtered.Length {
        fi++
        t := filtered[fi]
        if RegExMatch(t, "^-{3,}$") {
            gatherStart := prevFenceEnd + 1
            gs := fi - 1
            while gs > prevFenceEnd {
                if RegExMatch(filtered[gs], "i)^ppv") {
                    gatherStart := gs
                    break
                }
                gs--
            }
            while groups.Length && groupStart[groups.Length] >= gatherStart {
                groups.Pop()
                groupStart.Pop()
            }
            cur := [], curStart := 0
            block := []
            Loop fi - gatherStart
                block.Push(filtered[gatherStart + A_Index - 1])
            while block.Length && block[1] = ""
                block.RemoveAt(1)
            while block.Length && block[block.Length] = ""
                block.RemoveAt(block.Length)
            if block.Length {
                groups.Push(block)
                groupStart.Push(gatherStart)
                fenced[groups.Length] := true
            }
            prevFenceEnd := fi
            continue
        }
        if t = "" {
            if cur.Length {
                groups.Push(cur)
                groupStart.Push(curStart)
                cur := [], curStart := 0
            }
            continue
        }
        if !cur.Length
            curStart := fi
        cur.Push(t)
    }
    if cur.Length {
        groups.Push(cur)
        groupStart.Push(curStart)
    }
    return {groups: groups, fenced: fenced}
}

; ── `::name` — the one marker for every alternative ───────────────────────────
;  A line that opens with `::` belongs to a BRANCH rather than to the trunk:
;
;      follow up 1
;      ::alt folow up 1 alternative
;      ::mexican mehico
;      ::german germaniaaaaa
;      ::german gernabiaaa22222
;
;  "alt" is not special. It is simply the branch name you use when the wording has
;  no better name, which is why the old `alt:` / `alt0:` syntax and the old
;  `--Name` block syntax could both go: they were two spellings of this.
;
;  A branch keeps its identity by NAME across the whole mass, so the `::mexican`
;  under follow-up 2 is the same branch as the one under follow-up 1 — that is
;  what makes picking it at f1 commit you to it at f2 and f3.
;
;  Repeating a name inside ONE group adds the next PART, not another choice:
;  `::german` twice is one branch answering f1 with two messages (f1 then f1.5),
;  exactly as two unmarked lines are the trunk's f1 and f1.5. Capped at
;  MASS_FU_PARTS, since there are only three sub-slots to send them into.
;
;  ── a marker ALONE on its line owns the lines under it ──────────────────────
;  Both of these mean the same thing, and they have to, because the second is how
;  a person actually writes a mass — the wording is a sentence, not a label's
;  argument:
;
;      ::tits Would you mind if I smothered you with them?
;
;      ::tits
;      Would you mind if I smothered you with them?
;
;  The second form did not parse. `::tits` with nothing after it was read as "this
;  branch has nothing to say here" (a no-op), and the sentence under it fell
;  through to the TRUNK — so the branch was empty and the trunk's follow-up
;  silently became one branch's wording. Sent to a real fan, that is the wrong
;  message with no error anywhere.
;
;  So an empty marker now CAPTURES: every unmarked line under it, until the next
;  marker or the end of the group, is that branch's answer — each line a further
;  part, exactly as repeating the marker would give. See `curBr` in the three
;  parse modes below.
;
;  What was lost is the old empty-marker no-op, and nothing needs it: a branch
;  that says nothing in a group is written by simply not naming it there, and
;  AddBranchPart / the sender already treat a missing group as "skip", not as
;  silence to send.
;
;  Returns {name, body} for a marker line, or 0 for anything else. `::` alone, or
;  `:: ` with no name, is not a marker — it would open a branch with no identity.
BranchMarker(line) {
    if !RegExMatch(Trim(line), "^::\s*([^\s:][^\s]*)\s*(.*)$", &m)
        return 0
    return {name: Trim(m[1]), body: Trim(m[2])}
}

; One line of a group, routed to either a branch or the trunk.
;
; `curBr` is the branch an empty marker opened, carried BY REFERENCE so the three
; parse modes share one rule instead of three copies of it. Returns true when the
; line was consumed as part of a branch (marker or captured line), false when it is
; the trunk's and the caller should place it in the next sub-slot.
;
; `grp` is "fu1".."fu3" or "ppv" — the group the branch is answering. "" means the
; paste put a marker before there was anything for it to be an alternative TO,
; which is dropped with a warning rather than attached to a guess.
;
; `labelled` is for the keyword and prefix modes: a line carrying its own `f2` /
; `ppv` label belongs to that label, so it ENDS the capture instead of being
; swallowed by it. Without that, one `::tits` above an `f2` line ate the rest of the
; paste — every following line, labels and all, went into the branch and every field
; below it came out empty.
BranchLine(reg, t, grp, mNo, &curBr, labelled := false) {
    mk := BranchMarker(t)
    if mk {
        if (grp = "") {
            LOGW("gui.parse", "model " mNo ": '::" mk.name "' appears before any"
                            . " follow-up or ppv line, so there is nothing for it to"
                            . " be an alternative TO — dropped")
            curBr := ""
            return true
        }
        if (mk.body != "") {
            ; Its wording was on the marker line, so it does not own what follows.
            AddBranchPart(reg, mk.name, grp, mk.body, mNo)
            curBr := ""
        } else {
            curBr := mk.name          ; the lines under it are its answer
        }
        return true
    }
    if labelled {
        curBr := ""
        return false
    }
    if (curBr != "" && grp != "") {
        AddBranchPart(reg, curBr, grp, t, mNo)
        return true
    }
    return false
}

; The slot a branch NAME occupies on this mass, creating it on first sight.
;
; `reg` is the run's registry: {order: [name, …], idx: Map(lowername → slot)}.
; Matched case-insensitively, because `::Mexican` and `::mexican` in one mass are
; a typo, not two branches — and two branches is the answer that costs a slot and
; splits one wording across two rows of the Variants window.
;
; 0 when the mass names more branches than there are slots. The caller logs it;
; dropping the seventh name is the only honest answer, and it must not silently
; land in the sixth branch's row.
BranchSlot(reg, name, mNo) {
    global MASS_BRANCH_MAX
    key := StrLower(name)
    if reg.idx.Has(key)
        return reg.idx[key]
    if (reg.order.Length >= MASS_BRANCH_MAX) {
        LOGW("gui.parse", "model " mNo ": the pasted mass names more than "
                        . MASS_BRANCH_MAX " branches — '" name "' was DROPPED."
                        . " Everything it said is missing from this mass.")
        return 0
    }
    reg.order.Push(name)
    reg.idx[key] := reg.order.Length
    ck := "m" mNo "_br" reg.order.Length "_name"
    if edCtrls.Has(ck)
        edCtrls[ck].Value := name
    return reg.order.Length
}

; Add one part to branch `name`'s answer for `grp` ("fu1".."fu3" or "ppv").
;
; Appends rather than assigns: the parts arrive one line at a time, and the field
; holds all of them newline-joined. An empty body is a no-op — `::mexican` on its
; own under follow-up 2 means "this branch has nothing extra to say here", which
; is not the same as an empty message, and an empty message is a way to send
; silence to a real fan.
AddBranchPart(reg, name, grp, body, mNo) {
    global edCtrls, MASS_FU_PARTS
    if (Trim(body) = "")
        return
    k := BranchSlot(reg, name, mNo)
    if !k
        return
    ck := "m" mNo "_br" k "_" grp
    if !edCtrls.Has(ck)
        return
    cur := Trim(edCtrls[ck].Value)
    if (cur != "" && MASS_SplitParts(cur).Length >= MASS_FU_PARTS) {
        LOGW("gui.parse", "model " mNo ": branch '" name "' already has "
                        . MASS_FU_PARTS " parts for " grp " — '"
                        . SubStr(body, 1, 30) "' was dropped, there is no fourth"
                        . " sub-slot to send it in")
        return
    }
    edCtrls[ck].Value := (cur = "") ? Trim(body) : cur "`r`n" Trim(body)
}

; The branch group a trunk field belongs to: "fu1".."fu3" for fu1/fu1_5/fu1_7,
; "ppv" for ppv_base and the ppv follow-ups, "" for the mass line.
;
; The sub-slots collapse on purpose. f2.5 is not a follow-up of its own — it is
; the second message of follow-up 2 — so a `::name` line under it is an
; alternative to the whole of follow-up 2, which is the only thing a branch can
; answer. "" is what a marker before any label gets, and it is dropped rather than
; attached to a guess.
BranchGroupOf(field) {
    if RegExMatch(field, "^fu(\d)", &m)
        return "fu" m[1]
    if (SubStr(field, 1, 3) = "ppv")
        return "ppv"
    return ""
}

; A fresh branch registry, and blank br* fields to fill.
;
; The CLEAR is not optional: parsing writes into the boxes that are already on
; screen, and a mass with no `::mexican` in it must not inherit the last mass's
; mexican branch — which is precisely how a wording gets sent for a model it was
; never written for.
NewBranchReg(mNo) {
    global edCtrls, MASS_BRANCH_MAX
    Loop MASS_BRANCH_MAX
        for _, f in MASS_BranchFields(A_Index)
            if edCtrls.Has("m" mNo "_" f)
                edCtrls["m" mNo "_" f].Value := ""
    return {order: [], idx: Map()}
}

; Join follow-up parts into one field, `r`n between them (round-trips through
; MassPropIsMultiline as `n; MASS_SplitParts splits them back at send time).
JoinRN(parts) {
    out := ""
    for _, p in parts
        if Trim(p) != ""
            out .= (out != "" ? "`r`n" : "") Trim(p)
    return out
}

; A fenced multiline block → ppv text, keeping internal blank lines as paragraph
; breaks and dropping a leading `ppv` marker.
FencedPpvText(grp) {
    out := ""
    for i, l in grp {
        v := Trim(l)
        if i = 1 {
            if RegExMatch(v, "i)^ppv[:\s]+(.*)$", &pm)
                v := Trim(pm[1])
            else if RegExMatch(v, "i)^ppv$")
                v := ""
        }
        out .= (out != "" ? "`r`n" : "") v
    }
    return out
}

FillTab(lines, mNo) {
    global
    ; ── strip -- comments ─────────────────────────────────────────────────────
    ; A line that is `--` alone or begins with `-- ` is a comment, dropped before
    ; any parsing. `---` (a multiline fence) is NOT a comment — its third
    ; character is not whitespace.
    ;
    ; `--word` is no longer a branch marker (`::word` is), but it is still left
    ; alone here rather than swallowed as a comment: masses in the wild contain
    ; lines like "--sale ends tonight", and eating those would delete message text
    ; on a rule the person pasting never agreed to.
    cleaned := []
    for _, rawLn in lines {
        if RegExMatch(Trim(rawLn), "^--(\s|$)")
            continue
        cleaned.Push(rawLn)
    }
    lines := cleaned

    ; ── a bare `!mma` header: the block under it is the mass ──────────────────
    ; Done FIRST, before the mode is chosen, because the mass body is prose: a
    ; paragraph of it that happens to open with a word the keyword mode knows
    ; would otherwise pick the mode for the whole paste. Taken out of the way, the
    ; modes below decide on what is actually left. See MassHeaderBlock.
    massFound := false
    hdrBlk := MassHeaderBlock(lines)
    if hdrBlk {
        ck := "m" mNo "_mass"
        if edCtrls.Has(ck)
            edCtrls[ck].Value := hdrBlk.text
        lines     := hdrBlk.rest
        massFound := true
        LOGD("gui.parse", "model " mNo ": bare mass marker — the " StrLen(hdrBlk.text)
                        . " character block under it is the mass, in one message")
    }

    ; ── the branch registry for this parse ────────────────────────────────────
    ; Branches are no longer a block of their own to be split out first: a `::name`
    ; line sits IN the follow-up group it answers, so they are picked up group by
    ; group below. This only clears the old ones and opens the name → slot table.
    brReg := NewBranchReg(mNo)

    ; ── keyword mode: any non-mass line starts with a known keyword ────────────
    hasKw := false
    for _, rawLn in lines {
        t := Trim(rawLn)
        if RegExMatch(t, "^(\S+)\s", &m) && keyMap.Has(StrLower(m[1])) && !RegExMatch(m[1], "i)^!?mm[a]?$") {
            hasKw := true
            break
        }
    }

    if hasKw {
        ; `curGrp` is whichever follow-up was last named, so a `::name` line under
        ; `f2 …` answers follow-up 2. Same rule in all three modes; the only thing
        ; that differs is how the group gets named.
        curGrp := ""
        ; The branch an empty `::name` opened. A labelled line closes it — the label
        ; says the line is the trunk's — so it only ever captures the unlabelled
        ; lines directly under the marker, which in this mode were being dropped.
        curBr := ""
        for _, rawLn in lines {
            t := Trim(rawLn)
            if t = ""
                continue
            ; Whether this line carries a keyword decides who owns it, so it is
            ; worked out BEFORE the branch check — a labelled line is never a
            ; captured one.
            isLab := RegExMatch(t, "^(\S+)\s*(.*)", &m) && keyMap.Has(StrLower(m[1]))
            if BranchLine(brReg, t, curGrp, mNo, &curBr, isLab)
                continue
            if isLab {
                kw  := StrLower(m[1])
                ck  := "m" mNo "_" keyMap[kw]
                if edCtrls.Has(ck)
                    edCtrls[ck].Value := Trim(m[2])
                curGrp := BranchGroupOf(keyMap[kw])
            }
        }
        return
    }

    ; ── positional / prefix mode ──────────────────────────────────────────────

    ; extract mass line: !mm, !mma, MM, MMA — with or without colon
    ; Skipped when the header form already took it: a second marker further down
    ; must not blank the mass that was just read out of the block above.
    if !massFound {
        for _, rawLn in lines {
            t := Trim(rawLn)
            if RegExMatch(t, "i)^!?mm[a]?[\s:]+\s*(.*)", &m) {
                ck := "m" mNo "_mass"
                if edCtrls.Has(ck)
                    edCtrls[ck].Value := Trim(m[1])
                massFound := true
                break
            }
        }
    }

    ; build filtered lines: skip mass markers and Fan Response AI artifacts
    ; `|$` so a bare `!mma` with no colon and no text is dropped like any other
    ; marker rather than surviving to become the mass itself.
    filtered := []
    for _, rawLn in lines {
        t := Trim(rawLn)
        if RegExMatch(t, "i)^!?mm[a]?([\s:]|$)")
            continue
        if RegExMatch(t, "i)^fan\s+response[\s:]")
            continue
        filtered.Push(t)
    }

    ; no !mm line — treat first non-blank filtered line as mass and remove it from the pool
    if !massFound {
        for i, t in filtered {
            if t != "" {
                ck := "m" mNo "_mass"
                if edCtrls.Has(ck)
                    edCtrls[ck].Value := t
                filtered.RemoveAt(i)
                if filtered.Length >= i && filtered[i] = ""
                    filtered.RemoveAt(i)
                break
            }
        }
    }

    ; ── prefix mode: lines carry explicit f/fu + number labels ───────────────
    ; Use this when any line begins with the fu-prefix pattern.
    ; Unlike positional mode, prefix mode routes each line to the exact slot
    ; based on its number+decimal, so blank-group boundaries are irrelevant.
    hasFPrefix := false
    for _, t in filtered {
        if t != "" && RegExMatch(t, "i)^[Ff][Uu]?\s?\d+") {
            hasFPrefix := true
            break
        }
    }

    if hasFPrefix {
        ; A `::name` line has no number of its own, so it answers whichever group
        ; was last named — the same rule the eye applies when reading the paste.
        ; `curGrp` is "fu1".."fu3" or "ppv"; before any label, a marker has nothing
        ; to attach to and is skipped rather than guessed at.
        curGrp := ""
        ; As in keyword mode: an empty marker captures the unlabelled lines under it,
        ; which this mode used to drop on the floor (no f-prefix, no slot, gone).
        curBr := ""
        for _, t in filtered {
            if t = ""
                continue
            ; Same precedence as keyword mode: a line with an `f2` / `ppv` label of
            ; its own is that label's, never a captured branch line.
            isPpv := RegExMatch(t, "i)^ppv[:\s]+\s*(.*)", &pm) ? true : false
            slot  := isPpv ? "" : FPrefixToSlot(t)
            if BranchLine(brReg, t, curGrp, mNo, &curBr, isPpv || slot != "")
                continue
            if isPpv {
                curGrp := "ppv"
                ck := "m" mNo "_ppv_base"
                if edCtrls.Has(ck) && Trim(pm[1]) != ""
                    edCtrls[ck].Value := Trim(pm[1])
                continue
            }
            if slot = ""
                continue
            ; "fu2_5" is still follow-up 2 as far as a branch is concerned: the
            ; sub-slots are parts of one answer, and a branch has its own three.
            curGrp := BranchGroupOf(slot)
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := StripPrefix(t)
        }
        return
    }

    ; ── pure positional mode: no prefixes, position within blank-groups ───────
    ; A line of 3+ dashes is a multiline fence: everything from the most recent
    ; `ppv` marker (or, if none precedes it, the start of the positional content)
    ; up to the fence collapses into ONE group whose internal blank lines are kept
    ; as paragraph breaks. That group is routed to ppv_base and never spills a line
    ; into a ppv follow-up — a multiline ppv, not a ppv + ppvfu.
    pg     := PositionalGroups(filtered)
    groups := pg.groups
    fenced := pg.fenced

    fSlotGroups := [
        ["fu1",  "fu1_5", "fu1_7"],
        ["fu2",  "fu2_5", "fu2_7"],
        ["fu3",  "fu3_5", "fu3_7"],
    ]
    fIdx    := 0
    skipIdx := 0
    ; Was the group before this one led by a `::name` marker? Two in a row are two
    ; choices at the SAME follow-up, not two follow-ups — see the f-group block.
    ; Reset by a ppv or fenced group, because those end the run.
    prevBrLed := false
    for gi, grp in groups {
        if gi = skipIdx
            continue

        ; fenced multiline block — the whole thing is the ppv base, no ppv f-ups
        if fenced.Has(gi) {
            prevBrLed := false
            ppvBase := ""
            for i, l in grp {
                v := Trim(l)
                if i = 1 {
                    if RegExMatch(v, "i)^ppv[:\s]+(.*)$", &pm)
                        v := Trim(pm[1])
                    else if RegExMatch(v, "i)^ppv$")
                        v := ""
                }
                ppvBase .= (ppvBase != "" ? "`r`n" : "") v
            }
            ck := "m" mNo "_ppv_base"
            if edCtrls.Has(ck)
                edCtrls[ck].Value := ppvBase
            continue
        }

        firstLine := Trim(grp[1])

        ; ppv group — first line starts with "ppv"
        if RegExMatch(firstLine, "i)^ppv") {
            prevBrLed := false
            ppvParts := []
            if RegExMatch(firstLine, "i)^ppv\s+(.*)", &pm) && Trim(pm[1]) != ""
                ppvParts.Push(Trim(pm[1]))
            curBr := ""
            for i, l in grp {
                if i = 1
                    continue
                t := Trim(l)
                if (t = "")
                    continue
                ; A branch's own PPV, written where the trunk's is. Same rule as
                ; the follow-up groups, including a marker alone on its line owning
                ; the lines under it.
                if BranchLine(brReg, t, "ppv", mNo, &curBr)
                    continue
                ppvParts.Push(StripPrefix(t))
            }
            ppvBase := ""
            for _, part in ppvParts
                ppvBase .= (ppvBase != "" ? "`r`n" : "") part
            ck := "m" mNo "_ppv_base"
            if edCtrls.Has(ck)
                edCtrls[ck].Value := ppvBase
            fuSlots := ["ppv_f1", "ppv_f2", "ppv_f3"]
            if gi + 1 <= groups.Length {
                skipIdx := gi + 1
                fuGrp   := groups[gi + 1]
                for si, slot in fuSlots {
                    if si > fuGrp.Length
                        break
                    ck := "m" mNo "_" slot
                    if edCtrls.Has(ck)
                        edCtrls[ck].Value := StripPrefix(Trim(fuGrp[si]))
                }
            }
            continue
        }

        ; regular f-group (f1 → f2 → f3 in order)
        ;
        ; A group is now read in ONE pass: unmarked lines are the trunk's parts, in
        ; order, and a `::name` line is that branch's part for this same group. The
        ; two used to be split apart first (SplitAltLines) because `alt:` lines and
        ; `--Name` blocks lived in different places; with one marker there is one
        ; walk and nothing to reconcile.
        ;
        ; ── a group that OPENS with a marker is not a new follow-up ───────────
        ; It is an alternative to the follow-up the branches answer, and the blank
        ; line before it is how you write it:
        ;
        ;       And tell me.. which curve entices you the most      <- f2
        ;
        ;       ::tits                                             <- f3, if tits
        ;       would you mind if I smothered you with them?
        ;
        ;       ::ass                                              <- f3, if ass
        ;       I want to make you my personal throne
        ;
        ; Counted as ordinary groups those are follow-ups 3 and 4 — and there is no
        ; fourth, so the whole `::ass` block was DROPPED with only a line in the log
        ; to show for it. Consecutive branch-led groups therefore share one index:
        ; they are choices at the same step, not successive messages. The first one
        ; still advances the index, because it IS the next follow-up — one that the
        ; trunk has no wording for, which is normal and already supported.
        isBrLed := BranchMarker(firstLine) ? true : false
        if !(isBrLed && prevBrLed)
            fIdx++
        prevBrLed := isBrLed
        if fIdx > 3 {
            LOGW("gui.parse", "model " mNo ": the pasted mass has more than three"
                            . " follow-up groups — group " fIdx " was dropped, MMA"
                            . " sends f1, f2 and f3 only")
            continue
        }
        slots := fSlotGroups[fIdx]
        base  := 0
        ; The branch an empty `::name` opened; every unmarked line under it is that
        ; branch's, not the trunk's. See BranchLine.
        curBr := ""
        for _, l in grp {
            t := Trim(l)
            if (t = "")
                continue
            if BranchLine(brReg, t, "fu" fIdx, mNo, &curBr)
                continue
            base++
            if (base > slots.Length) {
                LOGW("gui.parse", "model " mNo ": follow-up " fIdx " has more than "
                                . slots.Length " lines — '" SubStr(t, 1, 30)
                                . "' was dropped. There are three sub-slots (f"
                                . fIdx ", f" fIdx ".5, f" fIdx ".7) and no fourth.")
                continue
            }
            ck := "m" mNo "_" slots[base]
            if edCtrls.Has(ck)
                edCtrls[ck].Value := StripPrefix(t)
        }
    }
}

; SplitAltLines() stood here: it pulled `alt:` / `alt0:` lines out of a follow-up
; group and returned {baseParts, alts}, with an insertion sort to compact a stray
; `alt5:` down to a dense list. All of it existed to reconcile a second syntax for
; a thing that is now spelled one way — see BranchMarker above. The group loop
; reads marked and unmarked lines in a single pass, so there is nothing to split.
