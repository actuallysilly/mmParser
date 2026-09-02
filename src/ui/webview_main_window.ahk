#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  webview_main_window.ahk — MMA's main window, drawn by Edge instead of by Win32.
; ───────────────────────────────────────────────────────────────────────────────
;  THE DEFAULT front end. MMA.ahk starts this one unless Settings ▸ GUI ▸ Main
;  window says "Classic (Win32)", and ui\main_window.ahk is the supported
;  fallback for a machine where WebView2 will not start.
;
;  It was a prototype in tools\ until it grew the four things a default has to
;  do — see the history note at the bottom of this block.
;
;  ─── WHAT IS ACTUALLY DIFFERENT ──────────────────────────────────────────────
;  Only the drawing. The window owns the same fourteen fields per model, the same
;  paste box, the same Load/Save/Parse/Clear/Export, the same bottom strip. What
;  used to be sixty Win32 controls laid out by ApplyLayout on every WM_SIZE is one
;  WebView2 filling the client area, and CSS does the reflow.
;
;  Everything that is NOT drawing is in ui\main_core.ahk, shared with the Win32
;  shell — the parser path, the model-name repository, the updater, the Add-hotkey
;  dialog, the [gui] hotkeys and the boot sequence. Neither shell owns a private
;  copy of any of it. See that file's header for what that cost to untangle.
;
;  ─── WHY THE CONTROLS STILL EXIST IN AHK ─────────────────────────────────────
;  parser.ahk writes into `edCtrls[...].Value`. So do archive.ahk's ExportMMA and
;  its "Load" button, and alt_fu_window.ahk's whole save path. None of them know
;  or care what a control is — they need a Map of things with a `.Value`.
;
;  So that is what they get: WvCell, an object with a `.Value` and a `.Text`
;  whose setter marks the page dirty. Every one of those files keeps working
;  untouched, and there is exactly ONE copy of the truth — AHK's — with the page
;  as a view onto it. Making the page authoritative would have meant a second
;  copy and a class of bug where Parse fills boxes nobody can see.
;
;  ─── HOW THE TWO HALVES TALK ────────────────────────────────────────────────
;  page → AHK   window.chrome.webview.postMessage({cmd: …})  → WV_OnMessage
;  AHK  → page  window.mma.sync({whole state})               → WV_Sync
;
;  Full state every time, not deltas. It is a few KB of JSON for a window this
;  size, and a delta protocol is a second source of truth wearing a hat — the
;  first thing to drift is exactly the thing that matters here (which model's
;  text is in the boxes).
;
;  ─── WHAT CHANGED WHEN IT STOPPED BEING A PROTOTYPE ─────────────────────────
;  It used to start nothing and bind nothing, on purpose: it was built to run
;  BESIDE the real MMA, and a second process claiming global single-instance keys
;  would have taken them off the window it was being compared against.
;
;  A default cannot do that. It now calls CORE_BootEarly() before Edge starts,
;  CORE_BootServices() at the end, and CORE_Arm() for the messages and keys — so
;  the engine, the sequence watcher, the startup scripts and the services all
;  come up, and the Discord import and the Hotstrings window's "Add hotkey"
;  button reach a window that is listening. Run it alongside the Win32 shell now
;  and both will answer; that is the price of it being real.
; ═══════════════════════════════════════════════════════════════════════════════

#SingleInstance Force

#Include "..\core\paths.ahk"
#Include "..\core\theme.ahk"
#Include "..\core\crashlog.ahk"
#Include "..\core\hotkeys.ahk"
#Include "..\mass\store.ahk"
#Include "..\core\active_model.ahk"
#Include "..\mass\archive.ahk"
#Include "..\mass\parser.ahk"
#Include "..\core\processes.ahk"
#Include "settings_window.ahk"
#Include "..\screen\ocr_grab.ahk"
; ui\actions_menu.ahk is NOT included, and that is the whole reason this list
; differs from main_window.ahk's. It HK_Binds gui.actions and gui.quickActions at
; its top level, so including it would register those keys a second time and the
; real MMA would open two menus on one press — while running both is exactly how
; you compare them. Nothing else here calls into it.
#Include "tools_window.ahk"
#Include "alt_fu_window.ahk"
; Only for CREDIT_On() and CRED_FindFile() — which file the corner picture comes
; from, honouring Settings ▸ GUI ▸ Corner picture. None of the GDI+ half of that
; file is used: the page shows her with an <img>, so the frame decoding, the rung
; ladder and the animation timer are all Edge's problem now. Settings ▸ GUI also
; calls CREDIT_AssetList() to fill its dropdown, so this include is not optional.
#Include "credit.ahk"
#Include "..\vendor\json.ahk"
; thqby's WebView2 wrapper. It finds WebView2Loader.dll beside itself (64bit\ or
; 32bit\ to match the interpreter) and the Edge runtime from its install root, so
; there is nothing to configure — see CreateEnvironmentAsync in that file.
#Include "..\vendor\WebView2\WebView2.ahk"

DetectHiddenWindows true

