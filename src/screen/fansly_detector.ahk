#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../vendor/OCR.ahk"
#Include "fansly_scan.ahk"

; ============================================================================
;  fansly_detector.ahk — active-model detector for the FANSLY rail.
; ----------------------------------------------------------------------------
;  The twin of screen/model_detector.ahk, and deliberately not an extension of
;  it. Same job — write which model is on screen to a status ini so one set of
;  f1/f2/f3 keys can serve whichever model you are looking at — but a different
;  platform, a different layout, a different status file and a different config
;  section. Nothing here can mis-tune the Infloww detector and nothing there can
;  mis-tune this. See the header of screen/rail_scan.ahk for why that separation
;  is worth two files.
;
;  Infloww is a horizontal strip of flat pills. Fansly is a vertical rail of
;  cards, each wrapped around the model's avatar photo, and the selected one is
;  only a few levels of grey lighter than the rail behind it. So:
;
;    • rows, not columns                     (rail_scan.ahk)
;    • test the card's flat left margin only, never across the avatar
;                                            (FanslySampleBand, fansly_scan.ahk)
;    • a much tighter colour tolerance       ([Fansly] CardTol)
;
;  POSITION IS THE PRIMARY ANSWER HERE, not the name. Every poll a cheap pixel
;  test says which row is lit; that costs no OCR and is written every time. OCR —
;  the expensive and unreliable part — runs only when the lit row CHANGES, and
;  purely so name mode has something to match. Two reasons it is demoted on this
;  platform: the labels are truncated with an ellipsis ("KB FANS…", "Luxdo Fa…"),
;  so a name is a prefix at best; and unselected labels are dim grey on near
;  black, which OCR reads as noise. Name matching therefore has to be substring
;  matching — which it already is, see FanslySlotOwnsName in core/fansly_model.
;
;  All tunables live in mass_gui.cfg [Fansly]; edit there, or run
;  tools/fansly_probe.ahk to measure them. No hotkeys, no window.
; ============================================================================

; LOG_IniInt throughout the config reader this includes — see the note in
; fansly_scan.ahk. Every value is read at the TOP LEVEL of a background service
; with no window, no tray icon and no output, so a typo in the config does not
; mis-tune the detector, it stops the detector from existing. The only symptom is
; the [mass.active] shared keys quietly having nothing to follow.
FanslySeedCfg()

CoordMode "Pixel", "Screen"

; ALL of these must be assigned before the first Poll() below, not merely
; somewhere in the file. Top-level statements run in order and function bodies
; are skipped, so an initialiser sitting next to the function that uses it — which
; reads better — has simply not run yet when Poll() fires on line one of the
; auto-execute section. That is what "_wIndex has not been assigned a value" was
; on the Infloww side: the very first poll reading a variable initialised 130
; lines later.
_lastRow  := 0          ; row we last OCR'd, so a switch is detectable
_lastName := ""         ; cached name for that row
_written  := "«?»"      ; last name written to the ini (dedupes writes)
_wIndex   := -1         ; last active_index written
_wY       := -99999     ; last active_y written

_cfg := FanslyCfg()
LOG_Kv("fansly.boot", Map("rail",   _cfg.x "," _cfg.y " w" _cfg.w
                                  . " × " _cfg.rows " rows",
                          "pitch",  _cfg.pitch,
                          "rowH",   _cfg.rowH,
                          "sample", "x+" _cfg.sx ".." (_cfg.sx + _cfg.sw)
                                  . "  (avatar deliberately excluded)",
                          "card",   Format("0x{:06X}", _cfg.rgb),
                          "cardTol", _cfg.tol,
                          "minCard", _cfg.min,
                          "pollMs", _cfg.pollMs,
                          "winMatch", _cfg.win = "" ? "(none — WILL NOT SCAN)"
                                                    : _cfg.win))

Poll()
SetTimer(Poll, _cfg.pollMs)

