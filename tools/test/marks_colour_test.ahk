#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  marks_colour_test.ahk — the colour helpers behind the bars AND the reply tiers.
;
;  These four functions decide what colour comes out, and every one of their
;  failure modes is SILENT: a wrong byte swap paints a plausible wrong colour, and
;  a hex parse that falls back to 0 paints black on a black strip, which reads as
;  "it disappeared". Neither throws, so neither shows up in a parse check or in
;  the log.
;
;  COLORREF is 0x00BBGGRR and a hex colour is RRGGBB, so the swap sits between the
;  cfg and comdlg32's ChooseColor in both directions. Its own inverse — which is
;  the property worth pinning, because a swap that is subtly not an involution
;  round-trips wrong only for colours where R and B differ.
;
;  ─── THE SWAP AND THE HEX PARSE MOVED ────────────────────────────────────────
;  They were _MARKS_SwapRB and _MARKS_HexVal. They are THEME_SwapRB and
;  THEME_HexVal in core/theme.ahk now, because the reply-timer tiers in
;  ui/settings_window.ahk open the same dialog and a second copy of a hand-packed
;  72-byte x64 struct is a second place to get the offsets wrong. Same arithmetic,
;  same coral fallback, twice the callers — so the assertions below are unchanged
;  apart from the names, and they now cover both features at once.
;
;  _MARKS_CleanHex stayed in tab_marks.ahk: it answers "" for a bad colour because
;  "" is a real state THERE ("this bar follows SepColor"), which is a different
;  question from "what integer do I hand the dialog".
;
;  Run it; it prints to stdout and exits 1 on any failure.
;
;  Do NOT /validate it. tab_marks.ahk also calls HK_Key and HK_Bind, and this file
;  deliberately does not pull in core/hotkeys.ahk: the colour helpers do not need
;  it, and dragging the hotkey registry into a unit test would mean the test binds
;  real keys.
;
;  ─── AND RUNNING IT NEEDED THE LINE BELOW ────────────────────────────────────
;  The header used to say running was the safe option. It was not, and the
;  difference is worth writing down: AHK raises "this local variable appears to
;  never be assigned a value" for HK_Key AT LOAD, before the first line of this
;  file executes, and `#Warn VarUnset` is ON BY DEFAULT in v2. So the unresolved
;  call produced a MODAL DIALOG on a run exactly as it does on a /validate — and
;  with no console attached, a modal dialog is indistinguishable from the runner
;  hanging: no output, no exit, nothing on stderr.
;
;  Sending warnings to stdout instead is the same fix settings_build_test.ahk
;  makes at its own top, for the same reason. VarUnset rather than All, so the
;  include chain's ordinary local-shadows-global noise stays out of the output.
; ═══════════════════════════════════════════════════════════════════════════════

#Warn VarUnset, StdOut

#Include "../../src/core/paths.ahk"
; theme.ahk explicitly, for the two functions that moved there. In the app it
; arrives through mass/runtime.ahk → core/utils.ahk, but this test deliberately
; includes neither — a file that names a function includes the file that defines
; it, and without this the run dies on "THEME_SwapRB not found".
#Include "../../src/core/theme.ahk"
#Include "../../src/screen/tab_marks.ahk"

pass := 0, fail := 0

Out(s) {
    FileAppend s "`n", "*"
}

Check(name, got, want) {
    global pass, fail
    if (got == want) {
        pass++
        return
    }
    fail++
    Out("FAIL  " name)
    Out("      want: " want)
    Out("      got:  " String(got))
}

; ── _MARKS_CleanHex ───────────────────────────────────────────────────────────
Check("plain hex",        _MARKS_CleanHex("4AC9FF"),  "4AC9FF")
Check("lowercase folds",  _MARKS_CleanHex("4ac9ff"),  "4AC9FF")
Check("leading #",        _MARKS_CleanHex("#4ac9ff"), "4AC9FF")
Check("surrounding ws",   _MARKS_CleanHex("  FF6B7A "), "FF6B7A")
; "" is a REAL value — it means "this bar has no colour of its own and follows
; SepColor" — so every reject has to land on it rather than on a default colour.
Check("empty stays empty", _MARKS_CleanHex(""),        "")
Check("three digits",      _MARKS_CleanHex("FFF"),     "")
Check("eight digits",      _MARKS_CleanHex("FF6B7A00"), "")
Check("not hex",           _MARKS_CleanHex("coral"),   "")
Check("nearly hex",        _MARKS_CleanHex("GG6B7A"),  "")

; ── THEME_SwapRB ─────────────────────────────────────────────────────────────
Check("swap red->blue",  Format("{:06X}", THEME_SwapRB(0xFF0000)), "0000FF")
Check("swap blue->red",  Format("{:06X}", THEME_SwapRB(0x0000FF)), "FF0000")
Check("green is fixed",  Format("{:06X}", THEME_SwapRB(0x00FF00)), "00FF00")
Check("mixed",           Format("{:06X}", THEME_SwapRB(0x4AC9FF)), "FFC94A")
Check("black",           Format("{:06X}", THEME_SwapRB(0x000000)), "000000")
Check("white",           Format("{:06X}", THEME_SwapRB(0xFFFFFF)), "FFFFFF")

; The involution. This is the one that catches a swap written with the shifts
; subtly wrong: it round-trips symmetric colours correctly and only breaks where
; R and B differ, so testing one direction on grey would have passed.
for _, v in [0xFF6B7A, 0x4AC9FF, 0x5BD98A, 0xFFC94A, 0xC08BFF, 0x010203] {
    Check("swap is its own inverse " Format("{:06X}", v),
          Format("{:06X}", THEME_SwapRB(THEME_SwapRB(v))), Format("{:06X}", v))
}

; ── THEME_HexVal ─────────────────────────────────────────────────────────────
Check("value of hex",    THEME_HexVal("4AC9FF"),  0x4AC9FF)
Check("value with #",    THEME_HexVal("#4AC9FF"), 0x4AC9FF)
; Junk falls back to the coral default, NOT to 0. Zero is black, and a black bar on
; Infloww's dark strip is invisible — the user would report the bar as missing.
Check("junk -> default", THEME_HexVal("nope"),    0xFF6B7A)
Check("empty -> default", THEME_HexVal(""),       0xFF6B7A)

; ── the whole round trip, cfg text -> COLORREF -> cfg text ────────────────────
; What actually happens when you open Custom… on a bar and press OK without
; touching anything: the stored hex goes in as a COLORREF and has to come back out
; identical, or the dialog would silently shift the colour every time it was opened.
for _, hex in ["FF6B7A", "4AC9FF", "010203", "FFFFFF", "000000"] {
    Check("cfg round trip " hex,
          Format("{:06X}", THEME_SwapRB(THEME_SwapRB(THEME_HexVal(hex)))), hex)
}

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
