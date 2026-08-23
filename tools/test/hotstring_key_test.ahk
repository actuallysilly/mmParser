#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstring_key_test.ahk — the [hotstring] section of hotkeys.ini.
; ───────────────────────────────────────────────────────────────────────────────
;  A hotstring can optionally have a KEY as well as a trigger. The binding is one
;  ini line, and three properties of it are worth asserting because all three fail
;  silently:
;
;    1. THE TAIL IS LAST. The Actions menu runs an action by broadcasting its
;       INDEX in HK_ORDER, so every MMA process must agree on what index N means.
;       Static declarations guarantee that; these do not — they come from the ini,
;       and a script started before you bound a hotstring has a shorter HK_ORDER.
;       Appending them after every static id is the whole of what keeps that safe,
;       and nothing about the code says so out loud. If someone declares one of
;       these earlier, the Actions menu starts firing the WRONG ACTION in older
;       processes, which is a real message to a real fan.
;
;    2. THE ORDER IS STABLE. Same reason: two processes reading the same ini must
;       build the same tail, and ini enumeration order is the file's LINE order —
;       which changes the moment a line is rewritten. Hence the sort.
;
;    3. DOTS SURVIVE. A fifth of the message library is named `..intro`,
;       `..ppv4f2`, `..bump2`. HK_Split cuts an ordinary id at its LAST dot, which
;       made `hotstring...intro` read as a section that does not exist — the key
;       was written in one place and read from another, and simply never fired.
;       These ids split at the FIRST dot instead. The first version of this
;       feature "fixed" that by refusing 23 of the user's triggers, so the round
;       trip is asserted rather than the rule.
;
;  ─── THIS FILE WRITES YOUR hotkeys.ini ───────────────────────────────────────
;  It has to: the functions under test read that file, and a fixture somewhere
;  else would be testing a copy. The [hotstring] section is snapshotted and put
;  back — including the case where you had no such section, which must end with
;  no such section rather than an empty one.
;
;  Prints to stdout. Exit 0 = all good.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn All, StdOut

#Include "../../src/core/paths.ahk"
#Include "../../src/core/hotkeys.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
pass := 0, fail := 0
Tck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── snapshot ──────────────────────────────────────────────────────────────────
; The whole section as text, and whether it existed at all. Restored in Finish(),
; which every exit path goes through — including the error handler, because a run
; that dies halfway must not leave test triggers bound to your keys.
_savedBody := IniRead(HK_INI, "hotstring", , "")
_hadSection := false
for _sec in StrSplit(Trim(IniRead(HK_INI)), "`n", "`r")
    if (Trim(_sec) = "hotstring")
        _hadSection := true

Finish(code) {
    global _savedBody, _hadSection
    try IniDelete(HK_INI, "hotstring")
    if (_hadSection && Trim(_savedBody) != "") {
        for line in StrSplit(_savedBody, "`n", "`r") {
            eq := InStr(line, "=")
            if eq
                try IniWrite(Trim(SubStr(line, eq + 1)), HK_INI, "hotstring",
                             Trim(SubStr(line, 1, eq - 1)))
        }
    }
    ExitApp(code)
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    Finish(1)
}

; ── the ordering property, measured BEFORE anything is added ──────────────────
; HK_ORDER is built at load, so this is the shape the app actually ships with,
; whatever the ini happened to hold when the test started.
Out("── HK_ORDER ──")
_lastStatic := 0, _firstHs := 0
for i, id in HK_ORDER {
    if HK_IsHotstringId(id) {
        if !_firstHs
            _firstHs := i
    } else
        _lastStatic := i
}
Out("  " HK_ORDER.Length " ids, first hotstring at " (_firstHs ? _firstHs : "(none)")
  . ", last static at " _lastStatic)
Tck("every hotstring id comes after every static id",
    (_firstHs = 0 || _firstHs > _lastStatic) ? 1 : 0, 1)

