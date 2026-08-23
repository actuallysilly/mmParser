#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_panel_test.ahk — does the hotkey editor KEEP YOUR PLACE?
; ───────────────────────────────────────────────────────────────────────────────
;  The bug this exists for: every edit in that panel calls Fill(), Fill() empties
;  the ListView and adds every row back, and an emptied ListView scrolls itself to
;  the top and forgets its selection. So changing the key of the last hotkey in the
;  list threw you back to the first one, every single time, and you had to find your
;  place again before you could change the next one.
;
;  It is invisible to a control census — the window builds, the rows are all there,
;  the value is written correctly — so it is checked the only way it can be: scroll
;  the real list, edit through the real method, and read the scroll position back
;  off the control with LVM_GETTOPINDEX.
;
;  ─── WHAT IT DOES TO YOUR CONFIG: NOTHING ────────────────────────────────────
;  Save() is never called. Every edit here lands in the panel's `pending` map and
;  dies with the window, so hotkeys.ini is not written and no HK_MSG_RELOAD is
;  broadcast at the scripts you have running. It reads hotkeys.ini and
;  hotkeys.default.ini, and that is all it touches.
;
;  A window does flash: the list has to be REAL for a scroll position to mean
;  anything. `hotkeys_panel_test.ahk hold` leaves it up instead, the same as
;  settings_build_test.ahk.
; ═══════════════════════════════════════════════════════════════════════════════

; Warnings to stdout, not to a dialog. A #Warn dialog is MODAL, arrives before the
; first line runs, and from the outside is indistinguishable from a hang.
#Warn VarUnset, StdOut

#Include "../../src/core/paths.ahk"
#Include "../../src/core/hotkeys.ahk"
#Include "../../src/ui/hotkeys_panel.ahk"

; `try`, because "*" is stdout and there ISN'T one when this is double-clicked.
Out(s) {
    try FileAppend(s "`n", "*")
}
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    ExitApp(1)
}

pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── build the real panel in a real window ─────────────────────────────────────
; Shown, not hidden: a ListView that has never been drawn has no page to scroll,
; so LVM_GETTOPINDEX answers 0 whatever you do to it and this test would pass
; against the broken code.
g := Gui("+Resize", "MMA Hotkeys — self-test")
g.SetFont("s9", "Segoe UI")
panel := HotkeysPanel(g, 12, 12, 876, 616, false)
g.Show("w900 h640")

lv := panel.lv
Ck("the list has rows", lv.GetCount() > 20, 1)
Ck("a row per id, plus headings and gaps",
   panel.lvIds.Length = lv.GetCount(), 1)

; ── headings are inert ────────────────────────────────────────────────────────
; The feature headings and the blank rows between groups carry the id "", which is
; what stops a heading being assigned a key. If that ever stops being true, Set key
; throws "key not found" out of HK_META on the first heading someone double-clicks.
heads := 0, blanks := 0
Loop lv.GetCount() {
    if (panel.lvIds[A_Index] != "")
        continue
    if (lv.GetText(A_Index, 2) = "")
        blanks++
    else
        heads++
}
Ck("there are feature headings", heads > 1, 1)
Ck("a blank row between the groups", blanks = heads - 1, 1)

; Selecting one and asking the panel what is selected must give nothing at all.
firstHead := 0
Loop lv.GetCount() {
    if (panel.lvIds[A_Index] = "" && lv.GetText(A_Index, 2) != "") {
        firstHead := A_Index
        break
    }
}
lv.Modify(firstHead, "Select Focus")
Ck("a heading selects as nothing", panel.SelectedId(), "")

; ── the actual regression: an edit must not scroll you back to the top ────────
; Pick a row well down the list, scroll to it, and change it the way the Disable
; button does.
target := 0
Loop lv.GetCount() {
    if (A_Index > 25 && panel.lvIds[A_Index] != "") {
        target := A_Index
        break
    }
}
Ck("found a row past the first page", target > 25, 1)

panel.PinTop(target)
lv.Modify(target, "Select Focus")
topBefore := panel.TopIndex()
idBefore  := panel.SelectedId()
Ck("the list actually scrolled", topBefore > 1, 1)

panel.ClearSelected()               ; pending only — nothing is written anywhere

Ck("the scroll position survived the rebuild", panel.TopIndex(), topBefore)
Ck("the selected hotkey survived it too",      panel.SelectedId(), idBefore)
Ck("...and the edit landed",                   panel.pending[idBefore], "")
Ck("...and it is marked as unsaved",           panel.Flag(idBefore), HotkeysPanel.MARK_EDIT)
Ck("the panel knows it is dirty",              panel.HasUnsaved() ? 1 : 0, 1)

; Searching is the other way the row set changes, and there the top of the list IS
; the right place to be — so this one asserts the opposite.
panel.edSearch.Value := "follow"
panel.Fill(false)
Ck("a search filters the list", lv.GetCount() < panel.lvIds.Length + 1, 1)
; 1, not 0: TopIndex() answers in AHK's row numbering, which starts at one.
Ck("...and starts at the top",  panel.TopIndex(), 1)
found := 0
Loop lv.GetCount() {
    if (panel.lvIds[A_Index] != "" && InStr(lv.GetText(A_Index, 2), "ollow"))
        found++
}
Ck("...and what is left matches", found > 0, 1)

panel.edSearch.Value := ""
panel.Fill(false)

; ── the key labels ────────────────────────────────────────────────────────────
Ck("a chord reads as a chord", HKP_KeyLabel("^!F1"), "Ctrl+Alt+F1")
Ck("a mouse button reads as one", HKP_KeyLabel("XButton1"), "Mouse 4")
Ck("no key reads as an em dash", HKP_KeyLabel(""), Chr(0x2014))

Out("")
Out(pass " passed, " fail " failed")

if (A_Args.Length && StrLower(A_Args[1]) = "hold") {
    Out("holding the window open — close it, or it goes on its own in 60s")
    SetTimer(() => ExitApp(fail ? 1 : 0), -60000)
    Persistent
    return
}
ExitApp(fail ? 1 : 0)
