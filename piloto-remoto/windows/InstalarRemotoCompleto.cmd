@echo off
setlocal
echo Instalacao administrativa do suporte remoto Conecta.
echo Prefira Instalar.cmd para identificar automaticamente a conta do monitor.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0InstalarRemotoCompleto.ps1"
exit /b %ERRORLEVEL%
