#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../src/core/paths.ahk"
#Include "../src/vendor/OCR.ahk"
#Include "../src/screen/fansly_scan.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  fansly_probe.ahk — what the Fansly detector is actually looking at.
; ───────────────────────────────────────────────────────────────────────────────
;  The Fansly detector ships with PLACEHOLDER geometry. It cannot ship with
;  anything else: RegionX/RegionY are absolute screen coordinates of a rail whose
;  position depends on your monitor, your window size and your zoom, and the card
;  colour depends on the theme. Every default in [Fansly] is read off a
;  screenshot. This is the tool that replaces them with measurements.
;
;  It never clicks and never types. It reads pixels and writes two config values
;  when you ask it to.
;
;  ─── USAGE ───────────────────────────────────────────────────────────────────
;  Put Fansly in front with the model rail visible and ONE model selected.
;
;    Ctrl+Alt+F9    point at the TOP-LEFT of the FIRST card, press → RegionX/Y
;    Ctrl+Alt+F11   point at the TOP-LEFT of the SECOND card, press → RowPitch
;    Ctrl+Alt+F10   measure: colours, per-row counts, sweep, OCR of every label
;    Ctrl+Alt+F12   quit
;
;  Do F9 and F11 first — until the origin is right, everything the report says is
;  about the wrong pixels. Then F10, then copy the suggested values into
;  mass_gui.cfg [Fansly] and restart the detector.
;
;  Modified keys, never a bare F-key or Esc: this runs WHILE Fansly is focused,
;  and a bare hotkey is swallowed globally — Esc would stop closing Fansly's own
;  dialogs for as long as the probe was up.
;
;  ─── WHAT TO LOOK FOR IN THE OUTPUT ──────────────────────────────────────────
;  The report is built around the three ways this detector fails, because a
;  number that is merely wrong looks identical to one that is right until you see
;  what it does:
;
;    • ONE row scoring high, the rest near zero            → correct.
;    • TWO adjacent rows both scoring high                 → RowPitch is wrong;
;      one card is straddling two slots and PILL_PickLit will refuse forever.
;    • EVERY row scoring high                              → CardTol is too loose
;      and the rail background is matching. This is the likely failure on Fansly,
;      where the selected card is only a few levels of grey lighter than the rail
;      — unlike Infloww, where the two are 30 apart.
;    • Everything at zero                                  → wrong RegionY, wrong
;      CardColor, or the sample band is landing on the avatar rather than the
;      card's left margin.
;
;  The avatar is the trap specific to this platform: a card wraps a photograph,
;  and a photograph contains every colour there is. The "sample band" line in the
;  report tells you which pixels are being tested — keep it in the flat margin.
; ═══════════════════════════════════════════════════════════════════════════════

CoordMode "Pixel",  "Screen"
CoordMode "Mouse",  "Screen"
CoordMode "ToolTip","Screen"
OUT := MMA_PROBE_FANSLY

FanslySeedCfg()

Say(s := "") {
    global OUT
    try FileAppend(s "`n", OUT, "UTF-8")
}

Hex(c) => Format("0x{:06X}", c)

; badgeGui, not badge: a variable and a function differing only in case are ONE
; name to AHK, and the script fails to LOAD rather than shadowing — silently,
; exit code 0, nothing printed. Same trap as detector_probe.ahk.
badgeGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")  ; WS_EX_NOACTIVATE
badgeGui.BackColor := "1E1E1E"
badgeGui.SetFont("s10 Bold cWhite", "Segoe UI")
badgeGui.Add("Text", "x12 y10 w320", "Fansly rail probe — running")
badgeGui.SetFont("s9 Norm c9A9A9A")
lblBadge := badgeGui.Add("Text", "x12 y34 w320",
                         "Ctrl+Alt+F9    top-left of card 1  → RegionX/Y`n"
                       . "Ctrl+Alt+F11   top-left of card 2  → RowPitch`n"
                       . "Ctrl+Alt+F10   measure the rail`n"
                       . "Ctrl+Alt+F12   quit")
badgeGui.Show("x" (A_ScreenWidth - 364) " y24 w344 h108 NoActivate")

Badge(s) {
    global lblBadge
    try lblBadge.Value := s
}

^!F9::SetOrigin()
^!F11::SetPitch()
^!F10::Probe()
^!F12::ExitApp()