; The section has to have a label or the Hotkeys tab throws indexing
; HK_SECTION_LABEL — a row with no label is not a styling problem, it is a crash
; on the one window that lists these.
Tck("the section is labelled", HK_SECTION_LABEL.Has("hotstring"), 1)

; ── ids ───────────────────────────────────────────────────────────────────────
Out("── ids ──")
Tck("id is prefixed",        HK_HotstringId("_gns1"), "hotstring._gns1")
Tck("id is trimmed",         HK_HotstringId("  _gns1 "), "hotstring._gns1")
Tck("recognised",            HK_IsHotstringId("hotstring._gns1"), 1)
Tck("a static id is not",    HK_IsHotstringId("mass.active.fu1"), 0)
; The id has to split back into the section and key it was written under, or
; HK_Key looks in the wrong place and every one of these is silently unbound.
_s := HK_Split(HK_HotstringId("_gns1"))
Tck("splits back: section",  _s.section, "hotstring")
Tck("splits back: key",      _s.key,     "_gns1")

; ── reading the section ───────────────────────────────────────────────────────
Out("── triggers ──")
IniDelete(HK_INI, "hotstring")
Tck("no section = nothing",  HK_HotstringTriggers().Length, 0)

; Written deliberately out of alphabetical order: the sort is what makes two
; processes agree, so a test that writes them sorted proves nothing.
IniWrite("^!TestKeyB", HK_INI, "hotstring", "zzTestB")
IniWrite("^!TestKeyA", HK_INI, "hotstring", "aaTestA")
IniWrite("",    HK_INI, "hotstring", "mmTestBlank")
_t := HK_HotstringTriggers()
Tck("three triggers",        _t.Length, 3)
Tck("sorted, 1st",           _t[1], "aaTestA")
Tck("sorted, 2nd",           _t[2], "mmTestBlank")
Tck("sorted, 3rd",           _t[3], "zzTestB")

; A blank value is "declared but disabled", exactly as it is everywhere else in
; this ini — it must still be LISTED, or the Hotkeys tab would have no row to set
; a key on and the binding would be unreachable from the GUI.
Tck("blank value still listed", _t[2], "mmTestBlank")
Tck("...and reads as unbound",  HK_Key(HK_HotstringId("mmTestBlank")), "")
Tck("a real one reads back",    HK_Key(HK_HotstringId("aaTestA")), "^!TestKeyA")

; ── dots ──────────────────────────────────────────────────────────────────────
;  A fifth of the real message library is named `..intro`, `..ppv4f2`, `..bump2`.
;  These ids therefore split at the FIRST dot, not the last, and the first version
;  of this feature got that backwards and refused 23 triggers rather than fix the
;  id format. The round trip is what matters: an id built from a trigger has to
;  split back into the section and key the binding was WRITTEN under, or the key
;  is stored in one place and read from another and simply never fires.
Out("── dots ──")
IniWrite("^!3", HK_INI, "hotstring", "..intro")
_t := HK_HotstringTriggers()
_hasDot := 0
for t in _t
    if (t = "..intro")
        _hasDot := 1
Tck("a dotted trigger is accepted", _hasDot, 1)
Tck("...and the others survive",    _t.Length, 4)

_s := HK_Split(HK_HotstringId("..intro"))
Tck("dotted id splits at the FIRST dot: section", _s.section, "hotstring")
Tck("...key keeps every dot",                     _s.key, "..intro")
; The round trip, through the real reader: this is the assertion that would have
; caught the original bug on its own.
Tck("...so the key reads back",  HK_Key(HK_HotstringId("..intro")), "^!3")

; A static id must be unaffected — it still splits at the LAST dot, or every
; other key in MMA moves section.
_s := HK_Split("mass.1.fu1")
Tck("static ids still split at the last dot: section", _s.section, "mass.1")
Tck("...and key",                                     _s.key, "fu1")

