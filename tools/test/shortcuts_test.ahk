#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  shortcuts_test.ahk — the hotstring shortcuts file, end to end.
; ───────────────────────────────────────────────────────────────────────────────
;  hotstrings\shortcuts.ahk turns userdata\shortcuts.ini into live triggers that
;  run registry actions. Three things can go wrong with that and only one of them
;  is visible without a test:
;
;    THE SEEDED FILE IS UNREADABLE. It is generated as a continuation section in
;    AHK source and then read back through the WINDOWS profile API, which is a
;    different parser with different rules about BOMs, comments and whitespace.
;    A file that looks perfect in an editor and returns nothing from IniRead is
;    the exact shape of this failure, and it is silent: no triggers, no error.
;
;    THE EXAMPLE ACTIONS ARE NOT REAL. Every id in the seeded file is a promise
;    about HK_META. Rename an action in hotkeys.ahk and the file still names the
;    old one — so the examples are checked against the registry here, including
;    the COMMENTED-OUT ones, which is the half a running MMA never validates
;    because it never reads them.
;
;    A BAD LINE TAKES THE REST WITH IT. This is a hand-edited file; a typo is the
;    normal case, not the exception, and one must cost its own line only.
;
;  Runs against a TEMP file, so the real userdata\shortcuts.ini is untouched — it
;  is the one file in userdata\ MMA never rewrites, and a test that clobbered it
;  would delete a list the user keeps in an order that means something to them.
;
;  Registration is exercised on triggers nobody types (..zzprobe*), never on the
;  seeded ones, so running this cannot put ..dorail on the live keyboard for the
;  second it is alive.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

; StdOut, not a dialog: this file names HK_Key and FEAT, and a #Warn about a
; global one of its includes did not set would otherwise hang the whole run with
; no output — see the note in tools\test\README.md.
#Warn VarUnset, StdOut
#Include "../../src/core/hotkeys.ahk"
#Include "../../src/hotstrings/shortcuts.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError(Err)
Err(e, mode) {
    Out("ERROR: " e.Message " | " (e.HasProp("Extra") ? e.Extra : "")
      . " @ " e.File ":" e.Line)
    ExitApp(1)
}
pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── a throwaway cfg, so LOGE cannot open a dialog ────────────────────────────
;  This test deliberately feeds SHORTCUTS_Register a bad action id, and that is a
;  LOGE. With Settings ▸ Debug ▸ "Report errors with a pop-up" switched on — which
;  is a real setting a real user has on right now — LOGE shows a MODAL MsgBox, and
;  a modal box in a headless test run is not a failure, it is a HANG with two
;  passing lines printed before it. Measured, the first time this file was run.
;
;  Pointing MMA_CFG at a temp path is the fix rather than writing Popups=0 into
;  the real one: a test that edits the user's diagnostics settings to make itself
;  pass is the thing tools\test\README.md warns about, and this way the [Debug]
;  block simply reads as its defaults.
;
;  _LOG_T := 0 forces a re-read. The switches are cached for LOG_SETTINGS_TTL, and
;  by this line the logger may already have read the REAL cfg once.
MMA_CFG := A_Temp "\mma_shortcuts_test_cfg.ini"
_LOG_T  := 0
try FileDelete(MMA_CFG)

; ── a throwaway shortcuts file, not the user's ───────────────────────────────
MMA_SHORTCUTS := A_Temp "\mma_shortcuts_test.ini"
try FileDelete(MMA_SHORTCUTS)

; ── the seeder writes something the Windows ini reader can read ──────────────
SHORTCUTS_Seed()
Ck("seed wrote a file", FileExist(MMA_SHORTCUTS) ? 1 : 0, 1)

lines := SHORTCUTS_Lines()
Out("parsed " lines.Length " live line(s):")
for L in lines
    Out("   '" L.trigger "'  ->  '" L.target "'")

; Exactly the live ones. Everything else in the seeded file is commented out, and
; a `;` line coming back as a shortcut would mean the whole file is being read as
; data rather than as an ini.
Ck("two live shortcuts", lines.Length, 2)
if (lines.Length = 2) {
    Ck("first trigger",  lines[1].trigger, "..dorail")
    Ck("first target",   lines[1].target,  "gui.toggleRailBadge")
    Ck("second trigger", lines[2].trigger, "..dostats")
    Ck("second target",  lines[2].target,  "gui.toggleStats")
}

; ── every id the seeded file names is real ───────────────────────────────────
for L in lines {
    Ck("HK_META has " L.target,   HK_META.Has(L.target) ? 1 : 0, 1)
    Ck("HK_IndexOf " L.target,    HK_IndexOf(L.target) > 0 ? 1 : 0, 1)
}
; The commented-out examples too. Nothing at runtime ever reads these, so a
; rename would rot them silently until the day you uncomment one.
for id in ["gui.toggleReplyBox", "gui.actions", "gui.quickActions",
           "gui.hotstringMenu"]
    Ck("commented example " id " is real", HK_META.Has(id) ? 1 : 0, 1)

; The paths in the commented `run:` examples have to exist as well, for the same
; reason: an example that cannot work is worse than no example.
for rel in ["tools\detection_overlay_debug.ahk", "tools\fansly_probe.ahk"]
    Ck("run: example " rel " exists", FileExist(MMA_ROOT "\" rel) ? 1 : 0, 1)

; ── HK_IndexOf agrees with the order every process broadcasts ────────────────
; The index IS the wire format (see _HK_OnFire), so this is not a formality.
Ck("index of the first id",  HK_IndexOf(HK_ORDER[1]), 1)
Ck("unknown id has no index", HK_IndexOf("nope.nothing"), 0)

; ── a bad line is refused and registers nothing ──────────────────────────────
Ck("unknown action refused",
   SHORTCUTS_Register("..zzprobebad", "gui.thisDoesNotExist") ? 1 : 0, 0)

; ── good ones register ───────────────────────────────────────────────────────
Ck("real action registers",
   SHORTCUTS_Register("..zzprobe", "gui.toggleRailBadge") ? 1 : 0, 1)
; run: is not checked against the registry — it names a file, not an action.
Ck("run: registers with no registry id",
   SHORTCUTS_Register("..zzproberun", "run:tools\fansly_probe.ahk") ? 1 : 0, 1)

; ── malformed lines cost their own line and nothing else ─────────────────────
FileAppend("`nthis line has no equals sign`n= no trigger`n..lonely =`n",
           MMA_SHORTCUTS, "UTF-8-RAW")
Ck("malformed lines skipped, the good ones survive", SHORTCUTS_Lines().Length, 2)

; ── a missing file is empty, not an error ────────────────────────────────────
try FileDelete(MMA_SHORTCUTS)
Ck("no file means no shortcuts", SHORTCUTS_Lines().Length, 0)
try FileDelete(MMA_CFG)

Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
