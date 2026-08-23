#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/theme.ahk"
#Include "../activity/record.ahk"
#Include "../vendor/json.ahk"
; thqby's WebView2 wrapper. It finds WebView2Loader.dll beside itself (64bit\ or
; 32bit\ to match the interpreter) and the Edge runtime from its install root, so
; there is nothing to configure. It pulls in ComVar.ahk and Promise.ahk itself.
#Include "../vendor/WebView2/WebView2.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  activity_window.ahk — the chart over what activity/tracker.ahk recorded.
; ───────────────────────────────────────────────────────────────────────────────
;  Its own process, opened by the tracker's gui.activity key. Nothing else in MMA
;  waits on it, it binds no hotkeys, and closing it stops nothing — the tracker
;  keeps recording whether or not anybody is looking at the chart.
;
;  ── Why Edge draws it ────────────────────────────────────────────────────────
;  A heatmap, an area chart with a crosshair, and four responsive cards is a lot
;  of GDI+ to hand-write, and every one of them would need re-drawing by hand on
;  every resize. The page in ui\webview\activity.html does the whole of it in
;  SVG and CSS, and this file's entire job is: make a window, give it a WebView,
;  hand it the numbers, and answer two commands.
;
;  ── The bridge ───────────────────────────────────────────────────────────────
;      page → AHK   chrome.webview.postMessage({cmd: "ready"|"focus"|"range"})
;      AHK  → page  window.mma.load({whole payload})   /  window.mma.theme(dark)
;
;  Full payload every time, exactly like webview_main_window.ahk: there is one
;  copy of the truth, it is the CSV on disk, and the page is a view onto it. A
;  delta protocol here would buy nothing — re-reading a month of hourly buckets
;  is a few milliseconds — and would cost a second thing that can be wrong.
;
;  ── The one ordering rule ────────────────────────────────────────────────────
;  Nothing may ExecuteScript until the page has posted `ready`. Before that,
;  `window.mma` does not exist yet and the call lands on a document that cannot
;  answer it — silently, because a script error inside the WebView goes to the
;  page's console and nowhere this process can see.
; ═══════════════════════════════════════════════════════════════════════════════

CFG := MMA_CFG

; Assigned before the window exists: g.Show() fires Size, and AW_OnSize reads
; wvc. Same trap as webview_main_window.ahk documents — assigned after the Show,
; the first resize of the session throws before the WebView exists.
wvc      := 0
wv       := 0
wvMsgTok := 0
AW_Ready := false

; What the page is currently showing. The range is remembered between sessions
; because it is a preference ("I think in fortnights"), not a per-open decision.
AW_Focus := FormatTime(A_Now, "yyyy-MM-dd")
AW_Days  := LOG_IniInt(CFG, "Activity", "Range", 30)
if (AW_Days != 7 && AW_Days != 30 && AW_Days != 90)
    AW_Days := 30

; ─── The window ───────────────────────────────────────────────────────────────

pal := THEME_Set()
g := Gui("+Resize +MinSize820x560", "MMA Activity")
g.MarginX := 0
g.MarginY := 0
; The theme colour is what shows for the few hundred ms between Show() and
; Edge's first paint. A white flash on a dark theme is the most visible thing
; this window does, so it is worth the two lines.
g.BackColor := (pal.win = "") ? "Default" : pal.win
try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20,
            "int*", pal.dark ? 1 : 0, "int", 4)
g.OnEvent("Size", AW_OnSize)
g.OnEvent("Close", (*) => ExitApp())
g.Show("w1180 h800")

try {
    wvc := WebView2.CreateControllerAsync(g.Hwnd).await2(20000)
    wv  := wvc.CoreWebView2
} catch as e {
    LOGE("act.win", "WebView2 would not start — there is no chart", LOG_Err(e))
    MsgBox("Could not start WebView2.`n`n" LOG_Err(e)
         . "`n`nThe activity chart is drawn by the Microsoft Edge WebView2"
         . " Runtime, which ships with Windows 11. Install it from Microsoft if"
         . " this machine has had it removed.`n`nThe tracker is unaffected — it"
         . " is still recording.", "MMA — Activity", 0x10)
    ExitApp
}

