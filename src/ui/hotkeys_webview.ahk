#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/log.ahk"
#Include "../core/theme.ahk"
#Include "../core/crashlog.ahk"
; The registry (HK_META / HK_ORDER / HK_SECTIONS) and the ini anchors, plus the
; editor rules both hotkey windows share — the capture, the pretty names, the
; clash test, the save.
#Include "hotkeys_core.ahk"
#Include "../vendor/json.ahk"
; thqby's WebView2 wrapper — finds WebView2Loader.dll beside itself and the Edge
; runtime from its install root, and pulls in ComVar.ahk / Promise.ahk itself.
#Include "../vendor/WebView2/WebView2.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  hotkeys_webview.ahk — the hotkey editor, drawn by Edge.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own PROCESS, like the WebView Settings and the branch builder: it carries
;  a WebView2, and nothing else in MMA should ever wait on an Edge runtime
;  starting. ui\hotkeys_window.ahk (the Win32 one, and the same panel the Settings
;  window's Hotkeys tab embeds) is untouched and stays — it is the fallback, and
;  it is still the thing to run when the main GUI will not start.
;
;  ─── THE KEYSTROKES ARE NOT READ BY THE BROWSER ──────────────────────────────
;  A hotkey editor in a web page sounds like a fight with the browser over every
;  keystroke, and it would be, if the page were the one listening. It is not.
;
;  The capture is HKP_Capture in hotkeys_core.ahk — the SAME InputHook and the
;  same seven temporary mouse hotkeys the Win32 editor uses, unchanged. An
;  InputHook is a system-wide hook: it does not care which window has focus, and
;  because it is started without the V option the keystroke is SWALLOWED. The
;  page never sees the key, so there is nothing to fight over. Alt, F10, Ctrl+W,
;  F12 and the Windows key all record exactly like any other chord, which is more
;  than a page listening for keydown could ever manage.
;
;  What the page draws is the overlay — "press a key", the chord as it builds,
;  what the row is bound to now. That is a picture, and a picture is the thing a
;  web page is better at.
;
;  Two consequences worth knowing rather than discovering:
;
;    • The mouse is captured too (*LButton and friends, so a Scimitar button can
;      be assigned). While the overlay is up, CLICKING CANCEL IS NOT POSSIBLE —
;      the click would be recorded as the new binding. Escape cancels, Backspace
;      unbinds, and the overlay says both. The Win32 editor has always behaved
;      this way; here it is drawn large enough to read.
;
;    • The grab BLOCKS. It is therefore run off a -1 timer rather than inside the
;      WebMessageReceived handler that asked for it: blocking inside a COM event
;      callback while the message loop keeps pumping is how a WebView2 host
;      re-enters its own handler. The handler sets a flag, tells the page to show
;      the overlay, and returns.
;
;  ─── WHAT IS SHARED, AND WHY IT HAD TO BE ────────────────────────────────────
;  Everything that is not drawing: hotkeys_core.ahk. Not tidiness — the two
;  editors write the same ini and report on the same keys, and a disagreement
;  between them about what counts as a clash, or about whether the schema stamp
;  goes on, is a bug you could only find by having both windows open at once and
;  noticing they said different things.
;
;  ─── THE BRIDGE ──────────────────────────────────────────────────────────────
;      page → AHK   postMessage {cmd: ready | assign | clear | reset | resetAll
;                                     | revert | save | close | openIni | devtools}
;      AHK  → page  window.mma.sync({whole state})
;                   window.mma.capture({on, label, current}) / .prompt(text)
;                   window.mma.toast(text)
;
;  Full state every sync, never a delta — the same rule the main window's page
;  follows. There are ~140 rows; a delta protocol would be a second copy of the
;  truth to keep in step for no measurable gain.
;
;  Nothing is written to hotkeys.ini until Save, which is what makes Close a real
;  discard: the edits live in HWV_Pending and nowhere else.
; ═══════════════════════════════════════════════════════════════════════════════

DetectHiddenWindows true

; Assigned before the window exists: g.Show() fires Size, and HWV_OnSize reads wvc.
wvc      := 0
wv       := 0
wvMsgTok := 0
HWV_Ready := false

; ── the state ─────────────────────────────────────────────────────────────────
;  pending  what the page is editing. Nothing else reads it, and it reaches the
;           ini only through Save.
;  saved    what hotkeys.ini said when this window opened (or last saved). The
;           difference between the two is the ● "unsaved" mark.
;  defaults what hotkeys.default.ini asks for. Read ONCE: the ○ "not the default"
;           mark asks this of every row on every redraw, and that is one IniRead
;           per row per keystroke in the search box if it is not cached.
HWV_Pending  := Map()
HWV_Saved    := Map()
HWV_Defaults := Map()
; True from the moment the page is told to show the overlay until the grab
; returns. A second assign while one is in flight is dropped rather than queued —
; there is one keyboard, and the overlay is modal in practice.
HWV_Capturing := false
; The last text pushed to the overlay. The grab loop offers one every 15ms and
; almost all of them are the same string; only changes go over the bridge.
HWV_LastPrompt := ""

HWV_Load() {
    global HWV_Pending, HWV_Saved, HWV_Defaults
    HWV_Pending := Map(), HWV_Saved := Map(), HWV_Defaults := Map()
    for id in HK_ORDER {
        HWV_Pending[id]  := HK_Key(id)
        HWV_Saved[id]    := HWV_Pending[id]
        HWV_Defaults[id] := HKP_DefaultKey(id)
    }
}

HWV_Dirty() {
    global HWV_Pending, HWV_Saved
    for id in HK_ORDER
        if (HWV_Pending[id] != HWV_Saved[id])
            return true
    return false
}

; ─── The window ───────────────────────────────────────────────────────────────

pal := THEME_Set()
g := Gui("+Resize +MinSize880x560", "MMA Hotkeys")
g.MarginX := 0
g.MarginY := 0
g.BackColor := (pal.win = "") ? "Default" : pal.win
; The title bar, so a dark theme does not stop at the top of the page.
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", pal.dark ? 1 : 0, "int", 4)
g.OnEvent("Size", HWV_OnSize)
g.OnEvent("Close", HWV_OnClose)
g.Show("w1080 h740")

HWV_Load()

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    LOGE("hwv.win", "WebView2 would not start — the hotkey editor cannot open this way",
                    LOG_Err(e))
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nThis window is drawn by the Microsoft Edge WebView2 Runtime, which"
         . " ships with Windows 11.`n`nThe classic hotkey editor needs none of it"
         . " and can do everything this one can — it is opening now.",
           "MMA — Hotkeys", 0x10)
    ; Not a dead end. The whole point of keeping the Win32 editor is the case
    ; where the browser is the thing that is broken, and a person who came here
    ; to fix a key binding should end up at an editor either way.
    try Run(A_AhkPath ' "' MMA_SRC '\ui\hotkeys_window.ahk"')
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false

