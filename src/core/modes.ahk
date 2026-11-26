#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  modes.ahk — Easy vs Advanced, and the one registry of every optional feature.
; ───────────────────────────────────────────────────────────────────────────────
;  EASY mode is MMA as it was at v1.4.0 (da93bf5, 2026-05-25), the last version
;  before britishizer and the feature run that followed: paste, Parse, Clear,
;  Export, per-file load/save/massNo, the model tabs, the script toggles, and a
;  Settings window with model count, Add Hotkey, How to Use, New Script, Wipe
;  Temp and Check Update. Nothing else.
;
;  ADVANCED is everything since.
;
;  Easy does not merely HIDE the extras — it switches them off. Advanced hotkeys
;  never register, the background children never start, and the advanced
;  behaviours are bypassed in code. That distinction is the whole point: a hidden
;  feature still interferes. The model detector silently gating a model's send
;  keys off is exactly the class of surprise Easy mode exists to remove.
;
;  ── Declaring a feature ──────────────────────────────────────────────────────
;  Every optional feature is declared ONCE here:
;
;      FEAT_Def(id, cfgKey, label, default, section)
;
;  id       — short name used in code:            if FEAT("altFollowups")
;  cfgKey   — its key in mass_gui.cfg [Settings]. Existing keys are reused as-is
;             so nobody's settings are lost; only genuinely new toggles add keys.
;  default  — value when the key is absent
;  section  — grouping for the Settings window
;
;  Everything declared here is ADVANCED by definition: Easy is the v1.4.0 set,
;  and anything that needed a toggle came later. So FEAT() is
;
;      the feature's own checkbox   AND   we are in Advanced mode
;
;  which means a user can switch a single feature off inside Advanced, and Easy
;  switches the lot off without touching their choices — flip back to Advanced
;  and every checkbox is exactly where they left it.
;
;  ── Adding a feature later ───────────────────────────────────────────────────
;  One FEAT_Def line here, then guard its entry points with FEAT("id"). If it has
;  hotkeys, add them to FEAT_HOTKEY_MAP below and HK_Bind refuses to register
;  them while the feature is off — no per-script changes needed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "paths.ahk"
global MODE_CFG   := MMA_CFG
global FEAT_META  := Map()      ; id -> {id, cfgKey, label, default, section}
global FEAT_ORDER := []         ; declaration order, for the Settings window
; Section names, in the order the Features tab shows them. Fixed here rather than
; first-seen, so where a FEAT_Def line sits in this file does not decide the
; layout. A section not listed is appended when its first FEAT_Def is seen.
global FEAT_SECTIONS := ["Sending", "Model detection", "Chat reading and AI",
                         "Screen helpers", "Library", "Tools", "System"]

FEAT_Def(id, cfgKey, label, default, section) {
    FEAT_META[id] := {id: id, cfgKey: cfgKey, label: label, default: default, section: section}
    FEAT_ORDER.Push(id)
    for _, s in FEAT_SECTIONS
        if (s = section)
            return
    FEAT_SECTIONS.Push(section)
}

; ── Mode ──────────────────────────────────────────────────────────────────────
; Defaults to Advanced. An existing install already has advanced settings and a
; workflow built on them; silently demoting it on upgrade would look like MMA had
; lost half its features. install.bat is what puts a fresh machine into Easy.
MODE_Current() {
    m := StrLower(Trim(IniRead(MODE_CFG, "Settings", "Mode", "advanced")))
    return (m = "easy") ? "easy" : "advanced"
}

MODE_IsEasy() => (MODE_Current() = "easy")

MODE_Set(mode) {
    was := MODE_Current()
    now := (mode = "easy") ? "easy" : "advanced"
    IniWrite(now, MODE_CFG, "Settings", "Mode")
    ; INFO, and phrased as a consequence rather than a value, because switching to
    ; Easy is the single largest behaviour change available in MMA and it is one
    ; radio button. Somebody reading the log a week later needs to see that this
    ; is why half the app went quiet.
    LOGI("mode", "mode " was " → " now
              . (now = "easy" ? "   (every registry feature is now off, their hotkeys"
                              . " will not register and their children will not start)"
                              : "   (features return to their own checkboxes)"))
}

