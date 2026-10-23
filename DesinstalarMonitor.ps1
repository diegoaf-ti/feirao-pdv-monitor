#requires -Version 2.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';
function Test-PdvMonitorUninstallShortcut {
  param($Shortcut,[string]$Arguments,[string]$TargetPath,[bool]$AllowLegacy=$false,[string]$LegacyArguments='',[string]$LegacyTarget='');
  if($Shortcut.Arguments -ceq $Arguments -and $Shortcut.TargetPath -ieq $TargetPath){return $true;}
  return ($AllowLegacy -and $LegacyArguments -and $LegacyTarget -and $Shortcut.Arguments -ceq $LegacyArguments -and $Shortcut.TargetPath -ieq $LegacyTarget);
}
function Get-PdvMonitorUninstallTargets {
  param([string]$Startup,[string]$Desktop);
  $targets=@();
  if($Startup){$targets+=(New-Object PSObject -Property @{Path=(Join-Path $Startup 'Feirao-PdvMonitor.lnk');AllowLegacy=$true;});}
  # Apenas o alias criado pelo instalador0.7; nao procura outros atalhos no Desktop.
  if($Desktop){$targets+=(New-Object PSObject -Property @{Path=(Join-Path $Desktop 'Monitor do PDV.lnk');AllowLegacy=$false;});}
  return $targets;
}
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Execute no Windows do caixa.';}
$startup=[Environment]::GetFolderPath('Startup');$desktop=[Environment]::GetFolderPath('DesktopDirectory');
if(-not $startup -and -not $desktop){throw 'As pastas de atalhos do usuario nao foram localizadas.';}
$targets=@(Get-PdvMonitorUninstallTargets $startup $desktop);
$launcher=Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor\IniciarMonitorInstalado.ps1';
$currentArguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcher+'"';
$currentTarget=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
$legacyArguments='"'+(Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor\programa\IniciarMonitor.vbs')+'"';
$legacyTarget=Join-Path $env:SystemRoot 'System32\wscript.exe';
$shell=$null;
try {
  foreach($entry in $targets){
    if(-not (Test-Path -LiteralPath $entry.Path)){continue;}
    if($null -eq $shell){$shell=New-Object -ComObject WScript.Shell;}
    $shortcut=$null;
    try {
      $shortcut=$shell.CreateShortcut($entry.Path);
      if(Test-PdvMonitorUninstallShortcut $shortcut $currentArguments $currentTarget ([bool]$entry.AllowLegacy) $legacyArguments $legacyTarget){
        Remove-Item -LiteralPath $entry.Path;
      } else { Write-Host ('Atalho de outro destino preservado: '+[IO.Path]::GetFileName($entry.Path)); }
    } finally {if($null -ne $shortcut){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut);}}
  }
} finally {if($null -ne $shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell);}}
Write-Host 'Atalhos proprios removidos. Dados, credenciais, logs, perfis e programa foram preservados. Encerre o monitor pelo icone ao lado do relogio.';
