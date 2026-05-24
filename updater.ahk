#Requires AutoHotkey v2.0
#SingleInstance Force

SCRIPT_DIR := A_ScriptDir
CFG_FILE   := SCRIPT_DIR "\mass_gui.cfg"
UPDATE_URL := IniRead(CFG_FILE, "Update", "URL", "")

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

try {
    treeJson := FetchURL(apiUrl)
} catch {
    g.Destroy()
    MsgBox "Could not fetch file list from GitHub.",, 0x10
    ExitApp
}

skipExact  := Map("mass_gui.cfg", 1, "general.ahk", 1)
skipPfx    := ["acc/", ".git"]
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
            f := FileOpen(dest, "w", "UTF-8")
            f.Write(content)
            f.Close()
        }
    } catch {
        failed.Push(path)
    }
}

g.Destroy()

if failed.Length {
    msg := "Some files failed to download:`n"
    for _, f in failed
        msg .= "  " f "`n"
    MsgBox msg "`nPartial update — please retry.",, 0x10
} else {
    Run SCRIPT_DIR "\mass_gui.ahk"
}
ExitApp
