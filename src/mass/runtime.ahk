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
#Include "next_fu.ahk"

; ── the mass library ──────────────────────────────────────────────────────────
;  Declared HERE, by the file that reads it, rather than by engine.ahk.
;
;  CurMass() and friends read MASS_DOC, but only engine.ahk ever assigned it. So
;  anything else that included this file — a test, a tool, a second entry point —
;  loaded with MASS_DOC undeclared and got a modal #Warn dialog ("This global
;  variable appears to never be assigned a value") before a line of its own code
;  ran. From the outside that looks exactly like a hang: no output, no exit, no
;  error on stdout, because a warning dialog is not an error.
;
;  A file that reads a global should be the file that declares it. engine.ahk
;  keeps the RELOAD handler, which is genuinely its business — it owns the
;  cross-process message contract with the GUI.
global MASS_DOC := MASS_Load()

; ── Settings mirrored from mass_gui.cfg ───────────────────────────────────────
; Read once at load, then kept live by the OnMessage handlers below — the GUI
; posts on toggle so you never have to restart a model script to change one.
; LOG_IniInt, not Integer(IniRead(...)) — nine times over.
;
; These eight lines run at the TOP LEVEL of the mass engine, so a throw here is
; not a wrong setting, it is an engine that does not start: every follow-up key,
; every PPV key, every branch and every __mm trigger in MMA silently dead. And
; Integer() throws on anything non-numeric, so all it takes is one hand-edited
; `MouseControl=yes` in a file MMA itself invites you to edit.
;
; Now each one degrades to its default and says so in the log. See LOG_IniInt.
mouseControl   := LOG_IniInt(MMA_CFG, "Settings", "MouseControl",   1, "mass.boot")
openTabFu2     := LOG_IniInt(MMA_CFG, "Settings", "OpenTabFu2",     0, "mass.boot")
openTabFu3     := LOG_IniInt(MMA_CFG, "Settings", "OpenTabFu3",     0, "mass.boot")
openTabPpv     := LOG_IniInt(MMA_CFG, "Settings", "OpenTabPpv",     0, "mass.boot")
walletCheckFu3 := LOG_IniInt(MMA_CFG, "Settings", "WalletCheckFu3", 0, "mass.boot")
editableFu1    := LOG_IniInt(MMA_CFG, "Settings", "EditableFu1",    0, "mass.boot")
editableFu2    := LOG_IniInt(MMA_CFG, "Settings", "EditableFu2",    0, "mass.boot")
editableFu3    := LOG_IniInt(MMA_CFG, "Settings", "EditableFu3",    0, "mass.boot")

doubleMM := false

; What this process resolved at load, in one line.
;
; These eight values decide what every follow-up key does, they are read ONCE
; here, and they are then kept live by PostMessage — so a stale one is invisible
; and permanent for the life of the process. Writing them down at boot is what
; makes "editable was on the whole time" a thing you can see rather than deduce.
LOG_Kv("mass.boot", Map("masses",     MMA_MASSES,
                        "mouseCtrl",  mouseControl,
                        "openTabFu2", openTabFu2,
                        "openTabFu3", openTabFu3,
                        "openTabPpv", openTabPpv,
                        "walletFu3",  walletCheckFu3,
                        "editFu1",    editableFu1,
                        "editFu2",    editableFu2,
                        "editFu3",    editableFu3))

; ── Live settings messages from mass_gui ──────────────────────────────────────
; The numbers are a contract with main_window.ahk, and they are declared in
; core/messages.ahk — the whole contract in one file, rather than the bare hex
; that used to sit here with a comment listing what each one meant.
; _BroadcastEditableFu() there posts to every running model script; before this
; file only 1_mass.ahk listened.
ToggleDMMMsg(wParam, lParam, msg, hwnd) {
    global doubleMM
    doubleMM := !doubleMM
    LOGI("mass.setting", "double-MM " (doubleMM ? "ON — follow-up keys now send"
                                                . " models 1 AND 2 back to back"
                                                : "off"))
}
OnMessage(MMA_MSG_DOUBLE_MM, ToggleDMMMsg)

SetWalletMsg(wParam, lParam, msg, hwnd) {
    global walletCheckFu3
    walletCheckFu3 := wParam
    LOGI("mass.setting", "wallet-check on FU3 → " (wParam ? "on (FU3 pastes for"
                                                          . " review instead of sending)"
                                                          : "off"))
}
OnMessage(MMA_MSG_WALLET_FU3, SetWalletMsg)

