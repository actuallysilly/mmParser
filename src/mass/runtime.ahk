#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/runtime.ahk — what a mass DOES. Bound by engine.ahk, once, for all models.
; ───────────────────────────────────────────────────────────────────────────────
;  Follow-ups, alts, branches, PPV, the __mm triggers and the Settings toggles all
;  live here. The message text itself is DATA and lives in userdata\masses.json,
;  read through mass/store.ahk — see ARCHITECTURE.md §5.
;
;  This behaviour used to be copied into each of 1_mass.ahk / 2_mass.ahk /
;  3_mass.ahk, and the copies drifted: 1_mass honoured EditableFu / WalletCheckFu3
;  / OpenTabFu2-3 while models 2 and 3 silently passed `false`, so those Settings
;  checkboxes did nothing for them even though the GUI broadcast to all three.
;  Regenerating a model file also deleted its branch support, because the template
;  never emitted the alt and branch functions at all. One copy is what stops both.
;
;  Those three files were also three PROCESSES, which is the more expensive part:
;  they all bound the same physical keys, so five separate mechanisms existed just
;  to arbitrate between them (see utils.ahk's ActiveModelNo comment). One process
;  needs none of it.
;
;  Two ways in, and they never overlap (§5.1):
;      MassBindModel(n)  — [mass.<n>]      explicit per-model keys. Manual mode.
;      MassBindActive()  — [mass.active]   one key set, follows the detector.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "store.ahk"
#Include "../core/coords.ahk"
#Include "../core/utils.ahk"

; ── Settings mirrored from mass_gui.cfg ───────────────────────────────────────
; Read once at load, then kept live by the OnMessage handlers below — the GUI
; posts on toggle so you never have to restart a model script to change one.
mouseControl   := Integer(IniRead(MMA_CFG, "Settings", "MouseControl",   "1"))
openTabFu2     := Integer(IniRead(MMA_CFG, "Settings", "OpenTabFu2",     "0"))
openTabFu3     := Integer(IniRead(MMA_CFG, "Settings", "OpenTabFu3",     "0"))
openTabPpv     := Integer(IniRead(MMA_CFG, "Settings", "OpenTabPpv",     "0"))
walletCheckFu3 := Integer(IniRead(MMA_CFG, "Settings", "WalletCheckFu3", "0"))
editableFu1    := Integer(IniRead(MMA_CFG, "Settings", "EditableFu1",    "0"))
editableFu2    := Integer(IniRead(MMA_CFG, "Settings", "EditableFu2",    "0"))
editableFu3    := Integer(IniRead(MMA_CFG, "Settings", "EditableFu3",    "0"))

doubleMM := false

; ── Live settings messages from mass_gui ──────────────────────────────────────
; Message numbers are a contract with main_window.ahk: 0x8001 doubleMM, 0x8002
; WalletCheckFu3, 0x8003-0x8005 EditableFu1-3. _BroadcastEditableFu() there posts
; to every running model script; before this file only 1_mass.ahk listened.
ToggleDMMMsg(wParam, lParam, msg, hwnd) {
    global doubleMM
    doubleMM := !doubleMM
}
OnMessage(0x8001, ToggleDMMMsg)

SetWalletMsg(wParam, lParam, msg, hwnd) {
    global walletCheckFu3
    walletCheckFu3 := wParam
}
OnMessage(0x8002, SetWalletMsg)

SetEditableFuMsg(wParam, lParam, msg, hwnd) {
    global editableFu1, editableFu2, editableFu3
    fuIdx := msg - 0x8002   ; 0x8003→1, 0x8004→2, 0x8005→3
    if fuIdx = 1
        editableFu1 := wParam
    else if fuIdx = 2
        editableFu2 := wParam
    else if fuIdx = 3
        editableFu3 := wParam
}
OnMessage(0x8003, SetEditableFuMsg)
OnMessage(0x8004, SetEditableFuMsg)
OnMessage(0x8005, SetEditableFuMsg)

; ── Sending ───────────────────────────────────────────────────────────────────
; Pastes the whole group as ONE block and does not press Enter, so you can edit
; before it goes out. This is what the Editable / Wallet-check toggles switch to.
SndFuEditable(parts*) {
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(Trim(p))
    if !nonEmpty.Length
        return
    combined := ""
    for p in nonEmpty
        combined .= (combined != "" ? "`n" : "") p
    A_Clipboard := ""
    A_Clipboard := combined
    ClipWait(1)
    Send "^v"
}

; ── which model is firing ─────────────────────────────────────────────────────
; One process now serves all three models (ARCHITECTURE.md §5), so "the current
; model" is no longer a per-process constant — it is whichever model owns the key
; you just pressed. Every mass handler is bound through _ModelFire below, which
; sets it immediately before running the handler.
;
; MASS_CUR_MODEL itself is declared in core/utils.ahk, because sndFu there reads
; it too and utils is included by scripts that never load this file.

; Wrap a handler so it announces which model it belongs to. This is what lets
; mass.1.fu1 (F1) and mass.2.fu1 (F9) be two live keys in ONE process, with no
; gating and no 350ms timer — the key you press IS the model selector (§5.1).
_ModelFire(modelNo, fn) {
    return (*) => (_SetCurModel(modelNo), fn())
}
_SetCurModel(n) {
    global MASS_CUR_MODEL := n
}

; The mass currently selected, for the model currently firing. Alt handling needs
; the whole object, not one field, so the chooser can read every variant.
CurMass() {
    global MASS_DOC, MASS_CUR_MODEL
    return MASS_AsObject(MASS_Active(MASS_DOC, MASS_CUR_MODEL))
}

; One of the current model's three slots, as an object.
CurMassSlot(slot) {
    global MASS_DOC, MASS_CUR_MODEL
    return MASS_AsObject(MASS_Get(MASS_DOC, MASS_CUR_MODEL, slot))
}

; The key _activeBranch is remembered under. Includes the MODEL, not just the
; slot: with three models in one process, "mass 1" alone would let model 2's
; chosen branch overwrite model 1's.
_BranchKey() {
    global MASS_DOC, MASS_CUR_MODEL
    return MASS_CUR_MODEL "." MASS_MassNo(MASS_DOC, MASS_CUR_MODEL)
}

; One follow-up group. `group` is 1/2/3; `editable` is that group's toggle.
; Order matters: let an alt chooser intercept first, then the editable paste, then
; the plain send. doubleMM sends slots 1 and 2 back to back.
;
; No gate any more. The key that got here was bound to a specific model (or was
; resolved against the detector by _RunOnActiveModel), so by this point there is
; nothing left to second-guess.
_DoFuGroup(group, editable, openTab) {
    global doubleMM, openInNewTabButton
    ; Each extra is both a user setting and a feature; Easy mode drops all three
    ; back to "paste the follow-up and press Enter", which is all v1.4.0 did.
    editable := editable && FEAT("editableFu")
    openTab  := openTab  && FEAT("openTab")
    sendBoth := doubleMM && FEAT("doubleMM")
    if AltIntercept(CurMass(), group, false, editable)
        return
    m := CurMass()
    if editable {
        SndFuEditable(_FuParts(m, group)*)
        return
    }
    if sendBoth {
        sndFu(group, _FuParts(CurMassSlot(1), group)*)
        sndFu(group, _FuParts(CurMassSlot(2), group)*)
    } else {
        sndFu(group, _FuParts(m, group)*)
    }
    if openTab
        clickReturn(openInNewTabButton)
}

; The three fields that make up a follow-up group: fuN, fuN_5, fuN_7.
;
; Group 3 alone has a fallback: a mass with no f3 at all sends the DefaultFu3 text
; from Settings instead of nothing. Applied here rather than in sndFu because
; SndFuEditable takes the same parts and has no idea which group it is holding —
; one place covers the plain send, the editable/wallet paste, and both halves of
; a double-MM (so a second model with no f3 still gets the default).
_FuParts(m, group) {
    parts := [m.%"fu" group%, m.%"fu" group "_5"%, m.%"fu" group "_7"%]
    if (group != 3)
        return parts
    for p in parts
        if Trim(p) != ""
            return parts
    return DefaultFu3Parts()
}

; The fallback FU3, as one part per line. Stored in mass_gui.cfg with `n for a
; line break — an ini has no other way to hold one — which is the same escape the
; alt fields use, so AltPartsRT already knows how to read it. Each line goes out
; as its own message, exactly like the three f3 fields would have.
;
; Read per press rather than cached: editing it in Settings then takes effect
; without restarting the model scripts, the same trade sndFu makes for FuSingle.
DefaultFu3Parts() {
    if !FEAT("defaultFu3")
        return ["", "", ""]
    return AltPartsRT(IniRead(MMA_CFG, "Settings", "DefaultFu3", ""))
}

DoFu1() {
    global editableFu1
    _DoFuGroup(1, editableFu1, false)
}
DoFu2() {
    global editableFu2, openTabFu2
    _DoFuGroup(2, editableFu2, openTabFu2)
}
DoFu3() {
    global editableFu3, walletCheckFu3, openTabFu3
    _DoFuGroup(3, walletCheckFu3 || editableFu3, openTabFu3)
}

; The mass body itself — pastes only, so you can review before sending.
DoMass() {
    m := CurMass()
    if m.mass = ""
        return
    A_Clipboard := m.mass
    ClipWait(0.5)
    Send "^v"
}

; PPV base. Paste-only for the same reason as DoMass.
DoPpv() {
    global openTabPpv, openInNewTabButton
    m := CurMass()
    if m.ppv_base = ""
        return
    A_Clipboard := m.ppv_base
    ClipWait(0.1)
    Send "^v"
    if openTabPpv && FEAT("openTab")
        clickReturn(openInNewTabButton)
}

DoPpvFus() {
    m := CurMass()
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

; ── Alt follow-ups ────────────────────────────────────────────────────────────
; ctrl+<follow-up key>. Offers the alternatives; with nothing to choose between it
; just does what the plain key does, so the ctrl variant is never a dead key.
DoAltFu1() {
    global editableFu1
    if !AltIntercept(CurMass(), 1, true, editableFu1)
        DoFu1()
}
DoAltFu2() {
    global editableFu2
    if !AltIntercept(CurMass(), 2, true, editableFu2)
        DoFu2()
}
DoAltFu3() {
    global editableFu3, walletCheckFu3
    if !AltIntercept(CurMass(), 3, true, walletCheckFu3 || editableFu3)
        DoFu3()
}

; ── --Name branches ───────────────────────────────────────────────────────────
; The trunk (base fu1/fu2/fu3) sends on the normal keys. A branch is a continuation
; you switch to: pick one, then walk its follow-ups and ppv. The chosen branch is
; remembered per mass (_activeBranch) so fu2/fu3/ppv keep sending the same one.
DoBranchPick() {
    global _activeBranch
    brs := BranchList(CurMass())
    if !brs.Length
        return
    idx := 1
    if brs.Length > 1 {
        labels := []
        for b in brs
            labels.Push(b.name (b.fu[1].Length ? "  —  " b.fu[1][1] : ""))
        idx := Overload_Choose(labels)
        if !idx
            return
    }
    _activeBranch[_BranchKey()] := idx
    BranchSendGroup(brs[idx].fu[1])
}

BranchSendActiveGroup(g) {
    global _activeBranch
    brs := BranchList(CurMass())
    k   := _BranchKey()
    if _activeBranch.Has(k) && _activeBranch[k] <= brs.Length
        BranchSendGroup(brs[_activeBranch[k]].fu[g])
}

DoBranchFu2() {
    BranchSendActiveGroup(2)
}
DoBranchFu3() {
    BranchSendActiveGroup(3)
}
DoBranchPpv() {
    global _activeBranch
    brs := BranchList(CurMass())
    k   := _BranchKey()
    if _activeBranch.Has(k) && _activeBranch[k] <= brs.Length
        BranchSendPpv(brs[_activeBranch[k]].ppv)
}

; ── Wiring ────────────────────────────────────────────────────────────────────

; Every slot a mass section can declare, and what runs it.
;
; Several slots share a handler on purpose — that is what a key OVERLOAD is here.
; fu1short, mFu1 and fu1 are three ids for one action, so one action can carry a
; keyboard key, a mouse button and a Scimitar button at once without any of them
; knowing about the others. Add an id to hotkeys.ahk, add a line here, done.
MassSlotHandlers() {
    return Map(
        "fu1",      DoFu1,  "fu1short", DoFu1,  "mFu1", DoFu1,
        "fu2",      DoFu2,  "fu2short", DoFu2,  "mFu2", DoFu2,
        "fu3",      DoFu3,  "fu3short", DoFu3,  "mFu3", DoFu3,
        "ppv",      DoPpv,      "mPpv",    DoPpv,
        "ppvFus",   DoPpvFus,   "mPpvFus", DoPpvFus,
        "b1Ppv",    DoPpvFus,
        "mass",     DoMass,
        "altFu1",   DoAltFu1,
        "altFu2",   DoAltFu2,
        "altFu3",   DoAltFu3,
        "brPick",   DoBranchPick,
        "brFu2",    DoBranchFu2,
        "brFu3",    DoBranchFu3,
        "brPpv",    DoBranchPpv)
}

; Bind one model's EXPLICIT keys — [mass.<n>] in hotkeys.ini.
;
; This is the manual scheme (§5.1): F1-F3 is model 1, F9-F11 is model 2, and the
; key you press is what says which model you mean. Each handler is wrapped in
; _ModelFire so it knows which that is. No gate, no timer, and no detector: these
; keys work identically whether or not the screen detector is running, which is
; exactly what v1 could not do — there, fu1-fu3 were gated, so with the detector
; on and model 2 in front, model 1's F1 went dead.
;
; Only slots hotkeys.ahk actually declares get bound; a model with fewer keys is
; not an error, and checking first keeps error_log.txt free of noise.
MassBindModel(n) {
    global mouseControl
    for slot, fn in MassSlotHandlers() {
        id := "mass." n "." slot
        if HK_META.Has(id)
            HK_Bind(id, _ModelFire(n, fn))
    }

    _MassApplyMouseControl("mass." n)
}

; Mouse-control off means the mouse-button keys stay dark. Done after binding
; rather than by skipping the bind, so flipping the setting back on only needs a
; reload, not a rebind.
;
; Shared by both binders. It used to be inline in MassBindModel and named only
; mFu1-3, which is the shape of bug that keeps recurring here: a list of slots
; written out by hand in one of the two places that binds them, going stale the
; moment a slot is added. The list comes from the handler table now.
_MassApplyMouseControl(section) {
    global mouseControl
    if mouseControl
        return
    for slot in MassSlotHandlers() {
        if (SubStr(slot, 1, 1) != "m" || SubStr(slot, 1, 4) = "mass")
            continue                          ; mFu1-3, mPpv, mPpvFus — not "mass"
        id := section "." slot
        if HK_META.Has(id)
            HK_SetState(id, "Off")
    }
}

; Bind the SHARED keys — [mass.active] in hotkeys.ini.
;
; One key set that follows whichever model is on screen. These are the keys that
; used to be declared three times over (smFu1-3 = F13/F14/F15 in all of
; [mass.1], [mass.2] and [mass.3]) and then un-declared again 350ms at a time by
; StartFuGating, which existed solely because three PROCESSES could not otherwise
; share a key. One process needs none of that: bind once, and resolve the model
; at fire time.
;
; With no detector answer there is nothing to follow, so these do nothing rather
; than guess — the numbered manual keys are the answer in that case.
MassBindActive() {
    for slot, fn in MassSlotHandlers() {
        id := "mass.active." slot
        if HK_META.Has(id)
            HK_Bind(id, _ActiveFire(fn))
    }
    _MassApplyMouseControl("mass.active")
}

_ActiveFire(fn) {
    return (*) => _RunOnActiveModel(fn)
}
_RunOnActiveModel(fn) {
    n := ActiveModelNo()
    if !n
        return
    _SetCurModel(n)
    fn()
}

; ── picking the active model by hand ──────────────────────────────────────────
;  [mass.select] in hotkeys.ini. What the shared keys above follow when the screen
;  detector cannot be trusted — see the header of core/active_model.ahk.
;
;  Pressing one of these does TWO things: it records the model, and it switches
;  ModelMatch to "manual". Both, because either alone is a trap. Recording without
;  switching leaves the detector in charge, so the key visibly does nothing and
;  you find out by sending the wrong model's message. Switching without recording
;  would strand you on whatever was stored last.
MassBindSelect() {
    global MASS_MODELS
    HK_Bind("mass.select.next", SelectNextModel)
    Loop MASS_MODELS {
        id := "mass.select.m" A_Index
        if HK_META.Has(id)
            ; .Bind, NOT `(*) => SelectModel(n)`. A fat-arrow closure captures the
            ; enclosing function's local BY REFERENCE, and one function body means
            ; one `n` shared by all three lambdas — so every key would select the
            ; last model the loop saw. .Bind copies the value at bind time.
            HK_Bind(id, SelectModel.Bind(A_Index))
    }
}

SelectModel(n) {
    global MMA_CFG
    if !SetManualModel(n) {
        _MassToast("No model " n)
        return
    }

    ; ── the press also TEACHES positional mode ────────────────────────────────
    ; You are looking at a tab and telling MMA which model it is. That is exactly
    ; the observation positional mode needs and cannot make on its own, so record
    ; where the lit pill is while you are saying it. Two models = two presses, on
    ; the tabs you were going to click anyway, and auto-detection is calibrated.
    ;
    ; Only when the detector actually sees a pill (x >= 0), which it only does
    ; while Infloww is in front — so pressing the key at your IDE cannot overwrite
    ; a good position with a meaningless one.
    learned := false
    x := ReadActiveX()
    if (x >= 0)
        learned := LearnSlotX(n, x)

    mode := ModelMatchMode()
    if (mode = "position") {
        ; Already in positional mode: do not drop out of it just because you
        ; nudged the model by hand. Teaching is the point of the press here.
        ; Two reasons x can be < 0, and the message must not pick one: Infloww is
        ; not the active window, or it is and the scan found no pill (colours or
        ; region wrong). Settings' live readout distinguishes them; a toast that
        ; guessed would send you to fix the wrong thing.
        _MassToast(learned ? "Learned: " ModelLabel(n) " is at x " x
                           : "Active model: " ModelLabel(n)
                             "`n(no tab detected — position NOT learned)")
        return
    }
    ; Any other mode becomes manual, because a key labelled "active model = 2"
    ; that left the detector in charge would be lying about what it does.
    if (mode != "manual")
        IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
    _MassToast("Active model: " ModelLabel(n)
             . (learned ? "`n(position x " x " learned)" : ""))
}