; add_, not the wrapper's shorthand — that returns an object whose only job is to
; unregister on destruction using a raw copy of the core pointer taken without an
; AddRef, which crashes on shutdown. See webview_main_window.ahk for the measured
; version of this.
wvMsgTok := wv.add_WebMessageReceived(HWV_OnMessage)

; file:// is an opaque origin, so the page is served from a virtual host mapped
; onto the repo root — same host name every MMA page uses.
wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/hotkeys.html")

LOG_Kv("hwv.win", Map("ini", HK_INI, "declared", HK_ORDER.Length,
                      "sections", HK_SECTIONS.Length, "theme", THEME_Name()))

; ── the overlay, without the grab ─────────────────────────────────────────────
;  Run this file with `overlay` as its only argument and the capture overlay
;  comes up over a real row and STAYS there — no InputHook, no suspend
;  broadcast, no keyboard taken.
;
;  That is the only safe way to LOOK at it. A screenshot probe that drives a
;  real capture suspends every MMA script running, and one that dies before the
;  grab returns leaves every hotkey in the app dead with nothing to say why. The
;  Win32 editor splits HotkeysPanel.CaptureOverlay out from SetKeyForSelected
;  for the same reason; this is that split, drawn across the bridge.
;
;  It also exercises the HWV_Prompt shim, which is the one piece of the capture
;  path that is new here rather than shared.
if (A_Args.Length && A_Args[1] = "overlay")
    SetTimer(HWV_OverlayProbe, -900)

