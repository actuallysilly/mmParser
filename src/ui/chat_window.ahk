#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/log.ahk"
#Include "../core/theme.ahk"
#Include "../core/crashlog.ahk"
#Include "../core/modes.ahk"
; MASS_Load / MASS_Save / MASS_Get / MASS_Fields — the library and its shape.
#Include "../mass/store.ahk"
; MASS_Transcript / BranchList — what this window draws. NOT worked out here: see
; the header of mass\shape.ahk for why the rules live in one place.
#Include "../mass/shape.ahk"
; The fan's half of the conversation.
#Include "../mass/sim_notes.ahk"
; MMA_MSG_MASSES_CHANGED, and HK_Broadcast to send it. core\hotkeys.ahk binds
; nothing unless something calls HK_Bind, so including it costs no keys.
#Include "../core/messages.ahk"
#Include "../core/hotkeys.ahk"
#Include "../vendor/json.ahk"
; thqby's WebView2 wrapper — finds WebView2Loader.dll beside itself and the Edge
; runtime from its install root, and pulls in ComVar.ahk / Promise.ahk itself.
#Include "../vendor/WebView2/WebView2.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  chat_window.ahk — the chat simulator: your mass, as the conversation it becomes.
; ───────────────────────────────────────────────────────────────────────────────
;  The GUI edits a mass as a GRID OF BOXES: mass, fu1, fu1_5, fu1_7, fu2 … Every
;  one of those boxes is correct and none of them tells you the thing you need to
;  know, which is what the fan actually sees:
;
;    * how many messages this is. Three boxes under "F1" are three MESSAGES, one
;      after another, ~1.5s apart — unless FuSingle is on for that model and
;      group, in which case they are one message with line breaks. You cannot see
;      which from the boxes.
;    * that the opener and the PPV blurb are PASTED and not sent, so they sit in
;      the chat box waiting for you, while everything else goes out on its own.
;    * that an empty f3 is not silence — it is the DefaultFu3 text from Settings.
;    * what a branch actually changes, given a branch answers the groups it has
;      wording for and the trunk answers the rest.
;
;  So this window draws the transcript, in send order, and lets you edit the mass
;  from inside it. It is the same work the GUI's boxes do, in the shape the work
;  is actually for.
;
;  ─── THE FAN REPLIES ─────────────────────────────────────────────────────────
;  You can write the fan's lines in between. They send nothing and they are not
;  part of the mass (mass\sim_notes.ahk says why they are their own file). They
;  exist so f2 is written against something rather than into the air.
;
;  ─── WHO OWNS WHAT ───────────────────────────────────────────────────────────
;      the page   owns what you are TYPING, while you are typing it
;      this file  owns masses.json, chat_sim.json, and the transcript
;
;  The page never works out what a mass sends. It asks, and renders the answer —
;  the same promise the branch builder makes about compiling, and for the same
;  reason: a JavaScript copy of the send rules would be faster and would be wrong
;  within a week. MASS_Transcript is the only thing that decides.
;
;  That split is also why there are two ways to reach the page. `load` replaces
;  everything and is sent when the mass CHANGES (open, model, slot, branch, an
;  outside edit); `derived` sends only the transcript and the counts, and is sent
;  while you type — because a full load would reset the textarea you are in and
;  put the caret back at the start of it.
;
;  ─── THE BRIDGE ──────────────────────────────────────────────────────────────
;      page → AHK   postMessage {cmd: ready | pick | field | append | reply
;                                     | save | copy | reload | pageerror}
;      AHK  → page  window.mma.load / .derived / .appended / .toast
;
;  Nothing may ExecuteScript before the page posts `ready` — until then
;  `window.mma` does not exist and the call lands on a document that cannot
;  answer, silently, because a script error inside the WebView goes to the page's
;  console and nowhere this process can see.
;
;  ─── IT IS A SECOND WRITER OF masses.json, AND THAT IS DELIBERATE ────────────
;  So is the branch builder. The rule both follow: read the file, change one
;  record, write it back — never hold a document across an edit. The main window
;  can be saving too, and the loser of that race loses one keystroke rather than
;  a library. After a write this posts MMA_MSG_MASSES_CHANGED so the engine
;  re-reads, which is what makes an edit here take effect on the next key press
;  instead of on the next restart.
; ═══════════════════════════════════════════════════════════════════════════════

