#Requires AutoHotkey v2.0
#Include "paths.ahk"
#SingleInstance Force
#Include "crashlog.ahk"
#Include "hotkeys.ahk"
#Include "archive.ahk"
#Include "mass_parser.ahk"
#Include "processes.ahk"
#Include "modes_gui.ahk"
#Include "ocr_grab.ahk"
#Include "actions_menu.ahk"
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

SCRIPT_DIR   := MMA_ROOT
ACC_DIR      := MMA_ACC_DIR
CFG_FILE     := MMA_CFG
_verFile     := MMA_VERSION
APP_VER      := FileExist(_verFile) ? Trim(FileRead(_verFile, "UTF-8")) : "?"
_codePath    := EnvGet("LOCALAPPDATA") "\Programs\Microsoft VS Code\Code.exe"
CODE_CMD     := FileExist(_codePath) ? _codePath : "C:\Program Files\Microsoft VS Code\Code.exe"
modelCount        := Integer(IniRead(CFG_FILE, "Settings", "ModelCount",        "2"))
_utilsRaw         := FileExist(MMA_SRC_UTILS) ? FileRead(MMA_SRC_UTILS, "UTF-8") : ""
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
; The Python automation listener (automation\automation.py) runs the
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
; The bottom strip's height is worked out per-layout by ToggleLines(), since it
; wraps. TOGGLE_H is only the starting guess used to place the controls before
; the first ApplyLayout runs.
TOGGLE_H     := 90           ; height reserved below tabs for script toggles (2 rows)
TOG_GAP      := 10           ; horizontal space between two controls in the strip
TOG_LINE     := 34           ; one line of the strip, button height included
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

; MinSize is client-area, and 750x500 was wishful: at that size the right panel's
; rows ran off the edge and the bottom button strip sat under the paste box. This
; is roughly what the two panels side by side actually need — see LEFT_MIN /
; RIGHT_MIN below. The field list still wants ~700 tall to show every row.
g := Gui("+Resize +MinSize900x640", "MMA v" APP_VER)
g.SetFont("s9", "Segoe UI")

; ── Right panel helpers ────────────────────────────────────────────────────────

RegTop(ctrl, ox) {
    global topCtrls
    topCtrls.Push({c: ctrl, ox: ox})
}

; Hide a control whose feature is switched off (or which is Advanced-only while
; we are in Easy mode). It stays in the layout tables so resizing still works —
; it is simply not shown. The BEHAVIOUR behind each of these is gated separately;
; hiding a button is never the only thing stopping a feature.
FeatCtrl(ctrl, featureId) {
    if !FEAT(featureId)
        ctrl.Visible := false
    return ctrl
}

; For a control that IS a feature's on/off switch. Such a control must not be
; gated on the feature's own state: the Pinger button was, and since its cfg key
; means "the pinger is running" rather than "the pinger is available", switching
; the pinger off hid the only button that could switch it back on. These are
; hidden by mode alone — Easy has no business showing them, Advanced always does.
ModeCtrl(ctrl) {
    if MODE_IsEasy()
        ctrl.Visible := false
    return ctrl
}

RegBtn(ctrl, ox, oy) {
    global btnCtrls
    btnCtrls.Push({c: ctrl, ox: ox, oy: oy})
}

