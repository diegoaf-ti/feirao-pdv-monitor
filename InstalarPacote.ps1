#requires -Version 2.0
$ErrorActionPreference='Stop';
try{
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WindowsRequired';}
  $source=Split-Path -Parent $MyInvocation.MyCommand.Path;
  & (Join-Path $source 'InstalarMonitor.ps1') | Out-Null;
  Write-Host 'Monitor instalado para o usuario atual.';
  if(-not [IO.File]::Exists((Join-Path $source 'piloto-remoto/windows/bundle/remoto-bundle.xml'))){Write-Host 'Este pacote contem somente o monitor. Para preparar suporte remoto, use o instalador com os componentes remotos conferidos.';return;}
  $answer=Read-Host 'Preparar tambem o suporte remoto neste computador? [S/N]';
  if($answer -ieq 'S'){
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
    if($sid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'InvalidMonitorAccount';}
    $path=Join-Path $source 'piloto-remoto/windows/InstalarRemotoCompleto.ps1';
    if($path -match '["\r\n]'){throw 'InvalidInstallerPath';}
    $powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
    if($env:PROCESSOR_ARCHITEW6432){$powerShell=Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe';}
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$path+'" -MonitorUserSid '+$sid;
    # One explicit UAC request after the operator chooses remote setup. SID is not a credential.
    $child=Start-Process -FilePath $powerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru;
    if($child.ExitCode -ne 0){Write-Host 'O monitor esta instalado. A preparacao remota precisa ser concluida; nenhum acesso foi liberado.';}
  }
}catch{Write-Host 'Nao foi possivel concluir a instalacao. Preserve os dados existentes e confira o pacote e a conta Windows.';exit 1;}
