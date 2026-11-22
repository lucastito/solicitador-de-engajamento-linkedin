@echo off
setlocal
set "SCRIPT=%~dp0solicitador_engajamento_linkedin.ps1"
if not exist "%SCRIPT%" exit /b 1
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
endlocal
exit /b 0