; ── the two numbers you cannot guess ─────────────────────────────────────────
; Pointing at them is the only honest way to get these. They are absolute screen
; coordinates; no amount of scanning derives them, because a scan needs to know
; where to look first.
SetOrigin() {
    MouseGetPos(&mx, &my)
    IniWrite(mx, MMA_CFG, "Fansly", "RegionX")
    IniWrite(my, MMA_CFG, "Fansly", "RegionY")
    Badge("RegionX=" mx "  RegionY=" my "`nnow point at card 2 and press Ctrl+Alt+F11")
    ToolTip("Fansly rail origin: " mx "," my, mx + 16, my)
    SetTimer(() => ToolTip(), -1500)
}

SetPitch() {
    MouseGetPos(&mx, &my)
    cfg := FanslyCfg()
    pitch := my - cfg.y
    if (pitch < 8) {
        ; Almost always "pressed F11 before F9", and it is worth saying so rather
        ; than writing a pitch of 3 and leaving the detector to fail strangely.
        Badge("that is only " pitch "px below RegionY (" cfg.y ").`n"
            . "Set the origin with Ctrl+Alt+F9 first.")
        return
    }
    IniWrite(pitch, MMA_CFG, "Fansly", "RowPitch")
    ; RowHeight is not asked for separately: on this rail the card fills nearly
    ; the whole pitch, and a height slightly under it is what the row inset is
    ; for anyway. One less thing to point at, one less thing to get wrong.
    IniWrite(Max(8, pitch - 9), MMA_CFG, "Fansly", "RowHeight")
    Badge("RowPitch=" pitch "  RowHeight=" (pitch - 9) "`nnow press Ctrl+Alt+F10")
    ToolTip("row pitch: " pitch "px", mx + 16, my)
    SetTimer(() => ToolTip(), -1500)
}

