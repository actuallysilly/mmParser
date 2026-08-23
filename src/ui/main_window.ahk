#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "../core/theme.ahk"
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
#Include "tools_window.ahk"
; The Variants window's "Add alt-FU…" button. Its own file rather than another
; screenful in here: it is a self-contained form, and this file is the largest in
; MMA. It reaches back into edCtrls and the mass-slot helpers below, which is why
; it is included BY the window that owns them rather than standing on its own.
#Include "alt_fu_window.ahk"
; The picture in the bottom-right corner: finding her, scaling her to the space the
; controls leave, and playing her if she is a GIF. Its own file because it is all
; GDI+ and none of it is about this window's layout — ApplyLayout only asks which
; sizes exist and says where the biggest one that fits should go.
#Include "credit.ahk"
DetectHiddenWindows true

; ─── The two children that own hotkeys, started FIRST ─────────────────────────
;  The mass engine (every mass hotkey) and sequences.ahk (the Discord Ctrl+click
;  import and the other seq.* keys). Neither is optional and neither is a startup
;  script — see LaunchEngine/LaunchSequences in core/processes.ahk.
;
;  Up HERE rather than after the GUI is built, which is where these used to sit.
;  Everything between this line and g.Show() is window construction: three tabs,
;  the variants window, the archive, the settings tabs. That is hundreds of
;  milliseconds during which MMA is on screen — or worse, still painting — with
;  every hotkey it owns dead. Ctrl+clicking a Discord message in that gap does
;  nothing at all, which is indistinguishable from the import being broken, and
;  it is exactly when you would do it: the moment MMA comes up.
;
;  Nothing below depends on these having run, and neither script needs the GUI
;  window to exist — sequences.ahk only looks for it when you actually import.
LaunchEngine()
LaunchSequences()

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

; ── Branches: every alternative there is ──────────────────────────────────────
; A follow-up can be answered more than one way, and each of those ways is a
; BRANCH — a name plus its own fu1/fu2/fu3/ppv. Pick it at f1 and f2/f3/ppv
; continue on it. "alt" is not a feature, it is the name people give a branch that
; has no better name.
;
; It was two things until now: `fu<N>_alt<i>` fields for "another wording of this
; one follow-up", and `br<k>_*` for "a whole alternate sequence". Two syntaxes to
; write (`alt:` and `--Name`), two shapes to store, two halves of the Variants
; window to edit — and the send path merged them back into one list anyway before
; showing you anything (AltVariants in core/utils.ahk). So the alt fields are gone
; and the branch count went to MASS_BRANCH_MAX = 6 to absorb them. See the record
; shape in mass/store.ahk and the `::name` marker in mass/parser.ahk.
;
; ALT_GROUPS and AltFields() stood here, naming the alt fields for the parser and
; the Variants window. Both are gone with the fields; a group's alternatives are
; now "every branch that has something for this group", which is one loop over
; MASS_BranchFields().
;
; A branch's parts for one group live in ONE field, `n-joined, the same compact
; scheme ppv_base uses — MASS_SplitParts reads them back at send time. That is
; what keeps six branches from adding 72 fields to the record.

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

; One ROW of the Variants window: one branch, across all four groups.
;
;  ─── WHY IT IS A GRID NOW ────────────────────────────────────────────────────
;  It used to be four CELLS — one per follow-up — each listing "main", three alt
;  boxes and three branch boxes. A branch was therefore four boxes in four
;  different corners of the window, with only its repeated row label to say they
;  were the same thing, and the alt boxes sat between them belonging to nothing at
;  all. Reading "what does mexican say?" meant looking in four places.
;
;  One row per branch, one column per group, is the same data laid out the way it
;  is used: across the row is one branch's whole conversation, down a column is
;  every way to answer that one follow-up — which is exactly the list the picker
;  stages when you press the key.
;
;  The name box is the row's first cell, so a branch is named once, where you are
;  looking at it, instead of once in a separate strip at the top of the window.
VarBuildBranchRow(gv, mNo, k, y) {
    global edCtrls, VAR_NAME_W, VAR_COL_W, VAR_COL_GAP, VAR_GRID_X, VAR_ROW_H
    gv.Add("Text", "x" VAR_GRID_X " y" (y + 4) " w14 c8E8AA6", k)
    ec := gv.Add("Edit", "x" (VAR_GRID_X + 18) " y" y " w" (VAR_NAME_W - 18)
                       . " h22 Background201E2B")
    edCtrls["m" mNo "_br" k "_name"] := ec
    ; A branch with no name still sends; it is simply called "branch <k>" in the
    ; picker (see BranchList). The cue is what stops that being a surprise.
    CueBannerFor(ec, "name")

    x := VAR_GRID_X + VAR_NAME_W + VAR_COL_GAP
    for _, grp in ["fu1", "fu2", "fu3", "ppv"] {
        edCtrls["m" mNo "_br" k "_" grp] := gv.Add("Edit",
            "x" x " y" y " w" VAR_COL_W " h" (VAR_ROW_H - 8)
          . " Multi +VScroll Background201E2B")
        x += VAR_COL_W + VAR_COL_GAP
    }
}

; Grey placeholder text inside an empty Edit. EM_SETCUEBANNER, the same call the
; Hotstrings window's search box uses.
CueBannerFor(ctrl, text) {
    try DllCall("SendMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x1501, "Ptr", 1,
                "WStr", text)
}

