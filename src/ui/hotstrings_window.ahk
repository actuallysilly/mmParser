#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../hotstrings/index.ahk"
#Include "../hotstrings/overloads.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings_window.ahk — a searchable window over the whole message library.
; ───────────────────────────────────────────────────────────────────────────────
;  Reads every hotstring via hotstrings/index.ahk (see there) and lists them so you
;  can find one by TRIGGER or by the TEXT inside it: browse, search, jump to the
;  source line, and turn a trigger into an OVERLOAD (several variants, one of which
;  fires) via hotstrings/overloads.ahk.
;
;  Run it on its own (double-click). Editing is deliberately one-way: overload
;  variants live in hotstring_overloads.ini and never touch your sources. DELETE is
;  the single exception — it cuts the block out of the .ahk file itself, after a
;  confirmation and a .bak.
; ═══════════════════════════════════════════════════════════════════════════════

; ── palette (dark violet, in the Infloww family). RRGGBB, no 0x. ──
BG      := "15141C"      ; window
SURFACE := "201E2B"      ; detail pane
LISTBG  := "1B1A24"      ; list
FIELDBG := "2A2836"      ; search box
TXT     := "E6E4EE"      ; primary text
MUTED   := "8E8AA6"      ; secondary text
ACCENT  := "B89CFF"      ; violet accent

; Built at runtime so the source file stays pure-ASCII (avoids .ahk encoding traps).
GLYPH_STAR  := Chr(0x2726)
GLYPH_ARROW := Chr(0x25B8)

gRecords   := HSI_Build()
gShown     := 0
gOverloads := OL_Load()        ; trigger -> {file, options, variants}; refreshed on save/rescan

; adjustable text size for the list + showcase, remembered across runs in mass_gui.cfg
;
; MMA_CFG, not `HSI_DIR "\mass_gui.cfg"`. HSI_DIR is content\ — right for finding
; the hotstring SOURCE files it indexes, wrong for the config, which lives in
; userdata\. Built that way, this window read and wrote a whole second file named
; mass_gui.cfg inside content\, which it CREATED on the first font-size change:
; the setting appeared to stick (it read back its own file) while being invisible
; to every other part of MMA, and sat one folder away from the real config under
; the same name.
gSizes    := ["9", "10", "11", "12", "13", "14", "16", "18", "20", "22", "24"]
gFontSize := Integer(IniRead(MMA_CFG, "Hotstrings", "FontSize", "11"))

; sort order, remembered across runs. "File order" is how the library reads on
; disk and stays the default; the date orders answer "what did I write lately?"
gSortModes := ["File order", "Newest first", "Oldest first", "Trigger A-Z"]
gSortMode  := Integer(IniRead(MMA_CFG, "Hotstrings", "Sort", "1"))
if (gSortMode < 1 || gSortMode > gSortModes.Length)
    gSortMode := 1

; ── window ──
MainGui := Gui("+Resize +MinSize780x460", "Hotstrings  " Chr(0x2014) "  message library")
MainGui.BackColor := BG
MainGui.OnEvent("Size",   OnSize)
MainGui.OnEvent("Close",  GuiClosed)
MainGui.OnEvent("Escape", GuiClosed)

; title + live count
MainGui.SetFont("s15 Bold c" ACCENT, "Segoe UI")
MainGui.Add("Text", "x16 y12 w400", GLYPH_STAR "  Hotstrings")
MainGui.SetFont("s11 Norm c" MUTED, "Segoe UI")
countTxt := MainGui.Add("Text", "x600 y21 w360 Right", "")

; search
MainGui.SetFont("s12 c" TXT, "Segoe UI")
searchEd := MainGui.Add("Edit", "x16 y48 w948 h32 Background" FIELDBG)
searchEd.OnEvent("Change", OnSearch)
CueBanner(searchEd, "Search trigger or message text" Chr(0x2026) "   (spaces = all terms must match)")

; list (full width; the showcase sits beneath it)
MainGui.SetFont("s11 c" TXT, "Segoe UI")
LV := MainGui.Add("ListView", "x16 y90 w948 h250 Background" LISTBG,
                  ["Trigger", "Message preview", "#", "Var", "File", "Added", "idx"])
