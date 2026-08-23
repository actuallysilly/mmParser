#Requires AutoHotkey v2.0
#Include "../core/hotkeys.ahk"
; theme.ahk, because this file now NAMES THEME_Set() and THEME_Accent() — the dark
; pass over the list and the accent rule on the capture overlay. Same rule
; settings_window.ahk states at its own top: a file that names a function includes
; the file that defines it, so it can still be parsed on its own. AHK loads any
; given file once, so saying it again in a window that already pulled theme.ahk
; costs nothing.
#Include "../core/theme.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_panel.ahk — the hotkey editor, as a panel that can live in any window.
; ───────────────────────────────────────────────────────────────────────────────
;  A VIEW over hotkeys.ini; it never owns the values. Save() writes the ini and
;  broadcasts HK_MSG_RELOAD, so running scripts pick changes up live. Editing the
;  ini by hand is just as valid — "Open hotkeys.ini" is right there.
;
;  ─── WHY A PANEL AND NOT A WINDOW ────────────────────────────────────────────
;  This was a whole separate PROCESS: its own Gui, its own #SingleInstance, its own
;  Save and Close. That is one more window to find, arrange and close for a thing
;  that is plainly a setting — and it made "settings" mean three windows that each
;  wrote mass_gui.cfg and hotkeys.ini with no idea the others existed.
;
;  Everything here is instance state on the class rather than script globals, which
;  is what makes embedding possible at all: the old file kept `g`, `lv`, `dirty`
;  and `pending` at the top level, and main_window.ahk already has a `g` and an
;  `lv` of its own. Two of those in one process is not a merge conflict, it is a
;  script that will not load.
;
;  ─── THE LIST IS REBUILT ON EVERY EDIT, AND THAT USED TO COST YOUR PLACE ─────
;  Changing one key calls Fill(), and Fill() deletes every row and adds them back —
;  which is the only honest way to redraw, since one edit can change the conflict
;  column of a row thirty lines further down. But a ListView that has been emptied
;  scrolls itself to the top and forgets what was selected, so assigning a key to
;  the last hotkey in the list threw you back to the first one and you had to find
;  your place again. Every edit.
;
;  That is what Fill(keepView) and RestoreView() are for: the row is remembered BY
;  ID — not by index, which the filter changes under you — and the scroll position
;  by its top row, and both are put back after the rebuild.
;
;  NoSort belongs to the same bug. A ListView sorts itself when a column header is
;  clicked, `lvIds` stays in insertion order, and from that click on every button
;  acted on a different row than the highlighted one. The list is grouped by
;  feature, so there was never a sort worth having: it is switched off rather than
;  tracked.
;
;  ─── SUSPENDING WHILE CAPTURING ──────────────────────────────────────────────
;  Press F1 to assign it and F1 must not also send model 1's follow-up, so every
;  MMA script holds fire during a capture. Embedded, "every script" now includes
;  the one this panel is running inside — which is correct (the GUI has its own
;  hotkeys) but also nearly fatal: the mouse-button capture works by registering
;  temporary hotkeys, and a suspended script has no live hotkeys to capture with.
;
;  Hence the S option on those temporary keys: suspend-exempt, so the capture keeps
;  working while everything it is protecting you from stays held. Verified against
;  AutoHotkey 2.0.26, including registering one WHILE already suspended.
; ═══════════════════════════════════════════════════════════════════════════════

; Set by the capture hotkeys, read by HKP_GrabKey. Script-level rather than
; instance state because a Hotkey() callback has no `this` — and there is only
; ever one capture in flight, since the overlay is modal in practice.
global _HKP_GRABBED  := ""
global _HKP_GRABMODS := ""

class HotkeysPanel {
    ; The "Show" dropdown. Compared by INDEX in Matches(), so the wording here is
    ; free to change without touching the filter.
    static VIEWS := ["Everything", "Changed only", "Clashes only", "Not assigned"]

    ; Two glyphs in the narrow first column, and one on a group row. Chr() rather
    ; than the literal characters, the same way settings_window.ahk writes its
    ; bullets — this file is read and edited far more than it is looked at.
    static MARK_EDIT   := Chr(0x25CF)     ; ● edited here, not saved yet
    static MARK_CUSTOM := Chr(0x25CB)     ; ○ saved, but not the default
    static MARK_GROUP  := Chr(0x25BE)     ; ▾ a feature heading, not a hotkey

