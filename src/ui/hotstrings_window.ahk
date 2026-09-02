#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../hotstrings/index.ahk"
#Include "../hotstrings/overloads.ahk"
; HSU_* — which hotstrings you use and which you pinned. The manager is where a
; pin is set, and the quick menu is where it is spent.
#Include "../hotstrings/usage.ahk"
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
;  can find one by TRIGGER or by the TEXT inside it: browse, search, EDIT, pin,
;  give it a key, turn it into an OVERLOAD (several variants, one of which fires),
;  or delete it.
;
;  Run it on its own (double-click).
;
;  ─── IT WRITES TO YOUR MESSAGE FILES, AND THAT IS NEW ───────────────────
;  This window used to be read-only with one exception: Delete cut a block out of
;  the source, and everything else either only looked, or wrote to an ini beside
;  it. Overload variants still live in hotstring_overloads.ini and still never
;  touch your .ahk files; a pin still lives in hotstring_usage.ini.
;
;  But Edit rewrites the block IN the source file — trigger, ':: vs :*:', the
;  message text, which function sends each line, and which file the hotstring
;  lives in. That was the last thing you had to leave this window to do, and
;  leaving meant VS Code, the right line, and getting AHK's own string escapes
;  right by hand. Every one of those writes goes through hotstrings/index.ahk,
;  which takes a .bak first and refuses anything it cannot re-verify.
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
; The recent/pinned store, read ONCE per rebuild rather than per row. Both of
; these are file reads, and the list is ~130 rows: asking per cell turned a
; rebuild into 260 IniReads, on every keystroke in the search box.
gPins  := Map()                ; lower(trigger) -> pin order (1-based)
gUses  := Map()                ; trigger -> {at, count}
HSW_LoadUsage() {
    global gPins, gUses
    gPins := Map()
    for i, pn in HSU_Pinned()
        gPins[StrLower(pn.trigger)] := i
    gUses := HSU_Uses()
}
HSW_LoadUsage()

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
; disk and stays the default; the date orders answer "what did I write lately?",
; and the last two answer "what do I actually use?" out of hotstring_usage.ini.
;
; APPENDED, never inserted. The chosen mode is stored in mass_gui.cfg as its
; INDEX in this array, so putting a new mode in the middle would silently move
; everyone who had picked one after it onto a different order.
gSortModes := ["File order", "Newest first", "Oldest first", "Trigger A-Z",
               "Pinned first", "Most used"]
gSortMode  := LOG_IniInt(MMA_CFG, "Hotstrings", "Sort", 1)
if (gSortMode < 1 || gSortMode > gSortModes.Length)
    gSortMode := 1

; ── window ──
;  ─── THE FOOTER IS WHAT SETS THE WIDTH ──────────────────────────
;  It is two clusters that grow towards each other: the buttons pinned to the
;  LEFT edge, and Sort + Text size pinned to the RIGHT. Neither shrinks, so the
;  window has a hard minimum — and it was once set as a round number rather than
;  measured, which is why the buttons used to run into the dropdowns.
;
;  Measured, at the sizes the controls are actually created with:
;
;      left  cluster   16 .. 846    Edit · Open source · Copy trigger · Rescan ·
;                                   Overload · Hotkey · Pin · Delete
;      right cluster   w-310 .. w   Sort [dropdown] · Text size [dropdown]
;
;  846 + 310 = 1156 with the two touching. HSW_W is that sum plus room to
;  breathe, and HSW_MIN is the point below which they would touch again.
;
;  RE-MEASURE THIS WHEN YOU ADD A BUTTON. The count has changed four times now —
;  "Hotkey" arrived, "Startup scripts" left for the top row, and "Edit" and
;  "Pin" arrived together — and every time the two numbers above went stale the
;  symptom was the same: buttons drawn UNDERNEATH the dropdowns, present and
;  invisible. That the footer holds the actions on the SELECTED ROW is what
;  keeps the list short; Startup scripts left because it acts on the FILES.
global HSW_W   := 1280     ; default width — the sum above, with room to breathe
global HSW_H   := 640
global HSW_MIN := 1192     ; 1156 + a 36px gap. Below this the two clusters meet.
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
; ── the columns ────────────────────────────────────────────────
;  HSW_COL_IDX is the hidden one: the master index into gRecords, riding with
;  its row so a sorted or filtered list can still say which record a row IS.
;  Named rather than written as a number in eight places — it moved from 8 to 10
;  when the pin and use-count columns arrived, and a missed one reads a DIFFERENT
;  COLUMN as an index, which silently acts on the wrong hotstring.
global HSW_COL_IDX := 10
LV := MainGui.Add("ListView", "x16 y90 w948 h250 Background" LISTBG,
                  ["Trigger", GLYPH_STAR, "Message preview", "#", "Var", "Key",
                   "File", "Added", "Used", "idx"])
