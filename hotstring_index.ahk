#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstring_index.ahk — reads the message library out of the .ahk source files.
; ───────────────────────────────────────────────────────────────────────────────
;  The manager GUI needs to SEARCH hotstrings by trigger AND by the text inside
;  them. That text lives inside  :*:trigger::{ snd("…") }  blocks in the source,
;  so this module parses those files into a plain list of records. It NEVER writes
;  — the .ahk files stay the single source of truth (editing comes later).
;
;  One record:
;      file     — source file, relative to this module's folder
;      line     — 1-based line of the trigger, so the GUI can jump to it
;      options  — the bit between the first two colons  (":*:" → "*",  "::" → "")
;      trigger  — the abbreviation you type            (":*:_joi1::" → "_joi1")
;      steps    — [{fn, text}] : one per snd()/SendText()/Sendt() call, with the
;                 AHK string escapes (`n `" `; …) resolved to real characters
;      preview  — every step's text joined onto one line, for display + search
;      raw      — the body source verbatim, so nothing is lost for later editing
; ═══════════════════════════════════════════════════════════════════════════════

; Anchored to THIS file, not A_ScriptDir, so it resolves the sources whether the
; GUI, a test runner, or anything else includes it (same trick as hotkeys.ahk).
global HSI_DIR := SubStr(A_LineFile, 1, InStr(A_LineFile, "\", , -1) - 1)

; The files that hold the message hotstrings. Plumbing hotstrings (utils.ahk's
; _afk / _offafk, which run code rather than send a message) are left out on
; purpose — this list is "the message library" and nothing else.
HSI_Files() {
    return ["general.ahk", "acc\ALIW.ahk", "acc\TEMP.ahk", "acc\BRI.ahk", "acc\UND.ahk"]
}

; Build the whole index. Returns an Array of records (see header).
HSI_Build() {
    records := []
    for rel in HSI_Files() {
        path := HSI_DIR "\" rel
        if FileExist(path)
            HSI_ParseFile(rel, path, records)
    }
    return records
}

; Parse one file, appending its hotstring records to `out`.
HSI_ParseFile(rel, path, out) {
    ; Matches a hotstring definition line:  :opts:trigger::rest
    ;   opts    = [^:]*  (empty for "::", "*" for ":*:")  — never contains a colon
    ;   trigger = .+?    (up to the first "::")
    ; Body lines (snd("…") etc.) start with a letter or brace, never a colon, so
    ; they can't be mistaken for a trigger.
    static triggerRe := "^\s*:([^:]*):(.+?)::(.*)$"

    text  := FileRead(path, "UTF-8")
    lines := StrSplit(text, "`n", "`r")
    i := 1
    while (i <= lines.Length) {
        if !RegExMatch(lines[i], triggerRe, &m) {
            i++
            continue
        }
        options := m[1]
        trigger := m[2]
        rest    := m[3]
        triggerLine := i

        ; Find where the body's opening brace is: on the trigger line itself
        ; (":*:tysm::{" or "::x::{}"), or on a following line after blanks/comments.
        stream := ""          ; source from the opening "{" onward, joined with `n
        bodyEndLine := i       ; last line the body occupies (for resuming the scan)
        if InStr(rest, "{") {
            stream := SubStr(rest, InStr(rest, "{"))
            j := i + 1
            while (j <= lines.Length) {
                stream .= "`n" lines[j]
                j++
            }
        } else {
            ; look ahead for the "{" line
            j := i + 1
            while (j <= lines.Length && !InStr(lines[j], "{"))
                j++
            if (j > lines.Length) {          ; no body found — treat as empty
                out.Push(HSI_Record(rel, triggerLine, options, trigger, ""))
                i++
                continue
            }
            stream := SubStr(lines[j], InStr(lines[j], "{"))
            triggerLine := i                  ; keep the trigger's own line number
            k := j + 1
            while (k <= lines.Length) {
                stream .= "`n" lines[k]
                k++
            }
            i := j                            ; body starts at line j; fix bodyEndLine below
        }

        closeIdx := HSI_MatchBrace(stream)
        if (closeIdx = 0) {                   ; unbalanced — save what we can, move on
            out.Push(HSI_Record(rel, triggerLine, options, trigger, ""))
            i := triggerLine + 1
            continue
        }
        body := SubStr(stream, 2, closeIdx - 2)                 ; strip the { … }
        ; how many source lines did the body span? (count newlines up to the close)
        consumed := StrLen(SubStr(stream, 1, closeIdx))
                  - StrLen(StrReplace(SubStr(stream, 1, closeIdx), "`n"))

        out.Push(HSI_Record(rel, triggerLine, options, trigger, body))
        i := (i >= triggerLine ? i : triggerLine) + consumed + 1
    }
}

; Assemble a record from a trigger + its raw body text.
HSI_Record(rel, line, options, trigger, body) {
    steps   := HSI_StepsFromBody(body)
    preview := ""
    for st in steps
        preview .= (preview != "" ? "   ·   " : "") st.text
    preview := StrReplace(StrReplace(preview, "`r", " "), "`n", " ")
    return {file: rel, line: line, options: options, trigger: trigger,
            steps: steps, preview: preview, raw: body}
}

; Pull the send-steps out of a body: each snd()/SendText()/Sendt() call becomes
; one {fn, text}. Comments and anything else are ignored (but survive in `raw`).
HSI_StepsFromBody(body) {
    steps := []
    for raw in StrSplit(body, "`n", "`r") {
        line := Trim(raw)
        if (line = "" || !RegExMatch(line, "i)^(snd|SendText|Sendt)\s*\(", &fm))
            continue
        q := InStr(line, '"')                            ; the send string opens at the first quote
        if !q
            continue
        steps.Push({fn: fm[1], text: HSI_ReadString(line, q)})
    }
    return steps
}

; Read one AHK double-quoted string starting at the opening-quote position `qpos`,
; returning its text with escapes resolved. Handles ``-escapes and doubled "".
HSI_ReadString(s, qpos) {
    out := ""
    i   := qpos + 1
    n   := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "``") {                       ; backtick escapes the next char
            out .= HSI_Unescape(SubStr(s, i + 1, 1))
            i += 2
            continue
        }
        if (c = '"') {
            if (SubStr(s, i + 1, 1) = '"') {  ; "" also means a literal quote
                out .= '"'
                i += 2
                continue
            }
            break                              ; unescaped quote = end of string
        }
        out .= c
        i++
    }
    return out
}

