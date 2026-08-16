Option Explicit

Dim shell, fso, scriptPath, command, index
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "Start-DSH-Debug.ps1")
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(scriptPath)
For index = 0 To WScript.Arguments.Count - 1
  command = command & " " & Quote(WScript.Arguments(index))
Next
shell.Run command, 0, False

Function Quote(value)
  Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
