#Requires AutoHotkey v2.0
#Include "hotkeys_panel.ahk"
#Include "features_panel.ahk"
#Include "debug_panel.ahk"
; Its own include, not its host's. This file used THEME_WindowBg() while relying on
; main_window.ahk having included theme.ahk first — which worked in the app and
; broke settings_build_test.ahk, the one thing that builds this window on its own.
; A file that names a function includes the file that defines it; AHK loads any
; given file once, so saying so twice costs nothing.
#Include "../core/theme.ahk"
; Same reasoning as theme.ahk above: the Reply timers block on the General tab
; parses and previews tiers with RB_ParseTier / RB_CleanHex, and a file that names
; a function includes the file that defines it. reply_tiers.ahk is pure — no
; timers, no ini writes, nothing that runs at load — so it is safe to pull into a
; window process that will never paint a box itself.
#Include "../core/reply_tiers.ahk"
; And the same again for the Reply timers "Calibrate the list…" button, which
; draws its box with OcrSelectRegion. main_window.ahk happens to include this
; already, so the app worked without it — which is exactly the shape of the bug
; the theme.ahk comment above describes, and #Warn caught it here: "this local
; variable appears to never be assigned a value: OcrSelectRegion". AHK loads any
; given file once, so naming it twice costs nothing.
#Include "../screen/ocr_grab.ahk"
; And the dot scan, for "Calibrate a row…". Shared with screen/reply_box.ahk
; rather than reimplemented here, which is the whole point of that file existing —
; a calibrator that finds the dot its own way measures a row height the service
; will not agree with. See the header of reply_scan.ahk.
#Include "../screen/reply_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  settings_window.ahk — every setting in MMA, in one window, on eight tabs.
; ───────────────────────────────────────────────────────────────────────────────
;  This replaces three windows: Settings (one 570-line function producing a single
;  620px column you scrolled with your eyes), "Mode & features" behind a button
;  inside it, and the Hotkeys editor, which was a separate PROCESS.
;
;  ─── WHAT WAS ACTUALLY WRONG ─────────────────────────────────────────────────
;  Not just the length. Settings and Mode & features both wrote SIX of the same
;  cfg keys — MouseControl, FastParseAutosave, AutomationListener, Pinger,
;  AutoDetectModel, StatsOverlay. Each window read its checkboxes when it opened
;  and wrote all of them when it saved, so whichever you saved last won. Switch the
;  pinger on in one, press Save in the other, and it went back off with no error
;  and nothing to see.
;
;  So the tabs are not a re-skin, they are an ownership split:
;
;    Features  owns every on/off switch in the modes.ahk registry, and nothing else
;              writes those keys.
;    the rest  own the DETAIL of each feature — the region a thing reads, the text
;              it falls back to, the order of the tabs — and show the on/off state
;              read-only, with a pointer at the tab that owns it.
;
;  A setting therefore has exactly one control, in exactly one place.
;
;  ─── WHY THE HOTKEYS EDITOR MOVED IN ─────────────────────────────────────────
;  It was a window you launched, arranged and closed, to do a thing that is plainly
;  a setting. It is hotkeys_panel.ahk now, embedded here as a tab and reused by the
;  thin hotkeys_window.ahk for the case where the main GUI is not running.
; ═══════════════════════════════════════════════════════════════════════════════

; Layout. Two numbers to change if the window ever needs to grow, and the tab
; content follows because everything inside is placed from CX/CY.
global SW_W       := 980
global SW_H       := 720
global SW_MARGIN  := 8
global SW_BAR_H   := 48       ; the Save/Close strip along the bottom
global SW_INSET_X := 14       ; tab page inset, left and right
global SW_INSET_Y := 34       ; below the tab strip itself

