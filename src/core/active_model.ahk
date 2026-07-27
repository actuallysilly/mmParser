#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "../mass/store.ahk"
#Include "../screen/pill_scan.ahk"
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
;  Three ways to decide, chosen in Settings (ARCHITECTURE.md §5.1):
;    name      OCR the tab and match it against [ActiveMap]/[ModelAliases]/the
;              model's display name. Survives reordering your tabs; depends on
;              names that differ across MMA, Infloww and Discord.
;    position  Use only the tab's place in the strip, mapped through [Positional].
;              No OCR, nothing to map; depends on the ORDER staying put.
;    manual    You say so, with a key, and MMA remembers until you say otherwise.
;              Reads no pixels at all.
;
;  The first two both go through the screen detector, so they share its failure
;  modes — and when it is wrong it is CONFIDENTLY wrong: a scan that groups two
;  tabs into one run reports "tab 1 of 1" forever, and every shared key then sends
;  model 1's messages no matter which model you are looking at. That is not
;  hypothetical, it is what detector_status.ini said while this was written.
;  Manual mode exists so the shared keys are usable while the detector is not
;  trustworthy on your screen: one keypress per model switch, never a guess.
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
    return _IniInt(MMA_DETECTOR, "detector", "active_index", 0)
}

; Where the lit pill is, in screen px, or -1. Written by the background service.
; Positional mode no longer reads it — it scans directly, because a value that
; refreshes every 500ms is stale exactly when you need it, which is the instant
; after you clicked a tab. Kept because the readout and external tools can watch
; it for free.
ReadActiveX() {
    return _IniInt(MMA_DETECTOR, "detector", "active_x", -1)
}

; An ini value as a number, or the default when it is not one.
;
; NOT Integer(IniRead(...)). IniRead hands back whatever is in the file and
; Integer() THROWS on anything that is not a number — and every caller of this is
; reached from #HotIf, which AHK re-evaluates on each keystroke. So one hand-typed
; `CurrentModel=one`, or a half-written file, is not a wrong answer: it is an
; error dialog per key you press, which is how the MASS_MODELS bug behaved.
; A setting MMA cannot read should degrade to the default, loudly in the log if
; anywhere, never into the typing path.
_IniInt(file, section, key, default) {
    v := Trim(IniRead(file, section, key, default))
    return IsInteger(v) ? Integer(v) : default
}

; "name" (default), "position" or "manual". See ActiveModelStatus.
ModelMatchMode() {
    return StrLower(Trim(IniRead(MMA_CFG, "Settings", "ModelMatch", "name")))
}

; ── manual mode ───────────────────────────────────────────────────────────────
; The model you last SAID you were on. Written by the mass.select* keys and by
; Settings; read on every press, so a switch takes effect immediately with no
; broadcast and no restart.
;
; Stored in the cfg rather than a global because the engine and the GUI are
; separate processes and both need the answer — the same reason the detector
; writes an ini instead of posting a message.
ManualModelNo() {
    global MASS_MODELS
    n := _IniInt(MMA_CFG, "Settings", "CurrentModel", 1)
    return (n >= 1 && n <= MASS_MODELS) ? n : 1
}

SetManualModel(n) {
    global MASS_MODELS
    if (n < 1 || n > MASS_MODELS)
        return false
    IniWrite(n, MMA_CFG, "Settings", "CurrentModel")
    return true
}

; What Settings calls this model. "" when the slot is unnamed — callers show the
; number in that case, so an unnamed slot is still selectable.
ModelDisplayName(n) {
    return Trim(IniRead(MMA_CFG, "Settings", "Model" n, ""))
}

; "2 — Rama", or just "2" for an unnamed slot. One label, so the toast the engine
; shows and the dropdown the GUI shows never drift apart.
ModelLabel(n) {
    disp := ModelDisplayName(n)
    return disp = "" ? String(n) : n " — " disp
}

; Tab position -> model slot, as ordered in Settings. Identity by default, so
; leftmost tab = model 1 until you say otherwise. Vestigial: it needs the detector
; to have COUNTED the tabs, which on a theme that draws inactive tabs as bare
; background it cannot. ResolveByTaughtX is the path that actually runs.
PositionalSlot(pos) {
    global MASS_MODELS
    if (pos < 1)
        return 0
    n := _IniInt(MMA_CFG, "Positional", "Pos" pos, pos)
    return (n >= 1 && n <= MASS_MODELS) ? n : 0
}

; ── which tab is lit, and which model that is ────────────────────────────────
;  Two steps, deliberately separate, because only ONE of them is a measurement.
;
;    1. WHICH TAB is in front    — from the screen. Pure colour, no OCR.
;    2. which MODEL that tab is  — from Settings. You said so; nothing is read.
;
;  Step 2 is not something a detector should ever try to work out. Tab 1 is Aliw
;  because you put it there, and no pixel on screen carries that fact. Every round
;  of this that went wrong went wrong by trying to infer it.
;
;  Step 1 is arithmetic, not a search, because model tab positions are FIXED: the
;  strip starts at TabOrigin and each tab is TabPitch wide, so the lit pill's x IS
;  the tab index. Nothing is counted — and counting was the part that could not
;  work here, since inactive tabs are drawn in the page background and are
;  invisible to a colour scan. Only the tab you are ON has to be visible, and it
;  is.
;
;  Both numbers are measured Infloww geometry (UI element map: strip starts x30,
;  pitch 150) and both live in mass_gui.cfg [Detector], so a zoom or theme change
;  is a config edit rather than a code change.

