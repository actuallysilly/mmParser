#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  hotstrings/quick_menu.ahk — the pinned and recent hotstrings, at the cursor.
; ───────────────────────────────────────────────────────────────────────────────
;  One key, a popup where the mouse is, and the ten or so messages you actually
;  send. Click one and it goes out exactly as its trigger would; shift-click one
;  to pin or unpin it; press 1-9 for the first nine rows without leaving the
;  keyboard.
;
;  The problem it solves is the library's size. ~120 triggers is far past what
;  anybody remembers, and the two ways in before this were both slow: type an
;  abbreviation you have to recall exactly, or open the manager and search. A
;  key bound per hotstring (see HotstringKeys_Register in core\utils.ahk) is the
;  right answer for the five you send all day and runs out of chords after that.
;  This is the layer between: no memorised abbreviation, no window, no key of
;  its own per message.
;
;  ─── PINNED VS RECENT, AND WHY BOTH ──────────────────────────────────────────
;  Recency alone gets the ordering wrong for the message you send twice a day —
;  it is exactly the one that falls off a most-recent list, and exactly the one
;  worth a menu. Pins are the fix and they are manual on purpose: MMA is not
;  guessing at frequency, you are telling it. See hotstrings\usage.ahk for the
;  store both lists come out of.
;
;  ─── IT SENDS THROUGH THE ORDINARY PATH ──────────────────────────────────────
;  Nothing here knows how to send. A row resolves to a RECORD out of the same
;  index the manager reads (hotstrings\index.ahk) and hands it to Hotstring_Fire
;  in core\utils.ahk — the one function that answers "send the hotstring named
;  X", shared with the per-hotstring keys. So an OVERLOADED trigger still asks
;  (or still picks at random) from this menu, and your words have one copy: the
;  one in your .ahk file.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "index.ahk"
#Include "overloads.ahk"
#Include "usage.ahk"
; HK_Bind, and the id declared in the [gui] section there.
#Include "../core/hotkeys.ahk"
; Hotstring_Fire. The include is CIRCULAR — utils.ahk names this file too, since
; it is what pulls the menu into every message script — and that is fine: AHK
; loads a given file once however many times it is named, so whichever is reached
; first wins and the other is a no-op. Same arrangement as core\paths.ahk and
; core\log.ahk. Saying it out loud is what stops the next person deleting one
; side of it as "redundant".
#Include "../core/utils.ahk"

; How many recent rows the menu offers. Chosen to keep the whole popup readable
; without scrolling once the pins are on top of it — a menu you have to scroll is
; a window, and there is already a window.
global HSQ_RECENT_MAX := 12
; How much of the message each row shows. Long enough to tell two openers apart,
; short enough that the popup does not become a paragraph.
global HSQ_PREVIEW_LEN := 58

