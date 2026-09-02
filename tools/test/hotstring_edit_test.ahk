#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstring_edit_test.ahk — the writers in hotstrings\index.ahk, and the
;  recent/pinned store in hotstrings\usage.ahk.
; ───────────────────────────────────────────────────────────────────────────────
;  The manager can now REWRITE a hotstring in place, move one to another file and
;  rename one. Every one of those edits your real message library, and the failure
;  mode is not an exception — it is a block that still loads, still fires, and
;  sends slightly different words than the ones you typed into the box.
;
;  So what is asserted here is the ROUND TRIP: text → source → text. Whatever
;  HSI_Escape writes, HSI_ReadString has to read back byte for byte, because that
;  is what happens on the next Rescan. The strings below are the ones that
;  actually break it — quotes, backticks, the `; the library already spells that
;  way, a real newline inside one message, an emoji.
;
;  ─── IT WRITES TO A SANDBOX, NEVER TO content\ ───────────────────────────────
;  HSI_ReplaceBlock and friends address files RELATIVE TO content\, so the file
;  operations are exercised against a throwaway .ahk created in content\ under a
;  name nothing else uses, and deleted again in Finish() — which every exit path
;  goes through, including the error handler. Your general.ahk and account files
;  are never opened for writing by this test.
;
;  The usage store is snapshotted the same way: the test triggers are removed at
;  the end, so a run cannot leave junk in your quick menu.
;
;  Prints to stdout. Exit 0 = all good.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn VarUnset, StdOut

#Include "../../src/hotstrings/index.ahk"
#Include "../../src/hotstrings/usage.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
pass := 0, fail := 0
Tck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ":`n     got  <" got ">`n     want <" want ">")
}
Ck(name, ok, detail := "") {
    global pass, fail
    if ok
        pass++
    else
        fail++, Out("FAIL " name (detail = "" ? "" : ": " detail))
}

; ── the sandbox ───────────────────────────────────────────────────────────────
global SANDBOX_REL := "_hsedit_test.ahk"
global SANDBOX     := MMA_CONTENT "\" SANDBOX_REL
global TEST_TRIGS  := ["_hsedit_zz1", "_hsedit_zz2", "_hsedit_zz3"]

Finish(code) {
    for _, ext in ["", ".bak", ".tmp"] {
        try FileDelete(SANDBOX ext)
    }
    for _, t in TEST_TRIGS
        HSU_Forget(t)
    ExitApp(code)
}

; Any throw becomes output and an exit code, never a modal dialog — and the
; sandbox still gets cleaned up, which is the whole reason this goes through
; Finish rather than ExitApp.
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    Finish(1)
}

Out("hotstring edit: writers + the recent/pinned store")

; ═══════════════════════════════════════════════════════════════════════════════
;  1. escaping round-trips
; ───────────────────────────────────────────────────────────────────────────────
;  HSI_Escape(text) wrapped in quotes must read back through HSI_ReadString as
;  exactly `text`. Asserted per string rather than in bulk so a failure names the
;  character that broke it.
; ═══════════════════════════════════════════════════════════════════════════════
RoundTrip(s) {
    line := 'snd("' HSI_Escape(s) '")'
    return HSI_ReadString(line, InStr(line, '"'))
}
; Built with Push rather than as one multi-line [ ... ] literal: a line ending
; in an opening bracket is not a continuation in v2, and the array then parses
; as an unterminated string on the first element that contains a quote.
samples := []
samples.Push("plain words")
samples.Push('he said "hello" to me')
samples.Push("kinks `;3")
samples.Push("a backtick `` in the middle")
samples.Push("line one`nline two")
samples.Push("tab`there")
samples.Push("emoji 🍑 and 🍒")
samples.Push("trailing spaces   ")
samples.Push('both "quotes" and `;semis and ``backticks')
for _, sample in samples
    Tck("round trip: " StrReplace(sample, "`n", "\n"), RoundTrip(sample), sample)

; The one thing the corpus already relies on: a `; in the source is a plain
; semicolon in the message. Read straight, not through Escape.
_lit := 'snd("some kinks `;3")'
Tck("the library's own `; escape reads as a semicolon",
    HSI_ReadString(_lit, InStr(_lit, '"')), "some kinks `;3")

; ═══════════════════════════════════════════════════════════════════════════════
;  2. steps survive a render / parse cycle, INCLUDING the send function
; ───────────────────────────────────────────────────────────────────────────────
;  Three blocks in content\general.ahk mix snd() and SendText() in one body, so
;  "which function sends this line" is per step and not per block. A renderer that
;  flattened them would turn a paste into a send — an extra Enter in a real chat.
; ═══════════════════════════════════════════════════════════════════════════════
steps := [{fn: "snd",      text: "first line",              ms: ""},
          {fn: "SendText", text: 'a "quoted" paste',        ms: ""},
          {fn: "Sendt",    text: "waits a second",          ms: "1000"},
          {fn: "Sendt",    text: "waits the block's local", ms: "t"},
          {fn: "snd",      text: "two`nlines in one send",  ms: ""}]