LV.OnEvent("ItemFocus",   OnRowFocus)
LV.OnEvent("DoubleClick", OnRowOpen)
LV.ModifyCol(1, 170)
LV.ModifyCol(2, "30 Center")       ; the pin marker, blank for everything unpinned
LV.ModifyCol(3, 350)
LV.ModifyCol(4, "50 Integer Center")
LV.ModifyCol(5, "50 Center")       ; variant count when overloaded, else blank
LV.ModifyCol(6, 90)                ; the key bound to it, blank for the great majority
LV.ModifyCol(7, 120)
LV.ModifyCol(8, 90)                ; date the hotstring was added, blank if unstamped
LV.ModifyCol(9, "56 Integer Center") ; how many times it has been sent
LV.ModifyCol(HSW_COL_IDX, 0)       ; hidden, see above

; showcase / detail pane — full width, word-wrapped so long messages read cleanly
MainGui.SetFont("s12 c" TXT, "Segoe UI")
detailEd := MainGui.Add("Edit", "x16 y350 w948 h170 ReadOnly +VScroll Background" SURFACE)

; footer
MainGui.SetFont("s10 c" TXT, "Segoe UI")
; ── Edit ────────────────────────────────────────────────────
;  First, and the only button here that changes what a hotstring SAYS. Reword
;  it, rename the trigger, change ':: to :*:', change which function sends a
;  line, move the whole thing to another message file — all of it, in the window
;  that lists them, instead of in VS Code at the right line getting AHK's string
;  escapes right by hand. "Open source" is still there for when you want the
;  editor anyway.
btnEdit   := MainGui.Add("Button", "x16 y534 w86 h30", "Edit" Chr(0x2026))
btnOpen   := MainGui.Add("Button", "x108 y534 w112 h30", "Open source")
btnCopy   := MainGui.Add("Button", "x226 y534 w112 h30", "Copy trigger")
btnRescan := MainGui.Add("Button", "x344 y534 w92 h30", "Rescan")
btnOver   := MainGui.Add("Button", "x442 y534 w118 h30", "Overload" Chr(0x2026))
; ── a key for a message you send constantly ───────────────────────────────────
;  Optional, per hotstring, and it never replaces the trigger — both fire the
;  same thing. See HotstringKeys_Register in core/utils.ahk for what happens when
;  it is pressed, and the [hotstring] block at the bottom of core/hotkeys.ahk for
;  where it is stored.
btnKey    := MainGui.Add("Button", "x566 y534 w100 h30", "Hotkey" Chr(0x2026))
; ── Pin ─────────────────────────────────────────────────────
;  A pinned hotstring is always in the quick menu, however long it has been
;  since you last sent it (hotstrings\quick_menu.ahk). That is the whole of what
;  a pin means — it changes nothing about the trigger, the key or the message.
;  The list's ✦ column is the same fact, per row.
btnPin    := MainGui.Add("Button", "x672 y534 w76 h30", "Pin")
btnDelete := MainGui.Add("Button", "x754 y534 w92 h30", "Delete")
btnEdit.OnEvent("Click",   EditSelected)
btnOpen.OnEvent("Click",   OpenSelected)
btnCopy.OnEvent("Click",   CopySelected)
btnRescan.OnEvent("Click", RescanFiles)
btnOver.OnEvent("Click",   EditOverload)
btnKey.OnEvent("Click",    SetHotstringKey)
btnPin.OnEvent("Click",    TogglePinSelected)
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
    global MMA_MSG_ADD_HOTKEY
    ; Whichever shell is up — MMA_SRC_GUI is only the Win32 one, and this button
    ; went nowhere when the WebView shell was the running window. See MMA_GuiWin.
    win  := MMA_GuiWin()
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
            LV.Add(, r.trigger, PinCell(r.trigger), FlattenOneLine(r.preview),
                     r.steps.Length, VarCell(r.trigger), KeyCell(r.trigger),
                     HsFileLabel(r.file), AddedCell(r.added), UsedCell(r.trigger), i)
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
    global gRecords, gSortMode, gPins, gUses
    idx := []
    Loop gRecords.Length
        idx.Push(A_Index)
    if (gSortMode = 1)
        return idx

    keyOf(i) {
        r := gRecords[i]
        return gSortMode = 4 ? StrLower(r.trigger) : r.added
    }
    ; Pin order, or 0 for everything that is not pinned. The number IS the order
    ; you pinned them in, so "Pinned first" lists them the way the quick menu
    ; does — two views of one list rather than two orderings of one set.
    pinOf(i) {
        k := StrLower(gRecords[i].trigger)
        return gPins.Has(k) ? gPins[k] : 0
    }
    useOf(i) {
        t := gRecords[i].trigger
        return gUses.Has(t) ? gUses[t].count : 0
    }
    less(a, b) {
        ; Pinned first: the pinned ones in pin order, then everything else. The
        ; unpinned tail keeps FILE order, because the sort below is stable and
        ; this returns false for any two of them — which is the answer, not an
        ; omission: "unpinned" is not a ranking.
        if (gSortMode = 5) {
            pa := pinOf(a), pb := pinOf(b)
            if (pa = pb)
                return false
            if (pa = 0 || pb = 0)
                return pb = 0
            return pa < pb
        }
        ; Most used: by count, and never-used rows keep file order among
        ; themselves for the same reason.
        if (gSortMode = 6)
            return useOf(a) > useOf(b)
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
    global gRecords, detailEd, HSW_COL_IDX
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, HSW_COL_IDX))
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