; Echo the trunk's four boxes into the window's top row, so the grid reads as the
; picker will: "main" first, then every branch under it. Called after a Load and
; after a parse.
;
; The trunk is a read-only ECHO because its editable control is in the main panel,
; and edCtrls maps one key to one control — registering a second would leave the
; main panel's box loaded from nothing and saved from nothing.
VarRefresh() {
    global edCtrls, varBaseEcho, modelCount
    Loop modelCount {
        mNo := A_Index
        for _, grp in ["fu1", "fu2", "fu3"] {
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
                joined .= (joined != "" ? "`r`n" : "") p
            varBaseEcho[key].Value := joined
        }
        pk := mNo "_ppv"
        if varBaseEcho.Has(pk) {
            bk := "m" mNo "_ppv_base"
            varBaseEcho[pk].Value := edCtrls.Has(bk) ? edCtrls[bk].Value : ""
        }
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
; Declared HERE, not beside the Variants window that fills it, because the main
; window is Show()n well before that block runs and VarRefresh() calls .Has() on
; it — an unset global would throw rather than find nothing.
;
; varBranchLbls stood beside it: "m<n>_br<k>_<grp>" → the row label a branch's name
; box retitled, in all four of the cells that branch was spread across. The grid
; put the name IN the row, so there is nothing left to keep in step.
varBaseEcho   := Map()  ; "<mNo>_<group>" → read-only echo of the main panel's box
btnLoadOne  := 0      ; the single Load button, labelled with the current model
btnSaveOne  := 0      ; the single Save button, ditto
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
modelCount        := LOG_IniInt(CFG_FILE, "Settings", "ModelCount", 2)
_utilsRaw         := FileExist(MMA_SRC_UTILS) ? FileRead(MMA_SRC_UTILS, "UTF-8") : ""
waitTime          := RegExMatch(_utilsRaw, "\bwaitTime\b\s*:=\s*(\d+)", &_wm) ? Integer(_wm[1]) : 350
; One entry per slot, read in a loop rather than three named globals.
;
; model1Name/model2Name/model3Name were the shape that capped MMA at three models
; more thoroughly than any loop did: ModelNameForSlot ended `: model3Name`, so slot
; 4 did not fail — it silently answered with model 3's NAME, on every label,
; dropdown, import prompt and log line. A wrong answer that looks right is worse
; than a crash, so the triplet is gone rather than extended.
;
; The three globals are still assigned below, because settings_window.ahk and the
; archive read them by name; they are now views onto the array, not the storage.
modelNames := []
Loop MASS_MODELS
    modelNames.Push(IniRead(CFG_FILE, "Settings", "Model" A_Index, "Model " A_Index))
model1Name        := modelNames[1]
model2Name        := modelNames[2]
model3Name        := modelNames[3]
defaultHotkeyFile := IniRead(CFG_FILE, "Settings", "DefaultHotkeyFile", "TEMP.ahk")
mouseControl      := LOG_IniInt(CFG_FILE, "Settings", "MouseControl", 1)
openTabFu2        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabFu2", 0)
openTabFu3        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabFu3", 0)
openTabPpv        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabPpv", 0)
walletCheckFu3    := LOG_IniInt(CFG_FILE, "Settings", "WalletCheckFu3", 0)
fastParseAutosave := LOG_IniInt(CFG_FILE, "Settings", "FastParseAutosave", 0)
; The right panel's load/save block. Off = ONE Load and ONE Save that follow the
; tab you are on and say the model's name; on = the old grid of "load <model>" /
; "save <model>" pairs, one of each per model.
;
; Kept as a fallback rather than deleted: the grid can load one model while you are
; looking at another's tab, which the pair cannot, and anyone who worked that way
; for a year should not have it taken away by an update. Read once, at build time,
; because it decides which controls exist — Settings reloads MMA when it changes.
legacyLoadSave    := LOG_IniInt(CFG_FILE, "Settings", "LegacyLoadSaveUI", 0)
; Whether Parse also appends the pasted mass to the archive. This was a tick box
; sitting on the button row, next to Parse — a per-parse switch for a thing nobody
; decides per parse, taking up the space the archive's own button now uses. It is
; a preference, so it lives in Settings ▸ GUI, and it is on by default because the
; archive is worth nothing with holes in it.
;
; There is deliberately NO global for it: ParseCurrent reads the key at the moment
; it parses. Settings writes it without reloading MMA, and a cached copy would keep
; archiving (or keep not archiving) until the next restart.
; HiddenScripts is gone: it only ever decided which acc scripts got a "◻ NAME"
; toggle on the bottom strip, and that whole row is now Hotstrings > Startup
; scripts. The cfg key is left unread rather than deleted, so downgrading does not
; lose the list.
; scripts auto-launched on startup (default general.ahk, preserving old behavior) + watchdog toggle
startupScripts    := []
for _s in StrSplit(IniRead(CFG_FILE, "Settings", "StartupScripts", "general.ahk"), ",")
    if Trim(_s) != ""
        startupScripts.Push(Trim(_s))
autoRestart       := LOG_IniInt(CFG_FILE, "Settings", "AutoRestart", 0)
; The Python automation listener (automation\automation.py) runs the
; [automation] hotkeys. On by default: those keys are declared in hotkeys.ahk and
; shown in the Hotkeys GUI, so if the listener isn't up they'd look bound but do
; nothing. See LaunchAutomationListener().
automationListener := LOG_IniInt(CFG_FILE, "Settings", "AutomationListener", 1)
; The pinger (pinger\pinger.pyw) beeps when an Infloww fan tab goes unread. Off by
; default — it makes noise, so it should be an opt-in. See LaunchPinger().
pinger            := LOG_IniInt(CFG_FILE, "Settings", "Pinger", 0)
; The model detector (model_detector.ahk) reads the active Infloww tab's name and
; writes it to detector_status.ini, so one set of f1/f2/f3 keys serves whichever
; model is on screen. Off by default. See LaunchDetector().
autoDetect        := LOG_IniInt(CFG_FILE, "Settings", "AutoDetectModel", 0)
; The stats overlay (stats_overlay.ahk) OCRs the Infloww stats page and shows a
; toggleable overlay of Sales + the PPVs-sent/Fans-chatted ratio. See LaunchStatsOverlay().
statsOverlay      := LOG_IniInt(CFG_FILE, "Settings", "StatsOverlay", 0)
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

; ── the single Load / Save pair ───────────────────────────────────────────────
;  Named functions rather than lambdas so the log line says which model the click
;  meant. "It saved the wrong model" is answerable only if the click is recorded
;  separately from the save: the button reads the TAB, and if the tab was not what
;  you thought it was, that is the whole bug.
LoadCurrentTab(*) {
    global tabs
    _mNo := tabs.Value
    LOGD("gui.load", "Load (current tab) clicked while tab " _mNo " is in front")
    LoadFile(MMA_ModelNames()[_mNo])
}

SaveCurrentTab(*) {
    global tabs
    _mNo := tabs.Value
    LOGD("gui.save", "Save (current tab) clicked while tab " _mNo " is in front")
    ApplyFile(MMA_ModelNames()[_mNo])
}

; Put the current model's name on the Load and Save buttons, so the button you are
; about to press says which model it means. Called on a tab change, and after a
; rename in Settings.
;
; Never throws: it is called from a Change event and from the tail of the startup
; path, and a mislabelled button is not worth taking the window down for.
RefreshModelHeader(*) {
    global tabs, modelCount, legacyLoadSave, btnLoadOne, btnSaveOne

    ; Before the legacy guard below, deliberately: the Lock button exists in both
    ; layouts and it names the tab in front, so a tab change has to reach it
    ; whichever Load/Save arrangement is in use.
    RefreshLockButton()

    ; The legacy grid names every model on its own buttons, so there is nothing
    ; here for it to relabel.
    if (legacyLoadSave || !IsObject(btnLoadOne))
        return
    try {
        mNo := tabs.Value
        if (mNo < 1 || mNo > modelCount)
            return
        nm := ModelNameForSlot(mNo)
        if (Trim(nm) = "")
            nm := "Model " mNo
        btnLoadOne.Text := "Load " nm
        btnSaveOne.Text := "Save " nm
    }
}

; Initialised HERE, above the two functions that read it and well above the strip
; that creates it. RefreshModelHeader() is called during startup BEFORE the bottom
; strip exists, and in AHK v2 reading a global that has never been assigned throws
; — so a nice-looking `if !IsObject(btnLock)` guard is itself the crash unless the
; variable exists first. The same trap the _askedNames comment further down
; describes, in the other direction.
btnLock := 0

; ── the Lock button ───────────────────────────────────────────────────────────
;  Two states on one control, and the label carries the model in both — "Lock to
;  Rama" / "Unlock (Aliw)". A button reading just "Lock" would leave the one
;  question that matters ("which model?") to be answered by whatever you assume,
;  and locking to the wrong model is exactly the failure lock mode has to avoid.
;
;  Never throws. It is called from a tab-change event and from a timer, and a
;  mislabelled button is not worth taking the window down for — the same rule
;  RefreshModelHeader follows.
RefreshLockButton(*) {
    global btnLock, tabs, modelCount
    if !IsObject(btnLock)
        return
    try {
        n := LockedModelNo()
        if n {
            nm := ModelNameForSlot(n)
            btnLock.Text := "Unlock (" (Trim(nm) = "" ? "model " n : nm) ")"
            return
        }
        mNo := tabs.Value
        nm  := (mNo >= 1 && mNo <= modelCount) ? ModelNameForSlot(mNo) : ""
        btnLock.Text := "Lock to " (Trim(nm) = "" ? "model " mNo : nm)
    }
}

; Locking from here means the TAB IN FRONT — see the button's comment on the strip.
; Unlocking needs no model at all, which is why the two halves share a control:
; there is never a moment when you want "lock" and "unlock" at once.
ToggleLockFromGui(*) {
    global tabs, modelCount
    if MassIsLocked() {
        was := ClearMassLock()
        RefreshLockButton()
        ToolTip("Unlocked — the shared keys resolve the model normally again")
        SetTimer(() => ToolTip(), -1800)
        return
    }
    mNo := tabs.Value
    if (mNo < 1 || mNo > modelCount) {
        LOGW("model.lock", "Lock clicked while tab " mNo " is in front, which is not"
                         . " one of the " modelCount " model(s) — nothing locked")
        return
    }
    if !SetLockedModel(mNo)
        return
    RefreshLockButton()
    ; The engine's badge is up within one poll (700ms), and it is the thing that
    ; will still be telling you an hour from now. This tooltip is for the second
    ; after the click, when your eyes are here and not on the corner of the screen.
    ToolTip("Locked to " ModelLabel(mNo) "`nevery shared / side-button send goes to"
          . " this model until you unlock")
    SetTimer(() => ToolTip(), -2500)
}

btnLoadM := []
btnSaveM := []

; ─── GUI ──────────────────────────────────────────────────────────────────────

; MinSize is client-area, and 750x500 was wishful: at that size the right panel's
; rows ran off the edge and the bottom button strip sat under the paste box. This
; is roughly what the two panels side by side actually need — see LEFT_MIN /
; RIGHT_MIN below. The field list still wants ~700 tall to show every row.
g := Gui("+Resize +MinSize900x640", "MMA v" APP_VER)
; Off-white with a little pink in it, rather than the system white this used to
; be. Kept this pale on purpose: the window is mostly TEXT — mass bodies, field
; labels, the follow-up boxes — and a real pink behind black text is tiring to
; read for a whole shift. At this lightness it reads as "warm white" and the
; contrast against the text is within a hair of what plain white gave.
;
; Only the window itself. Edit boxes and the field list keep their own white, and
; that is deliberate too: it is what separates "somewhere you type" from the panel
; around it, and tinting those would take the distinction away.
; The colour itself lives in core/theme.ahk, because the follow-up picker — drawn
; by a DIFFERENT PROCESS — has to answer the same question, and a constant here
; could never reach it. Settings → GUI picks the theme; this reads it.
ApplyWindowTheme()
; The theme's ink goes on the window font, HERE, before a single control exists —
; that is how every label gets its colour. Colouring them afterwards does not
; work: a static on a tab page loses its background the moment you touch it. See
; THEME_ApplyTo.
g.SetFont("s9" THEME_FontOpt(), "Segoe UI")

; Paint the main window in whatever theme is set. Called once while building it,
; and again by Settings the moment the theme changes — switching is not worth a
; restart, and a restart mid-shift costs whatever was half-typed.
;
; Only the window. Edit boxes and the field list keep their own colours, which is
; deliberate: it is what separates "somewhere you type" from the panel around it.
ApplyWindowTheme() {
    global g
    bg := THEME_WindowBg()
    ; "Default" restores the SYSTEM colour rather than a hard-coded white. That is
    ; the whole point of the classic theme — it follows Windows, including a
    ; high-contrast scheme somebody may actually need to read the screen.
    g.BackColor := (bg = "") ? "Default" : bg
    ; The controls, for the themes that need it. Harmless before any exist, which
    ; is the case on the first call — this runs at the top of the file, before the
    ; window is built, so that the background is right from the first paint rather
    ; than flashing white and then correcting itself.
    try THEME_ApplyTo(g)
    ; Button labels in bold. Separate from the theme pass because it applies on
    ; every theme, classic included — see THEME_BoldButtons.
    try THEME_BoldButtons(g)
    ; The selected tab's label is drawn by MMA in the theme's accent colour, from
    ; fonts and colours cached on first paint. A theme change is the one thing that
    ; invalidates them, and this is the one place that knows it happened.
    try TabResetDraw()
    ; Fails harmlessly on the first call, when the window has not been shown yet.
    try WinRedraw("ahk_id " g.Hwnd)
}

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

; The archive's one control on this panel. It used to be a tick box here plus a
; small "Load from archive" button down in the load/save block — two controls for
; one feature, in two different places, and the tick box was a per-parse switch
; for something you either archive or you don't. The switch moved to
; Settings ▸ GUI (ArchiveOnParse); what is left is the door into the archive, and
; it belongs on this row, beside the other three things you DO to a mass.
; x+320, not +322: a 10px gap like the two before it, so the four buttons read as
; one row rather than three and a stray.
c := g.Add("Button", "x" (PX0+320) " y" BY " w120 h28", "Archive…")
c.OnEvent("Click", OpenArchive)
FeatCtrl(c, "archive")
RegBtn(c, 320, 0)

c := g.Add("Text", "x" PX0 " y" (BY+38) " w" (RIGHT_W-20) " h2 0x10")
RegBtn(c, 0, 38)

_mNames := modelNames
_mFiles := MMA_ModelNames()
; Three per row, wrapping. The row used to be one line of `modelCount` buttons at
; a width chosen by `modelCount = 3 ? 143 : 175`, which is a layout that has no
; answer for a fourth model: it would have run off the right edge of the column
; and taken the panel's whole right-hand side with it. Wrapping keeps the button
; width — and so the label "load Bellarama" — readable at any count.
_mPerRow := Min(modelCount, 3)
_mW      := _mPerRow = 3 ? 143 : 175
_mGap    := _mPerRow = 3 ? 8   : 10
_mRowH   := 32
_mRows   := Ceil(modelCount / _mPerRow)
; Everything below these two blocks shifts down by the rows we added. Computed
; once and applied to both the y AND the RegBtn offset, because those two drifting
; apart is what makes a control jump on the first resize.
_mExtra  := (_mRows - 1) * _mRowH

_MassBtnRow(yBase, label, makeHandler, store) {
    global g, modelCount, _mNames, _mFiles, _mW, _mGap, _mPerRow, _mRowH, PX0, BY
    Loop modelCount {
        i    := A_Index
        row  := (i - 1) // _mPerRow
        col  := Mod(i - 1, _mPerRow)
        xOff := col * (_mW + _mGap)
        yOff := yBase + row * _mRowH
        btn  := g.Add("Button", "x" (PX0 + xOff) " y" (BY + yOff) " w" _mW " h28",
                      label " " _mNames[i])
        btn.OnEvent("Click", makeHandler(_mFiles[i]))
        RegBtn(btn, xOff, yOff)
        store.Push(btn)
    }
}

; ── Load / save ───────────────────────────────────────────────────────────────
;  TWO buttons that follow the tab you are on, rather than 2N buttons naming every
;  model. The grid was a fair layout when it was six buttons; at eight models it is
;  sixteen, wrapped over six rows, and picking "save Bellarama" out of them is a
;  reading task performed under time pressure, next to "save Bella" — while the tab
;  in front of you already says which model you mean.
;
;  So the pair reads the tab, and its labels say the model's name out loud: "Load
;  Bellarama" / "Save Bellarama". Nothing about WHAT is saved changed — the mass
;  slot is still the "mass #" row on the model's own tab.
;
;  The grid is still here, behind Settings ▸ GUI ▸ "Use legacy Load/Save UI", for
;  the one thing the pair genuinely cannot do: load or save a model you are not
;  looking at.
if legacyLoadSave {
    c := g.Add("Text", "x" PX0 " y" (BY+52), "-- Load fields from file --")
    RegBtn(c, 0, 52)
    lblLoaded := g.Add("Text", "x" (PX0+190) " y" (BY+52) " w220", "")
    RegBtn(lblLoaded, 190, 52)

    _MassBtnRow(70, "load", MakeLoader, btnLoadM)

    c := g.Add("Text", "x" PX0 " y" (BY+108+_mExtra), "-- Apply to file --")
    RegBtn(c, 0, 108+_mExtra)

    ; The mass slot a save writes into is the "mass #" radio row at the bottom of
    ; that model's own tab — not a control here. See the note beside it.
    _MassBtnRow(126 + _mExtra, "save", MakeSaver, btnSaveM)

    ; The "-- Set massNo --" grid stood here: one row of 1/2/3 radios per MODEL. It
    ; is replaced by the "mass #" row on each tab — see the note there for why a
    ; per-model grid could not come along to N models. SetMassNo() itself survives
    ; and is still what ApplyFile calls, so the live slot is still recorded per
    ; model; you just set it by saving into it rather than by clicking a separate
    ; radio.
    c := g.Add("Text", "x" PX0 " y" (BY+164+_mExtra*2) " w300 c808080",
               "Saving writes the mass # picked on that model's tab.")
    RegBtn(c, 0, 164+_mExtra*2)
} else {
    ; No section header and no explanatory note. Both were removed on purpose: the
    ; buttons carry the model's name ("Save Bellarama"), which says what they act on
    ; better than a grey paragraph under them did, and the header labelled a section
    ; that is now two buttons. Every pixel they gave back goes to the picture in the
    ; corner, which sizes itself to whatever the controls do not claim.
    btnLoadOne := g.Add("Button", "x" PX0 " y" (BY+52) " w150 h30", "Load")
    btnLoadOne.OnEvent("Click", LoadCurrentTab)
    RegBtn(btnLoadOne, 0, 52)

    btnSaveOne := g.Add("Button", "x" (PX0+160) " y" (BY+52) " w150 h30", "Save")
    btnSaveOne.OnEvent("Click", SaveCurrentTab)
    RegBtn(btnSaveOne, 160, 52)

    ; Where "loaded (mass 2)" lands. Same control the legacy branch adds and the
    ; same global — LoadFile writes it either way and must not have to ask which
    ; layout is on screen.
    ;
    ; w220, not w320: the longest thing it ever holds is "<model> loaded (mass 3)".
    ; The extra hundred pixels were empty, and empty pixels inside a control are
    ; not free — see the picture note above.
    lblLoaded := g.Add("Text", "x" PX0 " y" (BY+88) " w220", "")
    RegBtn(lblLoaded, 0, 88)
}

; ── Left: tabs ─────────────────────────────────────────────────────────────────

; One tab per model, generated. These were the literal ["Mass 1","Mass 2","Mass 3"]
; — note they are MODEL tabs despite the label; the number is the model slot, not
; the massNo (that is the radio row above). Labelled with the model's name where it
; has one, because "Mass 4" tells you nothing once there are five of them.
_tabLabels := []
Loop modelCount
    _tabLabels.Push(Trim(modelNames[A_Index]) != "" ? modelNames[A_Index] : "Mass " A_Index)
; +0x2000 is TCS_OWNERDRAWFIXED: the system still draws the tab SHAPES, and MMA
; draws the label inside each one. That is what puts the accent colour on the
; selected model — see TabDrawItem below for why the strip's own highlight was not
; enough on its own.
tabs := g.Add("Tab3", "x" TAB_X " y" TAB_Y " w" INIT_TAB_W " h" (INIT_H - TAB_Y - 10 - TOGGLE_H)
                    . " +0x2000",
              _tabLabels)

; ── which tab is selected, in colour ──────────────────────────────────────────
;  A tab strip marks the selected tab with a few pixels of shading. On the dark
;  theme that is close to nothing, and "which model am I typing into" is a question
;  whose wrong answer is a save into the wrong model's file.
;
;  So the selected tab's LABEL is drawn in the accent colour and in bold, and the
;  others are not. Nothing else changes: same strip, same tabs, same names.
;
;  This needs TCS_OWNERDRAWFIXED (set above) because a tab control gives you no
;  say over its text colour otherwise — there is no per-item colour and no
;  message to ask for one. Owner-draw means the system still draws the tab SHAPES,
;  in the user's visual style, and sends us WM_DRAWITEM for the content of each
;  one. We draw exactly the text it would have drawn, in our colour.
;
;  Registered HERE rather than down with the other OnMessage calls at the bottom of
;  the file: those run after g.Show(), and the first paint happens during Show. A
;  handler registered later would leave every tab BLANK until something forced a
;  repaint, which is a far worse bug than the one this fixes.
TAB_FONT_N  := 0      ; the label font, normal — created once, on first paint
TAB_FONT_B  := 0      ;   and bold, for the selected tab
TAB_INK_SEL := 0      ; COLORREF (BGR) for the selected label
TAB_INK_OFF := 0      ;   and for the rest

; "RRGGBB" → the 0x00BBGGRR that every GDI call wants.
ColorBGR(hex) {
    v := Integer("0x" hex)
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

MakeTabFont(height, weight) {
    return DllCall("CreateFont", "Int", height, "Int", 0, "Int", 0, "Int", 0,
                   "Int", weight, "UInt", 0, "UInt", 0, "UInt", 0,
                   "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
                   "Str", "Segoe UI", "Ptr")
}

TabInitDraw() {
    global TAB_FONT_N, TAB_FONT_B, TAB_INK_SEL, TAB_INK_OFF
    if TAB_FONT_N
        return
    _h := -Round(9 * A_ScreenDPI / 72)
    TAB_FONT_N := MakeTabFont(_h, 400)
    TAB_FONT_B := MakeTabFont(_h, 700)
    _acc := THEME_Accent()
    if (_acc = "") {
        ; Classic: the system owns every colour, including a high-contrast scheme
        ; somebody may need in order to read the screen. Bold alone marks the
        ; selection there — a hard-coded hue could be invisible.
        _sys := DllCall("GetSysColor", "Int", 18, "UInt")   ; COLOR_BTNTEXT, already BGR
        TAB_INK_SEL := _sys
        TAB_INK_OFF := _sys
        return
    }
    TAB_INK_SEL := ColorBGR(_acc)
    ; NOT the theme's own ink. The tab SHAPES are drawn by the visual style and
    ; stay light on every theme — see the note in THEME_ApplyTo about what the
    ; system draws — so a dark theme's white label would be white on white.
    TAB_INK_OFF := ColorBGR("3C3C43")
}

; Drop the cached fonts and colours so the next paint rebuilds them. Called when
; the theme changes, which is the only thing that invalidates them.
TabResetDraw() {
    global TAB_FONT_N, TAB_FONT_B
    if TAB_FONT_N
        DllCall("DeleteObject", "Ptr", TAB_FONT_N)
    if TAB_FONT_B
        DllCall("DeleteObject", "Ptr", TAB_FONT_B)
    TAB_FONT_N := 0
    TAB_FONT_B := 0
}

TabDrawItem(wParam, lParam, msg, hwnd) {
    global tabs, _tabLabels, TAB_FONT_N, TAB_FONT_B, TAB_INK_SEL, TAB_INK_OFF
    ; DRAWITEMSTRUCT: CtlType, CtlID, itemID, itemAction, itemState (five UINTs),
    ; then hwndItem and hDC on the pointer alignment, then rcItem.
    ; ODT_TAB is 101, NOT 2 — 2 is ODT_LISTBOX. Measured: with the wrong constant
    ; this returns on every message, the tabs are owner-drawn by a handler that
    ; draws nothing, and the whole strip comes up BLANK. The style is set and the
    ; messages do arrive; nothing in the window looks like a bad comparison.
    if (NumGet(lParam, 0, "UInt") != 101)
        return
    _o := (A_PtrSize = 8) ? 24 : 20
    if (NumGet(lParam, _o, "Ptr") != tabs.Hwnd)      ; hwndItem — not our control
        return
    idx := NumGet(lParam, 8, "UInt") + 1             ; itemID is 0-based
    if (idx < 1 || idx > _tabLabels.Length)
        return
    TabInitDraw()
    sel := NumGet(lParam, 16, "UInt") & 0x0001       ; ODS_SELECTED
    hdc := NumGet(lParam, _o + A_PtrSize, "Ptr")
    rc  := lParam + _o + A_PtrSize * 2               ; rcItem, in place
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)       ; TRANSPARENT: keep the tab's own fill
    DllCall("SetTextColor", "Ptr", hdc, "UInt", sel ? TAB_INK_SEL : TAB_INK_OFF)
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", sel ? TAB_FONT_B : TAB_FONT_N, "Ptr")
    DllCall("DrawText", "Ptr", hdc, "Str", _tabLabels[idx], "Int", -1, "Ptr", rc,
            "UInt", 0x25)                            ; DT_CENTER|DT_VCENTER|DT_SINGLELINE
    ; Put the DC's own font back. A device context handed to us is not ours to
    ; leave changed, and the fonts are cached — one that is still selected into a
    ; DC cannot be deleted on a theme change.
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old, "Ptr")
    return 1                                          ; handled
}
OnMessage(0x002B, TabDrawItem)                        ; WM_DRAWITEM

; Follow-up toggles live in a left column, stacked per f-group (see the fu branch).
;   editFuChks[f] = [one mirror per mass]  — global "editable" toggle, kept in sync
;   fuChks[m][f]  = per-mass "single" toggle
; They sit at a fixed left x, so they need no repositioning on resize.
; One bucket per F-GROUP, not per model — the first index is f, the second is the
; mirror. `Loop modelCount` here is what put four [Continue][Abort] dialogs on
; every startup: at the default ModelCount of 2 the array had two buckets, and
; the first tab's f3 row hit editFuChks[3] with "Invalid index." Pressing
; Continue then substitutes "" for the failed subscript and runs the rest of the
; SAME line, so `"".Push()` raises a second dialog ("no method named Push") for
; every one of these — two failures, four dialogs. Three is the f-group count the
; row builder below hardcodes (fu1/fu2/fu3), and the same literal the WebView
; twin in tools\webview_main_window.ahk allocates with.
editFuChks := []
Loop 3
    editFuChks.Push([])
fuChks     := []
; massNoRadios[model] = [radio per mass slot]. One group per tab, built with the
; fields below, read by ApplyFile and set by LoadFile.
massNoRadios := []
; The slot each model's tab is currently SHOWING. Not the same as the live slot on
; disk: this tracks what is in the boxes, so switching the radio knows what it is
; switching away from (and can put the radio back if you cancel).
massNoCurrent := []

Loop modelCount {
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
        } else if prop = "mass" {
            ; Multi, like ppv — a mass is one message but not always one line. The
            ; `!mma` header form (MassHeaderBlock in mass/parser.ahk) pastes a whole
            ; paragraphed opener into this box, and in a single-line Edit those
            ; breaks come out as boxes you cannot see past or edit around.
            ec := g.Add("Edit", "x" EDIT_X " y" (y-2) " w" INIT_EDIT_W " h48 Multi")
            edCtrls["m" mNo "_" prop] := ec
            resizables.Push(ec)
            ; 54, not 48+6: the taller box already reads as a separated block, and
            ; the column of fields ends 30px above the tab's bottom edge even when
            ; the toggle strip below wraps to three lines. There is no room to
            ; spend on a gap that is already there.
            y += 54
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

    ; ── which of this model's masses these boxes are ──────────────────────────
    ;  Below the last field, inside the model's own tab, because that is the only
    ;  place it can be unambiguous: the tab tells you the model, this row tells you
    ;  the mass, and the boxes between them are what you are editing.
    ;
    ;  It replaces the old "-- Set massNo --" grid in the right-hand panel, which
    ;  was one row of radios PER MODEL — 408px of them at twelve models, off the
    ;  bottom of the panel and out of reach. One row per tab costs nothing per model.
    ;
    ;  Read at save time (ApplyFile), set at load time (LoadFile).
    y += 10
    g.Add("Text", "x" LABEL_X " y" y " w65 Right", "mass #:")
    massNoRadios.Push([])
    massNoCurrent.Push(1)
    _rx := EDIT_X
    Loop MASS_SLOTS {
        _s   := A_Index
        _opt := (_s = 1 ? "Group " : "") "x" _rx " y" (y - 2) " w46 h22"
        _rb  := g.Add("Radio", _opt, String(_s))
        _rb.Value := (_s = 1)          ; default 1; LoadFile corrects it per model
        ; Picking a slot SHOWS that slot, so it can be edited in place. .Bind, not a
        ; closure over mNo/_s — one function body means one of each, and every radio
        ; in the window would have picked the last model's last slot.
        _rb.OnEvent("Click", PickMassSlot.Bind(mNo, _s))
        massNoRadios[mNo].Push(_rb)
        _rx += 50
    }
}
tabs.UseTab()
; Switching tab switches which model every Load/Save on the right panel acts on, so
; the labels that name that model have to move with it.
tabs.OnEvent("Change", RefreshModelHeader)

; ── fill every model's tab from its live slot, now ────────────────────────────
;  A tab per model means every model is on screen at once, so leaving them all
;  blank until you press "load" is just a window that lies about your library.
;
;  It also fixes a prompt that would otherwise fire on the first click of every
;  session: the unsaved-changes check compares the boxes against the slot they are
;  showing, and empty boxes against a stored mass IS a difference. Loading up front
;  makes the two agree, so the warning means what it says.
;
;  Guarded as a whole: a library that cannot be read must not stop the window from
;  opening — without a window there is no way to fix anything.
try {
    _startDoc := MASS_Load()
    Loop modelCount {
        _mi := A_Index
        _sl := MASS_MassNo(_startDoc, _mi)
        if (_sl < 1 || _sl > MASS_SLOTS)
            _sl := 1
        FillTabFromSlot(_mi, _sl, _startDoc)
    }
    LOGI("gui.load", "opened with all " modelCount " model tab(s) filled from their"
                   . " live mass slots")
} catch as e
    LOGE("gui.load", "could not pre-fill the model tabs — they will be blank until"
                   . " you press load", LOG_Err(e))
; Unconditionally, outside the try: a library that failed to load still leaves a
; window whose Load/Save buttons have to name a model, or they come up reading
; "Load" and "Save" and the panel looks like it did not finish building.
RefreshModelHeader()

; ── Script toggle section (below mass tabs) ────────────────────────────────────

TOGG_Y0 := INIT_H - TOGGLE_H + 8   ; initial y of this section

; The x/y given here are placeholders — ApplyLayout reflows the whole strip
; before the window is shown, so only the width and the row matter.

; ── what is NOT on this strip any more ────────────────────────────────────────
;  "Open with Code" and "How to Use" moved to Settings > Scripts. Neither is a
;  thing you reach for while working a mass — one opens an editor, the other opens
;  the manual — and on the strip they sat between Settings and Add Hotkey, which
;  are.
;
;  "New Script" moved to the bottom of the Add Hotkey window. It creates a file
;  for hotkeys to go INTO, so it belongs where you are choosing that file, not one
;  window away from it.
;
;  "Add Hotkey" itself moved to the Hotstrings window. What it writes IS a
;  hotstring in one of the message files, and Hotstrings is the window that lists
;  them, searches them, overloads them and deletes them — so "add one" belongs
;  beside all of that rather than on the strip you reach across mid-send. The
;  window is a separate process and the dialog is built out of THIS file's
;  globals, so it asks for it by message: see MMA_MSG_ADD_HOTKEY below.
;
;  The per-script "◻ NAME" toggles are gone entirely, along with the Visible
;  scripts checkboxes in Settings that decided which of them appeared. Their one
;  real use — restarting a message script that has stopped responding — is now
;  Hotstrings > Startup scripts, which shows every script's live state instead of
;  a row of buttons whose labels went stale the moment anything died on its own.

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w80 h28", "Settings")
c.OnEvent("Click", OpenSettings)
RegTog(c, 80, 0)

c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w100 h28", "Hotstrings")
c.OnEvent("Click", OpenHotstrings)
FeatCtrl(c, "hotstrings")
RegTog(c, 100, 0)

; Was "Pinger: ON / OFF" — one background tool out of five, because it was the one
; people asked about. Now every tool is behind it, and the count is read rather
; than remembered: see tools_window.ahk and RefreshToolsLabel.
btnTools := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Tools")
btnTools.OnEvent("Click", (*) => OpenToolsWindow(g.Hwnd))
ModeCtrl(btnTools)   ; NOT FeatCtrl: this is where the tools' own switches live
RegTog(btnTools, 95, 0)

; ONE button. "Alt FUs…" and "Branches…" were two, opening two windows that
; edited two halves of the same list — see the Variants window below.
c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Variants…")
c.OnEvent("Click", OpenVariantsWindow)
FeatCtrl(c, "altFollowups")
RegTog(c, 95, 0)

; ── the lock ──────────────────────────────────────────────────────────────────
;  Lock mode pins every shared [mass.active] key to ONE model and stops the "which
;  model?" picker opening at all, because a shift is worked one model at a time —
;  see the lock-mode block in core/active_model.ahk.
;
;  It locks to THE TAB IN FRONT, not to whatever the engine last resolved, and the
;  button says which so the two can never disagree: from this window the model you
;  are looking at is the only unambiguous answer, and a button that reads "Lock to
;  Rama" cannot lock you to somebody else.
;
;  The engine owns the same switch on a key (mass.select.lock) and the picker owns
;  it on a checkbox. All three write the one cfg key and the badge follows it, so
;  none of them has to know the others exist.
btnLock := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w150 h28", "Lock to model")
btnLock.OnEvent("Click", ToggleLockFromGui)
RegTog(btnLock, 150, 0)

; (single/editable follow-up toggles moved inline onto the f1/f2/f3 rows above)

; ── What the two panels actually need ─────────────────────────────────────────
; Measured from the controls themselves rather than guessed, so adding a button
; to either panel keeps the minimums honest with no constant to remember.
;
; BTN_STACK_H — the tallest thing hanging off the right panel's button origin.
;               The paste box above it is capped so this always fits.
; RIGHT_MIN   — the width the right panel needs before its widest row (Parse …
;               Archive…) starts running off the window edge.
BTN_STACK_H := 0
RIGHT_MIN   := 0
for _, bc in btnCtrls {
    ; The control's OWN height, not a flat 30 for everything. The stack now ends in
    ; a wrapped grey line three rows tall, and a stack measured 15px short is a
    ; paste box allowed 15px too much — which eats the last line of it at the
    ; smallest window size, where the note is most worth reading.
    bc.c.GetPos(, , &_bcW, &_bcH)
    ; Kept on the entry, because the picture in the corner needs to know where
    ; every one of these actually IS to find the space none of them use. Measured
    ; once, here, rather than GetPos'd for ten controls on every WM_SIZE.
    bc.w := _bcW
    bc.h := _bcH
    if (bc.oy + _bcH + 8 > BTN_STACK_H)
        BTN_STACK_H := bc.oy + _bcH + 8
    if (bc.ox + _bcW + 20 > RIGHT_MIN)
        RIGHT_MIN := bc.ox + _bcW + 20
}
; The left panel needs its label gutter plus a usable edit box.
LEFT_MIN := EDIT_X + 200

; ── the credit, and the corner she stands in ──────────────────────────────────
;  She is whatever is in assets\ — an animated GIF if there is one, otherwise the
;  PNG. Drop a file in and she appears; delete it and the credit is just the line
;  of text again. Nothing else in MMA depends on her existing.
;
;  WHERE: the empty block under the right panel's button stack, above the credit.
;  That corner is dead space at every window size — the button stack is a fixed
;  height and the panel is not — so it is the one place a picture costs nothing.
;
;  HOW BIG: a ladder of discrete heights; ApplyLayout picks the largest whose
;  rectangle clears every visible control. The scaling, the frames and the timer
;  all live in credit.ahk — see the header there for why this stopped being a row
;  of hidden Picture controls.
CREDIT_PLAIN := "made by actually.silly"
lblCredit := g.Add("Text", "x10 y" (TOGG_Y0 + 38), CREDIT_PLAIN)
; Measured before Show, because ApplyLayout needs the width and a resize can
; arrive the moment the window appears.
lblCredit.GetPos(, , &lblCreditW)

; She is created here and asked about on every layout pass — CREDIT_Sizes() comes
; back EMPTY when there is no picture or Settings has her switched off, and every
; reader is a loop over it, so "no picture" needs no second code path.
CREDIT_Load(g, 10, TOGG_Y0 + 36)

ApplyLayout(INIT_W, INIT_H)
; Again, now that every control exists. The call at the top of the file set the
; background before the first paint; this one reaches the controls, which is what
; a dark theme needs and a light one does not. Cheap enough to do both ways round
; rather than reason about which themes need which.
ApplyWindowTheme()
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
;  ONE GRID: a row per branch, a column per follow-up.
;
;  It was two windows once ("Alt FUs…" and "Branches…"), then one window of four
;  cells — and the four cells still had the old split inside them: a "main" echo,
;  three `alt` boxes, then three branch boxes, per follow-up. So one branch was
;  four boxes in four corners, tied together only by a repeated row label, and the
;  alt boxes in between belonged to no branch at all. "What does mexican say?" was
;  a question you answered by looking in four places.
;
;  There is only one kind of alternative now (see the record shape in
;  mass/store.ahk), so the window is the shape of the data:
;
;              FU1          FU2          FU3          PPV
;    main      (echo)       (echo)       (echo)       (echo)
;    1 alt     …            …            …            …
;    2 mexican …            …            …            …
;
;  Across a row is one branch's whole conversation. Down a column is every way to
;  answer that follow-up — which is exactly the list the key stages and TAB walks
;  (AltVariants in core/utils.ahk). The name is edited in the row it names.
;
;  A cell may hold up to MASS_FU_PARTS lines, and each line is one message: the
;  same three sub-slots the trunk has (f1, f1.5, f1.7), for the same reason.
;
;  "main" is a read-only echo of the main panel's boxes — registering a second
;  control under the same edCtrls key would orphan the first, and the main panel
;  would silently stop loading and saving it.

VAR_GRID_X   := 14
VAR_NAME_W   := 120
VAR_COL_W    := 194
VAR_COL_GAP  := 8
VAR_ROW_H    := 62
VAR_HEAD_Y   := 74                      ; the FU1/FU2/FU3/PPV column headings
VAR_MAIN_Y   := 96                      ; the trunk echo row
VAR_ROWS_Y   := VAR_MAIN_Y + VAR_ROW_H + 10
VAR_W        := VAR_GRID_X * 2 + VAR_NAME_W + 4 * (VAR_COL_W + VAR_COL_GAP) + 16
VAR_H        := VAR_ROWS_Y + MASS_BRANCH_MAX * VAR_ROW_H + 92

; varBaseEcho is declared with edCtrls near the top — see there.

gVar := Gui("+Resize +MinSize720x520", "Variants — every way to answer a follow-up")
gVar.BackColor := "15141C"
gVar.SetFont("s9 cE6E4EE", "Segoe UI")
_varLabels := []
Loop modelCount
    _varLabels.Push("M" A_Index)
varTabs := gVar.Add("Tab3", "x10 y10 w" (VAR_W-20) " h" (VAR_H-56), _varLabels)

Loop modelCount {
    mNo := A_Index
    varTabs.UseTab(mNo)

    ; ── column headings ───────────────────────────────────────────────────────
    gVar.SetFont("s8 Norm c8E8AA6", "Segoe UI")
    gVar.Add("Text", "x" VAR_GRID_X " y42 w" (VAR_W - 40),
             "One row per branch. Across a row is that branch's whole conversation;"
           . " down a column is every way to answer that follow-up, in the order the"
           . " picker shows them. One line per message, up to " MASS_FU_PARTS ".")
    gVar.SetFont("s10 Bold cB89CFF", "Segoe UI")
    _hx := VAR_GRID_X + VAR_NAME_W + VAR_COL_GAP
    for _, _hd in ["FU1", "FU2", "FU3", "PPV"] {
        gVar.Add("Text", "x" _hx " y" VAR_HEAD_Y " w" VAR_COL_W, _hd)
        _hx += VAR_COL_W + VAR_COL_GAP
    }

    ; ── the trunk, read-only, as the first row of the same grid ───────────────
    gVar.SetFont("s9 Norm c8E8AA6", "Segoe UI")
    gVar.Add("Text", "x" VAR_GRID_X " y" (VAR_MAIN_Y + 6) " w" VAR_NAME_W, "main")
    gVar.SetFont("s9 Norm cE6E4EE", "Segoe UI")
    _mx := VAR_GRID_X + VAR_NAME_W + VAR_COL_GAP
    for _, _grp in ["fu1", "fu2", "fu3", "ppv"] {
        varBaseEcho[mNo "_" _grp] := gVar.Add("Edit",
            "x" _mx " y" VAR_MAIN_Y " w" VAR_COL_W " h" (VAR_ROW_H - 8)
          . " ReadOnly Multi +VScroll Background1B1A24")
        _mx += VAR_COL_W + VAR_COL_GAP
    }

    ; ── one row per branch ────────────────────────────────────────────────────
    Loop MASS_BRANCH_MAX
        VarBuildBranchRow(gVar, mNo, A_Index, VAR_ROWS_Y + (A_Index - 1) * VAR_ROW_H)
}
varTabs.UseTab()

gVar.SetFont("s9 cE6E4EE", "Segoe UI")
_varBtnY := VAR_H - 44
gVar.Add("Button", "x10 y" _varBtnY " w120 h28", "Save to file")
     .OnEvent("Click", (*) => ApplyFile(MMA_ModelNames()[varTabs.Value]))
gVar.Add("Button", "x140 y" _varBtnY " w80 h28", "Close").OnEvent("Click", (*) => gVar.Hide())
; ── the guided way in ─────────────────────────────────────────────────────────
;  The grid above is the whole mass at once, which is what you want for READING
;  it and not what you want for adding one line to it: it never says that a row
;  is a branch, that the row needs a name before the picker can offer it, or that
;  a second wording goes on a second LINE of one cell rather than in the next
;  column. This button asks those in order. See ui/alt_fu_window.ahk.
;  Through a lambda that passes NOTHING, not bound straight to the function: a
;  click handler is handed the control object as its first argument, and
;  OpenAddAltFu's first parameter is the text to prefill the paste box with.
gVar.Add("Button", "x230 y" _varBtnY " w120 h28", "Add alt-FU" Chr(0x2026))
     .OnEvent("Click", (*) => OpenAddAltFu())
gVar.SetFont("s8 c8E8AA6", "Segoe UI")
gVar.Add("Text", "x360 y" (_varBtnY + 6) " w" (VAR_W - 380),
         "Written in a paste as `::name text` — one marker, whatever the wording is."
       . "  The follow-up key stages them all; TAB moves, Enter sends, Esc cancels.")
ArchiveDarkTheme(gVar, [])
THEME_BoldButtons(gVar)

; LaunchEngine() and LaunchSequences() ran here until now. They run at the TOP of
; this file instead — both own hotkeys, and waiting for the whole GUI to be built
; left those keys dead for the first few hundred ms of every launch. The rest below
; can only run here: LaunchStartupScripts needs the `startupScripts` list, and the
; background services need the settings this file has now finished reading.

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
if FEAT("typelog")
    LaunchTypelog()
if FEAT("replyBox")
    LaunchReplyBox()
SetTimer(RefreshToolsLabel, -800)   ; after python has claimed the events

; The lock is set from three places in two processes — this button, the engine's
; lock key, and the picker's checkbox — so the button reads the cfg rather than
; remembering what it last did. One ini read every 1.2s, and it is what keeps this
; window from claiming "Lock to Rama" while a lock put on from a keypress is
; already live.
RefreshLockButton()
SetTimer(RefreshLockButton, 1200)
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
;
; Returns where the NEXT control would have gone, {x, y}. The credit line uses it
; to find out whether the strip's last line reaches across to it — see ApplyLayout.
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
    return {x: x, y: y}
}

