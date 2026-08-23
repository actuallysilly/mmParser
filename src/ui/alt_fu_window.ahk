#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  alt_fu_window.ahk — text in, follow-up out. One form, two ways in.
; ───────────────────────────────────────────────────────────────────────────────
;  ── the two ways in ──────────────────────────────────────────────────────────
;      Variants ▸ "Add alt-FU…"      you are in the editor, writing a mass
;      Add Hotkey ▸ "Replace follow-up…"   you are mid-shift, holding text you
;                                    just grabbed off the screen
;
;  The second is the OCR pipeline, and it is the reason this window takes a
;  prefill: you typed a better wording by hand into a real chat, dragged a box
;  round it (`gui.ocrGrab`), and what you want is for that text to BE the
;  follow-up — either replacing what is there or joining it as an alternative.
;  Same four questions either way, so it is one window and not two:
;
;      which model  ·  which mass  ·  which follow-up  ·  what does it say
;
;  ── the two differences, and both are deliberate ─────────────────────────────
;  WHERE THE DROPDOWNS OPEN. From the grid, on the model whose tab you were
;  looking at. From a capture, on the follow-up you last SENT — see
;  MASS_RememberSent in mass/store.ahk. The text on your screen is nearly always a
;  better wording of the message you just pressed a key for.
;
;  WHETHER IT SAVES. In the editor it writes into the grid and waits for "Save to
;  file", for the reasons under "what it writes" below. A capture COMMITS — it
;  writes the grid and then calls the same ApplyFile the Save button calls. The
;  editor is not where you are during a capture: the main window is behind Infloww
;  and "now go and press Save" is a trip that would not be made until the end of a
;  shift, if at all. The line under the buttons says which of the two you are in,
;  because a window that sometimes saves and sometimes does not must say so.
;
;  ── the original way in ──────────────────────────────────────────────────────
;  Opened from the Variants window's "Add alt-FU…" button. The grid behind it is
;  the full editor — every branch, every follow-up, all on screen at once — and it
;  is the right shape for reading a mass and the wrong shape for ADDING one line
;  to it. To add an alternative there you have to know that the row is a branch,
;  that the column is a follow-up, that the row needs a name before it sends, and
;  that a second wording goes on a second LINE of the same cell rather than in the
;  next column. None of that is on screen. This window asks the four questions in
;  order instead:
;
;      which model  ·  which mass  ·  which follow-up  ·  what does it say
;
;  ─── IT PARSES THE SAME `::name` YOU WOULD PASTE ─────────────────────────────
;  The paste box takes either form, and that is the point rather than a
;  convenience:
;
;      no markers      one branch. Named from the Branch box, or "alt" — and
;                      "alt1", "alt2"… if the mass already has an "alt". One
;                      message per line.
;      `::name text`   parsed exactly as a real paste is, markers honoured, and
;                      NOTHING is auto-added. So working alt code copied out of a
;                      Discord message goes straight in, and several branches can
;                      arrive in one paste.
;
;  Detection is BranchMarker() from mass/parser.ahk — the shipping one, not a
;  regex of this window's own. A second implementation of "is this line a marker"
;  is a thing that agrees today and disagrees after the next syntax change, and
;  the disagreement would land in a real fan's chat.
;
;  ─── WHAT IT WRITES, AND WHAT IT DOES NOT ────────────────────────────────────
;  Both buttons write into the GRID — the same edit controls the Variants window
;  shows. So an Add is undoable by closing without saving, you can see what it did
;  before committing to it, and there is exactly one writer of the library
;  (ApplyFile). A window that wrote its own JSON behind the open editor would be a
;  second writer racing the first, and the one it would lose to is the user's own
;  unsaved work.
;
;  A capture still goes to disk — but through that same ApplyFile, after the grid
;  has been written, so the count of writers is still one.
;
;  The status line says which happened after every press, because "it worked and
;  nothing is saved yet" is the state people get wrong.
;
;  ─── REPLACE, AND WHY IT CLEARS WHAT IT DOES NOT FILL ────────────────────────
;  Add appends a wording to a branch. Replace overwrites the TRUNK — the follow-up
;  the plain key sends — and it writes every sub-slot of the group, including the
;  ones the new text does not reach. A replace that left f2.7 behind would send the
;  old third message after the new first one, which reads as MMA inventing a line.
;  See _AFW_WriteTrunk.
; ═══════════════════════════════════════════════════════════════════════════════

; The window while it is open, else 0. One at a time: it acts on whatever model
; and mass are selected in it, and two of them open on different models would be
; two answers to "where does Add go".
global _afwGui := 0
; Its paste box, and which of the two modes it was built in. Both are here rather
; than in the builder's closure for one case: a SECOND capture arriving while the
; window is already up. Same mode, and the new text simply replaces the box's
; contents; different mode, and the window is rebuilt, because the buttons would
; otherwise promise the wrong thing about saving.
global _afwBody    := 0
global _afwCapture := false

