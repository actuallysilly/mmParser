#Requires AutoHotkey v2.0
#Include "core/paths.ahk"
#SingleInstance Force

SCRIPT_DIR := MMA_ROOT
CFG_FILE   := MMA_CFG
UPDATE_URL := IniRead(CFG_FILE, "Update", "URL", "https://raw.githubusercontent.com/actuallysilly/mmParser/main")

if UPDATE_URL = "" {
    MsgBox "No update URL in mass_gui.cfg.",, 0x10
    ExitApp
}

if !RegExMatch(UPDATE_URL, "raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)", &rm) {
    MsgBox "Invalid update URL format.",, 0x10
    ExitApp
}
apiUrl := "https://api.github.com/repos/" rm[1] "/" rm[2] "/git/trees/" rm[3] "?recursive=1"

g := Gui(, "mmParser Updater")
g.SetFont("s9", "Segoe UI")
lblStatus := g.Add("Text", "x10 y14 w380", "Fetching file list...")
g.Show("w400 h40")

FetchURL(url) {
    xhr := ComObject("MSXML2.XMLHTTP.6.0")
    xhr.Open("GET", url, false)
    xhr.SetRequestHeader("Cache-Control", "no-cache, no-store")
    xhr.SetRequestHeader("Pragma", "no-cache")
    xhr.SetRequestHeader("User-Agent", "mmParser-Updater")
    xhr.Send()
    if xhr.Status != 200
        throw Error("HTTP " xhr.Status)
    return xhr.ResponseText
}

LOGI("update", "fetching the file list from " apiUrl)
try {
    treeJson := FetchURL(apiUrl)
} catch as e {
    LOGE("update", "could not fetch the file list from GitHub — nothing was"
                 . " changed on disk", LOG_Err(e))
    g.Destroy()
    MsgBox "Could not fetch file list from GitHub.",, 0x10
    ExitApp
}

; Files that belong to the USER, not to the release. Downloading these would hand
; someone the maintainer's copy and silently destroy their own — which is exactly
; what used to happen to hotkeys.ini on every single update: custom keys replaced
; by whatever was in the repo. hotkeys.default.ini still ships (it is NOT skipped),
; and HK_Init merges anything new out of it without touching a key that already
; has a value.
;
; These are REPO-RELATIVE PATHS, matched against the GitHub tree — and they had
; gone stale against the v2 layout, which made this list a liability rather than a
; guard. "general.ahk" cannot match "content/general.ahk", and the account files
; moved from "acc/" to "content/accounts/", so an update would have overwritten
; ALIW.ahk, BRI.ahk, TEMP.ahk, UND.ahk and general.ahk with the maintainer's
; copies: every hotstring the user has ever written, gone, with a progress bar
; ticking past it.
;
; content/ is skipped WHOLE. Everything in it is hand-written message text; the
; copies in the repo are the maintainer's, and there is no file under it that a
; release needs to push. Anyone installing fresh clones or runs install.bat —
; this path only ever runs against an install that already exists.
skipExact  := Map("userdata/mass_gui.cfg", 1,
                  "userdata/hotkeys.ini",  1,
                  "userdata/masses.json",  1)
skipPfx    := ["content/", "userdata/detector_status", "debuglogs/", ".git"]
binaryExts := Map("ico", 1, "exe", 1, "png", 1, "jpg", 1, "gif", 1)

updatePaths := []
pos := 1
while RegExMatch(treeJson, '"path":"([^"]+)","mode":"[^"]+","type":"blob"', &m, pos) {
    path     := m[1]
    pos      := m.Pos + m.Len
    excluded := skipExact.Has(path)
    if !excluded {
        for _, pfx in skipPfx {
            if SubStr(path, 1, StrLen(pfx)) = pfx {
                excluded := true
                break
            }
        }
    }
    if !excluded
        updatePaths.Push(path)
}

; An update REWRITES THE TREE THE USER IS RUNNING, so what it touched is worth
; keeping a record of — a "MMA broke after I updated" report is answerable only if
; something wrote down which files changed and which of them did not land.
LOGI("update", "updating " updatePaths.Length " file(s); user files skipped:"
             . " mass_gui.cfg, hotkeys.ini, masses.json, and all of content\\")

failed := []
for i, path in updatePaths {
    lblStatus.Text := "(" i "/" updatePaths.Length ")  " path
    dest := SCRIPT_DIR "\" StrReplace(path, "/", "\")
    SplitPath dest, , &dir, &ext
    try {
        if dir != "" && !DirExist(dir)
            DirCreate dir
        if binaryExts.Has(StrLower(ext))
            Download UPDATE_URL "/" path "?t=" A_TickCount, dest
        else {
            content := FetchURL(UPDATE_URL "/" path)
            f := FileOpen(dest, "w", "UTF-8-RAW")
            f.Write(content)
            f.Close()
        }
        LOGV("update", "wrote " path)
    } catch as e {
        LOGW("update", "FAILED to download " path " — " LOG_Err(e))
        failed.Push(path)
    }
}

g.Destroy()

if failed.Length {
    ; A partial update is the worst state MMA can be in: some files are the new
    ; release and some are the old one, and the symptoms are arbitrary. This has
    ; to be findable afterwards, because by then the progress window is long gone.
    ; Built inline, NOT with ArrJoin: that lives in main_window.ahk and this is a
    ; separate entry point, so calling it would be a load-time "nonexistent
    ; function" — in the updater, of all places, which is the one script that must
    ; not be broken by a refactor.
    flist := ""
    for _, f in failed
        flist .= (flist = "" ? "" : ", ") f
    LOGE("update", failed.Length " of " updatePaths.Length " file(s) did not"
                 . " download — THIS INSTALL IS NOW PART OLD AND PART NEW."
                 . " Re-run the update.",
                 "failed: " flist)
    msg := "Some files failed to download:`n"
    for _, f in failed
        msg .= "  " f "`n"
    MsgBox msg "`nPartial update — please retry.",, 0x10
} else {
    LOGI("update", "all " updatePaths.Length " file(s) updated — restarting MMA")
    Run MMA_SRC_GUI
}
ExitApp