    ; hostGui   — the Gui to build into. When it is a Tab3 page, the caller has
    ;             already called UseTab, so the controls land on the right page.
    ; x,y,w,h   — the rectangle to fill. Re-layout later with Layout().
    ; showSave  — a standalone window wants its own Save/Close; a Settings tab is
    ;             saved by the window's own Save button, so it asks for neither.
    __New(hostGui, x, y, w, h, showSave := false) {
        this.gui      := hostGui
        this.hostHwnd := hostGui.Hwnd
        this.showSave := showSave
        this.dirty    := false
        this.lvIds    := []
        this.pending  := Map()          ; id -> key as edited, not yet saved
        this.saved    := Map()          ; id -> key as it stands in hotkeys.ini
        this.defaults := Map()          ; id -> key hotkeys.default.ini asks for
        for id in HK_ORDER {
            this.pending[id]  := HK_Key(id)
            this.saved[id]    := this.pending[id]
            ; Read once, here. The flag column asks "is this still the default?"
            ; for every row of every redraw, and that is one IniRead per row per
            ; keystroke in the search box if it is not cached.
            this.defaults[id] := HKP_DefaultKey(id)
        }

        ; ── the controls, all at a placeholder position ───────────────────────
        ; Every coordinate in this panel is worked out in ONE place: Layout(),
        ; called at the end of this constructor. It used to be two sets of
        ; hand-counted offsets that had to agree and didn't — the static layout put
        ; the buttons at LV_H+48 and the status 38px under them, while the resize
        ; handler put the buttons at h-40 and the status at h-22, INSIDE the button
        ; row. A Text control paints its background, so the status line erased the
        ; bottom 12px of all seven buttons on the first WM_SIZE, which arrives the
        ; moment the window is shown. One layout function cannot disagree with
        ; itself, so that whole class of bug is gone rather than fixed.
        g := hostGui
        this.edSearch := g.Add("Edit", "x" x " y" y " w240 h24")
        this.edSearch.OnEvent("Change", (*) => this.Fill(false))
        ; The cue banner says what the box searches, so no "Search:" label has to.
        HKP_Cue(this.edSearch, "Search a feature, an action or a key…")

        this.ddView := g.Add("DropDownList", "x" x " y" y " w150 Choose1",
                             HotkeysPanel.VIEWS)
        this.ddView.OnEvent("Change", (*) => this.Fill(false))

        ; Right-aligned, and it counts the WHOLE registry rather than the filtered
        ; view — see PaintCount.
        this.lblCount := g.Add("Text", "x" x " y" y " w200 Right", "")

        ; A two-pixel accent rule under the toolbar, separating it from the list.
        ;
        ; A Progress, not a Text with a background colour. The Text version drew
        ; perfectly in the standalone window and drew NOTHING on the Settings tab
        ; page — the same paint path that makes a re-coloured static come back
        ; #000000 there (see THEME_ApplyTo). A progress bar is a real common
        ; control and paints itself the same way wherever it is put: `c` is the bar
        ; and `Background` is behind it, both the accent, with the bar at 100.
        ;
        ; Skipped on classic, where nothing is themed and a hard-coded violet could
        ; land on somebody's high-contrast scheme.
        this.rule := ""
        _accent := THEME_Accent()
        if (_accent != "")
            this.rule := g.Add("Progress", "x" x " y" y " w10 h2 c" _accent
                                         . " Background" _accent, 100)

        ; NoSort: see the header. LV0x010000 is LVS_EX_DOUBLEBUFFER — this list is
        ; deleted and refilled on every keystroke in the search box, and without it
        ; that flickers. No Grid either: the rows carry feature headings now, and
        ; grid lines over those read as a spreadsheet rather than a list.
        this.lv := g.Add("ListView", "x" x " y" y " w300 h200 NoSort -Multi +LV0x010000",
                         ["", "Action", "Key", "Only in", "Clashes with"])
        this.lv.OnEvent("DoubleClick", (*) => this.SetKeyForSelected())
        this.lv.OnEvent("ContextMenu", (ctrl, item, *) => this.RowMenu(item))

        this.btnSet     := g.Add("Button", "x" x " y" y " w96  h30", "Set key…")
        this.btnDefault := g.Add("Button", "x" x " y" y " w96  h30", "Default")
        this.btnDisable := g.Add("Button", "x" x " y" y " w96  h30", "Disable")
        this.btnResetAll:= g.Add("Button", "x" x " y" y " w104 h30", "Reset all")
        this.btnOpenIni := g.Add("Button", "x" x " y" y " w136 h30", "Open hotkeys.ini")
        this.btnSet.OnEvent("Click",      (*) => this.SetKeyForSelected())
        this.btnDefault.OnEvent("Click",  (*) => this.ResetSelected())
        this.btnDisable.OnEvent("Click",  (*) => this.ClearSelected())
        this.btnResetAll.OnEvent("Click", (*) => this.ResetAll())
        this.btnOpenIni.OnEvent("Click",  (*) => this.OpenIni())

        this.btnSave := ""
        if showSave {
            this.btnSave := g.Add("Button", "x" x " y" y " w90 h30 Default", "Save")
            this.btnSave.OnEvent("Click", (*) => this.SaveAndReport())
        }

        this.txtStatus := g.Add("Text", "x" x " y" y " w" w, "")
        ; Dark scrollbars and a dark column header, but only when the window around
        ; the list is dark too — see HKP_DarkList.
        HKP_DarkList(this.lv, this.edSearch)
        ; Layout BEFORE the first Fill, so the rows go into a list that is already
        ; the size it will be. Filled first and resized afterwards, the list came up
        ; scrolled a third of the way down inside the Settings tab — the control
        ; keeps a scroll offset worked out against the height it had at the time,
        ; and growing it does not reset that.
        this.Layout(x, y, w, h)
        this.Fill(false)
        this.Hint()
    }

