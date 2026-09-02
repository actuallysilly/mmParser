#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  main_core.ahk — the app behind the main window, with no window in it.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA has two front ends: ui\main_window.ahk draws the panel out of Win32
;  controls, ui\webview_main_window.ahk draws the same panel with Edge and CSS.
;  Everything that is not DRAWING lives here, and both of them #Include it.
;
;  ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
;  It did not, and the two shells had grown their own copies of the same logic —
;  thirty-four functions defined twice. They had already drifted: ApplyFile
;  differed by 56 lines, PickMassSlot by 28, and the WebView's LoadFile called
;  RefreshModelHeader() where the Win32 one did not. That is the exact shape of
;  the mass-# bug (2.0.3): what you SAW and what the keys SENT disagreed, because
;  two copies of one truth are one copy plus a lie waiting to be found.
;
;  So the rule is: if a function does not touch a Gui control's POSITION, SIZE or
;  CREATION, it belongs in here, not in a shell.
;
;  ─── THE SEAM ────────────────────────────────────────────────────────────────
;  Nothing in here creates a control, and nothing in here knows what a control
;  IS. It needs objects with a `.Value` (and, for captions, a `.Text`) — the Win32
;  shell hands it real Gui controls, the WebView shell hands it WvCell shims that
;  store a string and mark the page dirty. Both satisfy the same duck type, which
;  is what makes one copy of this logic possible at all.
;
;  A shell must have assigned these BEFORE anything here is called:
;
;    edCtrls     Map "m<model>_<field>" → cell     the fourteen boxes per model
;    edPaste     cell                              the paste box
;    tabs        cell, .Value = model number       which model is in front
;    lblLoaded   cell, .Text                       the "… loaded (mass N)" line
;    g           Gui                               owner for dialogs, WinActivate
;    _mFiles     array of model identifiers        what Load/Save/ApplyFile take
;    modelCount / modelNames / fastParseAutosave / _lastImportModel
;
;  Function bodies are resolved at RUN time, so the order of the #Include against
;  a shell's control setup does not matter for the functions. It DOES matter for
;  the top-level statements below (the OnMessage/OnClipboardChange registrations),
;  which is why each shell includes this at the point those should be armed.
; ═══════════════════════════════════════════════════════════════════════════════

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

; ── "Remember this name for the model" ────────────────────────────────────────
;  That one checkbox on the import prompt means two different facts, and it used
;  to write only the first:
;
;    the ALIAS   [ModelAliases] <name>=<slot>. What this model is called
;                SOMEWHERE ELSE — Infloww's tab, the Discord channel this import
;                came from. A slot can carry any number of these.
;    the NAME    [Settings] Model<n>. What MMA itself calls the slot: its tab, and
;                its Load and Save buttons. There is exactly one.
;
;  Writing only the alias is right for a model MMA already knows, and wrong for
;  the case the prompt exists to serve. Ctrl+click a new model's mass, type her
;  name, tick Remember — and the tab still said "Model 3", so you went to
;  Settings and typed the same name a second time. That is the reported bug.
;
;  So the name is ADOPTED when the slot has never been named. A slot that already
;  has a real name keeps it, because that is exactly the case where the two facts
;  differ on purpose: MMA calls her Dessy, Infloww's tab says "Dessy 🌸", and
;  overwriting the first with the second puts an emoji on the tab.
RememberModelName(name, slot) {
    global CFG_FILE, modelNames
    name := Trim(name)
    if (name = "" || slot < 1)
        return
    IniWrite(slot, CFG_FILE, "ModelAliases", name)

    if !SlotIsUnnamed(slot) {
        LOGV("model.name", "'" name "' is now an alias for model " slot
                         . ", which already calls itself '" ModelNameForSlot(slot)
                         . "' — the tab keeps that name")
        return
    }
    IniWrite(name, CFG_FILE, "Settings", "Model" slot)
    if (slot <= modelNames.Length)
        modelNames[slot] := name
    LOGI("model.name", "model " slot " had no name of its own, so the import's '"
                     . name "' is what MMA calls it now — tab and buttons included")
    ; The tab caption and the Load/Save buttons. Each shell defines this its own
    ; way and both spell it the same; `try` because the import prompt can be
    ; reached before the buttons exist on a slow start.
    try UpdateModelButtons()
}

