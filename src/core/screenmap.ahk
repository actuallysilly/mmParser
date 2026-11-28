#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "dpi.ahk"
#Include "../vendor/json.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  screenmap.ahk — the AHK half of the Screen Map. READ ONLY.
; ───────────────────────────────────────────────────────────────────────────────
;  The service (src\services\screenmap\screenmap.pyw) watches every Infloww
;  window and writes userdata\layout\infloww.json: which window is which (main
;  window or fan window, which model tab is lit, which fan), and where every part
;  of it is. Proposal: docs\proposals\layout-layer.html.
;
;  THE RULE: nothing reads or clicks inside Infloww without SM_Require() passing.
;  No tool keeps its own coordinates. If the map can't vouch for the window, the
;  tool does nothing and says why — never a guess.
;
;  ── Use ──────────────────────────────────────────────────────────────────────
;      w := SM_Require("composer")          ; the window you're in, its composer
;      if !w
;          return                           ; already told you why
;      Click(w.x + w.w // 2, w.y + w.h // 2)
;
;  Returns an object: hwnd, kind ("main" | "fan"), model, x, y, w, h (SCREEN
;  pixels, per-monitor aware), rec (the whole record as a Map). Or "" on refusal.
;
;  Regions: strip, active_tab, tabs_row, list, list_heading, conversation,
;  header, messages, composer, insights. Not every window has every one (a fan
;  window has no list; no chat open = no messages/header/composer).
;
;  Coordinates in the file are window-relative physical pixels. The ONE place
;  they become screen positions is SM_ToScreen, inside DPI_Enter, so they mean
;  the same thing on the 125% monitor and the 150% one.
; ═══════════════════════════════════════════════════════════════════════════════

global SM_MAX_AGE_S := 15        ; older than this = the service isn't running
global SM_WAIT_MS   := 1200      ; how long to wait for a fresh measure
global _SM_Doc      := ""
global _SM_Stamp    := ""

; The whole map, parsed again only when the file's TEXT changed. Not the file
; time: AHK reads that to the second, and the service rewrites the file more
; often than that, so two different maps looked identical. The file is a few KB;
; reading it is instant, parsing it is the part worth skipping.
SM_Load() {
    global _SM_Doc, _SM_Stamp
    text := ""
    loop 2 {
        try text := FileRead(MMA_SCREENMAP, "UTF-8")
        if (text != "")
            break
        Sleep 30                    ; caught mid-replace: the next read is whole
    }
    if (text = "")
        return Map("windows", [], "updated", 0, "focus_hwnd", 0)
    if (text == _SM_Stamp && IsObject(_SM_Doc))
        return _SM_Doc
    try doc := JSON.Parse(text)
    catch
        return Map("windows", [], "updated", 0, "focus_hwnd", 0)
    _SM_Doc := doc
    _SM_Stamp := text
    return doc
}

SM_UnixNow() {
    return DateDiff(A_NowUTC, "19700101000000", "Seconds")
}

; The record for one window handle, or "".
SM_Window(hwnd, doc := "") {
    doc := IsObject(doc) ? doc : SM_Load()
    for rec in doc["windows"]
        if (rec["hwnd"] = hwnd)
            return rec
    return ""
}

; The window showing this model. If more than one does (a main window AND a fan
; window), the one you used LAST wins — Silly's call, 2026-11-27.
SM_ForModel(name, doc := "") {
    doc := IsObject(doc) ? doc : SM_Load()
    want := _SM_Key(name)
    best := ""
    for rec in doc["windows"] {
        if !(rec["kind"] = "main" || rec["kind"] = "fan")
            continue
        if (!rec.Has("model") || _SM_Key(rec["model"]) != want)
            continue
        if (best = "" || rec["last_focus"] > best["last_focus"])
            best := rec
    }
    return best
}

; Compare model names the way OCR mixes them up: case, and I vs l.
_SM_Key(s) {
    return RegExReplace(StrReplace(StrLower(s), "i", "l"), "[^a-z0-9]")
}

; ── THE GATE ──────────────────────────────────────────────────────────────────
;  region      "" for just the window, or one of the region names above
;  hwnd        0 = the window you're in (a hotkey's case)
;  interactive true = you pressed something: a refusal shows a tooltip.
;              false = a background tool: a refusal only goes to the log.
SM_Require(region := "", hwnd := 0, interactive := true) {
    if !hwnd
        hwnd := WinExist("A")
    loop 2 {
        doc := SM_Load()
        why := _SM_Problem(doc, hwnd, region)
        if (why = "")
            return _SM_Result(SM_Window(hwnd, doc), region)
        if (why = "!stale")                  ; the service is off: nothing to wait for
            return _SM_Refuse("the Screen Map isn't running", interactive)
        if (A_Index = 2 || !_SM_Remeasure(doc))
            return _SM_Refuse(why, interactive)
    }
}