LV.OnEvent("ItemFocus",   OnRowFocus)
LV.OnEvent("DoubleClick", OnRowOpen)
LV.ModifyCol(1, 170)
LV.ModifyCol(2, 350)
LV.ModifyCol(3, "50 Integer Center")
LV.ModifyCol(4, "50 Center")       ; variant count when overloaded, else blank
LV.ModifyCol(5, 120)
LV.ModifyCol(6, 90)                ; date the hotstring was added, blank if unstamped
LV.ModifyCol(7, 0)                 ; hidden: master index into gRecords, rides with its row

; showcase / detail pane — full width, word-wrapped so long messages read cleanly
MainGui.SetFont("s12 c" TXT, "Segoe UI")
detailEd := MainGui.Add("Edit", "x16 y350 w948 h170 ReadOnly +VScroll Background" SURFACE)

; footer
MainGui.SetFont("s10 c" TXT, "Segoe UI")
btnOpen   := MainGui.Add("Button", "x16 y534 w112 h30", "Open source")
btnCopy   := MainGui.Add("Button", "x134 y534 w112 h30", "Copy trigger")
btnRescan := MainGui.Add("Button", "x252 y534 w92 h30", "Rescan")
btnOver   := MainGui.Add("Button", "x352 y534 w118 h30", "Overload" Chr(0x2026))
btnDelete := MainGui.Add("Button", "x478 y534 w92 h30", "Delete")
btnOpen.OnEvent("Click",   OpenSelected)
btnCopy.OnEvent("Click",   CopySelected)
btnRescan.OnEvent("Click", RescanFiles)
btnOver.OnEvent("Click",   EditOverload)
btnDelete.OnEvent("Click", DeleteSelected)
; ask-vs-random is NOT global: each overloaded trigger carries its own mode,
; set in the variant editor and stored with its variants.

; sort control
MainGui.SetFont("s10 c" MUTED, "Segoe UI")
lblSort := MainGui.Add("Text", "x580 y540 w34 h22 +0x200 Right", "Sort")
MainGui.SetFont("s10 c" TXT, "Segoe UI")
sortDD := MainGui.Add("DropDownList", "x618 y536 w120", gSortModes)
sortDD.Choose(gSortMode)
sortDD.OnEvent("Change", OnSortMode)

; text-size control — applies to the list + showcase, remembered across runs
MainGui.SetFont("s10 c" MUTED, "Segoe UI")
lblSize := MainGui.Add("Text", "x836 y540 w62 h22 +0x200 Right", "Text size")
MainGui.SetFont("s10 c" TXT, "Segoe UI")
sizeDD := MainGui.Add("DropDownList", "x902 y536 w62", gSizes)
sizeIdx := 3
for i, sv in gSizes
    if (Integer(sv) = gFontSize)
        sizeIdx := i
sizeDD.Choose(sizeIdx)
sizeDD.OnEvent("Change", OnFontSize)

ApplyDarkTheme()
ApplyContentFont(gFontSize)
PopulateList("")
MainGui.Show("w1000 h600")

; ═══════════════════════════════════════════════════════════════════════════════
;  behaviour
; ═══════════════════════════════════════════════════════════════════════════════

OnSearch(*) {
    global searchEd
    PopulateList(searchEd.Value)
}

GuiClosed(*) {
    ExitApp()
}

; Rebuild the list to show only records matching the query. Space-separated terms
; are ANDed, matched case-insensitively against the trigger AND the message text —
; that's the "search by text in the string" the manager exists for.
PopulateList(query) {
    global gRecords, gShown, LV, countTxt, detailEd
    terms := []
    for t in StrSplit(Trim(query), " ")
        if (t != "")
            terms.Push(t)

    LV.Opt("-Redraw")
    LV.Delete()
    shown := 0
    for _, i in SortedIndices() {
        r := gRecords[i]
        if MatchRec(r, terms) {
            LV.Add(, r.trigger, FlattenOneLine(r.preview), r.steps.Length, VarCell(r.trigger),
                     HsFileLabel(r.file), AddedCell(r.added), i)
            shown++
        }
    }
    LV.Opt("+Redraw")

    gShown := shown
    countTxt.Value := (shown = gRecords.Length)
        ? gRecords.Length " hotstrings"
        : shown " of " gRecords.Length " shown"

    if shown {
        LV.Modify(1, "Select Focus Vis")
        OnRowFocus(LV, 1)
    } else {
        detailEd.Value := "No matches."
    }
}

