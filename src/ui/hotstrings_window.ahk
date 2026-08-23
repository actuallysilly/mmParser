#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../hotstrings/index.ahk"
#Include "../hotstrings/overloads.ahk"
; The "Startup scripts" button below. It belongs to this window because the files
; it starts and stops are the very files this window indexes.
#Include "startup_scripts.ahk"
; MMA_MSG_ADD_HOTKEY, for the "Add hotstring" button. Included by name rather than
; relied on through index.ahk's chain — a file that names a constant includes the
; file that defines it, and AHK loads any given file once.
#Include "../core/messages.ahk"
; THEME_BoldButtons. This window keeps its own violet palette (it is not one of
; the themed windows), but "are buttons bold" has one answer everywhere.
#Include "../core/theme.ahk"
; HKP_GrabKey and HKP_KeyLabel, for the "Hotkey" button — the same capture the
; Hotkeys tab uses, so a key is recorded here exactly as it is recorded there
; (chords, mouse buttons, Esc to cancel, Backspace to clear). Reaching for the
; panel's file rather than reimplementing it also brings core/hotkeys.ahk, which
; is where the binding is read and written. A second key-capture would be a
; second answer to "what did the user just press".
#Include "hotkeys_panel.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings_window.ahk — a searchable window over the whole message library.
; ───────────────────────────────────────────────────────────────────────────────
;  Reads every hotstring via hotstrings/index.ahk (see there) and lists them so you
;  can find one by TRIGGER or by the TEXT inside it: browse, search, jump to the
;  source line, and turn a trigger into an OVERLOAD (several variants, one of which
;  fires) via hotstrings/overloads.ahk.
;
;  Run it on its own (double-click). Editing is deliberately one-way: overload
;  variants live in hotstring_overloads.ini and never touch your sources. DELETE is
;  the single exception — it cuts the block out of the .ahk file itself, after a
;  confirmation and a .bak.
; ═══════════════════════════════════════════════════════════════════════════════

; ── palette (dark violet, in the Infloww family). RRGGBB, no 0x. ──
BG      := "15141C"      ; window
SURFACE := "201E2B"      ; detail pane
LISTBG  := "1B1A24"      ; list
FIELDBG := "2A2836"      ; search box
TXT     := "E6E4EE"      ; primary text
MUTED   := "8E8AA6"      ; secondary text
ACCENT  := "B89CFF"      ; violet accent

; Built at runtime so the source file stays pure-ASCII (avoids .ahk encoding traps).
GLYPH_STAR  := Chr(0x2726)
GLYPH_ARROW := Chr(0x25B8)

gRecords   := HSI_Build()
gShown     := 0
gOverloads := OL_Load()        ; trigger -> {file, options, variants}; refreshed on save/rescan

; adjustable text size for the list + showcase, remembered across runs in mass_gui.cfg
;
; MMA_CFG, not `HSI_DIR "\mass_gui.cfg"`. HSI_DIR is content\ — right for finding
; the hotstring SOURCE files it indexes, wrong for the config, which lives in
; userdata\. Built that way, this window read and wrote a whole second file named
; mass_gui.cfg inside content\, which it CREATED on the first font-size change:
; the setting appeared to stick (it read back its own file) while being invisible
; to every other part of MMA, and sat one folder away from the real config under
; the same name.
gSizes    := ["9", "10", "11", "12", "13", "14", "16", "18", "20", "22", "24"]
gFontSize := LOG_IniInt(MMA_CFG, "Hotstrings", "FontSize", 11)

; sort order, remembered across runs. "File order" is how the library reads on
; disk and stays the default; the date orders answer "what did I write lately?"
gSortModes := ["File order", "Newest first", "Oldest first", "Trigger A-Z"]
gSortMode  := LOG_IniInt(MMA_CFG, "Hotstrings", "Sort", 1)
if (gSortMode < 1 || gSortMode > gSortModes.Length)
    gSortMode := 1

; ── window ──
;  ─── THE FOOTER IS WHAT SETS THE WIDTH ──────────────────────────────────────
;  It is two clusters that grow towards each other: six buttons pinned to the
;  LEFT edge, and Sort + Text size pinned to the RIGHT. Neither shrinks, so the
;  window has a hard minimum — and it was set as a round number rather than
;  measured, which is why the buttons ran into the dropdowns.
;
;  Measured, at the sizes the controls are actually created with:
;
;      left  cluster   16 .. 674    Open source · Copy trigger · Rescan ·
;                                   Overload · Hotkey · Delete
;      right cluster   w-310 .. w   Sort [dropdown] · Text size [dropdown]
;
;  674 + 310 = 984 with the two touching, so the old 1000-wide default left
;  sixteen pixels between them and the old MinSize900 let them overlap — the
;  buttons were there, drawn underneath the dropdowns. HSW_W is that sum plus a
;  gap you can see, and HSW_MIN is the point below which they would touch again.
;
;  The count changed twice over: "Hotkey" arrived, and "Startup scripts" left for
;  the top row. That is not shuffling — the footer is the buttons that act on the
;  SELECTED ROW, and Startup scripts acts on the files. It sat here only because
;  this is where buttons went, which is also why it was the one that finally
;  pushed the cluster into the dropdowns.
global HSW_W   := 1120     ; default width — the sum above, with room to breathe
global HSW_H   := 600
global HSW_MIN := 1020     ; 984 + a 36px gap. Below this the two clusters meet.
MainGui := Gui("+Resize +MinSize" HSW_MIN "x460",
               "Hotstrings  " Chr(0x2014) "  message library")
