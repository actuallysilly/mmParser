#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  activity_test.ahk — activity/record.ahk against the cases that would make the
;  chart lie.
;
;  Runs against a TEMP folder, never userdata\activity\. Exit 1 on any failure.
;
;  It tests the RECORD layer only, and deliberately: tracker.ahk's other half is
;  a global keyboard hook, and a test that installed one would be counting the
;  keystrokes of whoever ran it. Everything with a decision in it is here.
;
;  The two headline cases:
;    * a `max.` counter must MERGE BY MAXIMUM. Summed, two processes each seeing
;      a 40-second pause would report an 80-second stall that never happened.
;    * a minute is flushed to the day it BELONGS to, not the day it is written.
;      The minute starting 23:59 is written at 00:00, and taking the date from
;      the clock would file it under tomorrow — inventing a minute of activity in
;      a day that had not started.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../../src/activity/record.ahk"
#Include "../../src/vendor/json.ahk"

pass := 0, fail := 0
; Guarded, per tools\test\README.md: double-clicked there is no stdout, and an
; unguarded FileAppend throws "the handle is invalid" and kills the run at
; whatever line it reached — which looks exactly like the thing under test failing.
Out(s) {
    try FileAppend(s "`n", "*")
}

Check(name, got, want) {
    global pass, fail
    if (got == want) {
        pass++
        return
    }
    fail++
    Out("FAIL  " name)
    Out("      want: " String(want))
    Out("      got:  " String(got))
}

; Point the recorder at a scratch folder for the whole run.
global ACT_DIR := A_Temp "\mma_activity_test_" A_TickCount
DirCreate(ACT_DIR)

