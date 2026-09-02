#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  mass/shape.ahk — what a mass SENDS. The rules, with no sending in them.
; ───────────────────────────────────────────────────────────────────────────────
;  store.ahk owns the record: which fields exist and how they are written to disk.
;  runtime.ahk owns the keys: which press does what, and the clipboard work. This
;  file is the thing in between, and it had no home until now — the answer to
;  "given this mass, what messages go out, in what order?"
;
;  ─── WHY IT IS ITS OWN FILE ──────────────────────────────────────────────────
;  Every function here was already pure and already took the mass object; they
;  were just spread across the two files that happened to call them first, both
;  of which a GUI process cannot include. core\utils.ahk registers hotstrings and
;  binds keys the moment it loads (which is why main_window.ahk must not include
;  it), and mass\runtime.ahk binds the follow-up keys.
;
;  That mattered the day something OTHER than the engine needed the same answer.
;  The chat simulator (ui\chat_window.ahk) draws the conversation a mass turns
;  into — and a simulator that works the order out for itself is a second set of
;  rules that agrees with the engine until the week somebody changes one of them.
;  The branch builder already makes this promise about compiling and keeps it by
;  asking AHK rather than reimplementing in JavaScript; this is the same promise
;  for sending.
;
;  So: nothing in here touches the clipboard, presses a key, reads the screen or
;  knows which model is on it. Give it a record and it tells you what that record
;  means. Both the engine and the simulator read these, and there is one copy.
;
;  ─── WHAT IT DOES READ ───────────────────────────────────────────────────────
;  Settings, because three of them genuinely change what goes out:
;      FuSingle_<model>_<group>   three parts as one message, or as three
;      DefaultFu3 / defaultFu3    the fallback f3 for a mass that has none
;      altFollowups (feature)     whether branches exist at all
;  Those are reads, not writes, and they are per call rather than cached — the
;  same trade sndFu already made, so an edit applies without a restart.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../core/paths.ahk"
#Include "../core/modes.ahk"
#Include "store.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  Named branches (`::name`)
; ───────────────────────────────────────────────────────────────────────────────
;  A branch is a named alternative to the trunk: its own fu1/fu2/fu3/ppv, any of
;  which may be empty. Picking one at f1 continues on it at f2/f3/ppv. Since the
;  alt fields went, this is the ONLY kind of alternative there is — "alt" is just
;  the name people give a branch that has no better one.
; ═══════════════════════════════════════════════════════════════════════════════

; Non-empty branches on a mass: [{name, fu:[[p..],[p..],[p..]], ppv}].
BranchList(m) {
    global MASS_BRANCH_MAX
    out := []
    ; No branches means every branch key and window finds nothing to do, which is
    ; the pre-branch behaviour. Gating here rather than at each of the six call
    ; sites keeps the mass data itself untouched — switch branches back on and the
    ; `::name` wordings are still there.
    if !FEAT("altFollowups")
        return out
    Loop MASS_BRANCH_MAX {
        k  := A_Index
        f1 := "br" k "_fu1", f2 := "br" k "_fu2", f3 := "br" k "_fu3", pk := "br" k "_ppv"
        got := false
        for _, key in [f1, f2, f3, pk]
            if m.HasOwnProp(key) && Trim(m.%key%) != ""
                got := true
        if !got
            continue
        nk := "br" k "_name"
        nm := (m.HasOwnProp(nk) && Trim(m.%nk%) != "") ? Trim(m.%nk%) : "branch " k
        out.Push({ name: nm,
                   fu:   [BranchParts(m, f1), BranchParts(m, f2), BranchParts(m, f3)],
                   ppv:  (m.HasOwnProp(pk) ? Trim(m.%pk%) : "") })
    }
    return out
}

BranchParts(m, key) {
    return m.HasOwnProp(key) ? MASS_SplitParts(m.%key%) : []
}

