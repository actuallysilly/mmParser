#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "hotkeys.ahk"
#Include "ocr_grab.ahk"
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

; ── Alt follow-ups ────────────────────────────────────────────────────────────
; A follow-up can carry alternative versions of itself ("branches"): same slot in
; the conversation, different wording. The base variant is fu<N>/fu<N>_5/fu<N>_7 as
; before; each alt is one more complete variant of the whole group.
;
; An alt may itself be multi-part, so its parts are stored in a single field joined
; by a literal `n — the same escape ppv_base already uses. Keeping it to one field
; per alt is what stops the mN block from growing 27 fields wider.
ALT_MAX    := 3                       ; alt0..alt2 per follow-up
ALT_GROUPS := ["fu1", "fu2", "fu3"]

; "fu1" -> ["fu1_alt0", "fu1_alt1", "fu1_alt2"]
AltFields(group) {
    global ALT_MAX
    out := []
    Loop ALT_MAX
        out.Push(group "_alt" (A_Index - 1))
    return out
}

; Every alt field, in block order. Used by the loader, the writer and the editor
; so a new alt slot only has to be declared in ALT_MAX.
AllAltFields() {
    global ALT_GROUPS
    out := []
    for _, grp in ALT_GROUPS
        for _, f in AltFields(grp)
            out.Push(f)
    return out
}

; ── Named branches ────────────────────────────────────────────────────────────
; A `--Name` marker in a pasted mass opens a whole alternate follow-up sequence
; (its own fu1/fu2/fu3 + ppv), sent as a continuation after the shared trunk. Each
; branch is stored in its own fields; a group's parts are `n-joined into one field,
; the same compact scheme the alts use. This REPLACED the old or-or (b2_*) branch.
BRANCH_MAX    := 3                     ; --Name branches per mass
BRANCH_GROUPS := ["fu1", "fu2", "fu3", "ppv"]

; branch 1 -> ["br1_name","br1_fu1","br1_fu2","br1_fu3","br1_ppv"]
BranchFields(k) {
    global BRANCH_GROUPS
    out := ["br" k "_name"]
    for _, grp in BRANCH_GROUPS
        out.Push("br" k "_" grp)
    return out
}

; Every branch field, in block order.
AllBranchFields() {
    global BRANCH_MAX
    out := []
    Loop BRANCH_MAX
        for _, f in BranchFields(A_Index)
            out.Push(f)
    return out
}

; The mN := {} field list, in block order. Single source of truth — the loader,
; the writer and the new-file template all read it, so adding a field here is
; enough. They used to carry three separate copies of this list.
MassBlockProps() {
    props := ["mass","fu1","fu1_5","fu1_7","fu2","fu2_5","fu2_7",
              "fu3","fu3_5","fu3_7","ppv_base","ppv_f1","ppv_f2","ppv_f3"]
    for _, f in AllBranchFields()
        props.Push(f)
    for _, f in AllAltFields()
        props.Push(f)
    props.Push("altGui")
    return props
}

; Fields whose value may span lines, so newlines survive the round trip as `n.
MassPropIsMultiline(prop) {
    if (prop = "ppv_base" || InStr(prop, "_alt"))
        return true
    return RegExMatch(prop, "^br\d+_(fu\d|ppv)$") > 0
}

; Parts of one stored alt, splitting the `n join back out.
AltParts(stored) {
    parts := []
    for _, p in StrSplit(StrReplace(StrReplace(stored, "`r`n", "`n"), "``n", "`n"), "`n")
        if Trim(p) != ""
            parts.Push(Trim(p))
    return parts
}

; Does this mass/follow-up carry at least one alt?
MassHasAlts(mNo, group) {
    global edCtrls
    for _, fld in AltFields(group) {
        ck := "m" mNo "_" fld
        if edCtrls.Has(ck) && Trim(edCtrls[ck].Value) != ""
            return true
    }
    return false
}

MakeAltGuiToggle(mNo) {
    return AltGuiToggled.Bind(mNo)
}

AltGuiToggled(mNo, *) {
    global altGuiChks, edCtrls
    ck := "m" mNo "_altGui"
    if edCtrls.Has(ck)
        edCtrls[ck].Value := altGuiChks[mNo].Value ? "1" : "0"
}

; Mirror the stored altGui values onto the checkboxes, and echo each base variant
; so the window is readable after a Load. Called on load and on parse.
RefreshAltWindow() {
    global edCtrls, altGuiChks, altBaseEcho, ALT_GROUPS
    Loop 3 {
        mNo := A_Index
        ck := "m" mNo "_altGui"
        if edCtrls.Has(ck) && altGuiChks.Has(mNo)
            altGuiChks[mNo].Value := (Trim(edCtrls[ck].Value) = "1")
        for _, grp in ALT_GROUPS {
            key := mNo "_" grp
            if !altBaseEcho.Has(key)
                continue
            parts := []
            for _, sfx in ["", "_5", "_7"] {
                bk := "m" mNo "_" grp sfx
                if edCtrls.Has(bk) && Trim(edCtrls[bk].Value) != ""
                    parts.Push(Trim(edCtrls[bk].Value))
            }
            joined := ""
            for _, p in parts
                joined .= (joined != "" ? "  |  " : "") p
            altBaseEcho[key].Value := joined
        }
    }
}

SaveAltToFile(*) {
    global altTabs
    ApplyFile(["1_mass.ahk", "2_mass.ahk", "3_mass.ahk"][altTabs.Value])
}

OpenAltWindow(*) {
    global gAlt, ALT_W, tabs, altTabs
    RefreshAltWindow()
    altTabs.Value := tabs.Value          ; open on the model you are looking at
    gAlt.Show("w" ALT_W " h878")
}

OpenBranchWindow(*) {
    global gBranch, BR_W, tabs, brTabs
    brTabs.Value := tabs.Value           ; open on the model you are looking at
    gBranch.Show("w" BR_W " h862")
}

AHK_CHARS  := ["``", Chr(34), ";"]   ; backtick must be first

; A leading "word:" is normally stripped as a field prefix (see StripPrefix). URL
; schemes must be exempt or "https://x" gets mangled into "//x". Add any other word
; that must never be treated as a prefix here (compared case-insensitively).
PREFIX_EXCEPTIONS := Map("http",1, "https",1, "ftp",1, "ftps",1, "mailto",1, "tel",1, "file",1)

