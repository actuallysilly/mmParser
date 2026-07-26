#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "hotkeys.ahk"
#Include "hotstring_overloads.ahk"

SetKeyDelay(-1, -1)

; config
WaitTime     := 400
WaitTimeLong := 1500
modelFileNo  := 0


Afk := false
ClearInterval := 1000*30 ; 60s

global topChat := 300
; # Win
; ^ CTRL
; ! ALT
; + shift

; ── active-model gating (driven by the screen detector) ───────────────────────
; The detector writes the focused model's name to detector_status.ini. Each mass
; script runs one model, so its follow-up hotkeys should only fire when ITS model
; is the active tab — letting every model share the same 3 hotkeys.
ReadActiveModel() {
    return Trim(IniRead(MMA_DETECTOR, "detector", "active_model", ""))
}

; True if THIS model file is the one currently focused on screen.
;  - detector off / no active model  -> true (gating disabled, normal behaviour)
;  - this slot named                  -> true only when active model == this slot's name
;  - this slot unnamed                -> the lowest-numbered unnamed slot AUTO-CLAIMS the
;                                        active model (once), so scripts self-wire on first use
ModelIsActive() {
    global modelFileNo
    active := ReadActiveModel()
    if (active = "")
        return true
    cfg := MMA_CFG
    myName := Trim(IniRead(cfg, "ActiveMap", "File" modelFileNo, ""))
    if (myName != "")
        return (StrLower(active) = StrLower(myName))
    lowestUnnamed := 0
    Loop 9 {
        nm := Trim(IniRead(cfg, "ActiveMap", "File" A_Index, ""))
        if (StrLower(nm) = StrLower(active))
            return false                 ; already claimed by another slot -> not me
        if (nm = "" && lowestUnnamed = 0)
            lowestUnnamed := A_Index
    }
    if (lowestUnnamed != modelFileNo)
        return false
    IniWrite(active, cfg, "ActiveMap", "File" modelFileNo)   ; auto-name this slot
    return true
}

; in-handler safety for model-specific sends bound to non-shared keys
FuGate() => ModelIsActive()

; Which single script answers the universal "send the whole mass" trigger (__mm).
; Detector ON  -> only the active model's script (so __mm follows the focused tab).
; Detector OFF -> only model 1, preserving the original single-script behaviour.
; Gating __mm this way guarantees exactly ONE process ever fires it — otherwise all
; three would expand the hotstring at once and triple-backspace the typed trigger.
UniversalSendActive() {
    global modelFileNo
    if (ReadActiveModel() = "")
        return (modelFileNo = 1)
    return ModelIsActive()
}

; Register this model's SHARED send hotkeys only while its model is active, so
; several model scripts can share the same keys (only one is registered at a time).
; Takes hotkey IDS, not keys: a hard-coded key list stops matching the moment
; someone rebinds it in hotkeys.ini, which is how F13-F15 ended up firing in every
; model script at once. Call once after the keys are bound:
;     StartFuGating(HK_ModelSendIds(modelFileNo))
_gatedIds := []
StartFuGating(ids) {
    global _gatedIds := ids
    SetTimer(UpdateFuGating, 350)
    UpdateFuGating()
}
UpdateFuGating() {
    global _gatedIds
    state := ModelIsActive() ? "On" : "Off"
    for id in _gatedIds
        HK_SetState(id, state)
}

