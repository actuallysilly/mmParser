#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "../vendor/json.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  store.ahk — the mass library: its shape, and the one file it lives in.
; ───────────────────────────────────────────────────────────────────────────────
;  Masses used to be AHK SOURCE. The GUI generated `m1 := { mass: "…", … }` blocks
;  by string-splicing, and EscQ/UnescQ existed purely to make message text survive
;  a round trip through a programming language's grammar. That has a nasty failure
;  mode: a save that produces subtly wrong source produces a file that will not
;  load, exits 0, and says nothing — the same silent death as the `base`-is-
;  reserved bug. Data files do not have syntax errors that kill a process.
;
;  So the library is now userdata\masses.json, and this module is the only thing
;  that reads or writes it. See ARCHITECTURE.md §5.
;
;  ── Shape ────────────────────────────────────────────────────────────────────
;      {
;        "schema": 1,
;        "models": [                      exactly MASS_MODELS entries, in order
;          { "massNo": 1,                 which of this model's masses is live
;            "masses": [ {…}, {…}, {…} ]  exactly MASS_SLOTS entries
;          }, …
;        ]
;      }
;
;  One mass is a FLAT record of string fields — MASS_Fields() is the list. Flat is
;  not an accident: every field is one editable box in the GUI, and keeping the
;  storage shape equal to the editing shape is what stops a mapping layer from
;  existing at all.
;
;  ── Why the field list lives HERE ────────────────────────────────────────────
;  It used to be MassBlockProps() inside the GUI, with ALT_MAX_RT / BRANCH_MAX_RT
;  copied into utils.ahk under a comment reading "must match ALT_MAX in
;  main_window.ahk". Two files agreeing by hand about a record shape is a bug
;  waiting for someone to add a field. The GUI edits the record and the engine
;  sends it; neither owns it, so it is defined once, here.
; ═══════════════════════════════════════════════════════════════════════════════

global MASS_SCHEMA     := 1

; ── how many models the tree supports ─────────────────────────────────────────
;  This was `:= 3`, and it was the ONE number that pinned MMA to three models —
;  everything downstream already looped over it. It now follows the user's own
;  [Settings] ModelCount, so adding a model is a setting rather than a release.
;
;  Two guards, and both matter:
;
;    • never below 3. Every existing library on disk has three model entries and
;      three sets of numbered hotkeys ([mass.1]-[mass.3]) declared against them.
;      Dropping below that would orphan both.
;    • never above MASS_MODELS_MAX. Not arbitrary timidity: each model is a row in
;      Settings, a tab in the panel and an entry in every masses.json, and a cfg
;      typo of 400 should not produce a 400-tab window and a megabyte of blank
;      records. The cap is where the GUI stops being usable, not where the data
;      stops working.
;
;  MASS_MODELS is the CEILING — the slots that exist. [Settings] ModelCount is
;  also what the GUI shows, so in practice they are the same number; the two stay
;  distinct because the library must never be smaller than the file it is loading
;  (see MASS_Normalise).
global MASS_MODELS_MAX := 12
global MASS_MODELS     := _MASS_SlotCount()

_MASS_SlotCount() {
    global MASS_MODELS_MAX
    n := 3
    try n := Integer(Trim(IniRead(MMA_CFG, "Settings", "ModelCount", 3)))
    catch
        n := 3
    if (n < 3)
        n := 3
    if (n > MASS_MODELS_MAX)
        n := MASS_MODELS_MAX
    return n
}

global MASS_SLOTS      := 3      ; masses per model (was m1 / m2 / m3)
global MASS_ALT_MAX    := 3      ; alt wordings per follow-up
global MASS_BRANCH_MAX := 3      ; --Name branches per mass

; ── The record shape ──────────────────────────────────────────────────────────

; Alt fields for one follow-up group: fu<grp>_alt0 … _alt<MASS_ALT_MAX-1>
MASS_AltFields(grp) {
    out := []
    Loop MASS_ALT_MAX
        out.Push("fu" grp "_alt" (A_Index - 1))
    return out
}

; The five fields of one named branch.
MASS_BranchFields(n) {
    return ["br" n "_name", "br" n "_fu1", "br" n "_fu2", "br" n "_fu3",
            "br" n "_ppv"]
}

; Every field of one mass, in the order the GUI lays them out. Adding a field
; here is enough — the loader, the writer, the blank-record builder and the
; migration all read this list.
MASS_Fields() {
    out := ["mass", "fu1", "fu1_5", "fu1_7", "fu2", "fu2_5", "fu2_7",
            "fu3", "fu3_5", "fu3_7", "ppv_base", "ppv_f1", "ppv_f2", "ppv_f3"]
    Loop MASS_BRANCH_MAX
        for f in MASS_BranchFields(A_Index)
            out.Push(f)
    for grp in [1, 2, 3]
        for f in MASS_AltFields(grp)
            out.Push(f)
    out.Push("altGui")
    return out
}