MainGui.BackColor := BG
MainGui.OnEvent("Size",   OnSize)
MainGui.OnEvent("Close",  GuiClosed)
MainGui.OnEvent("Escape", GuiClosed)

; title + live count
MainGui.SetFont("s15 Bold c" ACCENT, "Segoe UI")
MainGui.Add("Text", "x16 y12 w190", GLYPH_STAR "  Hotstrings")
MainGui.SetFont("s11 Norm c" MUTED, "Segoe UI")
countTxt := MainGui.Add("Text", "x600 y21 w360 Right", "")

; ── Add hotstring ─────────────────────────────────────────────────────────────
;  Was "Add Hotkey", on the main window's bottom strip. It is called what it makes:
;  a HOTSTRING in one of the message files — the very files this window indexes,
;  searches, overloads and deletes. (The dialog it opens is shared with the
;  grab-selection hotkey and still calls itself Add Hotkey; renaming the button is
;  what matters here, because this is where you go looking to add one.)
;
;  Up here with the title rather than in the footer: every button in the footer
;  acts on the SELECTED ROW, and this one does not. (The right-hand end of that
;  row is also spoken for by the sort and size controls.)
MainGui.SetFont("s10 c" TXT, "Segoe UI")
btnAddHk := MainGui.Add("Button", "x216 y13 w150 h30", "Add hotstring" Chr(0x2026))
btnAddHk.OnEvent("Click", OpenAddHotkeyWindow)
; Up here for the same reason as Add hotstring, and it used to be in the footer
; with the row actions: it acts on the FILES, not on the hotstring you have
; selected. See startup_scripts.ahk for why it lives in this window at all.
btnStartup := MainGui.Add("Button", "x376 y13 w130 h30", "Startup scripts")
btnStartup.OnEvent("Click", (*) => OpenStartupScripts(MainGui.Hwnd))

; search
MainGui.SetFont("s12 c" TXT, "Segoe UI")
searchEd := MainGui.Add("Edit", "x16 y48 w948 h32 Background" FIELDBG)
searchEd.OnEvent("Change", OnSearch)
CueBanner(searchEd, "Search trigger or message text" Chr(0x2026) "   (spaces = all terms must match)")

; list (full width; the showcase sits beneath it)
MainGui.SetFont("s11 c" TXT, "Segoe UI")
LV := MainGui.Add("ListView", "x16 y90 w948 h250 Background" LISTBG,
                  ["Trigger", "Message preview", "#", "Var", "Key", "File", "Added",
                   "idx"])
LV.OnEvent("ItemFocus",   OnRowFocus)
LV.OnEvent("DoubleClick", OnRowOpen)
LV.ModifyCol(1, 170)
LV.ModifyCol(2, 350)
LV.ModifyCol(3, "50 Integer Center")
LV.ModifyCol(4, "50 Center")       ; variant count when overloaded, else blank
LV.ModifyCol(5, 90)                ; the key bound to it, blank for the great majority
LV.ModifyCol(6, 120)
LV.ModifyCol(7, 90)                ; date the hotstring was added, blank if unstamped
LV.ModifyCol(8, 0)                 ; hidden: master index into gRecords, rides with its row

; showcase / detail pane — full width, word-wrapped so long messages read cleanly
MainGui.SetFont("s12 c" TXT, "Segoe UI")
detailEd := MainGui.Add("Edit", "x16 y350 w948 h170 ReadOnly +VScroll Background" SURFACE)

; footer
MainGui.SetFont("s10 c" TXT, "Segoe UI")
btnOpen   := MainGui.Add("Button", "x16 y534 w112 h30", "Open source")
btnCopy   := MainGui.Add("Button", "x134 y534 w112 h30", "Copy trigger")
btnRescan := MainGui.Add("Button", "x252 y534 w92 h30", "Rescan")
btnOver   := MainGui.Add("Button", "x352 y534 w118 h30", "Overload" Chr(0x2026))
; ── a key for a message you send constantly ───────────────────────────────────
;  Optional, per hotstring, and it never replaces the trigger — both fire the
;  same thing. See HotstringKeys_Register in core/utils.ahk for what happens when
;  it is pressed, and the [hotstring] block at the bottom of core/hotkeys.ahk for
;  where it is stored.
btnKey    := MainGui.Add("Button", "x476 y534 w100 h30", "Hotkey" Chr(0x2026))
btnDelete := MainGui.Add("Button", "x582 y534 w92 h30", "Delete")
btnOpen.OnEvent("Click",   OpenSelected)
btnCopy.OnEvent("Click",   CopySelected)
btnRescan.OnEvent("Click", RescanFiles)
btnOver.OnEvent("Click",   EditOverload)
btnKey.OnEvent("Click",    SetHotstringKey)
btnDelete.OnEvent("Click", DeleteSelected)
; ask-vs-random is NOT global: each overloaded trigger carries its own mode,
; set in the variant editor and stored with its variants.

