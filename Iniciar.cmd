@echo off
setlocal
set "PDV_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PDV_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PDV_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Inicializar.ps1"
if errorlevel 1 pause
endlocal
