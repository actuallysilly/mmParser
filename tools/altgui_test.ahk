#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  altgui_test.ahk — the alt-FU picker window, without Infloww and without a mass.
; ───────────────────────────────────────────────────────────────────────────────
;  Two halves:
;
;    the pure part   AltGuiHead / AltGuiBody / the TAB and Shift+TAB walk. Runs
;                    with no window and no keys, so it can be checked from a
;                    terminal. Prints PASS/FAIL and exits.
;    the eyes part   pass `show` and it stages fabricated variants for real, so
;                    the window can be looked at. TAB walks it, Esc closes.
;
;  READ-ONLY on the config. It reads AltGuiWidth / AltGuiLift / AltStageNoGui and
;  writes nothing — no snapshot-and-restore needed, unlike the model tests, which
;  is deliberate: a test that has to put your settings back is a test that can
;  fail to. Nothing here calls AltStageCommit, so nothing can send.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/core/utils.ahk"

; `try`, because "*" is stdout and there ISN'T one when this is double-clicked or
; launched without a redirect — FileAppend then throws "the handle is invalid" and
; kills the run before it has done anything, which looks exactly like the window
; failing to appear.
Out(s) {
    try FileAppend(s "`n", "*")
}

pass := 0, fail := 0
Ck(name, got, want) {
    global pass, fail
    if (String(got) == String(want))
        pass++
    else
        fail++, Out("FAIL " name ":`n  got  <" got ">`n  want <" want ">")
}

; Three variants, the shape AltVariants() hands over: main, an alt, and a branch.
V := [{parts: ["hey babe did you see what i sent you earlier?", "let me know x"],
       label: "main",  branch: 0},
      {parts: ["still thinking about you", "", "  can't stop  "],
       label: "alt 1", branch: 0},
      {parts: ["so what did you think of it?"],
       label: "Curious", branch: 2}]

if (A_Args.Length && StrLower(A_Args[1]) = "show") {
    ; A stand-in for the chat window, activated FIRST so AltStageBegin anchors to
    ; it. Not cosmetic: the staging scopes Tab, Enter and Escape to the window it
    ; began in, and without this that is whatever you happened to be typing in when
    ; you ran the test — this file would hijack your Enter key in someone else's
    ; app. Anchoring to our own window means the hijack lands where it belongs.
    demo := Gui("+AlwaysOnTop", "MMA alt picker — test chat")
    demo.BackColor := "0F0E14"
    demo.SetFont("s10 c6F6A85", "Segoe UI")
    demo.Add("Text", "x20 y20 w860", "stand-in for the Infloww chat window."
                                   . "`n`nthe picker sits above where the composer"
                                   . " would be — TAB / SHIFT+TAB walk it, ESC closes.")
    demo.Show("x100 y100 w900 h700")
    WinWaitActive("ahk_id " demo.Hwnd, , 3)
    Out("staging 3 variants — TAB / SHIFT+TAB to walk, ESC to close")
    ; Nothing here calls AltStageCommit, so Enter cannot send anything.
    AltStageBegin(2, V, false, 1)
    ; Optional second arg: walk N steps on a timer. Calls the handler directly
    ; rather than sending {Tab}, so checking the repaint does not fire a keystroke
    ; at whatever else is open on the machine.
    if (A_Args.Length > 1)
        SetTimer(AutoWalk.Bind(Integer(A_Args[2])), -1200)
    ; Geometry, into the log. A picker whose last row is cut off by the window edge
    ; is the one rendering fault that matters — TAB wraps onto a variant you cannot
    ; see and Enter sends it — and it is invisible in a screenshot of the top half.
    DumpGeometry()
    Persistent
    return

    DumpGeometry() {
        global _altGui, _altGuiRows
        if !_altGui
            return
        _altGui.GetPos(, , &gw, &gh)
        LOGD("alt.test", "window " gw "x" gh)
        for i, row in _altGuiRows {
            row.head.GetPos(, &hy, , &hh)
            row.body.GetPos(, &by, , &bh)
            LOGD("alt.test", "row " i ": head y=" hy " h=" hh
                           . "   body y=" by " h=" bh "  bottom=" (by + bh))
        }
    }

    AutoWalk(n, *) {
        Loop n
            AltStageNext()
        Out("walked " n " — marker on " _altStaged)
    }
}

; ── the label line ────────────────────────────────────────────────────────────
global _altStaged := 1
Ck("head: marked",   AltGuiHead(1, V[1]), Chr(0x25B8) "  1.  main")
Ck("head: unmarked", AltGuiHead(2, V[2]), " " "  2.  alt 1")
Ck("head: branch says what picking it does",
   AltGuiHead(3, V[3]), " " "  3.  Curious      (branch — f2 and f3 will open here)")

; ── the body ──────────────────────────────────────────────────────────────────
; One part per line, blanks dropped, each part trimmed — a variant arrives as
; separate messages and the window should show it that way.
Ck("body: one line per part",
   AltGuiBody(V[1]), "hey babe did you see what i sent you earlier?`nlet me know x")
Ck("body: empty parts are not blank lines",
   AltGuiBody(V[2]), "still thinking about you`ncan't stop")
Ck("body: nothing at all still renders", AltGuiBody({parts: ["", "  "]}), "(empty)")

; A mass field with an essay in it must not push the window off the screen.
long := ""
Loop 100
    long .= "wordy "
Ck("body: capped", StrLen(AltGuiBody({parts: [long]})), ALT_GUI_MAXCHARS + 2)

; ── the walk ──────────────────────────────────────────────────────────────────
; Both directions wrap, so the list has no ends to get stuck against. Driven
; through the real handlers with the GUI absent (_altGui stays 0, so AltGuiRepaint
; returns immediately and AltPaintStage has nothing to draw).
global _altVariants := V, _altGui := 0, _altInBox := false
Walk(fn, times) {
    global _altStaged
    Loop times
        fn()
    return _altStaged
}
_altStaged := 1
Ck("TAB 1→2", Walk(AltStageNext, 1), 2)
Ck("TAB to the end and round", Walk(AltStageNext, 2), 1)
_altStaged := 1
Ck("SHIFT+TAB wraps backwards", Walk(AltStagePrev, 1), 3)
Ck("SHIFT+TAB 3→2", Walk(AltStagePrev, 1), 2)

; ── the fallback toggle ───────────────────────────────────────────────────────
; Reads the live cfg, so assert only that it answers a boolean rather than
; throwing — the value depends on the checkbox in Settings.
Ck("AltStageUseGui answers yes or no",
   (AltStageUseGui() = true || AltStageUseGui() = false), 1)

Out((fail ? "FAILED " fail " of " (pass + fail) : "all " pass " passed"))
ExitApp(fail ? 1 : 0)
