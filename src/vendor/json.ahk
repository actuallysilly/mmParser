#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  json.ahk — JSON for AutoHotkey v2. Parse and Stringify, nothing else.
; ───────────────────────────────────────────────────────────────────────────────
;  AHK v2 has no JSON built in, and MMA needs one because the mass library stopped
;  being generated AHK source (docs/decisions.md §5). This sits in vendor\ next to
;  OCR.ahk for the same reason: it is a general-purpose dependency, not MMA logic,
;  and nothing in here should ever learn what a "mass" is.
;
;  Mapping, both directions:
;      object  <->  Map          (see the note on key order in _StrMap)
;      array   <->  Array
;      string  <->  String
;      number  <->  Integer or Float
;      true/false -> 1 / 0        ... AHK has no distinct Boolean type
;      null    <->  ""            ... and no null; see the note on Stringify
;
;  The null/"" collapse is deliberate and safe HERE: every value MMA stores is a
;  message string, where "absent" and "empty" mean the same thing. A caller that
;  needs to tell them apart must not use this file.
;
;  Parse is strict — it throws on trailing commas, unquoted keys, single quotes
;  and anything left over after the top-level value. Silence would be worse: the
;  thing being parsed is the user's entire message library.
; ═══════════════════════════════════════════════════════════════════════════════

class JSON {

    ; ── Parse ─────────────────────────────────────────────────────────────────
    ; Returns Map / Array / String / Number. Throws Error on malformed input,
    ; with the character offset, because "invalid JSON" alone is useless when the
    ; file is thousands of lines of message text.
    static Parse(text) {
        pos := 1
        val := JSON._Value(text, &pos)
        JSON._Space(text, &pos)
        if (pos <= StrLen(text))
            throw Error("JSON: unexpected trailing data at " pos, -1,
                        SubStr(text, pos, 40))
        return val
    }

    static _Space(text, &pos) {
        while (pos <= StrLen(text)) {
            c := SubStr(text, pos, 1)
            if (c = " " || c = "`t" || c = "`n" || c = "`r")
                pos++
            else
                break
        }
    }

    static _Value(text, &pos) {
        JSON._Space(text, &pos)
        if (pos > StrLen(text))
            throw Error("JSON: unexpected end of input", -1)
        c := SubStr(text, pos, 1)
        if (c = "{")
            return JSON._Object(text, &pos)
        if (c = "[")
            return JSON._Array(text, &pos)
        if (c = '"')
            return JSON._String(text, &pos)
        if (SubStr(text, pos, 4) = "true") {
            pos += 4
            return 1
        }
        if (SubStr(text, pos, 5) = "false") {
            pos += 5
            return 0
        }
        if (SubStr(text, pos, 4) = "null") {
            pos += 4
            return ""
        }
        return JSON._Number(text, &pos)
    }

    static _Object(text, &pos) {
        obj := Map()
        pos++                                   ; past "{"
        JSON._Space(text, &pos)
        if (SubStr(text, pos, 1) = "}") {
            pos++
            return obj
        }
        loop {
            JSON._Space(text, &pos)
            if (SubStr(text, pos, 1) != '"')
                throw Error("JSON: expected a quoted key at " pos, -1,
                            SubStr(text, pos, 40))
            key := JSON._String(text, &pos)
            JSON._Space(text, &pos)
            if (SubStr(text, pos, 1) != ":")
                throw Error("JSON: expected ':' after key '" key "' at " pos, -1)
            pos++
            obj[key] := JSON._Value(text, &pos)
            JSON._Space(text, &pos)
            c := SubStr(text, pos, 1)
            pos++
            if (c = "}")
                return obj
            if (c != ",")
                throw Error("JSON: expected ',' or '}' at " (pos - 1), -1,
                            SubStr(text, pos - 1, 40))
        }
    }

    static _Array(text, &pos) {
        arr := []
        pos++                                   ; past "["
        JSON._Space(text, &pos)
        if (SubStr(text, pos, 1) = "]") {
            pos++
            return arr
        }
        loop {
            arr.Push(JSON._Value(text, &pos))
            JSON._Space(text, &pos)
            c := SubStr(text, pos, 1)
            pos++
            if (c = "]")
                return arr
            if (c != ",")
                throw Error("JSON: expected ',' or ']' at " (pos - 1), -1,
                            SubStr(text, pos - 1, 40))
        }
    }

