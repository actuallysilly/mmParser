; ═══════════════════════════════════════════════════════════════════════════════
;  usage.ahk — the usage log: one line per thing you actually used.
; ───────────────────────────────────────────────────────────────────────────────
;  userdata\usage\<yyyy-MM>.tsv, tab-separated, appended, never rewritten:
;
;    2026-11-28 16:40:12   engine.ahk   key        mass.active.fu1
;    2026-11-28 16:41:03   general.ahk  hotstring  ..povmppv
;    2026-11-28 16:42:30   general.ahk  typed      tool:lore
;    2026-11-28 16:42:30   main_window  tool       lore
;
;  kinds: key (a hotkey or an Actions-menu run, after the anti-fumble guards),
;  hotstring, typed (a shortcut trigger), tool (a Python tool opened).
;
;  Why its own file and not mma.log: mma.log rotates every few hours, so it can
;  never answer "what did I use in the last two weeks?" (2026-11-28). This file
;  is tiny — a line per action, a few hundred KB a month.
;  Read it with:  python tools\usage_report.py [--days 14]
;
;  Included from paths.ahk, so every process has it. Never throws.
; ═══════════════════════════════════════════════════════════════════════════════

USAGE_Note(kind, id) {
    try {
        dir := MMA_USERDATA "\usage"
        if !DirExist(dir)
            DirCreate(dir)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "`t" A_ScriptName "`t" kind "`t" id "`n"
                 , dir "\" FormatTime(, "yyyy-MM") ".tsv", "UTF-8-RAW")
    }
}
