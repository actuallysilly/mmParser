#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/parser.ahk — the mass text format: parse it, and escape it back out.
; ───────────────────────────────────────────────────────────────────────────────
;  Turns a pasted mass (the !mm / !f1 / --Branch / ~alt shorthand) into the tab
;  fields, and escapes strings on the way back into a model .ahk file.
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

; Parse one `--Name` branch segment into its br* fields. Same positional layout as
; the trunk (blank-separated groups → fu1/fu2/fu3, a `ppv` group → the branch ppv),
; but no per-group alts and each group is `n-joined into one field.
FillBranch(brLines, mNo, k, name) {
    global edCtrls
    nk := "m" mNo "_br" k "_name"
    if edCtrls.Has(nk)
        edCtrls[nk].Value := name
    filtered := []
    for _, l in brLines
        filtered.Push(Trim(l))
    pg     := PositionalGroups(filtered)
    groups := pg.groups
    fenced := pg.fenced
    fIdx := 0
    for gi, grp in groups {
        if fenced.Has(gi) {
            SetBranchField(mNo, k, "ppv", FencedPpvText(grp))
            continue
        }
        firstLine := Trim(grp[1])
        if RegExMatch(firstLine, "i)^ppv") {
            ppvParts := []
            if RegExMatch(firstLine, "i)^ppv\s+(.*)", &pm) && Trim(pm[1]) != ""
                ppvParts.Push(Trim(pm[1]))
            for i, l in grp
                if i > 1
                    ppvParts.Push(StripPrefix(Trim(l)))
            SetBranchField(mNo, k, "ppv", JoinRN(ppvParts))
            continue
        }
        fIdx++
        if fIdx > 3
            continue
        parts := []
        for _, l in grp
            parts.Push(StripPrefix(Trim(l)))
        SetBranchField(mNo, k, "fu" fIdx, JoinRN(parts))
    }
}

SetBranchField(mNo, k, grp, val) {
    global edCtrls
    ck := "m" mNo "_br" k "_" grp
    if edCtrls.Has(ck)
        edCtrls[ck].Value := val
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
    ; any parsing. `--word` (an alt marker) and `---` (a multiline fence) are NOT
    ; comments — their third character is not whitespace.
    cleaned := []
    for _, rawLn in lines {
        if RegExMatch(Trim(rawLn), "^--(\s|$)")
            continue
        cleaned.Push(rawLn)
    }
    lines := cleaned

    ; ── --Name branch segmentation ────────────────────────────────────────────
    ; A `--Name` marker opens a whole alternate follow-up sequence. Split those out
    ; and parse each into its br* fields; everything before the first marker is the
    ; shared trunk, parsed by the normal modes below.
    branches := []
    trunkLines := []
    curBr := 0
    for _, rawLn in lines {
        t := Trim(rawLn)
        if RegExMatch(t, "^--(?=[^\s-])") {
            branches.Push({ name: Trim(SubStr(t, 3)), lines: [] })
            curBr := branches.Length
            continue
        }
        if curBr = 0
            trunkLines.Push(rawLn)
        else
            branches[curBr].lines.Push(rawLn)
    }
    Loop Min(branches.Length, MASS_BRANCH_MAX) {
        k := A_Index
        FillBranch(branches[k].lines, mNo, k, branches[k].name)
    }
    lines := trunkLines

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
        for _, rawLn in lines {
            t := Trim(rawLn)
            if t = ""
                continue
            if RegExMatch(t, "^(\S+)\s*(.*)", &m) {
                kw  := StrLower(m[1])
                val := Trim(m[2])
                if keyMap.Has(kw) {
                    ck := "m" mNo "_" keyMap[kw]
                    if edCtrls.Has(ck)
                        edCtrls[ck].Value := val
                }
            }
        }
        return
    }

    ; ── positional / prefix mode ──────────────────────────────────────────────

    ; extract mass line: !mm, !mma, MM, MMA — with or without colon
    massFound := false
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

    ; build filtered lines: skip mass markers and Fan Response AI artifacts
    filtered := []
    for _, rawLn in lines {
        t := Trim(rawLn)
        if RegExMatch(t, "i)^!?mm[a]?[\s:]")
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
        for _, t in filtered {
            if t = ""
                continue
            if RegExMatch(t, "i)^ppv[:\s]+\s*(.*)", &pm) {
                ck := "m" mNo "_ppv_base"
                if edCtrls.Has(ck) && Trim(pm[1]) != ""
                    edCtrls[ck].Value := Trim(pm[1])
                continue
            }
            slot := FPrefixToSlot(t)
            if slot = ""
                continue
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
    for gi, grp in groups {
        if gi = skipIdx
            continue

        ; fenced multiline block — the whole thing is the ppv base, no ppv f-ups
        if fenced.Has(gi) {
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
            ppvParts := []
            if RegExMatch(firstLine, "i)^ppv\s+(.*)", &pm) && Trim(pm[1]) != ""
                ppvParts.Push(Trim(pm[1]))
            for i, l in grp
                if i > 1
                    ppvParts.Push(StripPrefix(Trim(l)))
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
        fIdx++
        if fIdx > 3
            continue
        slots := fSlotGroups[fIdx]
        split := SplitAltLines(grp)

        for si, slot in slots {
            if si > split.baseParts.Length
                break
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := StripPrefix(Trim(split.baseParts[si]))
        }

        altFlds := AltFields(ALT_GROUPS[fIdx])
        for ai, parts in split.alts {
            if ai > altFlds.Length          ; more alts than slots — keep the first MASS_ALT_MAX
                break
            ck := "m" mNo "_" altFlds[ai]
            if !edCtrls.Has(ck)
                continue
            joined := ""
            for _, p in parts
                joined .= (joined != "" ? "`r`n" : "") p
            edCtrls[ck].Value := joined
        }
    }
}

; Split one follow-up group into its base variant and its alternatives.
;
;   alt:   -> each line is its OWN alternative (the common case, one-liners)
;   alt0:  -> numbered; lines sharing a number join into one MULTI-PART alternative
;
; Both forms can be mixed; an unnumbered alt: always takes the next free slot.
; That distinction is the whole point — without it "alt:" twice is ambiguous
; between two single-part alts and one two-part alt.
; NOTE: the returned field is `baseParts`, not `base` — in an AHK v2 object literal
; `{base: x}` sets the object's PROTOTYPE, so returning {base: someArray} throws
; "Invalid base." at the call site rather than storing a field.
SplitAltLines(grp) {
    baseLines := []
    alts := Map()
    order := []
    maxIdx := 0

    for _, rawLn in grp {
        t := Trim(rawLn)
        if t = ""
            continue
        if RegExMatch(t, "i)^alt\s*(\d*)\s*:\s*(.*)$", &am) {
            body := Trim(am[2])
            if body = ""
                continue
            idx := (am[1] = "") ? maxIdx + 1 : Integer(am[1]) + 1   ; alt0 -> slot 1
            if idx < 1
                idx := 1
            if !alts.Has(idx) {
                alts[idx] := []
                order.Push(idx)
            }
            alts[idx].Push(body)
            if idx > maxIdx
                maxIdx := idx
        } else {
            baseLines.Push(t)
        }
    }

    ; compact to a dense array in first-seen order, so a stray alt5: does not
    ; leave four empty slots in front of it
    sorted := []
    for _, idx in order
        sorted.Push(idx)
    Loop sorted.Length - 1 {                  ; tiny list; insertion sort keeps it obvious
        i := A_Index + 1
        v := sorted[i]
        j := i - 1
        while (j >= 1 && sorted[j] > v) {
            sorted[j + 1] := sorted[j]
            j--
        }
        sorted[j + 1] := v
    }
    out := []
    for _, idx in sorted
        out.Push(alts[idx])

    return {baseParts: baseLines, alts: out}
}
