@echo off
setlocal
if not exist "%~dp0AtivarCertificadoRemotoBootstrap.ps1" (
  echo Pacote incompleto: bootstrap de ativacao ausente.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AtivarCertificadoRemotoBootstrap.ps1"
set "pdv_exit=%errorlevel%"
pause
exit /b %pdv_exit%
