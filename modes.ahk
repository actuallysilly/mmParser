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

global MODE_CFG   := SubStr(A_LineFile, 1, InStr(A_LineFile, "\", , -1) - 1) "\mass_gui.cfg"
global FEAT_META  := Map()      ; id -> {id, cfgKey, label, default, section}
global FEAT_ORDER := []         ; declaration order, for the Settings window
global FEAT_SECTIONS := []      ; section names in first-seen order

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
    IniWrite((mode = "easy") ? "easy" : "advanced", MODE_CFG, "Settings", "Mode")
}

; ── The one question the rest of the code asks ────────────────────────────────
; True only when this feature is switched on AND we are in Advanced mode.
FEAT(id) {
    if !FEAT_META.Has(id)                 ; undeclared = not a gated feature
        return true
    if MODE_IsEasy()
        return false
    f := FEAT_META[id]
    return Trim(IniRead(MODE_CFG, "Settings", f.cfgKey, f.default)) = "1"
}

; The feature's own checkbox, ignoring the mode. The Settings window needs this
; so the checkboxes still show a user's real choices while Easy greys them out.
FEAT_Raw(id) {
    if !FEAT_META.Has(id)
        return true
    f := FEAT_META[id]
    return Trim(IniRead(MODE_CFG, "Settings", f.cfgKey, f.default)) = "1"
}

FEAT_SetRaw(id, on) {
    if !FEAT_META.Has(id)
        return
    IniWrite(on ? "1" : "0", MODE_CFG, "Settings", FEAT_META[id].cfgKey)
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The registry. cfgKey reuses the key each feature already had wherever one
;  existed, so upgrading loses nothing.
; ═══════════════════════════════════════════════════════════════════════════════

; ── Sending ───────────────────────────────────────────────────────────────────
; Alt follow-ups and --Name branches are one feature with two spellings: both are
; "send something other than the default follow-up". They were separate toggles,
; which only offered a combination nobody wants (branches on, alts off) and two
; checkboxes to keep in step. Keeps the AltFollowups cfg key, so an existing
; config carries over; the old Branches key is simply ignored.
FEAT_Def("altFollowups", "AltFollowups",   "Alt follow-ups and --Name branches",       "1", "Sending")
FEAT_Def("editableFu",   "EditableFuAny",  "Editable follow-ups / wallet check",       "1", "Sending")
; The text itself is a Settings field (DefaultFu3); this only says whether the
; fallback applies at all. Blank text is inert either way, so the switch matters
; mainly to Easy mode — v1.4.0 sent nothing when a mass had no f3, and Easy has
; to keep doing that.
FEAT_Def("defaultFu3",   "DefaultFu3On",   "Default FU3 when the mass has none",      "1", "Sending")
FEAT_Def("openTab",      "OpenTabAny",     "Open in new tab after a send",             "1", "Sending")
FEAT_Def("doubleMM",     "DoubleMM",       "Double-MM (send two models at once)",      "1", "Sending")
FEAT_Def("fuSingle",     "FuSingleAny",    "FuSingle grid (per-model follow-up map)",  "1", "Sending")
FEAT_Def("mouseControl", "MouseControl",   "Mouse-button follow-ups",                  "1", "Sending")

; ── Library ───────────────────────────────────────────────────────────────────
FEAT_Def("archive",     "Archive",           "Mass archive (save + browse past masses)", "1", "Library")
FEAT_Def("hotstrings",  "HotstringsManager", "Hotstrings manager",                       "1", "Library")
FEAT_Def("fastParse",   "FastParseAutosave", "Fast-parse autosave",                      "1", "Library")

; ── Tools ─────────────────────────────────────────────────────────────────────
FEAT_Def("actionsMenu",  "ActionsMenu",  "Actions menu",                      "1", "Tools")
FEAT_Def("quickActions", "QuickActions", "Quick actions (pinned buttons)",    "1", "Tools")
FEAT_Def("recorder",     "Recorder",     "Coordinate recorder",               "1", "Tools")
FEAT_Def("capitalizer",  "Capitalizer",  "Auto-capitalize after Enter",       "1", "Tools")
FEAT_Def("sequences",    "Sequences",    "Sequences + Discord Ctrl+click import", "1", "Tools")
FEAT_Def("ocrGrab",      "OcrGrab",      "OCR / selection grab into Add Hotkey",  "1", "Tools")

; ── Background ────────────────────────────────────────────────────────────────
FEAT_Def("modelDetector", "AutoDetectModel",    "Auto-detect the active model",        "0", "Background")
FEAT_Def("statsOverlay",  "StatsOverlay",       "Stats overlay",                       "0", "Background")
FEAT_Def("automation",    "AutomationListener", "Automation hotkeys (needs Python)",   "1", "Background")
FEAT_Def("pinger",        "Pinger",             "Unread pinger (needs Python)",        "0", "Background")
FEAT_Def("startupScripts","StartupScriptsOn",   "Auto-start scripts + restart watchdog", "1", "Background")

; ═══════════════════════════════════════════════════════════════════════════════
;  Hotkey ownership. HK_Bind consults this, so a feature being off means its keys
;  are never registered — one central gate instead of a guard in every script.
;
;  Matched as a PREFIX against the hotkey id, longest first, so "mass.1.altFu1"
;  finds "altFu" while plain "mass.1.fu1" matches nothing and stays unguarded.
; ═══════════════════════════════════════════════════════════════════════════════
global FEAT_HOTKEY_MAP := Map(
    "altFu",              "altFollowups",
    "br",                 "altFollowups",   ; branches ride the same toggle
    "mFu",                "mouseControl",
    "gui.actions",        "actionsMenu",
    "gui.quickActions",   "quickActions",
    "gui.toggleStats",    "statsOverlay",
    "gui.toggleDoubleMM", "doubleMM",
    "gui.ocrGrab",        "ocrGrab",
    "gui.addHotkeyGrab",  "ocrGrab",
    "recorder.",          "recorder",
    "automation.",        "automation",
    "cap.",               "capitalizer",
    "seq.",               "sequences")

; Which feature owns this hotkey id, or "" when nothing does.
; mass.<n>.<slot> keys are matched on the SLOT, so one entry covers every model.
FEAT_ForHotkey(id) {
    slot := id
    if RegExMatch(id, "^mass\.\d+\.(.+)$", &m)
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
