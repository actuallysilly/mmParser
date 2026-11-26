#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  chat/grammar.ahk — fix the grammar of the message you are typing.
; ───────────────────────────────────────────────────────────────────────────────
;  Two keys, two voices (hotkeys.ini [util]):
;    fixGrammarCasual   WhatsApp: lowercase, no apostrophes, only typos fixed
;    fixGrammarAlice    proper British English
;
;  CUT -> FIX -> hand it back. It cuts the text out of the box (your selection
;  if you have one, otherwise the whole box) and runs it through the local model
;  (services\llm\grammar.py). How it hands it back is Settings ▸ Features ▸
;  "Fix grammar: fast mode" (FEAT "grammarFast"):
;
;    off  CLIPBOARD — the fix is left on the clipboard; you paste it.
;    on   FAST — the fix is pasted back into the box for you, and your clipboard
;         is put back the way it was. Ctrl+Z gets your original back.
;
;  When it cannot fix the text (the model is down, or its answer failed the
;  length guard because it replied to the message instead of correcting it),
;  your ORIGINAL comes back the same way the fix would have: on the clipboard,
;  or pasted back into the box in fast mode. The cut never loses your text.
;
;  Fast mode will not paste into a different window: if you switched while it
;  was thinking, the text goes on the clipboard instead.
;
;  Works in any text box, not only Infloww. Model and temperature are in
;  userdata\llm.ini. The first press after a long break waits ~5s while Ollama
;  loads the model; after that a fix takes about a third of a second.
; ═══════════════════════════════════════════════════════════════════════════════

GRAMMAR_PY      := MMA_SRC "\services\llm\grammar.py"
; Longest text we will treat as a message. A real one is a few lines; anything
; past this is a whole page that Ctrl+A grabbed because the box was not focused.
GRAMMAR_MAXLEN  := 2000

FixGrammarCasual() {
    FixGrammar("casual")
}

FixGrammarAlice() {
    FixGrammar("alice")
}

FixGrammar(mode) {
    static busy := false
    ; A second press while the first is still thinking would cut whatever you
    ; have typed since and overwrite the first result.
    if busy
        return
    busy := true
    try _FixGrammar(mode)
    finally busy := false
}

_FixGrammar(mode) {
    global GRAMMAR_PY, GRAMMAR_MAXLEN
    _GrammarReleaseMods()
    fast  := FEAT("grammarFast")
    win   := WinExist("A")
    saved := ClipboardAll()

    original := _GrammarCut()
    if original = "" {
        A_Clipboard := saved
        _GrammarTip("nothing to fix — click in the message box first")
        return
    }
    if StrLen(original) > GRAMMAR_MAXLEN {
        ; Ctrl+A grabbed a page, not a box, so nothing was actually cut out of
        ; anything — just put the clipboard back.
        A_Clipboard := saved
        _GrammarTip("that is not a message (" StrLen(original) " chars) — click in the message box first")
        return
    }

    inFile  := A_Temp "\mma_grammar_in.txt"
    outFile := A_Temp "\mma_grammar_out.txt"
    try FileDelete(inFile)
    try FileDelete(outFile)
    FileAppend(original, inFile, "UTF-8-RAW")

    ToolTip("fixing grammar (" mode ")…")
    try {
        code := RunWait('pythonw.exe "' GRAMMAR_PY '" --mode ' mode
                      . ' --in "' inFile '" --out "' outFile '"', , "Hide")
    } catch as e {
        LOGW("grammar", "RunWait failed: " e.Message)
        _GrammarGiveBack(original, fast, win, saved,
                         "could not start Python (pythonw.exe not on PATH?) — original kept")
        return
    }
    result := FileExist(outFile) ? FileRead(outFile, "UTF-8") : ""

    if code != 0 || result = "" {
        why := result != "" ? result : "grammar.py exited " code " with no message"
        LOGW("grammar", mode ": " why)
        _GrammarGiveBack(original, fast, win, saved, "grammar fix failed: " why " — original kept")
        return
    }

    ; grammar.py hands back \n; Windows text boxes expect \r\n from the clipboard.
    result := StrReplace(StrReplace(result, "`r`n", "`n"), "`n", "`r`n")
    LOGI("grammar", mode (fast ? " (fast)" : "") ": " StrLen(original) " -> " StrLen(result) " chars")
    _GrammarGiveBack(result, fast, win, saved, fast ? "" : "fixed (" mode ") — Ctrl+V to paste")
}

