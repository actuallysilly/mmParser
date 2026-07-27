#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "../mass/store.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  active_model.ahk — which of your models is on screen right now.
; ───────────────────────────────────────────────────────────────────────────────
;  Split out of utils.ahk because BOTH sides need it and neither should have to
;  take the other's baggage: the mass engine asks it on every keypress, and the
;  GUI asks it to decide whether to prompt about an unrecognised name. main_window
;  does not include utils.ahk — utils registers hotstrings and send helpers the
;  GUI has no business owning, which is the same reason crashlog.ahk was split
;  out — so calling these from there was a load-time 'nonexistent function'.
;
;  Two ways to decide, chosen in Settings (ARCHITECTURE.md §5.1):
;    name      OCR the tab and match it against [ActiveMap]/[ModelAliases]/the
;              model's display name. Survives reordering your tabs; depends on
;              names that differ across MMA, Infloww and Discord.
;    position  Use only the tab's place in the strip, mapped through [Positional].
;              No OCR, nothing to map; depends on the ORDER staying put.
; ═══════════════════════════════════════════════════════════════════════════════

; ── which model is on screen ──────────────────────────────────────────────────
; The detector writes the focused model's NAME to detector_status.ini; [ActiveMap]
; in mass_gui.cfg maps each model slot to a name. Together they answer "which of
; my three models is the user looking at".
;
; v1 needed a lot more than this, because the three models were three PROCESSES
; that all tried to bind the same physical keys. StartFuGating ran a 350ms timer
; in each one, re-reading this file off disk to switch the other models' hotkeys
; Off; FuGate re-checked inside every handler; HK_ModelSendIds listed which ids
; were shared; and hotkeys_window had to exempt those ids from its own conflict
; report so it would not cry wolf. All five existed to arbitrate between
; processes. One process needs none of them, and they are gone.
ReadActiveModel() {
    return Trim(IniRead(MMA_DETECTOR, "detector", "active_model", ""))
}

; Which TAB is in front, counting from the left, or 0 for "no answer". Costs the
; detector no OCR at all — it falls out of the same pixel scan that finds the lit
; pill — which is why positional mode still works when OCR reads nothing.
ReadActiveIndex() {
    return Integer(IniRead(MMA_DETECTOR, "detector", "active_index", "0"))
}

; "name" (default) or "position". See ActiveModelStatus.
ModelMatchMode() {
    return StrLower(Trim(IniRead(MMA_CFG, "Settings", "ModelMatch", "name")))
}

; Tab position -> model slot, as ordered in Settings. Identity by default, so
; leftmost tab = model 1 until you say otherwise.
PositionalSlot(pos) {
    global MASS_MODELS
    if (pos < 1)
        return 0
    n := Integer(IniRead(MMA_CFG, "Positional", "Pos" pos, pos))
    return (n >= 1 && n <= MASS_MODELS) ? n : 0
}

; Which model slot the detector is pointing at, or 0 for "no answer" — detector
; off, Infloww not visible, or a name that matches no slot.
;
; An UNNAMED slot auto-claims the current name, lowest-numbered first, so a fresh
; install wires itself up the first time you use it instead of needing the map
; filled in by hand.
; Three ways a slot can own the detected text, tried per slot:
;   1. [ActiveMap] File<n>   — the explicit map, exact. Written by the auto-claim
;                              below, or by hand.
;   2. [ModelAliases]        — the alias table you can already edit for the
;                              Discord import. It existed and this never read it,
;                              which is why an alias of rama=2 did nothing here.
;   3. [Settings] Model<n>   — the display name, as a SUBSTRING. Infloww's tab
;                              says "Bellarama" where MMA says "Rama"; requiring
;                              equality meant a name you would call a match
;                              was not one.
;
; MORE THAN ONE MATCH RETURNS 0, deliberately. If the detected text contains two
; models' names there is no way to tell which tab is in front, and the cost of
; guessing is one model's mass sent to the other's fan. 0 means "no answer", which
; falls back to the manual keys — the safe direction.
;
; The `global` line is not decoration. AHK v2 makes every name inside a function
; LOCAL unless declared, so `Loop MASS_MODELS` without it reads an unset local and
; THROWS — and this is reached from #HotIf, which AHK re-evaluates as you type, so
; that is one dialog per keystroke rather than one.
ActiveModelNo() {
    return ActiveModelStatus().no
}