; The order rows are listed in: an array of indices into gRecords. Filtering runs
; over this, so search results keep whatever order is selected.
;
; Records with no "; @added" stamp cannot be dated, and guessing would be worse
; than admitting it: they sort together at the END of both date orders, keeping
; their file order among themselves. So "Newest first" means "newest known first",
; never "unstamped is ancient".
SortedIndices() {
    global gRecords, gSortMode
    idx := []
    Loop gRecords.Length
        idx.Push(A_Index)
    if (gSortMode = 1)
        return idx

    keyOf(i) {
        r := gRecords[i]
        return gSortMode = 4 ? StrLower(r.trigger) : r.added
    }
    less(a, b) {
        ka := keyOf(a), kb := keyOf(b)
        if (gSortMode = 4)
            return StrCompare(ka, kb) < 0
        if (ka = "" || kb = "")
            return (ka != "" && kb = "")        ; dated before undated, either way round
        return gSortMode = 2 ? StrCompare(ka, kb) > 0 : StrCompare(ka, kb) < 0
    }
    ; Insertion sort: ~120 records, and it is stable, which is what keeps the
    ; undated tail and same-day entries in their original file order.
    Loop idx.Length - 1 {
        i := A_Index + 1
        v := idx[i]
        j := i - 1
        while (j >= 1 && less(v, idx[j])) {
            idx[j + 1] := idx[j]
            j--
        }
        idx[j + 1] := v
    }
    return idx
}

; "2026-07-25 14:03" -> "2026-07-25". The clock time is noise in a list column;
; it stays in the file for anyone who wants it.
AddedCell(added) {
    return added = "" ? "" : SubStr(added, 1, 10)
}

OnSortMode(ctrl, *) {
    global gSortMode, searchEd
    gSortMode := ctrl.Value
    try IniWrite(gSortMode, MMA_CFG, "Hotstrings", "Sort")
    PopulateList(searchEd.Value)
}

MatchRec(r, terms) {
    if !terms.Length
        return true
    hay := r.trigger " " r.preview
    for t in terms
        if !InStr(hay, t, false)          ; case-insensitive substring
            return false
    return true
}

OnRowFocus(ctrl, row) {
    global gRecords, detailEd
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, 7))
    if (idx < 1 || idx > gRecords.Length)
        return
    detailEd.Value := BuildDetail(gRecords[idx])
}

; The showcase pane: the message, and nothing else. The trigger, source file and
; line already sit in the list columns, and which function sends a step is an
; implementation detail — repeating them here just buried the text you came to read.
BuildDetail(r) {
    global gOverloads
    out := ""
    if !r.steps.Length {
        out .= "(empty " Chr(0x2014) " no send steps)`r`n"
    } else {
        for st in r.steps {
            t := StrReplace(st.text, "`r`n", "`n")     ; normalise, then give the Edit CRLFs
            t := StrReplace(t, "`n", "`r`n")
            out .= t "`r`n`r`n"
        }
    }
    if gOverloads.Has(r.trigger) {
        e := gOverloads[r.trigger]
        out .= "`r`n== OVERLOADED " Chr(0x2014) " " e.variants.Length
             . " variants, pick: " e.mode " (the body above is bypassed) ==`r`n`r`n"
        for vi, steps in e.variants {
            out .= "[" vi "]`r`n"
            for st in steps {
                t := StrReplace(StrReplace(st.text, "`r`n", "`n"), "`n", "`r`n")
                out .= "     " t "`r`n"
            }
            out .= "`r`n"
        }
    }
    return RTrim(out, "`r`n")
}

; "acc\TEMP.ahk" -> "TEMP", "general.ahk" -> "general". Display only — every path
; the code actually opens still goes through r.file.
HsFileLabel(f) {
    SplitPath(f, , , , &base)
    return base
}

; Blank unless the trigger is overloaded, in which case its variant count.
VarCell(trigger) {
    global gOverloads
    return gOverloads.Has(trigger) ? gOverloads[trigger].variants.Length : ""
}

OnRowOpen(ctrl, row) {
    global gRecords, HSI_DIR
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, 7))
    if (idx < 1 || idx > gRecords.Length)
        return
    r := gRecords[idx]
    OpenAt(HSI_DIR "\" r.file, r.line)
}

; Prefer VS Code at the exact line; fall back to Notepad if the `code` CLI is absent.
OpenAt(path, line) {
    try {
        Run(A_ComSpec ' /c code -g "' path '":' line, , "Hide")
        return
    }
    try Run('notepad.exe "' path '"')
}

OpenSelected(*) {
    global LV
    OnRowOpen(LV, LV.GetNext(0, "F"))
}

