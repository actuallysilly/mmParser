#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  branch_parse_test.ahk — does a pasted mass land in the right fields?
; ───────────────────────────────────────────────────────────────────────────────
;  The mass format is the one part of MMA a chatter types by hand, and a parser
;  that puts a line in the wrong slot does not fail — it sends the wrong message
;  to a real fan, later, in someone else's chat. So the format has a test, and it
;  runs the SHIPPING parser (mass/parser.ahk) against fake edit controls rather
;  than a copy of the rules.
;
;  Covers the `::name` marker that replaced `alt:` and `--Name`:
;    · an unmarked line is the trunk's next sub-slot (f1, f1.5, f1.7)
;    · `::name text` is that branch's answer to the group it sits in
;    · the same name twice in one group is one branch with two PARTS
;    · a branch keeps its identity by name across groups
;    · `::name` with no text says nothing rather than sending an empty message
;
;  Prints to stdout. Exit 0 = every check passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn All, StdOut

#Include "../../src/core/paths.ahk"
#Include "../../src/mass/store.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    if (e.HasProp("Extra") && e.Extra != "")
        Out("   extra: " e.Extra)
    ExitApp(1)
}

pass := 0, fail := 0
Expect(name, got, want) {
    global pass, fail
    ; Newlines make a failure unreadable in a one-line report, so they are shown
    ; as ⏎ — the VALUES are compared untouched.
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" Vis(got) "> want <" Vis(want) ">")
}
Vis(s) {
    return StrReplace(StrReplace(String(s), "`r`n", Chr(0x23CE)), "`n", Chr(0x23CE))
}

; NOTE: these helpers are NOT called Ck() or V(). mass/parser.ahk has locals named
; `ck` and `v`, and AHK matches names case-INSENSITIVELY across the whole script — a global
; function by either name makes every `ck := ...` / `v := ...` in the parser a
; load-time error
; ("This Func cannot be used as an output variable"). See the name-collision note.
;
; ── the stubs the parser expects from main_window.ahk ─────────────────────────
; A fake edit control: the parser only ever reads and writes .Value.
class FakeEdit {
    Value := ""
}

global edCtrls := Map()
global AHK_CHARS := ["``", Chr(34), ";"]
global PREFIX_EXCEPTIONS := Map("http",1, "https",1, "ftp",1, "ftps",1,
                                "mailto",1, "tel",1, "file",1)
global keyMap := Map(
    "!mm",    "mass",    "!mma",   "mass",    "mm",     "mass",    "mma",    "mass",
    "f1",     "fu1",     "f1.5",   "fu1_5",   "f1.7",   "fu1_7",
    "f2",     "fu2",     "f2.5",   "fu2_5",   "f2.7",   "fu2_7",
    "f3",     "fu3",     "f3.5",   "fu3_5",   "f3.7",   "fu3_7",
    "ppv",    "ppv_base",
    "ppvfu1", "ppv_f1",  "ppvfu2", "ppv_f2",  "ppvfu3", "ppv_f3")

#Include "../../src/mass/parser.ahk"

; One model's worth of controls, blank.
Fresh(mNo) {
    global edCtrls
    edCtrls := Map()
    for f in MASS_Fields()
        edCtrls["m" mNo "_" f] := FakeEdit()
}

FieldOf(mNo, field) {
    global edCtrls
    return edCtrls.Has("m" mNo "_" field) ? edCtrls["m" mNo "_" field].Value : "(no control)"
}

