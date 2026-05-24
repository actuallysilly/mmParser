#Requires AutoHotkey v2.0
#SingleInstance Force
DetectHiddenWindows true

; ─── Data ─────────────────────────────────────────────────────────────────────

fieldDefs := [
    ["mass",     "!mm",    true],
    ["fu1",      "f1",     false],
    ["fu1_5",    "f1.5",   false],
    ["fu1_7",    "f1.7",   true],
    ["fu2",      "f2",     false],
    ["fu2_5",    "f2.5",   false],
    ["fu2_7",    "f2.7",   true],
    ["fu3",      "f3",     false],
    ["fu3_5",    "f3.5",   false],
    ["fu3_7",    "f3.7",   true],
    ["ppv_base", "ppv",    false],
    ["ppv_f1",   "ppvfu1", false],
    ["ppv_f2",   "ppvfu2", false],
    ["ppv_f3",   "ppvfu3", false],
]

keyMap := Map(
    "!mm",    "mass",    "!mma",   "mass",    "mm",     "mass",    "mma",    "mass",
    "f1",     "fu1",     "f1.5",   "fu1_5",   "f1.7",   "fu1_7",
    "f2",     "fu2",     "f2.5",   "fu2_5",   "f2.7",   "fu2_7",
    "f3",     "fu3",     "f3.5",   "fu3_5",   "f3.7",   "fu3_7",
    "ppv",    "ppv_base",
    "ppvfu1", "ppv_f1",  "ppvfu2", "ppv_f2",  "ppvfu3", "ppv_f3"
)

AHK_CHARS  := ["``", Chr(34), ";"]   ; backtick must be first

edCtrls    := Map()
scriptPIDs := Map()   ; path → PID for toggle tracking
togCtrls   := []      ; [{c, x, oy}] script toggle section, y moves on resize
topCtrls   := []      ; [{c, ox}]       — right-panel top labels, x-slide on resize
btnCtrls   := []      ; [{c, ox, oy}]   — right-panel buttons, x+y move on resize
resizables := []      ; edit controls inside tabs, width grows on resize

; ─── Layout constants ─────────────────────────────────────────────────────────

SCRIPT_DIR   := A_ScriptDir
ACC_DIR      := A_ScriptDir "\acc"
CFG_FILE     := A_ScriptDir "\mass_gui.cfg"
_verFile     := A_ScriptDir "\version.txt"
APP_VER      := FileExist(_verFile) ? Trim(FileRead(_verFile, "UTF-8")) : "?"
_codePath    := EnvGet("LOCALAPPDATA") "\Programs\Microsoft VS Code\Code.exe"
CODE_CMD     := FileExist(_codePath) ? _codePath : "C:\Program Files\Microsoft VS Code\Code.exe"
model1Name   := IniRead(CFG_FILE, "Settings", "Model1",    "Model 1")
model2Name   := IniRead(CFG_FILE, "Settings", "Model2",    "Model 2")
UPDATE_URL   := IniRead(CFG_FILE, "Update",   "URL",       "https://raw.githubusercontent.com/actuallysilly/mmParser/main")
hk1_f1    := IniRead(CFG_FILE, "Hotkeys", "M1_f1",    "F1")
hk1_f2    := IniRead(CFG_FILE, "Hotkeys", "M1_f2",    "F2")
hk1_f3    := IniRead(CFG_FILE, "Hotkeys", "M1_f3",    "F3")
hk1_ppv   := IniRead(CFG_FILE, "Hotkeys", "M1_ppv",   "F4")
hk1_ppvfu := IniRead(CFG_FILE, "Hotkeys", "M1_ppvfu", "F5")
hk2_f1    := IniRead(CFG_FILE, "Hotkeys", "M2_f1",    "F9")
hk2_f2    := IniRead(CFG_FILE, "Hotkeys", "M2_f2",    "F10")
hk2_f3    := IniRead(CFG_FILE, "Hotkeys", "M2_f3",    "F11")
hk2_ppv   := IniRead(CFG_FILE, "Hotkeys", "M2_ppv",   "F12")
hk2_ppvfu := IniRead(CFG_FILE, "Hotkeys", "M2_ppvfu", "!F12")
TOGGLE_H     := 90           ; height reserved below tabs for script toggles (2 rows)
RIGHT_W      := 468          ; paste+buttons panel (20% wider, right-anchored)
INIT_W       := 1178         ; grew by same amount to keep tab width unchanged
INIT_H       := 700
TAB_X        := 10           ; tabs on the LEFT
TAB_Y        := 10
FIELD_Y0     := TAB_Y + 30  ; tab header ~30 px
LABEL_X      := TAB_X + 12  ; = 22
EDIT_X       := TAB_X + 82  ; = 92
PX0          := INIT_W - RIGHT_W        ; = 710  initial right-panel x
INIT_TAB_W   := PX0 - TAB_X - 10       ; = 690
INIT_EDIT_W  := INIT_TAB_W - (EDIT_X - TAB_X) - 15   ; = 593
PASTE_H0     := Floor((INIT_H - 20) * 0.52)
BTN_ORIG_Y0  := 26 + PASTE_H0 + 12