back := HSI_StepsFromBody(HSI_RenderBody(steps))
Tck("render/parse keeps the step count", back.Length, steps.Length)
for i, want in steps {
    if (i > back.Length)
        break
    Tck("step " i " function", StrLower(back[i].fn), StrLower(want.fn))
    Tck("step " i " text",     back[i].text,         want.text)
    if (StrLower(want.fn) = "sendt")
        Tck("step " i " wait",  back[i].ms,           want.ms)
}

; A Sendt whose wait is a NAME must come back as that name. This is BRI.ahk's
; `sendt("…", t)`, and rewriting it as a number would break the block it lives in.
Ck("Sendt keeps a variable wait verbatim",
   InStr(HSI_RenderBody([{fn: "Sendt", text: "x", ms: "t"}]), "Sendt(" Chr(34) "x" Chr(34) ", t)"),
   "rendered: " Trim(HSI_RenderBody([{fn: "Sendt", text: "x", ms: "t"}]), " `t`r`n"))

; A Sendt with no wait at all falls back to 500 rather than emitting `Sendt("x", )`.
Ck("Sendt with no wait renders a default",
   InStr(HSI_RenderBody([{fn: "Sendt", text: "x", ms: ""}]), ", 500)"),
   "rendered: " Trim(HSI_RenderBody([{fn: "Sendt", text: "x", ms: ""}]), " `t`r`n"))

; ═══════════════════════════════════════════════════════════════════════════════
;  3. plain vs not — the question the editor asks before it rewrites a body
; ═══════════════════════════════════════════════════════════════════════════════
Ck("send-only body is plain",       HSI_BodyIsPlain('    snd("a")`n    SendText("b")'))
Ck("comments do not spoil plain",   HSI_BodyIsPlain('    `; why`n    snd("a")'))
Ck("blank lines do not spoil plain", HSI_BodyIsPlain('`n    snd("a")`n`n'))
Ck("a local makes a body NOT plain", !HSI_BodyIsPlain('    t := 500`n    sendt("a", t)'),
   "BRI.ahk's blocks look like this, and rebuilding one from its steps would drop"
 . " the line the steps depend on")
Ck("any other call makes it NOT plain", !HSI_BodyIsPlain('    Sleep(200)`n    snd("a")'))

; ═══════════════════════════════════════════════════════════════════════════════
;  4. the file writers, against a sandbox file in content\
; ═══════════════════════════════════════════════════════════════════════════════
Ck("the sandbox name is free", !FileExist(SANDBOX),
   SANDBOX " already exists — refusing to touch it")
if FileExist(SANDBOX)
    Finish(1)

FileAppend("#Requires AutoHotkey v2.0`n; sandbox for hotstring_edit_test.ahk`n",
           SANDBOX, "UTF-8")

; append
r := HSI_AppendBlock(SANDBOX_REL, "", TEST_TRIGS[1],
                     HSI_RenderBody([{fn: "snd", text: "hello there", ms: ""}]),
                     "2026-08-30 09:00")
Ck("append succeeded", r.ok, r.ok ? "" : r.why)

recs := []
HSI_ParseFile(SANDBOX_REL, SANDBOX, recs)
Tck("one block after the append", recs.Length, 1)
Tck("the appended trigger",       recs[1].trigger, TEST_TRIGS[1])
Tck("the appended text",          recs[1].steps[1].text, "hello there")
Tck("the @added stamp survived",  recs[1].added, "2026-08-30 09:00")
Ck("the appended body is plain",  recs[1].plain)

; replace, changing the trigger, the options AND the body all at once
r := HSI_ReplaceBlock(SANDBOX_REL, recs[1].line, TEST_TRIGS[1], "*", TEST_TRIGS[2],
                      HSI_RenderBody([{fn: "SendText", text: 'now a "paste"', ms: ""},
                                      {fn: "Sendt",    text: "then a wait", ms: "750"}]),
                      recs[1].added)
Ck("replace succeeded", r.ok, r.ok ? "" : r.why)

recs := []
HSI_ParseFile(SANDBOX_REL, SANDBOX, recs)
Tck("still one block after the replace", recs.Length, 1)
Tck("the new trigger",  recs[1].trigger, TEST_TRIGS[2])
Tck("the new options",  recs[1].options, "*")
Tck("the stamp is kept", recs[1].added,  "2026-08-30 09:00")
Tck("step count",       recs[1].steps.Length, 2)
Tck("step 1 pastes",    StrLower(recs[1].steps[1].fn), "sendtext")
Tck("step 1 text",      recs[1].steps[1].text, 'now a "paste"')
Tck("step 2 waits",     recs[1].steps[2].ms, "750")

; the .bak is the point of the whole discipline
Ck("a .bak was written", FileExist(SANDBOX ".bak"))
Ck("no .tmp was left behind", !FileExist(SANDBOX ".tmp"))

; ── refusals: a stale line, and a trigger that has moved ──────────────────────
r := HSI_ReplaceBlock(SANDBOX_REL, recs[1].line, TEST_TRIGS[1], "", TEST_TRIGS[3],
                      HSI_RenderBody([{fn: "snd", text: "should not be written", ms: ""}]))
