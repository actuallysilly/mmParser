#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings/usage.ahk — which hotstrings you actually use, and which you pinned.
; ───────────────────────────────────────────────────────────────────────────────
;  The library is ~120 triggers and growing. Two of them are 80% of a shift and
;  you know their abbreviations by heart; the rest you half-remember, and finding
;  one means opening the manager and searching. This module is what makes the
;  quick menu (hotstrings/quick_menu.ahk) possible: the short list of what you
;  reached for last, and the shorter list of what you told MMA to keep at hand.
;
;  userdata\hotstring_usage.ini — two sections, both keyed by TRIGGER:
;
;      [Used]
;      _gns1 = 20260830140312907|42     ; when it last fired | times fired
;
;      [Pinned]
;      _gtittyfck = 20260830140312907   ; when it was pinned
;
;  A wall-clock stamp rather than a tick count or an epoch, because it sorts as a
;  STRING — which is the only ordering primitive an ini gives you — and because
;  it is readable when you open the file. See HSU_Stamp for why it carries the
;  milliseconds.
;
;  ─── WHY AN INI AND NOT A SHARED VARIABLE ────────────────────────────────────
;  Every message file is a separate PROCESS (content\general.ahk, each account
;  file), and any of them can be the one whose hotstring just fired. The quick
;  menu runs in a third. So "what did I use recently" has to survive crossing a
;  process boundary, and MMA's answer to that question everywhere else is a file
;  in userdata\. See MMA_DETECTOR and MMA_FANSLY in core\paths.ahk for the same
;  pattern, and for the one rule it comes with: separate concerns, separate files.
;
;  ─── THE COST, STATED ────────────────────────────────────────────────────────
;  HSU_Note runs inside a send, which is a keystroke path. It is one IniRead of a
;  small section plus one IniWrite — Windows caches ini files, and the send it
;  rides along with is already doing clipboard work and a Sleep of a second and a
;  half. Pruning is the only unbounded part, so it happens only when the section
;  has grown past HSU_PRUNE_AT rather than on every fire.
; ═══════════════════════════════════════════════════════════════════════════════

; Anchored to the one anchor, like every other userdata file.
#Include "../core/paths.ahk"

global HSU_INI := MMA_USAGE

; How many triggers [Used] remembers, and how far it is allowed to grow before a
; write trims it back. The gap between the two is what keeps pruning rare: a
; trim happens once every thirty new triggers, not on every send.
global HSU_KEEP     := 60
global HSU_PRUNE_AT := 90

; ── when did this happen? ────────────────────────────────────────
;  A_Now to the second, plus A_MSec. The milliseconds are not decoration: A_Now
;  alone TIES for two hotstrings sent in the same second, and the sort is stable
;  — so the recent list then orders that pair by whatever order the ini happened
;  to enumerate, which is exactly wrong for the two you just used. They are the
;  pair the menu is most for. A_MSec is already zero-padded to three digits, so
;  the whole stamp stays fixed-width and therefore string-sortable.
HSU_Stamp() {
    return A_Now A_MSec
}

; ── what may be an ini key ────────────────────────────────────────────────────
;  An `=` is the one character that cannot work, for exactly the reason the
;  [hotstring] section in core\hotkeys.ahk gives: it is what separates a key from
;  its value, so IniWrite of the trigger `a=b` emits `a=b=…` and reads back as
;  the trigger "a". A leading `;` is a comment marker and a leading `[` opens a
;  section, so both would write a line the reader cannot see again.
;
;  No trigger in the library has any of them. This returns false rather than
;  refusing loudly because the caller is a SEND: a message going out is not the
;  moment to raise a dialog about bookkeeping, and the trigger still works — it
;  just never appears in the quick menu.
HSU_Usable(trigger) {
    trigger := Trim(trigger)
    if (trigger = "" || InStr(trigger, "="))
        return false
    return !InStr(";[", SubStr(trigger, 1, 1))
}

; ── reading ───────────────────────────────────────────────────────────────────

