#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  settings_core.ahk — the settings work that is not a window.
; ───────────────────────────────────────────────────────────────────────────────
;  Shared by the two Settings front ends: ui\settings_window.ahk (Win32, a Gui
;  inside the main window) and ui\settings_webview.ahk (Edge, its own process).
;
;  Small on purpose. Almost everything Settings does IS a window — laying out
;  controls, dragging calibration boxes, picking colours. What lands here is the
;  work that must not exist twice: the FIELD TABLE below, and the one integer
;  parser it needs.
;
;  It opened with SW_SaveWaitTime until now — the guarded rewrite of
;  core\utils.ahk, through a regex, a temp file and a FileMove, because the
;  wait time was stored as SOURCE CODE and saving it edited the one file every
;  message script and the mass engine #Include. That function is gone: WaitTime
;  is a plain [Settings] key now (see core\utils.ahk), so it saves through the
;  same loop as every other setting and there is nothing left about it for the
;  two front ends to share.
; ═══════════════════════════════════════════════════════════════════════════════

; ═════════════════════════════════════════════════════════════════════════════
;  THE FIELD TABLE — one description of every plain setting.
; ─────────────────────────────────────────────────────────────────────────────
;  This lived in ui\settings_webview.ahk, which meant the WebView window
;  owned the only list of what a setting IS — its cfg home, its type, its
;  default, its wording — while ui\settings_window.ahk hand-built controls
;  for the same keys from literals typed out again. That file's own header
;  said what followed from it: "a NEW setting must be added in both or it
;  will be missing from one of them."
;
;  Nothing checked. The two happened to agree — measured, 20 of 23 rows had
;  their key present in the Win32 source and the three that did not are the
;  virtual rows below — but agreeing today is not a mechanism.
;
;  So the table lives here, in the file both front ends already #Include, and
;  tools\test\settings_parity_test.ahk fails the build when a row has no home
;  in the Win32 window. Adding a setting is now: one row here, one control
;  there, and a test that tells you when you have done only half of it.
;
;  ─── THE VALUE PROVIDER ───
;  Two rows BUILD THEMSELVES out of another row's value: how many Model/
;  Platform pairs exist depends on ModelCount. A window that is mid-edit has
;  to see the PENDING count, not the saved one, or raising it to 4 shows no
;  fourth row until Save. A window that is not editing anything — and the
;  parity test — wants the saved value.
;
;  So the caller passes `cur`, a func(id, iniSect, iniKey, def). Omit it and
;  the table reads mass_gui.cfg. That one parameter is the whole difference
;  between the two front ends' needs, which is why the rest can be shared.
; ═════════════════════════════════════════════════════════════════════════════

; Parse an integer out of a settings value, falling back when it is not one.
; Lives here rather than in a shell because the table itself needs it.
SETTINGS_Int(v, fallback, min := 0) {
    v := Trim(v)
    if !RegExMatch(v, "^\d+$")
        return Integer(fallback)
    n := Integer(v)
    return (n < min) ? Integer(fallback) : n
}

