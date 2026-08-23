#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  reply_tiers.ahk — how long has this fan been waiting, and what colour is that?
; ───────────────────────────────────────────────────────────────────────────────
;  Pure functions, for the same reason pill_scan.ahk is pure: THREE places have to
;  agree on the answer. screen/reply_box.ahk paints the boxes, the Settings tab
;  edits the thresholds and previews them, and tools/test/reply_tiers_test.ahk
;  checks the arithmetic. A settings page that previewed "4 min → red" using its
;  own copy of the rule is a page you cannot trust — you would tune numbers that
;  satisfy the preview and leave the overlay painting something else.
;
;  Nothing here reads an ini, writes a file, starts a timer or touches a pixel.
;  RB_Cfg() in reply_box.ahk is what turns cfg lines into the `tiers` array these
;  take; everything below is arithmetic on values already in memory.
;
;  ─── WHY THE CLOCK IS THE ONLY INPUT ─────────────────────────────────────────
;  Infloww's conversation list gives one piece of timing information per row: a
;  wall-clock stamp like "7:45 am", the time of the last message. There is no
;  elapsed-time field to read, so the wait is `now - that stamp` and nothing else.
;
;  That has a sharp edge, and it is the reason RB_GRACE_MIN exists. The stamp has
;  minute resolution and Infloww's clock is not ours: a message that lands at
;  7:45:50 is stamped "7:45" and may be read by us at 7:45:20, one machine's
;  rounding away. Subtracting gives MINUS one minute. Wrapped naively across
;  midnight (below) that becomes 1439 minutes, so the NEWEST message in the list
;  gets the loudest box in the palette — the exact inverse of the feature. A
;  couple of minutes of slack on the future side costs nothing (nobody boxes a
;  0-2 minute wait) and removes that failure entirely.
; ═══════════════════════════════════════════════════════════════════════════════

; How far into the "future" a stamp may sit before it is read as yesterday rather
; than as clock skew. See the header — this is the guard that stops a
; just-arrived message being painted as a 24-hour-old one.
global RB_GRACE_MIN := 2

; Minutes in a day, spelled out wherever the wrap happens.
global RB_DAY_MIN := 1440

; ── the tiers ─────────────────────────────────────────────────────────────────
;  A tier is "from this many minutes, paint this colour". They are stored as
;  [ReplyBox] Tier1..TierN in mass_gui.cfg, one per line, exactly like [Marks]
;  Bar<n> — hand-editable, and adding a sixth is adding a line rather than
;  editing a schema.
;
;      Tier1 = 3,FFD24A      from 3 minutes: yellow
;      Tier2 = 4,FF4A4A      from 4 minutes: red
;      Tier3 = 6,FF7AD9      from 6 minutes: pink
;      Tier4 = 10,FFFFFF     from 10 minutes: bright white
;
;  Below the lowest tier there is no box at all. That is not a special case in
;  the code — it falls out of RB_Pick finding nothing to match — and it is why
;  the "< 3 min, no box" rule needs no setting of its own: lower Tier1 and the
;  quiet band shrinks with it.

; Parse "3,FFD24A" into {mins, col}, or 0 for a line that is not one.
;
; Bad lines are DROPPED rather than thrown on, because this file is hand-editable
; by design and one fat-fingered tier must not take the overlay down at load —
; the same call tab_marks.ahk makes about a bad Bar line. The caller logs it.
RB_ParseTier(val) {
    p := StrSplit(val, ",")
    if (p.Length < 2)
        return 0
    m := Trim(p[1])
    if !RegExMatch(m, "^\d+$")
        return 0
    col := RB_CleanHex(Trim(p[2]))
    if (col = "")
        return 0
    return {mins: Integer(m), col: col}
}

; "#FFD24A" / "ffd24a" → "FFD24A", or "" for anything that is not six hex digits.
;
; "" means "not a colour", never a fallback to black: a black box on Infloww's
; near-black list is an invisible box, which reads as the feature being broken.
RB_CleanHex(s) {
    s := Trim(s)
    if (SubStr(s, 1, 1) = "#")
        s := SubStr(s, 2)
    if !RegExMatch(s, "^[0-9A-Fa-f]{6}$")
        return ""
    return StrUpper(s)
}

; Sort tiers ascending by minutes, in place, and hand the array back.
;
; RB_Pick walks them from the top down, so the order is load-bearing rather than
; cosmetic — an unsorted list would let Tier1's 3 minutes shadow Tier4's 10 and
; every wait past three minutes would come out yellow.
RB_SortTiers(tiers) {
    Loop tiers.Length - 1 {
        i := A_Index + 1
        v := tiers[i]
        j := i - 1
        while (j >= 1 && tiers[j].mins > v.mins) {
            tiers[j + 1] := tiers[j]
            j--
        }
        tiers[j + 1] := v
    }
    return tiers
}