; The whole [Used] section as Map(trigger -> {at, count}).
;
; Guarded: this is read from the quick menu and from every send, and a
; hand-mangled line must cost that line and nothing else. A value with no "|" is
; read as a timestamp with a count of 1, which is what the file would have looked
; like if it had been written by an older version of this module.
HSU_Uses() {
    global HSU_INI
    out := Map()
    if !FileExist(HSU_INI)
        return out
    body := ""
    try body := IniRead(HSU_INI, "Used", , "")
    catch
        return out
    for line in StrSplit(body, "`n", "`r") {
        eq := InStr(line, "=")
        if !eq
            continue
        trg := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (trg = "")
            continue
        bar := InStr(val, "|")
        at  := bar ? Trim(SubStr(val, 1, bar - 1)) : val
        cnt := bar ? Trim(SubStr(val, bar + 1))    : "1"
        out[trg] := {at: at, count: IsInteger(cnt) ? Integer(cnt) : 1}
    }
    return out
}

; The most recently used triggers, newest first: [{trigger, at, count}, …].
; `limit` of 0 means all of them.
HSU_Recent(limit := 0) {
    rows := []
    for trg, u in HSU_Uses()
        rows.Push({trigger: trg, at: u.at, count: u.count})
    ; Insertion sort, newest `at` first. Same reasoning as HK_HotstringTriggers:
    ; a handful of entries, and AHK v2 has no Array.Sort to lean on.
    Loop rows.Length - 1 {
        i := A_Index + 1
        v := rows[i]
        j := i - 1
        while (j >= 1 && StrCompare(rows[j].at, v.at) < 0) {
            rows[j + 1] := rows[j]
            j--
        }
        rows[j + 1] := v
    }
    if (limit > 0 && rows.Length > limit)
        rows.Length := limit
    return rows
}

HSU_Count(trigger) {
    u := HSU_Uses()
    return u.Has(Trim(trigger)) ? u[Trim(trigger)].count : 0
}

HSU_LastUsed(trigger) {
    u := HSU_Uses()
    return u.Has(Trim(trigger)) ? u[Trim(trigger)].at : ""
}

; ── pins ──────────────────────────────────────────────────────────────────────
;  A pin is a promise the quick menu keeps: this one is always there, however
;  long it has been since you last sent it. Recency alone cannot do that job —
;  the message you send twice a day is exactly the one that falls off a
;  most-recent list, and it is the one you most want a menu for.

HSU_IsPinned(trigger) {
    global HSU_INI
    if !FileExist(HSU_INI)
        return false
    v := ""
    try v := IniRead(HSU_INI, "Pinned", Trim(trigger), "")
    return Trim(v) != ""
}

; Pinned triggers in PIN ORDER — oldest pin first, so the menu does not reshuffle
; itself under your hand every time you pin something new.
HSU_Pinned() {
    global HSU_INI
    rows := []
    if !FileExist(HSU_INI)
        return rows
    body := ""
    try body := IniRead(HSU_INI, "Pinned", , "")
    catch
        return rows
    for line in StrSplit(body, "`n", "`r") {
        eq := InStr(line, "=")
        if !eq
            continue
        trg := Trim(SubStr(line, 1, eq - 1))
        if (trg != "")
            rows.Push({trigger: trg, at: Trim(SubStr(line, eq + 1))})
    }
    Loop rows.Length - 1 {
        i := A_Index + 1
        v := rows[i]
        j := i - 1
        while (j >= 1 && StrCompare(rows[j].at, v.at) > 0) {
            rows[j + 1] := rows[j]
            j--
        }
        rows[j + 1] := v
    }
    return rows
}

; Returns true if the trigger is pinned AFTERWARDS, so a caller can word its own
; toast without asking again.
HSU_TogglePin(trigger) {
    global HSU_INI
    trigger := Trim(trigger)
    if !HSU_Usable(trigger) {
        LOGW("hs.usage", "'" trigger "' cannot be pinned: an ini key may not"
                       . " contain '=' or start with ';' or '['")
        return false
    }
    if HSU_IsPinned(trigger) {
        try IniDelete(HSU_INI, "Pinned", trigger)
        LOGI("hs.usage", trigger " unpinned")
        return false
    }
    try IniWrite(HSU_Stamp(), HSU_INI, "Pinned", trigger)
    LOGI("hs.usage", trigger " pinned — it stays in the quick menu however long"
                   . " it has been since you last sent it")
    return true
}