Snd(arg){
    if (arg = "")
        return
    A_Clipboard := ""
    A_Clipboard := arg
    ClipWait(1)
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

; you can also provide a time in milliseconds
Sendt(arg,time){
    if (arg = "")
        return
    A_Clipboard := arg
    ClipWait(0.1)
    Send("^v")
    Send("{Enter}")
    Sleep(time)
}



; ── Alt follow-ups ────────────────────────────────────────────────────────────
; A follow-up may carry alternative wordings of itself. The base variant is
; fu<N>/fu<N>_5/fu<N>_7; each alt is one more complete variant, its parts joined
; by a literal `n in a single field (see mass_gui.ahk's MassBlockProps).
;
; Whichever variant is chosen is sent through sndFu(), so alts obey the existing
; per-group rules (FuSingle, editable) exactly like the base does.

ALT_MAX_RT := 3          ; must match ALT_MAX in mass_gui.ahk
BRANCH_MAX_RT := 3       ; must match BRANCH_MAX in mass_gui.ahk
_activeBranch := Map()   ; massNo -> chosen branch index, per model process

_altStaged  := 0         ; index of the variant currently staged in the chatbox
_altVariants := []       ; [[part, ...], ...] while staging; empty when idle
_altGroup   := 0
_altEditable := false
_altWin     := 0         ; window staging began in; the hotkeys are scoped to it
_altChooserHwnd := 0     ; the GUI chooser, while open; scopes its number keys
_altHotkeysOn := false

; Split a stored alt field back into its parts.
AltPartsRT(stored) {
    parts := []
    for _, p in StrSplit(StrReplace(StrReplace(stored, "`r`n", "`n"), "``n", "`n"), "`n")
        if Trim(p) != ""
            parts.Push(Trim(p))
    return parts
}

; All variants for one follow-up: variant 1 is the base, then each non-empty alt.
; `m` is the mass object, group is 1..3.
AltVariants(m, group) {
    global ALT_MAX_RT
    out := []
    base := []
    for _, sfx in ["", "_5", "_7"] {
        key := "fu" group sfx
        if m.HasOwnProp(key) && Trim(m.%key%) != ""
            base.Push(Trim(m.%key%))
    }
    if base.Length
        out.Push(base)
    Loop ALT_MAX_RT {
        key := "fu" group "_alt" (A_Index - 1)
        if !m.HasOwnProp(key)
            continue
        parts := AltPartsRT(m.%key%)
        if parts.Length
            out.Push(parts)
    }
    return out
}

MassUsesAltGui(m) {
    return m.HasOwnProp("altGui") && Trim(m.altGui) = "1"
}

; ── Named branches (--Name) ───────────────────────────────────────────────────
; A branch is a whole alternate follow-up sequence sent after the shared trunk.
; These helpers are pure (take the mass object) so utils.ahk stays free of any
; CurMass/massNo dependency — the model files own the hotkey handlers.

; Non-empty branches on a mass: [{name, fu:[[p..],[p..],[p..]], ppv}].
BranchList(m) {
    global BRANCH_MAX_RT
    out := []
    ; No branches means every branch key and window finds nothing to do, which is
    ; the pre-branch behaviour. Gating here rather than at each of the six call
    ; sites keeps the mass data itself untouched — switch branches back on and the
    ; --Name blocks are still there.
    if !FEAT("altFollowups")
        return out
    Loop BRANCH_MAX_RT {
        k  := A_Index
        f1 := "br" k "_fu1", f2 := "br" k "_fu2", f3 := "br" k "_fu3", pk := "br" k "_ppv"
        got := false
        for _, key in [f1, f2, f3, pk]
            if m.HasOwnProp(key) && Trim(m.%key%) != ""
                got := true
        if !got
            continue
        nk := "br" k "_name"
        nm := (m.HasOwnProp(nk) && Trim(m.%nk%) != "") ? Trim(m.%nk%) : "branch " k
        out.Push({ name: nm,
                   fu:   [BranchParts(m, f1), BranchParts(m, f2), BranchParts(m, f3)],
                   ppv:  (m.HasOwnProp(pk) ? Trim(m.%pk%) : "") })
    }
    return out
}
BranchParts(m, key) {
    return m.HasOwnProp(key) ? AltPartsRT(m.%key%) : []
}

; Send one branch follow-up group: each part is its own back-to-back message.
BranchSendGroup(parts) {
    for p in parts
        if Trim(p) != ""
            snd(p)
}