; sort control
MainGui.SetFont("s10 c" MUTED, "Segoe UI")
lblSort := MainGui.Add("Text", "x580 y540 w34 h22 +0x200 Right", "Sort")
MainGui.SetFont("s10 c" TXT, "Segoe UI")
sortDD := MainGui.Add("DropDownList", "x618 y536 w120", gSortModes)
sortDD.Choose(gSortMode)
sortDD.OnEvent("Change", OnSortMode)

; text-size control — applies to the list + showcase, remembered across runs
MainGui.SetFont("s10 c" MUTED, "Segoe UI")
lblSize := MainGui.Add("Text", "x836 y540 w62 h22 +0x200 Right", "Text size")
MainGui.SetFont("s10 c" TXT, "Segoe UI")
sizeDD := MainGui.Add("DropDownList", "x902 y536 w62", gSizes)
sizeIdx := 3
for i, sv in gSizes
    if (Integer(sv) = gFontSize)
        sizeIdx := i
sizeDD.Choose(sizeIdx)
sizeDD.OnEvent("Change", OnFontSize)

ApplyDarkTheme()
ApplyContentFont(gFontSize)
PopulateList("")
; ── lay the window out BEFORE it is shown ─────────────────────────────────────
;  Every control above is created at coordinates for a 980-wide window, and the
;  window opens at HSW_W (1120). OnSize then moved the whole right-hand cluster
;  ~300px to the right on the first WM_SIZE — i.e. while the window was already on
;  screen and painted.
;
;  That is "Sort" and its dropdown appearing TWICE: once ghosted at the creation
;  position, sitting on top of the Delete button, and once where they belong.
;  Moving a child window does not repaint the parent's background behind where it
;  used to be, and this window paints a custom dark BackColor, so the pixels the
;  controls vacated kept what they had.
;
;  Running the layout while the window is still HIDDEN means the first paint is
;  already the right one, and the WM_SIZE that follows Show finds everything where
;  it wants it. (Control.Move works on a hidden Gui; it is WinGetPos on the window
;  ITSELF that cannot see one.)
OnSize(MainGui, 0, HSW_W, HSW_H)
MainGui.Show("w" HSW_W " h" HSW_H)
; Lay the window out through the SAME code a resize uses, rather than trusting the
; x/w numbers each control was created with.
;
; Those numbers were written for a 1000px window and are now wrong by 120 — but
; more to the point they were a second copy of the layout that only agreed with
; OnSize by coincidence, and a Gui does not fire Size on Show. So the window you
; got before touching it was laid out by one set of rules and the window you got
; after dragging it by a different set. One rule now: the creation coordinates
; just have to be sane enough to exist.
OnSize(MainGui, 0, HSW_W, HSW_H)

; ═══════════════════════════════════════════════════════════════════════════════
;  behaviour
; ═══════════════════════════════════════════════════════════════════════════════

OnSearch(*) {
    global searchEd
    PopulateList(searchEd.Value)
}

GuiClosed(*) {
    ExitApp()
}

; Ask the main window to open its Add Hotkey dialog.
;
; It cannot be built here. The dialog is made out of main_window.ahk's globals —
; the account-file list, the default target file, the snd()/SendText()/Sendt()
; writers — and this window is a separate PROCESS, so there is nothing to call.
; The button therefore asks the window that owns the dialog to open it, the same
; way sequences.ahk asks it to parse a mass.
;
; DetectHiddenWindows because the window being addressed is the script's own
; message window, which is hidden. Saved and restored rather than set once at the
; top of the file: it is a per-thread setting and the rest of this window has no
; business seeing hidden windows.
;
; AllowSetForegroundWindow, or the dialog opens BEHIND this one — the foreground
; right belongs to whoever the user last clicked in, which is us, and it has to be
; handed over deliberately.
OpenAddHotkeyWindow(*) {
    global MMA_SRC_GUI, MMA_MSG_ADD_HOTKEY
    win  := MMA_SRC_GUI " ahk_class AutoHotkey"
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    try {
        if !WinExist(win) {
            MsgBox("The Add hotstring window is opened by MMA's main window, and"
                 . " that is not running.`n`nStart MMA, then press this again.",
                   "Add hotstring", 0x30)
            return
        }
        try DllCall("AllowSetForegroundWindow", "UInt", WinGetPID(win))
        PostMessage(MMA_MSG_ADD_HOTKEY, 0, 0, , win)
    }
    finally
        DetectHiddenWindows prev
}

; Rebuild the list to show only records matching the query. Space-separated terms
; are ANDed, matched case-insensitively against the trigger AND the message text —
; that's the "search by text in the string" the manager exists for.
PopulateList(query) {
    global gRecords, gShown, LV, countTxt, detailEd
    terms := []
    for t in StrSplit(Trim(query), " ")
        if (t != "")
            terms.Push(t)

    LV.Opt("-Redraw")
    LV.Delete()
    shown := 0
    for _, i in SortedIndices() {
        r := gRecords[i]
        if MatchRec(r, terms) {
            LV.Add(, r.trigger, FlattenOneLine(r.preview), r.steps.Length, VarCell(r.trigger),
                     KeyCell(r.trigger), HsFileLabel(r.file), AddedCell(r.added), i)
            shown++
        }
    }
    LV.Opt("+Redraw")

    gShown := shown
    countTxt.Value := (shown = gRecords.Length)
        ? gRecords.Length " hotstrings"
        : shown " of " gRecords.Length " shown"

    if shown {
        LV.Modify(1, "Select Focus Vis")
        OnRowFocus(LV, 1)
    } else {
        detailEd.Value := "No matches."
    }
}

