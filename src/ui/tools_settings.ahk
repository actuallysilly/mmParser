#Requires AutoHotkey v2.0
; The On / Off / Restart logic for the background services (TOOLS_*).
#Include "tools_window.ahk"
; SW_FieldPage / SW_FieldPageSave / SW_Num draw and save the field-table rows, and
; settings_core.ahk is the table. Both shells include settings_window.ahk already;
; AHK loads a file once, so naming it here costs nothing.
#Include "settings_window.ahk"
#Include "../core/theme.ahk"
; The Reply timers block: tiers, the "Calibrate…" drags and the dot scan.
#Include "../core/reply_tiers.ahk"
#Include "../screen/ocr_grab.ahk"
#Include "../screen/reply_scan.ahk"
; TestFlowOpen / LiveTrainerOpen / ShiftViewerOpen / ChatViewOpen, and the
; desktop shortcuts — shared with the engine, which binds their hotkeys.
#Include "../core/ai_suite.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  tools_settings.ahk — the Tools window: every tool's settings, one page.
; ───────────────────────────────────────────────────────────────────────────────
;  Settings holds what MMA itself needs (wait time, models, sending, keys). Every
;  non-core tool lives here instead, one section each, on ONE page that scrolls,
;  with the list on the left jumping to a section. Asked for 2026-10-24: "a new
;  tools GUI-window that displays the settings for all the tools … scrollable
;  section and I could navigate", and "for the features that don't have gui
;  settings add them in tools".
;
;  Each section is:
;    the tool's name and state — On / Off / Restart for a background service
;      (what this window used to be on its own), or the feature's switch shown
;      read-only for the rest, because Settings ▸ Features is the one place a
;      feature is switched (see features_panel.ahk);
;    one line on what it does;
;    any controls of its own (Reply timers' calibration, the purchase sound);
;    its rows from the field table (settings_core.ahk, the rows with `tool`).
;
;  ─── HOW THE PAGE SCROLLS ────────────────────────────────────────────────────
;  A Win32 window does not scroll its controls. So the page is a child window as
;  tall as everything on it, inside a viewport child window that has a scrollbar;
;  scrolling moves the page up inside the viewport.
;
;  Two kinds of number, and mixing them is the bug this paragraph is here for:
;  controls, Show's w/h and Gui.Move are in DPI-scaled Gui units, but a child
;  window's Show x/y is raw PIXELS. At 125% the first build put the viewport at
;  226 pixels — under a list 262 pixels wide. So everything about scrolling (`pos`,
;  the range, where a section starts) is kept in pixels, converted with `k` at the
;  two edges: the viewport's Show, and the page's Move.
; ═══════════════════════════════════════════════════════════════════════════════

; What is on the page, in order. A {grp} entry is a heading; the rest are tools.
;
;   id     a feature id from core\modes.ahk, or a pseudo id for settings that are
;          not a feature ("llm", "discord"). The field rows tagged with this id
;          in settings_core.ahk are drawn under it.
;   label  "" = the feature's own label, minus its bracketed note
;   desc   one line on what it does
;   draw   the name of a ToolsWindow method that draws extra controls, or ""
TW_Sections() {
    return [
        {grp: "AI suite"},
        {id: "aiSuite", label: "Open an AI tool", draw: "DrawAiSuite",
         desc: "TestFlow is the training lab, Live Trainer grades the AI on your real chats, Fan Viewer shows every fan the recorder saved (chat, spend, lore card), Video → chat turns a recording into chats."},

        {grp: "Model detection"},
        {id: "modelDetector", label: "Model detector (Infloww)", draw: "",
         desc: "Reads which Infloww tab is selected, so the shared keys follow the model on screen."},
        {id: "fanslyDetector", label: "Model detector (Fansly)", draw: "",
         desc: "Reads which card is selected on the Fansly rail."},

        {grp: "Chat reading and AI"},
        {id: "chatReader", label: "", draw: "",
         desc: "Reads the open Infloww chat in the background — no clicks, no focus. Suggestions, the shift recorder and the purchase sound all use it."},
        {id: "purchaseSound", label: "Purchase sound", draw: "DrawPurchaseSound",
         desc: "Plays a sound when a PPV in the open chat turns from 'not paid' to 'paid'."},
        {id: "unreadPing", label: "Unread ping", draw: "",
         desc: "Pings when the number on Infloww's Unread pill reaches X, and again every N minutes while it stays there."},
        {id: "shiftLog", label: "Shift recorder", draw: "DrawShiftLog",
         desc: "Saves every chat the chat reader sees, per fan, as AI training data."},
        {id: "typelog", label: "Typelog", draw: "DrawTypelog",
         desc: "Records every message you send in Infloww."},
        {id: "autoword", label: "Autoword", draw: "",
         desc: "Next-word suggestions while you type; Ctrl+Tab rewords. Saving restarts it if anything changed."},
        {id: "grammarFast", label: "Fix grammar: fast mode", draw: "",
         desc: "Fix grammar pastes the corrected text straight back instead of showing it first."},
        {id: "llm", label: "Local AI (Ollama)", draw: "",
         desc: "The model behind suggestions, rewording and grammar. Read on every request — no restart."},

        {grp: "Screen helpers"},
        {id: "statsOverlay", label: "Stats overlay", draw: "",
         desc: "A small always-on-top box with today's sales and your PPV-to-fans ratio."},
        {id: "replyBox", label: "Reply timers", draw: "DrawReplyTimers",
         desc: "A coloured border round any unread conversation that has waited too long."},
        {id: "timer", label: "Timer", draw: "",
         desc: "A countdown that beeps and can repeat. One key opens its window, the other starts and stops it with no window."},
        {id: "pinger", label: "Unread pinger", draw: "",
         desc: "Beeps when an Infloww tab goes unread."},
        {id: "automation", label: "Automation hotkeys", draw: "",
         desc: "Serves the [automation] keys — sales tally, unsend and the rest. Keys are in Settings ▸ Hotkeys."},

        {grp: "Library"},
        {id: "archive", label: "Mass archive", draw: "DrawArchive",
         desc: "Keeps a dated copy of every mass you parse, so you can find it again."},
        {id: "hotstrings", label: "Hotstrings manager", draw: "DrawHotstrings",
         desc: "The searchable window for your message hotstrings."},
        {id: "fastParse", label: "Fast-parse autosave", draw: "",
         desc: "Saves a parsed mass straight into the right model's tab."},

        {grp: "Tools"},
        {id: "actionsMenu", label: "Actions menu", draw: "",
         desc: "A searchable list of everything MMA can do."},
        {id: "quickActions", label: "Quick actions", draw: "",
         desc: "Big buttons for the actions you pinned in the Actions menu."},
        {id: "recorder", label: "Coordinate recorder", draw: "",
         desc: "Records clicks and keys so you can replay them."},
        {id: "capitalizer", label: "Auto-capitalize", draw: "",
         desc: "Capitalizes the first letter after you press Enter."},
        {id: "ocrGrab", label: "Add hotstring with OCR", draw: "",
         desc: "Drag a box on screen; its text opens in Add hotstring."},
        {id: "tabMarks", label: "Tab bars", draw: "",
         desc: "Draws dividers between the tabs on the Infloww strip."},
        {id: "branchBuilder", label: "Branch builder", draw: "DrawBranchBuilder",
         desc: "Draw a conversation as a tree of follow-ups."},
        {id: "chatSim", label: "Chat simulator", draw: "DrawChatSim",
         desc: "Write a mass while seeing it as a chat."},
        {id: "calc", label: "Payout calculator", draw: "DrawCalc",
         desc: "USD in, EUR out: amount × the fees × today's USD→EUR rate − the amount to subtract. The rate is fetched live each time it opens."},
        {id: "shortcuts", label: "Hotstring shortcuts", draw: "",
         desc: "Type a trigger to run an MMA action."},

        {grp: "While sending"},
        {id: "clickWall", label: "Click wall", draw: "",
         desc: "Holds a click on the chat list until a multi-part send has finished, so it never lands on the wrong fan."},
        {id: "discord", label: "Discord import", draw: "",
         desc: "Where to read the channel name when you Ctrl+click import from Discord, and where MM Gatherer reads the messages."},

        {grp: "System"},
        {id: "activity", label: "Activity tracker", draw: "DrawActivity",
         desc: "Counts your typing time, per day."}
    ]
}

; The one open instance, or 0.
global TOOLS_WIN := 0

OpenToolsWindow(ownerHwnd := 0) {
    global TOOLS_WIN
    if TOOLS_WIN {
        try {
            TOOLS_WIN.tg.Show()
            return
        }
        TOOLS_WIN := 0
    }
    TOOLS_WIN := ToolsWindow(ownerHwnd)
}

class ToolsWindow {
    static W     := 1040
    static H     := 760
    static NAV_W := 210
    static BAR_H := 48
    static PAD   := 16          ; page margin
    static WHEEL := 72          ; pixels per wheel notch

    __New(ownerHwnd := 0) {
        bg := THEME_WindowBg()
        this.tg := Gui("+Resize +MinSize820x480" (ownerHwnd ? " +Owner" ownerHwnd : ""),
                       "MMA Tools")
        if (bg != "")
            this.tg.BackColor := bg
        this.tg.SetFont("s9" THEME_FontOpt(), "Segoe UI")

        this.secs     := []      ; {id, top, entry} per nav row, in nav order
        this.rowSets  := []      ; SW_FieldPage results, for Save
        this.states   := []      ; {id, lbl, on, off, restart} per tool, for Refresh
        this.pos      := 0       ; current scroll offset, in PIXELS (see the header)
        this.k        := A_ScreenDPI / 96

        ; ── the list on the left ──────────────────────────────────────────────
        navH := ToolsWindow.H - ToolsWindow.BAR_H - 16
        this.nav := this.tg.Add("ListBox", "x8 y8 w" ToolsWindow.NAV_W " h" navH " 0x100")
        this.nav.OnEvent("Change", ObjBindMethod(this, "NavPicked"))

        ; ── the viewport, and the page inside it ──────────────────────────────
        this.vpW := ToolsWindow.W - ToolsWindow.NAV_W - 24
        this.vpH := navH
        this.vp := Gui("-Caption +Parent" this.tg.Hwnd " +0x200000")   ; WS_VSCROLL
        if (bg != "")
            this.vp.BackColor := bg
        this.pg := Gui("-Caption +Parent" this.vp.Hwnd)
        if (bg != "")
            this.pg.BackColor := bg
        this.pg.SetFont("s9" THEME_FontOpt(), "Segoe UI")

        this.Build()

        ; ── the bottom strip ──────────────────────────────────────────────────
        by := ToolsWindow.H - ToolsWindow.BAR_H + 8
        this.btnSave := this.tg.Add("Button", "x8 y" by " w100 h30 Default", "Save")
        this.btnSave.OnEvent("Click", ObjBindMethod(this, "Save"))
        this.btnClose := this.tg.Add("Button", "x116 y" by " w90 h30", "Close")
        this.btnClose.OnEvent("Click", ObjBindMethod(this, "Close"))
        this.lblSaved := this.tg.Add("Text", "x218 y" (by + 8) " w" (ToolsWindow.W - 230), "")

        THEME_ApplyTo(this.tg)
        THEME_ApplyTo(this.pg)
        THEME_BoldButtons(this.tg)
        THEME_BoldButtons(this.pg)

        ; Bound once and kept, so the same objects can be unregistered on close.
        this._onScroll := ObjBindMethod(this, "OnVScroll")
        this._onWheel  := ObjBindMethod(this, "OnWheel")
        this._refresh  := ObjBindMethod(this, "Refresh")
        OnMessage(0x115, this._onScroll)      ; WM_VSCROLL
        OnMessage(0x20A, this._onWheel)       ; WM_MOUSEWHEEL
        this.tg.OnEvent("Close",  ObjBindMethod(this, "Close"))
        this.tg.OnEvent("Escape", ObjBindMethod(this, "Close"))
        this.tg.OnEvent("Size",   ObjBindMethod(this, "OnSize"))

        try ArchiveDarkTheme(this.tg, [])
        this.tg.Show("w" ToolsWindow.W " h" ToolsWindow.H)
        this.vp.Show("x" Round((ToolsWindow.NAV_W + 16) * this.k) " y" Round(8 * this.k)
                   . " w" this.vpW " h" this.vpH " NoActivate")
        this.pg.Show("x0 y0 w" this.pageW " h" this.pageH " NoActivate")
        this.SetRange()
        this.nav.Value := 1

        this.Refresh()
        ; Every second: the watchdog restarting a tool, a detector exiting on a bad
        ; read, the pinger stopped from its own tray — none of it is a click here.
        SetTimer(this._refresh, 1000)
    }

    ; ── the page ──────────────────────────────────────────────────────────────
    Build() {
        g := this.pg
        ; The scrollbar takes its width out of the viewport.
        this.pageW := this.vpW - SysGet(2) - 4                 ; SM_CXVSCROLL
        x := ToolsWindow.PAD
        w := this.pageW - ToolsWindow.PAD * 2
        y := 12
        for s in TW_Sections() {
            if s.HasProp("grp") {
                if (this.secs.Length)
                    y += 10
                this.secs.Push({id: "", top: y})
                this.nav.Add([s.grp])
                g.SetFont("s12 Bold")
                g.Add("Text", "x" x " y" y " w" w, s.grp)
                g.SetFont("s9 Norm")
                y += 26
                g.Add("Text", "x" x " y" y " w" w " h1 0x10")
                y += 12
                continue
            }
            this.secs.Push({id: s.id, top: y})
            this.nav.Add(["      " this.Label(s)])
            y := this.DrawSection(g, s, x, y, w)
        }
        ; Room below the last section, so the list can bring it to the top.
        this.pageH := y + this.vpH - 120
    }

    ; A tool's name: the one in TW_Sections, else the feature's own label without
    ; its bracketed note ("Autoword (next-word suggestions…)" → "Autoword").
    Label(s) {
        if (s.label != "")
            return s.label
        if FEAT_META.Has(s.id)
            return Trim(RegExReplace(FEAT_META[s.id].label, "\s*\(.*$"))
        return s.id
    }

    DrawSection(g, s, x, y, w) {
        g.SetFont("s10 Bold")
        g.Add("Text", "x" x " y" y " w" (w - 330), this.Label(s))
        g.SetFont("s9 Norm")
        st := {id: s.id, lbl: 0, on: 0, off: 0, restart: 0}
        if FEAT_META.Has(s.id) {
            st.lbl := g.Add("Text", "x" (x + w - 520) " y" (y + 2) " w" 250, "")
            if this.IsService(s.id) {
                ; Two buttons rather than one toggle: a single button has to know
                ; the state to label itself, which is what went wrong with the old
                ; "Pinger: ON". Restart last, where the hands do not expect On.
                st.on      := g.Add("Button", "x" (x + w - 260) " y" (y - 3) " w76 h26", "On")
                st.off     := g.Add("Button", "x" (x + w - 178) " y" (y - 3) " w76 h26", "Off")
                st.restart := g.Add("Button", "x" (x + w - 96)  " y" (y - 3) " w96 h26", "Restart")
                st.on.OnEvent("Click",      ObjBindMethod(this, "ToolOn", s.id))
                st.off.OnEvent("Click",     ObjBindMethod(this, "ToolOff", s.id))
                st.restart.OnEvent("Click", ObjBindMethod(this, "ToolRestart", s.id))
            }
            this.states.Push(st)
        }
        y += 26
        g.SetFont("s9 c808080")
        g.Add("Text", "x" x " y" y " w" w, s.desc)
        g.SetFont("s9 cDefault" THEME_FontOpt())
        y += 24
        if (s.draw != "")
            y := this.%s.draw%(g, x, y, w)
        rows := SW_FieldPage(g, "", x, y, w, s.id, &yEnd)
        if rows.Length {
            this.rowSets.Push(rows)
            y := yEnd
        }
        return y + 18
    }

    IsService(id) {
        for sid in SVC_ORDER
            if (sid = id)
                return true
        return false
    }

    ; ── per-tool extras ───────────────────────────────────────────────────────
    ; Each takes the page, a position and a width, and returns the y below it.

    ; A row of buttons, each [caption, Func].
    Buttons(g, x, y, list) {
        for b in list {
            btn := g.Add("Button", "x" x " y" y " w" (b.Has(3) ? b[3] : 150) " h28", b[1])
            btn.OnEvent("Click", b[2])
            x += (b.Has(3) ? b[3] : 150) + 10
        }
        return y + 38
    }

    ; One button per tool, with its key on it, and the desktop shortcuts.
    DrawAiSuite(g, x, y, w) {
        y := this.Buttons(g, x, y,
            [["TestFlow   " HKP_KeyLabel(HK_Key("util.testFlow")),         TestFlowOpen,    170],
             ["Live Trainer   " HKP_KeyLabel(HK_Key("util.liveTrainer")),  LiveTrainerOpen, 170],
             ["Fan Viewer     " HKP_KeyLabel(HK_Key("util.shiftViewer")),  ShiftViewerOpen, 170],
             ["What's on screen", ChatViewOpen, 150]])
        return this.Buttons(g, x, y,
            [["Arena   " HKP_KeyLabel(HK_Key("util.arena")),              ArenaOpen,       170],
             ["Video → chat", VideoImportOpen, 150],
             ["Put shortcuts on the desktop", ObjBindMethod(this, "AiShortcuts"), 230]])
    }
    AiShortcuts(*) {
        made := AIS_MakeShortcuts()
        MsgBox(made = "" ? "No shortcut could be written — see the log."
                         : "On your desktop: " made " (named `"MMA …`").", "AI suite", 0x40)
    }

    DrawArchive(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open the archive", OpenArchive]])
    }

    DrawHotstrings(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open the manager", OpenHotstrings]])
    }

    DrawBranchBuilder(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open", OpenBranchBuilder, 100]])
    }

    DrawCalc(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open", OpenPayoutCalc, 100]])
    }

    DrawChatSim(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open", OpenChatSim, 100]])
    }

    DrawActivity(g, x, y, w) {
        return this.Buttons(g, x, y, [["Open the chart", ObjBindMethod(this, "OpenActivity")]])
    }
    OpenActivity(*) {
        CORE_OpenActivity()
    }

    DrawTypelog(g, x, y, w) {
        return this.Buttons(g, x, y,
            [["Open the folder", ObjBindMethod(this, "OpenFolder", MMA_USERDATA "\typelog\messages")]])
    }

    ; The recorder's three extras are their own feature switches, so they are
    ; shown here read-only and switched in Settings ▸ Features like the rest.
    DrawShiftLog(g, x, y, w) {
        this.lblShiftParts := g.Add("Text", "x" x " y" y " w" w, "")
        y += 24
        return this.Buttons(g, x, y,
            [["Open the folder", ObjBindMethod(this, "OpenFolder", MMA_USERDATA "\shiftlog")]])
    }

    OpenFolder(path, *) {
        if !DirExist(path) {
            MsgBox("Nothing has been recorded yet:`n`n" path, "Tools", 0x40)
            return
        }
        Run(path)
    }

    ; ── purchase sound ────────────────────────────────────────────────────────
    ; The sound is a FILE, not a key: services\llm\purchase_alert.py plays
    ; userdata\sounds\purchase.wav when it exists and Windows' tada.wav when it
    ; does not. So choosing one copies it there, and the default deletes it —
    ; nothing to save, and nothing for the two sides to disagree about.
    SoundPath() {
        custom := MMA_USERDATA "\sounds\purchase.wav"
        return FileExist(custom) ? custom : A_WinDir "\Media\tada.wav"
    }

    DrawPurchaseSound(g, x, y, w) {
        this.lblSound := g.Add("Text", "x" x " y" y " w" w, "")
        y += 24
        y := this.Buttons(g, x, y, [["Play it", ObjBindMethod(this, "PlaySound"), 100],
                                    ["Choose a sound…", ObjBindMethod(this, "ChooseSound")],
                                    ["Use the default", ObjBindMethod(this, "DefaultSound")]])
        this.PaintSound()
        return y
    }

    PaintSound() {
        this.lblSound.Value := InStr(this.SoundPath(), MMA_USERDATA)
            ? "Sound: your own (userdata\sounds\purchase.wav)"
            : "Sound: Windows' tada"
    }

    ; winmm PlaySound, NOT SoundPlay: SoundPlay goes through MCI, which keeps the
    ; file OPEN after it finishes, until the next SoundPlay or this window's
    ; process exits. So after one "Play it" (or the play that follows a choice)
    ; purchase.wav was locked, and the next "Choose a sound…" failed with "Could
    ; not copy that sound". PlaySound with SND_ASYNC (what purchase_alert.py's
    ; winsound uses too) holds no handle once it has loaded the file.
    PlaySound(*) {
        DllCall("winmm\PlaySoundW", "Str", this.SoundPath(), "Ptr", 0, "UInt", 0x20001)  ; SND_FILENAME | SND_ASYNC
    }

    ; Stop anything this window is playing before the file is replaced.
    StopSound() {
        DllCall("winmm\PlaySoundW", "Ptr", 0, "Ptr", 0, "UInt", 0)
    }

    ChooseSound(*) {
        f := FileSelect(3, A_WinDir "\Media\", "Pick the purchase sound", "Sounds (*.wav)")
        if (f = "")
            return
        this.StopSound()
        try {
            DirCreate(MMA_USERDATA "\sounds")
            FileCopy(f, MMA_USERDATA "\sounds\purchase.wav", true)
        } catch as e {
            MsgBox("Could not copy that sound:`n`n" e.Message, "Tools", 0x10)
            return
        }
        LOGI("ui.tools", "purchase sound set to " f)
        this.PaintSound()
        this.PlaySound()
    }

    DefaultSound(*) {
        this.StopSound()
        try FileDelete(MMA_USERDATA "\sounds\purchase.wav")
        this.PaintSound()
    }

    ; ── reply timers ──────────────────────────────────────────────────────────
    ;  Moved here from Settings ▸ General. Thresholds and colours for
    ;  screen\reply_box.ahk, which re-reads its cfg on every full pass — so a
    ;  saved change is live within seconds and nothing restarts.
    DrawReplyTimers(g, x, y, w) {
        ; Where the list is: a rectangle at your window size, on your monitor.
        ; No default is worth shipping, so "not calibrated" is said out loud.
        btn := g.Add("Button", "x" x " y" y " w150 h28", "Calibrate the list…")
        btn.OnEvent("Click", ObjBindMethod(this, "CalibrateReplyList"))
        this.lblRbCal := g.Add("Text", "x" (x + 160) " y" (y + 6) " w" (w - 160), "")
        y += 32
        ; A separate drag: one conversation, not the list. Measures how tall a
        ; row is and where the unread dot sits in it.
        btn := g.Add("Button", "x" x " y" y " w150 h28", "Calibrate a row…")
        btn.OnEvent("Click", ObjBindMethod(this, "CalibrateReplyRow"))
        this.lblRbRow := g.Add("Text", "x" (x + 160) " y" (y + 6) " w" (w - 160), "")
        y += 38

        ; Five rows for four defaults, so adding a tier is filling in a blank. A
        ; row with no minutes is not a tier — that is how one is deleted. The
        ; swatch is a Progress bar: Windows ignores a Button's background colour.
        g.SetFont("s8")
        g.Add("Text", "x" x " y" y " w120", "After (minutes)")
        g.Add("Text", "x" (x + 84) " y" y " w120", "Colour")
        g.SetFont("s9")
        y += 18
        this.edRbMins := [], this.swRbCol := [], this.rbCols := []
        Loop 5 {
            i   := A_Index
            raw := Trim(IniRead(MMA_CFG, "ReplyBox", "Tier" i, ""))
            t   := (raw != "") ? RB_ParseTier(raw) : 0
            this.rbCols.Push(t ? t.col : "")
            this.edRbMins.Push(g.Add("Edit", "x" x " y" y " w52 Number", t ? t.mins : ""))
            this.swRbCol.Push(g.Add("Progress", "x" (x + 60) " y" (y + 3) " w52 h18"
                                              . " Background" (t ? t.col : "808080"), 0))
            btn := g.Add("Button", "x" (x + 120) " y" y " w86 h24", "Colour…")
            btn.OnEvent("Click", ObjBindMethod(this, "PickTierColour", i))
            y += 28
        }
        y += 6

        g.Add("Text", "x" x " y" (y + 3) " w96", "Row height:")
        this.edRbRowH := g.Add("Edit", "x" (x + 100) " y" y " w52 Number",
                               _IniInt(MMA_CFG, "ReplyBox", "RowH", 105))
        g.Add("Text", "x" (x + 166) " y" (y + 3) " w72", "Above dot:")
        ; -1 is "nobody has measured this"; blank says the same and invites no one
        ; to type -1 back.
        off := _IniInt(MMA_CFG, "ReplyBox", "RowOffsetY", -1)
        this.edRbOff := g.Add("Edit", "x" (x + 240) " y" y " w52 Number", off < 0 ? "" : off)
        g.Add("Text", "x" (x + 306) " y" (y + 3) " w52", "Border:")
        this.edRbBorder := g.Add("Edit", "x" (x + 362) " y" y " w52 Number",
                                 _IniInt(MMA_CFG, "ReplyBox", "BorderW", 4))
        y += 30
        ; On by default so MMA's own scan reads Infloww and not its own borders;
        ; the cost is that the frames are invisible to any screen capture.
        this.chkRbCapture := g.Add("Checkbox", "x" x " y" y " w" w
                                 . (_IniInt(MMA_CFG, "ReplyBox", "ExcludeFromCapture", 1)
                                       ? " Checked" : ""),
                                   "Keep the boxes out of screenshots")
        y += 26
        this.PaintReplyBoxState()
        return y
    }

    ; Drag a box round the conversation list; stored in the Infloww window's
    ; CLIENT coordinates, so moving or maximising Infloww does not break it.
    ; Written NOW rather than at Save: the drag is the measurement, and there is
    ; no control holding it for Save to re-read.
    CalibrateReplyList(*) {
        win := Trim(IniRead(MMA_CFG, "ReplyBox", "WinMatch", "Infloww Messages"))
        if !WinExist(win) {
            MsgBox("No window matching '" win "' is open.`n`nOpen Infloww Messages"
                 . " first — the region is stored relative to that window.",
                   "Reply timers", 0x30)
            return
        }
        ; Hidden for the drag, or you would be drawing round this window.
        this.tg.Hide()
        Sleep 250
        rect := OcrSelectRegion()
        this.tg.Show()
        if !rect {
            LOGI("ui.replybox", "list calibration cancelled — the region is unchanged")
            return
        }
        ccx := 0, ccy := 0
        try WinGetClientPos(&ccx, &ccy, , , win)
        catch as e {
            MsgBox("Could not read where '" win "' is on screen.`n`n" e.Message,
                   "Reply timers", 0x10)
            return
        }
        cx := rect.x - ccx, cy := rect.y - ccy
        if (cx < 0 || cy < 0) {
            MsgBox("That box starts outside the '" win "' window.`n`nDraw it inside"
                 . " the Infloww window, around the list of conversations.",
                   "Reply timers", 0x30)
            return
        }
        reg := cx "," cy "," rect.w "," rect.h
        try IniWrite(reg, MMA_CFG, "ReplyBox", "Region")
        LOGI("ui.replybox", "list region calibrated to " reg " (client coords of '" win "')")
        this.PaintReplyBoxState()
    }

    ; Drag a box round ONE unread conversation: its height is the row height, and
    ; where the dot turned out to be inside it is the offset — found with the SAME
    ; scan the service uses (reply_scan.ahk), so the two cannot disagree. Writes to
    ; the boxes, not the cfg, so you can check it and still back out.
    CalibrateReplyRow(*) {
        win := Trim(IniRead(MMA_CFG, "ReplyBox", "WinMatch", "Infloww Messages"))
        if !WinExist(win) {
            MsgBox("No window matching '" win "' is open.`n`nOpen Infloww Messages"
                 . " first.", "Reply timers", 0x30)
            return
        }
        this.tg.Hide()
        Sleep 250
        rect := OcrSelectRegion()
        this.tg.Show()
        if !rect {
            LOGI("ui.replybox", "row calibration cancelled")
            return
        }
        ; A little wider than the box drawn: the dot is ~20px in from the list's
        ; right edge and nobody drags to the pixel.
        d    := RBS_Defaults()
        band := _IniInt(MMA_CFG, "ReplyBox", "DotBandW", d.band)
        gw   := Max(rect.w, band + 8)
        img  := PILL_Grab(rect.x + rect.w - gw, rect.y, gw, rect.h)
        dot  := img ? RBS_DotNearestCentre(img, this.RbDotOpts(d)) : 0
        if !dot {
            MsgBox("No unread dot was found inside that box.`n`nDraw it round a"
                 . " conversation that IS unread (the little orange dot on the"
                 . " right), and include the dot.", "Reply timers", 0x30)
            return
        }
        this.edRbRowH.Value := rect.h
        this.edRbOff.Value  := dot.cy - rect.y
        LOGI("ui.replybox", "row calibrated: height " rect.h "px, dot "
                          . (dot.cy - rect.y) "px below the top — press Save to keep it")
        this.PaintReplyBoxState()
    }

    ; The dot-scan options as the overlay reads them, defaulted from RBS_Defaults
    ; so this window and the service cannot fall back to different numbers.
    RbDotOpts(d) {
        hex := RB_CleanHex(IniRead(MMA_CFG, "ReplyBox", "DotColor", "FF7C71"))
        col := 0xFF7C71
        if (hex != "")
            try col := Integer("0x" hex)
        return {color: col,
                tol:   Max(0, _IniInt(MMA_CFG, "ReplyBox", "DotTol",   d.tol)),
                band:  Max(8, _IniInt(MMA_CFG, "ReplyBox", "DotBandW", d.band)),
                step:  Max(1, Min(4, _IniInt(MMA_CFG, "ReplyBox", "DotStep", d.step))),
                minPx: Max(1, _IniInt(MMA_CFG, "ReplyBox", "DotMinPx", d.minPx)),
                maxPx: Max(1, _IniInt(MMA_CFG, "ReplyBox", "DotMaxPx", d.maxPx)),
                maxH:  Max(2, _IniInt(MMA_CFG, "ReplyBox", "DotMaxH",  d.maxH)),
                gap:   Max(1, _IniInt(MMA_CFG, "ReplyBox", "DotGap",   d.gap))}
    }

    PickTierColour(idx, *) {
        start  := (this.rbCols[idx] != "") ? this.rbCols[idx] : "FFD24A"
        picked := THEME_ChooseColour(start, "FFD24A")
        if (picked = "")
            return
        this.rbCols[idx] := picked
        try this.swRbCol[idx].Opt("Background" picked)
        try WinRedraw(this.pg)
    }

    ; "Calibrated but off" and "on but never calibrated" are both states people
    ; reach; the on/off half is the section's own state line, so this says only
    ; what the calibration is.
    PaintReplyBoxState() {
        try {
            cur := Trim(IniRead(MMA_CFG, "ReplyBox", "Region", ""))
            if (cur = "") {
                this.lblRbCal.SetFont("cRed")
                this.lblRbCal.Value := "Not calibrated — nothing is painted until you"
                                     . " draw a box round the conversation list."
            } else {
                p := StrSplit(cur, ",")
                this.lblRbCal.SetFont("cGreen")
                this.lblRbCal.Value := "Region set: " (p.Length >= 4 ? p[3] "x" p[4] : "?")
                                     . " at " (p.Length >= 2 ? p[1] "," p[2] : "?")
                                     . " inside the Infloww window."
            }
            rh  := Trim(this.edRbRowH.Value)
            rof := Trim(this.edRbOff.Value)
            if (rof = "") {
                this.lblRbRow.SetFont("cGray")
                this.lblRbRow.Value := "Row " (rh = "" ? "?" : rh) "px, dot assumed"
                                     . " halfway — boxes will sit slightly high."
            } else {
                this.lblRbRow.SetFont("cGreen")
                this.lblRbRow.Value := "Row " rh "px, dot " rof "px below the top."
            }
        }
    }

    ; Rewritten whole, because deleting a tier is a RENUMBER: RB_Tiers stops at
    ; the first gap, so the surviving rows are written back from 1 and the rest
    ; deleted. The Region is not here — the list drag writes it.
    SaveReplyTimers() {
        kept := []
        for i, ed in this.edRbMins {
            m := Trim(ed.Value)
            if (m = "" || !RegExMatch(m, "^\d+$"))
                continue
            c := this.rbCols[i]
            if (c = "")
                continue
            kept.Push({mins: Integer(m), col: c})
        }
        RB_SortTiers(kept)
        for i, t in kept
            IniWrite(t.mins "," t.col, MMA_CFG, "ReplyBox", "Tier" i)
        i := kept.Length + 1
        while (i <= 32) {
            try IniDelete(MMA_CFG, "ReplyBox", "Tier" i)
            i++
        }
        ; Clamped to the bounds RB_Cfg enforces, so a typed 0 is corrected where
        ; it is visible on the next open.
        rowH := Max(8, SW_Num(this.edRbRowH, 104, 8))
        IniWrite(rowH, MMA_CFG, "ReplyBox", "RowH")
        IniWrite(Max(1, Min(24, SW_Num(this.edRbBorder, 4, 1))), MMA_CFG, "ReplyBox", "BorderW")
        offTxt := Trim(this.edRbOff.Value)
        IniWrite(offTxt = "" ? -1 : Max(0, Min(rowH, SW_Num(this.edRbOff, 0, 0))),
                 MMA_CFG, "ReplyBox", "RowOffsetY")
        IniWrite(this.chkRbCapture.Value ? 1 : 0, MMA_CFG, "ReplyBox", "ExcludeFromCapture")
        LOGI("ui.replybox", kept.Length " reply-timer tier(s) saved; row " rowH
                          . "px, offset " (offTxt = "" ? "auto" : offTxt))
    }

    ; ── on / off / restart, and the state lines ───────────────────────────────
    ToolOn(id, *) {
        TOOLS_Set({id: id}, true)
        this.Refresh()
        try RefreshToolsLabel()
    }
    ToolOff(id, *) {
        TOOLS_Set({id: id}, false)
        this.Refresh()
        try RefreshToolsLabel()
    }
    ToolRestart(id, *) {
        TOOLS_Restart({id: id})
        this.Refresh()
        try RefreshToolsLabel()
    }

    Refresh(*) {
        ; The timer can outlive the window by a tick; a throw on a timer thread is
        ; a dialog every second.
        try {
            DetectHiddenWindows true
            easy := MODE_IsEasy()
            for st in this.states {
                on := TOOLS_On(st.id)
                if st.on {
                    up := SVC_Running(st.id)
                    ; "on but not running" is the one worth seeing: it is what a
                    ; missing Python or a crashed detector looks like.
                    if up
                        this.Paint(st.lbl, "c3A9A50", Chr(0x25CF) " running")
                    else if on
                        this.Paint(st.lbl, "cD08A20", Chr(0x25CF) " on, but not running")
                    else
                        this.Paint(st.lbl, "c808080", Chr(0x25CB) " off")
                    st.on.Enabled      := !on || !up
                    st.off.Enabled     := on || up
                    st.restart.Enabled := on || up
                } else {
                    this.Paint(st.lbl, on ? "c3A9A50" : "c808080",
                               on ? Chr(0x25CF) " on" : Chr(0x25CB) " off — switch on in Settings ▸ Features")
                }
                if (easy && on)
                    this.Paint(st.lbl, "cD08A20", Chr(0x25CF) " on, but Easy mode keeps it off")
            }
            if this.HasProp("lblShiftParts")
                this.lblShiftParts.Value := "Also saving: message times "
                    . (FEAT_Raw("shiftTimes") ? Chr(0x25CF) : Chr(0x25CB))
                    . "   fan panel " (FEAT_Raw("shiftPanel") ? Chr(0x25CF) : Chr(0x25CB))
                    . "   pictures " (FEAT_Raw("shiftMedia") ? Chr(0x25CF) : Chr(0x25CB))
                    . "   (switch each in Settings ▸ Features)"
        } catch {
            SetTimer(this._refresh, 0)
        }
    }

    ; Text and colour, only when they changed — SetFont on every tick flickers.
    Paint(lbl, colour, text) {
        if (lbl.Value != text) {
            lbl.SetFont(colour)
            lbl.Value := text
        }
    }

    ; ── scrolling ─────────────────────────────────────────────────────────────
    MaxPos() {
        return Max(0, Round((this.pageH - this.vpH) * this.k))
    }

    ; SCROLLINFO: cbSize, fMask, nMin, nMax, nPage, nPos, nTrackPos.
    SetRange() {
        si := Buffer(28, 0)
        NumPut("UInt", 28, "UInt", 0x17, "Int", 0, "Int", Round(this.pageH * this.k) - 1,
               "UInt", Round(this.vpH * this.k), "Int", this.pos, si)   ; SIF_RANGE|PAGE|POS
        DllCall("SetScrollInfo", "Ptr", this.vp.Hwnd, "Int", 1, "Ptr", si, "Int", 1)
    }

    ScrollTo(pos) {
        pos := Max(0, Min(this.MaxPos(), Round(pos)))
        if (pos = this.pos)
            return
        this.pos := pos
        si := Buffer(28, 0)
        NumPut("UInt", 28, "UInt", 0x4, si)                     ; SIF_POS
        NumPut("Int", pos, si, 20)
        DllCall("SetScrollInfo", "Ptr", this.vp.Hwnd, "Int", 1, "Ptr", si, "Int", 1)
        ; Gui.Move DOES scale its numbers (Show's x/y does not), so it is handed
        ; Gui units — measured: passing pixels overshot by the DPI factor again.
        this.pg.Move(0, -Round(pos / this.k))
        this.SyncNav()
    }

    ; Light the list row for the section at the top of the view.
    SyncNav() {
        idx := 1
        for i, s in this.secs
            if (s.top * this.k <= this.pos + 12 * this.k)
                idx := i
        if (this.nav.Value != idx)
            this.nav.Value := idx
    }

    NavPicked(*) {
        i := this.nav.Value
        if (i >= 1 && i <= this.secs.Length)
            this.ScrollTo((this.secs[i].top - 6) * this.k)
    }

    OnVScroll(wParam, lParam, msg, hwnd) {
        if (hwnd != this.vp.Hwnd)
            return
        code := wParam & 0xFFFF
        switch code {
            case 0: this.ScrollTo(this.pos - 40 * this.k)                   ; SB_LINEUP
            case 1: this.ScrollTo(this.pos + 40 * this.k)                   ; SB_LINEDOWN
            case 2: this.ScrollTo(this.pos - (this.vpH - 40) * this.k)      ; SB_PAGEUP
            case 3: this.ScrollTo(this.pos + (this.vpH - 40) * this.k)      ; SB_PAGEDOWN
            case 4, 5:                                          ; THUMBPOSITION / THUMBTRACK
                ; The 16-bit position in wParam overflows on a tall page; the
                ; track position from GetScrollInfo does not.
                si := Buffer(28, 0)
                NumPut("UInt", 28, "UInt", 0x10, si)            ; SIF_TRACKPOS
                DllCall("GetScrollInfo", "Ptr", this.vp.Hwnd, "Int", 1, "Ptr", si)
                this.ScrollTo(NumGet(si, 24, "Int"))
            case 6: this.ScrollTo(0)                            ; SB_TOP
            case 7: this.ScrollTo(this.MaxPos())                ; SB_BOTTOM
        }
        return 0
    }

    ; The wheel goes to whatever has focus, so this asks where the MOUSE is: over
    ; the page, it scrolls the page — even when a dropdown under the pointer would
    ; otherwise have eaten the notch and changed its value.
    OnWheel(wParam, lParam, msg, hwnd) {
        MouseGetPos(, , &win, &ctl, 2)
        if (win != this.tg.Hwnd)
            return
        if !(ctl = this.vp.Hwnd || ctl = this.pg.Hwnd
             || DllCall("IsChild", "Ptr", this.vp.Hwnd, "Ptr", ctl))
            return
        delta := (wParam >> 16) & 0xFFFF
        if (delta >= 0x8000)
            delta -= 0x10000
        this.ScrollTo(this.pos - delta / 120 * ToolsWindow.WHEEL * this.k)
        return 0
    }

    ; Taller window, taller viewport and list. The page keeps its width.
    OnSize(gg, minMax, w, h) {
        if (minMax = -1)
            return
        try {
            navH := h - ToolsWindow.BAR_H - 16
            this.nav.Move(, , , navH)
            this.vpH := navH
            this.vp.Show("w" this.vpW " h" navH " NoActivate")
            this.SetRange()
            this.ScrollTo(Min(this.pos, this.MaxPos()))
            by := h - ToolsWindow.BAR_H + 8
            this.btnSave.Move(, by)
            this.btnClose.Move(, by)
            this.lblSaved.Move(, by + 8)
        }
    }

    ; ── save / close ──────────────────────────────────────────────────────────
    Save(*) {
        for rows in this.rowSets
            SW_FieldPageSave(rows)
        this.SaveReplyTimers()
        this.lblSaved.SetFont("cGreen")
        this.lblSaved.Text := "Saved. A running tool picks most changes up after"
                            . " its Restart."
        SetTimer(ObjBindMethod(this, "ClearSaved"), -5000)
        ; Restarts autoword if its ini changed. LAST, with nothing of Save left to
        ; run: it waits for the old autoword to exit, and that wait lets clicks
        ; through — a Close in that gap destroyed the window under the rest of a
        ; Save before (see settings_window.ahk).
        try CORE_AutowordModelCheck()
    }

    ClearSaved(*) {
        try this.lblSaved.Text := ""
    }

    Close(*) {
        global TOOLS_WIN
        SetTimer(this._refresh, 0)
        OnMessage(0x115, this._onScroll, 0)
        OnMessage(0x20A, this._onWheel, 0)
        TOOLS_WIN := 0
        try this.tg.Destroy()
        try RefreshToolsLabel()
    }
}