; The last size ApplyLayout ran at, so anything that changes what the layout should
; DO can re-run it without knowing the window's size. Not WinGetClientPos: that
; answers in device pixels and every coordinate in here is in AHK's logical units,
; so on a 125% display it would lay the window out a quarter too big.
LAST_W := INIT_W
LAST_H := INIT_H

; Re-run the layout at the size it last ran at. For settings that change where
; things go without changing what exists — Settings ▸ GUI ▸ Corner picture is the
; first of them.
RelayoutNow() {
    global LAST_W, LAST_H
    ApplyLayout(LAST_W, LAST_H)
}

ApplyLayout(W, H) {
    global
    LAST_W := W, LAST_H := H
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
        ; "Export !mma", "load <model>" and "Archive…" simply ran off the
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
        creditY := H - 20
        lblCredit.Move(W - lblCreditW - 10, creditY)

        ; ── the empty corner, and the biggest copy of her that fits ───────────
        ;  The block under the right panel's button stack: from the bottom of the
        ;  stack down to the credit, and the panel's full width. Measured from the
        ;  stack rather than assumed, so adding a button to that panel takes its
        ;  space back automatically instead of drawing over her.
        ;
        ;  Largest-that-fits, and nothing at all when even the smallest does not.
        ;  Decoration is the first thing to give up room, never the controls.
        ;  Which rung fits is decided against the CONTROLS, not against a box drawn
        ;  under them. "Everything below the button stack" was the obvious rule and
        ;  it was far too mean: the stack's bottom half is the lblLoaded line and a
        ;  330px grey note, both left-aligned in a panel half again as wide, so the
        ;  rule threw away a tall column of genuinely empty space to the right of
        ;  them and capped her at a third of the size that fits.
        ;
        ;  So she is bottom-right-anchored, and a rung fits when its rectangle
        ;  overlaps NO visible control in the panel — checked against the real
        ;  positions, which also means a button added to that panel later takes its
        ;  space back on its own.
        ; Asked fresh, not cached: Settings can switch her off, on, or over to a
        ; different file while the window is up, and it says so by handing back a
        ; different list.
        picSizes := CREDIT_Sizes()
        if picSizes.Length {
            blockBot := creditY - 4                 ; clear of the credit line
            paneTop  := 26 + newPasteH + 8          ; clear of the paste box
            pick := 0, pickX := 0, pickY := 0
            for _i, p in picSizes {                 ; smallest first → ends on the
                picL := W - 8 - p.w                 ;   largest that fits
                picT := blockBot - p.h
                if (picT < paneTop || picL < pasteX + 8)
                    continue
                clear := true
                for _, bc in btnCtrls {
                    if !bc.c.Visible
                        continue
                    bl := pasteX + bc.ox, bt := newBtnOrig + bc.oy
                    ; 6px of air, so she never looks like she is touching a label.
                    if (picL < bl + bc.w + 6 && picL + p.w + 6 > bl
                     && picT < bt + bc.h + 6 && picT + p.h + 6 > bt) {
                        clear := false
                        break
                    }
                }
                if clear
                    pick := _i, pickX := picL, pickY := picT
            }
            CREDIT_Place(pick, pickX, pickY)
        } else {
            CREDIT_Place(0, 0, 0)   ; switched off, or no file — and stops the timer
        }
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
    ; tabs.Value first, every time. ParseCurrent fills the tab that is IN FRONT and
    ; ApplyFile saves the model it is given — the same number, or the import lands
    ; in one model's boxes and is written to another's file.
    if (fastParseAutosave && slot) {
        tabs.Value := slot
        ParseCurrent()
        ApplyFile(_mFiles[slot], true)
        _lastImportModel := slot
    } else if (fastParseAutosave && detected = "" && _lastImportModel) {
        tabs.Value := _lastImportModel
        ParseCurrent()
        ApplyFile(_mFiles[_lastImportModel], true)
    } else {
        PromptSaveTarget(detected)
    }
}
; Paste the clipboard into edPaste and parse it. Posted by copyDiscordMessageSeq
; in sequences.ahk, and by WebImportFromClipboard below.
OnMessage(MMA_MSG_AUTOPARSE, AutoParseFromClipboard)