; ── the four groups, and what they are called ─────────────────────────────────
;  Keyed by the field prefix the store uses, so nothing here maps a label back to
;  a field name by parsing it. `short` is the name the key has on your keyboard —
;  it goes on the Replace button, which has to say which follow-up it is about to
;  overwrite in the width of a button.
global AFW_GROUPS := [{id: "fu1", label: "Follow-up 1", short: "f1"},
                      {id: "fu2", label: "Follow-up 2", short: "f2"},
                      {id: "fu3", label: "Follow-up 3", short: "f3"},
                      {id: "ppv", label: "PPV",         short: "PPV"}]

; `prefill` is the captured TEXT, and its presence is what puts this window in
; capture mode.
OpenAddAltFu(prefill := "", *) {
    global _afwGui, _afwBody, _afwCapture, AFW_GROUPS, modelCount, MASS_SLOTS
    ; `tabs` as well as `varTabs`: a capture moves BOTH windows' tabs onto the
    ; model it is aimed at, and an undeclared name here would be a fresh local —
    ; assigned inside a `try`, so the tab would simply not move and nothing would
    ; say why.
    global MASS_FU_PARTS, MASS_BRANCH_MAX, varTabs, tabs

    ; A control, not a string, means this was bound STRAIGHT to a button: OnEvent
    ; hands a handler the control object as its first argument, and it would land
    ; here as the captured text and put a GuiControl into the paste box. The
    ; Variants window's button therefore calls through a lambda that passes
    ; nothing — this is the belt to that braces.
    if !(prefill is String)
        prefill := ""
    capture := (Trim(prefill) != "")

    ; Already open. Asking a DESTROYED Gui object for its Hwnd throws rather than
    ; answering 0, so the check is wrapped: Escape closes this window with
    ; Destroy, and the variable goes on pointing at the corpse until the next open.
    _open := false
    try _open := (_afwGui && WinExist("ahk_id " _afwGui.Hwnd)) ? true : false
    if _open {
        if (capture = _afwCapture) {
            ; A second grab means "use this one instead" — the box holds a
            ; capture, not your typing.
            if capture
                try _afwBody.Value := prefill
            try WinActivate("ahk_id " _afwGui.Hwnd)
            return
        }
        ; The modes differ in what the buttons DO. Re-using the window across them
        ; would leave a button promising a save it will not make, or claiming a
        ; save is still needed after it has happened.
        LOGI("gui.altfu", "the window was open in " (_afwCapture ? "capture" : "editor")
                        . " mode and is now wanted in " (capture ? "capture" : "editor")
                        . " mode — rebuilding")
        try _afwGui.Destroy()
        _AFW_Forget()
    }

    W := 560
    ag := Gui("+AlwaysOnTop -MinimizeBox", capture ? "Replace follow-up" : "Add alt-FU")
    ag.BackColor := "15141C"
    ag.SetFont("s9 cE6E4EE", "Segoe UI")

    ; ── row 1: which model, which mass, which follow-up ───────────────────────
    y := 12
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x14 y" y " w150", "MODEL")
    ag.Add("Text", "x186 y" y " w80",  "MASS")
    ag.Add("Text", "x282 y" y " w150", "FOLLOW-UP")
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 16

    ; ── where the three dropdowns open ────────────────────────────────────────
    ;  From the grid: the model whose tab you were looking at. This window is
    ;  reached from that grid, so anything else would be a silent change of
    ;  subject.
    ;
    ;  From a capture: the follow-up you last SENT. You are holding text off the
    ;  screen and the question "which follow-up is this a better version of" has
    ;  the same answer nearly every time — the key you just pressed. Nothing is
    ;  assumed when the engine has not sent anything yet (a fresh boot): `last` is
    ;  0 and the grid's own defaults stand.
    last := capture ? MASS_LastSent() : 0

    _mdlItems := []
    Loop modelCount
        _mdlItems.Push(ModelLabel(A_Index))
    ddlModel := ag.Add("DropDownList", "x14 y" y " w164", _mdlItems)
    _wantModel := (varTabs.Value >= 1 && varTabs.Value <= modelCount)
                    ? varTabs.Value : 1
    ; MASS_LastSent answers against MASS_MODELS, the ceiling; modelCount is how
    ; many are in play. A model that has been switched off since the send is not
    ; one this window can offer.
    if (last && last.model <= modelCount)
        _wantModel := last.model
    ddlModel.Value := _wantModel

    _massItems := []
    Loop MASS_SLOTS
        _massItems.Push(String(A_Index))
    ddlMass := ag.Add("DropDownList", "x186 y" y " w84", _massItems)

    _grpItems := []
    for _, g in AFW_GROUPS
        _grpItems.Push(g.label)
    ddlGrp := ag.Add("DropDownList", "x282 y" y " w160", _grpItems)
    ddlGrp.Value := last ? _AFW_GroupIndex(last.group) : 1
    y += 32

    ; ── the preview ───────────────────────────────────────────────────────────
    ; What this follow-up says RIGHT NOW — the trunk's parts, then every branch
    ; already answering it. You are writing another wording of something, and the
    ; something is the one thing the grid makes you go and look up.
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x14 y" y " w" (W - 28), "WHAT THIS FOLLOW-UP SAYS NOW")
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 16
    edPrev := ag.Add("Edit", "x14 y" y " w" (W - 28) " h96 ReadOnly Multi +VScroll"
                           . " Background201E2B")
    y += 104

    ; ── the branch name ───────────────────────────────────────────────────────
    ag.Add("Text", "x14 y" (y + 4) " w86", "Branch name:")
    edName := ag.Add("Edit", "x104 y" y " w150 h22 Background201E2B")
    CueBannerFor(edName, "alt")
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x264 y" (y + 5) " w" (W - 278),
           "Blank = alt, then alt1, alt2… if taken. An existing name adds to that"
         . " branch.")
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 30

    ; ── the paste box ─────────────────────────────────────────────────────────
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x14 y" y " w" (W - 28),
           (capture ? "THE TEXT YOU GRABBED" : "THE ALTERNATIVE")
         . " — one message per line, up to " MASS_FU_PARTS)
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 16
    edBody := ag.Add("Edit", "x14 y" y " w" (W - 28) " h110 Multi WantReturn"
                           . " +VScroll Background201E2B")
    ; Editable, deliberately: OCR reads a chat bubble at a time and brings the
    ; furniture with it, so the first thing you do with a grab is tidy it. This is
    ; the last look at the words before they become a message MMA sends.
    edBody.Value := prefill
    y += 116
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x14 y" y " w" (W - 28),
           "Paste `::name text` lines and they are parsed exactly as a mass paste"
         . " is — markers kept, nothing added, several branches at once. Without a"
         . " marker the whole box is one branch.")
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 32

    ; ── the strip ─────────────────────────────────────────────────────────────
    ;  Two verbs, and the difference between them is the whole window: Replace
    ;  overwrites the follow-up the plain key sends, Add hangs another wording off
    ;  it as a branch. The Replace button names the group it is about to overwrite
    ;  (Refresh keeps it current) because "Replace" alone, next to three
    ;  dropdowns, is a button you have to look away from to be sure about.
    ;
    ;  Which one is Default follows the way in: a capture came from a button
    ;  labelled "Replace follow-up…", and in the editor the whole point of the
    ;  window is adding alternatives.
    btnReplace := ag.Add("Button", "x14 y" y " w150 h28" (capture ? " Default" : ""),
                         "Replace")
    btnAdd := ag.Add("Button", "x172 y" y " w130 h28" (capture ? "" : " Default"),
                     "Add as alt")
    btnClose := ag.Add("Button", "x310 y" y " w80 h28", "Close")
    y += 34
    ; Where the text ends up, in one sentence, in the mode you are actually in.
    ag.SetFont("s8 c8E8AA6", "Segoe UI")
    ag.Add("Text", "x14 y" y " w" (W - 28),
           capture ? "Both buttons save to masses.json straight away — the engine has"
                   . " it the moment you press one."
                   : "Both buttons write into the grid behind this window. Nothing"
                   . " reaches masses.json until Save to file.")
    ag.SetFont("s9 cE6E4EE", "Segoe UI")
    y += 20
    lblMsg := ag.Add("Text", "x14 y" y " w" (W - 28), "")
    y += 30

    ddlModel.OnEvent("Change",  OnModel)
    ddlMass.OnEvent("Change",   OnMass)
    ddlGrp.OnEvent("Change",    (*) => Refresh())
    btnReplace.OnEvent("Click", DoReplace)
    btnAdd.OnEvent("Click",     DoAdd)
    btnClose.OnEvent("Click",   CloseMe)
    ; Every way out goes through one function, so the globals above can never be
    ; left pointing at a window that is not there — which is what decides whether
    ; the next capture re-uses this window or builds a new one.
    ag.OnEvent("Close",  CloseMe)
    ag.OnEvent("Escape", CloseMe)

    _afwGui := ag, _afwBody := edBody, _afwCapture := capture
    THEME_BoldButtons(ag)
    ArchiveDarkTheme(ag, [edPrev, edName, edBody])
    ; A capture names a MASS as well as a model, and both buttons write into the
    ; GRID — which shows one slot per model. So the tabs are moved onto that model
    ; and that slot before anything can be written, exactly as OnModel and OnMass
    ; do when you change the dropdowns by hand. Ahead of SyncMass, which then reads
    ; back what actually happened rather than what was asked for.
    moved := false
    if (last && last.model <= modelCount) {
        try varTabs.Value := last.model
        try tabs.Value := last.model
        try RefreshModelHeader()
        moved := _AFW_AimAtMass(last.model, last.slot)
    }
    SyncMass()
    Refresh()
    if last {
        ; Where the defaults came from, said rather than left to be inferred.
        ;
        ; And if the aim MOVED the mass slot, that is said too. Picking a mass in
        ; this window makes it the model's live one — the dropdown has always meant
        ; that (see OnMass) — so a capture aimed at a slot the tab was not showing
        ; changes what every one of that model's keys sends. It is the right slot,
        ; being the one the send came from, and it is still a change nobody asked
        ; for out loud.
        _ago := _AFW_Ago(last.when)
        _msg := "Opened on the follow-up you last sent"
              . (_ago = "" ? "" : " (" _ago ")") "."
        if moved
            _msg .= "  " ModelLabel(last.model) " is on mass " last.slot " again —"
                  . " which is what its keys send."
        _Say(_msg, "c8E8AA6")
    }
    ag.Show("w" W " h" y)
    return

    ; ── which model ───────────────────────────────────────────────────────────
    ; Switching the dropdown switches the TABS TOO, in both windows. The grid
    ; behind this one has to be showing the model Add is about to write into, or
    ; the write is invisible and the first sight of it is in a fan's chat.
    OnModel(*) {
        global tabs, varTabs
        mNo := ddlModel.Value
        try varTabs.Value := mNo
        try tabs.Value := mNo
        try RefreshModelHeader()
        SyncMass()
        Refresh()
    }

    ; ── which mass ────────────────────────────────────────────────────────────
    ; Straight through PickMassSlot, which is what the mass radios on the model's
    ; own tab call. That is deliberate: switching mass discards the boxes, so it
    ; asks first when there is unsaved text, and it also makes the chosen slot the
    ; LIVE one. Reimplementing either half here would give the same dropdown two
    ; different meanings depending on which window you used.
    ;
    ; The prompt can be declined, and then the slot has not changed — so the
    ; dropdown is re-read from the model rather than left showing a lie.
    OnMass(*) {
        mNo := ddlModel.Value
        PickMassSlot(mNo, ddlMass.Value)
        SyncMass()
        Refresh()
    }

    SyncMass() {
        cur := MassNoForModel(ddlModel.Value)
        ddlMass.Value := (cur >= 1 && cur <= MASS_SLOTS) ? cur : 1
    }

    CloseMe(*) {
        _AFW_Forget()
        try ag.Destroy()
    }

    ; ── the preview ───────────────────────────────────────────────────────────
    Refresh(*) {
        global edCtrls, AFW_GROUPS, MASS_BRANCH_MAX
        mNo := ddlModel.Value
        grp := AFW_GROUPS[ddlGrp.Value].id
        ; The button says which follow-up it will overwrite. Here rather than in
        ; the group dropdown's handler because every path that changes what this
        ; window is aimed at already comes through Refresh.
        btnReplace.Text := "Replace " AFW_GROUPS[ddlGrp.Value].short
        out := ""

        ; The trunk. PPV's body lives in ppv_base while the follow-ups have three
        ; numbered sub-slots, so the field list differs by group — which is the
        ; store's shape, not a special case invented here.
        for _, f in _AFW_TrunkFields(grp) {
            ck := "m" mNo "_" f
            if (edCtrls.Has(ck) && Trim(edCtrls[ck].Value) != "")
                out .= (out = "" ? "" : "`r`n") "main:  "
                     . _AFW_OneLine(edCtrls[ck].Value)
        }
        if (out = "")
            out := "main:  (nothing written for this follow-up yet)"

        Loop MASS_BRANCH_MAX {
            k  := A_Index
            nk := "m" mNo "_br" k "_name"
            bk := "m" mNo "_br" k "_" grp
            if !edCtrls.Has(nk)
                continue
            nm := Trim(edCtrls[nk].Value)
            bd := edCtrls.Has(bk) ? Trim(edCtrls[bk].Value) : ""
            if (nm = "" && bd = "")
                continue
            ; A branch that exists but says nothing HERE is worth showing: it is
            ; a name that is already taken, which is exactly what you need to know
            ; before typing one into the box above.
            out .= "`r`n" (nm = "" ? "(unnamed " k ")" : nm) ":  "
                 . (bd = "" ? "—" : _AFW_OneLine(bd))
        }
        edPrev.Value := out
    }

    ; ── replace ───────────────────────────────────────────────────────────────
    ;  The destructive one, so it asks before it destroys and it shows what it is
    ;  about to destroy. That confirm is not politeness: the wording it is about
    ;  to overwrite may exist nowhere else on the machine, and in capture mode
    ;  this button also writes the file.
    DoReplace(*) {
        global AFW_GROUPS, MASS_FU_PARTS
        mNo  := ddlModel.Value
        grp  := AFW_GROUPS[ddlGrp.Value].id
        lbl  := AFW_GROUPS[ddlGrp.Value].short
        body := edBody.Value
        if (Trim(body) = "") {
            _Say("Nothing to write — the box is empty.", "cD08080")
            return
        }
        if !_AimOk()
            return

        ; A paste with `::name` markers is a set of ALTERNATIVES — the other
        ; button's input. Writing it into the trunk would either send a fan a
        ; message beginning "::alt" or silently drop half the paste, and there is
        ; no reading of it that means "replace".
        plan := _AFW_Plan(body)
        if plan.marked {
            _Say("That paste has ::name markers, so it is alternatives — use Add"
               . " as alt.", "cD08080")
            LOG_Bail("gui.altfu", "Replace refused a marked paste for model " mNo
                                . " " grp " — markers mean branches")
            return
        }
        parts := []
        for _, p in plan.parts
            parts.Push(p.text)

        ; A follow-up has exactly three sub-slots to send from (f2, f2.5, f2.7), so
        ; a fourth line has nowhere to go. Said with both counts and answered with
        ; a choice — a grab that pulled in one bubble too many is the common way to
        ; get here, and silently dropping the tail is how you find out in a chat.
        ; PPV is one multiline field, so it has no such ceiling.
        if (grp != "ppv" && parts.Length > MASS_FU_PARTS) {
            if (MsgBox("A follow-up sends at most " MASS_FU_PARTS " messages, and the"
                     . " box has " parts.Length " lines.`n`nKeep the first "
                     . MASS_FU_PARTS " and drop the rest?", "Too many lines",
                       0x24) != "Yes") {
                _Say("Nothing written — trim the box to " MASS_FU_PARTS " lines.",
                     "cD08080")
                return
            }
            kept := []
            Loop MASS_FU_PARTS
                kept.Push(parts[A_Index])
            parts := kept
        }

        ; What is there now, in the confirm, because this is the moment to notice
        ; that the dropdowns are aimed at the wrong follow-up.
        now := _AFW_TrunkNow(mNo, grp)
        if (now != "") {
            if (MsgBox(lbl " of " ModelLabel(mNo) ", mass " ddlMass.Value
                     . ", says:`n`n" now "`n`nReplace it with the "
                     . parts.Length " line(s) in the box?", "Replace " lbl,
                       0x24) != "Yes") {
                _Say("Replace cancelled — nothing written.", "c8E8AA6")
                LOG_Bail("gui.altfu", "Replace of model " mNo " " grp
                                    . " cancelled at the confirm")
                return
            }
        }

        r := _AFW_WriteTrunk(mNo, grp, parts)
        if (r != "ok") {
            _Say("Nothing written — " r ".", "cD08080")
            LOG_Bail("gui.altfu", "Replace wrote nothing for model " mNo " " grp
                                . " — " r)
            return
        }
        VarRefresh()
        Refresh()
        LOGI("gui.altfu", "model " mNo " " grp " REPLACED in the grid with "
                        . parts.Length " part(s) from the "
                        . (capture ? "capture" : "paste box"))
        _Commit(mNo, lbl " of " ModelLabel(mNo) " replaced")
    }

    ; ── the dropdown and the tab have to agree ────────────────────────────────
    ;  Both buttons write into the GRID, which shows ONE mass slot per model. The
    ;  mass dropdown is a request to move that slot, and PickMassSlot can refuse
    ;  it — there may be unsaved edits and you may say no. The gap between "asked
    ;  for mass 2" and "the tab is still on mass 1" is one follow-up written over
    ;  a different mass's, so it is checked at the moment of writing rather than
    ;  assumed from the moment of asking.
    _AimOk() {
        want := ddlMass.Value
        have := MassNoForModel(ddlModel.Value)
        if (want = have)
            return true
        SyncMass()
        _Say("The tab is on mass " have ", not mass " want " — nothing written.",
             "cD08080")
        LOG_Bail("gui.altfu", "refused to write model " ddlModel.Value
                            . ": the dropdown says mass " want " and the tab is"
                            . " showing mass " have)
        return false
    }

    ; ── and then, only in capture mode, to disk ───────────────────────────────
    ;  Through ApplyFile — the same function the Save button calls — so the grid
    ;  and the file cannot disagree and the library still has exactly one writer.
    ;  It saves the whole record for this model, which is right: what is on that
    ;  tab IS the mass, and it is now the mass with the new wording in it.
    _Commit(mNo, what) {
        if !capture {
            _Say(what " — NOT SAVED, press Save to file.", "c9BE29B")
            return
        }
        ApplyFile(MMA_ModelNames()[mNo], true)
        _Say(what ", and saved.", "c9BE29B")
    }

    ; ── add ───────────────────────────────────────────────────────────────────
    DoAdd(*) {
        global edCtrls, AFW_GROUPS, MASS_FU_PARTS, MASS_BRANCH_MAX
        mNo  := ddlModel.Value
        grp  := AFW_GROUPS[ddlGrp.Value].id
        body := edBody.Value
        if (Trim(body) = "") {
            _Say("Nothing to add — the box is empty.", "cD08080")
            return
        }
        if !_AimOk()
            return

        ; What the box says, as a list of {name, text}. The rules are in
        ; _AFW_Plan — deliberately a top-level function and not this closure, so
        ; the test can drive it. Every interesting decision this window makes is
        ; in there, and a decision that can only be reached by opening a window
        ; and clicking a button is a decision nothing will ever check.
        plan := _AFW_Plan(body)

        ; The default name is resolved HERE and not inside the plan, because it
        ; depends on the mass: "alt" is free on one model and taken on another.
        ; Only the unmarked case has one — a marked paste is taken at its word.
        fallback := ""
        if !plan.marked {
            fallback := Trim(edName.Value)
            if (fallback = "")
                fallback := _AFW_FreeAltName(mNo)
        }

        added := 0, names := "", refused := ""
        for _, part in plan.parts {
            nm := (part.name != "") ? part.name : fallback
            r  := _AFW_AddPart(mNo, nm, grp, part.text)
            if (r = "ok")
                added++, names := _AFW_Join(names, nm)
            else
                refused := _AFW_Join(refused, nm " (" r ")")
        }

        if !added {
            _Say("Nothing added" (refused = "" ? "." : " — " refused), "cD08080")
            LOG_Bail("gui.altfu", "Add wrote nothing for model " mNo " " grp
                                . (refused = "" ? "" : " — " refused))
            return
        }

        VarRefresh()
        Refresh()
        edBody.Value := ""
        LOGI("gui.altfu", "model " mNo ": " added " part(s) added to branch '"
                        . names "' for " grp " in the grid"
                        . (refused = "" ? "" : "; refused: " refused)
                        . (capture ? " — saving now"
                                   : " — nothing written to masses.json until Save"
                                   . " to file"))
        ; "It worked and nothing is saved yet" is the half people get wrong in the
        ; editor, so _Commit says which of the two happened either way.
        _Commit(mNo, added " part(s) → " names)
    }

    _Say(txt, colour) {
        lblMsg.SetFont(colour)
        lblMsg.Text := txt
    }
}

