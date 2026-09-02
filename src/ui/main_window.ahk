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
; Triggers that RUN an action instead of typing a message. Registered from this
; process because it is the one that is always up, and because actions_menu.ahk
; is here — the two are the same idea reached two ways, and only one of them can
; be reached without taking your hands off the chat box.
#Include "../hotstrings/shortcuts.ahk"
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
CORE_BootEarly()

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
; The wait time, from the cfg like every other setting. This used to READ A
; SOURCE FILE: utils.ahk was slurped whole and a regex pulled the literal back
; out of it, because that literal was where the number lived. Renaming that one
; line therefore broke this window, the WebView settings page and the save path,
; in three files that had no other reason to know utils.ahk's text.
waitTime          := LOG_IniInt(CFG_FILE, "Settings", "WaitTime", 1500)
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
; The Python automation listener (src\services\automation\automation.py) runs the
; [automation] hotkeys. On by default: those keys are declared in hotkeys.ahk and
; shown in the Hotkeys GUI, so if the listener isn't up they'd look bound but do
; nothing. Declared as a service in core\processes.ahk; started by SVC_Launch.
automationListener := LOG_IniInt(CFG_FILE, "Settings", "AutomationListener", 1)
; The pinger (src\services\pinger\pinger.pyw) beeps when an Infloww fan tab goes
; unread. Off by default — it makes noise, so it should be an opt-in. Declared as
; a service in core\processes.ahk.
pinger            := LOG_IniInt(CFG_FILE, "Settings", "Pinger", 0)
; The model detector (model_detector.ahk) reads the active Infloww tab's name and
; writes it to detector_status.ini, so one set of f1/f2/f3 keys serves whichever
; model is on screen. Off by default. Declared as a service in core\processes.ahk.
autoDetect        := LOG_IniInt(CFG_FILE, "Settings", "AutoDetectModel", 0)
; The stats overlay (stats_overlay.ahk) OCRs the Infloww stats page and shows a
; toggleable overlay of Sales + the PPVs-sent/Fans-chatted ratio. Declared as a
; service in core\processes.ahk.
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
; twin in ui\webview_main_window.ahk allocates with.
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
c.OnEvent("Click", (*) => CORE_OpenSettingsPreferred())
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

; The typing chart. It had no door but a hotkey nobody had pressed — see
; CORE_OpenActivity. Hidden with its feature, like Hotstrings and Variants.
c := g.Add("Button", "x" TAB_X " y" TOGG_Y0 " w95 h28", "Activity")
c.OnEvent("Click", (*) => CORE_OpenActivity())
FeatCtrl(c, "activity")
RegTog(c, 95, 0)

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
; this file, via CORE_BootEarly() — both own hotkeys, and waiting for the whole GUI
; to be built left those keys dead for the first few hundred ms of every launch.
;
; The rest can only run here: it needs the settings this file has now finished
; reading. It is shared with the WebView shell, which started none of it — see
; CORE_BootServices in ui\main_core.ahk.
CORE_BootServices()
CORE_BootWindowTasks()

; The lock is set from three places in two processes — this button, the engine's
; lock key, and the picker's checkbox — so the button reads the cfg rather than
; remembering what it last did. One ini read every 1.2s, and it is what keeps this
; window from claiming "Lock to Rama" while a lock put on from a keypress is
; already live.
;
; Stays here rather than in CORE_BootServices: it is a BUTTON's caption, and the
; WebView shell has no such button to refresh.
RefreshLockButton()
SetTimer(RefreshLockButton, 1200)

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

; ─── Parse, import and the model-name repository ──────────────────────────────
;  These used to be written out here. They are in ui\main_core.ahk now, shared
;  with the WebView shell, which had grown its own drifting copies of them — see
;  that file's header.
;
;  Included HERE rather than at the top of the file because the block is not only
;  functions: it registers OnMessage(MMA_MSG_AUTOPARSE), OnMessage(MMA_MSG_ADD_HOTKEY)
;  and OnClipboardChange at its top level, and this is the point in the startup
;  order at which those should start answering.
#Include "main_core.ahk"

; ─── Hotstring shortcuts ──────────────────────────────────────────────────────
;  userdata\shortcuts.ini, turned into live triggers — see hotstrings\shortcuts.ahk.
;
;  LAST, and after the whole registry is declared, because every line in that file
;  is checked against HK_META as it is registered: a shortcut naming an action
;  that does not exist is refused with the id in the log, and it can only be
;  refused correctly once every HK_Def has run.
SHORTCUTS_Start()

; ─── Parse / clear the paste box ──────────────────────────────────────────────

; ─── Load / save the mass library ─────────────────────────────────────────────
; These used to read and WRITE AHK SOURCE: LoadFile regex-matched `mN := { … }`
; blocks out of a model script, and ApplyFile spliced new ones back in via
; BuildBlock/BuildMassTemplate/EscQ. All of that is gone — the library is data
; now, and mass/store.ahk is the only thing that touches the file.
;
; The fname argument survives because every caller passes one (the model tabs,
; the branch window, the Discord import). It is turned into a model NUMBER here
; and used for nothing else.

; ─── Which mass a model sends ─────────────────────────────────────────────────
; Was a `massNo := 1` line rewritten inside a RUNNING script's source, which then
; had to be relaunched to take effect. It is state, so it lives with the data.

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

; ─── Arm the shared behaviour ─────────────────────────────────────────────────
;  Everything below this point used to be written out here: the Hotstrings
;  launcher, the updater, the Add-hotkey dialog, the acc-script builder, the FU
;  toggles, WipeTemp, CheckCollisions and the [gui] hotkey binds. It is all in
;  ui\main_core.ahk now, shared with the WebView shell — which had none of it,
;  and so had no OCR grab, no branch-builder key and no Add-hotkey dialog.
;
;  The call is LAST for the reason the binds were last: it registers this
;  process's [gui] hotkeys, and mouseControl has to be read before the context
;  that reads it goes live.
CORE_Arm()
