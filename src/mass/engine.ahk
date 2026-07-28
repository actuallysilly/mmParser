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
;    3. binds the one shared set that follows the active model — [mass.active],
;    4. binds the keys that SAY which model that is — [mass.select],
;    5. binds the navigation/chat keys that used to be stranded in 1_mass.ahk,
;    6. reloads the library when the GUI says it changed.
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
; MASS_DOC itself is declared and first loaded in runtime.ahk — the file that
; READS it, so that including runtime.ahk is enough on its own. What belongs here
; is the reload, because that is a contract with the GUI process.

; The GUI posts this after writing masses.json, so a save takes effect on the very
; next keypress with no reload and no restart. This is the whole reason the GUI
; and the engine can be separate processes at all: they share a file, not memory.
;
; MMA_MSG_MASSES_CHANGED is declared in core/messages.ahk, with the rest of the
; contract. It was `:= 0x8006` here, under a comment pointing at runtime.ahk for
; the neighbouring numbers — which is exactly the split that file now closes.
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
MassBindSelect()

NavBind()
