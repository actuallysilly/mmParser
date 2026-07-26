#Requires AutoHotkey v2.0
; Easy/Advanced and the feature registry. Included here rather than in each
; script because HK_Bind below is the single gate that keeps a disabled feature's
; keys from registering, and everything that binds a key already includes this.
#Include "modes.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys.ahk — MMA's central hotkey authority (loader / binder).
; ───────────────────────────────────────────────────────────────────────────────
;  THIS FILE CONTAINS NO KEYS. Every hotkey lives in hotkeys.ini.
;
;  Here we only declare, per feature:
;      id     — "<section>.<key>", matching hotkeys.ini exactly
;      label  — what the Hotkeys GUI shows
;      when   — which window/state it may fire in ("" = anywhere)
;      owner  — which script binds it (for the GUI's conflict report)
;
;  A script attaches behaviour by id and never names a key:
;
;      HK_Bind("nav.unread", Unread)
;
;  To CHANGE a key: edit hotkeys.ini, or use the Hotkeys GUI. Never touch code.
;  To ADD a hotkey: HK_Def(...) below + a line in hotkeys.ini + one HK_Bind call.
; ═══════════════════════════════════════════════════════════════════════════════

; Anchored to THIS file, not A_ScriptDir — acc\*.ahk run from a subfolder and
; must still find the one true ini.
global HK_DIR := SubStr(A_LineFile, 1, InStr(A_LineFile, "\", , -1) - 1)
global HK_INI := HK_DIR "\hotkeys.ini"
global HK_INI_DEFAULT := HK_DIR "\hotkeys.default.ini"
global HK_CFG := HK_DIR "\mass_gui.cfg"      ; legacy home, read only for migration

global HK_MSG_RELOAD  := 0x8020              ; broadcast → every script re-reads the ini
global HK_MSG_SUSPEND := 0x8021              ; broadcast → hold fire while a key is captured
global HK_MSG_FIRE    := 0x8022              ; broadcast → whoever owns this action runs it
global HK_SCHEMA := 2

global HK_META  := Map()      ; id -> {id, label, when, owner}
global HK_ORDER := []         ; ids in declaration order (GUI display order)
global HK_SECTIONS := []      ; section ids in order
global HK_SECTION_LABEL := Map()

global HK_CTX := Map()        ; context name -> criterion Func (identity matters to HotIf)
global _HK_BOUND := Map()     ; id -> {fn, key}  (what THIS script actually registered)

; Anti-fumble gating around every hotkey (see _HK_Fire). Three layers:
;   • _HK_SENDING   — a send is mid-flight; ANY other hotkey pressed meanwhile is
;                     dropped, so a stray F2 can't splice itself into F1's send.
;   • _HK_LAST      — per-id: an immediate repeat of the SAME key is swallowed.
;   • _HK_LAST_SEND — cross-send: a *different* send within HK_WINDOW_MS of the last
;                     one is dropped, so an accidental F1-then-F2 can't both go out.
; "Send" = the model message keys (mass.* — follow-ups, PPV, branches); navigation
; and utility keys are exempt, so fast chat-hopping is never eaten. The window is
; tunable in hotkeys.ini [meta] DoubleFireWindowMs (0 disables all of it); see HK_Init.
global _HK_LAST := Map()        ; id -> last-fire tick (every hotkey)
global _HK_LAST_SEND := 0       ; last-fire tick across all send hotkeys
global _HK_SENDING := false     ; a send handler is currently running
global HK_WINDOW_MS := 200

; A sentinel no real key could equal, so "absent from the ini" is distinguishable
; from "present but blank" (= deliberately disabled).
global HK_UNSET := Chr(1) "«unset»"

HK_Log(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [" A_ScriptName "]  hotkeys: " msg "`n",
                   HK_DIR "\error_log.txt", "UTF-8")
}

; ── declaration helpers ───────────────────────────────────────────────────────

HK_Section(id, label) {
    HK_SECTIONS.Push(id)
    HK_SECTION_LABEL[id] := label
}

HK_Def(id, label, when := "", owner := "") {
    HK_META[id] := {id: id, label: label, when: when, owner: owner}
    HK_ORDER.Push(id)
}

; "mass.1.fu1" -> section "mass.1", key "fu1"  (split at the LAST dot)
HK_Split(id) {
    p := InStr(id, ".", , -1)
    return {section: SubStr(id, 1, p - 1), key: SubStr(id, p + 1)}
}

; Scripts register their own non-window contexts (see mass_gui.ahk's "mouseControl").
; Window contexts that any script may need are pre-registered below.
HK_Context(name, criterion) {
    HK_CTX[name] := criterion
}

HK_Context("chrome",  (*) => WinActive("ahk_exe chrome.exe"))
HK_Context("discord", (*) => WinActive("ahk_exe Discord.exe"))

; ── the declarations ──────────────────────────────────────────────────────────
;  Keep in step with hotkeys.ini. HK_Init() reports drift in either direction.

HK_Section("nav", "Navigation")
HK_Def("nav.unread",      "Mark unread / drag back",   , "1_mass.ahk")
HK_Def("nav.focusAuto",   "Focus textbox or top chat", , "1_mass.ahk")
HK_Def("nav.nextChat",    "Next chat down",            , "1_mass.ahk")
HK_Def("nav.unreadLeft",  "Mark unread (left)",        , "1_mass.ahk")
HK_Def("nav.focusTop",    "Focus top chat",            , "1_mass.ahk")
HK_Def("nav.clickUnread", "Click unread button",       , "1_mass.ahk")
HK_Def("nav.clickHome",   "Click home",                , "1_mass.ahk")
HK_Def("nav.clickPpv",    "Click PPV notification",    , "1_mass.ahk")

HK_Section("mass.1", "Mass — model 1")
HK_Def("mass.1.fu1",      "Follow-up 1",                  , "1_mass.ahk")
HK_Def("mass.1.fu2",      "Follow-up 2",                  , "1_mass.ahk")
HK_Def("mass.1.fu3",      "Follow-up 3",                  , "1_mass.ahk")
HK_Def("mass.1.altFu1",   "Follow-up 1 — pick alt",       , "1_mass.ahk")
HK_Def("mass.1.altFu2",   "Follow-up 2 — pick alt",       , "1_mass.ahk")
HK_Def("mass.1.altFu3",   "Follow-up 3 — pick alt",       , "1_mass.ahk")
HK_Def("mass.1.fu1short", "Follow-up 1 (alt key)",        , "1_mass.ahk")
HK_Def("mass.1.fu2short", "Follow-up 2 (alt key)",        , "1_mass.ahk")
HK_Def("mass.1.fu3short", "Follow-up 3 (alt key)",        , "1_mass.ahk")
HK_Def("mass.1.mFu1",     "Follow-up 1 (mouse)",          , "1_mass.ahk")
HK_Def("mass.1.mFu2",     "Follow-up 2 (mouse)",          , "1_mass.ahk")
HK_Def("mass.1.mFu3",     "Follow-up 3 (mouse)",          , "1_mass.ahk")
HK_Def("mass.1.smFu1",    "Follow-up 1 (Scimitar)",       , "1_mass.ahk")
HK_Def("mass.1.smFu2",    "Follow-up 2 (Scimitar)",       , "1_mass.ahk")
HK_Def("mass.1.smFu3",    "Follow-up 3 (Scimitar)",       , "1_mass.ahk")
HK_Def("mass.1.ppv",      "PPV base",                     , "1_mass.ahk")
HK_Def("mass.1.ppvFus",   "PPV follow-ups",               , "1_mass.ahk")
HK_Def("mass.1.b1Ppv",    "PPV follow-ups (alt key)",     , "1_mass.ahk")
HK_Def("mass.1.brPick",   "Branch — pick + send fu1",     , "1_mass.ahk")
HK_Def("mass.1.brFu2",    "Branch — follow-up 2",         , "1_mass.ahk")
HK_Def("mass.1.brFu3",    "Branch — follow-up 3",         , "1_mass.ahk")
HK_Def("mass.1.brPpv",    "Branch — PPV",                 , "1_mass.ahk")

HK_Section("mass.2", "Mass — model 2")
HK_Def("mass.2.fu1",   "Follow-up 1",       , "2_mass.ahk")
HK_Def("mass.2.fu2",   "Follow-up 2",       , "2_mass.ahk")
HK_Def("mass.2.fu3",   "Follow-up 3",       , "2_mass.ahk")
HK_Def("mass.2.altFu1",   "Follow-up 1 — pick alt",       , "2_mass.ahk")
HK_Def("mass.2.altFu2",   "Follow-up 2 — pick alt",       , "2_mass.ahk")
HK_Def("mass.2.altFu3",   "Follow-up 3 — pick alt",       , "2_mass.ahk")
HK_Def("mass.2.smFu1", "Follow-up 1 (Scimitar)", , "2_mass.ahk")
HK_Def("mass.2.smFu2", "Follow-up 2 (Scimitar)", , "2_mass.ahk")
HK_Def("mass.2.smFu3", "Follow-up 3 (Scimitar)", , "2_mass.ahk")
HK_Def("mass.2.ppv",    "PPV base",         , "2_mass.ahk")
HK_Def("mass.2.ppvFus", "PPV follow-ups",   , "2_mass.ahk")
HK_Def("mass.2.brPick", "Branch — pick + send fu1", , "2_mass.ahk")
HK_Def("mass.2.brFu2",  "Branch — follow-up 2",     , "2_mass.ahk")
HK_Def("mass.2.brFu3",  "Branch — follow-up 3",     , "2_mass.ahk")
HK_Def("mass.2.brPpv",  "Branch — PPV",             , "2_mass.ahk")

HK_Section("mass.3", "Mass — model 3")
HK_Def("mass.3.fu1",   "Follow-up 1",       , "3_mass.ahk")
HK_Def("mass.3.fu2",   "Follow-up 2",       , "3_mass.ahk")
HK_Def("mass.3.fu3",   "Follow-up 3",       , "3_mass.ahk")
HK_Def("mass.3.altFu1",   "Follow-up 1 — pick alt",       , "3_mass.ahk")
HK_Def("mass.3.altFu2",   "Follow-up 2 — pick alt",       , "3_mass.ahk")
HK_Def("mass.3.altFu3",   "Follow-up 3 — pick alt",       , "3_mass.ahk")
HK_Def("mass.3.smFu1", "Follow-up 1 (Scimitar)", , "3_mass.ahk")
HK_Def("mass.3.smFu2", "Follow-up 2 (Scimitar)", , "3_mass.ahk")
HK_Def("mass.3.smFu3", "Follow-up 3 (Scimitar)", , "3_mass.ahk")
HK_Def("mass.3.ppv",    "PPV base",         , "3_mass.ahk")
HK_Def("mass.3.ppvFus", "PPV follow-ups",   , "3_mass.ahk")
HK_Def("mass.3.brPick", "Branch — pick + send fu1", , "3_mass.ahk")
HK_Def("mass.3.brFu2",  "Branch — follow-up 2",     , "3_mass.ahk")
HK_Def("mass.3.brFu3",  "Branch — follow-up 3",     , "3_mass.ahk")
HK_Def("mass.3.brPpv",  "Branch — PPV",             , "3_mass.ahk")

HK_Section("chat", "Chat")
HK_Def("chat.captureEnter", "Send + remember last message", "chrome", "1_mass.ahk")

HK_Section("seq", "Sequences")
HK_Def("seq.openFarmolijer", "Open Farmolijer DM",            , "sequences.ahk")
HK_Def("seq.copyDiscordMsg", "Copy Discord message → parse", "discord", "sequences.ahk")
HK_Def("seq.selectTopPpv",   "Select top PPV",                , "sequences.ahk")
; @recorder-sequences@  <- recorder.ahk inserts new sequence declarations here.
;                          Keep this marker; new ones arrive unbound (blank key),
;                          ready to assign in the Hotkeys GUI.

HK_Section("util", "Utilities")
HK_Def("util.afkClick",        "AFK click cycle",            , "1_mass.ahk")
HK_Def("util.recoverMsg",      "Recover last typed message", , "1_mass.ahk")
HK_Def("util.clickSecondGrey", "Click 2nd grey icon",        , "1_mass.ahk")
HK_Def("util.debugGrey",       "Debug grey search",          , "1_mass.ahk")

HK_Section("gui", "GUI")
HK_Def("gui.addHotkeyGrab",  "Grab selection → Add Hotkey",  ,              "mass_gui.ahk")
HK_Def("gui.ocrGrab",        "OCR screen region → Add Hotkey", ,            "mass_gui.ahk")
HK_Def("gui.toggleDoubleMM", "Toggle double-MM",             "mouseControl", "mass_gui.ahk")
HK_Def("gui.toggleStats",    "Toggle stats overlay",         ,              "stats_overlay.ahk")
HK_Def("gui.actions",        "Actions menu (what can I do?)", ,             "actions_menu.ahk")
HK_Def("gui.quickActions",   "Quick actions (pinned buttons)", ,            "actions_menu.ahk")

HK_Section("recorder", "Recorder")
HK_Def("recorder.toggle", "Start / stop recording", , "recorder.ahk")

; Declared here so the GUI lists, edits and conflict-checks them like any other
; key — but BOUND BY PYTHON, not AHK: no script calls HK_Bind for these. The
; listener (automation\automation.py --listen) reads the same ini and
; polls, so it must be running for them to fire. It gates itself to the Infloww
; Messages window, which is why "when" is blank rather than a registered context.
HK_Section("automation", "Automation (automation.py)")
HK_Def("automation.hopKebabs", "Hop cursor over model kebabs (test)", , "automation.py")
HK_Def("automation.unsendLast", "Unsend last message (again = whole run)", , "automation.py")
HK_Def("automation.countSales", "Total your sales in Notifications > Purchases", , "automation.py")

HK_Section("general", "General")
HK_Def("general.openFast",    "Open-fast pitch",     , "general.ahk")
HK_Def("general.openAndRate", "Open-and-rate pitch", , "general.ahk")
HK_Def("general.antiCc",      "Type a random 199.00-200.00 amount", , "general.ahk")

HK_Section("aliw", "Account — ALIW")
HK_Def("aliw.intro",        "Intro greeting",      , "acc\ALIW.ahk")
HK_Def("aliw.loved",        "Unforgettable journey", , "acc\ALIW.ahk")
HK_Def("aliw.glimpse",      "Glimpse / trousers down", , "acc\ALIW.ahk")
HK_Def("aliw.whatLoved",    "What did you love",   , "acc\ALIW.ahk")
HK_Def("aliw.ascend",       "Ascend to highest heights", , "acc\ALIW.ahk")
HK_Def("aliw.openThat",     "You were supposed to open that", , "acc\ALIW.ahk")
HK_Def("aliw.infiniteLust", "Infinite lust",       , "acc\ALIW.ahk")

HK_Section("temp", "Account — TEMP")
HK_Def("temp.fantasy", "Wildest fantasy", , "acc\TEMP.ahk")

HK_Section("cap", "Capitalizer")
HK_Def("cap.enterCap",   "Enter + capitalize next",  , "capitalizer.ahk")
HK_Def("cap.enterPass1", "Shift+Enter (pass through)", , "capitalizer.ahk")
HK_Def("cap.enterPass2", "Ctrl+Enter (pass through)", , "capitalizer.ahk")

; ── resolving ─────────────────────────────────────────────────────────────────

; The ini is the authority. Absent id -> unbound (and logged); blank -> disabled.
HK_Key(id) {
    s := HK_Split(id)
    v := IniRead(HK_INI, s.section, s.key, HK_UNSET)
    if (v == HK_UNSET) {
        HK_Log("[" s.section "] " s.key " missing from hotkeys.ini — '" id "' left unbound")
        return ""
    }
    return Trim(v)
}

; AHK hands a hotkey's callback the hotkey's own name as an argument. Feature
; functions don't want it, so it gets absorbed here — once — which is what keeps
; every call site a plain `HK_Bind("nav.unread", Unread)`.
_HK_Wrap(id, fn) {
    return (*) => _HK_Fire(id, fn)
}

; The "send" hotkeys: the model message keys under the mass.* sections (follow-ups,
; PPV, branch, and the mouse/Scimitar variants). They paste a message and hit Enter,
; so two firing back-to-back is the F1+F2 mess. Nav/click/util keys are NOT sends —
; they stay exempt from the cross-send cooldown so fast chat-hopping is never eaten.
_HK_IsSend(id) {
    return SubStr(id, 1, 5) = "mass."
}

; The anti-fumble gate wrapped around every hotkey. Order matters:
;   1. If a send is mid-flight, drop this press outright. AHK hotkey threads are
;      interruptible, so without this an F2 pressed during F1's ~1s send would run
;      DoFu2 spliced into DoFu1 — exactly the mess we're killing. (A stray nav key
;      mid-send is dropped too, which is what you want: don't yank the chat away.)
;   2. Same-key debounce: swallow an immediate repeat of THIS id (key chatter, or a
;      press that queued during the last run). Measured from both start and end.
;   3. Cross-send cooldown: after any send, a *different* send within the window is
;      dropped, so an accidental F1-then-F2 can't both go out even once F1 finished.
; DoubleFireWindowMs = 0 in the ini switches all three off (HK_WINDOW_MS is 0 then).
_HK_Fire(id, fn) {
    global _HK_LAST, _HK_LAST_SEND, _HK_SENDING, HK_WINDOW_MS
    now := A_TickCount
    isSend := _HK_IsSend(id)

    if (HK_WINDOW_MS) {
        if (_HK_SENDING)
            return
        if (_HK_LAST.Has(id) && now - _HK_LAST[id] < HK_WINDOW_MS)
            return
        if (isSend && _HK_LAST_SEND && now - _HK_LAST_SEND < HK_WINDOW_MS)
            return
    }

    _HK_LAST[id] := now
    if (isSend) {
        _HK_LAST_SEND := now
        _HK_SENDING := true
    }
    try
        fn()
    finally {
        _HK_LAST[id] := A_TickCount
        if (isSend) {
            _HK_LAST_SEND := A_TickCount
            _HK_SENDING := false
        }
    }
}

HK_Bind(id, fn) {
    if !HK_META.Has(id) {
        HK_Log("HK_Bind('" id "') — id not declared in hotkeys.ahk; ignored")
        return
    }
    ; The one gate for every optional feature's keys. Easy mode, or a feature
    ; switched off in Advanced, means its hotkeys are never registered at all —
    ; not registered-then-ignored. Declared in modes.ahk (FEAT_HOTKEY_MAP), so a
    ; new feature needs no change in any of the scripts that bind keys.
    ; Silent: a key absent because the feature is off is not a fault.
    if !FEAT_HotkeyAllowed(id)
        return
    m := HK_META[id]
    if (m.when != "" && !HK_CTX.Has(m.when)) {
        ; Binding a context-limited key with no context would make it global —
        ; exactly the bug this registry exists to kill. Refuse instead.
        HK_Log("HK_Bind('" id "') — context '" m.when "' not registered; refusing to bind globally")
        return
    }
    _HK_BOUND[id] := {fn: fn, key: ""}
    _HK_Apply(id, HK_Key(id))
}

_HK_Apply(id, key) {
    m := HK_META[id]
    b := _HK_BOUND[id]
    if (m.when != "")
        HotIf(HK_CTX[m.when])
    if (b.key != "")
        try Hotkey(b.key, "Off")
    if (key != "") {
        try {
            Hotkey(key, _HK_Wrap(id, b.fn))
        } catch as e {
            HK_Log("'" key "' is not a valid key for " id " — " e.Message)
            key := ""
        }
    }
    HotIf()
    b.key := key
}

; Enable/disable an already-bound id without forgetting its key (used by gating).
HK_SetState(id, state) {
    if !_HK_BOUND.Has(id)
        return
    b := _HK_BOUND[id]
    if (b.key = "")
        return
    m := HK_META[id]
    if (m.when != "")
        HotIf(HK_CTX[m.when])
    try Hotkey(b.key, state)
    HotIf()
}

; The send keys a model slot shares with the other slots, so only the active
; model's copy stays registered. The old code gated F1-F3 only, which is why the
; Scimitar keys — F13-F15 in all three slots — stayed live in every model script
; and fired at once. PPV and the --Name branch keys are gated too: they are
; model-specific sends, so they must follow the active model exactly like the
; follow-ups. That is also what makes it safe for different models to reuse the
; same physical key (e.g. model 1's branch keys and model 3's follow-ups both on
; F6-F8) — only the active model's copy is ever live.
;
; Mouse keys are deliberately NOT gated: they're bound by 1_mass.ahk alone (so
; nothing to share), the Mouse-control setting switches them off wholesale, and
; re-enabling them here every 350ms would defeat it. Pressing one while another
; model is active is still correct — FuGate() re-checks inside the handler.
HK_ModelSendIds(n) {
    ids := []
    for k in ["fu1", "fu2", "fu3", "fu1short", "fu2short", "fu3short",
              "smFu1", "smFu2", "smFu3", "ppv", "ppvFus",
              "brPick", "brFu2", "brFu3", "brPpv"] {
        id := "mass." n "." k
        if HK_META.Has(id)
            ids.Push(id)
    }
    return ids
}

; Re-read the ini and re-register anything whose key changed. Every script that
; includes this file answers HK_MSG_RELOAD, so the GUI's Save applies live.
HK_Reload(*) {
    for id, b in _HK_BOUND {
        k := HK_Key(id)
        if (k != b.key)
            _HK_Apply(id, k)
    }
}
OnMessage(HK_MSG_RELOAD, HK_Reload)

; While the Hotkeys GUI is capturing a key, every other script holds fire —
; otherwise pressing F1 to assign it would also *send* model 1's follow-up.
_HK_OnSuspend(wParam, *) {
    Suspend(wParam ? true : false)
}
OnMessage(HK_MSG_SUSPEND, _HK_OnSuspend)

; Post a registry message to every MMA script that is running.
;
; Enumerated, not a hard-coded file list: the old list in hotkeys_gui.ahk had gone
; stale in both directions — it still named the deleted acc\britishizer.ahk and had
; never gained sequences.ahk, so rebinding the Discord import key did not apply
; live. An AHK script's main window is titled with its full path, so matching on
; this folder finds MMA's scripts and nobody else's.
;
; exceptHwnd lets a caller skip itself, which is what the Actions menu needs: it
; suspends the others while it is open, but must keep its own keys alive to close.
HK_Broadcast(msg, wparam := 0, exceptHwnd := 0) {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        if (hwnd = exceptHwnd)
            continue
        try {
            if (InStr(WinGetTitle(hwnd), HK_DIR "\") = 1)
                PostMessage(msg, wparam, 0, , "ahk_id " hwnd)
        }
    }
    DetectHiddenWindows prev
}

; Run an action on request from another script (the Actions menu).
;
; wParam is an INDEX into HK_ORDER, not a name, because PostMessage carries only
; numbers — and every script loads this same file, so the index means the same
; action in all of them.
;
; Only the script that actually bound the id answers; the rest ignore it. That is
; what lets the menu run 1_mass's follow-up while living inside mass_gui, and it
; works for actions with no key at all, since HK_Bind records the callback whether
; or not the ini gave it one.
_HK_OnFire(wParam, *) {
    if (wParam < 1 || wParam > HK_ORDER.Length)
        return
    id := HK_ORDER[wParam]
    if !_HK_BOUND.Has(id)
        return
    m := HK_META[id]
    ; Honour the context. Firing a Discord-only sequence while Infloww is focused
    ; would click into the wrong window — the menu is a shortcut, not an override.
    if (m.when != "" && HK_CTX.Has(m.when) && !HK_CTX[m.when]())
        return
    _HK_Fire(id, _HK_BOUND[id].fn)      ; same anti-fumble gate a real key press gets
}
OnMessage(HK_MSG_FIRE, _HK_OnFire)

; ── migration off the four legacy surfaces ────────────────────────────────────
;  mass_gui.cfg used to hold [Hotkeys] (M1_f1…), [NavHotkeys] and [Recorder].
;  Lift any customisations into hotkeys.ini once, then delete the old sections.
;  Idempotent + guarded, so whichever script loads first does it and the rest skip.

HK_Migrate() {
    if (IniRead(HK_INI, "meta", "SchemaVersion", "0") >= HK_SCHEMA)
        return
    if !FileExist(HK_CFG) {
        IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
        return
    }
    try FileCopy(HK_CFG, HK_CFG ".bak", true)

    ; [NavHotkeys] wins over [Hotkeys] where they disagree: it is what the mass
    ; scripts actually obeyed, so this preserves current behaviour rather than
    ; the GUI's stale idea of it.
    navMap := Map(
        "Unread", "nav.unread",  "FocusAuto", "nav.focusAuto",  "NextChat", "nav.nextChat",
        "UnreadLeft", "nav.unreadLeft",  "FocusTop", "nav.focusTop",
        "ClickUnread", "nav.clickUnread", "ClickHome", "nav.clickHome", "ClickPpv", "nav.clickPpv",
        "Fu1", "mass.1.fu1short", "Fu2", "mass.1.fu2short", "Fu3", "mass.1.fu3short",
        "PFu1", "mass.1.fu1", "PFu2", "mass.1.fu2", "PFu3", "mass.1.fu3",
        "MFu1", "mass.1.mFu1", "MFu2", "mass.1.mFu2", "MFu3", "mass.1.mFu3",
        "Ppv", "mass.1.ppv", "PpvFus", "mass.1.ppvFus", "B1Ppv", "mass.1.b1Ppv",
        "B2Fu2", "mass.1.b2Fu2", "B2Fu3", "mass.1.b2Fu3",
        "B2Ppv", "mass.1.b2Ppv", "B2PpvFus", "mass.1.b2PpvFus",
        "RecoverMsg", "util.recoverMsg", "ClickSecondGrey", "util.clickSecondGrey",
        "openFarmolijerSeq", "seq.openFarmolijer",
        "CopyDiscordMsg", "seq.copyDiscordMsg", "SelectTopPPVSeq", "seq.selectTopPpv")
    for old, id in navMap
        _HK_Lift(IniRead(HK_CFG, "NavHotkeys", old, HK_UNSET), id)

    ; [Hotkeys] M<n>_<slot> -> mass.<n>.<slot>
    slotMap := Map("f1", "fu1", "f2", "fu2", "f3", "fu3", "ppv", "ppv", "ppvfu", "ppvFus")
    Loop 3 {
        n := A_Index
        for old, slot in slotMap
            _HK_Lift(IniRead(HK_CFG, "Hotkeys", "M" n "_" old, HK_UNSET), "mass." n "." slot)
    }

    _HK_Lift(IniRead(HK_CFG, "Recorder", "ToggleHotkey", HK_UNSET), "recorder.toggle")

    for sec in ["Hotkeys", "NavHotkeys"]
        try IniDelete(HK_CFG, sec)
    try IniDelete(HK_CFG, "Recorder", "ToggleHotkey")

    IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
    HK_Log("migrated legacy hotkeys from mass_gui.cfg (backup: mass_gui.cfg.bak)")
}

; Only overwrite the shipped default when the old cfg actually had an entry —
; including a blank one, which meant "disabled" and must survive.
_HK_Lift(val, id) {
    if (val == HK_UNSET)
        return
    if !HK_META.Has(id)
        return
    s := HK_Split(id)
    IniWrite(Trim(val), HK_INI, s.section, s.key)
}

; ── startup ───────────────────────────────────────────────────────────────────

HK_Init() {
    global HK_WINDOW_MS   ; assigned below, so it must be declared to hit the global
    if !FileExist(HK_INI) {
        if FileExist(HK_INI_DEFAULT)
            FileCopy(HK_INI_DEFAULT, HK_INI)
        else {
            HK_Log("hotkeys.ini AND hotkeys.default.ini are both missing — no hotkeys will bind")
            return
        }
    }
    HK_Migrate()
    ; Seed the double-fire window into the ini once so it's discoverable/editable,
    ; then read it. Set to 0 to disable debouncing entirely.
    if (IniRead(HK_INI, "meta", "DoubleFireWindowMs", HK_UNSET) == HK_UNSET)
        try IniWrite(HK_WINDOW_MS, HK_INI, "meta", "DoubleFireWindowMs")
    HK_WINDOW_MS := Integer(IniRead(HK_INI, "meta", "DoubleFireWindowMs", HK_WINDOW_MS))
}

HK_Init()