wv.Settings.AreDevToolsEnabled := true
wv.Settings.IsStatusBarEnabled := false
wv.Settings.IsZoomControlEnabled := false

; add_, NOT the wrapper's `wv.WebMessageReceived(fn)` shorthand — that returns an
; object whose only job is to unregister on destruction, using a raw copy of the
; core pointer taken without an AddRef, which crashes on shutdown. The long
; version of this is in webview_main_window.ahk; the short version is that this
; window wants its one handler for as long as it exists.
wvMsgTok := wv.add_WebMessageReceived(AW_OnMessage)

; The repo root behind a virtual host rather than file://, because a file:// page
; is an opaque origin to Edge and postMessage from one is a fight with the
; security model.
wv.SetVirtualHostNameToFolderMapping("mma.local", MMA_ROOT, 1)
wv.Navigate("https://mma.local/src/ui/webview/activity.html")

LOG_Kv("act.win", Map("focus", AW_Focus, "range", AW_Days, "dir", ACT_DIR))

; ─── The bridge ───────────────────────────────────────────────────────────────

AW_OnMessage(sender, args) {
    global AW_Ready, AW_Focus, AW_Days, CFG
    try {
        m := JSON.Parse(args.WebMessageAsJson)
    } catch as e {
        LOGE("act.msg", "unreadable message from the page — ignored", LOG_Err(e))
        return
    }
    cmd := m.Has("cmd") ? m["cmd"] : ""
    if (cmd = "ready") {
        AW_Ready := true
        AW_Theme()
        AW_Send()
        return
    }
    if (cmd = "focus") {
        day := m.Has("day") ? m["day"] : ""
        ; Anything the page can send lands in a FILE GLOB in ACT_ReadDay, so it
        ; is checked against the shape a date has rather than trusted. The page
        ; only ever sends dates it was given, which is exactly why a malformed
        ; one here would be a bug worth seeing rather than worth tolerating.
        if !RegExMatch(day, "^\d{4}-\d{2}-\d{2}$") {
            LOGW("act.msg", "the page asked for a day that is not a date: '"
                          . day "' — ignored")
            return
        }
        AW_Focus := day
        AW_Send()
        return
    }
    if (cmd = "range") {
        n := 30
        try n := Integer(m["days"])
        if (n != 7 && n != 30 && n != 90) {
            LOGW("act.msg", "the page asked for a " n "-day range, which is not one"
                          . " of the three it offers — ignored")
            return
        }
        AW_Days := n
        try IniWrite(n, CFG, "Activity", "Range")
        AW_Send()
        return
    }
    LOGW("act.msg", "unknown command from the page: '" cmd "'")
}

AW_Theme() {
    global wv, AW_Ready
    if !AW_Ready
        return
    ; Classic follows Windows, and the page's own prefers-color-scheme already
    ; does that — so classic is the one theme this must NOT stamp, or MMA would
    ; override the very system setting classic exists to defer to.
    if THEME_Is("classic")
        return
    try wv.ExecuteScriptAsync("window.mma.theme(" (THEME_Set().dark ? "true" : "false") ")")
}

AW_Send() {
    global wv, AW_Ready, AW_Focus, AW_Days
    if !AW_Ready {
        LOG_Bail("act.send", "the page has not said ready yet — nothing sent")
        return
    }
    t0 := A_TickCount
    try {
        payload := JSON.Stringify(ACT_Report(AW_Focus, AW_Days))
    } catch as e {
        LOGE("act.send", "could not build the activity report — the chart will"
                       . " stay on whatever it last showed", LOG_Err(e))
        return
    }
    try {
        wv.ExecuteScriptAsync("window.mma.load(" payload ")")
    } catch as e {
        LOGE("act.send", "could not hand the report to the page", LOG_Err(e))
        return
    }
    LOGV("act.send", "sent " StrLen(payload) " chars for " AW_Focus
                   . " / " AW_Days "d in " (A_TickCount - t0) "ms")
}

; The WebView has no window of its own to resize — it is told its bounds.
AW_OnSize(guiObj, minMax, W, H) {
    global wvc
    if (minMax = -1)              ; minimised: the dimensions are meaningless
        return
    if wvc
        try wvc.Fill()
}
