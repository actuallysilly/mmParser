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
;  nothing found, mass visible   → sends f1. The sequence genuinely starts here.
;  nothing found, no mass either → sends NOTHING. Either the pane is scrolled away
;                  from a thread that IS underway, or the mass never went to this
;                  chat at all; both look identical to a substring search, and f1
;                  is wrong in both. See NFU_MassPresence.
;  last one found → sends NOTHING. There is no f4, and wrapping back to f1 would
;                  re-send a message this fan has already had.
;
;  Every refusal here is the same trade: a key that does nothing costs a keypress,
;  a key that guesses costs a real message to a real person.
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
    ; _FuParts, not the three stored fields.
    ;
    ; They are the same thing for groups 1 and 2, and NOT for group 3: a mass with
    ; no f3 of its own sends the Default FU3 text from Settings instead (see
    ; _FuParts in runtime.ahk). So the message that lands in the conversation is
    ; the default — and matching the stored fields, which are blank, meant the
    ; walker could never find its own f3.
    ;
    ; The result was the exact failure this whole file is built to avoid. On such
    ; a mass: press 3 sends the default, press 4 still reads f2 as the last one
    ; sent and sends the default AGAIN, to a fan who has already had it. Match
    ; what will actually be SENT, not what happens to be stored.
    for part in _FuParts(m, group) {
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

; Is the mass itself — the opening message every follow-up follows up ON — in what
; we just read? "seen", "absent", or "uncheckable" when there is no mass text long
; enough to identify.
;
; This is the gate on f1, and it exists because "no follow-up found" has two very
; different causes that look identical to a substring search:
;
;   the sequence has not started  — the mass is there, no follow-up yet. Send f1.
;   we cannot see the sequence    — scrolled up, or a chat the mass never went to.
;                                   Sending f1 here either repeats a follow-up
;                                   that IS in the thread just out of view, or
;                                   opens with "did you see what I sent?" to
;                                   someone who was sent nothing.
;
; The mass is the evidence that tells them apart, so f1 waits for it. Matched with
; the same needles as the follow-ups, so a long mass whose top has scrolled off
; still registers on its middle or tail.
NFU_MassPresence(m, hay, cfg) {
    needles := NFU_Needles(m.mass, cfg)
    if !needles.Length
        return "uncheckable"
    for needle in needles
        if InStr(hay, needle, true)
            return "seen"
    return "absent"
}

; The next group AFTER this one that actually has something to send, or 0.
;
; Not simply group + 1. A mass is not required to carry all three follow-ups —
; plenty are f1 only, and f1 + f3 with a gap in the middle is just as legitimate.
; So "next" means the next follow-up THAT EXISTS, which is what the key promises.
;
; Counting blindly broke both ends of that. On an f1-only mass, press two resolved
; to f2, and sndFu returns silently when every part is empty — so the key did
; nothing at all while the toast said "sending f2". A key that lies about having
; sent is worse than one that refuses, because you believe it and move on.
NFU_NextWithContent(m, after) {
    g := after
    while (++g <= 3)
        for part in _FuParts(m, g)
            if (Trim(part) != "")
                return g
    return 0
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

    hay := NFU_Norm(text)
    r   := NFU_LastGroup(m, hay, cfg)

    ; Starting the sequence is the one move that needs corroboration. Once a
    ; follow-up is on screen the thread speaks for itself; before that, the mass
    ; being visible is the only thing separating "not started yet" from "cannot
    ; see it from here". Refuse rather than guess — the numbered f1 key is right
    ; there when you know better than MMA does.
    if (r.group = 0) {
        seen := NFU_MassPresence(m, hay, cfg)
        if (seen != "seen") {
            SoundBeep(300, 250)
            _MassToast(seen = "absent"
                ? "No follow-up here, and the mass is not on screen either."
                  . "`nScroll to it, or send f1 by hand if this chat is right."
                : "This model has no mass text stored, so there is nothing to"
                  . " check f1 against.`nSend it by hand.")
            return
        }
    }

    next := NFU_NextWithContent(m, r.group)
    if !next {
        ; The end of the line — either the last follow-up this mass HAS is already
        ; in the chat, or the mass has none at all. Wrapping back to f1 would
        ; re-send a message this fan has already had, which is worse than doing
        ; nothing. Say which of the two it is, or the beep is just a mystery.
        SoundBeep(300, 250)
        _MassToast(r.group
            ? "f" r.group " is the last follow-up this mass has,"
              . " and it is already in this chat.`nNothing sent."
            : "This mass has no follow-ups to send.`nNothing sent.")
        return
    }

    handlers := Map(1, DoFu1, 2, DoFu2, 3, DoFu3)
    ; Name the gap when there is one, so skipping f2 on a mass that has no f2
    ; reads as a decision rather than as the key losing count.
    _MassToast((r.group ? "Last seen: f" r.group : "No follow-up in this chat")
             . "  →  sending f" next
             . ((next > r.group + 1) ? "   (this mass has no f" (r.group + 1) ")" : ""))
    handlers[next]()
}

_NextFuFail(msg) {
    SoundBeep(300, 250)
    _MassToast(msg)
}
