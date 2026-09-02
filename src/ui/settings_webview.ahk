#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/log.ahk"
#Include "../core/theme.ahk"
#Include "../core/crashlog.ahk"
#Include "../core/modes.ahk"
#Include "../core/hotkeys.ahk"
#Include "../mass/store.ahk"
; ModelPlatform / SetModelPlatform, ModelMatchMode, PositionalSlot,
; FanslyMatchMode / FanslyPosSlot, and ActiveModelStatus + TabLitIndex for
; the live readout on the Models section. It pulls screen\pill_scan.ahk in
; with it, which is read-only code that runs only when called — the same
; deal the Win32 Settings already has, and the price of being able to show
; what the detector is seeing RIGHT NOW rather than only what it is set to.
#Include "../core/active_model.ahk"
; NOT core/processes.ahk. Nothing here launches or kills a script, and that
; file needs SCRIPT_DIR and startupScripts — globals the MAIN window owns.
; Including it for nothing would make this window depend on being one.
; SETTINGS_Fields / SETTINGS_Int — the field table both Settings front ends are
; built from, so a setting is described once (settings_core.ahk, below).
; CREDIT_AssetList — which pictures assets\decoration\ holds, for the corner
; picture list. None of the GDI+ half of that file is used here.
#Include "credit.ahk"
#Include "settings_core.ahk"
#Include "../vendor/json.ahk"
; thqby's WebView2 wrapper — finds WebView2Loader.dll beside itself and the Edge
; runtime from its install root, and pulls in ComVar.ahk / Promise.ahk itself.
#Include "../vendor/WebView2/WebView2.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  settings_webview.ahk — Settings, drawn by Edge.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own PROCESS, like the branch builder and the activity chart, and for the
;  same reason: it carries a WebView2, and the main window must never wait on an
;  Edge runtime starting. The Win32 Settings (ui\settings_window.ahk) is a Gui
;  built inside the main window and stays exactly as it is — it is the fallback,
;  and it is still the only place the deep tabs live (see WHAT IS NOT HERE).
;
;  ─── WHERE THE SETTINGS COME FROM ────────────────────────────────────────────
;  Two sources, and NEITHER is a list typed out again in this file:
;
;    Features   the registry in core\modes.ahk — FEAT_META / FEAT_ORDER /
;               FEAT_SECTIONS, read through FEAT_Raw and written through
;               FEAT_SetRaw. A new FEAT_Def line appears in this window with no
;               edit here, exactly as it does in the Win32 Features tab.
;    Everything the SWV_Fields() table below, which is the one description of
;    else       each plain setting: where it lives in the cfg, what type it is,
;               what it defaults to and what it is called.
;
;  The table is this file's own, and that is the honest limit of the current
;  arrangement: ui\settings_window.ahk still reads and writes the same keys its
;  own way. Two writers of one key is the drift this tree keeps getting bitten
;  by — see ui\main_core.ahk's header — so the table is deliberately declarative
;  and small, ready to be lifted out and handed to the Win32 window too. Until
;  that happens, a NEW setting must be added in both or it will be missing from
;  one of them.
;
;  ─── WHAT IS NOT HERE, AND WHY ───────────────────────────────────────────────
;    Hotkeys    a window of its own either way — ui\hotkeys_webview.ahk now,
;               ui\hotkeys_window.ahk before it. ~140 rows with search, clash
;               reporting and live key capture is not a Settings section, and
;               it is the one editor that must still open when the main GUI
;               will not. The button runs it.
;    Debug,     calibration drags, the OCR region pickers, the colour pickers,
;    probes     the detector readouts. All of them drive AHK-side screen capture
;               and overlays; the button opens the Win32 window at that tab.
;
;  Neither is a stub: both open the real thing, and the real thing is unchanged.
;
;  ─── THE BRIDGE ──────────────────────────────────────────────────────────────
;      page → AHK   postMessage {cmd: ready | set | save | close | open}
;      AHK  → page  window.mma.sync({whole state})
;
;  Full state every time, like the main window. This window holds a few dozen
;  values; a delta protocol would be a second copy of the truth for no gain.
;
;  Nothing may ExecuteScript before the page posts `ready` — until then
;  `window.mma` does not exist and the call lands on a document that cannot
;  answer, silently, because a script error inside the WebView goes to the page's
;  console and nowhere this process can see.
; ═══════════════════════════════════════════════════════════════════════════════

DetectHiddenWindows true

CFG := MMA_CFG