    ; Every control repositioned for a new rectangle. The list is the panel's whole
    ; point: it takes every pixel a resize gains, while the toolbar and the button
    ; row stay pinned to the top and the bottom of the rectangle.
    Layout(x, y, w, h) {
        by      := y + h - 68           ; button row
        statusY := y + h - 26
        lvY     := y + 38
        this.edSearch.Move(x, y, 240, 24)
        ; x and y only. Move()'s height on a dropdown is the height of the LIST it
        ; drops, not of the control, so passing one here quietly changes how many
        ; items you can see when it is open.
        this.ddView.Move(x + 248, y)
        this.lblCount.Move(x + 410, y + 5, Max(w - 410, 80))
        if this.rule
            this.rule.Move(x, y + 32, w, 2)
        this.lv.Move(x, lvY, w, Max(by - lvY - 12, 60))
        for i, c in [this.btnSet, this.btnDefault, this.btnDisable,
                     this.btnResetAll, this.btnOpenIni]
            c.Move(x + [0, 102, 204, 316, 428][i], by)
        if this.btnSave
            this.btnSave.Move(x + w - 98, by)
        this.txtStatus.Move(x, statusY, w)
        this.SizeCols()
    }

    ; The five columns have to add up to the list's width, or Windows puts a
    ; horizontal scrollbar under them — which it did, since AutoHdr on all five
    ; overflowed. Four take what their content needs; "Clashes with" gets the
    ; remainder, so widening the window widens the one column whose text has no
    ; fixed length.
    SizeCols() {
        this.lv.GetPos(, , &lvW)
        fixed := [26, 260, 170, 110]
        used  := 0
        for i, cw in fixed {
            this.lv.ModifyCol(i, cw)
            used += cw
        }
        ; grid lines, plus the vertical scrollbar this list always has
        this.lv.ModifyCol(5, Max(lvW - used - 26, 90))
    }

    ; ── list ──────────────────────────────────────────────────────────────────

    ; keepView — put the selection and the scroll position back afterwards. True
    ; for an EDIT: you are looking at the row you just changed and you want to stay
    ; there. False when the row set itself changed — searching, or switching what
    ; the Show dropdown lets through — where the top of a new list is the right
    ; place to be.
    Fill(keepView := true) {
        keepId  := keepView ? this.SelectedId() : ""
        keepTop := keepView ? this.TopIndex()   : 0

        filter := Trim(this.edSearch.Value)
        view   := this.ddView.Value
        clash  := this.Conflicts()
        this.lv.Opt("-Redraw")
        this.lv.Delete()
        this.lvIds := []
        lastSec := "", shown := 0
        for id in HK_ORDER {
            m      := HK_META[id]
            key    := this.pending[id]
            sec    := HK_Split(id).section
            secLbl := HK_SECTION_LABEL[sec]
            if !this.Matches(id, m, key, secLbl, filter, view, clash)
                continue
            ; ── the feature separation ───────────────────────────────────
            ; A blank row, then the feature's name in capitals under a ▾. Both
            ; carry the id "", which is what makes SelectedId() answer "nothing
            ; selected" on them — every action already handles that answer, so a
            ; heading cannot be assigned a key by accident.
            ;
            ; This is doing the job the old "Feature" column did, and doing more
            ; of it: that column repeated the section name on the first row of a
            ; group and left it blank on the rest, which separates the groups only
            ; if you are already reading down the left edge. A gap and a heading
            ; separate them whichever column your eye is in — and none of it can be
            ; sorted or scrolled out of alignment, because there is no sort.
            ;
            ; The heading goes in only once a row under it has survived the filter,
            ; so a search never leaves an empty group behind, and the blank row is
            ; skipped for the first group so the list does not start on a gap.
            if (sec != lastSec) {
                if (lastSec != "") {
                    this.lv.Add(, "", "", "", "", "")
                    this.lvIds.Push("")
                }
                lastSec := sec
                this.lv.Add(, "", HotkeysPanel.MARK_GROUP "  " StrUpper(secLbl), "", "", "")
                this.lvIds.Push("")
            }
            this.lv.Add(, this.Flag(id), "     " m.label, HKP_KeyLabel(key), m.when,
                        clash.Has(id) ? clash[id] : "")
            this.lvIds.Push(id)
            shown++
        }
        this.SizeCols()
        if keepView
            this.RestoreView(keepId, keepTop)
        this.lv.Opt("+Redraw")
        this.PaintCount(shown, clash)
    }

