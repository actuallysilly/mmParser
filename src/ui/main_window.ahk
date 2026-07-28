#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/crashlog.ahk"
#Include "../core/hotkeys.ahk"
#Include "../mass/store.ahk"
; Which model is on screen. Its own file precisely so the GUI can ask without
; including utils.ahk, whose hotstrings and send helpers belong to the message
; scripts, not to a window.
#Include "../core/active_model.ahk"
#Include "../mass/archive.ahk"
#Include "../mass/parser.ahk"
#Include "../core/processes.ahk"
; Every setting in one window: the tabs, the feature registry's checkboxes and the
; hotkey editor that used to be a separate process.
#Include "settings_window.ahk"
#Include "../screen/ocr_grab.ahk"
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
; HOW MANY alts is store.ahk's business — it owns the record shape, and a field
; count IS part of that shape. This file used to declare its own ALT_MAX := 3
; alongside utils.ahk's ALT_MAX_RT := 3, under a comment reading "must match
; ALT_MAX in main_window.ahk". Three copies of one number, kept in step by hand.
ALT_GROUPS := ["fu1", "fu2", "fu3"]

; "fu1" -> ["fu1_alt0", "fu1_alt1", "fu1_alt2"]
;
; Not MASS_AltFields(): that one takes the GROUP NUMBER and this takes the group
; NAME, which is what ALT_GROUPS and the control keys are built from. Same list,
; and now the same count behind it.
AltFields(group) {
    global MASS_ALT_MAX
    out := []
    Loop MASS_ALT_MAX
        out.Push(group "_alt" (A_Index - 1))
    return out
}

; ── Named branches ────────────────────────────────────────────────────────────
; A `--Name` marker in a pasted mass opens a whole alternate follow-up sequence
; (its own fu1/fu2/fu3 + ppv), sent as a continuation after the shared trunk. Each
; branch is stored in its own fields; a group's parts are `n-joined into one field,
; the same compact scheme the alts use. This REPLACED the old or-or (b2_*) branch.
; The count lives in store.ahk as MASS_BRANCH_MAX, for the same reason as the
; alts above.
;
; BRANCH_GROUPS / BranchFields() / AllBranchFields() stood here too, and so did
; AllAltFields(). All four were dead: they existed to emit the `mN := { … }`
; source block, and that serialiser went when the library became masses.json.
; MASS_BranchFields() in store.ahk is the surviving copy and returns the same
; five names.

; The mN := {} field list, in block order. Single source of truth — the loader,
; the writer and the new-file template all read it, so adding a field here is
; enough. They used to carry three separate copies of this list.
MassBlockProps() {
    return MASS_Fields()
}