; Write a shard by hand, to stand in for "another process wrote this".
Shard(ymd, source, text) {
    FileAppend(text, ACT_DIR "\" ymd "." source ".csv", "UTF-8")
}
; Stage counters for a known minute of a known day, bypassing the clock.
;
; This is split from ACT_Bump on purpose. Bump ALWAYS re-derives the bucket from
; the clock — that is its job, and it is why a test that set the bucket first and
; then bumped wrote everything into today's file instead. So the two halves are
; tested as the two units they are: bump accumulates, flush places.
Stage(counters, ymd, minute) {
    global _ACT_Pending, _ACT_Bucket
    _ACT_Pending := counters
    _ACT_Bucket  := StrReplace(ymd, "-", "") "," minute
}
Pending() {
    global _ACT_Pending
    return _ACT_Pending
}

TODAY := FormatTime(A_Now, "yyyy-MM-dd")

; ── 1. ACT_Bump / ACT_Max accumulate in memory ──────────────────────────────
;  Aligning the bucket to the current minute first means no flush can fire
;  underneath these, so nothing reaches the disk here.
global _ACT_Pending := Map()
global _ACT_Bucket  := FormatTime(A_Now, "yyyyMMdd") "," (Integer(A_Hour) * 60 + Integer(A_Min))
ACT_Bump("keys", 5)
ACT_Bump("keys", 7)
ACT_Bump("chars", 9)
ACT_Bump("mouse")                      ; default step is 1
ACT_Max("max.gap", 10)
ACT_Max("max.gap", 4)                  ; smaller — must NOT replace 10
ACT_Max("max.gap", 25)
p := Pending()
Check("bump sums",        p["keys"],    12)
Check("bump default 1",   p["mouse"],   1)
Check("max keeps largest", p["max.gap"], 25)

; ── 2. ACT_Flush writes them to the day the BUCKET names ────────────────────
Stage(Map("keys", 12, "chars", 9), "2026-03-02", 100)
ACT_Flush()
d := ACT_ReadDay("2026-03-02")
Check("minute present",  d.Has(100),          1)
Check("keys",            d[100]["keys"],      12)
Check("chars",           d[100]["chars"],     9)
Check("absent counter",  d[100].Has("mouse"), 0)

; flush empties the pending set, so a second one must not double the file
ACT_Flush()
d := ACT_ReadDay("2026-03-02")
Check("no double flush", d[100]["keys"], 12)

; ── 3. `max.` merges by MAXIMUM, everything else sums ───────────────────────
;  Two shards, same day, same minute — which is exactly the two-writer case the
;  per-process filenames exist to make safe.
Shard("2026-03-03", "alpha", "200,keys,10`n200,max.gap,40`n")
Shard("2026-03-03", "beta",  "200,keys,3`n200,max.gap,25`n")
d := ACT_ReadDay("2026-03-03")
Check("shards: keys summed", d[200]["keys"],    13)
Check("shards: gap is max",  d[200]["max.gap"], 40)

; and the max must win regardless of which shard is read first
Shard("2026-03-04", "alpha", "10,max.gap,5`n")
Shard("2026-03-04", "zulu",  "10,max.gap,90`n")
Check("max, low first", ACT_ReadDay("2026-03-04")[10]["max.gap"], 90)
Shard("2026-03-05", "alpha", "10,max.gap,90`n")
Shard("2026-03-05", "zulu",  "10,max.gap,5`n")
Check("max, high first", ACT_ReadDay("2026-03-05")[10]["max.gap"], 90)

; ── 4. the midnight case ────────────────────────────────────────────────────
;  Counters belonging to 23:59 on the 6th, flushed after the clock has rolled
;  over, must land on the 6th.
Stage(Map("keys", 4), "2026-03-06", 1439)
ACT_Flush()
Check("23:59 lands on its own day",  ACT_ReadDay("2026-03-06")[1439]["keys"], 4)
Check("and NOT on the next day",     ACT_ReadDay("2026-03-07").Count,         0)

; ── 5. a torn final line, as a crash mid-append would leave ─────────────────
Shard("2026-03-08", "alpha", "5,keys,100`n5,cha")
d := ACT_ReadDay("2026-03-08")
Check("good line survives", d[5]["keys"], 100)
Check("torn line ignored",  d[5].Count,   1)

; a file that is nothing but garbage must not throw
Shard("2026-03-09", "alpha", "nonsense`n`n,,`nx,y,z`n")
Check("garbage is survivable", ACT_ReadDay("2026-03-09").Count, 0)

; ── 6. a day nobody wrote reads as empty, not as an error ───────────────────
Check("missing day empty", ACT_ReadDay("2019-01-01").Count, 0)

; ── 7. ACT_Report shape ─────────────────────────────────────────────────────
;  today rows are [minute, ...FIELDS]; hour rows are [ymd, hour, ...FIELDS].
Shard(TODAY, "alpha", "61,keys,10`n61,active,30`n125,keys,4`n5,keys,1`n")
rep := ACT_Report(TODAY, 7)
Check("fields exported", rep["fields"].Length, ACT_FIELDS.Length)
Check("today row count", rep["today"].Length,  3)
; sorted by minute — a line chart drawn in hash order is a scribble
Check("sorted 1", rep["today"][1][1], 5)
Check("sorted 2", rep["today"][2][1], 61)
Check("sorted 3", rep["today"][3][1], 125)
; column positions follow ACT_FIELDS, resolved by name rather than assumed
keysCol := 0
for i, name in ACT_FIELDS
    if (name = "keys")
        keysCol := i + 1
Check("keys column", rep["today"][2][keysCol], 10)

; minutes 61 and 125 are hours 1 and 2; both must appear, summed per hour
hrs := Map()
for _, row in rep["hours"]
    if (row[1] = TODAY)
        hrs[row[2]] := row[keysCol + 1]
Check("hour 0", hrs.Has(0) ? hrs[0] : 0, 1)
Check("hour 1", hrs.Has(1) ? hrs[1] : 0, 10)
Check("hour 2", hrs.Has(2) ? hrs[2] : 0, 4)

; ── 7b. the payload survives JSON.Stringify ─────────────────────────────────
;  This is the actual bridge to the page: ACT_Report builds nested Maps and
;  Arrays, and if any of it stringifies wrong the chart shows nothing with no
;  error anywhere on the AHK side — the failure lands in the WebView's console,
;  which this process cannot see.
js := JSON.Stringify(rep)
Q := Chr(34)
Check("json has today",  InStr(js, Q "today" Q)  > 0, 1)
Check("json has hours",  InStr(js, Q "hours" Q)  > 0, 1)
Check("json has fields", InStr(js, Q "fields" Q) > 0, 1)
Check("json round trip", JSON.Parse(js)["today"].Length, 3)

; ── 8. prune keeps what is inside the window and nothing else ───────────────
old    := FormatTime(DateAdd(A_Now, -400, "Days"), "yyyy-MM-dd")
recent := FormatTime(DateAdd(A_Now, -2,   "Days"), "yyyy-MM-dd")
Shard(old,    "alpha", "1,keys,1`n")
Shard(recent, "alpha", "1,keys,1`n")
ACT_Prune(0)                      ; 0 means keep everything, forever
Check("prune 0 keeps old", FileExist(ACT_DIR "\" old ".alpha.csv") ? 1 : 0, 1)
ACT_Prune(30)
Check("prune drops old",   FileExist(ACT_DIR "\" old ".alpha.csv") ? 1 : 0, 0)
Check("prune keeps recent", FileExist(ACT_DIR "\" recent ".alpha.csv") ? 1 : 0, 1)

; ── done ────────────────────────────────────────────────────────────────────
try DirDelete(ACT_DIR, true)

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
