#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  reply_tiers_test.ahk — the arithmetic behind the reply-timer boxes.
; ───────────────────────────────────────────────────────────────────────────────
;  screen/reply_box.ahk turns "7:45 am" and a wall clock into a colour. The pixel
;  half of that needs Infloww on screen to test; THIS half needs nothing, and it
;  is the half where being wrong is expensive:
;
;    * too quiet — a fan who has been waiting twelve minutes gets no box, which is
;      the entire thing the feature exists to prevent;
;    * too loud — the newest message in the list wears the loudest colour in the
;      palette, which trains you to ignore the colours.
;
;  The second one is not hypothetical: a stamp one minute in the "future" (a
;  message that landed at 7:45:50, stamped 7:45, read by us at 7:45:20) wraps to
;  1439 minutes under a naive midnight rule, so the freshest row is painted as a
;  day-old one. RB_GRACE_MIN exists for that, and the cases below are what hold
;  it in place.
;
;  Everything here is pure. No screen, no ini, no clock — RB_ElapsedMin takes
;  `nowMin` as an argument precisely so that midnight can be tested at any hour.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../../src/core/reply_tiers.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError((e, m) => (Out("ERROR: " e.Message " @ " e.File ":" e.Line), ExitApp(1)))

pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── reading a clock ───────────────────────────────────────────────────────────
Ck("7:45 am",          RB_ClockToMin("7:45 am"),   465)
Ck("7:45 AM",          RB_ClockToMin("7:45 AM"),   465)
Ck("no space",         RB_ClockToMin("7:45am"),    465)
Ck("7:45 pm",          RB_ClockToMin("7:45 pm"),  1185)
; The two hours everyone gets wrong, and they go opposite ways.
Ck("12:15 am is 00:15", RB_ClockToMin("12:15 am"),   15)
Ck("12:15 pm is 12:15", RB_ClockToMin("12:15 pm"),  735)
Ck("midnight",         RB_ClockToMin("12:00 am"),    0)
Ck("noon",             RB_ClockToMin("12:00 pm"),  720)
; 24-hour locales, where there is no meridiem to read.
Ck("24h 19:45",        RB_ClockToMin("19:45"),    1185)
Ck("24h 00:05",        RB_ClockToMin("00:05"),       5)
; OCR mangles the meridiem on small text; only the first letter is trusted.
Ck("a.m. with dots",   RB_ClockToMin("7:45 a.m."),  465)
Ck("OCR'd 'arn'",      RB_ClockToMin("7:45 arn"),   465)
; Leading junk — a tick, a reaction glyph — is skipped, the same way the OCR
; cleaner in ocr_grab.ahk tolerates it.
Ck("leading glyph",    RB_ClockToMin("✓ 7:45 am"),  465)

; Not clock times. -1 means "cannot tell", never 0 — 0 would be midnight, which
; is a real and very stale time.
Ck("Yesterday",        RB_ClockToMin("Yesterday"),   -1)
Ck("a weekday",        RB_ClockToMin("Mon"),         -1)
Ck("a date",           RB_ClockToMin("4 Mar"),       -1)
Ck("empty",            RB_ClockToMin(""),            -1)
Ck("minutes over 59",  RB_ClockToMin("7:75 am"),     -1)
Ck("13 pm",            RB_ClockToMin("13:15 pm"),    -1)
Ck("hour over 23",     RB_ClockToMin("25:00"),       -1)

; ── the wait ──────────────────────────────────────────────────────────────────
; 7:45 read at 7:49.
Ck("4 minutes",        RB_ElapsedMin("7:45 am",  7*60 + 49),    4)
Ck("same minute",      RB_ElapsedMin("7:45 am",  7*60 + 45),    0)
Ck("2 hours",          RB_ElapsedMin("7:45 am",  9*60 + 45),  120)

; THE GRACE WINDOW. A stamp up to RB_GRACE_MIN in the future is clock skew and
; reads as 0 — not as a day.
Ck("1 min future",     RB_ElapsedMin("7:45 am",  7*60 + 44),    0)
Ck("2 min future",     RB_ElapsedMin("7:45 am",  7*60 + 43),    0)
; Past the grace, a "future" stamp is last night's, and wraps forward a day.
Ck("3 min future wraps", RB_ElapsedMin("7:45 am", 7*60 + 42), 1437)

; Across midnight: 23:50 read at 00:10 is twenty minutes, not minus 1420.
Ck("over midnight",    RB_ElapsedMin("11:50 pm",      10),     20)

; Non-clock labels are floored at midnight today — the rule is "as if 12:00",
; so the answer is however long today has been. A floor, never an estimate: it
; can only understate, which is the safe direction.
Ck("Yesterday at 7:45", RB_ElapsedMin("Yesterday", 7*60 + 45),  465)
Ck("Yesterday at 00:10", RB_ElapsedMin("Yesterday",       10),   10)
Ck("a date is floored", RB_ElapsedMin("4 Mar",     7*60 + 45),  465)
; Nothing to read at all is still "cannot tell", which RB_Pick paints as no box.
Ck("junk is unknown",  RB_ElapsedMin("...",       7*60 + 45),   -1)