; Fields whose value may span lines, so newlines survive the round trip as `n.
MassPropIsMultiline(prop) {
    return MASS_FieldIsMultiline(prop)
}

; AltParts() stood here — the same splitter as utils.ahk's AltPartsRT(), to the
; character. It had no callers left, and the surviving copy is MASS_SplitParts()
; in store.ahk, beside MASS_FieldIsMultiline() which says what needs splitting.

; MassHasAlts(), MakeAltGuiToggle() and AltGuiToggled() stood here. The first had
; no callers; the other two drove the "alt: gui" checkbox, and the modal chooser
; it switched to is gone — TAB staging is the only picker now.

; One cell of the Variants window: every way to answer ONE follow-up, in the
; order the staged list shows them. `grp` is "fu1"/"fu2"/"fu3" or "ppv".
;
; Only the alt and branch boxes are registered in edCtrls. "main" is a read-only
; echo, because the editable control for it is in the main panel and edCtrls maps
; one key to one control — registering it twice would leave the main panel's box
; loaded from nothing and saved from nothing.
VarBuildCell(gv, mNo, grp, x, y) {
    global edCtrls, varBaseEcho, varBranchLbls
    global VAR_LABEL_W, VAR_EDIT_DX, VAR_EDIT_W, MASS_BRANCH_MAX
    isPpv := (grp = "ppv")
    ex := x + VAR_EDIT_DX

    gv.SetFont("s10 Bold cB89CFF", "Segoe UI")
    gv.Add("Text", "x" x " y" y " w200", isPpv ? "PPV" : StrUpper(grp))
    gv.SetFont("s9 Norm cE6E4EE", "Segoe UI")
    y += 22

    gv.Add("Text", "x" x " y" (y+3) " w" VAR_LABEL_W " Right c8E8AA6", "main:")
    varBaseEcho[mNo "_" grp] := gv.Add("Edit",
        "x" ex " y" y " w" VAR_EDIT_W " h" (isPpv ? 38 : 20)
      . " ReadOnly -VScroll " (isPpv ? "Multi " : "") "Background201E2B")
    y += isPpv ? 44 : 26

    ; The PPV has no alt wordings — only the follow-ups do. Its alternatives are
    ; the branches' PPVs, which the loop below adds.
    if !isPpv {
        for ai, fld in AltFields(grp) {
            gv.Add("Text", "x" x " y" (y+3) " w" VAR_LABEL_W " Right c8E8AA6", "alt " ai ":")
            edCtrls["m" mNo "_" fld] := gv.Add("Edit",
                "x" ex " y" y " w" VAR_EDIT_W " h40 Multi +VScroll Background201E2B")
            y += 44
        }
    }

    Loop MASS_BRANCH_MAX {
        k   := A_Index
        key := "m" mNo "_br" k "_" grp
        varBranchLbls[key] := gv.Add("Text",
            "x" x " y" (y+3) " w" VAR_LABEL_W " Right c8E8AA6", "br" k ":")
        edCtrls[key] := gv.Add("Edit",
            "x" ex " y" y " w" VAR_EDIT_W " h40 Multi +VScroll Background201E2B")
        y += 44
    }
    return y
}

; Retitle branch k's four row labels from its name box. A branch is one thing
; spread across four cells, so naming it once has to be visible in all four.
VarRenameBranch(mNo, k, *) {
    global edCtrls, varBranchLbls
    nk := "m" mNo "_br" k "_name"
    nm := edCtrls.Has(nk) ? Trim(edCtrls[nk].Value) : ""
    if (nm = "")
        nm := "br" k
    else if (StrLen(nm) > 9)
        nm := SubStr(nm, 1, 8) Chr(0x2026)      ; the label is 78px, not elastic
    for _, grp in ["fu1", "fu2", "fu3", "ppv"] {
        lk := "m" mNo "_br" k "_" grp
        if varBranchLbls.Has(lk)
            varBranchLbls[lk].Text := nm ":"
    }
}

; Echo each "main" box into the Variants window and retitle every branch row, so
; the window reads correctly after a Load or a parse. Called by both.
VarRefresh() {
    global edCtrls, varBaseEcho, ALT_GROUPS, MASS_BRANCH_MAX
    Loop 3 {
        mNo := A_Index
        for _, grp in ALT_GROUPS {
            key := mNo "_" grp
            if !varBaseEcho.Has(key)
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
            varBaseEcho[key].Value := joined
        }
        pk := mNo "_ppv"
        if varBaseEcho.Has(pk) {
            bk := "m" mNo "_ppv_base"
            varBaseEcho[pk].Value := edCtrls.Has(bk) ? edCtrls[bk].Value : ""
        }
        Loop MASS_BRANCH_MAX
            VarRenameBranch(mNo, A_Index)
    }
}

OpenVariantsWindow(*) {
    global gVar, VAR_W, VAR_H, tabs, varTabs
    VarRefresh()
    varTabs.Value := tabs.Value          ; open on the model you are looking at
    gVar.Show("w" VAR_W " h" VAR_H)
}

AHK_CHARS  := ["``", Chr(34), ";"]   ; backtick must be first

; A leading "word:" is normally stripped as a field prefix (see StripPrefix). URL
; schemes must be exempt or "https://x" gets mangled into "//x". Add any other word
; that must never be treated as a prefix here (compared case-insensitively).
PREFIX_EXCEPTIONS := Map("http",1, "https",1, "ftp",1, "ftps",1, "mailto",1, "tel",1, "file",1)

edCtrls    := Map()
; Declared HERE, not beside the Variants window that fills them, because the main
; window is Show()n well before that block runs and VarRefresh() calls .Has() on
; both — an unset global would throw rather than find nothing.
varBaseEcho   := Map()  ; "<mNo>_<group>" → read-only echo of the main panel's box
varBranchLbls := Map()  ; "m<n>_br<k>_<grp>" → row label, retitled by the name box
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
_mFiles := MMA_ModelNames()
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

; ONE button. "Alt FUs…" and "Branches…" were two, opening two windows that
; edited two halves of the same list — see the Variants window below.
c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Variants…")
c.OnEvent("Click", OpenVariantsWindow)
FeatCtrl(c, "altFollowups")
RegTog(c, 95, 0)

; (single/editable follow-up toggles moved inline onto the f1/f2/f3 rows above)

Loop Files, ACC_DIR "\*.ahk" {
    spath := A_LoopFilePath
    sname := StrReplace(A_LoopFileName, ".ahk", "")
    if (A_LoopFileName = "main_window.ahk" || A_LoopFileName = "mass_gui copy.ahk")
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

; ─── Variants window (hidden until opened) ────────────────────────────────────
;  ONE window. It was two — "Alt FUs…" opened gAlt and "Branches…" opened
;  gBranch — which put the alternatives for f1 in one place and the branches'
;  version of f1 in another, with nothing on screen connecting them.
;
;  They are the same question. At send time the follow-up key stages exactly this
;  list and TAB walks it (see AltVariants in core/utils.ahk), so the window is
;  laid out to match what you will see in the chatbox: per follow-up, every way
;  to answer it, in order — main, the alts, then each branch.
;
;  What is EDITABLE here is only what has nowhere else to live: the alt fields,
;  the branch names, and each branch's fu1/fu2/fu3/ppv. "main" is the read-only
;  echo of the box in the main panel — registering a second control under the
;  same edCtrls key would orphan the first, and the main panel would silently
;  stop loading and saving it.
;
;  A branch spans all four cells, so its NAME is edited once at the top and the
;  row labels follow it live; a branch called "soft" reads "soft:" under FU1,
;  FU2, FU3 and PPV. That is the connection the two windows never showed.

VAR_W       := 980
VAR_H       := 812
VAR_COL1_X  := 12
VAR_COL2_X  := 498
VAR_LABEL_W := 78
VAR_EDIT_DX := 84                       ; edit offset from the column's left edge
VAR_EDIT_W  := 374
VAR_ROW1_Y  := 100
VAR_ROW2_Y  := 420                      ; a follow-up cell is 312 tall

; varBaseEcho / varBranchLbls are declared with edCtrls near the top — see there.

gVar := Gui("+Resize +MinSize720x520", "Variants — alts and branches")
gVar.BackColor := "15141C"
gVar.SetFont("s9 cE6E4EE", "Segoe UI")
varTabs := gVar.Add("Tab3", "x10 y10 w" (VAR_W-20) " h745", ["M1", "M2", "M3"])

Loop 3 {
    mNo := A_Index
    varTabs.UseTab(mNo)

    ; ── branch names, once for the whole tab ──────────────────────────────────
    gVar.SetFont("s10 Bold cB89CFF", "Segoe UI")
    gVar.Add("Text", "x" VAR_COL1_X " y42 w300", "BRANCHES")
    gVar.SetFont("s8 Norm c8E8AA6", "Segoe UI")
    gVar.Add("Text", "x" (VAR_COL1_X + 90) " y44 w560",
             "name them here — the rows below follow. Leave blank for none.")
    gVar.SetFont("s9 Norm cE6E4EE", "Segoe UI")
    Loop MASS_BRANCH_MAX {
        k  := A_Index
        bx := VAR_COL1_X + (k - 1) * 318
        gVar.Add("Text", "x" bx " y67 w18 Right c8E8AA6", k ":")
        ec := gVar.Add("Edit", "x" (bx + 24) " y64 w270 h22 Background201E2B")
        edCtrls["m" mNo "_br" k "_name"] := ec
        ec.OnEvent("Change", VarRenameBranch.Bind(mNo, k))
    }

    ; ── the four cells: FU1 FU2 / FU3 PPV ─────────────────────────────────────
    VarBuildCell(gVar, mNo, "fu1", VAR_COL1_X, VAR_ROW1_Y)
    VarBuildCell(gVar, mNo, "fu2", VAR_COL2_X, VAR_ROW1_Y)
    VarBuildCell(gVar, mNo, "fu3", VAR_COL1_X, VAR_ROW2_Y)
    VarBuildCell(gVar, mNo, "ppv", VAR_COL2_X, VAR_ROW2_Y)
}
varTabs.UseTab()

gVar.SetFont("s9 cE6E4EE", "Segoe UI")
gVar.Add("Button", "x10 y765 w120 h28", "Save to file")
     .OnEvent("Click", (*) => ApplyFile(MMA_ModelNames()[varTabs.Value]))
gVar.Add("Button", "x140 y765 w80 h28", "Close").OnEvent("Click", (*) => gVar.Hide())
gVar.SetFont("s8 c8E8AA6", "Segoe UI")
gVar.Add("Text", "x240 y771 w720",
         "Any of these may span lines — each line is sent as its own message. "
       . "The follow-up key stages them all; TAB moves, Enter sends, Esc cancels.")
ArchiveDarkTheme(gVar, [])

; The mass engine first, and unconditionally: it carries every mass hotkey, so
; without it MMA looks like it does nothing. Not part of StartupScripts — that
; list is rebuilt from checkboxes, and it lost the engine exactly once, silently.
LaunchEngine()

; auto-start configured startup scripts (defaults to general.ahk) if not already running
LaunchStartupScripts()
LaunchAutomationListener()
; FEAT rather than the globals above, which are read from the same cfg keys one
; way and would drift the moment anything wrote them without assigning back.
; Each Launch* refuses on its own feature anyway; this only avoids the call.
if FEAT("pinger")
    LaunchPinger()
if FEAT("modelDetector")
    LaunchDetector()
if FEAT("statsOverlay")
    LaunchStatsOverlay()
SetTimer(RefreshPingerLabel, -800)   ; after python has claimed the event
if autoRestart
    SetTimer(WatchdogTick, 5000)

; Ask about model names the detector cannot place. Here, in the GUI, because this
; opens a window — ActiveModelStatus is also read from #HotIf as you type, and a
; dialog there would be one popup per keystroke.
;
; Both globals are initialised HERE, before the timer that reads them, not down
; beside CheckUnmappedModel where they would read better. Top-level statements
; run in order and function bodies are skipped, so an initialiser further down
; the file has not run yet — the detector hit exactly that and threw
; "_wPos has not been assigned a value" on its first poll.
_askedNames := Map()      ; names asked about this session, so we ask once
_unmapGui   := 0          ; the prompt window, while it is open
if FEAT("modelDetector")
    SetTimer(CheckUnmappedModel, 4000)

; Off by default — see the autoUpdate FEAT_Def in core/modes.ahk. `silent` only
; suppresses the "already up to date" and "cannot reach the server" boxes; an
; update that IS available prompts either way, three seconds after launch, in
; front of whatever you were doing. The manual button in Settings is unaffected.
if FEAT("autoUpdate")
    SetTimer(() => CheckUpdate(true), -3000)

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
; Paste the clipboard into edPaste and parse it. Posted by copyDiscordMessageSeq
; in sequences.ahk, and by WebImportFromClipboard below.
OnMessage(MMA_MSG_AUTOPARSE, AutoParseFromClipboard)

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
    PostMessage(MMA_MSG_AUTOPARSE, 0, 0, , "ahk_id " g.Hwnd)   ; -> AutoParseFromClipboard
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
    VarRefresh()                ; alts and branches never surface in the main panel
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

; ─── Load / save the mass library ─────────────────────────────────────────────
; These used to read and WRITE AHK SOURCE: LoadFile regex-matched `mN := { … }`
; blocks out of a model script, and ApplyFile spliced new ones back in via
; BuildBlock/BuildMassTemplate/EscQ. All of that is gone — the library is data
; now, and mass/store.ahk is the only thing that touches the file.
;
; The fname argument survives because every caller passes one (the model tabs,
; the branch window, the Discord import). It is turned into a model NUMBER here
; and used for nothing else.

; "2_mass.ahk" -> 2. Kept tolerant: a bare number works too.
ModelNoOf(fname) {
    n := Integer(RegExReplace(fname, "\D", ""))
    return (n >= 1 && n <= MASS_MODELS) ? n : 1
}

LoadFile(fname) {
    global
    modelNo := ModelNoOf(fname)
    doc     := MASS_Load()
    ; `slot := A_Index` before the inner loop, NOT A_Index inside it. A_Index
    ; always refers to the INNERMOST loop, so inside the for-each it counts
    ; fields (1..44), not slots — which silently built control keys like
    ; "m17_fu1" that match nothing, and for the few that did exist wrote one
    ; slot's value into another's box. Saving was always fine; this is why it
    ; would not come back. ApplyFile below captures it the same way.
    Loop MASS_SLOTS {
        slot := A_Index
        rec  := MASS_Get(doc, modelNo, slot)
        for field, val in rec {
            ck := "m" slot "_" field
            if edCtrls.Has(ck)
                edCtrls[ck].Value := val
        }
    }
    VarRefresh()
    _nameMap := Map(1, model1Name, 2, model2Name, 3, model3Name)
    lblLoaded.Text := (_nameMap.Has(modelNo) ? _nameMap[modelNo] : fname) " loaded"
}

ApplyFile(fname, silent := false) {
    global
    modelNo := ModelNoOf(fname)
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

    ; Read-modify-write the WHOLE library, not just this model: the file holds all
    ; three, and the GUI only has this one on screen. Writing a document built from
    ; the edit boxes alone would blank the other two.
    doc := MASS_Load()
    Loop MASS_SLOTS {
        slot := A_Index
        rec  := MASS_Blank()
        for field in MASS_Fields() {
            ck := "m" slot "_" field
            rec[field] := edCtrls.Has(ck) ? edCtrls[ck].Value : ""
        }
        MASS_Set(doc, modelNo, slot, rec)
    }
    if !MASS_Save(doc)
        return
    engineUp := NotifyMassesChanged()
    if silent
        return
    if engineUp {
        MsgBox("Saved model " modelNo ".", "Done", 0x40)
        return
    }
    MsgBox("Saved model " modelNo " — but the mass engine is NOT running, so no "
         . "hotkey will send it.`n`nTick engine.ahk under Settings → startup "
         . "scripts, or run src\mass\engine.ahk.", "Saved, but nothing can send it",
           0x30)
}

; Tell the engine the library changed, so the next keypress sends the new text.
; No reload and no restart: the two processes share a FILE, and this is only the
; nudge to re-read it. Same broadcast the settings toggles use.
;
; Returns whether the engine was actually there to hear it. "Saved model 2" while
; nothing on the machine can send model 2 is a lie by omission — the save worked,
; but the thing the user is about to go and press does not exist.
NotifyMassesChanged() {
    try HK_Broadcast(MMA_MSG_MASSES_CHANGED)
    return EngineRunning()
}


; ─── Learning what a model is called on screen ────────────────────────────────
; MMA's model names, Infloww's tab labels and Discord's channel names are three
; different sets of names for the same people — "Rama" here is "Bellarama" there.
; No rule resolves that; MMA has to be told, once, and remember.
;
; [ActiveMap] File<n> is that memory: a comma-separated list of every on-screen
; name that means model n. This is what fills it in, by asking, replacing an
; auto-claim that used to guess silently and stick.
;
; Only ever asks about an "unknown" — one plausible name owned by no slot.
; "ambiguous" (two tabs read as one) is never asked about: the answer would file a
; string containing both models' names under one of them.

CheckUnmappedModel() {
    global _askedNames, _unmapGui
    if (IsObject(_unmapGui) && WinExist("ahk_id " _unmapGui.Hwnd))
        return                                   ; already asking
    ; Only name mode has names to ask about. Positional reads an index, manual
    ; reads your keypress — in both, a prompt about an OCR'd string would be
    ; asking you to map something nothing will ever look up.
    if (ModelMatchMode() != "name")
        return
    st := ActiveModelStatus()
    if (st.state != "unknown")
        return
    if !IsAskableModelName(st.name)
        return
    key := StrLower(st.name)
    if (_askedNames.Has(key) || IniRead(MMA_CFG, "ActiveMapIgnore", key, "") != "")
        return
    _askedNames[key] := true
    PromptUnmappedModel(st.name)
}

PromptUnmappedModel(detected) {
    global g, modelCount, _unmapGui
    items := []
    Loop modelCount
        items.Push(A_Index ": " ModelNameForSlot(A_Index))

    ; " +AlwaysOnTop" must be INSIDE the string. Written bare it is the unary +
    ; applied to a variable named AlwaysOnTop, which does not exist — an unset-
    ; variable throw the first time an unknown model appeared, i.e. exactly when
    ; this window is needed and never before.
    _unmapGui := Gui("+Owner" g.Hwnd " +AlwaysOnTop", "Unknown model on screen")
    ug := _unmapGui
    ug.SetFont("s9", "Segoe UI")
    ug.Add("Text", "x12 y12 w330",
           "Infloww is showing a model MMA does not recognise:")
    ug.SetFont("s11 Bold")
    ug.Add("Text", "x12 y34 w330", detected)
    ug.SetFont("s9 Norm")
    ug.Add("Text", "x12 y64 w330",
           "Which of your models is that? MMA will remember it, so the "
         . "follow-up keys can follow this tab.")
    ddl := ug.Add("DropDownList", "x12 y108 w200 Choose1", items)

    ug.Add("Button", "x12 y144 w110 h28 Default", "Remember").OnEvent("Click", Accept)
    ug.Add("Button", "x130 y144 w110 h28", "Not a model").OnEvent("Click", Ignore)
    ug.Add("Button", "x248 y144 w94 h28", "Later").OnEvent("Click", (*) => ug.Destroy())
    ug.OnEvent("Close", (*) => ug.Destroy())
    ug.OnEvent("Escape", (*) => ug.Destroy())
    ug.Show("w356 h186")

    Accept(*) {
        if ddl.Value
            ActiveMapAdd(ddl.Value, detected)
        ug.Destroy()
    }
    ; Remembered across restarts, unlike the ask-once map — a name that is not a
    ; model (a stray window, an OCR misread) would otherwise be asked about again
    ; every single launch.
    Ignore(*) {
        try IniWrite("1", MMA_CFG, "ActiveMapIgnore", StrLower(detected))
        ug.Destroy()
    }
}

; ─── Which mass a model sends ─────────────────────────────────────────────────
; Was a `massNo := 1` line rewritten inside a RUNNING script's source, which then
; had to be relaunched to take effect. It is state, so it lives with the data.

SetMassNo(fname, n, *) {
    doc := MASS_Load()
    MASS_SetMassNo(doc, ModelNoOf(fname), n)
    if MASS_Save(doc)
        NotifyMassesChanged()
}

ReadMassNo(fname) {
    return MASS_MassNo(MASS_Load(), ModelNoOf(fname))
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

; Launch the standalone Hotstrings manager (hotstrings_window.ahk). It's #SingleInstance,
; so clicking again just refreshes it rather than piling up windows.
OpenHotstrings(*) {
    global SCRIPT_DIR
    path := MMA_SRC "\ui\hotstrings_window.ahk"
    if !FileExist(path) {
        MsgBox "hotstrings_window.ahk isn't in " MMA_SRC "\ui", "Hotstrings", 0x30
        return
    }
    try Run(A_AhkPath ' "' path '"')
}

; mass_gui.cfg is an ini, and an ini value is one line. A multi-line setting is
; stored with a literal `n per break — the escape the alt fields already use, and
; the one MASS_SplitParts reads, so the model scripts need no new decoder.
_EncodeMultiline(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "``n")
}
_DecodeMultiline(s) {
    return StrReplace(s, "``n", "`n")
}