edCtrls    := Map()
altBaseEcho := Map()  ; "<mNo>_<group>" → read-only echo of the base variant in the alt window
scriptPIDs := Map()   ; path → PID for toggle tracking
togCtrls   := []      ; [{c, x, oy}] script toggle section, y moves on resize
topCtrls   := []      ; [{c, ox}]       — right-panel top labels, x-slide on resize
btnCtrls   := []      ; [{c, ox, oy}]   — right-panel buttons, x+y move on resize
resizables := []      ; edit controls inside tabs, width grows on resize
_lastImportModel := 0 ; slot the last import was routed to; fast-parse reuses it

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
; On by default: the follow-up keys keep sending the main branch as they always
; have, and ctrl+key is what opens the alt chooser. Off makes the plain key prompt.
promptAltCtrl     := Integer(IniRead(CFG_FILE, "Settings", "PromptAltCtrl", "1"))
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
; The Python automation listener (infloww ui elements\automation.py) runs the
; [automation] hotkeys. On by default: those keys are declared in hotkeys.ahk and
; shown in the Hotkeys GUI, so if the listener isn't up they'd look bound but do
; nothing. See LaunchAutomationListener().
automationListener := Integer(IniRead(CFG_FILE, "Settings", "AutomationListener", "1"))
; The pinger (pinger\pinger.pyw) beeps when an Infloww fan tab goes unread. Off by
; default — it makes noise, so it should be an opt-in. See LaunchPinger().
pinger            := Integer(IniRead(CFG_FILE, "Settings", "Pinger", "0"))
; The model detector (model_detector.ahk) reads the active Infloww tab's name and
; writes it to detector_status.ini, so one set of f1/f2/f3 keys serves whichever
; model is on screen. Off by default. See LaunchDetector().
autoDetect        := Integer(IniRead(CFG_FILE, "Settings", "AutoDetectModel", "0"))
; The stats overlay (stats_overlay.ahk) OCRs the Infloww stats page and shows a
; toggleable overlay of Sales + the PPVs-sent/Fans-chatted ratio. See LaunchStatsOverlay().
statsOverlay      := Integer(IniRead(CFG_FILE, "Settings", "StatsOverlay", "0"))
UPDATE_URL   := IniRead(CFG_FILE, "Update",   "URL",       "https://raw.githubusercontent.com/actuallysilly/mmParser/main")
; Hotkeys used to be mirrored here as hk1_f1..hk3_ppvfu and written into the mass
; files as literal `F9::` lines. They now live in hotkeys.ini and are read by the
; scripts themselves — see hotkeys.ahk and the "Hotkeys…" button in Settings.
TOGGLE_H     := 90           ; height reserved below tabs for script toggles (2 rows)
PASTE_SPLIT  := 0.66         ; fraction of width left of the right (paste) panel
INIT_W       := 1500         ; wide by default so the follow-up lines are long
INIT_H       := 700
TAB_X        := 10           ; tabs on the LEFT
TAB_Y        := 10
FIELD_Y0     := TAB_Y + 30  ; tab header ~30 px
; A narrow left gutter holds the follow-up single/editable toggles, stacked per
; f-group; labels + edit boxes are shifted right just enough to clear it.
TOG_COL_X    := TAB_X + 6   ; = 16   left toggle column x
FU_CHK_W     := 58          ; single/edit checkbox width
LABEL_X      := TAB_X + 70  ; = 80   shifted right to clear the toggle column
EDIT_X       := TAB_X + 140 ; = 150
PX0          := Round(INIT_W * PASTE_SPLIT)   ; right-panel x, kept in sync with resize
RIGHT_W      := INIT_W - PX0                  ; paste+buttons panel width
INIT_TAB_W   := PX0 - TAB_X - 10
INIT_EDIT_W  := INIT_TAB_W - (EDIT_X - TAB_X) - 15
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

; Follow-up toggles live in a left column, stacked per f-group (see the fu branch).
;   editFuChks[f] = [one mirror per mass]  — global "editable" toggle, kept in sync
;   fuChks[m][f]  = per-mass "single" toggle
; They sit at a fixed left x, so they need no repositioning on resize.
editFuChks := [[], [], []]
fuChks     := []