; Paste a branch's ppv base (review-before-send, like DoF4's ppv behaviour).
BranchSendPpv(ppv) {
    if Trim(ppv) = ""
        return
    A_Clipboard := ppv
    ClipWait(0.1)
    Send "^v"
}

; Send one already-chosen variant. Routed through the same two paths the base
; variant uses, so FuSingle / editable apply to alts identically.
SendAltVariant(group, parts, editable := false) {
    if !editable {
        sndFu(group, parts*)
        return
    }
    combined := ""
    for _, p in parts
        if Trim(p) != ""
            combined .= (combined != "" ? "`n" : "") Trim(p)
    if combined = ""
        return
    A_Clipboard := ""
    A_Clipboard := combined
    ClipWait(1)
    Send "^v"                      ; paste only — editable means you review first
}

; ── TAB staging ───────────────────────────────────────────────────────────────
; Paste every variant into the chatbox with a marker on the current one, so they
; can be read and compared in place. TAB moves the marker, Enter sends the marked
; variant (the box is cleared first — what gets sent goes through sndFu, so a
; multi-part variant still sends as separate messages), Esc cancels.

; Staging separators live in mass_gui.cfg [Settings], not here:
;   AltStageVariantSep   between variants               default \n\n (a blank line)
;   AltStagePartSep      between parts of one variant   default \s\s/\s\s
;   AltStageMarker       marks the staged variant       default a filled triangle
;
; Escapes: \n newline, \t tab, \s SPACE. \s is not decoration — Windows strips
; leading and trailing whitespace when reading an ini, so a literal "  /  " comes
; back as "/" and the separator silently loses its padding.
;
; Read per call — like sndFu reads FuSingle — so an edit applies without a restart.
ALT_SEP_UNSET := Chr(1) "«unset»"

AltDecodeEscapes(s) {
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\s", " ")
    return s
}

; Seeded into the cfg on first read so the keys are discoverable by opening the
; file, rather than being invisible defaults buried in code.
AltStageSetting(key, fallback) {
    global ALT_SEP_UNSET
    cfg := MMA_CFG
    v := IniRead(cfg, "Settings", key, ALT_SEP_UNSET)
    if (v == ALT_SEP_UNSET) {
        try IniWrite(fallback, cfg, "Settings", key)
        v := fallback
    }
    return AltDecodeEscapes(v)
}

AltStageText() {
    global _altVariants, _altStaged
    vsep := AltStageSetting("AltStageVariantSep", "\n\n")
    psep := AltStageSetting("AltStagePartSep",    "\s\s/\s\s")
    mk   := AltStageSetting("AltStageMarker",     Chr(0x25B8))
    pad  := ""
    Loop StrLen(mk) + 1
        pad .= " "
    out := ""
    for i, parts in _altVariants {
        mark := (i = _altStaged) ? mk " " : pad
        body := ""
        for _, p in parts
            body .= (body != "" ? psep : "") p
        out .= (out != "" ? vsep : "") mark body
    }
    return out
}

AltPaintStage() {
    A_Clipboard := ""
    A_Clipboard := AltStageText()
    ClipWait(1)
    Send "^a"
    Sleep 20
    Send "^v"
}

; Tab/Enter/Escape are hijacked while a choice is staged, so they must be scoped
; hard. Two guards: HotIf restricts them to the window staging began in AND to
; the staged state, and a timeout cancels a forgotten staging. Without these a
; stray Enter hook would swallow Enter in every application on the machine.
ALT_STAGE_TIMEOUT_MS := 45000

; The (*) is required, not stylistic: HotIf calls its criterion with the hotkey
; name, and a zero-parameter function is rejected with "Invalid callback function."
; That is why hotkeys.ahk declares every context as (*) => ... too.
AltChooserActive(*) {
    global _altChooserHwnd
    return _altChooserHwnd && WinActive("ahk_id " _altChooserHwnd)
}

