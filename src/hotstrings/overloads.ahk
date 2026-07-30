#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings/overloads.ahk — the registry of overloaded hotstrings.
; ───────────────────────────────────────────────────────────────────────────────
;  Your message .ahk files are NEVER rewritten. A trigger listed here simply gets
;  re-pointed at the overload engine when its owning script loads (verified: a
;  runtime Hotstring() call replaces a statically defined one, and statics are
;  registered before the auto-execute section runs).
;
;  hotstring_overloads.ini — one section per overloaded trigger:
;
;      [_joi1]
;      file     = general.ahk      ; which message file defines it (base name)
;      options  = *                ; the bit between the first two colons
;      mode     = random           ; how THIS trigger picks: "ask" or "random"
;      variants = 2
;      v1.steps = 2
;      v1.1     = snd|first line
;      v1.2     = snd|second line
;      v2.steps = 1
;      v2.1     = SendText|an alternative
;
;  A step value is  fn|text , split on the FIRST pipe so text may contain pipes.
;  Newlines in text are escaped \n and backslashes \\ (see OL_Enc / OL_Dec).
;  Counts (variants / vN.steps) are explicit so loading never has to enumerate keys.
; ═══════════════════════════════════════════════════════════════════════════════

; Anchored to THIS file, so every script finds the one true registry.
#Include "../core/paths.ahk"
global OL_DIR := MMA_ROOT
global OL_INI := MMA_OVERLOADS

; ── escaping ──────────────────────────────────────────────────────────────────

OL_Enc(text) {
    t := StrReplace(text, "\", "\\")
    t := StrReplace(t, "`r`n", "`n")
    t := StrReplace(t, "`r", "`n")
    return StrReplace(t, "`n", "\n")
}

; Decoded left-to-right so an escaped backslash can't swallow a following "n".
OL_Dec(s) {
    out := ""
    i := 1
    n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "\") {
            nx := SubStr(s, i + 1, 1)
            if (nx = "n")
                out .= "`n"
            else if (nx = "\")
                out .= "\"
            else
                out .= nx
            i += 2
            continue
        }
        out .= c
        i++
    }
    return out
}

; "acc\ALIW.ahk" -> "ALIW.ahk"  (registry stores/compares base names)
OL_BaseName(path) {
    p := InStr(path, "\", , -1)
    return p ? SubStr(path, p + 1) : path
}

; ── reading ───────────────────────────────────────────────────────────────────

; One trigger -> {file, options, variants:[ [{fn,text},…], … ]}, or "" if absent.
OL_LoadOne(trigger) {
    global OL_INI
    if !FileExist(OL_INI)
        return ""
    ; LOG_IniInt: OL_Load calls this for every section, and Overload_Register calls
    ; OL_Load at LOAD time in every message script. So one malformed `variants=`
    ; line in hotstring_overloads.ini did not disable one overload — it stopped
    ; general.ahk and every account file from starting, taking all their hotstrings
    ; with them.
    nv := LOG_IniInt(OL_INI, trigger, "variants", 0, "overload.load")
    if (nv < 1)
        return ""
    file    := Trim(IniRead(OL_INI, trigger, "file", ""))
    options := Trim(IniRead(OL_INI, trigger, "options", ""))
    mode    := StrLower(Trim(IniRead(OL_INI, trigger, "mode", "ask")))
    variants := []
    Loop nv {
        vi := A_Index
        ns := LOG_IniInt(OL_INI, trigger, "v" vi ".steps", 0, "overload.load")
        steps := []
        Loop ns {
            raw := IniRead(OL_INI, trigger, "v" vi "." A_Index, "")
            if (raw = "")
                continue
            bar := InStr(raw, "|")
            fn  := bar ? Trim(SubStr(raw, 1, bar - 1)) : "snd"
            tx  := bar ? SubStr(raw, bar + 1) : raw
            steps.Push({fn: fn, text: OL_Dec(tx)})
        }
        if steps.Length
            variants.Push(steps)
    }
    return variants.Length ? {file: file, options: options, mode: mode, variants: variants} : ""
}

; Every overload: Map(trigger -> entry).
OL_Load() {
    global OL_INI
    res := Map()
    if !FileExist(OL_INI) {
        LOGV("overload.load", "no " OL_INI " — no hotstring is overloaded, so every"
                            . " trigger sends its one fixed message")
        return res
    }
    bad := ""
    for sec in StrSplit(IniRead(OL_INI), "`n", "`r") {
        sec := Trim(sec)
        if (sec = "")
            continue
        e := OL_LoadOne(sec)
        if e
            res[sec] := e
        else
            bad .= (bad = "" ? "" : ", ") sec
    }
    ; A section that parses to nothing is silently dropped, and the trigger then
    ; behaves as an ordinary hotstring — which looks like the overload having been
    ; forgotten rather than rejected. Naming them is the difference.
    if (bad != "")
        LOGW("overload.load", "these sections in hotstring_overloads.ini have no"
                            . " usable variants and were IGNORED: " bad)
    LOGV("overload.load", res.Count " overloaded trigger(s) loaded")
    return res
}

OL_Has(trigger) {
    return OL_LoadOne(trigger) != ""
}

; ── writing ───────────────────────────────────────────────────────────────────

; Rewrites the trigger's section wholesale, so deleted variants actually disappear.
OL_Save(trigger, file, options, variants, mode := "ask") {
    global OL_INI
    OL_Remove(trigger)
    IniWrite(OL_BaseName(file),      OL_INI, trigger, "file")
    IniWrite(options,                OL_INI, trigger, "options")
    IniWrite(StrLower(Trim(mode)),   OL_INI, trigger, "mode")
    IniWrite(variants.Length,        OL_INI, trigger, "variants")
    for vi, steps in variants {
        IniWrite(steps.Length, OL_INI, trigger, "v" vi ".steps")
        for si, st in steps
            IniWrite(st.fn "|" OL_Enc(st.text), OL_INI, trigger, "v" vi "." si)
    }
}

OL_Remove(trigger) {
    global OL_INI
    try IniDelete(OL_INI, trigger)
}
