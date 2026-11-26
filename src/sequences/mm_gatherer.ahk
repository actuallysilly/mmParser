; ── MM Gatherer ────────────────────────────────────────────────────────────────
;  Press the key in a Discord channel: it scrolls that channel up to its very
;  first message, reads every screen with OCR, and saves each message that looks
;  like a mass to userdata\gathered\<channel>.txt.
;
;  Included by sequences.ahk, which owns the Discord helpers it leans on
;  (DiscordChannelName, ModelFromChannel) and is already in StartupScripts.
;
;  How it reads, and why it is built this way:
;   • OCR, not Copy Text. Copy Text is exact but drives the mouse and owns Discord
;     for the whole run; this reads with PrintWindow (mode 4) and scrolls with a
;     posted WM_MOUSEWHEEL, so you can keep working while it runs. The price is
;     emojis: OCR drops or garbles them.
;   • A message is keyed by its header line ("Author  Today at 3:04 PM"). It is
;     saved from a frame where its header AND its end are both on screen, so a
;     message cut off by the top or bottom of the pane is never saved half-read —
;     it is picked up whole a frame or two later, as the scroll moves it down.
;     A message taller than the pane can never be whole on one screen; the
;     longest read of it is saved and marked TRUNCATED.
;   • Consecutive messages from one person within a few minutes share ONE header
;     in Discord, so they arrive here as one entry. Known limit.
;   • It runs on a timer, one frame per tick, so the same key stops it.
;
;  Every frame's raw OCR goes to debuglogs\mm_gatherer_frames.txt while
;  [Discord] GatherDebug=1 — that file is how the header pattern and the pane box
;  get tuned when a run saves nothing.

MMG_DIR := MMA_USERDATA "\gathered"

; Seed the [Discord] Gather* keys so they are visible and editable in the cfg.
if (IniRead(SEQ_CFG, "Discord", "GatherWheel", "") = "") {
    for k, v in Map("GatherLeft", 460, "GatherTop", 80, "GatherRight", 260,
                    "GatherBottom", 90, "GatherWheel", 4, "GatherSettleMs", 450,
                    "GatherMinChars", 80, "GatherMinParas", 2, "GatherDebug", 1)
        try IniWrite(v, SEQ_CFG, "Discord", k)
}

global MMG := {running: false}

; The key: start a run, or stop the one in progress.
mmGatherSeq() {
    global MMG
    if MMG.running {
        MMG_Finish("stopped by you")
        return
    }
    MMG_Start()
}

; The channel to name the file after. DiscordChannelName() only accepts a slug with
; a hyphen (that is what keeps the import from routing on prose), so a plain
; "#silly" channel comes back blank — the window title still names it.
MMG_Channel() {
    chan := DiscordChannelName()
    if (chan = "") {
        t := ""
        try t := WinGetTitle("ahk_exe Discord.exe")
        if RegExMatch(t, "^#(.+?)\s*\|", &m)
            chan := StrLower(Trim(RegExReplace(m[1], "[^A-Za-z0-9_-]"), "-_"))
    }
    return chan
}

MMG_Cfg(key, def) {
    global SEQ_CFG
    return LOG_IniInt(SEQ_CFG, "Discord", key, def)
}

