#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  archive.ahk — the mass archive: its file format, its readers, and its window.
; ───────────────────────────────────────────────────────────────────────────────
;  mass_archive.txt is append-only and holds every mass you have parsed, one
;  ---- delimited entry each. Two things read it — the viewer window and the
;  duplicate check — so there is ONE parser (ReadArchiveEntries) and both use it.
;
;  Split out of main_window.ahk, which had grown to hold the GUI, this archive, the
;  text parser and the subprocess supervisor in one file. Nothing here builds the
;  main window; it is included by main_window.ahk and shares its globals.
; ═══════════════════════════════════════════════════════════════════════════════

; ─── Archive ──────────────────────────────────────────────────────────────────
; One parser for both readers — the viewer below and the duplicate check. They
; used to be the same code twice, which is how they would drift apart.

ArchiveFile() {
    return MMA_ARCHIVE
}

ReadArchiveEntries() {
    path := ArchiveFile()
    entries := []
    if !FileExist(path) {
        LOGD("archive.read", "no archive file yet — nothing to browse")
        return entries
    }
    raw := ""
    try {
        raw := FileRead(path, "UTF-8")
    } catch as e {
        ; The archive grows without bound and is the one file here likely to be
        ; open in a text editor while MMA runs. Unguarded this threw straight into
        ; whatever opened the archive window.
        LOGE("archive.read", "could not read the archive — the archive window will"
                           . " show nothing", LOG_Err(e) "   " path)
        return entries
    }
    for chunk in StrSplit(raw, "===END===") {
        chunk := Trim(chunk, " `t`r`n")   ; Trim() alone keeps leading CR/LF, making lines[1] empty → only first entry parsed
        if chunk = ""
            continue
        lines := StrSplit(StrReplace(chunk, "`r`n", "`n"), "`n")
        if lines.Length < 2
            continue
        header := Trim(lines[1])
        if !RegExMatch(header, "^\[(.+?)\]\s+\[(.+?)\]$", &hm)
            continue
        content := ""
        Loop lines.Length - 1
            content .= lines[A_Index + 1] "`n"
        content := Trim(content)
        preview := ""
        for ln in StrSplit(content, "`n") {
            t := Trim(ln)
            if t != "" {
                preview := t
                break
            }
        }
        entries.Push({ts: hm[1], model: hm[2], content: content, preview: preview})
    }
    return entries
}

; Delete one entry from the archive file.
;
; Re-reads the file rather than rewriting from the viewer's own list: parsing a
; mass appends to the archive, and the viewer can sit open across several parses.
; Rewriting from a list captured when the window opened would silently drop every
; mass archived since. Matched on ts+model+content, which is what identifies an
; entry — the viewer's row index means nothing to the file.
;
; Returns true if an entry was removed.
DeleteArchiveEntry(target) {
    path := ArchiveFile()
    if !FileExist(path)
        return false
    kept  := []
    found := false
    for e in ReadArchiveEntries() {
        if (!found && e.ts = target.ts && e.model = target.model && e.content = target.content) {
            found := true            ; first match only: identical re-pastes are
            continue                 ; separate entries, delete asks for one
        }
        kept.Push(e)
    }
    if !found
        return false

    out := ""
    for e in kept
        out .= "[" e.ts "] [" e.model "]`n" e.content "`n===END===`n`n"

    ; Write beside the file and swap, so a failure mid-write cannot leave the
    ; archive truncated — this is the only place MMA rewrites it wholesale.
    tmp := path ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8")
        if !f {
            LOGE("archive", "could not open the archive's temp file for writing —"
                          . " the archive was NOT changed", tmp)
            return false
        }
        f.Write(out)
        f.Close()
        FileMove(tmp, path, 1)
        LOGI("archive", "rewrote " path " — " kept.Length " entr(ies) kept")
    } catch as e {
        ; The archive is a write-only history of every mass ever parsed, so a
        ; failed rewrite is not data loss — the previous file is still there,
        ; untouched, by construction. Worth a FAIL anyway: the deletion the user
        ; just asked for did not happen, and the entry will still be there.
        LOGE("archive", "could not rewrite the archive — it is unchanged, so"
                      . " whatever you just deleted is still in it", LOG_Err(e))
        try FileDelete(tmp)
        return false
    }
    return true
}

