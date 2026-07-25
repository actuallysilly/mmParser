#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstring_index.ahk — reads the message library out of the .ahk source files.
; ───────────────────────────────────────────────────────────────────────────────
;  The manager GUI needs to SEARCH hotstrings by trigger AND by the text inside
;  them. That text lives inside  :*:trigger::{ snd("…") }  blocks in the source,
;  so this module parses those files into a plain list of records.
;
;  Reading is the bulk of this file. The ONE writer is HSI_DeleteBlock at the
;  bottom, which removes a whole hotstring block from its source file; it backs
;  the file up first and refuses to touch anything it cannot re-verify.
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
;      added    — "YYYY-MM-DD[ HH:mm]" from the "; @added" comment above the
;                 trigger, or "" for a block that has never been stamped
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
        added   := HSI_AddedAbove(lines, triggerLine)

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
                out.Push(HSI_Record(rel, triggerLine, options, trigger, "", added))
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
            out.Push(HSI_Record(rel, triggerLine, options, trigger, "", added))
            i := triggerLine + 1
            continue
        }
        body := SubStr(stream, 2, closeIdx - 2)                 ; strip the { … }
        ; how many source lines did the body span? (count newlines up to the close)
        consumed := StrLen(SubStr(stream, 1, closeIdx))
                  - StrLen(StrReplace(SubStr(stream, 1, closeIdx), "`n"))

        out.Push(HSI_Record(rel, triggerLine, options, trigger, body, added))
        i := (i >= triggerLine ? i : triggerLine) + consumed + 1
    }
}

; Assemble a record from a trigger + its raw body text.
HSI_Record(rel, line, options, trigger, body, added := "") {
    steps   := HSI_StepsFromBody(body)
    preview := ""
    for st in steps
        preview .= (preview != "" ? "   ·   " : "") st.text
    preview := StrReplace(StrReplace(preview, "`r", " "), "`n", " ")
    return {file: rel, line: line, options: options, trigger: trigger,
            steps: steps, preview: preview, raw: body, added: added}
}