; ─── The two children that own hotkeys, started FIRST ─────────────────────────
;  The mass engine (every mass hotkey) and sequences.ahk (the Discord Ctrl+click
;  import and the other seq.* keys). Neither is optional and neither is a startup
;  script.
;
;  The prototype started NEITHER, which is most of what made it a prototype: it
;  drew the panel while the real MMA behind it owned every key. This shell is the
;  one MMA starts now, so it has to bring them up itself.
;
;  Up here, before Edge, and that matters more in this shell than in the Win32
;  one: CreateControllerAsync below waits on the WebView2 runtime starting, which
;  is far slower than laying out sixty controls. Every one of those milliseconds
;  would be MMA on screen with its hotkeys dead.
CORE_BootEarly()

; ─── A control that is not a control ──────────────────────────────────────────
;  One box on screen, from the point of view of every file that writes into it.
;  `Value` is the text; `Text` is the same thing under the name the button and
;  label code uses (RefreshToolsLabel says `btnTools.Text := …`).
;
;  The setter marks the page dirty rather than pushing straight away. A single
;  FillTabFromSlot writes forty-odd of these in a row, and forty round trips
;  through ExecuteScript to draw one tab is the kind of thing that makes a
;  WebView feel slower than the Win32 window it replaced. WV_Touch coalesces
;  them into one sync on the next tick.
class WvCell {
    __New(startValue := "") {
        this._v := startValue
    }
    Value {
        get => this._v
        set {
            this._v := value
            WV_Touch()
        }
    }
    ; Buttons and labels are written through `.Text`. Same storage — a button's
    ; caption and an edit box's contents are both "the string this thing shows".
    Text {
        get => this._v
        set => this.Value := value
    }
}

; ─── Data ─────────────────────────────────────────────────────────────────────
;  fieldDefs and keyMap are copied from main_window.ahk rather than shared,
;  because they live at the top level of that file and it cannot be #Included
;  (it builds a whole GUI on load). The page carries the same list in FIELDS —
;  three copies of fourteen rows is the price of this being a prototype, and it
;  is what a real port would collapse into one table in mass\store.ahk.

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

; parser.ahk reads this global by name. Keyword → field.
keyMap := Map(
    "!mm",    "mass",    "!mma",   "mass",    "mm",     "mass",    "mma",    "mass",
    "f1",     "fu1",     "f1.5",   "fu1_5",   "f1.7",   "fu1_7",
    "f2",     "fu2",     "f2.5",   "fu2_5",   "f2.7",   "fu2_7",
    "f3",     "fu3",     "f3.5",   "fu3_5",   "f3.7",   "fu3_7",
    "ppv",    "ppv_base",
    "ppvfu1", "ppv_f1",  "ppvfu2", "ppv_f2",  "ppvfu3", "ppv_f3"
)

; Characters parser.ahk's EscQ has to escape. Backtick FIRST — escape it after
; the others and you escape the escapes you just added.
AHK_CHARS := ["``", Chr(34), ";"]

; A leading "word:" is normally stripped as a field prefix (StripPrefix in
; parser.ahk). URL schemes must be exempt or "https://x" is mangled into "//x".
PREFIX_EXCEPTIONS := Map("http",1, "https",1, "ftp",1, "ftps",1, "mailto",1,
                         "tel",1, "file",1)

SCRIPT_DIR := MMA_ROOT
ACC_DIR    := MMA_ACC_DIR
CFG_FILE   := MMA_CFG
APP_VER    := FileExist(MMA_VERSION) ? Trim(FileRead(MMA_VERSION, "UTF-8")) : "?"
UPDATE_URL := IniRead(CFG_FILE, "Update", "URL",
                      "https://raw.githubusercontent.com/actuallysilly/mmParser/main")

modelCount := LOG_IniInt(CFG_FILE, "Settings", "ModelCount", 2)
modelNames := []
Loop MASS_MODELS
    modelNames.Push(IniRead(CFG_FILE, "Settings", "Model" A_Index, "Model " A_Index))
; settings_window.ahk and the archive still read these three by name.
model1Name := modelNames[1]
model2Name := modelNames[2]
model3Name := modelNames[3]

walletCheckFu3 := LOG_IniInt(CFG_FILE, "Settings", "WalletCheckFu3", 0)
mouseControl   := LOG_IniInt(CFG_FILE, "Settings", "MouseControl", 1)
_doubleMM      := false

; ── what the Settings window reads out of the main window ────────────────────
;  Not this window's business, any of it — these are the values Settings shows on
;  its own tabs, and it reads them from the globals main_window.ahk happens to
;  have loaded. Reproduced here with the same defaults, because Settings is the
;  unchanged old window and it must find what it expects. A real port would have
;  it read the cfg for itself.
_codePath         := EnvGet("LOCALAPPDATA") "\Programs\Microsoft VS Code\Code.exe"
CODE_CMD          := FileExist(_codePath) ? _codePath
                                          : "C:\Program Files\Microsoft VS Code\Code.exe"
waitTime          := LOG_IniInt(CFG_FILE, "Settings", "WaitTime", 1500)
defaultHotkeyFile := IniRead(CFG_FILE, "Settings", "DefaultHotkeyFile", "TEMP.ahk")
openTabFu2        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabFu2", 0)
openTabFu3        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabFu3", 0)
openTabPpv        := LOG_IniInt(CFG_FILE, "Settings", "OpenTabPpv", 0)
fastParseAutosave := LOG_IniInt(CFG_FILE, "Settings", "FastParseAutosave", 0)
autoRestart       := LOG_IniInt(CFG_FILE, "Settings", "AutoRestart", 0)
pinger            := LOG_IniInt(CFG_FILE, "Settings", "Pinger", 0)
statsOverlay      := LOG_IniInt(CFG_FILE, "Settings", "StatsOverlay", 0)
startupScripts    := []
for _s in StrSplit(IniRead(CFG_FILE, "Settings", "StartupScripts", "general.ahk"), ",")
    if (Trim(_s) != "")
        startupScripts.Push(Trim(_s))