SetEditableFuMsg(wParam, lParam, msg, hwnd) {
    global editableFu1, editableFu2, editableFu3
    fuIdx := MMA_MSG_EditableFuNo(msg)      ; was msg - 0x8002
    if fuIdx = 1
        editableFu1 := wParam
    else if fuIdx = 2
        editableFu2 := wParam
    else if fuIdx = 3
        editableFu3 := wParam
    else {
        LOGW("mass.setting", "an editable-FU message arrived for follow-up " fuIdx
                           . ", which is not 1-3 — ignored. The GUI and the engine"
                           . " disagree about the message contract.")
        return
    }
    LOGI("mass.setting", "editable follow-up " fuIdx " → " (wParam ? "on (pastes for"
                                                                   . " review, no Enter)"
                                                                   : "off (sends)"))
}
OnMessage(MMA_MSG_EDITABLE_FU1, SetEditableFuMsg)
OnMessage(MMA_MSG_EDITABLE_FU2, SetEditableFuMsg)
OnMessage(MMA_MSG_EDITABLE_FU3, SetEditableFuMsg)

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
    global doubleMM, openInNewTabButton, MASS_CUR_MODEL, MASS_DOC
    ; Each extra is both a user setting and a feature; Easy mode drops all three
    ; back to "paste the follow-up and press Enter", which is all v1.4.0 did.
    editable := editable && FEAT("editableFu")
    openTab  := openTab  && FEAT("openTab")
    sendBoth := doubleMM && FEAT("doubleMM")
    ; The state every follow-up decision is made from, in one line, before any of
    ; it is acted on. Which model, which mass slot, and the three modifiers — the
    ; four things you would ask for first when somebody says "it sent the wrong
    ; thing" or "it sent nothing".
    LOG_Kv("mass.fu", Map("group",    group,
                          "model",    MASS_CUR_MODEL,
                          "massNo",   MASS_MassNo(MASS_DOC, MASS_CUR_MODEL),
                          "branch",   ActiveBranchNo(),
                          "editable", editable ? "y" : "n",
                          "openTab",  openTab ? "y" : "n",
                          "doubleMM", sendBoth ? "y" : "n"))
    ; One key. If this follow-up has alts or branches, they stage and TAB walks
    ; them; if it has neither, nothing appears and the send below runs. The old
    ; second key (ctrl+f<N>) and the PromptAltCtrl setting that chose between them
    ; are gone — they existed to decide which of two buttons offered the choice,
    ; and there is one button now.
    if AltIntercept(CurMass(), group, editable, ActiveBranchNo())
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
; alt fields use, so MASS_SplitParts already knows how to read it. Each line goes out
; as its own message, exactly like the three f3 fields would have.
;
; Read per press rather than cached: editing it in Settings then takes effect
; without restarting the model scripts, the same trade sndFu makes for FuSingle.
DefaultFu3Parts() {
    if !FEAT("defaultFu3")
        return ["", "", ""]
    return MASS_SplitParts(IniRead(MMA_CFG, "Settings", "DefaultFu3", ""))
}

; ── devlog: the handler was reached ───────────────────────────────────────────
;  One line each, at the top, before any decision is taken. These are the three
;  functions a user means when they say "I pressed f2 and nothing happened", and
;  they turn that into a yes/no question: if there is no `devlog: DoFu2 entered`
;  line, the problem is upstream of this file entirely — the key never bound, the
;  feature is off, the engine is not running, the press was debounced — and the
;  hk.* lines above say which. If there IS one, the cause is below it, and the
;  mass.fu BAIL line says which.
DoFu1() {
    global editableFu1
    LOGD("mass.fu1", "DoFu1 entered")
    _DoFuGroup(1, editableFu1, false)
}
DoFu2() {
    global editableFu2, openTabFu2
    LOGD("mass.fu2", "DoFu2 entered")
    _DoFuGroup(2, editableFu2, openTabFu2)
}
DoFu3() {
    global editableFu3, walletCheckFu3, openTabFu3
    LOGD("mass.fu3", "DoFu3 entered")
    _DoFuGroup(3, walletCheckFu3 || editableFu3, openTabFu3)
}

; The mass body itself — pastes only, so you can review before sending.
DoMass() {
    global MASS_CUR_MODEL, MASS_DOC
    LOGD("mass.body", "DoMass entered")
    m := CurMass()
    if (m.mass = "") {
        ; The classic __mm complaint. Almost always massNo pointing at a slot the
        ; user never filled in — see the "MMA hotkeys do nothing" pattern — so the
        ; slot number is named rather than just "empty".
        LOG_Bail("mass.body", "model " MASS_CUR_MODEL " mass slot "
                            . MASS_MassNo(MASS_DOC, MASS_CUR_MODEL) " has no mass"
                            . " text — nothing to paste. Check that this slot is the"
                            . " one you filled in.")
        return
    }
    LOGI("mass.body", "pasting model " MASS_CUR_MODEL " mass slot "
                    . MASS_MassNo(MASS_DOC, MASS_CUR_MODEL)
                    . " (" StrLen(m.mass) " chars, no Enter)")
    A_Clipboard := m.mass
    if !ClipWait(0.5)
        LOGE("mass.body", "the clipboard never accepted the mass — Ctrl+V is about"
                        . " to paste the PREVIOUS clipboard into the chat")
    Send "^v"
}