; The Hotstrings window's "Add hotkey…" button. It is another process and the
; dialog below is built out of this file's globals — the account file list, the
; default target file, the snd/SendText writers — so the button asks for the
; window rather than building one of its own. See MMA_MSG_ADD_HOTKEY.
;
; The caller has already called AllowSetForegroundWindow for this process, which is
; what lets the dialog come up IN FRONT rather than blinking in the taskbar behind
; the window you pressed the button in.
OpenAddHotkeyFromMsg(wParam, lParam, msg, hwnd) {
    LOGI("gui.hotkey", "Add Hotkey requested by the Hotstrings window")
    OpenAddHotkey()
    return 1
}
OnMessage(MMA_MSG_ADD_HOTKEY, OpenAddHotkeyFromMsg)

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

; The name of a model slot, for any slot the tree supports.
;
; The ternary this replaces (`slot = 1 ? … : slot = 2 ? … : model3Name`) answered
; for slot 4, 5 and 40 with model 3's name — confidently and wrongly. Out of range
; now says so instead of guessing.
ModelNameForSlot(slot) {
    global modelNames
    if (slot < 1 || slot > modelNames.Length) {
        LOGW("model.name", "slot " slot " is outside the " modelNames.Length
                         . " model slot(s) that exist — no name for it")
        return ""
    }
    return modelNames[slot]
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

; A slot number that is safe to assign to a DropDownList holding `count` items.
;
; A DDL rejects any Value outside 1..count with "Invalid value.", and that throw is
; UNCAUGHT: the window never opens, and from Discord the import looks like it did
; nothing — the mass is on the clipboard, tagged, with nowhere to go. Reported from a
; fresh install, on the import prompt, which is the one window whose whole job is to
; handle a name MMA does not know yet. Crashing there takes out the only path a new
; user has.
;
; Guarded rather than reasoned about, because every caller derives a slot from
; something that can outlive the list it indexes: an alias saved in the cfg, the model
; count in Settings, or _lastImportModel from before either was changed. Each of those
; is bounded by modelCount *at the time it was written*, which is not the same number.
SafeSlot(want, count, where) {
    if (count < 1) {
        LOGE("gui.slot", where ": the model list is EMPTY, so no slot can be selected"
                       . " — check [Settings] ModelCount", "wanted slot " want)
        return 0
    }
    if (want >= 1 && want <= count)
        return want
    LOGW("gui.slot", where ": slot " want " is outside the " count " model(s) on offer"
                   . " — falling back to 1. (Left unguarded this threw 'Invalid value'"
                   . " and killed the window.)")
    return 1
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
    ; A prompt with nothing to pick is not a prompt. modelCount comes from the cfg,
    ; and a 0 there is read as a number, so it arrives here without a murmur.
    if !modelItems.Length {
        LOGE("gui.import", "modelCount is " modelCount ", so the import prompt had no"
                         . " models to offer — showing model 1 so the mass can still"
                         . " be routed", "[Settings] ModelCount in mass_gui.cfg")
        modelItems.Push("1: " ModelNameForSlot(1))
    }

    pg := Gui("+Owner" g.Hwnd, "Import — route to model")
    pg.SetFont("s9", "Segoe UI")

    pg.Add("Text", "x10 y14 w45", "Name:")
    cbName := pg.Add("ComboBox", "x60 y11 w190", KnownModelNames())
    cbName.Text := detectedName

    pg.Add("Text", "x10 y46 w45", "Model:")
    ddlModel := pg.Add("DropDownList", "x60 y43 w190", modelItems)
    _pre := MatchModelName(detectedName)
    _want := _pre ? _pre : (_lastImportModel ? _lastImportModel : 1)
    ddlModel.Value := SafeSlot(_want, modelItems.Length, "import prompt")
    ; The routing decision as the user is asked to confirm it. "It imported into the
    ; wrong model" is answered here: whether the NAME matched, or whether this is just
    ; the last model an import went to being offered again.
    LOGI("gui.import", "import prompt for '" (detectedName = "" ? "(no name)" : detectedName)
                     . "' — " (_pre ? "name matches model " _pre
                                    : _lastImportModel ? "name unknown, offering last import's model "
                                                       . _lastImportModel
                                                       : "name unknown, offering model 1")
                     . "   (" modelItems.Length " model(s) on offer)")

    ; ── which site this model is worked on ────────────────────────────────────
    ;  This is the first time MMA has seen this model, and the platform is the one
    ;  thing about it that nothing can work out on its own: it decides which
    ;  detector is expected to see the model, and getting it wrong is silent —
    ;  the follow-up keys simply stop resolving on that site.
    ;
    ;  It was only in Settings ▸ Models, a window away from the moment you are
    ;  actually telling MMA about a new model, so in practice it kept its default
    ;  and nobody found out until the keys misfired. Asked here it costs one
    ;  dropdown, once.
    ;
    ;  It follows the MODEL dropdown, not the name: platform is a fact about the
    ;  slot (it is stored as [Settings] Platform<n>), and picking a different model
    ;  has to show that model's answer rather than leave the last one's on screen.
    pg.Add("Text", "x10 y74 w48", "Site:")
    ddlPlat := pg.Add("DropDownList", "x60 y71 w190",
                      ["Infloww (detect)", "Fansly (detect)"])
    SyncPlatform()

    chkRemember := pg.Add("Checkbox", "x60 y102 w230", "Remember this name for the model")

    pg.Add("Text", "x10 y130 w45", "Mass #:")
    rd1 := pg.Add("Radio", "x60 y128 Group", "1")
    rd2 := pg.Add("Radio", "x105 y128", "2")
    rd3 := pg.Add("Radio", "x150 y128", "3")
    rd1.Value := true

    pg.Add("Button", "x10  y160 w110 h26 Default", "Parse + Save").OnEvent("Click", DoSave)
    pg.Add("Button", "x130 y160 w80 h26", "Cancel").OnEvent("Click", (*) => pg.Destroy())

    cbName.OnEvent("Change", NameChanged)   ; auto-pick the model when the name is known
    ddlModel.OnEvent("Change", (*) => SyncPlatform())
    ; w230 clipped the "Remember this name for the model" checkbox mid-word — the one
    ; control that tells you the prompt will not ask again. The widths above are fixed
    ; rather than AutoSize on purpose (see the GUI geometry notes: AutoSize and
    ; -DPIScale both undersize this window).
    pg.Show("w310 h202")

    ; Show the selected model's stored platform. Guarded on the slot, because a
    ; dropdown with nothing chosen reads 0 and ModelPlatform(0) is not a question.
    SyncPlatform(*) {
        s := ddlModel.Value
        if s
            ddlPlat.Value := (ModelPlatform(s) = "fansly") ? 2 : 1
    }

    NameChanged(*) {
        s := MatchModelName(cbName.Text)
        if s {
            ddlModel.Value := SafeSlot(s, modelItems.Length, "import prompt (name typed)")
            SyncPlatform()
        }
    }

    DoSave(*) {
        slot := ddlModel.Value
        ; 0 = nothing selected, which _mFiles[slot] turns into a throw at the moment
        ; you click Save — i.e. after you have already answered the prompt.
        if !slot {
            LOGE("gui.import", "Parse + Save clicked with no model selected — nothing"
                             . " saved. Pick a model in the dropdown.")
            return
        }
        if (chkRemember.Value && Trim(cbName.Text) != "")
            RememberModelName(cbName.Text, slot)
        ; Written whether or not "Remember" is ticked: that checkbox is about the
        ; NAME → model mapping, and the platform is a property of the model slot
        ; itself. Ticking nothing must not leave the site unrecorded.
        _plat := (ddlPlat.Value = 2) ? "fansly" : "infloww"
        if (ModelPlatform(slot) != _plat) {
            SetModelPlatform(slot, _plat)
            LOGI("gui.import", "model " slot " is now marked as a " _plat
                             . " model, from the import prompt")
        }
        _lastImportModel := slot
        ; The prompt's two answers now go to two different places. `tabs.Value` is
        ; the MODEL, because a tab is a model — this line used to put the "Mass #"
        ; radio into it, which under the new tabs would have parsed the text into
        ; model 2's boxes and then saved model 3.
        tabs.Value := slot
        SetMassNoRadio(slot, rd1.Value ? 1 : rd2.Value ? 2 : 3)
        ParseCurrent()
        ApplyFile(_mFiles[slot], true)
        pg.Destroy()
    }
}

; ─── Parse / clear the paste box ──────────────────────────────────────────────

ParseCurrent(*) {
    global
    LOGD("gui.parse", "Parse fired")
    raw := StrReplace(StrReplace(edPaste.Value, "`r`n", "`n"), "`r", "`n")
    mNo := tabs.Value
    ; Parsing into the WRONG TAB is the classic version of "it did not work": the
    ; text lands in model 3's boxes while you are looking at model 1's, so the
    ; fields you can see stay empty and it reads as the parser failing outright.
    LOGI("gui.parse", "parsing " StrLen(raw) " chars of pasted text into model "
                    . mNo "'s fields"
                    . (Trim(raw) = "" ? "  — THE PASTE BOX IS EMPTY, so this will"
                                      . " clear the fields and fill nothing" : ""))
    pfx := "m" mNo "_"
    for k, c in edCtrls
        if SubStr(k, 1, 3) = pfx
            c.Value := ""
    FillTab(StrSplit(raw, "`n"), mNo)
    VarRefresh()                ; alts and branches never surface in the main panel
    ; Archiving is silent in both directions now. It used to raise a Yes/No dialog
    ; on every duplicate — mid-parse, with the fields already filled, for the most
    ; ordinary thing you can do here: fix a line and press Parse again. The answer
    ; was "No" every time, so the dialog was a keystroke charged for nothing. A mass
    ; already archived TODAY is simply not archived twice; the tooltip says so.
    if FEAT("archive") && LOG_IniInt(CFG_FILE, "Settings", "ArchiveOnParse", 1)
                       && Trim(raw) != "" {
        mName := ModelNameForSlot(mNo)
        if Trim(mName) = ""
            mName := "m" mNo    ; an unnamed slot used to write "[]", which no dup check could match
        if dup := ArchiveFindDuplicate(mName, raw) {
            LOGI("gui.parse", "not archiving — this mass is already in the archive"
                            . " from " dup.ts " [" dup.model "]")
            ToolTip("Archive: already saved today")
            SetTimer(ClearArchiveTip, -1500)
        } else {
            ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            FileAppend "[" ts "] [" mName "]`n" raw "`n===END===`n`n", ArchiveFile(), "UTF-8"
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
    LOGD("gui.load", "Load fired for " fname " → model " modelNo)
    doc     := MASS_Load()
    ; `slot := A_Index` before the inner loop, NOT A_Index inside it. A_Index
    ; always refers to the INNERMOST loop, so inside the for-each it counts
    ; fields (1..44), not slots — which silently built control keys like
    ; "m17_fu1" that match nothing, and for the few that did exist wrote one
    ; slot's value into another's box. Saving was always fine; this is why it
    ; would not come back. ApplyFile below captures it the same way.
    ; The control keys are "m<MODEL>_<field>" now, because a tab is a MODEL. They
    ; were "m<SLOT>_<field>" when the tabs were the three masses and one model was
    ; on screen at a time — and leaving this loop indexing by slot while the tabs
    ; became models is precisely how the three-masses-per-model editing was lost:
    ; loading a model wrote its masses 1-3 across the first three MODELS' tabs.
    ;
    ; Which mass comes in is the model's own live slot, and the Mass # field is set
    ; to match, so the box always says what you are looking at.
    slot := MASS_MassNo(doc, modelNo)
    if (slot < 1 || slot > MASS_SLOTS)
        slot := 1
    FillTabFromSlot(modelNo, slot, doc)   ; also moves the radio and refreshes variants
    try tabs.Value := modelNo             ; bring the model you loaded to the front
    lblLoaded.Text := ModelNameForSlot(modelNo) " loaded (mass " slot ")"
    LOGI("gui.load", "loaded model " modelNo " (" fname ") mass slot " slot
                   . " into its tab")
}

ApplyFile(fname, silent := false) {
    global
    modelNo := ModelNoOf(fname)
    LOGD("gui.save", "Save fired for " fname " → model " modelNo
                   . (silent ? " (silent)" : ""))
    ; Only THIS model's boxes. It used to scan every control in the window, which
    ; was right when the window held one model; with a tab per model it would call
    ; a blank model "not empty" because a different model's tab has text — and the
    ; whole point of the check is to refuse a save that would blank this one.
    _pfx := "m" modelNo "_"
    allEmpty := true
    for k, c in edCtrls {
        if (SubStr(k, 1, StrLen(_pfx)) = _pfx && Trim(c.Value) != "") {
            allEmpty := false
            break
        }
    }
    if allEmpty {
        if silent {
            ; Not harmless. A silent save with every box blank is how a loaded-but-
            ; not-displayed tab gets written out empty — the "save blanks unloaded
            ; tabs" trap. Refusing is right; saying nothing about it is not.
            LOG_Bail("gui.save", "silent save of model " modelNo " SKIPPED — every"
                               . " field on screen is empty, and writing that would"
                               . " blank this model's masses on disk")
            return
        }
        if MsgBox("All fields are empty. Save anyway?", "Confirm Save", 0x24) != "Yes" {
            LOG_Bail("gui.save", "save of model " modelNo " cancelled at the"
                               . " all-fields-empty prompt")
            return
        }
        LOGW("gui.save", "saving model " modelNo " with EVERY FIELD EMPTY —"
                       . " confirmed at the prompt. This blanks its masses on disk.")
    }

    ; Read-modify-write the WHOLE library, not just this model: the file holds all
    ; three, and the GUI only has this one on screen. Writing a document built from
    ; the edit boxes alone would blank the other two.
    ; ONE mass slot, chosen in the Mass # field, into THIS model.
    ;
    ; This wrote all MASS_SLOTS at once, reading "m1_/m2_/m3_" as the three masses —
    ; correct while the tabs WERE the three masses. Now a tab is a model, so those
    ; same keys mean three different models, and the old loop would have written
    ; model 2's and model 3's text into model 1's masses 2 and 3.
    slot := MassNoForModel(modelNo)
    doc  := MASS_Load()
    rec := MASS_Blank()
    for field in MASS_Fields() {
        ck := "m" modelNo "_" field
        rec[field] := edCtrls.Has(ck) ? edCtrls[ck].Value : ""
    }
    MASS_Set(doc, modelNo, slot, rec)
    ; What you just saved is what the keys should send. Without this you would save
    ; into mass 2 and go on sending mass 1, which is the "hotkeys are broken" report
    ; that SetMassNo's own comment describes.
    MASS_SetMassNo(doc, modelNo, slot)
    ; The tab is now in step with the slot on disk, so a later switch away from it
    ; must not claim there are unsaved changes.
    if (modelNo >= 1 && modelNo <= massNoCurrent.Length)
        massNoCurrent[modelNo] := slot
    if !MASS_Save(doc)
        return
    engineUp := NotifyMassesChanged()
    LOGI("gui.save", "saved model " modelNo " into mass slot " slot
                   . " (now the live slot for this model)"
                   . (engineUp ? "" : "  — but THE ENGINE IS NOT RUNNING, so no"
                                    . " hotkey can send it"))
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
    up := EngineRunning()
    if !up
        LOGW("gui.save", "the mass engine is not running — masses.json was written"
                       . " but nothing is listening, so every mass hotkey is dead"
                       . " until it starts")
    return up
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
    ; Same guard as the import prompt: `Choose1` against an empty list is a window you
    ; cannot answer, on the path that exists to teach MMA a name it does not know.
    if !items.Length {
        LOGE("gui.unmapped", "modelCount is " modelCount ", so there was nothing to map"
                           . " '" detected "' to — offering model 1")
        items.Push("1: " ModelNameForSlot(1))
    }

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

; This one line decides which of a model's three masses EVERY hotkey sends, and
; getting it wrong is the commonest false "the hotkeys are broken": the keys work
; perfectly and send slot 2, which is empty, because the text is in slot 1.
;
; So it logs the switch AND whether the slot it just switched to has any text —
; the second half being the part that would otherwise take twenty minutes and a
; probe to discover.
; Put one model's mass slot into that model's tab.
;
; The one place edit boxes are filled from the library. Every field of the record is
; written, INCLUDING the empty ones — that is the whole point of loading a slot you
; have not written yet: mass 2 of a model that only has a mass 1 must come up blank,
; not leave mass 1's text sitting in the boxes looking like it belongs to mass 2.
FillTabFromSlot(modelNo, slot, doc := 0) {
    global edCtrls, massNoCurrent
    if !doc
        doc := MASS_Load()
    rec := MASS_Get(doc, modelNo, slot)
    for field in MASS_Fields()
        if edCtrls.Has("m" modelNo "_" field)
            edCtrls["m" modelNo "_" field].Value := rec.Has(field) ? rec[field] : ""
    if (modelNo >= 1 && modelNo <= massNoCurrent.Length)
        massNoCurrent[modelNo] := slot
    SetMassNoRadio(modelNo, slot)
    VarRefresh()
}

; Has this tab been edited away from what is stored in the slot it is showing?
;
; Asked before a slot switch throws the boxes away. Compares against the SLOT the
; tab is showing, not the live one, so it is true only when there is genuinely
; unsaved text — a switch that would cost you nothing must not put a dialog up.
TabDiffersFromSlot(modelNo, slot) {
    global edCtrls
    doc := MASS_Load()
    rec := MASS_Get(doc, modelNo, slot)
    for field in MASS_Fields() {
        ck := "m" modelNo "_" field
        if !edCtrls.Has(ck)
            continue
        stored := rec.Has(field) ? rec[field] : ""
        cur    := edCtrls[ck].Value
        if (cur != stored) {
            ; Which field, and both values. This decides whether you get a modal
            ; asking to discard your work, so when it is WRONG — and it was: it
            ; refused to leave a slot nobody had edited — the log has to name the
            ; field rather than leave you bisecting forty of them by hand.
            LOGI("gui.massno", "model " modelNo " differs from mass " slot
                             . " at field '" field "': on screen '"
                             . SubStr(cur, 1, 40) "' vs stored '"
                             . SubStr(stored, 1, 40) "'")
            return true
        }
    }
    LOGV("gui.massno", "model " modelNo " matches mass " slot " — no unsaved changes")
    return false
}

; Clicking a "mass #" radio.
;
; Loads that slot in place so it can be edited — which necessarily discards what is
; in the boxes. Unsaved text is the one thing in this window that exists nowhere
; else, so it asks first, and only when there is something to lose.
PickMassSlot(modelNo, slot, *) {
    global massNoCurrent, MASS_SLOTS
    if (slot < 1 || slot > MASS_SLOTS)
        return
    prev := (modelNo >= 1 && modelNo <= massNoCurrent.Length) ? massNoCurrent[modelNo] : 1
    if (slot = prev) {
        FillTabFromSlot(modelNo, slot)      ; re-click = reload, a free undo
        return
    }
    if TabDiffersFromSlot(modelNo, prev) {
        if (MsgBox("Mass " prev " has unsaved changes.`n`nSwitch to mass " slot
                 . " and lose them?", "Unsaved changes", 0x24) != "Yes") {
            SetMassNoRadio(modelNo, prev)   ; put the radio back where it was
            LOG_Bail("gui.massno", "switch from mass " prev " to " slot " on model "
                                 . modelNo " cancelled — unsaved edits kept")
            return
        }
        LOGW("gui.massno", "model " modelNo ": unsaved edits to mass " prev
                         . " discarded, confirmed at the prompt")
    }
    doc := MASS_Load()
    FillTabFromSlot(modelNo, slot, doc)

    ; The radio is this model's mass, full stop: what you SEE, what a save writes,
    ; and what the hotkeys SEND. The old "-- Set massNo --" grid wrote the live slot
    ; the moment you clicked it, and dropping that half made the row look broken —
    ; Aliw sat on mass 3 because that was its live slot, and clicking mass 1 changed
    ; the boxes while every key went on sending 3. One control, one meaning.
    MASS_SetMassNo(doc, modelNo, slot)
    empty := (Trim(MASS_Get(doc, modelNo, slot)["mass"]) = "")
    if MASS_Save(doc)
        NotifyMassesChanged()
    LOGI("gui.massno", "model " modelNo " is now on mass " slot
                     . " — shown in its tab, and what the keys send"
                     . (empty ? ". That slot is EMPTY, so the mass keys will do"
                              . " nothing for this model until you fill it in" : ""))
}

; The mass slot picked on a model's tab, or 1 if that row is somehow unanswered.
;
; A radio group with nothing selected is a real state — a `Group` run reads 0 for
; every button until one is clicked — so this never assumes and never throws.
MassNoForModel(modelNo) {
    global massNoRadios, MASS_SLOTS
    if (modelNo < 1 || modelNo > massNoRadios.Length)
        return 1
    for i, rb in massNoRadios[modelNo]
        if rb.Value
            return (i >= 1 && i <= MASS_SLOTS) ? i : 1
    LOGW("gui.massno", "model " modelNo " has no mass # selected on its tab —"
                     . " defaulting to 1")
    return 1
}

SetMassNoRadio(modelNo, slot) {
    global massNoRadios
    if (modelNo < 1 || modelNo > massNoRadios.Length)
        return
    for i, rb in massNoRadios[modelNo]
        rb.Value := (i = slot)
}

SetMassNo(fname, n, *) {
    doc := MASS_Load()
    modelNo := ModelNoOf(fname)
    MASS_SetMassNo(doc, modelNo, n)
    empty := (Trim(MASS_Get(doc, modelNo, n)["mass"]) = "")
    LOGI("gui.massno", "model " modelNo " now sends mass slot " n
                     . (empty ? "  — WARNING: that slot has no mass text, so the"
                              . " mass keys will do nothing until you fill it in"
                              . " or pick another slot" : ""))
    if MASS_Save(doc)
        NotifyMassesChanged()
}

ReadMassNo(fname) {
    return MASS_MassNo(MASS_Load(), ModelNoOf(fname))
}

; ─── Settings ─────────────────────────────────────────────────────────────────

UpdateModelButtons() {
    global modelCount, modelNames, btnLoadM, btnSaveM
    ; Guarded on the arrays rather than modelCount: a rename applies live, but a
    ; CHANGE of model count restarts MMA (Settings does that deliberately), so
    ; between the write and the restart modelCount can be ahead of the buttons
    ; that exist. Indexing past them would throw inside a settings save.
    Loop Min(modelCount, Min(btnLoadM.Length, btnSaveM.Length)) {
        i := A_Index
        if (i > modelNames.Length)
            break
        btnLoadM[i].Text := "load " modelNames[i]
        btnSaveM[i].Text := "save " modelNames[i]
    }
    ; The other layout keeps the name on ONE pair of buttons, which the loop above
    ; does not touch. Returns immediately under the legacy grid.
    RefreshModelHeader()
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

    ; ── an optional key, recorded rather than typed ───────────────────────────
    ;  A hotstring you are writing because you will send it forty times a day is
    ;  exactly the one that wants a key, and this is the moment you know that —
    ;  not later, in another window, having remembered.
    ;
    ;  RECORDED, not typed. The Hotkey box above takes `^!9` as text and always
    ;  has, and that is a different thing in two ways: it writes a bare hotkey
    ;  block into the message file (invisible to the Hotkeys tab and to the
    ;  conflict report — see core/utils.ahk), and it asks you to know that `#` is
    ;  Win and `+` is Shift. This captures the chord you press and stores it as a
    ;  [hotstring] binding against the trigger, which is the same thing the
    ;  Hotstrings window's Hotkey button writes.
    ;
    ;  Nothing is written until Append. Recording is a note to the dialog.
    _recKey := ""
    ah.SetFont("s9")
    ah.Add("Text", "x390 y207 w60 Right", "Key:")
    lblRec := ah.Add("Text", "x455 y207 w150", "(none — optional)")
    btnRec := ah.Add("Button", "x610 y202 w90 h28", "Record" Chr(0x2026))
    btnRec.OnEvent("Click", RecordKey)
    btnRecClear := ah.Add("Button", "x706 y202 w60 h28", "Clear")
    btnRecClear.OnEvent("Click", ClearKey)

    ; ── the other thing this text can BE ──────────────────────────────────────
    ;  Everything else in this window writes a HOTSTRING: a trigger you type, and
    ;  the text it expands to. But the text that arrives here by OCR is usually a
    ;  message you have just sent BY HAND in a real chat, and the reason you
    ;  grabbed it is that it worked better than the follow-up MMA has. That
    ;  belongs in the mass, not behind a trigger — and until now the only route
    ;  was to remember it, find the model's tab, find the right box, and retype it.
    ;
    ;  So: same text, same box, one more button. It hands the Lines box to the
    ;  capture window (ui/alt_fu_window.ahk), which asks which model, which mass
    ;  and which follow-up — opening on the one you last SENT — and then either
    ;  replaces that follow-up or adds the wording as an alt. It saves on the way
    ;  out, because you are in Infloww, not in the editor.
    ;
    ;  This window is deliberately LEFT OPEN behind it. OCR'd text is expensive to
    ;  get back — a second drag, on a chat that has since scrolled — so closing on
    ;  the way out would lose it for anyone who then cancelled over there.
    ah.Add("Button", "x200 y202 w170 h28", "Replace follow-up" Chr(0x2026))
      .OnEvent("Click", ToFollowUp)
    ; "New Script" lives here rather than on the main window's bottom strip. The
    ; only reason to make one is to have somewhere for a hotkey to go, and this is
    ; the window where you pick that somewhere — so the new file drops straight
    ; into the File dropdown above and is selected, with nothing to reload.
    ah.Add("Button", "x" (W - 130) " y202 w120 h28", "New Script"
                   . Chr(0x2026)).OnEvent("Click", (*) => NewAccScript(ah.Hwnd, AddCreated))
    ah.Show("w" W " h245")

    ; ── recording ─────────────────────────────────────────────────────────────
    ;  DUPLICATES ARE REFUSED, not warned about. A hotstring key is global — it
    ;  fires in Infloww, in Discord, in your browser — so it overlaps with
    ;  everything, and "both fire, and the winner is whichever script loaded
    ;  last" is not a state worth offering. The check reads hotkeys.ini rather
    ;  than this process's own declarations, because the ini is the only place
    ;  every key in MMA is written down (see HK_KeyOwner).
    ;
    ;  Checked again at Append, deliberately: minutes can pass between recording
    ;  a key and pressing Append, the Hotkeys tab is one window away, and the
    ;  trigger you type afterwards decides which id this even is.
    RecordKey(*) {
        ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" ah.Hwnd)
        ov.BackColor := "1E1E1E"
        ov.SetFont("s11 cWhite", "Segoe UI")
        prompt := ov.Add("Text", "x0 y16 w420 Center", "Press a key for this hotstring…")
        ov.SetFont("s9 c9A9A9A")
        ov.Add("Text", "x0 y44 w420 Center", "Esc = cancel     Backspace = no key")
        ov.Show("w420 h80")

        ; Every MMA script holds fire while we listen, or pressing F1 to record it
        ; would also send model 1's follow-up. The un-suspend MUST run even if the
        ; grab throws, or every hotkey in MMA stays dead with no clue why.
        HK_Broadcast(HK_MSG_SUSPEND, 1)
        try
            k := HKP_GrabKey(prompt)
        finally {
            HK_Broadcast(HK_MSG_SUSPEND, 0)
            ov.Destroy()
        }

        if (k = "<cancel>")
            return
        if (k = "<clear>") {
            ClearKey()
            return
        }
        owner := HK_KeyOwner(k)
        if (owner != "") {
            MsgBox(HKP_KeyLabel(k) " is already used by:`n`n    " owner
                 . "`n`nRecord a different one. A hotstring key works in every"
                 . " window, so sharing it would mean both fire and whichever"
                 . " script loaded last wins.", "Key already used", 0x30)
            LOG_Bail("gui.addhotkey", "refused " HKP_KeyLabel(k)
                                    . " for the new hotstring — already used by "
                                    . owner)
            return
        }
        _recKey := k
        lblRec.Text := HKP_KeyLabel(k)
        LOGI("gui.addhotkey", "recorded " HKP_KeyLabel(k) " for the hotstring being"
                            . " written — nothing is bound until Append")
    }

    ClearKey(*) {
        _recKey := ""
        lblRec.Text := "(none — optional)"
    }

    ; Hand the box to the capture window. Nothing else here is read: the trigger,
    ; the target file and the send-function radios are all about a hotstring, and
    ; a follow-up has none of them.
    ToFollowUp(*) {
        if (Trim(edLines.Value) = "") {
            MsgBox("The Lines box is empty — there is nothing to put in a"
                 . " follow-up.", "Replace follow-up", 0x30)
            return
        }
        LOGI("gui.addhotkey", "handing " StrLen(edLines.Value) " chars to the"
                            . " capture window — this text is going into a mass,"
                            . " not into a hotstring")
        OpenAddAltFu(edLines.Value)
    }

    ; Called by NewAccScript with the path it just wrote.
    AddCreated(path) {
        SplitPath path, &fname
        fileList.Push(fname)
        filePaths.Push(path)
        ddl.Delete()
        ddl.Add(fileList)
        ddl.Value := fileList.Length
    }

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

        ; ── the recorded key, re-checked at the last moment ───────────────────
        ; Two things can have changed since you pressed Record: another window
        ; may have taken that key, and the TRIGGER may have been retyped — and
        ; the trigger is what the binding is written against, so it decides which
        ; id this is. Both are cheap to ask again and neither is recoverable if
        ; wrong: a duplicate binding is two things on one key, and a binding
        ; against the wrong trigger is a key that does nothing.
        bindKey := ""
        if (_recKey != "") {
            if RegExMatch(hk, "^[\^!+#]") {
                ; The Hotkey box holds a bare hotkey, so there is no trigger to
                ; bind to — the thing being written IS a key already.
                MsgBox("'" hk "' is itself a hotkey, so there is no hotstring for"
                     . " the recorded key to belong to.`n`nClear the recorded key,"
                     . " or write this as a hotstring trigger instead.",
                       "Add Hotkey", 0x30)
                return
            }
            if InStr(hk, "=") {
                MsgBox("'" hk "' has an '=' in it, and that is what separates a"
                     . " setting from its value in hotkeys.ini — so this trigger"
                     . " cannot have a key.`n`nClear the recorded key, or rename"
                     . " the trigger.", "Add Hotkey", 0x30)
                return
            }
            owner := HK_KeyOwner(_recKey, HK_HotstringId(hk))
            if (owner != "") {
                MsgBox(HKP_KeyLabel(_recKey) " has been taken by " owner
                     . " since you recorded it.`n`nRecord a different key, or"
                     . " clear it.", "Key already used", 0x30)
                LOG_Bail("gui.addhotkey", "refused to write " HKP_KeyLabel(_recKey)
                                        . " for " hk " — taken by " owner)
                return
            }
            bindKey := _recKey
        }
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
        ; The binding goes in AFTER the block is safely on disk, so a failed write
        ; cannot leave a key bound to a hotstring that does not exist. It needs no
        ; broadcast: the script is restarted below either way, and reading its
        ; keys is part of loading.
        if (bindKey != "") {
            try IniWrite(bindKey, HK_INI, "hotstring", hk)
            LOG_Ok("gui.addhotkey", hk " is bound to " HKP_KeyLabel(bindKey)
                                 . " ([hotstring] in hotkeys.ini)")
        }

        CheckCollisions()
        ah.Destroy()
        LOG_Ok("gui.addhotkey", "appended the new hotstring to " path
                             . " — restarting that script so it takes effect")
        ; TOCTOU, same as WipeTemp: a throw here would skip the Run below, so the
        ; hotstring would be in the file and the script would not be running it.
        if WinExist(path " ahk_class AutoHotkey") {
            try {
                pid := WinGetPID(path " ahk_class AutoHotkey")
                ProcessClose pid
            }
        }
        Run path
    }
}

; Create an empty message script in content\accounts\.
;
;   ownerHwnd — the window this dialog is modal-ish to. Defaults to the main
;               window; the Add Hotkey button passes its own so the New Script
;               dialog cannot end up behind it.
;   onCreated — optional callback, called with the new file's full path once it is
;               on disk. That is how Add Hotkey adds the file to its dropdown
;               without a reload.
NewAccScript(ownerHwnd := 0, onCreated := 0) {
    global ACC_DIR, g
    ns := Gui("+Owner" (ownerHwnd ? ownerHwnd : g.Hwnd), "New Script")
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
        ; Guarded: FileOpen returns "" on failure and `.Write` on that threw "no
        ; method named Write" — an error dialog naming a method, for what is really
        ; "content\accounts\ is not writable". The Destroy and the reload prompt
        ; below never ran either, so the window just sat there.
        try {
            f := FileOpen(path, "w", "UTF-8")
            if !f
                throw Error("could not open the file for writing")
            f.Write(content)
            f.Close()
        } catch as e {
            LOGE("gui.newacc", "could not create " name ".ahk", LOG_Err(e) "   " path)
            MsgBox("Could not create " name ".ahk:`n`n" e.Message "`n`n" path,
                   "New script", 0x10)
            return
        }
        LOG_Ok("gui.newacc", "created " path)
        ns.Destroy()
        ; No "reload to show the toggle button?" prompt any more — there is no
        ; toggle button. The caller wires the file into whatever list it owns.
        if onCreated
            onCreated(path)
        else
            MsgBox("Created " name ".ahk", "Done", 0x40)
    }
}

; ── How to Use ────────────────────────────────────────────────────────────────
;  Opens docs\guide.html in the default browser.
;
;  This used to dump docs\mass-format.md into a read-only Edit control, which was
;  the worst of both worlds: no formatting, no links, no search beyond Ctrl+F in a
;  textbox that did not wrap, and a 600x480 window you could not usefully resize.
;  The content had also gone stale in a way nobody noticed for exactly that reason
;  — it still told you to open "1_mass and 2_mass" and set your hotkeys there, and
;  neither of those files has existed since the v2 tree.
;
;  A browser gives navigation, real tables, search, zoom, printing and a back
;  button for free. The guide is one self-contained HTML file with its CSS inline,
;  so there is nothing to install and nothing to load from the network.
;
;  Run(), not ShellRun: a bare Run on an .html goes through the file association,
;  which is a browser on every machine this will ever run on. If it somehow is not,
;  the catch falls back to revealing the file in Explorer so the user can still get
;  at it — better than a dialog saying it could not open.
OpenGuide(*) {
    guide := MMA_ROOT "\docs\guide.html"
    LOGD("gui.guide", "How to Use clicked")
    if !FileExist(guide) {
        LOGE("gui.guide", "the guide is missing — cannot show it", guide)
        MsgBox("The guide is missing:`n`n" guide
             . "`n`nIt ships in docs\. Re-run an update to restore it.",
               "How to Use", 0x30)
        return
    }
    try {
        Run(guide)
        LOG_Ok("gui.guide", "opened " guide " in the default browser")
    } catch as e {
        LOGW("gui.guide", "could not open the guide in a browser (" LOG_Err(e)
                        . ") — revealing it in Explorer instead")
        try Run('explorer.exe /select,"' guide '"')
    }
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
    LOGD("gui.wipetemp", "wiping " path " back to its headers")
    ; TEMP.ahk is the scratch target for Add Hotkey, so this is a deliberate
    ; destructive write — but it must still either work or say so. Unguarded, a
    ; failed FileOpen threw before the restart below, leaving TEMP.ahk running the
    ; OLD content while the button reported nothing at all.
    try {
        f := FileOpen(path, "w", "UTF-8")
        if !f
            throw Error("could not open the file for writing")
        f.Write(headers)
        f.Close()
    } catch as e {
        LOGE("gui.wipetemp", "could not wipe TEMP.ahk — it still holds its old"
                           . " hotstrings", LOG_Err(e) "   " path)
        MsgBox("Could not wipe TEMP.ahk:`n`n" e.Message, "Wipe Temp", 0x10)
        return
    }
    if WinExist(path " ahk_class AutoHotkey") {
        ; TOCTOU: the script can exit between WinExist and WinGetPID, and then
        ; WinGetPID throws "Target window not found".
        try {
            pid := WinGetPID(path " ahk_class AutoHotkey")
            ProcessClose pid
        }
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

; The branch builder is its own process, like the archive viewer is not — it
; carries a WebView2 and a whole document model, and starting it in here would
; put Edge inside the window that must never be slow to open. Raised rather than
; relaunched when it is already up, so a second press does not throw away the
; canvas you were looking at.
OpenBranchBuilder(*) {
    win := MMA_SRC "\ui\branch_window.ahk"
    if !FileExist(win) {
        LOGE("gui.branch", "branch_window.ahk is missing — the branch builder"
                         . " cannot open", win)
        return
    }
    if WinExist("MMA Branch builder ahk_class AutoHotkeyGUI") {
        WinActivate("MMA Branch builder ahk_class AutoHotkeyGUI")
        return
    }
    LOGI("gui.branch", "opening the branch builder")
    LOG_Try("gui.branch", "Run branch_window.ahk", () => Run(win))
}

; ─── Hotkeys ──────────────────────────────────────────────────────────────────
; Keys live in hotkeys.ini under [gui]. "mouseControl" is this script's own
; context, so gui.toggleDoubleMM only fires while Mouse control is on.
HK_Context("mouseControl", (*) => mouseControl)

HK_Bind("gui.addHotkeyGrab",  AddHotkeyGrab)
HK_Bind("gui.ocrGrab",        OcrGrab)
HK_Bind("gui.branchBuilder",  OpenBranchBuilder)
HK_Bind("gui.toggleDoubleMM", ToggleDoubleMM)