_AFW_Forget() {
    global _afwGui, _afwBody, _afwCapture
    _afwGui := 0, _afwBody := 0, _afwCapture := false
}

; The trunk fields that make up one group, in send order.
_AFW_TrunkFields(grp) {
    if (grp = "ppv")
        return ["ppv_base"]
    return [grp, grp "_5", grp "_7"]
}

; Which entry of AFW_GROUPS a stored group id is, for the dropdown. Falls back to
; the first rather than throwing: the id comes out of the cfg, where anything can
; be written by hand.
_AFW_GroupIndex(id) {
    global AFW_GROUPS
    for i, g in AFW_GROUPS
        if (g.id = id)
            return i
    return 1
}

; ── replacing the trunk ───────────────────────────────────────────────────────
;  The captured wording BECOMES the follow-up the plain key sends. Returns "ok" or
;  a short reason, and is top-level for the same reason _AFW_AddPart is: a decision
;  that can only be reached by opening a window and clicking a button is a decision
;  nothing will ever check.
;
;  The shape difference between a follow-up and a PPV is the store's, not this
;  window's: f2 is three fields sent one after another, and a PPV is one multiline
;  field (see MASS_FieldIsMultiline).
;
;  EVERY sub-slot is written, including the ones the new wording does not fill.
;  This is the decision worth stating: a replace that only overwrote f2 and left
;  f2.5 and f2.7 alone would send the new first message followed by the OLD second
;  and third, which is not something anyone wrote and reads in the chat as MMA
;  inventing lines. Replace means what it says.
_AFW_WriteTrunk(mNo, grp, parts) {
    global edCtrls, MASS_FU_PARTS
    if !parts.Length
        return "empty"

    if (grp = "ppv") {
        ck := "m" mNo "_ppv_base"
        if !edCtrls.Has(ck)
            return "no such field"
        joined := ""
        for _, p in parts
            joined .= (joined = "" ? "" : "`r`n") p
        edCtrls[ck].Value := joined
        return "ok"
    }

    if (parts.Length > MASS_FU_PARTS)
        return "a follow-up holds " MASS_FU_PARTS " messages, not " parts.Length
    for i, f in _AFW_TrunkFields(grp) {
        ck := "m" mNo "_" f
        if !edCtrls.Has(ck)
            return "no such field"
        edCtrls[ck].Value := (i <= parts.Length) ? parts[i] : ""
    }
    return "ok"
}