; ─── GUI ──────────────────────────────────────────────────────────────────────

g := Gui("+Resize +MinSize750x500", "MMA v" APP_VER)
g.SetFont("s9", "Segoe UI")

; ── Right panel helpers ────────────────────────────────────────────────────────

RegTop(ctrl, ox) {
    global topCtrls
    topCtrls.Push({c: ctrl, ox: ox})
}

RegBtn(ctrl, ox, oy) {
    global btnCtrls
    btnCtrls.Push({c: ctrl, ox: ox, oy: oy})
}

; ── Right: paste area (top) ────────────────────────────────────────────────────

c := g.Add("Text",   "x" PX0         " y10", "Paste block:")
RegTop(c, 0)
c := g.Add("Text",   "x" (PX0+88)   " y10", "(blank = group sep  *  ppv = ppv section)")
RegTop(c, 88)
edPaste := g.Add("Edit", "x" (PX0+10) " y26 w" (RIGHT_W-20) " h" PASTE_H0 " Multi -Wrap")

; ── Right: buttons (bottom) ────────────────────────────────────────────────────

BY := BTN_ORIG_Y0


c := g.Add("Button", "x" PX0       " y" BY      " w85  h28", "Parse")
c.OnEvent("Click", ParseCurrent)
RegBtn(c, 0, 0)

c := g.Add("Button", "x" (PX0+95)  " y" BY      " w85  h28", "Clear")
c.OnEvent("Click", ClearAll)
RegBtn(c, 95, 0)

c := g.Add("Button", "x" (PX0+190) " y" BY      " w120 h28", "Export !mma")
c.OnEvent("Click", ExportMMA)
RegBtn(c, 190, 0)

c := g.Add("Text",   "x" PX0       " y" (BY+36),  "-- Load fields from file --")
RegBtn(c, 0, 36)
lblLoaded := g.Add("Text", "x" (PX0+190) " y" (BY+36) " w250", "")
RegBtn(lblLoaded, 190, 36)

btnLoadM1 := g.Add("Button", "x" PX0       " y" (BY+54)  " w175 h28", "load " model1Name)
btnLoadM1.OnEvent("Click", (*) => LoadFile("1_mass.ahk"))
RegBtn(btnLoadM1, 0, 54)

btnLoadM2 := g.Add("Button", "x" (PX0+185) " y" (BY+54)  " w175 h28", "load " model2Name)
btnLoadM2.OnEvent("Click", (*) => LoadFile("2_mass.ahk"))
RegBtn(btnLoadM2, 185, 54)

c := g.Add("Text",   "x" PX0       " y" (BY+92),  "-- Apply to file --")
RegBtn(c, 0, 92)

btnSaveM1 := g.Add("Button", "x" PX0       " y" (BY+110) " w175 h28", "save " model1Name "")
btnSaveM1.OnEvent("Click", (*) => ApplyFile("1_mass.ahk"))
RegBtn(btnSaveM1, 0, 110)

btnSaveM2 := g.Add("Button", "x" (PX0+185) " y" (BY+110) " w175 h28", "save " model2Name "")
btnSaveM2.OnEvent("Click", (*) => ApplyFile("2_mass.ahk"))
RegBtn(btnSaveM2, 185, 110)

c := g.Add("Text",   "x" PX0       " y" (BY+148), "-- Set massNo --")
RegBtn(c, 0, 148)

c := g.Add("Text",   "x" PX0       " y" (BY+170), "M1:")
RegBtn(c, 0, 170)
xA := PX0 + 28
xOff := 28
Loop 3 {
    n := A_Index
    c := g.Add("Button", "x" xA " y" (BY+166) " w40 h28", n)
    c.OnEvent("Click", SetMassNo.Bind("1_mass.ahk", n))
    RegBtn(c, xOff, 166)
    xA += 44 , xOff += 44
}

c := g.Add("Text",   "x" (PX0+160)  " y" (BY+170), "M2:")
RegBtn(c, 160, 170)
xA := PX0 + 188
xOff := 188
Loop 3 {
    n := A_Index
    c := g.Add("Button", "x" xA " y" (BY+166) " w40 h28", n)
    c.OnEvent("Click", SetMassNo.Bind("2_mass.ahk", n))
    RegBtn(c, xOff, 166)
    xA += 44 , xOff += 44
}