; ─── Start the rest of MMA, BEFORE Edge ──────────────────────────────────────
;  Startup scripts (general.ahk and the account files), the automation listener
;  and whichever background services are switched on.
;
;  Here, and not at the end of the file where it used to sit, because the next
;  thing this shell does is CreateControllerAsync — which blocks until the Edge
;  runtime is up. Measured at 60.8 seconds from launch to general.ahk starting
;  when this ran last, and general.ahk is every hotstring MMA has. A minute of
;  typing that does nothing, once per launch, is not a cosmetic difference.
;
;  Everything above this line is settings being read, which is all these need.
CORE_BootServices()

; ─── The shim controls ────────────────────────────────────────────────────────

edCtrls      := Map()      ; "m<model>_<field>" → WvCell, exactly as the GUI keys them
edPaste      := WvCell()
lblLoaded    := WvCell("")
btnLoadOne   := WvCell("Load")
btnSaveOne   := WvCell("Save")
btnTools     := WvCell("Tools")
varBaseEcho  := Map()      ; the Variants window's read-only trunk echo
massNoCurrent := []        ; the slot each model's boxes are SHOWING
massNoRadios  := []        ; [model][slot] → WvCell holding 1/0
fuChks        := []        ; [model][f]    → per-model "single"
editFuChks    := []        ; [f][model]    → the global "editable", mirrored

Loop modelCount {
    _m := A_Index
    for _, _fd in fieldDefs
        edCtrls["m" _m "_" _fd[1]] := WvCell()
    ; The branch fields never appear on the main panel — they are the Variants
    ; window's — but they must exist here, because parser.ahk clears and fills
    ; them by key on every parse and ExportMMA reads them back.
    Loop MASS_BRANCH_MAX
        for _, _bf in MASS_BranchFields(A_Index)
            edCtrls["m" _m "_" _bf] := WvCell()
    edCtrls["m" _m "_altGui"] := WvCell()

    massNoCurrent.Push(1)
    massNoRadios.Push([])
    Loop MASS_SLOTS
        massNoRadios[_m].Push(WvCell(A_Index = 1 ? 1 : 0))

    fuChks.Push([])
    Loop 3
        fuChks[_m].Push(WvCell(IniRead(CFG_FILE, "Settings",
                                       "FuSingle_" _m "_" A_Index, "0") = "1" ? 1 : 0))
}
Loop 3 {
    _f := A_Index
    editFuChks.Push([])
    Loop modelCount
        editFuChks[_f].Push(WvCell(IniRead(CFG_FILE, "Settings",
                                           "EditableFu" _f, "0") = "1" ? 1 : 0))
}

; The tab. One property, and it is the answer to "which model am I typing into" —
; every Load, Save, Parse and Export in this file reads it.
tabs := WvCell(1)

; ─── The window ───────────────────────────────────────────────────────────────

; ── these four are set BEFORE the window exists, on purpose ──────────────────
;  Top-level statements run in order and function bodies are skipped, so an
;  initialiser further down the file has NOT RUN when something up here calls
;  into a function that reads it. Two of them are reached that way:
;
;    wvc   g.Show() fires Size, and WV_OnSize reads it. Measured: assigned after
;          the Show, the very first resize of the session threw "this global
;          variable has not been assigned a value" before the WebView existed.
;    WV_Ready  the pre-fill below fills every model's tab, and each field write
;          fires WV_Touch → WV_Sync, which asks whether the page is up yet.
;
;  The other two are here to keep the four together rather than because they are
;  known to be read early. (The detector hit this same shape and threw on its
;  first poll — see the note in main_window.ahk beside _askedNames.)
WV_Ready := false
WV_CreditHost := ""   ; the folder mma.credit currently points at, if any
wvc := 0              ; the controller — owns the bounds
wv  := 0              ; the core — owns the page
wvMsgTok := 0         ; the WebMessageReceived registration token

g := Gui("+Resize +MinSize900x640", "MMA v" APP_VER " — WebView")
; No margins and no controls: the WebView is the client area. The background
; still gets the theme colour, because it is what shows for the few hundred ms
; between Show() and Edge's first paint, and a white flash on a dark theme is
; the most visible thing this window does.
g.MarginX := 0
g.MarginY := 0
_bg := THEME_WindowBg()
g.BackColor := (_bg = "") ? "Default" : _bg
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", THEME_Set().dark ? 1 : 0, "int", 4)

g.OnEvent("Size", WV_OnSize)
; Not `(*) => ExitApp()`, which is what a prototype could afford. This window
; STARTS the engine, the sequence watcher, the account scripts and the Python
; services now, so exiting without asking about them orphans all of it: no window
; left to stop them from, typelog still recording and the automation listener
; still holding its hotkeys. OnGuiClose asks the Yes/No/Cancel that the Win32
; shell has always asked, and KillAllScripts is the half that stops the services —
; they are not AHK windows, so nothing else finds them. Both in core/processes.ahk.
g.OnEvent("Close", OnGuiClose)
g.Show("w1500 h700")

