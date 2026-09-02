#Requires AutoHotkey v2.0
; #Warn VarUnset, StdOut — REQUIRED. settings_core.ahk is included by windows that
; assign globals it reads, so pulling it in from a bare script raises a warning,
; and a warning is a MODAL DIALOG even under /ErrorStdOut. The run then hangs with
; no output, which reads exactly like the test passing slowly. Same reasoning as
; services_test.ahk, which says it at more length.
#Warn VarUnset, StdOut
; ═══════════════════════════════════════════════════════════════════════════════
;  settings_parity_test.ahk — the two Settings windows offer the same settings.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA has two Settings front ends and they are NOT two views of one thing:
;
;      ui\settings_webview.ahk   Edge, its own process — the DEFAULT
;      ui\settings_window.ahk    a Win32 Gui inside the main window — "legacy"
;
;  They share ui\settings_core.ahk, and since the field table moved there they
;  share the one description of what a setting IS: its cfg home, its type, its
;  default, its wording. What they do NOT share is the drawing. The WebView page
;  renders SETTINGS_Fields() directly, so a new row appears there for free; the
;  Win32 window hand-builds a control per setting, so a new row appears there
;  only if somebody remembers.
;
;  That is the drift this file exists to catch, and it is worth catching because
;  of WHICH window loses. WebView is the default, so a setting added only to the
;  table works for everybody who never changed the shell — and is invisible to
;  everybody who did. Nothing errors. The key simply keeps its default, on a
;  machine whose owner is looking at a Settings window that does not mention it.
;
;  ─── WHY THIS READS SOURCE INSTEAD OF BUILDING THE WINDOW ────────────────────
;  Because building it cannot answer the question. settings_build_test.ahk does
;  build the Win32 window — that is its job, and it proves the layout code runs —
;  but a built Gui is a bag of controls with no way to ask "which setting is this
;  one for". The link between a control and its cfg key exists only in the source,
;  in the IniRead/IniWrite that reads or writes it. So that is what is checked.
;
;  It is a lint, and it is honest about what a lint can prove: that the key is
;  NAMED in the file. A control that is named but never drawn would pass. That
;  still catches the failure that actually happens — a row added to the table and
;  nowhere else — and it costs no GUI, so it runs in the Debug tab's "Run all"
;  alongside everything else rather than only when somebody remembers.
;
;  Prints to stdout. Exit 0 = the two windows agree.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../../src/core/paths.ahk"
#Include "../../src/core/modes.ahk"
#Include "../../src/mass/store.ahk"
; theme.ahk and credit.ahk for real, not stubbed: the Theme and Corner-picture
; rows call THEME_List and CREDIT_AssetList to build their option lists, so the
; table cannot be read without them. settings_build_test.ahk includes credit.ahk
; for the same reason.
#Include "../../src/core/theme.ahk"
#Include "../../src/ui/credit.ahk"
#Include "../../src/ui/settings_core.ahk"

; `try`, because "*" is stdout and there ISN'T one when this is launched without a
; redirect — FileAppend then throws and the run dies at whatever line it reached,
; looking exactly like the thing under test failing.
Out(s) {
    try FileAppend(s "`n", "*")
}

; Any throw becomes output and an exit code, never a modal dialog. Without this a
; failure inside SETTINGS_Fields() presents as a hang with no message — the run
; waits forever on a dialog nobody can see. Same guard as settings_build_test.ahk.
OnError(ReportAndDie)
ReportAndDie(e, mode) {
    Out("ERROR: " e.Message)
    Out("   at " e.File ":" e.Line)
    if (e.HasProp("Extra") && e.Extra != "")
        Out("   extra: " e.Extra)
    ExitApp(1)
}

Out("settings parity: reading the two front ends")

pass := 0, fail := 0
Ck(name, ok, detail := "") {
    global pass, fail
    if ok
        pass++
    else
        fail++, Out("FAIL " name (detail = "" ? "" : ": " detail))
}

; ── the rows that are deliberately not a plain cfg write ──────────────────────
;  There are none left, and that is the point of this comment rather than a
;  reason to delete it: every exemption here was a setting the two front ends had
;  to special-case on load and again on save, and each one that went took a pair
;  of special cases with it.
;
;    waitTime       was a literal inside core\utils.ahk that saving REWROTE
;                   through a regex, so there was no key to look for. It is
;                   [Settings] WaitTime now.
;    modelStrategy  were the two halves of ONE key, [Settings] ModelMatch —
;    inflowwMatch   a global manual/automatic switch plus an Infloww read mode,
;                   split on load and recombined on save. Manual is per site now,
;                   so inflowwMatch IS [Settings] ModelMatch and modelStrategy
;                   does not exist. See the Models block in ui\settings_core.ahk
;                   for why the global switch had to go.
;
;  Kept as empty maps rather than deleted so the next setting that genuinely
;  cannot be a plain write has an obvious place to say so, with the standard to
;  meet written above it.
global VIRTUAL := Map()

; Keys the Win32 window may touch without a row in the table.
global RECOMBINED := Map()

