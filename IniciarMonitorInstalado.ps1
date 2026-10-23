#requires -Version 2.0
# Bootstrap estável, instalado na pasta de dados (fora de programa).
[CmdletBinding()]
param([string]$DataDirectory='')
$ErrorActionPreference='Stop';

function Read-PdvStableXml {
  param([string]$Path,[int]$MaxBytes=32768);
  if (-not [IO.File]::Exists($Path) -or (New-Object IO.FileInfo($Path)).Length -gt $MaxBytes) { throw 'BootstrapMetadataUnavailable'; }
  $settings=New-Object Xml.XmlReaderSettings; $settings.ProhibitDtd=$true; $settings.XmlResolver=$null; $reader=$null;
  try { $reader=[Xml.XmlReader]::Create($Path,$settings); $xml=New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.Load($reader); return ,$xml; }
  finally { if ($null -ne $reader) { $reader.Close(); } }
}
function Get-PdvStableSha256 {
  param([string]$Path);
  $hash=[Security.Cryptography.SHA256]::Create(); $stream=[IO.File]::OpenRead($Path);
  try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant(); }
  finally { $stream.Close(); $hash.Clear(); }
}
function Assert-PdvStableNoReparse {
  param([string]$Path);
  $current=[IO.Path]::GetFullPath($Path);
  while ($current) {
    if (([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'BootstrapReparsePointRejected'; }
    $parent=[IO.Path]::GetDirectoryName($current); if ($parent -eq $current) { break; }; $current=$parent;
  }
}
function Write-PdvStableText {
  param([string]$Path,[string]$Text);
  $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'; $backup=$temp+'.bak';
  try { [IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($false))); if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,$backup); } else { [IO.File]::Move($temp,$Path); } }
  finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp); }; if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup); } }
}
function Start-PdvStableMonitor {
  param([string]$ProgramDirectory,[string]$DataDirectory);
  # O próprio monitor faz a exclusão de instância; não fecha PDV/TEF nem processos existentes.
  & (Join-Path $ProgramDirectory 'MonitorPdv.ps1') -StartHidden -DataDirectory $DataDirectory;
}
function Invoke-PdvStableMonitorBootstrap {
  param([string]$DataDirectory);
  $data=[IO.Path]::GetFullPath($DataDirectory); $program=Join-Path $data 'programa'; $root=Join-Path $data 'atualizacoes'; $backup=Join-Path $root 'backup'; $lock=$null;
  Assert-PdvStableNoReparse $data;
  if ([IO.Directory]::Exists($program)) { Assert-PdvStableNoReparse $program; Start-PdvStableMonitor $program $data; return 'Started'; }
  if (-not [IO.Directory]::Exists($backup)) { throw 'BootstrapProgramAndBackupMissing'; }
  Assert-PdvStableNoReparse $backup;
  try {
    # Mesmo lock do atualizador: o bootstrap nunca restaura enquanto ele está ativo.
    try { $lock=New-Object IO.FileStream((Join-Path $root 'aplicando.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); }
    catch { throw 'BootstrapUpdateStillRunning'; }
    # Uma troca pode ter terminado entre a primeira leitura e a aquisição do lock.
    if ([IO.Directory]::Exists($program)) { return 'UpdateAlreadyRestored'; }
    $state=Read-PdvStableXml (Join-Path $root 'estado.xml') 4096; $journal=$state.DocumentElement;
    if ($journal.Name -cne 'Update' -or $journal.Attributes.Count -ne 4 -or $journal.ChildNodes.Count -ne 0 -or $journal.GetAttribute('status') -cne 'applying' -or $journal.GetAttribute('reason') -cne 'UpdateReplacingMonitor' -or $journal.GetAttribute('version') -cnotmatch '^(0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})$') { throw 'BootstrapJournalInvalid'; }
    $manifest=Read-PdvStableXml (Join-Path $root 'backup-manifest.xml'); $m=$manifest.DocumentElement;
    $allowed=@('MonitorPdv.ps1','InicializarMonitor.ps1','Monitor.cmd','IniciarMonitor.vbs','InstalarMonitor.ps1','DesinstalarMonitor.ps1','PdvMonitor.Runtime.psm1','PdvMonitor.Inventario.psm1','PdvMonitor.Coleta.psm1','PdvMonitor.Politica.psm1','PdvLegado.Core.psm1','PdvDispositivos.Core.psm1','PdvMonitor.Transporte.psm1','PdvMonitor.Atualizacao.psm1','AplicarAtualizacao.ps1','monitor-version.txt','PdvMonitor.Nerus.psm1','PdvMonitor.Version.psm1','atualizacoes-chave-publica.xml','IniciarMonitorInstalado.ps1','PdvMonitor.Remoto.psm1','PdvMonitor.Remoto.Transporte.psm1');
    if ($m.Name -cne 'PdvMonitorBackup' -or $m.Attributes.Count -ne 3 -or $m.GetAttribute('schemaVersion') -cne '1' -or $m.GetAttribute('targetVersion') -cne $journal.GetAttribute('version') -or $m.GetAttribute('version') -cnotmatch '^(0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})$' -or [Version]$m.GetAttribute('version') -ge [Version]$m.GetAttribute('targetVersion') -or $m.ChildNodes.Count -ne $allowed.Length -or [IO.Directory]::GetDirectories($backup).Length -ne 0 -or [IO.Directory]::GetFiles($backup).Length -ne $allowed.Length) { throw 'BootstrapBackupManifestInvalid'; }
    $seen=@{};
    foreach ($entry in $m.ChildNodes) {
      $name=$entry.GetAttribute('name'); $sha=$entry.GetAttribute('sha256'); $size=$entry.GetAttribute('sizeBytes');
      if ($entry.LocalName -cne 'File' -or $entry.Attributes.Count -ne 3 -or $entry.ChildNodes.Count -ne 0 -or $name -notmatch '^[A-Za-z0-9.-]+$' -or $allowed -notcontains $name -or $seen.ContainsKey($name) -or $sha -cnotmatch '^[a-f0-9]{64}$' -or $size -cnotmatch '^(0|[1-9][0-9]{0,6})$' -or [long]$size -gt 4194304) { throw 'BootstrapBackupEntryInvalid'; }
      $seen[$name]=$true; $path=Join-Path $backup $name; Assert-PdvStableNoReparse $path;
      if (-not [IO.File]::Exists($path) -or (New-Object IO.FileInfo($path)).Length -ne [long]$size -or (Get-PdvStableSha256 $path) -cne $sha) { throw 'BootstrapBackupIntegrityFailed'; }
    }
    if ([IO.File]::ReadAllText((Join-Path $backup 'monitor-version.txt')).Trim() -cne $m.GetAttribute('version')) { throw 'BootstrapBackupVersionMismatch'; }
    # Persiste a quarentena antes de restaurar, para sobreviver a outra queda neste passo.
    Write-PdvStableText (Join-Path $root 'versao-rejeitada.txt') $journal.GetAttribute('version');
    $pending=Join-Path $root 'saude-pendente.xml'; if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending); }
    $health=Join-Path $root 'saude.xml'; if ([IO.File]::Exists($health)) { [IO.File]::Delete($health); }
    [IO.Directory]::Move($backup,$program);
    $journal.SetAttribute('status','rolledBack'); $journal.SetAttribute('reason','UpdatePowerInterruptionRecovered'); $journal.SetAttribute('at',[DateTimeOffset]::UtcNow.ToString('o'));
    Write-PdvStableText (Join-Path $root 'estado.xml') $journal.OuterXml;
  } finally { if ($null -ne $lock) { $lock.Close(); } }
  Start-PdvStableMonitor $program $data; return 'Recovered';
}

# Dot source apenas define as funções para os testes offline; nenhuma coleta é executada.
if ($MyInvocation.InvocationName -ne '.') {
  if (-not $DataDirectory) { $DataDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path; }
  try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'O monitor instalado deve iniciar no Windows do caixa.'; }
    Invoke-PdvStableMonitorBootstrap $DataDirectory | Out-Null;
  } catch {
    $message='Não foi possível iniciar ou restaurar o monitor. Nenhum sistema do caixa foi encerrado. Motivo: '+$_.Exception.Message;
    try { [IO.File]::WriteAllText((Join-Path $DataDirectory 'falha-inicializacao-monitor.txt'),$message,[Text.Encoding]::UTF8); } catch { }
    Add-Type -AssemblyName System.Windows.Forms;
    [void][System.Windows.Forms.MessageBox]::Show($message,'Monitor do PDV','OK','Error'); exit 1;
  }
}