; tray: one-click clean shutdown (right-click tray, or double-click the icon),
; the same entry and the same default item as the Win32 shell.
try {
    A_TrayMenu.Insert("1&", "Kill all scripts && Exit", (*) => KillAllAndExit())
    A_TrayMenu.Insert("2&")
    A_TrayMenu.Default := "Kill all scripts && Exit"
}

; ─── Arm the shared behaviour ─────────────────────────────────────────────────
;  The auto-parse and add-hotkey messages, the webgui clipboard watcher, and the
;  [gui] hotkeys — OCR grab, Add-hotkey grab, the branch builder and double-MM.
;
;  The prototype bound NONE of this, deliberately: it was built to run beside the
;  real MMA, and a second process claiming the same global keys would have taken
;  them off the window it was being compared against. That trade is over — this
;  shell is the one MMA starts, so it owns the keys.
;
;  ABOVE the WebView block, not after it, for the same reason the services moved:
;  CreateControllerAsync blocks for as long as Edge takes to start, and keys armed
;  after it are keys that do nothing for that whole minute. `g` already exists, so
;  the clipboard handler has the window it activates; the page does not, and does
;  not need to — a sync before it is ready is dropped and re-sent on ready.
CORE_Arm()

; ─── The WebView ──────────────────────────────────────────────────────────────

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nThis needs the Microsoft Edge WebView2 Runtime, which ships with"
         . " Windows 11. Install it from Microsoft if this machine has had it"
         . " removed.", "MMA — WebView", 0x10)
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false
; Right-click stays on: it is how you cut, copy and paste in the boxes, which is
; most of what this window is for.

; ── add_, NOT the wrapper's `wv.WebMessageReceived(fn)` shorthand ────────────
;  That shorthand returns a small object whose whole job is to UNREGISTER the
;  handler when it is destructed:
;
;      { ptr: this.ptr, __Delete: this.remove_WebMessageReceived.Bind(, token) }
;
;  Its `ptr` is a raw copy of the CoreWebView2 pointer taken WITHOUT an AddRef.
;  So whether that __Delete is safe depends entirely on whether the core is still
;  alive when AHK gets round to collecting the object — and on shutdown it is
;  not. Measured: "Invalid memory read/write in ComCall (WebView2.ahk:676)",
;  which is the remove_ line, with nothing in the message to say what asked for
;  it.
;
;  This window registers ONE handler and wants it for as long as it exists, so
;  there is nothing for that object to do except eventually crash. add_ returns a
;  plain token instead. The handler itself stays alive on WebView2's own
;  reference — WebView2.Handler maps COM AddRef/Release onto ObjAddRef/ObjRelease
;  — so there is nothing here to keep either.
wvMsgTok := wv.add_WebMessageReceived(WV_OnMessage)

; ─── Serving the page ─────────────────────────────────────────────────────────
;  The repo root is mapped to a virtual host rather than the page being loaded
;  over file://. Two reasons, and the first is the one that matters: file://
;  pages are treated as opaque origins by Edge, so `postMessage` from one is a
;  fight with the security model. The second is that it makes assets\ reachable
;  by an ordinary relative URL, which is how the credit picture gets on screen
;  with no GDI+ and no rung ladder.
;
;  ALLOW, not DENY_CORS: same-origin fetches from the page only, which is all
;  there is here.
wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/main_window.html")

; ── fill every model's tab from its live slot, now ────────────────────────────
;  Before the page has said "ready", deliberately. The first sync then carries
;  real text, and the window has never been on screen empty — the AHK original
;  does the same thing for the same reason, and it also stops the unsaved-changes
;  check firing on the first click of the session (empty boxes against a stored
;  mass IS a difference).
try {
    _startDoc := MASS_Load()
    Loop modelCount
        FillTabFromSlot(A_Index, WV_SafeSlot(MASS_MassNo(_startDoc, A_Index)), _startDoc)
    LOGI("wv.load", "opened with all " modelCount " model tab(s) filled from their"
                  . " live mass slots")
} catch as e
    LOGE("wv.load", "could not pre-fill the model tabs — they will be blank until"
                  . " you press load", LOG_Err(e))
RefreshModelHeader()
SetTimer(RefreshToolsLabel, -800)

; ─── The app behind the window ────────────────────────────────────────────────
;  Parse-on-import, the model-name repository and the save-target prompt. Shared
;  with the Win32 shell rather than reimplemented here — this file used to carry
;  its own ModelNameForSlot and nothing else of the block, so the Discord import
;  and the Hotstrings window's "Add hotkey" button reached a window that was not
;  listening. See ui\main_core.ahk.
;
;  Down HERE, after the WebView exists, because the block ARMS things at its top
;  level: OnMessage for the auto-parse and add-hotkey messages, and the clipboard
;  watcher behind the webgui's "Send to MMA". Those answer by filling edPaste and
;  activating `g`, so both must already be built.
;
;  The two globals below are the rest of that block's seam. _mFiles is what
;  ApplyFile and the prompt take as a model identifier; _lastImportModel is how
;  fast-parse remembers where an untagged import went last time.
_mFiles          := MMA_ModelNames()
_lastImportModel := 0
#Include "main_core.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  The bridge
; ═══════════════════════════════════════════════════════════════════════════════

