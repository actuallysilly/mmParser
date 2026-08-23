' typelog_start.vbs - start the MMA typelog recorder silently.
'
' Let MMA launch it (Settings -> Features -> "Typelog", or the Tools window), or
' double-click it. It runs typelog.pyw --listen under pythonw.exe, so there is NO
' console window: the recorder sits in the background like the pinger and logs its
' operational lines to MMA's error_log.txt. The text it records goes to
' userdata\typelog\.
'
' A .cmd would flash a console for a moment even with `start`; wscript does not.
'
' Single-instance is enforced inside typelog.pyw (a named mutex, same idea as
' #SingleInstance), so running this twice is harmless - the second exits.
'
' Exit codes:  0 = launched   1 = the .py is missing
'              2 = no usable Python   3 = the launch itself failed
'
' To stop it:    python typelog.pyw --stop
' Is it up?:     python typelog.pyw --status

Option Explicit
Dim shell, fso, here, script, pyw, cmd
Dim exec, pyPath, cand, f

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "typelog.pyw")

If Not fso.FileExists(script) Then
    MsgBox "Cannot find:" & vbCrLf & script, vbCritical, "MMA typelog"
    WScript.Quit 1
End If

' Resolve a REAL pythonw.exe. Three things this must not do:
'
'   - Fall back to the bare name "pythonw.exe" and hope PATH resolves it. When it
'     does not, shell.Run RAISES, and MMA may start this automatically -- so that
'     would be an error dialog on a machine with no Python installed.
'
'   - Accept a zero-byte hit. Those are the Microsoft Store's App Execution
'     Aliases (a reparse-point stub in WindowsApps): running one opens the Store
'     instead of starting Python.
'
'   - Look only at the FIRST line `where` prints. On a machine with both, the
'     Store stub is listed FIRST and the real interpreter second, so checking one
'     line finds the stub, rejects it, and wrongly concludes there is no Python.
pyw = ""
On Error Resume Next

Set exec = shell.Exec("cmd /c where pythonw.exe")
If Err.Number = 0 Then pyw = FirstRealExe(exec.StdOut.ReadAll)
Err.Clear

' Nothing usable named pythonw - try python, and take the pythonw beside it.
If pyw = "" Then
    Set exec = shell.Exec("cmd /c where python.exe")
    If Err.Number = 0 Then
        pyPath = FirstRealExe(exec.StdOut.ReadAll)
        If pyPath <> "" Then
            cand = fso.BuildPath(fso.GetParentFolderName(pyPath), "pythonw.exe")
            If fso.FileExists(cand) Then
                Set f = fso.GetFile(cand)
                If f.Size > 0 Then pyw = cand
            End If
        End If
    End If
End If
Err.Clear

' No usable interpreter. Quit QUIETLY: a .vbs has nowhere to report a failure
' except its own dialog. MMA decides what to say, and says it only when the
' feature is switched on by hand -- see PythonAvailable() in processes.ahk.
If pyw = "" Then WScript.Quit 2

cmd = """" & pyw & """ """ & script & """ --listen"
' 0 = hidden window, False = do not wait for it to exit
shell.Run cmd, 0, False
If Err.Number <> 0 Then WScript.Quit 3
On Error GoTo 0

' First line of `where` output naming a file that exists and is not a zero-byte
' Store alias stub. "" when there is no such line.
Function FirstRealExe(listing)
    Dim lines, i, p, ff
    FirstRealExe = ""
    lines = Split(listing, vbCrLf)
    For i = 0 To UBound(lines)
        p = Trim(lines(i))
        If p <> "" Then
            If fso.FileExists(p) Then
                Set ff = fso.GetFile(p)
                If ff.Size > 0 Then
                    FirstRealExe = p
                    Exit For
                End If
            End If
        End If
    Next
End Function