; Assigned before the window exists: g.Show() fires Size and SWV_OnSize reads wvc.
wvc       := 0
wv        := 0
wvMsgTok  := 0
SWV_Ready := false
; What the page is editing. Loaded from the cfg on open, written back on Save —
; so Close really does discard, and nothing is half-applied on the way through.
SWV_Val   := Map()
SWV_Feat  := Map()
SWV_Easy  := MODE_IsEasy()
SWV_Dirty := false

; ─── The settings this window shows ─────────────────────────────────
;  The table itself is SETTINGS_Fields() in ui\settings_core.ahk — shared with
;  the Win32 window, because one description of a setting is the only way the
;  two front ends can be relied on to offer the same ones.
;
;  What is local to this window is the VALUE it should show, and that is the
;  whole of this function: rows that size themselves off another row (the
;  Model/Platform pairs off ModelCount) must see what you have just typed, not
;  what is saved, or raising the count to 4 shows no fourth row until Save.
SWV_Fields() {
    return SETTINGS_Fields(SWV_Pending)
}

; The pending-edit view of one row, handed to the table above. Anything this
; window has touched answers from SWV_Val; anything it has not falls through to
; the saved config, and the virtual rows (no ini home) to their default.
SWV_Pending(id, iniSect, iniKey, def) {
    global SWV_Val, CFG
    if SWV_Val.Has(id)
        return SWV_Val[id]
    if (iniSect = "")
        return def
    return Trim(IniRead(CFG, iniSect, iniKey, def))
}

; ─── Reading and writing ──────────────────────────────────────────────────────

; Load every field's current value out of the cfg into SWV_Val.
;
; Everything is carried as a STRING, including the booleans, because that is what
; an ini holds and what every other reader of these keys compares against. The
; page turns "1" into a tick; nothing converts on the way back.
SWV_Load() {
    global SWV_Val, SWV_Feat, SWV_Easy, CFG
    SWV_Val := Map()
    for _, fld in SWV_Fields() {
        ; A row with no ini home of its own — a "note", or a readout the page
        ; draws but cannot edit. waitTime used to be here too, scraped out of
        ; utils.ahk by a regex, and so were modelStrategy and inflowwMatch, the
        ; two halves of [Settings] ModelMatch. All three are ordinary keys now
        ; and load in this loop like everything else.
        ;
        ; The ModelMatch pair went the same way and for the same reason: the
        ; "Strategy" row was global manual-vs-automatic, so it had to be split
        ; off ModelMatch on load and recombined on save, and it made Fansly's
        ; mode a hostage to Infloww's. Each site now owns its own three-way key,
        ; inflowwMatch IS [Settings] ModelMatch, and this loop is the whole of it.
        if (fld.iniSect = "")
            continue
        SWV_Val[fld.id] := Trim(IniRead(CFG, fld.iniSect, fld.iniKey, fld.def))
    }

    SWV_Feat := Map()
    for _, id in FEAT_ORDER
        SWV_Feat[id] := FEAT_Raw(id) ? "1" : "0"
    SWV_Easy := MODE_IsEasy()
}

; How many models the page is currently editing, clamped to the slots that
; actually exist. Several places below have to agree on this number.
SWV_ModelCount() {
    global SWV_Val, CFG
    n := SETTINGS_Int(SWV_Val.Has("ModelCount") ? SWV_Val["ModelCount"]
                                           : Trim(IniRead(CFG, "Settings", "ModelCount", "3")),
                 3, 1)
    return Max(1, Min(n, MASS_MODELS))
}

; The model slots assigned to one site, in model order, as the page has them.
SWV_SlotsOn(want) {
    global SWV_Val, CFG
    out := []
    Loop SWV_ModelCount() {
        k := "Platform" A_Index
        v := SWV_Val.Has(k) ? SWV_Val[k]
                            : Trim(IniRead(CFG, "Settings", k, "infloww"))
        if (StrLower(v) = want)
            out.Push(A_Index)
    }
    return out
}