; Which colour does a wait of `mins` minutes earn? "" means no box.
;
; Highest tier first, so the answer is the STRONGEST threshold the wait has
; passed. Ties go to the later tier: two tiers both set to 6 minutes is a
; configuration mistake, and taking the last one makes it visibly the last one
; you edited rather than silently the first.
RB_Pick(tiers, mins) {
    if (mins < 0)
        return ""
    i := tiers.Length
    while (i >= 1) {
        if (mins >= tiers[i].mins)
            return tiers[i].col
        i--
    }
    return ""
}

; ── the clock ─────────────────────────────────────────────────────────────────

; "7:45 am" → 465, minutes since midnight. -1 when it is not a clock time.
;
; Both 12- and 24-hour forms, because the list follows the machine's locale and
; MMA is not entitled to assume which one you run. The meridiem is optional and
; OCR-tolerant: Windows OCR renders it "am", "AM", "a.m." and occasionally "arn"
; on small text, so the test is the first letter after the digits rather than an
; exact string.
;
; The 12 o'clock hours are the two everyone gets wrong and they go opposite ways:
; 12:15 AM is 00:15 (hour 12 becomes 0) while 12:15 PM is 12:15 (hour 12 stays).
RB_ClockToMin(text) {
    t := Trim(text)
    if !RegExMatch(t, "^\D*(\d{1,2}):(\d{2})\s*([APap])?", &m)
        return -1
    h := Integer(m[1]), mm := Integer(m[2])
    if (mm > 59)
        return -1
    ap := (m.Count >= 3) ? StrUpper(m[3]) : ""
    if (ap = "A") {
        if (h < 1 || h > 12)
            return -1
        if (h = 12)
            h := 0
    } else if (ap = "P") {
        if (h < 1 || h > 12)
            return -1
        if (h != 12)
            h += 12
    } else if (h > 23)
        return -1
    return h * 60 + mm
}

; Does this line look like a row stamp at all?
;
; The time column also carries "Yesterday", a weekday, or a date, and those are
; rows too — they just are not clock times. So a stamp is either a clock time, or
; something with a LETTER in it.
;
;  ─── WHY A BARE NUMBER IS NOT A STAMP ────────────────────────────────────────
;  This used to accept anything with `\w` in it, which includes digits, and that
;  was a live bug rather than a loose test. An unread row can carry a COUNT badge
;  in the same band as the time — a bare "2". It has no colon, so it is not a
;  clock; it was therefore treated as a "Yesterday"-style label and floored at
;  midnight, which lands in the top tier. The result was the loudest colour in
;  the palette on a conversation that had just arrived: the precise inverse of
;  the feature, and the same failure RB_GRACE_MIN exists to prevent from the
;  other direction.
;
;  Requiring a letter costs nothing real — every non-clock stamp Infloww writes
;  is a word or contains a month — and it makes a digits-only line fall through
;  to "cannot tell", which paints nothing.
RB_IsStamp(text) {
    t := Trim(text)
    if (RB_ClockToMin(t) >= 0)
        return true
    return RegExMatch(t, "[A-Za-z]") ? true : false
}

; How long has this row been waiting? Minutes, or -1 for "cannot tell".
;
; `nowMin` is the caller's clock, passed in rather than read here, so a test can
; drive every branch without waiting for the wall clock to reach it.
;
;  ─── THE TWO CASES ──────────────────────────────────────────────────────────
;  A CLOCK TIME is subtracted directly. If the result is negative the stamp is
;  either clock skew (within RB_GRACE_MIN — clamped to 0, see the header) or a
;  time from yesterday evening that the list is still showing as a bare clock,
;  which wraps forward a day.
;
;  ANYTHING ELSE — "Yesterday", "Mon", "4 Mar" — is floored at midnight today, so
;  its wait comes out as however long today has been. That is deliberately a
;  FLOOR and not an estimate: a genuinely week-old row reports as today's
;  minutes-since-midnight rather than a week, so the number can only ever
;  UNDERSTATE the wait. Understating is the safe direction — it can leave a stale
;  row one tier quieter than it deserves, where overstating would put a fresh row
;  in the loudest colour on the strength of a label nobody measured. In practice
;  it lands in the top tier from 00:10 onwards anyway.
RB_ElapsedMin(text, nowMin) {
    if !RB_IsStamp(text)
        return -1
    stamp := RB_ClockToMin(text)
    if (stamp < 0)
        return nowMin              ; "Yesterday" and friends — floored at midnight
    global RB_GRACE_MIN, RB_DAY_MIN
    d := nowMin - stamp
    if (d < 0)
        return (d >= -RB_GRACE_MIN) ? 0 : d + RB_DAY_MIN
    return d
}

; The machine's clock as minutes since midnight. The one impure line in the file,
; kept here so that every caller reads the clock the same way and RB_ElapsedMin
; itself stays testable.
RB_NowMin() {
    return A_Hour * 60 + A_Min
}

; "4 min" / "1 hr 12 min" / "2 days". For the log and the Settings preview, where
; a bare 1439 means nothing to read at a glance.
RB_Humanise(mins) {
    if (mins < 0)
        return "unknown"
    if (mins < 60)
        return mins " min"
    if (mins < 1440)
        return (mins // 60) " hr " Mod(mins, 60) " min"
    d := mins // 1440
    return d " day" (d = 1 ? "" : "s")
}