; Assigned before the window exists: g.Show() fires Size and CW_OnSize reads wvc.
wvc      := 0
wv       := 0
wvMsgTok := 0
CW_Ready := false

; What the window is looking at. The record is a working copy: it is loaded from
; masses.json, edited in place as you type, and written back on a debounce.
CW_Model   := 1
CW_Slot    := 1
CW_Branch  := 0
CW_Rec     := 0        ; the mass record being edited (an object, per MASS_Get)
CW_Notes   := 0        ; the whole chat_sim.json doc
CW_Replies := Map()    ; this mass's fan lines, beat key -> text

pal := THEME_Set()
g := Gui("+Resize +MinSize980x640", "MMA Chat simulator")
g.MarginX := 0
g.MarginY := 0
g.BackColor := (pal.win = "") ? "Default" : pal.win
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", pal.dark ? 1 : 0, "int", 4)
g.OnEvent("Size", CW_OnSize)
; Closing is safe: every edit is already written on its debounce, and the one in
; flight is flushed here. There is nothing to ask about.
g.OnEvent("Close", CW_Close)
g.Show("w1400 h900")

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    LOGE("cw.win", "WebView2 would not start — the chat simulator cannot open",
                   LOG_Err(e))
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nThe chat simulator is drawn by the Microsoft Edge WebView2"
         . " Runtime, which ships with Windows 11. Install it from Microsoft if"
         . " this machine has had it removed.`n`nYour masses are unaffected —"
         . " they are still editable in the main window.",
           "MMA — Chat simulator", 0x10)
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false

; add_, not the wrapper's shorthand — that returns an object whose only job is to
; unregister on destruction using a raw copy of the core pointer taken without an
; AddRef, which crashes on shutdown. See webview_main_window.ahk for the measured
; version of this.
wvMsgTok := wv.add_WebMessageReceived(CW_OnMessage)

wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/chat_sim.html")

; ═══════════════════════════════════════════════════════════════════════════════
;  Loading a mass into the window
; ═══════════════════════════════════════════════════════════════════════════════

; Read model/slot off disk into the working copy, and pick up its fan lines.
;
; Re-read every time rather than kept in a document: the main window and the
; branch builder both write masses.json, and this window is often open beside
; one of them. What it shows should be what is on disk.
CW_LoadMass() {
    global CW_Model, CW_Slot, CW_Rec, CW_Notes, CW_Replies, CW_Branch
    doc := MASS_Load()
    CW_Model := Max(1, Min(CW_Model, MASS_MODELS))
    CW_Slot  := Max(1, Min(CW_Slot,  MASS_SLOTS))
    ; AsObject, because everything downstream of here — MASS_Transcript,
    ; BranchList, MASS_FuParts — reads a mass with m.fu1 and m.HasOwnProp(),
    ; and what comes out of masses.json is a Map. The send path converts at
    ; exactly this boundary too (see CurMass); this window is the first thing
    ; that also has to convert BACK, on save.
    CW_Rec   := MASS_AsObject(MASS_Get(doc, CW_Model, CW_Slot))

    CW_Notes := SIM_Load()
    n := SIM_For(CW_Notes, CW_Model, CW_Slot)
    CW_Replies := n["replies"]
    ; The branch this slot was last read on. Clamped against the branches that
    ; exist NOW — a saved selection outlives the branch it named the moment you
    ; empty that branch's fields, and indexing past the end would throw.
    b := n["branch"]
    CW_Branch := (b >= 1 && b <= BranchList(CW_Rec).Length) ? b : 0
}

