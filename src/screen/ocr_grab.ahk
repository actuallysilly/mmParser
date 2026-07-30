#Requires AutoHotkey v2.0
#Include "../vendor/OCR.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  ocr_grab.ahk — drag a box on screen, OCR it, get the text back.
;
;  This is the screen-reading half of gui.ocrGrab. main_window.ahk feeds the result
;  straight into OpenAddHotkey(), the same dialog gui.addHotkeyGrab (!0) uses —
;  so it inherits snd()/SendText()/Sendt(), the target-file list and the hotstring
;  options for free.
;
;  Reads via Windows' own OCR engine (Windows.Media.Ocr) — offline, no install.
; ═══════════════════════════════════════════════════════════════════════════════

; How long the selection overlay may sit there before it gives up. See the wait
; loop for why a full-screen click-swallowing window must never wait forever.
global OCR_SELECT_TIMEOUT_MS := 20000

; Guards against a second overlay stacking on the first. The hotkey is global, so
; pressing it again while the sheet is already up used to build a whole second
; set of windows over the first — and cancelling then cleared only the newest,
; leaving the desktop still covered by one nobody could see.
global _ocrSelecting := false

; Drag a rectangle across the whole desktop. Returns {x,y,w,h} or 0 if cancelled.
; Spans the virtual screen, so it works on any monitor / negative coordinates.
OcrSelectRegion() {
    global _ocrSelecting, OCR_SELECT_TIMEOUT_MS
    if _ocrSelecting
        return 0
    _ocrSelecting := true
    static SM_XVIRTUALSCREEN := 76, SM_YVIRTUALSCREEN := 77
         , SM_CXVIRTUALSCREEN := 78, SM_CYVIRTUALSCREEN := 79
    ; WS_EX_NOACTIVATE: these overlays must never steal focus from the chat.
    static NOACTIVATE := "+E0x08000000"
    vx := SysGet(SM_XVIRTUALSCREEN), vy := SysGet(SM_YVIRTUALSCREEN)
    vw := SysGet(SM_CXVIRTUALSCREEN), vh := SysGet(SM_CYVIRTUALSCREEN)

    ; Dim sheet to drag on + a bright box drawn on top of it. The sheet also
    ; swallows the click, so the drag can't reach the app underneath.
    sheet := Gui("+AlwaysOnTop -Caption +ToolWindow " NOACTIVATE)
    sheet.BackColor := "202020"
    sheet.Show("x" vx " y" vy " w" vw " h" vh " NoActivate")
    ; "ahk_id " Hwnd, matching recorder.ahk — this sheet covers every monitor, so
    ; a failed transparency call would black out the whole desktop.
    WinSetTransparent(90, "ahk_id " sheet.Hwnd)

    box := Gui("+AlwaysOnTop -Caption +ToolWindow " NOACTIVATE)
    box.BackColor := "22A0FF"

    hint := Gui("+AlwaysOnTop -Caption +ToolWindow " NOACTIVATE)
    hint.BackColor := "101010"
    hint.SetFont("s10 cWhite", "Segoe UI")
    ; Say every way out, because until one of them happens the whole desktop is
    ; unclickable and this strip is the only thing on screen that explains why.
    hint.Add("Text", "x12 y8 w520",
             "Drag a box around the messages   ·   Esc or right-click cancels"
           . "   ·   gives up after " (OCR_SELECT_TIMEOUT_MS // 1000) "s")
    hint.Show("x" (vx + 20) " y" (vy + 20) " w544 h34 NoActivate")

    prevCoord := A_CoordModeMouse
    CoordMode "Mouse", "Screen"
    DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32515, "Ptr"))  ; IDC_CROSS

    rect := 0
    ; Wait for a press — but NOT forever. This sheet covers the whole virtual
    ; screen and deliberately swallows the click, so for as long as it is up the
    ; entire desktop is unclickable. At 90/255 alpha over a dark theme it is also
    ; nearly invisible, so "I pressed the OCR key and now nothing on my computer
    ; responds to the mouse" is what a forgotten overlay actually looks like — and
    ; Escape being the only way out is no help if you cannot see why you are stuck.
    ;
    ; Giving up after 20 seconds costs a keypress to start again, and is the
    ; difference between a cancelled grab and a desktop you have to kill MMA to
    ; get back.
    LOGI("ocr.select", "region overlay is UP — the whole desktop is unclickable"
                     . " until you drag a box, press Escape, right-click, or it"
                     . " gives up after " (OCR_SELECT_TIMEOUT_MS // 1000) "s")
    startTick := A_TickCount
    while true {
        if GetKeyState("Escape", "P") {
            LOGI("ocr.select", "cancelled with Escape")
            break
        }
        if (A_TickCount - startTick > OCR_SELECT_TIMEOUT_MS) {
            ; The timeout is the safety net that stops a forgotten overlay locking
            ; the desktop. If it is what ended the selection, say so — otherwise
            ; the grab looks like it silently failed.
            LOGW("ocr.select", "gave up after " OCR_SELECT_TIMEOUT_MS "ms with no"
                             . " selection — the overlay is down and the desktop is"
                             . " clickable again")
            break
        }
        ; Right-click cancels too. One more way out than Escape, on the device
        ; your hand is already on — the overlay is a mouse tool.
        if GetKeyState("RButton", "P") {
            LOGI("ocr.select", "cancelled with a right-click")
            break
        }
        if GetKeyState("LButton", "P") {
            MouseGetPos &x1, &y1
            ; drag
            while GetKeyState("LButton", "P") {
                MouseGetPos &x2, &y2
                bx := Min(x1, x2), by := Min(y1, y2)
                bw := Abs(x2 - x1), bh := Abs(y2 - y1)
                if (bw > 0 && bh > 0)
                    box.Show("x" bx " y" by " w" bw " h" bh " NoActivate")
                Sleep 10
            }
            MouseGetPos &x2, &y2
            bx := Min(x1, x2), by := Min(y1, y2)
            bw := Abs(x2 - x1), bh := Abs(y2 - y1)
            if (bw >= 5 && bh >= 5)
                rect := {x: bx, y: by, w: bw, h: bh}
            break
        }
        Sleep 10
    }

    box.Destroy(), sheet.Destroy(), hint.Destroy()
    CoordMode "Mouse", prevCoord
    _ocrSelecting := false
    return rect
}

; OCR a screen rect and return its text, one line per line, in reading order.
OcrRegionToText(rect) {
    res := OCR.FromRect(rect.x, rect.y, rect.w, rect.h)
    lines := []
    for line in res.Lines {
        t := CleanOcrLine(line.Text)
        if (t = "")
            continue
        lines.Push({t: t, x: line.x, y: line.y})
    }
    SortByPosition(lines)
    out := ""
    for l in lines
        out .= (out = "" ? "" : "`n") l.t
    if (out = "")
        LOGW("ocr.grab", "OCR found no text in the " rect.w "x" rect.h " box at "
                       . rect.x "," rect.y " — nothing to add")
    else
        LOGI("ocr.grab", "OCR read " lines.Length " line(s), " StrLen(out)
                       . " chars from the " rect.w "x" rect.h " box at "
                       . rect.x "," rect.y)
    return out
}

; Windows OCR returns lines grouped by layout block, not top-to-bottom: in a chat
; that alternates sides it hands back every left-hand bubble before every
; right-hand one. Sorting by position puts them back in the order you read them.
SortByPosition(arr) {
    Loop arr.Length - 1 {
        i := A_Index + 1
        v := arr[i]
        j := i - 1
        while (j >= 1 && IsAfter(arr[j], v)) {
            arr[j + 1] := arr[j]
            j--
        }
        arr[j + 1] := v
    }
}

; Same row within a tolerance -> order left-to-right; otherwise top-to-bottom.
IsAfter(a, b) {
    if (Abs(a.y - b.y) > 10)
        return a.y > b.y
    return a.x > b.x
}

; Strip the chat furniture that sits inside the box next to the messages —
; timestamps, the per-message icons, stray single glyphs. Deliberately gentle:
; the Add Hotkey dialog shows the result in an editable box you review before
; appending, so under-cleaning costs a keystroke and over-cleaning eats content.
CleanOcrLine(t) {
    t := Trim(t)
    if (t = "")
        return ""
    ; Icon-only rows: the ⋮ kebab, a lone reaction emoji. Tested by "has no letter
    ; or digit", NOT by length — "no", "ok" and "<3" are real messages, and a
    ; length rule silently ate them.
    if !RegExMatch(t, "\w")
        return ""
    ; Timestamp rows. Everything from the clock time onwards is furniture: the
    ; sent ✓✓ (which OCR as stray punctuation) and the chatter name, which can run
    ; to several words. Since the trailing part varies but always FOLLOWS the
    ; time, drop the whole line once it starts with one instead of trying to
    ; enumerate what trails it. A leading reaction emoji/tick is tolerated.
    ; Trade-off: a message literally opening with a clock time ("8:30 pm works for
    ; me") goes too — visible in the review box, where you can put it back.
    if RegExMatch(t, "i)^\W{0,4}\d{1,2}:\d{2}\b")
        return ""
    return t
}

; The whole flow: select -> OCR -> text. Returns "" if cancelled or nothing read.
OcrGrabToText() {
    rect := OcrSelectRegion()
    if !rect
        return ""
    try {
        return OcrRegionToText(rect)
    } catch as e {
        MsgBox "OCR failed: " e.Message
             . "`n`nThis uses the OCR engine built into Windows. If it's missing,"
             . " add an English language pack under Settings > Time & language.",, 0x10
        return ""
    }
}
