#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "modes.ahk"
#Include "../mass/store.ahk"
#Include "../screen/fansly_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  fansly_model.ahk — which of your models is on the Fansly rail right now.
; ───────────────────────────────────────────────────────────────────────────────
;  The Fansly counterpart to the detector half of core/active_model.ahk, kept in
;  its own file so the two platforms share no state, no config and no tuning. The
;  ONE place they meet is ActiveModelStatus(), which asks this first and falls
;  through to the Infloww path when the Fansly window is not in front. That is
;  the whole integration, and it is deliberately one branch: routing by "which
;  window am I actually looking at" needs no setting, no mode and no guess.
;
;  ─── TWO MODES, AND WHY POSITION IS THE DEFAULT HERE ─────────────────────────
;  On Infloww, name mode is the default and position is the fallback. On Fansly
;  it is the other way round, for reasons that are properties of the interface
;  rather than preferences:
;
;    • The rail truncates. The label reads "KB FANS…", "Luxdo Fa…", "SRA FAN…" —
;      there is no full name on screen to read, at any OCR quality. Matching is
;      therefore substring matching (it already was, for Infloww's "Bellarama"
;      vs MMA's "Rama"), and a truncated prefix is a weaker key: two models whose
;      names start alike are indistinguishable, and the honest answer to that is
;      0, not a coin flip. See FanslySlotOwnsName.
;    • The rows are tall, evenly pitched and in a fixed order. Position is
;      arithmetic on a number the scan already produced, needs no OCR, and works
;      on a theme where unselected cards are drawn as bare background and cannot
;      be seen at all.
;
;  The cost of positional mode, stated plainly because it is real: it trusts the
;  ORDER of the rail. If Fansly ever reorders it — an unread badge floating a
;  model to the top would do it — the keys follow the position rather than the
;  person, silently. That is the one thing to watch for on this platform, and it
;  is why name mode exists here at all: it is the check on the order.
;
;  ─── NOTHING HERE WRITES, AND NOTHING HERE ASKS ──────────────────────────────
;  Everything below is reached from #HotIf, which AHK re-evaluates on EVERY
;  KEYSTROKE while you type into a fan's chat. So: no IniWrite, no dialog, no
;  unguarded Integer(), and the pixel work is cached. The GUI owns the asking.
; ═══════════════════════════════════════════════════════════════════════════════

; "position" (default) or "name". See the header for why the default is not the
; same as Infloww's.
FanslyMatchMode() {
    m := StrLower(Trim(IniRead(MMA_CFG, "Fansly", "Match", "position")))
    return (m = "name") ? "name" : "position"
}

; ── what the background service last saw ─────────────────────────────────────
; Its own file, never a section of detector_status.ini — see the note beside
; MMA_FANSLY in paths.ahk for why two services must not share one key.
ReadFanslyName() {
    return Trim(IniRead(MMA_FANSLY, "fansly", "active_model", ""))
}

ReadFanslyIndex() {
    return LOG_IniInt(MMA_FANSLY, "fansly", "active_index", 0, "fansly.status")
}

ReadFanslyY() {
    return LOG_IniInt(MMA_FANSLY, "fansly", "active_y", -1, "fansly.status")
}

; ── rail row -> model slot ───────────────────────────────────────────────────
;  Two steps, deliberately separate, because only ONE of them is a measurement:
;
;    1. WHICH ROW is selected  — from the screen. Pure colour, no OCR.
;    2. which MODEL that is    — from settings. You said so; nothing is read.
;
;  Step 2 is not something a detector should ever try to work out. Row 2 is Luxdo
;  because you put her there, and no pixel on screen carries that fact.
;
;  Identity by default, so the top row is model 1 until you say otherwise. Its
;  own [FanslyPos] section rather than reusing [Positional]: that one describes
;  the left-to-right order of the Infloww tabs, and the two orders have no reason
;  on earth to match.
FanslyPosSlot(row) {
    global MASS_MODELS
    if (row < 1)
        return 0
    n := LOG_IniInt(MMA_CFG, "FanslyPos", "Pos" row, row, "fansly.cfg")
    return (n >= 1 && n <= MASS_MODELS) ? n : 0
}

; Teach the rail order by POINTING at it: "the row I am on is model 2". The same
; fact the dropdowns hold, entered the way you actually know it — nobody knows
; their card is row 2, everybody knows the card they are looking at is Luxdo.
;
; The one writer in this file, and it is called from a key press, never from
; #HotIf.
SetFanslyPosFor(row, n) {
    global MASS_MODELS
    if (row < 1 || row > 12 || n < 1 || n > MASS_MODELS)
        return false
    LOGI("fansly.teach", "rail row " row " is model " n)
    IniWrite(n, MMA_CFG, "FanslyPos", "Pos" row)
    return true
}

; ── name -> model slot ───────────────────────────────────────────────────────
; Three ways a slot can own the text OCR read, tried in order:
;   1. [FanslyMap] File<n>  — the explicit map, comma-separated, its own section
;                             so a Fansly display name cannot collide with an
;                             Infloww one under [ActiveMap].
;   2. [ModelAliases]       — the shared alias table, which the Discord import
;                             already uses. Reused rather than duplicated: an
;                             alias is a fact about the model, not the platform.
;   3. [Settings] Model<n>  — the display name, as a SUBSTRING both ways.
;
; SUBSTRING BOTH WAYS is the part that is specific to Fansly. Elsewhere it is
; enough to ask whether the mapped name appears in the detected text. Here the
; detected text is TRUNCATED — the rail shows "Luxdo Fa…" for a model MMA calls
; "Luxdo Fansly" — so the mapped name does not appear in it; the detected text
; appears in the mapped name. Requiring the usual direction meant a name you
; would call an obvious match was not one.
;
; The truncation is also why this is the weaker mode. "KB FANS…" and a second
; model called "KB Fansly VIP" both match, ActiveModelStatus refuses on more than
; one hit, and the shared keys go quiet — correctly, but invisibly.
FanslySlotOwnsName(n, text) {
    if (text = "")
        return false
    for mapped in StrSplit(Trim(IniRead(MMA_CFG, "FanslyMap", "File" n, "")), ",") {
        mapped := Trim(mapped)
        if (mapped != "" && _FanTouches(text, mapped))
            return true
    }
    disp := Trim(IniRead(MMA_CFG, "Settings", "Model" n, ""))
    if (disp != "" && _FanTouches(text, disp))
        return true
    for line in StrSplit(IniRead(MMA_CFG, "ModelAliases", "", ""), "`n", "`r") {
        eq := InStr(line, "=")
        if !eq
            continue
        alias := Trim(SubStr(line, 1, eq - 1))
        slot  := Trim(SubStr(line, eq + 1))
        if (alias != "" && slot = String(n) && _FanTouches(text, alias))
            return true
    }
    return false
}

; Does one of these two strings contain the other? InStr is case-insensitive, so
; "LUXDO FA" matches "Luxdo Fansly" without any normalising.
;
; The 3-character floor is not decoration. OCR of an 11px dim label produces
; single characters and stray punctuation on a bad read, and a one-character
; "name" is inside almost every model name there is — so without this the first
; garbled frame claims a slot and the keys start sending the wrong model's mass.
; Better to have no answer.
_FanTouches(detected, known) {
    detected := Trim(RegExReplace(detected, "[.…]+$"))   ; drop the truncation mark
    if (StrLen(detected) < 3 || StrLen(known) < 3)
        return false
    return InStr(known, detected) || InStr(detected, known) ? true : false
}

; Teach a slot one more on-screen name. [FanslyMap] File<n> is COMMA-SEPARATED,
; because one model can be spelled several ways and none of them should have to
; be deleted to add another.
FanslyMapAdd(n, name) {
    name := Trim(name)
    if (name = "")
        return
    cur := Trim(IniRead(MMA_CFG, "FanslyMap", "File" n, ""))
    for have in StrSplit(cur, ",")
        if (Trim(have) = name)
            return
    LOGI("fansly.teach", "model " n " also answers to '" name "' on the rail")
    IniWrite(cur = "" ? name : cur "," name, MMA_CFG, "FanslyMap", "File" n)
}

; ── the answer ───────────────────────────────────────────────────────────────
;  Cached for 250ms, and that is not an optimisation detail: this is reached from
;  #HotIf, so a paragraph typed into a chat would otherwise be a few hundred rail
;  scans. 250ms is far below the time it takes a human to click a card and press
;  a key, so nothing observable is ever stale.
global _FAN_CACHE_T := 0
global _FAN_CACHE_R := 0

; {no, name, state}. state is one of:
;   "off"        Fansly is not what you are looking at — the feature is off or
;                its window is not in front. The ONLY state that means "ask the
;                Infloww path instead", which is why it is distinct from "none".
;   "ok"         .no is the model on the rail.
;   "none"       Fansly IS in front and nothing reads as selected. A real
;                failure: wrong RegionY, wrong CardTol, or the rail scrolled.
;   "unlearned"  a card is lit, name mode is on, and nothing claims the text.
;   "ambiguous"  the truncated label matches more than one slot. Never guess —
;                the cost of guessing is one model's mass in another's chat.
FanslyStatus() {
    global _FAN_CACHE_T, _FAN_CACHE_R
    now := A_TickCount
    if (_FAN_CACHE_R && now - _FAN_CACHE_T < 250)
        return _FAN_CACHE_R
    res := _FanslyStatusUncached()
    _FAN_CACHE_T := now, _FAN_CACHE_R := res
    return res
}

_FanslyStatusUncached() {
    ; FEAT first, and cheapest: with the feature off this must cost one ini read
    ; and get out of the way, because every keystroke in Infloww passes through
    ; here on its way to the detector that IS switched on.
    if !FEAT("fanslyDetector")
        return {no: 0, name: "", state: "off"}

    cfg := FanslyCfg()
    if !FanslyWindowUp(cfg)
        return {no: 0, name: "", state: "off"}

    ; Scanned HERE rather than read out of fansly_status.ini, and for the reason
    ; the Infloww positional path learned the hard way: the service polls every
    ; 500ms, so "click a card, press the key" reads a value from before the
    ; click. The pixels are right there and one BitBlt of the rail is under a
    ; millisecond. Never stale, by construction.
    lit := FanslyLitRow(cfg)
    if !lit.index {
        LOG_Bail("fansly.resolve", "'" cfg.win "' is in front but no row on the rail"
                                 . " reads as selected, so every [mass.active]"
                                 . " shared key will do nothing. Per-row counts: "
                                 . _FanCounts(lit.counts) ". Run"
                                 . " tools\fansly_probe.ahk — this is normally"
                                 . " RegionY, CardTol, or the rail having scrolled.")
        return {no: 0, name: "", state: "none"}
    }

    if (FanslyMatchMode() = "position") {
        n := FanslyPosSlot(lit.index)
        if !n {
            LOGW("fansly.resolve", "rail row " lit.index " is selected but no model"
                                 . " slot claims it. Press a mass.select key on"
                                 . " this card, or set [FanslyPos] Pos" lit.index
                                 . " in mass_gui.cfg.")
            return {no: 0, name: "", state: "unlearned"}
        }
        LOGV("fansly.resolve", "rail row " lit.index " → model " n)
        return {no: n, name: FanslyDisplayName(n), state: "ok"}
    }

    ; ── name mode ────────────────────────────────────────────────────────────
    ; The service owns the OCR, so this reads what it last wrote. That IS one
    ; poll stale, unlike the row above — which is the honest reason positional is
    ; the default on this platform and not merely the simpler one.
    text := ReadFanslyName()
    if (text = "") {
        LOG_Bail("fansly.resolve", "name mode: fansly_status.ini has no name."
                                 . " The rail's labels are truncated and dim, so"
                                 . " this is the expected outcome more often than"
                                 . " not — set [Fansly] Match=position.")
        return {no: 0, name: "", state: "none"}
    }
    hits := []
    Loop MASS_MODELS
        if FanslySlotOwnsName(A_Index, text)
            hits.Push(A_Index)
    if (hits.Length = 1)
        return {no: hits[1], name: text, state: "ok"}
    if (hits.Length > 1) {
        LOGW("fansly.resolve", "name mode: OCR read '" text "' which matches "
                             . hits.Length " models at once, so MMA refuses to"
                             . " guess. The rail truncates names, so two models"
                             . " sharing a prefix will always do this — use"
                             . " [Fansly] Match=position.")
        return {no: 0, name: text, state: "ambiguous"}
    }
    LOGW("fansly.resolve", "name mode: OCR read '" text "' and no model claims it."
                         . " Add it under [FanslyMap] File<n> in mass_gui.cfg.")
    return {no: 0, name: text, state: "unknown"}
}

; What Settings calls this model. "" when the slot is unnamed — callers show the
; number then, so an unnamed slot is still usable.
FanslyDisplayName(n) {
    return Trim(IniRead(MMA_CFG, "Settings", "Model" n, ""))
}

_FanCounts(counts) {
    out := ""
    for i, n in counts
        out .= (out = "" ? "" : " ") "r" i "=" n
    return out = "" ? "(none)" : out
}
