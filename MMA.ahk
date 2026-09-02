#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  MMA.ahk — the one thing you double-click.
; ───────────────────────────────────────────────────────────────────────────────
;  A launcher, not the app. The GUI is src\ui\main_window.ahk; this only exists so
;  the front door stays at the top of the tree while the code lives in src\.
;
;  Why Run and not #Include: an AHK script's main window is TITLED WITH ITS FULL
;  PATH, and three things depend on that title being the GUI's real path —
;  HK_Broadcast (which finds MMA's scripts by it), processes.ahk (which closes
;  them by it) and sequences.ahk (which builds a WinTitle from MMA_SRC_GUI to post
;  the auto-parse message). #Include would run the GUI under the title "MMA.ahk"
;  and all three would quietly stop matching. Run keeps one canonical identity.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "src\core\paths.ahk"

if !FileExist(MMA_SRC_GUI) {
    MsgBox "Cannot find the main window at:`n`n" MMA_SRC_GUI
         . "`n`nMMA.ahk must sit in the repo root, beside src\.", "MMA", 0x10
    ExitApp
}

; ─── The one-time move to the WebView shell ──────────────────────────────────
;  The WebView window is the default now, and a default only ever reaches an
;  install that has no opinion. Every install here HAS one: Settings writes every
;  key it owns on save, so anyone who has opened Settings once has
;  MainWindowShell=legacy on disk — written by the old default, not chosen. Left
;  alone, "the new default" would have reached new installs only.
;
;  So the value the OLD default wrote is lifted once, and a marker is set. After
;  that this never runs again, which is what makes a later, deliberate "Classic"
;  stick: the difference between a preference and an inherited default is whether
;  anyone has been asked, and the marker is that question having been asked.
;
;  Failures are swallowed. A read-only cfg is a reason to start in the shell the
;  file already names, never a reason not to start.
try {
    if (Trim(IniRead(MMA_CFG, "Settings", "ShellDefaultMigrated", "")) = "") {
        if (Trim(IniRead(MMA_CFG, "Settings", "MainWindowShell", "")) = "legacy")
            IniWrite("webview", MMA_CFG, "Settings", "MainWindowShell")
        IniWrite("1", MMA_CFG, "Settings", "ShellDefaultMigrated")
    }
}

; WHICH window, though, is Settings ▸ GUI ▸ Main window: the Win32 one or the
; WebView one. The check above is still against MMA_SRC_GUI on purpose — that is
; the file whose absence means a broken install, whereas a missing WebView shell
; only means the preference falls back, which MMA_ShellPath already does.
Run '"' A_AhkPath '" "' MMA_ShellPath() '"'
ExitApp