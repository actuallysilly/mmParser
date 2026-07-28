#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  paths.ahk — every path in MMA, resolved from ONE anchor.
; ───────────────────────────────────────────────────────────────────────────────
;  A_ScriptDir is the folder of the MAIN script — the one you double-clicked —
;  not the folder of the file the code is written in. While every entry point
;  lived in the repo root those were the same folder, so 37 uses of
;  A_ScriptDir "\something" happened to work by coincidence.
;
;  They fail SILENTLY the moment a script runs from a subfolder: IniRead with a
;  default just returns the default, so settings quietly revert and nothing says
;  why. In the v2 tree EVERY entry point is in a subfolder, so that coincidence
;  is gone for good and this file is the only thing standing in for it.
;
;  A_LineFile is the file THIS line is written in, so it is immune to which
;  script is the main one.
;
;  TO MOVE THIS FILE: change the MMA_ROOT line below to climb the right number of
;  levels. Nothing else in the repo needs to know where anything lives.
; ═══════════════════════════════════════════════════════════════════════════════

; Strip the last "\segment" off a path. Defined before first use: AHK parses every
; function at load time, so calling this from the top-level initialisers below is
; safe regardless of which script #Included us.
MMA_ParentDir(p) {
    cut := InStr(p, "\", , -1)
    return cut ? SubStr(p, 1, cut - 1) : p
}

; This file is  <root>\src\core\paths.ahk  → three levels up is <root>.
global MMA_ROOT := MMA_ParentDir(MMA_ParentDir(MMA_ParentDir(A_LineFile)))

; ─── Folders ──────────────────────────────────────────────────────────────────
global MMA_SRC       := MMA_ROOT "\src"
global MMA_CONTENT   := MMA_ROOT "\content"        ; hand-written AHK message files
global MMA_ACC_DIR   := MMA_CONTENT "\accounts"    ; per-account hotstring files
global MMA_USERDATA  := MMA_ROOT "\userdata"       ; settings and messages
global MMA_ASSETS    := MMA_ROOT "\assets"
; Diagnostics: crash traces and whatever the probe tools dump. Its own folder
; because these are THROWAWAY — you read one, you fix the thing, you delete it —
; and mixing them into userdata\ put them next to masses.json and hotkeys.ini,
; the two files you must never delete by mistake.
global MMA_DEBUGLOGS := MMA_ROOT "\debuglogs"

; ─── Files the user owns ──────────────────────────────────────────────────────
; All of these live in userdata\, which is gitignored except for the .default
; that seeds hotkeys.ini. See ARCHITECTURE.md §1.3.
global MMA_CFG         := MMA_USERDATA "\mass_gui.cfg"
global MMA_HK_INI      := MMA_USERDATA "\hotkeys.ini"
global MMA_HK_DEFAULT  := MMA_USERDATA "\hotkeys.default.ini"
global MMA_OVERLOADS   := MMA_USERDATA "\hotstring_overloads.ini"
global MMA_MASSES      := MMA_USERDATA "\masses.json"
global MMA_ARCHIVE     := MMA_USERDATA "\mass_archive.txt"
global MMA_DETECTOR    := MMA_USERDATA "\detector_status.ini"
global MMA_VERSION     := MMA_ROOT "\version.txt"

; ─── Diagnostics ──────────────────────────────────────────────────────────────
; Created HERE, at load, rather than by each writer.
;
; Every one of these is written with FileAppend, which throws if the folder is
; missing — and each writer is inside a `try` precisely because a logger must not
; be able to crash the thing it is logging for. So a missing folder would not
; raise anything: the crash log would silently stop recording crashes, which is
; the one failure you cannot debug from the log. One idempotent DirCreate, in the
; file every script already includes, removes the possibility.
try DirCreate(MMA_DEBUGLOGS)
global MMA_ERRLOG       := MMA_DEBUGLOGS "\error_log.txt"
global MMA_PROBE_DETECT := MMA_DEBUGLOGS "\detector_probe.txt"
global MMA_PROBE_NEXTFU := MMA_DEBUGLOGS "\nextfu_probe.txt"

; ─── Source files referenced as PATHS rather than #Included ───────────────────
;  Three things do this and all three are easy to miss when moving files:
;    • recorder.ahk WRITES new code into sequences.ahk and hotkeys.ahk
;    • main_window.ahk READS utils.ahk as text to scrape its waitTime value
;    • sequences.ahk builds a WinTitle from main_window.ahk's path, because an
;      AHK script's window title IS its full path
global MMA_SRC_COORDS    := MMA_SRC "\core\coords.ahk"
global MMA_SRC_UTILS     := MMA_SRC "\core\utils.ahk"
global MMA_SRC_HOTKEYS   := MMA_SRC "\core\hotkeys.ahk"
global MMA_SRC_SEQUENCES := MMA_SRC "\sequences\sequences.ahk"
global MMA_SRC_GUI       := MMA_SRC "\ui\main_window.ahk"

; ─── Resolvers ────────────────────────────────────────────────────────────────

; The model IDENTIFIERS the GUI's tabs pass around — "2_mass.ahk" and friends.
;
; These are labels, not paths: no such file exists any more. ApplyFile/LoadFile
; call ModelNoOf() on them to get a slot number and read the mass out of
; userdata\masses.json. The old MMA_ModelFile/MMA_ModelFiles pointed into
; content\models\, which is deleted, and are gone with it.
MMA_ModelNames() {
    out := []
    loop 3
        out.Push(A_Index "_mass.ahk")
    return out
}

; Turn a BARE FILENAME from mass_gui.cfg into a full path.
;
; The cfg stores names, not paths — StartupScripts=1_mass.ahk,ALIW.ahk,general.ahk
; and friends. That was unambiguous while every script sat in one folder; now the
; three names in that example live in three different folders. Resolving here
; means the cfg format does not change, so nobody's settings break.
;
; Order matters only if two folders hold the same filename, which nothing does.
; The folder list must cover every folder a StartupScripts entry can name. It is
; the one place that knows, and a folder missing from it fails the worst possible
; way: ResolveScriptPath returns "", LaunchStartupScripts skips the entry, and the
; script simply never starts — no error, no dialog, nothing in the log. That is
; how "engine.ahk" silently did not run after it moved to src\mass\.
MMA_ScriptPath(name) {
    global MMA_ACC_DIR, MMA_CONTENT, MMA_SRC
    if InStr(name, "\") || InStr(name, "/")     ; already a path — leave it alone
        return name
    for dir in [MMA_ACC_DIR, MMA_CONTENT,
                MMA_SRC "\mass", MMA_SRC "\chat", MMA_SRC "\sequences",
                MMA_SRC "\screen", MMA_SRC "\ui", MMA_SRC] {
        p := dir "\" name
        if FileExist(p)
            return p
    }
    return MMA_CONTENT "\" name        ; best guess, so callers still get a path
}