; True for fields whose value may span lines. The GUI stores those with real
; newlines; only the old .ahk serialiser needed them flattened to `n, and that
; is exactly the escaping this format removes.
MASS_FieldIsMultiline(field) {
    if (field = "ppv_base" || InStr(field, "_alt"))
        return true
    return RegExMatch(field, "^br\d+_(fu\d|ppv)$") > 0
}

; A multiline field's stored value, split back into the parts it was joined from.
;
; This is the other half of MASS_FieldIsMultiline: that says WHICH fields carry
; several messages in one field, and this says how to read one back out. Both
; are the record format, so both belong here.
;
; It existed twice — AltParts() in main_window.ahk and AltPartsRT() in utils.ahk,
; identical character for character — because the GUI deliberately does not
; include utils.ahk and so had no way to reach it. The "RT" suffix was only ever
; there to stop the two names colliding. Both files already reach store.ahk, so
; one copy is enough and neither needs a suffix.
MASS_SplitParts(stored) {
    parts := []
    for _, p in StrSplit(StrReplace(StrReplace(stored, "`r`n", "`n"), "``n", "`n"), "`n")
        if Trim(p) != ""
            parts.Push(Trim(p))
    return parts
}

; A mass with every field present and empty. Every reader can then assume the
; key exists, which is what lets the rest of the code drop its Has() guards.
MASS_Blank() {
    m := Map()
    for f in MASS_Fields()
        m[f] := ""
    return m
}

; ── Reading and writing ───────────────────────────────────────────────────────

; The whole library. Never throws: a missing file is a first run, and a corrupt
; one must not take the GUI down with it — it is reported and backed up, because
; silently replacing a damaged message library with an empty one would destroy
; work that a text editor could still have recovered.
MASS_Load() {
    if !FileExist(MMA_MASSES) {
        ; On a fresh install this is right and harmless. On an existing one it
        ; means every mass the user has written is gone from MMA's point of view,
        ; and the first symptom is every follow-up key doing nothing — so it says
        ; which file it looked for rather than starting empty in silence.
        LOGW("mass.load", "masses.json does not exist — starting with an EMPTY"
                        . " library. Normal on a first run; on an existing install"
                        . " it means every mass is missing. Looked for " MMA_MASSES)
        return MASS_Default()
    }
    try {
        raw := FileRead(MMA_MASSES, "UTF-8")
        ; FileRead strips a leading BOM, but a file written by some other tool may
        ; still start with U+FEFF mid-stream after decoding. Drop it rather than
        ; fail: a stray BOM is a nuisance, not a reason to lose the library.
        if (SubStr(raw, 1, 1) = Chr(0xFEFF))
            raw := SubStr(raw, 2)
        doc := JSON.Parse(raw)
    } catch as e {
        bak := MMA_MASSES ".broken-" FormatTime(, "yyyyMMdd-HHmmss")
        try FileCopy(MMA_MASSES, bak, true)
        LOGE("mass.load", "masses.json is not valid JSON — started with an EMPTY"
                        . " library and kept a copy of the broken file",
                        LOG_Err(e) "   copy: " bak)
        MsgBox "masses.json could not be read:`n`n" e.Message
             . "`n`nA copy was kept at:`n" bak
             . "`n`nMMA has started with an empty library. Fix that file and "
             . "restart rather than saving over it.", "MMA", 0x10
        return MASS_Default()
    }
    doc := MASS_Normalise(doc)
    ; A summary of what actually loaded, per model: which slot is live and how
    ; many of its slots have any text at all. This is the line that settles
    ; "the hotkeys do nothing" — massNo pointing at an empty slot while the text
    ; sits in another one is a known and repeat offender, and it is invisible
    ; from the keyboard.
    if LOG_On() {
        summary := ""
        Loop MASS_MODELS {
            mi := A_Index
            filled := ""
            Loop MASS_SLOTS
                if (Trim(MASS_Get(doc, mi, A_Index)["mass"]) != "")
                    filled .= A_Index
            summary .= (summary = "" ? "" : "   ")
                     . "m" mi ": live=" MASS_MassNo(doc, mi)
                     . " withText=" (filled = "" ? "none" : filled)
        }
        LOGI("mass.load", "loaded " MMA_MASSES " — " summary)
    }
    return doc
}