    ; One row of the registry, against the search box and the Show dropdown.
    Matches(id, m, key, secLbl, filter, view, clash) {
        if (view = 2 && !this.IsChanged(id))
            return false
        if (view = 3 && !clash.Has(id))
            return false
        if (view = 4 && key != "")
            return false
        if (filter = "")
            return true
        ; The heading is searchable too: typing "mass" should bring back the whole
        ; feature, not only the rows whose action happens to contain the word.
        return InStr(m.label, filter, false) || InStr(id, filter, false)
            || InStr(key, filter, false) || InStr(HKP_KeyLabel(key), filter, false)
            || InStr(secLbl, filter, false)
    }

    ; ● edited and not saved · ○ saved, but not what the defaults say · blank for
    ; stock. Three states in 26 pixels, which is the whole reason the column
    ; exists: "what have I actually touched here" could not be answered before
    ; without opening the ini next to the window.
    Flag(id) {
        if (this.pending[id] != this.saved[id])
            return HotkeysPanel.MARK_EDIT
        return this.IsChanged(id) ? HotkeysPanel.MARK_CUSTOM : ""
    }

    ; An id with no line in hotkeys.default.ini counts as changed as soon as it has
    ; a key at all — there is nothing for it to match, so "same as the default"
    ; cannot be true of it.
    IsChanged(id) {
        d := this.defaults[id]
        return (d == HK_UNSET) ? (this.pending[id] != "") : (this.pending[id] != d)
    }

    ; The counter on the right of the toolbar. Deliberately counts the WHOLE
    ; registry and not the filtered view: "3 unsaved" dropping to 0 because you
    ; typed in the search box would be a lie about the one thing it is there to
    ; warn you about. Only the leading number follows the filter, and it says so.
    PaintCount(shown, clash) {
        total := HK_ORDER.Length
        edits := 0, off := 0
        for id in HK_ORDER {
            if (this.pending[id] != this.saved[id])
                edits++
            if (this.pending[id] = "")
                off++
        }
        s := (shown = total) ? total " keys" : shown " of " total " keys"
        if edits
            s .= "   ·   " edits " unsaved"
        if clash.Count
            s .= "   ·   " clash.Count " clashing"
        if off
            s .= "   ·   " off " off"
        this.lblCount.Value := s
    }

    ; ── keeping your place across a rebuild ───────────────────────────────────

    ; LVM_GETTOPINDEX — the row currently at the top of the visible area. There is
    ; no AHK property for it, and GetNext() cannot stand in: what is SELECTED and
    ; what is SCROLLED TO are different questions, and the list answers neither
    ; after a Delete().
    ;
    ; The message counts rows from 0 and AHK counts them from 1. Converted here, at
    ; the message boundary, so that every other line in this class is in AHK's
    ; numbering — mixing the two gives a panel that restores your place one row off,
    ; which looks like nothing at all until you are at the bottom of the list.
    TopIndex() {
        static LVM_GETTOPINDEX := 0x1027
        return SendMessage(LVM_GETTOPINDEX, 0, 0, this.lv) + 1
    }

