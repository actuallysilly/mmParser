#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  chat/reword.ahk — freestyle reworder (hotkeys.ini [util] reword).
; ───────────────────────────────────────────────────────────────────────────────
;  Rewords a PPV caption or a mass follow-up: same ideas, a bit added/changed,
;  and the fan's own words from the chat on screen woven in.
;
;  WHERE THE TEXT COMES FROM: it cuts the message box (your selection, otherwise
;  the whole box) the way the grammar keys do. If the box is empty it rewords
;  what is on the CLIPBOARD instead — so you can copy a mass and press the key.
;
;  The reword always lands on the CLIPBOARD; Ctrl+V to paste it. When it fails,
;  the original goes back on the clipboard, so the cut never loses your text.
;
;  The work is services\llm\reword.py; model/temperature: userdata\llm.ini
;  [Reword] (falls back to [Ollama] Model). Uses grammar.ahk's _GrammarCut/Tip.
; ═══════════════════════════════════════════════════════════════════════════════

REWORD_PY := MMA_SRC "\services\llm\reword.py"

RewordMessage() {
    static busy := false
    if busy
        return
    busy := true
    try _RewordMessage()
    finally busy := false
}

_RewordMessage() {
    global REWORD_PY, GRAMMAR_MAXLEN
    _GrammarReleaseMods()           ; grammar.ahk: Alt AND Win, for Ctrl+Win keys
    saved := ClipboardAll()
    clipText := A_Clipboard

    original := _GrammarCut()
    if original = "" {
        ; Empty box: reword the clipboard instead.
        A_Clipboard := saved
        original := clipText
    }
    if Trim(original, " `t`r`n") = "" {
        _GrammarTip("nothing to reword — put the message in the box or on the clipboard")
        return
    }
    if StrLen(original) > GRAMMAR_MAXLEN {
        A_Clipboard := saved
        _GrammarTip("that is not a message (" StrLen(original) " chars)")
        return
    }

    inFile  := A_Temp "\mma_reword_in.txt"
    outFile := A_Temp "\mma_reword_out.txt"
    try FileDelete(inFile)
    try FileDelete(outFile)
    FileAppend(original, inFile, "UTF-8-RAW")

    ToolTip("rewording…")
    try {
        code := RunWait('pythonw.exe "' REWORD_PY '" --in "' inFile '" --out "' outFile '"', , "Hide")
    } catch as e {
        LOGW("reword", "RunWait failed: " e.Message)
        A_Clipboard := original
        _GrammarTip("could not start Python — original is on the clipboard")
        return
    }
    result := FileExist(outFile) ? FileRead(outFile, "UTF-8") : ""

    if code != 0 || result = "" {
        why := result != "" ? result : "reword.py exited " code " with no message"
        LOGW("reword", why)
        A_Clipboard := original
        _GrammarTip("reword failed: " why " — original is on the clipboard")
        return
    }

    result := StrReplace(StrReplace(result, "`r`n", "`n"), "`n", "`r`n")
    LOGI("reword", StrLen(original) " -> " StrLen(result) " chars")
    A_Clipboard := result
    _GrammarTip("reworded — Ctrl+V to paste")
}