CopySelected(*) {
    global LV
    row := LV.GetNext(0, "F")
    if !row
        return
    A_Clipboard := LV.GetText(row, 1)
    ToolTip "Copied  " A_Clipboard
    SetTimer(RemoveToolTip, -1200)
}

RemoveToolTip() {
    ToolTip()
}

RescanFiles(*) {
    global gRecords, gOverloads, searchEd
    gRecords   := HSI_Build()
    gOverloads := OL_Load()
    PopulateList(searchEd.Value)
}

; ── delete: the one action that edits a message .ahk file ─────────────────────
;
; Everything else here is a view. This cuts the block out of the source, so it
; asks first, shows exactly what is going: trigger, file, line, and the message
; body, because a trigger alone ("_g3") is not enough to recognise what you are
; about to lose. hotstrings/index.ahk writes the .bak and re-verifies the line.
DeleteSelected(*) {
    global LV, gRecords, gOverloads, searchEd
    row := LV.GetNext(0, "F")
    if !row {
        Notify("Select a hotstring first")
        return
    }
    idx := Integer(LV.GetText(row, 7))
    if (idx < 1 || idx > gRecords.Length)
        return
    r := gRecords[idx]

    body := FlattenOneLine(r.preview)
    if (StrLen(body) > 220)
        body := SubStr(body, 1, 220) Chr(0x2026)

    warn := ""
    if gOverloads.Has(r.trigger)
        warn := "`n`nIts " gOverloads[r.trigger].variants.Length " overload variants will be "
              . "removed too " Chr(0x2014) " left behind, they would keep firing for a "
              . "trigger whose source is gone."

    prompt := "Delete this hotstring from " r.file "?`n`n"
            . ":" r.options ":" r.trigger "::   (line " r.line ")`n`n"
            . (body = "" ? "(empty)" : body)
            . warn
            . "`n`nThis edits the source file. A copy is saved as "
            . HsFileLabel(r.file) ".ahk.bak first, and "
            . OL_BaseName(r.file) " must be restarted for the change to take effect."
    if (MsgBox(prompt, "Delete hotstring", 0x24) != "Yes")
        return

    res := HSI_DeleteBlock(r.file, r.line, r.trigger)
    if !res.ok {
        MsgBox(res.why, "Delete hotstring", 0x30)
        return
    }
    if gOverloads.Has(r.trigger)
        OL_Remove(r.trigger)

    RescanFiles()
    Notify(r.trigger " deleted from " OL_BaseName(r.file) " (" res.removed " lines, .bak saved)"
         . "  " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  overloading — variants live in hotstring_overloads.ini, never in your .ahk
; ═══════════════════════════════════════════════════════════════════════════════

EditOverload(*) {
    global LV, gRecords
    row := LV.GetNext(0, "F")
    if !row
        return
    idx := Integer(LV.GetText(row, 7))
    if (idx < 1 || idx > gRecords.Length)
        return
    OpenVariantEditor(gRecords[idx])
}

; A variant is edited as plain text: ONE STEP PER LINE, with \n standing in for a
; newline inside a single step (same escape the registry uses), so nothing is lost
; on the round-trip. The mode picks how every step in that variant is sent.
StepsToVariant(steps) {
    mode := "lines"
    t := ""
    for st in steps {
        if (StrLower(st.fn) = "sendtext")
            mode := "paste"
        line := StrReplace(StrReplace(st.text, "`r`n", "`n"), "`n", "\n")
        t .= (t = "" ? "" : "`r`n") line
    }
    return {mode: mode, text: t}
}

VariantToSteps(v) {
    steps := []
    fn := (v.mode = "paste") ? "SendText" : "snd"
    for line in StrSplit(v.text, "`n", "`r") {
        if (Trim(line) = "")            ; skip blank lines, but keep a real line verbatim —
            continue                    ; trimming would eat intentional leading/trailing spaces
        steps.Push({fn: fn, text: StrReplace(line, "\n", "`n")})
    }
    return steps
}

OpenVariantEditor(r) {
    global gOverloads, MainGui, searchEd, BG, LISTBG, FIELDBG, TXT, MUTED, ACCENT

    ; working copy — seed variant 1 from the source body when not yet overloaded
    vars := []
    pickMode := "ask"
    if gOverloads.Has(r.trigger) {
        pickMode := gOverloads[r.trigger].mode
        for steps in gOverloads[r.trigger].variants
            vars.Push(StepsToVariant(steps))
    } else {
        vars.Push(StepsToVariant(r.steps))
    }
    cur := 0

    eg := Gui("+Owner" MainGui.Hwnd, "Overload  " r.trigger)
    eg.BackColor := BG
    eg.SetFont("s11 Bold c" ACCENT, "Segoe UI")
    eg.Add("Text", "x14 y12 w400", ":" r.options ":" r.trigger "::")

    ; how THIS trigger chooses among its variants — stored per trigger, not globally
    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x420 y14 w96 h20 +0x200 Right", "On fire, pick")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    pickSel := eg.Add("DropDownList", "x522 y11 w92", ["ask", "random"])
    pickSel.Choose(pickMode = "random" ? 2 : 1)

    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x14 y36 w600",
           "One step per line." Chr(0x2026) "  use \n inside a line for a newline within that message.")

    eg.SetFont("s10 c" TXT, "Segoe UI")
    lb := eg.Add("ListBox", "x14 y62 w200 h236 Background" LISTBG)
    modeSel := eg.Add("DropDownList", "x224 y62 w390",
                      ["send each line (Enter after each)", "paste only (no Enter)"])
    body := eg.Add("Edit", "x224 y94 w390 h204 Multi +VScroll Background" FIELDBG)

    eg.SetFont("s9 c" TXT, "Segoe UI")
    bAdd  := eg.Add("Button", "x14 y308 w86 h27", "Add")
    bDel  := eg.Add("Button", "x106 y308 w86 h27", "Delete")
    bSave := eg.Add("Button", "x330 y308 w86 h27", "Save")
    bOff  := eg.Add("Button", "x422 y308 w110 h27", "Remove overload")
    bCan  := eg.Add("Button", "x538 y308 w76 h27", "Cancel")

    lb.OnEvent("Change", PickVariant)
    bAdd.OnEvent("Click",  AddVariant)
    bDel.OnEvent("Click",  DelVariant)
    bSave.OnEvent("Click", SaveVariants)
    bOff.OnEvent("Click",  DropOverload)
    bCan.OnEvent("Click",  CloseEditor)
    eg.OnEvent("Close",  CloseEditor)
    eg.OnEvent("Escape", CloseEditor)

    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", eg.Hwnd, "int", 20, "int*", 1, "int", 4)
    RefreshVariants(1)
    eg.Show("w628 h348")
    return

    ; ── nested handlers (closures over vars / cur / the controls above) ──

    RefreshVariants(want) {
        lb.Delete()
        for i, v in vars
            lb.Add([i "   " SubStr(StrReplace(v.text, "`r`n", " / "), 1, 40)])
        if vars.Length {
            want := Max(1, Min(want, vars.Length))
            lb.Choose(want)
            LoadVariant(want)
        }
    }

    LoadVariant(i) {
        cur := i
        body.Value := vars[i].text
        modeSel.Choose(vars[i].mode = "paste" ? 2 : 1)
    }

    CommitCurrent() {
        if (cur >= 1 && cur <= vars.Length) {
            vars[cur].text := body.Value
            vars[cur].mode := (modeSel.Value = 2) ? "paste" : "lines"
        }
    }

    PickVariant(*) {
        sel := lb.Value
        if (!sel || sel = cur)
            return
        CommitCurrent()
        LoadVariant(sel)
    }

    AddVariant(*) {
        CommitCurrent()
        vars.Push({mode: "lines", text: ""})
        RefreshVariants(vars.Length)
    }

    DelVariant(*) {
        if (vars.Length <= 1) {
            MsgBox("A variant list needs at least one entry."
                 . "`n`nUse 'Remove overload' to drop it entirely.", "Overload", 0x40)
            return
        }
        if (cur < 1 || cur > vars.Length)
            return
        vars.RemoveAt(cur)
        cur := 0
        RefreshVariants(1)
    }

    SaveVariants(*) {
        global gOverloads, searchEd
        CommitCurrent()
        built := []
        for v in vars {
            steps := VariantToSteps(v)
            if steps.Length
                built.Push(steps)
        }
        if !built.Length {
            MsgBox("Every variant is empty " Chr(0x2014) " nothing to save.", "Overload", 0x30)
            return
        }
        ; Read the control BEFORE the window goes away — eg.Destroy() takes pickSel
        ; with it, and touching it afterwards throws "The control is destroyed."
        mode := pickSel.Text
        OL_Save(r.trigger, r.file, r.options, built, mode)
        gOverloads := OL_Load()
        PopulateList(searchEd.Value)
        eg.Destroy()
        Notify(r.trigger " overloaded " Chr(0x2014) " " built.Length " variants, pick: " mode
             . "  " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
    }

    DropOverload(*) {
        global gOverloads, searchEd
        OL_Remove(r.trigger)
        gOverloads := OL_Load()
        PopulateList(searchEd.Value)
        eg.Destroy()
        Notify(r.trigger " overload removed " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
    }

    CloseEditor(*) {
        eg.Destroy()
    }
}

Notify(msg) {
    ToolTip(msg)
    SetTimer(RemoveToolTip, -2600)
}

; ── resize: search spans the width; list on top, showcase (full width) beneath ──
OnSize(g, minMax, w, h) {
    global searchEd, LV, detailEd, countTxt, btnOpen, btnCopy, btnRescan, lblSize, sizeDD
    global btnOver, btnDelete, lblSort, sortDD
    if (minMax = -1)
        return
    m := 16, gap := 10, footerH := 30, footerGap := 14
    countTxt.Move(w - 376, 21, 360)
    searchEd.Move(m, 48, w - 2 * m, 32)

    top := 90
    contentH := h - top - m - footerH - footerGap
    if (contentH < 220)
        contentH := 220
    listW  := w - 2 * m
    listH  := Integer((contentH - gap) * 0.42)      ; list ~42%, showcase gets the rest
    detailH := contentH - gap - listH
    LV.Move(m, top, listW, listH)
    detailEd.Move(m, top + listH + gap, listW, detailH)

    ; preview column soaks up the list's spare width
    LV.ModifyCol(1, 190)
    LV.ModifyCol(3, 54)
    LV.ModifyCol(4, 54)
    LV.ModifyCol(5, 130)
    LV.ModifyCol(6, 92)
    LV.ModifyCol(2, Max(160, listW - 190 - 54 - 54 - 130 - 92 - 24))

    by := top + contentH + footerGap
    btnOpen.Move(m, by)
    btnCopy.Move(m + 118, by)
    btnRescan.Move(m + 236, by)
    btnOver.Move(m + 336, by)
    btnDelete.Move(m + 462, by)
    sizeDD.Move(w - m - 62, by, 62)
    lblSize.Move(w - m - 62 - 66, by + 6, 62)
    sortDD.Move(w - m - 62 - 66 - 128, by, 120)
    lblSort.Move(w - m - 62 - 66 - 128 - 38, by + 6, 34)
}

; ── text size: live-apply to list + showcase and remember the choice ──
OnFontSize(ctrl, *) {
    global gFontSize
    gFontSize := Integer(ctrl.Text)
    ApplyContentFont(gFontSize)
    SaveFontSize(gFontSize)
}

ApplyContentFont(sz) {
    global detailEd, TXT
    detailEd.SetFont("s" sz " c" TXT)     ; preview box only — the list keeps its own size
}

SaveFontSize(sz) {
    global HSI_DIR
    try IniWrite(sz, MMA_CFG, "Hotstrings", "FontSize")
}

; ── native helpers ──
CueBanner(ctrl, text) {
    static EM_SETCUEBANNER := 0x1501
    SendMessage(EM_SETCUEBANNER, 1, StrPtr(text), ctrl)
}

FlattenOneLine(s) {
    return StrReplace(StrReplace(s, "`r", " "), "`n", " ")
}

; Dark title bar + dark scrollbars/selection, so the window doesn't have a white
; frame around a dark body. All best-effort — wrapped so old Windows just skips it.
ApplyDarkTheme() {
    global MainGui, LV, detailEd, searchEd
    for attr in [20, 19]                    ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", MainGui.Hwnd, "int", attr, "int*", 1, "int", 4)
    for hwnd in [LV.Hwnd, detailEd.Hwnd, searchEd.Hwnd]
        try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    ; The column header is a separate SysHeader32 child and does NOT inherit the
    ; list's theme. Use DarkMode_Explorer, not DarkMode_ItemsView: ItemsView
    ; darkens the header background but leaves the LABEL text dark too, which
    ; reads as an empty/transparent header rather than a themed one.
    hHdr := SendMessage(0x101F, 0, 0, LV)        ; LVM_GETHEADER
    if hHdr
        try DllCall("uxtheme\SetWindowTheme", "ptr", hHdr, "str", "DarkMode_Explorer", "ptr", 0)
}