; PPV base. Paste-only for the same reason as DoMass.
;
; Same one-key rule as the follow-ups: with branch PPVs present this stages them
; alongside the trunk's and TAB walks the list. That is what retired brPpv.
DoPpv() {
    global openTabPpv, openInNewTabButton, MASS_CUR_MODEL
    LOGD("mass.ppv", "DoPpv entered")
    m := CurMass()
    if AltInterceptPpv(m, true, ActiveBranchNo())
        return
    if (m.ppv_base = "") {
        LOG_Bail("mass.ppv", "model " MASS_CUR_MODEL " has no PPV base text in the"
                           . " selected mass — nothing to paste")
        return
    }
    LOGI("mass.ppv", "pasting model " MASS_CUR_MODEL " PPV base ("
                   . StrLen(m.ppv_base) " chars, no Enter)")
    A_Clipboard := m.ppv_base
    if !ClipWait(0.1)
        LOGE("mass.ppv", "the clipboard never accepted the PPV in 100ms — Ctrl+V is"
                       . " about to paste the PREVIOUS clipboard")
    Send "^v"
    if openTabPpv && FEAT("openTab")
        clickReturn(openInNewTabButton)
}

DoPpvFus() {
    global MASS_CUR_MODEL
    LOGD("mass.ppvfus", "DoPpvFus entered")
    m := CurMass()
    n := 0
    for _, p in [m.ppv_f1, m.ppv_f2, m.ppv_f3]
        if (Trim(p) != "")
            n++
    if (n = 0) {
        LOG_Bail("mass.ppvfus", "model " MASS_CUR_MODEL " has no PPV follow-ups in"
                              . " the selected mass — nothing sent")
        return
    }
    LOGI("mass.ppvfus", "sending " n " PPV follow-up(s) for model " MASS_CUR_MODEL)
    snd(m.ppv_f1)
    snd(m.ppv_f2)
    snd(m.ppv_f3)
}

; ── Which branch this conversation is on ──────────────────────────────────────
;  Branches used to be four keys of their own — brPick opened a list window, then
;  brFu2/brFu3/brPpv replayed whatever it had remembered. That was a second way to
;  ask the same question the alt key already asked, so it is one list on one key
;  now (see AltVariants) and these two functions are all that is left: the memory,
;  and the hook that writes it.
;
;  The memory still matters. A branch means the NEXT follow-ups change too, so
;  once you pick one at f1, f2 and f3 open on that same branch instead of making
;  you find it again. TAB still reaches everything, so it is a starting point and
;  never a lock.

; The branch the current model's current mass is on, or 0 for the trunk.
ActiveBranchNo() {
    global _activeBranch
    k := _BranchKey()
    if !_activeBranch.Has(k)
        return 0
    n := _activeBranch[k]
    ; Guard against a mass that has been edited since: the branch that was picked
    ; may no longer exist, and indexing BranchList past its end throws inside a
    ; hotkey handler.
    return (n >= 1 && n <= BranchList(CurMass()).Length) ? n : 0
}