MMG_Start() {
    global MMG, MMG_DIR, MMA_DEBUGLOGS
    prevHidden := A_DetectHiddenWindows
    DetectHiddenWindows false        ; else "ahk_exe Discord.exe" can hit a hidden helper window
    hwnd := WinExist("ahk_exe Discord.exe")
    if !hwnd {
        DetectHiddenWindows prevHidden
        LOG_Bail("seq.gather", "Discord is not open — nothing to gather")
        MMG_Tip("MM Gatherer: Discord is not open")
        return
    }
    if (WinGetMinMax("ahk_id " hwnd) = -1) {
        DetectHiddenWindows prevHidden
        LOG_Bail("seq.gather", "Discord is minimized — PrintWindow sees nothing")
        MMG_Tip("MM Gatherer: Discord is minimized, open it first")
        return
    }
    chan  := MMG_Channel()
    DetectHiddenWindows prevHidden
    if (chan = "") {
        LOG_Bail("seq.gather", "could not read the channel name — no file to save to")
        MMG_Tip("MM Gatherer: channel not recognised")
        return
    }
    model := ModelFromChannel(chan)

    MMG := {running: true, hwnd: hwnd, chan: chan, model: model,
            frame: 0, stuck: 0, lastSig: "", sawTop: false,
            best: Map(), order: [],
            debug: MMG_Cfg("GatherDebug", 1),
            dbgFile: MMA_DEBUGLOGS "\mm_gatherer_frames.txt"}
    if MMG.debug
        try FileDelete(MMG.dbgFile)
    DirCreate(MMG_DIR)
    LOGI("seq.gather", "started on #" chan " (model '" model "')")
    MMG_Tip("MM Gatherer: reading #" chan " — press the key again to stop")
    SetTimer(MMG_Tick, -10)
}

; One frame: read the pane, keep what is whole, scroll up, come back.
MMG_Tick() {
    global MMG
    if !MMG.running
        return
    prevHidden := A_DetectHiddenWindows
    DetectHiddenWindows false
    ok := WinExist("ahk_id " MMG.hwnd) && WinGetMinMax("ahk_id " MMG.hwnd) != -1
    pane := ok ? MMG_Pane() : 0
    DetectHiddenWindows prevHidden
    if !pane {
        MMG_Finish("Discord was closed or minimized")
        return
    }

    MMG.frame += 1
    lines := MMG_ReadLines(pane)
    MMG_TakeFrame(lines, pane)

    ; The top: Discord's channel intro is on screen, or the pane stopped moving.
    ; "Stopped moving" needs several frames in a row, because older history is
    ; lazy-loaded — the scroll pauses at the edge of what has loaded so far.
    sig := ""
    for row in lines
        sig .= row.text "|"
    if (sig = MMG.lastSig)
        MMG.stuck += 1
    else
        MMG.stuck := 0
    MMG.lastSig := sig
    if (MMG.sawTop || MMG.stuck >= 4) {
        MMG_Finish(MMG.sawTop ? "reached the top of the channel"
                              : "the channel stopped scrolling (top, or still loading)")
        return
    }
    if (MMG.frame >= 5000) {
        MMG_Finish("hit the 5000-frame safety limit")
        return
    }

    MMG_Scroll(pane)
    MMG_Tip("MM Gatherer: #" MMG.chan "  frame " MMG.frame "  messages " MMG.order.Length
          . "`npress the key again to stop")
    wait := MMG_Cfg("GatherSettleMs", 450)
    SetTimer(MMG_Tick, -(MMG.stuck ? wait * 2 : wait))
}

; The message pane in client coordinates: the client area minus the channel
; sidebar on the left, the header on top, the member list on the right and the
; composer at the bottom. Each trim is a [Discord] Gather* key.
MMG_Pane() {
    global MMG
    WinGetClientPos(, , &cw, &ch, "ahk_id " MMG.hwnd)
    x := MMG_Cfg("GatherLeft", 460), y := MMG_Cfg("GatherTop", 80)
    w := cw - x - MMG_Cfg("GatherRight", 260)
    h := ch - y - MMG_Cfg("GatherBottom", 90)
    if (w < 100 || h < 100)
        return 0
    return {x: x, y: y, w: w, h: h}
}

; OCR the pane; lines sorted top to bottom, in client coordinates.
MMG_ReadLines(pane) {
    global MMG
    out := []
    res := 0
    try res := OCR.FromWindow("ahk_id " MMG.hwnd,
                              {x: pane.x, y: pane.y, w: pane.w, h: pane.h,
                               scale: 2, mode: 4})
    if !res
        return out
    for oline in res.Lines {
        r := oline.BoundingRect
        txt := Trim(oline.Text)
        if (txt != "")
            out.Push({text: txt, x: r.x, y: r.y, h: r.h})
    }
    ; Insertion sort by y — a screen is a few dozen lines.
    i := 2
    while (i <= out.Length) {
        cur := out[i], j := i - 1
        while (j >= 1 && out[j].y > cur.y) {
            out[j + 1] := out[j]
            j -= 1
        }
        out[j + 1] := cur
        i += 1
    }
    if MMG.debug {
        s := "── frame " MMG.frame " ──`n"
        for row in out
            s .= row.x "," row.y " h" row.h "  | " row.text "`n"
        try FileAppend(s, MMG.dbgFile, "UTF-8")
    }
    return out
}

