#Requires AutoHotkey v2.0
#SingleInstance Off
; ═══════════════════════════════════════════════════════════════════════════════
;  screenmap_test.ahk — offline checks for core\screenmap.ahk (the AHK reader).
;  Runs against a FIXTURE map in %TEMP%, never userdata\layout\infloww.json, and
;  never sends a key or clicks. Every refusal is non-interactive (no tooltip).
;
;      AutoHotkey64.exe /ErrorStdOut tools\screenmap_test.ahk
;  Prints one line per check; exit code = number of failures.
; ═══════════════════════════════════════════════════════════════════════════════
#Include "../src/core/screenmap.ahk"

global fails := 0
; An error must print and exit, never open a dialog: a dialog hangs the run.
OnError(TestCrashed)
TestCrashed(e, mode) {
    FileAppend("  CRASH " e.Message " " e.Extra "`n" e.Stack "`n", "*")
    ExitApp(99)
}
fixture := A_Temp "\mma_screenmap_fixture.json"
MMA_SCREENMAP := fixture

Check(what, got, want) {
    global fails
    ok := (got = want)
    fails += !ok
    FileAppend((ok ? "  ok   " : "  FAIL ") what ": " got (ok ? "" : "  (want " want ")") "`n", "*")
}

WriteFixture(updated) {
    text := '
    (
    {"schema": 1, "focus_hwnd": 111, "updated": @NOW@, "windows": [
     {"hwnd": 111, "kind": "main", "status": "ok", "reason": "", "model": "CIN",
      "last_focus": 100, "rect": [0, 0, 3441, 1381], "check": [],
      "regions": {"composer": [551, 1151, 2504, 230]}},
     {"hwnd": 222, "kind": "fan", "status": "ok", "reason": "", "model": "HAIL",
      "last_focus": 300, "rect": [-4243, -247, 4130, 1658], "check": [], "regions": {}},
     {"hwnd": 333, "kind": "main", "status": "ok", "reason": "", "model": "Hail",
      "last_focus": 200, "rect": [0, 0, 100, 100], "check": [], "regions": {}},
     {"hwnd": 444, "kind": "other", "status": "unsure",
      "reason": "a popup is open over Infloww (everything is dimmed)",
      "last_focus": 0, "rect": [0, 0, 10, 10], "check": [], "regions": {}}
    ]}
    )'
    FileOpen(fixture, "w", "UTF-8-RAW").Write(StrReplace(text, "@NOW@", updated))
}

FileAppend("reading the map:`n", "*")
WriteFixture(SM_UnixNow())
doc := SM_Load()
Check("windows", doc["windows"].Length, 4)
Check("window 111 model", SM_Window(111)["model"], "CIN")
Check("no such window", SM_Window(999), "")

FileAppend("which window for a model (last used wins):`n", "*")
Check("HAIL -> fan window used last", SM_ForModel("HAIL")["hwnd"], 222)
Check("hail (OCR case) matches too", SM_ForModel("hail")["hwnd"], 222)
Check("CIN -> its main window", SM_ForModel("CIN")["hwnd"], 111)
Check("unknown model", SM_ForModel("TAL"), "")

FileAppend("the gate refuses when it can't vouch:`n", "*")
; 111 is not a real window, so its spot check fails and nothing can re-measure.
Check("fake window refused", SM_Require("composer", 111, false), "")
Check("popup window refused", _SM_Problem(SM_Load(), 444, ""),
      "a popup is open over Infloww (everything is dimmed)")
Check("unknown window", _SM_Problem(SM_Load(), 999, ""), "you're not in an Infloww Messages window")
Check("missing region", _SM_Problem(SM_Load(), 222, "list"), "this window has no list right now")

FileAppend("a stale map = the service is off:`n", "*")
WriteFixture(SM_UnixNow() - 60)
Check("stale", _SM_Problem(SM_Load(), 111, ""), "!stale")

FileDelete(fixture)
FileAppend((fails ? fails " FAILED" : "ALL PASSED") "`n", "*")
ExitApp(fails)