; ─── The settings, declared once ────────────────────────────────────────────
;  One row per setting. Built by a function rather than a top-level array because
;  the model rows depend on ModelCount, which is itself one of the settings.
;
;    id     what a front end calls it, and the key it stores an edit under
;    sect   which page section it appears under
;    ini    [section, key] in mass_gui.cfg — or "" for a row with no key of its
;           own, which today means only the read-only "note" rows. Every editable
;           row is a plain write. There were three virtual rows once: waitTime,
;           a literal inside core\utils.ahk that saving rewrote, and the pair
;           modelStrategy + inflowwMatch, two halves of [Settings] ModelMatch.
;           All three became ordinary keys, and each time the special cases on
;           both front ends went with them.
;    type   bool | int | text | choice
;    def    the default, as a string, matching what the rest of MMA reads
;    label  what it is called
;    help   the line under it, or ""
;    opts   choice only: [[value, label], …]
;    warn   true if changing it needs MMA restarted to take effect
SETTINGS_Fields(cur := "") {
    f := []
    ; `grp` is the sub-heading a row sits under within its section. Empty for most
    ; of them; the Models section is the one that needs it, because it answers two
    ; different questions and running them together as one list is what made the
    ; Win32 tab hard to read.
    _grp := ""
    _add(id, sect, iniSect, iniKey, type, def, label, help := "", opts := 0, warn := false) {
        f.Push({id: id, sect: sect, grp: _grp, iniSect: iniSect, iniKey: iniKey,
                type: type, def: def, label: label, help: help, opts: opts,
                warn: warn})
    }
    ; A read-only line the page draws but cannot edit — a live readout, or a note
    ; about why a row above it is empty.
    _note(id, sect, label, help := "") {
        f.Push({id: id, sect: sect, grp: _grp, iniSect: "", iniKey: "",
                type: "note", def: "", label: label, help: help, opts: 0,
                warn: false})
    }
    ; The value a row should show: what the page has edited if it has edited it,
    ; otherwise what the cfg says. The Models rows below BUILD THEMSELVES out of
    ; other rows' values — which models are on which site decides what the tab and
    ; rail order rows may offer — so they have to see the pending edit, not the
    ; saved one. Switching a model to Fansly takes it out of the Infloww tab order
    ; in front of you, before Save; the Win32 tab does the same and says why.
    _cur(id, iniSect, iniKey, def) {
        if (cur != "")
            return cur.Call(id, iniSect, iniKey, def)
        ; A row with no ini home of its own. IniRead with a blank section is not
        ; a question, so it answers with its default.
        if (iniSect = "")
            return def
        return Trim(IniRead(MMA_CFG, iniSect, iniKey, def))
    }

    ; ── General ───────────────────────────────────────────────────────────────
    ; waitTime is an ORDINARY ROW now, and that is the whole change. It was the
    ; one setting in the table with no ini home — a literal inside core\utils.ahk
    ; that saving REWROTE — so both front ends carried a special case for it on
    ; load and another on save, and a third file scraped the same regex to read
    ; it. Moving the number into the cfg deleted all of that; what is left is
    ; this line. See core\utils.ahk for why the default is 1500 and not 350.
    _add("waitTime", "General", "Settings", "WaitTime", "int", "1500",
         "Wait between sent messages (ms)",
         "How long MMA pauses between the parts of a follow-up. Lower is faster"
       . " and more likely to outrun the page. Changing it restarts MMA.", 0, true)
    _add("DefaultHotkeyFile", "General", "Settings", "DefaultHotkeyFile", "text", "TEMP.ahk",
         "Default file for new hotstrings",
         "Which account file the Add-hotstring dialog writes to unless you pick"
       . " another.")
    _add("AutoRestart", "General", "Settings", "AutoRestart", "bool", "0",
         "Restart scripts that die",
         "A watchdog checks every 5 seconds and relaunches anything on the"
       . " startup list that has stopped.")
    _add("StartupScripts", "General", "Settings", "StartupScripts", "text", "general.ahk",
         "Scripts started with MMA",
         "Comma-separated. general.ahk holds your hotstrings, so it belongs here"
       . " unless you know otherwise.", 0, true)

    ; == Models ================================================================
    ;  A PORT of the Win32 Models tab, not a reinterpretation of it. Same rows,
    ;  same order, same wording, same grouping - drawn in HTML instead of
    ;  pixel-positioned AHK controls, and free of the one constraint that shaped
    ;  that tab (a Tab3 page cannot scroll, so everything had to fit).
    ;
    ;  This section is the one people are in most, and it is the one where a
    ;  wrong answer is expensive: a shared key that resolves to the wrong model
    ;  sends one model's message into another model's chat. Somebody who knows
    ;  the Win32 tab must not have to re-learn it here.
    ;
    ;  The page lays this section out ITSELF (renderModels in settings.html)
    ;  rather than as a list of rows, because the layout carries meaning: the
    ;  NAME/PLATFORM table, the "Strategy" pair, and the two per-site blocks are
    ;  each one question, and running them together as a flat list is not the
    ;  same window. The rows below are still the only description of what those
    ;  controls ARE - the page picks them out by id.
    _grp := ""

    _mc := []
    Loop MASS_MODELS_MAX
        _mc.Push([A_Index . "", A_Index . ""])
    ; Default 3, matching MMA_ModelNames in core\paths.ahk - that is the function
    ; that decides how many slots actually exist, so a different default here
    ; would disagree with the tree on a fresh install.
    _add("ModelCount", "Models", "Settings", "ModelCount", "choice", "3",
         "Active models", "Changing this restarts MMA.", _mc, true)

    ; The EDITED count, so raising it to 4 shows model 4's row at once - clamped
    ; to the slots that exist, because a name typed into a slot MMA has not got
    ; would be written to the cfg and never read.
    _n := SETTINGS_Int(_cur("ModelCount", "Settings", "ModelCount", "3"), 3, 1)
    _n := Max(1, Min(_n, MASS_MODELS))

    ; 1 = Infloww, 2 = Fansly, stored by NAME. The Win32 tab spells out why the
    ; third entry ("Manual (you say)") is gone: that is not a site, it is a way
    ; of deciding which model is on screen, and that question is the Strategy
    ; control below. One question, one control.
    _sites := [["infloww", "Infloww (detect)"], ["fansly", "Fansly (detect)"]]
    Loop _n {
        _i := A_Index
        _add("Model" _i, "Models", "Settings", "Model" _i, "text", "Model " _i,
             "Model " _i)
        _add("Platform" _i, "Models", "Settings", "Platform" _i, "choice",
             "infloww", "Model " _i " platform", "", _sites)
    }

    ; ── Use a single hotkey for all masses ────────────────────────────────────
    ;  ONE key per action instead of one per action per model. The [mass.active]
    ;  keys are shared: they send whatever the model you are working on has in
    ;  that slot. The numbered keys ([mass.1.*], [mass.2.*]) are unaffected by
    ;  everything below and keep working whatever this is set to.
    _add("SharedKeys", "Models", "Settings", "SharedKeys", "bool", "1",
         "Enabled - the shared [mass.active] keys resolve to the model you are"
       . " working on",
         "Off: the shared keys go quiet and only the numbered per-model keys"
       . " send. Applies to the next keypress - no restart.")

    ; ── how each site decides, and they are NOT one setting ───────────────────
    ;  Two sites, two detectors, two answers. The Infloww tab strip and the
    ;  Fansly rail share no scan, no config and no failure mode, and a mixed desk
    ;  is the normal case here - so each site gets the SAME three choices over
    ;  its OWN key, and the two do not have to agree.
    ;
    ;  MANUAL reads no pixels at all: you name the model with a [mass.select]
    ;  key, and the shared follow-up and PPV keys open the picker window so the
    ;  model is never assumed. It is the working setup on a site whose detector
    ;  cannot be trusted, which is exactly where Fansly is today.
    ;
    ;  BY NAME OCRs the label and matches it against the names above. Survives
    ;  you reordering, but the names are the fragile part - MMA, Infloww and
    ;  Discord each have their own, and Fansly's rail truncates them.
    ;
    ;  BY POSITION uses where the lit tab or card SITS. No OCR, no names. The
    ;  cost is that it trusts the order staying put.
    ;
    ;  ─── THIS USED TO BE THREE CONTROLS OVER TWO KEYS ────────────────────────
    ;  There was a "Strategy" pair (manual/automatic) ABOVE these, and it was
    ;  global: it wrote the manual half of [Settings] ModelMatch, and the
    ;  resolver short-circuited on that before Fansly was ever consulted. So the
    ;  only way to stop MMA trusting the Fansly rail was to stop it reading the
    ;  Infloww tab strip as well. "Automatic on OnlyFans, manual on Fansly" was
    ;  not expressible in this window or in the cfg.
    ;
    ;  Folding manual into each site's own row makes the two rows independent and
    ;  removes a virtual field: inflowwMatch is now a plain write of [Settings]
    ;  ModelMatch rather than half of it, so both front ends lost the split-on-
    ;  load / recombine-on-save dance that went with it.
    _matchOpts(posLabel) {
        return [["manual",   "Manual - I pick with the GUI"],
                ["name",     "by name (OCR)"],
                ["position", posLabel]]
    }
    _add("inflowwMatch", "Models", "Settings", "ModelMatch", "choice", "name",
         "OnlyFans (Infloww)",
         "How MMA decides which model is on screen in Infloww. Says nothing"
       . " about Fansly.",
         _matchOpts("by tab position"))
    ; Position is the default on THIS platform, not name - the rail truncates
    ; its labels, so there is often no full name on screen to read at any OCR
    ; quality. See core\fansly_model.ahk.
    _add("fanslyMatch", "Models", "Fansly", "Match", "choice", "position",
         "Fansly",
         "How MMA decides which model is on the Fansly rail. Says nothing about"
       . " Infloww.",
         _matchOpts("by rail position"))

    ; ── the two order rows ────────────────────────────────────────────────────
    ;  Tab order, left to right: which model each tab index IS. The screen
    ;  answers "which tab is lit"; this answers "which model that tab is", and
    ;  no pixel on screen carries that fact.
    ;
    ;  Each row is built from the PLATFORM column above it, LIVE - as many
    ;  dropdowns as that site has models, each listing only those models. A
    ;  model switched to Fansly leaves the Infloww tab order in front of you,
    ;  before Save. A control that only tells the truth after a save-and-reopen
    ;  is how the old version could be read as correct.
    ;
    ;  The value IS the model number, so nothing has to map a dropdown index
    ;  back to a slot on the way out - which is where the Win32 version has to
    ;  be careful, and where "tab 1 = the second Infloww model" could be written
    ;  as "tab 1 = model 2" on a setup whose first Infloww model is model 2.
    _onSite(want) {
        out := []
        Loop _n
            if (_cur("Platform" A_Index, "Settings", "Platform" A_Index, "infloww") = want)
                out.Push(A_Index)
        return out
    }
    _slotOpts(slots) {
        out := []
        for _, _sl in slots
            out.Push([_sl . "", Trim(_cur("Model" _sl, "Settings", "Model" _sl,
                                          "Model " _sl))])
        return out
    }
    _ofSlots  := _onSite("infloww")
    _fanSlots := _onSite("fansly")

    _opts := _slotOpts(_ofSlots)
    for _pos, _sl in _ofSlots
        _add("Positional.Pos" _pos, "Models", "Positional", "Pos" _pos, "choice",
             _sl . "", "Infloww tab " _pos, "", _opts)

    _opts := _slotOpts(_fanSlots)
    for _pos, _sl in _fanSlots
        _add("FanslyPos.Pos" _pos, "Models", "FanslyPos", "Pos" _pos, "choice",
             _sl . "", "Fansly card " _pos, "", _opts)

    _grp := ""

    ; ── Sending ───────────────────────────────────────────────────────────────
    _add("WalletCheckFu3", "Sending", "Settings", "WalletCheckFu3", "bool", "0",
         "Check the wallet before FU3",
         "Reads the fan's balance and skips FU3 if there is nothing in it.")
    _add("OpenTabFu2", "Sending", "Settings", "OpenTabFu2", "bool", "0",
         "Open a new tab after FU2")
    _add("OpenTabFu3", "Sending", "Settings", "OpenTabFu3", "bool", "0",
         "Open a new tab after FU3")
    _add("OpenTabPpv", "Sending", "Settings", "OpenTabPpv", "bool", "0",
         "Open a new tab after a PPV")
    _add("DefaultFu3", "Sending", "Settings", "DefaultFu3", "text", "",
         "Default FU3",
         "Sent as FU3 when the mass does not define one. Leave empty to send"
       . " nothing.")
    _add("AltStageNoGui", "Sending", "Settings", "AltStageNoGui", "bool", "0",
         "Stage branches without the picker window",
         "TAB walks the staged alternatives in the chat box instead of opening"
       . " the Variants grid.")

    ; ── Interface ─────────────────────────────────────────────────────────────
    ; THEME_List, not THEME_Picker — the latter returns the follow-up picker's
    ; COLOUR palette, which is an object of hex strings and not enumerable. The
    ; list of themes is kept in theme.ahk so adding one is one file, not two.
    _th := []
    for _, t in THEME_List()
        _th.Push([t.id, t.label])
    _add("Theme", "Interface", "Settings", "Theme", "choice", "pink",
         "Theme", "Applies to every MMA window.", _th)
    _add("MainWindowShell", "Interface", "Settings", "MainWindowShell", "choice", "webview",
         "Main window",
         "WebView draws the panel with Edge and CSS and is what MMA opens."
       . " Classic is the Win32 window — pick it if WebView2 will not start on"
       . " this machine.",
         [["webview", "WebView (Edge)"], ["legacy", "Classic (Win32)"]], true)
    ; ── the other two windows that come in both kinds ─────────────────────────
    ;  One question per window rather than one switch for the lot: WebView2 can
    ;  be fine for one of these and not another, and the Win32 versions are not
    ;  going anywhere. All three read through MMA_ShellFor in core\paths.ahk, so
    ;  every launcher gets the same answer — including the Classic main window's
    ;  Settings button, which used to be able to open only its own Win32 tabs and
    ;  so made this preference a half-truth.
    ;
    ;  Neither needs a restart: both are read when the button is pressed.
    _add("SettingsShell", "Interface", "Settings", "SettingsShell", "choice", "webview",
         "Settings window",
         "This window, or the Win32 tabs. Classic Settings is the only place the"
       . " calibration drags, the region pickers and the detector probes live, so"
       . " it stays reachable either way from the link below.",
         [["webview", "WebView (Edge)"], ["legacy", "Classic (Win32)"]])
    _add("HotkeysShell", "Interface", "Settings", "HotkeysShell", "choice", "webview",
         "Hotkey editor",
         "Both read and write the same hotkeys.ini and capture keys the same way"
       . " — the WebView one draws them as keycaps and puts the clashes on the"
       . " row. If Edge will not start it opens the Win32 one for you.",
         [["webview", "WebView (Edge)"], ["legacy", "Classic (Win32)"]])
    _add("LegacyLoadSaveUI", "Interface", "Settings", "LegacyLoadSaveUI", "bool", "0",
         "Use the legacy Load/Save grid",
         "Off gives one Load and one Save for the tab in front of you. On gives"
       . " the per-model grid, which is the only way to load a model you are not"
       . " looking at.", 0, true)
    _add("ArchiveOnParse", "Interface", "Settings", "ArchiveOnParse", "bool", "1",
         "Archive every mass you Parse",
         "Keeps a dated copy of each pasted mass so you can find it again.")
    ; TWO keys, and they are not the same question. CreditPicture is a BOOLEAN —
    ; CREDIT_On() reads it with LOG_IniInt and it means "show her at all" — while
    ; CreditImage holds WHICH file. Writing a path into CreditPicture (which is
    ; what a single text row here did at first) leaves CREDIT_On reading a
    ; filename as a number.
    _add("CreditPicture", "Interface", "Settings", "CreditPicture", "bool", "1",
         "Show the corner picture",
         "The artwork in the bottom-right of the main window.")
    ; Built from the folder, like the Win32 dropdown, plus whatever is already
    ; set — a file picked from outside assets\decoration\ is not in the folder
    ; listing, and leaving it out would show "automatic" next to a picture that is
    ; nothing of the sort and then wipe the choice on save.
    _ci := [["", "Automatic — an anime_girl GIF in assets\decoration\, else the PNG"]]
    _ciCur := Trim(IniRead(MMA_CFG, "Settings", "CreditImage", ""))
    _ciSeen := false
    for _f in CREDIT_AssetList() {
        _ci.Push([_f, _f])
        if (_f = _ciCur)
            _ciSeen := true
    }
    if (_ciCur != "" && !_ciSeen)
        _ci.Push([_ciCur, _ciCur])
    _add("CreditImage", "Interface", "Settings", "CreditImage", "choice", "",
         "Which picture",
         "Anything in assets\decoration\ shows up here. Pick a file from"
       . " elsewhere in the Classic Settings — this list is the folder.", _ci)
    return f
}
