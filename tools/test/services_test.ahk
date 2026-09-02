#Requires AutoHotkey v2.0
; #Warn VarUnset, StdOut — REQUIRED, and not a style choice.
;
; VarUnset is on by default in v2 and fires at LOAD. processes.ahk reads
; globals that only the main window ever assigns (SCRIPT_DIR, btnTools), so
; including it from a bare script raises a warning — and a warning is a MODAL
; DIALOG, even under /ErrorStdOut. The run then hangs forever with no output,
; which reads exactly like the test passing slowly. Sending warnings to stdout
; is what makes this file runnable unattended. settings_build_test.ahk uses
; `#Warn All, StdOut` for the same reason; VarUnset alone is enough here and
; does not bury the output under the tree's ~80 shadowed-global notices.
#Warn VarUnset, StdOut
; ═══════════════════════════════════════════════════════════════════════════════
;  services_test.ahk — the background-service registry holds together.
; ───────────────────────────────────────────────────────────────────────────────
;  core/processes.ahk used to carry eleven hand-written Launch*/Stop*/*Running
;  triples, and FOUR separate hand-kept lists decided when each one ran: the boot
;  list in ui/main_core.ahk, the if/else chain in ui/features_panel.ahk,
;  TOOLS_List in ui/tools_window.ahk, and WatchdogTick. Nothing checked that the
;  four agreed, and they did not:
;
;    * fanslyDetector, activity and autoword were absent from the BOOT list, so
;      they only started on the first watchdog tick five seconds later — and
;      never at all with startupScripts off, which is what Easy mode does;
;    * activity and autoword were absent from the FEATURES chain, so unticking
;      either wrote the cfg key and left the process running. "Activity tracker"
;      read off in Settings while it went on counting keystrokes until restart.
;
;  Both bugs are the same bug: a list of services somewhere other than the list of
;  services. SVC_ORDER is the only list now, and this file is what stops a second
;  one growing back — every check below is a property that was true by hand and
;  is now true by construction, asserted so it stays that way.
;
;  Pure: reads the registry and the filesystem. Starts nothing, stops nothing,
;  writes no settings. Safe to run mid-shift.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

; processes.ahk carries the registry. hotkeys.ahk and theme.ahk are what IT
; leans on its includer for (HK_Key in the no-Python message; the theme calls
; in the Tools window), and tools_window.ahk is here because TOOLS_List is the
; one reader of SVC_ORDER that lives outside core — which is exactly the seam
; the old hand-written table went stale across.
#Include "../../src/core/paths.ahk"
#Include "../../src/core/theme.ahk"
#Include "../../src/core/hotkeys.ahk"
#Include "../../src/core/processes.ahk"
#Include "../../src/ui/tools_window.ahk"

; The two globals processes.ahk expects its INCLUDER to own. The main window
; assigns both; a test does not, and reading an unassigned global is what the
; #Warn line above would otherwise print two notices about on every run. Assigning
; them here states the contract instead of muting it — SCRIPT_DIR is the tree root
; every child is launched from, and startupScripts is the list LaunchStartupScripts
; walks, which is empty because this test starts nothing.
global SCRIPT_DIR := MMA_ROOT
global startupScripts := []

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
Ok(name, cond) {
    global pass, fail
    if cond
        pass++
    else
        fail++, Out("FAIL " name)
}

; ── the registry is populated at all ──────────────────────────────────────────
; A registry that silently ended up empty would make every check below vacuous:
; "no service is missing a path" is trivially true of no services. This is the
; guard on the guards.
Ok("SVC_ORDER is not empty", SVC_ORDER.Length > 0)
Ck("SVC_META and SVC_ORDER agree", SVC_META.Count, SVC_ORDER.Length)
Ok("at least the nine shipped services", SVC_ORDER.Length >= 9)

; ── every service is a declared FEATURE ───────────────────────────────────────
; This is the whole contract. FEAT(id) is what SVC_Launch gates on, and modes.ahk
; answers TRUE for any id NOT in its registry — so a service whose id is not a
; feature would be permanently on, in Easy mode too, with no checkbox anywhere.
; A typo in an SVC_Def id produces exactly that, and produces it silently.
for _id in SVC_ORDER {
    Ok("service '" _id "' is a declared feature", FEAT_META.Has(_id))
    Ok("service '" _id "' has a label", SVC_Label(_id) != "" && SVC_Label(_id) != _id)
}

; ── every service is one of the two kinds, with what that kind needs ──────────
for _id in SVC_ORDER {
    _s := SVC_META[_id]
    Ok("'" _id "' kind is ahk or python", _s.kind = "ahk" || _s.kind = "python")
    Ok("'" _id "' has a log tag",  _s.tag  != "")
    Ok("'" _id "' has a noun",     _s.noun != "")

    ; The file has to be on disk. A missing one is logged at launch and nothing
    ; starts — which for the .vbs launchers is a SILENT failure, because a .vbs
    ; has nowhere to report anything. Checking here means a path typo or a moved
    ; file is caught by the test run rather than by a feature that quietly does
    ; nothing.
    Ok("'" _id "' path exists: " _s.path, FileExist(_s.path) != "")

    if (_s.kind = "python") {
        ; The named event is both the "is it up?" probe and the only way to ask it
        ; to leave. Blank, SVC_Running would ask OpenEventW for "" — the service
        ; would read as permanently down and SVC_Stop could never close it.
        Ok("python '" _id "' has a stop event", _s.event != "")
        Ok("python '" _id "' event is Global\\", InStr(_s.event, "Global\") = 1)
        ; announce := true means a user clicked it by hand, so "nothing happened
        ; because Python is missing" has to be sayable out loud.
        Ok("python '" _id "' has needText", _s.needText != "")
        Ok("'" _id "' launcher is a .vbs", SubStr(_s.path, -4) = ".vbs")
    } else {
        Ok("ahk '" _id "' needs no event", _s.event = "")
        Ok("'" _id "' script is a .ahk", SubStr(_s.path, -4) = ".ahk")
    }
}

; ── the {key} placeholder resolves ────────────────────────────────────────────
; needText may name a hotkey to mention. If needKey is set the placeholder has to
; be there to replace, and if it is not set there must be no orphan placeholder —
; a "{key}" reaching a MsgBox verbatim is the kind of thing nobody notices until
; it is in front of a user who has no Python.
for _id in SVC_ORDER {
    _s := SVC_META[_id]
    if (_s.needKey != "")
        Ok("'" _id "' needText has a {key} to fill", InStr(_s.needText, "{key}") > 0)
    else
        Ok("'" _id "' needText has no orphan {key}", InStr(_s.needText, "{key}") = 0)
}

; ── ids and paths are unique ──────────────────────────────────────────────────
; Two rows sharing an id means the second SVC_Def overwrites the first in
; SVC_META while BOTH sit in SVC_ORDER — so the service is launched twice and
; walked twice, and the Tools count double-counts it.
_seenId := Map(), _seenPath := Map(), _dupId := 0, _dupPath := 0
for _id in SVC_ORDER {
    if _seenId.Has(StrLower(_id))
        _dupId++
    _seenId[StrLower(_id)] := true
    _p := StrLower(SVC_META[_id].path)
    if _seenPath.Has(_p)
        _dupPath++
    _seenPath[_p] := true
}
Ck("no duplicate service ids",   _dupId,   0)
Ck("no two services share a file", _dupPath, 0)

; ── the services that must be OFF by default are ──────────────────────────────
; Not a style rule. These three read or write things a person has to opt into:
; typelog records the text you type, activity installs a keyboard hook that sees
; every key in every application, and autoword can put text into the message box.
; Each FEAT_Def carries a long comment saying so, and a default flipped by
; accident would arrive switched on for everyone on the next update.
for _id in ["typelog", "activity", "autoword"] {
    Ok("'" _id "' is declared", FEAT_META.Has(_id))
    if FEAT_META.Has(_id)
        Ck("'" _id "' defaults to OFF", FEAT_META[_id].default, "0")
}

; ── lookups on an unknown id do not throw ─────────────────────────────────────
; SVC_Running and SVC_Stop are called from timers and from window handlers, where
; an uncaught throw takes the window down. An id that is not in the registry has
; to be a quiet no-answer, not an exception.
Ok("SVC_Running on an unknown id is false", SVC_Running("no_such_service") = false)
try {
    SVC_Stop("no_such_service")
    pass++
} catch {
    fail++, Out("FAIL SVC_Stop on an unknown id threw")
}
Ck("SVC_Label falls back to the id", SVC_Label("no_such_service"), "no_such_service")

; ── the Tools window shows every service, and nothing else ────────────────────
; TOOLS_List used to be a hand-written table over in ui/tools_window.ahk with the
; ids retyped. It reads SVC_ORDER now; this is what says it still does.
_tools := TOOLS_List()
Ck("TOOLS_List covers every service", _tools.Length, SVC_ORDER.Length)
_i := 0
for _t in _tools {
    _i++
    Ck("TOOLS_List row " _i " is in registry order", _t.id, SVC_ORDER[_i])
}

Out(fail ? (pass " passed, " fail " failed") : ("ok  " pass " checks"))
ExitApp(fail ? 1 : 0)