; ─── Settings ─────────────────────────────────────────────────────────────────
; OpenSettings used to be here: 570 lines building one tall 620px column, plus
; OpenHotkeysGui() to Run() the hotkey editor as its own process, plus
; RestartMassScripts() for the one setting that needed a restart.
;
; All three are src/ui/settings_window.ahk now — five tabs in one window. The
; restart is ApplyModeToRunning() in features_panel.ahk, which the mode switch
; already used and which handles every service rather than just the mass engine.

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

    localVerFile := MMA_VERSION
    localVer := FileExist(localVerFile) ? Trim(FileRead(localVerFile, "UTF-8")) : "0"

    ; ORDER, not equality.
    ;
    ; This used to be `remoteVer = localVer`, so any difference at all counted as
    ; "an update is available" — including the remote being OLDER. UPDATE_URL
    ; points at main, and a pre-release lives on a branch, so the moment
    ; version.txt here read 2.0.0-alpha every start would offer to "update" to
    ; main's 1.9.2 and the updater would overwrite the v2 tree with v1 files.
    ;
    ; Worse, that prompt is not suppressed by `silent`: the startup check runs
    ; three seconds after launch, so it would appear unbidden, in front of
    ; whatever you were doing, offering a downgrade that reads like an upgrade.
    ;
    ; VerCompare is AHK v2's built-in and understands pre-release suffixes the
    ; semver way — 2.0.0-alpha < 2.0.0 — so an alpha correctly updates to the
    ; release and never to what came before it.
    cmp := VerCompare(remoteVer, localVer)
    if (cmp = 0) {
        if !silent
            MsgBox "Already up to date (v" localVer ").",, 0x40
        return
    }
    if (cmp < 0) {
        ; Running something newer than what is published — a pre-release. Say so
        ; rather than silently doing nothing, so it is not mistaken for a broken
        ; update check.
        if !silent
            MsgBox "You are on v" localVer ", which is newer than the published "
                 . "v" remoteVer ".`nNothing to update.",, 0x40
        return
    }

    if MsgBox("Update available!`nInstalled: v" localVer "  →  Latest: v" remoteVer "`n`nDownload and restart now?", "Update", 0x24) != "Yes"
        return

    Run MMA_SRC "\updater.ahk"
    ExitApp
}

