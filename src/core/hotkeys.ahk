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

; ─── Anchors ──────────────────────────────────────────────────────────────────
;  These used to be derived from THIS file's own folder, which was the repo root
;  and therefore also the root every script runs from. In the v2 tree it is
;  src\core\, and HK_DIR is not just a place to find the ini — HK_Broadcast uses
;  it to decide which running scripts are OURS, by testing their window title
;  (an AHK script's title IS its full path). Left as this file's folder, that
;  test would look for "…\MMA\src\core\" and match NOTHING: no script lives
;  there. Every rebind, suspend and Actions-menu fire would silently stop
;  crossing process boundaries, with no error anywhere.
;
;  So HK_DIR is the REPO ROOT, from the one anchor in paths.ahk.
#Include "paths.ahk"
global HK_DIR         := MMA_ROOT
global HK_INI         := MMA_HK_INI
global HK_INI_DEFAULT := MMA_HK_DEFAULT

; HK_MSG_RELOAD / _SUSPEND / _FIRE were declared here. They are three of the ten
; messages MMA's processes send each other, and the other seven were spread over
; runtime.ahk, engine.ahk and sequences.ahk — so they all live in messages.ahk
; now. Included here because every script that binds a key already includes this
; file, which makes this the one place that reaches every sender and receiver.
#Include "messages.ahk"
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

; Kept as the name every call site in this file already uses, but it is a
; forwarder now: core\log.ahk owns the file, the timestamp and the format, and
; routing through it means a hotkey problem appears in the SAME timeline as the
; send it should have triggered. Reading "key not in ini" in one file and "engine
; exited" in another, and having to interleave them by eye, is what made this
; area hard to debug.
;
; WARN, not INFO: everything that calls this is something that did not bind.
HK_Log(msg) {
    LOGW("hk", msg)
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

; Scripts register their own non-window contexts (see main_window.ahk's "mouseControl").
; Window contexts that any script may need are pre-registered below.
HK_Context(name, criterion) {
    HK_CTX[name] := criterion
}

HK_Context("chrome",  (*) => WinActive("ahk_exe chrome.exe"))
HK_Context("discord", (*) => WinActive("ahk_exe Discord.exe"))

; ── the declarations ──────────────────────────────────────────────────────────
;  Keep in step with hotkeys.ini. HK_Init() reports drift in either direction.

HK_Section("nav", "Navigation")
HK_Def("nav.unread",      "Mark unread / drag back",   , "engine.ahk")
HK_Def("nav.focusAuto",   "Focus textbox or top chat", , "engine.ahk")
HK_Def("nav.nextChat",    "Next chat down",            , "engine.ahk")
HK_Def("nav.unreadLeft",  "Mark unread (left)",        , "engine.ahk")
HK_Def("nav.focusTop",    "Focus top chat",            , "engine.ahk")
HK_Def("nav.clickUnread", "Click unread button",       , "engine.ahk")
HK_Def("nav.clickHome",   "Click home",                , "engine.ahk")
HK_Def("nav.clickPpv",    "Click PPV notification",    , "engine.ahk")

HK_Section("mass.1", "Mass — model 1")
HK_Def("mass.1.fu1",      "Follow-up 1",                  , "engine.ahk")
HK_Def("mass.1.fu2",      "Follow-up 2",                  , "engine.ahk")
HK_Def("mass.1.fu3",      "Follow-up 3",                  , "engine.ahk")
; Third key for fu1-3, kept so an existing ^F1 binding does not go dead. They no
; longer mean anything of their own: the plain follow-up key stages every alt AND
; every branch, so "pick alt" is what fu1 does.
HK_Def("mass.1.altFu1",   "Follow-up 1 (third key)",      , "engine.ahk")
HK_Def("mass.1.altFu2",   "Follow-up 2 (third key)",      , "engine.ahk")
HK_Def("mass.1.altFu3",   "Follow-up 3 (third key)",      , "engine.ahk")
; "second key", not "alt key": another binding for the plain follow-up. Labelled
; "(alt key)" they sat three rows under "Follow-up 1 — pick alt", where the same
; word meant two different things — and now that alts and branches are both on
; the plain key, all three of these rows are just extra keys for one action.
HK_Def("mass.1.fu1short", "Follow-up 1 (second key)",     , "engine.ahk")
HK_Def("mass.1.fu2short", "Follow-up 2 (second key)",     , "engine.ahk")
HK_Def("mass.1.fu3short", "Follow-up 3 (second key)",     , "engine.ahk")
; mass.1.mFu1-3 lived here — the mouse-button follow-ups, declared under MODEL 1
; and therefore hard-wired to model 1 forever. They are the same three physical
; buttons whichever model you are looking at, so binding them to one model meant
; pressing XButton1 in front of model 2 sent MODEL 1's follow-up to model 2's fan.
; A mouse button is a shared key by nature; shared keys belong in [mass.active].
HK_Def("mass.1.nextFu",   "Next follow-up (reads the chat)", , "engine.ahk")
HK_Def("mass.1.ppv",      "PPV base",                     , "engine.ahk")
HK_Def("mass.1.ppvFus",   "PPV follow-ups",               , "engine.ahk")
HK_Def("mass.1.b1Ppv",    "PPV follow-ups (second key)",  , "engine.ahk")
; mass.<n>.brPick / brFu2 / brFu3 / brPpv are GONE from all four sections.
;
; A branch is one more way to answer a follow-up, so its variants are staged by
; the follow-up key itself and TAB reaches them — four keys and a second picker
; window existed to ask a question the alt key was already asking.
;
; This also un-breaks model 3. brPick/brFu2/brFu3/brPpv defaulted to F6/F7/F8/!F8,
; which are model 3's fu3/fu1/ppv/ppvFus — and with one engine binding both, those
; four keys each had two meanings. Pressing F7 in front of model 3 could send
; model 1's branch. The ini keys are left in place and simply unclaimed now.

HK_Section("mass.2", "Mass — model 2")
HK_Def("mass.2.fu1",   "Follow-up 1",       , "engine.ahk")
HK_Def("mass.2.fu2",   "Follow-up 2",       , "engine.ahk")
HK_Def("mass.2.fu3",   "Follow-up 3",       , "engine.ahk")
HK_Def("mass.2.altFu1",   "Follow-up 1 (third key)",      , "engine.ahk")
HK_Def("mass.2.altFu2",   "Follow-up 2 (third key)",      , "engine.ahk")
HK_Def("mass.2.altFu3",   "Follow-up 3 (third key)",      , "engine.ahk")
HK_Def("mass.2.nextFu",   "Next follow-up (reads the chat)", , "engine.ahk")
HK_Def("mass.2.ppv",    "PPV base",         , "engine.ahk")
HK_Def("mass.2.ppvFus", "PPV follow-ups",   , "engine.ahk")

HK_Section("mass.3", "Mass — model 3")
HK_Def("mass.3.fu1",   "Follow-up 1",       , "engine.ahk")
HK_Def("mass.3.fu2",   "Follow-up 2",       , "engine.ahk")
HK_Def("mass.3.fu3",   "Follow-up 3",       , "engine.ahk")
HK_Def("mass.3.altFu1",   "Follow-up 1 (third key)",      , "engine.ahk")
HK_Def("mass.3.altFu2",   "Follow-up 2 (third key)",      , "engine.ahk")
HK_Def("mass.3.altFu3",   "Follow-up 3 (third key)",      , "engine.ahk")
HK_Def("mass.3.nextFu",   "Next follow-up (reads the chat)", , "engine.ahk")
HK_Def("mass.3.ppv",    "PPV base",         , "engine.ahk")
HK_Def("mass.3.ppvFus", "PPV follow-ups",   , "engine.ahk")

; --- Mass: the ACTIVE model (shared keys that follow the screen detector) -----
;  ONE key set, resolved at fire time to whichever model the detector says is on
;  screen. This is what F13-F15 always meant.
;
;  They used to be declared three times over — smFu1-3 in [mass.1], [mass.2] AND
;  [mass.3], all bound to the same physical keys — and then un-declared again
;  350ms at a time by StartFuGating, because three PROCESSES could not otherwise
;  share a key. That also forced hotkeys_window.ahk to exempt them from its own
;  conflict report, since three copies of one key look exactly like a clash.
;
;  One process, one declaration, no exemption, and the conflict report can now be
;  believed. With no detector answer these simply do nothing; the per-model keys
;  above are the manual answer. See ARCHITECTURE.md §5.1.
;  The HK_Section is not optional decoration: hotkeys_window.ahk reads
;  HK_SECTION_LABEL[section] for the first row of each group, and an AHK Map
;  THROWS on a missing key. These ids were declared without one, so the Hotkeys
;  window raised "key not found" the moment it reached the first mass.active row.
HK_Section("mass.active", "Mass — active model (shared keys)")
;  This set covers everything [mass.<n>] does, not just fu1-3. A shared key set
;  that can only send follow-ups is a set you cannot actually work from: the PPV,
;  the branches and the mass body would still need you to know which numbered key
;  belonged to the model in front, which is the exact problem this solves.
;
;  mFu1-3 / mPpv / mPpvFus are the MOUSE overload — a second key for the same
;  action, the same trick fu1short and b1Ppv play in [mass.1] (which is what
;  "second key" in their labels means; it is NOT the alt wordings). They are here and
;  not under a model because a mouse button cannot be per-model: there is one
;  XButton1 and it is under your thumb whichever tab is open.
HK_Def("mass.active.fu1",    "Follow-up 1 — active model",  , "engine.ahk")
HK_Def("mass.active.fu2",    "Follow-up 2 — active model",  , "engine.ahk")
HK_Def("mass.active.fu3",    "Follow-up 3 — active model",  , "engine.ahk")
HK_Def("mass.active.mFu1",   "Follow-up 1 — active model (mouse)", , "engine.ahk")
HK_Def("mass.active.mFu2",   "Follow-up 2 — active model (mouse)", , "engine.ahk")
HK_Def("mass.active.mFu3",   "Follow-up 3 — active model (mouse)", , "engine.ahk")
HK_Def("mass.active.altFu1", "Follow-up 1 — active model (second key)", , "engine.ahk")
HK_Def("mass.active.altFu2", "Follow-up 2 — active model (second key)", , "engine.ahk")
HK_Def("mass.active.altFu3", "Follow-up 3 — active model (second key)", , "engine.ahk")
HK_Def("mass.active.ppv",    "PPV base — active model",     , "engine.ahk")
HK_Def("mass.active.ppvFus", "PPV follow-ups — active model", , "engine.ahk")
HK_Def("mass.active.mPpv",    "PPV base — active model (mouse)", , "engine.ahk")
HK_Def("mass.active.mPpvFus", "PPV follow-ups — active model (mouse)", , "engine.ahk")
HK_Def("mass.active.mass",   "Paste the mass — active model", , "engine.ahk")
HK_Def("mass.active.nextFu", "Next follow-up — reads the chat, sends f1/f2/f3", , "engine.ahk")

; --- Which model the [mass.active] keys mean, when you say so yourself ---------
;  Manual mode (Settings ▸ "Decide which model by: I pick). The detector reads
;  pixels and OCRs a 13px pill; on a screen where that does not work it does not
;  fail loudly, it reports the wrong tab confidently — and then every shared key
;  sends the wrong model's messages to a real fan.
;
;  These keys are the way out: one press names the model, MMA remembers it, and
;  the shared set above follows THAT until you say otherwise. Pressing one also
;  switches Settings to manual mode, because a key labelled "switch to model 2"
;  that leaves the detector in charge would be lying about what it does.
HK_Section("mass.select", "Mass — pick the active model")
HK_Def("mass.select.next", "Next model (cycle)",  , "engine.ahk")
HK_Def("mass.select.m1",   "Active model = 1",    , "engine.ahk")
HK_Def("mass.select.m2",   "Active model = 2",    , "engine.ahk")
HK_Def("mass.select.m3",   "Active model = 3",    , "engine.ahk")

HK_Section("chat", "Chat")
HK_Def("chat.captureEnter", "Send + remember last message", "chrome", "engine.ahk")

HK_Section("seq", "Sequences")
HK_Def("seq.openFarmolijer", "Open Farmolijer DM",            , "sequences.ahk")
HK_Def("seq.copyDiscordMsg", "Copy Discord message → parse", "discord", "sequences.ahk")
HK_Def("seq.selectTopPpv",   "Select top PPV",                , "sequences.ahk")
; @recorder-sequences@  <- recorder.ahk inserts new sequence declarations here.
;                          Keep this marker; new ones arrive unbound (blank key),
;                          ready to assign in the Hotkeys GUI.

HK_Section("util", "Utilities")
HK_Def("util.afkClick",        "AFK click cycle",            , "engine.ahk")
HK_Def("util.recoverMsg",      "Recover last typed message", , "engine.ahk")
HK_Def("util.clickSecondGrey", "Click 2nd grey icon",        , "engine.ahk")
HK_Def("util.debugGrey",       "Debug grey search",          , "engine.ahk")

HK_Section("gui", "GUI")
HK_Def("gui.addHotkeyGrab",  "Grab selection → Add Hotkey",  ,              "main_window.ahk")
HK_Def("gui.ocrGrab",        "Add hotstring with OCR",       ,              "main_window.ahk")
HK_Def("gui.toggleDoubleMM", "Toggle double-MM",             "mouseControl", "main_window.ahk")
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

; No per-account sections. There was an [aliw] one holding seven keys, each firing
; a function in acc\ALIW.ahk that did nothing but send a canned message — a
; hotstring wearing a hotkey. Those are hotstrings now (..intro, ..loved, …), so
; there is nothing to declare. A message belongs in a message file as data; only
; keys that RUN SOMETHING (open a chat, type an amount, drive the mouse) belong
; here. [temp] went the same way: it declared temp.fantasy, which acc\TEMP.ahk
; never bound, so the Hotkeys window has been offering a key that did nothing.

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
; mass.select.* is excluded: it sends nothing, it only records which model the
; shared keys mean. Left in, a select would set the cross-send clock and swallow
; the follow-up you pressed it in order to send — the switch-then-send sequence is
; the ONE pair of presses that must never be debounced against each other.
_HK_IsSend(id) {
    return SubStr(id, 1, 5) = "mass." && SubStr(id, 1, 12) != "mass.select."
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
;
; ─── why every branch here is logged ─────────────────────────────────────────
;  All three guards are INVISIBLE and INTENTIONAL: you press a key, the key was
;  registered, the handler exists, and nothing happens. That is indistinguishable
;  from a broken hotkey from the outside, and it is the single most likely
;  explanation for "it silently failed to do something" on a machine where
;  somebody is working fast. So each drop says which guard ate it and by how many
;  milliseconds it missed — a number that also tells you whether
;  DoubleFireWindowMs is simply set too high for how this person types.
_HK_Fire(id, fn) {
    global _HK_LAST, _HK_LAST_SEND, _HK_SENDING, HK_WINDOW_MS
    now := A_TickCount
    isSend := _HK_IsSend(id)

    if (HK_WINDOW_MS) {
        if (_HK_SENDING) {
            LOG_Bail("hk.fire", id " DROPPED — another send is still in flight."
                              . " Anti-fumble guard 1 of 3.")
            return
        }
        if (_HK_LAST.Has(id) && now - _HK_LAST[id] < HK_WINDOW_MS) {
            LOG_Bail("hk.fire", id " DROPPED — same key repeated after only "
                              . (now - _HK_LAST[id]) "ms (window " HK_WINDOW_MS "ms)."
                              . " Anti-fumble guard 2 of 3.")
            return
        }
        if (isSend && _HK_LAST_SEND && now - _HK_LAST_SEND < HK_WINDOW_MS) {
            LOG_Bail("hk.fire", id " DROPPED — a different send went out "
                              . (now - _HK_LAST_SEND) "ms ago (window " HK_WINDOW_MS "ms)."
                              . " Anti-fumble guard 3 of 3.")
            return
        }
    }

    _HK_LAST[id] := now
    if (isSend) {
        _HK_LAST_SEND := now
        _HK_SENDING := true
    }
    LOGI("hk.fire", id " → running" (isSend ? "  (send)" : ""))
    try
        fn()
    catch as e {
        ; Rethrown, so nothing about error handling changes — but written down
        ; first. A handler that throws mid-send leaves the chat box in an unknown
        ; state, and knowing WHICH key was in flight is most of the diagnosis.
        LOGE("hk.fire", id " threw while running", LOG_Err(e))
        throw
    }
    finally {
        _HK_LAST[id] := A_TickCount
        if (isSend) {
            _HK_LAST_SEND := A_TickCount
            _HK_SENDING := false
        }
        LOGV("hk.fire", id " finished in " (A_TickCount - now) "ms")
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
    ;
    ; Still silent to the USER — a key absent because the feature is off is not a
    ; fault — but no longer silent to the log. "That key does nothing on his
    ; machine" and "that feature is off on his machine" are the same sentence, and
    ; this is the line that says so. It names the feature, so the answer is
    ; actionable rather than just a refusal.
    if !FEAT_HotkeyAllowed(id) {
        LOG_Bail("hk.bind", id " NOT REGISTERED — feature '" FEAT_ForHotkey(id)
                          . "' is off (or MMA is in Easy mode). Settings ▸ Features.")
        return
    }
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
            LOGI("hk.bind", id " ← " key (m.when != "" ? "   (only in: " m.when ")" : ""))
        } catch as e {
            HK_Log("'" key "' is not a valid key for " id " — " e.Message)
            key := ""
        }
    } else {
        ; Blank in the ini is "deliberately disabled" and absent was already
        ; reported by HK_Key. Either way the action has no key, which is worth a
        ; line: it is the difference between a broken feature and an unassigned
        ; one, and from the user's chair those look identical.
        LOG_Bail("hk.bind", id " has NO KEY — blank or missing in hotkeys.ini,"
                          . " so nothing can trigger it")
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

; HK_ModelSendIds used to live here: the list of ids that three model PROCESSES
; shared a physical key for, so StartFuGating could keep only the active model's
; copy registered and switch the rest Off every 350ms.
;
; One process shares nothing, so the list has no meaning and is gone — along with
; StartFuGating/UpdateFuGating in utils.ahk and the conflict-report exemption in
; hotkeys_window.ahk, which existed only to stop the GUI flagging three copies of
; one key as a clash. Shared keys are declared once now, as [mass.active] above.
;
; Worth knowing, because removing it uncovers this: [mass.1] brPick and [mass.3]
; fu1 are both on F6. That was a REAL conflict the whole time, hidden because
; both ids were in this list and therefore exempt. The report can be believed
; now, so it will start saying so.

; Re-read the ini and re-register anything whose key changed. Every script that
; includes this file answers HK_MSG_RELOAD, so the GUI's Save applies live.
HK_Reload(*) {
    changed := 0
    for id, b in _HK_BOUND {
        k := HK_Key(id)
        if (k != b.key) {
            LOGI("hk.reload", id ": " (b.key = "" ? "(none)" : b.key)
                           . " → " (k = "" ? "(none)" : k))
            _HK_Apply(id, k)
            changed++
        }
    }
    LOGI("hk.reload", "re-read hotkeys.ini — " changed " key(s) changed in this script")
}
OnMessage(HK_MSG_RELOAD, HK_Reload)

; While the Hotkeys GUI is capturing a key, every other script holds fire —
; otherwise pressing F1 to assign it would also *send* model 1's follow-up.
; Worth a line of its own: a script left SUSPENDED is the perfect silent failure —
; every key is registered, every feature is on, and not one of them fires. If the
; Hotkeys GUI or the Actions menu dies while holding the suspend, this is the only
; evidence of why the whole app went deaf.
_HK_OnSuspend(wParam, *) {
    LOGI("hk.suspend", wParam ? "SUSPENDED — every hotkey in this script is on hold"
                             : "resumed — hotkeys live again")
    Suspend(wParam ? true : false)
}
OnMessage(HK_MSG_SUSPEND, _HK_OnSuspend)

; Post a registry message to every MMA script that is running.
;
; Enumerated, not a hard-coded file list: the old list in hotkeys_window.ahk had gone
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
    sent := 0, seen := 0, names := ""
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        if (hwnd = exceptHwnd)
            continue
        seen++
        try {
            if (InStr(WinGetTitle(hwnd), HK_DIR "\") = 1) {
                PostMessage(msg, wparam, 0, , "ahk_id " hwnd)
                sent++
                try names .= (names = "" ? "" : ", ") _LOG_BaseName(WinGetTitle(hwnd))
            }
        }
    }
    DetectHiddenWindows prev
    ; A cross-process message that reaches NOBODY is the shape of half the bugs
    ; this file's header describes — a save that does not apply live, a rebind
    ; that does not take, an Actions-menu entry that fires nothing. It looks
    ; exactly like a message that was never sent, and until now it left no trace
    ; either way. The recipient count is the fastest way to tell those apart.
    if sent
        LOGI("hk.broadcast", "msg " Format("0x{:X}", msg) " wparam=" wparam
                          . " → " sent " of " seen " AutoHotkey window(s): " names)
    else
        LOGW("hk.broadcast", "msg " Format("0x{:X}", msg) " wparam=" wparam
                           . " reached NOBODY — " seen " AutoHotkey window(s) exist"
                           . " but none is titled under " HK_DIR "\ ."
                           . " Whatever this was meant to apply live has not applied.")
    return sent
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
    if (wParam < 1 || wParam > HK_ORDER.Length) {
        LOGW("hk.remote", "fire request for index " wParam " is out of range"
                        . " (1-" HK_ORDER.Length ") — sender and receiver disagree"
                        . " about HK_ORDER, i.e. they are running different code")
        return
    }
    id := HK_ORDER[wParam]
    ; Not an error: the message goes to EVERY MMA script and only the one that
    ; bound this id answers. Verbose so the firehose can prove the request
    ; arrived somewhere, without a line per script per press at normal level.
    if !_HK_BOUND.Has(id) {
        LOGV("hk.remote", id " not bound in this script — ignoring (expected)")
        return
    }
    m := HK_META[id]
    ; Honour the context. Firing a Discord-only sequence while Infloww is focused
    ; would click into the wrong window — the menu is a shortcut, not an override.
    if (m.when != "" && HK_CTX.Has(m.when) && !HK_CTX[m.when]()) {
        LOG_Bail("hk.remote", id " requested but its context '" m.when "' is not"
                            . " satisfied — wrong window is in front, so nothing ran")
        return
    }
    LOGI("hk.remote", id " fired by message from another MMA script")
    _HK_Fire(id, _HK_BOUND[id].fn)      ; same anti-fumble gate a real key press gets
}
OnMessage(HK_MSG_FIRE, _HK_OnFire)

; ── schema stamp ──────────────────────────────────────────────────────────────
;  v1 carried a migration that lifted hotkeys out of mass_gui.cfg's old
;  [Hotkeys] / [NavHotkeys] / [Recorder] sections into hotkeys.ini. 2.0.0 is a
;  clean break with no installed base (ARCHITECTURE.md §4.7), so there is nothing
;  left to lift and the whole lift-and-delete pass is gone — along with _HK_Lift
;  and HK_CFG, which existed only to serve it.
;
;  The stamp itself stays: hotkeys_window.ahk writes it on Save, and HK_SyncNew
;  reads it to decide whether a release has added keys the user's ini lacks.
HK_Migrate() {
    if (IniRead(HK_INI, "meta", "SchemaVersion", "0") >= HK_SCHEMA)
        return
    IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
}

; ── keeping a user's hotkeys.ini across updates ───────────────────────────────
;  hotkeys.ini belongs to the user; hotkeys.default.ini is what ships. The updater
;  skips the former (see updater.ahk's skipExact), so an update can no longer
;  overwrite anyone's keys.
;
;  That alone would freeze the file: a hotkey added in a later release would be
;  absent from an existing hotkeys.ini, and HK_Key treats absent as UNBOUND — the
;  action would simply never work, with nothing but a line in error_log to say so.
;
;  So new defaults are merged IN, additively:
;    • key missing from hotkeys.ini  -> copied from hotkeys.default.ini
;    • key already present           -> left alone, ALWAYS
;
;  A blank value is "deliberately disabled" and counts as present, so a key you
;  cleared on purpose does not come back to life on the next update.
HK_MergeDefaults() {
    if !FileExist(HK_INI_DEFAULT) || !FileExist(HK_INI)
        return 0

    added := 0
    for section in StrSplit(Trim(IniRead(HK_INI_DEFAULT)), "`n", "`r") {
        section := Trim(section)
        if (section = "")
            continue
        body := IniRead(HK_INI_DEFAULT, section, , "")
        for line in StrSplit(body, "`n", "`r") {
            eq := InStr(line, "=")
            if !eq
                continue
            key := Trim(SubStr(line, 1, eq - 1))
            if (key = "")
                continue
            if (IniRead(HK_INI, section, key, HK_UNSET) != HK_UNSET)
                continue                       ; the user's value wins, blank included
            IniWrite(Trim(SubStr(line, eq + 1)), HK_INI, section, key)
            added++
        }
    }
    if added
        HK_Log("merged " added " new default hotkey(s) into hotkeys.ini")
    return added
}

; ── startup ───────────────────────────────────────────────────────────────────

HK_Init() {
    global HK_WINDOW_MS   ; assigned below, so it must be declared to hit the global
    if !FileExist(HK_INI) {
        if FileExist(HK_INI_DEFAULT) {
            LOGW("hk.init", "hotkeys.ini did not exist — seeding it from"
                          . " hotkeys.default.ini. This is normal on a fresh install"
                          . " and alarming on an old one (did userdata\\ get wiped?)")
            ; Guarded: an unwritable userdata\ (read-only, permissions, antivirus)
            ; made this throw at LOAD, in a file every key-binding script includes.
            ; One failed copy therefore stopped the whole app from starting, rather
            ; than starting it with no hotkeys — which is recoverable and says so.
            LOG_Try("hk.init", "seed hotkeys.ini from the default",
                    () => FileCopy(HK_INI_DEFAULT, HK_INI), &seeded)
            if !seeded {
                LOGE("hk.init", "could not create hotkeys.ini — NO HOTKEY WILL BIND"
                              . " in this script",
                              "is " MMA_USERDATA " writable?")
                return
            }
        } else {
            ; The worst startup state there is: MMA loads, the GUI opens, and not
            ; one key in the app works. FAIL, so it raises a dialog when popups
            ; are on — this is precisely the case where a user is about to report
            ; "nothing happens when I press anything".
            LOGE("hk.init", "hotkeys.ini AND hotkeys.default.ini are both missing —"
                          . " NO HOTKEY IN MMA WILL BIND",
                          "looked for " HK_INI " and " HK_INI_DEFAULT)
            HK_Log("hotkeys.ini AND hotkeys.default.ini are both missing — no hotkeys will bind")
            return
        }
    }
    HK_Migrate()
    ; After migrating, before anything reads a key: pick up hotkeys added by this
    ; release without disturbing any the user has already set.
    HK_MergeDefaults()
    ; Seed the double-fire window into the ini once so it's discoverable/editable,
    ; then read it. Set to 0 to disable debouncing entirely.
    if (IniRead(HK_INI, "meta", "DoubleFireWindowMs", HK_UNSET) == HK_UNSET)
        try IniWrite(HK_WINDOW_MS, HK_INI, "meta", "DoubleFireWindowMs")
    ; LOG_IniInt, not Integer(IniRead(...)). This line runs at LOAD in every script
    ; that binds a key — the GUI, the engine, sequences, general.ahk, every account
    ; file. `DoubleFireWindowMs=none` typed into hotkeys.ini by hand therefore did
    ; not disable debouncing, it stopped ALL OF MMA from starting, from a file
    ; whose whole purpose is to be hand-editable.
    HK_WINDOW_MS := LOG_IniInt(HK_INI, "meta", "DoubleFireWindowMs", HK_WINDOW_MS, "hk.init")
    LOG_Kv("hk.init", Map("ini", HK_INI,
                          "declared", HK_ORDER.Length,
                          "sections", HK_SECTIONS.Length,
                          "doubleFireWindowMs", HK_WINDOW_MS,
                          "schema", IniRead(HK_INI, "meta", "SchemaVersion", "0")))
}

; What this script ACTUALLY ended up owning, once it has finished binding.
;
; Every other line in this file reports one key at a time, which answers "did this
; key bind?" but never "is the engine holding the keys at all?". After a bad
; startup the per-key lines can all look reasonable and the total still be zero —
; that is what a feature-gated Easy mode looks like from in here. Call it at the
; bottom of a script's binding block.
HK_Summary(what := "") {
    keyed := 0, dark := 0, list := ""
    for id, b in _HK_BOUND {
        if (b.key != "") {
            keyed++
            list .= (list = "" ? "" : "  ") id "=" b.key
        } else
            dark++
    }
    LOGI("hk.summary", (what != "" ? what ": " : "")
                    . keyed " key(s) live, " dark " bound but unassigned")
    LOGV("hk.summary", list)
    if (keyed = 0)
        LOGW("hk.summary", (what != "" ? what ": " : "")
                         . "this script registered NO working hotkeys at all —"
                         . " check Easy mode, the Features tab, and hotkeys.ini")
    return keyed
}

HK_Init()