; Everything the page needs to draw itself.
CW_State() {
    global CW_Model, CW_Slot, CW_Branch, CW_Rec, CW_Replies

    models := []
    Loop MASS_MODELS
        models.Push(Map("no", A_Index, "name", CW_ModelName(A_Index)))

    branches := [Map("no", 0, "name", "trunk")]
    for i, b in BranchList(CW_Rec)
        branches.Push(Map("no", i, "name", b.name))

    replies := Map()
    for k, v in CW_Replies
        replies[k] := v

    return Map(
        "models",   models,
        "model",    CW_Model,
        "slots",    MASS_SLOTS,
        "slot",     CW_Slot,
        "branches", branches,
        "branch",   CW_Branch,
        "fields",   CW_FieldMap(),
        "replies",  replies,
        ; The pause the engine takes between the parts of one send. Shown between
        ; the bubbles, because "three messages" and "three messages over four and
        ; a half seconds" are different things to read.
        "waitMs",     LOG_IniInt(MMA_CFG, "Settings", "WaitTime", 1500),
        "slots_count", MASS_SLOTS,
        "beats",      CW_Beats(),
        "counts",     CW_Counts(),
        "slots",      CW_Slots(),
        "nextSlot",   CW_NextSlotId())
}

; The ordered places the composer can write, with whether each already has text.
; MASS_WriteSlots decides which they are and what they are called; this only adds
; `filled`, which is the one part that depends on the record rather than on the
; shape of a mass.
CW_Slots() {
    global CW_Rec, CW_Branch
    out := []
    for _, sl in MASS_WriteSlots(CW_Rec, CW_Branch) {
        cur := CW_Rec.HasOwnProp(sl.field) ? CW_Rec.%sl.field% : ""
        out.Push(Map("id", sl.id, "field", sl.field, "beat", sl.beat,
                     "label", sl.label, "kind", sl.kind, "mode", sl.mode,
                     "filled", Trim(cur) != "" ? true : false))
    }
    return out
}

; Which slot "the next response" means, or "" when the mass is full.
CW_NextSlotId() {
    global CW_Rec, CW_Branch
    n := MASS_NextEmptySlot(CW_Rec, CW_Branch)
    return IsObject(n) ? n.id : ""
}

; The transcript, as plain Maps the page can read.
CW_Beats() {
    global CW_Rec, CW_Model, CW_Branch
    out := []
    for _, b in MASS_Transcript(CW_Rec, CW_Model, CW_Branch) {
        msgs := []
        for _, msg in b.messages {
            flds := []
            for _, f in msg.fields
                flds.Push(f)
            msgs.Push(Map("text", msg.text, "fields", flds))
        }
        out.Push(Map("key", b.key, "label", b.label, "kind", b.kind,
                     "note", b.note, "messages", msgs))
    }
    return out
}

CW_Counts() {
    global CW_Rec, CW_Model, CW_Branch
    c := MASS_TranscriptCounts(MASS_Transcript(CW_Rec, CW_Model, CW_Branch))
    return Map("sent", c.sent, "pasted", c.pasted, "chars", c.chars)
}

; A model's name, from the cfg the rest of MMA reads it from.
CW_ModelName(n) {
    v := Trim(IniRead(MMA_CFG, "Settings", "Model" n, ""))
    return (v = "") ? ("Model " n) : v
}

; ── the two pushes ──────────────────────────────────────────────────
;  Both LOG a failure rather than swallowing it. A bare `try` around the whole
;  line covers TWO different things — the ExecuteScript, and building the state
;  that goes into it — and it was the second that failed first: a mass record
;  handed over as a Map instead of an object threw inside JSON.Stringify, the
;  try ate it, and the window came up correct, silent and completely blank.
;  Between this and the page's own error hook, both ends of the bridge now say
;  when they break.
CW_Push() {
    global wv, CW_Ready
    if !CW_Ready
        return
    try {
        js := "window.mma.load(" JSON.Stringify(CW_State()) ")"
    } catch as e {
        LOGE("cw.push", "could not build the window's state — it is showing"
                      . " nothing, or the last thing it was sent", LOG_Err(e))
        return
    }
    try wv.ExecuteScriptAsync(js)
    catch as e
        LOGE("cw.push", "the page would not take the state", LOG_Err(e))
}

