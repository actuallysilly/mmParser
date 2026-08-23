#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  record.ahk — what the activity tracker writes down, and how it is read back.
; ───────────────────────────────────────────────────────────────────────────────
;  ONE line per counter per minute:
;
;      minute,counter,value            e.g.  623,keys,214
;
;  `minute` is minutes since local midnight (0-1439), so a day is a closed set of
;  1440 slots and no line carries a date — the FILENAME does.
;
;  ── Why counts and never text ────────────────────────────────────────────────
;  Nothing here records WHAT was typed. Not a character, not a window title, not
;  a fan's name. The tracker sees every keystroke of a working shift, which means
;  it sees the messages, and the only version of this feature that is safe to
;  leave running for months is one that structurally cannot retain them. The
;  counters below are the whole vocabulary; there is no field a character could
;  be put in even by accident.
;
;  ── Why one file PER PROCESS per day ─────────────────────────────────────────
;  MMA is up to eight processes. Today only tracker.ahk writes here, so a single
;  shared file would work — right up until the second writer arrives, at which
;  point two processes are appending to one file and the loser of the race
;  silently loses a minute of data.
;
;  That is the same reasoning that gave Fansly its own status file instead of a
;  second section of detector_status.ini (see MMA_FANSLY in core/paths.ahk), and
;  it costs one Loop Files in the reader:
;
;      userdata\activity\2026-08-06.tracker.csv
;      userdata\activity\2026-08-06.<whatever writes next>.csv
;
;  Readers glob `<date>.*.csv` and merge. Appending is therefore always
;  single-writer, which is the only property that makes a bare FileAppend safe.
;
;  ── Sums vs maxima ───────────────────────────────────────────────────────────
;  A counter named `max.<something>` is merged by taking the LARGER value;
;  everything else is summed. Encoding that in the name rather than in a table
;  means the reader never has to be kept in step with the writer — the longest
;  pause in a minute is not a quantity you can add up across two processes, and a
;  reader that did would report a stall that never happened.
; ═══════════════════════════════════════════════════════════════════════════════

global ACT_DIR := MMA_USERDATA "\activity"

; Counters pending for the minute currently being filled. Held in memory and
; appended once, on the minute boundary — a FileAppend per keystroke would put
; disk IO on the input path, which is the one place in MMA that must never
; stutter.
global _ACT_Pending := Map()
global _ACT_Bucket  := ""       ; "yyyyMMdd,minute" the pending counters belong to

; ─── Where ────────────────────────────────────────────────────────────────────

; Which script is writing. Sanitised to letters, digits, dash and underscore
; because it lands in a FILENAME, and A_ScriptName is whatever a future caller
; happens to be called.
ACT_Source() {
    static cached := ""
    if (cached != "")
        return cached
    name := StrReplace(A_ScriptName, ".ahk", "")
    clean := ""
    Loop Parse name {
        if InStr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", A_LoopField)
            clean .= A_LoopField
    }
    cached := (clean = "") ? "unknown" : clean
    return cached
}

ACT_Path(ymd) {
    return ACT_DIR "\" ymd "." ACT_Source() ".csv"
}

; Created on demand rather than in paths.ahk, because unlike debuglogs\ this
; folder should not appear on a machine that never switches the tracker on.
ACT_EnsureDir() {
    if !DirExist(ACT_DIR) {
        try DirCreate(ACT_DIR)
    }
    return DirExist(ACT_DIR) ? true : false
}

; ─── Writing ──────────────────────────────────────────────────────────────────

; The minute we are currently filling, as "yyyyMMdd,minuteOfDay".
_ACT_Now() {
    return FormatTime(A_Now, "yyyyMMdd") "," (Integer(A_Hour) * 60 + Integer(A_Min))
}

; Add to a counter. Called from the keyboard hook, so it does no IO and cannot
; throw: a tracker that can crash the thing it is measuring is worse than no
; tracker.
ACT_Bump(name, n := 1) {
    global _ACT_Pending, _ACT_Bucket
    try {
        now := _ACT_Now()
        if (now != _ACT_Bucket) {
            ACT_Flush()                 ; writes the minute that just ended
            _ACT_Bucket := now
        }
        _ACT_Pending[name] := (_ACT_Pending.Has(name) ? _ACT_Pending[name] : 0) + n
    }
}