Probe() {
    global OUT
    Badge("reading the rail…")          ; before the slow part, so it never looks dead
    try FileDelete(OUT)

    cfg  := FanslyCfg()
    band := FanslySampleBand(cfg)
    botY := cfg.y + cfg.pitch * cfg.rows

    Say("MMA Fansly rail probe — " FormatTime(, "yyyy-MM-dd HH:mm:ss"))
    Say("window:      " (WinExist("A") ? WinGetTitle("A") : "?"))
    Say("WinMatch:    '" cfg.win "'  → " (FanslyWindowUp(cfg)
                                          ? "in front, good"
                                          : "NOT in front. The detector would not"
                                          . " scan at all in this state."))
    Say("rail:        x" cfg.x " y" cfg.y " w" cfg.w
      . "   " cfg.rows " rows of " cfg.pitch "px (card " cfg.rowH "px)")
    Say("sample band: x " band.x1 ".." band.x2
      . "   ← these are the ONLY columns tested. Keep them on the card's flat"
      . " left margin, off the avatar.")
    Say("cfg:         CardColor=" Hex(cfg.rgb) " CardTol=" cfg.tol
      . " MinCard=" cfg.min " ScanStep=" cfg.step " GapTol=" cfg.gap)
    Say("")

    img := FanslyGrabRail(cfg)
    if !img {
        Say("CAPTURE FAILED — nothing below this line is meaningful.")
        Badge("capture failed"), Run('notepad.exe "' OUT '"')
        return
    }

    ; ── every colour in the sample band, counted ─────────────────────────────
    ; The colours are most of the answer. The band is deliberately flat — no
    ; avatar, no text — so it holds essentially two colours: the rail background
    ; and, on one row, the selected card. You do not have to guess either; they
    ; are the top two entries of this list.
    seen := Map()
    y := cfg.y
    while (y <= botY) {
        x := band.x1
        while (x <= band.x2) {
            c := PILL_Px(img, x, y)
            if (c >= 0)
                seen[c] := seen.Has(c) ? seen[c] + 1 : 1
            x += cfg.step
        }
        y += cfg.step
    }
    top := []
    for c, n in seen
        top.Push({c: c, n: n})
    ; Plain insertion sort: the band holds a handful of distinct colours, and a
    ; dependency-free sort that is obviously correct beats a clever one here.
    Loop top.Length {
        i := A_Index
        Loop top.Length - i {
            j := A_Index
            if (top[j].n < top[j + 1].n) {
                t := top[j], top[j] := top[j + 1], top[j + 1] := t
            }
        }
    }
    Say("── colours in the sample band, most common first ──")
    Loop Min(8, top.Length)
        Say(Format("   {:-10s}  {:6} px   dist to CardColor {:3}",
                   Hex(top[A_Index].c), top[A_Index].n,
                   PILL_ColorDist(top[A_Index].c, cfg.rgb)))
    if (top.Length >= 2) {
        sep := PILL_ColorDist(top[1].c, top[2].c)
        Say("")
        Say("   the two most common are " sep " apart.")
        if (sep < 6)
            Say("   THAT IS TOO CLOSE to separate reliably. Either no card is"
              . " selected right now, or the band is not on a card at all.")
        else
            Say("   suggested:  RailColor=" Hex(top[1].c)
              . "   CardColor=" Hex(top[2].c)
              . "   CardTol=" Max(4, sep // 3))
        Say("   (the rail background is the COMMONER of the two — only one row is"
          . " lit, so the card colour is the rarer one.)")
    }
    Say("")

    ; ── what the current settings decide ─────────────────────────────────────
    lit := FanslyLitRow(cfg, img)
    Say("── per-row counts with the CURRENT settings ──")
    hi := 0
    for i, n in lit.counts
        hi := Max(hi, n)
    for i, n in lit.counts {
        bar := ""
        if (hi > 0)
            Loop Round(n / hi * 24)
                bar .= "#"
        r := FanslyRowRange(i, cfg)
        Say(Format("   row {:2}  y {:5}..{:-5}  {:6} px  {:-24s}{}",
                   i, r.y1, r.y2, n, bar,
                   (i = lit.index) ? "  <- lit" : ""))
    }
    Say("")
    if !lit.index {
        ; PILL_PickLit's two refusals are different diagnoses and it is worth
        ; separating them here, because "no answer" alone is unactionable.
        if (hi < cfg.min)
            Say("   NO ROW IS LIT: the best row scored " hi ", below MinCard="
              . cfg.min ". Wrong RegionY, wrong CardColor, or no model is"
              . " selected.")
        else
            Say("   REFUSED: more than one row scores high, so a card is"
              . " straddling two slots. That is RowPitch — re-measure it with"
              . " Ctrl+Alt+F11.")
    } else {
        Say("   row " lit.index " is selected. [FanslyPos] Pos" lit.index
          . " decides which model that is.")
    }
    Say("")

    ; ── the sweep, which does not trust RowPitch ─────────────────────────────
    ; Worth having precisely because it needs neither the origin nor the pitch to
    ; be right: it finds the lit card wherever it is. If the sweep sees a card and
    ; the per-row counts above see nothing, the colours are fine and the geometry
    ; is what is wrong — which is a completely different afternoon's work.
    sw := FanslySweep(cfg, img)
    Say("── sweep (ignores RowPitch; finds the card wherever it is) ──")
    if !sw.count {
        Say("   nothing found. If the colour list above looked sensible, the"
          . " sample band is off the card.")
    } else {
        Say("   lit card: y " sw.minY ".." sw.maxY "  (" (sw.maxY - sw.minY)
          . "px tall, centre " sw.avgY ")  " sw.count " px")
        Say("   → if no row above is lit, set RegionY=" sw.minY
          . " and RowHeight≈" (sw.maxY - sw.minY))
    }
    Say("")

    ; ── OCR every label ──────────────────────────────────────────────────────
    ; Not because name mode is the recommended mode on this platform — it is not,
    ; the rail truncates every name — but because seeing the ACTUAL strings is
    ; the only way to know whether it could work for YOUR model names. Two models
    ; whose truncated labels are both "KB FANS…" can never be told apart by name,
    ; and this is where you find that out, rather than from messages arriving in
    ; the wrong chat.
    Say("── OCR of each row's label ──")
    Loop cfg.rows {
        r := FanslyLabelRect(A_Index, cfg)
        Say(Format("   row {:2}  <{}>", A_Index, OcrRect(r, cfg.scale)))
    }
    Say("   (labels are truncated on screen, so these are PREFIXES. Matching is"
      . " substring-based both ways — see FanslySlotOwnsName.)")
    Say("")
    Say("Copy the suggested values into mass_gui.cfg [Fansly], then restart the"
      . " detector from Settings ▸ Features.")

    Badge("done — see debuglogs\fansly_probe.txt")
    Run('notepad.exe "' OUT '"')
}

OcrRect(r, scale) {
    if (r.w < 4 || r.h < 4)
        return "rect too small"
    try {
        res := OCR.FromRect(r.x, r.y, r.w, r.h, {scale: scale, grayscale: 1})
        return Trim(RegExReplace(res.Text, "\s+", " "))
    } catch as e {
        return "OCR failed: " e.Message
    }
}