; ── Left: tabs ─────────────────────────────────────────────────────────────────

tabs := g.Add("Tab3", "x" TAB_X " y" TAB_Y " w" INIT_TAB_W " h" (INIT_H - TAB_Y - 10 - TOGGLE_H),
              ["Mass 1", "Mass 2", "Mass 3"])

Loop 3 {
    mNo := A_Index
    tabs.UseTab(mNo)
    y := FIELD_Y0
    for _, fd in fieldDefs {
        prop  := fd[1]
        label := fd[2]
        sep   := fd[3]
        g.Add("Text", "x" LABEL_X " y" y " w65 Right", label ":")
        if prop = "ppv_base" {
            ec := g.Add("Edit", "x" EDIT_X " y" (y-2) " w" INIT_EDIT_W " h103 Multi")
            edCtrls["m" mNo "_" prop] := ec
            resizables.Push(ec)
            y += 109
        } else {
            ec := g.Add("Edit", "x" EDIT_X " y" (y-2) " w" INIT_EDIT_W " h22")
            edCtrls["m" mNo "_" prop] := ec
            resizables.Push(ec)
            y += 27
            if sep
                y += 6
        }
    }
}
tabs.UseTab()

; ── Script toggle section (below mass tabs) ────────────────────────────────────

TOGG_Y0 := INIT_H - TOGGLE_H + 8   ; initial y of this section

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w130 h28", "Open with Code")
c.OnEvent("Click", (*) => Run(Chr(34) CODE_CMD Chr(34) " " Chr(34) SCRIPT_DIR Chr(34)))
togCtrls.Push({c: c, x: TAB_X, oy: 0})

c := g.Add("Button", "x" (TAB_X+140) " y" TOGG_Y0 " w80 h28", "Settings")
c.OnEvent("Click", OpenSettings)
togCtrls.Push({c: c, x: TAB_X+140, oy: 0})

c := g.Add("Button", "x" (TAB_X+230) " y" TOGG_Y0 " w95 h28", "Add Hotkey")
c.OnEvent("Click", OpenAddHotkey)
togCtrls.Push({c: c, x: TAB_X+230, oy: 0})

c := g.Add("Button", "x" (TAB_X+335) " y" TOGG_Y0 " w85 h28", "Wipe Temp")
c.OnEvent("Click", WipeTemp)
togCtrls.Push({c: c, x: TAB_X+335, oy: 0})
                           
c := g.Add("Button", "x" (TAB_X+430) " y" TOGG_Y0 " w85 h28", "How to Use")
c.OnEvent("Click", OpenGuide)
togCtrls.Push({c: c, x: TAB_X+430, oy: 0})

c := g.Add("Button", "x" (TAB_X+525) " y" TOGG_Y0 " w90 h28", "New Script")
c.OnEvent("Click", NewAccScript)
togCtrls.Push({c: c, x: TAB_X+525, oy: 0})

togX := TAB_X
Loop Files, ACC_DIR "\*.ahk" {
    spath := A_LoopFilePath
    sname := StrReplace(A_LoopFileName, ".ahk", "")
    if (A_LoopFileName = "mass_gui.ahk" || A_LoopFileName = "mass_gui copy.ahk")
        continue
    btn := g.Add("Button", "x" togX " y" (TOGG_Y0+34) " w70 h28", "◻ " sname)
    btn.OnEvent("Click", MakeScriptToggle(spath, btn))
    togCtrls.Push({c: btn, x: togX, oy: 34})
    togX += 80
}

g.Add("Text", "x" (INIT_W - 140) " y" (TOGG_Y0 + 38) " w130 Right", "made by actually.silly")

g.Show("w" INIT_W " h" INIT_H)
g.OnEvent("Size", OnResize)

; auto-start general.ahk from root if not already running
_gPath := A_ScriptDir "\general.ahk"
if FileExist(_gPath) && !WinExist(_gPath " ahk_class AutoHotkey")
    Run _gPath

; ─── Resize ───────────────────────────────────────────────────────────────────

OnResize(gObj, minMax, W, H) {
    global
    if minMax = -1
        return
    pasteX     := Round(W * 0.6)
    newPasteH  := Floor((H - 20) * 0.52)
    for _, tc in topCtrls
        tc.c.Move(pasteX + tc.ox)
    edPaste.Move(pasteX + 10,, W - pasteX - 20, newPasteH)
    newBtnOrig := 26 + newPasteH + 12
    for _, bc in btnCtrls
        bc.c.Move(pasteX + bc.ox, newBtnOrig + bc.oy)
    tabW  := pasteX - TAB_X - 10
    editW := tabW - (EDIT_X - TAB_X) - 15
    tabs.Move(,, tabW, H - TAB_Y - 10 - TOGGLE_H)
    for _, ec in resizables
        ec.Move(,, editW)
    togY := H - TOGGLE_H + 8
    for _, tc in togCtrls
        tc.c.Move(tc.x, togY + tc.oy)
}