; Cycles over the models you actually have, not all MASS_MODELS: with ModelCount
; at 2 a third stop would be a slot with no name and no mass, and you would find
; that out by pressing a follow-up key into a fan's chat.
SelectNextModel(*) {
    global MMA_CFG, MASS_MODELS
    count := _IniInt(MMA_CFG, "Settings", "ModelCount", MASS_MODELS)
    if (count < 1 || count > MASS_MODELS)
        count := MASS_MODELS
    SelectModel(Mod(ManualModelNo(), count) + 1)
}

; The confirmation. In manual mode this toast is the only thing standing between
; "I switched tabs" and "I sent the other model's message to this fan", so it is
; deliberately near the cursor and deliberately not silent-on-repeat.
_MassToast(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1400)
}

; ── the "send the whole mass" triggers ────────────────────────────────────────
;  __mm   — paste the ACTIVE model's mass. Only meaningful when the detector is
;           running to say which model that is, so UniversalSendActive() returns
;           false outright in manual mode and this trigger simply does not expand.
;  __mm1  — paste MODEL n's mass, named explicitly. This is the MANUAL-mode form:
;  __mm2    the number selects the model because you said so, exactly like the
;  __mm3    manual F-keys, where the key you press is the selector.
;
;  Never both at once — see NumberedSendActive in utils.ahk for why the `*` in
;  :*X:__mm:: makes that a structural guarantee rather than a policy. Also
;  ARCHITECTURE.md §5.2.
#HotIf UniversalSendActive()
:*X:__mm::_RunOnActiveModel(DoMass)
#HotIf

#HotIf NumberedSendActive(1)
:*X:__mm1::(_SetCurModel(1), DoMass())
#HotIf
#HotIf NumberedSendActive(2)
:*X:__mm2::(_SetCurModel(2), DoMass())
#HotIf
#HotIf NumberedSendActive(3)
:*X:__mm3::(_SetCurModel(3), DoMass())
#HotIf
