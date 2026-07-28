#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "hotkeys.ahk"
#Include "../hotstrings/overloads.ahk"
; Model identity moved to its own file so the GUI can use it too — main_window
; must not include utils.ahk (hotstrings, send helpers), and calling these from
; there was a load-time error until they lived somewhere both could reach.
#Include "active_model.ahk"

SetKeyDelay(-1, -1)

; config
WaitTime     := 400
WaitTimeLong := 1500

; Which model the key that is currently firing belongs to. Declared HERE, not in
; mass/runtime.ahk, because sndFu below reads it and utils.ahk is also included by
; scripts that never load the mass engine (content\general.ahk, the account
; files) — an unset global would throw the moment one of them touched it.
;
; runtime.ahk's _SetCurModel is the only writer. This replaced `modelFileNo`,
; which MassInit(n) used to set once per process back when each model WAS a
; process; with one engine there is no per-process answer, only a per-keypress one.
global MASS_CUR_MODEL := 1


Afk := false
ClearInterval := 1000*30 ; 60s

global topChat := 300
; # Win
; ^ CTRL
; ! ALT
; + shift

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
; by a literal `n in a single field (see main_window.ahk's MassBlockProps).
;
; Whichever variant is chosen is sent through sndFu(), so alts obey the existing
; per-group rules (FuSingle, editable) exactly like the base does.

; The counts come from store.ahk (reached via active_model.ahk above), which owns
; the record shape. They used to be ALT_MAX_RT / BRANCH_MAX_RT here, under a
; comment reading "must match ALT_MAX in main_window.ahk" — one number written
; down three times, with nothing but that comment keeping them in step.
_activeBranch := Map()   ; massNo -> chosen branch index, per model process

_altStaged  := 0         ; index of the variant currently staged in the chatbox
_altVariants := []       ; [{parts, label, branch}, ...] while staging; [] when idle
_altGroup   := 0         ; 1/2/3, or 0 for the PPV (which pastes, never sends)
_altEditable := false
_altWin     := 0         ; window staging began in; the hotkeys are scoped to it
_altHotkeysOn := false

; Called with the chosen variant's branch number the moment a staged choice is
; committed. mass/runtime.ahk installs the real one; anything that includes
; utils.ahk without the engine (content\general.ahk, the account files) leaves it
; blank and the commit simply skips it. See AltStageCommit.
global ALT_ON_PICK := ""

; Splitting a stored alt field back into its parts is MASS_SplitParts() in
; store.ahk now — it is the record format, not a send-path detail.

; ── One list of ways to answer this follow-up ─────────────────────────────────
;  Alts and branches were two features with two keys and two pickers. They are one
;  question — "which wording goes out for f<N>?" — so they are one list and one
;  key now, and TAB walks the whole thing.
;
;  What actually differed was never worth a second button: an ALT is a different
;  wording of this one follow-up, a BRANCH is a different wording of this one
;  follow-up that also implies the next two. So the only thing the merge has to
;  keep is the implication, and that is what `branch` on each variant carries —
;  pick a branch variant at f1 and f2/f3/ppv start on that same branch.
;
;  Each variant is { parts, label, branch }:
;      parts   the messages to send, in order
;      label   what the staged list calls it ("main", "alt 1", or the --Name)
;      branch  0 for the trunk, else which branch it commits you to
AltVariants(m, group) {
    global MASS_ALT_MAX
    out := []
    base := []
    for _, sfx in ["", "_5", "_7"] {
        key := "fu" group sfx
        if m.HasOwnProp(key) && Trim(m.%key%) != ""
            base.Push(Trim(m.%key%))
    }
    if base.Length
        out.Push({ parts: base, label: "main", branch: 0 })
    Loop MASS_ALT_MAX {
        key := "fu" group "_alt" (A_Index - 1)
        if !m.HasOwnProp(key)
            continue
        parts := MASS_SplitParts(m.%key%)
        if parts.Length
            out.Push({ parts: parts, label: "alt " A_Index, branch: 0 })
    }
    ; The branches, as more variants of the same question. A branch with nothing
    ; in THIS group is skipped rather than shown empty — branches are commonly
    ; f1-only, and an empty row you can TAB onto and send is a way to send silence.
    for bi, b in BranchList(m) {
        if !b.fu[group].Length
            continue
        out.Push({ parts: b.fu[group], label: b.name, branch: bi })
    }
    return out
}

; The same question for the PPV: the trunk's ppv, then each branch's.
AltPpvVariants(m) {
    out := []
    if m.HasOwnProp("ppv_base") && Trim(m.ppv_base) != ""
        out.Push({ parts: [Trim(m.ppv_base)], label: "main", branch: 0 })
    for bi, b in BranchList(m) {
        if Trim(b.ppv) = ""
            continue
        out.Push({ parts: [Trim(b.ppv)], label: b.name, branch: bi })
    }
    return out
}

; ── Named branches (--Name) ───────────────────────────────────────────────────
; A branch is a whole alternate follow-up sequence sent after the shared trunk.
; These helpers are pure (take the mass object) so utils.ahk stays free of any
; CurMass/massNo dependency — the model files own the hotkey handlers.

; Non-empty branches on a mass: [{name, fu:[[p..],[p..],[p..]], ppv}].
BranchList(m) {
    global MASS_BRANCH_MAX
    out := []
    ; No branches means every branch key and window finds nothing to do, which is
    ; the pre-branch behaviour. Gating here rather than at each of the six call
    ; sites keeps the mass data itself untouched — switch branches back on and the
    ; --Name blocks are still there.
    if !FEAT("altFollowups")
        return out
    Loop MASS_BRANCH_MAX {
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
    return m.HasOwnProp(key) ? MASS_SplitParts(m.%key%) : []
}

; BranchSendGroup() and BranchSendPpv() stood here — the send half of the four
; branch keys. A branch variant goes out through SendAltVariant() like every other
; variant now, which is the point of the merge: one list, one picker, one path to
; the chatbox, so FuSingle and the editable toggles apply to a branch exactly as
; they always did to an alt.

; Send one already-chosen variant. Routed through the same two paths the base
; variant uses, so FuSingle / editable apply to alts identically.
;
; group 0 is the PPV, which has never had an Enter pressed for it — DoPpv pasted
; and left it to you. So 0 takes the paste path regardless of `editable`, or a
; staged PPV choice would send itself the moment you picked it.
SendAltVariant(group, parts, editable := false) {
    if (!editable && group > 0) {
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
    for i, v in _altVariants {
        mark := (i = _altStaged) ? mk " " : pad
        body := ""
        for _, p in v.parts
            body .= (body != "" ? psep : "") p
        ; The label earns its place now that branches are in this list: "main" and
        ; "alt 2" are obvious from position, but which --Name you are about to
        ; commit to is not, and committing to the wrong one silently redirects the
        ; next two follow-ups.
        out .= (out != "" ? vsep : "") mark (v.branch ? "[" v.label "] " : "") body
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
AltStageActive(*) {
    global _altVariants, _altWin
    return _altVariants.Length > 0 && _altWin && WinActive("ahk_id " _altWin)
}

; `startAt` is which variant the marker opens on. Not always 1: once you have
; picked a branch at f1, f2 opens on THAT branch, so walking a branch is press-
; Enter, press-Enter, press-Enter rather than TAB-hunting for the same --Name
; three times. TAB still reaches every other variant, so nothing is locked in.
AltStageBegin(group, variants, editable := false, startAt := 1) {
    global _altVariants, _altStaged, _altGroup, _altEditable, _altHotkeysOn
    global _altWin, ALT_STAGE_TIMEOUT_MS
    _altVariants := variants
    _altStaged   := (startAt >= 1 && startAt <= variants.Length) ? startAt : 1
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
    global _altVariants, _altStaged, _altGroup, _altEditable, ALT_ON_PICK
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    v     := _altVariants[_altStaged]
    grp   := _altGroup
    edit  := _altEditable
    ; clear the staged preview before sending, or the variants would be sent too
    Send "^a"
    Sleep 20
    Send "{Delete}"
    AltStageEnd()
    ; Tell the engine which branch this commits to, BEFORE sending — so if the send
    ; throws, the next follow-up still knows where the conversation went.
    ;
    ; A callback rather than a direct call: remembering a branch needs the mass
    ; document and the active model, which live in mass/runtime.ahk, and utils.ahk
    ; is also included by content\general.ahk and the account files, which never
    ; load the engine. Calling _BranchKey() from here would throw in those.
    if ALT_ON_PICK
        try ALT_ON_PICK.Call(v.branch)
    SendAltVariant(grp, v.parts, edit)
}

AltStageCancel(*) {
    Send "^a"
    Sleep 20
    Send "{Delete}"
    AltStageEnd()
}

; AltChooseGui() stood here — a modal window listing the variants, opened when a
; mass had "alt: gui" ticked, plus ArchiveDarkThemeRT() to theme it and
; AltChooserActive()/_altChooserHwnd to scope its 1-9 keys. It was the second way
; to answer the same question, and TAB staging is the one that got used: you read
; the variants in the chatbox, in the font and width they will actually send at,
; without a window taking focus off the chat. All of it is gone.
;
; The `altGui` field survives in the record (store.ahk) and its checkbox survives
; in the alt window; both are now inert. Left rather than migrated away because
; dropping a field rewrites every mass on next save, and this is not worth that.

; ── entry point used by the mass scripts ──────────────────────────────────────
; Returns true if the staging took over the send, false to fall through to the
; plain send.
;
; ONE KEY. There is no ctrl-variant to press and no "prompt using ctrl+hotkey"
; setting any more: if this follow-up can be answered more than one way, the key
; stages the choices and TAB walks them. If it cannot — no alts, no branches —
; the key sends, exactly as it always did, and the staging never appears.
;
; `activeBranch` is which branch an earlier follow-up in this conversation
; committed to, or 0. It only picks where the marker STARTS.
AltIntercept(m, group, editable := false, activeBranch := 0) {
    ; One gate for every caller. Returning false means "nothing intercepted", so
    ; the plain send runs exactly as it did before alts existed — which is what
    ; Easy mode is: a follow-up key that sends the follow-up, full stop.
    if !FEAT("altFollowups")
        return false
    variants := AltVariants(m, group)
    if variants.Length <= 1
        return false
    AltStageBegin(group, variants, editable, AltStartIndex(variants, activeBranch))
    return true
}

; The same, for the PPV. Separate entry point only because the PPV has no group
; number and pastes rather than sends; the list and the walk are identical.
AltInterceptPpv(m, editable := true, activeBranch := 0) {
    if !FEAT("altFollowups")
        return false
    variants := AltPpvVariants(m)
    if variants.Length <= 1
        return false
    AltStageBegin(0, variants, editable, AltStartIndex(variants, activeBranch))
    return true
}

; Which variant to open on: the one belonging to the branch already in play, or
; the first. Falls back to 1 when that branch has nothing in this group, which is
; the normal case for an f1-only branch reaching f2.
AltStartIndex(variants, activeBranch) {
    if !activeBranch
        return 1
    for i, v in variants
        if (v.branch = activeBranch)
            return i
    return 1
}

sndFu(group, parts*) {
    global waitTime, MASS_CUR_MODEL
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(p)
    if !nonEmpty.Length
        return
    ; FuSingle_<model>_<group>. The model number must be the one whose key was
    ; pressed — read from the wrong one and IniRead just returns its default, so
    ; the setting appears to do nothing and nothing says why.
    fuSingle := IniRead(MMA_CFG, "Settings",
                        "FuSingle_" MASS_CUR_MODEL "_" group, "0") = "1"
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

; MMA_CFG, not `HK_DIR "\mass_gui.cfg"`. HK_DIR is the REPO ROOT (hotkeys.ahk
; sets it there so HK_Broadcast can recognise our scripts by title), and no cfg
; has ever lived in the root — so this read every setting out of a file that does
; not exist and returned the default "ask" forever, exactly the silent revert
; paths.ahk was written to stop.
Overload_Mode() {
    return StrLower(Trim(IniRead(MMA_CFG, "Hotstrings", "OverloadMode", "ask")))
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
; Moved to crashlog.ahk so main_window.ahk can have it too without pulling in this
; file's hotstrings and send helpers.
#Include "crashlog.ahk"