    ; Assumes text[pos] is the opening quote. Leaves pos just past the closer.
    static _String(text, &pos) {
        pos++                                   ; past the opening quote
        out := ""
        len := StrLen(text)
        while (pos <= len) {
            c := SubStr(text, pos, 1)
            if (c = '"') {
                pos++
                return out
            }
            if (c != "\") {
                out .= c
                pos++
                continue
            }
            e := SubStr(text, pos + 1, 1)
            pos += 2
            switch e {
                case '"':  out .= '"'
                case "\":  out .= "\"
                case "/":  out .= "/"
                case "b":  out .= Chr(8)
                case "f":  out .= Chr(12)
                case "n":  out .= "`n"
                case "r":  out .= "`r"
                case "t":  out .= "`t"
                case "u":
                    hex := SubStr(text, pos, 4)
                    if !RegExMatch(hex, "^[0-9a-fA-F]{4}$")
                        throw Error("JSON: bad \u escape at " (pos - 2), -1, hex)
                    ; AHK strings are UTF-16, so a surrogate PAIR written as two
                    ; \u escapes reassembles into one character on its own.
                    out .= Chr(Integer("0x" hex))
                    pos += 4
                default:
                    throw Error("JSON: unknown escape \" e " at " (pos - 2), -1)
            }
        }
        throw Error("JSON: unterminated string", -1)
    }

    static _Number(text, &pos) {
        ; Matched against a SUBSTRING, not with RegExMatch's StartingPos: PCRE is
        ; handed the whole subject with an offset, so "^" would still anchor to
        ; the start of the FILE and never match here. 64 chars is far more than
        ; any legal JSON number.
        if !RegExMatch(SubStr(text, pos, 64),
                       "^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][-+]?\d+)?", &m)
            throw Error("JSON: invalid value at " pos, -1, SubStr(text, pos, 40))
        pos += m.Len
        s := m[0]
        return (InStr(s, ".") || InStr(s, "e") || InStr(s, "E"))
             ? Float(s) : Integer(s)
    }

    ; ── Stringify ─────────────────────────────────────────────────────────────
    ; indent: "" for one dense line, or e.g. "  " to pretty-print. MMA writes with
    ; an indent on purpose — masses.json is something you may well open and read,
    ; and a diff of two pretty files is reviewable where a diff of two one-liners
    ; is not.
    static Stringify(value, indent := "", _depth := 0) {
        if (value is Map)
            return JSON._StrMap(value, indent, _depth)
        if (value is Array)
            return JSON._StrArr(value, indent, _depth)
        if (value is Integer || value is Float)
            return String(value)
        return JSON._Quote(String(value))
    }

    ; Keys are written SORTED, deliberately.
    ;
    ; AHK v2's Map is not insertion-ordered and its enumeration order is not part
    ; of the documented contract, so "just write them as they come" would produce
    ; a file whose key order is whatever the implementation felt like. For
    ; masses.json that is the difference between a diff you can review and a diff
    ; that reshuffles forty fields for no reason. JSON objects are unordered by
    ; RFC 8259, so imposing an order costs nothing and buys byte-stable output.
    static _StrMap(obj, indent, depth) {
        if !obj.Count
            return "{}"
        nl  := indent = "" ? "" : "`n"
        pad := indent = "" ? "" : JSON._Repeat(indent, depth + 1)
        end := indent = "" ? "" : JSON._Repeat(indent, depth)
        keys := []
        for k in obj
            keys.Push(String(k))
        keys := JSON._Sorted(keys)
        parts := []
        for k in keys
            parts.Push(pad JSON._Quote(k) ":" (indent = "" ? "" : " ")
                       JSON.Stringify(obj[k], indent, depth + 1))
        return "{" nl JSON._Join(parts, "," nl) nl end "}"
    }

    ; Case-sensitive ordinal sort, so the order does not shift with the user's
    ; locale the way a linguistic comparison would.
    static _Sorted(arr) {
        joined := ""
        for v in arr
            joined .= (A_Index = 1 ? "" : "`n") v
        out := []
        for v in StrSplit(Sort(joined, "C"), "`n")
            out.Push(v)
        return out
    }

    static _StrArr(arr, indent, depth) {
        if !arr.Length
            return "[]"
        nl  := indent = "" ? "" : "`n"
        pad := indent = "" ? "" : JSON._Repeat(indent, depth + 1)
        end := indent = "" ? "" : JSON._Repeat(indent, depth)
        parts := []
        for v in arr
            parts.Push(pad JSON.Stringify(v, indent, depth + 1))
        return "[" nl JSON._Join(parts, "," nl) nl end "]"
    }

    ; Escape exactly what RFC 8259 requires: the quote, the backslash, and every
    ; control character below 0x20. Anything else — accented letters, emoji — is
    ; written literally, because the file is UTF-8 and \u-escaping it all would
    ; make the user's own messages unreadable in their own data file.
    static _Quote(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`t", "\t")
        s := StrReplace(s, Chr(8),  "\b")
        s := StrReplace(s, Chr(12), "\f")
        ; The stragglers: C0 controls with no short form. Starts at 1, not 0 —
        ; Chr(0) is a string terminator to half of the Win32 surface AHK sits on,
        ; so feeding it to StrReplace is asking for a truncated message library.
        ; It cannot appear in text typed into a chat box anyway.
        loop 31 {
            c := Chr(A_Index)
            if InStr(s, c)
                s := StrReplace(s, c, Format("\u{:04x}", A_Index))
        }
        return '"' s '"'
    }

    static _Repeat(s, n) {
        out := ""
        loop n
            out .= s
        return out
    }

    static _Join(arr, sep) {
        out := ""
        for v in arr
            out .= (A_Index = 1 ? "" : sep) v
        return out
    }
}