; Compare on meaning, not layout: trailing spaces and blank lines vary between
; two pastes of the same mass. Case is left alone — changing it is a real edit.
NormalizeMass(s) {
    s := StrReplace(StrReplace(s, "`r`n", "`n"), "`r", "`n")
    out := ""
    for ln in StrSplit(s, "`n") {
        t := Trim(ln)
        if t != ""
            out .= t "`n"
    }
    return out
}

; "2026-06-22 10:48:04" -> "20260622000000". Date only: the window is in whole
; calendar days, so the time of day must not affect the comparison.
ArchiveDayStamp(ts) {
    d := RegExReplace(SubStr(Trim(ts), 1, 10), "[^0-9]", "")
    return StrLen(d) = 8 ? d "000000" : ""
}

; The archived copy of this mass from the last ArchiveDupDays days, or 0 if there
; is none. A hit means Parse does NOT archive — silently, see the caller.
;
; Re-parsing the same paste is routine (fixing one line and hitting parse again),
; and every parse used to append: 21 of the first 59 entries were duplicates, one
; mass stored 9 times in under two minutes.
;
; The window defaults to 0 — the SAME CALENDAR DAY, nothing older. That is the rule
; the archive is meant to enforce: one entry per mass per day. A wider window would
; start dropping the genuine case of the same mass going out again next week, which
; is a real thing that happened and which the archive should record. ArchiveDupDays
; is still read, so a wider window is a one-line ini edit if you want one.
;
; The model is deliberately NOT part of the match. Scoping by name missed two real
; cases: the same mass genuinely does get archived for two models, and a blank
; model name wrote a "[]" header that then matched nothing at all — which is how
; "Pop or rock music?" got in twice three seconds apart. A same-model hit is
; returned in preference to a cross-model one so the log line names the closest
; entry, but either one counts as already archived.
ArchiveFindDuplicate(mName, raw) {
    global CFG_FILE
    ; Reached from Parse, so an unparseable ArchiveDupDays threw every time you
    ; pressed Parse with archiving on — i.e. the core action of the app.
    window := LOG_IniInt(CFG_FILE, "Settings", "ArchiveDupDays", 0, "archive")
    if window < 0
        return 0
    want  := NormalizeMass(raw)
    today := ArchiveDayStamp(FormatTime(, "yyyy-MM-dd"))
    if want = "" || today = ""
        return 0
    other := 0
    for e in ReadArchiveEntries() {
        if NormalizeMass(e.content) != want
            continue
        stamp := ArchiveDayStamp(e.ts)
        if stamp = ""
            continue
        age := DateDiff(today, stamp, "Days")
        if !(age >= 0 && age <= window)
            continue
        if (StrLower(Trim(e.model)) = StrLower(Trim(mName)))
            return e
        if !other
            other := e
    }
    return other
}

; ArchiveDuplicatePrompt stood here: a Yes/No dialog raised mid-parse whenever the
; mass was already archived. It is gone, not disabled — a duplicate is now just
; skipped, which is what "No" (its default button) did on every one of them. See
; the caller in ParseCurrent.

ClearArchiveTip() {
    ToolTip()
}

