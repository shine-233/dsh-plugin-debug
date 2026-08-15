@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DSH-Debug.ps1" %*
exit /b %ERRORLEVEL%
