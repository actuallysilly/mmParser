#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "../vendor/json.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/sim_notes.ahk — the fan's half of the simulated conversation.
; ───────────────────────────────────────────────────────────────────────────────
;  The chat simulator draws your mass as a transcript. A transcript of one side
;  of a conversation is a list, and a list is what the GUI already shows you.
;  What makes it a CONVERSATION is the replies in between — and those are not
;  part of the mass, so they cannot live in masses.json.
;
;      "hey babe what are you up to"        ← f1, from the mass
;      "nothing much, bored at work"        ← the fan, from this file
;      "well then let me give you something to think about"   ← f2, from the mass
;
;  You write the fan's lines from memory: what they usually say, what the reply
;  you are afraid of looks like. Then f2 is written against something rather than
;  into the air. That is the whole feature, and it is why these are worth keeping
;  between sessions instead of being a scratchpad you retype every time.
;
;  ─── WHY ITS OWN FILE, NOT A FIELD ON THE MASS ───────────────────────────────
;  masses.json is what MMA SENDS. Everything in it goes out to somebody. A fan
;  line that exists only so you can read your own follow-up in context must never
;  be one keystroke away from being sent, and it must never be something a future
;  reader of that record has to work out the sendability of. Separate file,
;  separate question — the same reasoning that keeps branch_trees.json out of
;  masses.json, and userdata\hotstring_usage.ini out of hotstring_overloads.ini.
;
;  ─── SHAPE ───────────────────────────────────────────────────────────────────
;      {
;        "schema": 1,
;        "notes": {
;          "1:2": {                     model 1, mass slot 2
;            "branch": 0,               which branch the window was last showing
;            "replies": {               the fan line AFTER each beat, if any
;              "mass": "nothing much, bored at work",
;              "fu1":  "haha maybe"
;            }
;          }
;        }
;      }
;
;  Keyed "<model>:<slot>" because that pair is what a mass IS to the rest of MMA
;  — the same coordinates MASS_Get takes. A note whose mass has since been
;  rewritten is simply a note against the new one, which is right: the slot is
;  the conversation, and you are still writing the same conversation.
; ═══════════════════════════════════════════════════════════════════════════════

global SIM_FILE   := MMA_USERDATA "\chat_sim.json"
global SIM_SCHEMA := 1

; The whole file. Never throws: these are notes, and a damaged notes file must
; not stop the window opening — losing the fan lines costs you context, losing
; the window costs you the feature.
;
; A corrupt file is REPORTED and left alone rather than replaced, for the reason
; MASS_Load gives about masses.json: a text editor can still recover something
; from a file that is still on disk.
SIM_Load() {
    global SIM_FILE, SIM_SCHEMA
    blank := Map("schema", SIM_SCHEMA, "notes", Map())
    if !FileExist(SIM_FILE) {
        LOGV("sim.load", "no chat_sim.json yet — the simulator starts with no fan"
                       . " lines, which is what a first run looks like")
        return blank
    }
    try {
        doc := JSON.Parse(FileRead(SIM_FILE, "UTF-8"))
    } catch as e {
        LOGE("sim.load", "chat_sim.json could not be read — the simulator opens"
                       . " with NO fan lines. The file is untouched; open it in an"
                       . " editor before letting the window save over it.",
                       LOG_Err(e))
        return blank
    }
    if !(doc is Map) || !doc.Has("notes") || !(doc["notes"] is Map) {
        LOGW("sim.load", "chat_sim.json is not the shape this module writes —"
                       . " starting empty")
        return blank
    }
    return doc
}

SIM_Save(doc) {
    global SIM_FILE, SIM_SCHEMA
    doc["schema"] := SIM_SCHEMA
    tmp := SIM_FILE ".tmp"
    try {
        ; UTF-8-RAW, not UTF-8: the latter writes a BOM, and a BOM is illegal at
        ; the start of JSON — the same trap MASS_Save documents.
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        if !f
            throw Error("could not open " tmp " for writing")
        f.Write(JSON.Stringify(doc, "  "))
        f.Close()
        FileMove(tmp, SIM_FILE, true)
    } catch as e {
        try FileDelete(tmp)
        ; WARN, not FAIL, and no dialog. These are notes: losing them is annoying
        ; and losing your place mid-sentence to a modal is worse. MASS_Save is the
        ; one that shouts, because that file is every message you have written.
        LOGW("sim.save", "could not write chat_sim.json — this session's fan lines"
                       . " are not on disk:  " LOG_Err(e))
        return false
    }
    return true
}

; ── where you were ───────────────────────────────────────────────────────────
;  Which mass the simulator was last looking at. Kept beside the notes rather
;  than in mass_gui.cfg because it is the same kind of thing they are: a fact
;  about this window's session, not a setting anybody chose.
;
;  Clamped by the caller, not here — this module has no opinion about how many
;  models exist, and a stored 7 must not become an error just because the model
;  count was lowered since.
SIM_LastAt(doc) {
    if (!doc.Has("last") || !(doc["last"] is Map))
        return Map("model", 1, "slot", 1)
    l := doc["last"]
    return Map("model", l.Has("model") && IsInteger(l["model"]) ? l["model"] : 1,
               "slot",  l.Has("slot")  && IsInteger(l["slot"])  ? l["slot"]  : 1)
}

SIM_SetLastAt(doc, modelNo, slot) {
    doc["last"] := Map("model", modelNo, "slot", slot)
    return doc
}

; "<model>:<slot>". One place, so a reader and a writer cannot disagree about it.
SIM_Key(modelNo, slot) {
    return modelNo ":" slot
}

; The note for one mass: {branch, replies}. Always a usable object, so callers
; need no Has() guards — the same courtesy MASS_Blank does for a mass.
SIM_For(doc, modelNo, slot) {
    k := SIM_Key(modelNo, slot)
    if !doc["notes"].Has(k)
        return Map("branch", 0, "replies", Map())
    n := doc["notes"][k]
    if !(n is Map)
        return Map("branch", 0, "replies", Map())
    return Map("branch",  n.Has("branch") && IsInteger(n["branch"]) ? n["branch"] : 0,
               "replies", n.Has("replies") && (n["replies"] is Map) ? n["replies"] : Map())
}

; Replace one mass's note wholesale.
;
; Empty replies are DROPPED rather than stored as "". A note file that accumulates
; a blank entry for every beat of every slot you ever opened is a file nobody can
; read, and "no reply here" and "a reply that is empty" are not two states.
SIM_Set(doc, modelNo, slot, replies, branch) {
    keep := Map()
    for k, v in replies
        if (Trim(String(v)) != "")
            keep[k] := String(v)
    if (!keep.Count && !branch) {
        ; Nothing left to remember about this slot. Remove the entry instead of
        ; writing an empty one, so clearing your notes really does clear them.
        try doc["notes"].Delete(SIM_Key(modelNo, slot))
        return doc
    }
    doc["notes"][SIM_Key(modelNo, slot)] := Map("branch", branch, "replies", keep)
    return doc
}
