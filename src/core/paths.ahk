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
global MMA_MODELS    := MMA_CONTENT "\models"      ; the mass data scripts
global MMA_ACC_DIR   := MMA_CONTENT "\accounts"    ; per-account hotstring files
global MMA_USERDATA  := MMA_ROOT "\userdata"       ; settings, messages, logs
global MMA_ASSETS    := MMA_ROOT "\assets"

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
global MMA_ERRLOG      := MMA_USERDATA "\error_log.txt"
global MMA_VERSION     := MMA_ROOT "\version.txt"

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

; The model data script for model n.  Was  SCRIPT_DIR "\" n "_mass.ahk"  written
; out by hand in five places in the GUI, plus four hard-coded three-element
; arrays; every one of them silently pointed at the wrong folder after the move.
MMA_ModelFile(n) {
    return MMA_MODELS "\" n "_mass.ahk"
}

; Every model file, in order. Use this instead of writing the list again.
MMA_ModelFiles() {
    out := []
    loop 3
        out.Push(MMA_ModelFile(A_Index))
    return out
}

; The BARE NAMES, for the GUI's fname-taking helpers (ApplyFile, LoadFile, …) and
; for anything the cfg round-trips. Replaces four copies of the same three-element
; array literal, which is three chances to update two of them.
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
MMA_ScriptPath(name) {
    if InStr(name, "\") || InStr(name, "/")     ; already a path — leave it alone
        return name
    for dir in [MMA_MODELS, MMA_ACC_DIR, MMA_CONTENT,
                MMA_SRC "\sequences", MMA_SRC "\screen", MMA_SRC "\ui", MMA_SRC] {
        p := dir "\" name
        if FileExist(p)
            return p
    }
    return MMA_CONTENT "\" name        ; best guess, so callers still get a path
}
