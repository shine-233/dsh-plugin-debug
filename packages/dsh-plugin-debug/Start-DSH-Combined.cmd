@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DSH-Combined.ps1" %*
exit /b %ERRORLEVEL%
