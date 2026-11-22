@echo off
setlocal
set "SCRIPT=%~dp0iniciar_baileys_bridge.ps1"
if not exist "%SCRIPT%" exit /b 1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
exit /b 0