; Mark the page out of date. Coalesced onto a -1 timer so a burst of forty
; setters is one sync — see the note on WvCell.
WV_Touch() {
    SetTimer(WV_Sync, -1)
}

; Push the whole window state to the page.
;
; Everything, every time. See the header for why there is no delta protocol.
WV_Sync() {
    global wv, WV_Ready, edCtrls, edPaste, tabs, modelCount, modelNames
    global massNoRadios, fuChks, editFuChks, btnLoadOne, btnSaveOne, btnTools
    global lblLoaded, APP_VER
    if !WV_Ready
        return

    st := Map()
    f  := Map()
    for k, c in edCtrls
        f[k] := c.Value
    st["fields"] := f
    st["paste"]  := edPaste.Value
    st["tab"]    := tabs.Value
    st["slots"]  := MASS_SLOTS

    names := []
    Loop modelCount
        names.Push(Trim(modelNames[A_Index]) != "" ? modelNames[A_Index] : "Mass " A_Index)
    st["models"] := names

    st["massNo"] := WV_MassNoOf(tabs.Value)

    ; Both toggle rows are read for the MODEL IN FRONT. "single" is per model;
    ; "editable" is global and mirrored across models, so either mirror answers.
    sing := [], edit := []
    Loop 3 {
        sing.Push(WV_ChkVal(fuChks, tabs.Value, A_Index))
        edit.Push(editFuChks[A_Index].Length ? (editFuChks[A_Index][1].Value ? 1 : 0) : 0)
    }
    st["single"] := sing
    st["editFu"] := edit

    st["loadLabel"]  := btnLoadOne.Text
    st["saveLabel"]  := btnSaveOne.Text
    st["toolsLabel"] := btnTools.Text
    st["loaded"]     := lblLoaded.Text
    st["theme"]      := THEME_Name()
    st["title"]      := "MMA v" APP_VER
    st["credit"]     := WV_CreditUrl()

    ; Same gates the AHK window's FeatCtrl/ModeCtrl apply. The BEHAVIOUR behind
    ; each is gated separately — hiding a button is never the only thing stopping
    ; a feature.
    ; `gates`, and NOT `feat` — AHK identifiers are case-insensitive, so a local
    ; called `feat` IS the global FEAT, and the first line below then calls a Map.
    ; It fails as "this value of type Map has no method named Call", which names
    ; neither the variable nor the function it ate.
    gates := Map()
    gates["archive"]    := FEAT("archive")      ? 1 : 0
    gates["hotstrings"] := FEAT("hotstrings")   ? 1 : 0
    gates["variants"]   := FEAT("altFollowups") ? 1 : 0
    gates["tools"]      := MODE_IsEasy()        ? 0 : 1
    gates["activity"]   := FEAT("activity")     ? 1 : 0
    st["feat"] := gates

    try wv.ExecuteScriptAsync("window.mma.sync(" JSON.Stringify(st) ")")
}

; The corner picture, as a URL the page can load — or "" when she is switched off
; or there is no file, in which case the credit is a line of text and nothing else.
;
; The CHOICE is credit.ahk's, not this file's: CREDIT_On() and CRED_FindFile()
; between them honour Settings ▸ GUI ▸ Corner picture, its fallback to any
; assets\decoration\anime_girl*.gif, and the GIF-beats-PNG rule. Answering that question here
; would have been a second opinion that goes stale the first time somebody picks a
; file in Settings.
;
; A picked file may live ANYWHERE — the setting takes an absolute path on purpose
; — and the mma.local mapping only reaches the repo. So anything outside it gets a
; host of its own, mapped once, the first time it is needed.
WV_CreditUrl() {
    global wv, WV_CreditHost
    if !CREDIT_On()
        return ""
    path := CRED_FindFile()
    if (path = "" || !FileExist(path))
        return ""
    root := MMA_ROOT "\"
    if (SubStr(path, 1, StrLen(root)) = root)
        return "https://mma.local/" WV_UrlPath(SubStr(path, StrLen(root) + 1))
    SplitPath path, &fname, &fdir
    if (WV_CreditHost != fdir) {
        try {
            wv.SetVirtualHostNameToFolderMapping("mma.credit", fdir, 1)
            WV_CreditHost := fdir
        } catch as e {
            LOGE("wv.credit", "could not serve the picture from outside the repo",
                 LOG_Err(e) "   " fdir)
            return ""
        }
    }
    return "https://mma.credit/" WV_UrlPath(fname)
}

