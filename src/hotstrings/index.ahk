#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings/index.ahk — reads the message library out of the .ahk source files.
; ───────────────────────────────────────────────────────────────────────────────
;  The manager GUI needs to SEARCH hotstrings by trigger AND by the text inside
;  them. That text lives inside  :*:trigger::{ snd("…") }  blocks in the source,
;  so this module parses those files into a plain list of records.
;
;  Reading is the bulk of this file. The WRITERS are at the bottom — delete a
;  block, replace one in place, append one to another file — and they share one
;  discipline: back the file up, re-verify the line still holds the trigger the
;  caller thinks it does, and write through a temp file so a failure leaves the
;  old version rather than half of the new one.
;
;  One record:
;      file     — source file, relative to this module's folder
;      line     — 1-based line of the trigger, so the GUI can jump to it
;      options  — the bit between the first two colons  (":*:" → "*",  "::" → "")
;      trigger  — the abbreviation you type            (":*:_joi1::" → "_joi1")
;      steps    — [{fn, text, ms}] : one per snd()/SendText()/Sendt() call, with
;                 the AHK string escapes (`n `" `; …) resolved to real
;                 characters. `ms` is Sendt's second argument, verbatim — it is
;                 "500" in most of the library and `t` in content\accounts\BRI.ahk,
;                 which is a local declared in the block. Kept as TEXT for that
;                 reason: an editor that turned it into a number would rewrite
;                 those blocks into something that no longer compiles.
;      plain    — true when the body is send calls and nothing else, so it can be
;                 rebuilt from `steps` without losing anything. False for a body
;                 with a local, a loop, or any line the parser skips — which is
;                 what tells the editor to work on the source instead.
;      preview  — every step's text joined onto one line, for display + search
;      raw      — the body source verbatim, so nothing is lost for later editing
;      added    — "YYYY-MM-DD[ HH:mm]" from the "; @added" comment above the
;                 trigger, or "" for a block that has never been stamped
; ═══════════════════════════════════════════════════════════════════════════════

; Paths come from the one anchor, not from this file's own folder — src\hotstrings
; is not where anything it reads lives.
#Include "../core/paths.ahk"
global HSI_DIR := MMA_CONTENT

; The files that hold the message hotstrings — ENUMERATED, not listed.
;
; This was a hard-coded array of five relative paths, which is the same mistake
; HK_Broadcast's comment describes: the old file list in hotkeys_window.ahk had gone
; stale in both directions, still naming a deleted script and never gaining one
; that had been added. A list you must remember to edit is a list that will be
; wrong. content\ is exactly "the hand-written message library", so reading the
; folder IS the definition — add an account file and it indexes itself.
;
; Plumbing hotstrings (utils.ahk's _afk / _offafk, which run code rather than
; send a message) stay out for free: utils.ahk is in src\, not content\.
HSI_Files() {
    out := []
    if FileExist(MMA_CONTENT "\general.ahk")        ; shared library first
        out.Push("general.ahk")
    Loop Files, MMA_ACC_DIR "\*.ahk"
        out.Push("accounts\" A_LoopFileName)
    return out
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

    ; Guarded because this runs over EVERY message file in a loop, so one
    ; unreadable file (open in an editor, mid-save, permissions) threw and took
    ; the whole scan with it — the Hotstrings manager then showed nothing at all
    ; rather than everything except that one file.
    text := ""
    try {
        text := FileRead(path, "UTF-8")
    } catch as e {
        LOGE("hsi.parse", "could not read " rel " — its hotstrings are MISSING from"
                        . " the manager's list, the rest are fine", LOG_Err(e))
        return
    }
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
            steps: steps, preview: preview, raw: body, added: added,
            plain: HSI_BodyIsPlain(body)}
}

; ── can this body be rebuilt from its steps? ──────────────────────────────
;  The question the EDITOR has to ask before it offers to rewrite one.
;
;  HSI_StepsFromBody skips anything that is not a send call, which is exactly
;  right for reading and exactly wrong for writing: rebuild _showersex2 in
;  content\accounts\BRI.ahk from its steps and the `t := 500` line those steps
;  refer to is gone, leaving four sendt() calls naming a variable that no longer
;  exists — a load error in a message script, from a wording change.
;
;  So a body counts as plain only when EVERY line is blank, a comment, or a send
;  call. Comments are allowed through because the renderer keeps none of them and
;  losing a comment is not losing a message — stated here rather than left to be
;  discovered, because it is the one thing this promise does not cover.
HSI_BodyIsPlain(body) {
    for raw in StrSplit(body, "`n", "`r") {
        line := Trim(raw)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if !RegExMatch(line, "i)^(snd|SendText|Sendt)\s*\(")
            return false
    }
    return true
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
; one {fn, text, ms}. Comments and anything else are ignored (but survive in
; `raw`, and make the record not `plain` — see HSI_BodyIsPlain).
;
; `ms` is whatever Sendt was passed as its SECOND argument, as written: "1000"
; through most of the library, "t" in BRI.ahk where the block declares a local.
; Blank for snd() and SendText(), which take no such argument.
HSI_StepsFromBody(body) {
    steps := []
    for raw in StrSplit(body, "`n", "`r") {
        line := Trim(raw)
        if (line = "" || !RegExMatch(line, "i)^(snd|SendText|Sendt)\s*\(", &fm))
            continue
        q := InStr(line, '"')                            ; the send string opens at the first quote
        if !q
            continue
        txt := HSI_ReadString(line, q, &after)
        ms  := ""
        ; Everything after the closing quote of the message, for Sendt's wait.
        ; Anchored and non-greedy so it reads the argument and not the ")" — and
        ; it captures a NAME as readily as a number, because BRI.ahk passes one.
        if (StrLower(fm[1]) = "sendt"
                && RegExMatch(SubStr(line, after), "^\s*,\s*([^),]+)", &am))
            ms := Trim(am[1])
        steps.Push({fn: fm[1], text: txt, ms: ms})
    }
    return steps
}

; Read one AHK double-quoted string starting at the opening-quote position `qpos`,
; returning its text with escapes resolved. Handles ``-escapes and doubled "".
;
; `endPos` comes back as the position just PAST the closing quote, which is where
; Sendt's wait argument starts. An output parameter rather than a second scan:
; finding the end of an AHK string means honouring the same escapes this loop
; already walks, and two implementations of that would eventually disagree.
HSI_ReadString(s, qpos, &endPos := "") {
    out := ""
    i   := qpos + 1
    n   := StrLen(s)
    endPos := n + 1                     ; unterminated string: everything is text
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
            endPos := i + 1
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
;  writing — turning records back into source
; ───────────────────────────────────────────────────────────────────────────────
;  Everything above reads. From here down the file EDITS your message library, so
;  every function shares one discipline:
;
;    • a .bak first, always, before the first byte changes
;    • re-verify the target line still holds the trigger the caller named, and
;      abandon if it does not — a record is a snapshot and the file is a file
;    • write through <name>.tmp and FileMove it into place, so an interrupted
;      write leaves the OLD file rather than half of the new one. FileOpen(…,"w")
;      truncates before it writes, which is how a failure empties a script every
;      message in it depends on
;    • return {ok, why} rather than throwing, so the caller can say what happened
;      in its own words instead of dying inside a click handler
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

    if !_HSI_ReadLines(path, &lines, &crlf)
        return {ok: false, why: "Could not read " rel ". Nothing was deleted."}

    span := _HSI_VerifySpan(lines, triggerLine, expectTrigger, rel, &why)
    if !span
        return {ok: false, why: why}

    bk := _HSI_Backup(path)
    if !bk.ok
        return bk

    ; The "; @added" stamp belongs to this block and goes with it. Left behind, it
    ; floats up to whatever trigger comes next and misdates it.
    delFirst := _HSI_BlockFirstLine(lines, span.first)

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

    res := _HSI_WriteLines(path, kept, crlf)
    if !res.ok
        return res
    LOG_Ok("hsi.write", "deleted " expectTrigger " from " rel " ("
                      . (span.last - delFirst + 1) " lines, .bak saved)")
    return {ok: true, removed: span.last - delFirst + 1}
}

; ── text → an AHK double-quoted string ────────────────────────────────────────
;  The exact inverse of HSI_ReadString / HSI_Unescape above, and it has to stay
;  that way: whatever this writes, the parser reads back on the next rescan, and
;  the two disagreeing means a message that changes every time you open it.
;
;  The backtick goes FIRST. It is the escape character, so escaping it after the
;  others would also escape the backticks this function had just introduced —
;  `n would become ``n, which is a literal backtick followed by an n.
;
;  The semicolon does not strictly need escaping inside a quoted string; AHK's
;  tokeniser knows it is in one. It is escaped anyway because the hand-written
;  library already spells it `; (content\general.ahk's `;3 is in the source
;  today), and a rewrite that silently changed that convention would show up as a
;  diff on every block anyone touched.
HSI_Escape(text) {
    t := StrReplace(text, "``", "````")
    ; '``"' and not '`"'. The backtick is AHK's escape character in
    ; SINGLE-quoted strings too, so '`"' is a one-character string holding a
    ; plain quote — which made this replacement a no-op that compiled, ran, and
    ; wrote every quote in a message out unescaped. The block then ended at the
    ; first quote in your own words. Caught by hotstring_edit_test.ahk, which is
    ; why the round trip is asserted per character rather than in bulk.
    t := StrReplace(t, '"', '``"')
    t := StrReplace(t, "`r`n", "`n")
    t := StrReplace(t, "`r", "`n")
    t := StrReplace(t, "`n", "``n")
    t := StrReplace(t, "`t", "``t")
    return StrReplace(t, ";", "``;")
}

; ── steps → the lines between the braces ──────────────────────────────────────
;  One send call per step, four spaces in, which is how every block in the
;  library is already written.
;
;  Sendt's wait is emitted VERBATIM from the step, not as a number. Most of them
;  are "1000"; BRI.ahk's are the local `t`, and turning that into a literal — or
;  worse, into a default because it did not parse as an integer — would rewrite a
;  working block into a different one. A Sendt step that arrives with no wait at
;  all gets 500, the same figure the Add-hotstring dialog writes.
HSI_RenderBody(steps) {
    out := ""
    for st in steps {
        fn  := StrLower(st.fn)
        txt := '"' HSI_Escape(st.text) '"'
        if (fn = "sendtext")
            out .= "    SendText(" txt ")`n"
        else if (fn = "sendt") {
            ms := (st.HasProp("ms") && Trim(st.ms) != "") ? Trim(st.ms) : "500"
            out .= "    Sendt(" txt ", " ms ")`n"
        } else
            out .= "    snd(" txt ")`n"
    }
    return out
}

; ── a whole block, as source ──────────────────────────────────────────────────
;  The "; @added" stamp is part of the block, not decoration: HSI_AddedAbove
;  reads it and the manager sorts by it, so a rewrite that dropped it would date
;  the hotstring as unknown from then on. An empty `added` writes no comment at
;  all, which is what an unstamped block already looks like.
;
;  `body` is the text between the braces, WITHOUT them — either HSI_RenderBody's
;  output or a body the user edited as source. Trailing blank lines are trimmed
;  so repeated saves cannot grow a hole inside the block.
HSI_RenderBlock(options, trigger, body, added := "") {
    body := RTrim(StrReplace(StrReplace(body, "`r`n", "`n"), "`r", "`n"), "`n `t")
    out  := ""
    if (Trim(added) != "")
        out .= "; @added " Trim(added) "`n"
    out .= ":" options ":" trigger "::{`n"
    if (body != "")
        out .= body "`n"
    return out "}`n"
}

; ── is this trigger already taken? ────────────────────────────────────────────
;  Returns the record that holds it, or 0. `exceptFile`/`exceptLine` exclude the
;  block being edited, which would otherwise always report itself as a clash.
;
;  Case-insensitive, because AHK matches hotstrings that way: defining `_gns1`
;  when `_GNS1` exists does not give you two hotstrings, it gives you one whose
;  behaviour depends on which script loaded last.
HSI_FindTrigger(trigger, exceptFile := "", exceptLine := 0) {
    want := StrLower(Trim(trigger))
    for r in HSI_Build() {
        if (StrLower(r.trigger) != want)
            continue
        if (r.file = exceptFile && r.line = exceptLine)
            continue
        return r
    }
    return 0
}

; ── the shared read / write pair ──────────────────────────────────────────────

; Read a message file as lines, reporting whether it uses CRLF so the rewrite can
; put back what it found. Returns 0 on failure; the caller logs and bails.
_HSI_ReadLines(path, &lines, &crlf) {
    raw := ""
    try {
        raw := FileRead(path, "UTF-8")
    } catch as e {
        LOGE("hsi.write", "could not read " _LOG_BaseName(path) " — nothing was"
                        . " changed", LOG_Err(e))
        return 0
    }
    crlf  := InStr(raw, "`r`n") ? true : false
    lines := StrSplit(raw, "`n", "`r")
    return 1
}

; Write lines back, through a temp file. Returns {ok, why}.
;
; The BOM is preserved rather than imposed, for the reason HSI_HasBom gives:
; general.ahk and acc\UND.ahk have none while the other account files do, and
; guessing either way corrupts one group or the other.
_HSI_WriteLines(path, lines, crlf) {
    out := ""
    for i, ln in lines
        out .= (i = 1 ? "" : (crlf ? "`r`n" : "`n")) ln

    tmp := path ".tmp"
    try {
        f := FileOpen(tmp, "w", HSI_HasBom(path) ? "UTF-8" : "UTF-8-RAW")
        if !f
            throw Error("could not open " tmp " for writing")
        f.Write(out)
        f.Close()
        FileMove(tmp, path, true)
    } catch as e {
        try FileDelete(tmp)
        LOGE("hsi.write", "could not write " _LOG_BaseName(path) " — it is"
                        . " UNTOUCHED, and the .bak beside it is the same file",
                        LOG_Err(e))
        return {ok: false, why: "Could not write " _LOG_BaseName(path) ":`n`n"
                              . e.Message
                              . "`n`nThe file was not changed. Is it open in an"
                              . " editor, or read-only?"}
    }
    return {ok: true}
}

; The .bak every writer takes first. Returns {ok, why}.
_HSI_Backup(path) {
    try FileCopy(path, path ".bak", 1)
    catch as e
        return {ok: false, why: "Could not write the backup "
                              . _LOG_BaseName(path) ".bak:`n" e.Message
                              . "`n`nNothing was changed."}
    return {ok: true}
}

; Where does the block at `triggerLine` really start — including its "; @added"
; comment, which belongs to it and must move or go with it. Blank lines between
; the comment and the trigger are tolerated, exactly as HSI_AddedAbove tolerates
; them, or reformatting a file by hand would strip the stamp off its block.
_HSI_BlockFirstLine(lines, spanFirst) {
    j := spanFirst - 1
    while (j >= 1 && Trim(lines[j]) = "")
        j--
    if (j >= 1 && RegExMatch(Trim(lines[j]), "^;\s*@added\s"))
        return j
    return spanFirst
}

; The check every writer runs before it touches anything: is line `triggerLine`
; of `lines` still the hotstring the caller thinks it is? Returns the span, or 0
; with `why` filled in.
_HSI_VerifySpan(lines, triggerLine, expectTrigger, rel, &why) {
    static triggerRe := "^\s*:([^:]*):(.+?)::(.*)$"
    why := ""
    span := HSI_BlockSpan(lines, triggerLine)
    if !span {
        why := "Line " triggerLine " of " rel " is no longer a hotstring."
             . "`n`nThe file changed since the list was built — press Rescan."
        return 0
    }
    RegExMatch(lines[span.first], triggerRe, &m)
    if (m[2] != expectTrigger) {
        why := "Line " triggerLine " of " rel " now holds " m[2] ", not "
             . expectTrigger "."
             . "`n`nThe file changed since the list was built — press Rescan."
        return 0
    }
    return span
}

; ── replace one block in place ────────────────────────────────────────────────
;  The whole of "edit a hotstring", minus moving it to another file: the trigger,
;  the options, and the body are all free to change, and the block is rewritten
;  where it stands so the file keeps its shape and its comments.
;
;  Returns {ok: true, lines: n} or {ok: false, why: "…"}.
HSI_ReplaceBlock(rel, triggerLine, expectTrigger, options, trigger, body, added := "") {
    global HSI_DIR
    path := HSI_DIR "\" rel
    if !FileExist(path)
        return {ok: false, why: "File not found: " rel}
    if (Trim(trigger) = "")
        return {ok: false, why: "A hotstring needs a trigger."}

    if !_HSI_ReadLines(path, &lines, &crlf)
        return {ok: false, why: "Could not read " rel ". Nothing was changed."}

    span := _HSI_VerifySpan(lines, triggerLine, expectTrigger, rel, &why)
    if !span
        return {ok: false, why: why}

    bk := _HSI_Backup(path)
    if !bk.ok
        return bk

    first := _HSI_BlockFirstLine(lines, span.first)
    block := StrSplit(RTrim(HSI_RenderBlock(options, trigger, body, added), "`n"),
                      "`n", "`r")

    kept := []
    for i, ln in lines {
        if (i = first) {
            for _, bl in block
                kept.Push(bl)
            continue
        }
        if (i > first && i <= span.last)          ; the rest of the old block
            continue
        kept.Push(ln)
    }

    res := _HSI_WriteLines(path, kept, crlf)
    if !res.ok
        return res
    LOG_Ok("hsi.write", "rewrote " expectTrigger " in " rel
                      . (trigger = expectTrigger ? "" : " (now " trigger ")")
                      . " — " block.Length " lines, .bak saved")
    return {ok: true, lines: block.Length}
}

; ── append one block to a file ────────────────────────────────────────────────
;  The other half of MOVING a hotstring between message files: this writes it
;  into the new file, HSI_DeleteBlock takes it out of the old one. In that order,
;  deliberately — a failed append leaves the hotstring where it was, while a
;  failed delete after a successful append leaves it in BOTH files, which is
;  visible, harmless and fixable. The reverse order can lose it outright.
;
;  Returns {ok: true} or {ok: false, why: "…"}.
HSI_AppendBlock(rel, options, trigger, body, added := "") {
    global HSI_DIR
    path := HSI_DIR "\" rel
    if !FileExist(path)
        return {ok: false, why: "File not found: " rel}

    bk := _HSI_Backup(path)
    if !bk.ok
        return bk

    if !_HSI_ReadLines(path, &lines, &crlf)
        return {ok: false, why: "Could not read " rel ". Nothing was changed."}

    ; A blank line before the block, unless the file already ends in one. The
    ; library is read by people as much as by the parser, and blocks jammed
    ; against each other are the thing that makes a message file unreadable.
    while (lines.Length && Trim(lines[lines.Length]) = "")
        lines.Pop()
    lines.Push("")
    for _, bl in StrSplit(RTrim(HSI_RenderBlock(options, trigger, body, added), "`n"),
                          "`n", "`r")
        lines.Push(bl)

    res := _HSI_WriteLines(path, lines, crlf)
    if !res.ok
        return res
    LOG_Ok("hsi.write", "appended " trigger " to " rel " (.bak saved)")
    return {ok: true}
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
