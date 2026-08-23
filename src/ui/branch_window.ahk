#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/theme.ahk"
#Include "../branch/tree.ahk"
#Include "../vendor/json.ahk"
; thqby's WebView2 wrapper — finds WebView2Loader.dll beside itself and the Edge
; runtime from its install root, and pulls in ComVar.ahk / Promise.ahk itself.
#Include "../vendor/WebView2/WebView2.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  branch_window.ahk — the branch builder's window.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own process. It binds no hotkeys, supervises nothing, and closing it stops
;  nothing — it is a document editor for userdata\branch_trees.json that happens
;  to know how to compile.
;
;  ── Who owns what ────────────────────────────────────────────────────────────
;      the page   owns the tree WHILE THE WINDOW IS OPEN, and every edit
;      this file  owns the FILE, the compiler, the clipboard and masses.json
;
;  There is exactly one compiler and it is branch/tree.ahk. The page never works
;  out what a tree compiles to — it asks, on a 220 ms debounce, and renders the
;  answer. That is the whole reason the preview pane can be trusted: what it
;  shows is produced by the same function that Save writes, so the two cannot
;  drift. A JavaScript copy of the rules would have been faster and would have
;  been wrong within a week.
;
;  ── The bridge ───────────────────────────────────────────────────────────────
;      page → AHK   postMessage {cmd: ready | compile | save | copy | toSlot}
;      AHK  → page  window.mma.load / .preview / .toast / .theme
;
;  Nothing may ExecuteScript before the page posts `ready` — until then
;  `window.mma` does not exist and the call lands on a document that cannot
;  answer, silently, because a script error inside the WebView goes to the
;  page's console and nowhere this process can see.
; ═══════════════════════════════════════════════════════════════════════════════

CFG := MMA_CFG

; Assigned before the window exists: g.Show() fires Size and BW_OnSize reads wvc.
wvc      := 0
wv       := 0
wvMsgTok := 0
BW_Ready := false

pal := THEME_Set()
g := Gui("+Resize +MinSize900x620", "MMA Branch builder")
g.MarginX := 0
g.MarginY := 0
g.BackColor := (pal.win = "") ? "Default" : pal.win
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", pal.dark ? 1 : 0, "int", 4)
g.OnEvent("Size", BW_OnSize)
g.OnEvent("Close", (*) => ExitApp())
g.Show("w1320 h860")

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    LOGE("br.win", "WebView2 would not start — the branch builder cannot open",
                   LOG_Err(e))
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nThe branch builder is drawn by the Microsoft Edge WebView2"
         . " Runtime, which ships with Windows 11. Install it from Microsoft if"
         . " this machine has had it removed.`n`nYour saved flows are untouched"
         . " — they live in userdata\branch_trees.json.",
           "MMA — Branch builder", 0x10)
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false

; add_, not the wrapper's shorthand — that returns an object whose only job is to
; unregister on destruction using a raw copy of the core pointer taken without an
; AddRef, which crashes on shutdown. See webview_main_window.ahk for the measured
; version of this.
wvMsgTok := wv.add_WebMessageReceived(BW_OnMessage)

wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/branch_builder.html")

LOG_Kv("br.win", Map("file", BR_FILE, "models", MASS_MODELS, "slots", MASS_SLOTS))

; ═══════════════════════════════════════════════════════════════════════════════
;  The bridge
; ═══════════════════════════════════════════════════════════════════════════════

