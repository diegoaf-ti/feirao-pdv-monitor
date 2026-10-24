@echo off
setlocal
set "PDV_INSTALL_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PDV_INSTALL_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PDV_INSTALL_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0InstalarPacote.ps1"
if errorlevel 1 goto falha
echo Monitor instalado para este usuario.
start "" "%PDV_INSTALL_POWERSHELL%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Feirao\PdvMonitor\IniciarMonitorInstalado.ps1"
endlocal
exit /b 0
:falha
echo Nao foi possivel instalar. Encerre o monitor existente e confira a mensagem acima.
pause
endlocal
exit /b 1