; ── The one question the rest of the code asks ────────────────────────────────
; True only when this feature is switched on AND we are in Advanced mode.
;
; Logged at VERB, never higher, and that split is deliberate. This is called from
; #HotIf and from inside send handlers, so it runs tens of times per keystroke —
; at INFO it would bury every other line in the file. But "the feature is off" is
; the correct answer to a startling number of "why did nothing happen" reports, so
; with max logging on, every gate that closed is written down with the cfg key you
; would have to change to open it.
FEAT(id) {
    if !FEAT_META.Has(id) {               ; undeclared = not a gated feature
        LOGV("feat", id " is not in the registry — treated as always on")
        return true
    }
    if MODE_IsEasy() {
        LOGV("feat", id " OFF — MMA is in Easy mode, which switches off every"
                   . " feature in the registry")
        return false
    }
    f := FEAT_META[id]
    on := Trim(IniRead(MODE_CFG, "Settings", f.cfgKey, f.default)) = "1"
    LOGV("feat", id " " (on ? "on" : "OFF") "  ([Settings] " f.cfgKey ")")
    return on
}

; The feature's own checkbox, ignoring the mode. The Settings window needs this
; so the checkboxes still show a user's real choices while Easy greys them out.
FEAT_Raw(id) {
    if !FEAT_META.Has(id)
        return true
    f := FEAT_META[id]
    return Trim(IniRead(MODE_CFG, "Settings", f.cfgKey, f.default)) = "1"
}