BW_OnMessage(sender, args) {
    global BW_Ready
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("br.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""

    if (cmd = "ready") {
        BW_Ready := true
        BW_Theme()
        BW_SendDoc()
        return
    }
    if (cmd = "compile") {
        BW_SendPreview(m.Has("tree") ? m["tree"] : Map())
        return
    }
    if (cmd = "save") {
        ; Autosaved on a 700 ms debounce from the page. VERB, not INFO: this
        ; fires every few seconds while somebody types, and at INFO it would
        ; bury the log the way the FEAT() gate would have.
        if m.Has("doc")
            BR_Save(m["doc"])
        return
    }
    if (cmd = "copy") {
        BW_Copy(m.Has("tree") ? m["tree"] : Map())
        return
    }
    if (cmd = "toSlot") {
        BW_ToSlot(m)
        return
    }
    LOGW("br.msg", "unknown command from the page: '" cmd "'")
}

BW_Theme() {
    global wv, BW_Ready
    if !BW_Ready
        return
    ; Classic defers to Windows, and the page's own prefers-color-scheme already
    ; does that — so classic is the one theme this must NOT stamp.
    if THEME_Is("classic")
        return
    try wv.ExecuteScriptAsync("window.mma.theme(" (THEME_Set().dark ? "true" : "false") ")")
}

; The whole document, plus the two numbers the page needs in order to show the
; limits rather than discover them: how many follow-up levels there are, and how
; many models a mass can be saved into.
BW_SendDoc() {
    global wv, BW_Ready
    if !BW_Ready {
        LOG_Bail("br.send", "the page has not said ready yet — nothing sent")
        return
    }
    names := []
    Loop MASS_MODELS
        names.Push(IniRead(MMA_CFG, "Settings", "Model" A_Index, "Model " A_Index))

    payload := Map("doc",     BR_Load(),
                   "models",  names,
                   "slots",   MASS_SLOTS,
                   "fuDepth", MASS_FU_DEPTH)
    try {
        wv.ExecuteScriptAsync("window.mma.load(" JSON.Stringify(payload) ")")
    } catch as e {
        LOGE("br.send", "could not hand the flows to the page", LOG_Err(e))
    }
}

; One compile, turned into what the page draws under the canvas.
_BW_Result(tree) {
    r := BR_Compile(tree)
    return Map("ok",       r["ok"],
               "errors",   r["errors"],
               "warnings", r["warnings"],
               "paths",    r["paths"],
               "text",     r["ok"] ? BR_EmitText(r["record"]) : "")
}

BW_SendPreview(tree) {
    global wv, BW_Ready
    if !BW_Ready
        return
    try {
        out := _BW_Result(tree)
        wv.ExecuteScriptAsync("window.mma.preview(" JSON.Stringify(out) ")")
    } catch as e {
        ; A compile that throws must not take the window with it — you would lose
        ; whatever is on the canvas, which is the only copy until the autosave.
        LOGE("br.preview", "compiling the flow threw — the preview is stale",
                           LOG_Err(e))
    }
}

BW_Copy(tree) {
    global wv
    r := BR_Compile(tree)
    if !r["ok"] {
        LOG_Bail("br.copy", "refused to copy a flow that does not compile")
        try wv.ExecuteScriptAsync("window.mma.toast('fix the errors first')")
        return
    }
    txt := BR_EmitText(r["record"])
    A_Clipboard := txt
    ; ClipWait, because "Copy" that silently did not is the worst possible
    ; version of this button: you paste into MMA and get whatever was there
    ; before, which may well be another model's mass.
    if !ClipWait(1) {
        LOGE("br.copy", "the clipboard never accepted the mass — nothing was copied")
        try wv.ExecuteScriptAsync("window.mma.toast('the clipboard refused it')")
        return
    }
    LOGI("br.copy", "copied a compiled flow (" StrLen(txt) " chars, "
                  . r["paths"] " route(s)) to the clipboard")
    try wv.ExecuteScriptAsync("window.mma.toast('copied — paste it into MMA')")
}

; Write the compiled record straight into masses.json.
;
; Read-modify-write through MASS_Load/MASS_Save, so the other eleven slots are
; untouched. What this CANNOT defend against is the main window holding a stale
; copy of the same model and saving afterwards — that is a pre-existing property
; of a GUI that edits one model at a time, and the dialog in the page says so
; rather than this pretending to solve it.
BW_ToSlot(m) {
    global wv
    if !m.Has("tree") || !m.Has("model") || !m.Has("slot") {
        LOGW("br.slot", "save request was missing its target — ignored")
        return
    }
    model := 0, slot := 0
    try {
        model := Integer(m["model"])
        slot  := Integer(m["slot"])
    } catch {
        LOGW("br.slot", "save target was not a number — ignored")
        return
    }
    if (model < 1 || model > MASS_MODELS || slot < 1 || slot > MASS_SLOTS) {
        LOGW("br.slot", "save target model " model " slot " slot " is outside the"
                      . " " MASS_MODELS "x" MASS_SLOTS " that exist — ignored")
        return
    }
    r := BR_Compile(m["tree"])
    if !r["ok"] {
        LOG_Bail("br.slot", "refused to save a flow that does not compile")
        try wv.ExecuteScriptAsync("window.mma.toast('fix the errors first')")
        return
    }
    doc := MASS_Load()
    MASS_Set(doc, model, slot, r["record"])
    if !MASS_Save(doc) {
        try wv.ExecuteScriptAsync("window.mma.toast('could not write masses.json')")
        return
    }
    LOGI("br.slot", "wrote a compiled flow into model " model " mass " slot
                  . " (" r["paths"] " route(s))")
    try wv.ExecuteScriptAsync("window.mma.toast('saved into model " model
                            . " mass " slot "')")
}

BW_OnSize(guiObj, minMax, W, H) {
    global wvc
    if (minMax = -1)
        return
    if wvc
        try wvc.Fill()
}