; "Silly  Today at 3:04 PM" → {author, stamp}; 0 if the line is not a header.
; Discord writes the time as "Today at 3:04 PM", "Yesterday at 15:04" or
; "10/22/2026 3:04 PM" depending on age and locale.
MMG_Header(txt) {
    if RegExMatch(txt, "i)^(.*?)\s*[-—]?\s*((?:Today|Yesterday) at \d{1,2}[:.]\d{2}(?:\s*[AP]M)?"
                     . "|\d{1,2}[/.]\d{1,2}[/.]\d{2,4},?\s+\d{1,2}[:.]\d{2}(?:\s*[AP]M)?)\s*$", &m)
        && Trim(m[1]) != ""
        return {author: Trim(m[1]), stamp: m[2]}
    return 0
}

; Lines that are Discord's furniture, never message text.
MMG_IsChrome(txt) {
    static months := "January|February|March|April|May|June|July|August|September|October|November|December"
    return RegExMatch(txt, "i)^(?:" months ")\s+\d{1,2},\s+\d{4}$")      ; date divider
        || RegExMatch(txt, "i)^\d{1,2}[:.]\d{2}\s*(?:[AP]M)?$")          ; hover time on a grouped line
        || RegExMatch(txt, "i)^NEW$")                                     ; unread divider
}

; Split one frame into messages and keep the ones that are whole.
MMG_TakeFrame(lines, pane) {
    global MMG
    msgs := [], cur := 0
    for row in lines {
        if RegExMatch(row.text, "i)Welcome to #|This is the start of the") {
            MMG.sawTop := true
            continue
        }
        if hdr := MMG_Header(row.text) {
            cur := {author: hdr.author, stamp: hdr.stamp, body: "", lastBottom: row.y + row.h,
                    lineH: row.h, complete: false}
            msgs.Push(cur)
            continue
        }
        if (!cur || MMG_IsChrome(row.text))    ; text above the first header is a cut-off message
            continue
        txt := RegExReplace(row.text, "\s*\(edited\)\s*$")
        ; A gap taller than about one line between two lines is a blank line in the
        ; message — the paragraph break that makes a mass a mass.
        gap := row.y - cur.lastBottom
        if (cur.body != "")
            cur.body .= (gap > row.h * 0.9) ? "`n`n" : "`n"
        cur.body .= txt
        cur.lastBottom := row.y + row.h
        cur.lineH := row.h
    }
    ; Whole = another header follows it on this screen, or its last line ends
    ; clear of the pane's bottom edge.
    for i, msg in msgs
        msg.complete := (i < msgs.Length)
                     || (msg.lastBottom < pane.y + pane.h - 2 * msg.lineH)

    for msg in msgs {
        if (msg.body = "")
            continue
        key := StrLower(RegExReplace(msg.author msg.stamp, "[^A-Za-z0-9]"))
        if !MMG.best.Has(key) {
            MMG.best[key] := {author: msg.author, stamp: msg.stamp, body: msg.body,
                              complete: msg.complete}
            MMG.order.Push(key)
            continue
        }
        have := MMG.best[key]
        ; A whole read beats a cut one; between two of a kind, the longer wins.
        if (msg.complete && !have.complete)
            || (msg.complete = have.complete && StrLen(msg.body) > StrLen(have.body))
            MMG.best[key] := {author: msg.author, stamp: msg.stamp, body: msg.body,
                              complete: msg.complete}
    }
}

