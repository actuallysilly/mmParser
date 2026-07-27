#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/hotkeys.ahk"

cfgFile        := MMA_CFG
defaultSleep   := Integer(IniRead(cfgFile, "Recorder", "DefaultSleep", "500"))

recording      := false
sequence       := []
actionCount    := 0
lastTime       := 0
dragStartX     := 0
dragStartY     := 0
namedJustFired := false
actualTiming   := false
coordsFile     := MMA_SRC_COORDS

; ── overlay ──────────────────────────────────────────────────────────────────
overlay := Gui("+AlwaysOnTop +ToolWindow -Caption", "")
overlay.BackColor := "111111"
overlay.MarginX   := 14
overlay.MarginY   := 9
overlay.SetFont("s10 cWhite", "Segoe UI")
statusTxt := overlay.Add("Text", "w150 Center", "○   READY")
overlay.Show("x10 y10 w178 h38 NoActivate")
WinSetTransparent(210, "ahk_id " overlay.Hwnd)

overlay.OnEvent("ContextMenu", ShowOverlayMenu)
OnMessage(0x0084, (*) => 2)

ShowOverlayMenu(*) {
    global actualTiming
    m := Menu()
    m.Add("Actual timing", (*) => (actualTiming := !actualTiming))
    if actualTiming
        m.Check("Actual timing")
    m.Add()
    m.Add("Exit", (*) => ExitApp())
    m.Show()
}

; ── toggle ───────────────────────────────────────────────────────────────────
; key lives in hotkeys.ini under [recorder]. The ~LButton keys below stay
; hard-coded: they're only live while recording, and they ARE the recorder.
HK_Bind("recorder.toggle", ToggleRecording)

ToggleRecording(*) {
    global recording, sequence, actionCount, lastTime, namedJustFired
    if !recording {
        recording      := true
        sequence       := []
        actionCount    := 0
        namedJustFired := false
        lastTime       := A_TickCount
        Hotkey "~LButton",    RecordDown,  "On"
        Hotkey "~LButton Up", RecordUp,    "On"
        Hotkey "+LButton",    RecordNamed, "On"
        SetOverlay("●   REC   (0)", "2d0000", 255)
    } else {
        recording := false
        Hotkey "~LButton",    "Off"
        Hotkey "~LButton Up", "Off"
        Hotkey "+LButton",    "Off"
        SetOverlay("○   READY", "111111", 210)
        ShowOutput()
    }
}

SetOverlay(text, bg, alpha) {
    global overlay, statusTxt
    overlay.BackColor := bg
    statusTxt.Value   := text
    WinSetTransparent(alpha, "ahk_id " overlay.Hwnd)
}

; ── recording ─────────────────────────────────────────────────────────────────
RecordDown(*) {
    global dragStartX, dragStartY
    MouseGetPos &dragStartX, &dragStartY
}

RecordUp(*) {
    global sequence, actionCount, lastTime, dragStartX, dragStartY, namedJustFired, actualTiming, defaultSleep
    if namedJustFired {
        namedJustFired := false
        return
    }
    MouseGetPos &x2, &y2
    dx  := x2 - dragStartX
    dy  := y2 - dragStartY
    now := A_TickCount
    if sequence.Length > 0 {
        d := now - lastTime
        if actualTiming {
            if d > 50
                sequence.Push("Sleep " d)
        } else if d > 100 {
            sequence.Push("Sleep " defaultSleep)
        }
    }
    if Sqrt(dx*dx + dy*dy) > 10
        sequence.Push('MouseClickDrag "Left", ' dragStartX ', ' dragStartY ', ' x2 ', ' y2)
    else
        sequence.Push("clickOn([" dragStartX ", " dragStartY "])")
    lastTime := now
    actionCount++
    statusTxt.Value := "●   REC   (" actionCount ")"
}

RecordNamed(*) {
    global sequence, actionCount, lastTime, namedJustFired, coordsFile, actualTiming, defaultSleep
    namedJustFired := true
    MouseGetPos &x, &y
    ib := InputBox("Name for [" x ", " y "]", "Name Coordinate", "w260 h120")
    if ib.Result != "OK" || Trim(ib.Value) = ""
        return
    name := Trim(ib.Value)
    FileAppend name " := [" x ", " y "]`n", coordsFile
    now := A_TickCount
    if sequence.Length > 0 {
        d := now - lastTime
        if actualTiming {
            if d > 50
                sequence.Push("Sleep " d)
        } else if d > 100 {
            sequence.Push("Sleep " defaultSleep)
        }
    }
    sequence.Push("clickOn(" name ")")
    lastTime := now
    actionCount++
    statusTxt.Value := "●   REC   (" actionCount ")"
}

