#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  nextfu_test.ahk — "which follow-up was last sent in this chat?"
; ───────────────────────────────────────────────────────────────────────────────
;  The one-key follow-up walker reads the conversation and picks the next group.
;  Get this wrong in the safe direction and you send nothing; get it wrong in the
;  unsafe direction and a fan gets the same message twice, or gets f3 before f2.
;
;  Everything here is pure: normalisation, needle selection, and the last-group
;  decision. No OCR, no screen. The conversations below are written as text the
;  way OCR would hand it over, including the ways OCR mangles it.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/runtime.ahk"

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

CFG := NFU_Cfg()

; A mass with three distinct follow-ups, the shape masses.json produces.
M := {
    fu1: "hey babe did you get a chance to look at what i sent you earlier",
    fu1_5: "", fu1_7: "",
    fu2: "im still thinking about it honestly cant stop picturing your reaction",
    fu2_5: "", fu2_7: "",
    fu3: "last chance before i take it down tonight promise you wont regret it",
    fu3_5: "", fu3_7: ""}

Last(hay) {
    global M, CFG
    return NFU_LastGroup(M, NFU_Norm(hay), CFG).group
}

; ── normalisation ────────────────────────────────────────────────────────────
; Spaces and punctuation are dropped because OCR engines disagree about them
; constantly — that is the entire reason matching is done on letters and digits.
Ck("norm lowercases",        NFU_Norm("HeyBabe"), "heybabe")
Ck("norm drops spaces",      NFU_Norm("hey babe"), "heybabe")
Ck("norm drops punctuation", NFU_Norm("hey, babe!"), "heybabe")
Ck("norm drops emoji",       NFU_Norm("hey babe 💘"), "heybabe")
Ck("norm keeps digits",      NFU_Norm("pay $25 now"), "pay25now")
Ck("norm of empty",          NFU_Norm(""), "")

; ── the basic walk ───────────────────────────────────────────────────────────
Ck("empty chat -> none",  Last(""), 0)
Ck("only fan chatter",    Last("hey there whats up how are you doing today"), 0)
Ck("f1 sent",             Last("hey babe did you get a chance to look at what i sent you earlier"), 1)
Ck("f1 then f2",          Last("hey babe did you get a chance to look at what i sent you earlier"
                             . " im still thinking about it honestly cant stop picturing your reaction"), 2)
Ck("f1 f2 f3",            Last("hey babe did you get a chance to look at what i sent you earlier"
                             . " im still thinking about it honestly cant stop picturing your reaction"
                             . " last chance before i take it down tonight promise you wont regret it"), 3)

; ── the fan talks in between, which is the normal case ───────────────────────
Ck("fan replies between", Last("hey babe did you get a chance to look at what i sent you earlier"
                             . " yeah sorry i was at work all day whats up"
                             . " im still thinking about it honestly cant stop picturing your reaction"
                             . " haha you are too much"), 2)

; ── POSITION decides, not group number ───────────────────────────────────────
; Re-sending an earlier follow-up on purpose is a thing you do. Taking the
; highest group number present would then send f3 next and skip f2 forever.
Ck("f2 then f1 again -> f1 is last",
   Last("im still thinking about it honestly cant stop picturing your reaction"
      . " hey babe did you get a chance to look at what i sent you earlier"), 1)

; A previous round of the same mass higher up must not win over a later one.
Ck("old f3 above, new f1 below",
   Last("last chance before i take it down tonight promise you wont regret it"
      . " ok that was last week"
      . " hey babe did you get a chance to look at what i sent you earlier"), 1)

; ── OCR damage ───────────────────────────────────────────────────────────────
; Three needles are taken from each message — start, middle, end — so a mangled
; character has to land in all three to hide the message.
Ck("typo near the start",
   Last("hey babO did you get a chance to look at what i sent you earlier"), 1)
Ck("typo in the middle",
   Last("hey babe did you get a chanco to look at what i sent you earlier"), 1)
Ck("typo at the end",
   Last("hey babe did you get a chance to look at what i sent you earliOr"), 1)
Ck("line broken mid-word (spaces are dropped anyway)",
   Last("hey babe did you get a cha`nnce to look at what i sent you earlier"), 1)

; ── text around the message, which the user called out explicitly ────────────
Ck("timestamp and name around it",
   Last("Silly 14:32 hey babe did you get a chance to look at what i sent you earlier Seen"), 1)
Ck("two messages on one line",
   Last("...tip me? hey babe did you get a chance to look at what i sent you earlier ok??"), 1)

; ── short and empty follow-ups ───────────────────────────────────────────────
; A follow-up too short to identify must never match: "hey" appears everywhere,
; and matching it would pick a group essentially at random.
S := {fu1: "hey", fu1_5: "", fu1_7: "",
      fu2: "im still thinking about it honestly cant stop picturing your reaction",
      fu2_5: "", fu2_7: "",
      fu3: "", fu3_5: "", fu3_7: ""}
Ck("too-short f1 ignored",
   NFU_LastGroup(S, NFU_Norm("hey hey hey hey hey"), CFG).group, 0)
Ck("empty f3 ignored",
   NFU_LastGroup(S, NFU_Norm("im still thinking about it honestly cant stop picturing your reaction"), CFG).group, 2)

; ── multi-part follow-ups (fuN, fuN_5, fuN_7 are three separate messages) ────
P := {fu1: "first part of the opener that goes out on its own",
      fu1_5: "second part which lands a few seconds later",
      fu1_7: "and the third part rounds it off nicely",
      fu2: "completely different second follow up message here",
      fu2_5: "", fu2_7: "",
      fu3: "", fu3_5: "", fu3_7: ""}
Ck("matches the first part",  NFU_LastGroup(P, NFU_Norm("first part of the opener that goes out on its own"), CFG).group, 1)
Ck("matches a middle part",   NFU_LastGroup(P, NFU_Norm("second part which lands a few seconds later"), CFG).group, 1)
Ck("matches the last part",   NFU_LastGroup(P, NFU_Norm("and the third part rounds it off nicely"), CFG).group, 1)
; Only the LAST part is on screen because the pane scrolled — still group 1.
Ck("later group still wins",
   NFU_LastGroup(P, NFU_Norm("and the third part rounds it off nicely"
                           . " completely different second follow up message here"), CFG).group, 2)

; ── needles ──────────────────────────────────────────────────────────────────
Ck("short part -> no needles", NFU_Needles("hey", CFG).Length, 0)
Ck("exactly at the floor",     NFU_Needles("twelvecharss", CFG).Length, 1)
Ck("long part -> three",       NFU_Needles(M.fu1, CFG).Length, 3)
n := NFU_Needles(M.fu1, CFG)
Ck("needles are the tuned length", StrLen(n[1]), CFG.needleLen)
Ck("needles differ", n[1] != n[2] && n[2] != n[3], 1)

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
