#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  ini_utf8.ahk — read and set one key in a UTF-8 ini that is not ours.
; ───────────────────────────────────────────────────────────────────────────────
;  For the ini files the Python services own (userdata\autoword.ini first). They
;  are UTF-8, mostly without a BOM, and full of non-ASCII comments. IniWrite goes
;  through the Windows profile API, which rewrites a BOM-less file through the
;  ANSI code page — a character whose UTF-8 bytes include 0x81/0x8D/0x8F/0x90/
;  0x9D does not survive that. These edit the one value line in the text and
;  leave every other byte, the BOM-or-not and the line endings as they were.
;
;  mass_gui.cfg and the other AHK-owned files keep using IniRead/IniWrite.
; ═══════════════════════════════════════════════════════════════════════════════

; The value of `key` in `[section]`, or `def`. Comment lines are skipped.
INI8_Read(path, section, key, def := "") {
    if !FileExist(path)
        return def
    inSect := false
    for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        t := Trim(line)
        if RegExMatch(t, "^\[(.*)\]$", &m) {
            inSect := (m[1] = section)
            continue
        }
        if inSect && RegExMatch(t, "i)^\Q" key "\E\s*=\s*(.*)$", &m)
            return Trim(m[1])
    }
    return def
}

; Set `key` in `[section]`, editing only that line. A key that is missing is
; added at the end of its section, a section that is missing at the end of the
; file, and a file that is missing is created (UTF-8, no BOM).
INI8_Write(path, section, key, value) {
    if !FileExist(path) {
        FileAppend("[" section "]`n" key " = " value "`n", path, "UTF-8-RAW")
        return
    }
    raw := FileRead(path, "RAW")
    bom := raw.Size >= 3 && NumGet(raw, 0, "UChar") = 0xEF
                         && NumGet(raw, 1, "UChar") = 0xBB && NumGet(raw, 2, "UChar") = 0xBF
    text := FileRead(path, "UTF-8")
    nl := InStr(text, "`r`n") ? "`r`n" : "`n"
    lines := StrSplit(text, "`n", "`r")
    inSect := false, sectEnd := 0, done := false
    for i, line in lines {
        t := Trim(line)
        if RegExMatch(t, "^\[(.*)\]$", &m) {
            if inSect && !sectEnd
                sectEnd := i
            inSect := (m[1] = section)
            continue
        }
        if inSect && RegExMatch(t, "i)^\Q" key "\E\s*=") {
            lines[i] := key " = " value
            done := true
            break
        }
    }
    if !done {
        if inSect && !sectEnd
            lines.Push(key " = " value)
        else if sectEnd
            lines.InsertAt(sectEnd, key " = " value)
        else
            lines.Push("[" section "]", key " = " value)
    }
    out := ""
    for i, line in lines
        out .= line (i < lines.Length ? nl : "")
    f := FileOpen(path, "w", bom ? "UTF-8" : "UTF-8-RAW")
    f.Write(out)
    f.Close()
}