; A Windows relative path as a URL path. Backslashes turn round and spaces are
; escaped — "anime girl.gif" is a perfectly ordinary file name and an <img src>
; with a raw space in it does not load.
WV_UrlPath(rel) {
    out := ""
    for _, seg in StrSplit(StrReplace(rel, "\", "/"), "/")
        out .= (out = "" ? "" : "/") WV_UrlSeg(seg)
    return out
}

WV_UrlSeg(s) {
    out := ""
    Loop Parse s {
        c := A_LoopField
        ; Unreserved, plus the few that are safe and common in file names. Anything
        ; else is percent-encoded from its UTF-8 bytes, which is what a browser
        ; expects and what an accented name needs.
        if RegExMatch(c, "[A-Za-z0-9\-_.~]")
            out .= c
        else {
            buf := Buffer(StrPut(c, "UTF-8"))
            n   := StrPut(c, buf, "UTF-8") - 1
            Loop n
                out .= Format("%{:02X}", NumGet(buf, A_Index - 1, "UChar"))
        }
    }
    return out
}

WV_ChkVal(arr, m, i) {
    if (m < 1 || m > arr.Length)
        return 0
    return (i >= 1 && i <= arr[m].Length && arr[m][i].Value) ? 1 : 0
}

WV_SafeSlot(n) {
    return (n >= 1 && n <= MASS_SLOTS) ? n : 1
}

; Write a value WITHOUT marking the page dirty.
;
; Only ever for text the page itself just typed. Everything else must go through
; `.Value`, or the change is made and never drawn.
;
; ─── WHY THE `is WvCell` TEST IS NOT DEFENSIVE PADDING ────────────────────────
;  edCtrls holds two kinds of thing. The main panel's fourteen fields are shims;
;  the Variants window's branch cells are REAL Gui Edit controls, because that
;  window is still old AHK (see the bottom of this file). A Gui control has no
;  `_v`, and AHK will happily create one — so the assignment would succeed, the
;  box would keep its old text, and nothing anywhere would say so.
WV_Quiet(cell, v) {
    if (cell is WvCell)
        cell._v := v
    else
        cell.Value := v
}

; ── one message from the page ────────────────────────────────────────────────
;  `set` is handled inline: it is the common case, it happens on every keystroke
;  and it can never put a window up.
;
;  Everything else is QUEUED onto a -1 timer instead of being run here. This
;  function is called from inside a COM event, and half these commands open a
;  modal — the unsaved-changes prompt, "All fields are empty. Save anyway?", the
;  Settings window. A modal pumps messages, so running one inside the callback
;  invites the next web message to arrive while this one is still on the stack.
;  Returning first costs nothing and takes the whole question away.
WV_OnMessage(sender, args) {
    global edCtrls, edPaste
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("wv.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""
    if (cmd = "set") {
        k := m["k"], v := m["v"]
        ; Quietly: the page is already showing this character, so syncing it back
        ; is a round trip that can only fight the caret.
        if (k = "paste")
            WV_Quiet(edPaste, v)
        else if edCtrls.Has(k)
            WV_Quiet(edCtrls[k], v)
        return
    }
    SetTimer(WV_Dispatch.Bind(m), -1)
}

; One queued command.
;
; Every branch ends in a sync, because every one of them can change what the
; window says — even the ones that only open another window, since Settings can
; change the theme and the model names out from under this one.
WV_Dispatch(m) {
    global g, tabs, wv, WV_Ready, modelCount
    cmd := m.Has("cmd") ? m["cmd"] : ""
    try {
        switch cmd {
            case "ready":
                WV_Ready := true
                LOGI("wv.page", "the page is up and asking for its first state")

            case "tab":
                n := Integer(m["n"])
                if (n >= 1 && n <= modelCount) {
                    tabs.Value := n
                    ; Switching tab switches which model Load and Save act on, so
                    ; the labels that name that model move with it.
                    RefreshModelHeader()
                }

            case "massSlot":
                PickMassSlot(tabs.Value, Integer(m["s"]))

            case "single":
                f := Integer(m["f"])
                fuChks[tabs.Value][f].Value := Integer(m["v"])
                ToggleFuCell(tabs.Value, f)

            case "editfu":
                f := Integer(m["f"])
                ; ToggleEditFuCell reads the control it is handed and mirrors the
                ; answer across every model, so it is given one mirror to read.
                editFuChks[f][1].Value := Integer(m["v"])
                ToggleEditFuCell(f, editFuChks[f][1])

            case "parse":       ParseCurrent()
            case "clear":       ClearAll()
            case "export":      ExportMMA()
            case "archive":     OpenArchive()
            case "load":        LoadCurrentTab()
            case "save":        SaveCurrentTab()
            case "settings":    CORE_OpenSettingsPreferred()
            case "hotkeys":     HWV_Open()
            case "activity":    CORE_OpenActivity()
            case "hotstrings":  OpenHotstrings()
            case "tools":       OpenToolsWindow(g.Hwnd)
            case "variants":    OpenVariantsWindow()
            case "devtools":    wv.OpenDevToolsWindow()
            default:
                LOGW("wv.msg", "the page asked for '" cmd "', which is not a command")
        }
    } catch as e {
        ; A failed click must not take the window down with it — without a window
        ; there is no way to fix anything.
        LOGE("wv.cmd", "'" cmd "' threw", LOG_Err(e))
        MsgBox("That did not work:`n`n" e.Message, "MMA", 0x10)
    }
    WV_Sync()
}

; The WebView has no window of its own to resize — it is told its bounds.
WV_OnSize(guiObj, minMax, W, H) {
    global wvc
    if (minMax = -1)          ; minimised: the dimensions are meaningless
        return
    if wvc
        try wvc.Fill()
}

; ═══════════════════════════════════════════════════════════════════════════════
;  What the window does
; ───────────────────────────────────────────────────────────────────────────────
;  Ported from main_window.ahk with the control reads swapped for shim reads.
;  The logic is deliberately unchanged, including the guards and the prompts —
;  the point of the prototype is to find out whether the LOOK can move, and it
;  answers nothing if the behaviour moved too.
; ═══════════════════════════════════════════════════════════════════════════════

; Put the current model's name on Load and Save, so the button you are about to
; press says which model it means. Never throws: a mislabelled button is not
; worth taking the window down for.
RefreshModelHeader(*) {
    global tabs, modelCount, btnLoadOne, btnSaveOne
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

; Settings calls this after a rename. There is no grid of per-model buttons in
; this window, so it is the pair's labels and nothing else.
UpdateModelButtons() {
    global modelNames, CFG_FILE
    Loop modelNames.Length
        modelNames[A_Index] := IniRead(CFG_FILE, "Settings", "Model" A_Index,
                                       "Model " A_Index)
    RefreshModelHeader()
    WV_Touch()
}

; Settings calls this the moment the theme changes. In the AHK window it repaints
; sixty controls; here it is one message, and CSS does the rest.
ApplyWindowTheme() {
    global g
    bg := THEME_WindowBg()
    try g.BackColor := (bg = "") ? "Default" : bg
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
                "int*", THEME_Set().dark ? 1 : 0, "int", 4)
    WV_Touch()
}

; "Something that changes WHERE things go has changed — lay the window out
; again." In the AHK window that is ApplyLayout re-run at the last size it saw;
; Settings calls it after Corner picture is switched or repointed.
;
; Here there is no layout to re-run. CSS already places everything against the
; size the window happens to be, so the only thing a relayout can still mean is
; "the picture may be a different file now" — which is one sync.
RelayoutNow() {
    WV_Touch()
}

; ─── Parse ────────────────────────────────────────────────────────────────────

; ─── Load / save the mass library ─────────────────────────────────────────────

; ─── Which mass a model sends ─────────────────────────────────────────────────

SetMassNoRadio(modelNo, slot) {
    global massNoRadios
    if (modelNo < 1 || modelNo > massNoRadios.Length)
        return
    for i, rb in massNoRadios[modelNo]
        rb.Value := (i = slot) ? 1 : 0
    WV_Touch()
}

; What the page's pill row shows for one model. Reads the same shims
; MassNoForModel does, so the highlight and the save target can never disagree.
WV_MassNoOf(modelNo) {
    return MassNoForModel(modelNo)
}

; ─── The follow-up toggles, the updater, Wipe temp and the rest ───────────────
;  Twelve functions stood here as this file's own copies of main_window.ahk's.
;  They are in ui\main_core.ahk now — see that file's header for why, and for
;  what had already drifted between the two sets.
;
;  The only thing the copies did differently was call WV_Touch() at the end of
;  the two follow-up toggles, because those change an ini key without writing a
;  cell and so leave the page showing a stale tick. That is not lost: the shared
;  versions call CORE_Changed(), and the assignment below is what points it here.
CORE_OnChanged := WV_Touch
; ═══════════════════════════════════════════════════════════════════════════════
;  The Variants window — old AHK, verbatim
; ───────────────────────────────────────────────────────────────────────────────
;  Lifted from main_window.ahk unchanged. It is here rather than #Included
;  because it is built inline in that file, not in one of its own; a real port
;  would move it out first. It is the one subwindow this prototype had to carry,
;  and it is carried as-is on purpose — every other window MMA opens is reached
;  through a function in src\ and needed no copy at all.
; ═══════════════════════════════════════════════════════════════════════════════

VAR_GRID_X   := 14
VAR_NAME_W   := 120
VAR_COL_W    := 194
VAR_COL_GAP  := 8
VAR_ROW_H    := 62
VAR_HEAD_Y   := 74
VAR_MAIN_Y   := 96
VAR_ROWS_Y   := VAR_MAIN_Y + VAR_ROW_H + 10
VAR_W        := VAR_GRID_X * 2 + VAR_NAME_W + 4 * (VAR_COL_W + VAR_COL_GAP) + 16
VAR_H        := VAR_ROWS_Y + MASS_BRANCH_MAX * VAR_ROW_H + 92

gVar := Gui("+Resize +MinSize720x520", "Variants — every way to answer a follow-up")
gVar.BackColor := "15141C"
gVar.SetFont("s9 cE6E4EE", "Segoe UI")
_varLabels := []
Loop modelCount
    _varLabels.Push("M" A_Index)
varTabs := gVar.Add("Tab3", "x10 y10 w" (VAR_W-20) " h" (VAR_H-56), _varLabels)

Loop modelCount {
    _vm := A_Index
    varTabs.UseTab(_vm)

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

    gVar.SetFont("s9 Norm c8E8AA6", "Segoe UI")
    gVar.Add("Text", "x" VAR_GRID_X " y" (VAR_MAIN_Y + 6) " w" VAR_NAME_W, "main")
    gVar.SetFont("s9 Norm cE6E4EE", "Segoe UI")
    _mx := VAR_GRID_X + VAR_NAME_W + VAR_COL_GAP
    for _, _grp in ["fu1", "fu2", "fu3", "ppv"] {
        varBaseEcho[_vm "_" _grp] := gVar.Add("Edit",
            "x" _mx " y" VAR_MAIN_Y " w" VAR_COL_W " h" (VAR_ROW_H - 8)
          . " ReadOnly Multi +VScroll Background1B1A24")
        _mx += VAR_COL_W + VAR_COL_GAP
    }

    Loop MASS_BRANCH_MAX
        VarBuildBranchRow(gVar, _vm, A_Index, VAR_ROWS_Y + (A_Index - 1) * VAR_ROW_H)
}
varTabs.UseTab()

gVar.SetFont("s9 cE6E4EE", "Segoe UI")
_varBtnY := VAR_H - 44
gVar.Add("Button", "x10 y" _varBtnY " w120 h28", "Save to file")
     .OnEvent("Click", (*) => ApplyFile(MMA_ModelNames()[varTabs.Value]))
gVar.Add("Button", "x140 y" _varBtnY " w80 h28", "Close").OnEvent("Click", (*) => gVar.Hide())
gVar.Add("Button", "x230 y" _varBtnY " w120 h28", "Add alt-FU" Chr(0x2026))
     .OnEvent("Click", OpenAddAltFu)
gVar.SetFont("s8 c8E8AA6", "Segoe UI")
gVar.Add("Text", "x360 y" (_varBtnY + 6) " w" (VAR_W - 380),
         "Written in a paste as `::name text` — one marker, whatever the wording is."
       . "  The follow-up key stages them all; TAB moves, Enter sends, Esc cancels.")
ArchiveDarkTheme(gVar, [])
THEME_BoldButtons(gVar)

; ── The Variants window is real AHK, so ITS boxes are real controls ──────────
;  edCtrls therefore holds two kinds of thing: WvCell shims for the main panel's
;  fields, and genuine Gui Edit controls for the branch cells. Nothing cares —
;  both answer `.Value`, which is the entire contract every writer relies on.
VarBuildBranchRow(gv, mNo, k, y) {
    global edCtrls, VAR_NAME_W, VAR_COL_W, VAR_COL_GAP, VAR_GRID_X, VAR_ROW_H
    gv.Add("Text", "x" VAR_GRID_X " y" (y + 4) " w14 c8E8AA6", k)
    ec := gv.Add("Edit", "x" (VAR_GRID_X + 18) " y" y " w" (VAR_NAME_W - 18)
                       . " h22 Background201E2B")
    edCtrls["m" mNo "_br" k "_name"] := ec
    CueBannerFor(ec, "name")

    x := VAR_GRID_X + VAR_NAME_W + VAR_COL_GAP
    for _, grp in ["fu1", "fu2", "fu3", "ppv"] {
        edCtrls["m" mNo "_br" k "_" grp] := gv.Add("Edit",
            "x" x " y" y " w" VAR_COL_W " h" (VAR_ROW_H - 8)
          . " Multi +VScroll Background201E2B")
        x += VAR_COL_W + VAR_COL_GAP
    }
}

; Grey placeholder text inside an empty Edit. EM_SETCUEBANNER.
CueBannerFor(ctrl, text) {
    try DllCall("SendMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x1501, "Ptr", 1,
                "WStr", text)
}

; Echo the trunk's four boxes into the grid's top row, so it reads as the picker
; will: "main" first, then every branch under it.
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


; ─── The timers that needed the window ───────────────────────────────────────
;  The Tools button's caption and the unknown-model prompt. Everything else that
;  starting MMA involves ran before Edge did — see CORE_BootServices, called up
;  beside the settings block rather than here.
CORE_BootWindowTasks()

; ─── Settings ─────────────────────────────────────────────────────────────────
;  The WebView Settings, which is its own PROCESS — it carries an Edge runtime of
;  its own, and this window must never wait on one starting. Raised rather than
;  relaunched when it is already up, so a second press does not throw away what
;  you had typed but not saved.
;
;  The Win32 shell keeps calling OpenSettings() for the Gui version. Both write
;  the same cfg; the WebView one broadcasts MMA_MSG_SETTINGS_CHANGED when it
;  saves, which is what puts a renamed model on this window's buttons.
; The hotkey editor. Its own process for the same reason Settings is — it
; carries a WebView2 — and its own BUTTON rather than a link inside Settings,
; because "which key does that" is a question people arrive with, not one they
; go looking through a settings window for.
;
; The Win32 editor is the fallback, and hotkeys_webview.ahk falls back to it by
; itself when the Edge runtime will not start; the only case left for here is
; the file being absent outright.
HWV_Open() {
    ; Settings ▸ Interface ▸ Hotkey editor. Both kinds are runnable scripts here,
    ; so this is a straight choice of file — and MMA_ShellFor has already dropped
    ; to legacy if the WebView one is missing.
    path := (MMA_ShellFor("hotkeys") = "webview") ? MMA_SRC_HOTKEYS_WV
                                                  : MMA_SRC_HOTKEYS_GUI
    if !FileExist(path) {
        LOGE("wv.hotkeys", "no hotkey editor to open", path)
        return
    }
    ; #SingleInstance Force would replace a running one, which throws away any
    ; unsaved captures. Raise the one that is up instead.
    if WinExist("MMA Hotkeys ahk_class AutoHotkeyGUI") {
        WinActivate("MMA Hotkeys ahk_class AutoHotkeyGUI")
        return
    }
    LOGI("wv.hotkeys", "opening the hotkey editor: " path)
    LOG_Try("wv.hotkeys", "Run the hotkey editor", () => Run(A_AhkPath ' "' path '"'))
}

