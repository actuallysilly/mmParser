#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  next_fu.ahk — one key that sends whichever follow-up comes next.
; ───────────────────────────────────────────────────────────────────────────────
;  Reads the conversation, finds the LAST follow-up already sent in it, and sends
;  the one after. So f1 → f2 → f3 is one button pressed three times instead of
;  three buttons you have to keep track of.
;
;  ─── WHY IT READS THE SCREEN INSTEAD OF REMEMBERING ──────────────────────────
;  The obvious implementation is for MMA to remember what it sent. It cannot, not
;  usefully: "which follow-up is next" is per FAN, and MMA has no fan identity —
;  it would need to OCR the chat header to get one, which is the same cost as
;  this and gives an answer that is still wrong after a restart, after you send
;  from your phone, or the first time you open a chat you were mid-way through.
;
;  The conversation already holds the answer. The follow-up text is known — it is
;  in masses.json, MMA wrote it — so finding it is a substring search, not
;  recognition. Reading it back means:
;
;    • per chat for free. You are looking at the chat; there is nothing to key.
;    • per model for free. Matching is against THAT model's follow-ups, so the
;      same key does the right thing on either model's tab.
;    • correct after a restart, and correct in a chat MMA never sent in.
;
;  ─── WHAT IT REFUSES TO DO ───────────────────────────────────────────────────
;  Nothing found → sends f1, because an empty conversation genuinely starts there.
;  f3 found      → sends NOTHING. There is no f4, and wrapping back to f1 would
;                  re-send a message this fan has already had. Every refusal in
;                  this codebase is the same trade: a key that does nothing costs
;                  a keypress, a key that guesses costs a real message to a real
;                  person.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../vendor/OCR.ahk"

; ── tunables ──────────────────────────────────────────────────────────────────
; The conversation pane, in SCREEN coordinates. Default is automation.py's
; R_MESSAGES, the same measured rectangle its unsend flow reads, so the two agree
; about where the messages are.
NFU_Cfg() {
    return {
        x:     _IniInt(MMA_CFG, "NextFu", "RegionX", 401),
        y:     _IniInt(MMA_CFG, "NextFu", "RegionY", 135),
        w:     _IniInt(MMA_CFG, "NextFu", "RegionW", 1237),
        h:     _IniInt(MMA_CFG, "NextFu", "RegionH", 727),
        scale: _IniInt(MMA_CFG, "NextFu", "Scale",   1),
        ; Shortest normalised needle worth trusting. Below this, a follow-up like
        ; "hey" would match half the conversation and pick a group at random.
        minNeedle: _IniInt(MMA_CFG, "NextFu", "MinNeedle", 12),
        ; How much of a message to match on. Long enough to be distinctive,
        ; short enough that one OCR slip does not sink it — and three slices are
        ; taken at different offsets, so a slip has to hit all three.
        needleLen: _IniInt(MMA_CFG, "NextFu", "NeedleLen", 24)}
}

; ── matching ──────────────────────────────────────────────────────────────────

; Everything that survives OCR reliably: letters and digits, folded to lower case.
;
; Spaces go too. OCR engines disagree about them constantly — RapidOCR drops them
; outright (see the notes on the unsend flow), Windows OCR inserts them inside
; words at line breaks — so any needle containing one is a coin flip. Punctuation
; and emoji go for the same reason. What is left still identifies a message: two
; different follow-ups do not share twenty-four consecutive letters by accident.
; RegExReplace, not a character loop with `c >= "a" && c <= "z"`. In AHK v2 the
; relational operators are NUMERIC — comparing two non-numeric strings with >=
; throws "Expected a Number but got a String", so that loop did not filter
; letters, it crashed on the first one. (Use StrCompare for ordering strings.)
; This is also the faster of the two on a pane's worth of OCR text.
NFU_Norm(s) {
    return RegExReplace(StrLower(s), "[^a-z0-9]", "")
}