AltStageActive(*) {
    global _altVariants, _altWin
    return _altVariants.Length > 0 && _altWin && WinActive("ahk_id " _altWin)
}

AltStageBegin(group, variants, editable := false) {
    global _altVariants, _altStaged, _altGroup, _altEditable, _altHotkeysOn
    global _altWin, ALT_STAGE_TIMEOUT_MS
    _altVariants := variants
    _altStaged   := 1
    _altGroup    := group
    _altEditable := editable
    _altWin      := WinExist("A")
    AltPaintStage()
    if !_altHotkeysOn {
        HotIf AltStageActive
        Hotkey "*Tab",    AltStageNext,   "On"
        Hotkey "*Enter",  AltStageCommit, "On"
        Hotkey "*Escape", AltStageCancel, "On"
        HotIf
        _altHotkeysOn := true
    }
    SetTimer(AltStageTimeout, -ALT_STAGE_TIMEOUT_MS)
}

; Give up rather than leave the keys claimed. The staged text is left in the box
; — it is the user's chat window, so silently wiping it would be worse.
AltStageTimeout() {
    global _altVariants
    if _altVariants.Length
        AltStageEnd()
}

AltStageEnd() {
    global _altVariants, _altStaged, _altGroup, _altWin, _altHotkeysOn
    SetTimer(AltStageTimeout, 0)
    if _altHotkeysOn {
        HotIf AltStageActive
        Hotkey "*Tab",    "Off"
        Hotkey "*Enter",  "Off"
        Hotkey "*Escape", "Off"
        HotIf
        _altHotkeysOn := false
    }
    _altVariants := []
    _altStaged := 0
    _altGroup := 0
    _altWin := 0
}

AltStageNext(*) {
    global _altVariants, _altStaged
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    _altStaged := Mod(_altStaged, _altVariants.Length) + 1
    AltPaintStage()
}

AltStageCommit(*) {
    global _altVariants, _altStaged, _altGroup, _altEditable
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    parts := _altVariants[_altStaged]
    grp   := _altGroup
    edit  := _altEditable
    ; clear the staged preview before sending, or the variants would be sent too
    Send "^a"
    Sleep 20
    Send "{Delete}"
    AltStageEnd()
    SendAltVariant(grp, parts, edit)
}

AltStageCancel(*) {
    Send "^a"
    Sleep 20
    Send "{Delete}"
    AltStageEnd()
}

; ── GUI chooser ───────────────────────────────────────────────────────────────
; Per-mass opt-in (the "alt: gui" toggle). Modal, word-wrapped so long variants
; stay readable; 1..9 / click / Enter pick, Esc cancels.

