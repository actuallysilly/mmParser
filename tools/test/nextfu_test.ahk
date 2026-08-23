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

#Include "../../src/mass/runtime.ahk"

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

; ── group 3 falls back to the Default FU3 text ───────────────────────────────
; A mass with no f3 of its own SENDS the Default FU3 from Settings, so that text
; is what ends up in the conversation and that is what the walker has to match.
; Matching the blank stored fields instead meant f3 was never found: press again
; and it read f2 as the last one sent and re-sent the default to the same fan.
;
; This writes to the live cfg to make the fallback deterministic, so it saves and
; restores it. A test that edits real config has to leave it as it found it —
; mass_bind_test used to change ModelMatch and never put it back.
_savedFu3 := IniRead(MMA_CFG, "Settings", "DefaultFu3", "")
IniWrite("this is the fallback third follow up message", MMA_CFG, "Settings", "DefaultFu3")
D := {fu1: "hey babe did you get a chance to look at what i sent you earlier",
      fu1_5: "", fu1_7: "",
      fu2: "im still thinking about it honestly cant stop picturing your reaction",
      fu2_5: "", fu2_7: "",
      fu3: "", fu3_5: "", fu3_7: ""}
_chat := "hey babe did you get a chance to look at what i sent you earlier"
       . " im still thinking about it honestly cant stop picturing your reaction"
       . " this is the fallback third follow up message"
; Off in Easy mode, where the fallback genuinely does not apply — so assert the
; behaviour that matches the mode rather than assuming Advanced.
if FEAT("defaultFu3")
    Ck("default f3 counts as f3", NFU_LastGroup(D, NFU_Norm(_chat), CFG).group, 3)
else
    Ck("no fallback in easy mode", NFU_LastGroup(D, NFU_Norm(_chat), CFG).group, 2)
; ...and the mass's OWN f3 still wins when it has one.
D2 := D.Clone()
D2.fu3 := "last chance before i take it down tonight promise you wont regret it"
Ck("real f3 still matches",
   NFU_LastGroup(D2, NFU_Norm("hey babe did you get a chance to look at what i sent you earlier"
                            . " last chance before i take it down tonight promise you wont regret it"),
                 CFG).group, 3)
IniWrite(_savedFu3, MMA_CFG, "Settings", "DefaultFu3")

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

; ── f1 is gated on the mass being visible ────────────────────────────────────
; "No follow-up found" has two causes a substring search cannot tell apart: the
; sequence has not started, or we cannot see it (scrolled up, or the mass never
; went to this chat). The mass being on screen is the evidence that separates
; them, so f1 waits for it. Without this the key opens with "did you see what I
; sent?" to someone who was sent nothing.
MM := {mass: "hey love i put together something special for you tonight and i really"
             . " hope you like it because i thought about you the whole time",
       fu1: "hey babe did you get a chance to look at what i sent you earlier",
       fu1_5: "", fu1_7: "", fu2: "", fu2_5: "", fu2_7: "",
       fu3: "", fu3_5: "", fu3_7: ""}

Ck("mass visible -> seen",
   NFU_MassPresence(MM, NFU_Norm("hey love i put together something special for you"
                               . " tonight and i really hope you like it because i"
                               . " thought about you the whole time"), CFG), "seen")
Ck("mass absent -> absent",
   NFU_MassPresence(MM, NFU_Norm("hey there whats up how are you doing today"), CFG), "absent")
; Only the TAIL of a long mass is still on screen — the top has scrolled off.
; Three needles exist exactly so this still counts.
Ck("mass tail only -> seen",
   NFU_MassPresence(MM, NFU_Norm("because i thought about you the whole time"), CFG), "seen")
; OCR damage in one window must not hide it either.
Ck("mass with a typo -> seen",
   NFU_MassPresence(MM, NFU_Norm("hey love i put together something speciai for you"
                               . " tonight and i really hope you like it because i"
                               . " thought about you the whole time"), CFG), "seen")
; Nothing to check against is NOT permission to send.
NOMASS := MM.Clone()
NOMASS.mass := ""
Ck("no mass stored -> uncheckable",
   NFU_MassPresence(NOMASS, NFU_Norm("anything at all here"), CFG), "uncheckable")
; A mass too short to identify is equally unusable as evidence.
SHORTMASS := MM.Clone()
SHORTMASS.mass := "hi"
Ck("mass too short -> uncheckable",
   NFU_MassPresence(SHORTMASS, NFU_Norm("hi"), CFG), "uncheckable")