; Resolve a single AHK escape (the char that followed a backtick). Unknown escapes
; pass through as themselves, which is what AHK does for e.g. `D.
HSI_Unescape(ch) {
    switch ch {
        case "n": return "`n"
        case "r": return "`r"
        case "t": return "`t"
        case "b": return Chr(8)
        case "a": return Chr(7)
        case "f": return Chr(12)
        case "v": return Chr(11)
        case '"': return '"'
        case ";": return ";"
        case "``": return "``"
        default:  return ch
    }
}

; Find the "}" that matches the "{" at s[1], ignoring braces that sit inside a
; double-quoted string or after a ";" comment. Returns its 1-based index, or 0 if
; the braces never balance.
HSI_MatchBrace(s) {
    depth := 0
    inStr := false
    i := 1
    n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if inStr {
            if (c = "``") {                    ; escape — skip the escaped char too
                i += 2
                continue
            }
            if (c = '"')
                inStr := false
            i++
            continue
        }
        if (c = '"') {
            inStr := true
        } else if (c = ";") {                  ; line comment → skip to the next newline
            while (i <= n && SubStr(s, i, 1) != "`n")
                i++
            continue
        } else if (c = "{") {
            depth++
        } else if (c = "}") {
            if (--depth = 0)
                return i
        }
        i++
    }
    return 0
}
