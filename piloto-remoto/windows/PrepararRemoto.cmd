@echo off
setlocal
echo Preparacao opcional do componente remoto do Conecta.
echo Feche o monitor. Execute este arquivo com Executar como administrador.
echo Este passo copia apenas codigo e modelos inativos; nao habilita acesso remoto.
set "PDV_REMOTE_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PDV_REMOTE_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PDV_REMOTE_POWERSHELL%" (
  echo Windows PowerShell nao localizado.
  exit /b 1
)
"%PDV_REMOTE_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0InstalarComponenteRemoto.ps1"
set "PDV_REMOTE_RESULT=%ERRORLEVEL%"
if not "%PDV_REMOTE_RESULT%"=="0" echo Preparacao nao concluida. Confira a mensagem acima; nenhuma elevacao automatica foi feita.
pause
exit /b %PDV_REMOTE_RESULT%
