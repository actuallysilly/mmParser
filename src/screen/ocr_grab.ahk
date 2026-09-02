#Requires AutoHotkey v2.0
#Include "../vendor/OCR.ahk"
#Include "../core/dpi.ahk"
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
    ;
    ; -DPIScale is NOT cosmetic here, it is the whole grab. Gui.Show multiplies w
    ; and h by A_ScreenDPI/96 (x and y pass through untouched), so at 125% the box
    ; drawn under the cursor came out 25% wider and taller than the rect handed to
    ; OCR — you dragged until the blue box covered the message, and the capture was
    ; the last 80% short of it. That is why the end of every sentence went missing.
    ; Mouse coordinates are physical pixels; these two windows must be too.
    static NOACTIVATE := "-DPIScale +E0x08000000"
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

    ; The hint keeps +DPIScale, deliberately: it is a text banner, not a
    ; measurement. Its font grows with the DPI, so its window has to as well or
    ; the one line explaining how to get out of the overlay gets clipped.
    hint := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
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
                if (bw > 0 && bh > 0) {
                    box.Show("x" bx " y" by " w" bw " h" bh " NoActivate")
                    ; Re-punched on every tick, not once at creation: a window
                    ; region is in WINDOW coordinates, so it does not follow a
                    ; resize. Skip this and the frame is whatever size the box
                    ; first happened to be.
                    HollowBox(box.Hwnd, bw, bh)
                }
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

; Punch the middle out of the selection box, leaving a frame you can see through.
;
; The box was a SOLID fill, and that is what made this thing so hard to aim. It is
; drawn ON TOP of the very text you are framing, over a sheet that has already
; dimmed the desktop — so from the moment the drag starts you cannot read a word
; of what you are selecting. You end up placing the edges by memory, and an edge a
; few pixels out slices a line in half. What comes back then looks exactly like
; OCR "cutting" the text, when the engine in fact read every pixel it was given:
; measured on a real grab, the box itself had clipped "...Imagine" to "k..." and
; "her ball" to "ter ball" before OCR ever ran.
;
; RGN_DIFF of the outer rect against an inset one. After SetWindowRgn the WINDOW
; owns the region, so `outer` must not be deleted here — `inner` must.
HollowBox(hwnd, bw, bh, thick := 3) {
    ; No inside to punch. Leave it filled rather than build an empty region, which
    ; would make the box vanish exactly when it is a thin sliver — and a selection
    ; tool that disappears while you are dragging it is worse than a solid one.
    if (bw <= thick * 2 || bh <= thick * 2)
        return
    outer := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", bw, "int", bh, "ptr")
    inner := DllCall("CreateRectRgn", "int", thick, "int", thick,
                     "int", bw - thick, "int", bh - thick, "ptr")
    DllCall("CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner, "int", 4)  ; RGN_DIFF
    DllCall("DeleteObject", "ptr", inner)
    DllCall("SetWindowRgn", "ptr", hwnd, "ptr", outer, "int", 1)
}

; OCR a screen rect and return its text, one line per line, in reading order.
OcrRegionToText(rect) {
    ; scale 3 AND grayscale, both measured on this UI rather than picked to taste.
    ; Read plain, Infloww's chat comes back as "(.. •mag•ne tne nectar tnat would mow
    ; out" — the recogniser guessing h→n, i→t, fl→m at the size these glyphs land on
    ; screen. grayscale ALONE does not fix that. And scale 2 is worse than nothing:
    ; it drops a whole line instead of garbling it, which is the failure you cannot
    ; see in the review box. scale 3 + grayscale reads the same rect back as
    ; "Imagine the nectar that would flow out" — the pair model_detector.ahk and
    ; fansly_detector.ahk already settled on.
    res := OCR.FromRect(rect.x, rect.y, rect.w, rect.h, {scale: 3, grayscale: 1})
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
;
; The whole thing runs per-monitor aware, and it has to be the WHOLE thing rather
; than the capture alone: the overlay you drag, the mouse coordinates it is built
; from, and the rect handed to OCR must all land in the same space. Under AHK's
; default system awareness they agree with each other and disagree with the
; screen on any monitor scaled differently from the primary — so the box sits
; away from the cursor and the text comes back clipped. See core/dpi.ahk.
OcrGrabToText() {
    _dpi := DpiScope()
    try {
        rect := OcrSelectRegion()
        if !rect
            return ""
        return OcrRegionToText(rect)
    } catch as e {
        MsgBox "OCR failed: " e.Message
             . "`n`nThis uses the OCR engine built into Windows. If it's missing,"
             . " add an English language pack under Settings > Time & language.",, 0x10
        return ""
    }
}
