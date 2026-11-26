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

; INI8_Read / INI8_Write, for the rows whose home is a Python service's own ini
; rather than mass_gui.cfg — see SETTINGS_Read below.
#Include "../core/ini_utf8.ahk"

; autoword's own settings file. Its [Model] rows are in the table below.
global SETTINGS_AUTOWORD_INI := MMA_USERDATA "\autoword.ini"
; The local-AI services' settings file ([Ollama], [Draft], [Grammar]).
global SETTINGS_LLM_INI := MMA_USERDATA "\llm.ini"

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
;    tool   the feature id (or pseudo-id) whose page in the Tools window draws
;           this row, or "" for a row that lives in Settings. A tool row is drawn
;           generically by ui\tools_settings.ahk; the WebView settings page shows
;           it under its `sect` like any other.
SETTINGS_Fields(cur := "") {
    f := []
    ; `grp` is the sub-heading a row sits under within its section. Empty for most
    ; of them; the Models section is the one that needs it, because it answers two
    ; different questions and running them together as one list is what made the
    ; Win32 tab hard to read.
    _grp := ""
    ; `file` is where a row lives when that is NOT mass_gui.cfg — "" for nearly
    ; all of them. Set it before a run of rows and clear it after, like _grp.
    _file := ""
    ; `tool` — see the header. Set before a run of rows and clear it after.
    _tool := ""
    _add(id, sect, iniSect, iniKey, type, def, label, help := "", opts := 0, warn := false) {
        f.Push({id: id, sect: sect, grp: _grp, iniSect: iniSect, iniKey: iniKey,
                type: type, def: def, label: label, help: help, opts: opts,
                warn: warn, file: _file, tool: _tool})
    }
    ; A read-only line the page draws but cannot edit — a live readout, or a note
    ; about why a row above it is empty.
    _note(id, sect, label, help := "") {
        f.Push({id: id, sect: sect, grp: _grp, iniSect: "", iniKey: "",
                type: "note", def: "", label: label, help: help, opts: 0,
                warn: false, file: "", tool: _tool})
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
    _add("HotkeyExpiryDays", "General", "Settings", "HotkeyExpiryDays", "int", "10",
         "Hotstring keys expire after (days)",
         "What the Add-hotstring dialog's Expires box starts at. When a key's"
       . " date passes, the key is released and the hotstring is kept. 0 ="
       . " never.")
    _add("AutoRestart", "General", "Settings", "AutoRestart", "bool", "0",
         "Restart scripts that die",
         "A watchdog checks every 5 seconds and relaunches anything on the"
       . " startup list that has stopped.")
    _add("AutoRecordShift", "General", "Settings", "AutoRecordShift", "bool", "1",
         "Record every shift with OBS",
         "When the Infloww Messages window opens, start OBS on its Shifts"
       . " profile, recording to D:\ShiftRecordings. Once per window; if OBS"
       . " is already open it is left alone.")
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
    _tool := "archive"
    _add("ArchiveOnParse", "Interface", "Settings", "ArchiveOnParse", "bool", "1",
         "Archive every mass you Parse",
         "Keeps a dated copy of each pasted mass so you can find it again.")
    ; Read by ArchiveExportSeparator in mass\archive.ahk. Stored escaped (\n, \t)
    ; because an ini value cannot hold a real line break.
    _add("ArchiveSeparator", "Interface", "Settings", "default_archive_separator", "text", "\n",
         "Export separator",
         "Goes between masses in an exported .txt. \n is a line break, \t a tab."
       . " Empty means \n.")
    _tool := ""
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

    ; ── Autoword ──────────────────────────────────────────────────────────────
    ;  Its own section. Every row lives in userdata\autoword.ini, which autoword
    ;  reads once at startup — so the main window restarts autoword whenever that
    ;  file changes (CORE_AutowordModelCheck in ui\main_core.ahk). Switching
    ;  autoword on or off is still Features; this is how it behaves once it is on.
    ;  autoword's keys ([Keys], [Reword] Key) are left to the ini.
    ;
    ;  A choice row lists only the values worth offering, plus the current one
    ;  when it is something else (hand-edited), for the reason CreditImage keeps
    ;  its outside file: leaving it out would wipe it on save.
    ; NOT `cur`: a nested function assigning a name the outer function owns
    ; writes the OUTER variable, and that one is the pending-edits callback, so
    ; every _cur() after this section threw "String has no method Call".
    _awOpts(opts, iniSect, iniKey, def) {
        have := INI8_Read(SETTINGS_AUTOWORD_INI, iniSect, iniKey, def)
        for o in opts
            if (o[1] = have)
                return opts
        if (have != "")
            opts.Push([have, have])
        return opts
    }
    _file := SETTINGS_AUTOWORD_INI
    _tool := "autoword"

    _grp  := "Suggestions"
    _add("awRender", "Autoword", "Mode", "Render", "choice", "off",
         "Show suggestions",
         "Off still predicts, and logs what it would have said to"
       . " debuglogs\autoword_shadow.log.",
         _awOpts([["strip", "Strip near the message box"],
                  ["off",   "Off (measure only)"]], "Mode", "Render", "off"))
    _add("awPredict", "Autoword", "Mode", "Predict", "choice", "nextword",
         "What to predict",
         "Completion ignores the words before; Both uses them and falls back to"
       . " completion when it has never seen them.",
         _awOpts([["nextword",   "Next word, from the words before it"],
                  ["completion", "Complete the word being typed"],
                  ["both",       "Both"]], "Mode", "Predict", "nextword"))
    _add("awMinChars", "Autoword", "Suggest", "MinChars", "choice", "1",
         "When to suggest",
         "Before any letter, the right word is in the list about 47% of the time;"
       . " after one letter, 73%.",
         _awOpts([["1", "After the first letter (measured best)"],
                  ["0", "Right after space, before any letter"],
                  ["2", "After two letters"]], "Suggest", "MinChars", "1"))
    _add("awListSize", "Autoword", "Suggest", "ListSize", "int", "3",
         "How many to show",
         "Measured: 3 saves the most keystrokes; past 3 you are reading for nothing.")
    _add("awMinSaving", "Autoword", "Suggest", "MinSaving", "int", "1",
         "Least letters saved",
         "Hide a suggestion that saves fewer letters than this. 1 measured best;"
       . " higher cuts to, so, me — the easiest words to predict.")
    _add("awPreferContent", "Autoword", "Suggest", "PreferContentWords", "choice", "off",
         "Prefer real words",
         "Rank real words above stop words (to, the, you, it), which are quicker to"
       . " type than to pick. Before the first letter needs When to suggest = right"
       . " after space. Weights and the word list are in autoword.ini.",
         _awOpts([["off",    "Off (plain ranking)"],
                  ["empty",  "Only before the first letter"],
                  ["always", "Always"]], "Suggest", "PreferContentWords", "off"))

    _grp  := "Model"
    _add("awPredictor", "Autoword", "Model", "Predictor", "choice", "ngram",
         "Who ranks them",
         "The language model reads the whole sentence and your previous message;"
       . " it needs the GPU. Shadow shows the n-gram and logs both, to"
       . " debuglogs\autoword_lm_shadow.log.",
         [["ngram",  "n-gram (fast, no GPU)"],
          ["lm",     "Language model"],
          ["shadow", "Shadow (n-gram shown, both measured)"]])
    ; The model folders that can load: a config.json beside the weights. Plus the
    ; current value when it points somewhere else, for the reason CreditImage
    ; keeps its outside file: leaving it out would wipe it on save.
    _lm := []
    _lmCur := INI8_Read(SETTINGS_AUTOWORD_INI, "Model", "LmPath", "")
    _lmSeen := false
    loop files MMA_USERDATA "\corpus\models\*", "D" {
        if !FileExist(A_LoopFileFullPath "\config.json")
            continue
        _v := "userdata\corpus\models\" A_LoopFileName
        _lm.Push([_v, A_LoopFileName])
        if (_v = _lmCur)
            _lmSeen := true
    }
    if (_lmCur != "" && !_lmSeen)
        _lm.Push([_lmCur, _lmCur])
    _add("awLmPath", "Autoword", "Model", "LmPath", "choice", "",
         "Language model",
         "Which fine-tuned model, from userdata\corpus\models. Used by Language"
       . " model and Shadow; ignored by n-gram.", _lm)
    _add("awLmContext", "Autoword", "Model", "Context", "choice", "typed",
         "What it reads first",
         "The open chat needs Features ▸ Chat reader on; it uses the reader's OCR"
       . " and falls back to your last message when that is missing.",
         _awOpts([["typed", "Your last sent message"],
                  ["chat",  "The open chat (OCR, fan and model)"]], "Model", "Context", "typed"))
    _add("awLmWeight", "Autoword", "Model", "LmWeight", "text", "0.5",
         "n-gram weight in the mix",
         "Suggestions are ranked by LM + weight × log(n-gram). 0.5 to 1 measured best.")

    _grp  := "Typing for you"
    _add("awAutoChars", "Autoword", "Suggest", "AutoCompleteChars", "int", "0",
         "Type the word after",
         "Letters typed before an obvious word (the only one you have ever typed"
       . " here) is typed for you. 0 = never; 3 is a sane start.")
    _add("awAutoSeen", "Autoword", "Suggest", "AutoCompleteSeen", "int", "5",
         "Only words seen at least",
         "Times. Measured at 3 letters: 5 is right 97% of the time, 10 is 98% but"
       . " fires a third less.")
    _add("awAutoIdle", "Autoword", "Suggest", "AutoCompleteIdleMs", "int", "250",
         "Wait for a pause of",
         "Milliseconds of no typing before it types. 0 typed 'feelinging': it acted"
       . " a keystroke behind your fingers.")
    _add("awAutoFrag", "Autoword", "Suggest", "AutoCompleteOnlyFragments", "choice", "true",
         "Finished words",
         "do → does is right most of the time and still wrong: you were done.",
         _awOpts([["true",  "Never extend a word you had finished"],
                  ["false", "Extend them too"]], "Suggest", "AutoCompleteOnlyFragments", "true"))
    _add("awAutoNever", "Autoword", "Suggest", "AutoCompleteNever", "text", "",
         "Never type these",
         "Comma separated, the finished word: does, your, legs."
       . " userdata\autoword\vocabulary.tsv lists your words, commonest first.")

    _grp  := "Where"
    _add("awProcesses", "Autoword", "Scope", "Processes", "text", "infloww.exe",
         "Only in",
         "Programs it suggests in, comma separated. Empty = everywhere.")
    _file := ""
    _grp  := ""

    ; ══ Tools ════════════════════════════════════════════════════════════════
    ;  Settings for the tools that had none in any window — they lived only in
    ;  mass_gui.cfg or a service's own ini. Drawn by ui\tools_settings.ahk on each
    ;  tool's page. Most services read these once at start, so the Tools window
    ;  says "press Restart" rather than pretending they apply live.
    _tool := "statsOverlay", _grp := "Stats overlay"
    _add("soVisible", "Tools", "StatsOverlay", "Visible", "bool", "1", "Show the overlay")
    _add("soPoll", "Tools", "StatsOverlay", "PollMs", "int", "10000", "Read every (ms)")
    _add("soScale", "Tools", "StatsOverlay", "OcrScale", "int", "2", "OCR scale")
    _add("soRed", "Tools", "StatsOverlay", "RedAt", "text", "0.30", "Ratio is red under")
    _add("soYellow", "Tools", "StatsOverlay", "YellowAt", "text", "0.40", "Yellow under")
    _add("soGreen", "Tools", "StatsOverlay", "GreenAt", "text", "0.50", "Green from")

    ; Read on every start (src/timer/timer.ahk), so no restart. The timer's own
    ; window writes the first four too.
    _tool := "timer", _grp := "Timer"
    _add("tmMin", "Tools", "Timer", "Minutes", "int", "5", "Minutes")
    _add("tmSec", "Tools", "Timer", "Seconds", "int", "0", "Seconds")
    _add("tmRepeat", "Tools", "Timer", "Repeat", "bool", "0", "Repeat")
    _add("tmBeep", "Tools", "Timer", "Beep", "bool", "1", "Beep when done")
    _add("tmBeeps", "Tools", "Timer", "Beeps", "int", "3", "Beeps")

    _tool := "unreadPing", _grp := "Unread ping"
    _add("upAt", "Tools", "UnreadPing", "At", "int", "10", "Ping at (unread chats)",
         "The number on Infloww's Unread pill. Read every 5s; applies live.")
    _add("upEvery", "Tools", "UnreadPing", "EveryMin", "int", "3", "Repeat every (minutes)",
         "While it stays at or above that. 0 = once, until it drops back under.")

    ; The countSales key (automation.py -> sales_tally.py). Read on every run.
    ; Prices are per model SLOT, so renaming a model keeps its prices.
    _tool := "automation", _grp := "Sales tally"
    _add("stStop", "Tools", "SalesTally", "StopAfter", "int", "3",
         "Stop after (in a row)",
         "The shift ends when this many purchases in a row were answered by someone else.")
    Loop _n {
        _add("stMppv" A_Index, "Tools", "SalesTally", "Mppv" A_Index, "text", "",
             _cur("Model" A_Index, "Settings", "Model" A_Index, "Model " A_Index) " MPPV prices",
             A_Index = 1 ? "Mass PPV prices, comma separated (20, 25). Those sales are not the chatter's and are listed apart." : "")
    }

    _tool := "modelDetector", _grp := "Model detector (Infloww)"
    _add("detWin", "Tools", "Detector", "WinMatch", "text", "Infloww Messages",
         "Window title has", "Restart the detector after changing anything here.")
    _add("detPoll", "Tools", "Detector", "PollMs", "int", "500", "Check every (ms)")
    _add("detX", "Tools", "Detector", "RegionX", "int", "0", "Tab strip left")
    _add("detY", "Tools", "Detector", "RegionY", "int", "0", "Tab strip top")
    _add("detW", "Tools", "Detector", "RegionW", "int", "330", "Tab strip width")
    _add("detH", "Tools", "Detector", "RegionH", "int", "50", "Tab strip height")
    _add("detOrigin", "Tools", "Detector", "TabOrigin", "int", "30", "First tab starts at")
    _add("detPitch", "Tools", "Detector", "TabPitch", "int", "150", "Tab width")
    _add("detGrey", "Tools", "Detector", "GreyColor", "text", "0x2B2C30", "Selected-tab colour")
    _add("detTol", "Tools", "Detector", "GreyTol", "int", "22", "Colour tolerance")
    _add("detScale", "Tools", "Detector", "OcrScale", "int", "3", "OCR scale",
         "Only used when Models reads the model by name.")

    _tool := "fanslyDetector", _grp := "Model detector (Fansly)"
    _add("fanWin", "Tools", "Fansly", "WinMatch", "text", "Fansly",
         "Window title has", "Restart the detector after changing anything here.")
    _add("fanPoll", "Tools", "Fansly", "PollMs", "int", "500", "Check every (ms)")
    _add("fanRows", "Tools", "Fansly", "Rows", "int", "3", "Cards on the rail")
    _add("fanPitch", "Tools", "Fansly", "RowPitch", "int", "116", "Card spacing (px)")
    _add("fanRowH", "Tools", "Fansly", "RowHeight", "int", "86", "Card height (px)")
    _add("fanCard", "Tools", "Fansly", "CardColor", "text", "0x2C2C2C", "Selected-card colour")
    _add("fanTol", "Tools", "Fansly", "CardTol", "int", "6", "Colour tolerance")
    _add("fanScale", "Tools", "Fansly", "OcrScale", "int", "4", "OCR scale",
         "Only used when Models reads the model by name.")

    _tool := "activity", _grp := "Activity tracker"
    _add("actIdle", "Tools", "Activity", "IdleMs", "int", "2000", "Idle after (ms)",
         "A pause longer than this stops the typing clock.")
    _add("actKeep", "Tools", "Activity", "KeepDays", "int", "0", "Keep logs (days)",
         "0 = keep everything.")
    _add("actRange", "Tools", "Activity", "Range", "int", "30", "Chart shows (days)")

    _tool := "tabMarks", _grp := "Tab bars"
    _add("mkVisible", "Tools", "Marks", "Visible", "bool", "1", "Show the bars")
    _add("mkW", "Tools", "Marks", "SepWidth", "int", "5", "Bar width (px)")
    _add("mkH", "Tools", "Marks", "SepHeight", "int", "36", "Bar height (px)")
    _add("mkCol", "Tools", "Marks", "SepColor", "text", "FF6B7A", "Bar colour (hex)")

    _tool := "clickWall", _grp := "Click wall"
    _add("cwHold", "Tools", "ClickWall", "HoldMaxMs", "int", "6000", "Hold a click at most (ms)",
         "A click held longer than this is dropped, never replayed late.")
    _add("cwVerify", "Tools", "ClickWall", "Verify", "bool", "1", "Check the chat list first")
    _add("cwWin", "Tools", "ClickWall", "WinMatch", "text", "Infloww Messages", "Window title has")

    ; Read every time the calculator recalculates — no restart. UsdToEur is
    ; overwritten by every successful live fetch; what is here is the fallback.
    _tool := "calc", _grp := "Payout calculator"
    _add("calcFees", "Tools", "Calculator", "Fees", "text", "0.97, 0.97", "Multiply by",
         "Comma separated; each is applied in turn.")
    _add("calcSub", "Tools", "Calculator", "Subtract", "text", "150", "Then subtract (EUR)")
    _add("calcRate", "Tools", "Calculator", "UsdToEur", "text", "0.91", "USD→EUR rate",
         "Updated from the live rate each time the calculator opens; used as is when it cannot fetch.")

    _tool := "recorder", _grp := "Coordinate recorder"
    _add("recSleep", "Tools", "Recorder", "DefaultSleep", "int", "500", "Pause between steps (ms)")

    _tool := "hotstrings", _grp := "Hotstrings manager"
    _add("hsFont", "Tools", "Hotstrings", "FontSize", "int", "11", "Font size")
    _add("hsOverload", "Tools", "Hotstrings", "OverloadMode", "choice", "ask",
         "A trigger with several texts",
         "The default for triggers that do not set their own.",
         [["ask", "Ask which one"], ["random", "Pick one at random"]])

    _tool := "discord", _grp := "Discord import"
    _add("dcX", "Tools", "Discord", "HeaderX", "int", "460", "Channel name left")
    _add("dcY", "Tools", "Discord", "HeaderY", "int", "42", "Channel name top")
    _add("dcW", "Tools", "Discord", "HeaderW", "int", "500", "Channel name width")
    _add("dcH", "Tools", "Discord", "HeaderH", "int", "38", "Channel name height")
    _grp := "MM Gatherer"
    _add("mmgLeft", "Tools", "Discord", "GatherLeft", "int", "460", "Messages start at x",
         "Right of the channel sidebar.")
    _add("mmgTop", "Tools", "Discord", "GatherTop", "int", "80", "Messages start at y",
         "Below the channel header.")
    _add("mmgRight", "Tools", "Discord", "GatherRight", "int", "260", "Trim from the right",
         "The member list. 0 if you hide it.")
    _add("mmgBottom", "Tools", "Discord", "GatherBottom", "int", "90", "Trim from the bottom",
         "The message box.")
    _add("mmgWheel", "Tools", "Discord", "GatherWheel", "int", "4", "Scroll per step (notches)")
    _add("mmgSettle", "Tools", "Discord", "GatherSettleMs", "int", "450", "Wait after a scroll (ms)")
    _add("mmgChars", "Tools", "Discord", "GatherMinChars", "int", "80", "A mass is at least (chars)")
    _add("mmgParas", "Tools", "Discord", "GatherMinParas", "int", "2", "A mass has paragraphs",
         "Or a ppv / !mm line.")
    _add("mmgDebug", "Tools", "Discord", "GatherDebug", "bool", "1", "Dump every screen read",
         "To debuglogs\mm_gatherer_frames.txt")

    ; Local AI: every AI tool's model and voice, in the services' own UTF-8 ini.
    _file := SETTINGS_LLM_INI
    _tool := "llm", _grp := "Local AI (Ollama)"
    _add("llmHost", "Tools", "Ollama", "Host", "text", "http://127.0.0.1:11434", "Ollama address")
    _add("llmModel", "Tools", "Ollama", "Model", "text", "mistral-nemo:12b", "Model",
         "Must fit in the GPU's memory, or it is many times slower.")
    _add("llmKeep", "Tools", "Ollama", "KeepAlive", "text", "30m", "Keep loaded for")
    _add("llmTimeout", "Tools", "Ollama", "TimeoutMs", "int", "300000", "Give up after (ms)")
    _add("llmCount", "Tools", "Draft", "Count", "int", "3", "Drafts per request")
    _add("llmTemp", "Tools", "Draft", "Temperature", "text", "0.9", "Draft temperature",
         "Higher is more varied, lower is safer.")
    _add("llmMax", "Tools", "Draft", "MaxTokens", "int", "80", "Draft length (tokens)")
    _add("llmPersona", "Tools", "Draft", "Persona", "text",
         "a flirty, playful adult creator talking to a paying fan", "Persona")
    _add("llmGModel", "Tools", "Grammar", "Model", "text", "mistral-nemo:12b", "Grammar model")
    _add("llmGTemp", "Tools", "Grammar", "Temperature", "text", "0.2", "Grammar temperature")
    _file := ""

    _tool := "", _grp := ""
    return f
}

; ─── Where a row's value lives ───────────────────────────────────────────────
;  Both front ends read and write every row through these two, so a row whose
;  home is another file (`file` above) needs nothing special from either of them.
;  `cfg` is the front end's own handle on mass_gui.cfg.
SETTINGS_Read(fld, cfg) {
    if (fld.file != "")
        return INI8_Read(fld.file, fld.iniSect, fld.iniKey, fld.def)
    return Trim(IniRead(cfg, fld.iniSect, fld.iniKey, fld.def))
}

SETTINGS_Write(fld, v, cfg) {
    if (fld.file != "")
        INI8_Write(fld.file, fld.iniSect, fld.iniKey, v)
    else
        IniWrite(v, cfg, fld.iniSect, fld.iniKey)
}

; The row for [iniSect] iniKey, or 0. By key rather than by id so that the Win32
; window, which builds its controls by hand, names the key it offers — the thing
; tools	est\settings_parity_test.ahk looks for.
SETTINGS_FieldFor(iniSect, iniKey) {
    for _, fld in SETTINGS_Fields()
        if (fld.iniSect = iniSect && fld.iniKey = iniKey)
            return fld
    return 0
}
