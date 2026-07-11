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

b2FieldDefs := [
    ["b2_fu1",      "b2.f1",    false],
    ["b2_fu1_5",    "b2.f1.5",  false],
    ["b2_fu1_7",    "b2.f1.7",  true],
    ["b2_fu2",      "b2.f2",    false],
    ["b2_fu2_5",    "b2.f2.5",  false],
    ["b2_fu2_7",    "b2.f2.7",  true],
    ["b2_fu3",      "b2.f3",    false],
    ["b2_fu3_5",    "b2.f3.5",  false],
    ["b2_fu3_7",    "b2.f3.7",  true],
    ["b2_ppv_base", "b2.ppv",   false],
    ["b2_ppv_f1",   "b2.ppvf1", false],
    ["b2_ppv_f2",   "b2.ppvf2", false],
    ["b2_ppv_f3",   "b2.ppvf3", false],
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
modelCount        := Integer(IniRead(CFG_FILE, "Settings", "ModelCount",        "2"))
_utilsRaw         := FileExist(A_ScriptDir "\utils.ahk") ? FileRead(A_ScriptDir "\utils.ahk", "UTF-8") : ""
waitTime          := RegExMatch(_utilsRaw, "\bwaitTime\b\s*:=\s*(\d+)", &_wm) ? Integer(_wm[1]) : 350
model1Name        := IniRead(CFG_FILE, "Settings", "Model1",            "Model 1")
model2Name        := IniRead(CFG_FILE, "Settings", "Model2",            "Model 2")
model3Name        := IniRead(CFG_FILE, "Settings", "Model3",            "Model 3")
defaultHotkeyFile := IniRead(CFG_FILE, "Settings", "DefaultHotkeyFile", "TEMP.ahk")
mouseControl      := Integer(IniRead(CFG_FILE, "Settings", "MouseControl",      "1"))
openTabFu2        := Integer(IniRead(CFG_FILE, "Settings", "OpenTabFu2",        "0"))
openTabFu3        := Integer(IniRead(CFG_FILE, "Settings", "OpenTabFu3",        "0"))
openTabPpv        := Integer(IniRead(CFG_FILE, "Settings", "OpenTabPpv",        "0"))
walletCheckFu3    := Integer(IniRead(CFG_FILE, "Settings", "WalletCheckFu3",    "0"))
fastParseAutosave := Integer(IniRead(CFG_FILE, "Settings", "FastParseAutosave", "0"))
_hiddenRaw        := IniRead(CFG_FILE, "Settings", "HiddenScripts", "")
hiddenScripts     := Map()
for _h in StrSplit(_hiddenRaw, ",")
    if Trim(_h) != ""
        hiddenScripts[Trim(_h)] := true
; scripts auto-launched on startup (default general.ahk, preserving old behavior) + watchdog toggle
startupScripts    := []
for _s in StrSplit(IniRead(CFG_FILE, "Settings", "StartupScripts", "general.ahk"), ",")
    if Trim(_s) != ""
        startupScripts.Push(Trim(_s))
autoRestart       := Integer(IniRead(CFG_FILE, "Settings", "AutoRestart", "0"))
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
hk3_f1    := IniRead(CFG_FILE, "Hotkeys", "M3_f1",    "")
hk3_f2    := IniRead(CFG_FILE, "Hotkeys", "M3_f2",    "")
hk3_f3    := IniRead(CFG_FILE, "Hotkeys", "M3_f3",    "")
hk3_ppv   := IniRead(CFG_FILE, "Hotkeys", "M3_ppv",   "")
hk3_ppvfu := IniRead(CFG_FILE, "Hotkeys", "M3_ppvfu", "")
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

MakeLoader(f) => (*) => LoadFile(f)
MakeSaver(f)  => (*) => ApplyFile(f)

btnLoadM := []
btnSaveM := []

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

chkArchive := g.Add("Checkbox", "x" (PX0+322) " y" (BY+6) " Checked", "Archive")
RegBtn(chkArchive, 322, 6)

c := g.Add("Text", "x" PX0 " y" (BY+38) " w" (RIGHT_W-20) " h2 0x10")
RegBtn(c, 0, 38)

c := g.Add("Text",   "x" PX0 " y" (BY+52), "-- Load fields from file --")
RegBtn(c, 0, 52)
lblLoaded := g.Add("Text", "x" (PX0+190) " y" (BY+52) " w140", "")
RegBtn(lblLoaded, 190, 52)
c := g.Add("Button", "x" (PX0+338) " y" (BY+48) " w118 h22", "Load from archive")
c.OnEvent("Click", OpenArchive)
RegBtn(c, 338, 48)

_mNames := [model1Name, model2Name, model3Name]
_mFiles := ["1_mass.ahk", "2_mass.ahk", "3_mass.ahk"]
_mW     := modelCount = 3 ? 143 : 175
_mGap   := modelCount = 3 ? 8   : 10
xA := PX0, xOff := 0
Loop modelCount {
    i := A_Index
    btn := g.Add("Button", "x" xA " y" (BY+70) " w" _mW " h28", "load " _mNames[i])
    btn.OnEvent("Click", MakeLoader(_mFiles[i]))
    RegBtn(btn, xOff, 70)
    btnLoadM.Push(btn)
    xA += _mW + _mGap, xOff += _mW + _mGap
}

c := g.Add("Text", "x" PX0 " y" (BY+108), "-- Apply to file --")
RegBtn(c, 0, 108)

xA := PX0, xOff := 0
Loop modelCount {
    i := A_Index
    btn := g.Add("Button", "x" xA " y" (BY+126) " w" _mW " h28", "save " _mNames[i])
    btn.OnEvent("Click", MakeSaver(_mFiles[i]))
    RegBtn(btn, xOff, 126)
    btnSaveM.Push(btn)
    xA += _mW + _mGap, xOff += _mW + _mGap
}

c := g.Add("Text", "x" PX0 " y" (BY+164), "-- Set massNo --")
RegBtn(c, 0, 164)

Loop modelCount {
    i := A_Index
    _rowY := BY + 182 + (i - 1) * 34
    _file := _mFiles[i]
    c := g.Add("Text", "x" PX0 " y" (_rowY + 4), "M" i ":")
    RegBtn(c, 0, _rowY - BY)
    _curMassNo := ReadMassNo(_file)
    xA := PX0 + 30, xOff := 30
    Loop 3 {
        n := A_Index
        opt := (n = 1 ? "Group " : "") "x" xA " y" _rowY " w40 h24"
        c := g.Add("Radio", opt, n)
        c.Value := (n = _curMassNo)
        c.OnEvent("Click", SetMassNo.Bind(_file, n))
        RegBtn(c, xOff, _rowY - BY)
        xA += 44, xOff += 44
    }
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
c.OnEvent("Click", (*) => OpenAddHotkey())
togCtrls.Push({c: c, x: TAB_X+230, oy: 0})

c := g.Add("Button", "x" (TAB_X+335) " y" TOGG_Y0 " w85 h28", "How to Use")
c.OnEvent("Click", OpenGuide)
togCtrls.Push({c: c, x: TAB_X+335, oy: 0})

c := g.Add("Button", "x" (TAB_X+430) " y" TOGG_Y0 " w90 h28", "New Script")
c.OnEvent("Click", NewAccScript)
togCtrls.Push({c: c, x: TAB_X+430, oy: 0})

editFuChks := []
_edLbl := g.Add("Text", "x" (TAB_X+534) " y" (TOGG_Y0-11) " w18 Right", "Ed")
togCtrls.Push({c: _edLbl, x: TAB_X+534, oy: -11})
Loop 3 {
    _f := A_Index
    _xFu := TAB_X + 556 + (_f - 1) * 38
    _eChk := g.Add("Checkbox", "x" _xFu " y" (TOGG_Y0-13) " w34", "F" _f)
    _eChk.Value := IniRead(CFG_FILE, "Settings", "EditableFu" _f, "0") = "1"
    _eChk.OnEvent("Click", MakeEditFuToggle(_f))
    togCtrls.Push({c: _eChk, x: _xFu, oy: -13})
    editFuChks.Push(_eChk)
}

fuChks := []
Loop 3 {
    m := A_Index
    _oy := 4 + (m - 1) * 17
    lbl := g.Add("Text", "x" (TAB_X+534) " y" (TOGG_Y0+_oy+2) " w18 Right", "M" m)
    togCtrls.Push({c: lbl, x: TAB_X+534, oy: _oy+2})
    fuChks.Push([])
    Loop 3 {
        f := A_Index
        _xFu := TAB_X + 556 + (f - 1) * 38
        chk := g.Add("Checkbox", "x" _xFu " y" (TOGG_Y0+_oy) " w34", "F" f)
        chk.Value := IniRead(CFG_FILE, "Settings", "FuSingle_" m "_" f, "0") = "1"
        chk.OnEvent("Click", MakeFuToggle(m, f))
        togCtrls.Push({c: chk, x: _xFu, oy: _oy})
        fuChks[m].Push(chk)
    }
}

togX := TAB_X
Loop Files, ACC_DIR "\*.ahk" {
    spath := A_LoopFilePath
    sname := StrReplace(A_LoopFileName, ".ahk", "")
    if (A_LoopFileName = "mass_gui.ahk" || A_LoopFileName = "mass_gui copy.ahk")
        continue
    if hiddenScripts.Has(A_LoopFileName)
        continue
    btn := g.Add("Button", "x" togX " y" (TOGG_Y0+34) " w70 h28", "◻ " sname)
    btn.OnEvent("Click", MakeScriptToggle(spath, btn))
    togCtrls.Push({c: btn, x: togX, oy: 34})
    togX += 80
}


lblCredit := g.Add("Text", "x10 y" (TOGG_Y0 + 38), "made by actually.silly")

g.Show("w" INIT_W " h" INIT_H)
g.OnEvent("Size", OnResize)
g.OnEvent("Close", OnGuiClose)

; tray: one-click clean shutdown (right-click tray, or double-click the icon)
try {
    A_TrayMenu.Insert("1&", "Kill all scripts && Exit", (*) => KillAllAndExit())
    A_TrayMenu.Insert("2&")
    A_TrayMenu.Default := "Kill all scripts && Exit"
}

; ─── Or-Or window (hidden until or-or mode is parsed) ─────────────────────────

OOR_W     := 720
OOR_LABEL_X := 12
OOR_EDIT_X  := 82
OOR_EDIT_W  := OOR_W - OOR_EDIT_X - 30

gOrOr := Gui("+Resize +MinSize400x300", "Or-Or — Branch 2")
gOrOr.SetFont("s9", "Segoe UI")
oorTabs := gOrOr.Add("Tab3", "x10 y10 w" (OOR_W-20) " h560", ["M1", "M2", "M3"])

Loop 3 {
    mNo := A_Index
    oorTabs.UseTab(mNo)
    y := 40

    ec := gOrOr.Add("Edit", "x" OOR_EDIT_X " y" y " w0 h0")
    edCtrls["m" mNo "_orOr"] := ec

    gOrOr.Add("Text", "x" OOR_LABEL_X " y" (y+4) " w65 Right", "B1 label:")
    ec := gOrOr.Add("Edit", "x" OOR_EDIT_X " y" y " w130 h22 ReadOnly")
    edCtrls["m" mNo "_b1_label"] := ec
    gOrOr.Add("Text", "x" (OOR_EDIT_X+138) " y" (y+4), "B2 label:")
    ec := gOrOr.Add("Edit", "x" (OOR_EDIT_X+200) " y" y " w130 h22 ReadOnly")
    edCtrls["m" mNo "_b2_label"] := ec
    y += 32

    for _, fd in b2FieldDefs {
        prop  := fd[1]
        label := fd[2]
        sep   := fd[3]
        gOrOr.Add("Text", "x" OOR_LABEL_X " y" y " w65 Right", label ":")
        if prop = "b2_ppv_base" {
            ec := gOrOr.Add("Edit", "x" OOR_EDIT_X " y" (y-2) " w" OOR_EDIT_W " h103 Multi")
            edCtrls["m" mNo "_" prop] := ec
            y += 109
        } else {
            ec := gOrOr.Add("Edit", "x" OOR_EDIT_X " y" (y-2) " w" OOR_EDIT_W " h22")
            edCtrls["m" mNo "_" prop] := ec
            y += 27
            if sep
                y += 6
        }
    }
}
oorTabs.UseTab()

gOrOr.Add("Button", "x10 y580 w120 h28", "Save to file").OnEvent("Click", (*) => ApplyFile(["1_mass.ahk","2_mass.ahk","3_mass.ahk"][oorTabs.Value]))
gOrOr.Add("Button", "x140 y580 w80 h28", "Close").OnEvent("Click", (*) => gOrOr.Hide())

lblCredit.GetPos(, , &lblCreditW)
lblCredit.Move(INIT_W - lblCreditW - 10)

; auto-start configured startup scripts (defaults to general.ahk) if not already running
LaunchStartupScripts()
if autoRestart
    SetTimer(WatchdogTick, 5000)

SetTimer(() => CheckUpdate(true), -3000)  ; silent check 3s after startup

; ─── Resize ───────────────────────────────────────────────────────────────────

ApplyLayout(W, H) {
    global
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
    lblCredit.Move(W - lblCreditW - 10, togY + 38)
}

OnResize(gObj, minMax, W, H) {
    global
    if minMax = -1 || minMax = 1
        return  ; minimize: skip; maximize: WM_SIZE handler has correct dims
    ApplyLayout(W, H)
}

OnWMSize(wParam, lParam, *) {
    global g
    if wParam != 2  ; SIZE_MAXIMIZED = 2
        return
    ApplyLayout(lParam & 0xFFFF, lParam >> 16)
}
OnMessage(0x0005, OnWMSize)

; ─── Parse ────────────────────────────────────────────────────────────────────

AutoParseFromClipboard(wParam, lParam, msg, hwnd) {
    global
    edPaste.Value := A_Clipboard
    if fastParseAutosave {
        ParseCurrent()
        ApplyFile(_mFiles[tabs.Value], true)
    } else {
        PromptSaveTarget()
    }
}
OnMessage(0x8010, AutoParseFromClipboard) ; 0x8010: paste clipboard into edPaste + parse (from copyDiscordMessageSeq)

PromptSaveTarget() {
    global _mNames, _mFiles, tabs, modelCount, g
    names := []
    Loop modelCount
        names.Push(_mNames[A_Index])

    pg := Gui("+Owner" g.Hwnd, "Save parsed message")
    pg.SetFont("s9", "Segoe UI")
    pg.Add("Text", "x10 y14 w45", "Model:")
    ddlModel := pg.Add("DropDownList", "x60 y11 w150", names)
    ddlModel.Value := 1
    pg.Add("Text", "x10 y46 w45", "Mass #:")
    rd1 := pg.Add("Radio", "x60 y44 Group", "1")
    rd2 := pg.Add("Radio", "x105 y44", "2")
    rd3 := pg.Add("Radio", "x150 y44", "3")
    rd1.Value := true
    pg.Add("Button", "x10  y78 w95 h26 Default", "Parse + Save").OnEvent("Click", DoSave)
    pg.Add("Button", "x115 y78 w95 h26", "Cancel").OnEvent("Click", (*) => pg.Destroy())
    pg.Show("w230 h116")

    DoSave(*) {
        tabs.Value := rd1.Value ? 1 : rd2.Value ? 2 : 3
        ParseCurrent()
        ApplyFile(_mFiles[ddlModel.Value], true)
        pg.Destroy()
    }
}

ParseCurrent(*) {
    global
    raw := StrReplace(StrReplace(edPaste.Value, "`r`n", "`n"), "`r", "`n")
    mNo := tabs.Value
    pfx := "m" mNo "_"
    for k, c in edCtrls
        if SubStr(k, 1, 3) = pfx
            c.Value := ""
    FillTab(StrSplit(raw, "`n"), mNo)
    if chkArchive.Value && Trim(raw) != "" {
        mName := mNo = 1 ? model1Name : mNo = 2 ? model2Name : model3Name
        ts    := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend "[" ts "] [" mName "]`n" raw "`n===END===`n`n", A_ScriptDir "\mass_archive.txt", "UTF-8"
    }
}

ClearAll(*) {
    global
    edPaste.Value := ""
    for _, c in edCtrls
        c.Value := ""
}

OpenArchive(*) {
    global edPaste
    archiveFile := A_ScriptDir "\mass_archive.txt"
    if !FileExist(archiveFile) {
        MsgBox "No archive file found."
        return
    }
    raw     := FileRead(archiveFile, "UTF-8")
    chunks  := StrSplit(raw, "===END===")
    entries := []
    for chunk in chunks {
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
    if !entries.Length {
        MsgBox "Archive is empty."
        return
    }
    ag := Gui("+Owner" g.Hwnd, "Mass Archive")
    ag.BackColor := "1a1a1a"
    ag.SetFont("s9 cWhite", "Segoe UI")
    ag.MarginX := 10
    ag.MarginY := 10
    lv := ag.Add("ListView", "w660 h380 -Multi Background1a1a1a cWhite", ["Timestamp", "Model", "Preview"])
    lv.ModifyCol(1, 160)
    lv.ModifyCol(2, 80)
    lv.ModifyCol(3, 400)
    Loop entries.Length {
        e := entries[entries.Length - A_Index + 1]
        lv.Add("", e.ts, e.model, e.preview)
    }
    revEntries := []
    Loop entries.Length
        revEntries.Push(entries[entries.Length - A_Index + 1])
    ag.Add("Button", "w100 y+8", "Load").OnEvent("Click", DoLoad)
    ag.Add("Button", "w80 x+6",  "Close").OnEvent("Click", (*) => ag.Destroy())
    ag.Show("w680")
    lv.OnEvent("DoubleClick", DoLoad)
    DoLoad(*) {
        row := lv.GetNext(0)
        if !row
            return
        edPaste.Value := revEntries[row].content
        ag.Destroy()
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
    if RegExMatch(s, "^\S+:(?![)(])\s*", &m)
        return SubStr(s, m.Len + 1)
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

ParseBranch(lines, mNo, pfx) {
    global edCtrls
    groups := [], cur := []
    for _, rawLn in lines {
        t := Trim(rawLn)
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
        [pfx "fu1",  pfx "fu1_5", pfx "fu1_7"],
        [pfx "fu2",  pfx "fu2_5", pfx "fu2_7"],
        [pfx "fu3",  pfx "fu3_5", pfx "fu3_7"],
    ]
    fIdx := 0, skipIdx := 0
    for gi, grp in groups {
        if gi = skipIdx
            continue
        firstLine := Trim(grp[1])
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
            ck := "m" mNo "_" pfx "ppv_base"
            if edCtrls.Has(ck)
                edCtrls[ck].Value := ppvBase
            if gi + 1 <= groups.Length {
                skipIdx := gi + 1
                fuGrp := groups[gi + 1]
                for si, slot in [pfx "ppv_f1", pfx "ppv_f2", pfx "ppv_f3"] {
                    if si > fuGrp.Length
                        break
                    ck := "m" mNo "_" slot
                    if edCtrls.Has(ck)
                        edCtrls[ck].Value := StripPrefix(Trim(fuGrp[si]))
                }
            }
            continue
        }
        fIdx++
        if fIdx > 3
            continue
        slots := fSlotGroups[fIdx]
        for si, slot in slots {
            if si > grp.Length
                break
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := StripPrefix(Trim(grp[si]))
        }
    }
}

FillTab(lines, mNo) {
    global
    ; ── or-or mode detection ─────────────────────────────────────────────────────
    firstContent := ""
    for _, rawLn in lines {
        t := Trim(rawLn)
        if t != "" {
            firstContent := t
            break
        }
    }
    if RegExMatch(firstContent, "i)^!?mm[a]?\s+(.+?)\s+or\s+(.+)$", &om) {
        tagPositions := []
        for i, rawLn in lines {
            t := Trim(rawLn)
            if RegExMatch(t, "i)^(\w+):$", &tm) && StrLower(tm[1]) != "ppv"
                tagPositions.Push(i)
        }
        if tagPositions.Length >= 1 {
            b1Label := Trim(om[1])
            b2Label := Trim(om[2])
            for prop, val in Map("orOr", "1", "b1_label", b1Label, "b2_label", b2Label, "mass", b1Label " or " b2Label) {
                ck := "m" mNo "_" prop
                if edCtrls.Has(ck)
                    edCtrls[ck].Value := val
            }
            b1Lines := [], b2Lines := []
            if tagPositions.Length >= 2 {
                b1Start := tagPositions[1] + 1
                b2Start := tagPositions[2] + 1
                Loop tagPositions[2] - b1Start
                    b1Lines.Push(lines[b1Start + A_Index - 1])
                Loop lines.Length - b2Start + 1
                    b2Lines.Push(lines[b2Start + A_Index - 1])
            } else {
                b1Start := tagPositions[1] + 1
                Loop lines.Length - b1Start + 1
                    b1Lines.Push(lines[b1Start + A_Index - 1])
            }
            ParseBranch(b1Lines, mNo, "")
            ParseBranch(b2Lines, mNo, "b2_")
            oorTabs.Value := mNo
            gOrOr.Show("w" OOR_W " h620")
            return
        }
    }

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
        for si, slot in slots {
            if si > grp.Length
                break
            ck := "m" mNo "_" slot
            if edCtrls.Has(ck)
                edCtrls[ck].Value := StripPrefix(Trim(grp[si]))
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
                "fu3","fu3_5","fu3_7","ppv_base","ppv_f1","ppv_f2","ppv_f3",
                "orOr","b1_label","b2_label",
                "b2_fu1","b2_fu1_5","b2_fu1_7","b2_fu2","b2_fu2_5","b2_fu2_7",
                "b2_fu3","b2_fu3_5","b2_fu3_7","b2_ppv_base",
                "b2_ppv_f1","b2_ppv_f2","b2_ppv_f3"]
    Loop 3 {
        mNo := A_Index
        if !RegExMatch(content, "m" mNo " := \{([^}]*)\}", &blk)
            continue
        blockText := blk[1]
        for _, prop in props {
            ck := "m" mNo "_" prop
            if RegExMatch(blockText, prop ": " Chr(34) "((?:[^" Chr(34) Chr(96) "]|" Chr(96) ".)*)" Chr(34), &mv) && edCtrls.Has(ck) {
                v := mv[1]
                if (prop = "ppv_base" || prop = "b2_ppv_base")
                    v := StrReplace(v, "``n", "`r`n")
                edCtrls[ck].Value := UnescQ(v)
            }
        }
    }
    _nameMap := Map("1_mass.ahk", model1Name, "2_mass.ahk", model2Name, "3_mass.ahk", model3Name)
    lblLoaded.Text := (_nameMap.Has(fname) ? _nameMap[fname] : fname) " loaded"
}

; ─── Apply to file ────────────────────────────────────────────────────────────

ApplyFile(fname, silent := false) {
    global
    path := SCRIPT_DIR "\" fname
    allEmpty := true
    for _, c in edCtrls {
        if Trim(c.Value) != "" {
            allEmpty := false
            break
        }
    }
    if allEmpty {
        if silent
            return
        if MsgBox("All fields are empty. Save anyway?", "Confirm Save", 0x24) != "Yes"
            return
    }
    content := FileExist(path) ? FileRead(path, "UTF-8") : BuildMassTemplate(fname)
    Loop 3 {
        mNo  := A_Index
        repl := BuildBlock(mNo)
        content := RegExReplace(content, "m" mNo " := \{[^}]*\}", repl, &n)
        if !n && !silent
            MsgBox "Warning: m" mNo " block not found in " fname,, 0x30
    }
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(content)
        f.Close()
    } catch as e {
        if !silent
            MsgBox "Write error: " e.Message,, 0x10
        return
    }
    if silent
        return
    if MsgBox("Saved to " fname ".`nReload script now?", "Done", 0x24) = "Yes"
        Run path
}

BuildMassTemplate(fname) {
    q := Chr(34)
    SplitPath fname, , , , &base
    num := RegExReplace(base, "\D", "")
    if num = "3"
        hk := [hk3_f1, hk3_f2, hk3_f3, hk3_ppv, hk3_ppvfu]
    else if num = "2"
        hk := [hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu]
    else
        hk := [hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu]

    out := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " q "utils.ahk" q "`n`nmassNo := 1`nmodelFileNo := " num "`n`n"
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

    BuildSwitchFu(group, slots*) {
        s := ""
        Loop 3 {
            mn := A_Index
            s .= "        case " mn ":`n"
            args := group
            for _, prop in slots
                args .= ", m" mn "." prop
            s .= "            sndFu(" args ")`n"
        }
        return s
    }

    sc := Chr(59)
    out .= hk[1] "::{ " sc " send fu1`n    switch massNo`n    {`n" BuildSwitchFu(1, "fu1","fu1_5","fu1_7") "    }`n}`n`n"
    out .= hk[2] "::{ " sc " send fu2`n    switch massNo`n    {`n" BuildSwitchFu(2, "fu2","fu2_5","fu2_7") "    }`n}`n`n"
    out .= hk[3] "::{ " sc " send fu3`n    switch massNo`n    {`n" BuildSwitchFu(3, "fu3","fu3_5","fu3_7") "    }`n}`n`n"

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
               "fu3","fu3_5","fu3_7","ppv_base","ppv_f1","ppv_f2","ppv_f3",
               "orOr","b1_label","b2_label",
               "b2_fu1","b2_fu1_5","b2_fu1_7","b2_fu2","b2_fu2_5","b2_fu2_7",
               "b2_fu3","b2_fu3_5","b2_fu3_7","b2_ppv_base",
               "b2_ppv_f1","b2_ppv_f2","b2_ppv_f3"]
    breaks := Map("fu1_7", 1, "fu2_7", 1, "fu3_7", 1, "ppv_f3", 1, "b2_fu1_7", 1, "b2_fu2_7", 1, "b2_fu3_7", 1)
    out    := "m" mNo " := {`n"
    Loop props.Length {
        p     := props[A_Index]
        val   := edCtrls.Has("m" mNo "_" p) ? edCtrls["m" mNo "_" p].Value : ""
        val   := EscQ(val)
        if (p = "ppv_base" || p = "b2_ppv_base")
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

; ─── Clean exit / startup / watchdog ──────────────────────────────────────────

; X on the panel: ask whether to also tear down the running scripts.
OnGuiClose(*) {
    r := MsgBox("Close all running scripts too?"
              . "`n`nYes = kill every script in this folder and exit"
              . "`nNo = exit this panel only"
              . "`nCancel = keep everything open", "Exit MMA", 0x23)  ; YesNoCancel + question icon
    if r = "Cancel"
        return true                      ; keep the window open
    if r = "Yes"
        KillAllScripts()
    ExitApp
}

KillAllAndExit(*) {
    KillAllScripts()
    ExitApp
}

; ProcessClose every AutoHotkey script launched from this folder (except this GUI).
KillAllScripts() {
    global SCRIPT_DIR
    try SetTimer(WatchdogTick, 0)        ; stop watchdog first so it can't relaunch anything
    myPID := ProcessExist()
    DetectHiddenWindows true
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        pid := WinGetPID("ahk_id " hwnd)
        if pid = myPID
            continue
        if InStr(WinGetTitle("ahk_id " hwnd), SCRIPT_DIR)
            try ProcessClose(pid)
    }
}

; startup scripts may live in the root or in acc\
ResolveScriptPath(fname) {
    global SCRIPT_DIR, ACC_DIR
    if FileExist(SCRIPT_DIR "\" fname)
        return SCRIPT_DIR "\" fname
    if FileExist(ACC_DIR "\" fname)
        return ACC_DIR "\" fname
    return ""
}

; run each configured startup script that isn't already running (also used by the watchdog)
LaunchStartupScripts() {
    global startupScripts
    for fname in startupScripts {
        path := ResolveScriptPath(fname)
        if path != "" && !WinExist(path " ahk_class AutoHotkey")
            try Run(path)
    }
}

WatchdogTick() {
    LaunchStartupScripts()
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

ReadMassNo(fname) {
    global SCRIPT_DIR
    path := SCRIPT_DIR "\" fname
    if !FileExist(path)
        return 1
    content := FileRead(path, "UTF-8")
    if RegExMatch(content, "massNo\s*:=\s*(\d+)", &m)
        return Integer(m[1])
    return 1
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
    global modelCount, model1Name, model2Name, model3Name, btnLoadM, btnSaveM
    _mNames := [model1Name, model2Name, model3Name]
    Loop modelCount {
        i := A_Index
        btnLoadM[i].Text := "load " _mNames[i]
        btnSaveM[i].Text := "save " _mNames[i]
    }
}

OpenSettings(*) {
    global model1Name, model2Name, model3Name, modelCount, CFG_FILE, g
    global hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu
    global hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu
    global hk3_f1, hk3_f2, hk3_f3, hk3_ppv, hk3_ppvfu
    global defaultHotkeyFile, ACC_DIR, SCRIPT_DIR, mouseControl
    global startupScripts, autoRestart

    _dhfList := []
    _genPath2 := SCRIPT_DIR "\general.ahk"
    if FileExist(_genPath2)
        _dhfList.Push("general.ahk")
    Loop Files, ACC_DIR "\*.ahk"
        _dhfList.Push(A_LoopFileName)

    sg := Gui("+Owner" g.Hwnd, "Settings")
    sg.SetFont("s9", "Segoe UI")

    ; ── Model count ────────────────────────────────────────────────────────────
    sg.Add("Text", "x10 y15", "Active models:")
    rdMC1 := sg.Add("Radio", "x118 y12 Group", "1")
    rdMC2 := sg.Add("Radio", "x158 y12",       "2")
    rdMC3 := sg.Add("Radio", "x198 y12",       "3")
    rdMC1.Value := modelCount = 1
    rdMC2.Value := modelCount = 2
    rdMC3.Value := modelCount = 3

    ; ── Model names ────────────────────────────────────────────────────────────
    sg.Add("Text", "x10  y48 w70 Right", "Model 1:")
    ed1 := sg.Add("Edit", "x85  y45 w120", model1Name)
    sg.Add("Text", "x215 y48 w70 Right", "Model 2:")
    ed2 := sg.Add("Edit", "x290 y45 w120", model2Name)
    sg.Add("Text", "x420 y48 w70 Right", "Model 3:")
    ed3 := sg.Add("Edit", "x495 y45 w95",  model3Name)

    sg.Add("Text", "x10 y78 w70 Right", "Wait time:")
    edWT := sg.Add("Edit", "x85 y75 w60", waitTime)
    sg.Add("Text", "x150 y78", "ms")
    sg.Add("Text", "x220 y78 w80 Right", "Default file:")
    ddlDef := sg.Add("DropDownList", "x305 y75 w165", _dhfList)
    chkMC := sg.Add("Checkbox", "x480 y78", "Mouse control")
    chkMC.Value := mouseControl
    for i, f in _dhfList
        if f = defaultHotkeyFile {
            ddlDef.Value := i
            break
        }
    if ddlDef.Value = 0
        ddlDef.Value := 1

    ; ── Hotkey config ──────────────────────────────────────────────────────────
    sg.Add("Text", "x10 y115 w590", "── Hotkeys ─────────────────────────────────────────────────────────────────")
    sg.Add("Text", "x70  y138", "M1")
    sg.Add("Text", "x230 y138", "M2")
    sg.Add("Text", "x390 y138", "M3")

    hkRows := [
        ["f1:",    hk1_f1,    hk2_f1,    hk3_f1],
        ["f2:",    hk1_f2,    hk2_f2,    hk3_f2],
        ["f3:",    hk1_f3,    hk2_f3,    hk3_f3],
        ["ppv:",   hk1_ppv,   hk2_ppv,   hk3_ppv],
        ["ppvfu:", hk1_ppvfu, hk2_ppvfu, hk3_ppvfu],
    ]
    edHK1 := [], edHK2 := [], edHK3 := []
    y := 162
    for _, row in hkRows {
        sg.Add("Text", "x10 y" (y+3) " w55 Right", row[1])
        edHK1.Push(sg.Add("Edit", "x70  y" y " w100", row[2]))
        edHK2.Push(sg.Add("Edit", "x230 y" y " w100", row[3]))
        edHK3.Push(sg.Add("Edit", "x390 y" y " w100", row[4]))
        y += 30
    }

    sg.Add("Text",   "x10  y" (y+8)  " w580 h2 0x10")
    y += 22
    sg.Add("Text",   "x10  y" (y+8)  " w200", "── Open new tab after send ──")
    chkTabFu2 := sg.Add("Checkbox", "x10  y" (y+28), "FU2")
    chkTabFu3 := sg.Add("Checkbox", "x70  y" (y+28), "FU3")
    chkTabPpv := sg.Add("Checkbox", "x130 y" (y+28), "PPV")
    chkTabFu2.Value := openTabFu2
    chkTabFu3.Value := openTabFu3
    chkTabPpv.Value := openTabPpv
    chkDMM    := sg.Add("Checkbox", "x230 y" (y+28), "Double MM")
    chkDMM.Value := _doubleMM
    chkDMM.OnEvent("Click", (*) => (ToggleDoubleMM(), chkDMM.Value := _doubleMM))
    chkWallet := sg.Add("Checkbox", "x330 y" (y+28), "Wallet check FU3")
    chkWallet.Value := walletCheckFu3
    chkWallet.OnEvent("Click", (*) => _BroadcastWallet(chkWallet.Value ? 1 : 0))
    chkFastSave := sg.Add("Checkbox", "x10 y" (y+52), "Fast parse+autosave (auto-saves current model, no prompts)")
    chkFastSave.Value := fastParseAutosave
    y += 80
    sg.Add("Text",   "x10  y" (y+8)  " w580 h2 0x10")
    y += 22
    sg.Add("Text",   "x10  y" (y+8)  " w200", "── Visible scripts ──")
    accChks := Map()
    xSc := 10
    Loop Files, ACC_DIR "\*.ahk" {
        fname := A_LoopFileName
        chk := sg.Add("Checkbox", "x" xSc " y" (y+28), StrReplace(fname, ".ahk", ""))
        chk.Value := !hiddenScripts.Has(fname)
        accChks[fname] := chk
        xSc += 80
    }
    y += 52
    sg.Add("Text",   "x10  y" (y+8)  " w200", "── Run on startup ──")
    startChks := Map()
    _startSet := Map()
    for _s in startupScripts
        _startSet[_s] := true
    _eligible := []
    if FileExist(SCRIPT_DIR "\general.ahk")
        _eligible.Push("general.ahk")
    for _mf in ["1_mass.ahk", "2_mass.ahk", "3_mass.ahk"]
        if FileExist(SCRIPT_DIR "\" _mf)
            _eligible.Push(_mf)
    Loop Files, ACC_DIR "\*.ahk"
        _eligible.Push(A_LoopFileName)
    _sx := 10, _sy := y + 28
    for _, efn in _eligible {
        chk := sg.Add("Checkbox", "x" _sx " y" _sy, StrReplace(efn, ".ahk", ""))
        chk.Value := _startSet.Has(efn)
        startChks[efn] := chk
        _sx += 90
        if _sx > 500 {
            _sx := 10
            _sy += 24
        }
    }
    chkAutoRestart := sg.Add("Checkbox", "x10 y" (_sy + 30), "Auto-restart these if they die (watchdog, checks every 5s)")
    chkAutoRestart.Value := autoRestart
    y := _sy + 56
    sg.Add("Text",   "x10  y" (y+8)  " w580 h2 0x10")
    sg.Add("Button", "x10  y" (y+18) " w85 h28",  "Save").OnEvent("Click", SaveCfg)
    sg.Add("Button", "x105 y" (y+18) " w85 h28",  "Reset").OnEvent("Click", ResetCfg)
    sg.Add("Button", "x200 y" (y+18) " w90 h28",  "Wipe Temp").OnEvent("Click", (*) => (WipeTemp(), sg.Destroy()))
    sg.Add("Button", "x300 y" (y+18) " w85 h28",  "Report Bug").OnEvent("Click", (*) => Run("https://github.com/actuallysilly/mmParser/issues/new?title=Bug+Report&labels=bug"))
    sg.Add("Button", "x490 y" (y+18) " w100 h28", "Check Update").OnEvent("Click", (*) => CheckUpdate())
    sg.Show("w600 h" (y + 62))

    SaveCfg(*) {
        global model1Name, model2Name, model3Name, modelCount, CFG_FILE
        global hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu
        global hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu
        global hk3_f1, hk3_f2, hk3_f3, hk3_ppv, hk3_ppvfu
        global defaultHotkeyFile, mouseControl, fastParseAutosave
        global startupScripts, autoRestart

        newCount          := rdMC1.Value ? 1 : rdMC2.Value ? 2 : 3
        model1Name        := ed1.Value
        model2Name        := ed2.Value
        model3Name        := ed3.Value
        waitTime          := Max(50, Integer(edWT.Value))
        defaultHotkeyFile := ddlDef.Text
        IniWrite(newCount,          CFG_FILE, "Settings", "ModelCount")
        IniWrite(model1Name,        CFG_FILE, "Settings", "Model1")
        IniWrite(model2Name,        CFG_FILE, "Settings", "Model2")
        IniWrite(model3Name,        CFG_FILE, "Settings", "Model3")
        IniWrite(defaultHotkeyFile, CFG_FILE, "Settings", "DefaultHotkeyFile")
        _uPath := SCRIPT_DIR "\utils.ahk"
        _uContent := FileRead(_uPath, "UTF-8")
        _uContent := RegExReplace(_uContent, "\bwaitTime\b\s*:=\s*\d+", "waitTime     := " waitTime)
        _f := FileOpen(_uPath, "w", "UTF-8")
        _f.Write(_uContent)
        _f.Close()
        UpdateModelButtons()

        hk1_f1    := edHK1[1].Value , hk2_f1    := edHK2[1].Value , hk3_f1    := edHK3[1].Value
        hk1_f2    := edHK1[2].Value , hk2_f2    := edHK2[2].Value , hk3_f2    := edHK3[2].Value
        hk1_f3    := edHK1[3].Value , hk2_f3    := edHK2[3].Value , hk3_f3    := edHK3[3].Value
        hk1_ppv   := edHK1[4].Value , hk2_ppv   := edHK2[4].Value , hk3_ppv   := edHK3[4].Value
        hk1_ppvfu := edHK1[5].Value , hk2_ppvfu := edHK2[5].Value , hk3_ppvfu := edHK3[5].Value

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
        IniWrite(hk3_f1,    CFG_FILE, "Hotkeys", "M3_f1")
        IniWrite(hk3_f2,    CFG_FILE, "Hotkeys", "M3_f2")
        IniWrite(hk3_f3,    CFG_FILE, "Hotkeys", "M3_f3")
        IniWrite(hk3_ppv,   CFG_FILE, "Hotkeys", "M3_ppv")
        IniWrite(hk3_ppvfu, CFG_FILE, "Hotkeys", "M3_ppvfu")

        newMC := chkMC.Value ? 1 : 0
        mcChanged := (newMC != mouseControl)
        mouseControl := newMC
        IniWrite(mouseControl,         CFG_FILE, "Settings", "MouseControl")
        openTabFu2 := chkTabFu2.Value ? 1 : 0
        openTabFu3 := chkTabFu3.Value ? 1 : 0
        openTabPpv := chkTabPpv.Value ? 1 : 0
        IniWrite(openTabFu2, CFG_FILE, "Settings", "OpenTabFu2")
        IniWrite(openTabFu3, CFG_FILE, "Settings", "OpenTabFu3")
        IniWrite(openTabPpv, CFG_FILE, "Settings", "OpenTabPpv")
        walletCheckFu3 := chkWallet.Value ? 1 : 0
        IniWrite(walletCheckFu3, CFG_FILE, "Settings", "WalletCheckFu3")
        fastParseAutosave := chkFastSave.Value ? 1 : 0
        IniWrite(fastParseAutosave, CFG_FILE, "Settings", "FastParseAutosave")
        _hiddenList := ""
        for fname, chk in accChks
            if !chk.Value
                _hiddenList .= (_hiddenList != "" ? "," : "") fname
        hiddenScripts := Map()
        for _h in StrSplit(_hiddenList, ",")
            if Trim(_h) != ""
                hiddenScripts[Trim(_h)] := true
        IniWrite(_hiddenList, CFG_FILE, "Settings", "HiddenScripts")

        _startupCsv := ""
        for efn, chk in startChks
            if chk.Value
                _startupCsv .= (_startupCsv != "" ? "," : "") efn
        IniWrite(_startupCsv, CFG_FILE, "Settings", "StartupScripts")
        autoRestart := chkAutoRestart.Value ? 1 : 0
        IniWrite(autoRestart, CFG_FILE, "Settings", "AutoRestart")
        startupScripts := []
        for _s in StrSplit(_startupCsv, ",")
            if Trim(_s) != ""
                startupScripts.Push(Trim(_s))
        SetTimer(WatchdogTick, autoRestart ? 5000 : 0)
        LaunchStartupScripts()

        c1 := UpdateMassFileHotkeys("1_mass.ahk", [hk1_f1, hk1_f2, hk1_f3, hk1_ppv, hk1_ppvfu]) || mcChanged
        c2 := UpdateMassFileHotkeys("2_mass.ahk", [hk2_f1, hk2_f2, hk2_f3, hk2_ppv, hk2_ppvfu])
        c3 := hk3_f1 != "" ? UpdateMassFileHotkeys("3_mass.ahk", [hk3_f1, hk3_f2, hk3_f3, hk3_ppv, hk3_ppvfu]) : false
        sg.Destroy()

        if newCount != modelCount {
            modelCount := newCount
            Reload
            return
        }

        if (c1 || c2 || c3) {
            msg := "Hotkeys updated in:"
            if c1
                msg .= "`n  1_mass.ahk"
            if c2
                msg .= "`n  2_mass.ahk"
            if c3
                msg .= "`n  3_mass.ahk"
            if MsgBox(msg "`nReload now?", "Done", 0x24) = "Yes" {
                fnames := []
                if c1
                    fnames.Push("1_mass.ahk")
                if c2
                    fnames.Push("2_mass.ahk")
                if c3
                    fnames.Push("3_mass.ahk")
                for fname in fnames {
                    p := SCRIPT_DIR "\" fname
                    if WinExist(p " ahk_class AutoHotkey") {
                        ProcessClose WinGetPID(p " ahk_class AutoHotkey")
                        Sleep 150
                        Run p
                    }
                }
            }
        }
    }

    ResetCfg(*) {
        ed1.Value := "Model 1"
        ed2.Value := "Model 2"
        ed3.Value := "Model 3"
        edWT.Value := "350"
        rdMC2.Value := true
        defs1 := ["F1", "F2", "F3", "F4",  "F5"]
        defs2 := ["F9", "F10","F11","F12", "!F12"]
        defs3 := ["",   "",   "",   "",    ""]
        for i, e in edHK1
            e.Value := defs1[i]
        for i, e in edHK2
            e.Value := defs2[i]
        for i, e in edHK3
            e.Value := defs3[i]
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

CheckUpdate(silent := false, *) {
    global UPDATE_URL, SCRIPT_DIR

    if UPDATE_URL = "" {
        if !silent
            MsgBox "No update URL configured.`nSet [Update] URL= in mass_gui.cfg.",, 0x10
        return
    }

    try {
        remoteVer := Trim(FetchURL(UPDATE_URL "/version.txt"))
    } catch {
        if !silent
            MsgBox "Could not reach update server.`nCheck your internet connection.",, 0x10
        return
    }

    localVerFile := SCRIPT_DIR "\version.txt"
    localVer := FileExist(localVerFile) ? Trim(FileRead(localVerFile, "UTF-8")) : "0"

    if remoteVer = localVer {
        if !silent
            MsgBox "Already up to date (v" localVer ").",, 0x40
        return
    }

    if MsgBox("Update available!`nInstalled: v" localVer "  →  Latest: v" remoteVer "`n`nDownload and restart now?", "Update", 0x24) != "Yes"
        return

    Run SCRIPT_DIR "\updater.ahk"
    ExitApp
}

OpenAddHotkey(prefill := "", *) {
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
        if f = defaultHotkeyFile {
            ddl.Value := i
            break
        }
    rdSnd   := ah.Add("Radio", "x555 y44 Group Checked", "snd()")
    rdSend  := ah.Add("Radio", "x625 y44",               "SendText()")
    rdSendt := ah.Add("Radio", "x715 y44",               "Sendt()")
    ah.Add("Text",  "x800 y47 w25 Right", "ms:")
    edSendtMs := ah.Add("Edit", "x828 y44 w55 h20 Number")
    edSendtMs.Enabled := false
    rdSendt.OnEvent("Click", (*) => edSendtMs.Enabled := true)
    rdSnd.OnEvent("Click",   (*) => edSendtMs.Enabled := false)
    rdSend.OnEvent("Click",  (*) => edSendtMs.Enabled := false)
    ah.Add("Text",        "x900 y45 w55 Right",   "HS type:")
    rdHSStd  := ah.Add("Radio", "x960 y44 Group",         "::")
    rdHSWild := ah.Add("Radio", "x1005 y44 Checked",      ":*:")
    ah.Add("Text",        "x10  y75 w55 Right",   "Lines:")
    edLines := ah.Add("Edit",        "x70  y72 w" (W-80) " h120 Multi")
    if prefill != ""
        edLines.Value := prefill
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
            if t = ""
                continue
            if rdSendt.Value
                block .= '    Sendt("' t '", ' (Trim(edSendtMs.Value) != "" ? Integer(edSendtMs.Value) : 500) ')`n'
            else
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
        CheckCollisions()
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

MakeFuToggle(m, f) => (*) => ToggleFuCell(m, f)

ToggleFuCell(m, f) {
    global fuChks, CFG_FILE
    IniWrite(fuChks[m][f].Value ? "1" : "0", CFG_FILE, "Settings", "FuSingle_" m "_" f)
}

MakeEditFuToggle(f) => (*) => ToggleEditFuCell(f)

ToggleEditFuCell(f) {
    global editFuChks, CFG_FILE
    val := editFuChks[f].Value ? 1 : 0
    IniWrite(val, CFG_FILE, "Settings", "EditableFu" f)
    _BroadcastEditableFu(f, val)
}

_BroadcastEditableFu(f, val) {
    global SCRIPT_DIR, modelCount
    Loop modelCount {
        path := SCRIPT_DIR "\" A_Index "_mass.ahk"
        if WinExist(path " ahk_class AutoHotkey")
            PostMessage(0x8002 + f, val, 0, , path " ahk_class AutoHotkey")
    }
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

; ─── Collision checker ───────────────────────────────────────────────────────

CheckCollisions() {
    global SCRIPT_DIR, ACC_DIR

    files := []
    for fp in [SCRIPT_DIR "\utils.ahk", SCRIPT_DIR "\general.ahk"] {
        if FileExist(fp)
            files.Push(fp)
    }
    Loop Files, ACC_DIR "\*.ahk"
        files.Push(A_LoopFilePath)
    Loop 3 {
        fp := SCRIPT_DIR "\" A_Index "_mass.ahk"
        if FileExist(fp)
            files.Push(fp)
    }

    seen := Map()  ; trigger → Map(fname → 1)

    for fpath in files {
        SplitPath fpath, &fname
        content := FileRead(fpath, "UTF-8")
        for ln in StrSplit(StrReplace(StrReplace(content, "`r`n", "`n"), "`r", "`n"), "`n") {
            ln := Trim(ln)
            if ln = "" || SubStr(ln, 1, 1) = ";"
                continue
            trigger := ""
            if RegExMatch(ln, "^:[^:]*:([^:`r`n]+)::", &m)
                trigger := StrLower(Trim(m[1]))
            else if RegExMatch(ln, "^([^:\s]+)::", &m)
                trigger := StrLower(m[1])
            if trigger = ""
                continue
            if !seen.Has(trigger)
                seen[trigger] := Map()
            seen[trigger][fname] := 1
        }
    }

    collisions := []
    for trigger, fmap in seen {
        if fmap.Count > 1 {
            fnames := []
            for fn, _ in fmap
                fnames.Push(fn)
            collisions.Push(trigger "  →  " ArrJoin(fnames, ", "))
        }
    }

    if !collisions.Length
        return

    msg := "Collision warning — same trigger in multiple files:`n`n"
    for c in collisions
        msg .= "  " c "`n"
    MsgBox msg, "Collision Warning", 0x30
}

ArrJoin(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") v
    return out
}

!0:: {
    saved := A_Clipboard
    A_Clipboard := ""
    Send "^a"
    Sleep 50
    Send "^c"
    ClipWait 0.5
    grabbed := A_Clipboard
    A_Clipboard := saved
    OpenAddHotkey(grabbed)
}

; ─── Mouse control ────────────────────────────────────────────────────────────

_doubleMM := false

ToggleDoubleMM() {
    global SCRIPT_DIR, modelCount, _doubleMM
    _doubleMM := !_doubleMM
    Loop modelCount {
        path := SCRIPT_DIR "\" A_Index "_mass.ahk"
        if WinExist(path " ahk_class AutoHotkey")
            PostMessage(0x8001, 0, 0, , path " ahk_class AutoHotkey")
    }
    ToolTip("Double MM: " (_doubleMM ? "ON" : "OFF"))
    SetTimer(() => ToolTip(), -1500)
}

_BroadcastWallet(val) {
    global SCRIPT_DIR, modelCount, walletCheckFu3
    walletCheckFu3 := val
    Loop modelCount {
        path := SCRIPT_DIR "\" A_Index "_mass.ahk"
        if WinExist(path " ahk_class AutoHotkey")
            PostMessage(0x8002, val, 0, , path " ahk_class AutoHotkey")
    }
}

#HotIf mouseControl
MButton:: ToggleDoubleMM()
#HotIf