; ═══════════════════════════════════════════════════════════════════════════════
;  One list of ways to answer this follow-up
; ───────────────────────────────────────────────────────────────────────────────
;  Alts and branches were two features with two keys and two pickers. They are one
;  question — "which wording goes out for f<N>?" — so they are one list and one
;  key now, and TAB walks the whole thing.
;
;  The merge finished in the DATA, not just here: there are no alt fields any
;  more. Everything that is not the trunk is a named branch, and "alt" is simply
;  the name you give one when the wording has no better name — see the record
;  shape in mass/store.ahk and the `::name` marker in mass/parser.ahk.
;
;  What a branch carries that a loose wording did not is the IMPLICATION: pick a
;  branch variant at f1 and f2/f3/ppv start on that same branch. That is what
;  `branch` on each variant is for.
;
;  Each variant is { parts, label, branch }:
;      parts   the messages to send, in order
;      label   what the staged list calls it ("main", or the branch's name)
;      branch  0 for the trunk, else which branch it commits you to
; ═══════════════════════════════════════════════════════════════════════════════

AltVariants(m, group) {
    out := []
    base := []
    for _, sfx in ["", "_5", "_7"] {
        key := "fu" group sfx
        if m.HasOwnProp(key) && Trim(m.%key%) != ""
            base.Push(Trim(m.%key%))
    }
    if base.Length
        out.Push({ parts: base, label: "main", branch: 0 })
    ; The branches, as the other ways to answer the same question. A branch with
    ; nothing in THIS group is skipped rather than shown empty — branches are
    ; commonly f1-only, and an empty row you can TAB onto and send is a way to
    ; send silence.
    for bi, b in BranchList(m) {
        if !b.fu[group].Length
            continue
        out.Push({ parts: b.fu[group], label: b.name, branch: bi })
    }
    return out
}

; The same question for the PPV: the trunk's ppv, then each branch's.
AltPpvVariants(m) {
    out := []
    if m.HasOwnProp("ppv_base") && Trim(m.ppv_base) != ""
        out.Push({ parts: [Trim(m.ppv_base)], label: "main", branch: 0 })
    for bi, b in BranchList(m) {
        if Trim(b.ppv) = ""
            continue
        out.Push({ parts: [Trim(b.ppv)], label: b.name, branch: bi })
    }
    return out
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The three settings that change what goes out
; ═══════════════════════════════════════════════════════════════════════════════

; The three fields that make up a follow-up group: fuN, fuN_5, fuN_7.
;
; Group 3 alone has a fallback: a mass with no f3 at all sends the DefaultFu3 text
; from Settings instead of nothing. Applied here rather than in sndFu because
; SndFuEditable takes the same parts and has no idea which group it is holding —
; one place covers the plain send, the editable/wallet paste, and both halves of
; a double-MM (so a second model with no f3 still gets the default).
MASS_FuParts(m, group) {
    parts := [m.%"fu" group%, m.%"fu" group "_5"%, m.%"fu" group "_7"%]
    if (group != 3)
        return parts
    for p in parts
        if Trim(p) != ""
            return parts
    return DefaultFu3Parts()
}

; The fallback FU3, as one part per line. Stored in mass_gui.cfg with `n for a
; line break — an ini has no other way to hold one — which is the same escape the
; branch fields use, so MASS_SplitParts already knows how to read it.
;
; Read per call rather than cached, so an edit in Settings applies without
; restarting the model scripts — the same trade sndFu makes for FuSingle.
DefaultFu3Parts() {
    if !FEAT("defaultFu3")
        return ["", "", ""]
    return MASS_SplitParts(IniRead(MMA_CFG, "Settings", "DefaultFu3", ""))
}

; Does this model/group join its parts into ONE message?
;
; FuSingle_<model>_<group>. The model number must be the one whose key was
; pressed — read from the wrong one and IniRead just returns its default, so the
; setting appears to do nothing and nothing says why.
MASS_FuSingle(modelNo, group) {
    return IniRead(MMA_CFG, "Settings", "FuSingle_" modelNo "_" group, "0") = "1"
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The transcript — every message a mass produces, in order
; ───────────────────────────────────────────────────────────────────────────────
;  The whole point of this file, and the thing the chat simulator draws.
;
;  A BEAT is one key press. A beat holds the MESSAGES that press produces, which
;  is not one-to-one and is exactly the part nobody can hold in their head:
;
;      !mm    one message, PASTED — no Enter. It sits in the box for you to read
;             before you send it, which is why the opener is the one you edit in
;             the chat rather than in the GUI.
;      f1-f3  up to three parts, sent as three messages — or joined into ONE with
;             line breaks when FuSingle_<model>_<group> is set. f3 falls back to
;             the DefaultFu3 text when the mass has none.
;      PPV    the blurb, PASTED like the opener; then its three follow-ups, sent.
;
;  `branchNo` is which alternative to walk: 0 for the trunk, else the index into
;  BranchList. A branch that has nothing in a group falls back to the trunk's
;  wording for that group, which is what actually happens at send time — TAB
;  staging skips a group the branch does not answer (see AltVariants), so the
;  trunk's is what goes out.
;
;  Returns [{ key, label, kind, messages, note }]:
;      key       "mass" | "fu1" | "fu2" | "fu3" | "ppv" | "ppvfus"
;      label     what the key is called on the keyboard side ("!mm", "F1", …)
;      kind      "paste" (lands in the box, no Enter) or "send" (goes out)
;      messages  [{ text, fields }] — fields names the record fields it came
;                from, so the editor can jump to them
;      note      why this beat looks the way it does, or "" — the FuSingle join,
;                the DefaultFu3 fallback, the branch that had no wording here
; ═══════════════════════════════════════════════════════════════════════════════

MASS_Transcript(m, modelNo := 1, branchNo := 0) {
    branches := BranchList(m)
    onBranch := (branchNo >= 1 && branchNo <= branches.Length)
    br       := onBranch ? branches[branchNo] : 0
    out      := []

    ; ── the opener ────────────────────────────────────────────────────────────
    out.Push({ key: "mass", label: "!mm", kind: "paste",
               messages: (Trim(m.mass) = "")
                            ? []
                            : [{ text: m.mass, fields: ["mass"] }],
               note: "pasted into the box — no Enter, so you read it before it goes" })

    ; ── the three follow-up groups ────────────────────────────────────────────
    Loop 3 {
        g     := A_Index
        note  := ""
        parts := []
        srcs  := []

        if (onBranch && br.fu[g].Length) {
            for _, p in br.fu[g] {
                parts.Push(p)
                srcs.Push("br" branchNo "_fu" g)
            }
            note := "branch " Chr(0x201C) br.name Chr(0x201D)
        } else {
            if onBranch
                note := "branch " Chr(0x201C) br.name Chr(0x201D) " has no f" g
                      . " — the trunk's wording goes out"
            raw := MASS_FuParts(m, g)
            for i, p in raw {
                if (Trim(p) = "")
                    continue
                parts.Push(Trim(p))
                srcs.Push("fu" g (i = 1 ? "" : (i = 2 ? "_5" : "_7")))
            }
            ; Said only when it actually happened: a mass with its own f3 must not
            ; be labelled as falling back to one.
            if (g = 3 && parts.Length && _MASS_GroupEmpty(m, 3))
                note := "the mass has no f3 — this is the DefaultFu3 text from Settings"
        }

        msgs := []
        if parts.Length {
            if MASS_FuSingle(modelNo, g) {
                joined := ""
                for _, p in parts
                    joined .= (joined = "" ? "" : "`n") p
                msgs.Push({ text: joined, fields: srcs })
                note := (note = "" ? "" : note "   ·   ")
                      . parts.Length " part(s) joined into ONE message"
                      . " (FuSingle_" modelNo "_" g ")"
            } else {
                for i, p in parts
                    msgs.Push({ text: p, fields: [srcs[i]] })
            }
        }
        out.Push({ key: "fu" g, label: "F" g, kind: "send",
                   messages: msgs, note: note })
    }

    ; ── the PPV ───────────────────────────────────────────────────────────────
    ppvTxt := (onBranch && Trim(br.ppv) != "") ? Trim(br.ppv) : Trim(m.ppv_base)
    ppvFld := (onBranch && Trim(br.ppv) != "") ? "br" branchNo "_ppv" : "ppv_base"
    out.Push({ key: "ppv", label: "PPV", kind: "paste",
               messages: (ppvTxt = "") ? [] : [{ text: ppvTxt, fields: [ppvFld] }],
               note: "pasted like the opener — the blurb you attach the media to" })

    msgs := []
    for i, p in [m.ppv_f1, m.ppv_f2, m.ppv_f3]
        if (Trim(p) != "")
            msgs.Push({ text: Trim(p), fields: ["ppv_f" i] })
    out.Push({ key: "ppvfus", label: "PPV f/u", kind: "send",
               messages: msgs, note: "" })

    return out
}