MMG_Scroll(pane) {
    global MMG
    ; WM_MOUSEWHEEL takes SCREEN coordinates of the point to scroll, packed as
    ; 16-bit halves — masked, because a second monitor can make them negative.
    WinGetClientPos(&cx, &cy, , , "ahk_id " MMG.hwnd)
    sx := cx + pane.x + pane.w // 2
    sy := cy + pane.y + pane.h // 2
    notches := MMG_Cfg("GatherWheel", 4)
    wParam := (120 * notches) << 16                  ; positive delta = up
    lParam := ((sy & 0xFFFF) << 16) | (sx & 0xFFFF)
    try PostMessage(0x020A, wParam, lParam, , "ahk_id " MMG.hwnd)
}

; "Today at 3:04 PM" → "2026-11-02 3:04 PM": the file outlives the word "Today".
MMG_Date(stamp) {
    if RegExMatch(stamp, "i)^Today at (.*)$", &m)
        return FormatTime(A_Now, "yyyy-MM-dd") " " m[1]
    if RegExMatch(stamp, "i)^Yesterday at (.*)$", &m)
        return FormatTime(DateAdd(A_Now, -1, "Days"), "yyyy-MM-dd") " " m[1]
    return stamp
}

; Looks like a mass: long enough, and either several paragraphs or a PPV/!mm marker.
MMG_IsMass(body) {
    if (StrLen(body) < MMG_Cfg("GatherMinChars", 80))
        return false
    paras := 1
    pos := 1
    while (pos := InStr(body, "`n`n", , pos)) {
        paras += 1
        pos += 2
    }
    return paras >= MMG_Cfg("GatherMinParas", 2)
        || RegExMatch(body, "im)\bppv\b|^!mm")
}

; Text compared for "already in the file": case and spacing ignored, because two
; OCR reads of one message rarely agree on either.
MMG_Norm(s) {
    return StrLower(RegExReplace(s, "\s+"))
}

MMG_Finish(why) {
    global MMG, MMG_DIR
    SetTimer(MMG_Tick, 0)
    if !MMG.running
        return
    MMG.running := false

    file := MMG_DIR "\" MMG.chan ".txt"
    have := Map()
    if FileExist(file) {
        for block in StrSplit(FileRead(file, "UTF-8"), "===END===") {
            ; Every block but the first starts with the blank lines left after the
            ; previous ===END===; skip them, then drop the [date] [model] line.
            block := LTrim(block, "`r`n")
            p := InStr(block, "`n")
            if p
                have[MMG_Norm(SubStr(block, p + 1))] := true
        }
    }

    ; Read bottom-up, written oldest first.
    out := "", added := 0, skippedShort := 0, dupes := 0, cut := 0
    i := MMG.order.Length
    while (i >= 1) {
        msg := MMG.best[MMG.order[i]]
        i -= 1
        if !MMG_IsMass(msg.body) {
            skippedShort += 1
            continue
        }
        n := MMG_Norm(msg.body)
        if have.Has(n) {
            dupes += 1
            continue
        }
        have[n] := true
        added += 1
        if !msg.complete
            cut += 1
        out .= "[" MMG_Date(msg.stamp) "] [" (MMG.model != "" ? MMG.model : MMG.chan) "] "
             . msg.author (msg.complete ? "" : "  TRUNCATED — longer than the window")
             . "`n" msg.body "`n===END===`n`n"
    }
    if (out != "")
        FileAppend(out, file, "UTF-8")

    LOGI("seq.gather", "finished on #" MMG.chan " — " why ". " MMG.frame " frames, "
                     . MMG.order.Length " messages read, " added " masses saved"
                     . (cut ? " (" cut " truncated)" : "") ", " dupes " already in the file, "
                     . skippedShort " not mass-shaped. → " file)
    MMG_Tip("MM Gatherer: " why "`n" added " new masses saved to gathered\" MMG.chan ".txt"
          . (dupes ? "`n(" dupes " were already there)" : ""), 6000)
}

MMG_Tip(text, ms := 0) {
    ToolTip(text)
    if ms
        SetTimer(ClearImportTip, -ms)
    else
        SetTimer(ClearImportTip, -2500)
}

HK_Bind("seq.mmGather", mmGatherSeq)