; What one group's trunk says right now, for the confirm — the parts as one line,
; in send order, exactly as _AFW_OneLine renders a branch's. "" when the follow-up
; is empty, which is what tells Replace there is nothing to ask about.
_AFW_TrunkNow(mNo, grp) {
    global edCtrls
    out := ""
    for _, f in _AFW_TrunkFields(grp) {
        ck := "m" mNo "_" f
        if (edCtrls.Has(ck) && Trim(edCtrls[ck].Value) != "")
            ; Each part flattened on its own, so the "  /  " between them survives
            ; — collapsing the whole string afterwards would eat the separator
            ; that says where one message ends and the next begins.
            out .= (out = "" ? "" : "  /  ")
                 . RegExReplace(Trim(edCtrls[ck].Value), "\s+", " ")
    }
    return out
}

; Put a model's tab on the mass this window is about to write into — but only when
; it is not already there. Returns whether it had to move it.
;
; PickMassSlot RELOADS the boxes when you pick the slot they are already showing
; ("re-click = reload, a free undo"), and doing that behind a capture would throw
; away unsaved edits nobody was asked about. When the slot genuinely differs it is
; PickMassSlot's own prompt that asks, which is right — it is the same question the
; mass radios ask.
;
; Moving it also makes that slot the model's LIVE one, which is what its dropdown
; has always meant. Logged for that reason: it is the one thing this window can do
; that changes what a key sends without the key being pressed.
_AFW_AimAtMass(mNo, slot) {
    was := MassNoForModel(mNo)
    if (was = slot)
        return false
    LOGI("gui.altfu", "capture aimed at model " mNo " mass " slot " while its tab"
                    . " was showing mass " was " — switching, which also makes "
                    . slot " the slot this model's keys send")
    PickMassSlot(mNo, slot)
    return MassNoForModel(mNo) = slot
}