; Write the library. Writes to a TEMP file and moves it into place, so a crash
; or a full disk mid-write leaves the previous library intact instead of a
; half-written one — this single file is now every mass the user has.
MASS_Save(doc) {
    doc := MASS_Normalise(doc)
    tmp := MMA_MASSES ".tmp"
    try {
        ; "UTF-8-RAW", not "UTF-8" — the latter writes a BOM, and a BOM is
        ; ILLEGAL at the start of JSON. Python's json.load rejects it outright and
        ; so does a browser's JSON.parse, which would quietly undo the main reason
        ; this is JSON rather than another ini: that something other than AHK can
        ; read it (the web branch editor in docs/proposals/branching.md).
        ; FileRead(…, "UTF-8") strips a BOM on the way back in, so AHK never
        ; noticed it was writing one.
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        if !f
            throw Error("could not open " tmp " for writing")
        body := JSON.Stringify(doc, "  ")
        f.Write(body)
        f.Close()
        FileMove(tmp, MMA_MASSES, true)
        LOGI("mass.save", "wrote " MMA_MASSES " (" StrLen(body) " chars) via "
                        . "temp file + move")
    } catch as e {
        try FileDelete(tmp)
        ; Losing a save is the worst outcome in the app — this file IS every mass
        ; the user has written. FAIL so it pops up when popups are on, rather than
        ; only living behind the MsgBox the user is about to dismiss.
        LOGE("mass.save", "could not save masses.json — YOUR EDITS ARE NOT ON DISK."
                        . " The previous library is intact.", LOG_Err(e))
        MsgBox "Could not save masses.json:`n`n" e.Message, "MMA", 0x10
        return false
    }
    return true
}

; An empty library with every slot present.
MASS_Default() {
    models := []
    Loop MASS_MODELS {
        masses := []
        Loop MASS_SLOTS
            masses.Push(MASS_Blank())
        models.Push(Map("massNo", 1, "masses", masses))
    }
    return Map("schema", MASS_SCHEMA, "models", models)
}

; Force a document into full shape: every model, every slot, every field.
;
; Run on the way IN and on the way OUT. A hand-edited file that omits a field, a
; release that adds one, a truncated array — all become "present and empty"
; rather than a crash somewhere far away in the send path, where the first sign
; of trouble would be a fan receiving nothing.
MASS_Normalise(doc) {
    if !(doc is Map)
        doc := Map()
    out := Map("schema", MASS_SCHEMA, "models", [])
    src := (doc.Has("models") && doc["models"] is Array) ? doc["models"] : []
    ; Max, not MASS_MODELS. Now that the slot count follows a SETTING, a plain
    ; `Loop MASS_MODELS` would make "set Active models back to 3" a data-destroying
    ; action: models 4-8 would be dropped on the next normalise and written out on
    ; the next save, with no warning and no undo, taking every mass in them. Keeping
    ; whatever the file already holds means lowering the count HIDES models rather
    ; than deleting them, and raising it again brings the text back.
    keep := Max(MASS_MODELS, src.Length)
    Loop keep {
        mi  := A_Index
        sm  := (mi <= src.Length && src[mi] is Map) ? src[mi] : Map()
        sMs := (sm.Has("masses") && sm["masses"] is Array) ? sm["masses"] : []
        masses := []
        Loop MASS_SLOTS {
            rec := MASS_Blank()
            if (A_Index <= sMs.Length && sMs[A_Index] is Map) {
                for f, v in sMs[A_Index]
                    if rec.Has(f)                  ; drop keys we no longer know
                        rec[f] := String(v)
            }
            masses.Push(rec)
        }
        no := sm.Has("massNo") ? Integer(sm["massNo"]) : 1
        if (no < 1 || no > MASS_SLOTS)
            no := 1
        out["models"].Push(Map("massNo", no, "masses", masses))
    }
    return out
}

; ── Accessors ─────────────────────────────────────────────────────────────────

MASS_Get(doc, modelNo, slot) {
    return doc["models"][modelNo]["masses"][slot]
}

MASS_Set(doc, modelNo, slot, rec) {
    doc["models"][modelNo]["masses"][slot] := rec
}

; Which mass a model's hotkeys act on. This was `massNo := 1` written into the
; model's SOURCE and rewritten by the GUI on every change — state stored as code.
MASS_MassNo(doc, modelNo) {
    return doc["models"][modelNo]["massNo"]
}

MASS_SetMassNo(doc, modelNo, slot) {
    if (slot >= 1 && slot <= MASS_SLOTS)
        doc["models"][modelNo]["massNo"] := slot
}

; The record a model's hotkeys should send right now.
MASS_Active(doc, modelNo) {
    return MASS_Get(doc, modelNo, MASS_MassNo(doc, modelNo))
}

; A mass as a plain OBJECT rather than a Map, i.e. m.fu1 instead of m["fu1"].
;
; Storage wants a Map (that is what a JSON object is, and what lets Normalise
; iterate keys generically). The send path wants properties: every follow-up,
; alt and branch helper in utils.ahk and runtime.ahk was written against m.fu1 /
; m.%key% / m.HasOwnProp(key), and that code is correct and working. Converting
; at the boundary keeps one shape for storage and one for sending without either
; side compromising — and without touching a single line of the send logic, which
; is the part it would hurt most to get wrong.
MASS_AsObject(rec) {
    o := {}
    for k, v in rec
        o.%k% := v
    return o
}