Parse(mNo, text) {
    Fresh(mNo)
    FillTab(StrSplit(StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n"), "`n"), mNo)
}

; ═══ 1. the example from the spec ══════════════════════════════════════════════
Parse(1, "
(
!mma the mass itself

follow up 1
::alt folow up 1 alternative
::mexican mehico
::german germaniaaaaa
::german gernabiaaa22222

follow up 2
::alt fu2
::alt ffu2.1
::mexican

follow up 3
::alt ddddd
)")

Out("── the spec's example ──")
Expect("mass",        FieldOf(1, "mass"),      "the mass itself")
Expect("trunk f1",    FieldOf(1, "fu1"),       "follow up 1")
Expect("trunk f2",    FieldOf(1, "fu2"),       "follow up 2")
Expect("trunk f3",    FieldOf(1, "fu3"),       "follow up 3")

; "alt" is a branch name like any other, and it was seen first.
Expect("br1 name",    FieldOf(1, "br1_name"),  "alt")
Expect("br1 fu1",     FieldOf(1, "br1_fu1"),   "folow up 1 alternative")
; Two `::alt` lines in ONE group are two PARTS of that branch's answer, which is
; the rule that makes them f2 and f2.5 at send time — not two competing choices.
Expect("br1 fu2",     FieldOf(1, "br1_fu2"),   "fu2`r`nffu2.1")
Expect("br1 fu3",     FieldOf(1, "br1_fu3"),   "ddddd")

; Same name in a later group is the SAME branch: that is what makes picking it at
; f1 commit you to it at f2.
Expect("br2 name",    FieldOf(1, "br2_name"),  "mexican")
Expect("br2 fu1",     FieldOf(1, "br2_fu1"),   "mehico")
; `::mexican` with nothing after it says nothing. An empty message here would be
; a blank line sent to a fan.
Expect("br2 fu2",     FieldOf(1, "br2_fu2"),   "")

Expect("br3 name",    FieldOf(1, "br3_name"),  "german")
Expect("br3 fu1",     FieldOf(1, "br3_fu1"),   "germaniaaaaa`r`ngernabiaaa22222")
Expect("br4 unused",  FieldOf(1, "br4_name"),  "")

; ═══ 2. the trunk still fills three sub-slots in order ═════════════════════════
Parse(2, "
(
!mma m

one
one and a half
one and three quarters

two
::soft gentler two
)")

Out("── trunk sub-slots ──")
Expect("f1",     FieldOf(2, "fu1"),     "one")
Expect("f1.5",   FieldOf(2, "fu1_5"),   "one and a half")
Expect("f1.7",   FieldOf(2, "fu1_7"),   "one and three quarters")
Expect("f2",     FieldOf(2, "fu2"),     "two")
Expect("soft",   FieldOf(2, "br1_name"), "soft")
Expect("soft f2", FieldOf(2, "br1_fu2"), "gentler two")
Expect("soft f1", FieldOf(2, "br1_fu1"), "")

; ═══ 3. the ppv group, and a branch's own ppv ══════════════════════════════════
Parse(3, "
(
!mma m

f1 line

ppv the trunk ppv
::mexican el ppv
)")

Out("── ppv ──")
Expect("ppv base",   FieldOf(3, "ppv_base"),   "the trunk ppv")
Expect("br ppv name", FieldOf(3, "br1_name"),  "mexican")
Expect("br ppv",     FieldOf(3, "br1_ppv"),    "el ppv")

; ═══ 4. keyword mode: `::name` attaches to the last labelled group ═════════════
; `f1 …` / `f2 …` / `ppv …` are keyMap keywords, so this paste takes the KEYWORD
; path, not the prefix one. Which path a paste takes is not obvious from looking
; at it — that is exactly why both are tested.
Parse(4, "
(
!mma m
f1 first
::alt other first
f2 second
::alt other second
ppv the ppv
::alt other ppv
)")

Out("── keyword mode ──")
Expect("f1",       FieldOf(4, "fu1"),       "first")
Expect("f2",       FieldOf(4, "fu2"),       "second")
Expect("ppv",      FieldOf(4, "ppv_base"),  "the ppv")
Expect("alt fu1",  FieldOf(4, "br1_fu1"),   "other first")
Expect("alt fu2",  FieldOf(4, "br1_fu2"),   "other second")
Expect("alt ppv",  FieldOf(4, "br1_ppv"),   "other ppv")

; ═══ 4b. prefix mode: `fu1`/`fu2` are NOT keywords, so this takes that path ════
Parse(7, "
(
!mma m
fu1 first
::alt other first
fu2.5 second part of two
::alt other second
ppv: the ppv
::alt other ppv
)")

Out("── prefix mode ──")
Expect("fu1",      FieldOf(7, "fu1"),       "first")
Expect("fu2.5",    FieldOf(7, "fu2_5"),     "second part of two")
Expect("ppv",      FieldOf(7, "ppv_base"),  "the ppv")
Expect("alt fu1",  FieldOf(7, "br1_fu1"),   "other first")
; The marker sat under f2.5, and it answers follow-up 2 — the sub-slots are parts
; of one answer, not follow-ups of their own.
Expect("alt fu2",  FieldOf(7, "br1_fu2"),   "other second")
Expect("alt ppv",  FieldOf(7, "br1_ppv"),   "other ppv")

; ═══ 5. a re-parse must not leave the last mass's branches behind ══════════════
Parse(5, "
(
!mma first mass

f1 mehico for real
::mexican mehico
)")
Expect("before", FieldOf(5, "br1_name"), "mexican")
Parse(5, "
(
!mma second mass, no branches at all

f1 only
)")
Out("── re-parse clears ──")
Expect("name cleared", FieldOf(5, "br1_name"), "")
Expect("fu1 cleared",  FieldOf(5, "br1_fu1"),  "")

; ═══ 6. more parts than there are sub-slots ════════════════════════════════════
; Four is one more than the three a group can send. The fourth is dropped and
; logged rather than silently overwriting the third.
Parse(6, "
(
!mma m

a
::alt 1
::alt 2
::alt 3
::alt 4
)")
Out("── the fourth part ──")
Expect("three parts", FieldOf(6, "br1_fu1"), "1`r`n2`r`n3")

; ═══ 7. a marker ALONE on its line owns the lines under it ═════════════════════
;  The shape a real mass is written in, and the one that did not parse. Reported
;  2026-08-04 with this exact paste: the branch wording goes on its OWN line under
;  the marker, and each branch sits in its own blank-line-separated block.
;
;  What used to happen: `::tits` with nothing after it was a no-op, the sentence
;  under it fell through to the TRUNK's f3, and the whole `::ass` block was counted
;  as a fourth follow-up group and dropped. So the mass came out with one branch's
;  wording as the trunk's f3, the other branch missing entirely, and nothing but a
;  line in the log to say so.
Parse(8, "
(
!mma Are you needy for nakedness?

late night opener

which curve entices you the most?
and be honest about it

::tits
smother line

::ass
throne line
)")

Out("── a marker alone on its line ──")
Expect("trunk f1",        FieldOf(8, "fu1"),      "late night opener")
Expect("trunk f2",        FieldOf(8, "fu2"),      "which curve entices you the most?")
Expect("trunk f2.5",      FieldOf(8, "fu2_5"),    "and be honest about it")
; The heart of it: the branch wording is the BRANCH's, and the trunk's f3 is empty
; because the trunk genuinely has no third message — which follow-up goes out
; depends on her answer. A sparse trunk is normal (see the masses-are-sparse note).
Expect("trunk f3 empty",  FieldOf(8, "fu3"),      "")
Expect("br1 name",        FieldOf(8, "br1_name"), "tits")
Expect("br1 f3",          FieldOf(8, "br1_fu3"),  "smother line")
; And the second branch block is NOT a fourth follow-up group. Two branch-led
; groups in a row are two choices at the same step.
Expect("br2 name",        FieldOf(8, "br2_name"), "ass")
Expect("br2 f3",          FieldOf(8, "br2_fu3"),  "throne line")
Expect("br1 f1 untouched", FieldOf(8, "br1_fu1"), "")

; Several lines under one marker are several PARTS of that branch's answer, exactly
; as repeating the marker would be — f3 then f3.5 at send time.
Parse(9, "
(
!mma m

opener

::tits
part one
part two
)")
Out("── several lines under one marker ──")
Expect("two parts", FieldOf(9, "br1_fu2"), "part one`r`npart two")

; ── the two boundaries this must NOT cross ────────────────────────────────────
; A marker WITH text on its line does not own what follows: the line after it is
; the trunk's next sub-slot, which is how every mass written before this behaved.
Parse(10, "
(
!mma m

hey did you see it?
::alt did you get my message babe?
i'm still up if you are
)")
Out("── a marker with text keeps its hands off the next line ──")
Expect("trunk f1",   FieldOf(10, "fu1"),      "hey did you see it?")
Expect("trunk f1.5", FieldOf(10, "fu1_5"),    "i'm still up if you are")
Expect("alt f1",     FieldOf(10, "br1_fu1"),  "did you get my message babe?")

; And a marker with nothing under it still says nothing — an empty message is a
; blank line sent to a fan, which is worse than a branch that stays quiet here.
Parse(11, "
(
!mma m

one
::mexican mehico

two
::mexican

three
)")
Out("── an empty marker with nothing under it ──")
Expect("br f1",        FieldOf(11, "br1_fu1"), "mehico")
Expect("br f2 silent", FieldOf(11, "br1_fu2"), "")
Expect("trunk f3",     FieldOf(11, "fu3"),     "three")

; ── the same rule in the labelled modes ───────────────────────────────────────
; An unlabelled line has no slot of its own in these modes, so it used to be
; dropped outright. Under a marker it now belongs to that branch.
Parse(12, "
(
!mma m
f1 first
::tits
smother line
f2 second
)")
Out("── keyword mode ──")
Expect("f1",      FieldOf(12, "fu1"),      "first")
Expect("f2",      FieldOf(12, "fu2"),      "second")
Expect("br f1",   FieldOf(12, "br1_fu1"),  "smother line")

Parse(13, "
(
!mma m
fu1 first
::tits
smother line
fu2 second
)")
Out("── prefix mode ──")
Expect("fu1",     FieldOf(13, "fu1"),      "first")
Expect("fu2",     FieldOf(13, "fu2"),      "second")
Expect("br fu1",  FieldOf(13, "br1_fu1"),  "smother line")

; ═══ 8. the two spellings converge — an export re-imports to the same fields ═══
;  ExportMMA (mass/archive.ahk) writes every branch part as `::name text` on ONE
;  line, so a mass written in the own-line form and then exported comes back in the
;  marker-line form. Both must land in the same slots or a round trip through
;  Export !mma would quietly move a branch's wording.
;
;  Note what the export's f3 block looks like: nothing but markers, no trunk line at
;  all. That is the branch-led group rule doing the work — it has to resolve to
;  follow-up 3, not follow-up 4.
Parse(14, "
(
!mma m

late night opener

which curve entices you the most?
and be honest about it

::tits smother line
::ass throne line
)")
Out("── the export form round-trips ──")
Expect("f1",       FieldOf(14, "fu1"),      "late night opener")
Expect("f2",       FieldOf(14, "fu2"),      "which curve entices you the most?")
Expect("f2.5",     FieldOf(14, "fu2_5"),    "and be honest about it")
Expect("f3 empty", FieldOf(14, "fu3"),      "")
Expect("br1 name", FieldOf(14, "br1_name"), "tits")
Expect("br1 f3",   FieldOf(14, "br1_fu3"),  "smother line")
Expect("br2 name", FieldOf(14, "br2_name"), "ass")
Expect("br2 f3",   FieldOf(14, "br2_fu3"),  "throne line")

; ═══ 9. `!mma` alone on top — the block under it is the mass ═══════════════════
;  Reported 2026-08-05 with a paste of exactly this shape: a bare `!mma:` and then
;  a paragraphed opener under it. It parsed as a mass of "" plus three follow-ups
;  and a dropped fourth group — the whole message went out in pieces, as replies,
;  or not at all.
;
;  The blank lines inside are PARAGRAPH BREAKS of one message, not group
;  separators, which is the entire point: this is what the fan receives.
Parse(15, "
(
!mma:

If you were my artist, how would you picture me?

Would my curves take over the entire canvas...
Or would you only sketch the parts you couldn't stop thinking about? :3

And once your painting was finally finished...
Would you step back and admire what you'd created?
)")

Out("-- a bare mass marker owns the block under it --")
Expect("the whole thing is the mass", FieldOf(15, "mass"),
       "If you were my artist, how would you picture me?`r`n`r`n"
     . "Would my curves take over the entire canvas...`r`n"
     . "Or would you only sketch the parts you couldn't stop thinking about? :3`r`n`r`n"
     . "And once your painting was finally finished...`r`n"
     . "Would you step back and admire what you'd created?")
Expect("nothing became f1", FieldOf(15, "fu1"), "")
Expect("nothing became f2", FieldOf(15, "fu2"), "")
Expect("nothing became f3", FieldOf(15, "fu3"), "")

; A labelled line ENDS the block — it names a field, so it is that field's.
Parse(16, "
(
!mm

first paragraph

second paragraph
f1 the actual follow-up
f2 and the second
)")
Out("-- a labelled line ends the block --")
Expect("mass",  FieldOf(16, "mass"), "first paragraph`r`n`r`nsecond paragraph")
Expect("f1",    FieldOf(16, "fu1"),  "the actual follow-up")
Expect("f2",    FieldOf(16, "fu2"),  "and the second")

; So does a `---` fence, which is what ExportMMA writes for a multiline mass —
; unlabelled positional follow-ups have nothing else to stop the block with.
Parse(17, "
(
!mma

paragraph one

paragraph two
---

late night opener
still up?

which curve entices you the most?
)")
Out("-- a fence closes the block --")
Expect("mass",   FieldOf(17, "mass"),   "paragraph one`r`n`r`nparagraph two")
Expect("f1",     FieldOf(17, "fu1"),    "late night opener")
Expect("f1.5",   FieldOf(17, "fu1_5"),  "still up?")
Expect("f2",     FieldOf(17, "fu2"),    "which curve entices you the most?")
; The fence itself is eaten with the block, not left to collapse the ppv.
Expect("no stray ppv", FieldOf(17, "ppv_base"), "")

; A branch marker ends it too, so the block cannot swallow a branch's wording.
Parse(18, "
(
!mma

the opener

::tits smother line
)")
Out("-- a branch marker ends the block --")
Expect("mass",     FieldOf(18, "mass"),      "the opener")
Expect("br1 name", FieldOf(18, "br1_name"),  "tits")
Expect("br1 f1",   FieldOf(18, "br1_fu1"),   "smother line")

; And none of this touches the ordinary one-line form, in any of the three modes.
Parse(19, "
(
!mma one line mass

f1 line
)")
Out("-- the one-line form is unchanged --")
Expect("mass", FieldOf(19, "mass"), "one line mass")
; `f1 line` is prefix mode, so the label is stripped off the message text.
Expect("f1",   FieldOf(19, "fu1"),  "line")

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