; ── reading the strip HERE, not via the detector service ─────────────────────
;  Positional mode used to read active_x out of detector_status.ini. That is one
;  indirection too many and it produced exactly the failure you would predict:
;  the service polls every 500ms and only while Infloww is the ACTIVE window, so
;  "click a tab, press the key" read a value from before the click — and both
;  models got taught the same x.
;
;  The pixels are right there. Read them. It costs ~80 PixelGetColor calls, which
;  is under a millisecond, and it is never stale by construction.
;
;  The service still runs: it owns the OCR that name mode needs. Positional mode
;  no longer depends on it at all.

; The [Detector] block, as numbers. Cached with the scan below — an IniRead per
; keystroke is the kind of cost that only shows up as "MMA feels laggy".
DetectorCfg() {
    hex := Trim(IniRead(MMA_CFG, "Detector", "GreyColor", "0x2B2C30"))
    return {
        x:    _IniInt(MMA_CFG, "Detector", "RegionX",  0),
        y:    _IniInt(MMA_CFG, "Detector", "RegionY",  0),
        w:    _IniInt(MMA_CFG, "Detector", "RegionW",  330),
        h:    _IniInt(MMA_CFG, "Detector", "RegionH",  50),
        tol:  _IniInt(MMA_CFG, "Detector", "GreyTol",  22),
        step: _IniInt(MMA_CFG, "Detector", "ScanStep", 4),
        gap:  _IniInt(MMA_CFG, "Detector", "GapTol",   12),
        min:  _IniInt(MMA_CFG, "Detector", "MinGrey",  6),
        origin: _IniInt(MMA_CFG, "Detector", "TabOrigin", 30),
        pitch:  _IniInt(MMA_CFG, "Detector", "TabPitch",  150),
        rgb:  Integer(RegExMatch(hex, "i)^0x") ? hex : "0x" hex),
        win:  Trim(IniRead(MMA_CFG, "Detector", "WinMatch", "Infloww Messages"))}
}

; Is Infloww actually in front? Every scan below is at FIXED SCREEN COORDINATES,
; so without this they happily measure whatever window is sitting there — which
; is how an earlier version of the detector read VS Code's menu bar and filed it
; as a model name.
DetectorWindowUp(cfg := 0) {
    if !cfg
        cfg := DetectorCfg()
    return cfg.win = "" || WinActive(cfg.win)
}

; Grab the tab strip once. Everything below reads from the returned buffer.
;
; One BitBlt costs about what a SINGLE PixelGetColor costs on this machine, and
; every pixel after it is free — see the header of screen/pill_scan.ahk for the
; measurements that forced this. Callers grab once and pass it down; a function
; that grabs its own copy per call is back to the slow path.
GrabStrip(cfg := 0) {
    if !cfg
        cfg := DetectorCfg()
    return PILL_Grab(cfg.x, cfg.y, cfg.w + 1, cfg.h + 1)
}

; Find the lit pill by sweeping the band. Returns the PILL_Scan record; .count = 0
; means nothing found. Used by the OCR path and the probe — NOT by the hotkey
; path, which knows where the tabs are and samples them directly.
;
; Does not check the window: callers that need that gate say so, and the probe
; deliberately does not, so it can show what the strip looks like while you are
; looking at Settings.
ScanLitPill(cfg := 0, img := 0) {
    if !cfg
        cfg := DetectorCfg()
    if !img
        img := GrabStrip(cfg)
    if !img
        return {count: 0, avgX: -1, minX: 0, maxX: -1, index: 0, total: 0}
    return PILL_Scan(img, cfg.x, cfg.y, cfg.x + cfg.w, cfg.y + cfg.h,
                     cfg.rgb, cfg.rgb, cfg.tol, cfg.step, cfg.gap)
}