; Write everything back, then tell the rest of MMA.
;
; Returns a string describing what needs a restart, or "" if nothing does. The
; caller shows it — this function does not open dialogs, so it can be reasoned
; about and, one day, tested.
SWV_Save() {
    global SWV_Val, SWV_Feat, SWV_Easy, CFG
    changed := []

    ; ── features first ────────────────────────────────────────────────────────
    ; Before the plain keys, for the same reason the Win32 tab applies them first:
    ; everything below runs in the state the features are about to be in, and a
    ; service that is being switched off should not be started by the block after.
    MODE_Set(SWV_Easy ? "easy" : "advanced")
    for id, on in SWV_Feat {
        if (FEAT_Raw(id) ? "1" : "0") != on
            changed.Push(FEAT_META.Has(id) ? FEAT_META[id].label : id)
        FEAT_SetRaw(id, on = "1")
    }

    needRestart := []
    for _, fld in SWV_Fields() {
        if !SWV_Val.Has(fld.id)
            continue
        v := SWV_Val[fld.id]

        if (fld.iniSect = "")
            continue

        was := Trim(IniRead(CFG, fld.iniSect, fld.iniKey, fld.def))
        if (was = v)
            continue
        if (fld.type = "int")
            v := SETTINGS_Int(v, fld.def, 0) . ""
        IniWrite(v, CFG, fld.iniSect, fld.iniKey)
        LOGI("swv.save", fld.iniKey ": " (was = "" ? "(unset)" : was) " → " v)
        if fld.warn
            needRestart.Push(fld.label)
    }

    ; ── the model keys that are not one control, one key ──────────────────────
    ;
    ; ModelMatch used to be recombined here out of the Strategy row and the
    ; Infloww row. It is not any more: inflowwMatch writes [Settings] ModelMatch
    ; directly and fanslyMatch writes [Fansly] Match, both through the generic
    ; loop above, which is what lets a mixed setup read each site the way that
    ; site can be read — or not read one of them at all.

    ; Positions past the end of a site's model list.
    ;
    ; The order rows only exist for the tabs a site actually has, so moving a
    ; model from Infloww to Fansly leaves the Infloww row it used to occupy
    ; behind in the cfg - still naming a model that is not on that site any
    ; more. PositionalSlot reads 0 as "no answer", which is the honest value for
    ; a tab position that cannot happen; left alone, a stale Pos3=2 would answer
    ; for a third Infloww tab on a setup that has two.
    _ClearOrderTail(sect, keep) {
        Loop MASS_MODELS {
            if (A_Index <= keep)
                continue
            if (Trim(IniRead(CFG, sect, "Pos" A_Index, "")) != "0") {
                IniWrite(0, CFG, sect, "Pos" A_Index)
                LOGV("swv.save", "[" sect "] Pos" A_Index " cleared - that site has"
                               . " only " keep " model(s) now")
            }
        }
    }
    _ClearOrderTail("Positional", SWV_SlotsOn("infloww").Length)
    _ClearOrderTail("FanslyPos",  SWV_SlotsOn("fansly").Length)

    ; ── tell everyone ─────────────────────────────────────────────────────────
    ; The theme, the model names and the feature switches are all cached by the
    ; processes that read them, so a write alone changes nothing on screen. The
    ; broadcast is what makes a rename show up on the Load button without a
    ; restart — see MMA_MSG_SETTINGS_CHANGED in core\messages.ahk.
    HK_Broadcast(MMA_MSG_SETTINGS_CHANGED)
    ; Feature changes also move which hotkeys may register at all, and that is the
    ; registry's own broadcast rather than this one.
    if changed.Length
        HK_Broadcast(HK_MSG_RELOAD)

    out := ""
    for _, r in needRestart
        out .= (out = "" ? "" : "`n• ") r
    return out = "" ? "" : "• " out
}

; An integer from the page, clamped. The page sends strings and a person can type
; anything into a number box; a blank or a word must fall back rather than write 0
; into a wait time.
; SETTINGS_Int lives in settings_core.ahk, next to the table that needs it.

; ─── The window ───────────────────────────────────────────────────────────────

pal := THEME_Set()
g := Gui("+Resize +MinSize860x600", "MMA Settings")
g.MarginX := 0
g.MarginY := 0
g.BackColor := (pal.win = "") ? "Default" : pal.win
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", pal.dark ? 1 : 0, "int", 4)
g.OnEvent("Size", SWV_OnSize)
; Closing discards. Nothing is written until Save, so there is nothing to ask
; about — which is the point of loading into SWV_Val rather than editing live.
g.OnEvent("Close", (*) => ExitApp())
g.Show("w1040 h760")

SWV_Load()

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    LOGE("swv.win", "WebView2 would not start — Settings cannot open this way",
                    LOG_Err(e))
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nSettings is drawn by the Microsoft Edge WebView2 Runtime, which"
         . " ships with Windows 11. Install it from Microsoft if this machine has"
         . " had it removed.`n`nIn the meantime, switch the main window to"
         . " Classic — its Settings is a plain Win32 window and needs none of"
         . " this.", "MMA — Settings", 0x10)
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false