; The order rows are listed in: an array of indices into gRecords. Filtering runs
; over this, so search results keep whatever order is selected.
;
; Records with no "; @added" stamp cannot be dated, and guessing would be worse
; than admitting it: they sort together at the END of both date orders, keeping
; their file order among themselves. So "Newest first" means "newest known first",
; never "unstamped is ancient".
SortedIndices() {
    global gRecords, gSortMode
    idx := []
    Loop gRecords.Length
        idx.Push(A_Index)
    if (gSortMode = 1)
        return idx

    keyOf(i) {
        r := gRecords[i]
        return gSortMode = 4 ? StrLower(r.trigger) : r.added
    }
    less(a, b) {
        ka := keyOf(a), kb := keyOf(b)
        if (gSortMode = 4)
            return StrCompare(ka, kb) < 0
        if (ka = "" || kb = "")
            return (ka != "" && kb = "")        ; dated before undated, either way round
        return gSortMode = 2 ? StrCompare(ka, kb) > 0 : StrCompare(ka, kb) < 0
    }
    ; Insertion sort: ~120 records, and it is stable, which is what keeps the
    ; undated tail and same-day entries in their original file order.
    Loop idx.Length - 1 {
        i := A_Index + 1
        v := idx[i]
        j := i - 1
        while (j >= 1 && less(v, idx[j])) {
            idx[j + 1] := idx[j]
            j--
        }
        idx[j + 1] := v
    }
    return idx
}

; "2026-07-25 14:03" -> "2026-07-25". The clock time is noise in a list column;
; it stays in the file for anyone who wants it.
AddedCell(added) {
    return added = "" ? "" : SubStr(added, 1, 10)
}

OnSortMode(ctrl, *) {
    global gSortMode, searchEd
    gSortMode := ctrl.Value
    try IniWrite(gSortMode, MMA_CFG, "Hotstrings", "Sort")
    PopulateList(searchEd.Value)
}

MatchRec(r, terms) {
    if !terms.Length
        return true
    hay := r.trigger " " r.preview
    for t in terms
        if !InStr(hay, t, false)          ; case-insensitive substring
            return false
    return true
}

OnRowFocus(ctrl, row) {
    global gRecords, detailEd
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, 8))
    if (idx < 1 || idx > gRecords.Length)
        return
    detailEd.Value := BuildDetail(gRecords[idx])
}

; The showcase pane: the message, and nothing else. The trigger, source file and
; line already sit in the list columns, and which function sends a step is an
; implementation detail — repeating them here just buried the text you came to read.
BuildDetail(r) {
    global gOverloads
    out := ""
    if !r.steps.Length {
        out .= "(empty " Chr(0x2014) " no send steps)`r`n"
    } else {
        for st in r.steps {
            t := StrReplace(st.text, "`r`n", "`n")     ; normalise, then give the Edit CRLFs
            t := StrReplace(t, "`n", "`r`n")
            out .= t "`r`n`r`n"
        }
    }
    if gOverloads.Has(r.trigger) {
        e := gOverloads[r.trigger]
        out .= "`r`n== OVERLOADED " Chr(0x2014) " " e.variants.Length
             . " variants, pick: " e.mode " (the body above is bypassed) ==`r`n`r`n"
        for vi, steps in e.variants {
            out .= "[" vi "]`r`n"
            for st in steps {
                t := StrReplace(StrReplace(st.text, "`r`n", "`n"), "`n", "`r`n")
                out .= "     " t "`r`n"
            }
            out .= "`r`n"
        }
    }
    return RTrim(out, "`r`n")
}

; "acc\TEMP.ahk" -> "TEMP", "general.ahk" -> "general". Display only — every path
; the code actually opens still goes through r.file.
HsFileLabel(f) {
    SplitPath(f, , , , &base)
    return base
}

; Blank unless the trigger is overloaded, in which case its variant count.
VarCell(trigger) {
    global gOverloads
    return gOverloads.Has(trigger) ? gOverloads[trigger].variants.Length : ""
}

; The key bound to this hotstring, prettified, or "" for the great majority that
; have none. Read from hotkeys.ini every time the list is built rather than
; cached: the Hotkeys tab in Settings can rebind one of these too, and a cached
; column would go on showing the old key until a rescan.
KeyCell(trigger) {
    k := HK_Key(HK_HotstringId(trigger))
    return (k = "") ? "" : HKP_KeyLabel(k)
}

OnRowOpen(ctrl, row) {
    global gRecords, HSI_DIR
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, 8))
    if (idx < 1 || idx > gRecords.Length)
        return
    r := gRecords[idx]
    OpenAt(HSI_DIR "\" r.file, r.line)
}

