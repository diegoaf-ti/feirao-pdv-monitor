@echo off
setlocal
set "PDV_MONITOR_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PDV_MONITOR_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PDV_MONITOR_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0InicializarMonitor.ps1"
if errorlevel 1 pause
endlocal