; Record a maximum rather than a total — see the header. Same bucket handling.
ACT_Max(name, v) {
    global _ACT_Pending, _ACT_Bucket
    try {
        now := _ACT_Now()
        if (now != _ACT_Bucket) {
            ACT_Flush()
            _ACT_Bucket := now
        }
        if (!_ACT_Pending.Has(name) || v > _ACT_Pending[name])
            _ACT_Pending[name] := v
    }
}

; Append everything pending to the day the pending counters BELONG to — which is
; not necessarily today. A minute that starts at 23:59 is flushed at 00:00, and
; taking the date from the clock at flush time would file it under tomorrow and
; leave a phantom minute 1439 of activity in a day that had not started.
ACT_Flush() {
    global _ACT_Pending, _ACT_Bucket
    if (_ACT_Pending.Count = 0 || _ACT_Bucket = "")
        return
    parts  := StrSplit(_ACT_Bucket, ",")
    stamp  := parts[1]
    minute := parts[2]
    ymd    := SubStr(stamp, 1, 4) "-" SubStr(stamp, 5, 2) "-" SubStr(stamp, 7, 2)

    body := ""
    for name, val in _ACT_Pending
        body .= minute "," name "," val "`n"
    _ACT_Pending := Map()

    if !ACT_EnsureDir() {
        LOGE("act.flush", "cannot create " ACT_DIR " — this minute of activity is"
                        . " lost, and so is every minute until it exists")
        return
    }
    try {
        FileAppend(body, ACT_Path(ymd), "UTF-8")
    } catch as e {
        ; WARN, not FAIL: losing a minute of statistics is not worth a dialog in
        ; front of somebody mid-shift. It is worth a line, because a disk that
        ; started refusing writes explains an otherwise baffling flat chart.
        LOGW("act.flush", "could not append a minute of activity to "
                        . ACT_Path(ymd) " — " LOG_Err(e))
    }
}

; Flush if the minute the pending counters belong to is over.
;
; ACT_Bump already flushes on the boundary, but only when something bumps — so a
; shift that ends at 17:03:20 leaves that last minute sitting in memory, and the
; tracker's own tick is the only thing that will ever notice. Called from there
; once a second, which is also why it is this cheap: two string compares.
ACT_FlushIfMinuteEnded() {
    global _ACT_Bucket
    if (_ACT_Bucket = "" || _ACT_Bucket = _ACT_Now())
        return
    ACT_Flush()
    _ACT_Bucket := ""
}

; ─── Housekeeping ─────────────────────────────────────────────────────────────

; Delete day files older than `days`. A day is a few KB, so this is about not
; leaving an unbounded folder behind rather than about disk space — 0 keeps
; everything forever, which is a legitimate answer for a log you are keeping in
; order to spot a pattern across months.
ACT_Prune(days) {
    if (days <= 0)
        return 0
    if !DirExist(ACT_DIR)
        return 0
    cutoff := DateAdd(A_Now, -days, "Days")
    limit  := FormatTime(cutoff, "yyyy-MM-dd")
    gone   := 0
    Loop Files, ACT_DIR "\*.csv" {
        ; "2026-08-06.tracker.csv" — the date is the first ten characters, and a
        ; lexical compare is a date compare in this format, which is most of why
        ; it was chosen.
        ;
        ; StrCompare, NOT `<`. AHK v2's comparison operators are NUMERIC: given
        ; two strings that are not numbers they throw "Expected a Number but got
        ; a String" rather than comparing them. `<` here threw on the first file
        ; it looked at. The shipped default (KeepDays=0) returns above before
        ; reaching this loop, so it would have hidden until the first person set
        ; a retention — and then taken the tracker down at startup, since that is
        ; where ACT_Prune is called from.
        if (StrLen(A_LoopFileName) < 10)
            continue
        if (StrCompare(SubStr(A_LoopFileName, 1, 10), limit) < 0) {
            try {
                FileDelete(A_LoopFileFullPath)
                gone++
            }
        }
    }
    if gone
        LOGI("act.prune", gone " activity file(s) older than " days " days deleted")
    return gone
}

; ─── Reading ──────────────────────────────────────────────────────────────────

