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
    if ($shortcut.Arguments -ne $expected) { throw 'O atalho aponta para outro destino e não será removido.'; }
    Remove-Item -LiteralPath $linkPath;
  } finally {
    if ($null -ne $shortcut) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut); }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell);
  }
}
Write-Host 'Início automático removido. Os logs, perfis e arquivos do programa foram preservados. Encerre o monitor pelo ícone ao lado do relógio.';