; The hotkey's modifiers are still held (Ctrl+Win, or Ctrl+Alt on an old ini).
; Waiting for Alt and Win keeps the Ctrl+X / Ctrl+A below from going out as
; Ctrl+Win+X (the Windows power menu is Win+X) or Ctrl+Alt+A. Ctrl is left
; down on purpose: the sends below hold it anyway.
_GrammarReleaseMods() {
    KeyWait "Alt", "T1"
    KeyWait "LWin", "T1"
    KeyWait "RWin", "T1"
}

; Cuts the selection, or the whole box when nothing is selected. Returns the
; text, or "" when there was nothing to cut.
;
; Watches the clipboard's SEQUENCE NUMBER rather than ClipWait-ing on an emptied
; clipboard. The common case is no selection, where the first Ctrl+X cuts
; nothing and the old 0.3s ClipWait was spent in full on every press — half of
; the whole fix's time once the model is warm. A cut lands in 10-50ms, so 150ms
; is plenty, and the number is checked once more right before Ctrl+A: a cut
; that was merely slow is taken then, not overwritten by the whole-box cut.
_GrammarCut() {
    A_Clipboard := ""
    seq := DllCall("GetClipboardSequenceNumber", "UInt")
    Send "^x"
    if _GrammarClipChanged(seq, 150)
        return A_Clipboard
    if (DllCall("GetClipboardSequenceNumber", "UInt") != seq
        && Trim(A_Clipboard, " `t`r`n") != "")
        return A_Clipboard
    ; Nothing selected: Ctrl+X cut nothing, so take the whole box.
    A_Clipboard := ""
    seq := DllCall("GetClipboardSequenceNumber", "UInt")
    Send "^a"
    Send "^x"
    if _GrammarClipChanged(seq, 500)
        return A_Clipboard
    return ""
}

; True once the clipboard has changed since `seq` and holds text, within `ms`.
_GrammarClipChanged(seq, ms) {
    end := A_TickCount + ms
    while (A_TickCount < end) {
        if (DllCall("GetClipboardSequenceNumber", "UInt") != seq
            && Trim(A_Clipboard, " `t`r`n") != "")
            return true
        Sleep 10
    }
    return false
}

; Hands `text` back — the fix, or the original when the fix failed.
;   clipboard mode: leaves it on the clipboard.
;   fast mode:      pastes it where the cut was and restores your clipboard,
;                   unless you have switched windows, then clipboard after all.
_GrammarGiveBack(text, fast, win, saved, tip) {
    if fast && WinExist("A") = win {
        A_Clipboard := text
        ClipWait 0.5
        Send "^v"
        ; The target app reads the clipboard asynchronously after ^v. Restoring
        ; it too soon pastes your OLD clipboard into the box instead. Stays a
        ; plain Sleep, not a timer: a timer restore could land in the middle of
        ; a second press's cut and be read back as the text to fix.
        Sleep 200
        A_Clipboard := saved
        if tip != ""
            _GrammarTip(tip)
        else
            ToolTip()
        return
    }
    A_Clipboard := text
    if fast
        tip := "you switched windows — " (tip != "" ? tip "; " : "") "the text is on the clipboard"
    _GrammarTip(tip)
}

_GrammarTip(text) {
    ToolTip(text)
    SetTimer(_GrammarTipOff, -3000)
}

_GrammarTipOff() {
    ToolTip()
}