; "4 min ago", for the stamp MASS_RememberSent wrote. "" when there is no usable
; stamp — the sentence it appears in is then not shown at all, rather than shown
; with a hole in it.
_AFW_Ago(stamp) {
    if (Trim(stamp) = "")
        return ""
    try secs := DateDiff(A_Now, stamp, "Seconds")
    catch
        return ""
    if (secs < 0)
        return ""
    if (secs < 90)
        return "just now"
    if (secs < 5400)
        return Round(secs / 60) " min ago"
    if (secs < 172800)
        return Round(secs / 3600) " h ago"
    return Round(secs / 86400) " days ago"
}

; A stored field as one line, for the preview. The parts are separate messages;
; the preview is about telling wordings apart at a glance, not reading them.
_AFW_OneLine(v) {
    out := ""
    for _, p in MASS_SplitParts(v)
        out .= (out = "" ? "" : "  /  ") p
    out := RegExReplace(out, "\s+", " ")
    return StrLen(out) > 110 ? SubStr(out, 1, 109) Chr(0x2026) : out
}

; ── what the paste box means ──────────────────────────────────────────────────
;  Returns {marked, parts}, where parts is [{name, text}] in the order they should
;  be written and an empty `name` means "whatever the caller decided the default
;  is". The caller resolves that, because the default depends on the mass being
;  written to and this function knows nothing about any mass.
;
;  TWO SHAPES, and which one you get is decided by the paste itself:
;
;    no marker anywhere   Every non-blank line is one message of ONE branch. This
;                         is the common case — you have a wording, you want it as
;                         an alternative, you do not care what it is called.
;
;    any `::name` line    The paste is taken at its word and NOTHING is added. A
;                         marker opens a branch and every line under it belongs to
;                         that branch until the next marker, which is exactly the
;                         rule mass/parser.ahk applies to a real paste — so a block
;                         copied out of a mass, or out of the Discord message the
;                         mass came from, lands here meaning what it meant there.
;
;  Text BEFORE the first marker in a marked paste is dropped, not given to the
;  default branch. In every paste that has actually looked like this the leading
;  line was the trunk follow-up being copied along with its alternatives, and
;  silently filing the trunk as an alternative of itself is the kind of wrong that
;  reads as correct in the grid and doubles a message in the chat.
;
;  Detection is BranchMarker() from the parser and not a regex of this file's own:
;  two answers to "is this a marker" is two behaviours, and the one that would be
;  wrong is the one a fan sees.
_AFW_Plan(body) {
    lines  := StrSplit(StrReplace(body, "`r`n", "`n"), "`n")
    marked := false
    for _, ln in lines
        if BranchMarker(ln) {
            marked := true
            break
        }

    parts := []
    if !marked {
        for _, ln in lines
            if (Trim(ln) != "")
                parts.Push({name: "", text: Trim(ln)})
        return {marked: false, parts: parts}
    }

    cur := ""
    for _, ln in lines {
        if (Trim(ln) = "")
            continue
        m := BranchMarker(ln)
        if m {
            cur := m.name
            ; `::name` with nothing after it is a real thing to write: it means
            ; "this branch has nothing extra to say here". It opens the branch and
            ; contributes no message, the same as in a mass paste.
            if (m.body = "")
                continue
            parts.Push({name: cur, text: m.body})
            continue
        }
        if (cur = "")                       ; the trunk line above the markers
            continue
        parts.Push({name: cur, text: Trim(ln)})
    }
    return {marked: true, parts: parts}
}