Loop 3 {
    mNo := A_Index
    tabs.UseTab(mNo)
    fuChks.Push([])
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
            ; f1/f2/f3 primary rows get a stacked single/editable pair in the left gutter,
            ; aligned to this row (single) and the row below it (editable).
            if (prop = "fu1" || prop = "fu2" || prop = "fu3") {
                f    := Integer(SubStr(prop, 3))   ; "fu1" -> 1
                sChk := g.Add("Checkbox", "x" TOG_COL_X " y" (y-2) " w" FU_CHK_W " h22", "single")
                sChk.Value := IniRead(CFG_FILE, "Settings", "FuSingle_" mNo "_" f, "0") = "1"
                sChk.OnEvent("Click", MakeFuToggle(mNo, f))
                fuChks[mNo].Push(sChk)
                eChk := g.Add("Checkbox", "x" TOG_COL_X " y" (y+25) " w" FU_CHK_W " h22", "edit")
                eChk.Value := IniRead(CFG_FILE, "Settings", "EditableFu" f, "0") = "1"
                eChk.OnEvent("Click", MakeEditFuToggle(f))
                editFuChks[f].Push(eChk)
            }
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

c := g.Add("Button", "x" (TAB_X+530) " y" TOGG_Y0 " w100 h28", "Hotstrings")
c.OnEvent("Click", OpenHotstrings)
togCtrls.Push({c: c, x: TAB_X+530, oy: 0})

; Label carries the state, so the button is also the running indicator.
btnPinger := g.Add("Button", "x" (TAB_X+640) " y" TOGG_Y0 " w95 h28", "Pinger: OFF")
btnPinger.OnEvent("Click", TogglePinger)
togCtrls.Push({c: btnPinger, x: TAB_X+640, oy: 0})

c := g.Add("Button", "x" (TAB_X+745) " y" TOGG_Y0 " w95 h28", "Alt FUs…")
c.OnEvent("Click", OpenAltWindow)
togCtrls.Push({c: c, x: TAB_X+745, oy: 0})

c := g.Add("Button", "x" (TAB_X+745) " y" (TOGG_Y0+34) " w95 h28", "Branches…")
c.OnEvent("Click", OpenBranchWindow)
togCtrls.Push({c: c, x: TAB_X+745, oy: 34})

; (single/editable follow-up toggles moved inline onto the f1/f2/f3 rows above)

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

; ─── Branches window (--Name alternate sequences; hidden until opened) ────────
; One tab per model, BRANCH_MAX branches each. Parsing a `--Name` mass writes
; straight into these controls, and this is where you see or edit them.

BR_W       := 720
BR_LABEL_X := 12
BR_EDIT_X  := 92
BR_EDIT_W  := BR_W - BR_EDIT_X - 30

gBranch := Gui("+Resize +MinSize420x300", "Branches (--Name)")
gBranch.SetFont("s9", "Segoe UI")
brTabs := gBranch.Add("Tab3", "x10 y10 w" (BR_W-20) " h800", ["M1", "M2", "M3"])

Loop 3 {
    mNo := A_Index
    brTabs.UseTab(mNo)
    y := 40
    Loop BRANCH_MAX {
        k := A_Index
        gBranch.SetFont("s10 Bold", "Segoe UI")
        gBranch.Add("Text", "x" BR_LABEL_X " y" y " w200", "BRANCH " k)
        gBranch.SetFont("s9 Norm", "Segoe UI")
        y += 22

        gBranch.Add("Text", "x" BR_LABEL_X " y" (y+3) " w74 Right", "name:")
        ec := gBranch.Add("Edit", "x" BR_EDIT_X " y" y " w" BR_EDIT_W " h22")
        edCtrls["m" mNo "_br" k "_name"] := ec
        y += 28

        for _, grp in ["fu1", "fu2", "fu3"] {
            gBranch.Add("Text", "x" BR_LABEL_X " y" (y+3) " w74 Right", grp ":")
            ec := gBranch.Add("Edit", "x" BR_EDIT_X " y" y " w" BR_EDIT_W " h40 Multi +VScroll")
            edCtrls["m" mNo "_br" k "_" grp] := ec
            y += 44
        }
        gBranch.Add("Text", "x" BR_LABEL_X " y" (y+3) " w74 Right", "ppv:")
        ec := gBranch.Add("Edit", "x" BR_EDIT_X " y" y " w" BR_EDIT_W " h52 Multi +VScroll")
        edCtrls["m" mNo "_br" k "_ppv"] := ec
        y += 64
    }
}
brTabs.UseTab()

gBranch.Add("Button", "x10 y820 w120 h28", "Save to file").OnEvent("Click", (*) => ApplyFile(["1_mass.ahk","2_mass.ahk","3_mass.ahk"][brTabs.Value]))
gBranch.Add("Button", "x140 y820 w80 h28", "Close").OnEvent("Click", (*) => gBranch.Hide())

; ─── Alt follow-up window (hidden; alts never show in the main panel) ─────────
; Parsing an alt: line writes straight into these controls, so a pasted mass
; registers its alternatives quietly. This window is the only place to see or
; edit them.

ALT_W       := 780
ALT_LABEL_X := 12
ALT_EDIT_X  := 92
ALT_EDIT_W  := ALT_W - ALT_EDIT_X - 34

gAlt := Gui("+Resize +MinSize560x420", "Alt follow-ups")
gAlt.BackColor := "15141C"
gAlt.SetFont("s9 cE6E4EE", "Segoe UI")
altTabs := gAlt.Add("Tab3", "x10 y10 w" (ALT_W-20) " h812", ["M1", "M2", "M3"])
altGuiChks := Map()

Loop 3 {
    mNo := A_Index
    altTabs.UseTab(mNo)
    y := 42

    ; per-mass chooser style. Off = TAB staging in the chatbox (the default).
    chk := gAlt.Add("Checkbox", "x" ALT_LABEL_X " y" y " w220 cE6E4EE", "alt: gui  (modal instead of TAB)")
    altGuiChks[mNo] := chk
    ec := gAlt.Add("Edit", "x" ALT_EDIT_X " y" y " w0 h0")     ; value holder for altGui
    edCtrls["m" mNo "_altGui"] := ec
    chk.OnEvent("Click", MakeAltGuiToggle(mNo))
    y += 34

    for _, grp in ALT_GROUPS {
        gAlt.SetFont("s10 Bold cB89CFF", "Segoe UI")
        gAlt.Add("Text", "x" ALT_LABEL_X " y" y " w200", StrUpper(grp))
        gAlt.SetFont("s9 Norm cE6E4EE", "Segoe UI")
        y += 22

        ; the base variant, shown read-only so you can see what you are alternating
        gAlt.Add("Text", "x" ALT_LABEL_X " y" (y+3) " w74 Right c8E8AA6", "base:")
        ec := gAlt.Add("Edit", "x" ALT_EDIT_X " y" y " w" ALT_EDIT_W " h20 ReadOnly Background201E2B")
        altBaseEcho[mNo "_" grp] := ec
        y += 26

        for ai, fld in AltFields(grp) {
            gAlt.Add("Text", "x" ALT_LABEL_X " y" (y+3) " w74 Right c8E8AA6", "alt" (ai-1) ":")
            ec := gAlt.Add("Edit", "x" ALT_EDIT_X " y" y " w" ALT_EDIT_W " h56 Multi +VScroll Background201E2B")
            edCtrls["m" mNo "_" fld] := ec
            y += 60
        }
        y += 10
    }
}
altTabs.UseTab()

gAlt.SetFont("s9 cE6E4EE", "Segoe UI")
gAlt.Add("Button", "x10 y834 w120 h28", "Save to file").OnEvent("Click", SaveAltToFile)
gAlt.Add("Button", "x140 y834 w80 h28", "Close").OnEvent("Click", (*) => gAlt.Hide())
gAlt.Add("Text", "x240 y840 w520 c8E8AA6",
         "An alt may span lines — each line is sent as its own message, like the base.")
ArchiveDarkTheme(gAlt, [])

lblCredit.GetPos(, , &lblCreditW)
lblCredit.Move(INIT_W - lblCreditW - 10)

; auto-start configured startup scripts (defaults to general.ahk) if not already running
LaunchStartupScripts()
LaunchAutomationListener()
if pinger
    LaunchPinger()
if autoDetect
    LaunchDetector()
if statsOverlay
    LaunchStatsOverlay()
SetTimer(RefreshPingerLabel, -800)   ; after python has claimed the event
if autoRestart
    SetTimer(WatchdogTick, 5000)

SetTimer(() => CheckUpdate(true), -3000)  ; silent check 3s after startup

; ─── Resize ───────────────────────────────────────────────────────────────────

ApplyLayout(W, H) {
    global
    pasteX     := Round(W * PASTE_SPLIT)
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
    raw      := A_Clipboard
    detected := ExtractModelName(&raw)          ; strips a leading @model line if present
    edPaste.Value := raw
    slot := detected != "" ? MatchModelName(detected) : 0
    ; Fast mode auto-saves only when we know the model: a matched name, or the model
    ; the last import was routed to. Otherwise ask — never silently dump into mass 1.
    if (fastParseAutosave && slot) {
        ParseCurrent()
        ApplyFile(_mFiles[slot], true)
        _lastImportModel := slot
    } else if (fastParseAutosave && detected = "" && _lastImportModel) {
        ParseCurrent()
        ApplyFile(_mFiles[_lastImportModel], true)
    } else {
        PromptSaveTarget(detected)
    }
}
OnMessage(0x8010, AutoParseFromClipboard) ; 0x8010: paste clipboard into edPaste + parse (from copyDiscordMessageSeq)

; ─── One-click import from the draft/archive webgui ───────────────────────────
; The webgui's "Send to MMA" copies "#MMA-IMPORT#\n<mma text>" to the clipboard.
; We detect the sentinel, strip it, and reuse the same parse path as the Discord
; import above — so a single click in the browser lands the mass in the panel.
WEB_IMPORT_SENTINEL := "#MMA-IMPORT#"
_webImporting := false
WebImportFromClipboard(dataType) {
    global WEB_IMPORT_SENTINEL, _webImporting, g
    if _webImporting || dataType != 1     ; 1 = clipboard now holds text
        return
    cb := A_Clipboard
    if SubStr(cb, 1, StrLen(WEB_IMPORT_SENTINEL)) != WEB_IMPORT_SENTINEL
        return
    _webImporting := true
    body := LTrim(SubStr(cb, StrLen(WEB_IMPORT_SENTINEL) + 1), "`r`n")
    A_Clipboard := body                   ; leave a clean copy (re-fires handler, but no sentinel now)
    ClipWait(0.5)
    try WinActivate("ahk_id " g.Hwnd)
    PostMessage(0x8010, 0, 0, , "ahk_id " g.Hwnd)   ; -> AutoParseFromClipboard
    _webImporting := false
}
OnClipboardChange(WebImportFromClipboard)

; ─── Model name repository ────────────────────────────────────────────────────
; An imported mass can be tagged with a model name that differs from the slot's own
; name (e.g. "AW" for the "ALIW" model). We keep a small alias table in the cfg
; [ModelAliases] (name -> slot) so the import prompt can match a known name to its
; model automatically, or remember a new one.

ModelNameForSlot(slot) {
    global model1Name, model2Name, model3Name
    return slot = 1 ? model1Name : slot = 2 ? model2Name : model3Name
}

; Returns the slot (1..modelCount) a name maps to, or 0 if unknown.
MatchModelName(name) {
    global CFG_FILE, modelCount
    name := Trim(name)
    if name = ""
        return 0
    Loop modelCount                                   ; a slot's own name always matches
        if StrLower(ModelNameForSlot(A_Index)) = StrLower(name)
            return A_Index
    slot := IniRead(CFG_FILE, "ModelAliases", name, "")   ; ini keys are case-insensitive
    if (IsInteger(slot) && Integer(slot) >= 1 && Integer(slot) <= modelCount)
        return Integer(slot)
    return 0
}

RememberModelName(name, slot) {
    global CFG_FILE
    name := Trim(name)
    if (name != "" && slot >= 1)
        IniWrite(slot, CFG_FILE, "ModelAliases", name)
}

; Model names + saved aliases, for the prompt's combo box.
KnownModelNames() {
    global CFG_FILE, modelCount
    names := [], seen := Map()
    add(nm) {
        if (Trim(nm) != "" && !seen.Has(StrLower(nm))) {
            names.Push(nm)
            seen[StrLower(nm)] := true
        }
    }
    Loop modelCount
        add(ModelNameForSlot(A_Index))
    sect := ""
    try sect := IniRead(CFG_FILE, "ModelAliases")
    for line in StrSplit(sect, "`n") {
        p := InStr(line, "=")
        if p
            add(Trim(SubStr(line, 1, p - 1)))
    }
    return names
}

; If the text opens with an explicit "@model: NAME" marker line, consume it (strip
; from raw) and return the name. Gives the Discord/webgui flows a clean way to tag
; the model later; absent -> "". raw is modified in place.
ExtractModelName(&raw) {
    lines := StrSplit(StrReplace(StrReplace(raw, "`r`n", "`n"), "`r", "`n"), "`n")
    for i, ln in lines {
        t := Trim(ln)
        if t = ""
            continue
        if RegExMatch(t, "i)^@(?:mma-)?model\s*[:=]?\s*(.+)$", &m) {
            name := Trim(m[1])
            lines.RemoveAt(i)
            raw := ""
            for _, l in lines
                raw .= (raw = "" ? "" : "`n") l
            return name
        }
        return ""   ; first real line isn't a marker
    }
    return ""
}

PromptSaveTarget(detectedName := "") {
    global _mFiles, tabs, modelCount, g, _lastImportModel
    modelItems := []
    Loop modelCount
        modelItems.Push(A_Index ": " ModelNameForSlot(A_Index))

    pg := Gui("+Owner" g.Hwnd, "Import — route to model")
    pg.SetFont("s9", "Segoe UI")

    pg.Add("Text", "x10 y14 w45", "Name:")
    cbName := pg.Add("ComboBox", "x60 y11 w150", KnownModelNames())
    cbName.Text := detectedName

    pg.Add("Text", "x10 y46 w45", "Model:")
    ddlModel := pg.Add("DropDownList", "x60 y43 w150", modelItems)
    _pre := MatchModelName(detectedName)
    ddlModel.Value := _pre ? _pre : (_lastImportModel ? _lastImportModel : 1)

    chkRemember := pg.Add("Checkbox", "x60 y72", "Remember this name for the model")

    pg.Add("Text", "x10 y100 w45", "Mass #:")
    rd1 := pg.Add("Radio", "x60 y98 Group", "1")
    rd2 := pg.Add("Radio", "x105 y98", "2")
    rd3 := pg.Add("Radio", "x150 y98", "3")
    rd1.Value := true

    pg.Add("Button", "x10  y130 w110 h26 Default", "Parse + Save").OnEvent("Click", DoSave)
    pg.Add("Button", "x130 y130 w80 h26", "Cancel").OnEvent("Click", (*) => pg.Destroy())

    cbName.OnEvent("Change", NameChanged)   ; auto-pick the model when the name is known
    pg.Show("w230 h172")

    NameChanged(*) {
        s := MatchModelName(cbName.Text)
        if s
            ddlModel.Value := s
    }

    DoSave(*) {
        slot := ddlModel.Value
        if (chkRemember.Value && Trim(cbName.Text) != "")
            RememberModelName(cbName.Text, slot)
        _lastImportModel := slot
        tabs.Value := rd1.Value ? 1 : rd2.Value ? 2 : 3
        ParseCurrent()
        ApplyFile(_mFiles[slot], true)
        pg.Destroy()
    }
}

; ─── Archive ──────────────────────────────────────────────────────────────────
; One parser for both readers — the viewer below and the duplicate check. They
; used to be the same code twice, which is how they would drift apart.

ArchiveFile() {
    return A_ScriptDir "\mass_archive.txt"
}

ReadArchiveEntries() {
    path := ArchiveFile()
    entries := []
    if !FileExist(path)
        return entries
    raw := FileRead(path, "UTF-8")
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
        if !f
            return false
        f.Write(out)
        f.Close()
        FileMove(tmp, path, 1)
    } catch {
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
; is none. Re-parsing the same paste is routine (fixing one line and hitting parse
; again), and every parse used to append: 21 of the first 59 entries were
; duplicates, one mass stored 9 times in under two minutes.
;
; The model is deliberately NOT part of the match. Scoping by name missed two real
; cases: the same mass genuinely does get archived for two models, and a blank
; model name wrote a "[]" header that then matched nothing at all — which is how
; "Pop or rock music?" got in twice three seconds apart. A same-model hit is
; returned in preference to a cross-model one so the prompt names the closest
; entry, but either one is worth asking about.
ArchiveFindDuplicate(mName, raw) {
    global CFG_FILE
    window := Integer(IniRead(CFG_FILE, "Settings", "ArchiveDupDays", "1"))
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

; A duplicate is never stored or dropped on its own: this asks. The dialog says
; when the mass was already archived and for which model, and No is the default
; button, so leaning on Enter cannot grow the archive.
ArchiveDuplicatePrompt(dup, mName) {
    who  := Trim(dup.model) = "" ? "(untagged)" : dup.model
    prev := ArchiveFlatten(dup.preview)
    if StrLen(prev) > 120
        prev := SubStr(prev, 1, 120) "..."
    msg := "This mass is already in the archive.`n`n"
         . "Saved:  " dup.ts "`n"
         . "Model:  " who
         . (StrLower(Trim(dup.model)) = StrLower(Trim(mName)) ? "" : "   (archiving now for " mName ")") "`n`n"
         . prev "`n`n"
         . "Archive it again anyway?"
    return MsgBox(msg, "Archive - duplicate mass", 0x4 | 0x100 | 0x30) = "Yes"
}

ClearArchiveTip() {
    ToolTip()
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
    RefreshAltWindow()          ; alts never surface in the main panel; keep their window honest
    if chkArchive.Value && Trim(raw) != "" {
        mName := mNo = 1 ? model1Name : mNo = 2 ? model2Name : model3Name
        if Trim(mName) = ""
            mName := "m" mNo    ; an unnamed slot used to write "[]", which no dup check could match
        dup := ArchiveFindDuplicate(mName, raw)
        if (!dup || ArchiveDuplicatePrompt(dup, mName)) {
            ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            FileAppend "[" ts "] [" mName "]`n" raw "`n===END===`n`n", ArchiveFile(), "UTF-8"
        } else {
            ToolTip("Archive: skipped")
            SetTimer(ClearArchiveTip, -1500)
        }
    }
}

ClearAll(*) {
    global
    edPaste.Value := ""
    for _, c in edCtrls
        c.Value := ""
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

    ; same palette as hotstrings_gui.ahk (dark violet, Infloww family)
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
        idx := Integer(lv.GetText(row, 4))
        return (idx >= 1 && idx <= all.Length) ? idx : 0
    }

    DoSearch(*) {
        Populate(edSearch.Value)
    }

    DoFocus(ctrl, row) {
        if !row || row > ctrl.GetCount()
            return
        idx := Integer(ctrl.GetText(row, 4))
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
; MassPropIsMultiline as `n; AltPartsRT splits them back at send time).
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
    Loop Min(branches.Length, BRANCH_MAX) {
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
            if ai > altFlds.Length          ; more alts than slots — keep the first ALT_MAX
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

; ─── Load from file ───────────────────────────────────────────────────────────

LoadFile(fname) {
    global
    path := SCRIPT_DIR "\" fname
    if !FileExist(path) {
        MsgBox "File not found:`n" path,, 0x10
        return
    }
    content := FileRead(path, "UTF-8")
    props   := MassBlockProps()
    Loop 3 {
        mNo := A_Index
        if !RegExMatch(content, "m" mNo " := \{([^}]*)\}", &blk)
            continue
        blockText := blk[1]
        for _, prop in props {
            ck := "m" mNo "_" prop
            ; alt fields are longest-first in MassBlockProps so "fu1_alt0" cannot be
            ; matched by the "fu1" pattern; anchor anyway to be certain.
            if RegExMatch(blockText, "(?:^|\R)\s*" prop ": " Chr(34) "((?:[^" Chr(34) Chr(96) "]|" Chr(96) ".)*)" Chr(34), &mv) && edCtrls.Has(ck) {
                v := mv[1]
                if MassPropIsMultiline(prop)
                    v := StrReplace(v, "``n", "`r`n")
                edCtrls[ck].Value := UnescQ(v)
            }
        }
    }
    RefreshAltWindow()
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

    ; The generated HK_Bind calls only work for slots hotkeys.ahk declares. Without
    ; this the file would build fine and then bind nothing, logging to error_log
    ; where nobody looks.
    if !HK_META.Has("mass." num ".fu1") {
        MsgBox "No hotkeys are declared for model slot " num ".`n`n"
             . "Add a [mass." num "] section to hotkeys.ini and HK_Def lines to "
             . "hotkeys.ahk first, otherwise " fname " will load but none of its "
             . "hotkeys will work.",, 0x30
    }

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

    ; Named functions + HK_Bind, never literal keys: the keys belong to
    ; hotkeys.ini under [mass.<n>], so a generated file never needs rewriting to
    ; change one.
    out .= "DoFu1(){`n    switch massNo`n    {`n" BuildSwitchFu(1, "fu1","fu1_5","fu1_7") "    }`n}`n`n"
    out .= "DoFu2(){`n    switch massNo`n    {`n" BuildSwitchFu(2, "fu2","fu2_5","fu2_7") "    }`n}`n`n"
    out .= "DoFu3(){`n    switch massNo`n    {`n" BuildSwitchFu(3, "fu3","fu3_5","fu3_7") "    }`n}`n`n"

    out .= "DoPpv(){`n    ppv := `"`"`n    switch massNo{`n"
    Loop 3
        out .= "        case " A_Index ": ppv := m" A_Index ".ppv_base`n"
    out .= "    }`n    A_Clipboard := ppv`n    ClipWait(0.1)`n    Send " q "^v" q "`n}`n`n"

    out .= "DoPpvFus(){`n    switch massNo`n    {`n" BuildSwitch("ppv_f1","ppv_f2","ppv_f3") "    }`n}`n`n"

    for _, slot in ["fu1", "fu2", "fu3", "smFu1", "smFu2", "smFu3", "ppv", "ppvFus"] {
        fn := (slot = "ppv") ? "DoPpv"
            : (slot = "ppvFus") ? "DoPpvFus"
            : "DoFu" SubStr(slot, -1)
        out .= "HK_Bind(" q "mass." num "." slot q ", " fn ")`n"
    }
    out .= "`nStartFuGating(HK_ModelSendIds(modelFileNo))`n"

    ; type __mm to paste the ACTIVE model's mass, gated so only the focused model's
    ; script fires it (UniversalSendActive lives in utils.ahk). Mirrors the hand-
    ; written copy in 1_mass.ahk so every model behaves the same.
    out .= "`nDoMass(){`n"
         . "    global massNo, m1, m2, m3`n"
         . "    m := massNo = 1 ? m1 : massNo = 2 ? m2 : m3`n"
         . "    if m.mass = " q q "`n"
         . "        return`n"
         . "    A_Clipboard := m.mass`n"
         . "    ClipWait(0.5)`n"
         . "    Send " q "^v" q "`n"
         . "}`n"
         . "#HotIf UniversalSendActive()`n"
         . ":*X:__mm::DoMass()`n"
         . "#HotIf`n"
    return out
}


BuildBlock(mNo) {
    global
    props  := MassBlockProps()
    breaks := Map("fu1_7", 1, "fu2_7", 1, "fu3_7", 1, "ppv_f3", 1,
                  "br1_ppv", 1, "br2_ppv", 1, "br3_ppv", 1,
                  "fu1_alt2", 1, "fu2_alt2", 1, "fu3_alt2", 1)
    out    := "m" mNo " := {`n"
    Loop props.Length {
        p     := props[A_Index]
        val   := edCtrls.Has("m" mNo "_" p) ? edCtrls["m" mNo "_" p].Value : ""
        val   := EscQ(val)
        if MassPropIsMultiline(p)
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
    StopAutomationListener()             ; not an AHK window, so the loop below misses it
    StopPinger()                         ; likewise
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

; ── the Python automation listener ────────────────────────────────────────────
;  automation.py serves the [automation] hotkeys. It cannot ride on startupScripts:
;  that path tests WinExist("… ahk_class AutoHotkey") and KillAllScripts only closes
;  AutoHotkey windows, neither of which sees a Python process.
;
;  It signs its presence with a named event, so we can ask "is it up?" with one
;  DllCall instead of shelling out to `--status` (which would spawn a whole Python
;  every watchdog tick, every 5 seconds).
;
;  Launched via the .vbs so there is no console window; it is single-instance on its
;  own (a named mutex), so a double-launch is harmless — the second copy just exits.

; Open the listener's own named event. Its mere existence means "a listener is up";
; setting it means "please exit". Must match STOP_EVENT_NAME in automation.py.
_AutomationOpenEvent() {
    static EVENT_MODIFY_STATE := 0x0002
    static EVENT_NAME := "Global\MMA.automation.listener.stop"
    return DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                   "Str", EVENT_NAME, "Ptr")
}

AutomationListenerRunning() {
    h := _AutomationOpenEvent()
    if !h
        return false
    DllCall("CloseHandle", "Ptr", h)
    return true
}

LaunchAutomationListener() {
    global SCRIPT_DIR, automationListener
    if !automationListener || AutomationListenerRunning()
        return
    vbs := SCRIPT_DIR "\infloww ui elements\automation_listen.vbs"
    if FileExist(vbs)
        try Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide")
}

; Ask it to exit cleanly (it has no console to Ctrl+C, and it is not an AHK window
; so KillAllScripts cannot see it).
StopAutomationListener() {
    h := _AutomationOpenEvent()
    if !h
        return
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
}

; ─── Pinger ───────────────────────────────────────────────────────────────────
; Beeps when an Infloww fan tab goes unread. Same shape as the automation
; listener above: a python process with no console and no AHK window, so the
; named event is both the "is it up?" probe and the only way to close it.

_PingerOpenEvent() {
    static EVENT_MODIFY_STATE := 0x0002
    static EVENT_NAME := "Global\MMA.pinger.stop"
    return DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                   "Str", EVENT_NAME, "Ptr")
}

PingerRunning() {
    h := _PingerOpenEvent()
    if !h
        return false
    DllCall("CloseHandle", "Ptr", h)
    return true
}

LaunchPinger() {
    global SCRIPT_DIR
    if PingerRunning()
        return
    vbs := SCRIPT_DIR "\pinger\pinger_start.vbs"
    if FileExist(vbs)
        try Run('wscript.exe "' vbs '"', SCRIPT_DIR, "Hide")
}

StopPinger() {
    h := _PingerOpenEvent()
    if !h
        return
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
}

; ─── Model detector ───────────────────────────────────────────────────────────
; An AHK script (not python), so its hidden main window — titled with its full
; path, class AutoHotkey — is both the "is it up?" probe and the kill target.
_DetectorTitle() {
    global SCRIPT_DIR
    return SCRIPT_DIR "\model_detector.ahk ahk_class AutoHotkey"
}
DetectorRunning() {
    return WinExist(_DetectorTitle()) != 0
}
LaunchDetector() {
    global SCRIPT_DIR
    path := SCRIPT_DIR "\model_detector.ahk"
    if !FileExist(path) || DetectorRunning()
        return
    try Run(path)
}
StopDetector() {
    global SCRIPT_DIR
    if WinExist(_DetectorTitle())
        try ProcessClose(WinGetPID(_DetectorTitle()))
    ; clear the gate so every model responds again once detection is off
    try IniWrite("", SCRIPT_DIR "\detector_status.ini", "detector", "active_model")
}

; ─── Stats overlay ────────────────────────────────────────────────────────────
; Resident AHK script that owns the gui.toggleStats hotkey and the OCR overlay.
_StatsTitle() {
    global SCRIPT_DIR
    return SCRIPT_DIR "\stats_overlay.ahk ahk_class AutoHotkey"
}
StatsOverlayRunning() {
    return WinExist(_StatsTitle()) != 0
}
LaunchStatsOverlay() {
    global SCRIPT_DIR
    path := SCRIPT_DIR "\stats_overlay.ahk"
    if !FileExist(path) || StatsOverlayRunning()
        return
    try Run(path)
}
StopStatsOverlay() {
    if WinExist(_StatsTitle())
        try ProcessClose(WinGetPID(_StatsTitle()))
}

TogglePinger(*) {
    global pinger, CFG_FILE
    if PingerRunning() {
        StopPinger()
        pinger := 0
    } else {
        LaunchPinger()
        pinger := 1
    }
    IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
    ; the python side takes a moment to claim or release the event
    SetTimer(RefreshPingerLabel, -600)
}

RefreshPingerLabel() {
    global btnPinger
    if IsSet(btnPinger) && btnPinger
        try btnPinger.Text := PingerRunning() ? "Pinger: ON" : "Pinger: OFF"
}

WatchdogTick() {
    global pinger, autoDetect, statsOverlay
    LaunchStartupScripts()
    LaunchAutomationListener()
    if pinger
        LaunchPinger()
    if autoDetect
        LaunchDetector()
    if statsOverlay
        LaunchStatsOverlay()
    RefreshPingerLabel()
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

UpdateModelButtons() {
    global modelCount, model1Name, model2Name, model3Name, btnLoadM, btnSaveM
    _mNames := [model1Name, model2Name, model3Name]
    Loop modelCount {
        i := A_Index
        btnLoadM[i].Text := "load " _mNames[i]
        btnSaveM[i].Text := "save " _mNames[i]
    }
}

; Launch the standalone Hotstrings manager (hotstrings_gui.ahk). It's #SingleInstance,
; so clicking again just refreshes it rather than piling up windows.
OpenHotstrings(*) {
    global SCRIPT_DIR
    path := SCRIPT_DIR "\hotstrings_gui.ahk"
    if !FileExist(path) {
        MsgBox "hotstrings_gui.ahk isn't in " SCRIPT_DIR, "Hotstrings", 0x30
        return
    }
    try Run(A_AhkPath ' "' path '"')
}

OpenSettings(*) {
    global model1Name, model2Name, model3Name, modelCount, CFG_FILE, g
    global defaultHotkeyFile, ACC_DIR, SCRIPT_DIR, mouseControl
    global startupScripts, autoRestart, automationListener, pinger, promptAltCtrl

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

    ; ── Hotkeys ────────────────────────────────────────────────────────────────
    ; Every hotkey in MMA — not just the 15 model-send keys this grid used to
    ; show — is edited in its own window now, backed by hotkeys.ini.
    sg.Add("Text", "x10 y115 w590", "── Hotkeys ─────────────────────────────────────────────────────────────────")
    sg.Add("Button", "x10 y138 w150 h28", "Hotkeys…").OnEvent("Click", (*) => OpenHotkeysGui())
    sg.Add("Text", "x170 y144 w420", "Every hotkey, grouped by feature. Applies live.")
    y := 176
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
    ; On  = the plain follow-up key always sends the main branch, ctrl+key picks.
    ; Off = the plain key prompts whenever the follow-up has alts.
    chkPromptAlt := sg.Add("Checkbox", "x10 y" (y+74) " w560", "Prompt for Alt-FUs using ctrl+hotkey (off = the plain key always prompts)")
    chkPromptAlt.Value := promptAltCtrl
    y += 102
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
    ; sequences.ahk owns the Discord Ctrl+click import, Open Farmolijer and Select
    ; top PPV. It was missing from this list, so those keys could only be bound by
    ; running the file by hand — and the day that stopped, the import "broke".
    if FileExist(SCRIPT_DIR "\sequences.ahk")
        _eligible.Push("sequences.ahk")
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
    chkAutomation := sg.Add("Checkbox", "x10 y" (_sy + 54), "Run the automation listener (serves the [automation] hotkeys)")
    chkAutomation.Value := automationListener
    chkPinger := sg.Add("Checkbox", "x10 y" (_sy + 78), "Run the pinger (beeps when an Infloww tab goes unread)")
    chkPinger.Value := pinger
    ; Read the live process, not the setting — they disagree whenever the pinger
    ; was toggled from the main window, or died on its own.
    lblPinger := sg.Add("Text", "x360 y" (_sy + 78) " w230", "")
    chkAutoDetect := sg.Add("Checkbox", "x10 y" (_sy + 102) " w340", "Auto-detect active model (OCR/CV) — one f1/f2/f3 set, gated by tab")
    chkAutoDetect.Value := autoDetect
    lblDetector := sg.Add("Text", "x360 y" (_sy + 102) " w230", "")
    chkStats := sg.Add("Checkbox", "x10 y" (_sy + 126) " w340", "Run stats overlay (OCR of Infloww stats — toggle hotkey: gui.toggleStats)")
    chkStats.Value := statsOverlay
    lblStats := sg.Add("Text", "x360 y" (_sy + 126) " w230", "")
    PaintPingerStatus()
    sg.OnEvent("Close", StopPingerStatusTimer)
    SetTimer(PaintPingerStatus, 1500)
    y := _sy + 152
    sg.Add("Text",   "x10  y" (y+8)  " w580 h2 0x10")
    sg.Add("Button", "x10  y" (y+18) " w85 h28",  "Save").OnEvent("Click", SaveCfg)
    sg.Add("Button", "x105 y" (y+18) " w85 h28",  "Reset").OnEvent("Click", ResetCfg)
    sg.Add("Button", "x200 y" (y+18) " w90 h28",  "Wipe Temp").OnEvent("Click", (*) => (WipeTemp(), sg.Destroy()))
    sg.Add("Button", "x300 y" (y+18) " w85 h28",  "Report Bug").OnEvent("Click", (*) => Run("https://github.com/actuallysilly/mmParser/issues/new?title=Bug+Report&labels=bug"))
    sg.Add("Button", "x490 y" (y+18) " w100 h28", "Check Update").OnEvent("Click", (*) => CheckUpdate())
    sg.Show("w600 h" (y + 62))

    ; The sign that it is actually up. Polls the named event the pinger holds, so
    ; it stays honest if the process dies or is toggled from the main window.
    PaintPingerStatus(*) {
        ; "Wipe Temp" destroys the window without firing Close, so the timer can
        ; outlive the control. Touching a destroyed control throws — stop instead.
        try {
            if PingerRunning() {
                lblPinger.SetFont("cGreen")
                lblPinger.Text := "● running"
            } else {
                lblPinger.SetFont("cGray")
                lblPinger.Text := "○ not running"
            }
            if DetectorRunning() {
                lblDetector.SetFont("cGreen")
                lblDetector.Text := "● running"
            } else {
                lblDetector.SetFont("cGray")
                lblDetector.Text := "○ not running"
            }
            if StatsOverlayRunning() {
                lblStats.SetFont("cGreen")
                lblStats.Text := "● running"
            } else {
                lblStats.SetFont("cGray")
                lblStats.Text := "○ not running"
            }
        } catch {
            SetTimer(PaintPingerStatus, 0)
        }
    }

    StopPingerStatusTimer(*) {
        SetTimer(PaintPingerStatus, 0)
    }

    SaveCfg(*) {
        global model1Name, model2Name, model3Name, modelCount, CFG_FILE
        global defaultHotkeyFile, mouseControl, fastParseAutosave
        global startupScripts, autoRestart, automationListener, pinger, promptAltCtrl, autoDetect, statsOverlay

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
        promptAltCtrl := chkPromptAlt.Value ? 1 : 0
        IniWrite(promptAltCtrl, CFG_FILE, "Settings", "PromptAltCtrl")
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
        automationListener := chkAutomation.Value ? 1 : 0
        IniWrite(automationListener, CFG_FILE, "Settings", "AutomationListener")
        startupScripts := []
        for _s in StrSplit(_startupCsv, ",")
            if Trim(_s) != ""
                startupScripts.Push(Trim(_s))
        SetTimer(WatchdogTick, autoRestart ? 5000 : 0)
        LaunchStartupScripts()
        ; apply the toggle now, both ways - unticking it should stop the running one
        if automationListener
            LaunchAutomationListener()
        else
            StopAutomationListener()

        pinger := chkPinger.Value ? 1 : 0
        IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
        if pinger
            LaunchPinger()
        else
            StopPinger()
        SetTimer(RefreshPingerLabel, -600)

        autoDetect := chkAutoDetect.Value ? 1 : 0
        IniWrite(autoDetect, CFG_FILE, "Settings", "AutoDetectModel")
        if autoDetect
            LaunchDetector()
        else
            StopDetector()

        statsOverlay := chkStats.Value ? 1 : 0
        IniWrite(statsOverlay, CFG_FILE, "Settings", "StatsOverlay")
        if statsOverlay
            LaunchStatsOverlay()
        else
            StopStatsOverlay()

        StopPingerStatusTimer()
        sg.Destroy()

        if newCount != modelCount {
            modelCount := newCount
            Reload
            return
        }

        ; Mouse control is read once at load, so the model scripts must restart to
        ; see it change. Hotkeys no longer need this — they reload live from
        ; hotkeys.ini via HK_Reload().
        if mcChanged
            RestartMassScripts()
    }

    ; Hotkeys are not reset here — the Hotkeys window has its own per-row and
    ; "Reset all" controls, backed by hotkeys.default.ini.
    ResetCfg(*) {
        ed1.Value := "Model 1"
        ed2.Value := "Model 2"
        ed3.Value := "Model 3"
        edWT.Value := "350"
        rdMC2.Value := true
    }
}

; Restart the running model scripts (used when a load-time setting changes).
RestartMassScripts() {
    global SCRIPT_DIR, modelCount
    if MsgBox("Mouse control changed.`nRestart the model scripts now?", "Done", 0x24) != "Yes"
        return
    Loop modelCount {
        p := SCRIPT_DIR "\" A_Index "_mass.ahk"
        if WinExist(p " ahk_class AutoHotkey") {
            ProcessClose WinGetPID(p " ahk_class AutoHotkey")
            Sleep 150
            Run p
        }
    }
}

OpenHotkeysGui(*) {
    global SCRIPT_DIR
    p := SCRIPT_DIR "\hotkeys_gui.ahk"
    if !FileExist(p) {
        MsgBox "hotkeys_gui.ahk is missing.",, 0x10
        return
    }
    Run p
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
        ; The date stamp is what lets the Hotstrings manager sort by "newest".
        ; A comment rather than anything structural: AHK ignores it, the index
        ; reads it (HSI_AddedAbove), and hand-editing the file cannot break it.
        block := "`n; @added " FormatTime(, "yyyy-MM-dd HH:mm") "`n" trigger "`n{`n"
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

MakeEditFuToggle(f) => (ctrl, *) => ToggleEditFuCell(f, ctrl)

ToggleEditFuCell(f, ctrl) {
    global editFuChks, CFG_FILE
    val := ctrl.Value ? 1 : 0
    for _, c in editFuChks[f]   ; "editable" is global — sync the per-tab mirrors
        c.Value := val
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

; Grab whatever's in the focused box and open Add Hotkey prefilled with it.
AddHotkeyGrab() {
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

; Same idea, but the text is read off the SCREEN instead of the focused box:
; drag a region, OCR it, then hand it to the very same dialog — so every option
; there (snd/SendText/Sendt, target file, hotstring type) works identically.
OcrGrab() {
    text := OcrGrabToText()
    if (text = "")
        return
    OpenAddHotkey(text)
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

; ─── Hotkeys ──────────────────────────────────────────────────────────────────
; Keys live in hotkeys.ini under [gui]. "mouseControl" is this script's own
; context, so gui.toggleDoubleMM only fires while Mouse control is on.
HK_Context("mouseControl", (*) => mouseControl)

HK_Bind("gui.addHotkeyGrab",  AddHotkeyGrab)
HK_Bind("gui.ocrGrab",        OcrGrab)
HK_Bind("gui.toggleDoubleMM", ToggleDoubleMM)

