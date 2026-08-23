#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "hotkeys_panel.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_window.ahk — the hotkey editor on its own, for when the main GUI isn't.
; ───────────────────────────────────────────────────────────────────────────────
;  The editor itself is hotkeys_panel.ahk and normally lives in the Settings
;  window's Hotkeys tab. This file is what is left of the standalone window: a
;  frame, a Save and a Close around the same panel.
;
;  It stays because it is the only way to fix a broken key binding without the
;  main GUI — run this file and nothing else. Everything it can do, the Settings
;  tab can do, and they share every line that matters, so there is no second
;  implementation to keep in step.
; ═══════════════════════════════════════════════════════════════════════════════

WIN_W := 900
WIN_H := 640
PAD   := 12

g := Gui("+Resize +MinSize790x320", "MMA Hotkeys")
; The same theme as every other MMA window. This one used to be the exception —
; a system-grey box next to a set of tinted ones — and it is the window you open
; precisely when the main GUI is not available, so it should not look like a
; different program. Read here rather than passed in: nothing else in this process
; knows the theme, and the file is run directly.
_bg := THEME_WindowBg()
if (_bg != "")
    g.BackColor := _bg
; Colour on the window font, BEFORE any control is added — see THEME_ApplyTo on
; why a label cannot be given its colour afterwards.
g.SetFont("s9" THEME_FontOpt(), "Segoe UI")
g.OnEvent("Close", OnClose)
g.OnEvent("Escape", OnClose)
g.OnEvent("Size", OnSize)

panel := HotkeysPanel(g, PAD, PAD, WIN_W - PAD * 2, WIN_H - PAD * 2, true)
btnClose := g.Add("Button", "x" (WIN_W - PAD - 194) " y" (WIN_H - PAD - 68) " w90 h30", "Close")
btnClose.OnEvent("Click", OnClose)

; After every control exists: on dark this is what stops black labels on a black
; window, and the bold pass runs on every theme.
THEME_ApplyTo(g)
THEME_BoldButtons(g)

g.Show("w" WIN_W " h" WIN_H)

OnSize(gg, minMax, w, h) {
    if (minMax = -1)          ; minimised
        return
    panel.Layout(PAD, PAD, w - PAD * 2, h - PAD * 2)
    ; The panel pins its own Save to the right edge of its rectangle; Close sits
    ; one button to the left of it.
    btnClose.Move(w - PAD - 194, h - PAD - 68)
}

OnClose(*) {
    if panel.HasUnsaved() && MsgBox("Discard unsaved hotkey changes?", "Unsaved", 0x24) != "Yes"
        return true          ; keep the window open
    ExitApp()
}