; The same answer, plus WHY, for callers that can do something about it.
;
; state is one of:
;   "none"       detector off, or Infloww not in front. Manual keys, no problem.
;   "ok"         exactly one slot owns the name; .no is it.
;   "unknown"    a plausible single name that maps to no slot — the case worth
;                ASKING about, e.g. Infloww says "Bellarama" and nothing claims it.
;   "ambiguous"  the text matches more than one slot, so it is almost certainly
;                two tabs read as one. Never ask about this: the answer would put
;                a string containing both models' names into one model's map.
;
; Deliberately read-only. This runs from #HotIf, i.e. as you type, so it must not
; write the ini and must never open a dialog. The GUI owns the asking; see
; PromptUnmappedModel in main_window.ahk.
ActiveModelStatus() {
    global MASS_MODELS, MMA_CFG

    ; ── positional mode ───────────────────────────────────────────────────────
    ; Names are the hard part of this: MMA, Infloww and Discord each have their
    ; own, they drift, and OCR has to read them off a 13px pill. Position needs
    ; none of that — the leftmost tab is the leftmost tab. You order your models
    ; once in Settings to match the strip, and the follow-up keys follow whichever
    ; tab is in front.
    ;
    ; The trade is stated plainly because it matters: this trusts the ORDER of
    ; your tabs. Drag one, or open them in a different order tomorrow, and the
    ; keys follow the position rather than the person. Name mode survives that;
    ; this does not. It is the fallback for when names cannot be made to work.
    if (ModelMatchMode() = "position") {
        pos := ReadActiveIndex()
        if (pos < 1)
            return {no: 0, name: "", state: "none"}
        slot := PositionalSlot(pos)
        if (!slot)
            return {no: 0, name: "tab " pos, state: "unknown"}
        return {no: slot, name: "tab " pos, state: "ok"}
    }

    active := Trim(ReadActiveModel())
    if (active = "")
        return {no: 0, name: "", state: "none"}
    cfg  := MMA_CFG
    hits := []
    Loop MASS_MODELS
        if _SlotOwnsName(cfg, A_Index, active)
            hits.Push(A_Index)
    if (hits.Length = 1)
        return {no: hits[1], name: active, state: "ok"}
    if (hits.Length > 1)
        return {no: 0, name: active, state: "ambiguous"}
    return {no: 0, name: active, state: "unknown"}
}

; Teach a slot one more on-screen name. [ActiveMap] File<n> is a COMMA-SEPARATED
; list because one model has more than one external name — Infloww shows
; "Bellarama" where Discord says "Rama" — and both have to resolve to the same
; slot. Appends; never replaces what is already there.
ActiveMapAdd(n, name) {
    global MMA_CFG
    name := Trim(name)
    if (name = "")
        return
    cur := Trim(IniRead(MMA_CFG, "ActiveMap", "File" n, ""))
    for existing in StrSplit(cur, ",")
        if (StrLower(Trim(existing)) = StrLower(name))
            return
    IniWrite(cur = "" ? name : cur "," name, MMA_CFG, "ActiveMap", "File" n)
}

_SlotOwnsName(cfg, n, active) {
    ; Substring, not equality — and that matters for the AMBIGUITY check as much
    ; as for matching. "AW Bellarama" (two tabs read as one) has to count as
    ; evidence for slot 1 as well as slot 2, or exactly one slot matches, the
    ; caller sees no ambiguity, and it confidently returns the wrong model.
    ;
    ; A comma-separated LIST, because one model wears more than one name: MMA
    ; calls it Rama, Infloww's tab says Bellarama, Discord's channel says
    ; something else again. All of them point at the same slot.
    for mapped in StrSplit(Trim(IniRead(cfg, "ActiveMap", "File" n, "")), ",") {
        mapped := Trim(mapped)
        if (mapped != "" && InStr(active, mapped))
            return true
    }
    disp := Trim(IniRead(cfg, "Settings", "Model" n, ""))
    if (disp != "" && InStr(active, disp))          ; InStr is case-insensitive
        return true
    for line in StrSplit(Trim(IniRead(cfg, "ModelAliases", , "")), "`n", "`r") {
        eq := InStr(line, "=")
        if (!eq)
            continue
        alias := Trim(SubStr(line, 1, eq - 1))
        slot  := Trim(SubStr(line, eq + 1))
        if (alias != "" && slot = String(n) && InStr(active, alias))
            return true
    }
    return false
}

; An unknown name worth ASKING about: one plausible model name, not two tabs run
; together and not a stray window's chrome.
;
; This replaced a silent auto-claim that gave any unrecognised string to the first
; empty slot. That is how the detector's header describes
; "File Edit Selection View Go R" ending up as a model's identity and permanently
; gating its keys off. A wrong slot claim is silent and sticky; a question is
; neither, and the names genuinely do not match across Discord/Infloww/MMA, so
; there is no rule that could get this right without being told.
IsAskableModelName(name) {
    name := Trim(name)
    if (name = "" || StrLen(name) > 24)
        return false
    return !RegExMatch(name, "\s")
}

; ── __mm  vs  __mm1 / __mm2 / __mm3 ───────────────────────────────────────────
;  Two ways to say "send the whole mass", and which is live depends on whether
;  the detector is running. See ARCHITECTURE.md §5.2.
;
;  DETECTOR ON  — "automatic mode". The screen says which model is in front, so
;    bare __mm is unambiguous: it means "this one".
;
;  DETECTOR OFF — "manual mode". Nothing on screen says which model you mean, so
;    bare __mm has no correct answer. v1 guessed and always fired model 1, which
;    meant a manual model-2 user typing __mm did not get nothing — they got MODEL
;    1's mass, sent to their fan. A wrong mass is worse than no expansion, so bare
;    __mm is disabled and the numbered triggers take over. __mm2 means model 2
;    because you said so: the thing you type IS the model selector, same contract
;    as the manual F-keys.
;
;  The two are mutually exclusive BY CONSTRUCTION, not by preference. __mm is
;  declared :*X:, and `*` means "fire as soon as the trigger is typed, no ending
;  character" — so while __mm is live it expands the instant you type the second
;  m, and the `1` in __mm1 is never reached. Gating the numbered triggers on the
;  same condition that silences __mm keeps "what is registered" equal to "what can
;  actually fire", instead of leaving three hotstrings that look bound and cannot.

UniversalSendActive() {
    return ActiveModelNo() != 0
}

NumberedSendActive(n) {
    return ActiveModelNo() = 0        ; manual mode only; see above
}
