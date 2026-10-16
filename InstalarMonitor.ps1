#requires -Version 2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop';
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'A instalação deve ser executada no Windows do caixa.'; }
$source = Split-Path -Parent $MyInvocation.MyCommand.Path;
$destination = Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor\programa';
# Lista explícita: não copia credenciais, configurações, logs ou arquivos do PDV.
$files = @('MonitorPdv.ps1', 'InicializarMonitor.ps1', 'Monitor.cmd', 'IniciarMonitor.vbs', 'InstalarMonitor.ps1', 'DesinstalarMonitor.ps1', 'PdvMonitor.Runtime.psm1', 'PdvMonitor.Coleta.psm1', 'PdvMonitor.Politica.psm1', 'PdvLegado.Core.psm1', 'PdvDispositivos.Core.psm1');
if (Test-Path -LiteralPath (Join-Path $source 'PdvMonitor.Transporte.psm1')) { $files += 'PdvMonitor.Transporte.psm1'; }
foreach ($file in $files) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $file))) { throw ('Pacote incompleto: ' + $file); }
}
$startup = [Environment]::GetFolderPath('Startup');
if (-not $startup) { throw 'A pasta de início automático do usuário não foi localizada.'; }
$linkPath = Join-Path $startup 'Feirao-PdvMonitor.lnk';
$shell = New-Object -ComObject WScript.Shell;
$arguments = '"' + (Join-Path $destination 'IniciarMonitor.vbs') + '"';
try {
  if (Test-Path -LiteralPath $linkPath) {
    $existing = $shell.CreateShortcut($linkPath);
    if ($existing.Arguments -ne $arguments) { throw 'Já existe um atalho com este nome e outro destino. Nenhum atalho foi substituído.'; }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($existing);
  }
  [void](New-Item -ItemType Directory -Path $destination -Force);
  if ([System.IO.Path]::GetFullPath($source).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($destination).TrimEnd('\')) {
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $destination $file) -Force; }
  }
  $shortcut = $shell.CreateShortcut($linkPath);
  $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe';
  $shortcut.Arguments = $arguments; $shortcut.WorkingDirectory = $destination;
  $shortcut.Description = 'Feirão: monitor local do pinpad e da impressora do PDV';
  $shortcut.Save();
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut);
  return $destination;
} finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell); }