; The strip along the bottom of the LEFT panel: row 0 is the app buttons, row 1
; the acc-script toggles. Registered with a width instead of an x, because on
; resize they REFLOW — laid left to right and wrapped to whatever width the left
; panel currently has, skipping anything hidden. Fixed x is how "Alt FUs…" and
; "Branches…" (which start at TAB_X+745) ended up underneath the paste panel on
; any window narrower than ~1300, and how a feature switched off left a gap.
RegTog(ctrl, w, row) {
    global togCtrls
    togCtrls.Push({c: ctrl, w: w, row: row})
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
FeatCtrl(chkArchive, "archive")
RegBtn(chkArchive, 322, 6)

c := g.Add("Text", "x" PX0 " y" (BY+38) " w" (RIGHT_W-20) " h2 0x10")
RegBtn(c, 0, 38)

c := g.Add("Text",   "x" PX0 " y" (BY+52), "-- Load fields from file --")
RegBtn(c, 0, 52)
lblLoaded := g.Add("Text", "x" (PX0+190) " y" (BY+52) " w140", "")
RegBtn(lblLoaded, 190, 52)
c := g.Add("Button", "x" (PX0+338) " y" (BY+48) " w118 h22", "Load from archive")
c.OnEvent("Click", OpenArchive)
FeatCtrl(c, "archive")
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

; The x/y given here are placeholders — ApplyLayout reflows the whole strip
; before the window is shown, so only the width and the row matter.

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w130 h28", "Open with Code")
c.OnEvent("Click", (*) => Run(Chr(34) CODE_CMD Chr(34) " " Chr(34) SCRIPT_DIR Chr(34)))
RegTog(c, 130, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w80 h28", "Settings")
c.OnEvent("Click", OpenSettings)
RegTog(c, 80, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Add Hotkey")
c.OnEvent("Click", (*) => OpenAddHotkey())
RegTog(c, 95, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w85 h28", "How to Use")
c.OnEvent("Click", OpenGuide)
RegTog(c, 85, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w90 h28", "New Script")
c.OnEvent("Click", NewAccScript)
RegTog(c, 90, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w100 h28", "Hotstrings")
c.OnEvent("Click", OpenHotstrings)
FeatCtrl(c, "hotstrings")
RegTog(c, 100, 0)

; Label carries the state, so the button is also the running indicator.
btnPinger := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Pinger: OFF")
btnPinger.OnEvent("Click", TogglePinger)
ModeCtrl(btnPinger)   ; NOT FeatCtrl: this button is the pinger's own on/off switch
RegTog(btnPinger, 95, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Alt FUs…")
c.OnEvent("Click", OpenAltWindow)
FeatCtrl(c, "altFollowups")
RegTog(c, 95, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Branches…")
c.OnEvent("Click", OpenBranchWindow)
FeatCtrl(c, "altFollowups")
RegTog(c, 95, 0)

; (single/editable follow-up toggles moved inline onto the f1/f2/f3 rows above)

Loop Files, ACC_DIR "\*.ahk" {
    spath := A_LoopFilePath
    sname := StrReplace(A_LoopFileName, ".ahk", "")
    if (A_LoopFileName = "mass_gui.ahk" || A_LoopFileName = "mass_gui copy.ahk")
        continue
    if hiddenScripts.Has(A_LoopFileName)
        continue
    btn := g.Add("Button", "x" TAB_X " y" (TOGG_Y0+34) " w70 h28", "◻ " sname)
    btn.OnEvent("Click", MakeScriptToggle(spath, btn))
    RegTog(btn, 70, 1)
}

; ── What the two panels actually need ─────────────────────────────────────────
; Measured from the controls themselves rather than guessed, so adding a button
; to either panel keeps the minimums honest with no constant to remember.
;
; BTN_STACK_H — the tallest thing hanging off the right panel's button origin.
;               The paste box above it is capped so this always fits.
; RIGHT_MIN   — the width the right panel needs before its widest row (the
;               "Load from archive" line) starts running off the window edge.
BTN_STACK_H := 0
RIGHT_MIN   := 0
for _, bc in btnCtrls {
    if (bc.oy + 30 > BTN_STACK_H)
        BTN_STACK_H := bc.oy + 30
    bc.c.GetPos(, , &_bcW)
    if (bc.ox + _bcW + 20 > RIGHT_MIN)
        RIGHT_MIN := bc.ox + _bcW + 20
}
; The left panel needs its label gutter plus a usable edit box.
LEFT_MIN := EDIT_X + 200

lblCredit := g.Add("Text", "x10 y" (TOGG_Y0 + 38), "made by actually.silly")
; Measured before Show, because ApplyLayout needs the width and a resize can
; arrive the moment the window appears.
lblCredit.GetPos(, , &lblCreditW)

ApplyLayout(INIT_W, INIT_H)
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

; ── The bottom strip ──────────────────────────────────────────────────────────
; Two logical rows (app buttons, then script toggles). Each starts on a fresh
; line and wraps within the left panel, so nothing ever reaches under the paste
; panel however narrow the window gets. Hidden controls are skipped entirely —
; a feature switched off closes the gap instead of leaving a hole in the row.

; How many lines the strip needs at this left-panel width. Measured before the
; tabs are sized, because the tabs get whatever the strip does not.
ToggleLines(leftW) {
    global togCtrls, TAB_X, TOG_GAP
    lines := 0, x := TAB_X, curRow := -1
    for _, t in togCtrls {
        if !t.c.Visible
            continue
        if (t.row != curRow) {
            lines  += 1
            x      := TAB_X
            curRow := t.row
        } else if (x + t.w > TAB_X + leftW) {
            lines += 1
            x     := TAB_X
        }
        x += t.w + TOG_GAP
    }
    return Max(lines, 1)
}

; Same walk, this time moving the controls.
FlowToggles(leftW, topY) {
    global togCtrls, TAB_X, TOG_GAP, TOG_LINE
    x := TAB_X, y := topY, curRow := -1
    for _, t in togCtrls {
        if !t.c.Visible
            continue
        if (t.row != curRow) {
            if (curRow != -1)
                y += TOG_LINE
            x := TAB_X, curRow := t.row
        } else if (x + t.w > TAB_X + leftW) {
            x := TAB_X
            y += TOG_LINE
        }
        t.c.Move(x, y)
        x += t.w + TOG_GAP
    }
}

ApplyLayout(W, H) {
    global
    ; Around sixty controls move on every WM_SIZE. Left to repaint one at a time,
    ; dragging an edge tears the window — which is what "hates resizing" looked
    ; like. Suppress drawing for the batch and repaint once at the end. The
    ; finally is not optional: bail out with redraw still off and the window stays
    ; blank until it is next uncovered.
    DllCall("SendMessage", "Ptr", g.Hwnd, "UInt", 0x000B, "Ptr", 0, "Ptr", 0)  ; WM_SETREDRAW off
    try {
        ; The split is a proportion until one side would be squeezed below what
        ; its controls need. A flat 66% meant the right panel got 34% of a narrow
        ; window — a couple of hundred pixels for a column of 460px-wide rows, so
        ; "Export !mma", "load <model>" and "Load from archive" simply ran off the
        ; edge. Below LEFT_MIN + RIGHT_MIN there is no honest answer; MinSize
        ; keeps the window above it.
        pasteX := Round(W * PASTE_SPLIT)
        if (W - pasteX < RIGHT_MIN)
            pasteX := W - RIGHT_MIN
        pasteX := Max(pasteX, LEFT_MIN)
        leftW  := pasteX - TAB_X - 10

        ; The bottom strip claims its height first; the tabs take what is left.
        ; TOGGLE_H used to be a constant 90, so a strip that wrapped to a third
        ; line simply grew off the bottom edge.
        togH := ToggleLines(leftW) * TOG_LINE + 12
        togY := H - togH + 6

        ; The right panel's button stack is a fixed height, so the paste box above
        ; it can only have what is left over. Its old flat 52% share pushed the
        ; massNo radios past the bottom edge on anything under ~650px tall.
        newPasteH := Floor((H - 20) * 0.52)
        maxPasteH := H - 50 - BTN_STACK_H
        if (newPasteH > maxPasteH)
            newPasteH := maxPasteH
        newPasteH := Max(newPasteH, 90)

        for _, tc in topCtrls
            tc.c.Move(pasteX + tc.ox)
        edPaste.Move(pasteX + 10,, W - pasteX - 20, newPasteH)
        newBtnOrig := 26 + newPasteH + 12
        for _, bc in btnCtrls
            bc.c.Move(pasteX + bc.ox, newBtnOrig + bc.oy)

        editW := leftW - (EDIT_X - TAB_X) - 15
        tabs.Move(,, leftW, Max(togY - TAB_Y - 6, 120))
        for _, ec in resizables
            ec.Move(,, editW)

        FlowToggles(leftW, togY)
        lblCredit.Move(W - lblCreditW - 10, H - 20)
    }
    finally {
        DllCall("SendMessage", "Ptr", g.Hwnd, "UInt", 0x000B, "Ptr", 1, "Ptr", 0)
        ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
        DllCall("RedrawWindow", "Ptr", g.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0185)
    }
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

; ─── Parse / clear the paste box ──────────────────────────────────────────────

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
    if FEAT("archive") && chkArchive.Value && Trim(raw) != "" {
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

    ; The generated MassInit call only binds slots hotkeys.ahk declares. Without
    ; this the file would build fine and then bind nothing, logging to error_log
    ; where nobody looks.
    if !HK_META.Has("mass." num ".fu1") {
        MsgBox "No hotkeys are declared for model slot " num ".`n`n"
             . "Add a [mass." num "] section to hotkeys.ini and HK_Def lines to "
             . "hotkeys.ahk first, otherwise " fname " will load but none of its "
             . "hotkeys will work.",, 0x30
    }

    ; A model file is DATA plus one MassInit call. Every behaviour — follow-ups,
    ; alts, branches, PPV, __mm — is shared and lives in mass_runtime.ahk.
    ;
    ; This used to emit its own copy of DoFu1/DoFu2/DoFu3/DoPpv and the HK_Bind
    ; lines, but never the alt or branch functions. Regenerating a file therefore
    ; silently deleted its branch support, and the emitted follow-ups ignored the
    ; EditableFu / WalletCheckFu3 / OpenTab settings that 1_mass.ahk honoured.
    ; Emitting a shell instead is what keeps a generated model identical to a
    ; hand-written one.
    out := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n"
         . "; Model " num ". This file is DATA: the three mN blocks below hold the message`n"
         . "; text and nothing else. Follow-ups, alts, branches, PPV and the __mm hotstring`n"
         . "; are shared behaviour and live in mass_runtime.ahk — do not copy them in here.`n"
         . "#Include " q "mass_runtime.ahk" q "`n`n"
         . "; which of the three blocks the hotkeys act on; mass_gui rewrites this line`n"
         . "massNo := 1`n"
         . "modelFileNo := " num "`n`n"

    Loop 3
        out .= BuildBlock(A_Index) "`n`n"

    out .= "; Binds every [mass." num "] key hotkeys.ahk declares, applies the Mouse-control`n"
         . "; setting, and starts the active-model gating. See mass_runtime.ahk.`n"
         . "MassInit(" num ")`n"
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

; mass_gui.cfg is an ini, and an ini value is one line. A multi-line setting is
; stored with a literal `n per break — the escape the alt fields already use, and
; the one AltPartsRT reads, so the model scripts need no new decoder.
_EncodeMultiline(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "``n")
}
_DecodeMultiline(s) {
    return StrReplace(s, "``n", "`n")
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

    ; ── Layout ─────────────────────────────────────────────────────────────────
    ; Rows are placed with a running cursor. This used to be hand-counted offsets
    ; ("y + 126", "_sy + 102"), which held only while every label happened to fit
    ; on one line. Two of them outgrew their width, wrapped onto a second line and
    ; printed over the row beneath them and over the button strip — the window in
    ; the bug report. A cursor cannot drift: a row that needs more height takes it,
    ; and everything after it moves down.
    ;
    ; Two rules keep it that way:
    ;   • a checkbox with a status light gets LBL_W, which stops short of STAT_X
    ;   • rows of per-script checkboxes wrap at CW instead of running off the edge
    PAD    := 12
    W      := 620                  ; client width
    CW     := W - PAD * 2          ; usable content width
    STAT_X := PAD + CW - 96        ; the "● running" column
    LBL_W  := CW - 104             ; label width for a row that has one
    y      := 12

    ; ── Models ─────────────────────────────────────────────────────────────────
    sg.Add("Text", "x" PAD " y" (y+4) " w96", "Active models:")
    rdMC1 := sg.Add("Radio", "x" (PAD+100) " y" (y+2) " w36 Group", "1")
    rdMC2 := sg.Add("Radio", "x" (PAD+140) " y" (y+2) " w36",       "2")
    rdMC3 := sg.Add("Radio", "x" (PAD+180) " y" (y+2) " w36",       "3")
    rdMC1.Value := modelCount = 1
    rdMC2.Value := modelCount = 2
    rdMC3.Value := modelCount = 3
    y += 30

    sg.Add("Text", "x" PAD        " y" (y+3) " w62 Right", "Model 1:")
    ed1 := sg.Add("Edit", "x" (PAD+68)  " y" y " w118", model1Name)
    sg.Add("Text", "x" (PAD+196) " y" (y+3) " w62 Right", "Model 2:")
    ed2 := sg.Add("Edit", "x" (PAD+264) " y" y " w118", model2Name)
    sg.Add("Text", "x" (PAD+392) " y" (y+3) " w62 Right", "Model 3:")
    ed3 := sg.Add("Edit", "x" (PAD+460) " y" y " w118", model3Name)
    y += 30

    sg.Add("Text", "x" PAD " y" (y+3) " w62 Right", "Wait time:")
    edWT := sg.Add("Edit", "x" (PAD+68) " y" y " w58", waitTime)
    sg.Add("Text", "x" (PAD+132) " y" (y+3) " w24", "ms")
    sg.Add("Text", "x" (PAD+166) " y" (y+3) " w76 Right", "Default file:")
    ddlDef := sg.Add("DropDownList", "x" (PAD+248) " y" y " w158", _dhfList)
    chkMC := sg.Add("Checkbox", "x" (PAD+418) " y" (y+3) " w160", "Mouse control")
    chkMC.Value := mouseControl
    for i, f in _dhfList
        if f = defaultHotkeyFile {
            ddlDef.Value := i
            break
        }
    if ddlDef.Value = 0
        ddlDef.Value := 1
    y += 38

    ; ── Hotkeys ────────────────────────────────────────────────────────────────
    ; Every hotkey in MMA — not just the 15 model-send keys this grid used to
    ; show — is edited in its own window now, backed by hotkeys.ini.
    sg.Add("Text", "x" PAD " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" PAD " y" y " w" CW, "Hotkeys")
    sg.SetFont("s9 Norm")
    y += 22
    sg.Add("Button", "x" PAD " y" y " w150 h28", "Hotkeys…").OnEvent("Click", (*) => OpenHotkeysGui())
    sg.Add("Text", "x" (PAD+160) " y" (y+6) " w" (CW-160), "Every hotkey, grouped by feature. Applies live.")
    y += 40

    ; ── Sending ────────────────────────────────────────────────────────────────
    sg.Add("Text", "x" PAD " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" PAD " y" y " w" CW, "Sending")
    sg.SetFont("s9 Norm")
    y += 22
    sg.Add("Text", "x" PAD " y" (y+2) " w130", "Open new tab after:")
    chkTabFu2 := sg.Add("Checkbox", "x" (PAD+136) " y" y " w52", "FU2")
    chkTabFu3 := sg.Add("Checkbox", "x" (PAD+192) " y" y " w52", "FU3")
    chkTabPpv := sg.Add("Checkbox", "x" (PAD+248) " y" y " w52", "PPV")
    chkTabFu2.Value := openTabFu2
    chkTabFu3.Value := openTabFu3
    chkTabPpv.Value := openTabPpv
    y += 26
    chkDMM := sg.Add("Checkbox", "x" PAD " y" y " w160", "Double MM")
    chkDMM.Value := _doubleMM
    chkDMM.OnEvent("Click", (*) => (ToggleDoubleMM(), chkDMM.Value := _doubleMM))
    chkWallet := sg.Add("Checkbox", "x" (PAD+176) " y" y " w180", "Wallet check FU3")
    chkWallet.Value := walletCheckFu3
    chkWallet.OnEvent("Click", (*) => _BroadcastWallet(chkWallet.Value ? 1 : 0))
    y += 26
    chkFastSave := sg.Add("Checkbox", "x" PAD " y" y " w" CW, "Fast parse+autosave (auto-saves current model, no prompts)")
    chkFastSave.Value := fastParseAutosave
    y += 26
    ; On  = the plain follow-up key always sends the main branch, ctrl+key picks.
    ; Off = the plain key prompts whenever the follow-up has alts.
    chkPromptAlt := sg.Add("Checkbox", "x" PAD " y" y " w" CW, "Prompt for Alt-FUs using ctrl+hotkey (off = the plain key always prompts)")
    chkPromptAlt.Value := promptAltCtrl
    y += 28
    sg.Add("Text", "x" PAD " y" y " w" CW, "Default FU3 — sent when the mass has no f3 at all (one message per line):")
    y += 20
    edDefFu3 := sg.Add("Edit", "x" PAD " y" y " w" CW " h56 Multi WantReturn",
                       _DecodeMultiline(IniRead(CFG_FILE, "Settings", "DefaultFu3", "")))
    y += 66
    sg.Add("Text", "x" PAD " y" y " w" CW " cGray",
           "Leave blank for the old behaviour: an f3 key on a mass with no f3 does nothing.")
    y += 32

    ; ── Visible scripts ────────────────────────────────────────────────────────
    sg.Add("Text", "x" PAD " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" PAD " y" y " w" CW, "Visible scripts")
    sg.SetFont("s9 Norm")
    y += 22
    accChks := Map()
    ; Wraps at CW. It used to march right at a fixed 80px step with no wrap, so a
    ; sixth acc script simply left the window.
    xSc := PAD
    Loop Files, ACC_DIR "\*.ahk" {
        fname := A_LoopFileName
        if (xSc + 96 > PAD + CW) {
            xSc := PAD
            y += 24
        }
        chk := sg.Add("Checkbox", "x" xSc " y" y " w92", StrReplace(fname, ".ahk", ""))
        chk.Value := !hiddenScripts.Has(fname)
        accChks[fname] := chk
        xSc += 96
    }
    y += 38

    ; ── Run on startup ─────────────────────────────────────────────────────────
    sg.Add("Text", "x" PAD " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" PAD " y" y " w" CW, "Run on startup")
    sg.SetFont("s9 Norm")
    y += 22
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
    _sx := PAD
    for _, efn in _eligible {
        if (_sx + 100 > PAD + CW) {
            _sx := PAD
            y += 24
        }
        chk := sg.Add("Checkbox", "x" _sx " y" y " w96", StrReplace(efn, ".ahk", ""))
        chk.Value := _startSet.Has(efn)
        startChks[efn] := chk
        _sx += 100
    }
    y += 30

    chkAutoRestart := sg.Add("Checkbox", "x" PAD " y" y " w" CW, "Auto-restart these if they die (watchdog, checks every 5s)")
    chkAutoRestart.Value := autoRestart
    y += 24
    chkAutomation := sg.Add("Checkbox", "x" PAD " y" y " w" LBL_W, "Run the automation listener (serves the [automation] hotkeys)")
    chkAutomation.Value := automationListener
    y += 24
    chkPinger := sg.Add("Checkbox", "x" PAD " y" y " w" LBL_W, "Run the pinger (beeps when an Infloww tab goes unread)")
    chkPinger.Value := pinger
    ; Read the live process, not the setting — they disagree whenever the pinger
    ; was toggled from the main window, or died on its own.
    lblPinger := sg.Add("Text", "x" STAT_X " y" y " w96", "")
    y += 24
    chkAutoDetect := sg.Add("Checkbox", "x" PAD " y" y " w" LBL_W, "Auto-detect the active model (OCR) — one f1/f2/f3 set, gated by tab")
    chkAutoDetect.Value := autoDetect
    lblDetector := sg.Add("Text", "x" STAT_X " y" y " w96", "")
    y += 24
    ; The key, not the hotkey id: "gui.toggleStats" told you nothing about which
    ; keys to press, and it was the longer of the two labels that wrapped.
    chkStats := sg.Add("Checkbox", "x" PAD " y" y " w" LBL_W,
                       "Stats overlay (OCR of Infloww stats) — toggle: " HK_Key("gui.toggleStats"))
    chkStats.Value := statsOverlay
    lblStats := sg.Add("Text", "x" STAT_X " y" y " w96", "")
    y += 36

    PaintPingerStatus()
    sg.OnEvent("Close", StopPingerStatusTimer)
    SetTimer(PaintPingerStatus, 1500)

    ; ── Buttons ────────────────────────────────────────────────────────────────
    sg.Add("Text", "x" PAD " y" y " w" CW " h1 0x10")
    y += 12
    _bx := PAD
    sg.Add("Button", "x" _bx " y" y " w88 h28", "Save").OnEvent("Click", SaveCfg)
    _bx += 96
    sg.Add("Button", "x" _bx " y" y " w88 h28", "Reset").OnEvent("Click", ResetCfg)
    _bx += 96
    sg.Add("Button", "x" _bx " y" y " w96 h28", "Wipe Temp").OnEvent("Click", (*) => (WipeTemp(), sg.Destroy()))
    _bx += 104
    sg.Add("Button", "x" _bx " y" y " w88 h28", "Mode…").OnEvent("Click", (*) => (sg.Destroy(), OpenModesWindow()))
    _bx += 96
    sg.Add("Button", "x" _bx " y" y " w104 h28", "Check Update").OnEvent("Click", (*) => CheckUpdate())
    y += 40

    sg.Show("w" W " h" y)

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
        ; The model scripts re-read this on every f3 press, so no broadcast and no
        ; restart — saving is enough.
        IniWrite(_EncodeMultiline(edDefFu3.Value), CFG_FILE, "Settings", "DefaultFu3")
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
        ; apply the toggle now, both ways - unticking it should stop the running one.
        ; announce := true so ticking it on a machine with no Python explains itself
        ; instead of silently doing nothing.
        if automationListener
            LaunchAutomationListener(true)
        else
            StopAutomationListener()

        pinger := chkPinger.Value ? 1 : 0
        IniWrite(pinger, CFG_FILE, "Settings", "Pinger")
        if pinger
            LaunchPinger(true)
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

