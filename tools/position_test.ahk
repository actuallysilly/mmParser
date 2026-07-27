#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  position_test.ahk — taught-position matching, which decides whose fan gets
;  whose message.
; ───────────────────────────────────────────────────────────────────────────────
;  Positional mode used to count tabs and answer "model 1" for every tab forever,
;  because it could not count them and said 1 anyway. The replacement matches the
;  lit pill's x against positions you taught it. The interesting cases are all at
;  the edges: a pill exactly between two taught tabs, a pill nowhere near any of
;  them, and nothing taught at all — each of which must return 0, "no answer",
;  rather than the nearest guess.
;
;  Writes to the REAL mass_gui.cfg and detector_status.ini, restoring both at the
;  end, because the ini round trip is the thing under test.
;
;  Prints to stdout. Exit 0 = all passed.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/core/active_model.ahk"

Out(s) => FileAppend(s "`n", "*")
OnError(Err)
Err(e, mode) {
    Out("ERROR: " e.Message " | " (e.HasProp("Extra") ? e.Extra : "") " @ " e.File ":" e.Line)
    Restore()
    ExitApp(1)
}

pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ": got <" got "> want <" want ">")
}

; ── save whatever the user really has ────────────────────────────────────────
_savedMode := IniRead(MMA_CFG, "Settings", "ModelMatch", "name")
_savedX    := []
Loop MASS_MODELS
    _savedX.Push(IniRead(MMA_CFG, "Positional", "X" A_Index, ""))
_savedAX := IniRead(MMA_DETECTOR, "detector", "active_x", "")

Restore() {
    global _savedMode, _savedX, _savedAX
    try IniWrite(_savedMode, MMA_CFG, "Settings", "ModelMatch")
    ; Braces are load-bearing: `if X` / `try …` / `else` does not parse in AHK v2 —
    ; the try swallows the statement and the else has nothing to attach to.
    Loop MASS_MODELS {
        if (_savedX[A_Index] = "") {
            try IniDelete(MMA_CFG, "Positional", "X" A_Index)
        } else {
            try IniWrite(_savedX[A_Index], MMA_CFG, "Positional", "X" A_Index)
        }
    }
    if (_savedAX = "") {
        try IniDelete(MMA_DETECTOR, "detector", "active_x")
    } else {
        try IniWrite(_savedAX, MMA_DETECTOR, "detector", "active_x")
    }
}

Forget() {
    Loop MASS_MODELS
        try IniDelete(MMA_CFG, "Positional", "X" A_Index)
}
SetX(x) => IniWrite(x, MMA_DETECTOR, "detector", "active_x")

IniWrite("position", MMA_CFG, "Settings", "ModelMatch")

; ── nothing taught ───────────────────────────────────────────────────────────
Forget()
Ck("no positions -> AnyLearned false", AnyLearnedPositions(), 0)
Ck("no positions -> match 0",          PositionalSlotByX(200), 0)
Ck("LearnedSlotX untaught = -1",       LearnedSlotX(1), -1)

; ── two models, 150px apart (the measured Infloww model-tab pitch) ───────────
LearnSlotX(1, 105)
LearnSlotX(2, 255)
Ck("taught 1", LearnedSlotX(1), 105)
Ck("taught 2", LearnedSlotX(2), 255)
Ck("tol = half the gap", PositionTol(), 75)

Ck("dead on 1",        PositionalSlotByX(105), 1)
Ck("dead on 2",        PositionalSlotByX(255), 2)
Ck("near 1",           PositionalSlotByX(120), 1)
Ck("near 2",           PositionalSlotByX(240), 2)
; 105 and 255 taught, so 180 is the exact midpoint: refused, and either side of
; it stays refused until one tab is a clear 15px nearer than the other.
Ck("midpoint refused", PositionalSlotByX(180), 0)
Ck("just inside 1",    PositionalSlotByX(170), 1)
Ck("just inside 2",    PositionalSlotByX(190), 2)
Ck("7px off midpoint still refused", PositionalSlotByX(187), 0)
; The whole point of a tolerance: a pill far from anything taught is NOT the
; nearest taught tab, it is an unknown. Guessing here sends model 1's message to
; model 2's fan, which is the bug this file exists to prevent.
Ck("far left  -> none", PositionalSlotByX(10),  0)
Ck("far right -> none", PositionalSlotByX(400), 0)
Ck("no pill   -> none", PositionalSlotByX(-1),  0)

; ── resolution end to end, through the inis ──────────────────────────────────
SetX(255)
st := ActiveModelStatus()
Ck("resolve x255 .no",    st.no, 2)
Ck("resolve x255 .state", st.state, "ok")

SetX(105)
Ck("resolve x105", ActiveModelStatus().no, 1)

SetX(400)
st := ActiveModelStatus()
Ck("stray pill .no",    st.no, 0)
Ck("stray pill .state", st.state, "unknown")

SetX(-1)
st := ActiveModelStatus()
Ck("no pill .no",    st.no, 0)
Ck("no pill .state", st.state, "none")

; nothing taught, pill on screen -> the one state a message can fix
Forget()
SetX(200)
st := ActiveModelStatus()
Ck("unlearned .no",    st.no, 0)
Ck("unlearned .state", st.state, "unlearned")

; ── tight tabs: the tolerance must shrink with them ──────────────────────────
Forget()
LearnSlotX(1, 100)
LearnSlotX(2, 140)
Ck("tight tol", PositionTol(), 20)
Ck("tight: on 1",   PositionalSlotByX(100), 1)
Ck("tight: on 2",   PositionalSlotByX(140), 2)
; Equidistant from both taught tabs. Answering either would be a coin flip
; between two people's fans, so the answer is "I do not know".
Ck("tight: midway", PositionalSlotByX(120), 0)
Ck("tight: beyond", PositionalSlotByX(170), 0)

; ── one model taught, the other not ──────────────────────────────────────────
Forget()
LearnSlotX(2, 255)
Ck("single tol default", PositionTol(), 60)
Ck("single: on it",      PositionalSlotByX(255), 2)
Ck("single: near",       PositionalSlotByX(300), 2)
Ck("single: far",        PositionalSlotByX(400), 0)
Ck("single: model 1 never matches", PositionalSlotByX(105), 0)

; ── refuses nonsense ─────────────────────────────────────────────────────────
Ck("learn slot 0 refused",  LearnSlotX(0, 100), 0)
Ck("learn slot 99 refused", LearnSlotX(99, 100), 0)
Ck("learn x -1 refused",    LearnSlotX(1, -1), 0)
Ck("still untaught after refusals", LearnedSlotX(1), -1)

Restore()
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
