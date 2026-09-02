#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  paths.ahk — every path in MMA, resolved from ONE anchor.
; ───────────────────────────────────────────────────────────────────────────────
;  A_ScriptDir is the folder of the MAIN script — the one you double-clicked —
;  not the folder of the file the code is written in. While every entry point
;  lived in the repo root those were the same folder, so 37 uses of
;  A_ScriptDir "\something" happened to work by coincidence.
;
;  They fail SILENTLY the moment a script runs from a subfolder: IniRead with a
;  default just returns the default, so settings quietly revert and nothing says
;  why. In the v2 tree EVERY entry point is in a subfolder, so that coincidence
;  is gone for good and this file is the only thing standing in for it.
;
;  A_LineFile is the file THIS line is written in, so it is immune to which
;  script is the main one.
;
;  TO MOVE THIS FILE: change the MMA_ROOT line below to climb the right number of
;  levels. Nothing else in the repo needs to know where anything lives.
; ═══════════════════════════════════════════════════════════════════════════════

; Strip the last "\segment" off a path. Defined before first use: AHK parses every
; function at load time, so calling this from the top-level initialisers below is
; safe regardless of which script #Included us.
MMA_ParentDir(p) {
    cut := InStr(p, "\", , -1)
    return cut ? SubStr(p, 1, cut - 1) : p
}

; This file is  <root>\src\core\paths.ahk  → three levels up is <root>.
global MMA_ROOT := MMA_ParentDir(MMA_ParentDir(MMA_ParentDir(A_LineFile)))

; ─── Folders ──────────────────────────────────────────────────────────────────
global MMA_SRC       := MMA_ROOT "\src"
global MMA_CONTENT   := MMA_ROOT "\content"        ; hand-written AHK message files
global MMA_ACC_DIR   := MMA_CONTENT "\accounts"    ; per-account hotstring files
global MMA_USERDATA  := MMA_ROOT "\userdata"       ; settings and messages
global MMA_ASSETS    := MMA_ROOT "\assets"
; Pictures that are only ever looked at — the corner girl and anything else you
; drop in. Kept apart from assets\ proper because the files THERE are load-bearing
; (icon.ico, copy_text.png is matched on screen), and a glob for "every image in
; the folder" must not be able to offer you one of those.
global MMA_DECOR     := MMA_ASSETS "\decoration"
; Diagnostics: crash traces and whatever the probe tools dump. Its own folder
; because these are THROWAWAY — you read one, you fix the thing, you delete it —
; and mixing them into userdata\ put them next to masses.json and hotkeys.ini,
; the two files you must never delete by mistake.
global MMA_DEBUGLOGS := MMA_ROOT "\debuglogs"

; ─── Files the user owns ──────────────────────────────────────────────────────
; All of these live in userdata\, which is gitignored except for the .default
; that seeds hotkeys.ini. See ARCHITECTURE.md §5.
global MMA_CFG         := MMA_USERDATA "\mass_gui.cfg"
global MMA_HK_INI      := MMA_USERDATA "\hotkeys.ini"
global MMA_HK_DEFAULT  := MMA_USERDATA "\hotkeys.default.ini"
global MMA_OVERLOADS   := MMA_USERDATA "\hotstring_overloads.ini"
; Which hotstrings you use, and which you pinned — the quick menu's whole
; memory. Its OWN file, not another section of hotstring_overloads.ini: that
; one is written by a human in the manager and read at load by every message
; script, while this one is written on every send. Mixing them would put a
; keystroke-rate writer into the file your overloads live in.
global MMA_USAGE       := MMA_USERDATA "\hotstring_usage.ini"
; Triggers that run an ACTION instead of typing a message — see
; hotstrings\shortcuts.ahk. Its own file, hand-edited and never written by MMA,
; for the reason hotkeys.ini is its own file: mass_gui.cfg is machine-written
; UTF-16 whose key order IniWrite reshuffles, which is no place for a list you
; keep in an order that means something to you.
global MMA_SHORTCUTS   := MMA_USERDATA "\shortcuts.ini"
global MMA_MASSES      := MMA_USERDATA "\masses.json"
global MMA_ARCHIVE     := MMA_USERDATA "\mass_archive.txt"
global MMA_DETECTOR    := MMA_USERDATA "\detector_status.ini"
; Fansly gets its OWN status file, not another section of detector_status.ini.
; Two services writing one file is two services racing for one `active_model`
; key, and the loser wins about half the time — which on this particular key
; means one model's mass sent into another model's chat. Separate files, separate
; readers, and whichever platform's window is in front is the only one consulted.
global MMA_FANSLY      := MMA_USERDATA "\fansly_status.ini"
global MMA_VERSION     := MMA_ROOT "\version.txt"

; ─── Diagnostics ──────────────────────────────────────────────────────────────
; Created HERE, at load, rather than by each writer.
;
; Every one of these is written with FileAppend, which throws if the folder is
; missing — and each writer is inside a `try` precisely because a logger must not
; be able to crash the thing it is logging for. So a missing folder would not
; raise anything: the crash log would silently stop recording crashes, which is
; the one failure you cannot debug from the log. One idempotent DirCreate, in the
; file every script already includes, removes the possibility.
try DirCreate(MMA_DEBUGLOGS)
; error_log.txt is now the SHORT list — failures only, so it stays openable and
; readable top to bottom. mma.log is the full timeline every process appends to;
; see core\log.ahk. Both are written by LOGE, deliberately: the question "what
; broke" and the question "what was happening when it broke" want different files.
global MMA_ERRLOG       := MMA_DEBUGLOGS "\error_log.txt"
global MMA_LOGFILE      := MMA_DEBUGLOGS "\mma.log"
; AHK_engine.log — the ENGINE layer, not MMA's own. Uncaught errors land here
; alongside mma.log, and tools/test writes its /validate output here too, so the
; #Warn warnings that only ever appeared as a modal dialog have a written record.
global MMA_AHKLOG       := MMA_DEBUGLOGS "\AHK_engine.log"
global MMA_PROBE_DETECT := MMA_DEBUGLOGS "\detector_probe.txt"
global MMA_PROBE_FANSLY := MMA_DEBUGLOGS "\fansly_probe.txt"
global MMA_PROBE_NEXTFU := MMA_DEBUGLOGS "\nextfu_probe.txt"

; ─── Source files referenced as PATHS rather than #Included ───────────────────
;  Two things do this and both are easy to miss when moving files:
;    • recorder.ahk WRITES new code into sequences.ahk and hotkeys.ahk
;    • sequences.ahk builds a WinTitle from main_window.ahk's path, because an
;      AHK script's window title IS its full path
;
;  There was a third: both main windows and both Settings windows READ utils.ahk
;  as text, to scrape the waitTime literal out of it. That number is [Settings]
;  WaitTime in the cfg now, so four files stopped caring how utils.ahk is worded.
global MMA_SRC_COORDS    := MMA_SRC "\core\coords.ahk"
global MMA_SRC_UTILS     := MMA_SRC "\core\utils.ahk"
global MMA_SRC_HOTKEYS   := MMA_SRC "\core\hotkeys.ahk"
global MMA_SRC_SEQUENCES := MMA_SRC "\sequences\sequences.ahk"
global MMA_SRC_GUI       := MMA_SRC "\ui\main_window.ahk"
; The WebView shell — the same window drawn by Edge instead of by Win32, and the
; one MMA starts unless you ask for the other. It lived in tools\ while it was a
; prototype; it is release code now, and it sits beside the Win32 shell and the
; pages it loads (ui\webview\).
;
; MMA_SRC_GUI still points at main_window.ahk whichever one is running. That path
; is the Win32 shell's own identity and nothing else: what used to address "the
; GUI" through it now calls MMA_GuiWin() below, which answers with whichever
; shell is actually up.
global MMA_SRC_WEBVIEW   := MMA_SRC "\ui\webview_main_window.ahk"
; The other two windows that come in both kinds. Settings has no standalone
; Win32 script - the classic one is a Gui built inside the MAIN window, so
; "legacy" there means "ask the main window", not "run this file".
global MMA_SRC_SETTINGS_WV := MMA_SRC "\ui\settings_webview.ahk"
global MMA_SRC_HOTKEYS_WV  := MMA_SRC "\ui\hotkeys_webview.ahk"
global MMA_SRC_HOTKEYS_GUI := MMA_SRC "\ui\hotkeys_window.ahk"

; Which of the two MMA.ahk should start — Settings ▸ GUI ▸ Main window.
;
; The default is the WebView shell. The key is only ever WRITTEN by Settings, so
; an install that has never touched that radio has no key at all and takes the
; default — which is the whole mechanism by which this became the new front end.
; "legacy" is still honoured and still fully supported; it is a choice now rather
; than the starting point.
;
; Falls back to the Win32 window whenever the WebView file is missing, rather than
; failing to start: this is a preference, and a preference must not be able to
; leave you with no window at all. IniRead and nothing else — paths.ahk is included
; by scripts that include nothing, so it cannot call into log.ahk.
MMA_ShellPath() {
    return (MMA_ShellFor("main") = "webview") ? MMA_SRC_WEBVIEW : MMA_SRC_GUI
}

; Which KIND of window to open: "webview" or "legacy". One function for all three
; windows that come in both, so "everything is configurable as WebView vs AHK"
; is one question asked the same way each time rather than three launchers each
; reading their own key their own way.
;
;     which        key                  legacy means
;     ---------    ------------------   ----------------------------------------
;     "main"       MainWindowShell      run ui\main_window.ahk
;     "settings"   SettingsShell        the Win32 Gui INSIDE the main window
;     "hotkeys"    HotkeysShell         run ui\hotkeys_window.ahk
;
; WebView is the default for all three, and every key is only ever WRITTEN by
; Settings - an install that has never touched them has no keys at all and takes
; the default, which is the mechanism by which these became the front ends.
;
; Falls back to legacy whenever the WebView file is MISSING rather than failing:
; this is a preference, and a preference must never be able to leave you with no
; window at all. IniRead and nothing else - paths.ahk is included by scripts that
; include nothing, so it cannot call into log.ahk.
MMA_ShellFor(which) {
    which := StrLower(Trim(which))
    if (which = "settings") {
        key := "SettingsShell", wv := MMA_SRC_SETTINGS_WV
    } else if (which = "hotkeys") {
        key := "HotkeysShell",  wv := MMA_SRC_HOTKEYS_WV
    } else {
        key := "MainWindowShell", wv := MMA_SRC_WEBVIEW
    }
    v := StrLower(Trim(IniRead(MMA_CFG, "Settings", key, "webview")))
    return (v = "webview" && FileExist(wv)) ? "webview" : "legacy"
}

; The WinTitle of the main window that is actually RUNNING, whichever shell it is.
;
; An AHK script's hidden main window is titled with its full path, and two things
; address the GUI that way across processes: sequences.ahk, which posts the
; Discord import's auto-parse message, and hotstrings_window.ahk, whose
; "Add hotkey..." button asks the GUI to open a dialog built out of the GUI's own
; globals.
;
; Both hard-coded MMA_SRC_GUI, which was right while main_window.ahk was the only
; front end and silently wrong the moment the WebView shell could be the window
; MMA started: the message goes to a title nothing has, WinExist says the GUI is
; not running, and the import reports itself as "MMA is not open" while MMA is
; plainly open. That is the failure this function exists to prevent.
;
; Asks the preference first, then tries the other shell, so it is right whichever
; one is up even if the setting was changed without a restart. If neither is
; running it still returns a title, so the caller's own "not running" branch and
; its log line say something meaningful.
MMA_GuiWin() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows true
    try {
        for _, path in [MMA_ShellPath(), MMA_SRC_GUI, MMA_SRC_WEBVIEW] {
            title := path " ahk_class AutoHotkey"
            if WinExist(title)
                return title
        }
        return MMA_ShellPath() " ahk_class AutoHotkey"
    }
    finally
        DetectHiddenWindows prev
}