; "" when the map vouches for this window right now, else the plain reason.
_SM_Problem(doc, hwnd, region) {
    if (SM_UnixNow() - doc["updated"] > SM_MAX_AGE_S)
        return "!stale"
    rec := SM_Window(hwnd, doc)
    if !IsObject(rec)
        return "you're not in an Infloww Messages window"
    if (rec["status"] != "ok")
        return rec["reason"] != "" ? rec["reason"] : "Infloww's layout isn't readable right now"
    if !(rec["kind"] = "main" || rec["kind"] = "fan")
        return "this Infloww window isn't a chat window"
    if (region != "" && !rec["regions"].Has(region))
        return "this window has no " StrReplace(region, "_", " ") " right now"
    if !_SM_SpotCheck(rec)
        return "Infloww's layout changed since it was measured"
    return ""
}

; Is the map still true? Same size and place, and the spot-check pixels still
; read what they did (the lit tab, the panel lines). Pixels are read from the
; SCREEN, so this is only trusted for the window in front — which is the window
; a hotkey acts on. A covered window is checked by the service's own captures.
_SM_SpotCheck(rec) {
    prev := DPI_Enter()
    try {
        try WinGetPos(&x, &y, &w, &h, "ahk_id " rec["hwnd"])
        catch
            return false
        r := rec["rect"]
        if (x != r[1] || y != r[2] || w != r[3] || h != r[4])
            return false
        if (WinExist("A") != rec["hwnd"])
            return true
        CoordMode("Pixel", "Screen")
        for c in rec["check"] {
            col := PixelGetColor(x + c[1], y + c[2])
            for v in [(col >> 16) & 0xFF, (col >> 8) & 0xFF, col & 0xFF]
                if (Abs(v - c[3]) > c[4])
                    return false
        }
        return true
    } finally {
        DPI_Leave(prev)
    }
}

; Ask the service to look again, and wait for the new map. False if it can't.
_SM_Remeasure(doc) {
    static EVENT_MODIFY_STATE := 0x0002
    h := DllCall("OpenEventW", "UInt", EVENT_MODIFY_STATE, "Int", false,
                 "Str", "Global\MMA.screenmap.remeasure", "Ptr")
    if !h
        return false
    was := doc["updated"]
    DllCall("SetEvent", "Ptr", h)
    DllCall("CloseHandle", "Ptr", h)
    start := A_TickCount
    while (A_TickCount - start < SM_WAIT_MS) {
        Sleep 60
        if (SM_Load()["updated"] > was)
            return true
    }
    return false
}

_SM_Result(rec, region) {
    out := {hwnd: rec["hwnd"], kind: rec["kind"], rec: rec,
            model: rec.Has("model") ? rec["model"] : ""}
    r := region = "" ? [0, 0, rec["rect"][3], rec["rect"][4]] : rec["regions"][region]
    pt := SM_ToScreen(rec["hwnd"], r[1], r[2])
    out.x := pt.x, out.y := pt.y, out.w := r[3], out.h := r[4]
    return out
}

; Window-relative -> screen. The one place this happens on the AHK side.
SM_ToScreen(hwnd, x, y) {
    prev := DPI_Enter()
    try {
        WinGetPos(&wx, &wy, , , "ahk_id " hwnd)
        return {x: wx + x, y: wy + y}
    } finally {
        DPI_Leave(prev)
    }
}

_SM_Refuse(why, interactive) {
    try LOG_Bail("screenmap", why)
    if interactive {
        ToolTip("Can't act here: " why)
        SetTimer(SM_TipOff, -2000)
    }
    return ""
}

SM_TipOff() {
    ToolTip()
}