    ; Put `row` back on the top line of the visible area.
    ;
    ; There is no AHK option for this. v1 had "VisFirst" and v2 REJECTS it — the
    ; panel threw "Invalid option" from Modify() the first time this ran — and plain
    ; "Vis" only guarantees the row is somewhere on screen, which is not the same
    ; thing as putting your place back.
    ;
    ; So it is done the way the control's own API does it: make the last row of the
    ; page visible, then the row you actually want. The list scrolls down, then up,
    ; and comes to rest with `row` on the top line.
    PinTop(row) {
        static LVM_ENSUREVISIBLE := 0x1013, LVM_GETCOUNTPERPAGE := 0x1028
        n := this.lv.GetCount()
        if (n = 0 || row < 1)
            return
        row := Min(row, n)
        per := SendMessage(LVM_GETCOUNTPERPAGE, 0, 0, this.lv)
        SendMessage(LVM_ENSUREVISIBLE, Min(row + per - 1, n) - 1, 0, this.lv)
        SendMessage(LVM_ENSUREVISIBLE, row - 1, 0, this.lv)
    }

    ; Selection first, scroll second, and the order matters: focusing a row scrolls
    ; it into view, so restoring the scroll AFTERWARDS is what actually pins the
    ; view where it was. Nothing is forced into range that isn't there — a row the
    ; filter has just removed simply leaves the list unselected.
    RestoreView(id, top) {
        n := this.lv.GetCount()
        if (n = 0)
            return
        if (id != "") {
            for i, x in this.lvIds {
                if (x = id) {
                    this.lv.Modify(i, "Select Focus")
                    break
                }
            }
        }
        if (top > 0)
            this.PinTop(top)
    }

    ; ── conflicts ─────────────────────────────────────────────────────────────

    ; Two ids clash when they resolve to the same key AND can be live at the same
    ; time.
    ;
    ; There used to be an exemption here: model send keys did not count as clashing
    ; with each other, because three model PROCESSES each bound the same key and
    ; StartFuGating kept only the active one registered — so three copies of F13
    ; were normal, and flagging them was crying wolf. One process shares keys
    ; through a single [mass.active] declaration instead, so there is nothing to
    ; exempt. Removing it makes the report honest, and it has something to report.
    Conflicts() {
        byKey := Map(), out := Map()
        for id in HK_ORDER {
            k := this.pending[id]
            if (k = "")
                continue
            if !byKey.Has(k)
                byKey[k] := []
            byKey[k].Push(id)
        }
        for k, ids in byKey {
            if (ids.Length < 2)
                continue
            for i, a in ids {
                names := ""
                for j, b in ids {
                    if (i = j || !HKP_CanCollide(a, b))
                        continue
                    names .= (names = "" ? "" : ", ") HK_META[b].label
                }
                if (names != "")
                    out[a] := Chr(0x26A0) " " names
            }
        }
        return out
    }

    ; ── actions ───────────────────────────────────────────────────────────────

    ; "" for a group heading as much as for nothing selected at all — a heading is
    ; not a hotkey, and every caller already treats "" as "nothing to act on".
    SelectedId() {
        r := this.lv.GetNext()
        return r ? this.lvIds[r] : ""
    }

    ; Right-click acts on the row UNDER THE CURSOR, which is not necessarily the
    ; selected one — so that row is selected first. Anything else silently edits a
    ; row you are not pointing at.
    RowMenu(item) {
        if (item > 0)
            this.lv.Modify(item, "Select Focus")
        id := this.SelectedId()
        if (id = "")
            return
        m := Menu()
        m.Add("Set key…",         (*) => this.SetKeyForSelected())
        m.Add("Reset to default", (*) => this.ResetSelected())
        m.Add("Disable",          (*) => this.ClearSelected())
        m.Add()
        m.Add("Copy key",         (*) => this.CopyKey())
        if (this.defaults[id] == HK_UNSET)
            m.Disable("Reset to default")
        if (this.pending[id] = "")
            m.Disable("Copy key")
        m.Show()
    }

    CopyKey() {
        id := this.SelectedId()
        if (id = "" || this.pending[id] = "")
            return
        A_Clipboard := this.pending[id]
        this.Status("Copied " HKP_KeyLabel(this.pending[id]) " to the clipboard")
    }