AltChooseGui(group, variants, editable := false) {
    global _altChooserHwnd
    static BG := "15141C", SURFACE := "201E2B", TXT := "E6E4EE"
    static MUTED := "8E8AA6", ACCENT := "B89CFF"

    chosen := 0
    cg := Gui("+AlwaysOnTop +ToolWindow", "Choose follow-up")
    cg.BackColor := BG
    cg.MarginX := 0
    cg.MarginY := 0

    cg.SetFont("s13 Bold c" ACCENT, "Segoe UI")
    cg.Add("Text", "x18 y14 w520", Chr(0x2726) "  FU" group " — pick a variant")
    cg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    cg.Add("Text", "x18 y42 w520", "Click one, or press its number. Esc cancels.")

    y := 70
    for i, parts in variants {
        body := ""
        for _, p in parts
            body .= (body != "" ? "`r`n" : "") p
        label := (i = 1) ? "main" : "alt" (i - 2)

        ; height grows with the text so nothing is clipped; wraps rather than scrolls
        lines := 0
        for _, p in parts
            lines += Max(1, Ceil(StrLen(p) / 58))
        h := Max(30, lines * 19 + 8)

        ; A button is what picks. The text sits in a ReadOnly Edit purely so it
        ; wraps — an Edit must NOT drive the choice: it fires Focus as soon as the
        ; window opens, which auto-picked the first variant and sent it instantly.
        cg.SetFont("s9 Bold c" TXT, "Segoe UI")
        btn := cg.Add("Button", "x18 y" y " w30 h26", i)
        btn.OnEvent("Click", MakePick(i))
        cg.SetFont("s8 Norm c" MUTED, "Segoe UI")
        cg.Add("Text", "x52 y" (y + 6) " w46", label)
        cg.SetFont("s10 Norm c" TXT, "Segoe UI")
        cg.Add("Edit", "x104 y" y " w432 h" h " ReadOnly -VScroll Multi Background" SURFACE, body)

        y += Max(h, 30) + 10
    }

    cg.SetFont("s9 c" TXT, "Segoe UI")
    cg.Add("Button", "x18 y" (y + 4) " w90 h28", "Cancel").OnEvent("Click", DoCancel)
    ArchiveDarkThemeRT(cg)

    ; Esc and the window's X are Gui events, so they need no global hotkey at all.
    cg.OnEvent("Escape", DoCancel)
    cg.OnEvent("Close",  DoCancel)

    ; The number keys DO need real hotkeys — scoped to this window, or 1-9 would
    ; be swallowed in every application for as long as the chooser is open.
    _altChooserHwnd := cg.Hwnd
    HotIf AltChooserActive
    Loop variants.Length
        Hotkey "*" A_Index, MakePick(A_Index), "On"
    HotIf

    cg.Show("w560 h" (y + 46))
    WinWaitClose("ahk_id " cg.Hwnd)

    HotIf AltChooserActive
    Loop variants.Length
        Hotkey "*" A_Index, "Off"
    HotIf
    _altChooserHwnd := 0

    if chosen
        SendAltVariant(group, variants[chosen], editable)
    return

    MakePick(i) {
        return Pick.Bind(i)
    }
    Pick(i, *) {
        chosen := i
        cg.Destroy()
    }
    DoCancel(*) {
        chosen := 0
        cg.Destroy()
    }
}

; Local copy of the dark-theme call (mass_gui.ahk has its own; the mass scripts
; do not include that file).
ArchiveDarkThemeRT(guiObj) {
    for attr in [20, 19]
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", guiObj.Hwnd, "int", attr, "int*", 1, "int", 4)
}

; ── entry point used by the mass scripts ──────────────────────────────────────
; Returns true if the chooser took over the send, false to fall through to the
; normal base-variant send.
;
;   viaCtrl=false  the plain follow-up key (F1). Only intercepts when the
;                  "prompt using ctrl+hotkey" setting is OFF.
;   viaCtrl=true   the ctrl+follow-up key. Always offers the choice; the caller
;                  falls back to a normal send when there is nothing to choose.
;
; Read per call like sndFu reads FuSingle, so toggling the setting applies
; immediately without restarting the mass scripts.
AltIntercept(m, group, viaCtrl := false, editable := false) {
    ; One gate for every caller. Returning false means "nothing intercepted", so
    ; the plain send runs exactly as it did before alts existed — which is what
    ; Easy mode is: a follow-up key that sends the follow-up, full stop.
    if !FEAT("altFollowups")
        return false
    if !viaCtrl {
        promptCtrl := IniRead(MMA_CFG, "Settings", "PromptAltCtrl", "1") = "1"
        if promptCtrl
            return false
    }
    variants := AltVariants(m, group)
    if variants.Length <= 1
        return false
    if MassUsesAltGui(m)
        AltChooseGui(group, variants, editable)
    else
        AltStageBegin(group, variants, editable)
    return true
}

