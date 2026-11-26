#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  chat/ppvpick.ahk — which PPV caption to send this fan, from what has sold.
; ───────────────────────────────────────────────────────────────────────────────
;  hotkeys.ini [util] ppvPick. Opens a list of captions for the chat on screen:
;
;    ┌ PPV scripts for Chris ─────────────────────────────────────────────────┐
;    │ #  Sold   Price  $/send  Caption                        Why             │
;    │ 1  2/3    $33    13.51   Just the two of us inside…     his: lost, …    │
;    │ 2  2/4    $130   47.32   As my finger finds its way…    over his usual  │
;    │ [ the whole caption of the selected row                              ]  │
;    └──────────────────────────────────────────────────────────────────────────┘
;
;  The library is every PPV the shift recorder has seen, grouped, with how often
;  each sold (services\llm\ppvlib.py). Ranked by what one send is expected to
;  earn; captions that use his own words go up, ones far over his biggest buy go
;  down, ones he already got are left out. Only captions sent to 2+ fans are
;  offered: a caption sent once was a custom for that fan.
;
;  Enter, double-click or Alt+1..8 puts the caption on the CLIPBOARD and closes.
;  Nothing is typed or sent. Esc closes. The price is yours to set in Infloww.
; ═══════════════════════════════════════════════════════════════════════════════

PPVPICK_PY := MMA_SRC "\services\llm\ppvlib.py"
PPVPICK_N  := 8

_ppvGui   := 0
_ppvList  := 0
_ppvFull  := 0
_ppvState := 0
_ppvRecs  := []
_ppvFan   := ""
_ppvOut   := ""
_ppvPid   := 0
_ppvStart := 0

PpvPickOpen() {
    global _ppvGui
    if _ppvGui
        _PpvPickClose()
    _PpvPickBuild()
    _PpvPickRun()
}

