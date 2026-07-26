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
;  why. That is the single most dangerous thing about moving files here.
;
;  A_LineFile is the file THIS line is written in, so it is immune to which
;  script is the main one. hotkeys.ahk and hotstring_index.ahk each solved this
;  locally already; this is that same fix, once, for everything.
;
;  TO MOVE THIS FILE: change MMA_ROOT below to climb the right number of levels.
;  Nothing else in the repo needs to know where anything lives.
; ═══════════════════════════════════════════════════════════════════════════════

; Folder containing THIS file. Same idiom as hotkeys.ahk's HK_DIR.
global MMA_ROOT := SubStr(A_LineFile, 1, InStr(A_LineFile, "\", , -1) - 1)

; ─── Folders ──────────────────────────────────────────────────────────────────
global MMA_ACC_DIR := MMA_ROOT "\acc"
global MMA_ASSETS  := MMA_ROOT "\assets"

; ─── Files the user owns ──────────────────────────────────────────────────────
global MMA_CFG      := MMA_ROOT "\mass_gui.cfg"
global MMA_HK_INI   := MMA_ROOT "\hotkeys.ini"
global MMA_ARCHIVE  := MMA_ROOT "\mass_archive.txt"
global MMA_DETECTOR := MMA_ROOT "\detector_status.ini"
global MMA_ERRLOG   := MMA_ROOT "\error_log.txt"
global MMA_VERSION  := MMA_ROOT "\version.txt"

; ─── Source files referenced as PATHS rather than #Included ───────────────────
;  Three things do this and all three are easy to miss when moving files:
;    • recorder.ahk WRITES new code into sequences.ahk and hotkeys.ahk
;    • mass_gui.ahk READS utils.ahk as text to scrape its waitTime value
;    • sequences.ahk builds a WinTitle from mass_gui.ahk's path, because an AHK
;      script's window title IS its full path
global MMA_SRC_COORDS    := MMA_ROOT "\coords.ahk"
global MMA_SRC_UTILS     := MMA_ROOT "\utils.ahk"
global MMA_SRC_SEQUENCES := MMA_ROOT "\sequences.ahk"
global MMA_SRC_HOTKEYS   := MMA_ROOT "\hotkeys.ahk"
global MMA_SRC_GUI       := MMA_ROOT "\mass_gui.ahk"
