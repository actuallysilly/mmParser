#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/runtime.ahk — everything a model script DOES, shared by all of them.
; ───────────────────────────────────────────────────────────────────────────────
;  A model script (1_mass.ahk, 2_mass.ahk, …) is DATA: three `mN := {...}` blocks
;  holding the message text, and nothing else. All the behaviour — follow-ups,
;  alts, branches, PPV, the settings toggles — lives here, once.
;
;  It used to live in each model file, copied. The copies drifted: 1_mass.ahk
;  honoured EditableFu / WalletCheckFu3 / OpenTabFu2-3 and models 2-3 silently
;  passed `false` instead, so those Settings checkboxes did nothing for them even
;  though the GUI broadcast to all three. BuildMassTemplate never emitted the alt
;  and branch functions at all, so regenerating a model file deleted its branch
;  support. One copy here is what stops both.
;
;  A model script only needs:
;      #Include "../../src/mass/runtime.ahk"
;      … the mN data blocks …
;      MassInit(<this file's number>)
;
;  MassInit binds only the slots hotkeys.ahk actually declares for that model, so
;  a model with fewer keys (2 and 3 have no mouse/short variants) is not an error.
; ═══════════════════════════════════════════════════════════════════════════════

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

; The mass currently selected by massNo. Alt handling needs the whole object, not
; one field, so the chooser can read every variant of a group.
CurMass() {
    global massNo, m1, m2, m3
    return massNo = 1 ? m1 : massNo = 2 ? m2 : m3
}

; One follow-up group. `group` is 1/2/3; `editable` is that group's toggle.
; Order matters: gate first, then let an alt chooser intercept, then the editable
; paste, then the plain send. doubleMM sends slots 1 and 2 back to back.
_DoFuGroup(group, editable, openTab) {
    global massNo, m1, m2, m3, doubleMM, openInNewTabButton
    if !FuGate()
        return
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
        sndFu(group, _FuParts(m1, group)*)
        sndFu(group, _FuParts(m2, group)*)
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
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 1, true, editableFu1)
        DoFu1()
}
DoAltFu2() {
    global editableFu2
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 2, true, editableFu2)
        DoFu2()
}
DoAltFu3() {
    global editableFu3, walletCheckFu3
    if !FuGate()
        return
    if !AltIntercept(CurMass(), 3, true, walletCheckFu3 || editableFu3)
        DoFu3()
}

; ── --Name branches ───────────────────────────────────────────────────────────
; The trunk (base fu1/fu2/fu3) sends on the normal keys. A branch is a continuation
; you switch to: pick one, then walk its follow-ups and ppv. The chosen branch is
; remembered per mass (_activeBranch) so fu2/fu3/ppv keep sending the same one.
DoBranchPick() {
    global _activeBranch, massNo
    if !FuGate()
        return
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
    _activeBranch[massNo] := idx
    BranchSendGroup(brs[idx].fu[1])
}

BranchSendActiveGroup(g) {
    global _activeBranch, massNo
    if !FuGate()
        return
    brs := BranchList(CurMass())
    if _activeBranch.Has(massNo) && _activeBranch[massNo] <= brs.Length
        BranchSendGroup(brs[_activeBranch[massNo]].fu[g])
}

DoBranchFu2() {
    BranchSendActiveGroup(2)
}
DoBranchFu3() {
    BranchSendActiveGroup(3)
}
DoBranchPpv() {
    global _activeBranch, massNo
    brs := BranchList(CurMass())
    if _activeBranch.Has(massNo) && _activeBranch[massNo] <= brs.Length
        BranchSendPpv(brs[_activeBranch[massNo]].ppv)
}

; ── Wiring ────────────────────────────────────────────────────────────────────
; Called at the END of a model script, once its data blocks exist. `n` is the
; model file's number, which is also its hotkeys.ini section: [mass.<n>].
;
; Every slot below is attempted, but only the ones hotkeys.ahk declares for THIS
; model get bound — models 2 and 3 have no mouse or short-key variants, and that
; is not an error. HK_Bind would log and skip an undeclared id anyway; checking
; first keeps error_log.txt free of noise that reads like a fault.
MassInit(n) {
    global massNo, modelFileNo, mouseControl
    modelFileNo := n

    slots := Map(
        "fu1",      DoFu1,  "fu1short", DoFu1,  "mFu1", DoFu1,  "smFu1", DoFu1,
        "fu2",      DoFu2,  "fu2short", DoFu2,  "mFu2", DoFu2,  "smFu2", DoFu2,
        "fu3",      DoFu3,  "fu3short", DoFu3,  "mFu3", DoFu3,  "smFu3", DoFu3,
        "ppv",      DoPpv,
        "ppvFus",   DoPpvFus,
        "b1Ppv",    DoPpvFus,
        "altFu1",   DoAltFu1,
        "altFu2",   DoAltFu2,
        "altFu3",   DoAltFu3,
        "brPick",   DoBranchPick,
        "brFu2",    DoBranchFu2,
        "brFu3",    DoBranchFu3,
        "brPpv",    DoBranchPpv)

    for slot, fn in slots {
        id := "mass." n "." slot
        if HK_META.Has(id)
            HK_Bind(id, fn)
    }

    ; Mouse-control off means the mouse-button follow-ups stay dark. Done after
    ; binding rather than by skipping the bind, so flipping the setting back on
    ; only needs a reload, not a rebind.
    if !mouseControl {
        for slot in ["mFu1", "mFu2", "mFu3"] {
            id := "mass." n "." slot
            if HK_META.Has(id)
                HK_SetState(id, "Off")
        }
    }

    ; The Scimitar keys are the same F13-F15 in every model, so without this one
    ; press fired every model's follow-up at once. Registers this model's shared
    ; send keys only while its tab is the active one.
    StartFuGating(HK_ModelSendIds(n))
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
:*X:__mm::DoMass()
#HotIf

#HotIf NumberedSendActive(1)
:*X:__mm1::DoMass()
#HotIf
#HotIf NumberedSendActive(2)
:*X:__mm2::DoMass()
#HotIf
#HotIf NumberedSendActive(3)
:*X:__mm3::DoMass()
#HotIf