; Windows only themes these controls if asked; without it a dark BackColor still
; leaves white scrollbars and a white ListView header.
ArchiveDarkTheme(guiObj, ctrls) {
    static LVM_GETHEADER := 0x101F
    for attr in [20, 19]              ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", guiObj.Hwnd, "int", attr, "int*", 1, "int", 4)
    for c in ctrls {
        try DllCall("uxtheme\SetWindowTheme", "ptr", c.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
        ; The column header is a separate SysHeader32 child and does NOT inherit the
        ; list's theme. DarkMode_Explorer, not DarkMode_ItemsView — the latter
        ; darkens the header but leaves its label text dark, so it reads blank.
        if c.Type = "ListView" {
            hHdr := SendMessage(LVM_GETHEADER, 0, 0, c)
            if hHdr
                try DllCall("uxtheme\SetWindowTheme", "ptr", hHdr, "str", "DarkMode_Explorer", "ptr", 0)
        }
    }
}

ArchiveCueBanner(ctrl, text) {
    static EM_SETCUEBANNER := 0x1501
    SendMessage(EM_SETCUEBANNER, 1, StrPtr(text), ctrl)
}

; A mass is multi-line; the list column needs one line.
ArchiveFlatten(s) {
    s := StrReplace(StrReplace(s, "`r`n", " "), "`n", " ")
    return RegExReplace(Trim(s), "\s+", " ")
}

OpenArchive(*) {
    global edPaste, g
    if !FileExist(ArchiveFile()) {
        MsgBox "No archive file found."
        return
    }
    entries := ReadArchiveEntries()
    if !entries.Length {
        MsgBox "Archive is empty."
        return
    }

    ; newest first — the one you want is nearly always the most recent
    all := []
    Loop entries.Length
        all.Push(entries[entries.Length - A_Index + 1])

    ; same palette as hotstrings_window.ahk (dark violet, Infloww family)
    BG      := "15141C"
    SURFACE := "201E2B"
    LISTBG  := "1B1A24"
    FIELDBG := "2A2836"
    TXT     := "E6E4EE"
    MUTED   := "8E8AA6"
    ACCENT  := "B89CFF"

    ag := Gui("+Owner" g.Hwnd " +Resize +MinSize640x420", "Mass Archive")
    ag.BackColor := BG
    ag.MarginX := 0
    ag.MarginY := 0

    ag.SetFont("s15 Bold c" ACCENT, "Segoe UI")
    ag.Add("Text", "x16 y12 w420", Chr(0x2726) "  Mass Archive")
    ag.SetFont("s11 Norm c" MUTED, "Segoe UI")
    lblCount := ag.Add("Text", "x440 y21 w264 Right", "")

    ag.SetFont("s12 c" TXT, "Segoe UI")
    edSearch := ag.Add("Edit", "x16 y48 w688 h32 Background" FIELDBG)
    ArchiveCueBanner(edSearch, "Search model or message text" Chr(0x2026)
                             . "   (spaces = all terms must match)")

    ag.SetFont("s11 c" TXT, "Segoe UI")
    lv := ag.Add("ListView", "x16 y92 w688 h232 -Multi Background" LISTBG,
                 ["When", "Model", "Preview", "idx"])
    lv.ModifyCol(1, 155)
    lv.ModifyCol(2, 90)
    lv.ModifyCol(3, 405)              ; leaves room for the vertical scrollbar
    lv.ModifyCol(4, 0)                ; hidden: index into `all`, rides with its row

    edDetail := ag.Add("Edit", "x16 y334 w688 h152 ReadOnly +VScroll Background" SURFACE)

    ag.SetFont("s10 c" TXT, "Segoe UI")
    btnLoad   := ag.Add("Button", "x16  y498 w110 h30", "Load")
    btnCopy   := ag.Add("Button", "x132 y498 w110 h30", "Copy")
    btnDelete := ag.Add("Button", "x248 y498 w110 h30", "Delete")
    btnClose  := ag.Add("Button", "x614 y498 w90  h30", "Close")

    edSearch.OnEvent("Change",      DoSearch)
    lv.OnEvent("ItemFocus",         DoFocus)
    lv.OnEvent("DoubleClick",       DoLoad)
    btnLoad.OnEvent("Click",        DoLoad)
    btnCopy.OnEvent("Click",        DoCopy)
    btnDelete.OnEvent("Click",      DoDelete)
    btnClose.OnEvent("Click",       DoClose)
    ag.OnEvent("Close",             DoClose)
    ag.OnEvent("Escape",            DoClose)
    ag.OnEvent("Size",              DoSize)

    ArchiveDarkTheme(ag, [lv, edDetail, edSearch])
    THEME_BoldButtons(ag)
    Populate("")
    ag.Show("w720 h542")
    return

    ; wantRow keeps the caret where it was across a delete; without it every
    ; delete jumps you back to the top of the list.
    Populate(query, wantRow := 1) {
        terms := []
        for t in StrSplit(Trim(query), " ")
            if t != ""
                terms.Push(t)

        lv.Opt("-Redraw")
        lv.Delete()
        shown := 0
        for i, e in all {
            if Matches(e, terms) {
                lv.Add(, e.ts, e.model, ArchiveFlatten(e.preview), i)
                shown++
            }
        }
        lv.Opt("+Redraw")

        lblCount.Value := (shown = all.Length)
            ? all.Length " masses"
            : shown " of " all.Length " shown"

        if shown {
            wantRow := Max(1, Min(wantRow, shown))
            lv.Modify(wantRow, "Select Focus Vis")
            DoFocus(lv, wantRow)
        } else {
            edDetail.Value := "No matches."
        }
    }

    ; Search the whole mass, not just the preview — the line you remember is
    ; usually in the middle of it, which is the point of having a search box.
    Matches(e, terms) {
        if !terms.Length
            return true
        hay := e.ts " " e.model " " e.content
        for t in terms
            if !InStr(hay, t, false)
                return false
        return true
    }

    Selected() {
        row := lv.GetNext(0)
        if !row
            return 0
        ; Column 4 is a hidden index the Populate loop writes. LOG_Int rather than
        ; Integer(): an empty or non-numeric cell (a row added by any future code
        ; path that forgets column 4) threw on SELECTION, so clicking a row in the
        ; archive raised an error dialog instead of showing the mass.
        idx := LOG_Int(lv.GetText(row, 4), 0, "archive row index")
        return (idx >= 1 && idx <= all.Length) ? idx : 0
    }

    DoSearch(*) {
        Populate(edSearch.Value)
    }

    DoFocus(ctrl, row) {
        if !row || row > ctrl.GetCount()
            return
        idx := LOG_Int(ctrl.GetText(row, 4), 0, "archive row index")
        if idx < 1 || idx > all.Length
            return
        e := all[idx]
        edDetail.Value := e.ts "   " Chr(0x2022) "   " e.model "`r`n`r`n" e.content
    }

    DoLoad(*) {
        idx := Selected()
        if !idx
            return
        edPaste.Value := all[idx].content
        DoClose()
    }

    DoCopy(*) {
        idx := Selected()
        if !idx
            return
        A_Clipboard := all[idx].content
        ToolTip("Copied to clipboard")
        SetTimer(ClearArchiveTip, -1200)
    }

    ; Once a mass has left the paste box the archive is the only copy of it, so
    ; this confirms and shows the text — a timestamp and a model name are not
    ; enough to tell two masses apart at a glance.
    DoDelete(*) {
        row := lv.GetNext(0)
        idx := Selected()
        if !idx
            return
        e := all[idx]
        body := ArchiveFlatten(e.content)
        if (StrLen(body) > 220)
            body := SubStr(body, 1, 220) Chr(0x2026)
        if (MsgBox("Delete this mass from the archive?`n`n"
                 . e.ts "   " Chr(0x2022) "   " e.model "`n`n"
                 . (body = "" ? "(empty)" : body)
                 . "`n`nThis cannot be undone.", "Delete from archive", 0x24) != "Yes")
            return

        if !DeleteArchiveEntry(e) {
            MsgBox("Could not delete it. The archive file may have changed or be in use.",
                   "Delete from archive", 0x30)
            return
        }
        all.RemoveAt(idx)
        if !all.Length {
            DoClose()
            return
        }
        Populate(edSearch.Value, row)
        ToolTip("Deleted from archive")
        SetTimer(ClearArchiveTip, -1200)
    }

    DoClose(*) {
        ag.Destroy()
    }

    DoSize(guiObj, minMax, W, H) {
        if minMax = -1                ; minimised: dimensions are meaningless
            return
        pad  := 16
        cw   := W - pad * 2
        listH := H - 310              ; footer + detail keep fixed heights
        if listH < 80
            listH := 80
        lblCount.Move(pad + 240, 21, cw - 240)
        edSearch.Move(pad, 48, cw)
        lv.Move(pad, 92, cw, listH)
        lv.ModifyCol(3, cw - 265)     ; 155 + 90 cols + scrollbar
        edDetail.Move(pad, 92 + listH + 10, cw, H - (92 + listH + 10) - 56)
        btnLoad.Move(pad, H - 44)
        btnCopy.Move(pad + 116, H - 44)
        btnDelete.Move(pad + 232, H - 44)
        btnClose.Move(W - pad - 90, H - 44)
    }
}

ExportMMA(*) {
    global tabs, edCtrls, edPaste
    mNo     := tabs.Value
    result  := ""
    fuGroups := [["fu1","fu1_5","fu1_7"], ["fu2","fu2_5","fu2_7"], ["fu3","fu3_5","fu3_7"]]
    ppvFus   := ["ppv_f1", "ppv_f2", "ppv_f3"]

    GetVal(prop) {
        ck := "m" mNo "_" prop
        return edCtrls.Has(ck) ? Trim(edCtrls[ck].Value) : ""
    }

    ; One branch's lines for one group, as `::name text` — the same marker the
    ; parser reads, so an export pasted back in rebuilds what it came from.
    ; Branches with nothing in this group contribute nothing, which is why an
    ; f1-only branch does not litter the f2 block with empty markers.
    BranchLines(grp) {
        out := ""
        Loop MASS_BRANCH_MAX {
            k  := A_Index
            nm := GetVal("br" k "_name")
            if (nm = "")
                nm := "br" k          ; unnamed but filled in: it still has to round-trip
            for _, part in MASS_SplitParts(GetVal("br" k "_" grp))
                out .= "::" nm " " part "`n"
        }
        return out
    }

    v := GetVal("mass")
    if (v != "") {
        v := StrReplace(StrReplace(v, "`r`n", "`n"), "`r", "`n")
        ; A mass that spans lines cannot go on the marker line — the line ends at
        ; the first break and the rest would come back as follow-ups. It is written
        ; as a block under a bare `!mma`, closed by a `---` fence so whatever
        ; follows is still read as the follow-ups it is. MassHeaderBlock in
        ; mass/parser.ahk is the half that reads this back.
        result .= InStr(v, "`n") ? "!mma`n" v "`n---`n" : "!mma " v "`n"
    }

    for gi, grp in fuGroups {
        block := ""
        for _, prop in grp {
            v := GetVal(prop)
            if (v != "")
                block .= v "`n"
        }
        block .= BranchLines("fu" gi)
        if (block != "")
            result .= "`n" block
    }

    v := GetVal("ppv_base")
    _ppvBr := BranchLines("ppv")
    if (v != "" || _ppvBr != "") {
        v := StrReplace(StrReplace(v, "`r`n", "`n"), "`r", "`n")
        result .= "`n" (v != "" ? v "`n" : "ppv`n") _ppvBr
    }

    block := ""
    for _, prop in ppvFus {
        v := GetVal(prop)
        if (v != "")
            block .= v "`n"
    }
    if (block != "")
        result .= "`n" block

    edPaste.Value := Trim(result)
}
