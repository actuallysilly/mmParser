#Requires AutoHotkey v2.0
#SingleInstance Force
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/engine.ahk — the mass process. ONE of them, for all models.
; ───────────────────────────────────────────────────────────────────────────────
;  Replaces 1_mass.ahk, 2_mass.ahk and 3_mass.ahk (docs/decisions.md §5).
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
; Vertical divider bars on your own tab strip. Included here rather than by
; runtime.ahk because nothing in the mass runtime calls into it — it is a thing this
; process hosts, not a thing a mass does.
#Include "../screen/tab_marks.ahk"
; The mouse half of the anti-fumble guards. Same reasoning as tab_marks above: the
; mass runtime never calls into it, this process hosts it. See HK_OnSend below.
#Include "../screen/click_wall.ahk"

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
    LOGI("mass.reload", "the GUI saved masses.json — library reloaded, the next"
                      . " keypress uses the new text")
}
OnMessage(MMA_MSG_MASSES_CHANGED, ReloadMasses)

; ── keys ──────────────────────────────────────────────────────────────────────
; Per-model first, then the shared set. Both come from hotkeys.ini and neither
; names a key here; see hotkeys.ahk.
LOGI("engine.boot", "binding keys for " MASS_MODELS " model(s)")
Loop MASS_MODELS
    MassBindModel(A_Index)
MassBindActive()
MassBindSelect()

NavBind()

; ── the lock badge ────────────────────────────────────────────────────────────
;  Lock mode aims every shared key at one model and takes the "which model?"
;  window away (core/active_model.ahk). The badge is what stops that being a
;  silent re-aim, so it is not optional decoration — see ui/lock_badge.ahk.
;
;  Once now, so a lock survives an engine restart mid-shift with the badge coming
;  straight back up. Then on a timer, because THIS process is not the only writer:
;  the GUI's Lock button is in main_window.ahk, another process entirely, and a
;  poll costs one ini read where a message contract would cost a number, a handler
;  and a way to be out of date.
LOCKBADGE_Sync()
SetTimer(LOCKBADGE_Sync, 700)

; ── the Fansly rail readout ───────────────────────────────────────────────────
;  Says which model the rail detector is seeing, beside the rail, while you are on
;  it (ui/fansly_badge.ahk). Off unless [Debug] FanslyRail is ticked in
;  Settings ▸ Debug, and the tick below is one cached ini read while it is off.
;
;  Same 700ms as the badge above, and deliberately the same timer rate rather than
;  something faster: it has to keep up with you clicking a card, not with you
;  typing, and every tick that finds nothing changed is a tick that did no work.
;
;  In THIS process because this is the one that resolves the model — the badge
;  shows FanslyStatus(), the same cached call every [mass.active] key goes through,
;  so it cannot drift from what the keys would actually do. A separate overlay
;  process would be a second opinion, which is the one thing a readout must not be.
FANBADGE_Sync()
SetTimer(FANBADGE_Sync, 700)
HK_Bind("gui.toggleRailBadge", FANBADGE_Toggle)

; ── the tab bars ──────────────────────────────────────────────────────────────
;  Divider bars you stick on your own tab strip — decoration, and deliberately
;  nothing more (screen/tab_marks.ahk). Here for the same two reasons as the badge:
;  this process is the one that is always running, and it already owns the keys.
;
;  MARKS_Start binds its three keys through HK_Bind, so the `tabMarks` feature being
;  off means they never register — no check needed here.
MARKS_Start()

; ── the click wall ────────────────────────────────────────────────────────────
;  Holds a click on the conversation list while a follow-up is still going out,
;  and plays it back when the send lands (screen/click_wall.ahk).
;
;  Installed HERE rather than inside hotkeys.ahk, which publishes the two edges but
;  must not know what listens on them: that file is included by every process MMA
;  runs — the GUI, the account scripts, each background service — and naming CW_Arm
;  in it would be a load-time "nonexistent function" in all of them. This process is
;  the one that owns the message keys, so it is the one that owns the guard around
;  them, for the same reason it hosts the lock badge and the tab bars.
;
;  Ungated by design: CW_Arm checks FEAT("clickWall") itself on every send, so the
;  Features checkbox takes effect immediately rather than at the next engine start.
HK_OnSend(CW_Arm, CW_Release)

; The line that answers "are the mass hotkeys alive at all on this machine?".
;
; Every bind above logs itself, but a hundred individual lines do not answer the
; question a user is actually asking when they say nothing happens. If this says
; 0, the cause is upstream of anything in this file — Easy mode, the Features tab,
; or a hotkeys.ini that never arrived — and HK_Summary says which.
HK_Summary("mass engine")