sndFu(group, parts*) {
    global waitTime, modelFileNo
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(p)
    if !nonEmpty.Length
        return
    fuSingle := IniRead(MMA_CFG, "Settings", "FuSingle_" modelFileNo "_" group, "0") = "1"
    if !fuSingle {
        for p in nonEmpty
            snd(p)
        return
    }
    combined := ""
    for p in nonEmpty
        combined .= (combined != "" ? "`n" : "") p
    A_Clipboard := ""
    A_Clipboard := combined
    ClipWait(1)
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

; ── message overloading ───────────────────────────────────────────────────────
; A few hotstrings send ONE OF several variants instead of a fixed message. The
; owning script hands its variants to Overload_Run; this layer only decides WHICH
; one goes out and sends it:
;     "random" → pick one at random, no prompt
;     "ask"    → a small chooser pops up (click a row, or press 1-9; Esc cancels)
; Mode lives in mass_gui.cfg [Hotstrings] OverloadMode (default "ask"), editable
; from the Hotstrings manager. A "variant" is an array of steps, each {fn, text}
; — the same shape the manager reads from source (fn "snd" = sends + Enter,
; "SendText" = pastes only). See the hotstring-manager notes.

Overload_Mode() {
    global HK_DIR
    return StrLower(Trim(IniRead(HK_DIR "\mass_gui.cfg", "Hotstrings", "OverloadMode", "ask")))
}

; Entry point an overloaded hotstring calls. `mode` is that trigger's own "ask" or
; "random" (each overload carries its own); blank falls back to the global default.
Overload_Run(variants, mode := "") {
    if !variants.Length
        return
    labels := []
    for v in variants
        labels.Push(Overload_Label(v))
    idx := Overload_Pick(labels, mode)
    if (idx >= 1 && idx <= variants.Length)
        Overload_Send(variants[idx])
}

; Which variant (1-based)? 0 = none/cancelled. `mode` blank → read the setting;
; passed explicitly only so it's testable without touching the cfg.
Overload_Pick(labels, mode := "") {
    n := labels.Length
    if (n <= 1)
        return n
    if (mode = "")
        mode := Overload_Mode()
    if (mode = "random")
        return Random(1, n)
    return Overload_Choose(labels)
}

Overload_Send(steps) {
    for st in steps {
        if (StrLower(st.fn) = "sendtext")
            SendText(st.text)
        else
            snd(st.text)
    }
}

; One-line preview of a variant, for the chooser rows.
Overload_Label(steps) {
    s := ""
    for st in steps
        s .= (s = "" ? "" : "   /   ") st.text
    return SubStr(StrReplace(StrReplace(s, "`r", " "), "`n", " "), 1, 72)
}

; Re-point THIS script's overloaded triggers at the engine. Runs once at load (see
; the call below), so no message file ever needs a registration line added: each
; script picks up only the overloads whose owning file matches its own name, and a
; runtime Hotstring() replaces the statically defined trigger.
Overload_Register() {
    for trg, e in OL_Load() {
        if (StrLower(OL_BaseName(e.file)) != StrLower(A_ScriptName))
            continue
        try Hotstring(":" e.options ":" trg, Overload_Handler.Bind(e))
    }
}

Overload_Handler(entry, *) {
    Overload_Run(entry.variants, entry.mode)
}

; Blocking chooser. Returns the picked index (1-based) or 0 if cancelled.
Overload_Choose(labels) {
    picked := 0
    cg := Gui("+AlwaysOnTop +ToolWindow +Owner", "Pick a variant")
    cg.BackColor := "1B1A24"
    cg.SetFont("s10 cE6E4EE", "Segoe UI")
    cg.MarginX := 14, cg.MarginY := 12
    for i, lab in labels {
        opt := (i = 1) ? "w560 h34" : "w560 h34 y+8"
        btn := cg.Add("Button", opt, i "     " lab)
        btn.OnEvent("Click", PickThis.Bind(i))
    }
    cg.OnEvent("Escape", PickNone)
    cg.OnEvent("Close",  PickNone)
    cg.Show()
    WinWaitClose("ahk_id " cg.Hwnd)
    return picked

    PickThis(i, *) {
        picked := i
        cg.Destroy()
    }
    PickNone(*) {
        picked := 0
        cg.Destroy()
    }
}