; Prefer VS Code at the exact line; fall back to Notepad if the `code` CLI is absent.
OpenAt(path, line) {
    try {
        Run(A_ComSpec ' /c code -g "' path '":' line, , "Hide")
        return
    }
    try Run('notepad.exe "' path '"')
}

OpenSelected(*) {
    global LV
    OnRowOpen(LV, LV.GetNext(0, "F"))
}

CopySelected(*) {
    global LV
    row := LV.GetNext(0, "F")
    if !row
        return
    A_Clipboard := LV.GetText(row, 1)
    ToolTip "Copied  " A_Clipboard
    SetTimer(RemoveToolTip, -1200)
}

RemoveToolTip() {
    ToolTip()
}

RescanFiles(*) {
    global gRecords, gOverloads, searchEd
    gRecords   := HSI_Build()
    gOverloads := OL_Load()
    PopulateList(searchEd.Value)
}

; ── delete: the one action that edits a message .ahk file ─────────────────────
;
; Everything else here is a view. This cuts the block out of the source, so it
; asks first, shows exactly what is going: trigger, file, line, and the message
; body, because a trigger alone ("_g3") is not enough to recognise what you are
; about to lose. hotstrings/index.ahk writes the .bak and re-verifies the line.
DeleteSelected(*) {
    global LV, gRecords, gOverloads, searchEd
    row := LV.GetNext(0, "F")
    if !row {
        Notify("Select a hotstring first")
        return
    }
    idx := Integer(LV.GetText(row, 8))
    if (idx < 1 || idx > gRecords.Length)
        return
    r := gRecords[idx]

    body := FlattenOneLine(r.preview)
    if (StrLen(body) > 220)
        body := SubStr(body, 1, 220) Chr(0x2026)

    warn := ""
    if gOverloads.Has(r.trigger)
        warn := "`n`nIts " gOverloads[r.trigger].variants.Length " overload variants will be "
              . "removed too " Chr(0x2014) " left behind, they would keep firing for a "
              . "trigger whose source is gone."

    prompt := "Delete this hotstring from " r.file "?`n`n"
            . ":" r.options ":" r.trigger "::   (line " r.line ")`n`n"
            . (body = "" ? "(empty)" : body)
            . warn
            . "`n`nThis edits the source file. A copy is saved as "
            . HsFileLabel(r.file) ".ahk.bak first, and "
            . OL_BaseName(r.file) " must be restarted for the change to take effect."
    if (MsgBox(prompt, "Delete hotstring", 0x24) != "Yes")
        return

    res := HSI_DeleteBlock(r.file, r.line, r.trigger)
    if !res.ok {
        MsgBox(res.why, "Delete hotstring", 0x30)
        return
    }
    if gOverloads.Has(r.trigger)
        OL_Remove(r.trigger)

    RescanFiles()
    Notify(r.trigger " deleted from " OL_BaseName(r.file) " (" res.removed " lines, .bak saved)"
         . "  " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  overloading — variants live in hotstring_overloads.ini, never in your .ahk
; ═══════════════════════════════════════════════════════════════════════════════

EditOverload(*) {
    global LV, gRecords
    row := LV.GetNext(0, "F")
    if !row
        return
    idx := Integer(LV.GetText(row, 8))
    if (idx < 1 || idx > gRecords.Length)
        return
    OpenVariantEditor(gRecords[idx])
}

; ── give this hotstring a key ─────────────────────────────────────────────────
;  Optional, one per hotstring, and it never replaces the trigger: both fire the
;  same thing, so a key is something you add to the ten messages you send all day
;  and never think about for the other hundred.
;
;  The binding is a line in hotkeys.ini — `[hotstring] trigger = key` — which is
;  the same file, the same format and the same conflict report as every other key
;  in MMA. See the [hotstring] block at the bottom of core/hotkeys.ahk for why it
;  is in the registry rather than bound off to one side, and
;  HotstringKeys_Register in core/utils.ahk for what happens when you press it.
SetHotstringKey(*) {
    global LV, gRecords, MainGui
    row := LV.GetNext(0, "F")
    if !row {
        MsgBox("Select a hotstring first.", "Hotkey", 0x40)
        return
    }
    idx := Integer(LV.GetText(row, 8))
    if (idx < 1 || idx > gRecords.Length)
        return
    rec := gRecords[idx]
    trg := rec.trigger

    ; Dots are fine. An `=` is not, and it is the ini line format saying so rather
    ; than MMA: `a=b = ^!1` reads back as the trigger "a" with the value "b = ^!1".
    ; No trigger in the library has one.
    if InStr(trg, "=") {
        MsgBox("'" trg "' has an '=' in it, and that is what separates a setting"
             . " from its value in hotkeys.ini — so this trigger cannot have a"
             . " key.`n`nRename the trigger if you want one.", "Hotkey", 0x30)
        return
    }

    id  := HK_HotstringId(trg)
    was := HK_Key(id)

    ov := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner" MainGui.Hwnd)
    ov.BackColor := "1E1E1E"
    ov.SetFont("s11 cWhite", "Segoe UI")
    lblPrompt := ov.Add("Text", "x0 y16 w420 Center", "Press a key for  " trg)
    ov.SetFont("s9 c9A9A9A")
    ov.Add("Text", "x0 y44 w420 Center", "Esc = cancel     Backspace = remove the key")
    ov.Show("w420 h80")

    ; Every MMA script holds fire while we listen, or pressing F1 to assign it
    ; would also send model 1's follow-up. The un-suspend MUST run even if the
    ; grab throws, or every hotkey in MMA stays dead with no clue why — the same
    ; reasoning, and the same `finally`, as the Hotkeys tab.
    HK_Broadcast(HK_MSG_SUSPEND, 1)
    try
        k := HKP_GrabKey(lblPrompt)
    finally {
        HK_Broadcast(HK_MSG_SUSPEND, 0)
        ov.Destroy()
    }

    if (k = "<cancel>")
        return
    if (k = "<clear>") {
        if (was = "") {
            MsgBox("'" trg "' had no key.", "Hotkey", 0x40)
            return
        }
        try IniDelete(HK_INI, "hotstring", trg)
        LOGI("hotstring.key", "removed the key from " trg " (was "
                            . HKP_KeyLabel(was) ") — it is typed only from now on")
        _HsKeyApplied(rec, "'" trg "' no longer has a key.", true)
        return
    }

    ; ── no duplicates ─────────────────────────────────────────────────────────
    ; Refused, not warned about. Elsewhere in MMA two ids may share a key when
    ; their window contexts do not overlap — but a hotstring key is GLOBAL (see
    ; HotstringKeys_Register), so it overlaps with everything, and "both fire and
    ; the winner is whichever script registered last" is not a state to offer
    ; someone as a checkbox. Press another key.
    clash := HK_KeyOwner(k, id)
    if (clash != "") {
        MsgBox(HKP_KeyLabel(k) " is already used by:`n`n    " clash
             . "`n`nPick a different one — a hotstring key works in every window,"
             . " so sharing it would mean both fire and whichever script loaded"
             . " last wins.", "Key already used", 0x30)
        LOG_Bail("hotstring.key", "refused to bind " HKP_KeyLabel(k) " to " trg
                                . " — already used by " clash)
        return
    }

    IniWrite(k, HK_INI, "hotstring", trg)
    LOGI("hotstring.key", trg " is now on " HKP_KeyLabel(k)
                        . (was = "" ? "" : " (was " HKP_KeyLabel(was) ")"))
    _HsKeyApplied(rec, "'" trg "' is now on  " HKP_KeyLabel(k), was = "")
}

; Make the change real, then say what happened.
;
; ─── WHY A RESTART, AND ONLY SOMETIMES ────────────────────────────────────────
; A message script binds its hotstring keys once, at load, from the ini. So:
;
;   the key CHANGED   the id is already bound in that script, and the reload
;                     broadcast is enough — HK_Bind re-reads the ini and moves
;                     the key with no restart and nothing interrupted.
;   a NEW binding     there is no bound id to move. The script has to load again
;                     to notice, and until it does the key does nothing at all —
;                     which is indistinguishable from the feature being broken.
;
; So a new binding restarts the owning script, and says so. Restarting one
; message script is what "Startup scripts ▸ Restart" does and takes a moment;
; doing it silently would be worse, and not doing it would ship a key that only
; works tomorrow.
_HsKeyApplied(rec, msg, needsRestart) {
    global gRecords, searchEd
    HK_Broadcast(HK_MSG_RELOAD, 0)
    ; Rebuild the list so the Key column is right immediately — it is read from
    ; the ini per row, so nothing else has to be told.
    PopulateList(searchEd.Value)

    if !needsRestart {
        MsgBox(msg "`n`nApplied live.", "Hotkey", 0x40)
        return
    }
    path := MMA_CONTENT "\" rec.file
    SplitPath(path, &fname)
    if !FileExist(path) {
        MsgBox(msg "`n`nSaved, but " fname " is not where the index said it was,"
             . " so it could not be restarted. The key works next time that script"
             . " starts.", "Hotkey", 0x30)
        return
    }
    SS_Restart(path)
    MsgBox(msg "`n`n" fname " was restarted so the key takes effect now.",
           "Hotkey", 0x40)
}

; A variant is edited as plain text: ONE STEP PER LINE, with \n standing in for a
; newline inside a single step (same escape the registry uses), so nothing is lost
; on the round-trip. The mode picks how every step in that variant is sent.
StepsToVariant(steps) {
    mode := "lines"
    t := ""
    for st in steps {
        if (StrLower(st.fn) = "sendtext")
            mode := "paste"
        line := StrReplace(StrReplace(st.text, "`r`n", "`n"), "`n", "\n")
        t .= (t = "" ? "" : "`r`n") line
    }
    return {mode: mode, text: t}
}

VariantToSteps(v) {
    steps := []
    fn := (v.mode = "paste") ? "SendText" : "snd"
    for line in StrSplit(v.text, "`n", "`r") {
        if (Trim(line) = "")            ; skip blank lines, but keep a real line verbatim —
            continue                    ; trimming would eat intentional leading/trailing spaces
        steps.Push({fn: fn, text: StrReplace(line, "\n", "`n")})
    }
    return steps
}

OpenVariantEditor(r) {
    global gOverloads, MainGui, searchEd, BG, LISTBG, FIELDBG, TXT, MUTED, ACCENT

    ; working copy — seed variant 1 from the source body when not yet overloaded
    vars := []
    pickMode := "ask"
    if gOverloads.Has(r.trigger) {
        pickMode := gOverloads[r.trigger].mode
        for steps in gOverloads[r.trigger].variants
            vars.Push(StepsToVariant(steps))
    } else {
        vars.Push(StepsToVariant(r.steps))
    }
    cur := 0

    eg := Gui("+Owner" MainGui.Hwnd, "Overload  " r.trigger)
    eg.BackColor := BG
    eg.SetFont("s11 Bold c" ACCENT, "Segoe UI")
    eg.Add("Text", "x14 y12 w400", ":" r.options ":" r.trigger "::")

    ; how THIS trigger chooses among its variants — stored per trigger, not globally
    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x420 y14 w96 h20 +0x200 Right", "On fire, pick")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    pickSel := eg.Add("DropDownList", "x522 y11 w92", ["ask", "random"])
    pickSel.Choose(pickMode = "random" ? 2 : 1)

    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x14 y36 w600",
           "One step per line." Chr(0x2026) "  use \n inside a line for a newline within that message.")

    eg.SetFont("s10 c" TXT, "Segoe UI")
    lb := eg.Add("ListBox", "x14 y62 w200 h236 Background" LISTBG)
    modeSel := eg.Add("DropDownList", "x224 y62 w390",
                      ["send each line (Enter after each)", "paste only (no Enter)"])
    body := eg.Add("Edit", "x224 y94 w390 h204 Multi +VScroll Background" FIELDBG)

    eg.SetFont("s9 c" TXT, "Segoe UI")
    bAdd  := eg.Add("Button", "x14 y308 w86 h27", "Add")
    bDel  := eg.Add("Button", "x106 y308 w86 h27", "Delete")
    bSave := eg.Add("Button", "x330 y308 w86 h27", "Save")
    bOff  := eg.Add("Button", "x422 y308 w110 h27", "Remove overload")
    bCan  := eg.Add("Button", "x538 y308 w76 h27", "Cancel")

    lb.OnEvent("Change", PickVariant)
    bAdd.OnEvent("Click",  AddVariant)
    bDel.OnEvent("Click",  DelVariant)
    bSave.OnEvent("Click", SaveVariants)
    bOff.OnEvent("Click",  DropOverload)
    bCan.OnEvent("Click",  CloseEditor)
    eg.OnEvent("Close",  CloseEditor)
    eg.OnEvent("Escape", CloseEditor)

    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", eg.Hwnd, "int", 20, "int*", 1, "int", 4)
    RefreshVariants(1)
    eg.Show("w628 h348")
    return

    ; ── nested handlers (closures over vars / cur / the controls above) ──

    RefreshVariants(want) {
        lb.Delete()
        for i, v in vars
            lb.Add([i "   " SubStr(StrReplace(v.text, "`r`n", " / "), 1, 40)])
        if vars.Length {
            want := Max(1, Min(want, vars.Length))
            lb.Choose(want)
            LoadVariant(want)
        }
    }

    LoadVariant(i) {
        cur := i
        body.Value := vars[i].text
        modeSel.Choose(vars[i].mode = "paste" ? 2 : 1)
    }

    CommitCurrent() {
        if (cur >= 1 && cur <= vars.Length) {
            vars[cur].text := body.Value
            vars[cur].mode := (modeSel.Value = 2) ? "paste" : "lines"
        }
    }

    PickVariant(*) {
        sel := lb.Value
        if (!sel || sel = cur)
            return
        CommitCurrent()
        LoadVariant(sel)
    }

    AddVariant(*) {
        CommitCurrent()
        vars.Push({mode: "lines", text: ""})
        RefreshVariants(vars.Length)
    }

    DelVariant(*) {
        if (vars.Length <= 1) {
            MsgBox("A variant list needs at least one entry."
                 . "`n`nUse 'Remove overload' to drop it entirely.", "Overload", 0x40)
            return
        }
        if (cur < 1 || cur > vars.Length)
            return
        vars.RemoveAt(cur)
        cur := 0
        RefreshVariants(1)
    }

    SaveVariants(*) {
        global gOverloads, searchEd
        CommitCurrent()
        built := []
        for v in vars {
            steps := VariantToSteps(v)
            if steps.Length
                built.Push(steps)
        }
        if !built.Length {
            MsgBox("Every variant is empty " Chr(0x2014) " nothing to save.", "Overload", 0x30)
            return
        }
        ; Read the control BEFORE the window goes away — eg.Destroy() takes pickSel
        ; with it, and touching it afterwards throws "The control is destroyed."
        mode := pickSel.Text
        OL_Save(r.trigger, r.file, r.options, built, mode)
        gOverloads := OL_Load()
        PopulateList(searchEd.Value)
        eg.Destroy()
        Notify(r.trigger " overloaded " Chr(0x2014) " " built.Length " variants, pick: " mode
             . "  " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
    }

    DropOverload(*) {
        global gOverloads, searchEd
        OL_Remove(r.trigger)
        gOverloads := OL_Load()
        PopulateList(searchEd.Value)
        eg.Destroy()
        Notify(r.trigger " overload removed " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
    }

    CloseEditor(*) {
        eg.Destroy()
    }
}

Notify(msg) {
    ToolTip(msg)
    SetTimer(RemoveToolTip, -2600)
}

; ── resize: search spans the width; list on top, showcase (full width) beneath ──
OnSize(g, minMax, w, h) {
    global searchEd, LV, detailEd, countTxt, btnOpen, btnCopy, btnRescan, lblSize, sizeDD
    global btnOver, btnKey, btnDelete, lblSort, sortDD
    if (minMax = -1)
        return
    m := 16, gap := 10, footerH := 30, footerGap := 14
    countTxt.Move(w - 376, 21, 360)
    searchEd.Move(m, 48, w - 2 * m, 32)

    top := 90
    contentH := h - top - m - footerH - footerGap
    if (contentH < 220)
        contentH := 220
    listW  := w - 2 * m
    listH  := Integer((contentH - gap) * 0.42)      ; list ~42%, showcase gets the rest
    detailH := contentH - gap - listH
    LV.Move(m, top, listW, listH)
    detailEd.Move(m, top + listH + gap, listW, detailH)

    ; preview column soaks up the list's spare width
    LV.ModifyCol(1, 190)
    LV.ModifyCol(3, 54)
    LV.ModifyCol(4, 54)
    LV.ModifyCol(5, 96)
    LV.ModifyCol(6, 130)
    LV.ModifyCol(7, 92)
    LV.ModifyCol(2, Max(160, listW - 190 - 54 - 54 - 96 - 130 - 92 - 24))

    by := top + contentH + footerGap
    btnOpen.Move(m, by)
    btnCopy.Move(m + 118, by)
    btnRescan.Move(m + 236, by)
    btnOver.Move(m + 336, by)
    btnKey.Move(m + 460, by)
    btnDelete.Move(m + 566, by)
    sizeDD.Move(w - m - 62, by, 62)
    lblSize.Move(w - m - 62 - 66, by + 6, 62)
    sortDD.Move(w - m - 62 - 66 - 128, by, 120)
    lblSort.Move(w - m - 62 - 66 - 128 - 38, by + 6, 34)

    ; Repaint the strip the footer lives in. The right-hand cluster slides with the
    ; window edge, and the background it slides OFF is the parent's — which Windows
    ; does not repaint on its own when a child moves. Without this, dragging the
    ; window wider smears "Sort" and its dropdown across the footer, the same way
    ; the first WM_SIZE used to. Just this band, not the whole window: the list and
    ; the showcase are opaque controls that paint themselves, and invalidating them
    ; on every WM_SIZE of a drag is a flicker you can see.
    _rc := Buffer(16, 0)
    NumPut("Int", 0,          _rc, 0)
    NumPut("Int", by - 6,     _rc, 4)
    NumPut("Int", w,          _rc, 8)
    NumPut("Int", by + 40,    _rc, 12)
    DllCall("InvalidateRect", "Ptr", g.Hwnd, "Ptr", _rc, "Int", true)
}

; ── text size: live-apply to list + showcase and remember the choice ──
OnFontSize(ctrl, *) {
    global gFontSize
    gFontSize := Integer(ctrl.Text)
    ApplyContentFont(gFontSize)
    SaveFontSize(gFontSize)
}

ApplyContentFont(sz) {
    global detailEd, TXT
    detailEd.SetFont("s" sz " c" TXT)     ; preview box only — the list keeps its own size
}

SaveFontSize(sz) {
    global HSI_DIR
    try IniWrite(sz, MMA_CFG, "Hotstrings", "FontSize")
}

; ── native helpers ──
CueBanner(ctrl, text) {
    static EM_SETCUEBANNER := 0x1501
    SendMessage(EM_SETCUEBANNER, 1, StrPtr(text), ctrl)
}

FlattenOneLine(s) {
    return StrReplace(StrReplace(s, "`r", " "), "`n", " ")
}

; Dark title bar + dark scrollbars/selection, so the window doesn't have a white
; frame around a dark body. All best-effort — wrapped so old Windows just skips it.
ApplyDarkTheme() {
    global MainGui, LV, detailEd, searchEd
    for attr in [20, 19]                    ; DWMWA_USE_IMMERSIVE_DARK_MODE (20 new, 19 old)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", MainGui.Hwnd, "int", attr, "int*", 1, "int", 4)
    for hwnd in [LV.Hwnd, detailEd.Hwnd, searchEd.Hwnd]
        try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    ; The column header is a separate SysHeader32 child and does NOT inherit the
    ; list's theme. Use DarkMode_Explorer, not DarkMode_ItemsView: ItemsView
    ; darkens the header background but leaves the LABEL text dark too, which
    ; reads as an empty/transparent header rather than a themed one.
    hHdr := SendMessage(0x101F, 0, 0, LV)        ; LVM_GETHEADER
    if hHdr
        try DllCall("uxtheme\SetWindowTheme", "ptr", hHdr, "str", "DarkMode_Explorer", "ptr", 0)
    ; Bold button labels, the same as every other MMA window — the shared helper
    ; in core/theme.ahk, so there is one answer to "are buttons bold".
    try THEME_BoldButtons(MainGui)
}