; Is this key NAMED in the Win32 window?
;
; Quoted, so a short key cannot be satisfied by a longer word that contains it:
; "Model" must not pass because "ModelCount" is present.
;
; The stem rule is for the GENERATED families. Model1, Platform2, Pos3 are
; built by interpolation in both windows - `"Model" n` - so the full literal
; appears in neither source and never can. Proving the stem is the strongest
; claim available for those, and it still catches the failure that matters: a
; whole family the Win32 window does not build at all.
_Names(w32, key) {
    if InStr(w32, '"' key '"')
        return true
    if RegExMatch(key, "^(\D+)\d+$", &st)
        return InStr(w32, '"' st[1] '"') > 0
    return false
}

; ── the Win32 window, as text ─────────────────────────────────────────────────
w32path := MMA_SRC "\ui\settings_window.ahk"
w32 := ""
try {
    w32 := FileRead(w32path, "UTF-8")
} catch as e {
    Out("ERROR: could not read " w32path " — " e.Message)
    ExitApp(1)
}
Ck("the Win32 settings window is readable", StrLen(w32) > 1000,
   "read " StrLen(w32) " bytes from " w32path)

; ── every table row has a home in the Win32 window ────────────────────────────
;  No value provider is passed, so the table answers from the saved cfg. That is
;  what this test wants: the shape of the window as it ships, not as it looks
;  mid-edit.
fields := SETTINGS_Fields()
Ck("the field table is not empty", fields.Length > 0, "got " fields.Length " rows")

; nVirtual, not `virtual`: AHK names are CASE-INSENSITIVE, so a counter called
; `virtual` IS the VIRTUAL map above and the first VIRTUAL.Has() call dies with
; "this value of type Integer has no method named Has".
checked := 0, nVirtual := 0, notes := 0
for _, fld in fields {
    if (fld.type = "note") {
        notes++
        continue                       ; a readout, not a setting — nothing to save
    }
    if VIRTUAL.Has(fld.id) {
        nVirtual++
        continue
    }
    if (fld.iniKey = "") {
        ; A row with no ini home that is not on the exempt list above is either a
        ; new virtual row nobody documented, or a row that forgot its key. Both
        ; are worth stopping for.
        Ck("row '" fld.id "' has a cfg home", false,
           "no iniKey, and it is not in the VIRTUAL list at the top of this file")
        continue
    }
    checked++
    Ck("Win32 window offers [" fld.iniSect "] " fld.iniKey,
       _Names(w32, fld.iniKey),
       "the field table declares it and settings_window.ahk never names it."
     . " Added to SETTINGS_Fields() without a control in the Win32 tab?")
}

for key, _ in RECOMBINED
    Ck("Win32 window offers the recombined [Settings] " key,
       _Names(w32, key),
       "the virtual rows recombine into it, so both windows must write it")

; ── and nothing in the Win32 window is a setting the table has never heard of ──
;  The other direction, and the one that says a setting exists only in the legacy
;  window — where the default-shell user will never find it.
declared := Map()
for _, fld in fields
    if (fld.iniKey != "")
        declared[fld.iniKey] := true
; Feature checkboxes are not table rows and never should be: they come from the
; registry in core\modes.ahk, which both windows already walk. Their cfg keys are
; therefore legitimately absent from the table.
for _, id in FEAT_ORDER
    declared[FEAT_META[id].cfgKey] := true
for key, _ in RECOMBINED
    declared[key] := true

; Only [Settings]. The Win32 window also owns whole calibration sections
; ([ReplyBox] geometry, [Detector] colours) that are drawn by a dedicated dialog
; rather than by a field row, and those are not settings in this sense.
stray := []
pos := 1
while (pos := RegExMatch(w32, 'Ini(?:Read|Write)\s*\([^,]+,\s*"Settings"\s*,\s*"([^"]+)"',
                         &m, pos)) {
    ; m.Len[0] is the WHOLE match. A bare `m.Len` is not that, and a step of
    ; zero here is an infinite loop rather than an error.
    pos := m.Pos[0] + m.Len[0]
    key := m[1]
    ; Interpolated keys (Model1, Platform2, FuSingle_3) arrive here as their
    ; literal prefix only when the source spells them out; the built ones cannot
    ; be seen textually at all, so a prefix match keeps them out of the report.
    if declared.Has(key)
        continue
    if RegExMatch(key, "^(Model|Platform|FuSingle_|Pos|Order)\d*$")
        continue
    if !HasVal(stray, key)
        stray.Push(key)
}
HasVal(arr, v) {
    for _, x in arr
        if (x = v)
            return true
    return false
}

Ck("no [Settings] key is offered only by the Win32 window", stray.Length = 0,
   stray.Length " key(s) the field table has never heard of: " Join(stray, ", ")
 . "  — either add a row to SETTINGS_Fields() so the WebView window offers it too,"
 . " or add it to RECOMBINED at the top of this file if it is a derived key")
Join(arr, sep) {
    s := ""
    for _, x in arr
        s .= (s = "" ? "" : sep) x
    return s
}

Out("")
Out("checked " checked " table row(s) against the Win32 window"
  . "  (" nVirtual " virtual, " notes " note row(s) skipped)")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