; Wire up whatever overloads this script owns (a no-op for scripts that own none).
Overload_Register()

Unread() {
    MouseGetPos &cx, &cy
    CoordMode "Mouse", "Screen"
    MouseClickDrag "Left", cx, cy, cx - 300, cy, 5
    MouseMove cx - 50, cy + 60, 0
}



; AFK

CoordMode "Mouse", "Window"

; Bound once, by 1_mass.ahk. It used to be a bare ^p:: here in utils.ahk, which
; every including script re-registered — so one press fired it once per running
; script.
AfkClick() {
    MouseMove 347, 208, 0
    Click
    Sleep(200)
    MouseMove 231, 352, 0
    Sleep(50)
    Click
}

GoAfk(){
    
    while(afk){
        MouseMove 347, 208, 0
        Click
        Sleep(200)
        MouseMove 231, 352, 0
        Sleep(50)
        Click
        Sleep(50)
        MouseMove 711, 481, 0
        Sleep(clearInterval)
    }
}

::_afk::{

   global afk
   afk := true
   goAfk()
}

::_offafk::{
    global afk
    afk := false
}

SetTimer(CheckAFK, 1000) ; cheque every 1 second

CheckAFK() {
    static afkTriggered := false  ; persistent state (like a private field)

    if (A_TimeIdle > 60000) {      ; 60,000 ms = 1 minute
        if (!afkTriggered) {
            afkTriggered := true
            goAfk()
        }
    } else {
        afkTriggered := false      ; reset when user becomes active again
    }
}

; Finds the nth occurrence of a color in a screen area.
; Returns [x, y] or false if fewer than n matches found.
; groupSkip: pixels to advance after each match — set > icon width to treat each icon as one hit
FindNthColor(n, color, x1, y1, x2, y2, variation := 10, groupSkip := 1) {
    CoordMode "Pixel", "Screen"
    sx := x1, sy := y1
    loop n {
        if !PixelSearch(&px, &py, sx, sy, x2, y2, color, variation)
            return false
        sx := px + groupSkip
        sy := py
        if sx > x2 {
            sx := x1
            sy := py + 1
            if sy > y2
                return false
        }
    }
    return [px, py]
}

clickOn(coord){
    MouseMove coord[1], coord[2]
    Click
}

; Like clickOn, but INSTANT (speed 0 — no drag animation) and it snaps the cursor
; back where it started afterwards. For side-effect clicks on a fixed-coord button
; (e.g. "open in new tab") that shouldn't yank your mouse away from what you're
; doing. Save/restore use the thread's current CoordMode, which is consistent here
; because the click keeps the same window active.
clickReturn(coord){
    MouseGetPos &sx, &sy
    MouseMove coord[1], coord[2], 0
    Click
    MouseMove sx, sy, 0
}

_lastTyped := ""

RecoverLastMsg() {
    global _lastTyped
    if _lastTyped = ""
        return
    focusTextbox()
    Sleep 80
    A_Clipboard := _lastTyped
    Send "^v"
}

focusTextbox(){
    MouseMove 800, 950
    Click
}

focusTop(){
    MouseMove 220,315
    Click
}

_savedChatX := 220
_savedChatY := 315

focusAuto(){
    global _savedChatX, _savedChatY, topChat
    MouseGetPos &mx, &my
    if (mx < 400) {
        _savedChatX := mx
        _savedChatY := my
        focusTextbox()
    } else {
        clickOn(topChat)
        if (_savedChatY > 900)
            Send "{WheelDown 4}"
    }
}

nextChat(){
   MouseGetPos &cx, &cy
   MouseMove cx, cy + 100
   MouseClick
}

; ─── Crash logging ────────────────────────────────────────────────────────────
; Moved to crashlog.ahk so mass_gui.ahk can have it too without pulling in this
; file's hotstrings and send helpers.
#Include "crashlog.ahk"