; ── writing ───────────────────────────────────────────────────────────────────

; Record one USE. Called from the send path — see the cost note in the header.
;
; Never throws and never raises anything the user has to dismiss. A hotstring
; that fires and sends its message has done its job; failing to write it down is
; a log line, not an interruption.
HSU_Note(trigger) {
    global HSU_INI, HSU_KEEP, HSU_PRUNE_AT
    trigger := Trim(trigger)
    if !HSU_Usable(trigger) {
        LOGV("hs.usage", "not recording '" trigger "' — it cannot be an ini key")
        return
    }
    uses := HSU_Uses()                          ; one read; it also carries the count
    n    := uses.Has(trigger) ? uses[trigger].count + 1 : 1
    try IniWrite(HSU_Stamp() "|" n, HSU_INI, "Used", trigger)
    catch as e {
        LOGW("hs.usage", "could not record a use of " trigger " — the quick menu's"
                       . " recent list will be one entry behind:  " LOG_Err(e))
        return
    }
    LOGV("hs.usage", trigger " used (" n " time(s))")
    ; Pruning is the only unbounded work here, so it waits until the section has
    ; actually grown. `uses` is the state BEFORE this write, which is why the
    ; comparison is against the pre-write count plus the one just added.
    if (uses.Count + 1 > HSU_PRUNE_AT)
        HSU_Prune()
}

; Trim [Used] back to the HSU_KEEP most recent triggers.
;
; Pinned triggers are kept whatever their age: a pin is a statement that this one
; matters, and dropping its use record would lose the count and the last-used
; date behind a row the menu is still showing.
HSU_Prune() {
    global HSU_INI, HSU_KEEP
    rows := HSU_Recent()
    if (rows.Length <= HSU_KEEP)
        return
    pinned := Map()
    for _, p in HSU_Pinned()
        pinned[StrLower(p.trigger)] := true

    dropped := 0
    Loop rows.Length - HSU_KEEP {
        r := rows[HSU_KEEP + A_Index]
        if pinned.Has(StrLower(r.trigger))
            continue
        try IniDelete(HSU_INI, "Used", r.trigger)
        dropped++
    }
    if dropped
        LOGI("hs.usage", "pruned " dropped " stale trigger(s) out of the recent"
                       . " list; the " HSU_KEEP " newest and every pinned one stay")
}

; ── keeping up with the library ───────────────────────────────────────────────
;  The two edits that would otherwise leave this file describing hotstrings that
;  no longer exist. Both are called by the manager window, which is the only
;  thing that can rename or delete a trigger.

; A renamed trigger is the SAME hotstring: it keeps its history and its pin.
; Without this, renaming one silently reset its count to zero and dropped it out
; of the quick menu — which reads as the rename having broken something.
HSU_Rename(oldTrigger, newTrigger) {
    global HSU_INI
    oldTrigger := Trim(oldTrigger), newTrigger := Trim(newTrigger)
    if (oldTrigger = "" || newTrigger = "" || oldTrigger = newTrigger)
        return
    if !HSU_Usable(newTrigger) {
        HSU_Forget(oldTrigger)                  ; the new name cannot be recorded
        return
    }
    uses := HSU_Uses()
    if uses.Has(oldTrigger)
        try IniWrite(uses[oldTrigger].at "|" uses[oldTrigger].count,
                     HSU_INI, "Used", newTrigger)
    if HSU_IsPinned(oldTrigger)
        try IniWrite(IniRead(HSU_INI, "Pinned", oldTrigger, HSU_Stamp()),
                     HSU_INI, "Pinned", newTrigger)
    HSU_Forget(oldTrigger)
    LOGI("hs.usage", oldTrigger " → " newTrigger ": its use count and pin moved"
                   . " with it")
}

; Drop every trace of a trigger. Called when one is deleted from its source file,
; so a dangling pin cannot keep offering a menu row that sends nothing.
HSU_Forget(trigger) {
    global HSU_INI
    trigger := Trim(trigger)
    if (trigger = "")
        return
    try IniDelete(HSU_INI, "Used", trigger)
    try IniDelete(HSU_INI, "Pinned", trigger)
    LOGV("hs.usage", "forgot " trigger)
}
