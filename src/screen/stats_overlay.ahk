#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/hotkeys.ahk"
#Include "ocr_grab.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  stats_overlay.ahk — at-a-glance KPI overlay for Infloww "Chatting statistics".
;
;  Reads three numbers — Total Sales, Direct PPVs sent, Fans chatted — via the
;  offline Windows OCR. Those numbers live on the Infloww Home window, NOT the
;  Messages window you chat in, so we OCR Home *in the background* (PrintWindow,
;  OCR.FromWindow mode 4): the ratio keeps updating while you work another window,
;  and reading never steals focus. Regions are stored client-relative to Home, so
;  they survive that window being moved. Shows Sales + the PPVs-sent / Fans-chatted
;  ratio, colour-graded red→yellow→green on a spectrum (thresholds in the ini).
;
;  Calibrate by dragging a box around each number (right-click the overlay →
;  Calibrate) — include the little % change beside the two counts (a lone 1-2
;  digit number won't OCR; see CalibrateOne / ParseNum). Regions live in
;  mass_gui.cfg [StatsOverlay]. The overlay shows itself on launch (unless you hid
;  it last time — remembered in the cfg); the gui.toggleStats hotkey toggles it.
;
;  Started/stopped by the "Run stats overlay" toggle in mass_gui Settings.
; ═══════════════════════════════════════════════════════════════════════════════

; Nothing below is guaranteed to keep the script alive (no key may be bound, the
; refresh timer only runs while shown) — without this, AHK exits after auto-exec.
Persistent

CFG := MMA_CFG

; LOG_IniNum, not Number(IniRead(...)) — Number() throws on non-numeric exactly
; like Integer() does, and these three are the values a user is most likely to
; tune by hand. Unguarded, `RedAt = 30%` stopped this whole service loading.
RedAt    := LOG_IniNum(CFG, "StatsOverlay", "RedAt",    0.30, "stats.boot")
YellowAt := LOG_IniNum(CFG, "StatsOverlay", "YellowAt", 0.40, "stats.boot")
GreenAt  := LOG_IniNum(CFG, "StatsOverlay", "GreenAt",  0.50, "stats.boot")
PollMs   := LOG_IniInt(CFG, "StatsOverlay", "PollMs", 10000)
OcrScale := LOG_IniInt(CFG, "StatsOverlay", "OcrScale", 2)
PosX     := LOG_IniInt(CFG, "StatsOverlay", "PosX", 60)
PosY     := LOG_IniInt(CFG, "StatsOverlay", "PosY", 60)
Visible0 := LOG_IniInt(CFG, "StatsOverlay", "Visible", 1)
; The window carrying the Chatting-statistics numbers (a WinTitle criterion). The
; live suffix — "Infloww Home - 333" — is why this is a substring match, not exact.
StatsWin := IniRead(CFG, "StatsOverlay", "StatsWin", "Infloww Home ahk_exe Infloww.exe")

; seed the section so the tunables are visible/editable. String literals, not the
; Number()-parsed globals — writing those back leaves float noise (0.29999…).
if (IniRead(CFG, "StatsOverlay", "RedAt", "") = "") {
    for k, v in Map("RedAt","0.30", "YellowAt","0.40", "GreenAt","0.50",
                    "PollMs","10000", "OcrScale","2", "PosX",PosX, "PosY",PosY,
                    "Visible","1", "StatsWin",StatsWin)
        try IniWrite(v, CFG, "StatsOverlay", k)
}
SetTitleMatchMode 2   ; StatsWin is a substring criterion (title has a live suffix)

_sales := 0, _ppv := 0, _fans := 0
_haveSales := false, _havePpv := false, _haveFans := false
_visible := false
_savedPos := PosX "," PosY

CoordMode "Mouse", "Screen"

; ── overlay window ────────────────────────────────────────────────────────────
NOACTIVATE := "+E0x08000000"      ; WS_EX_NOACTIVATE — never take focus from chat
ov := Gui("+AlwaysOnTop -Caption +ToolWindow " NOACTIVATE, "MMA stats")
ov.BackColor := "121218"
ov.SetFont("s8 cE8E8F0", "Segoe UI")
txtSales := ov.Add("Text",     "x9 y5 w160", "Sales   —")
ov.SetFont("s10 Bold")
txtRatio := ov.Add("Text",     "x9 y20 w160", "PPV/Chat   —")
ov.SetFont("s8 Norm cE8E8F0")
bar      := ov.Add("Progress", "x9 y40 w160 h5 Background2A2A33", 0)

ov.OnEvent("ContextMenu", ShowMenu)
OnMessage(0x201, WM_LBUTTONDOWN)   ; drag from anywhere in the overlay
OnMessage(0x232, WM_EXITSIZEMOVE)  ; persist position as soon as a drag ends

statsMenu := Menu()
statsMenu.Add("Refresh now",             (*) => Refresh())
statsMenu.Add()
statsMenu.Add("Calibrate all",           (*) => CalibrateAll())
statsMenu.Add("Calibrate: Sales",        (*) => CalibrateOne("SalesRect",       "SALES"))
statsMenu.Add("Calibrate: PPVs sent",    (*) => CalibrateOne("PpvSentRect",     "DIRECT PPVs SENT"))
statsMenu.Add("Calibrate: Fans chatted", (*) => CalibrateOne("FansChattedRect", "FANS CHATTED"))
statsMenu.Add()
statsMenu.Add("Park it here",            ParkHere)
statsMenu.Add("Hide",                    (*) => HideOverlay())
statsMenu.Add()
statsMenu.Add("Exit the stats overlay",  ExitOverlay)

HK_Bind("gui.toggleStats", ToggleOverlay)

Paint()   ; render placeholders
if Visible0
    ShowOverlay()

; ── toggle / show / hide ──────────────────────────────────────────────────────
ToggleOverlay(*) {
    global _visible
    if _visible
        HideOverlay()
    else
        ShowOverlay()
}
ShowOverlay() {
    global ov, CFG, PosX, PosY, PollMs, _visible
    Refresh()
    ov.Show("x" PosX " y" PosY " w178 h52 NoActivate")
    SetTimer(Refresh, PollMs)
    _visible := true
    try IniWrite(1, CFG, "StatsOverlay", "Visible")
}
HideOverlay() {
    global ov, CFG, _visible
    SavePos()
    SetTimer(Refresh, 0)
    ov.Hide()
    _visible := false
    try IniWrite(0, CFG, "StatsOverlay", "Visible")
}

; ── quitting for good, as opposed to Hide ─────────────────────────────────────
;  "Hide" is temporary: the window goes, the process stays, and gui.toggleStats
;  brings it back. This is the other one — and a bare ExitApp does NOT deliver it.
;  main_window re-runs LaunchStatsOverlay every few seconds for as long as the
;  'statsOverlay' feature is on (core/processes.ahk), so quitting without touching
;  the feature is a window that disappears and is back before you have let go of
;  the mouse. Switching the feature off first is what exit has to mean here.
;
;  FEAT_SetRaw rather than a direct IniWrite: it is the single writer of every
;  feature key (see ui/features_panel.ahk), so the Settings ▸ Features checkbox and
;  the Tools window both follow this without either of them being told.
;
;  SavePos first — position is only persisted on drag-end and on Hide, and exiting
;  from the menu is neither, so without it a move made just before quitting is
;  the one that gets thrown away.
ExitOverlay(*) {
    SavePos()
    LOGI("stats", "exiting from the overlay's right-click menu — switching the"
               . " 'statsOverlay' feature off so it is not relaunched")
    FEAT_SetRaw("statsOverlay", false)
    ExitApp()
}

; ── read + render ─────────────────────────────────────────────────────────────
Refresh(*) {
    global CFG, OcrScale
    global _sales, _ppv, _fans, _haveSales, _havePpv, _haveFans
    if (r := RectFromCfg("SalesRect")) {
        v := ParseNum(OcrRect(r, OcrScale), true)
        if (v != "")
            _sales := v, _haveSales := true
    }
    if (r := RectFromCfg("PpvSentRect")) {
        v := ParseNum(OcrRect(PadForCount(r), OcrScale), false)
        if (v != "")
            _ppv := v, _havePpv := true
    }
    if (r := RectFromCfg("FansChattedRect")) {
        v := ParseNum(OcrRect(PadForCount(r), OcrScale), false)
        if (v != "")
            _fans := v, _haveFans := true
    }
    LOG_Kv("stats", Map("sales", _haveSales ? _sales : "—",
                        "ppv",   _havePpv   ? _ppv   : "—",
                        "fans",  _haveFans  ? _fans  : "—"), "VERB")
    SavePos()
    Paint()
}

; A tight box around a lone 1-2 digit count reads back EMPTY — Windows OCR discards
; a region with too little in it. On this stats page the little "% change" always
; sits just to the RIGHT of the count, so widen the box that way to give OCR real
; glyphs to latch onto; ParseNum then drops the % and keeps the leading number.
; (Anchored left/top so we never reach into the neighbouring column.)
PadForCount(r) {
    return {x: r.x, y: r.y - 8, w: r.w + 150, h: r.h + 16}
}

Paint() {
    global txtSales, txtRatio, bar
    global _sales, _ppv, _fans, _haveSales, _havePpv, _haveFans
    txtSales.Value := "Sales  " (_haveSales ? "$" Format("{:.2f}", _sales) : "—")
    if (_havePpv && _haveFans && _fans > 0) {
        ratio := _ppv / _fans
        col   := LerpColor(ratio)
        txtRatio.SetFont("c" col)
        txtRatio.Value := "PPV/Chat  " Round(ratio * 100) "%  (" _ppv "/" _fans ")"
        bar.Opt("+c" col)
        bar.Value := Min(100, Round(ratio * 100))
    } else {
        txtRatio.SetFont("cAAAAAA")
        txtRatio.Value := "PPV/Chat  —  (right-click)"
        bar.Value := 0
    }
}

; ── OCR + parsing ─────────────────────────────────────────────────────────────
; Rects are stored CLIENT-relative to the stats (Infloww Home) window, so we OCR
; that window directly via PrintWindow (mode 4). This reads it even while it's in
; the background behind the chat, and never steals focus. Returns "" if the window
; isn't open or the capture fails, leaving the last good value in place.
; VERB throughout: this runs on a repeating timer, so anything louder would be
; the only thing in the log. The overlay showing "—" for an hour is a mild
; annoyance, not a failure — but when somebody does ask why, these three lines
; separate "the Home window is not open" from "OCR read it and got nothing", which
; are the only two possibilities and have different fixes.
OcrRect(r, scale) {
    global StatsWin
    if !WinExist(StatsWin) {
        LOGV("stats", "the '" StatsWin "' window is not open — keeping the last"
                    . " numbers, showing '—' for anything never read")
        return ""
    }
    try
        return OCR.FromWindow(StatsWin, {x: r.x, y: r.y, w: r.w, h: r.h,
                                         scale: scale, grayscale: 1, mode: 4}).Text
    catch as e {
        LOGV("stats", "OCR of the " r.w "x" r.h " box at " r.x "," r.y " failed — "
                    . LOG_Err(e))
        return ""
    }
}

; Pull a number out of an OCR line. Money keeps decimals (strip $ and commas);
; counts take the leading integer run (the column reads e.g. "43 -").
; The calibration box deliberately includes the little "% change" beside the
; number (a lone small number won't OCR — see CalibrateOne), so first delete any
; percentage token, otherwise "5 -93.33%" could read back as 93.
ParseNum(text, isMoney) {
    text := RegExReplace(text, "[-+]?\d[\d.,]*\s*%", "")
    if (isMoney) {
        if RegExMatch(text, "([\d,]+(?:\.\d+)?)", &m)
            return Number(StrReplace(m[1], ",", ""))
        return ""
    }
    if RegExMatch(text, "(\d[\d,]*)", &m)
        return Integer(StrReplace(m[1], ",", ""))
    return ""
}

RectFromCfg(key) {
    global CFG
    p := StrSplit(Trim(IniRead(CFG, "StatsOverlay", key, "")), ",")
    if (p.Length < 4)
        return 0
    return {x: Integer(Trim(p[1])), y: Integer(Trim(p[2])), w: Integer(Trim(p[3])), h: Integer(Trim(p[4]))}
}

; ── colour spectrum ───────────────────────────────────────────────────────────
; ≤RedAt red, RedAt→YellowAt lerp red→yellow, YellowAt→GreenAt lerp yellow→green,
; ≥GreenAt green. Returns an "RRGGBB" string for SetFont/Opt.
LerpColor(r) {
    global RedAt, YellowAt, GreenAt
    red    := [225, 66, 66]
    yellow := [232, 196, 66]
    green  := [78, 200, 96]
    if (r <= RedAt)
        c := red
    else if (r < YellowAt)
        c := Lerp3(red, yellow, (r - RedAt) / (YellowAt - RedAt))
    else if (r < GreenAt)
        c := Lerp3(yellow, green, (r - YellowAt) / (GreenAt - YellowAt))
    else
        c := green
    return Format("{:02X}{:02X}{:02X}", c[1], c[2], c[3])
}
Lerp3(a, b, t) {
    return [Round(a[1] + (b[1] - a[1]) * t),
            Round(a[2] + (b[2] - a[2]) * t),
            Round(a[3] + (b[3] - a[3]) * t)]
}

; ── calibration ───────────────────────────────────────────────────────────────
; Drag a box around JUST the number — for the two counts the reader auto-widens
; rightward to the % (see PadForCount), so you don't have to be precise. Stored
; CLIENT-relative to the stats window so the boxes hold if that window is moved.
CalibrateOne(key, label) {
    global CFG, ov, StatsWin, _visible
    wasVisible := _visible
    if wasVisible
        ov.Hide()
    ToolTip("Drag a box around " label " on the Infloww Home page     (Esc cancels)")
    rect := OcrSelectRegion()
    ToolTip()
    if wasVisible
        ov.Show("NoActivate")
    if !rect
        return false
    if (hw := WinExist(StatsWin)) {
        ; TOCTOU: the Home window can close between WinExist and WinGetClientPos,
        ; and then this throws away a calibration the user has just finished
        ; dragging — with nothing written and nothing said.
        try {
            WinGetClientPos(&cx, &cy, , , hw)
        } catch as e {
            LOGE("stats.calibrate", "the '" StatsWin "' window closed mid-calibration"
                                  . " — the box was NOT saved", LOG_Err(e))
            MsgBox("The stats window closed before I could anchor the box to it."
                 . "`n`nNothing was saved — open it and calibrate again.",
                   "Calibrate", 0x30)
            return false
        }
        rect.x -= cx, rect.y -= cy      ; screen → client of the stats window
    } else {
        MsgBox "The Infloww Home (statistics) window isn't open, so I can't anchor"
             . " this box to it. Open it and calibrate again.",, 0x30
        return false
    }
    IniWrite(rect.x "," rect.y "," rect.w "," rect.h, CFG, "StatsOverlay", key)
    Refresh()
    return true
}
CalibrateAll() {
    if !CalibrateOne("SalesRect",       "SALES")
        return
    if !CalibrateOne("PpvSentRect",     "DIRECT PPVs SENT")
        return
    CalibrateOne("FansChattedRect", "FANS CHATTED")
}

; ── window plumbing ───────────────────────────────────────────────────────────
ShowMenu(guiObj, ctrlObj, item, isRightClick, x, y) {
    global statsMenu
    statsMenu.Show()
}

; Drag a caption-less window by its client area: turn a left-press anywhere in the
; overlay into a title-bar drag (WM_NCLBUTTONDOWN / HTCAPTION).
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global ov
    if (DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") = ov.Hwnd) {
        ; 4th arg is Control and must stay OMITTED — a 0 there makes AHK hunt for
        ; a control with hwnd 0 and throw "Target window not found".
        PostMessage(0xA1, 2, 0, , "ahk_id " ov.Hwnd)
        return 0
    }
}

WM_EXITSIZEMOVE(wParam, lParam, msg, hwnd) {
    SavePos()
}

SavePos() {
    global ov, CFG, _visible, _savedPos, PosX, PosY
    if !_visible
        return
    ov.GetPos(&px, &py)
    if (px = "" || (px "," py) = _savedPos)
        return
    _savedPos := px "," py
    PosX := px, PosY := py   ; so a later hide→show reopens where you left it
    try IniWrite(px, CFG, "StatsOverlay", "PosX")
    try IniWrite(py, CFG, "StatsOverlay", "PosY")
}

; "Park it here" menu item: commit the overlay's current spot as its default
; opening position (PosX/PosY), unconditionally — unlike SavePos, no debounce, so
; it also works when the drag-end save happened to be skipped. A tooltip confirms.
ParkHere(*) {
    global ov, CFG, PosX, PosY, _savedPos
    ov.GetPos(&px, &py)
    if (px = "")
        return
    PosX := px, PosY := py, _savedPos := px "," py
    try IniWrite(px, CFG, "StatsOverlay", "PosX")
    try IniWrite(py, CFG, "StatsOverlay", "PosY")
    ToolTip("Parked — this is now the overlay's default position")
    SetTimer(ClearToolTip, -1400)
}
ClearToolTip() {
    ToolTip()
}
