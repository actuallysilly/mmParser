#Requires AutoHotkey v2.0

; ============================================================
;  CAPITALIZATION ONLY — spelling fixes handled by espanso
;  Enter  → capitalize sentences in current text field
; ============================================================

; Shift+Enter = normal Enter (no capitalization)
+Enter:: Send("{Enter}")

; Ctrl+Enter = normal Enter (no capitalization)
^Enter:: Send("{Enter}")

; Normal Enter = fix capitalization + send Enter
Enter:: CapitalizeOnEnter(true)

; Win+Enter = fix capitalization but don't send Enter (useful for review)
#Enter:: CapitalizeOnEnter(false)

CapitalizeOnEnter(sendEnter) {
    saved := ClipboardAll()
    A_Clipboard := ""

    ; Select all text in current field
    Send("^a")
    Sleep(50)
    Send("^c")

    if !ClipWait(1) {
        A_Clipboard := saved
        if sendEnter
            Send("{Enter}")
        return
    }

    text := A_Clipboard

    if (text = "") {
        A_Clipboard := saved
        if sendEnter
            Send("{Enter}")
        return
    }

    text := CapitalizeSentences(text)

    A_Clipboard := text
    ClipWait(0.5)
    Send("^a")
    Sleep(50)
    Send("^v")
    Sleep(100)

    A_Clipboard := saved
    if sendEnter
        Send("{Enter}")
}

CapitalizeSentences(text) {
    ; Fix standalone lowercase "i" → "I"
    text := RegExReplace(text, "(?<![a-zA-Z])i(?![a-zA-Z])", "I")

    ; Capitalize first letter of the entire text (start of document/field)
    text := RegExReplace(text, "^([a-z])", "$U1")

    ; Capitalize after newline (every new line starts uppercase)
    text := RegExReplace(text, "`n([a-z])", "`n$U1")
    text := RegExReplace(text, "`r`n([a-z])", "`r`n$U1")

    ; Capitalize after sentence-ending punctuation + whitespace
    ; Handles: .  ..  ...  !  ?  followed by space(s) then lowercase
    text := RegExReplace(text, "([.!?])\s+([a-z])", "$1 $U2")

    ; Also handle multiple periods (ellipsis) followed by space + lowercase
    text := RegExReplace(text, "([.]{2,})\s+([a-z])", "$1 $U2")

    return text
}