; When was this hotstring added? A "; @added YYYY-MM-DD[ HH:mm]" comment directly
; above the trigger carries the answer — written by the mass_gui "Add hotstring"
; dialog, and stamped onto the pre-existing library once from git history. Returns
; "" when there is no stamp, which the manager sorts as "unknown", never as old.
;
; Blank lines between the comment and the trigger are tolerated, so reformatting a
; source file by hand does not silently drop the date.
HSI_AddedAbove(lines, triggerLine) {
    static addedRe := "^;\s*@added\s+(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?)\s*$"
    j := triggerLine - 1
    while (j >= 1 && Trim(lines[j]) = "")
        j--
    if (j < 1)
        return ""
    if RegExMatch(Trim(lines[j]), addedRe, &am)
        return Trim(am[1])
    return ""
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

; ═══════════════════════════════════════════════════════════════════════════════
;  deleting — the only path in this module that writes to a message file
; ═══════════════════════════════════════════════════════════════════════════════

; Which source lines does the hotstring at `triggerLine` occupy?
;
; Returns {first, last} (1-based, inclusive) or 0 if that line is not a trigger.
; Deliberately re-derives the span from the file rather than trusting the record,
; because a record can be minutes old and the file may have been hand-edited since
; — and the caller is about to delete whatever this returns.
HSI_BlockSpan(lines, triggerLine) {
    static triggerRe := "^\s*:([^:]*):(.+?)::(.*)$"
    if (triggerLine < 1 || triggerLine > lines.Length)
        return 0
    if !RegExMatch(lines[triggerLine], triggerRe, &m)
        return 0

    ; Same two shapes HSI_ParseFile handles: brace on the trigger line, or on a
    ; later line. Keep the two in step — they must agree on where a block ends.
    if InStr(m[3], "{") {
        openLine := triggerLine
        stream   := SubStr(m[3], InStr(m[3], "{"))
        j := triggerLine + 1
    } else {
        j := triggerLine + 1
        while (j <= lines.Length && !InStr(lines[j], "{"))
            j++
        if (j > lines.Length)
            return {first: triggerLine, last: triggerLine}   ; trigger with no body
        openLine := j
        stream   := SubStr(lines[j], InStr(lines[j], "{"))
        j := openLine + 1
    }
    while (j <= lines.Length) {
        stream .= "`n" lines[j]
        j++
    }

    closeIdx := HSI_MatchBrace(stream)
    if (closeIdx = 0)                                        ; unbalanced source
        return {first: triggerLine, last: triggerLine}
    head := SubStr(stream, 1, closeIdx)
    return {first: triggerLine, last: openLine + StrLen(head) - StrLen(StrReplace(head, "`n"))}
}

; True if the file starts with a UTF-8 BOM. It is not decoration: general.ahk and
; acc\UND.ahk have none while the other acc files do, and rewriting a file with
; the wrong one either injects stray characters at the top or drops the marker
; AHK uses to read the rest of the file as UTF-8.
HSI_HasBom(path) {
    ; Must be FileRead RAW. FileOpen consumes the BOM while opening the file and
    ; leaves the pointer after it — whatever encoding you pass — so a RawRead
    ; there reports "no BOM" for every file that has one, and the rewrite below
    ; would then strip it from acc\ALIW.ahk and friends.
    try b := FileRead(path, "RAW m3")
    catch
        return false
    return (b.Size = 3 && NumGet(b, 0, "UChar") = 0xEF
                       && NumGet(b, 1, "UChar") = 0xBB
                       && NumGet(b, 2, "UChar") = 0xBF)
}

; Delete one hotstring block from its source file.
;
; `expectTrigger` is checked against the trigger actually on that line and the
; delete is abandoned if they differ — the index is a snapshot, and deleting the
; wrong block out of a message file is not something the user can easily undo.
; The file is copied to <name>.bak first for the same reason.
;
; Returns {ok: true, removed: n} or {ok: false, why: "…"}.
HSI_DeleteBlock(rel, triggerLine, expectTrigger) {
    global HSI_DIR
    path := HSI_DIR "\" rel
    if !FileExist(path)
        return {ok: false, why: "File not found: " rel}

    raw   := FileRead(path, "UTF-8")
    crlf  := InStr(raw, "`r`n") ? true : false
    lines := StrSplit(raw, "`n", "`r")

    span := HSI_BlockSpan(lines, triggerLine)
    if !span
        return {ok: false, why: "Line " triggerLine " of " rel " is no longer a hotstring."
                              . "`n`nThe file changed since the list was built — press Rescan."}

    static triggerRe := "^\s*:([^:]*):(.+?)::(.*)$"
    RegExMatch(lines[span.first], triggerRe, &m)
    if (m[2] != expectTrigger)
        return {ok: false, why: "Line " triggerLine " of " rel " now holds " m[2] ", not "
                              . expectTrigger "."
                              . "`n`nThe file changed since the list was built — press Rescan."}

    try FileCopy(path, path ".bak", 1)
    catch as e
        return {ok: false, why: "Could not write the backup " rel ".bak:`n" e.Message}

    ; The "; @added" stamp belongs to this block and goes with it. Left behind, it
    ; floats up to whatever trigger comes next and misdates it — HSI_AddedAbove
    ; looks past blank lines, so the same walk is used here to find it.
    delFirst := span.first
    j := span.first - 1
    while (j >= 1 && Trim(lines[j]) = "")
        j--
    if (j >= 1 && RegExMatch(Trim(lines[j]), "^;\s*@added\s"))
        delFirst := j

    kept := []
    for i, ln in lines
        if (i < delFirst || i > span.last)
            kept.Push(ln)

    ; The blank line that separated this block from the next one is now a second
    ; blank line against the one above it. Collapse the pair, or repeated deletes
    ; leave a growing hole in the file.
    if (delFirst > 1 && delFirst <= kept.Length
            && Trim(kept[delFirst - 1]) = "" && Trim(kept[delFirst]) = "")
        kept.RemoveAt(delFirst)

    out := ""
    for i, ln in kept
        out .= (i = 1 ? "" : (crlf ? "`r`n" : "`n")) ln

    f := FileOpen(path, "w", HSI_HasBom(path) ? "UTF-8" : "UTF-8-RAW")
    if !f
        return {ok: false, why: "Could not open " rel " for writing (is it open elsewhere?)"}
    f.Write(out)
    f.Close()
    return {ok: true, removed: span.last - delFirst + 1}
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
