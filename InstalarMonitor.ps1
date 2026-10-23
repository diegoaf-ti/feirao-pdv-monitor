#requires -Version 2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop';
# O mutex coincide com o host e fica reservado ate o fim da copia.
# Assim, um segundo monitor/instalador nao pode abrir estes arquivos durante a troca.
function Get-PdvMonitorInstallMutexName {
  param([string]$UserIdentity,[string]$Directory);
  $algorithm=[Security.Cryptography.SHA256]::Create();
  try {
    $canonical=[IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).ToUpperInvariant();
    $bytes=[Text.Encoding]::UTF8.GetBytes($UserIdentity+'|'+$canonical);
    return ('Local\Feirao.PdvMonitor.'+([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-',''));
  } finally { $algorithm.Dispose(); }
}
function New-PdvMonitorInstallMutex {
  param([string]$Name);
  $created=$false;$mutex=$null;
  try {
    $mutex=New-Object Threading.Mutex($true,$Name,[ref]$created);
    if(-not $created){throw 'Encerre o monitor pelo icone ao lado do relogio antes de instalar. Nenhum programa foi encerrado.';}
    return $mutex;
  } catch { if($null -ne $mutex){$mutex.Dispose();};throw; }
}
function Test-PdvMonitorInstallShortcut {
  param($Shortcut,[string]$Arguments,[string]$TargetPath,[string]$LegacyArguments,[string]$LegacyTarget);
  return (($Shortcut.Arguments -ceq $Arguments -and $Shortcut.TargetPath -ieq $TargetPath) -or ($Shortcut.Arguments -ceq $LegacyArguments -and $Shortcut.TargetPath -ieq $LegacyTarget));
}
function Get-PdvMonitorInstallFiles {
  # Lista exata do core 0.7; a extensao administrativa remota e provisionada separadamente.
  return @('MonitorPdv.ps1','InicializarMonitor.ps1','Monitor.cmd','IniciarMonitor.vbs','InstalarMonitor.ps1','DesinstalarMonitor.ps1','PdvMonitor.Runtime.psm1','PdvMonitor.Inventario.psm1','PdvMonitor.Coleta.psm1','PdvMonitor.Politica.psm1','PdvLegado.Core.psm1','PdvDispositivos.Core.psm1','PdvMonitor.Transporte.psm1','PdvMonitor.Atualizacao.psm1','AplicarAtualizacao.ps1','monitor-version.txt','PdvMonitor.Nerus.psm1','PdvMonitor.Version.psm1','atualizacoes-chave-publica.xml','IniciarMonitorInstalado.ps1','PdvMonitor.Remoto.psm1','PdvMonitor.Remoto.Transporte.psm1');
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'A instalação deve ser executada no Windows do caixa.'; }
$source=Split-Path -Parent $MyInvocation.MyCommand.Path;
$dataDirectory=Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor';
$destination=Join-Path $dataDirectory 'programa';
$launcherPath=Join-Path $dataDirectory 'IniciarMonitorInstalado.ps1';
$files=@(Get-PdvMonitorInstallFiles);
foreach($file in $files){
  $path=Join-Path $source $file;
  if(-not [IO.File]::Exists($path) -or ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Pacote incompleto ou arquivo inseguro: '+$file);}
}
$startup=[Environment]::GetFolderPath('Startup');
if(-not $startup){throw 'A pasta de início automático do usuário não foi localizada.';}
$linkPath=Join-Path $startup 'Feirao-PdvMonitor.lnk';
$shortcutPaths=@($linkPath);$desktop=[Environment]::GetFolderPath('DesktopDirectory');
if($desktop){$shortcutPaths+=(Join-Path $desktop 'Monitor do PDV.lnk');}
$legacyArguments='"'+(Join-Path $destination 'IniciarMonitor.vbs')+'"';
$arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$launcherPath+'"';
$targetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
$guard=$null;$updateLock=$null;$shell=$null;
try {
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
  $guard=New-PdvMonitorInstallMutex (Get-PdvMonitorInstallMutexName $sid $dataDirectory);
  # O instalador tambem nao concorre com executor/bootstrap depois de o host sair.
  [void](New-Item -ItemType Directory -Path (Join-Path $dataDirectory 'atualizacoes') -Force);
  try{$updateLock=New-Object IO.FileStream((Join-Path $dataDirectory 'atualizacoes\aplicando.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);}
  catch{throw 'Existe uma atualizacao do monitor em andamento. Aguarde antes de instalar.';}
  if([IO.Directory]::Exists($destination)){
    if(([IO.File]::GetAttributes($destination) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [IO.Directory]::GetDirectories($destination).Length -ne 0){throw 'A pasta do programa contem diretorios inesperados. Preserve os dados e revise a instalacao.';}
    foreach($existingFile in [IO.Directory]::GetFiles($destination)){
      if($files -cnotcontains [IO.Path]::GetFileName($existingFile) -or ([IO.File]::GetAttributes($existingFile) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A pasta do programa contem arquivos inesperados. Preserve os dados e revise a instalacao.';}
    }
  }
  $shell=New-Object -ComObject WScript.Shell;
  foreach($shortcutPath in $shortcutPaths){
    if(Test-Path -LiteralPath $shortcutPath){
      $existing=$shell.CreateShortcut($shortcutPath);
      try{if(-not (Test-PdvMonitorInstallShortcut $existing $arguments $targetPath $legacyArguments (Join-Path $env:SystemRoot 'System32\wscript.exe'))){throw ('Já existe um atalho com este nome e outro destino. Nenhum atalho foi substituído: '+[IO.Path]::GetFileName($shortcutPath));}}
      finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($existing);}
    }
  }
  [void](New-Item -ItemType Directory -Path $destination -Force);
  if([IO.Path]::GetFullPath($source).TrimEnd('\') -ne [IO.Path]::GetFullPath($destination).TrimEnd('\')){
    foreach($file in $files){Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $destination $file) -Force;}
  }
  Copy-Item -LiteralPath (Join-Path $destination 'IniciarMonitorInstalado.ps1') -Destination $launcherPath -Force;
  Import-Module (Join-Path $destination 'PdvMonitor.Atualizacao.psm1') -Force;
  [void](Initialize-PdvMonitorUpdateTrust -DataDirectory $dataDirectory -PublicKeyPath (Join-Path $destination 'atualizacoes-chave-publica.xml'));
  foreach($shortcutPath in $shortcutPaths){
    $shortcut=$shell.CreateShortcut($shortcutPath);
    try{
      $shortcut.TargetPath=$targetPath;$shortcut.Arguments=$arguments;$shortcut.WorkingDirectory=$dataDirectory;
      $shortcut.Description='Feirão: monitor local do pinpad e da impressora do PDV';$shortcut.Save();
    } finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut);}
  }
  return $destination;
} finally {
  if($null -ne $shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell);}
  if($null -ne $updateLock){$updateLock.Close();}
  if($null -ne $guard){try{$guard.ReleaseMutex();}finally{$guard.Dispose();}}
}
