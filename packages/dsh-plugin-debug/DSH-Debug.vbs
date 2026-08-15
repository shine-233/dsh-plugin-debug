Option Explicit
Dim shell, root, command
Set shell = CreateObject("WScript.Shell")
root = Replace(WScript.ScriptFullName, WScript.ScriptName, "")
command = "powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Quote(root & "DSH-Debug.ps1") & " -Action doctor"
shell.Run command, 0, False
Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