; True while a slot has never been given a name — blank, or still the "Model <n>"
; placeholder BOTH shells fall back to when [Settings] Model<n> is missing. In one
; place so the two shells, the prompt and Settings cannot disagree about what
; "unnamed" means.
SlotIsUnnamed(slot) {
    nm := Trim(ModelNameForSlot(slot))
    return (nm = "" || nm = "Model " slot)
}

; Re-read the model names out of the cfg into the in-memory array.
;
; Needed because a rename can now arrive from ANOTHER PROCESS — the WebView
; Settings is its own script — and the shells' UpdateModelButtons only redraws
; from `modelNames`. Without this the buttons would be repainted with the names
; they already had, which looks exactly like the message never arrived.
CORE_ReloadModelNames() {
    global modelNames, CFG_FILE
    Loop modelNames.Length
        modelNames[A_Index] := IniRead(CFG_FILE, "Settings", "Model" A_Index,
                                       "Model " A_Index)
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
; All three are src/ui/settings_window.ahk now — one window of tabs (General,
; Models, Sending, Features, Scripts, Hotkeys, GUI, Debug; it said "five" until
; somebody counted). The
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
    ; A_ScreenWidth is PHYSICAL pixels; Gui.Show takes LOGICAL ones and multiplies
    ; them by A_ScreenDPI/96. Handing it the physical number made "80% of the
    ; screen" render at exactly 100% — 3440px wide on a 3440px display at 125%,
    ; with h245 arriving as 306. Converted here rather than by putting -DPIScale
    ; on the Gui: that would strip scaling from every control coordinate below
    ; while the FONT stayed scaled, which undersizes the dialog instead of fixing
    ; it. Measured: asked 700x250, +DPIScale gives 875x313, -DPIScale gives 700x250.
    W := Round(A_ScreenWidth * 0.8 * 96 / A_ScreenDPI)
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
    CORE_Changed()
}

MakeEditFuToggle(f) => (ctrl, *) => ToggleEditFuCell(f, ctrl)

