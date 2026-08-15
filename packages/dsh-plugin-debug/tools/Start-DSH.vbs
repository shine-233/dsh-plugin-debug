Option Explicit

Dim shell, fso, scriptPath, commandLine
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "Start-DSH.ps1")
commandLine = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Quote(scriptPath) & " -EnableCrashGuard"
shell.Run commandLine, 0, False

Function Quote(value)
  Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