; ─── Parse ────────────────────────────────────────────────────────────────────

ParseCurrent(*) {
    global
    raw := StrReplace(StrReplace(edPaste.Value, "`r`n", "`n"), "`r", "`n")
    mNo := tabs.Value
    pfx := "m" mNo "_"
    for k, c in edCtrls
        if SubStr(k, 1, 3) = pfx
            c.Value := ""
    FillTab(StrSplit(raw, "`n"), mNo)
}

ClearAll(*) {
    global
    edPaste.Value := ""
    for _, c in edCtrls
        c.Value := ""
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

    v := GetVal("mass")
    if (v != "")
        result .= "!mma " v "`n"

    for _, grp in fuGroups {
        block := ""
        for _, prop in grp {
            v := GetVal(prop)
            if (v != "")
                block .= v "`n"
        }
        if (block != "")
            result .= "`n" block
    }

    v := GetVal("ppv_base")
    if (v != "") {
        v := StrReplace(StrReplace(v, "`r`n", "`n"), "`r", "`n")
        result .= "`n" v "`n"
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

EscQ(s) {
    for _, ch in AHK_CHARS
        s := StrReplace(s, ch, "``" ch)
    return s
}

StripPrefix(s) {
    if RegExMatch(s, "i)^[Ff][Uu]?\s?\d+(?:\.\d+)?[:\s]+", &m)
        return SubStr(s, m.Len + 1)
    if RegExMatch(s, "^[^:]+:(?![)(])\s*", &m)
        return SubStr(s, m.Len + 1)
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

FillTab(lines, mNo) {
    global
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
                val := EscQ(Trim(m[2]))
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
    for _, rawLn in lines {
        t := Trim(rawLn)
        if RegExMatch(t, "i)^!?mm[a]?[\s:]+\s*(.*)", &m) {
            ck := "m" mNo "_mass"
            if edCtrls.Has(ck)
                edCtrls[ck].Value := EscQ(Trim(m[1]))
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
                    edCtrls[ck].Value := EscQ(Trim(pm[1]))
                continue
            }
            slot := FPrefixToSlot(t)
            if slot = ""
                continue
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := EscQ(StripPrefix(t))
        }
        return
    }

    ; ── pure positional mode: no prefixes, position within blank-groups ───────
    groups := [], cur := []
    for _, t in filtered {
        if t = "" {
            if cur.Length {
                groups.Push(cur)
                cur := []
            }
        } else
            cur.Push(t)
    }
    if cur.Length
        groups.Push(cur)

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
        firstLine := Trim(grp[1])

        ; ppv group — first line starts with "ppv"
        if RegExMatch(firstLine, "i)^ppv") {
            ppvParts := []
            if RegExMatch(firstLine, "i)^ppv\s+(.*)", &pm) && Trim(pm[1]) != ""
                ppvParts.Push(EscQ(Trim(pm[1])))
            for i, l in grp
                if i > 1
                    ppvParts.Push(EscQ(StripPrefix(Trim(l))))
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
                        edCtrls[ck].Value := EscQ(StripPrefix(Trim(fuGrp[si])))
                }
            }
            continue
        }

        ; regular f-group (f1 → f2 → f3 in order)
        fIdx++
        if fIdx > 3
            continue
        slots := fSlotGroups[fIdx]
        for si, slot in slots {
            if si > grp.Length
                break
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := EscQ(StripPrefix(Trim(grp[si])))
        }
    }
}

; ─── Load from file ───────────────────────────────────────────────────────────

LoadFile(fname) {
    global
    path := SCRIPT_DIR "\" fname
    if !FileExist(path) {
        MsgBox "File not found:`n" path,, 0x10
        return
    }
    content := FileRead(path, "UTF-8")
    props   := ["mass","fu1","fu1_5","fu1_7","fu2","fu2_5","fu2_7",
                "fu3","fu3_5","fu3_7","ppv_base","ppv_f1","ppv_f2","ppv_f3"]
    Loop 3 {
        mNo := A_Index
        if !RegExMatch(content, "m" mNo " := \{([^}]*)\}", &blk)
            continue
        blockText := blk[1]
        for _, prop in props {
            ck := "m" mNo "_" prop
            if RegExMatch(blockText, prop ": " Chr(34) "([^" Chr(34) "]*)", &mv) && edCtrls.Has(ck) {
                v := mv[1]
                if (prop = "ppv_base")
                    v := StrReplace(v, "``n", "`r`n")
                edCtrls[ck].Value := v
            }
        }
    }
    lblLoaded.Text := (fname = "1_mass.ahk" ? model1Name : model2Name) " loaded"
}