Poll() {
    global _lastRow, _lastName

    cfg := FanslyCfg()

    ; No gate, no scanning. Unlike the Infloww detector this refuses outright on
    ; an empty WinMatch rather than scanning ungated: the rail sits at the far
    ; left of the screen, which is where every other application also keeps
    ; something, so an ungated scan here is not a small risk.
    if (cfg.win = "") {
        LOG_Heartbeat("fansly.idle", "alive, but [Fansly] WinMatch is empty so"
                                   . " there is no window to gate on. Refusing to"
                                   . " scan fixed screen coordinates ungated.")
        Clear()
        return
    }
    if !FanslyWindowUp(cfg) {
        ; Throttled, or this would be thousands of lines an hour while you work
        ; anywhere else. Its ABSENCE from a stretch of log is how you tell the
        ; service died rather than merely having nothing to report.
        LOG_Heartbeat("fansly.idle",
                      "alive, but '" cfg.win "' is not in front — not scanning."
                    . " Fansly's shared keys have no answer while this is true;"
                    . " the Infloww detector answers instead if that window is up.")
        Clear()
        return
    }
    LOG_Heartbeat("fansly.poll", "alive and scanning; last name read: '"
                               . (_lastName = "" ? "(none)" : _lastName) "'")

    img := FanslyGrabRail(cfg)
    lit := FanslyLitRow(cfg, img)
    if !lit.index {
        ; Worth distinguishing from "window not up": the rail IS in front and
        ; nothing on it reads as selected. Almost always RegionY or CardTol, and
        ; the counts are the only thing that tells you which — two rows both
        ; scoring high is a wrong RowPitch, everything at zero is a wrong colour
        ; or a wrong origin.
        LOG_Heartbeat("fansly.dark", "'" cfg.win "' is in front but no row reads as"
                                   . " selected. Per-row counts: "
                                   . _Counts(lit.counts)
                                   . "  (MinCard=" cfg.min ", CardTol=" cfg.tol ")."
                                   . " Run tools\fansly_probe.ahk.")
        Clear()
        return
    }

    ; OCR only on a row CHANGE. It is the expensive part, it is the unreliable
    ; part, and on this platform it is not even the primary answer — positional
    ; mode below is written every poll and does not depend on any of it.
    if (lit.index != _lastRow || _lastName = "") {
        r    := FanslyLabelRect(lit.index, cfg)
        name := OcrLabel(r.x, r.y, r.w, r.h, cfg.scale)
        _lastRow := lit.index
        if (name != "") {
            ; The one line worth having from this whole service. Everything
            ; downstream is decided from this string, and it is OCR of a ~11px
            ; truncated label. Seeing the ACTUAL text is the difference between
            ; "detection is broken" and "detection read 'KB FANS...' and no slot
            ; claims that prefix", which are completely different bugs.
            LOGI("fansly", "OCR read '" name "'  row " lit.index " of " cfg.rows)
            _lastName := name
        } else {
            ; Note the row WAS found — this is an OCR failure, not a scan
            ; failure, and positional mode is entirely unaffected. That is the
            ; advice this line exists to point at.
            LOGW("fansly", "row " lit.index " is lit but OCR read nothing from its"
                         . " label. Name mode has no answer; positional mode is"
                         . " unaffected and still works — and on Fansly it is the"
                         . " mode to be using anyway.")
        }
    }
    if (_lastName != "")
        WriteName(_lastName)

    WriteIndex(lit.index)
    WriteY(cfg.y + (lit.index - 1) * cfg.pitch)
}

; Everything to "no answer". Clearing rather than leaving the last reading is the
; safe direction: a stale name gates the wrong model's keys on, silently, and the
; user's only symptom is messages going to the wrong chat.
Clear() {
    global _lastRow, _lastName
    WriteName("")
    WriteIndex(0)
    WriteY(-1)
    _lastRow := 0, _lastName := ""
}

; OCR a rectangle to a single cleaned line; "" on any failure.
;
; The trailing ellipsis Fansly truncates names with is left ON deliberately — OCR
; renders it as "..." or "…" or drops it, and stripping it here would just be a
; third variant to match against. The matcher does substring matching, so the
; junk on the end costs nothing.
OcrLabel(x, y, w, h, scale) {
    if (w < 4 || h < 4)
        return ""
    try {
        res := OCR.FromRect(x, y, w, h, {scale: scale, grayscale: 1})
        return Trim(RegExReplace(res.Text, "\s+", " "))
    } catch {
        return ""
    }
}

; Only CHANGES are logged and written — this runs twice a second, and the early
; return is what keeps a steady state from filling the file with one identical
; line. What is left is a clean record of every model switch MMA believed in.
WriteName(name) {
    global _written
    if (name = _written)
        return
    LOGI("fansly", "active model name: '" (_written = "" ? "(none)" : _written)
                 . "' → '" (name = "" ? "(none)" : name) "'")
    _written := name
    try IniWrite(name, MMA_FANSLY, "fansly", "active_model")
}

; WHICH ROW, which is the answer that actually matters on this platform: no OCR,
; no names, no aliases, and it survives a theme where unselected cards are
; invisible. 0 = no answer, and it is distinct from row 1.
WriteIndex(index) {
    global _wIndex
    if (index = _wIndex)
        return
    _wIndex := index
    try IniWrite(index, MMA_FANSLY, "fansly", "active_index")
}

; Where the lit card is, in screen px. Falls straight out of the scan and costs
; nothing; nothing reads it in the hot path (that scans directly, because a value
; refreshed every 500ms is stale exactly when you need it — the instant after you
; clicked) but the probe and the debug panel can watch it for free.
WriteY(y) {
    global _wY
    if (y = _wY)
        return
    _wY := y
    try IniWrite(y, MMA_FANSLY, "fansly", "active_y")
}

_Counts(counts) {
    out := ""
    for i, n in counts
        out .= (out = "" ? "" : " ") "r" i "=" n
    return out = "" ? "(none)" : out
}