; Only the parts that change while you type. See the header for why this is not
; a CW_Push: a full load replaces the editor's DOM and takes the caret with it.
CW_PushDerived() {
    global wv, CW_Ready
    if !CW_Ready
        return
    try {
        js := "window.mma.derived("
            . JSON.Stringify(Map("beats",    CW_Beats(),
                                 "counts",   CW_Counts(),
                                 "slots",    CW_Slots(),
                                 "nextSlot", CW_NextSlotId())) ")"
    } catch as e {
        LOGE("cw.push", "could not rebuild the transcript — the chat pane is"
                      . " now STALE and does not match what you are typing",
                      LOG_Err(e))
        return
    }
    try wv.ExecuteScriptAsync(js)
}

CW_Toast(msg) {
    global wv, CW_Ready
    if !CW_Ready
        return
    try wv.ExecuteScriptAsync("window.mma.toast(" JSON.Stringify(msg) ")")
}

CW_Theme() {
    global wv, CW_Ready
    if !CW_Ready
        return
    ; Classic defers to Windows, and the page's own prefers-color-scheme already
    ; does that — so classic is the one theme this must NOT stamp.
    if THEME_Is("classic")
        return
    try wv.ExecuteScriptAsync("window.mma.theme(" (THEME_Set().dark ? "true" : "false") ")")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Saving
; ───────────────────────────────────────────────────────────────────────────────
;  Both files are written on a debounce driven from the page, so a save is one
;  per pause rather than one per keystroke. The timer below is the safety net for
;  the case the page cannot fire: the window closing.
; ═══════════════════════════════════════════════════════════════════════════════

CW_Dirty := false

; Write the working record back into masses.json.
;
; Read-modify-write, never a held document. The main window is very often open
; beside this one and it saves the WHOLE library; holding a doc across an edit
; here would write that stale whole library back over its work.
CW_SaveMass() {
    global CW_Model, CW_Slot, CW_Rec, CW_Dirty
    doc := MASS_Load()
    ; AsMap, and it is load-bearing: MASS_Normalise keeps a record only if it
    ; `is Map`, so storing the object form silently writes a BLANK mass and the
    ; edit looks saved until you reopen it.
    MASS_Set(doc, CW_Model, CW_Slot, MASS_AsMap(CW_Rec))
    if !MASS_Save(doc) {
        CW_Toast("could not write masses.json")
        return false
    }
    CW_Dirty := false
    ; The engine keeps the library in memory and re-reads on this message. Without
    ; it an edit here would be correct on disk and invisible to the next key press
    ; — which reads exactly like the edit not having saved.
    try HK_Broadcast(MMA_MSG_MASSES_CHANGED)
    return true
}

; Write a composed message into the slot the page named.
;
; The slot list is rebuilt here rather than trusted from the page: the page's copy
; is as old as its last render, and the field a stale id names is a field this
; would otherwise overwrite without being asked to.
CW_Append(slotId, text) {
    global CW_Rec, CW_Branch, CW_Dirty, wv, CW_Ready
    hit := 0
    for _, sl in MASS_WriteSlots(CW_Rec, CW_Branch)
        if (sl.id = slotId)
            hit := sl
    if !hit {
        LOGW("cw.append", "the page asked to write slot '" slotId "', which this"
                        . " mass does not have — ignored. (Did the branch change"
                        . " under it?)")
        CW_Toast("that slot is not part of this mass any more")
        return
    }
    cur := CW_Rec.HasOwnProp(hit.field) ? CW_Rec.%hit.field% : ""
    CW_Rec.%hit.field% := MASS_SlotWrite(cur, text, hit.mode)
    CW_Dirty := true
    LOGI("cw.append", "wrote " StrLen(text) " chars into " hit.field
                    . " (" hit.label ", " hit.mode ")")

    ; A full redraw, not a derived push: the conversation gained a turn, so the
    ; bubbles themselves changed rather than just the numbers beside them.
    if !CW_Ready
        return
    try {
        js := "window.mma.appended("
            . JSON.Stringify(Map("beats",    CW_Beats(),
                                 "counts",   CW_Counts(),
                                 "slots",    CW_Slots(),
                                 "nextSlot", CW_NextSlotId(),
                                 "fields",   CW_FieldMap())) ")"
    } catch as e {
        LOGE("cw.append", "wrote the message but could not rebuild the view —"
                        . " press Reload to see it", LOG_Err(e))
        return
    }
    try wv.ExecuteScriptAsync(js)
}

; The whole record as the page sees it. Its own function because two pushes want
; it and a mass has enough fields that spelling the loop out twice would drift.
CW_FieldMap() {
    global CW_Rec
    out := Map()
    for f in MASS_Fields()
        out[f] := CW_Rec.HasOwnProp(f) ? CW_Rec.%f% : ""
    return out
}

CW_SaveNotes() {
    global CW_Notes, CW_Model, CW_Slot, CW_Replies, CW_Branch
    SIM_Set(CW_Notes, CW_Model, CW_Slot, CW_Replies, CW_Branch)
    SIM_SetLastAt(CW_Notes, CW_Model, CW_Slot)
    SIM_Save(CW_Notes)
}

CW_Close(*) {
    global CW_Dirty
    ; The debounce in the page may not have fired yet. Losing the last sentence
    ; you typed because you closed the window is not a trade worth making.
    if CW_Dirty
        CW_SaveMass()
    CW_SaveNotes()
    ExitApp()
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The bridge
; ═══════════════════════════════════════════════════════════════════════════════

CW_OnMessage(sender, args) {
    global CW_Ready, CW_Rec, CW_Model, CW_Slot, CW_Branch, CW_Replies, CW_Dirty
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("cw.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""

    switch cmd {
        case "ready":
            CW_Ready := true
            CW_Theme()
            ; Open where you left off. Writing a mass is not a one-sitting job,
            ; and coming back to model 1 slot 1 every time is a small tax on
            ; exactly the person who uses this window most.
            _at := SIM_LastAt(SIM_Load())
            CW_Model := CW_Int(_at["model"], 1, 1, MASS_MODELS)
            CW_Slot  := CW_Int(_at["slot"],  1, 1, MASS_SLOTS)
            CW_LoadMass()
            CW_Push()
            LOG_Kv("cw.win", Map("model", CW_Model, "slot", CW_Slot,
                                 "branch", CW_Branch,
                                 "branches", BranchList(CW_Rec).Length))

        ; Which mass to look at, and on which branch. Any of the three may be
        ; absent — the page sends what changed.
        case "pick":
            if CW_Dirty
                CW_SaveMass()
            CW_SaveNotes()
            if m.Has("model")
                CW_Model := CW_Int(m["model"], CW_Model, 1, MASS_MODELS)
            if m.Has("slot")
                CW_Slot := CW_Int(m["slot"], CW_Slot, 1, MASS_SLOTS)
            CW_LoadMass()
            ; Branch is applied AFTER the load, which resets it to what the notes
            ; remembered — an explicit pick has to win over that.
            if m.Has("branch")
                CW_Branch := CW_Int(m["branch"], 0, 0, BranchList(CW_Rec).Length)
            CW_Push()

        ; One field of the mass, as you type it.
        case "field":
            if (!m.Has("field") || !m.Has("value"))
                return
            f := String(m["field"])
            if !CW_IsField(f) {
                LOGW("cw.msg", "the page tried to write '" f "', which is not a"
                             . " field of a mass — ignored")
                return
            }
            CW_Rec.%f% := String(m["value"])
            CW_Dirty := true
            ; The transcript changes with the field, so it is recomputed here
            ; rather than by the page. This is the load-bearing line of the whole
            ; window: what you see is what MASS_Transcript says, always.
            CW_PushDerived()

        ; The composer's Send: a whole new message, into a named slot.
        ;
        ; Separate from "field" because it is not the same act. "field" is you
        ; editing a bubble that exists; this is the mass gaining a message, which
        ; changes which slot is next and therefore redraws the conversation.
        case "append":
            if (!m.Has("slot") || !m.Has("value"))
                return
            CW_Append(String(m["slot"]), String(m["value"]))

        ; One fan line, as you type it. Never saved into the mass.
        case "reply":
            if !m.Has("beat")
                return
            CW_Replies[String(m["beat"])] := m.Has("value") ? String(m["value"]) : ""

        ; The page's debounce came due.
        case "save":
            if CW_Dirty
                CW_SaveMass()
            CW_SaveNotes()

        ; The whole conversation, as text, for pasting somewhere else.
        case "copy":
            CW_CopyTranscript()

        ; Somebody edited the mass elsewhere and wants this window to catch up.
        case "reload":
            if CW_Dirty
                CW_SaveMass()
            CW_LoadMass()
            CW_Push()
            CW_Toast("reloaded from masses.json")

        ; A JavaScript error inside the WebView. It is reported here because
        ; the alternative is the page silently drawing nothing — which is
        ; indistinguishable from this process never having sent it anything,
        ; and cost an hour the first time it happened.
        case "pageerror":
            LOGE("cw.page", "the page threw — it may be showing nothing or"
                          . " showing stale state",
                          (m.Has("msg") ? m["msg"] : "?")
                        . (m.Has("at") && m["at"] != "" ? "   at " m["at"] : ""))

        default:
            LOGW("cw.msg", "unknown command from the page: '" cmd "'")
    }
}

; An integer from the page, clamped. The page sends strings, and a dropdown can
; hold a stale value after the library changes shape under it.
CW_Int(v, fallback, lo, hi) {
    n := fallback
    try n := Integer(v)
    catch
        return fallback
    return (n < lo || n > hi) ? fallback : n
}

; Is this the name of a field a mass actually has? The page is the only caller,
; and a page is the one place a name can arrive from that nobody typed on
; purpose. Writing an unknown property onto the record would be silently kept in
; memory and silently dropped by MASS_Save's normalise, which is the worst of
; both — it looks saved until you reopen.
CW_IsField(name) {
    static known := 0
    if !known {
        known := Map()
        for f in MASS_Fields()
            known[f] := true
    }
    return known.Has(name)
}

; The transcript as plain text, on the clipboard.
;
; Includes the fan lines and the beat labels, because the thing people want to
; paste into a chat with their manager is the CONVERSATION, not the field dump —
; the field dump is what `Export !mma` already produces.
CW_CopyTranscript() {
    global CW_Rec, CW_Model, CW_Branch, CW_Replies
    out := ""
    for _, b in MASS_Transcript(CW_Rec, CW_Model, CW_Branch) {
        if b.messages.Length {
            out .= (out = "" ? "" : "`r`n") "[" b.label
                 . (b.kind = "paste" ? " — pasted" : "") "]`r`n"
            for _, msg in b.messages
                out .= "  " StrReplace(msg.text, "`n", "`r`n  ") "`r`n"
        }
        if (CW_Replies.Has(b.key) && Trim(CW_Replies[b.key]) != "")
            out .= "`r`n  [fan]  " CW_Replies[b.key] "`r`n"
    }
    if (Trim(out) = "") {
        CW_Toast("nothing to copy — this mass is empty")
        return
    }
    A_Clipboard := out
    if !ClipWait(1) {
        CW_Toast("the clipboard would not take it")
        return
    }
    CW_Toast("the conversation is on the clipboard")
    LOGI("cw.copy", "copied the " CW_Model "/" CW_Slot " transcript ("
                  . StrLen(out) " chars)")
}

; The WebView has no window of its own to resize — it is told its bounds.
CW_OnSize(gObj, minMax, w, h) {
    global wvc
    if (minMax = -1 || !IsObject(wvc))
        return
    try wvc.Bounds := [0, 0, w, h]
}