_AFW_Join(cur, add) {
    if (add = "")
        return cur
    for _, have in StrSplit(cur, ", ")
        if (have = add)
            return cur
    return cur = "" ? add : cur ", " add
}

; ── which branch row a name owns on this mass ─────────────────────────────────
;  An existing row with that name (case-insensitively — `::Mexican` and
;  `::mexican` are a typo, not two branches), else the first row with no name at
;  all, else 0 for "this mass is full".
;
;  ─── WHY THIS IS NOT BranchSlot() FROM THE PARSER ────────────────────────────
;  The two answer different questions and it matters. BranchSlot numbers branches
;  AS IT MEETS THEM while building a mass from nothing, so slot N is simply the
;  Nth distinct name in the paste. This runs against a mass that already exists on
;  screen, where the row a name lives in was decided earlier — quite possibly by
;  hand — and "the Nth name I have seen" would put the new part in a row that
;  belongs to something else. Reusing it would have needed a fake registry
;  reconstructed from the grid, which is the same code as below with a trap in it:
;  a mass whose named rows have a GAP (clear row 1's name and row 2 keeps sending)
;  would renumber every branch under it.
_AFW_SlotFor(mNo, name) {
    global edCtrls, MASS_BRANCH_MAX
    want := StrLower(Trim(name))
    free := 0
    Loop MASS_BRANCH_MAX {
        ck := "m" mNo "_br" A_Index "_name"
        if !edCtrls.Has(ck)
            continue
        have := StrLower(Trim(edCtrls[ck].Value))
        if (have = want)
            return A_Index
        if (have = "" && !free)
            free := A_Index
    }
    return free
}

; "alt", or "alt1", "alt2"… — the first one this mass does not already use.
;
; Only reached when the Branch box is blank. A name you TYPED is never renamed
; behind your back: typing one that exists means "add to that branch", which is
; the whole point of a branch keeping its identity across follow-ups.
_AFW_FreeAltName(mNo) {
    global MASS_BRANCH_MAX
    if !_AFW_NameTaken(mNo, "alt")
        return "alt"
    Loop MASS_BRANCH_MAX + 1
        if !_AFW_NameTaken(mNo, "alt" A_Index)
            return "alt" A_Index
    return "alt"          ; every name taken: _AFW_AddPart refuses and says why
}

_AFW_NameTaken(mNo, name) {
    global edCtrls, MASS_BRANCH_MAX
    want := StrLower(name)
    Loop MASS_BRANCH_MAX {
        ck := "m" mNo "_br" A_Index "_name"
        if (edCtrls.Has(ck) && StrLower(Trim(edCtrls[ck].Value)) = want)
            return true
    }
    return false
}

; Append one message to a branch's answer for one group, in the grid.
;
; Returns "ok", or a short reason. The three rules are the parser's own — see
; AddBranchPart in mass/parser.ahk, which this deliberately mirrors:
;
;   • an empty body is a no-op, not an empty message. Sending silence to a fan is
;     worse than sending nothing.
;   • parts are newline-joined and capped at MASS_FU_PARTS, because there are
;     exactly that many sub-slots to send them in (f1, f1.5, f1.7).
;   • the branch's NAME is written as well as its text. A branch with text and no
;     name still sends, but the picker can only call it "branch 3" — which is not
;     a thing anyone can choose from under time pressure.
_AFW_AddPart(mNo, name, grp, body) {
    global edCtrls, MASS_FU_PARTS, MASS_BRANCH_MAX
    body := Trim(body)
    if (body = "")
        return "empty"
    name := Trim(name)
    if (name = "")
        return "no name"

    k := _AFW_SlotFor(mNo, name)
    if !k
        return "no free branch row (" MASS_BRANCH_MAX " max)"

    nk := "m" mNo "_br" k "_name"
    bk := "m" mNo "_br" k "_" grp
    if !edCtrls.Has(bk)
        return "no such field"

    cur := Trim(edCtrls[bk].Value)
    if (cur != "" && MASS_SplitParts(cur).Length >= MASS_FU_PARTS)
        return "'" name "' already has " MASS_FU_PARTS " parts here"

    if edCtrls.Has(nk)
        edCtrls[nk].Value := name
    edCtrls[bk].Value := (cur = "") ? body : cur "`r`n" body
    return "ok"
}
