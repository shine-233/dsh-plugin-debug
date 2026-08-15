@echo off
setlocal
set "SCRIPT=%~dp0Start-DSH.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
if errorlevel 1 pause
endlocal