; ── a bare number is NOT a stamp ──────────────────────────────────────────────
; An unread row can carry a COUNT badge in the same band as the time. It has no
; colon, so it is not a clock — and when "anything with \w in it" counted as a
; stamp it was floored at midnight instead, i.e. painted in the TOP tier. A
; conversation that had just arrived wore the loudest colour in the palette.
Ck("a count is not a stamp",   RB_IsStamp("2"),      0)
Ck("a two-digit count either", RB_IsStamp("12"),     0)
; -1 is what RB_Pick paints as no box at all — asserted directly further down.
Ck("a count reads as unknown", RB_ElapsedMin("2",  7*60 + 45), -1)
; The things that ARE stamps still are.
Ck("a clock is a stamp",       RB_IsStamp("7:45 am"), 1)
Ck("24h clock is a stamp",     RB_IsStamp("19:45"),   1)
Ck("a word is a stamp",        RB_IsStamp("Yesterday"), 1)
Ck("a date is a stamp",        RB_IsStamp("4 Mar"),   1)
Ck("punctuation is not",       RB_IsStamp("···"),     0)
Ck("empty is not",             RB_IsStamp(""),        0)

; ── picking a colour ──────────────────────────────────────────────────────────
T := RB_SortTiers([{mins: 3,  col: "FFD24A"},
                   {mins: 4,  col: "FF4A4A"},
                   {mins: 6,  col: "FF7AD9"},
                   {mins: 10, col: "FFFFFF"}])

Ck("0 min  no box",    RB_Pick(T,  0),  "")
Ck("2 min  no box",    RB_Pick(T,  2),  "")
Ck("3 min  yellow",    RB_Pick(T,  3),  "FFD24A")
Ck("3 min is inclusive", RB_Pick(T, 3), "FFD24A")
Ck("4 min  red",       RB_Pick(T,  4),  "FF4A4A")
Ck("5 min  red",       RB_Pick(T,  5),  "FF4A4A")
Ck("6 min  pink",      RB_Pick(T,  6),  "FF7AD9")
Ck("9 min  pink",      RB_Pick(T,  9),  "FF7AD9")
Ck("10 min white",     RB_Pick(T, 10),  "FFFFFF")
Ck("a day    white",   RB_Pick(T, 1439), "FFFFFF")
; "cannot tell" must never paint. A -1 reaching the palette as if it were a small
; number would be a box on every row whose stamp failed to OCR.
Ck("unknown no box",   RB_Pick(T, -1),  "")
Ck("no tiers no box",  RB_Pick([], 99),  "")

; Sorting is what makes "highest tier first" true. An unsorted list would let a
; 3-minute tier shadow a 10-minute one and everything past three would be yellow.
U := RB_SortTiers([{mins: 10, col: "FFFFFF"}, {mins: 3, col: "FFD24A"}])
Ck("sorted ascending", U[1].mins, 3)
Ck("unsorted input still picks the top tier", RB_Pick(U, 12), "FFFFFF")

; ── parsing what the cfg holds ────────────────────────────────────────────────
Ck("tier line",        RB_ParseTier("3,FFD24A").mins,  3)
Ck("tier colour",      RB_ParseTier("3,FFD24A").col,   "FFD24A")
Ck("tier with spaces", RB_ParseTier(" 4 , ff4a4a ").col, "FF4A4A")
Ck("tier with hash",   RB_ParseTier("4,#ff4a4a").col,  "FF4A4A")
; Bad lines are dropped, not guessed at — the cfg is hand-editable by design and
; one fat-fingered line must not take the overlay down at load.
Ck("no colour",        RB_ParseTier("4"),              0)
Ck("bad colour",       RB_ParseTier("4,nope"),         0)
Ck("short colour",     RB_ParseTier("4,FFF"),          0)
Ck("bad minutes",      RB_ParseTier("soon,FFD24A"),    0)
Ck("negative minutes", RB_ParseTier("-4,FFD24A"),      0)
Ck("empty",            RB_ParseTier(""),               0)

; "" for a bad colour, never a fallback to black: a black box on Infloww's
; near-black list is an invisible box, which reads as the feature being broken.
Ck("hex passthrough",  RB_CleanHex("ffd24a"),  "FFD24A")
Ck("hex with hash",    RB_CleanHex("#FFD24A"), "FFD24A")
Ck("hex too short",    RB_CleanHex("FFD24"),   "")
Ck("hex not hex",      RB_CleanHex("ZZZZZZ"),  "")

; ── the log/preview wording ───────────────────────────────────────────────────
Ck("humanise minutes", RB_Humanise(4),     "4 min")
Ck("humanise an hour", RB_Humanise(72),    "1 hr 12 min")
Ck("humanise a day",   RB_Humanise(1440),  "1 day")
Ck("humanise two days", RB_Humanise(2880), "2 days")
Ck("humanise unknown", RB_Humanise(-1),    "unknown")

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
