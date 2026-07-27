#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  migrate_masses.ahk — content\models\*.ahk  ->  userdata\masses.json
; ───────────────────────────────────────────────────────────────────────────────
;  One-shot, for the 2.0.0 cut. Reads the three model scripts with the SAME regex
;  the GUI's LoadFile used, so what lands in JSON is exactly what the GUI would
;  have shown you, then reads the result back and compares every field.
;
;  It refuses to overwrite an existing masses.json. Run it once; after that the
;  .ahk files are history and this file can go.
;
;  Prints to stdout. Exit 0 = migrated and verified, 1 = something differed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/mass/store.ahk"

Out(s) => FileAppend(s "`n", "*")

if FileExist(MMA_MASSES) {
    Out("masses.json already exists — refusing to overwrite.")
    Out("Delete it first if you really mean to re-migrate.")
    ExitApp(1)
}

; ── read ──────────────────────────────────────────────────────────────────────
; Mirrors the old LoadFile: find each `mN := { … }` block, then pull `key: "value"`
; out of it. The value pattern allows any char that is not a quote or a backtick,
; plus any backtick-escaped pair — which is how AHK source quoted these.
doc     := MASS_Default()
fields  := MASS_Fields()
q       := Chr(34)
bt      := Chr(96)
found   := 0
missing := []

Loop MASS_MODELS {
    modelNo := A_Index
    path    := MMA_ModelFile(modelNo)
    if !FileExist(path) {
        Out("  model " modelNo ": no file at " path " — leaving it blank")
        continue
    }
    content := FileRead(path, "UTF-8")

    ; `massNo := N` is the live-slot pointer that used to be a line of code.
    if RegExMatch(content, "m)^\s*massNo\s*:=\s*(\d+)", &mn)
        MASS_SetMassNo(doc, modelNo, Integer(mn[1]))

    Loop MASS_SLOTS {
        slot := A_Index
        if !RegExMatch(content, "m" slot " := \{([^}]*)\}", &blk) {
            missing.Push("model " modelNo " slot " slot)
            continue
        }
        rec := MASS_Get(doc, modelNo, slot)
        for field in fields {
            pat := "(?:^|\R)\s*" field ": " q "((?:[^" q bt "]|" bt ".)*)" q
            if !RegExMatch(blk[1], pat, &mv)
                continue
            v := mv[1]
            ; Multiline fields were flattened to a literal `n by the writer.
            if MASS_FieldIsMultiline(field)
                v := StrReplace(v, bt "n", "`n")
            rec[field] := UnescAhk(v)
            if (Trim(rec[field]) != "")
                found++
        }
    }
}

; Undo the AHK source escaping the old writer applied (EscQ's inverse).
UnescAhk(s) {
    bt := Chr(96)
    out := "", i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = bt && i < n) {
            e := SubStr(s, i + 1, 1)
            switch e {
                case "n": out .= "`n"
                case "r": out .= "`r"
                case "t": out .= "`t"
                default:  out .= e          ; `" and `` and `; -> the bare char
            }
            i += 2
            continue
        }
        out .= c
        i++
    }
    return out
}

Out("read " found " non-empty fields from " MASS_MODELS " model files")
for m in missing
    Out("  WARNING: no block for " m " — stored blank")

; ── write ─────────────────────────────────────────────────────────────────────
if !MASS_Save(doc) {
    Out("FAILED to write " MMA_MASSES)
    ExitApp(1)
}
Out("wrote " MMA_MASSES)

; ── verify: read it back and compare every single field ──────────────────────
; The whole point. A migration you did not diff is a migration you are hoping
; about, and what is at stake is the entire message library.
back := MASS_Load()
bad  := 0
Loop MASS_MODELS {
    modelNo := A_Index
    if (MASS_MassNo(back, modelNo) != MASS_MassNo(doc, modelNo)) {
        Out("MISMATCH model " modelNo " massNo")
        bad++
    }
    Loop MASS_SLOTS {
        slot := A_Index
        a := MASS_Get(doc,  modelNo, slot)
        b := MASS_Get(back, modelNo, slot)
        for field in fields {
            if (a[field] == b[field])
                continue
            bad++
            Out("MISMATCH m" modelNo " slot" slot " ." field)
            Out("   wrote: " StrReplace(a[field], "`n", "\n"))
            Out("   read:  " StrReplace(b[field], "`n", "\n"))
        }
    }
}

Out("")
if bad {
    Out("VERIFY FAILED — " bad " field(s) differ. masses.json is NOT trustworthy.")
    ExitApp(1)
}
Out("verified: every field survived the round trip.")
ExitApp(0)