; ── the one character that cannot work, and why nothing here can catch it ─────
;  `=` separates a key from its value, so IniWrite of the trigger `a=b` emits
;  `a=b=^!1` — which reads back as the trigger "a". The binding is mangled at the
;  moment it is WRITTEN, before any reader exists to object, and what comes back
;  is indistinguishable from someone having written a trigger called "a".
;
;  Asserted because it is the argument for where the guard lives: at the two UIs
;  that write a binding, not in HK_HotstringTriggers, where the obvious `InStr`
;  check would be dead code that reads like protection.
Out("── equals ──")
IniWrite("^!F23", HK_INI, "hotstring", "has=equals")
_t := HK_HotstringTriggers()
_mangled := 0, _intact := 0
for t in _t {
    if (t = "has")
        _mangled := 1
    if (t = "has=equals")
        _intact := 1
}
Tck("an '=' trigger is mangled by the ini itself", _mangled, 1)
Tck("...and never arrives intact",                 _intact, 0)
IniDelete(HK_INI, "hotstring", "has")

; ── duplicates ────────────────────────────────────────────────────────────────
;  Both UIs that bind one of these refuse a key that is already taken, and both
;  ask this function. It reads the INI rather than HK_META on purpose: the ids
;  differ per process, and a check that only knows this process's ids goes quiet
;  exactly when it matters.
;
;  The keys below are deliberately absurd chords. An earlier draft used ^!1 and
;  every assertion failed — because ^!1 is really bound to mass.select.m1 in the
;  shipped defaults, which is the cross-section collision this whole function
;  exists to catch. A test fixture must not pick a key the app actually uses.
Out("── duplicates ──")
Tck("a free key has no owner",   HK_KeyOwner("^!+#F22"), "")
Tck("a taken one names its id",  HK_KeyOwner("^!TestKeyA"), "hotstring.aaTestA")
Tck("...ignoring whitespace",    HK_KeyOwner("  ^!TestKeyA  "), "hotstring.aaTestA")
Tck("...and case",               HK_KeyOwner("^!testkeya"), "hotstring.aaTestA")
Tck("the binding does not report itself",
    HK_KeyOwner("^!TestKeyA", "hotstring.aaTestA"), "")
Tck("a blank key owns nothing",  HK_KeyOwner(""), "")
; The blank-valued entry must never be reported as owning anything, or every
; unbound row would collide with every other unbound row.
Tck("blank entries are not owners",
    InStr(HK_KeyOwner("^!+#F22"), "mmTestBlank") ? 1 : 0, 0)
; Across sections, which is the entire point: a hotstring key clashing with a
; mass key is the collision worth catching, and the two live in different
; sections written by different windows.
Tck("it sees the static sections too",
    HK_KeyOwner(HK_Key("mass.select.m1")) != "" ? 1 : 0, 1)
Tck("...and names the right one",
    InStr(HK_KeyOwner(HK_Key("mass.select.m1")), "mass.select.m1") ? 1 : 0, 1)
IniWrite("^!TestKeyA", HK_INI, "hotstring", "zzDupe")
Tck("two owners are both named",
    HK_KeyOwner("^!TestKeyA"), "hotstring.aaTestA, hotstring.zzDupe")
IniDelete(HK_INI, "hotstring", "zzDupe")
IniDelete(HK_INI, "hotstring", "..intro")

; ── declaring ─────────────────────────────────────────────────────────────────
; One extra round of declarations on top of whatever loaded. Asserted on the
; TAIL rather than on absolute positions, since the ini may already have had
; bindings of its own when the run started.
Out("── declaring ──")
_before := HK_ORDER.Length
HK_DefHotstrings()
Tck("three ids declared", HK_ORDER.Length - _before, 3)
Tck("the last one is a hotstring id", HK_IsHotstringId(HK_ORDER[HK_ORDER.Length]), 1)
Tck("...and it is the last trigger alphabetically",
    HK_ORDER[HK_ORDER.Length], "hotstring.zzTestB")
Tck("it has a label", HK_META["hotstring.aaTestA"].label, "Send hotstring  aaTestA")

Out("")
Out(pass " passed, " fail " failed")
Finish(fail ? 1 : 0)
