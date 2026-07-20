' pinger_start.vbs - start the MMA pinger silently.
'
' Double-click it, or let MMA launch it (Settings -> "Run the pinger"). It runs
' pinger.pyw --listen under pythonw.exe, so there is NO console window: the
' pinger sits in the background like the resident AHK scripts and logs to MMA's
' error_log.txt.
'
' A .cmd would flash a console for a moment even with `start`; wscript does not.
'
' Single-instance is enforced inside pinger.pyw (a named mutex, same idea as
' #SingleInstance), so running this twice is harmless - the second exits.
'
' To stop it:    python pinger.pyw --stop
' Is it up?:     python pinger.pyw --status

Option Explicit
Dim shell, fso, here, script, pyw, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "pinger.pyw")

If Not fso.FileExists(script) Then
    MsgBox "Cannot find:" & vbCrLf & script, vbCritical, "MMA pinger"
    WScript.Quit 1
End If

' Resolve pythonw.exe next to whatever python is on PATH; fall back to the bare
' name and let PATH resolve it. Using pythonw (not python) is what makes it silent.
pyw = "pythonw.exe"
On Error Resume Next
Dim exec, pyPath
Set exec = shell.Exec("cmd /c where python")
If Err.Number = 0 Then
    pyPath = Trim(Split(exec.StdOut.ReadAll, vbCrLf)(0))
    If pyPath <> "" And fso.FileExists(pyPath) Then
        Dim cand
        cand = fso.BuildPath(fso.GetParentFolderName(pyPath), "pythonw.exe")
        If fso.FileExists(cand) Then pyw = cand
    End If
End If
On Error GoTo 0

cmd = """" & pyw & """ """ & script & """ --listen"
' 0 = hidden window, False = do not wait for it to exit
shell.Run cmd, 0, False