; ─── Resolvers ────────────────────────────────────────────────────────────────

; The model IDENTIFIERS the GUI's tabs pass around — "2_mass.ahk" and friends.
;
; These are labels, not paths: no such file exists any more. ApplyFile/LoadFile
; call ModelNoOf() on them to get a slot number and read the mass out of
; userdata\masses.json. The old MMA_ModelFile/MMA_ModelFiles pointed into
; content\models\, which is deleted, and are gone with it.
; Reads the count from the cfg rather than taking MASS_MODELS: store.ahk includes
; THIS file, so the constant does not exist yet when this is defined, and paths.ahk
; must stand alone for the scripts that include nothing else. Same clamp as
; _MASS_SlotCount, deliberately — two readers of one setting must agree, and the
; failure if they drift is a model whose load/save button has no slot behind it.
MMA_ModelNames() {
    n := 3
    try n := Integer(Trim(IniRead(MMA_CFG, "Settings", "ModelCount", 3)))
    catch
        n := 3
    n := Max(3, Min(n, 12))       ; MASS_MODELS_MAX, which we cannot see from here
    out := []
    loop n
        out.Push(A_Index "_mass.ahk")
    return out
}

; Turn a BARE FILENAME from mass_gui.cfg into a full path.
;
; The cfg stores names, not paths — StartupScripts=1_mass.ahk,ALIW.ahk,general.ahk
; and friends. That was unambiguous while every script sat in one folder; now the
; three names in that example live in three different folders. Resolving here
; means the cfg format does not change, so nobody's settings break.
;
; Order matters only if two folders hold the same filename, which nothing does.
; The folder list must cover every folder a StartupScripts entry can name. It is
; the one place that knows, and a folder missing from it fails the worst possible
; way: ResolveScriptPath returns "", LaunchStartupScripts skips the entry, and the
; script simply never starts — no error, no dialog, nothing in the log. That is
; how "engine.ahk" silently did not run after it moved to src\mass\.
MMA_ScriptPath(name) {
    global MMA_ACC_DIR, MMA_CONTENT, MMA_SRC
    if InStr(name, "\") || InStr(name, "/") {   ; already a path — leave it alone
        LOGV("paths.resolve", name " is already a path")
        return name
    }
    for dir in [MMA_ACC_DIR, MMA_CONTENT,
                MMA_SRC "\mass", MMA_SRC "\chat", MMA_SRC "\sequences",
                MMA_SRC "\screen", MMA_SRC "\ui", MMA_SRC] {
        p := dir "\" name
        if FileExist(p) {
            LOGV("paths.resolve", name " → " p)
            return p
        }
    }
    ; The failure this function's header is about, now audible. A name that
    ; resolves nowhere returns a path that does not exist, LaunchStartupScripts
    ; skips it, and the script never starts — which is how engine.ahk silently
    ; stopped running after it moved to src\mass\. WARN rather than FAIL: the
    ; caller still gets a usable path and decides for itself whether it matters.
    LOGW("paths.resolve", "'" name "' is in none of the searched folders —"
                        . " falling back to " MMA_CONTENT "\" name
                        . " which does not exist. Anything launching it will do"
                        . " nothing, silently.")
    return MMA_CONTENT "\" name        ; best guess, so callers still get a path
}

; ─── the logger ───────────────────────────────────────────────────────────────
;  LAST, and from here rather than from each script.
;
;  This is the one file every entry point in the tree already includes, which
;  makes it the only place a logger can be added once and reach everything —
;  including the scripts nobody remembers exist. Each process therefore gets its
;  boot line, its exit line and its uncaught-error hook with no wiring of its own
;  and no way to drift out of step.
;
;  At the END because log.ahk's own load-time code writes that boot line, and it
;  needs MMA_LOGFILE and MMA_DEBUGLOGS above to exist first. The include is
;  circular — log.ahk names this file too, since it may equally be included
;  directly — and that is fine: AHK loads a given file once however many times it
;  is named, so whichever is reached first wins and the other is a no-op.
#Include "log.ahk"