; The pin marker, or blank. Read from the map built once per rebuild, not from
; the ini per row — see gPins.
PinCell(trigger) {
    global gPins, GLYPH_STAR
    return gPins.Has(StrLower(trigger)) ? GLYPH_STAR : ""
}

; How many times this hotstring has been sent, or blank for never. Blank rather
; than "0": a column of zeroes is noise, and the question the column answers is
; "which of these do I use", which an empty cell answers just as well.
UsedCell(trigger) {
    global gUses
    return (gUses.Has(trigger) && gUses[trigger].count > 0) ? gUses[trigger].count : ""
}

; The key bound to this hotstring, prettified, or "" for the great majority that
; have none. Read from hotkeys.ini every time the list is built rather than
; cached: the Hotkeys tab in Settings can rebind one of these too, and a cached
; column would go on showing the old key until a rescan.
KeyCell(trigger) {
    k := HK_Key(HK_HotstringId(trigger))
    return (k = "") ? "" : HKP_KeyLabel(k)
}

; ── which hotstring is selected? ────────────────────────────────────
;  Six buttons ask it, and every one of them used to spell out the same four
;  lines: find the focused row, read the hidden index column, bounds-check it,
;  index gRecords. That is six copies of the one place the COLUMN NUMBER is
;  written down, and adding the ✦ column moved that number.
;
;  Returns the record, or 0 when nothing is selected. `what` names the action
;  for the nudge, so "Select a hotstring first" says which button you pressed.
HSW_Selected(what := "") {
    global LV, gRecords, HSW_COL_IDX
    row := LV.GetNext(0, "F")
    if !row {
        if (what != "")
            Notify("Select a hotstring first — then " what)
        return 0
    }
    idx := Integer(LV.GetText(row, HSW_COL_IDX))
    if (idx < 1 || idx > gRecords.Length)
        return 0
    return gRecords[idx]
}

; Double-click EDITS. It used to open VS Code at the line, which was the only
; way to change a message and is now the long way round — "Open source" is still
; there for when the editor is what you actually wanted.
OnRowOpen(ctrl, row) {
    global gRecords, HSW_COL_IDX
    if (!row || row > ctrl.GetCount())
        return
    idx := Integer(ctrl.GetText(row, HSW_COL_IDX))
    if (idx < 1 || idx > gRecords.Length)
        return
    OpenHotstringEditor(gRecords[idx])
}

; Prefer VS Code at the exact line; fall back to Notepad if the `code` CLI is absent.
OpenAt(path, line) {
    try {
        Run(A_ComSpec ' /c code -g "' path '":' line, , "Hide")
        return
    }
    try Run('notepad.exe "' path '"')
}