; ─── Apply to file ────────────────────────────────────────────────────────────

ApplyFile(fname) {
    global
    path := SCRIPT_DIR "\" fname
    content := FileExist(path) ? FileRead(path, "UTF-8") : BuildMassTemplate(fname)
    Loop 3 {
        mNo  := A_Index
        repl := BuildBlock(mNo)
        content := RegExReplace(content, "m" mNo " := \{[^}]*\}", repl, &n)
        if !n
            MsgBox "Warning: m" mNo " block not found in " fname,, 0x30
    }
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        MsgBox "Write error: " e.Message,, 0x10
        return
    }
    if MsgBox("Saved to " fname ".`nReload script now?", "Done", 0x24) = "Yes"
        Run path
}

BuildMassTemplate(fname) {
    q := Chr(34)
    SplitPath fname, , , , &base
    num := RegExReplace(base, "\D", "")
    if num = "2"
        hk := [hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu]
    else
        hk := [hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu]

    out := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " q "utils.ahk" q "`n`nmassNo := 1`n`n"
    Loop 3
        out .= BuildBlock(A_Index) "`n`n"

    BuildSwitch(slots*) {
        s := ""
        Loop 3 {
            mn := A_Index
            s .= "        case " mn ":`n"
            for _, prop in slots
                s .= "            snd(m" mn "." prop ")`n"
        }
        return s
    }

    sc := Chr(59)
    out .= hk[1] "::{ " sc " send fu1`n    switch massNo`n    {`n" BuildSwitch("fu1","fu1_5","fu1_7") "    }`n}`n`n"
    out .= hk[2] "::{ " sc " send fu2`n    switch massNo`n    {`n" BuildSwitch("fu2","fu2_5","fu2_7") "    }`n}`n`n"
    out .= hk[3] "::{ " sc " send fu3`n    switch massNo`n    {`n" BuildSwitch("fu3","fu3_5","fu3_7") "    }`n}`n`n"

    out .= hk[4] "::{ " sc " send ppv1`n    ppv := `"`"`n    switch massNo{`n"
    Loop 3
        out .= "        case " A_Index ": ppv := m" A_Index ".ppv_base`n"
    out .= "    }`n    A_Clipboard := ppv`n    ClipWait(0.1)`n    Send " q "^v" q "`n}`n`n"

    out .= hk[5] "::{ " sc " send ppv2`n    switch massNo`n    {`n" BuildSwitch("ppv_f1","ppv_f2","ppv_f3") "    }`n}`n"
    return out
}


BuildBlock(mNo) {
    global
    props  := ["mass","fu1","fu1_5","fu1_7","fu2","fu2_5","fu2_7",
               "fu3","fu3_5","fu3_7","ppv_base","ppv_f1","ppv_f2","ppv_f3"]
    breaks := Map("fu1_7", 1, "fu2_7", 1, "fu3_7", 1)
    out    := "m" mNo " := {`n"
    Loop props.Length {
        p     := props[A_Index]
        val   := edCtrls.Has("m" mNo "_" p) ? edCtrls["m" mNo "_" p].Value : ""
        if (p = "ppv_base")
            val := StrReplace(StrReplace(val, "`r`n", "``n"), "`n", "``n")
        comma := A_Index < props.Length ? "," : ""
        out   .= p ': "' val '"' comma "`n"
        if breaks.Has(p)
            out .= "`n"
    }
    return out . "}"
}

; ─── Script toggles ──────────────────────────────────────────────────────────

MakeScriptToggle(spath, btn) {
    return (*) => ToggleScript(spath, btn)
}

ToggleScript(path, btn) {
    SplitPath path, &fname
    label := StrReplace(fname, ".ahk", "")
    if WinExist(path " ahk_class AutoHotkey") {
        pid := WinGetPID(path " ahk_class AutoHotkey")
        ProcessClose pid
        btn.Text := "◻ " label
    } else {
        Run path
        btn.Text := "◼ " label
    }
}

; ─── Set massNo ───────────────────────────────────────────────────────────────

SetMassNo(fname, n, *) {
    global
    path := SCRIPT_DIR "\" fname
    if !FileExist(path) {
        MsgBox "File not found:`n" path,, 0x10
        return
    }
    content := FileRead(path, "UTF-8")
    content := RegExReplace(content, "massNo\s*:=\s*\d+", "massNo := " n, &cnt)
    if !cnt {
        MsgBox "massNo not found in " fname,, 0x30
        return
    }
    f := FileOpen(path, "w", "UTF-8")
    f.Write(content)
    f.Close()
    Run path
}

; ─── Settings ─────────────────────────────────────────────────────────────────

UpdateMassFileHotkeys(fname, newHK) {
    global SCRIPT_DIR
    path := SCRIPT_DIR "\" fname
    if !FileExist(path)
        return false
    content := FileRead(path, "UTF-8")
    labels  := ["fu1", "fu2", "fu3", "ppv1", "ppv2"]
    changed := false
    sc := Chr(59)
    for i, lbl in labels {
        newContent := RegExReplace(content, "m)^\S+(::\{ " sc " send " lbl ")", newHK[i] "$1", &n)
        if n {
            content := newContent
            changed  := true
        }
    }
    if changed {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
    }
    return changed
}

UpdateModelButtons() {
    global model1Name, model2Name, btnLoadM1, btnLoadM2, btnSaveM1, btnSaveM2
    btnLoadM1.Text := "load " model1Name
    btnLoadM2.Text := "load " model2Name
    btnSaveM1.Text := "save " model1Name "  (1_mass.ahk)"
    btnSaveM2.Text := "save " model2Name "  (2_mass.ahk)"
}

OpenSettings(*) {
    global model1Name, model2Name, CFG_FILE, g
    global hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu
    global hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu

    sg := Gui("+Owner" g.Hwnd, "Settings")
    sg.SetFont("s9", "Segoe UI")

    ; ── Model names ────────────────────────────────────────────────────────────
    sg.Add("Text", "x10 y15 w70 Right", "Model 1:")
    ed1 := sg.Add("Edit", "x85 y12 w150", model1Name)
    sg.Add("Text", "x250 y15 w70 Right", "Model 2:")
    ed2 := sg.Add("Edit", "x325 y12 w150", model2Name)

    ; ── Hotkey config ──────────────────────────────────────────────────────────
    sg.Add("Text", "x10 y50 w480", "── Hotkeys ───────────────────────────────────────────────────────")
    sg.Add("Text", "x85 y73 w80", "M1")
    sg.Add("Text", "x230 y73 w80", "M2")

    hkRows := [
        ["f1:",    hk1_f1,    hk2_f1],
        ["f2:",    hk1_f2,    hk2_f2],
        ["f3:",    hk1_f3,    hk2_f3],
        ["ppv:",   hk1_ppv,   hk2_ppv],
        ["ppvfu:", hk1_ppvfu, hk2_ppvfu],
    ]
    edHK1 := [], edHK2 := []
    y := 97
    for _, row in hkRows {
        sg.Add("Text", "x10 y" (y+3) " w70 Right", row[1])
        edHK1.Push(sg.Add("Edit", "x85 y" y " w80", row[2]))
        edHK2.Push(sg.Add("Edit", "x230 y" y " w80", row[3]))
        y += 30
    }

    sg.Add("Button", "x10  y" (y+10) " w85 h28", "Save").OnEvent("Click", SaveCfg)
    sg.Add("Button", "x105 y" (y+10) " w85 h28", "Reset").OnEvent("Click", ResetCfg)
    sg.Add("Button", "x380 y" (y+10) " w100 h28", "Check Update").OnEvent("Click", CheckUpdate)
    sg.Show("w490 h" (y + 55))

    SaveCfg(*) {
        global model1Name, model2Name, CFG_FILE
        global hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu
        global hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu

        model1Name := ed1.Value
        model2Name := ed2.Value
        IniWrite(model1Name, CFG_FILE, "Settings", "Model1")
        IniWrite(model2Name, CFG_FILE, "Settings", "Model2")
        UpdateModelButtons()

        hk1_f1    := edHK1[1].Value  ,  hk2_f1    := edHK2[1].Value
        hk1_f2    := edHK1[2].Value  ,  hk2_f2    := edHK2[2].Value
        hk1_f3    := edHK1[3].Value  ,  hk2_f3    := edHK2[3].Value
        hk1_ppv   := edHK1[4].Value  ,  hk2_ppv   := edHK2[4].Value
        hk1_ppvfu := edHK1[5].Value  ,  hk2_ppvfu := edHK2[5].Value

        IniWrite(hk1_f1,    CFG_FILE, "Hotkeys", "M1_f1")
        IniWrite(hk1_f2,    CFG_FILE, "Hotkeys", "M1_f2")
        IniWrite(hk1_f3,    CFG_FILE, "Hotkeys", "M1_f3")
        IniWrite(hk1_ppv,   CFG_FILE, "Hotkeys", "M1_ppv")
        IniWrite(hk1_ppvfu, CFG_FILE, "Hotkeys", "M1_ppvfu")
        IniWrite(hk2_f1,    CFG_FILE, "Hotkeys", "M2_f1")
        IniWrite(hk2_f2,    CFG_FILE, "Hotkeys", "M2_f2")
        IniWrite(hk2_f3,    CFG_FILE, "Hotkeys", "M2_f3")
        IniWrite(hk2_ppv,   CFG_FILE, "Hotkeys", "M2_ppv")
        IniWrite(hk2_ppvfu, CFG_FILE, "Hotkeys", "M2_ppvfu")

        c1 := UpdateMassFileHotkeys("1_mass.ahk", [hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu])
        c2 := UpdateMassFileHotkeys("2_mass.ahk", [hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu])
        sg.Destroy()
        if (c1 || c2) {
            msg := "Hotkeys updated in:"
            if c1
                msg .= "`n  1_mass.ahk"
            if c2
                msg .= "`n  2_mass.ahk"
            if MsgBox(msg "`nReload now?", "Done", 0x24) = "Yes" {
                p1 := SCRIPT_DIR "\1_mass.ahk"
                p2 := SCRIPT_DIR "\2_mass.ahk"
                if c1 && WinExist(p1 " ahk_class AutoHotkey") {
                    ProcessClose WinGetPID(p1 " ahk_class AutoHotkey")
                    Sleep 150
                    Run p1
                }
                if c2 && WinExist(p2 " ahk_class AutoHotkey") {
                    ProcessClose WinGetPID(p2 " ahk_class AutoHotkey")
                    Sleep 150
                    Run p2
                }
            }
        }
    }

    ResetCfg(*) {
        ed1.Value := "Model 1"
        ed2.Value := "Model 2"
        defs1 := ["F1","F2","F3","F4","F5"]
        defs2 := ["F9","F10","F11","F12","!F12"]
        for i, e in edHK1
            e.Value := defs1[i]
        for i, e in edHK2
            e.Value := defs2[i]
    }
}

FetchURL(url) {
    xhr := ComObject("MSXML2.XMLHTTP.6.0")
    xhr.Open("GET", url, false)
    xhr.SetRequestHeader("Cache-Control", "no-cache, no-store")
    xhr.SetRequestHeader("Pragma", "no-cache")
    xhr.SetRequestHeader("User-Agent", "mmParser-Updater")
    xhr.Send()
    if xhr.Status != 200
        throw Error("HTTP " xhr.Status)
    return xhr.ResponseText
}

CheckUpdate(*) {
    global UPDATE_URL, SCRIPT_DIR

    if UPDATE_URL = "" {
        MsgBox "No update URL configured.`nSet [Update] URL= in mass_gui.cfg.",, 0x10
        return
    }

    try {
        remoteVer := Trim(FetchURL(UPDATE_URL "/version.txt"))
    } catch {
        MsgBox "Could not reach update server.`nCheck your internet connection.",, 0x10
        return
    }

    localVerFile := SCRIPT_DIR "\version.txt"
    localVer := FileExist(localVerFile) ? Trim(FileRead(localVerFile, "UTF-8")) : "0"

    if remoteVer = localVer {
        MsgBox "Already up to date (v" localVer ").",, 0x40
        return
    }

    if MsgBox("Update available!`nInstalled: v" localVer "  →  Latest: v" remoteVer "`n`nDownload and restart now?", "Update", 0x24) != "Yes"
        return

    Run SCRIPT_DIR "\updater.ahk"
    ExitApp
}

OpenAddHotkey(*) {
    global ACC_DIR, SCRIPT_DIR, g
    fileList  := []
    filePaths := []
    _genPath := SCRIPT_DIR "\general.ahk"
    if FileExist(_genPath) {
        fileList.Push("general.ahk")
        filePaths.Push(_genPath)
    }
    Loop Files, ACC_DIR "\*.ahk" {
        fileList.Push(A_LoopFileName)
        filePaths.Push(A_LoopFilePath)
    }
    if !fileList.Length {
        MsgBox "No .ahk files found.",, 0x10
        return
    }
    W := Round(A_ScreenWidth * 0.8)
    ah := Gui("+Owner" g.Hwnd, "Add Hotkey")
    ah.SetFont("s9", "Segoe UI")
    ah.Add("Text",        "x10 y13",              "Ctrl (^), Alt (!), Shift (+) and Win (#)")
    ah.Add("Text",        "x10  y45 w55 Right",   "Hotkey:")
    edHk    := ah.Add("Edit",        "x70  y42 w200")
    ah.Add("Text",        "x280 y45 w40 Right",   "File:")
    ddl     := ah.Add("DropDownList", "x325 y41 w220", fileList)
    ddl.Value := 1
    for i, f in fileList
        if f = "TEMP.ahk" {
            ddl.Value := i
            break
        }
    rdSnd  := ah.Add("Radio", "x555 y44 Group Checked", "snd()")
    rdSend := ah.Add("Radio", "x625 y44",               "SendText()")
    ah.Add("Text",        "x730 y45 w55 Right",   "HS type:")
    rdHSStd  := ah.Add("Radio", "x790 y44 Group",         "::")
    rdHSWild := ah.Add("Radio", "x835 y44 Checked",       ":*:")
    ah.Add("Text",        "x10  y75 w55 Right",   "Lines:")
    edLines := ah.Add("Edit",        "x70  y72 w" (W-80) " h120 Multi")
    ah.Add("Button", "x10  y202 w85 h28", "Append").OnEvent("Click", DoAppend)
    ah.Add("Button", "x105 y202 w85 h28", "Cancel").OnEvent("Click", (*) => ah.Destroy())
    ah.Show("w" W " h245")

    DoAppend(*) {
        global ACC_DIR
        hk := Trim(edHk.Value)
        if hk = "" {
            MsgBox "Enter a hotkey or hotstring.",, 0x10
            return
        }
        if RegExMatch(hk, "^[\^!+#]")
            trigger := hk "::"
        else
            trigger := (rdHSWild.Value ? ":*:" : "::") hk "::"
        fn    := rdSnd.Value ? "snd" : "SendText"
        path  := filePaths[ddl.Value]
        raw   := StrReplace(StrReplace(edLines.Value, "`r`n", "`n"), "`r", "`n")
        block := "`n" trigger "`n{`n"
        for _, ln in StrSplit(raw, "`n") {
            t := Trim(ln)
            if t != ""
                block .= "    " fn '("' t '")`n'
        }
        block .= "}`n"
        try {
            f := FileOpen(path, "a", "UTF-8")
            f.Write(block)
            f.Close()
        } catch as e {
            MsgBox "Write error: " e.Message,, 0x10
            return
        }
        ah.Destroy()
        if WinExist(path " ahk_class AutoHotkey") {
            pid := WinGetPID(path " ahk_class AutoHotkey")
            ProcessClose pid
        }
        Run path
    }
}

NewAccScript(*) {
    global ACC_DIR, g
    ns := Gui("+Owner" g.Hwnd, "New Script")
    ns.SetFont("s9", "Segoe UI")
    ns.Add("Text",   "x10 y15 w80 Right", "Filename:")
    edName := ns.Add("Edit", "x95 y12 w160")
    ns.Add("Text",   "x260 y15",          ".ahk")
    ns.Add("Button", "x10 y50 w85 h28",   "Create").OnEvent("Click", DoCreate)
    ns.Add("Button", "x105 y50 w85 h28",  "Cancel").OnEvent("Click", (*) => ns.Destroy())
    ns.Show("w315 h90")

    DoCreate(*) {
        name := Trim(edName.Value)
        if name = "" {
            MsgBox "Enter a filename.",, 0x10
            return
        }
        name := RegExReplace(name, "i)\.ahk$", "")
        path := ACC_DIR "\" name ".ahk"
        if FileExist(path) {
            MsgBox "File already exists: " name ".ahk",, 0x10
            return
        }
        content := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " Chr(34) "../utils.ahk" Chr(34) "`n"
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
        ns.Destroy()
        if MsgBox("Created " name ".ahk`nReload to show toggle button?", "Done", 0x24) = "Yes"
            Reload
    }
}

OpenGuide(*) {
    global SCRIPT_DIR, g
    content := FileExist(SCRIPT_DIR "\guide.md") ? FileRead(SCRIPT_DIR "\guide.md") : "guide.md not found."
    gg := Gui("+Owner" g.Hwnd, "How to Use")
    gg.SetFont("s10", "Segoe UI")
    gg.Add("Edit", "x10 y10 w580 h420 Multi ReadOnly -Wrap", content)
    gg.Add("Button", "x10 y440 w80 h28", "Close").OnEvent("Click", (*) => gg.Destroy())
    gg.Show("w600 h480")
}

WipeTemp(*) {
    global ACC_DIR
    path    := ACC_DIR "\TEMP.ahk"
    headers := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " Chr(34) "../utils.ahk" Chr(34) "`n"
    f := FileOpen(path, "w", "UTF-8")
    f.Write(headers)
    f.Close()
    if WinExist(path " ahk_class AutoHotkey") {
        pid := WinGetPID(path " ahk_class AutoHotkey")
        ProcessClose pid
    }
    Run path
}
