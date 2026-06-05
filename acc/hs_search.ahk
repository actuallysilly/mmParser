#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../utils.ahk"

ROOT_DIR   := A_ScriptDir "\.."
allEntries := []
visList    := []

; ─── Parser ───────────────────────────────────────────────────────────────────

LoadAll() {
    global allEntries, ROOT_DIR
    allEntries := []
    files := []
    gp := ROOT_DIR "\general.ahk"
    if FileExist(gp)
        files.Push(gp)
    Loop Files, ROOT_DIR "\acc\*.ahk" {
        if A_LoopFileName != "hs_search.ahk"
            files.Push(A_LoopFilePath)
    }
    for fp in files
        for e in ParseFile(fp)
            allEntries.Push(e)
}

UnescAHK(s) {
    s := StrReplace(s, "``n",  "`n")
    s := StrReplace(s, "``t",  "`t")
    s := StrReplace(s, Chr(96) Chr(34), Chr(34))
    s := StrReplace(s, Chr(96) Chr(59), Chr(59))
    s := StrReplace(s, Chr(96) Chr(96), Chr(96))
    return s
}

ParseFile(filePath) {
    q34 := Chr(34)
    out  := []
    if !FileExist(filePath)
        return out
    content := FileRead(filePath, "UTF-8")
    SplitPath filePath, &fname
    pos := 1
    while RegExMatch(content, ":[\*?]*:([^:`r`n]+)::\s*\{([^}]*)\}", &m, pos) {
        pos     := m.Pos + m.Len
        trigger := Trim(m[1])
        block   := m[2]
        textLines := []
        for ln in StrSplit(block, "`n") {
            ln := Trim(StrReplace(ln, "`r", ""))
            if RegExMatch(ln, "i)^snd\(" q34 "(.*)" q34 "\)\s*$", &sm)
                textLines.Push({text: UnescAHK(sm[1]), fn: "snd"})
            else if RegExMatch(ln, "i)^SendText\(" q34 "(.*)" q34 "\)\s*$", &stm)
                textLines.Push({text: UnescAHK(stm[1]), fn: "send"})
        }
        if textLines.Length
            out.Push({trigger: trigger, lines: textLines, file: fname})
    }
    return out
}

; ─── GUI ──────────────────────────────────────────────────────────────────────

!1:: ShowSearch()

ShowSearch() {
    global allEntries, visList

    if WinExist("HS Search") {
        WinActivate "HS Search"
        return
    }

    LoadAll()
    prevHwnd := WinExist("A")

    sg := Gui("-MaximizeBox +AlwaysOnTop", "HS Search")
    sg.SetFont("s10", "Segoe UI")

    edSearch := sg.Add("Edit", "x10 y10 w600 h24")

    lv := sg.Add("ListView",
        "x10 y44 w600 h360 -Multi -Hdr NoSortHdr AltSubmit",
        ["Trigger", "Preview", "File"])
    lv.ModifyCol(1, 155)
    lv.ModifyCol(2, 355)
    lv.ModifyCol(3, 75)
    lv.SetFont("s9")

    sg.Add("Text", "x10 y414 w600 cGray",
        "-- prefix = search by name   ·   Enter / dbl-click = send   ·   Esc = close")

    ; Hidden default button catches Enter while edit has focus
    btnSend := sg.Add("Button", "x0 y0 w1 h1 Default", "")
    btnSend.OnEvent("Click", (*) => SendSelected(lv, sg, prevHwnd))

    lv.OnEvent("DoubleClick", (*) => SendSelected(lv, sg, prevHwnd))
    sg.OnEvent("Escape", (*) => sg.Destroy())
    sg.OnEvent("Close",  (*) => sg.Destroy())

    edSearch.OnEvent("Change", (*) => PopulateList(edSearch.Value, lv))

    PopulateList("", lv)

    sg.Show("w620 h440")
    edSearch.Focus()
}

PopulateList(query, lv) {
    global allEntries, visList
    lv.Delete()
    visList := []

    q      := Trim(query)
    byName := SubStr(q, 1, 2) = "--"
    if byName
        q := Trim(SubStr(q, 3))
    q := StrLower(q)

    for i, entry in allEntries {
        matched := false
        if q = "" {
            matched := true
        } else if byName {
            matched := !!InStr(StrLower(entry.trigger), q)
        } else {
            hay := StrLower(entry.trigger)
            for ln in entry.lines
                hay .= " " StrLower(ln.text)
            matched := !!InStr(hay, q)
        }
        if matched {
            lv.Add(, entry.trigger, entry.lines[1].text, entry.file)
            visList.Push(i)
        }
    }

    if lv.GetCount() > 0
        lv.Modify(1, "Select Focus")
}

SendSelected(lv, sg, prevHwnd) {
    global allEntries, visList

    row := lv.GetNext(0, "F")
    if !row
        row := lv.GetNext()
    if !row
        return

    entry := allEntries[visList[row]]
    sg.Destroy()

    if prevHwnd
        WinActivate "ahk_id " prevHwnd
    Sleep(150)

    for ln in entry.lines {
        if ln.fn = "snd"
            snd(ln.text)
        else
            SendText(ln.text)
    }
}