; Screen x -> tab index, 1-based, left to right. 0 = outside the strip.
;
; The entire positional detection, in one line of arithmetic. Everything that came
; before it — grouping runs, counting tabs, matching centroids against taught
; coordinates within a derived tolerance — was an elaborate attempt to discover
; something that was never unknown: where tab 2 is.
TabIndexFromX(x, cfg := 0) {
    if (x < 0)
        return 0
    if !cfg
        cfg := DetectorCfg()
    if (cfg.pitch < 1 || x < cfg.origin)
        return 0
    return ((x - cfg.origin) // cfg.pitch) + 1
}

; Tab index -> model slot, straight from the Settings "Tab order" dropdowns.
; Identity by default, so the leftmost tab is model 1 until you reorder them.
TabModel(index) {
    return PositionalSlot(index)
}

; The x range tab `i` occupies, inset a little so a neighbour's edge or the
; rounded corner of this one cannot contribute.
TabRange(i, cfg) {
    x1 := cfg.origin + (i - 1) * cfg.pitch
    return {x1: x1 + 8, x2: x1 + cfg.pitch - 8}
}

; WHICH TAB is lit, sampled at the fixed slots. 0 = no clear answer.
;
; This is the hot path — reached from #HotIf, so on every keystroke — which is why
; it samples a handful of columns per slot instead of sweeping the band. A sweep
; is ~1000 GDI GetPixel calls and stalls typing; this is ~50 and does not.
;
; Also returns the counts, because they are the only useful diagnostic: two slots
; both showing a big number means one pill is straddling two slots, i.e. TabPitch
; is wrong. Without them "no answer" is unactionable.
TabLitIndex(cfg := 0, img := 0) {
    global MASS_MODELS
    if !cfg
        cfg := DetectorCfg()
    if !img
        img := GrabStrip(cfg)
    counts := []
    if !img {
        Loop MASS_MODELS
            counts.Push(-1)
        return {index: 0, counts: counts}
    }
    xstep := Max(4, cfg.pitch // 8)
    Loop MASS_MODELS {
        r := TabRange(A_Index, cfg)
        counts.Push(PILL_CountIn(img, r.x1, r.x2, cfg.y, cfg.y + cfg.h,
                                 cfg.rgb, cfg.tol, xstep, cfg.step))
    }
    return {index: PILL_PickLit(counts, cfg.min), counts: counts}
}

; Set the order by POINTING at it: pressing "active model = 2" while model 2's tab
; is in front records "whatever tab index that is, is model 2".
;
; The same fact the dropdowns hold, entered the way you actually know it. Nobody
; knows their tab is index 2; everybody knows the tab they are looking at is Rama.
SetTabOrderFor(index, n) {
    global MASS_MODELS
    if (index < 1 || index > MASS_MODELS || n < 1 || n > MASS_MODELS)
        return false
    IniWrite(n, MMA_CFG, "Positional", "Pos" index)
    return true
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
;   "unlearned"  positional mode, a pill on screen, and nothing taught yet — the
;                one state a message can fix. Press a mass.select key on each tab.
;
; Deliberately read-only. This runs from #HotIf, i.e. as you type, so it must not
; write the ini and must never open a dialog. The GUI owns the asking; see
; PromptUnmappedModel in main_window.ahk.
ActiveModelStatus() {
    global MASS_MODELS, MMA_CFG

    mode := ModelMatchMode()

    ; ── manual mode ───────────────────────────────────────────────────────────
    ; No screen reading of any kind. You pressed a key that said "model 2", so the
    ; answer is model 2 until you press another one. Always "ok": there is no such
    ; thing as an unrecognised name or an ambiguous scan here, which is the whole
    ; point — the shared keys work on a machine where the detector does not.
    ;
    ; The cost, stated plainly: MMA cannot notice you switched tabs. Change model
    ; in Infloww without pressing the select key and the next shared key sends the
    ; previous model's message. That is why the select keys show a toast — the
    ; confirmation IS the safety mechanism.
    if (mode = "manual") {
        n := ManualModelNo()
        return {no: n, name: ModelDisplayName(n), state: "ok"}
    }

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
    if (mode = "position")
        return _PositionalStatus()

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

; ── positional mode, resolved from the screen ────────────────────────────────
;  Cached for 250ms, and that is not an optimisation detail — this is reached
;  from #HotIf, which AHK re-evaluates on EVERY keystroke while you type. Without
;  a cache, a paragraph typed into a fan's chat is a few hundred pixel scans.
;  250ms is far below the time it takes a human to click a tab and press a key,
;  so nothing observable is ever stale.
global _AM_CACHE_T := 0
global _AM_CACHE_R := 0

_PositionalStatus() {
    global _AM_CACHE_T, _AM_CACHE_R
    now := A_TickCount
    if (_AM_CACHE_R && now - _AM_CACHE_T < 250)
        return _AM_CACHE_R

    cfg := DetectorCfg()
    res := _PositionalStatusUncached(cfg)
    _AM_CACHE_T := now, _AM_CACHE_R := res
    return res
}

_PositionalStatusUncached(cfg) {
    global MASS_MODELS
    ; Fixed screen coordinates, so this MUST be gated on the window. Otherwise
    ; the scan measures whatever is at those pixels and names a model from it.
    if !DetectorWindowUp(cfg)
        return {no: 0, name: "", state: "none"}

    idx := TabLitIndex(cfg).index
    if (idx < 1)
        return {no: 0, name: "", state: "none"}      ; no tab clearly lit

    slot := TabModel(idx)
    if (!slot)
        return {no: 0, name: "tab " idx, state: "unknown"}
    return {no: slot, name: "tab " idx, state: "ok"}
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
;  MODEL KNOWN — the detector resolved a model, or you selected one by hand in
;    manual mode. Either way something authoritative says which model is in
;    front, so bare __mm is unambiguous: it means "this one".
;
;  MODEL UNKNOWN — no answer from anywhere. Nothing says which model you mean, so
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