OpenSettings(*) {
    global model1Name, model2Name, model3Name, modelCount, CFG_FILE, g
    global defaultHotkeyFile, ACC_DIR, SCRIPT_DIR, mouseControl, waitTime
    global startupScripts, autoRestart, walletCheckFu3
    global openTabFu2, openTabFu3, openTabPpv, fastParseAutosave
    global CODE_CMD

    CX := SW_MARGIN + SW_INSET_X                        ; content left edge
    CY := SW_MARGIN + SW_INSET_Y                        ; content top edge
    CW := SW_W - SW_MARGIN * 2 - SW_INSET_X * 2         ; content width
    CH := SW_H - SW_BAR_H - SW_MARGIN - CY              ; content height

    sg := Gui("+Owner" g.Hwnd " +Resize +MinSize900x600", "MMA Settings")
    ; Same theme as the main window. Read here rather than passed in, because this
    ; window is rebuilt every time it is opened — so it picks up a theme change on
    ; the next open with nothing to notify it.
    _sgBg := THEME_WindowBg()
    if (_sgBg != "")
        sg.BackColor := _sgBg
    ; Colour on the window font, before any control is added — the only way a
    ; label on a tab page ends up readable. See THEME_ApplyTo.
    sg.SetFont("s9" THEME_FontOpt(), "Segoe UI")

    ; The Background option is what actually colours this window. A Tab3 paints its
    ; own page interior, and that page covers everything but an 8px frame — so
    ; sg.BackColor alone changes a border you cannot see and nothing else, which is
    ; exactly how it looked when this was first tried.
    tab := sg.Add("Tab3", "x" SW_MARGIN " y" SW_MARGIN
                        . " w" (SW_W - SW_MARGIN * 2)
                        . " h" (SW_H - SW_BAR_H - SW_MARGIN * 2)
                        . (_sgBg != "" ? " Background" _sgBg : ""),
                  ["General", "Models", "Sending", "Features", "Scripts",
                   "Hotkeys", "GUI", "Debug"])
    ; Exported so a tab can be opened directly — `tab` itself is a local, and the
    ; only way in from outside was Ctrl+Tab, which needs the focus to be inside the
    ; control and silently does nothing when it is not. Setting .Value switches the
    ; page properly, which a TCM_SETCURSEL message does not: Tab3 swaps its pages
    ; off the control's notification, so a message-only switch lights the tab you
    ; asked for while still showing the previous page's controls.
    global SW_TAB := tab

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 1 — General: settings that belong to MMA itself rather than to one
    ;  feature. The wait time is the first of them, and it was on the Models tab
    ;  purely because that tab used to be "Settings" — it says nothing about a
    ;  model, and it sat between the model rows and the detector block, splitting
    ;  the one page you come here to read.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(1)
    y := CY

    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Timing")
    sg.SetFont("s9 Norm")
    y += 24

    sg.Add("Text", "x" CX " y" (y + 3) " w66 Right", "Wait time:")
    edWT := sg.Add("Edit", "x" (CX + 76) " y" y " w58", waitTime)
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 140) " y" (y + 6) " w" (CW - 148) " cGray",
           "ms — the pause between the parts of one send.")
    sg.SetFont("s9")
    y += 30
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "The one setting in MMA stored as SOURCE CODE rather than as config:"
         . " saving it rewrites the `waitTime` line in core\utils.ahk, which every"
         . " message script and the mass engine #Include — so the scripts restart"
         . " when you change it. Too low and Infloww misses keystrokes; too high"
         . " and every send drags.")
    sg.SetFont("s9")
    y += 56

    ; ── Reply timers ──────────────────────────────────────────────────────────
    ;  The thresholds and colours for screen/reply_box.ahk. They are HERE rather
    ;  than on a window of their own for the reason the Features rework exists: a
    ;  second window writing mass_gui.cfg is a second window that can disagree
    ;  with this one. General is the tab with the room, and a wait time in minutes
    ;  belongs next to a wait time in milliseconds.
    ;
    ;  Nothing in this block restarts anything. reply_box.ahk re-reads its cfg on
    ;  every full pass, so a colour or a threshold is live within PollMs — which
    ;  is why the note below can promise "a few seconds" rather than "on restart".
    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Reply timers")
    sg.SetFont("s9 Norm")
    y += 22
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Puts a coloured border round any conversation in the Infloww list that"
         . " is UNREAD and has been waiting longer than one of the times below."
         . " Replying clears the row's unread dot, so the box goes on its own —"
         . " nothing has to be dismissed.")
    sg.SetFont("s9")
    y += 34

    ; ── where the list is ─────────────────────────────────────────────────────
    ;  A rectangle on your screen, at your window size, on your monitor. There is
    ;  no default worth shipping, so an empty Region is a first-class state that
    ;  says so out loud instead of painting boxes over whatever is at 0,0.
    btnRbCal := sg.Add("Button", "x" CX " y" y " w150 h28", "Calibrate the list…")
    lblRbCal := sg.Add("Text", "x" (CX + 160) " y" (y + 6) " w" (CW - 160), "")
    btnRbCal.OnEvent("Click", CalibrateReplyList)
    y += 32
    ; The second measurement, and the one that decides whether a box covers the
    ; whole row or two-thirds of it. It is a separate button rather than part of
    ; the first because it asks for a different drag — one conversation, not the
    ; list — and because the list rarely changes while the row height changes with
    ; every zoom level.
    btnRbRow := sg.Add("Button", "x" CX " y" y " w150 h28", "Calibrate a row…")
    lblRbRow := sg.Add("Text", "x" (CX + 160) " y" (y + 6) " w" (CW - 160), "")
    btnRbRow.OnEvent("Click", CalibrateReplyRow)
    y += 36

    ; ── the tiers ─────────────────────────────────────────────────────────────
    ;  Five rows for four defaults, so adding one is filling in a blank rather
    ;  than editing the cfg by hand. A row with no minutes is not a tier — that is
    ;  how you delete one, and it is what the note says.
    ;
    ;  The swatch is a Progress bar, not a coloured Button. Windows draws buttons
    ;  itself and ignores a background colour, which this window's own GUI tab
    ;  says out loud; a Progress with a Background option is the one control that
    ;  will simply be a rectangle of a given colour.
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w120", "After (minutes)")
    sg.Add("Text", "x" (CX + 84) " y" y " w120", "Colour")
    sg.SetFont("s9")
    y += 18

    edRbMins := [], swRbCol := [], _rbCols := []
    Loop 5 {
        _i   := A_Index
        _raw := Trim(IniRead(CFG_FILE, "ReplyBox", "Tier" _i, ""))
        _t   := (_raw != "") ? RB_ParseTier(_raw) : 0
        _rbCols.Push(_t ? _t.col : "")
        edRbMins.Push(sg.Add("Edit", "x" CX " y" y " w52 Number",
                             _t ? _t.mins : ""))
        swRbCol.Push(sg.Add("Progress", "x" (CX + 60) " y" (y + 3) " w52 h18"
                                      . " Background" (_t ? _t.col : "808080"), 0))
        ; .Bind, not a closure over _i: one function body means one set of locals,
        ; so a closure would hand every row the last index in the loop. The same
        ; trap tools_window.ahk documents on its per-row buttons.
        _btn := sg.Add("Button", "x" (CX + 120) " y" y " w86 h24", "Colour…")
        _btn.OnEvent("Click", PickTierColour.Bind(_i))
        sg.SetFont("s8")
        sg.Add("Text", "x" (CX + 214) " y" (y + 5) " w" (CW - 214) " cGray",
               _i = 1 ? "the quiet band below this gets no box at all" : "")
        sg.SetFont("s9")
        y += 28
    }
    y += 6

    sg.Add("Text", "x" CX " y" (y + 3) " w96", "Row height:")
    edRbRowH := sg.Add("Edit", "x" (CX + 100) " y" y " w52 Number",
                       _IniInt(CFG_FILE, "ReplyBox", "RowH", 105))
    sg.Add("Text", "x" (CX + 166) " y" (y + 3) " w72", "Above dot:")
    ; -1 is the "nobody has measured this" sentinel, and showing it as a number
    ; you could edit invites someone to type -1 back and wonder why the box moved.
    ; Blank means the same thing and reads as what it is.
    _rbOffCur := _IniInt(CFG_FILE, "ReplyBox", "RowOffsetY", -1)
    edRbOff := sg.Add("Edit", "x" (CX + 240) " y" y " w52 Number",
                      _rbOffCur < 0 ? "" : _rbOffCur)
    sg.Add("Text", "x" (CX + 306) " y" (y + 3) " w52", "Border:")
    edRbBorder := sg.Add("Edit", "x" (CX + 362) " y" y " w52 Number",
                         _IniInt(CFG_FILE, "ReplyBox", "BorderW", 4))
    y += 30

    chkRbCapture := sg.Add("Checkbox", "x" CX " y" y " w" CW
                         . (_IniInt(CFG_FILE, "ReplyBox", "ExcludeFromCapture", 1)
                               ? " Checked" : ""),
                           "Keep the boxes out of screenshots")
    sg.SetFont("s8")
    lblRbFeat := sg.Add("Text", "x" (CX + 300) " y" (y + 2) " w" (CW - 300), "")
    sg.SetFont("s9")
    y += 26

    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "All in pixels. Row height is how tall one conversation is; 'above dot'"
         . " is how far the top of the box sits above the unread dot — the dot is"
         . " NOT in the middle of its row, so leaving this blank (halfway) draws"
         . " every box slightly high. Both are set for you by 'Calibrate a row…',"
         . " which is easier than measuring. Clear a tier's minutes to delete it."
         . " Saving applies within a few seconds; nothing restarts."
         . "  •  The screenshot box is on by default so MMA's own scan reads"
         . " Infloww and not its own borders — the cost is that the frames are"
         . " invisible to any screen capture. Untick it when you need a picture of"
         . " them, and avoid tier colours close to the unread coral while it is"
         . " off.")
    sg.SetFont("s9")

    PaintReplyBoxState()

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 2 — Models: who they are, and which one MMA thinks is on screen.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(2)
    y := CY

    ; A dropdown, not three radios. The radios were the count's own ceiling — one
    ; control per possible answer does not survive a twelfth model, and it was also
    ; the shape that made `newCount := rdMC1.Value ? 1 : rdMC2.Value ? 2 : 3` the
    ; only way to read it, which silently answers 3 when nothing is checked.
    sg.Add("Text", "x" CX " y" (y + 4) " w96", "Active models:")
    _mcItems := []
    Loop MASS_MODELS_MAX
        _mcItems.Push(String(A_Index))
    ddlMC := sg.Add("DropDownList", "x" (CX + 100) " y" y " w60", _mcItems)
    ddlMC.Value := (modelCount >= 1 && modelCount <= MASS_MODELS_MAX) ? modelCount : 3
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 232) " y" (y + 6) " w" (CW - 240) " cGray",
           "Changing this restarts MMA.")
    sg.SetFont("s9")
    y += 32

    ; ── name and platform, one row per model ──────────────────────────────────
    ; Which SITE this model is worked on: Infloww's tab strip or Fansly's rail,
    ; each read by its own detector. Per model rather than one global switch
    ; because a mixed setup is the normal case, not an edge case.
    ;
    ; There was a third option here, "Manual (you say)", and it is gone: that is
    ; not a site, it is a way of deciding which model is on screen — and that
    ; question already has its own setting further down this tab ("Decide which
    ; model by: I pick"). One question, one control. See ModelPlatform() in
    ; core/active_model.ahk for what an existing Platform<n>=manual now reads as.
    sg.SetFont("s8 Bold")
    sg.Add("Text", "x" (CX + 76)  " y" y " w150", "NAME")
    sg.Add("Text", "x" (CX + 236) " y" y " w160", "PLATFORM")
    sg.SetFont("s9 Norm")
    y += 18

    ; The dropdown's numeric Value is not what gets saved any more — the save maps
    ; it to a NAME. It used to be positional ("2 means manual"), which is what made
    ; removing the middle entry a data change rather than a layout one: every
    ; Fansly model would have silently become manual on the next Save.
    ; 1 = Infloww, 2 = Fansly.
    _platItems := ["Infloww (detect)", "Fansly (detect)"]
    edModel := []
    ddlPlat := []
    ; One row per model the user actually has, rather than three fixed rows with
    ; the unused ones greyed out. Past six they go into two columns: twelve rows at
    ; 28px is 336px of a 720px window, and it would have pushed the detector
    ; section — the part of this tab you come here to read — off the bottom.
    _mcRows := modelCount
    _mcCols := (_mcRows > 6) ? 2 : 1
    _mcPer  := Ceil(_mcRows / _mcCols)
    _mcColW := 420
    _yTop   := y
    Loop _mcRows {
        _i   := A_Index
        _col := (_i - 1) // _mcPer
        _row := Mod(_i - 1, _mcPer)
        _x   := CX + _col * _mcColW
        _ry  := _yTop + _row * 28
        sg.Add("Text", "x" _x " y" (_ry + 3) " w66 Right", "Model " _i ":")
        _ed := sg.Add("Edit", "x" (_x + 76) " y" _ry " w150",
                      _i <= modelNames.Length ? modelNames[_i] : "Model " _i)
        _dp := sg.Add("DropDownList", "x" (_x + 236) " y" _ry " w160", _platItems)
        ; ModelPlatform, not IsManualPlatform: the latter answers TRUE for a
        ; Fansly model whose detector is switched off, which is correct for
        ; routing and wrong for a dropdown — it would redraw the user's "Fansly"
        ; choice as something else and then save it that way.
        _dp.Value := (ModelPlatform(_i) = "fansly") ? 2 : 1
        edModel.Push(_ed)
        ddlPlat.Push(_dp)
    }
    ; The tallest column decides where the rest of the tab starts.
    y := _yTop + _mcPer * 28
    y += 6

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Use a single hotkey for all masses")
    sg.SetFont("s9 Norm")
    y += 20

    ; ── what this whole section is about ──────────────────────────────────────
    ; ONE key per action instead of one per action per model. The [mass.active]
    ; keys — follow-up 1, the PPV, next-follow-up — are shared: they send whatever
    ; the model you are working on has in that slot. The numbered keys
    ; ([mass.1.*], [mass.2.*]) are unaffected by every control below and keep
    ; working whatever this is set to; they are the fallback when this is off.
    ;
    ; Off, every shared key does nothing and says so in the log. That is a real
    ; answer, not a broken one: on a machine where nothing on screen identifies the
    ; model and you do not want a window in front of every keypress, the numbered
    ; keys ARE the interface.
    chkShared := sg.Add("Checkbox", "x" CX " y" y " w" CW,
                        "Enabled — the shared [mass.active] keys resolve to the"
                      . " model you are working on")
    chkShared.Value := _IniInt(CFG_FILE, "Settings", "SharedKeys", 1)
    y += 20
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 18) " y" y " w" (CW - 18) " cGray",
           "Off: the shared keys go quiet and only the numbered per-model keys"
         . " send. Applies to the next keypress — no restart.")
    sg.SetFont("s9")
    y += 26

    ; ── manual, or automatic ──────────────────────────────────────────────────
    ; MANUAL reads no pixels at all. The shared follow-up and PPV keys open the
    ; picker window and the send happens on your answer — so the model is never
    ; assumed, it is stated, once per send, in front of you. It exists because the
    ; automatic modes fail the same way: not by going quiet, but by reporting the
    ; wrong tab with total confidence, at which point a shared key sends one
    ; model's message to another model's fan.
    ;
    ; It used to be called "I pick", and it meant something narrower: a
    ; [mass.select] key named the model and MMA remembered it until you said
    ; otherwise — silent and blind, since nothing on screen said which model was
    ; remembered. The window replaced that (mass/model_picker.ahk). The remembered
    ; model still exists underneath, for the two shared keys that do not ask, and
    ; the picker and the select keys both write it — which is why there is no
    ; dropdown for it here any more. It is not a setting; it is a consequence.
    sg.Add("Text", "x" CX " y" (y + 2) " w96", "Strategy:")
    ; Consecutive, with Group on the first — see the theme radios on the GUI tab
    ; for what happens when a Text control is interleaved: Windows ends a radio
    ; group at the first control that is not a radio, so each one becomes a group
    ; of one and nothing ever unchecks anything.
    rdMan  := sg.Add("Radio", "x" (CX + 100) " y" y " Group",
                     "Manual — pick with the GUI")
    rdAuto := sg.Add("Radio", "x" (CX + 290) " y" y,
                     "Automatic — read the screen")
    _mm := StrLower(Trim(IniRead(CFG_FILE, "Settings", "ModelMatch", "name")))
    if (_mm = "manual")
        rdMan.Value := true
    else
        rdAuto.Value := true
    y += 26

    ; ── automatic, per site ───────────────────────────────────────────────────
    ; Two sites, two detectors, two answers — and they are NOT one setting. The
    ; Infloww tab strip and the Fansly rail share no scan, no config and no
    ; failure mode (core/fansly_model.ahk says why the defaults are opposite), and
    ; a mixed setup is the normal case here. The [Fansly] Match key has existed
    ; since the rail detector went in and this is the first control that writes
    ; it; before this it was a hand edit in mass_gui.cfg.
    ;
    ; BY NAME OCRs the label and matches it against the maps. Survives you
    ; reordering, but the names are the fragile part — MMA, Infloww and Discord
    ; each have their own, and Fansly's rail truncates them.
    ;
    ; BY POSITION uses where the lit tab or card SITS. No OCR, no names. The cost
    ; is that it trusts the order staying put: reorder, and you re-teach it by
    ; pointing (click the tab, press that model's key).
    sg.SetFont("s8 Bold")
    _lblAutoHdr := sg.Add("Text", "x" CX " y" y " w" CW,
                          "AUTOMATIC — HOW EACH SITE IS READ")
    sg.SetFont("s9 Norm")
    y += 20

    _autoCtrls := [_lblAutoHdr]              ; everything greyed out in manual mode

    ; OnlyFans, worked through Infloww — which is the window MMA actually reads,
    ; hence both names on the label.
    _lblOf := sg.Add("Text", "x" CX " y" (y + 2) " w130", "OnlyFans (Infloww):")
    rdOfName := sg.Add("Radio", "x" (CX + 136) " y" y " Group w110", "by name (OCR)")
    rdOfPos  := sg.Add("Radio", "x" (CX + 252) " y" y " w130", "by tab position")
    if (_mm = "position")
        rdOfPos.Value := true
    else
        rdOfName.Value := true
    _autoCtrls.Push(_lblOf, rdOfName, rdOfPos)
    y += 26

    ; Tab order, left to right: which model each tab index IS. The screen answers
    ; "which tab is lit"; this answers "which model that tab is", and no pixel on
    ; screen carries that fact.
    ;
    ; ── only the models that are ON this site ─────────────────────────────────
    ; Both rows used to offer every model and show one dropdown per model, on both
    ; sites. On a mixed setup that is a question with no right answer in it: "which
    ; model is Infloww tab 3" has no answer when only two of your models are worked
    ; in Infloww, and offering a Fansly model as the answer invites a mapping that
    ; sends a Fansly model's mass into an Infloww tab — silently, and to a real fan.
    ;
    ; So each row is built from the PLATFORM column above it: as many dropdowns as
    ; that site has models, each listing only those models. Rebuilt live from the
    ; Platform dropdowns rather than from the cfg, so switching a model to Fansly
    ; takes it out of the tab order in front of you, before Save — a control that
    ; only tells the truth after a save-and-reopen is how the old version could be
    ; read as correct.
    _lblOfOrd := sg.Add("Text", "x" (CX + 18) " y" (y + 4) " w118", "Tab order (left→right):")
    _autoCtrls.Push(_lblOfOrd)
    ddlPos := []
    ; Built at the widest they can ever need to be — one per model — and then hidden
    ; down to the count that is actually on this site. Creating them once means a
    ; platform change never has to re-lay-out the tab.
    Loop modelCount {
        _p  := A_Index
        _dd := sg.Add("DropDownList", "x" (CX + 136 + (_p - 1) * 110) " y" y " w104")
        ddlPos.Push(_dd)
        _autoCtrls.Push(_dd)
    }
    _lblOfNone := sg.Add("Text", "x" (CX + 136) " y" (y + 4) " w300 cGray",
                         "no models are set to Infloww")
    _autoCtrls.Push(_lblOfNone)
    y += 30

    _lblFan := sg.Add("Text", "x" CX " y" (y + 2) " w130", "Fansly:")
    rdFanName := sg.Add("Radio", "x" (CX + 136) " y" y " Group w110", "by name (OCR)")
    rdFanPos  := sg.Add("Radio", "x" (CX + 252) " y" y " w130", "by rail position")
    ; Position is the default on this platform, not name — the rail truncates its
    ; labels, so there is often no full name on screen to read at any OCR quality.
    if (FanslyMatchMode() = "name")
        rdFanName.Value := true
    else
        rdFanPos.Value := true
    _autoCtrls.Push(_lblFan, rdFanName, rdFanPos)
    y += 26

    ; [FanslyPos], not [Positional]. The rail's top-to-bottom order and the tab
    ; strip's left-to-right order are two different facts about two different
    ; windows, and they have no reason on earth to match.
    ;
    ; Filtered the same way, in the other direction: an Infloww model has no card on
    ; the Fansly rail, so it is not one of the answers here either.
    _lblFanOrd := sg.Add("Text", "x" (CX + 18) " y" (y + 4) " w118", "Rail order (top→bottom):")
    _autoCtrls.Push(_lblFanOrd)
    ddlFPos := []
    Loop modelCount {
        _p  := A_Index
        _dd := sg.Add("DropDownList", "x" (CX + 136 + (_p - 1) * 110) " y" y " w104")
        ddlFPos.Push(_dd)
        _autoCtrls.Push(_dd)
    }
    _lblFanNone := sg.Add("Text", "x" (CX + 136) " y" (y + 4) " w300 cGray",
                          "no models are set to Fansly")
    _autoCtrls.Push(_lblFanNone)

    ; Which model slots each row is offering, in the order the dropdowns show them.
    ; The save maps a dropdown's INDEX back through these — with a filtered list the
    ; index is no longer the model number, and that is exactly the kind of quiet
    ; off-by-one that would write "tab 1 = model 2" and look right on screen.
    _ordOf  := []
    _ordFan := []
    _SyncOrderRows(true)
    ; Live, so a platform change moves a model between the two rows immediately.
    for _dp in ddlPlat
        _dp.OnEvent("Change", _SyncOrderRowsEvent)
    y += 32

    ; Greyed rather than hidden, and greyed the moment you click rather than on
    ; Save. A control that is live but ignored is the shape of every "I set that
    ; and it did nothing" in this window's history — the OCR region you tune while
    ; the feature is off, the fallback text that is never sent. Manual mode reads
    ; no pixels, so every dropdown and radio above is inert; switching the section
    ; off makes even the strategy inert.
    chkShared.OnEvent("Click", (*) => _SyncModelCtrls())
    rdMan.OnEvent("Click",    (*) => _SyncModelCtrls())
    rdAuto.OnEvent("Click",   (*) => _SyncModelCtrls())
    _SyncModelCtrls()

    ; ── the live readout ──────────────────────────────────────────────────────
    ; Everything above is a setting you cannot check by looking at it, which is why
    ; the detector stayed wrong for so long without saying so: it answered "model 1"
    ; with total confidence and nothing on screen disagreed. This line is the
    ; disagreement. It shows the lit tab's x, which TAB INDEX that works out to, and
    ; which model the order above maps that index to.
    ;
    ; Read it in that order when something is off. "no lit tab" is a colour or
    ; region problem and no amount of reordering helps. A wrong tab NUMBER is
    ; TabOrigin/TabPitch. A right tab number pointing at the wrong model is the
    ; order — fix it in the dropdowns above, or by pointing at it with the keys.
    sg.Add("Text", "x" CX " y" y " w130", "Detector sees:")
    lblDetLive := sg.Add("Text", "x" (CX + 136) " y" y " w" (CW - 136), "")
    y += 22
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Set either order by pointing: click a model's tab in Infloww — or its"
         . " card on the Fansly rail — and press that model's key ("
         . HK_Key("mass.select.m1") " / " HK_Key("mass.select.m2") "). The key"
         . " knows which window is in front and teaches that one. High beep = set,"
         . " low beep = refused, tooltip says why.")
    y += 30
    sg.SetFont("s9")

    ; Two lines' worth of height: the "not running" wording is a sentence, and a
    ; Text control given one line's height simply clips the rest.
    lblDetector := sg.Add("Text", "x" CX " y" y " w" CW " h30", "")
    y += 34

    btnResetModels := sg.Add("Button", "x" CX " y" y " w130 h26", "Reset model fields")
    btnResetModels.OnEvent("Click", (*) => ResetModelFields())

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 3 — Sending: what goes out, and what happens after it does.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(3)
    y := CY

    sg.Add("Text", "x" CX " y" (y + 2) " w130", "Open new tab after:")
    chkTabFu2 := sg.Add("Checkbox", "x" (CX + 136) " y" y " w52", "FU2")
    chkTabFu3 := sg.Add("Checkbox", "x" (CX + 192) " y" y " w52", "FU3")
    chkTabPpv := sg.Add("Checkbox", "x" (CX + 248) " y" y " w52", "PPV")
    chkTabFu2.Value := openTabFu2
    chkTabFu3.Value := openTabFu3
    chkTabPpv.Value := openTabPpv
    y += 28

    chkWallet := sg.Add("Checkbox", "x" CX " y" y " w" CW, "Wallet check before FU3")
    chkWallet.Value := walletCheckFu3
    chkWallet.OnEvent("Click", (*) => _BroadcastWallet(chkWallet.Value ? 1 : 0))
    y += 24

    ; "Prompt for Alt-FUs using ctrl+hotkey" was here. It chose which of two keys
    ; offered the alternatives — and there is one key now, so there is nothing left
    ; to choose. The follow-up key stages every alt and every branch; TAB walks
    ; them, Enter sends the marked one, Esc cancels. A follow-up with no
    ; alternatives sends straight out and never stages.
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Every branch of a follow-up is one list on the follow-up key: TAB moves"
         . " through them, Shift+TAB goes back, Enter sends, Esc cancels. Branches"
         . " are written `::name text` in a paste and edited in Variants. Switch the"
         . " whole thing off under Features.")
    sg.SetFont("s9")
    y += 30

    ; The fallback for the picker window, and the reason it is phrased as an
    ; opt-OUT: the window is the fix, not the option. Ticking this goes back to
    ; previewing the variants inside the chat box, which is where they used to go —
    ; and where, if Infloww swallows the Ctrl+A that clears them, ENTER SENDS ALL
    ; OF THEM to the fan as one message. That is the bug the window removes, so the
    ; box is here as a way out if the window misbehaves, not as a preference.
    chkAltNoGui := sg.Add("Checkbox", "x" CX " y" y " w" CW,
                          "Don't use a GUI for alt FUs (preview in the chat box"
                        . " instead)")
    chkAltNoGui.Value := IniRead(CFG_FILE, "Settings", "AltStageNoGui", "0") = "1"
    y += 22
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "The chat-box preview can send every variant at once if Infloww ignores"
         . " the keystroke that clears it. Leave this unticked unless the picker"
         . " window itself gives you trouble.  Applies to the next follow-up key —"
         . " no restart.")
    sg.SetFont("s9")
    y += 34

    ; Not a saved setting: _doubleMM is session state, and the checkbox applies the
    ; moment it is clicked. It sits here rather than in Features because Features
    ; holds whether double-MM EXISTS, and this is whether it is on right now.
    chkDMM := sg.Add("Checkbox", "x" CX " y" y " w" CW,
                     "Double MM is on for this session (applies immediately, not saved)")
    chkDMM.Value := _doubleMM
    chkDMM.OnEvent("Click", (*) => (ToggleDoubleMM(), chkDMM.Value := _doubleMM))
    y += 30

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w150", "Default FU3")
    sg.SetFont("s9 Norm")
    ; The SWITCH stays in Features — that tab is the only writer of a feature key
    ; (see this file's header). But with no sign of it here, the field was
    ; indistinguishable from broken: you type a fallback, press Save, press f3 on
    ; a mass with no f3, and nothing goes out with nothing on screen to say why.
    ; So the state is echoed read-only, next to the thing it governs.
    _defFu3On := FEAT("defaultFu3")
    sg.SetFont("s8")
    _lblDefFu3 := sg.Add("Text", "x" (CX + 150) " y" (y + 4) " w" (CW - 150),
                         _defFu3On
                            ? Chr(0x25CF) " On — switch it off under Features"
                            : Chr(0x25CB) " Off — the text below is never sent."
                            . " Switch it on under Features.")
    _lblDefFu3.SetFont(_defFu3On ? "cGreen" : "cGray")
    sg.SetFont("s9")
    y += 22
    sg.Add("Text", "x" CX " y" y " w" CW,
           "Sent when the mass has no f3 at all — one message per line:")
    y += 20
    ; Left ENABLED even when the feature is off, deliberately: writing the
    ; fallback and then switching it on is the normal order to do this in.
    edDefFu3 := sg.Add("Edit", "x" CX " y" y " w" CW " h56 Multi WantReturn",
                       _DecodeMultiline(IniRead(CFG_FILE, "Settings", "DefaultFu3", "")))
    y += 62
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Leave blank for the old behaviour: an f3 key on a mass with no f3 does"
         . " nothing.")
    sg.SetFont("s9")
    y += 30

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w230", "Next follow-up  (" HK_Key("mass.active.nextFu") ")")
    sg.SetFont("s9 Norm")
    ; Same read-only echo as Default FU3 above, and for the same reason: every
    ; number in this section is inert while the feature is off, and tuning an OCR
    ; region that is never read is the worst way to spend an afternoon.
    _nextFuOn := FEAT("nextFu")
    sg.SetFont("s8")
    _lblNextFu := sg.Add("Text", "x" (CX + 230) " y" (y + 4) " w" (CW - 230),
                         _nextFuOn
                            ? Chr(0x25CF) " On — switch it off under Features"
                            : Chr(0x25CB) " Off — the key does nothing."
                            . " Switch it on under Features.")
    _lblNextFu.SetFont(_nextFuOn ? "cGreen" : "cGray")
    sg.SetFont("s9")
    y += 22
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "One key for the whole f1 → f2 → f3 walk. It OCRs the conversation, finds"
         . " the last follow-up already sent in it, and sends the one after — so it"
         . " is right per chat and per model, with nothing to remember.")
    y += 30
    sg.SetFont("s9")

    ; The pane it reads, in SCREEN coordinates. Defaults are automation.py's
    ; R_MESSAGES, the same measured rectangle its unsend flow reads, so the two
    ; agree about where the messages are. Wrong region is the failure everybody
    ; hits first, and it cannot announce itself — it just never finds a follow-up
    ; and always sends f1 — so the numbers belong somewhere you can see them.
    sg.Add("Text", "x" CX " y" (y + 3) " w130", "Chat region (screen):")
    _nfuLbl := ["x", "y", "w", "h"]
    _nfuKey := ["RegionX", "RegionY", "RegionW", "RegionH"]
    _nfuDef := [401, 135, 1237, 727]
    edNfu := Map()
    Loop 4 {
        _k := A_Index
        sg.Add("Text", "x" (CX + 136 + (_k - 1) * 90) " y" (y + 3) " w14", _nfuLbl[_k])
        _e := sg.Add("Edit", "x" (CX + 152 + (_k - 1) * 90) " y" y " w64",
                     _IniInt(CFG_FILE, "NextFu", _nfuKey[_k], _nfuDef[_k]))
        edNfu[_nfuKey[_k]] := _e
    }
    y += 30

    sg.Add("Text", "x" CX " y" (y + 3) " w130", "OCR scale:")
    edNfu["Scale"] := sg.Add("Edit", "x" (CX + 136) " y" y " w54",
                             _IniInt(CFG_FILE, "NextFu", "Scale", 1))
    sg.Add("Text", "x" (CX + 202) " y" (y + 3) " w80", "Match on:")
    edNfu["NeedleLen"] := sg.Add("Edit", "x" (CX + 268) " y" y " w54",
                                 _IniInt(CFG_FILE, "NextFu", "NeedleLen", 24))
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 328) " y" (y + 4) " w60 cGray", "chars, at")
    sg.SetFont("s9")
    edNfu["MinNeedle"] := sg.Add("Edit", "x" (CX + 386) " y" y " w54",
                                 _IniInt(CFG_FILE, "NextFu", "MinNeedle", 12))
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 446) " y" (y + 4) " w" (CW - 446) " cGray",
           "minimum. A follow-up shorter than the minimum is ignored rather than"
         . " matched — `"hey`" is in half the conversation.")
    sg.SetFont("s9")
    y += 34

    btnNfuTest := sg.Add("Button", "x" CX " y" y " w130 h26", "Test what it reads")
    btnNfuTest.OnEvent("Click", (*) => RunNextFuProbe())
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 140) " y" (y + 5) " w" (CW - 140) " cGray",
           "Opens the probe: switch to a chat that already has a follow-up in it,"
         . " press Ctrl+Alt+F10, and it reports what it read and which group it"
         . " would pick. Ctrl+Alt+F12 closes it.")
    sg.SetFont("s9")

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 4 — Features: the one place a feature is switched on or off.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(4)
    featPanel := FeaturesPanel(sg, CX, CY, CW)

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 5 — Scripts: what runs, what is visible, and what is up right now.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(5)
    y := CY

    _dhfList := []
    _genPath := MMA_CONTENT "\general.ahk"
    if FileExist(_genPath)
        _dhfList.Push("general.ahk")
    Loop Files, ACC_DIR "\*.ahk"
        _dhfList.Push(A_LoopFileName)

    sg.Add("Text", "x" CX " y" (y + 3) " w150", "New hotkeys go into:")
    ddlDef := sg.Add("DropDownList", "x" (CX + 156) " y" y " w180", _dhfList)
    for _i, _f in _dhfList
        if (_f = defaultHotkeyFile) {
            ddlDef.Value := _i
            break
        }
    if (ddlDef.Value = 0)
        ddlDef.Value := 1
    y += 34

    ; ── "Visible scripts" used to be here ─────────────────────────────────────
    ;  One checkbox per acc script, deciding which of them got a "◻ NAME" toggle
    ;  button on the main window's bottom strip. Both halves are gone: the strip
    ;  no longer carries those buttons, so a switch over which ones appear had
    ;  nothing left to switch. Restarting a message script that has stopped
    ;  responding is Hotstrings > Startup scripts now, which reads each script's
    ;  live state rather than trusting a button label.

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Run on startup")
    sg.SetFont("s9 Norm")
    y += 22
    startChks := Map()
    _startSet := Map()
    for _s in startupScripts
        _startSet[_s] := true
    _eligible := []
    if FileExist(_genPath)
        _eligible.Push("general.ahk")
    ; sequences.ahk is NOT offered here either, for the same reason as the engine.
    ; It was added to this list to fix "the Ctrl+click import stopped working" —
    ; but a checkbox was the wrong fix, and the import broke again twice more:
    ; once because the DEFAULT StartupScripts is "general.ahk" alone, so a fresh
    ; install never ticked it, and once because a box you can untick is a box that
    ; gets unticked. LaunchSequences() starts it unconditionally now, and it has no
    ; switch anywhere — the Features tab entry is gone too, because Easy mode turned
    ; that one off in bulk and killed the import a fourth time.
    ;
    ; The mass engine is deliberately NOT offered here. It is core, launched by
    ; LaunchEngine(); listing it would let one unticked box silently disable every
    ; mass hotkey, which is precisely how it went missing before.
    Loop Files, ACC_DIR "\*.ahk"
        _eligible.Push(A_LoopFileName)
    _sx := CX
    for _, _efn in _eligible {
        if (_sx + 100 > CX + CW) {
            _sx := CX
            y += 24
        }
        _chk := sg.Add("Checkbox", "x" _sx " y" y " w96", StrReplace(_efn, ".ahk", ""))
        _chk.Value := _startSet.Has(_efn)
        startChks[_efn] := _chk
        _sx += 100
    }
    y += 30

    chkAutoRestart := sg.Add("Checkbox", "x" CX " y" y " w" CW,
                             "Auto-restart these if they die (watchdog, checks every 5s)")
    chkAutoRestart.Value := autoRestart
    y += 32

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Background services")
    sg.SetFont("s9 Norm")
    y += 20
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Read-only. These are switched on and off in Features — that tab owns"
         . " them, so they cannot disagree with it here.")
    sg.SetFont("s9")
    y += 24

    ; id -> label, in the order they are painted. Kept as a list so the status
    ; painter below is one loop rather than four near-identical blocks — the shape
    ; the old window had, where adding the stats overlay meant adding a fifth copy.
    svcRows := [["automation",    "Automation listener (serves the [automation] hotkeys)"],
                ["pinger",        "Unread pinger (beeps when an Infloww tab goes unread)"],
                ["modelDetector", "Model detector (reads which model's tab is in front)"],
                ["statsOverlay",  "Stats overlay (toggle: " HK_Key("gui.toggleStats") ")"]]
    svcLbls := Map()
    for _, _row in svcRows {
        sg.Add("Text", "x" CX " y" y " w" (CW - 120), _row[2])
        svcLbls[_row[1]] := sg.Add("Text", "x" (CX + CW - 110) " y" y " w110", "")
        y += 22
    }
    y += 14

    btnWipe := sg.Add("Button", "x" CX " y" y " w110 h28", "Wipe TEMP.ahk")
    btnWipe.OnEvent("Click", (*) => (StopSettingsTimers(), sg.Destroy(), WipeTemp()))
    ; Always live, whatever the autoUpdate feature is set to — that switch only
    ; governs the automatic check at startup, and a manual "check now" that the
    ; switch could disable would be a button that silently does nothing.
    btnUpd := sg.Add("Button", "x" (CX + 120) " y" y " w110 h28", "Check update")
    btnUpd.OnEvent("Click", (*) => CheckUpdate())
    _autoUpd := FEAT("autoUpdate")
    sg.SetFont("s8")
    _lblAutoUpd := sg.Add("Text", "x" (CX + 240) " y" (y + 7) " w" (CW - 240),
                          _autoUpd
                             ? Chr(0x25CF) " Also checks at startup — switch that off under Features"
                             : Chr(0x25CB) " Startup check is off. This button always works;"
                             . " turn the startup check on under Features.")
    _lblAutoUpd.SetFont(_autoUpd ? "cGreen" : "cGray")
    sg.SetFont("s9")
    y += 38

    ; ── moved off the main window's bottom strip ──────────────────────────────
    ; Neither is something you press mid-shift: one opens an editor over the whole
    ; source tree, the other opens the manual in a browser. On the strip they sat
    ; between Settings and Add Hotkey, which ARE, so every real press had to read
    ; past them. They belong on the tab that already holds Wipe TEMP and Check
    ; update — the "things you do to MMA itself" row.
    btnCode := sg.Add("Button", "x" CX " y" y " w130 h28", "Open with Code")
    btnCode.OnEvent("Click",
        (*) => Run(Chr(34) CODE_CMD Chr(34) " " Chr(34) SCRIPT_DIR Chr(34)))
    btnGuide := sg.Add("Button", "x" (CX + 140) " y" y " w110 h28", "How to Use")
    btnGuide.OnEvent("Click", OpenGuide)
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 260) " y" (y + 7) " w" (CW - 260) " cGray",
           "Opens the whole MMA folder in VS Code, and docs\guide.html in your"
         . " browser.")
    sg.SetFont("s9")

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 6 — Hotkeys: the editor that used to be its own process.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(6)
    hkPanel := HotkeysPanel(sg, CX, CY, CW, CH)

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 7 — GUI: what MMA looks like.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(7)
    y := CY

    sg.SetFont("s10 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Theme")
    sg.SetFont("s9 Norm")
    y += 26
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Colours only — nothing here changes what MMA sends or which key does"
         . " what. It covers this window, the main window, and the follow-up"
         . " picker that appears over the chat.")
    sg.SetFont("s9")
    y += 32

    ; Built from THEME_List() rather than hard-coded, so adding a theme is one
    ; edit in core/theme.ahk and this tab grows a row on its own.
    ;
    ; ─── THE RADIOS ARE ADDED CONSECUTIVELY, AND THAT IS NOT A STYLE CHOICE ───
    ; Windows decides which radio buttons belong to one group by CREATION ORDER:
    ; a group runs from one radio until a control that is not a radio. Adding each
    ; radio followed by its description Text — the obvious way to write this —
    ; therefore put every radio in a group of its own, and a group of one never
    ; unchecks anything. All three themes could be selected at the same time, and
    ; Save then picked whichever it happened to find first.
    ;
    ; So the positions are worked out first, the radios go in as one run, and the
    ; descriptions are placed afterwards at the coordinates already reserved for
    ; them. Same layout, one group.
    themes := THEME_List()
    _rowY  := []
    for _t in themes {
        _rowY.Push(y)
        y += 46                    ; 20 for the radio, 26 for its note
    }
    rdTheme := Map()
    _curTheme := THEME_Name()
    for _i, _t in themes {
        ; Group on the first one states the intent rather than leaning on the
        ; automatic behaviour that caused the bug in the first place.
        _rd := sg.Add("Radio", "x" CX " y" _rowY[_i] " w" CW
                             . (_i = 1 ? " Group" : "")
                             . (_t.id = _curTheme ? " Checked" : ""), _t.label)
        rdTheme[_t.id] := _rd
    }
    sg.SetFont("s8")
    for _i, _t in themes
        sg.Add("Text", "x" (CX + 18) " y" (_rowY[_i] + 20) " w" (CW - 18) " cGray",
               _t.note)
    sg.SetFont("s9")

    y += 8
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Changing the theme RESTARTS MMA when you press Save — label colours and"
         . " the tab strip's accent are set when each control is created, so a"
         . " repaint alone would leave the window half in the old theme. Nothing is"
         . " lost by the restart except unsaved text in the mass fields. Buttons and"
         . " list headers are drawn by Windows and stay light whatever you pick.")
    sg.SetFont("s9")
    y += 44

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Follow-up picker size")
    sg.SetFont("s9 Norm")
    y += 24
    sg.Add("Text", "x" CX " y" (y + 3) " w130", "Width:")
    edAltW := sg.Add("Edit", "x" (CX + 136) " y" y " w64",
                     _IniInt(CFG_FILE, "Settings", "AltGuiWidth", 560))
    sg.Add("Text", "x" (CX + 210) " y" (y + 3) " w130", "Sits above bottom by:")
    edAltLift := sg.Add("Edit", "x" (CX + 346) " y" y " w64",
                        _IniInt(CFG_FILE, "Settings", "AltGuiLift", 150))
    y += 28
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Both in pixels at 100% display zoom — the width is scaled up on a"
         . " high-DPI screen so the window keeps its shape. The lift is how far"
         . " above the chat window's bottom edge the picker sits; raise it if it"
         . " covers your composer.")
    sg.SetFont("s9")
    y += 52

    ; ── TWO COLUMNS FROM HERE DOWN, AND WHY ───────────────────────────────────
    ;  This tab is a stack of one-line switches under multi-line grey notes, and
    ;  the stack ran off the bottom of the page: the "Corner picture" section below
    ;  was drawn under the Save strip, where it could not be read OR reached — a
    ;  Tab3 page does not scroll, so anything past the bottom edge is simply gone.
    ;
    ;  The notes were the space: each one had 936px of width and used two lines of
    ;  it. Side by side at half the width they run to five or six lines and still
    ;  cost less height than the two sections stacked, which is what buys the room.
    ;
    ;  Anything added to this tab from now on goes in a column, not on the end.
    _colW := (CW - 24) // 2
    _colR := CX + _colW + 24
    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    _rowTop := y

    ; ── left column: what the main window IS, and what its Load/Save looks like ─
    ;  The two radios pick which of the two front ends MMA.ahk starts — see
    ;  MMA_ShellPath in core\paths.ahk. They are added consecutively, for the same
    ;  reason the theme radios above are: a radio followed by anything else starts
    ;  its own group, and a group of one never unchecks the other.
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" _colW, "Main window")
    sg.SetFont("s9 Norm")
    _shellCur := Trim(IniRead(CFG_FILE, "Settings", "MainWindowShell", "legacy"))
    rdShellWin := sg.Add("Radio", "x" CX " y" (y + 22) " w150 Group"
                       . (_shellCur = "webview" ? "" : " Checked"), "Classic (Win32)")
    rdShellWeb := sg.Add("Radio", "x" (CX + 156) " y" (y + 22) " w150"
                       . (_shellCur = "webview" ? " Checked" : ""), "WebView (Edge)")
    chkLegacyLS := sg.Add("Checkbox", "x" CX " y" (y + 46) " w" _colW
                        . (_IniInt(CFG_FILE, "Settings", "LegacyLoadSaveUI", 0)
                              ? " Checked" : ""),
                          "Use the legacy Load/Save grid")
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 18) " y" (y + 68) " w" (_colW - 18) " cGray",
           "WebView draws the same window with Edge and CSS instead of sixty Win32"
         . " controls. It is still a PROTOTYPE: it does not start the mass engine,"
         . " the sequence watcher or your startup scripts, and it binds no hotkeys —"
         . " so pick Classic unless you are looking at the new one on purpose."
         . "  •  Legacy Load/Save: off gives ONE Load and ONE Save for the tab in"
         . " front of you; on gives the per-model grid, the only way to load a model"
         . " you are not looking at. Both settings restart MMA.")
    sg.SetFont("s9")

    ; ── right column: the archive's on/off switch ─────────────────────────────
    ; It was a tick box on the main window's button row, beside Parse — read once
    ; per parse, so it was a per-parse decision about something nobody decides per
    ; parse. Here it is a preference, and the row it vacated now holds the button
    ; that opens the archive.
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" _colR " y" y " w" _colW, "Mass archive")
    sg.SetFont("s9 Norm")
    chkArchiveParse := sg.Add("Checkbox", "x" _colR " y" (y + 24) " w" _colW
                            . (_IniInt(CFG_FILE, "Settings", "ArchiveOnParse", 1)
                                  ? " Checked" : ""),
                              "Archive every mass you Parse")
    sg.SetFont("s8")
    sg.Add("Text", "x" (_colR + 18) " y" (y + 46) " w" (_colW - 18) " cGray",
           "On (default): pressing Parse also appends the pasted mass to the"
         . " archive, which is what the 'Archive…' button on the main window"
         . " browses. A mass already archived TODAY is skipped rather than stored"
         . " twice — re-parsing after fixing a line does not grow the archive, and"
         . " nothing asks you about it. Takes effect on the next Parse; no reload."
         . (FEAT("archive") ? ""
                            : "   The Archive feature itself is switched OFF under"
                            . " Features, so nothing is archived either way."))
    sg.SetFont("s9")
    y := _rowTop + 132

    ; ── the picture in the main window's corner ───────────────────────────────
    ;  Both settings apply LIVE — see CREDIT_Refresh in credit.ahk. Nothing here
    ;  changes which controls the main window builds, so nothing here reloads MMA.
    ;
    ;  The list is every image in assets\decoration\ plus, when you have browsed to
    ;  one, the file you picked. A bare name is stored for anything inside that
    ;  folder and a full path for anything outside it, so moving the install does
    ;  not break the choice — see CREDIT_PickedPath.
    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 10
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Corner picture")
    sg.SetFont("s9 Norm")
    y += 22
    chkCredit := sg.Add("Checkbox", "x" CX " y" (y + 4) " w190"
                      . (_IniInt(CFG_FILE, "Settings", "CreditPicture", 1)
                            ? " Checked" : ""),
                        "Show her in the corner")
    _credCur   := Trim(IniRead(CFG_FILE, "Settings", "CreditImage", ""))
    ; The label spells out what "automatic" DOES, because the answer is not
    ; obvious from an empty value — and it says GIF first because that is the
    ; order CRED_FindFile searches in.
    _credItems := ["(automatic — an anime_girl GIF in assets\decoration\, else the PNG)"]
    for _f in CREDIT_AssetList()
        _credItems.Push(_f)
    ; A picked file from outside decoration\ is not in the list the folder produced, so
    ; it is appended — otherwise opening Settings would silently show "automatic"
    ; next to a picture that is nothing of the sort, and saving would then wipe the
    ; choice.
    if (_credCur != "" && (InStr(_credCur, "\") || InStr(_credCur, ":")))
        _credItems.Push(_credCur)
    ddlCredit := sg.Add("DropDownList", "x" (CX + 200) " y" y " w400", _credItems)
    _credPick := 1
    for _i, _it in _credItems
        if (_credCur != "" && _it = _credCur)
            _credPick := _i
    ddlCredit.Choose(_credPick)
    btnCredBrowse := sg.Add("Button", "x" (CX + 610) " y" (y - 2) " w100 h26",
                            "Browse" Chr(0x2026))
    btnCredBrowse.OnEvent("Click", BrowseCredit)
    y += 32
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" (CW - 8) " cGray",
           "Any GIF or PNG. An animated GIF plays; a still image just sits there."
         . " She is scaled to whatever space the buttons above her leave — a bigger"
         . " window gives her more — and she is never drawn over a control. Both"
         . " settings apply the moment you press Save; neither reloads MMA.")
    sg.SetFont("s9")

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 8 — Debug: the tools\ scripts, without going to find them in Explorer.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(8)
    DebugPanel(sg, CX, CY, CW, CH)

    tab.UseTab()

    ; ── the bottom strip, outside the tabs ────────────────────────────────────
    ; One Save for the whole window, including the Hotkeys tab. Two Saves that mean
    ; different amounts of "saved" is the confusion this rework exists to remove.
    _by := SW_H - SW_BAR_H + 8
    btnSave := sg.Add("Button", "x" SW_MARGIN " y" _by " w100 h30 Default", "Save")
    btnSave.OnEvent("Click", SaveCfg)
    btnClose := sg.Add("Button", "x" (SW_MARGIN + 108) " y" _by " w90 h30", "Close")
    btnClose.OnEvent("Click", (*) => CloseSettings())
    lblSaved := sg.Add("Text", "x" (SW_MARGIN + 210) " y" (_by + 8) " w" (SW_W - 230), "")

    ; Colour the controls, now that all eight tabs' worth of them exist. Nothing to
    ; do on a light theme; on dark this is what stops the labels being black text
    ; on a black window. Rebuilt every time the window opens, so a theme change
    ; lands on the next open with nothing to notify it.
    THEME_ApplyTo(sg)
    ; Bold button labels, on every theme — see THEME_BoldButtons. After the theme
    ; pass, and after all eight tabs exist, so it reaches the Debug tab's buttons
    ; and the Hotkeys panel's too.
    THEME_BoldButtons(sg)

    sg.OnEvent("Close", (*) => StopSettingsTimers())
    sg.OnEvent("Size", OnSettingsSize)

    ; The HWND as a plain INTEGER, captured while the window is alive.
    ;
    ; The timers below cannot ask `sg` whether `sg` still exists: Save and Wipe TEMP
    ; destroy it WITHOUT firing Close, and touching a destroyed Gui object throws.
    ; So a timer would keep firing every 400ms after you saved, throwing each time —
    ; a dialog per tick rather than one. A number survives the window it came from,
    ; so WinExist can answer honestly.
    _swHwnd := sg.Hwnd

    PaintDetectorLive()
    PaintServiceStatus()
    SetTimer(PaintDetectorLive, 400)
    SetTimer(PaintServiceStatus, 1500)

    ; Title bar only — the empty control list is deliberate. This window's client
    ; area is light, and DarkMode_Explorer on a control inside a light window gives
    ; you one dark box among twenty light ones. The archive window passes its list
    ; and edits here because that window IS dark; this one is not.
    try ArchiveDarkTheme(sg, [])
    sg.Show("w" SW_W " h" SW_H)
    return

    ; ── resize ────────────────────────────────────────────────────────────────
    ; Only the Hotkeys tab actually wants the extra room — its list is the window's
    ; whole point — so the tab control and the bottom strip follow the frame and the
    ; panel re-lays itself. The other tabs are lists of controls at fixed sizes;
    ; stretching them buys nothing.
    OnSettingsSize(gg, minMax, w, h) {
        if (minMax = -1)                  ; minimised
            return
        try {
            tab.Move(SW_MARGIN, SW_MARGIN, w - SW_MARGIN * 2, h - SW_BAR_H - SW_MARGIN * 2)
            hkPanel.Layout(CX, CY, w - SW_MARGIN * 2 - SW_INSET_X * 2,
                           h - SW_BAR_H - SW_MARGIN - CY)
            _y2 := h - SW_BAR_H + 8
            btnSave.Move(SW_MARGIN, _y2)
            btnClose.Move(SW_MARGIN + 108, _y2)
            lblSaved.Move(SW_MARGIN + 210, _y2 + 8, w - 230)
        }
    }

    ; ── Browse… for a picture outside assets\decoration\ ──────────────────────
    ; Adds the chosen file to the list and selects it. It is NOT copied into
    ; decoration\ and NOT written to the ini here — Save is the only writer, so
    ; backing out of this window leaves the setting exactly as it was.
    ;
    ; A file that IS in decoration\ collapses back to its bare name, so browsing to
    ; decoration\anime_girl1.gif and picking it from the list store the same thing.
    BrowseCredit(*) {
        f := FileSelect(3, MMA_DECOR "\", "Pick a picture for the corner",
                        "Images (*.gif; *.png; *.jpg; *.jpeg; *.bmp)")
        if (f = "")
            return
        if (SubStr(f, 1, StrLen(MMA_DECOR) + 1) = MMA_DECOR "\")
            f := SubStr(f, StrLen(MMA_DECOR) + 2)
        for _i, _it in _credItems
            if (_it = f) {
                ddlCredit.Choose(_i)
                return
            }
        _credItems.Push(f)
        ddlCredit.Add([f])
        ddlCredit.Choose(_credItems.Length)
    }

    ; ── Reply timers: calibrate, colour, and what the state line says ─────────

    ; Drag a box round the conversation list and store it in the Infloww window's
    ; CLIENT coordinates.
    ;
    ; Client, not screen, and that is the whole reason this is a button rather
    ; than four numbers you type: move or maximise Infloww and a screen rectangle
    ; is pointing at the desktop, while a client one comes with the window. Same
    ; call tab_marks.ahk makes about where a bar lives.
    ;
    ; The Settings window HIDES itself for the drag. It is a 980px window sitting
    ; over the thing you have been asked to draw a box around — without this you
    ; would be calibrating against MMA's own General tab, which is exactly what
    ; the first version let you do.
    CalibrateReplyList(*) {
        _win := Trim(IniRead(CFG_FILE, "ReplyBox", "WinMatch", "Infloww Messages"))
        if !WinExist(_win) {
            MsgBox("No window matching '" _win "' is open.`n`nOpen Infloww"
                 . " Messages first — the region is stored relative to that"
                 . " window, so it has to be there to measure against.",
                   "Reply timers", 0x30)
            return
        }
        sg.Hide()
        ; The overlay is drawn by the same code the OCR grab uses, so it inherits
        ; Escape, right-click and the 20-second give-up that stop a forgotten
        ; sheet locking the desktop. Sleep first: hiding a window is a request to
        ; the compositor, and grabbing before it has gone captures this window.
        Sleep 250
        _rect := OcrSelectRegion()
        sg.Show()
        if !_rect {
            LOGI("ui.replybox", "list calibration cancelled — the region is"
                              . " unchanged")
            return
        }
        _ccx := 0, _ccy := 0
        try WinGetClientPos(&_ccx, &_ccy, , , _win)
        catch as e {
            MsgBox("Could not read where '" _win "' is on screen, so the box you"
                 . " drew cannot be stored against it.`n`n" e.Message,
                   "Reply timers", 0x10)
            return
        }
        _cx := _rect.x - _ccx, _cy := _rect.y - _ccy
        ; A box drawn outside the window would store a negative offset that reads
        ; as valid and then grabs whatever is left of Infloww. Refuse it here,
        ; where there is somebody to tell.
        if (_cx < 0 || _cy < 0) {
            MsgBox("That box starts outside the '" _win "' window, so it cannot be"
                 . " stored relative to it.`n`nDraw the box inside the Infloww"
                 . " window, around the list of conversations.",
                   "Reply timers", 0x30)
            return
        }
        _reg := _cx "," _cy "," _rect.w "," _rect.h
        ; Written NOW rather than at Save, unlike everything else on this tab. The
        ; drag is the measurement — there is no control holding it to re-read on
        ; Save, and asking someone to press Save to keep a box they just drew is
        ; how a calibration gets lost. It also means the region lives in exactly
        ; one place, the cfg, which is what PaintReplyBoxState reads back.
        try IniWrite(_reg, CFG_FILE, "ReplyBox", "Region")
        LOGI("ui.replybox", "list region calibrated to " _reg
                          . " (client coords of '" _win "')")
        PaintReplyBoxState()
    }

    ; Drag a box round ONE conversation, and take both numbers off it.
    ;
    ; This exists because the two things the overlay needs about a row cannot be
    ; guessed from the list region: how TALL a row is, and where in it the unread
    ; dot sits. The first varies with zoom and DPI. The second is not "the middle"
    ; — on Infloww the dot shares a line with the timestamp, below the fan's name,
    ; so assuming halfway draws every box high by the difference.
    ;
    ; Both fall out of one drag. The height is the box you drew; the offset is
    ; where the dot turned out to be inside it, found with RBS_DotNearestCentre —
    ; the SAME scan screen/reply_box.ahk uses, which is the entire reason
    ; reply_scan.ahk is a separate file. A calibrator with its own copy would
    ; report an offset measured against its own idea of the dot, and the service
    ; would then draw against a different one.
    ;
    ; It writes to the CONTROLS, not to the cfg, unlike the list calibration
    ; above. These two are ordinary numbers with edit boxes sitting right there,
    ; so the measurement should land where you can see it, sanity-check it and
    ; still back out by closing without saving. The region has no such control —
    ; that is why it is the one that writes immediately.
    CalibrateReplyRow(*) {
        _win := Trim(IniRead(CFG_FILE, "ReplyBox", "WinMatch", "Infloww Messages"))
        if !WinExist(_win) {
            MsgBox("No window matching '" _win "' is open.`n`nOpen Infloww"
                 . " Messages first.", "Reply timers", 0x30)
            return
        }
        sg.Hide()
        Sleep 250
        _rect := OcrSelectRegion()
        sg.Show()
        if !_rect {
            LOGI("ui.replybox", "row calibration cancelled")
            return
        }
        ; Grab a little wider than the box drawn, so the dot band is inside it
        ; even when the drag stopped short of the list's right edge. The dot is
        ; ~20px in from that edge and nobody drags to the pixel.
        _d    := RBS_Defaults()
        _band := _IniInt(CFG_FILE, "ReplyBox", "DotBandW", _d.band)
        _gw   := Max(_rect.w, _band + 8)
        _img  := PILL_Grab(_rect.x + _rect.w - _gw, _rect.y, _gw, _rect.h)
        _dot  := _img ? RBS_DotNearestCentre(_img, _RbDotOpts(_d)) : 0
        if !_dot {
            MsgBox("No unread dot was found inside that box.`n`nThe row height is"
                 . " measured from the box, but the second number — where the dot"
                 . " sits inside the row — has to be read off a real one. Draw the"
                 . " box round a conversation that IS unread (one with the little"
                 . " orange dot on the right), and include that dot.",
                   "Reply timers", 0x30)
            return
        }
        _h   := _rect.h
        _off := _dot.cy - _rect.y
        edRbRowH.Value := _h
        edRbOff.Value  := _off
        LOGI("ui.replybox", "row calibrated: height " _h "px, dot " _off "px below"
                          . " the top — press Save to keep it")
        PaintReplyBoxState()
    }

    ; The dot-scan options as the overlay reads them, defaulted from RBS_Defaults
    ; so this window and the service cannot fall back to different numbers.
    _RbDotOpts(d) {
        _hex := RB_CleanHex(IniRead(CFG_FILE, "ReplyBox", "DotColor", "FF7C71"))
        _col := 0xFF7C71
        if (_hex != "")
            try _col := Integer("0x" _hex)
        return {color: _col,
                tol:   Max(0, _IniInt(CFG_FILE, "ReplyBox", "DotTol",   d.tol)),
                band:  Max(8, _IniInt(CFG_FILE, "ReplyBox", "DotBandW", d.band)),
                step:  Max(1, Min(4, _IniInt(CFG_FILE, "ReplyBox", "DotStep", d.step))),
                minPx: Max(1, _IniInt(CFG_FILE, "ReplyBox", "DotMinPx", d.minPx)),
                maxPx: Max(1, _IniInt(CFG_FILE, "ReplyBox", "DotMaxPx", d.maxPx)),
                maxH:  Max(2, _IniInt(CFG_FILE, "ReplyBox", "DotMaxH",  d.maxH)),
                gap:   Max(1, _IniInt(CFG_FILE, "ReplyBox", "DotGap",   d.gap))}
    }

    ; The system colour dialog for one tier, from core/theme.ahk — the same one
    ; the tab bars use. Cancelling leaves the swatch alone.
    PickTierColour(idx, *) {
        if (idx > _rbCols.Length)
            return
        _start := (_rbCols[idx] != "") ? _rbCols[idx] : "FFD24A"
        _picked := THEME_ChooseColour(_start, "FFD24A")
        if (_picked = "")
            return
        _rbCols[idx] := _picked
        ; Opt() rather than rebuilding the control: a Progress takes its colour
        ; from an option string it will accept at any time.
        try swRbCol[idx].Opt("Background" _picked)
        try WinRedraw(sg)
    }

    ; The one line that says whether this feature can do anything at all, and the
    ; note beside the border width saying whether it is switched on.
    ;
    ; Two SEPARATE facts, deliberately. "Calibrated but the feature is off" and
    ; "on but never calibrated" are both states people reach, and a single
    ; combined message would have to guess which one you are in.
    ; The region is re-READ from the cfg rather than kept in a variable up in the
    ; build. CalibrateReplyList already writes it there the moment the box is
    ; drawn, so the cfg is the single copy — and a nested function assigning to an
    ; enclosing local is the one closure behaviour in AHK v2 that is worth not
    ; relying on.
    PaintReplyBoxState() {
        try {
            _cur := Trim(IniRead(CFG_FILE, "ReplyBox", "Region", ""))
            if (_cur = "") {
                lblRbCal.SetFont("cRed")
                lblRbCal.Value := "Not calibrated — nothing is painted until you"
                                . " draw a box round the conversation list."
            } else {
                _p := StrSplit(_cur, ",")
                lblRbCal.SetFont("cGreen")
                lblRbCal.Value := "Region set: " (_p.Length >= 3 ? _p[3] : "?") "x"
                                . (_p.Length >= 4 ? _p[4] : "?") " at "
                                . (_p.Length >= 1 ? _p[1] : "?") ","
                                . (_p.Length >= 2 ? _p[2] : "?")
                                . " inside the Infloww window."
            }
            ; Read off the CONTROLS, not the cfg — CalibrateReplyRow writes there
            ; and Save is what commits, so this has to describe what you are
            ; looking at rather than what is still on disk.
            _rh  := Trim(edRbRowH.Value)
            _rof := Trim(edRbOff.Value)
            if (_rof = "") {
                lblRbRow.SetFont("cGray")
                lblRbRow.Value := "Row " (_rh = "" ? "?" : _rh) "px, dot assumed"
                                . " halfway — boxes will sit slightly high."
            } else {
                lblRbRow.SetFont("cGreen")
                lblRbRow.Value := "Row " _rh "px, dot " _rof "px below the top."
            }
            ; FEAT_Raw, not FEAT: the Features tab may be about to turn this on in
            ; the same Save, and FEAT answers false for everything in Easy mode,
            ; which would make this line read "off" for a reason it does not name.
            lblRbFeat.SetFont(FEAT_Raw("replyBox") ? "cGreen" : "cGray")
            lblRbFeat.Value := FEAT_Raw("replyBox")
                ? Chr(0x25CF) " Reply timers are ON."
                : Chr(0x25CB) " OFF — switch on under Features."
        }
    }

    ; ── the live detector readout ─────────────────────────────────────────────
    ; Scans the strip ITSELF, and deliberately does NOT require Infloww to be the
    ; active window — because reading this line means MMA is the active window, so a
    ; focus-gated readout could only ever say "nothing on screen". That is exactly
    ; what the first version did, which made the one diagnostic useless.
    ;
    ; Safe to skip the gate here precisely because it only DISPLAYS. The resolver
    ; keeps the gate, since it acts on the answer.
    PaintDetectorLive() {
        if !SW_Alive(_swHwnd) {
            SetTimer(PaintDetectorLive, 0)
            return
        }
        ; Belt as well as braces: the window can be destroyed BETWEEN the check
        ; above and the control write below, and a throw on a timer thread is a
        ; dialog every 400ms rather than one.
        try {
            ; The same cheap slot sampling the hotkeys use, NOT a full band sweep —
            ; a sweep is ~1000 GDI GetPixel calls and would make this 400ms timer
            ; stutter the whole window. It also means what you read here is
            ; literally what the keys will decide, not a second opinion.
            cfg  := DetectorCfg()
            t    := TabLitIndex(cfg)
            slot := (t.index >= 1) ? TabModel(t.index) : 0

            px := ""
            for _i, _c in t.counts
                px .= (px = "" ? "" : "  ") "tab" _i ":" _c

            ; Two different facts, and conflating them is what made this line read
            ; as a contradiction ("tab 2 → Rama (Infloww not in front)"):
            ;
            ;   what the STRIP shows  — this readout ignores focus deliberately, or
            ;                           you could never read it: looking at Settings
            ;                           means Infloww is not focused.
            ;   what the KEYS will do — asked of the resolver itself, so it accounts
            ;                           for the focus gate AND the mixed-platform
            ;                           fallback. Nothing here re-derives that; a
            ;                           second opinion is how a readout starts
            ;                           disagreeing with reality.
            st := ActiveModelStatus()
            lblDetLive.Value := px
                              . "   |   " (t.index < 1 ? "no tab lit" : "tab " t.index)
                              . "   |   " (slot ? "→ " ModelLabel(slot) : "→ no answer")
                              . "   |   keys → "
                              . (st.no
                                 ? ModelLabel(st.no)
                                     (DetectorWindowUp(cfg) ? "" : "  (manual)")
                                 : "nothing"
                                     (DetectorWindowUp(cfg) ? "" : "  — Infloww not focused"))
        } catch {
            SetTimer(PaintDetectorLive, 0)
        }
    }

    ; Reads the live PROCESSES, not the settings — they disagree whenever something
    ; was toggled from the main window, or died on its own. That disagreement is the
    ; only reason this readout is worth having.
    PaintServiceStatus() {
        if !SW_Alive(_swHwnd) {
            SetTimer(PaintServiceStatus, 0)
            return
        }
        try {
            up := Map("automation",    AutomationListenerRunning(),
                      "pinger",        PingerRunning(),
                      "modelDetector", DetectorRunning(),
                      "fanslyDetector", FanslyDetectorRunning(),
                      "statsOverlay",  StatsOverlayRunning())
            for _id, _lbl in svcLbls {
                _lbl.SetFont(up[_id] ? "cGreen" : "cGray")
                _lbl.Text := up[_id] ? "● running" : "○ not running"
            }
            ; The detector's light lives on the Models tab too, beside the settings
            ; that decide what it reads — that is where you are standing when it is
            ; wrong.
            lblDetector.SetFont(up["modelDetector"] ? "cGreen" : "cGray")
            lblDetector.Text := up["modelDetector"]
                ? "● Model detector is running."
                : "○ Model detector is not running — switch it on in Features, or"
                . " set the strategy above to Manual and pick the model in the"
                . " window."
        } catch {
            SetTimer(PaintServiceStatus, 0)
        }
    }

    ; ── which of the Models tab's controls are live right now ─────────────────
    ; Called on every click of the three controls that decide it, and once while
    ; the window is being built. Enabled is the outer switch: with the shared keys
    ; off, the strategy is a choice about nothing. Manual is the inner one: it
    ; reads no pixels, so every automatic control below it is inert.
    ;
    ; Nothing here writes. The greying describes what Save will mean, and the user
    ; can still change their mind before pressing it.
    _SyncModelCtrls(*) {
        on   := chkShared.Value ? true : false
        auto := on && rdAuto.Value
        rdMan.Enabled  := on
        rdAuto.Enabled := on
        for _c in _autoCtrls
            _c.Enabled := auto
    }

    ; ── the two order rows, filtered by platform ──────────────────────────────
    ;  Which models are on Infloww is answered by the Platform column at the top of
    ;  this tab, LIVE — the dropdowns there, not the cfg — so a model switched to
    ;  Fansly leaves the tab order before you save, and vice versa.
    ;
    ;  `seed` true means "read the saved order"; false means "keep what is on screen".
    ;  A platform change must not throw away a mapping you have just set for the
    ;  other four models.
    _SyncOrderRows(seed := false) {
        prevOf  := _ordOf,  prevFan := _ordFan
        _ordOf  := _PlatSlots("infloww")
        _ordFan := _PlatSlots("fansly")
        _FillOrderRow(ddlPos,  _ordOf,  prevOf,  "Positional", seed)
        _FillOrderRow(ddlFPos, _ordFan, prevFan, "FanslyPos",  seed)
        ; The label belongs to the row, so it goes when the row has nothing to ask.
        _lblOfOrd.Visible   := _ordOf.Length  > 0
        _lblOfNone.Visible  := _ordOf.Length  = 0
        _lblFanOrd.Visible  := _ordFan.Length > 0
        _lblFanNone.Visible := _ordFan.Length = 0
    }

    ; Write one order row back. Positions this site does not have are written as 0,
    ; not left alone: PositionalSlot reads 0 as "no answer" and the shared keys then
    ; do nothing, while a stale `Pos3=3` from before a model moved to Fansly would
    ; keep claiming that a third lit tab is model 3 — a confident wrong answer, which
    ; is the expensive kind here (ARCHITECTURE.md §4.8).
    _SaveOrderRow(dds, slots, section) {
        for _i, _dd in dds {
            if (_i > slots.Length) {
                IniWrite(0, CFG_FILE, section, "Pos" _i)
                continue
            }
            _v := _dd.Value
            IniWrite((_v && _v <= slots.Length) ? slots[_v] : slots[Min(_i, slots.Length)],
                     CFG_FILE, section, "Pos" _i)
        }
    }

    ; A named handler rather than a lambda on five dropdowns: the Change event hands
    ; the control and the item along, and _SyncOrderRows' first parameter is `seed` —
    ; wired straight up, a platform change would arrive as seed=<the dropdown> and
    ; re-read the cfg over the top of everything on screen.
    _SyncOrderRowsEvent(*) {
        _SyncOrderRows(false)
    }

    ; The model slots on one site, in model order, read from the Platform dropdowns.
    _PlatSlots(want) {
        out := []
        for _i, _dp in ddlPlat
            if ((_dp.Value = 2 ? "fansly" : "infloww") = want)
                out.Push(_i)
        return out
    }

    ; One row: `slots` dropdowns, each offering `slots`, and the rest hidden.
    _FillOrderRow(dds, slots, prevSlots, section, seed) {
        ; What each dropdown is pointing at right now, as a MODEL number, before the
        ; items are replaced underneath it.
        keep := []
        for _k, _dd in dds {
            _v := _dd.Value
            keep.Push((_v && _v <= prevSlots.Length) ? prevSlots[_v] : 0)
        }
        items := []
        for _s in slots
            items.Push(_s ": " ModelNameForSlot(_s))
        for _k, _dd in dds {
            if (_k > slots.Length) {
                _dd.Visible := false
                continue
            }
            _dd.Delete()
            _dd.Add(items)
            want := seed ? LOG_IniInt(CFG_FILE, section, "Pos" _k, 0, "settings")
                         : keep[_k]
            idx := 0
            for _j, _s in slots
                if (_s = want)
                    idx := _j
            ; Identity as the fallback — the k-th position is the k-th model on this
            ; site — which is right on a fresh install and harmless once taught.
            _dd.Value := idx ? idx : Min(_k, slots.Length)
            _dd.Visible := true
        }
    }

    ; Every path that closes this window has to stop every timer it started, and
    ; "every" is why this is one function rather than a line per timer at each call
    ; site — the detector readout was added with its stop wired only to Close, which
    ; Save and Wipe TEMP do not fire.
    StopSettingsTimers(*) {
        SetTimer(PaintDetectorLive, 0)
        SetTimer(PaintServiceStatus, 0)
    }

    CloseSettings(*) {
        if (hkPanel.HasUnsaved()
            && MsgBox("Discard unsaved hotkey changes?", "Unsaved", 0x24) != "Yes")
            return
        StopSettingsTimers()
        sg.Destroy()
    }

    ; ── save ──────────────────────────────────────────────────────────────────
    SaveCfg(*) {
        global model1Name, model2Name, model3Name, modelCount, CFG_FILE, waitTime
        global defaultHotkeyFile, startupScripts, autoRestart
        global openTabFu2, openTabFu3, openTabPpv

        ; Features first, so everything below sees the state it is about to run in.
        featChanged := featPanel.Changed()
        featPanel.Apply()

        ; The dropdown's index IS the count — 1-based list of 1..MASS_MODELS_MAX.
        ; A 0 (nothing selected) would write a count of 0 and leave the panel with
        ; no tabs at all, so it falls back to what is already in force.
        newCount := ddlMC.Value ? ddlMC.Value : modelCount
        Loop edModel.Length {
            _i := A_Index
            IniWrite(edModel[_i].Value, CFG_FILE, "Settings", "Model" _i)
            if (_i <= modelNames.Length)
                modelNames[_i] := edModel[_i].Value
        }
        ; Kept in step for the code that still reads them by name (the archive, the
        ; main panel's own globals). They are views onto modelNames now.
        model1Name := modelNames.Length >= 1 ? modelNames[1] : ""
        model2Name := modelNames.Length >= 2 ? modelNames[2] : ""
        model3Name := modelNames.Length >= 3 ? modelNames[3] : ""
        IniWrite(newCount, CFG_FILE, "Settings", "ModelCount")
        for _i, _dp in ddlPlat
            SetModelPlatform(_i, _dp.Value = 2 ? "fansly" : "infloww")

        ; waitTime lives in utils.ahk as a literal, so saving it rewrites that file.
        ; The mass engine reads it at load, which is why this one needs a restart —
        ; handled at the end, together with every other reason to restart.
        _newWait  := SW_Num(edWT, waitTime, 50)
        waitChanged := (_newWait != waitTime)
        waitTime  := _newWait
        ; ── the riskiest write in the app, now guarded ────────────────────────
        ; This REWRITES core/utils.ahk, a source file every message script and the
        ; engine #Include. It was unguarded, and failed two ways:
        ;
        ;   1. FileRead throws (file missing, locked by antivirus, permissions) →
        ;      the throw escapes the Save handler, so EVERY SETTING BELOW THIS
        ;      LINE never saves. ModelMatch, the tab order, the open-in-new-tab
        ;      boxes, the wallet check — silently discarded, while the settings
        ;      above this line did save. Half-saved is worse than not saved.
        ;   2. FileOpen(…, "w") TRUNCATES FIRST. A failure between the truncate
        ;      and the write leaves utils.ahk empty, which breaks every message
        ;      script and the engine at once.
        ;
        ; Both are contained here: the write goes to a temp file and is MOVED into
        ; place (the pattern store.ahk and archive.ahk already use for exactly this
        ; reason), and the whole thing is scoped so a failure costs you the wait
        ; time and nothing else.
        if waitChanged
            SW_SaveWaitTime(waitTime)
        UpdateModelButtons()

        ; ── the reply-timer tiers ─────────────────────────────────────────────
        ; Rewritten whole, because deleting a tier is a RENUMBER: clearing row 2's
        ; minutes has to leave Tier1, Tier2, Tier3 contiguous, or RB_Tiers stops
        ; at the gap and silently drops every tier below it. So the surviving rows
        ; are collected first and written back from 1, and the rest of the range
        ; is deleted rather than left behind.
        ;
        ; The Region is NOT written here — CalibrateReplyList writes it when the
        ; box is drawn. See the comment there for why.
        _kept := []
        for _i, _ed in edRbMins {
            _m := Trim(_ed.Value)
            if (_m = "" || !RegExMatch(_m, "^\d+$"))
                continue                          ; blank row = no tier
            _c := (_i <= _rbCols.Length) ? _rbCols[_i] : ""
            if (_c = "")
                continue                          ; never had a colour picked
            _kept.Push({mins: Integer(_m), col: _c})
        }
        RB_SortTiers(_kept)
        for _i, _t in _kept
            IniWrite(_t.mins "," _t.col, CFG_FILE, "ReplyBox", "Tier" _i)
        ; Clear the tail. The five rows on the tab are the ceiling for what this
        ; window can write, but a hand-edited cfg may hold more, so the delete
        ; runs past them — cheap, and it is what makes "clear a row to delete the
        ; tier" true rather than nearly true.
        _i := _kept.Length + 1
        while (_i <= 32) {
            try IniDelete(CFG_FILE, "ReplyBox", "Tier" _i)
            _i++
        }
        ; Clamped to the same bounds RB_Cfg enforces, so a typed 0 is corrected
        ; here — where it is visible on the next open — rather than silently in
        ; the overlay, where the box would just look wrong.
        _rbH := Max(8, SW_Num(edRbRowH, 104, 8))
        IniWrite(_rbH, CFG_FILE, "ReplyBox", "RowH")
        IniWrite(Max(1, Min(24, SW_Num(edRbBorder, 4, 1))),
                 CFG_FILE, "ReplyBox", "BorderW")
        ; Blank means "nobody has measured this", which the overlay stores as -1
        ; and reads as "assume halfway". Clamped to the row so a hand-typed 900
        ; cannot hang the box entirely above the dot it was drawn for.
        _rbOffTxt := Trim(edRbOff.Value)
        IniWrite(_rbOffTxt = "" ? -1 : Max(0, Min(_rbH, SW_Num(edRbOff, 0, 0))),
                 CFG_FILE, "ReplyBox", "RowOffsetY")
        IniWrite(chkRbCapture.Value ? 1 : 0,
                 CFG_FILE, "ReplyBox", "ExcludeFromCapture")
        LOGI("ui.replybox", _kept.Length " reply-timer tier(s) saved; row " _rbH
                          . "px, offset " (_rbOffTxt = "" ? "auto" : _rbOffTxt))

        ; ── the shared keys ───────────────────────────────────────────────────
        ; All four of these are read per keypress, so they apply to the next key
        ; you press with no restart and no broadcast.
        IniWrite(chkShared.Value ? 1 : 0, CFG_FILE, "Settings", "SharedKeys")

        ; Two controls, one key — and the key keeps the three values it has always
        ; had, so nothing downstream changes. Manual is still "manual"; automatic
        ; is whichever of name/position the OnlyFans radios say, because that key
        ; has only ever described the Infloww side. Fansly's equivalent is its own
        ; key in its own section, which is what lets a mixed setup read each site
        ; the way that site can actually be read.
        IniWrite(rdMan.Value ? "manual" : rdOfPos.Value ? "position" : "name",
                 CFG_FILE, "Settings", "ModelMatch")
        IniWrite(rdFanName.Value ? "name" : "position", CFG_FILE, "Fansly", "Match")
        ; The dropdowns list only the models on that site, so the selected INDEX is
        ; not the model number any more — it is a position in _ordOf / _ordFan. The
        ; save has to go back through the same list the row was built from, or "tab 1
        ; = the second Infloww model" would be written as "tab 1 = model 2" and be
        ; wrong on any setup where model 1 is not on Infloww.
        _SaveOrderRow(ddlPos,  _ordOf,  "Positional")
        _SaveOrderRow(ddlFPos, _ordFan, "FanslyPos")

        ; ── Sending ───────────────────────────────────────────────────────────
        openTabFu2 := chkTabFu2.Value ? 1 : 0
        openTabFu3 := chkTabFu3.Value ? 1 : 0
        openTabPpv := chkTabPpv.Value ? 1 : 0
        IniWrite(openTabFu2, CFG_FILE, "Settings", "OpenTabFu2")
        IniWrite(openTabFu3, CFG_FILE, "Settings", "OpenTabFu3")
        IniWrite(openTabPpv, CFG_FILE, "Settings", "OpenTabPpv")
        IniWrite(chkWallet.Value ? 1 : 0, CFG_FILE, "Settings", "WalletCheckFu3")
        ; Read per follow-up key by AltStageUseGui(), so this needs no broadcast and
        ; no restart either — the next press picks it up.
        IniWrite(chkAltNoGui.Value ? 1 : 0, CFG_FILE, "Settings", "AltStageNoGui")
        ; The model scripts re-read this on every f3 press, so no broadcast and no
        ; restart — saving is enough.
        IniWrite(_EncodeMultiline(edDefFu3.Value), CFG_FILE, "Settings", "DefaultFu3")

        ; Next follow-up. Read per keypress, so these apply with no restart at all.
        for _key, _ed in edNfu
            IniWrite(SW_Num(_ed, _IniInt(CFG_FILE, "NextFu", _key, 0)),
                     CFG_FILE, "NextFu", _key)

        ; ── GUI ───────────────────────────────────────────────────────────────
        ; Every window reads the theme from the cfg for itself (they are separate
        ; processes — see core/theme.ahk), so writing the name IS the broadcast for
        ; the picker and the overlays.
        ;
        ; The MAIN window is the one that cannot fully re-read: repainting reaches
        ; its background and its inputs, but not the colours baked into controls at
        ; creation — the label ink (THEME_FontOpt on the window font) and the tab
        ; strip's accent. So a repaint left the window half in the new theme, which
        ; looks like the theme is broken rather than like it needs a restart.
        ; Changing it therefore reloads MMA, the same as the model count.
        _themePick := ""
        for _id, _rd in rdTheme
            if _rd.Value
                _themePick := _id
        ; Read BEFORE the write, or the comparison is against what was just saved
        ; and every theme change looks like no change at all.
        _themeChg := (_themePick != "" && _themePick != THEME_Name())
        if (_themePick != "") {
            IniWrite(_themePick, CFG_FILE, "Settings", "Theme")
            ; Still repainted, because the reload below is not instant and a window
            ; that keeps the old background for a second reads as a save that did
            ; nothing.
            ApplyWindowTheme()
        }
        ; Read per picker build, so these two need no restart either.
        IniWrite(SW_Num(edAltW,    _IniInt(CFG_FILE, "Settings", "AltGuiWidth", 560), 260),
                 CFG_FILE, "Settings", "AltGuiWidth")
        IniWrite(SW_Num(edAltLift, _IniInt(CFG_FILE, "Settings", "AltGuiLift", 150), 0),
                 CFG_FILE, "Settings", "AltGuiLift")

        ; Which load/save layout the main window builds. It decides which CONTROLS
        ; exist, not how they look, so it cannot apply in place — the panel is built
        ; once at startup. Same treatment as the model count below: write it, then
        ; reload, which is honest about what is happening rather than leaving the
        ; checkbox ticked next to the layout it does not describe.
        _legacyLS  := chkLegacyLS.Value ? 1 : 0
        _legacyChg := (_legacyLS != _IniInt(CFG_FILE, "Settings", "LegacyLoadSaveUI", 0))
        IniWrite(_legacyLS, CFG_FILE, "Settings", "LegacyLoadSaveUI")

        ; Which front end MMA.ahk starts. Read before the write, like the theme, or
        ; the comparison is against what was just saved.
        _shellPick := rdShellWeb.Value ? "webview" : "legacy"
        _shellChg  := (_shellPick != Trim(IniRead(CFG_FILE, "Settings",
                                                  "MainWindowShell", "legacy")))
        IniWrite(_shellPick, CFG_FILE, "Settings", "MainWindowShell")

        ; No reload and no global to keep in step: ParseCurrent reads this key at
        ; the moment it parses, so the next Parse already obeys it.
        IniWrite(chkArchiveParse.Value ? 1 : 0, CFG_FILE, "Settings", "ArchiveOnParse")

        ; ── the corner picture ────────────────────────────────────────────────
        ; Written, then applied in place: CREDIT_Refresh reloads the file and
        ; RelayoutNow puts her back at whatever size now fits. Item 1 of the list
        ; is "automatic", which is stored as an EMPTY value rather than as its own
        ; label — the label is a sentence, and a sentence in the ini would be read
        ; back as a file name.
        _credWas := Trim(IniRead(CFG_FILE, "Settings", "CreditImage", ""))
                  . "|" _IniInt(CFG_FILE, "Settings", "CreditPicture", 1)
        IniWrite(chkCredit.Value ? 1 : 0, CFG_FILE, "Settings", "CreditPicture")
        IniWrite(ddlCredit.Value > 1 ? ddlCredit.Text : "",
                 CFG_FILE, "Settings", "CreditImage")
        if (_credWas != Trim(IniRead(CFG_FILE, "Settings", "CreditImage", ""))
                      . "|" _IniInt(CFG_FILE, "Settings", "CreditPicture", 1)) {
            CREDIT_Refresh()
            RelayoutNow()
        }

        ; ── Scripts ───────────────────────────────────────────────────────────
        defaultHotkeyFile := ddlDef.Text
        IniWrite(defaultHotkeyFile, CFG_FILE, "Settings", "DefaultHotkeyFile")

        _startupCsv := ""
        for _efn, _chk in startChks
            if _chk.Value
                _startupCsv .= (_startupCsv != "" ? "," : "") _efn
        IniWrite(_startupCsv, CFG_FILE, "Settings", "StartupScripts")
        startupScripts := []
        for _s in StrSplit(_startupCsv, ",")
            if (Trim(_s) != "")
                startupScripts.Push(Trim(_s))
        autoRestart := chkAutoRestart.Value ? 1 : 0
        IniWrite(autoRestart, CFG_FILE, "Settings", "AutoRestart")
        SetTimer(WatchdogTick, autoRestart ? 5000 : 0)
        LaunchStartupScripts()

        ; ── Hotkeys ───────────────────────────────────────────────────────────
        hkCount := hkPanel.Save()

        ; ── apply ─────────────────────────────────────────────────────────────
        ; A hotkey is registered at BIND time, so a feature switched off keeps its
        ; key until its script reloads — restarting is what makes the change real.
        ; Only when something actually changed, though: restarting the mass engine
        ; because you edited the default FU3 text would kill a send in flight.
        if (featChanged || waitChanged)
            ApplyModeToRunning()

        ; Switching front ends is NOT a Reload: Reload restarts the script that is
        ; running, which is the one you just chose to stop using. So the running
        ; window's children are torn down and MMA.ahk is started again — it re-reads
        ; MainWindowShell and opens the other one, which then launches whatever it
        ; launches. Going through the launcher rather than Running the shell path
        ; here keeps ONE place that decides which window MMA is.
        if (_shellChg) {
            StopSettingsTimers()
            sg.Destroy()
            KillAllScripts()
            Run '"' A_AhkPath '" "' MMA_ROOT '\MMA.ahk"'
            ExitApp
        }

        ; Model count, the load/save layout and the theme all change what the main
        ; window builds rather than how it behaves, so these are the settings that
        ; reload MMA instead of applying in place.
        if (newCount != modelCount || _legacyChg || _themeChg) {
            modelCount := newCount
            StopSettingsTimers()
            sg.Destroy()
            Reload
            return
        }

        _msg := "Saved."
        if hkCount
            _msg .= "  " hkCount " hotkey(s) applied live."
        if (featChanged || waitChanged)
            _msg .= "  Scripts restarted."
        lblSaved.SetFont("cGreen")
        lblSaved.Text := _msg
        SetTimer(ClearSavedMsg, -4000)
    }

    ClearSavedMsg() {
        try lblSaved.Text := ""
    }

    ; Puts the model rows back to stock. Only the CONTROLS — nothing is written
    ; until Save, so this is undone by closing the window.
    ResetModelFields(*) {
        Loop edModel.Length
            edModel[A_Index].Value := "Model " A_Index
        ; The wait time used to be reset here as well, back when it sat on this
        ; tab. It is on General now, and a button on the Models tab reaching over
        ; to change a field on another tab — one the user cannot see it touch — is
        ; exactly the kind of reach this window was rebuilt to remove.
        ;
        ; The COUNT is deliberately left alone. Resetting it to 2 while the panel
        ; behind this window has eight tabs open would be a reset that hides six
        ; models, from a button labelled "Reset model fields".
    }
}

; Does this window still exist?
;
; IsWindow, not WinExist("ahk_id " h). WinExist consults DetectHiddenWindows, which
; is a per-thread setting owned by whoever included this file — main_window.ahk
; happens to switch it on, so WinExist answers correctly THERE and answers "gone"
; anywhere else for a window that merely has not been shown yet. Both painters run
; once before sg.Show(), so under the wrong ambient setting they would switch their
; own timer off at birth and the readouts would stay blank forever.
;
; The question being asked is about a window handle, not about visibility, and
; IsWindow is that question exactly.
SW_Alive(hwnd) {
    return DllCall("IsWindow", "Ptr", hwnd, "Int")
}

; What a numeric field means when it holds something that is not a number.
;
; Integer("") and Integer("12px") both THROW, and every one of these is a plain
; Edit the user can type anything into. Unguarded, one stray character aborts Save
; halfway through — after the model names are written and before the hotkeys are,
; which is the worst possible place to stop. Fall back to what the field had.
SW_Num(ctrl, fallback, min := 0) {
    try
        return Max(min, Integer(Trim(ctrl.Value)))
    catch
        return fallback
}

; Write the new waitTime into core/utils.ahk, where it lives as a literal.
;
; The only setting in MMA that is stored as SOURCE CODE rather than as config, so
; it is the only save that can break the app by succeeding partially. Three things
; keep that contained:
;
;   • temp file + FileMove, so utils.ahk is either the old version or the new one
;     and never a truncated one. FileOpen(…, "w") on the real path truncates
;     before writing, which is how an interrupted save empties a file that every
;     message script and the engine #Include.
;   • the replacement is verified to have actually matched before anything is
;     written. RegExReplace returns the input UNCHANGED when the pattern misses,
;     so renaming or reformatting that line in utils.ahk would otherwise make this
;     silently write the file back identical and report success, and the wait time
;     would just never change — with the Settings field showing the new value.
;   • it returns false rather than throwing, so a failure costs the wait time and
;     leaves the rest of Save to finish.
SW_SaveWaitTime(ms) {
    path := MMA_SRC_UTILS
    LOGD("settings.wait", "writing waitTime=" ms " into " _LOG_BaseName(path))

    body := ""
    try {
        body := FileRead(path, "UTF-8")
    } catch as e {
        LOGE("settings.wait", "could not read utils.ahk — the wait time was NOT"
                            . " saved. Every other setting still was.", LOG_Err(e))
        return false
    }

    ; `hits`, not `n` — some script in the tree has a global by that name, and a
    ; local shadowing a global is a #Warn warning in every file that includes both.
    updated := RegExReplace(body, "\bwaitTime\b\s*:=\s*\d+", "waitTime     := " ms, &hits)
    if (!hits) {
        LOGE("settings.wait", "could not find the `waitTime := <number>` line in"
                            . " utils.ahk — the wait time was NOT saved and the file"
                            . " was left alone",
                            "has that line been renamed or reformatted? " path)
        return false
    }

    tmp := path ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8")
        if !f
            throw Error("could not open " tmp " for writing")
        f.Write(updated)
        f.Close()
        FileMove(tmp, path, true)
    } catch as e {
        try FileDelete(tmp)
        LOGE("settings.wait", "could not write utils.ahk — the wait time was NOT"
                            . " saved. utils.ahk is untouched.", LOG_Err(e))
        return false
    }
    LOG_Ok("settings.wait", "utils.ahk now has waitTime := " ms
                          . " (" hits " occurrence(s) replaced); the engine picks it"
                          . " up on its next restart")
    return true
}

; The probe is a tool, not a feature: it binds Ctrl+Alt+F10, reports, and exits. Run it
; rather than reimplementing the read here, so what you are shown is what the key
; itself would see — a second implementation would drift and then lie.
RunNextFuProbe() {
    p := MMA_ROOT "\tools\nextfu_probe.ahk"
    if !FileExist(p) {
        MsgBox "tools\nextfu_probe.ahk is missing.", "Next follow-up", 0x10
        return
    }
    try
        Run(p)
    catch as e
        MsgBox "Could not start the probe.`n`n" e.Message, "Next follow-up", 0x10
}