; Instrumented here rather than in features_panel.ahk on purpose: this is the
; single writer of every feature key (see that file's header), so one line here
; catches every toggle from everywhere, forever, and cannot be forgotten by a
; future second caller.
;
; Only CHANGES are logged. Saving the Features tab rewrites all ~24 keys whether
; or not you touched them, and 24 identical lines per save would make the one that
; matters unfindable.
FEAT_SetRaw(id, on) {
    if !FEAT_META.Has(id) {
        LOGW("feat.set", "'" id "' is not a declared feature — nothing written")
        return
    }
    f := FEAT_META[id]
    now := on ? "1" : "0"
    was := Trim(IniRead(MODE_CFG, "Settings", f.cfgKey, f.default))
    if (was != now)
        LOGI("feat.set", id " " (was = "1" ? "on" : "off") " → " (on ? "on" : "off")
                      . "   ([Settings] " f.cfgKey ")")
    IniWrite(now, MODE_CFG, "Settings", f.cfgKey)
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The registry. cfgKey reuses the key each feature already had wherever one
;  existed, so upgrading loses nothing.
; ═══════════════════════════════════════════════════════════════════════════════

; ── Sending ───────────────────────────────────────────────────────────────────
; Answering a follow-up with something other than the default. It was two toggles
; once — alts and branches — which only offered a combination nobody wants
; (branches on, alts off) and two checkboxes to keep in step. It is now one
; toggle over one thing: there are no alts, only named branches, and "alt" is
; simply the commonest branch name (see mass/store.ahk). Keeps the AltFollowups
; cfg key, so an existing config carries over; the old Branches key is ignored.
FEAT_Def("altFollowups", "AltFollowups",   "Branches (::name alternatives)",           "1", "Sending")
FEAT_Def("editableFu",   "EditableFuAny",  "Editable follow-ups / wallet check",       "1", "Sending")
; The text itself is a Settings field (DefaultFu3); this only says whether the
; fallback applies at all. Blank text is inert either way, so the switch matters
; mainly to Easy mode — v1.4.0 sent nothing when a mass had no f3, and Easy has
; to keep doing that.
FEAT_Def("defaultFu3",   "DefaultFu3On",   "Default FU3 when the mass has none",      "1", "Sending")
; Reads the chat and sends whichever follow-up comes next. Off by default is
; wrong here — it is bound and working — but it is the one send key that decides
; WHAT to send by looking at the screen, so it is also the one whose failure mode
; is "sent the wrong follow-up" rather than "did nothing". Being able to switch it
; off without unbinding the key is worth a checkbox of its own.
FEAT_Def("nextFu",       "NextFu",         "Auto detect next follow up (single button mode)", "1", "Sending")
FEAT_Def("openTab",      "OpenTabAny",     "Open in new tab after a send",             "1", "Sending")
FEAT_Def("mouseControl", "MouseControl",   "Mouse-button follow-ups",                  "1", "Sending")

; Its own switch rather than riding on the follow-up picker's, because the two ask
; at very different rates. The shared follow-up keys fire constantly and the window
; is a rhythm you either want or do not; the shared PPV keys fire a handful of times
; a shift, so someone can reasonably want the ask on one and not the other.
;
; Only bites in "I pick" mode — with a detector resolving the model there is nothing
; to ask, and this switch does nothing at all. See mass/model_picker.ahk.
FEAT_Def("ppvPicker",    "AskPpvModel",    "Ask which model on the shared PPV keys",   "1", "Sending")

; The mouse half of the anti-fumble guards. A follow-up is three messages with a
; pause between each, so clicking the next conversation a beat too early splits it
; across two fans; while a send runs this holds a click on the list and plays it
; back the moment the send lands. See screen/click_wall.ahk.
;
; ON by default, unlike the other guards-that-change-behaviour, because it costs
; nothing when it is wrong: the worst it can do is delay a click by the length of
; a send you were in the middle of anyway. And it is inert without a region — the
; fallback chain in CW_Region derives one from [NextFu], so the ordinary install
; is covered with nothing to calibrate.
FEAT_Def("clickWall",    "ClickWall",      "Hold clicks on the chat list while sending", "1", "Sending")

; ── Library ───────────────────────────────────────────────────────────────────
FEAT_Def("archive",     "Archive",           "Mass archive (save + browse past masses)", "1", "Library")
FEAT_Def("hotstrings",  "HotstringsManager", "Hotstrings manager",                       "1", "Library")
FEAT_Def("fastParse",   "FastParseAutosave", "Fast-parse autosave",                      "1", "Library")

; ── Tools ─────────────────────────────────────────────────────────────────────
FEAT_Def("actionsMenu",  "ActionsMenu",  "Actions menu",                      "1", "Tools")
FEAT_Def("quickActions", "QuickActions", "Quick actions (pinned buttons)",    "1", "Tools")
FEAT_Def("recorder",     "Recorder",     "Coordinate recorder",               "1", "Tools")
FEAT_Def("capitalizer",  "Capitalizer",  "Auto-capitalize after Enter",       "1", "Tools")
FEAT_Def("ocrGrab",      "OcrGrab",      "Add hotstring with OCR",            "1", "Tools")
; Stars and separators you stick onto your own browser tabs — decoration, not a
; readout (screen/tab_marks.ahk says why that distinction is load-bearing). A
; feature rather than always-on because it draws a window over the tab strip, and
; anything that puts pixels on top of the strip MMA also scans deserves an off
; switch that is one click away.
FEAT_Def("tabMarks",     "TabMarks",     "Tab bars (dividers on the strip)",  "1", "Tools")
; Draws a conversation as a tree and compiles it back into an ordinary mass —
; see src/branch/tree.ahk. On by default: it writes nothing until you press Save,
; it starts no background process, and it is only reachable from a key you press.
FEAT_Def("branchBuilder", "BranchBuilder", "Branch builder (draw a conversation)", "1", "Tools")
; The chat simulator draws a mass as the conversation it becomes, and lets you
; write it from inside that. Its own switch rather than riding the branch
; builder's: they are both "a window that makes a mass" and they answer
; different questions — one draws the structure, the other the experience.
FEAT_Def("chatSim",       "ChatSim",       "Chat simulator (write a mass in context)", "1", "Tools")
; Triggers that run an ACTION instead of typing a message, from
; userdata\shortcuts.ini — see hotstrings\shortcuts.ahk.
;
; On by default, and that is safe rather than presumptuous: the file it reads is
; seeded with two live lines and everything else commented out, so "on" means two
; triggers exist. It needs a switch at all because these are hotstrings on a
; system-wide hook, sharing a namespace with ~117 message triggers — if one ever
; swallows a message you type all day, the fix has to be one click and not a file
; you have to remember the name of.
FEAT_Def("shortcuts",     "HotstringShortcuts", "Hotstring shortcuts (type a trigger, run an action)", "1", "Tools")
; How the fix-grammar keys (chat/grammar.ahk) hand back their result. Off = the
; fix goes on the clipboard and you paste it. On = FAST: it pastes the fix back
; into the box itself and leaves your clipboard as it was. Not a hotkey gate —
; the keys work either way; this only picks the ending. Read on every press, so
; it applies without a restart.
FEAT_Def("grammarFast",   "GrammarFast",   "Fix grammar: fast mode (pastes the fix back for you)", "0", "Chat reading and AI")

; ── sequences: deliberately NOT declared ──────────────────────────────────────
;  It had a FEAT_Def here ("Sequences + Discord Ctrl+click import"), and that made
;  it the third switch able to kill the Discord import on its own — after the
;  StartupScripts checkbox and the Hotkeys tab, both of which have already done it.
;  Easy mode made it a fourth: Easy switches off EVERYTHING in this registry, so
;  the import died there with no checkbox to look at and nothing to untick.
;
;  Sequences is core now, like the engine. It owns hotkeys, the import is how masses
;  get into MMA at all, and a script that owns hotkeys should not be a checkbox —
;  see LaunchSequences in core/processes.ahk.
;
;  Leaving it undeclared is what makes it always-on: FEAT() above answers TRUE for
;  any id not in this registry, in Easy mode as well as Advanced, so the FEAT
;  ("sequences") calls that used to gate it cannot come back to life by accident.
;  The old [Settings] Sequences key in mass_gui.cfg is simply ignored from here on.

; ── Background ────────────────────────────────────────────────────────────────
FEAT_Def("modelDetector", "AutoDetectModel",    "Auto-detect the active model",        "0", "Model detection")
; Its own switch, not a mode of the one above. The two detectors read different
; windows, different geometry and different config, and either can be worth
; running while the other is not: an Infloww-only setup should not pay for a rail
; scan, and a Fansly session should not have the Infloww detector writing stale
; names. Both off is also a valid answer — that is what the manual select keys
; are for.
FEAT_Def("fanslyDetector","AutoDetectFansly",   "Auto-detect the active Fansly model", "0", "Model detection")
FEAT_Def("statsOverlay",  "StatsOverlay",       "Stats overlay",                       "0", "Screen helpers")
; OFF by default because it is useless until calibrated: it needs a rectangle
; drawn round YOUR conversation list, on your monitor at your window size, and
; there is no default for that worth shipping. Settings ▸ General ▸ Reply timers
; has the button. See screen/reply_box.ahk.
FEAT_Def("replyBox",      "ReplyBox",           "Reply timers (box rows kept waiting)", "0", "Screen helpers")
; A countdown timer: a window (gui.timer) and a no-window start/stop key
; (gui.timerToggle). On by default: asked for. See src/timer/timer.ahk.
FEAT_Def("timer",         "TimerTool",          "Timer (countdown, beep, repeat)",     "1", "Screen helpers")
FEAT_Def("automation",    "AutomationListener", "Automation hotkeys (needs Python)",   "1", "Screen helpers")
FEAT_Def("pinger",        "Pinger",             "Unread pinger (needs Python)",        "0", "Screen helpers")
FEAT_Def("startupScripts","StartupScriptsOn",   "Auto-start scripts + restart watchdog", "1", "System")
; OFF by default, and this one is not a taste call. It installs a keyboard hook
; that sees every key you press, in every application, for as long as it runs —
; it counts and never records what (src/activity/record.ahk is built so it
; cannot), but "counts your keystrokes" is still a thing somebody must switch on
; deliberately rather than discover running. Its hotkey goes with it: the chart
; is only worth a key when there is something behind it.
FEAT_Def("activity",      "ActivityTracker",    "Activity tracker (typing stats)",     "0", "System")
; OFF by default, and this one is the strongest version of that. The activity
; tracker above counts keystrokes and is BUILT so it cannot keep WHAT you typed
; (src/activity/record.ahk); typelog is the opposite — it records the text you
; type in Infloww into userdata\typelog\, to mine for hotstrings. That is a thing
; somebody switches on deliberately, never discovers running. Needs Python
; (pynput). See src/services/typelog/.
FEAT_Def("typelog",       "Typelog",            "Typelog (records what you type in Infloww)", "0", "Chat reading and AI")
; Next-word suggestions while you type, trained on the typelog corpus, plus
; Ctrl+Tab to reword the word you just typed (touched -> caressed). OFF by
; default for the same reason typelog is, plus one of its own: it can put text
; into the message box (Tab accepts a suggestion), and nothing that types on your
; behalf should ever arrive switched on. Ships in Render=off — predicting but
; drawing nothing, logging what it WOULD have said — so turning the feature on
; still shows no UI until you set Render=strip in userdata\autoword.ini.
; Needs Python (pynput). See src/services/autoword/.
FEAT_Def("autoword",      "Autoword",           "Autoword (next-word suggestions, Ctrl+Tab to reword)", "0", "Chat reading and AI")
; Keeps the open Infloww chat OCR'd in the background (userdata\chat_now.json),
; so the suggestion key has it instantly instead of paying ~2-5s of OCR per press.
; It only reads: PrintWindow, no focus, no clicks. On by default because the user
; asked for it always-on; it OCRs only when the chat changes. Needs Python.
; See src/services/llm/chatreader.pyw.
FEAT_Def("chatReader",    "ChatReader",         "Chat reader (reads the open chat for suggestions, needs Python)", "1", "Chat reading and AI")
; Shift recorder: the chat reader keeps every chat it reads, per fan, as training
; data (userdata\shiftlog\). Read by Python (shiftlog.feat), so these three only
; matter while the Chat reader runs. Times = the line under each message (time,
; chatter, PPV paid pill, his like); turn it off if those come out wrong. Panel =
; the fan's spend / subscription / notes on the right (~1.5s OCR when it changes).
FEAT_Def("shiftLog",      "ShiftLog",           "Shift recorder (saves every chat you work, for AI training)", "1", "Chat reading and AI")
FEAT_Def("shiftTimes",    "ShiftTimes",         "Shift recorder: message times, chatter, PPV paid, likes", "1", "Chat reading and AI")
FEAT_Def("shiftPanel",    "ShiftPanel",         "Shift recorder: fan panel (spend, subscription, notes)", "1", "Chat reading and AI")
FEAT_Def("shiftMedia",    "ShiftMedia",         "Shift recorder: keep a picture of each image/PPV you send", "1", "Chat reading and AI")
; Fan recorder (lore_gatherer, docs/proposals/lore-gatherer.md): the chat reader
; files every chat under the fan's @handle in [FanData] Root (D:\FanData), with
; dates and a crop of every unreadable bubble. Runs BESIDE the shift recorder for
; one shift (decision 33); shiftLog is switched off once it has been checked.
; A fan whose handle is cut off is filed provisionally and merged once it is read.
; Read by Python (mmacfg.feat) inside the Chat reader. See llm/fanrec.py.
FEAT_Def("fanRecorder",   "FanRecorder",        "Fan recorder (files every chat by the fan's @handle, D:\FanData)", "1", "Chat reading and AI")
; AutoNote (Silly's name for the fan database): a few minutes after you stop
; chatting a fan ([AutoNote] AfterMin, default 3), the local LLM writes or
; refreshes his note from his whole kept chat: who, into, money, recently, right
; now, avoid, reach-out lines. Shown in Fan Viewer. Uses the GPU, live, by choice
; (2026-11-26). Needs the Fan recorder. See llm/autonote.py.
FEAT_Def("autoNote",      "AutoNote",           "AutoNote (writes each fan's note after you chat him, needs Fan recorder)", "1", "Chat reading and AI")
; Rings when a PPV in the open chat flips from "not paid" to "paid" (what live
; Infloww shows), or a "has purchased your message" bubble appears.
; Read by Python (shiftlog.feat) inside the Chat reader, so it needs that on.
; Sound: userdata\sounds\purchase.wav if present, else Windows' tada.wav.
; See src/services/llm/purchase_alert.py.
FEAT_Def("purchaseSound", "PurchaseSound",      "Purchase sound (rings when a fan buys, needs Chat reader)", "1", "Chat reading and AI")
; Pings when the number on Infloww's Unread pill reaches [UnreadPing] At, then
; every EveryMin minutes while it stays there. Read by Python inside the Chat
; reader every 5s (shiftlog.feat), so it needs that on. On by default: asked for.
; See src/services/llm/unread_ping.py.
FEAT_Def("unreadPing",    "UnreadPing",         "Unread ping (beeps when X fans are waiting, needs Chat reader)", "1", "Chat reading and AI")
; OFF by default, deliberately. The startup check runs three seconds after launch
; and its prompt is NOT suppressed by `silent`, so with this on you get an update
; dialog in front of whatever you were doing, on someone else's release schedule
; — and saying yes overwrites the tree you are working in. Settings ▸ Models
; still has a "Check for updates" button that works whatever this is set to, so
; off costs you nothing except being asked.
FEAT_Def("autoUpdate",    "AutoUpdate",         "Check for updates at startup",        "0", "System")

; ═══════════════════════════════════════════════════════════════════════════════
;  Hotkey ownership. HK_Bind consults this, so a feature being off means its keys
;  are never registered — one central gate instead of a guard in every script.
;
;  Matched as a PREFIX against the hotkey id, longest first. Mass keys are matched
;  on their slot ("nextFu"); plain "mass.1.fu1" matches nothing and stays
;  unguarded. Mouse-button follow-ups is not in here: it gates individual MOUSE
;  keys of an overload, which a per-id map cannot say — see _HK_Apply.
; ═══════════════════════════════════════════════════════════════════════════════
global FEAT_HOTKEY_MAP := Map(
    "br",                 "altFollowups",   ; branches ride the same toggle
    "nextFu",             "nextFu",
    "gui.actions",        "actionsMenu",
    "gui.hotstringMenu",  "hotstrings",     ; the quick menu IS the manager
    "gui.quickActions",   "quickActions",
    "gui.toggleStats",    "statsOverlay",
    "gui.timer",          "timer",          ; gui.timer and gui.timerToggle
    "gui.activity",       "activity",
    "gui.branchBuilder",  "branchBuilder",
    "gui.chatSim",        "chatSim",
    "gui.ocrGrab",        "ocrGrab",
    "gui.addHotkeyGrab",  "ocrGrab",
    "marks.",             "tabMarks",
    "recorder.",          "recorder",
    "automation.",        "automation",
    ; No "seq." entry, and that absence is the point: FEAT_ForHotkey returns "" for
    ; seq.copyDiscordMsg and friends, so HK_Bind registers them whatever the mode.
    "cap.",               "capitalizer")

; Which feature owns this hotkey id, or "" when nothing does.
; mass.<n>.<slot> keys are matched on the SLOT, so one entry covers every model.
;
; "active" counts as a model here. It is not a digit, so the old \d+ pattern left
; mass.active.altFu1 and mass.active.mFu1 matching on the FULL id — where no
; prefix in the map can ever match, since they all start "mass." — and both keys
; registered with their feature switched off. Turning off alt follow-ups or mouse
; control silenced the numbered keys and left the shared ones live.
FEAT_ForHotkey(id) {
    slot := id
    if RegExMatch(id, "^mass\.(?:\d+|active)\.(.+)$", &m)
        slot := m[1]

    best := "", bestLen := 0
    for prefix, feat in FEAT_HOTKEY_MAP {
        ; a mass slot matches on its own name; everything else on the full id
        subject := (slot != id && !InStr(prefix, ".")) ? slot : id
        if (SubStr(subject, 1, StrLen(prefix)) = prefix && StrLen(prefix) > bestLen) {
            best := feat, bestLen := StrLen(prefix)
        }
    }
    return best
}

; True when this hotkey may register right now.
FEAT_HotkeyAllowed(id) {
    f := FEAT_ForHotkey(id)
    return (f = "") ? true : FEAT(f)
}