; add_, not the wrapper's shorthand — that returns an object whose only job is to
; unregister on destruction using a raw copy of the core pointer taken without an
; AddRef, which crashes on shutdown. See webview_main_window.ahk for the measured
; version of this.
wvMsgTok := wv.add_WebMessageReceived(SWV_OnMessage)

wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/settings.html")

LOG_Kv("swv.win", Map("fields", SWV_Fields().Length, "features", FEAT_ORDER.Length,
                      "easy", MODE_IsEasy() ? 1 : 0, "theme", THEME_Name()))

; ═══════════════════════════════════════════════════════════════════════════════
;  The bridge
; ═══════════════════════════════════════════════════════════════════════════════

SWV_OnMessage(sender, args) {
    global SWV_Ready, SWV_Val, SWV_Feat, SWV_Easy, SWV_Dirty, g, wv
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("swv.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""
    try {
        switch cmd {
            case "ready":
                SWV_Ready := true
                SWV_Sync()
                ; ── open on a named section ───────────────────────────────────
                ;  `settings_webview.ahk section=Models` shows that section
                ;  straight away. It exists for the screenshot loop: driving the
                ;  rail with a real click from outside needs SetForegroundWindow,
                ;  which Windows REFUSES from a background process - and the
                ;  click then lands on whatever is actually in front, which on
                ;  this machine is the user's browser. Same reason
                ;  hotkeys_webview.ahk takes `overlay`.
                ;  A trailing "!" on the name scrolls to the bottom of it,
                ;  which is the only way to photograph a section taller than
                ;  the window.
                if (A_Args.Length && SubStr(A_Args[1], 1, 8) = "section=") {
                    _sec := SubStr(A_Args[1], 9)
                    _end := (SubStr(_sec, -1) = "!")
                    if _end
                        _sec := SubStr(_sec, 1, -1)
                    SWV_Js("window.mma.go(" JSON.Stringify(_sec) ", "
                         . (_end ? "true" : "false") ")")
                }
                ; The Models readout, from here on. 900ms rather than the Win32
                ; tab's 400: this one crosses a process boundary and a bridge,
                ; and nothing on that line changes faster than you can read it.
                SetTimer(SWV_PushDetector, 900)

            ; One value changed. Held in SWV_Val until Save — nothing reaches the
            ; cfg from here, which is what makes Close a real discard.
            case "set":
                k := m["key"], v := m["value"] . ""
                if (k = "__easy") {
                    SWV_Easy := (v = "1")
                } else if SWV_Feat.Has(k) {
                    SWV_Feat[k] := v
                } else {
                    SWV_Val[k] := v
                }
                SWV_Dirty := true
                SWV_Sync()

            case "save":
                note := SWV_Save()
                SWV_Dirty := false
                ; Re-read rather than trusting what was just sent: FEAT_SetRaw can
                ; refuse, and the page must show what is actually on disk, not
                ; what was asked for.
                SWV_Load()
                SWV_Sync()
                if (note != "")
                    MsgBox("Saved.`n`nThese need MMA restarted before they take"
                         . " effect:`n`n" note, "MMA Settings", 0x40)
                else
                    SWV_Toast("Saved")

            case "close":
                ExitApp()

            ; The two things this window deliberately does not draw. Both open the
            ; real window rather than a stub — see the header.
            case "open":
                SWV_OpenExternal(m.Has("what") ? m["what"] : "")

            case "devtools":
                wv.OpenDevToolsWindow()
        }
    } catch as e
        LOGE("swv.msg", "handling '" cmd "' failed", LOG_Err(e))
}

; Push the whole state to the page.
SWV_Sync() {
    global wv, SWV_Ready, SWV_Val, SWV_Feat, SWV_Easy, SWV_Dirty
    if !SWV_Ready
        return

    st := Map()

    ; The field descriptors travel WITH the values, so the page has no list of
    ; its own to keep in step. Adding a row to SWV_Fields() puts it on screen.
    fields := []
    for _, fld in SWV_Fields() {
        o := Map("id", fld.id, "sect", fld.sect, "group", fld.grp,
                 "type", fld.type,
                 "label", fld.label, "help", fld.help, "warn", fld.warn ? 1 : 0,
                 "value", SWV_Val.Has(fld.id) ? SWV_Val[fld.id] : fld.def)
        if (fld.type = "choice") {
            opts := []
            for _, o2 in fld.opts
                opts.Push(Map("v", o2[1], "l", o2[2]))
            o["opts"] := opts
        }
        fields.Push(o)
    }
    st["fields"] := fields

    ; Same for the feature registry — sections in declaration order, so the page
    ; groups them the way modes.ahk does.
    feats := []
    for _, id in FEAT_ORDER {
        f := FEAT_META[id]
        feats.Push(Map("id", id, "label", f.label, "sect", f.section,
                       "on", SWV_Feat.Has(id) ? SWV_Feat[id] : "0"))
    }
    st["features"] := feats
    st["models"]   := SWV_ModelsInfo()
    st["easy"]     := SWV_Easy ? 1 : 0
    st["dirty"]    := SWV_Dirty ? 1 : 0
    st["theme"]    := SWV_Val.Has("Theme") ? SWV_Val["Theme"] : THEME_Name()

    try wv.ExecuteScriptAsync("window.mma.sync(" JSON.Stringify(st) ")")
}

; ─── What the detector is seeing, right now ───────────────────────────────────
;  The one line on the Models section that is not a setting. Everything above it
;  is a choice you cannot check by looking at it, which is how the detector
;  stayed wrong for so long without anyone noticing: it answered "model 1" with
;  total confidence and nothing on screen disagreed.
;
;  Two different facts, and conflating them is what made the Win32 version of
;  this line read as a contradiction ("tab 2 -> Rama (Infloww not in front)"):
;
;    what the STRIP shows   read with the focus gate deliberately ignored, or you
;                           could never read it at all - looking at this window
;                           means Infloww is not the focused one.
;    what the KEYS will do  asked of the resolver itself, so it accounts for the
;                           focus gate AND the mixed-platform fallback. Nothing
;                           here re-derives that; a second opinion is how a
;                           readout starts disagreeing with reality.
;
;  Every call is guarded as one. This runs on a timer, in a window whose whole
;  job is to be open while the detector is misbehaving, and a throw from a pixel
;  read must cost the line rather than the window.
SWV_DetectorLine() {
    try {
        ; The site you are actually looking at, not Infloww unconditionally. With
        ; per-site modes "manual" is no longer one fact about the whole install,
        ; and reading [Settings] ModelMatch here reported "nothing is read" for a
        ; desk whose Infloww tab strip was being read perfectly well.
        if (ActiveSiteMatchMode() = "manual")
            return "manual on " (ActiveSiteName() = "fansly" ? "Fansly" : "Infloww")
                 . " - nothing on screen is read there; the picker window asks"

        ; `dc`, not `cfg`. AHK matches names case-INSENSITIVELY, so a local
        ; called cfg IS the global CFG — assigning it here made CFG local to
        ; this whole function, and the IniRead above then read an unassigned
        ; variable. The line reported "could not read the screen" and named a
        ; variable nothing on screen mentions.
        dc := DetectorCfg()
        t  := TabLitIndex(dc)
        st := ActiveModelStatus()

        line := (t.index < 1) ? "no lit tab" : "tab " t.index
        slot := (t.index >= 1) ? TabModel(t.index) : 0
        line .= "   |   " (slot ? "that tab is " SWV_SlotName(slot) : "no answer")
        line .= "   |   keys send "
              . (st.no ? SWV_SlotName(st.no) : "nothing")
        return line
    }
    catch as e
        return "could not read the screen: " LOG_Err(e)
}

; "3: Dessy", from the names the PAGE is showing - not from the cfg. Renaming a
; model and watching the readout still call her by the old name would read as the
; rename not having taken.
SWV_SlotName(n) {
    global SWV_Val, CFG
    if (n < 1)
        return "-"
    k  := "Model" n
    nm := Trim(SWV_Val.Has(k) ? SWV_Val[k] : IniRead(CFG, "Settings", k, ""))
    return n ": " (nm = "" ? "Model " n : nm)
}

; Everything the Models section needs that is not a setting.
;
;   ofSlots / fanSlots  which models are on each site, from what the PAGE has,
;                       so the two order rows can be built and labelled - and so
;                       "no models are set to Infloww" can be said rather than
;                       leaving an empty row that looks broken.
;   detector            the live readout (below).
;   service             whether the detector process is actually up. Read from
;                       the PROCESS, not the setting: they disagree whenever
;                       something was toggled from the main window or died on
;                       its own, and that disagreement is the only reason this
;                       line is worth having.
;   pointHint           the real keys, from hotkeys.ini, in the sentence that
;                       tells you how to teach the order by pointing. Written
;                       out with whatever the keys are set to rather than the
;                       defaults, because a hint naming a key you do not have is
;                       worse than no hint.
SWV_ModelsInfo() {
    det := WinExist(MMA_SRC "\screen\model_detector.ahk ahk_class AutoHotkey") != 0
    return Map(
        "ofSlots",  SWV_SlotsOn("infloww"),
        "fanSlots", SWV_SlotsOn("fansly"),
        "detector", SWV_DetectorLine(),
        "serviceOn", det ? 1 : 0,
        "service", det
            ? Chr(0x25CF) " Model detector is running."
            : Chr(0x25CB) " Model detector is not running - switch it on in"
                        . " Features, or set the strategy above to Manual and"
                        . " pick the model in the window.",
        "pointHint",
            "Set either order by pointing: click a model's tab in Infloww - or"
          . " its card on the Fansly rail - and press that model's key ("
          . HK_Key("mass.select.m1") " / " HK_Key("mass.select.m2") "). The key"
          . " knows which window is in front and teaches that one. High beep ="
          . " set, low beep = refused, tooltip says why.")
}

; Push just the two live lines. A whole SWV_Sync every second would rebuild the
; page under the pointer and fight anything half-typed in a text box.
SWV_PushDetector() {
    global SWV_Ready, wv
    if !SWV_Ready
        return
    det := WinExist(MMA_SRC "\screen\model_detector.ahk ahk_class AutoHotkey") != 0
    try wv.ExecuteScriptAsync("window.mma.live("
                            . JSON.Stringify(SWV_DetectorLine()) ", "
                            . (det ? "1" : "0") ")")
}

SWV_Toast(text) {
    SWV_Js("window.mma.toast(" JSON.Stringify(text) ")")
}

; One guarded place to run script in the page. Before `ready` there is no
; window.mma to call and the call lands on a document that cannot answer -
; silently, because a script error inside the WebView goes to the page's console
; and nowhere this process can see. So it is a hard gate, not a try.
SWV_Js(js) {
    global wv, SWV_Ready
    if !SWV_Ready
        return
    try wv.ExecuteScriptAsync(js)
}

; Open the windows this one does not draw.
;
; Both are the REAL thing, unchanged: the hotkeys editor is already a standalone
; window over the registry, and the Win32 Settings still owns every calibration
; drag, colour picker and probe readout.
SWV_OpenExternal(what) {
    switch what {
        ; Whichever kind Settings ▸ Interface asks for. MMA_ShellFor has
        ; already dropped to legacy if the WebView file is missing; and if the
        ; EDGE RUNTIME is what will not start, hotkeys_webview.ahk opens the
        ; Win32 editor itself rather than leaving you with no way to fix a key.
        case "hotkeys":
            path := (MMA_ShellFor("hotkeys") = "webview") ? MMA_SRC_HOTKEYS_WV
                                                          : MMA_SRC_HOTKEYS_GUI
            if !FileExist(path) {
                LOGE("swv.open", "no hotkey editor to open", path)
                return
            }
            LOGI("swv.open", "opening the hotkeys editor: " path)
            LOG_Try("swv.open", "Run the hotkeys editor", () => Run(A_AhkPath ' "' path '"'))

        ; The Win32 Settings, for the tabs that drive screen capture and overlays.
        ; It is a Gui inside the MAIN window's process, not a script that can be
        ; run — so this asks that window to open it, the same way the Hotstrings
        ; window asks for the Add-hotkey dialog.
        case "classic":
            win := MMA_GuiWin()
            if !WinExist(win) {
                MsgBox("The classic Settings window is opened by MMA's main"
                     . " window, and that is not running.", "MMA Settings", 0x30)
                return
            }
            try DllCall("AllowSetForegroundWindow", "UInt", WinGetPID(win))
            PostMessage(MMA_MSG_OPEN_SETTINGS, 0, 0, , win)
            LOGI("swv.open", "asked the main window for the classic Settings")
    }
}

; The WebView has no window of its own to resize — it is told its bounds.
SWV_OnSize(gObj, minMax, w, h) {
    global wvc
    if (minMax = -1 || !IsObject(wvc))
        return
    try wvc.Bounds := [0, 0, w, h]
}