; Has this mass nothing of its own in a follow-up group? The question
; MASS_FuParts asks before it reaches for DefaultFu3, asked again here so the
; transcript can SAY that is what happened rather than showing text with no
; explanation of where it came from.
_MASS_GroupEmpty(m, group) {
    for _, sfx in ["", "_5", "_7"]
        if (Trim(m.%"fu" group sfx%) != "")
            return false
    return true
}

; How many messages a whole transcript sends, and how many it merely pastes.
; The two numbers the simulator puts at the top, because "this mass is eleven
; messages" is the thing you cannot see from a grid of edit boxes.
MASS_TranscriptCounts(beats) {
    sent := 0, pasted := 0, chars := 0
    for _, b in beats
        for _, msg in b.messages {
            chars += StrLen(msg.text)
            if (b.kind = "paste")
                pasted++
            else
                sent++
        }
    return { sent: sent, pasted: pasted, chars: chars }
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Where the next message goes
; ───────────────────────────────────────────────────────────────────────────────
;  MASS_Transcript answers "what does this mass send". This answers the question
;  the chat simulator's composer asks, which is the other direction: "I have just
;  typed a message — which field does it belong in?"
;
;  A mass has fourteen writable places and they are ORDERED, which is the only
;  reason a composer can work at all: the opener, then three parts each for f1,
;  f2 and f3, then the PPV blurb and its three follow-ups. Type, send, and it
;  lands in the next empty one — the same way you would actually write the
;  conversation.
;
;  ─── A BRANCH IS SHAPED DIFFERENTLY, AND PRETENDING OTHERWISE WOULD LIE ──────
;  The trunk keeps its three parts in three FIELDS (fu1, fu1_5, fu1_7). A branch
;  keeps all of its parts in ONE field, newline-separated (br<n>_fu1), because
;  that is the record shape — see MASS_BranchFields in store.ahk. So a branch
;  slot appends a LINE where a trunk slot fills a FIELD, and `mode` says which.
;
;  A branch also has no opener and no PPV follow-ups of its own. Those slots stay
;  pointed at the trunk's fields, and say so in their label, because the
;  alternative is a composer that silently writes nothing.
;
;  Each slot is { id, field, beat, label, kind, mode }:
;      id     what the page sends back to name this slot
;      field  the record field it writes
;      beat   which press sends it — the transcript beat it belongs to
;      label  what the composer calls it
;      kind   "paste" or "send", the same distinction the transcript draws
;      mode   "field" (this slot IS the message) | "line" (append one line)
; ═══════════════════════════════════════════════════════════════════════════════

MASS_WriteSlots(m, branchNo := 0) {
    branches := BranchList(m)
    onBranch := (branchNo >= 1 && branchNo <= branches.Length)
    bn       := onBranch ? branches[branchNo].name : ""
    out      := []

    _add(id, field, beat, label, kind, mode) {
        out.Push({ id: id, field: field, beat: beat, label: label,
                   kind: kind, mode: mode })
    }

    ; The opener. A branch has none of its own, so on a branch this is still the
    ; trunk's — labelled, so it does not look like it belongs to the branch.
    _add("mass", "mass", "mass",
         onBranch ? "Opener (shared with the trunk)" : "Opener",
         "paste", "field")

    Loop 3 {
        g := A_Index
        if onBranch {
            _add("fu" g, "br" branchNo "_fu" g, "fu" g,
                 "F" g "  " Chr(0x00B7) "  " bn, "send", "line")
        } else {
            _add("fu" g,      "fu" g,        "fu" g, "F" g "  part 1", "send", "field")
            _add("fu" g "_5", "fu" g "_5",   "fu" g, "F" g "  part 2", "send", "field")
            _add("fu" g "_7", "fu" g "_7",   "fu" g, "F" g "  part 3", "send", "field")
        }
    }

    if onBranch
        _add("ppv", "br" branchNo "_ppv", "ppv",
             "PPV blurb  " Chr(0x00B7) "  " bn, "paste", "field")
    else
        _add("ppv", "ppv_base", "ppv", "PPV blurb", "paste", "field")

    Loop 3
        _add("ppv_f" A_Index, "ppv_f" A_Index, "ppvfus",
             (onBranch ? "PPV f/u " A_Index " (shared)" : "PPV f/u " A_Index),
             "send", "field")

    return out
}

; The first slot with nothing in it, or 0 when the mass is full.
;
; "Empty" for a `line` slot means the whole field is blank — a branch group you
; have not written yet. Once it has a line, the composer appends rather than
; moving on, which is what makes writing a branch's three parts feel the same as
; writing the trunk's.
MASS_NextEmptySlot(m, branchNo := 0) {
    for _, s in MASS_WriteSlots(m, branchNo)
        if (Trim(m.HasOwnProp(s.field) ? m.%s.field% : "") = "")
            return s
    return 0
}

; Write `text` into a slot, returning the field's new value.
;
; The two modes differ only here, which is the point of carrying `mode` at all: a
; trunk slot is replaced, a branch slot gains a line. Neither trims the text —
; leading spaces in a message are the author's business.
MASS_SlotWrite(current, text, mode) {
    if (mode != "line")
        return text
    cur := RTrim(StrReplace(StrReplace(current, "`r`n", "`n"), "`r", "`n"), "`n")
    return (Trim(cur) = "") ? text : cur "`n" text
}