; ── output ────────────────────────────────────────────────────────────────────
ShowOutput() {
    global sequence, coordsFile
    if !sequence.Length {
        MsgBox "Nothing was recorded."
        return
    }
    out := ""
    for line in sequence
        out .= line "`n"
    out := Trim(out)

    g := Gui(, "Recorded Sequence")
    g.BackColor := "1a1a1a"
    g.SetFont("s10 cWhite", "Consolas")
    g.MarginX := 12
    g.MarginY := 12
    ed := g.Add("Edit", "w520 h320 Multi Background111111 cWhite", out)

    g.SetFont("s9 cWhite", "Segoe UI")
    g.Add("Text", "x12 y+10 w42 h20 +0x200", "Name:")
    nameEd := g.Add("Edit", "x+4 yp w196 Background111111 cWhite")
    g.Add("Button", "x+6 yp-2 w100 h24", "Save as fn").OnEvent("Click", SaveAsFn)

    g.Add("Button", "x12 y+10 w80",  "Replay").OnEvent("Click", ReplaySeq)
    g.Add("Button", "x+6 w110",      "Copy All").OnEvent("Click", (*) => A_Clipboard := ed.Value)
    g.Add("Button", "x+6 w130",      "Open coords.ahk").OnEvent("Click", (*) => Run("notepad.exe " coordsFile))
    g.Add("Button", "x+6 w80",       "Close").OnEvent("Click", (*) => g.Destroy())
    g.Show("w544")

    ReplaySeq(*) {
        content := Trim(ed.Value)
        if content = ""
            return
        tmpFile := A_Temp "\recorder_replay.ahk"
        script  := "#Requires AutoHotkey v2.0`n"
            . "#Include `"" MMA_SRC_COORDS "`"`n"
            . "#Include `"" MMA_SRC_UTILS "`"`n"
            . "Sleep 3000`n"
            . content
        FileDelete tmpFile
        FileAppend script, tmpFile, "UTF-8"
        Run A_AhkPath " `"" tmpFile "`""
        ToolTip "Replaying in 3s — switch to target window", , , 3
        SetTimer(() => ToolTip(,,,3), -3000)
    }

    SaveAsFn(*) {
        name := Trim(nameEd.Value)
        if name = "" {
            MsgBox "Enter a function name."
            return
        }
        name     := StrReplace(name, " ", "_") . "Seq"
        id       := "seq." name
        indented := "    " StrReplace(Trim(ed.Value), "`n", "`n    ")
        seqFile := MMA_SRC_SEQUENCES
        if !FileExist(seqFile)
            FileAppend "#Include `"coords.ahk`"`n#Include `"utils.ahk`"`n`n", seqFile, "UTF-8"
        FileAppend name "() {`n" indented "`n}`n`n", seqFile, "UTF-8"
        FileAppend 'HK_Bind("' id '", ' name ')`n`n', seqFile, "UTF-8"

        ; A new sequence has to exist in all three places to be bindable: declared
        ; in hotkeys.ahk, keyed in hotkeys.ini, wired in sequences.ahk. It arrives
        ; with a blank key = unbound, ready to assign in the Hotkeys GUI.
        if !DeclareSeqHotkey(id, name) {
            MsgBox "Saved " name "(), but couldn't declare it in hotkeys.ahk"
                 . " (the @recorder-sequences@ marker is missing).`n`n"
                 . "Add this line there by hand:`n`n"
                 . 'HK_Def("' id '", "' name '", , "sequences.ahk")',, 0x30
            return
        }
        IniWrite "", MMA_HK_INI, "seq", name

        nameEd.Value := ""
        ToolTip "Saved as " name "()  — assign a key in the Hotkeys GUI", , , 2
        SetTimer(() => ToolTip(,,,2), -2000)
    }
}

; Add a HK_Def line for a recorded sequence at the marker in hotkeys.ahk, so the
; registry knows the id exists (HK_Bind refuses undeclared ids by design).
DeclareSeqHotkey(id, label) {
    hkFile := MMA_SRC_HOTKEYS
    marker := "; @recorder-sequences@"
    if !FileExist(hkFile)
        return false
    content := FileRead(hkFile, "UTF-8")
    if !InStr(content, marker)
        return false
    if InStr(content, 'HK_Def("' id '"')
        return true                       ; already declared — re-saving is fine
    content := StrReplace(content, marker,
                          'HK_Def("' id '", "' label '", , "sequences.ahk")`n' marker, , , 1)
    f := FileOpen(hkFile, "w", "UTF-8")
    f.Write(content)
    f.Close()
    return true
}
