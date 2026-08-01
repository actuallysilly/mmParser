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
; ═══════════════════════════════════════════════════════════════════════════════
;  settings_window.ahk — every setting in MMA, in one window, on seven tabs.
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
    global openTabFu2, openTabFu3, openTabPpv, hiddenScripts, fastParseAutosave

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
                  ["Models", "Sending", "Features", "Scripts", "Hotkeys", "GUI",
                   "Debug"])
    ; Exported so a tab can be opened directly — `tab` itself is a local, and the
    ; only way in from outside was Ctrl+Tab, which needs the focus to be inside the
    ; control and silently does nothing when it is not. Setting .Value switches the
    ; page properly, which a TCM_SETCURSEL message does not: Tab3 swaps its pages
    ; off the control's notification, so a message-only switch lights the tab you
    ; asked for while still showing the previous page's controls.
    global SW_TAB := tab

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 1 — Models: who they are, and which one MMA thinks is on screen.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(1)
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
    ; Infloww has a tab strip the detector can read. Fansly is a different
    ; interface with nothing calibrated for it, and no reason to expect there ever
    ; will be for every site you work.
    ;
    ; Marking a model "manual" does two things: the shared keys fall back to it
    ; whenever Infloww is not in front (so your side buttons work on the other
    ; site), and its select key stops trying to record a tab position it does not
    ; have. Both are why this is per model rather than one global switch — a mixed
    ; setup is the normal case, not an edge case.
    sg.SetFont("s8 Bold")
    sg.Add("Text", "x" (CX + 76)  " y" y " w150", "NAME")
    sg.Add("Text", "x" (CX + 236) " y" y " w160", "PLATFORM")
    sg.SetFont("s9 Norm")
    y += 18

    _platItems := ["Infloww (detect)", "Manual (Fansly, …)"]
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
        _dp.Value := IsManualPlatform(_i) ? 2 : 1
        edModel.Push(_ed)
        ddlPlat.Push(_dp)
    }
    ; The tallest column decides where the rest of the tab starts.
    y := _yTop + _mcPer * 28
    y += 6

    sg.Add("Text", "x" CX " y" (y + 3) " w66 Right", "Wait time:")
    edWT := sg.Add("Edit", "x" (CX + 76) " y" y " w58", waitTime)
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 140) " y" (y + 6) " w" (CW - 148) " cGray",
           "ms — the pause between the parts of one send. Applied by rewriting"
         . " utils.ahk, so the mass engine restarts.")
    sg.SetFont("s9")
    y += 36

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Which model is on screen")
    sg.SetFont("s9 Norm")
    y += 22

    ; ── how the detector decides which model ──────────────────────────────────
    ; By NAME it OCRs the pill and matches it against [ActiveMap]. That survives you
    ; reordering your tabs, but only once the names are mapped, and the names are
    ; the fragile part — MMA, Infloww and Discord each have their own.
    ;
    ; By POSITION it uses where the lit tab SITS, matched against positions you
    ; taught it — click a tab, press that model's key, done. No OCR, no names, and
    ; nothing assumed about tab width or how many tabs there are. Counting tabs was
    ; tried and cannot work here: inactive tabs are drawn in the page background, so
    ; the tabs you are not on are not visible to a colour scan at all. The cost is
    ; that it trusts positions staying put — reorder your tabs and you re-teach.
    ;
    ; MANUALLY is the third option, and it reads no pixels at all: you press a
    ; [mass.select] key, MMA remembers, done. It exists because the first two fail
    ; the same way — not by going quiet, but by reporting the wrong tab with total
    ; confidence, at which point every shared key sends the wrong model's message to
    ; a real fan. When the detector cannot read your strip, this is what keeps the
    ; shared keys usable.
    sg.Add("Text", "x" CX " y" y " w130", "Decide which model by:")
    rdName := sg.Add("Radio", "x" (CX + 136) " y" y " Group", "name (OCR)")
    rdPos  := sg.Add("Radio", "x" (CX + 240) " y" y, "tab position (taught)")
    rdMan  := sg.Add("Radio", "x" (CX + 396) " y" y, "I pick")
    _mm := StrLower(Trim(IniRead(CFG_FILE, "Settings", "ModelMatch", "name")))
    if (_mm = "position")
        rdPos.Value := true
    else if (_mm = "manual")
        rdMan.Value := true
    else
        rdName.Value := true
    y += 28

    ; Which model "I pick" currently means. Editable here as well as by key, so the
    ; setting is never something you can only see by pressing something.
    sg.Add("Text", "x" CX " y" (y + 4) " w130", "I pick — active model:")
    _manItems := []
    Loop modelCount
        _manItems.Push(ModelLabel(A_Index))
    ddlManual := sg.Add("DropDownList", "x" (CX + 136) " y" y " w160", _manItems)
    _manCur := ManualModelNo()
    ddlManual.Value := (_manCur >= 1 && _manCur <= modelCount) ? _manCur : 1
    sg.SetFont("s8")
    sg.Add("Text", "x" (CX + 306) " y" (y + 4) " w" (CW - 314) " cGray",
           "switch with " HK_Key("mass.select.next"))
    sg.SetFont("s9")
    y += 32

    ; Tab order, left to right. Only consulted when nothing has been TAUGHT and the
    ; detector managed to separate the tabs, which on this UI it usually cannot.
    ; Kept because it costs nothing and is right on a theme where inactive tabs are
    ; visible.
    sg.Add("Text", "x" CX " y" (y + 4) " w130", "Tab order (left→right):")
    ddlPos := []
    _posItems := []
    Loop modelCount
        _posItems.Push(A_Index ": " ModelNameForSlot(A_Index))
    Loop modelCount {
        _p  := A_Index
        _dd := sg.Add("DropDownList", "x" (CX + 136 + (_p - 1) * 110) " y" y " w104", _posItems)
        _cur := LOG_IniInt(CFG_FILE, "Positional", "Pos" _p, _p, "settings")
        _dd.Value := (_cur >= 1 && _cur <= modelCount) ? _cur : _p
        ddlPos.Push(_dd)
    }
    y += 32

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
    y += 24
    sg.SetFont("s8")
    sg.Add("Text", "x" CX " y" y " w" CW " cGray",
           "Set the order by pointing: click a model's tab in Infloww, press that "
         . "model's key (" HK_Key("mass.select.m1") " / " HK_Key("mass.select.m2")
         . "). High beep = set, low beep = refused, tooltip says why.")
    y += 32
    sg.SetFont("s9")

    ; Two lines' worth of height: the "not running" wording is a sentence, and a
    ; Text control given one line's height simply clips the rest.
    lblDetector := sg.Add("Text", "x" CX " y" y " w" CW " h34", "")
    y += 40

    btnResetModels := sg.Add("Button", "x" CX " y" y " w130 h26", "Reset model fields")
    btnResetModels.OnEvent("Click", (*) => ResetModelFields())

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 2 — Sending: what goes out, and what happens after it does.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(2)
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
           "Alt follow-ups and --Name branches are one list on the follow-up key:"
         . " TAB moves through them, Shift+TAB goes back, Enter sends, Esc cancels."
         . " Switch the whole thing off under Features.")
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
    ;  Tab 3 — Features: the one place a feature is switched on or off.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(3)
    featPanel := FeaturesPanel(sg, CX, CY, CW)

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 4 — Scripts: what runs, what is visible, and what is up right now.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(4)
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

    sg.Add("Text", "x" CX " y" y " w" CW " h1 0x10")
    y += 12
    sg.SetFont("s9 Bold")
    sg.Add("Text", "x" CX " y" y " w" CW, "Visible scripts")
    sg.SetFont("s9 Norm")
    y += 22
    accChks := Map()
    ; Wraps at CW. It used to march right at a fixed 80px step with no wrap, so a
    ; sixth acc script simply left the window.
    _xSc := CX
    Loop Files, ACC_DIR "\*.ahk" {
        _fname := A_LoopFileName
        if (_xSc + 96 > CX + CW) {
            _xSc := CX
            y += 24
        }
        _chk := sg.Add("Checkbox", "x" _xSc " y" y " w92", StrReplace(_fname, ".ahk", ""))
        _chk.Value := !hiddenScripts.Has(_fname)
        accChks[_fname] := _chk
        _xSc += 96
    }
    y += 34

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

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 5 — Hotkeys: the editor that used to be its own process.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(5)
    hkPanel := HotkeysPanel(sg, CX, CY, CW, CH)

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 6 — GUI: what MMA looks like.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(6)
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
           "Applies when you press Save. The main window repaints straight away,"
         . " this window on its next open, and the follow-up picker on the next"
         . " follow-up key — nothing needs restarting. Buttons and list headers are"
         . " drawn by Windows and stay light whatever you pick here.")
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

    ; ═══════════════════════════════════════════════════════════════════════════
    ;  Tab 7 — Debug: the tools\ scripts, without going to find them in Explorer.
    ; ═══════════════════════════════════════════════════════════════════════════
    tab.UseTab(7)
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

    ; Colour the controls, now that all seven tabs' worth of them exist. Nothing to
    ; do on a light theme; on dark this is what stops the labels being black text
    ; on a black window. Rebuilt every time the window opens, so a theme change
    ; lands on the next open with nothing to notify it.
    THEME_ApplyTo(sg)

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
                . " pick `"I pick`" above and choose the model yourself."
        } catch {
            SetTimer(PaintServiceStatus, 0)
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
        global openTabFu2, openTabFu3, openTabPpv, hiddenScripts

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
            SetModelPlatform(_i, _dp.Value = 2 ? "manual" : "infloww")

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

        IniWrite(rdPos.Value ? "position" : rdMan.Value ? "manual" : "name",
                 CFG_FILE, "Settings", "ModelMatch")
        for _i, _dd in ddlPos
            IniWrite(_dd.Value ? _dd.Value : _i, CFG_FILE, "Positional", "Pos" _i)
        if ddlManual.Value
            SetManualModel(ddlManual.Value)

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
        ; processes — see core/theme.ahk), so writing the name IS the broadcast.
        ; The one window that cannot re-read on its own is the one already on
        ; screen, so it gets repainted here.
        _themePick := ""
        for _id, _rd in rdTheme
            if _rd.Value
                _themePick := _id
        if (_themePick != "") {
            IniWrite(_themePick, CFG_FILE, "Settings", "Theme")
            ApplyWindowTheme()
        }
        ; Read per picker build, so these two need no restart either.
        IniWrite(SW_Num(edAltW,    _IniInt(CFG_FILE, "Settings", "AltGuiWidth", 560), 260),
                 CFG_FILE, "Settings", "AltGuiWidth")
        IniWrite(SW_Num(edAltLift, _IniInt(CFG_FILE, "Settings", "AltGuiLift", 150), 0),
                 CFG_FILE, "Settings", "AltGuiLift")

        ; ── Scripts ───────────────────────────────────────────────────────────
        defaultHotkeyFile := ddlDef.Text
        IniWrite(defaultHotkeyFile, CFG_FILE, "Settings", "DefaultHotkeyFile")

        _hiddenList := ""
        for _fname, _chk in accChks
            if !_chk.Value
                _hiddenList .= (_hiddenList != "" ? "," : "") _fname
        hiddenScripts := Map()
        for _h in StrSplit(_hiddenList, ",")
            if (Trim(_h) != "")
                hiddenScripts[Trim(_h)] := true
        IniWrite(_hiddenList, CFG_FILE, "Settings", "HiddenScripts")

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

        ; Model count changes the whole layout of the main window, so it is the one
        ; setting that reloads MMA rather than applying in place.
        if (newCount != modelCount) {
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
        edWT.Value := "350"
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