; ── which script owns the key ─────────────────────────────────────────────────
;  Exactly one, and it has to be decided WITHOUT asking what is running.
;
;  Every message file is a separate process and every one of them #Includes
;  core\utils.ahk, so this file loads in all of them. Bind the key in each and
;  the menu opens three times, once per script, each covering the whole library
;  — three identical popups stacked on one another.
;
;  So ownership is a rule, not a race: the FIRST file HSI_Files() lists owns it.
;  That is general.ahk wherever it exists (the shared library, and the file
;  Settings' own help calls the one that belongs on the startup list), and the
;  first account file otherwise. Every process computes the same list from the
;  same folder, so every process reaches the same answer and exactly one of them
;  answers "me".
;
;  The menu is not limited to the owner's own hotstrings — it indexes the whole
;  library and sends any of it, exactly as a per-hotstring key does. Ownership is
;  only about which process draws the popup.
HSQ_OwnerFile() {
    files := HSI_Files()
    return files.Length ? OL_BaseName(files[1]) : ""
}

HSQ_Register() {
    own := HSQ_OwnerFile()
    if (own = "") {
        LOGW("hs.menu", "content\\ holds no message files, so nothing can own the"
                      . " quick menu key — it will not open")
        return
    }
    if (StrLower(own) != StrLower(A_ScriptName)) {
        LOGV("hs.menu", A_ScriptName " does not own the quick menu (" own " does)")
        return
    }
    HK_Bind("gui.hotstringMenu", HSQ_Open)
    LOGI("hs.menu", A_ScriptName " owns the hotstrings quick menu key")
}

; The bound handler. Separate from HSQ_Show so the menu can also be opened from
; code that has no key behind it.
HSQ_Open(*) {
    HSQ_Show()
}

; ── the popup ─────────────────────────────────────────────────────────────────

HSQ_Show() {
    global HSQ_RECENT_MAX

    ; Rebuilt on every open, deliberately. The alternative is a cached index that
    ; goes stale the moment you add or reword a hotstring in the manager — and
    ; the manager is a separate process, so there is nothing to invalidate it
    ; with. Six small files parsed while a menu is opening is not a cost anyone
    ; can feel; a menu that sends last week's wording is.
    byTrigger := Map()
    for r in HSI_Build()
        byTrigger[StrLower(r.trigger)] := r

    pinned := HSU_Pinned()
    seen   := Map()
    for _, pn in pinned
        seen[StrLower(pn.trigger)] := true

    recent := []
    for _, u in HSU_Recent(HSQ_RECENT_MAX + pinned.Length) {
        if seen.Has(StrLower(u.trigger))         ; a pin is already on the menu
            continue
        recent.Push(u)
        if (recent.Length >= HSQ_RECENT_MAX)
            break
    }

    m := Menu()
    n := 0
    if pinned.Length {
        HSQ_Header(m, "Pinned")
        for _, pn in pinned
            n := HSQ_Row(m, n, byTrigger, pn.trigger)
    }
    if recent.Length {
        if pinned.Length
            m.Add()
        HSQ_Header(m, "Recently used")
        for _, u in recent
            n := HSQ_Row(m, n, byTrigger, u.trigger)
    }
    if !n {
        ; The honest empty state. Nothing has fired yet on this install and
        ; nothing is pinned, so a bare "Manage hotstrings" popup would read as
        ; the feature being broken rather than as it being new.
        HSQ_Header(m, "Nothing here yet " Chr(0x2014) " send a hotstring, or pin"
                    . " one in the manager")
        LOGV("hs.menu", "opened with nothing to show: no recorded uses and no pins")
    }

    m.Add()
    m.Add("Manage hotstrings" Chr(0x2026), (*) => HSQ_OpenManager())
    ; The one instruction the menu cannot show per row without doubling its
    ; width. Disabled, so it reads as a caption rather than something to click.
    HSQ_Header(m, "shift-click a row to pin / unpin it")

    LOGV("hs.menu", "showing " pinned.Length " pinned and " recent.Length
                  . " recent hotstring(s)")
    m.Show()
}

; A caption row: present, unclickable, and never confusable with a message.
;
; Menu item text is also the item's IDENTITY, so two rows may not share it. The
; captions are distinct strings and every message row carries its own index, so
; nothing here can collide.
HSQ_Header(m, text) {
    m.Add(HSQ_Escape(text), (*) => 0)
    m.Disable(HSQ_Escape(text))
}

; Add one hotstring row, returning the running row number.
;
; A trigger with no record is a DANGLING pin — pinned once, then deleted or
; renamed in a file MMA was not watching. It is shown, disabled, saying so: the
; alternative is silently dropping it, which looks like the pin never took.
HSQ_Row(m, n, byTrigger, trigger) {
    global HSQ_PREVIEW_LEN
    key := StrLower(trigger)
    n++
    ; 1-9 get a real accelerator, so the common case never needs the mouse.
    ; Beyond nine the number is still printed — it is what makes the item text
    ; unique — it just is not a shortcut.
    lead := (n <= 9) ? "&" n : n
    if !byTrigger.Has(key) {
        txt := lead "   " HSQ_Escape(trigger) "   "
             . Chr(0x2014) " not in the library any more"
        m.Add(txt, (*) => 0)
        m.Disable(txt)
        return n
    }
    r := byTrigger[key]
    prev := HSQ_Flat(r.preview)
    if (StrLen(prev) > HSQ_PREVIEW_LEN)
        prev := SubStr(prev, 1, HSQ_PREVIEW_LEN) Chr(0x2026)
    if (prev = "")
        prev := "(empty)"
    m.Add(lead "   " HSQ_Escape(r.trigger) "   " Chr(0x00B7) "   " HSQ_Escape(prev),
          HSQ_Pick.Bind(r))
    return n
}

; What a row does when you choose it.
;
; Shift is read PHYSICALLY and after the fact: the menu has already closed by the
; time this runs, and what matters is whether the key is still held, not whether
; some earlier thread saw it down.
HSQ_Pick(rec, *) {
    if GetKeyState("Shift", "P") {
        nowPinned := HSU_TogglePin(rec.trigger)
        ToolTip(rec.trigger (nowPinned ? "  pinned" : "  unpinned"))
        SetTimer(HSQ_ClearTip, -1400)
        return
    }
    Hotstring_Fire(rec.trigger, rec, "the quick menu")
}

HSQ_ClearTip() {
    ToolTip()
}

; Menu item text uses "&" for its accelerators, so a message containing one would
; both lose the character and claim a shortcut nobody asked for. Doubling it is
; how Windows spells a literal ampersand in a menu.
HSQ_Escape(s) {
    return StrReplace(s, "&", "&&")
}

; A record's preview is already one line in the manager's list, but it is built
; from source and a hand-written body can carry a real newline through it. A
; menu item is one line whatever you give it, so fold them here rather than
; letting Windows decide what to do with the rest.
HSQ_Flat(s) {
    return StrReplace(StrReplace(s, "`r", " "), "`n", " ")
}

; Open the manager, the same way the main window's button does: it is
; #SingleInstance, so a second press refreshes the one that is up rather than
; stacking windows.
HSQ_OpenManager() {
    path := MMA_SRC "\ui\hotstrings_window.ahk"
    if !FileExist(path) {
        LOGE("hs.menu", "the Hotstrings manager is not where it should be, so the"
                      . " menu's last row does nothing",
                      "expected " path)
        return
    }
    try Run(A_AhkPath ' "' path '"')
}
