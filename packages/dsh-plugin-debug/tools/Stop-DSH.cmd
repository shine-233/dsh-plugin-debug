@echo off
setlocal
set "SCRIPT=%~dp0Stop-DSH.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ShowWindow %*
if errorlevel 1 pause
endlocal