Ck("replace REFUSES when the line holds a different trigger", !r.ok,
   "it rewrote a block the caller had not seen — this is the failure the"
 . " verify step exists to stop")
recs := []
HSI_ParseFile(SANDBOX_REL, SANDBOX, recs)
Tck("and the file is untouched", recs[1].trigger, TEST_TRIGS[2])

r := HSI_ReplaceBlock(SANDBOX_REL, 9999, TEST_TRIGS[2], "", TEST_TRIGS[2], "")
Ck("replace REFUSES a line that is not a hotstring", !r.ok)

; ── duplicate detection ───────────────────────────────────────────────────────
; Against the REAL library, not the sandbox. HSI_FindTrigger searches
; HSI_Build(), which is general.ahk plus content\accounts\*.ahk — a loose file
; in content\ is deliberately not part of the library, so the sandbox is
; invisible to it. Read-only either way: nothing below writes.
_lib := HSI_Build()
Ck("the library is not empty", _lib.Length > 0,
   "nothing to check duplicate detection against")
if _lib.Length {
    _known := _lib[1]
    Ck("HSI_FindTrigger finds a trigger that exists",
       IsObject(HSI_FindTrigger(_known.trigger)), _known.trigger)
    Ck("HSI_FindTrigger ignores the block being edited",
       !IsObject(HSI_FindTrigger(_known.trigger, _known.file, _known.line)),
       "editing a block without renaming it must not report the block itself as a clash")
    Ck("HSI_FindTrigger is case-insensitive",
       IsObject(HSI_FindTrigger(StrUpper(_known.trigger))),
       "AHK matches hotstrings case-insensitively, so two triggers differing only"
     . " in case are one hotstring with two definitions")
}
Ck("HSI_FindTrigger returns 0 for a trigger nothing defines",
   !IsObject(HSI_FindTrigger("_hsedit_definitely_not_a_trigger")))

; ── delete ────────────────────────────────────────────────────────────────────
r := HSI_DeleteBlock(SANDBOX_REL, recs[1].line, TEST_TRIGS[2])
Ck("delete succeeded", r.ok, r.ok ? "" : r.why)
recs := []
HSI_ParseFile(SANDBOX_REL, SANDBOX, recs)
Tck("nothing left in the sandbox", recs.Length, 0)
Ck("the @added comment went with it",
   !InStr(FileRead(SANDBOX, "UTF-8"), "@added"),
   "the stamp was left behind and now dates whatever trigger comes next")

; ═══════════════════════════════════════════════════════════════════════════════
;  5. the recent / pinned store
; ═══════════════════════════════════════════════════════════════════════════════
for _, t in TEST_TRIGS
    HSU_Forget(t)

HSU_Note(TEST_TRIGS[1])
HSU_Note(TEST_TRIGS[1])
Tck("a use is counted", HSU_Count(TEST_TRIGS[1]), 2)

HSU_Note(TEST_TRIGS[2])
_recent := HSU_Recent(0)
_first := ""
for _, u in _recent {
    if (u.trigger = TEST_TRIGS[1] || u.trigger = TEST_TRIGS[2]) {
        _first := u.trigger
        break
    }
}
; Both notes land in the same second, which is the case A_Now alone cannot
; order — see HSU_Stamp. This assertion is what makes that a bug rather than a
; coin flip.
Tck("the most recent use sorts first, even within one second",
    _first, TEST_TRIGS[2])

Ck("nothing is pinned to start with", !HSU_IsPinned(TEST_TRIGS[1]))
Ck("pinning reports the new state",    HSU_TogglePin(TEST_TRIGS[1]))
Ck("and it reads back as pinned",      HSU_IsPinned(TEST_TRIGS[1]))
Ck("unpinning reports the new state", !HSU_TogglePin(TEST_TRIGS[1]))
Ck("and it reads back as unpinned",   !HSU_IsPinned(TEST_TRIGS[1]))

; A rename must carry the history over. Losing it looks like the rename having
; broken the hotstring: it drops out of the quick menu the moment you touch it.
HSU_TogglePin(TEST_TRIGS[1])
HSU_Rename(TEST_TRIGS[1], TEST_TRIGS[3])
Tck("a rename carries the count",  HSU_Count(TEST_TRIGS[3]), 2)
Ck("a rename carries the pin",     HSU_IsPinned(TEST_TRIGS[3]))
Tck("and the old name is gone",    HSU_Count(TEST_TRIGS[1]), 0)
Ck("its pin is gone too",         !HSU_IsPinned(TEST_TRIGS[1]))

; A trigger with an "=" cannot be an ini key, so it is refused rather than
; written mangled. Same rule the [hotstring] section in core\hotkeys.ahk states.
Ck("a trigger with '=' is not usable as a key", !HSU_Usable("a=b"))
Ck("an ordinary trigger is usable",              HSU_Usable("_gns1"))
Ck("a trigger starting with ';' is refused",    !HSU_Usable(";nope"))

Out("")
Out(pass " passed, " fail " failed")
Finish(fail ? 1 : 0)
