#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkey_guard_test.ahk — the Windows guard and the Help search.
; ───────────────────────────────────────────────────────────────────────────────
;  HKP_SystemOwner (ui\hotkeys_core.ahk) must refuse the combos Windows owns and
;  pass MMA's own keys — every key in YOUR hotkeys.ini must pass, or a key you
;  already have could not be re-captured. HelpQuery/HelpMatches (ui\help_panel.ahk)
;  must find "ctrl win r" as exactly Ctrl+Win+R.
;
;  Writes nothing. Reads hotkeys.ini. Prints PASS/FAIL lines; exit code = fails.
; ═══════════════════════════════════════════════════════════════════════════════
#Warn VarUnset, StdOut

#Include "../../src/core/paths.ahk"
#Include "../../src/core/hotkeys.ahk"
#Include "../../src/ui/hotkeys_panel.ahk"
#Include "../../src/ui/help_panel.ahk"

Out(s) {
    try FileAppend(s "`n", "*")
}
fails := 0
Check(name, ok, detail := "") {
    global fails
    Out((ok ? "PASS " : "FAIL ") name (detail != "" ? "  — " detail : ""))
    if !ok
        fails++
}

for k in ["^#l", "+#l", "^#d", "^#1", "^+#1", "#e", "#v", "^+#b", "^!Del",
          "^+Escape", "!Tab", "^#Enter", "^#v", "+#s", "PrintScreen"]
    Check("refused " k, HKP_SystemOwner(k) != "", HKP_SystemOwner(k))

for k in ["^#r", "^+#d", "^#F1", "^#F5", "^#i", "F13", "XButton1", "^+o", "^+#t", "^+#k", "^#F8", "^!F10"]
    Check("allowed " k, HKP_SystemOwner(k) = "", HKP_SystemOwner(k))

; Every key bound right now must pass the guard.
for row in HK_HelpRows() {
    why := HKP_SystemOwner(row["key"])
    if (why != "")
        Check("live key " row["key"] " (" row["what"] ")", false, why)
}
Check("help rows exist", HK_HelpRows().Length > 20, HK_HelpRows().Length " rows")

q := HelpQuery("ctrl win r")
Check("key search hits Ctrl+Win+R", HelpMatches(q, "Ctrl+Win+R", "Fix grammar"))
Check("key search skips Ctrl+Shift+Win+R", !HelpMatches(q, "Ctrl+Shift+Win+R", "x"))
Check("key search skips F2 with an r in the name", !HelpMatches(q, "F2", "grammar"))
Check("word search", HelpMatches(HelpQuery("grammar"), "Ctrl+Win+R", "Fix grammar — casual"))
Check("mods-only search", HelpMatches(HelpQuery("ctrl+win"), "Ctrl+Win+E", "x"))

Out(fails " failure(s)")
ExitApp(fails)