    ; The overlay that says "press a key". Its own method so it can be BUILT
    ; without being driven: previewing it from a probe must not broadcast the
    ; suspend that a real capture needs, because that reaches every MMA script you
    ; have running and a probe that dies before un-suspending leaves every hotkey
    ; in the app dead with no clue why.
    ;
    ; Returns {gui, prompt} — the caller shows nothing else and updates `prompt`
    ; as the chord builds.
    CaptureOverlay(id) {
        meta := HK_META[id]
        ovW := 420, ovH := 132
        ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" this.hostHwnd)
        ov.BackColor := "17161F"
        ov.MarginX := 0, ov.MarginY := 0
        ; A bar of the accent colour along the top, so this reads as MMA's overlay
        ; and not as a system dialog that has lost its title bar. It is the one
        ; colour here that is not fixed, and it falls back rather than vanishing on
        ; classic — this window is dark on every theme, so there is no high-contrast
        ; scheme for it to land in.
        _accent := THEME_Accent()
        ov.Add("Text", "x0 y0 w" ovW " h4 Background" (_accent != "" ? _accent : "6D28D9"))
        ; WHAT you are about to rebind. The old overlay said only "press a key",
        ; which is fine right up until you have double-clicked the wrong row.
        ov.SetFont("s9 c9A9A9A", "Segoe UI")
        ov.Add("Text", "x0 y20 w" ovW " Center", meta.label)
        ov.SetFont("s13 cFFFFFF")
        lblPrompt := ov.Add("Text", "x0 y44 w" ovW " Center", "Press a key or mouse button…")
        ov.SetFont("s9 c6F6C7D")
        ov.Add("Text", "x0 y80 w" ovW " Center", "currently " HKP_KeyLabel(this.pending[id]))
        ov.Add("Text", "x0 y102 w" ovW " Center", "Esc = cancel     Backspace = disable")
        ; Over the window it belongs to, not over the middle of the desktop — on a
        ; three-monitor desk those are not the same place, and this one takes every
        ; keystroke you make while it is up.
        ov.Show(HKP_CenterOn(this.hostHwnd, ovW, ovH))
        return {gui: ov, prompt: lblPrompt}
    }

    SetKeyForSelected() {
        id := this.SelectedId()
        if (id = "") {
            this.Status("Select a hotkey first — the " HotkeysPanel.MARK_GROUP
                      . " lines are feature headings, not keys")
            return
        }
        cap := this.CaptureOverlay(id)
        ov  := cap.gui
        lblPrompt := cap.prompt

        ; Every script holds fire while we listen — this one included, now that the
        ; panel lives inside a script that has hotkeys of its own. The un-suspend
        ; MUST run even if the grab throws, or every hotkey in MMA stays dead with
        ; no clue why.
        HK_Broadcast(HK_MSG_SUSPEND, 1)
        try
            k := HKP_GrabKey(lblPrompt)
        finally {
            HK_Broadcast(HK_MSG_SUSPEND, 0)
            ov.Destroy()
        }

        if (k = "<cancel>")
            return
        this.pending[id] := (k = "<clear>") ? "" : k
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label "   " Chr(0x2192) "   "
                  . HKP_KeyLabel(this.pending[id]) "      (not saved yet)")
    }

    ResetSelected() {
        id := this.SelectedId()
        if (id = "") {
            this.Status("Select a hotkey first")
            return
        }
        d := this.defaults[id]
        if (d == HK_UNSET) {
            this.Status("No default for " id)
            return
        }
        this.pending[id] := d
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label "   " Chr(0x2192) "   default (" HKP_KeyLabel(d) ")")
    }

    ClearSelected() {
        id := this.SelectedId()
        if (id = "") {
            this.Status("Select a hotkey first")
            return
        }
        this.pending[id] := ""
        this.dirty := true
        this.Fill()
        this.Status(HK_META[id].label " disabled")
    }

    ResetAll() {
        if MsgBox("Reset every hotkey back to its default?", "Reset all", 0x24) != "Yes"
            return
        for id in HK_ORDER {
            d := this.defaults[id]
            if (d != HK_UNSET)
                this.pending[id] := d
        }
        this.dirty := true
        this.Fill()
        this.Status("All hotkeys reset to defaults — press Save to apply")
    }

    ; Writes the changed rows and applies them live. Returns how many changed, so
    ; a host window can fold this into its own save message instead of popping a
    ; second one. Safe to call when nothing changed — it writes nothing.
    Save() {
        n := 0
        for id in HK_ORDER {
            s   := HK_Split(id)
            cur := IniRead(HK_INI, s.section, s.key, HK_UNSET)
            if (cur == HK_UNSET || Trim(cur) != this.pending[id]) {
                IniWrite(this.pending[id], HK_INI, s.section, s.key)
                n++
            }
            this.saved[id] := this.pending[id]
        }
        if (n = 0)
            return 0
        ; Reset all pulls from hotkeys.default.ini, which carries no SchemaVersion —
        ; re-stamp it so the one-time cfg migration can't run again over a clean cfg.
        IniWrite(HK_SCHEMA, HK_INI, "meta", "SchemaVersion")
        HK_Broadcast(HK_MSG_RELOAD, 0)
        this.dirty := false
        ; Every ● says "edited, not saved yet", and not one of them is true now.
        ; `try`, because a host window is allowed to save and close in the same
        ; breath — Settings does — and repainting a destroyed Gui throws.
        try this.Fill()
        return n
    }

    SaveAndReport() {
        n := this.Save()
        this.Status(n = 0 ? "No changes" : n " hotkey(s) saved — applied live, no restart")
    }

    ; Hand-editing the ini is a first-class path, so don't let a missing .ini file
    ; association turn "Open hotkeys.ini" into an error dialog — fall back to Notepad.
    OpenIni() {
        try
            Run(Chr(34) HK_INI Chr(34))
        catch
            try Run("notepad.exe " Chr(34) HK_INI Chr(34))
    }

    Status(s) {
        this.txtStatus.Value := s
    }

    ; What the status line says when it has no news: the legend for the two marks,
    ; which is the only place they are explained. Said in text and glyphs rather
    ; than in colour, because a static that is recoloured after it exists repaints
    ; black on a tab page — the failure THEME_ApplyTo describes.
    Hint() {
        this.Status("Double-click a row to assign it, or right-click for the lot"
                  . "      " HotkeysPanel.MARK_EDIT " unsaved"
                  . "      " HotkeysPanel.MARK_CUSTOM " not the default"
                  . "      " Chr(0x2014) " disabled")
    }

    ; True when there are edits the user has not saved. A host window asks this
    ; before closing.
    HasUnsaved() => this.dirty
}

