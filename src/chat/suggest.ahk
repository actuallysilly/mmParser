#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  chat/suggest.ahk — suggest the next sexting message from the chat on screen.
; ───────────────────────────────────────────────────────────────────────────────
;  hotkeys.ini [util] suggest. Opens a small window and starts generating at once
;  (as Co-chatter, "nothing bought yet"):
;
;    ┌ Write: (•) Co-chatter ( ) Filler ( ) PPV  He has bought: [ nothing ▾ ]┐
;    │ PPV content: [ the next PPV / what the bundle shows               ]   │
;    │ Direction (optional): [                          ] [ Regenerate ]    │
;    │ [1] suggestion one          (⚠ + the rule, if it still breaks one)   │
;    │ [2] suggestion two                                                   │
;    │ [3] suggestion three                                                 │
;    │ status                                                               │
;    └──────────────────────────────────────────────────────────────────────┘
;
;  The chatter decides; the AI only writes (docs\chatting-process.md).
;  Co-chatter reads the moment itself and drafts her next 1-3 short texts in the
;  voice of the account in front (services\llm\prompts\cochatter.md); PPV content
;  there is the next PPV it should set up. 📝 = a note for you, never copied;
;  ✋ = it hands this message to you. Filler is pure roleplay; PPV is a caption
;  for the content you describe plus a question (prompts\sexting.md).
;  "He has bought" sets how explicit it may be. Change any of them, then Enter.
;
;  Pick one — click it, or Alt+1/2/3 — and it goes on the CLIPBOARD and the
;  window closes. Nothing is typed or sent. Esc closes.
;
;  The chat comes from the chat reader service (Settings ▸ Features ▸ "Chat
;  reader"), which keeps it OCR'd in the background — so a press costs only the
;  generation, about a second. Without the reader it still works, just slower:
;  services\llm\suggest.py reads the screen itself.
;
;  The work runs in a separate pythonw process and this window polls for its
;  answer, so the engine's other keys keep working while it thinks.
; ═══════════════════════════════════════════════════════════════════════════════

SUGGEST_PY    := MMA_SRC "\services\llm\suggest.py"
SUGGEST_COUNT := 3
; The content ladder, docs\chatting-process.md — same order as TIERS in
; suggest.py, because the index is what is sent.
SUGGEST_TIERS := ["nothing bought yet", "bikini", "hand-bra", "pasties / stickers",
                  "nipples visible", "full nudes", "genitals visible", "solo play",
                  "with other creators"]

_sugGui     := 0
_sugPrompt  := 0
_sugCo      := 0
_sugFiller  := 0
_sugPpv     := 0
_sugTier    := 0
_sugContent := 0
_sugBoxes   := []
_sugStatus  := 0
_sugTexts   := []
_sugPid     := 0
_sugOut     := ""
_sugStart   := 0
_sugId      := ""         ; suggest.py's run id, so a pick can be logged against it

SuggestOpen() {
    global _sugGui
    if _sugGui {
        _sugGui.Show()
        return
    }
    _SuggestBuild()
    _SuggestRun()
}

; Opens on Filler and "nothing bought yet" every time, never on the last fan's
; settings: the window is per press, and a remembered tier would carry one fan's
; heat into the next fan's chat.
_SuggestBuild() {
    global _sugGui, _sugPrompt, _sugCo, _sugFiller, _sugPpv, _sugTier, _sugContent
    global _sugBoxes, _sugStatus, SUGGEST_COUNT, SUGGEST_TIERS
    W := 600, PAD := 10
    g := Gui("+AlwaysOnTop +ToolWindow", "MMA suggestions")
    g.SetFont("s10", "Segoe UI")

    g.Add("Text", "x" PAD " y" (PAD + 3) " w50", "Write:")
    _sugCo     := g.Add("Radio", "x+4 yp w95 Checked Group", "Co-chatter")
    _sugFiller := g.Add("Radio", "x+4 yp w60", "Filler")
    _sugPpv    := g.Add("Radio", "x+4 yp w50", "PPV")
    _sugCo.OnEvent("Click", _SuggestModeChanged)
    _sugFiller.OnEvent("Click", _SuggestModeChanged)
    _sugPpv.OnEvent("Click", _SuggestModeChanged)
    g.Add("Text", "x+8 yp w100", "He has bought:")
    _sugTier := g.Add("DropDownList", "x+4 yp-3 w" (W - 2 * PAD - 379) " Choose1", SUGGEST_TIERS)   ; the rest of the row

    g.Add("Text", "x" PAD " y+10 w95", "PPV content:")
    _sugContent := g.Add("Edit", "x+4 yp-3 w" (W - 2 * PAD - 99) " h26")

    g.Add("Text", "x" PAD " y+10 w" (W - 2 * PAD), "Direction (optional). Enter for new suggestions:")
    _sugPrompt := g.Add("Edit", "x" PAD " y+4 w" (W - 2 * PAD - 110) " h26")
    regen := g.Add("Button", "x+10 yp-1 w100 h28 Default", "Regenerate")
    regen.OnEvent("Click", _SuggestRegen)

    _sugBoxes := []
    loop SUGGEST_COUNT {
        b := g.Add("Button", "x" PAD " y+10 w34 h84", "&" A_Index)
        b.OnEvent("Click", _SuggestPickButton)
        t := g.Add("Edit", "x+8 yp w" (W - 2 * PAD - 42) " h84 ReadOnly Multi -VScroll", "")
        _sugBoxes.Push(t)
    }
    _sugStatus := g.Add("Text", "x" PAD " y+8 w" (W - 2 * PAD), "")
    g.Add("Text", "x" PAD " y+2 w" (W - 2 * PAD) " cGray",
          "Alt+1/2/3 or the number button copies it to the clipboard. ⚠ = breaks a"
        . " rule (shown anyway). Esc closes.")

    g.OnEvent("Escape", _SuggestClose)
    g.OnEvent("Close",  _SuggestClose)
    THEME_ApplyTo(g)
    _sugGui := g

    ; Near the cursor, clamped to the monitor it is on: you press this mid-chat
    ; and you are looking where the pointer is.
    g.Show("Hide AutoSize")
    g.GetPos(, , &gw, &gh)
    CoordMode "Mouse", "Screen"
    MouseGetPos &mx, &my
    mon := _SuggestMonitorAt(mx, my)
    MonitorGetWorkArea(mon, &l, &t, &r, &bt)
    x := Min(Max(mx - gw // 2, l), r - gw)
    y := Min(Max(my + 20, t), bt - gh)
    g.Show("x" x " y" y " NoActivate")
    WinActivate g.Hwnd
    _sugPrompt.Focus()
}

; PPV needs a content description; filler must not have one. Co-chatter may:
; it is the next PPV, which the burst then sets up.
_SuggestModeChanged(*) {
    global _sugPpv, _sugFiller, _sugContent
    _sugContent.Enabled := !_sugFiller.Value
    if _sugPpv.Value
        _sugContent.Focus()
}

_SuggestMonitorAt(x, y) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if x >= l && x < r && y >= t && y < b
            return A_Index
    }
    return MonitorGetPrimary()
}

_SuggestRegen(*) {
    _SuggestRun()
}

; Starts a generation. A press while one is still running replaces it: the
; newer settings are the ones you want.
_SuggestRun() {
    global _sugPid, _sugOut, _sugStart, _sugPrompt, _sugBoxes, _sugTexts
    global _sugPpv, _sugCo, _sugFiller, _sugTier, _sugContent, SUGGEST_PY, SUGGEST_COUNT
    _SuggestKill()
    for b in _sugBoxes
        b.Value := ""
    _sugTexts := []

    ; Everything the chatter decided, as one small JSON file: suggest.py's
    ; --request. A file rather than arguments, so quotes and emoji in the
    ; direction or the content cannot break the command line.
    req := Map("mode",    _sugCo.Value ? "co" : _sugPpv.Value ? "ppv" : "filler",
               "tier",    Max(_sugTier.Value - 1, 0),
               "content", _sugFiller.Value ? "" : _sugContent.Value,
               "prompt",  _sugPrompt.Value)
    reqFile := A_Temp "\mma_suggest_request.json"
    _sugOut := A_Temp "\mma_suggest_out_" A_TickCount ".json"
    try FileDelete(reqFile)
    FileAppend(JSON.Stringify(req), reqFile, "UTF-8-RAW")

    _SuggestSetStatus("reading the chat and thinking…")
    _sugStart := A_TickCount
    try {
        Run('pythonw.exe "' SUGGEST_PY '" --request "' reqFile '" --out "' _sugOut
          . '" --count ' SUGGEST_COUNT, , "Hide", &pid)
        _sugPid := pid
    } catch as e {
        _SuggestSetStatus("could not start Python (pythonw.exe not on PATH?)")
        LOGW("suggest", "Run failed: " e.Message)
        return
    }
    SetTimer(_SuggestPoll, 100)
}

_SuggestPoll() {
    global _sugPid, _sugOut, _sugStart, _sugBoxes, _sugTexts, _sugId
    if FileExist(_sugOut) {
        SetTimer(_SuggestPoll, 0)
        _sugPid := 0
        try {
            res := JSON.Parse(FileRead(_sugOut, "UTF-8"))
        } catch as e {
            _SuggestSetStatus("could not read the answer: " e.Message)
            return
        }
        try FileDelete(_sugOut)
        _sugId := res.Has("id") ? res["id"] : ""
        ; What goes on the clipboard is "send": a co-chatter draft without its
        ; NOTE lines, and "" for a handoff (that message is yours to write).
        send := res.Has("send") ? res["send"] : res["suggestions"]
        notes := res.Has("notes") ? res["notes"] : []
        hand := res.Has("handoff") ? res["handoff"] : []
        _sugTexts := []
        for s in send
            _sugTexts.Push(s)
        flags := res.Has("flags") ? res["flags"] : []
        for i, b in _sugBoxes {
            if i > _sugTexts.Length {
                b.Value := ""
                continue
            }
            ; A draft that still breaks a rule is shown, marked, so the window is
            ; never empty — the marker is in the box only, never on the clipboard.
            warn := ""
            if i <= flags.Length && flags[i].Length {
                for f in flags[i]
                    warn .= (warn = "" ? "" : ", ") f
                warn := "⚠ " warn "`r`n"
            }
            if i <= hand.Length && hand[i] != "" {
                b.Value := "✋ yours to answer: " hand[i]
                continue
            }
            if i <= notes.Length
                for n in notes[i]
                    warn .= "📝 " n "`r`n"
            b.Value := warn StrReplace(_sugTexts[i], "`n", "`r`n")
        }
        secs := Round((A_TickCount - _sugStart) / 1000, 1)
        if _sugTexts.Length
            _SuggestSetStatus("ready in " secs "s")
        else
            _SuggestSetStatus("nothing suggested: " res["error"])
        LOGI("suggest", _sugTexts.Length " suggestion(s) in " secs "s"
                      . (res["error"] != "" ? " — " res["error"] : ""))
        return
    }
    ; The process ended without writing an answer: it crashed.
    if _sugPid && !ProcessExist(_sugPid) {
        Sleep 50                                  ; the file may land a beat later
        if !FileExist(_sugOut) {
            SetTimer(_SuggestPoll, 0)
            _sugPid := 0
            _SuggestSetStatus("the suggester stopped without an answer — see debuglogs")
        }
    }
}

_SuggestPickButton(btn, *) {
    _SuggestPick(Integer(SubStr(btn.Text, 2)))
}

_SuggestPick(n) {
    global _sugTexts, _sugId
    if n > _sugTexts.Length || _sugTexts[n] = ""      ; "" = a handoff: nothing to paste
        return
    ; Which one you took is a grade you did not have to give. Same log the
    ; viewer's 1-5 buttons write (services\llm\chatview.pyw).
    if _sugId != ""
        try FileAppend(JSON.Stringify(Map("id", _sugId, "n", n, "picked", true,
                                          "at", A_Now)) "`n",
                       MMA_USERDATA "\suggest_ratings.jsonl", "UTF-8-RAW")
    A_Clipboard := StrReplace(StrReplace(_sugTexts[n], "`r`n", "`n"), "`n", "`r`n")
    _SuggestClose()
    ToolTip("suggestion " n " copied — Ctrl+V to paste")
    SetTimer(_SuggestTipOff, -2500)
}

_SuggestTipOff() {
    ToolTip()
}

_SuggestSetStatus(text) {
    global _sugStatus
    if _sugStatus
        _sugStatus.Value := text
}

_SuggestKill() {
    global _sugPid
    SetTimer(_SuggestPoll, 0)
    if _sugPid && ProcessExist(_sugPid)
        try ProcessClose(_sugPid)
    _sugPid := 0
}

_SuggestClose(*) {
    global _sugGui
    _SuggestKill()
    if _sugGui
        _sugGui.Destroy()
    _sugGui := 0
}


; ChatViewOpen and LiveTrainerOpen moved to core\ai_suite.ahk, with the rest of
; the AI suite's launchers, so the Tools window can call them too.
