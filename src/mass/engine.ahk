#Requires AutoHotkey v2.0
#SingleInstance Force
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/engine.ahk — the mass process. ONE of them, for all models.
; ───────────────────────────────────────────────────────────────────────────────
;  Replaces 1_mass.ahk, 2_mass.ahk and 3_mass.ahk (ARCHITECTURE.md §5).
;
;  Those were three processes holding three copies of the same behaviour around
;  three blocks of data. The data moved to userdata\masses.json (mass/store.ahk)
;  and the behaviour was already shared (mass/runtime.ahk), which left the three
;  processes doing nothing but fighting each other over hotkeys: all three bound
;  F13-F15, so five mechanisms existed purely to decide who answered. None of them
;  survive here.
;
;  What this file does, in order:
;    1. loads the mass library,
;    2. binds each model's explicit keys      — [mass.1] [mass.2] [mass.3],
;    3. binds the one shared, detector-following set — [mass.active],
;    4. binds the navigation/chat keys that used to be stranded in 1_mass.ahk,
;    5. reloads the library when the GUI says it changed.
;
;  It does NOT include sequences.ahk. 1_mass.ahk did, while sequences.ahk was ALSO
;  its own entry in StartupScripts — so seq.openFarmolijer, seq.copyDiscordMsg and
;  seq.selectTopPpv were each registered in two processes and fired twice per
;  press. It runs standalone; that is enough.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "runtime.ahk"
#Include "../chat/nav.ahk"
#Include "../sequences/composer.ahk"

; ── the library ───────────────────────────────────────────────────────────────
; One process, one copy, read once at startup. MASS_DOC is what CurMass() reads
; through; nothing else in the codebase touches masses.json directly.
global MASS_DOC := MASS_Load()

; The GUI posts this after writing masses.json, so a save takes effect on the very
; next keypress with no reload and no restart. This is the whole reason the GUI
; and the engine can be separate processes at all: they share a file, not memory.
;
; 0x8006 continues the 0x8001-0x8005 settings series in runtime.ahk — same
; contract, same file to check when adding another.
global MMA_MSG_MASSES_CHANGED := 0x8006
ReloadMasses(*) {
    global MASS_DOC := MASS_Load()
}
OnMessage(MMA_MSG_MASSES_CHANGED, ReloadMasses)

; ── keys ──────────────────────────────────────────────────────────────────────
; Per-model first, then the shared set. Both come from hotkeys.ini and neither
; names a key here; see hotkeys.ahk.
Loop MASS_MODELS
    MassBindModel(A_Index)
MassBindActive()

NavBind()