; Up to three needles from one message part, taken at the start, middle and end.
;
; One needle would be enough if OCR were perfect. It is not, and a single mangled
; character inside a 24-character window silently turns "already sent" into "not
; sent" — which sends the fan the same follow-up twice. Three windows spread
; across the message means a slip has to land in all three to do that.
NFU_Needles(part, cfg) {
    n := NFU_Norm(part)
    if (StrLen(n) < cfg.minNeedle)
        return []                       ; too short to identify anything
    L := cfg.needleLen
    if (StrLen(n) <= L)
        return [n]
    mid  := ((StrLen(n) - L) // 2) + 1
    last := StrLen(n) - L + 1
    out  := [SubStr(n, 1, L)]
    if (mid > 1)
        out.Push(SubStr(n, mid, L))
    if (last > mid)
        out.Push(SubStr(n, last, L))
    return out
}

; Where in `hay` this group's text was last seen, or 0 for "not there".
;
; The LAST occurrence, not the first: a long thread can hold the same follow-up
; from a previous round, and what matters is the most recent one. InStr with a
; negative StartingPos searches backwards from the end.
NFU_GroupAt(m, group, hay, cfg) {
    best := 0
    for field in ["fu" group, "fu" group "_5", "fu" group "_7"] {
        part := m.%field%
        if (Trim(part) = "")
            continue
        for needle in NFU_Needles(part, cfg) {
            at := InStr(hay, needle, true, -1)
            if (at > best)
                best := at
        }
    }
    return best
}

; The highest-numbered follow-up present in the conversation, by POSITION.
;
; Position, not group number: what is wanted is the last one SENT, and the pane
; reads top to bottom, so furthest down is most recent. Taking the highest group
; number instead would get this wrong the moment you deliberately re-send an
; earlier follow-up — the thing this key exists to let you do.
;
; Returns {group: 0..3, at: position, hits: [pos,pos,pos]}. group 0 = none found.
NFU_LastGroup(m, hay, cfg) {
    hits := [], best := 0, bestAt := 0
    Loop 3 {
        at := NFU_GroupAt(m, A_Index, hay, cfg)
        hits.Push(at)
        if (at > bestAt)
            best := A_Index, bestAt := at
    }
    return {group: best, at: bestAt, hits: hits}
}

; ── reading the conversation ──────────────────────────────────────────────────

; OCR the pane to one string, or "" if it could not be read.
NFU_ReadChat(cfg := 0) {
    if !cfg
        cfg := NFU_Cfg()
    if (cfg.w < 8 || cfg.h < 8)
        return ""
    try {
        res := OCR.FromRect(cfg.x, cfg.y, cfg.w, cfg.h, {scale: cfg.scale})
        return res.Text
    } catch {
        return ""
    }
}

; ── the key ───────────────────────────────────────────────────────────────────
;  Bound like any other mass slot, so it inherits the model wiring for free:
;  _ModelFire sets the model for a per-model key, _ActiveFire resolves it from the
;  screen for the shared one. By the time this runs, CurMass() is the right mass.
DoNextFu() {
    cfg := NFU_Cfg()
    m   := CurMass()

    text := NFU_ReadChat(cfg)
    if (text = "") {
        _NextFuFail("Could not read the conversation."
                  . "`nCheck [NextFu] Region* in mass_gui.cfg, or run"
                  . " tools\nextfu_probe.ahk to see what it reads.")
        return
    }

    r := NFU_LastGroup(m, NFU_Norm(text), cfg)
    next := r.group + 1
    if (next > 3) {
        ; f3 is the end of the line. Wrapping to f1 would re-send a message this
        ; fan has already had, which is worse than doing nothing.
        SoundBeep(300, 250)
        _MassToast("Follow-up 3 is already the last one sent here."
                 . "`nNothing sent.")
        return
    }

    handlers := Map(1, DoFu1, 2, DoFu2, 3, DoFu3)
    _MassToast((r.group ? "Last seen: f" r.group : "No follow-up in this chat")
             . "  →  sending f" next)
    handlers[next]()
}

_NextFuFail(msg) {
    SoundBeep(300, 250)
    _MassToast(msg)
}