HWV_OverlayProbe() {
    global HWV_Ready
    if !HWV_Ready {
        SetTimer(HWV_OverlayProbe, -300)
        return
    }
    HWV_CaptureOn(HK_ORDER[1])
    HWV_Prompt().Value := "Ctrl+Alt+…"
    LOGW("hwv.probe", "overlay shown WITHOUT a capture — this window is a"
                    . " screenshot probe and binds nothing")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The bridge
; ═══════════════════════════════════════════════════════════════════════════════

HWV_OnMessage(sender, args) {
    global HWV_Ready, HWV_Pending, HWV_Defaults, HWV_Capturing, wv
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("hwv.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""
    id  := m.Has("id")  ? m["id"]  : ""
    ; A row id from the page is never trusted into a Map: the page is built from
    ; a sync we sent, but a stale one could name an id a reload has since removed,
    ; and HWV_Pending[gone] throws rather than returning blank.
    if (id != "" && !HK_META.Has(id)) {
        LOGW("hwv.msg", "'" cmd "' named an id the registry does not have: " id)
        return
    }
    try {
        switch cmd {
            case "ready":
                HWV_Ready := true
                HWV_Sync()

            ; The handler does NOT grab. It flips the flag, puts the overlay on
            ; screen and gets out — see the header on why blocking in here is
            ; how a WebView2 host re-enters its own callback. The delay is for
            ; the page: the overlay has to be PAINTED before the keyboard goes
            ; dead, or the first thing a person sees is a frozen window.
            case "assign":
                if HWV_Capturing
                    return
                HWV_Capturing := true
                HWV_CaptureOn(id)
                SetTimer(HWV_DoCapture.Bind(id), -80)

            case "clear":
                HWV_Pending[id] := ""
                HWV_Sync()

            case "reset":
                d := HWV_Defaults[id]
                if (d == HK_UNSET) {
                    HWV_Toast(HK_META[id].label " has no default to go back to")
                    return
                }
                HWV_Pending[id] := d
                HWV_Sync()

            case "resetAll":
                if MsgBox("Put every hotkey back to its default?`n`nNothing is"
                        . " written until you press Save.", "Reset all", 0x24) != "Yes"
                    return
                n := 0
                for _, rid in HK_ORDER {
                    d := HWV_Defaults[rid]
                    if (d != HK_UNSET && HWV_Pending[rid] != d) {
                        HWV_Pending[rid] := d
                        n++
                    }
                }
                HWV_Sync()
                HWV_Toast(n = 0 ? "Already all defaults" : n " row(s) back to default")

            ; Throw the edits away without closing. The other half of "nothing is
            ; written until Save": you can back out of a session of fiddling and
            ; keep the window open.
            case "revert":
                HWV_Load()
                HWV_Sync()
                HWV_Toast("Back to what hotkeys.ini says")

            case "save":
                n := HKP_SaveKeys(HWV_Pending)
                for _, rid in HK_ORDER
                    HWV_Saved[rid] := HWV_Pending[rid]
                HWV_Sync()
                HWV_Toast(n = 0 ? "No changes"
                                : n " hotkey(s) saved — live now, no restart")
                LOGI("hwv.save", n " hotkey(s) written to hotkeys.ini")

            case "close":
                HWV_OnClose()

            ; Hand-editing the ini is a first-class path — the file is the truth
            ; and this window is a view over it.
            case "openIni":
                HWV_OpenIni()

            case "devtools":
                wv.OpenDevToolsWindow()
        }
    } catch as e
        LOGE("hwv.msg", "handling '" cmd "' failed", LOG_Err(e))
}

; ── the capture ───────────────────────────────────────────────────────────────

; Runs off the timer, not off the bridge. Blocks until a key, a mouse button,
; Escape or Backspace arrives.
HWV_DoCapture(id) {
    global HWV_Pending, HWV_Capturing, HWV_LastPrompt
    k := "<cancel>"
    try
        k := HKP_Capture(HWV_Prompt())
    catch as e
        LOGE("hwv.grab", "the key capture threw — nothing was assigned", LOG_Err(e))
    finally {
        HWV_Capturing  := false
        HWV_LastPrompt := ""
        HWV_CaptureOff()
    }

    if (k = "<cancel>")
        return
    HWV_Pending[id] := (k = "<clear>") ? "" : k
    HWV_Sync()
    HWV_Toast(HK_META[id].label "  →  " HKP_KeyLabel(HWV_Pending[id])
            . "      (not saved yet)")
}

; What HKP_GrabKey talks to while a chord is being held. It expects a control —
; it sets `.Value` on it — so this is a stand-in with that one property, the
; same duck-type trick the main window uses to hand parser.ahk something that
; is not a Gui cell. The setter is where the throttle lives: the grab loop
; offers a string every 15ms and nearly all of them are the one already on
; screen, which would otherwise be 60-odd bridge calls a second to say nothing.
class HWV_Prompt {
    Value {
        set {
            global HWV_LastPrompt
            if (value == HWV_LastPrompt)
                return
            HWV_LastPrompt := value
            HWV_Js("window.mma.prompt(" JSON.Stringify(value) ")")
        }
    }
}

HWV_CaptureOn(id) {
    global HWV_Pending
    m := HK_META[id]
    st := Map("on", 1, "id", id, "label", m.label,
              "section", HK_SECTION_LABEL.Has(HK_Split(id).section)
                         ? HK_SECTION_LABEL[HK_Split(id).section] : "",
              "current", HKP_KeyLabel(HWV_Pending[id]))
    HWV_Js("window.mma.capture(" JSON.Stringify(st) ")")
}

HWV_CaptureOff() {
    HWV_Js("window.mma.capture(" JSON.Stringify(Map("on", 0)) ")")
}

; ── talking to the page ───────────────────────────────────────────────────────

; One guarded place to run script in the page. Before `ready` there is no
; window.mma to call and the call lands on a document that cannot answer —
; silently, because a script error inside the WebView goes to the page's console
; and nowhere this process can see. So it is a hard gate, not a try.
HWV_Js(js) {
    global wv, HWV_Ready
    if !HWV_Ready
        return
    try wv.ExecuteScriptAsync(js)
}

; Push the whole state to the page.
;
; The rows carry their own descriptors — label, section, context, owner, the key
; as separate parts — so the page holds NO list of hotkeys. Adding an HK_Def line
; in core\hotkeys.ahk puts a row on screen with no edit to the HTML, which is the
; same arrangement the WebView Settings has with the feature registry.
HWV_Sync() {
    global HWV_Pending, HWV_Saved, HWV_Defaults, HWV_Ready
    if !HWV_Ready
        return

    clash := HKP_Conflicts(HWV_Pending)

    secs := []
    for _, sid in HK_SECTIONS
        secs.Push(Map("id", sid,
                      "label", HK_SECTION_LABEL.Has(sid) ? HK_SECTION_LABEL[sid] : sid))

    rows := []
    edits := 0, off := 0
    for id in HK_ORDER {
        m   := HK_META[id]
        key := HWV_Pending[id]
        def := HWV_Defaults[id]
        unsaved := (key != HWV_Saved[id])
        if unsaved
            edits++
        if (key = "")
            off++
        rows.Push(Map(
            "id",       id,
            "sect",     HK_Split(id).section,
            "label",    m.label,
            "when",     m.when,
            "owner",    m.owner,
            "key",      key,
            "tokens",   (key = "") ? [] : HKP_KeyTokens(key),
            "pretty",   HKP_KeyLabel(key),
            ; unsaved beats custom: a row you have just edited says so, even when
            ; what you edited it to happens to also be the default.
            "flag",     unsaved ? "edit"
                                : (HKP_IsChanged(key, def) ? "custom" : ""),
            "hasDef",   (def == HK_UNSET) ? 0 : 1,
            "defLabel", (def == HK_UNSET) ? "" : HKP_KeyLabel(def),
            "clash",    clash.Has(id) ? clash[id] : ""))
    }

    st := Map("sections", secs, "rows", rows,
              "counts", Map("total", HK_ORDER.Length, "edits", edits,
                            "off", off, "clashes", clash.Count),
              "dirty", HWV_Dirty() ? 1 : 0,
              "ini", HK_INI,
              "theme", THEME_Name())

    HWV_Js("window.mma.sync(" JSON.Stringify(st) ")")
}

HWV_Toast(text) {
    HWV_Js("window.mma.toast(" JSON.Stringify(text) ")")
}

; ── the rest ──────────────────────────────────────────────────────────────────

; Don't let a missing .ini file association turn "Open hotkeys.ini" into an error
; dialog — fall back to Notepad, which is always there.
HWV_OpenIni() {
    try
        Run(Chr(34) HK_INI Chr(34))
    catch
        try Run("notepad.exe " Chr(34) HK_INI Chr(34))
}

; Closing DISCARDS, so it asks — unlike the Settings window, where every setting
; has a default to fall back to and losing an edit costs a moment. Losing a
; capture costs finding the key again, and a person who spent five minutes
; rebinding a Scimitar deserves to be asked.
HWV_OnClose(*) {
    global HWV_Capturing
    ; Mid-capture the keyboard is hooked and every script is suspended. Exiting
    ; here would leave the suspend broadcast unanswered — HKP_Capture's `finally`
    ; is the only thing that lifts it — and every hotkey in MMA would stay dead
    ; until something else reloaded them.
    if HWV_Capturing
        return true
    if (HWV_Dirty() && MsgBox("Discard unsaved hotkey changes?", "Unsaved", 0x24) != "Yes")
        return true          ; keep the window open
    ExitApp()
}

; The WebView has no window of its own to resize — it is told its bounds.
HWV_OnSize(gObj, minMax, w, h) {
    global wvc
    if (minMax = -1 || !IsObject(wvc))
        return
    try wvc.Bounds := [0, 0, w, h]
}