OpenAddHotkey(prefill := "", *) {
    global ACC_DIR, SCRIPT_DIR, g
    fileList  := []
    filePaths := []
    _genPath := MMA_CONTENT "\general.ahk"
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
        content := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " Chr(34) "../../src/core/utils.ahk" Chr(34) "`n"
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
    _guide := MMA_ROOT "\docs\mass-format.md"
    content := FileExist(_guide) ? FileRead(_guide) : "docs\mass-format.md not found."
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

; One engine now, so these are one broadcast rather than a loop that poked three
; model processes by window title. HK_Broadcast already finds every MMA script.
_BroadcastEditableFu(f, val) {
    ; Was `0x8002 + f` — arithmetic on a literal, correct only because the three
    ; EditableFu messages happen to sit directly above the wallet one. The name
    ; does the same sum in messages.ahk, where the numbers are.
    HK_Broadcast(MMA_MSG_EditableFu(f), val)
}

WipeTemp(*) {
    global ACC_DIR
    path    := ACC_DIR "\TEMP.ahk"
    headers := "#Requires AutoHotkey v2.0`n#SingleInstance Force`n#Include " Chr(34) "../../src/core/utils.ahk" Chr(34) "`n"
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
    for fp in [MMA_SRC_UTILS, MMA_CONTENT "\general.ahk"] {
        if FileExist(fp)
            files.Push(fp)
    }
    Loop Files, ACC_DIR "\*.ahk"
        files.Push(A_LoopFilePath)

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
    global _doubleMM
    _doubleMM := !_doubleMM
    HK_Broadcast(MMA_MSG_DOUBLE_MM)
    ToolTip("Double MM: " (_doubleMM ? "ON" : "OFF"))
    SetTimer(() => ToolTip(), -1500)
}

_BroadcastWallet(val) {
    global walletCheckFu3
    walletCheckFu3 := val
    HK_Broadcast(MMA_MSG_WALLET_FU3, val)
}

; ─── Hotkeys ──────────────────────────────────────────────────────────────────
; Keys live in hotkeys.ini under [gui]. "mouseControl" is this script's own
; context, so gui.toggleDoubleMM only fires while Mouse control is on.
HK_Context("mouseControl", (*) => mouseControl)

HK_Bind("gui.addHotkeyGrab",  AddHotkeyGrab)
HK_Bind("gui.ocrGrab",        OcrGrab)
HK_Bind("gui.toggleDoubleMM", ToggleDoubleMM)