; The source file, in VS Code, at the line. Still here on purpose: the editor
; covers the hotstring, and sometimes what you want is the FILE — the section
; comments, the block above, the whole shape of the library.
OpenSelected(*) {
    global HSI_DIR
    r := HSW_Selected("press Open source")
    if !r
        return
    OpenAt(HSI_DIR "\" r.file, r.line)
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
    HSW_LoadUsage()
    PopulateList(searchEd.Value)
}

; ── delete: the one action that edits a message .ahk file ─────────────────────
;
; Everything else here is a view. This cuts the block out of the source, so it
; asks first, shows exactly what is going: trigger, file, line, and the message
; body, because a trigger alone ("_g3") is not enough to recognise what you are
; about to lose. hotstrings/index.ahk writes the .bak and re-verifies the line.
DeleteSelected(*) {
    global gOverloads, searchEd
    r := HSW_Selected("press Delete")
    if !r
        return

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
    ; And its pin and its use count. Left behind, a pin for a deleted hotstring
    ; keeps a row in the quick menu that resolves to nothing — the menu shows it
    ; greyed out and says so, which is right for a hotstring that vanished from
    ; under it and wrong for one you just deleted on purpose.
    HSU_Forget(r.trigger)

    RescanFiles()
    Notify(r.trigger " deleted from " OL_BaseName(r.file) " (" res.removed " lines, .bak saved)"
         . "  " Chr(0x2014) " restart " OL_BaseName(r.file) " to apply")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  overloading — variants live in hotstring_overloads.ini, never in your .ahk
; ═══════════════════════════════════════════════════════════════════════════════

EditOverload(*) {
    r := HSW_Selected("press Overload")
    if r
        OpenVariantEditor(r)
}

; ── Edit ────────────────────────────────────────────────────
EditSelected(*) {
    r := HSW_Selected("press Edit")
    if r
        OpenHotstringEditor(r)
}

; ── Pin ─────────────────────────────────────────────────────
;  Nothing is written to your message files and nothing is restarted: a pin is
;  one line in hotstring_usage.ini, and the quick menu reads it fresh every time
;  it opens. So this takes effect the moment you click it, in every process.
TogglePinSelected(*) {
    global searchEd
    r := HSW_Selected("press Pin")
    if !r
        return
    nowPinned := HSU_TogglePin(r.trigger)
    HSW_LoadUsage()
    PopulateList(searchEd.Value)
    Notify(r.trigger (nowPinned
        ? " pinned — it is in the quick menu from now on"
        : " unpinned — it shows in the quick menu only while it is recent"))
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
    global MainGui
    rec := HSW_Selected("press Hotkey")
    if !rec
        return
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

; ═══════════════════════════════════════════════════════════════════════════════
;  the editor — the one window in MMA that rewrites a message file
; ───────────────────────────────────────────────────────────────────────────────
;  Everything about one hotstring, in one dialog: its trigger, whether it is `::`
;  or `:*:`, the message itself, which function sends each line, and which file
;  the whole thing lives in.
;
;  ─── TWO WAYS TO EDIT THE BODY, AND WHY BOTH EXIST ───────────────────────────
;  STEPS is the one you want: a row per message, a box for the words, a dropdown
;  for how that row is sent. No AHK, no quotes to escape, no `n to remember.
;
;  SOURCE is the body as it is written in the file. It is not a power-user
;  flourish — it is the only honest way to edit the blocks the Steps view cannot
;  represent. content\accounts\BRI.ahk has blocks that open with `t := 500` and
;  then pass `t` to every sendt() below it; rebuild one of those from its steps
;  and the line those steps depend on is gone, leaving a message script that no
;  longer loads. HSI_BodyIsPlain is the question that decides, and a body that
;  answers no opens on Source with the reason on screen.
;
;  Whichever tab you are on when you press Save is what gets written. Switching
;  tabs converts, and converting Source → Steps warns first when it would drop
;  something, because that is the direction that loses.
;
;  ─── RENAMING IS A MIGRATION, NOT A STRING CHANGE ────────────────────────────
;  Three other files key off the trigger: hotkeys.ini's [hotstring] section (the
;  key you can bind to it), hotstring_overloads.ini (its variants) and
;  hotstring_usage.ini (its pin and its use count). Rename the trigger without
;  moving those and the key stops working, the overload stops firing and the
;  history resets — three silent failures from one rename. They move here.
; ═══════════════════════════════════════════════════════════════════════════════

; Which message file is which, for the File dropdown. Names for display, the
; relative paths HSI_* wants for the writes.
HSE_FileList() {
    names := [], rels := []
    for rel in HSI_Files() {
        rels.Push(rel)
        names.Push(HsFileLabel(rel))
    }
    return {names: names, rels: rels}
}

; A working copy of a record's steps. The editor must not mutate gRecords: a
; cancelled edit has to leave the list showing what is actually on disk.
HSE_CopySteps(steps) {
    out := []
    for st in steps
        out.Push({fn: st.fn, text: st.text,
                  ms: st.HasProp("ms") ? st.ms : ""})
    return out
}

HSE_FnIndex(fn) {
    switch StrLower(fn) {
        case "sendtext": return 2
        case "sendt":    return 3
        default:         return 1
    }
}
HSE_FnName(i) {
    switch i {
        case 2:  return "SendText"
        case 3:  return "Sendt"
        default: return "snd"
    }
}

OpenHotstringEditor(r) {
    global MainGui, searchEd, BG, LISTBG, FIELDBG, TXT, MUTED, ACCENT

    files    := HSE_FileList()
    steps    := HSE_CopySteps(r.steps)
    source   := r.raw
    cur      := 0                 ; which step row is loaded into the boxes
    onSteps  := r.plain           ; which tab is authoritative right now

    ; Fixed size, deliberately. Every control below is placed at an absolute
    ; coordinate and there is no OnSize handler for this dialog, so +Resize
    ; bought nothing but a band of empty window to drag out.
    eg := Gui("+Owner" MainGui.Hwnd,
              "Edit hotstring  " Chr(0x2014) "  " r.trigger)
    eg.BackColor := BG

    ; ── identity ──────────────────────────────────────────────────────────────
    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x14 y16 w50 h22 +0x200 Right", "Trigger")
    eg.SetFont("s11 Bold c" TXT, "Segoe UI")
    edTrig := eg.Add("Edit", "x70 y13 w190 h26 Background" FIELDBG, r.trigger)

    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x276 y16 w34 h22 +0x200 Right", "Fires")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    ; ":*:" fires the moment you finish typing the trigger; "::" waits for a
    ; space or punctuation. The library is overwhelmingly "::", and the
    ; difference is invisible until a trigger is a prefix of a word you type.
    rdPlain := eg.Add("Radio", "x316 y17 Group" (r.options = "" ? " Checked" : ""),
                      "after a space  ( :: )")
    rdWild  := eg.Add("Radio", "x470 y17" (r.options != "" ? " Checked" : ""),
                      "immediately  ( :*: )")

    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x624 y16 w30 h22 +0x200 Right", "File")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    ddFile := eg.Add("DropDownList", "x660 y13 w150", files.names)
    for i, rel in files.rels
        if (rel = r.file)
            ddFile.Choose(i)

    ; The stamp is carried through every save rather than refreshed, so "Newest
    ; first" keeps meaning "written lately" and not "touched lately".
    eg.SetFont("s8 c" MUTED, "Segoe UI")
    lblMeta := eg.Add("Text", "x70 y44 w740",
        "added " (r.added = "" ? "(unstamped)" : r.added)
      . "   " Chr(0x00B7) "   " r.file " line " r.line
      . (HSU_IsPinned(r.trigger) ? "   " Chr(0x00B7) "   pinned" : "")
      . (HSU_Count(r.trigger) ? "   " Chr(0x00B7) "   sent "
                                . HSU_Count(r.trigger) " time(s)" : ""))

    ; ── the two ways to edit the body ─────────────────────────────────────────
    eg.SetFont("s9 c" TXT, "Segoe UI")
    tabs := eg.Add("Tab3", "x14 y66 w796 h360", ["Steps", "Source"])

    tabs.UseTab(1)
    eg.SetFont("s8 c" MUTED, "Segoe UI")
    ; Fixed height, and the controls below start past it. An auto-height Text
    ; that wraps to a second line grows DOWNWARD over whatever is beneath it,
    ; and the list underneath does not move out of the way.
    eg.Add("Text", "x26 y92 w776 h30",
           "One row per message. Pick a row to edit its words below; a line break "
         . "in the box is a line break in the message.   " Chr(0x00B7) "   "
         . Chr(0x2018) "Send it, then wait" Chr(0x2019) " also holds the chat for "
         . "that many ms before the next row goes out.")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    lvSteps := eg.Add("ListView", "x26 y126 w776 h112 Background" LISTBG
                                . " -Multi", ["#", "Sent as", "Message"])
    lvSteps.ModifyCol(1, "34 Integer Center")
    lvSteps.ModifyCol(2, 110)
    lvSteps.ModifyCol(3, 610)

    eg.SetFont("s9 c" TXT, "Segoe UI")
    bStepAdd := eg.Add("Button", "x26  y246 w70 h26", "Add")
    bStepDel := eg.Add("Button", "x100 y246 w70 h26", "Delete")
    bStepUp  := eg.Add("Button", "x174 y246 w40 h26", Chr(0x25B2))
    bStepDn  := eg.Add("Button", "x218 y246 w40 h26", Chr(0x25BC))

    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x286 y250 w52 h22 +0x200 Right", "Sent as")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    ; The three senders, named by what they DO rather than by their function
    ; names — which is the thing you actually have to decide per line. The
    ; function names are still what goes in the file.
    ddFn := eg.Add("DropDownList", "x342 y247 w236",
                   ["send it, then Enter            snd()",
                    "paste it, no Enter             SendText()",
                    "send it, then wait             Sendt()"])
    eg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    eg.Add("Text", "x590 y250 w48 h22 +0x200 Right", "wait")
    eg.SetFont("s9 c" TXT, "Segoe UI")
    edMs := eg.Add("Edit", "x642 y247 w70 h24 Background" FIELDBG)
    eg.SetFont("s8 c" MUTED, "Segoe UI")
    lblMs := eg.Add("Text", "x718 y251 w84", "")

    eg.SetFont("s10 c" TXT, "Segoe UI")
    edStep := eg.Add("Edit", "x26 y280 w776 h134 Multi +WantReturn +VScroll Background"
                            FIELDBG)

    tabs.UseTab(2)
    eg.SetFont("s8 c" MUTED, "Segoe UI")
    lblSrc := eg.Add("Text", "x26 y96 w776 h44", "")
    eg.SetFont("s10 c" TXT, "Segoe UI")
    edSrc := eg.Add("Edit", "x26 y144 w776 h270 Multi +WantReturn +VScroll +HScroll"
                          . " Background" FIELDBG)
    tabs.UseTab()

    eg.SetFont("s9 c" TXT, "Segoe UI")
    bSave := eg.Add("Button", "x610 y438 w92 h30 Default", "Save")
    bCan  := eg.Add("Button", "x710 y438 w100 h30", "Cancel")
    eg.SetFont("s8 c" MUTED, "Segoe UI")
    lblNote := eg.Add("Text", "x14 y444 w580 h20", "")

    tabs.OnEvent("Change", OnTab)
    lvSteps.OnEvent("ItemFocus", PickStep)
    ddFn.OnEvent("Change", OnFnChange)
    bStepAdd.OnEvent("Click", AddStep)
    bStepDel.OnEvent("Click", DelStep)
    bStepUp.OnEvent("Click",  (*) => MoveStep(-1))
    bStepDn.OnEvent("Click",  (*) => MoveStep(1))
    bSave.OnEvent("Click", SaveEdit)
    bCan.OnEvent("Click",  CloseEditor)
    eg.OnEvent("Close",  CloseEditor)
    eg.OnEvent("Escape", CloseEditor)

    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", eg.Hwnd, "int", 20, "int*", 1, "int", 4)
    for hwnd in [lvSteps.Hwnd, edStep.Hwnd, edSrc.Hwnd, edTrig.Hwnd]
        try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    try THEME_BoldButtons(eg)

    RefreshSteps(1)
    edSrc.Value := HSE_ToCrLf(source)
    ; A body the Steps view cannot rebuild opens on Source, with the reason where
    ; you will read it. Silently showing a Steps view that would DROP a line on
    ; save is the failure this whole distinction exists to prevent.
    if !r.plain {
        tabs.Choose(2)
        onSteps := false
        lblSrc.Text := "This block does more than send messages — a local, a loop, "
                     . "something the Steps view cannot rebuild — so it is edited as "
                     . "source. Switching to Steps would drop those lines."
    } else {
        lblSrc.Text := "The body as it is written in the file, between the braces. "
                     . "Whichever tab you are on when you press Save is what gets "
                     . "written."
    }
    eg.Show("w824 h484")
    return

    ; ── nested handlers (closures over steps / cur / the controls above) ──────

    RefreshSteps(want) {
        lvSteps.Opt("-Redraw")
        lvSteps.Delete()
        for i, st in steps
            lvSteps.Add(, i, HSE_FnLabel(st), FlattenOneLine(st.text))
        lvSteps.Opt("+Redraw")
        if steps.Length {
            want := Max(1, Min(want, steps.Length))
            lvSteps.Modify(want, "Select Focus Vis")
            LoadStep(want)
        } else {
            cur := 0
            edStep.Value := ""
        }
        UpdateNote()
    }

    LoadStep(i) {
        cur := i
        edStep.Value := HSE_ToCrLf(steps[i].text)
        ddFn.Choose(HSE_FnIndex(steps[i].fn))
        edMs.Value := steps[i].ms
        OnFnChange()
    }

    ; Read the boxes back into the working copy. Called before ANY change of
    ; which row is selected, and again at Save — the box is the truth only while
    ; you are looking at it.
    CommitStep() {
        if (cur < 1 || cur > steps.Length)
            return
        steps[cur].text := HSE_FromCrLf(edStep.Value)
        steps[cur].fn   := HSE_FnName(ddFn.Value)
        steps[cur].ms   := Trim(edMs.Value)
        lvSteps.Modify(cur, , cur, HSE_FnLabel(steps[cur]),
                       FlattenOneLine(steps[cur].text))
    }

    PickStep(ctrl, row) {
        if (!row || row = cur || row > steps.Length)
            return
        CommitStep()
        LoadStep(row)
    }

    ; The wait box belongs to Sendt and nothing else. Disabled rather than hidden
    ; so the row does not jump about as you change the dropdown.
    OnFnChange(*) {
        isWait := (ddFn.Value = 3)
        edMs.Enabled := isWait
        ; "ms" and not "ms before the next line": the label has 84px, and the
        ; longer wording was clipped mid-word. The sentence it was trying to say
        ; is in the help line at the top of this tab instead.
        lblMs.Text := isWait ? "ms" : ""
        if (isWait && Trim(edMs.Value) = "")
            edMs.Value := "500"
        ; Commit, so the row's "Sent as" cell changes as you change the dropdown
        ; rather than staying stale until you click another row. Harmless when
        ; LoadStep calls this: it writes back the values it has just loaded.
        CommitStep()
    }

    AddStep(*) {
        CommitStep()
        steps.Push({fn: "snd", text: "", ms: ""})
        RefreshSteps(steps.Length)
        edStep.Focus()
    }

    DelStep(*) {
        if (cur < 1 || cur > steps.Length)
            return
        steps.RemoveAt(cur)
        want := cur
        cur := 0
        RefreshSteps(want)
    }

    MoveStep(by) {
        CommitStep()
        to := cur + by
        if (cur < 1 || to < 1 || to > steps.Length)
            return
        tmp := steps[cur]
        steps[cur] := steps[to]
        steps[to]  := tmp
        cur := 0
        RefreshSteps(to)
    }

    ; ── switching tabs converts ───────────────────────────────────────────────
    ;  Leaving Steps renders them into the Source box, so what Source shows is
    ;  always what Save would write. Leaving Source parses it back — and asks
    ;  first when that would lose something, because that is the lossy direction.
    OnTab(*) {
        if (tabs.Value = 2) {
            if onSteps {
                CommitStep()
                edSrc.Value := HSE_ToCrLf(HSI_RenderBody(steps))
            }
            onSteps := false
            UpdateNote()
            return
        }
        body := HSE_FromCrLf(edSrc.Value)
        if (!onSteps && !HSI_BodyIsPlain(body)) {
            if (MsgBox("This body has lines that are not send calls — a local, a "
                     . "loop, something else.`n`nThe Steps view can only rebuild "
                     . "send calls, so switching to it and saving would DELETE "
                     . "those lines.`n`nSwitch anyway?",
                       "Edit hotstring", 0x24) != "Yes") {
                tabs.Choose(2)
                return
            }
        }
        if !onSteps {
            steps := HSI_StepsFromBody(body)
            cur := 0
            RefreshSteps(1)
        }
        onSteps := true
        UpdateNote()
    }

    UpdateNote() {
        lblNote.Text := onSteps
            ? steps.Length " message(s) — Save writes them into "
              . files.rels[ddFile.Value]
            : "editing the source — Save writes the body exactly as it reads here"
    }

    ; ── save ──────────────────────────────────────────────────────────────────
    SaveEdit(*) {
        global searchEd
        if onSteps
            CommitStep()

        newTrig := Trim(edTrig.Value)
        newOpts := rdWild.Value ? "*" : ""
        newRel  := files.rels[ddFile.Value]
        body    := onSteps ? HSI_RenderBody(steps) : HSE_FromCrLf(edSrc.Value)

        if (newTrig = "") {
            MsgBox("A hotstring needs a trigger — the abbreviation you type.",
                   "Edit hotstring", 0x30)
            return
        }
        ; "::" inside a trigger would close the definition early, so the rest of
        ; what you typed would be read as the body. Refused rather than escaped:
        ; there is no way to type such a trigger anyway.
        if InStr(newTrig, "::") {
            MsgBox("'" newTrig "' contains '::', which is what ENDS a trigger — a "
                 . "hotstring cannot have one in its name.", "Edit hotstring", 0x30)
            return
        }
        clash := HSI_FindTrigger(newTrig, r.file, r.line)
        if IsObject(clash) {
            MsgBox("'" newTrig "' is already defined in " clash.file " at line "
                 . clash.line ".`n`nAHK matches triggers case-insensitively, so two "
                 . "definitions of one trigger is not two hotstrings — it is one, "
                 . "and which body fires depends on which script loaded last.",
                   "Trigger already used", 0x30)
            LOG_Bail("hs.edit", "refused to rename " r.trigger " to " newTrig
                              . " — already defined in " clash.file)
            return
        }
        ; An "=" cannot be an ini key, and both the [hotstring] key binding and
        ; the pin are stored under the trigger. Refused for the same reason the
        ; Hotkey button refuses it, and BEFORE anything is written.
        if (InStr(newTrig, "=") && (HK_Key(HK_HotstringId(r.trigger)) != ""
                                    || HSU_IsPinned(r.trigger))) {
            MsgBox("'" newTrig "' has an '=' in it, and that is what separates a "
                 . "setting from its value in an ini — so this trigger cannot keep "
                 . "its key or its pin.`n`nRename it differently, or clear the key "
                 . "and the pin first.", "Edit hotstring", 0x30)
            return
        }

        moved := (newRel != r.file)
        if moved {
            ; Append FIRST, delete second. A failed append leaves the hotstring
            ; where it was; a failed delete after a good append leaves it in both
            ; files, which is visible and fixable. The other order can lose it.
            res := HSI_AppendBlock(newRel, newOpts, newTrig, body, r.added)
            if !res.ok {
                MsgBox(res.why, "Edit hotstring", 0x30)
                return
            }
            res := HSI_DeleteBlock(r.file, r.line, r.trigger)
            if !res.ok {
                MsgBox("The hotstring was written into " newRel ", but it could "
                     . "NOT be removed from " r.file ":`n`n" res.why
                     . "`n`nIt is now defined in both files. Delete it from "
                     . r.file " before restarting them.", "Edit hotstring", 0x30)
                RescanFiles()
                return
            }
        } else {
            res := HSI_ReplaceBlock(r.file, r.line, r.trigger, newOpts, newTrig,
                                    body, r.added)
            if !res.ok {
                MsgBox(res.why, "Edit hotstring", 0x30)
                return
            }
        }

        HSE_Migrate(r, newTrig, newOpts, newRel)

        ; The scripts read their hotstrings at LOAD, so the file on disk is not
        ; the hotstring that fires until the owning script starts again. Both
        ; files when it moved — the old one still has the block in memory.
        restarted := HSE_Restart(r.file, moved ? newRel : "")
        RescanFiles()
        eg.Destroy()
        Notify(r.trigger (newTrig = r.trigger ? "" : " → " newTrig)
             . " saved to " HsFileLabel(newRel) "  " Chr(0x2014) "  " restarted)
    }

    CloseEditor(*) {
        eg.Destroy()
    }
}

; ── the three files that key off a trigger ────────────────────────────────────
;  Called after the source write has SUCCEEDED, never before: each of these
;  points at a hotstring, and pointing them at a rename that then failed to write
;  would leave a key, an overload and a pin all naming something that does not
;  exist.
HSE_Migrate(r, newTrig, newOpts, newRel) {
    ; 1. the key bound to it, in hotkeys.ini's [hotstring] section
    if (newTrig != r.trigger) {
        k := HK_Key(HK_HotstringId(r.trigger))
        if (k != "") {
            try IniDelete(HK_INI, "hotstring", r.trigger)
            try IniWrite(k, HK_INI, "hotstring", newTrig)
            LOGI("hs.edit", "moved the key " HKP_KeyLabel(k) " from " r.trigger
                          . " to " newTrig)
        }
    }

    ; 2. its overload variants, in hotstring_overloads.ini
    e := OL_LoadOne(r.trigger)
    if (IsObject(e) && e.variants.Length
            && (newTrig != r.trigger || newOpts != r.options || newRel != r.file)) {
        OL_Remove(r.trigger)
        OL_Save(newTrig, newRel, newOpts, e.variants, e.mode)
        LOGI("hs.edit", "moved " e.variants.Length " overload variant(s) from "
                      . r.trigger " to " newTrig " in " OL_BaseName(newRel))
    }

    ; 3. its pin and its use count, in hotstring_usage.ini
    if (newTrig != r.trigger)
        HSU_Rename(r.trigger, newTrig)
}

; Restart the message script(s) whose hotstrings just changed, and say which.
;
; A restart, not a broadcast: a message script binds its hotstrings statically at
; LOAD, so an edited block does not become the thing that fires until the script
; runs again. Doing it silently would be worse than doing it — you would go on
; sending the old wording — and not doing it at all ships an edit that only takes
; effect tomorrow.
HSE_Restart(relA, relB := "") {
    done := "", idle := ""
    for _, rel in (relB = "" ? [relA] : [relA, relB]) {
        path := MMA_CONTENT "\" rel
        if !FileExist(path)
            continue
        ; Only what is actually RUNNING. SS_Restart stops then Runs, and its
        ; Run does not care whether there was anything to stop — so calling it
        ; blindly would START a message script you had deliberately left off,
        ; as a side effect of rewording one line in it.
        if !SS_Pid(path) {
            idle .= (idle = "" ? "" : " and ") HsFileLabel(rel)
            continue
        }
        SS_Restart(path)
        done .= (done = "" ? "" : " and ") HsFileLabel(rel)
    }
    if (done != "" && idle != "")
        return "restarted " done "; " idle " was not running"
    if (done != "")
        return "restarted " done
    if (idle != "")
        return idle " is not running, so it picks this up when it starts"
    return "nothing to restart"
}

; The label the steps list and the dropdown agree on for one step.
HSE_FnLabel(st) {
    switch StrLower(st.fn) {
        case "sendtext": return "paste"
        case "sendt":    return "send + " (Trim(st.ms) = "" ? "500" : Trim(st.ms))
        default:         return "send"
    }
}

; An Edit control speaks CRLF; everything else in MMA speaks LF. Converting at
; the boundary rather than everywhere else means a message that survives a
; round trip through the box unchanged — a stray `r in a step's text becomes a
; `` `r `` in the source file, which is a carriage return in a real message.
HSE_ToCrLf(s) {
    return StrReplace(StrReplace(StrReplace(s, "`r`n", "`n"), "`r", "`n"), "`n", "`r`n")
}
HSE_FromCrLf(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`r", "`n")
}

Notify(msg) {
    ToolTip(msg)
    SetTimer(RemoveToolTip, -2600)
}

; ── resize: search spans the width; list on top, showcase (full width) beneath ──
OnSize(g, minMax, w, h) {
    global searchEd, LV, detailEd, countTxt, btnOpen, btnCopy, btnRescan, lblSize, sizeDD
    global btnOver, btnKey, btnDelete, lblSort, sortDD, btnEdit, btnPin, HSW_COL_IDX
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

    ; preview column soaks up the list's spare width. Every other column is
    ; fixed, so the subtraction below is the sum of them plus the scrollbar —
    ; keep the two in step or the preview runs off the right-hand edge.
    LV.ModifyCol(1, 190)
    LV.ModifyCol(2, 30)
    LV.ModifyCol(4, 54)
    LV.ModifyCol(5, 54)
    LV.ModifyCol(6, 96)
    LV.ModifyCol(7, 130)
    LV.ModifyCol(8, 92)
    LV.ModifyCol(9, 56)
    LV.ModifyCol(3, Max(160, listW - 190 - 30 - 54 - 54 - 96 - 130 - 92 - 56 - 24))

    by := top + contentH + footerGap
    btnEdit.Move(m, by)
    btnOpen.Move(m + 92, by)
    btnCopy.Move(m + 210, by)
    btnRescan.Move(m + 328, by)
    btnOver.Move(m + 426, by)
    btnKey.Move(m + 550, by)
    btnPin.Move(m + 656, by)
    btnDelete.Move(m + 738, by)
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