; Installed into ALT_ON_PICK below, so committing a staged choice records where
; the conversation went. Picking a trunk variant CLEARS the branch — going back to
; "main" at f2 has to mean the trunk, or there would be no way back.
RememberBranch(branch) {
    global _activeBranch
    if branch
        _activeBranch[_BranchKey()] := branch
    else
        _activeBranch.Delete(_BranchKey())
}
global ALT_ON_PICK := RememberBranch

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
        ; One key for the whole f1->f2->f3 walk; see mass/next_fu.ahk.
        "nextFu",   DoNextFu,
        ; altFu1-3 are a SECOND KEY for fu1-3, kept only so an existing ^F1
        ; binding does not go dead. They do exactly what the plain key does —
        ; there is nothing left for a separate "pick alt" key to do now that the
        ; plain key stages every alt AND every branch.
        ;
        ; brPick / brFu2 / brFu3 / brPpv were here. They are gone, not renamed:
        ; the branch variants are in the same staged list as the alts, and the
        ; branch you are on is remembered from what you pick there.
        "altFu1",   DoFu1,
        "altFu2",   DoFu2,
        "altFu3",   DoFu3)
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
; Every [mass.active] key comes through here, and "no answer" means the key does
; nothing at all. That is the correct choice — guessing sends one model's message
; to another model's fan — but it is also the single most confusing thing MMA
; does, because the key is bound, the feature is on, and nothing happens.
;
; ActiveModelStatus already logged WHY it has no answer (detector off, window not
; in front, name unclaimed, tabs ambiguous). This adds the consequence, so the two
; lines sit together in the log and the chain is readable end to end.
_RunOnActiveModel(fn) {
    st := ActiveModelStatus()
    if !st.no {
        LOG_Bail("mass.active", "a shared [mass.active] key was pressed but MMA does"
                              . " not know which model is on screen (state: "
                              . st.state "). Nothing sent — that is deliberate,"
                              . " since guessing would send to the wrong fan. Use"
                              . " the numbered keys, or a 'active model = N' key.")
        return
    }
    LOGV("mass.active", "shared key resolved to model " st.no
                      . " (" st.state (st.name != "" ? ", " st.name : "") ")")
    _SetCurModel(st.no)
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

    mode := ModelMatchMode()

    ; A model on a platform the detector cannot see has no tab index to record,
    ; and trying would be actively destructive: TeachPosition maps whatever
    ; Infloww tab happens to be lit to this model, so pressing the Fansly model's
    ; key with Infloww behind would file a Fansly model under an Infloww tab and
    ; quietly reroute that tab's sends.
    ;
    ; For these, the press means exactly what it says and nothing more: this is
    ; the model now. ActiveModelStatus picks it up whenever Infloww is not in
    ; front — see ManualFallbackModel.
    if IsManualPlatform(n) {
        SoundBeep(880, 90)
        _MassToast("Active model: " ModelLabel(n) "   (manual — not on Infloww)")
        return
    }

    if (mode = "position") {
        TeachPosition(n)
        return
    }
    ; Any other mode becomes manual, because a key labelled "active model = 2"
    ; that left the detector in charge would be lying about what it does.
    if (mode != "manual")
        IniWrite("manual", MMA_CFG, "Settings", "ModelMatch")
    _MassToast("Active model: " ModelLabel(n))
}

; ── saying which model the tab in front is ────────────────────────────────────
;  In positional mode the screen answers "which TAB is lit" and Settings answers
;  "which model is that tab". This press is how you give the second answer without
;  opening Settings: it reads the lit tab's INDEX off the screen and files the
;  model you named under it.
;
;  Reads the pixels HERE, at the moment of the press. It used to go through
;  detector_status.ini, which the background service refreshes every 500ms and
;  only while Infloww is focused — so "click the tab, press the key" acted on a
;  reading from before the click. There is no reason to route a measurement you
;  can take directly through a file.
;
;  Every outcome is audible. A tooltip you have to notice is not feedback when
;  your eyes are on the chat you are about to send into.
TeachPosition(n) {
    global MASS_MODELS
    cfg := DetectorCfg()

    if !DetectorWindowUp(cfg) {
        _TeachFail("Click " (cfg.win = "" ? "Infloww" : cfg.win) " first."
                 . "`nNothing changed — MMA only reads the tab strip while that"
                 . " window is in front.")
        return
    }

    t := TabLitIndex(cfg)
    if (t.index < 1) {
        ; The counts ARE the diagnosis, so show them. All zeros = nothing lit
        ; (wrong colour or region). Two big ones = one pill straddling two slots
        ; (wrong TabPitch). Without them "it did not work" is unactionable.
        _TeachFail("No single tab is lit at the expected positions."
                 . "`nper-tab pixels: " _CountsLine(t.counts)
                 . "`nNothing changed. All zeros means the colour or region is"
                 . " wrong — run tools\detector_probe.ahk. Two large numbers"
                 . " means TabPitch is wrong.")
        return
    }
    idx := t.index

    if !SetTabOrderFor(idx, n) {
        _TeachFail("Could not set tab " idx " to model " n ".")
        return
    }
    SoundBeep(880, 90)
    _MassToast("Tab " idx " = " ModelLabel(n) "`n" _OrderSummary())
}

; Per-tab pixel counts, for the messages that need to show their working.
_CountsLine(counts) {
    out := ""
    for i, c in counts
        out .= (out = "" ? "" : "  ") "tab" i ":" c
    return out
}

_TeachFail(msg) {
    SoundBeep(300, 250)
    _MassToast(msg)
}

; The whole order after every press. Two tabs mapped to the same model is a real
; mistake and one you would otherwise only find by sending to the wrong fan.
_OrderSummary() {
    global MASS_MODELS
    out := "", seen := Map()
    dup := false
    Loop MASS_MODELS {
        m := TabModel(A_Index)
        out .= (out = "" ? "order: " : "   ") "tab" A_Index "→" ModelLabel(m)
        if seen.Has(m)
            dup := true
        seen[m] := true
    }
    return out (dup ? "   ⚠ two tabs share a model" : "")
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