ToggleEditFuCell(f, ctrl) {
    global editFuChks, CFG_FILE
    val := ctrl.Value ? 1 : 0
    for _, c in editFuChks[f]   ; "editable" is global — sync the per-tab mirrors
        c.Value := val
    IniWrite(val, CFG_FILE, "Settings", "EditableFu" f)
    _BroadcastEditableFu(f, val)
    CORE_Changed()
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

; The chat simulator, on the same terms as the branch builder above: its own
; process because it carries a WebView2, and raised rather than relaunched when
; it is already up, so a second press does not throw away the fan lines you were
; part way through writing.
OpenChatSim(*) {
    win := MMA_SRC "\ui\chat_window.ahk"
    if !FileExist(win) {
        LOGE("gui.chatsim", "chat_window.ahk is missing — the chat simulator"
                          . " cannot open", win)
        return
    }
    if WinExist("MMA Chat simulator ahk_class AutoHotkeyGUI") {
        WinActivate("MMA Chat simulator ahk_class AutoHotkeyGUI")
        return
    }
    LOGI("gui.chatsim", "opening the chat simulator")
    LOG_Try("gui.chatsim", "Run chat_window.ahk", () => Run(win))
}

; ─── Arming the shared behaviour ──────────────────────────────────────────────
;  The registrations, behind a call instead of at this file's top level.
;
;  They used to be top-level statements, which made WHERE a shell #Included this
;  file part of its behaviour: the OnMessage lines sat mid-file in the Win32
;  shell and the HK_Binds sat at its very end, so any shell that included this
;  anywhere else got a subtly different startup. A call says plainly "arm the
;  shared behaviour now", and both shells make it at the end of their own setup.
;
;  Nothing in here is safe to run twice — OnClipboardChange would fire the webgui
;  import handler twice per copy — so call it exactly once per process.
CORE_Arm() {
    ; Paste the clipboard into edPaste and parse it. Posted by copyDiscordMessageSeq
    ; in sequences.ahk, and by WebImportFromClipboard below.
    OnMessage(MMA_MSG_AUTOPARSE, AutoParseFromClipboard)
    ; The Hotstrings window's "Add hotkey…" button. It is another process, and the
    ; dialog is built out of this file's globals — the account file list, the
    ; default target file, the snd/SendText writers — so the button asks for the
    ; window rather than building one of its own. See MMA_MSG_ADD_HOTKEY.
    OnMessage(MMA_MSG_ADD_HOTKEY, OpenAddHotkeyFromMsg)
    ; The webgui's "Send to MMA" button, which copies a sentinel to the clipboard.
    OnClipboardChange(WebImportFromClipboard)
    ; The WebView Settings asking for the Win32 Settings — the tabs it does not
    ; draw. See MMA_MSG_OPEN_SETTINGS.
    OnMessage(MMA_MSG_OPEN_SETTINGS, CORE_OpenSettingsFromMsg)
    ; ...and the same window saying it just SAVED. The Win32 Settings is a Gui
    ; inside this process and calls UpdateModelButtons() directly; the WebView one
    ; is its own script and cannot. Without this handler a rename or a theme
    ; change made there landed in the cfg and nowhere on screen until a restart,
    ; which reads exactly like the setting did not save.
    OnMessage(MMA_MSG_SETTINGS_CHANGED, CORE_SettingsChangedFromMsg)

    ; Keys live in hotkeys.ini under [gui]. "mouseControl" is the shell's own
    ; context, so gui.toggleDoubleMM only fires while Mouse control is on.
    HK_Context("mouseControl", CORE_MouseControlOn)
    HK_Bind("gui.addHotkeyGrab",  AddHotkeyGrab)
    HK_Bind("gui.ocrGrab",        OcrGrab)
    HK_Bind("gui.branchBuilder",  OpenBranchBuilder)
    HK_Bind("gui.chatSim",        OpenChatSim)
    HK_Bind("gui.toggleDoubleMM", ToggleDoubleMM)
}

; ── the activity chart ────────────────────────────────────────────────────────
;  The chart has always existed and has only ever had one door: the gui.activity
;  key. That is a door you have to already know about, and the log says this one
;  had never been opened once — act.boot every session, act.chart never.
;
;  So: a button, in both shells, going through here.
;
;  It does NOT run activity_window.ahk itself. The tracker owns the minute in
;  progress and flushes it before opening the chart — without that the chart
;  comes up showing everything EXCEPT the minute you just pressed the button
;  about. So the button FIRES gui.activity through the registry and the tracker
;  answers, exactly as the Actions menu runs a key that lives in another
;  process. One implementation, and the button and the key cannot drift.
;
;  Every branch that cannot do that says why, out loud. A button that silently
;  does nothing is the failure this tree keeps being bitten by, and a broadcast
;  nobody answers is precisely that shape.
CORE_OpenActivity() {
    if !FEAT("activity") {
        MsgBox("The activity tracker is switched off, so nothing is being"
             . " recorded and there is no chart to draw.`n`nSwitch it on in"
             . " Settings " Chr(0x25B8) " Features " Chr(0x25B8) " Interface,"
             . " then give it a few minutes of typing.",
               "MMA " Chr(0x2014) " Activity", 0x40)
        return
    }
    ; Already open: raise it. #SingleInstance Force over there would make a
    ; second press close and rebuild the window you were reading.
    if WinExist("MMA Activity ahk_class AutoHotkeyGUI") {
        WinActivate("MMA Activity ahk_class AutoHotkeyGUI")
        return
    }

    ; The tracker is running: let IT open the chart, so the pending minute is
    ; flushed first.
    if SVC_Running("activity") {
        idx := 0
        for _i, _id in HK_ORDER {
            if (_id = "gui.activity") {
                idx := _i
                break
            }
        }
        if idx {
            LOGI("gui.activity", "asking the tracker to open the chart")
            HK_Broadcast(HK_MSG_FIRE, idx)
            return
        }
        LOGW("gui.activity", "gui.activity is not in HK_ORDER — opening the chart"
                           . " directly instead, so it will be missing the minute"
                           . " in progress")
    }

    ; The tracker is not running (or the registry could not be asked). Everything
    ; already on disk is still there to look at; only the current minute is
    ; missing, so this is worth doing rather than refusing.
    win := MMA_SRC "\ui\activity_window.ahk"
    if !FileExist(win) {
        LOGE("gui.activity", "activity_window.ahk is missing — there is no way to"
                           . " see what the tracker recorded", win)
        return
    }
    LOGI("gui.activity", "the tracker is not running — opening the chart directly")
    ; A_AhkPath, never a bare Run(path): a bare path goes through the .ahk file
    ; association, which is whatever is registered on this machine — an editor,
    ; or AutoHotkey v1.
    LOG_Try("gui.activity", "Run activity_window.ahk",
            () => Run(A_AhkPath ' "' win '"'))
}

; ── Settings, whichever kind is asked for ─────────────────────────────────────
;  Both shells' Settings button comes through here, so "WebView vs Classic" is
;  one answer for both rather than a choice the Classic window could not offer.
;
;  Classic could only ever open its own Win32 Settings, which made the preference
;  a half-truth: pick WebView Settings, run the Classic main window, and the
;  button still gave you the Win32 tabs with nothing saying why.
;
;  The Win32 Settings is a Gui built inside THIS process out of THIS window's
;  globals, so "legacy" is a direct call and "webview" is a script to run. If the
;  script will not start, the Win32 one opens instead — a preference must never
;  leave the button doing nothing.
CORE_OpenSettingsPreferred() {
    if (MMA_ShellFor("settings") = "legacy") {
        OpenSettings()
        return
    }
    if WinExist("MMA Settings ahk_class AutoHotkeyGUI") {
        WinActivate("MMA Settings ahk_class AutoHotkeyGUI")
        return
    }
    LOGI("gui.settings", "opening the WebView Settings")
    ; The &ok out-param, not the return value: LOG_Try RETURNS whatever fn
    ; returned, and Run returns nothing — so testing the return would read every
    ; successful launch as a failure and open both windows.
    LOG_Try("gui.settings", "Run settings_webview.ahk",
            () => Run(A_AhkPath ' "' MMA_SRC_SETTINGS_WV '"'), &started)
    if !started {
        LOGW("gui.settings", "the WebView Settings would not start — opening the"
                           . " Win32 one instead")
        OpenSettings()
    }
}

; Another process saved Settings. Re-read what this window shows.
;
; Only the three things a save can change WITHOUT a restart, which is exactly the
; set the Win32 Settings calls in-process after its own save — so both routes end
; at the same three functions and neither can drift ahead of the other. Anything
; that needs a restart needs one either way and is not this handler's business.
;
; Each call is guarded on its own. These are per-shell functions and the WebView
; shell's versions talk to a page that may not have finished loading; one of them
; throwing must not cost the other two, or a rename would depend on the theme.
CORE_SettingsChangedFromMsg(wParam, lParam, msg, hwnd) {
    LOGI("gui.settings", "another process saved Settings — re-reading the names,"
                       . " the theme and the layout")
    CORE_ReloadModelNames()
    LOG_Try("gui.settings", "repaint the model names", () => UpdateModelButtons())
    LOG_Try("gui.settings", "repaint the theme",       () => ApplyWindowTheme())
    LOG_Try("gui.settings", "re-lay out the window",   () => RelayoutNow())
    return 1
}

; The Win32 Settings, asked for by the WebView Settings window (another process).
; It is built out of this process's globals, which is why it is opened here rather
; than run over there. The caller has already called AllowSetForegroundWindow, so
; the window comes up IN FRONT rather than blinking in the taskbar behind it.
CORE_OpenSettingsFromMsg(wParam, lParam, msg, hwnd) {
    LOGI("gui.settings", "classic Settings requested by the WebView Settings window")
    OpenSettings()
    return 1
}

; A named function rather than the `(*) => mouseControl` lambda this replaces.
; A lambda written inside CORE_Arm captures by the rules that already cost this
; tree a bug (a `() =>` cannot see a for-loop's variables), and a hotkey context
; that quietly reads the wrong thing disables a key with no error anywhere.
CORE_MouseControlOn(*) {
    global mouseControl
    return mouseControl
}

; ─── Telling a shell that something changed ───────────────────────────────────
;  Most of this file changes state by writing a cell, and a shell that redraws
;  from cells needs no telling — the WebView's WvCell setter marks the page dirty
;  by itself. A few things change state WITHOUT touching a cell: the follow-up
;  toggles write an ini key and broadcast, and that is all. The Win32 shell does
;  not care, because its checkbox IS the state; the WebView shell would sit there
;  showing the old tick until something else happened to sync it.
;
;  So the shells that need it assign CORE_OnChanged (the WebView sets it to
;  WV_Touch). One that does not, does not, and this is a no-op — which is why it
;  is a hook and not a direct WV_Touch() call the Win32 shell would have to
;  define a dummy for.
global CORE_OnChanged := 0

; IsSet, not a bare truth test, and this is not belt-and-braces — it is the whole
; reason the call did not work. `global CORE_OnChanged := 0` above is a TOP-LEVEL
; statement, so it runs when a shell's #Include reaches it. The Win32 shell
; includes this file AFTER it has built its window and pre-filled the model tabs,
; and pre-filling calls FillTabFromSlot, which calls this — so the first call of
; the session happens while the global is still unassigned. Unguarded that threw
; "This global variable has not been assigned a value", the pre-fill was abandoned
; mid-way, and MMA came up with every tab blank and "press load" in the log.
;
; The same shape as the _wPos crash in the detector, and the reason CORE_BootServices
; assigns _askedNames next to the timer that reads it.
CORE_Changed() {
    global CORE_OnChanged
    if IsSet(CORE_OnChanged) && CORE_OnChanged
        try CORE_OnChanged.Call()
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

; ─── Starting the rest of MMA ─────────────────────────────────────────────────
;  The main window is also the thing that starts everything else, and that is not
;  a property of how it is DRAWN. Both shells call these, in this order.
;
;  Split in two because the two halves have to happen at opposite ends of a
;  shell's setup, and the reason is a real bug rather than tidiness — see below.

; The two children that own hotkeys. Called FIRST, before a shell builds anything.
;
;  Everything a shell does between here and showing its window is construction:
;  tabs, the variants window, the archive, the settings pages — or, for the
;  WebView, standing up Edge and waiting on CreateControllerAsync, which is
;  slower still. That is hundreds of milliseconds during which MMA is on screen,
;  or worse still painting, with every hotkey it owns dead. Ctrl+clicking a
;  Discord message in that gap does nothing at all, which is indistinguishable
;  from the import being broken, and it is exactly when you would do it: the
;  moment MMA comes up.
;
;  Neither script needs the window to exist — sequences.ahk only looks for it
;  when you actually import.
CORE_BootEarly() {
    LaunchEngine()
    LaunchSequences()
}

; Startup scripts and the background services.
;
; Called as soon as a shell has READ ITS SETTINGS, and — this is the part that
; matters — BEFORE it builds anything. It used to be the last thing either shell
; did, which was harmless in the Win32 window (its controls are up in
; milliseconds) and badly wrong in the WebView one: CreateControllerAsync blocks
; until the Edge runtime is up, measured at 60.8 SECONDS from launch to
; general.ahk starting. That is a minute of MMA apparently running with every
; hotstring dead, on every launch.
;
; So the rule is the same one CORE_BootEarly follows: nothing a user reaches for
; waits on a window being drawn.
CORE_BootServices() {
    ; auto-start configured startup scripts (defaults to general.ahk) if not already running
    LaunchStartupScripts()
    ; Every declared service that is switched on — see SVC_LaunchEnabled in
    ; core/processes.ahk.
    ;
    ; This was six hand-written lines, and it had six of the nine services:
    ; fanslyDetector, activity and autoword were absent, so none of them started at
    ; boot. They came up on the first WatchdogTick instead, five seconds later —
    ; and with startupScripts off, which is what Easy mode does, the watchdog
    ; returns early and they never started at all.
    ;
    ; FEAT is still consulted before the call rather than left to the launcher.
    ; It is read from the cfg key, not from the globals a shell loads, which are
    ; the same values one way and would drift the moment anything wrote them
    ; without assigning back.
    SVC_LaunchEnabled()
}

; The timers that need the WINDOW, so these do come last.
;
; RefreshToolsLabel writes a button's caption, and the unknown-model prompt opens
; a window owned by the shell's Gui — neither can run before there is one. Split
; from CORE_BootServices above for exactly that reason: everything that does NOT
; need the window now goes early, and only this waits.
CORE_BootWindowTasks() {
    global autoRestart, _askedNames, _unmapGui

    SetTimer(RefreshToolsLabel, -800)   ; after python has claimed the events

    if autoRestart
        SetTimer(WatchdogTick, 5000)

    ; Ask about model names the detector cannot place. In the GUI's process
    ; because this opens a window — ActiveModelStatus is also read from #HotIf as
    ; you type, and a dialog there would be one popup per keystroke.
    ;
    ; Both globals are assigned before the timer that reads them, not left to a
    ; top-level line somewhere below: the detector hit exactly that shape and
    ; threw "_wPos has not been assigned a value" on its first poll.
    _askedNames := Map()      ; names asked about this session, so we ask once
    _unmapGui   := 0          ; the prompt window, while it is open
    if FEAT("modelDetector")
        SetTimer(CheckUnmappedModel, 4000)
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The mass library — loading a model into the boxes, and writing it back
; ───────────────────────────────────────────────────────────────────────────────
;  The last of what both shells had written out twice, and the set where the two
;  copies had drifted furthest. Reconciled rather than picked: the Win32 text is
;  the base because it carries the reasoning, with the WebView's one real fix
;  folded in (see the StrLen(pfx) note in ParseCurrent — the Win32 copy stopped
;  clearing the boxes at ten models, and nobody had run into it yet).
;
;  Everything here talks to `edCtrls`, `edPaste` and `tabs` and to four functions
;  each shell defines its own way — SetMassNoRadio, RefreshModelHeader,
;  UpdateModelButtons and VarRefresh. Those stay per-shell on purpose: they move
;  controls, and that is the one thing this file does not do.
; ═══════════════════════════════════════════════════════════════════════════════

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

ClearAll(*) {
    global
    edPaste.Value := ""
    for _, c in edCtrls
        c.Value := ""
    CORE_Changed()
}

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
    CORE_Changed()
}

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
    ; The tab was moved in CODE, which fires no tab-change event in either shell —
    ; so the labels that name the model Load and Save act on have to be told. The
    ; WebView's own copy of this function called it and the Win32 copy did not,
    ; which is how the merged version nearly lost it: its Load/Save captions come
    ; from btnLoadOne.Text through WV_Sync, so loading a model you were not looking
    ; at left both buttons naming the PREVIOUS one.
    RefreshModelHeader()
    lblLoaded.Text := ModelNameForSlot(modelNo) " loaded (mass " slot ")"
    LOGI("gui.load", "loaded model " modelNo " (" fname ") mass slot " slot
                   . " into its tab")
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

; "2_mass.ahk" -> 2. Kept tolerant: a bare number works too.
ModelNoOf(fname) {
    n := Integer(RegExReplace(fname, "\D", ""))
    return (n >= 1 && n <= MASS_MODELS) ? n : 1
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
        ; StrLen(pfx), not 3. pfx is "m" mNo "_", so it is three characters
        ; only while mNo is one digit — at ten models "m10" was compared
        ; against "m10_", matched nothing, and Parse stopped clearing the
        ; old text out of the boxes before filling them.
        if SubStr(k, 1, StrLen(pfx)) = pfx
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
    CORE_Changed()
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

SaveCurrentTab(*) {
    global tabs
    _mNo := tabs.Value
    LOGD("gui.save", "Save (current tab) clicked while tab " _mNo " is in front")
    ApplyFile(MMA_ModelNames()[_mNo])
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