; ── helpers ───────────────────────────────────────────────────────────────────
; Free functions, HKP_-prefixed. main_window.ahk's include graph is large and flat,
; and a plain `Pretty` or `Status` there would be a name collision — in AHK v2 a
; function and a variable that share a name (case-insensitively) do not merely
; shadow one another, the script fails to load.

; An em dash for "no key", not an empty cell: a blank column reads as a row that
; failed to draw, and this one is a deliberate state you can put a hotkey into.
HKP_KeyLabel(k) => (k = "" ? Chr(0x2014) : HKP_Pretty(k))

; ^!+# is how AHK writes it and what the ini stores; spell it out for the list.
HKP_Pretty(k) {
    ; Mouse buttons under the name they have on the mouse. "XButton1" is the API's
    ; word for it and nobody else's, and this label is read by someone deciding
    ; whether the button they just pressed is the one they meant. Shared with the
    ; hotstrings window and the main window's Add Hotkey, both of which show a
    ; captured key back to you the same way.
    static NICE := Map("LButton", "Left click", "RButton", "Right click",
                       "MButton", "Middle click", "XButton1", "Mouse 4",
                       "XButton2", "Mouse 5", "WheelUp", "Wheel up",
                       "WheelDown", "Wheel down")
    out := ""
    while (k != "" && InStr("^!+#", SubStr(k, 1, 1))) {
        c := SubStr(k, 1, 1)
        out .= (c = "^") ? "Ctrl+" : (c = "!") ? "Alt+" : (c = "+") ? "Shift+" : "Win+"
        k := SubStr(k, 2)
    }
    return out (NICE.Has(k) ? NICE[k] : k)
}

; A grey prompt inside an empty Edit. It says what the box searches without
; spending a label and 50 pixels of the toolbar on saying it.
HKP_Cue(ctrl, text) {
    static EM_SETCUEBANNER := 0x1501
    try SendMessage(EM_SETCUEBANNER, 1, StrPtr(text), ctrl)
}

