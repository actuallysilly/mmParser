#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings/clip_history.ahk — a small private clipboard history.
; ───────────────────────────────────────────────────────────────────────────────
;  The last N things YOU copied, as a popup at the mouse (gui.clipboard, Ctrl+Win+V
;  by default, or type __clip). 1-9 or a click pastes one; shift-click forgets it.
;
;  Silly's spec (2026-11-28): small, survives restarts, forgets the oldest once
;  it is full (a queue), never records MMA's own pastes. Windows' own history is
;  switched off on this PC because it is not private, so:
;
;  - text only, kept in userdata\clipboard_history.txt on THIS PC, nothing else
;  - copies a password manager marks "do not record" are skipped (the standard
;    ExcludeClipboardContentFromMonitorProcessing / CanIncludeInClipboardHistory
;    / Clipboard Viewer Ignore formats)
;  - MMA's own writes are skipped: every mass, follow-up and hotstring goes out
;    through the clipboard, and would bury real copies within a minute. There are
;    ~40 places that write it, so instead of marking each one the history asks
;    WHO owns the new clipboard: an AutoHotkey script's hidden window is titled
;    with its full path, so a path inside MMA_ROOT means MMA put it there.
;    (Copy buttons in MMA's Python tools, e.g. __lore's Copy, ARE kept: you
;    pressed those on purpose.)
;
;  Lives in the main window's process (CORE_Arm calls CLIP_Arm), the one MMA
;  process that is always up. Size: mass_gui.cfg [Clipboard] Size (default 25).
; ═══════════════════════════════════════════════════════════════════════════════

global CLIP_FILE := MMA_USERDATA "\clipboard_history.txt"
global CLIP_ITEMS := []                  ; newest first
global CLIP_MAX_CHARS := 20000           ; a copy bigger than this is a document, not a clip
global CLIP_PREVIEW := 64

CLIP_Arm() {
    if !FEAT("clipboard")
        return
    CLIP_Load()
    OnClipboardChange(CLIP_OnChange)
    HK_Bind("gui.clipboard", CLIP_Open)
    LOGI("clip", "clipboard history on: " CLIP_ITEMS.Length " item(s), keeps " CLIP_Size())
}

CLIP_Size() {
    n := 25
    try n := Integer(IniRead(MMA_CFG, "Clipboard", "Size", "25"))
    return Max(5, Min(n, 200))
}

; ── recording ─────────────────────────────────────────────────────────────────
CLIP_OnChange(type) {
    if (type != 1)                       ; 1 = text; pictures and files are not kept
        return
    if CLIP_Private()
        return
    if CLIP_OwnerIsMMA()
        return
    t := A_Clipboard
    if (Trim(t, " `t`r`n") = "" || StrLen(t) > CLIP_MAX_CHARS)
        return
    CLIP_Push(t)
}

CLIP_Push(t) {
    global CLIP_ITEMS
    for i, x in CLIP_ITEMS               ; copied again: move it to the top
        if (x == t) {
            CLIP_ITEMS.RemoveAt(i)
            break
        }
    CLIP_ITEMS.InsertAt(1, t)
    while (CLIP_ITEMS.Length > CLIP_Size())
        CLIP_ITEMS.Pop()                 ; full: the oldest goes
    CLIP_Save()
}

; A password manager (or anything else) asked clipboard watchers to look away.
CLIP_Private() {
    for name in ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore",
                 "CanIncludeInClipboardHistory"] {
        fmt := DllCall("RegisterClipboardFormat", "str", name, "uint")
        if (fmt && DllCall("IsClipboardFormatAvailable", "uint", fmt))
            return true
    }
    return false
}

; Did one of MMA's own scripts write this?
CLIP_OwnerIsMMA() {
    h := DllCall("GetClipboardOwner", "ptr")
    if !h
        return false
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    title := ""
    try title := WinGetTitle("ahk_id " h)
    DetectHiddenWindows prev
    return (title != "" && InStr(title, MMA_ROOT "\"))
}

; ── the file: one item per line, \ \n \r escaped ──────────────────────────────
CLIP_Load() {
    global CLIP_ITEMS
    CLIP_ITEMS := []
    if !FileExist(CLIP_FILE)
        return
    try txt := FileRead(CLIP_FILE, "UTF-8")
    catch
        return
    for line in StrSplit(txt, "`n", "`r")
        if (line != "")
            CLIP_ITEMS.Push(CLIP_Unescape(line))
    while (CLIP_ITEMS.Length > CLIP_Size())
        CLIP_ITEMS.Pop()
}

CLIP_Save() {
    out := ""
    for x in CLIP_ITEMS
        out .= CLIP_Escape(x) "`n"
    tmp := CLIP_FILE ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(out)
        f.Close()
        FileMove(tmp, CLIP_FILE, true)
    } catch as e {
        LOGW("clip", "could not save the clipboard history: " e.Message)
    }
}

CLIP_Escape(s) {
    return StrReplace(StrReplace(StrReplace(s, "\", "\\"), "`n", "\n"), "`r", "\r")
}

CLIP_Unescape(s) {
    out := "", i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "\" && i < n) {
            d := SubStr(s, i + 1, 1)
            out .= (d == "n") ? "`n" : (d == "r") ? "`r" : d
            i += 2
            continue
        }
        out .= c
        i++
    }
    return out
}

; ── the popup ─────────────────────────────────────────────────────────────────
CLIP_Open(*) {
    USAGE_Note("key", "gui.clipboard.open")
    m := Menu()
    if !CLIP_ITEMS.Length {
        m.Add("Nothing copied yet", (*) => 0)
        m.Disable("Nothing copied yet")
    }
    for i, x in CLIP_ITEMS {
        flat := Trim(RegExReplace(x, "\s+", " "))
        if (StrLen(flat) > CLIP_PREVIEW)
            flat := SubStr(flat, 1, CLIP_PREVIEW) Chr(0x2026)
        lead := (i <= 9) ? "&" i : i
        m.Add(lead "   " StrReplace(flat, "&", "&&"), CLIP_Pick.Bind(i))
    }
    m.Add()
    if CLIP_ITEMS.Length
        m.Add("Clear history", (*) => CLIP_Clear())
    cap := "click or 1-9 pastes · shift-click forgets one"
    m.Add(cap, (*) => 0)
    m.Disable(cap)
    m.Show()
}

CLIP_Pick(i, *) {
    global CLIP_ITEMS
    if (i > CLIP_ITEMS.Length)
        return
    t := CLIP_ITEMS[i]
    if GetKeyState("Shift", "P") {
        CLIP_ITEMS.RemoveAt(i)
        CLIP_Save()
        ToolTip("forgotten")
        SetTimer(() => ToolTip(), -1200)
        return
    }
    A_Clipboard := t                     ; owned by this script: not re-recorded
    if !ClipWait(1)
        return
    Send("^v")
    CLIP_ITEMS.RemoveAt(i)               ; used: back to the top
    CLIP_ITEMS.InsertAt(1, t)
    CLIP_Save()
}

CLIP_Clear() {
    global CLIP_ITEMS
    CLIP_ITEMS := []
    CLIP_Save()
}