; The gate applies ONLY to starting the sequence. Once a follow-up is on screen
; the thread speaks for itself and the mass may well have scrolled away.
Ck("f1 on screen still walks to f2 without the mass",
   NFU_LastGroup(M, NFU_Norm("hey babe did you get a chance to look at what i sent you earlier"),
                 CFG).group, 1)

; ── sparse masses, which are the normal case and not an edge case ────────────
; A mass is not required to carry all three follow-ups. f1 only is common; f1 and
; f3 with a hole in the middle is legitimate too. "Next" therefore means the next
; follow-up THAT EXISTS — counting group + 1 blindly fired an empty send, and
; sndFu returns silently on empty parts, so the key did nothing while announcing
; that it had sent something.
;
; DefaultFu3 is forced blank here so group 3 is genuinely empty: with it set, a
; mass with no f3 still HAS a third follow-up (the fallback) and would rightly
; report one. Saved and restored, like every other test that touches live config.
_savedFu3b := IniRead(MMA_CFG, "Settings", "DefaultFu3", "")
IniWrite("", MMA_CFG, "Settings", "DefaultFu3")

ONLY1 := {fu1: "hey babe did you get a chance to look at what i sent you earlier",
          fu1_5: "", fu1_7: "", fu2: "", fu2_5: "", fu2_7: "",
          fu3: "", fu3_5: "", fu3_7: ""}
Ck("f1-only: nothing sent yet -> f1", NFU_NextWithContent(ONLY1, 0), 1)
Ck("f1-only: after f1 -> nothing",    NFU_NextWithContent(ONLY1, 1), 0)

; The hole in the middle: after f1 the next one that exists is f3, not "f2 then
; give up". Skipping is the right answer — f3 is a real message the fan has not had.
GAP := {fu1: "hey babe did you get a chance to look at what i sent you earlier",
        fu1_5: "", fu1_7: "", fu2: "", fu2_5: "", fu2_7: "",
        fu3: "last chance before i take it down tonight promise you wont regret it",
        fu3_5: "", fu3_7: ""}
Ck("gap: after f1 -> skips to f3", NFU_NextWithContent(GAP, 1), 3)
Ck("gap: after f3 -> nothing",     NFU_NextWithContent(GAP, 3), 0)

; A part in fuN_5 with fuN itself blank still counts as content.
LATE := {fu1: "", fu1_5: "the second part carries this whole follow-up", fu1_7: "",
         fu2: "", fu2_5: "", fu2_7: "", fu3: "", fu3_5: "", fu3_7: ""}
Ck("a _5 part alone counts", NFU_NextWithContent(LATE, 0), 1)

EMPTY := {fu1: "", fu1_5: "", fu1_7: "", fu2: "", fu2_5: "", fu2_7: "",
          fu3: "", fu3_5: "", fu3_7: ""}
Ck("nothing to send at all", NFU_NextWithContent(EMPTY, 0), 0)

IniWrite(_savedFu3b, MMA_CFG, "Settings", "DefaultFu3")

; With a Default FU3 configured, a mass with no f3 DOES have a third follow-up,
; so the walk runs f1 -> f2 -> default. Mode-aware, since Easy switches it off.
IniWrite("this is the fallback third follow up message", MMA_CFG, "Settings", "DefaultFu3")
NOF3 := {fu1: "hey babe did you get a chance to look at what i sent you earlier",
         fu1_5: "", fu1_7: "",
         fu2: "im still thinking about it honestly cant stop picturing your reaction",
         fu2_5: "", fu2_7: "", fu3: "", fu3_5: "", fu3_7: ""}
Ck("after f2, the default counts as f3",
   NFU_NextWithContent(NOF3, 2), FEAT("defaultFu3") ? 3 : 0)
IniWrite(_savedFu3b, MMA_CFG, "Settings", "DefaultFu3")

; ── needles ──────────────────────────────────────────────────────────────────
Ck("short part -> no needles", NFU_Needles("hey", CFG).Length, 0)
Ck("exactly at the floor",     NFU_Needles("twelvecharss", CFG).Length, 1)
Ck("long part -> three",       NFU_Needles(M.fu1, CFG).Length, 3)
n := NFU_Needles(M.fu1, CFG)
Ck("needles are the tuned length", StrLen(n[1]), CFG.needleLen)
Ck("needles differ", n[1] != n[2] && n[2] != n[3], 1)

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