; Centre a window over another one, as a Show() option string. WinGetPos cannot see
; a HIDDEN window and the host is always visible when this is called — but a throw
; here would take the whole capture down for a cosmetic reason, so it falls back to
; letting Windows centre it on the screen.
HKP_CenterOn(hwnd, w, h) {
    try {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        return "x" (wx + (ww - w) // 2) " y" (wy + (wh - h) // 2) " w" w " h" h
    }
    return "w" w " h" h
}

; Dark scrollbars, a dark selection band and a dark column header — but ONLY when
; the theme is dark. DarkMode_Explorer on a control inside a LIGHT window gives you
; one dark box among twenty light ones, which is exactly why Settings hands its own
; helper an empty control list (see the ArchiveDarkTheme call at the end of
; OpenSettings).
;
; The header is a separate SysHeader32 child and does not inherit the list's theme,
; so it is themed by hand. DarkMode_Explorer, not DarkMode_ItemsView: ItemsView
; darkens the header background and leaves the LABEL text dark too, which reads as
; an empty header rather than a themed one.
HKP_DarkList(lv, ctrls*) {
    if !THEME_Set().dark
        return
    for c in ctrls
        try DllCall("uxtheme\SetWindowTheme", "ptr", c.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    try DllCall("uxtheme\SetWindowTheme", "ptr", lv.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    hHdr := SendMessage(0x101F, 0, 0, lv)          ; LVM_GETHEADER
    if hHdr
        try DllCall("uxtheme\SetWindowTheme", "ptr", hHdr, "str", "DarkMode_Explorer", "ptr", 0)
}

HKP_CanCollide(a, b) {
    ma := HK_META[a], mb := HK_META[b]
    ; different window contexts can never both be active
    if (ma.when != "" && mb.when != "" && ma.when != mb.when)
        return false
    return true
}

HKP_DefaultKey(id) {
    s := HK_Split(id)
    v := IniRead(HK_INI_DEFAULT, s.section, s.key, HK_UNSET)
    return (v == HK_UNSET) ? HK_UNSET : Trim(v)
}

; Reads one chord. InputHook covers the keyboard (F13-F24 included); mouse buttons
; never reach it, so those get temporary hotkeys. Capturing XButton1/2 and the
; Scimitar keys is exactly why this editor is native AHK, not a web page.
HKP_GrabKey(fb := "") {
    static btns := ["LButton", "RButton", "MButton", "XButton1", "XButton2",
                    "WheelUp", "WheelDown"]
    ; The eight keys that are modifiers, never a chord's main key.
    static MOD_KEYS := "{LControl}{RControl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}"
    global _HKP_GRABBED  := ""
    global _HKP_GRABMODS := ""

    ; "S" = exempt from Suspend. The suspend broadcast that protects you from
    ; firing a real hotkey mid-capture now reaches this script too, and without
    ; the exemption it would switch off the very keys doing the capturing.
    for b in btns
        try Hotkey("*" b, HKP_MouseGrab.Bind(b), "On S")

    ; L0 = no length limit; KeyOpt {All} E makes any key an end key, so this blocks
    ; until one arrives. No V, so the keypress is swallowed rather than typed into
    ; whatever is behind the overlay.
    ih := InputHook("L0")
    ; Which modifiers were down AT THE INSTANT the end key arrived. Reading them
    ; afterwards races the user's fingers: release Ctrl a few ms after F1 and the
    ; chord silently records as plain F1.
    ih.OnEnd := HKP_GrabEndMods
    try {
        ih.KeyOpt("{All}", "E")
        ; ...but NOT the modifiers. With {All} E they ended the input too, so the
        ; instant you pressed Ctrl the capture finished with EndKey "LControl"
        ; while the modifier read also saw Ctrl held — giving "^LControl" and
        ; leaving no way to type a chord unless you hit the second key in the same
        ; instant. Excluding them gives the behaviour every other app has: hold the
        ; modifiers, and the capture waits for a real key.
        ih.KeyOpt(MOD_KEYS, "-E")
        ih.Start()
        while (ih.InProgress && _HKP_GRABBED = "") {
            ; Show the chord as it builds, so holding Ctrl visibly does something.
            if IsObject(fb) {
                m := HKP_Mods()
                fb.Value := (m = "") ? "Press a key or mouse button…" : HKP_Pretty(m) "…"
            }
            Sleep(15)
        }
    } finally {
        if ih.InProgress
            ih.Stop()
        for b in btns                ; always release, even if the above threw
            try Hotkey("*" b, "Off")
    }

    if (_HKP_GRABBED != "") {
        got := _HKP_GRABBED
        _HKP_GRABBED := ""
        return got
    }
    ek := ih.EndKey
    if (ek = "" || ek = "Escape")
        return "<cancel>"
    if (ek = "Backspace")
        return "<clear>"
    ; OnEnd is the accurate reading; fall back to a live one if it never ran, so a
    ; missed callback costs the modifiers rather than the whole chord.
    return (_HKP_GRABMODS != "" ? _HKP_GRABMODS : HKP_Mods()) ek
}

; InputHook.OnEnd — the one moment the held modifiers are still true.
HKP_GrabEndMods(*) {
    global _HKP_GRABMODS := HKP_Mods()
}

HKP_MouseGrab(btn, *) {
    global _HKP_GRABBED := HKP_Mods() btn
}

HKP_Mods() {
    s := ""
    if GetKeyState("Ctrl", "P")
        s .= "^"
    if GetKeyState("Alt", "P")
        s .= "!"
    if GetKeyState("Shift", "P")
        s .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        s .= "#"
    return s
}