_PpvPickBuild() {
    global _ppvGui, _ppvList, _ppvFull, _ppvState, PPVPICK_N
    W := 760, PAD := 10
    g := Gui("+AlwaysOnTop +ToolWindow", "MMA PPV scripts")
    g.SetFont("s10", "Segoe UI")
    _ppvState := g.Add("Text", "x" PAD " y" PAD " w" (W - 2 * PAD), "reading the chat…")
    _ppvList := g.Add("ListView", "x" PAD " y+6 w" (W - 2 * PAD) " r" PPVPICK_N
                    . " -Multi Grid NoSortHdr", ["#", "Sold", "Price", "$/send", "Caption", "Why"])
    _ppvList.OnEvent("ItemSelect", _PpvPickShow)
    _ppvList.OnEvent("DoubleClick", _PpvPickDouble)
    _ppvFull := g.Add("Edit", "x" PAD " y+6 w" (W - 2 * PAD) " h84 ReadOnly Multi -VScroll", "")
    ok := g.Add("Button", "x" PAD " y+6 w0 h0 Default", "")       ; Enter = copy the selected one
    ok.OnEvent("Click", _PpvPickEnter)
    g.Add("Text", "x" PAD " y+2 w" (W - 2 * PAD) " cGray",
          "Enter / double-click / Alt+1-" PPVPICK_N " copies the caption. Sold = bought / sent"
        . " (shift recorder). Esc closes.")
    loop PPVPICK_N
        HotIfWinActive("ahk_id " g.Hwnd), Hotkey("!" A_Index, _PpvPickAlt, "On")
    HotIfWinActive()
    g.OnEvent("Escape", _PpvPickClose)
    g.OnEvent("Close",  _PpvPickClose)
    THEME_ApplyTo(g)
    _ppvGui := g

    ; Near the cursor, like the suggest window: you press it mid-chat.
    g.Show("Hide AutoSize")
    g.GetPos(, , &gw, &gh)
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    MonitorGetWorkArea(_SuggestMonitorAt(mx, my), &l, &t, &r, &bt)
    g.Show("x" Min(Max(mx - gw // 2, l), r - gw) " y" Min(Max(my + 20, t), bt - gh))
    _ppvList.Focus()
}

_PpvPickRun() {
    global _ppvOut, _ppvPid, _ppvStart, PPVPICK_PY, PPVPICK_N
    _ppvOut := A_Temp "\mma_ppvpick_" A_TickCount ".json"
    _ppvStart := A_TickCount
    try {
        Run('pythonw.exe "' PPVPICK_PY '" --now --json "' _ppvOut '" --n ' PPVPICK_N, , "Hide", &pid)
        _ppvPid := pid
    } catch as e {
        _PpvPickStatus("could not start Python (pythonw.exe not on PATH?)")
        LOGW("ppvpick", "Run failed: " e.Message)
        return
    }
    SetTimer(_PpvPickPoll, 100)
}

_PpvPickPoll() {
    global _ppvOut, _ppvPid, _ppvRecs, _ppvFan, _ppvList, _ppvStart
    if !FileExist(_ppvOut) {
        ; Still thinking — unless the process died without an answer.
        if _ppvPid && !ProcessExist(_ppvPid) {
            Sleep 50
            if !FileExist(_ppvOut) {
                SetTimer(_PpvPickPoll, 0)
                _PpvPickStatus("the PPV library stopped without an answer — see debuglogs")
            }
        }
        if (A_TickCount - _ppvStart > 2000)
            _PpvPickStatus("building the PPV library for the first time (about 30s)…")
        return
    }
    SetTimer(_PpvPickPoll, 0)
    ; Answered. The process may go on to refresh an hour-old library; closing
    ; the window must not kill that, so it is not ours to close any more.
    _ppvPid := 0
    try {
        res := JSON.Parse(FileRead(_ppvOut, "UTF-8"))
    } catch as e {
        _PpvPickStatus("could not read the answer: " e.Message)
        return
    }
    try FileDelete(_ppvOut)
    _ppvFan := res["fan"]
    _ppvRecs := res["recs"]
    if !_ppvRecs.Length {
        _PpvPickStatus(res["note"] != "" ? "nothing to suggest: " res["note"]
                                         : "nothing to suggest for " _ppvFan)
        return
    }
    _ppvList.Opt("-Redraw")
    for i, r in _ppvRecs {
        why := ""
        for w in r["hits"]
            why .= (why = "" ? "his words: " : ", ") w
        if r["over"]
            why .= (why = "" ? "" : "; ") "over his usual price"
        _ppvList.Add(, i, r["bought"] "/" r["sent"], "$" _PpvMoney(r["price"]),
                     _PpvMoney(r["per_send"]), r["text"], why)
    }
    _ppvList.ModifyCol(1, "30"), _ppvList.ModifyCol(2, "50"), _ppvList.ModifyCol(3, "64")
    _ppvList.ModifyCol(4, "56"), _ppvList.ModifyCol(5, "370"), _ppvList.ModifyCol(6, "AutoHdr")
    _ppvList.Opt("+Redraw")
    _ppvList.Modify(1, "Select Focus")
    _PpvPickStatus("PPV scripts for " (_ppvFan != "" ? _ppvFan : "this chat")
                 . " — best first, " _ppvRecs.Length " shown")
}

_PpvMoney(v) {
    return Format("{:.2f}", v)
}

_PpvPickShow(lv, row, selected) {
    global _ppvFull, _ppvRecs
    if selected && row >= 1 && row <= _ppvRecs.Length
        _ppvFull.Value := StrReplace(_ppvRecs[row]["text"], "`n", "`r`n")
}

_PpvPickDouble(lv, row) {
    _PpvPick(row)
}

_PpvPickEnter(*) {
    global _ppvList
    _PpvPick(_ppvList.GetNext(0))
}

_PpvPickAlt(hk) {
    _PpvPick(Integer(SubStr(hk, 2)))
}

_PpvPick(n) {
    global _ppvRecs, _ppvFan
    if n < 1 || n > _ppvRecs.Length
        return
    r := _ppvRecs[n]
    ; Which caption was taken, against what was offered: later this says whether
    ; the ranking is any good (did the top one get picked, did it sell).
    try FileAppend(JSON.Stringify(Map("at", A_Now, "fan", _ppvFan, "n", n, "id", r["id"],
                                      "price", r["price"], "text", r["text"])) "`n",
                   MMA_USERDATA "\ppv_picks.jsonl", "UTF-8-RAW")
    A_Clipboard := StrReplace(StrReplace(r["text"], "`r`n", "`n"), "`n", "`r`n")
    _PpvPickClose()
    ToolTip("PPV caption copied (usually $" _PpvMoney(r["price"]) ") — Ctrl+V to paste")
    SetTimer(_SuggestTipOff, -2500)
}

_PpvPickStatus(text) {
    global _ppvState
    if _ppvState
        try _ppvState.Value := text
}

_PpvPickClose(*) {
    global _ppvGui, _ppvPid, PPVPICK_N
    SetTimer(_PpvPickPoll, 0)
    if _ppvPid && ProcessExist(_ppvPid)
        try ProcessClose(_ppvPid)          ; a first-time build: it finishes next press
    _ppvPid := 0
    if _ppvGui {
        HotIfWinActive("ahk_id " _ppvGui.Hwnd)
        loop PPVPICK_N
            try Hotkey("!" A_Index, "Off")
        HotIfWinActive()
        _ppvGui.Destroy()
    }
    _ppvGui := 0
}
