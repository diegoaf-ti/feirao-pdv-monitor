#requires -Version 2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop';
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Execute no Windows do caixa.'; }
$startup = [Environment]::GetFolderPath('Startup');
if (-not $startup) { throw 'A pasta de início automático do usuário não foi localizada.'; }
$linkPath = Join-Path $startup 'Feirao-PdvMonitor.lnk';
if (Test-Path -LiteralPath $linkPath) {
  $shell = New-Object -ComObject WScript.Shell;
  $shortcut = $null;
  try {
    $shortcut = $shell.CreateShortcut($linkPath);
    $expected = '"' + (Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor\programa\IniciarMonitor.vbs') + '"';
    $launcher = Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor\IniciarMonitorInstalado.ps1';
    $currentArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"';
    $currentTarget = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
    $legacyTarget = Join-Path $env:SystemRoot 'System32\wscript.exe';
    if (($shortcut.Arguments -ne $expected -or $shortcut.TargetPath -ine $legacyTarget) -and ($shortcut.Arguments -ne $currentArguments -or $shortcut.TargetPath -ine $currentTarget)) { throw 'O atalho aponta para outro destino e não será removido.'; }
    Remove-Item -LiteralPath $linkPath;
  } finally {
    if ($null -ne $shortcut) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut); }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell);
  }
}
Write-Host 'Início automático removido. Os logs, perfis e arquivos do programa foram preservados. Encerre o monitor pelo ícone ao lado do relógio.';