; One day, merged across every process that wrote it.
;   returns Map(minuteOfDay -> Map(counter -> value))
ACT_ReadDay(ymd) {
    out := Map()
    if !DirExist(ACT_DIR)
        return out
    Loop Files, ACT_DIR "\" ymd ".*.csv" {
        text := ""
        try {
            text := FileRead(A_LoopFileFullPath, "UTF-8")
        } catch as e {
            LOGW("act.read", "could not read " A_LoopFileName " — " LOG_Err(e))
            continue
        }
        Loop Parse text, "`n", "`r" {
            line := A_LoopField
            if (line = "")
                continue
            f := StrSplit(line, ",")
            if (f.Length < 3)
                continue                      ; a torn final line from a crash
            min := ""
            val := ""
            try {
                min := Integer(f[1])
                val := Number(f[3])
            } catch {
                continue
            }
            name := f[2]
            if !out.Has(min)
                out[min] := Map()
            slot := out[min]
            if !slot.Has(name) {
                slot[name] := val
            } else if (SubStr(name, 1, 4) = "max.") {
                if (val > slot[name])
                    slot[name] := val
            } else {
                slot[name] := slot[name] + val
            }
        }
    }
    return out
}

; The last `n` dates, oldest first, as "yyyy-MM-dd".
ACT_RecentDays(n) {
    out := []
    Loop n {
        d := DateAdd(A_Now, -(n - A_Index), "Days")
        out.Push(FormatTime(d, "yyyy-MM-dd"))
    }
    return out
}

; Every counter this build writes, in the order the page expects them. Kept in
; ONE place: the page indexes the compact arrays below by position, so a counter
; inserted in the middle here without changing the page silently relabels every
; column of every chart.
global ACT_FIELDS := ["keys", "chars", "bksp", "mouse", "active", "max.gap"]

_ACT_Row(slot) {
    global ACT_FIELDS
    row := []
    for _, name in ACT_FIELDS
        row.Push(slot.Has(name) ? slot[name] : 0)
    return row
}

; The whole payload the chart window hands to the page.
;
;   today  — SPARSE minute rows for `focus`: [minute, keys, chars, bksp, mouse,
;            active, maxgap]. Sparse because a shift is a few hundred non-empty
;            minutes out of 1440, and sending the zeros is ten times the JSON for
;            no information.
;   hours  — [date, hour, ...the same six] for the whole range, which is what the
;            heatmap and every cross-day average are built from. Hourly rather
;            than per-minute because 90 days of minutes is 130,000 rows and no
;            chart on the page resolves finer than an hour.
ACT_Report(focus, days) {
    global ACT_FIELDS
    todayRows := []
    for min, slot in ACT_ReadDay(focus) {
        row := _ACT_Row(slot)
        row.InsertAt(1, min)
        todayRows.Push(row)
    }
    ; Map iteration order is not minute order, and a line chart drawn in hash
    ; order is a scribble. Sorted here rather than in the page because the page
    ; would have to do it on every redraw.
    _ACT_SortRows(todayRows)

    hourRows := []
    for _, ymd in ACT_RecentDays(days) {
        buckets := Map()
        for min, slot in ACT_ReadDay(ymd) {
            h := min // 60
            if !buckets.Has(h)
                buckets[h] := Map()
            into := buckets[h]
            for name, val in slot {
                if (SubStr(name, 1, 4) = "max.") {
                    if (!into.Has(name) || val > into[name])
                        into[name] := val
                } else {
                    into[name] := (into.Has(name) ? into[name] : 0) + val
                }
            }
        }
        for h, slot in buckets {
            row := _ACT_Row(slot)
            row.InsertAt(1, h)
            row.InsertAt(1, ymd)
            hourRows.Push(row)
        }
    }

    return Map("fields", ACT_FIELDS,
               "focus",  focus,
               "days",   days,
               "today",  todayRows,
               "hours",  hourRows,
               "generated", FormatTime(A_Now, "yyyy-MM-dd HH:mm"))
}

; Insertion sort on the first column. The array is at most 1440 long and almost
; always nearly sorted already (Map order tends to follow insertion for small
; integer keys), so this beats dragging in a general sort for one call site.
_ACT_SortRows(rows) {
    i := 2
    while (i <= rows.Length) {
        cur := rows[i]
        j := i - 1
        while (j >= 1 && rows[j][1] > cur[1]) {
            rows[j + 1] := rows[j]
            j--
        }
        rows[j + 1] := cur
        i++
    }
}
