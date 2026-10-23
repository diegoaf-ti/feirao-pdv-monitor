#requires -Version 5.1
# Offline: fixture de arquivos e mocks das APIs Windows; nao instala componentes.
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version 2.0;
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
. (Join-Path $directory 'piloto-remoto/windows/InstalarComponenteRemoto.ps1');
$script:Checks = 0; $script:Cases = 0; $script:Failures = @();
$base = [IO.Path]::GetTempPath(); if ([IO.Directory]::Exists('/private/tmp')) { $base = '/private/tmp'; }
$temporary = Join-Path $base ('pdv-remote-install-tests-' + [Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($temporary);
$script:ActualNative = (Get-Command Initialize-PdvRemoteInstallNative).ScriptBlock;
$script:ActualAcl = (Get-Command Assert-PdvRemoteInstallAcl).ScriptBlock;
function Assert-Install($Value, [string]$Message) { $script:Checks++; if (-not $Value) { throw $Message; } }
function Assert-InstallThrows([scriptblock]$Body, [string]$Message) { $script:Checks++; try { & $Body | Out-Null; } catch { if (-not $Message -or $_.Exception.Message.Contains($Message)) { return; }; throw ('Erro inesperado: ' + $_.Exception.Message); }; throw ('Erro esperado: ' + $Message); }
function Test-Install([string]$Name, [scriptblock]$Body) { $script:Cases++; try { & $Body; Write-Output ('OK: ' + $Name); } catch { $script:Failures += ($Name + ': ' + $_.Exception.Message + ' ' + $_.ScriptStackTrace); Write-Output ('FALHOU: ' + $Name + ': ' + $_.Exception.Message); } }
function Write-InstallManifest {
  param([string]$Root);
  $xml = New-Object Xml.XmlDocument; $node = $xml.CreateElement('PdvRemoteInstallManifest'); $node.SetAttribute('schemaVersion', '1'); [void]$xml.AppendChild($node);
  foreach ($relative in (Get-PdvRemoteInstallFiles)) { $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $relative)); $file = $xml.CreateElement('File'); $file.SetAttribute('path', $relative); $file.SetAttribute('sha256', (Get-PdvRemoteInstallHash $bytes)); $file.SetAttribute('sizeBytes', [string]$bytes.Length); [void]$node.AppendChild($file); }
  [IO.File]::WriteAllText((Join-Path $Root 'remoto-instalacao-sha256.xml'), $xml.OuterXml, (New-Object Text.UTF8Encoding($false)));
}
function New-InstallCase {
  $path = Join-Path $temporary ([Guid]::NewGuid().ToString('N')); $package = Join-Path $path 'pacote'; $windows = Join-Path $package 'piloto-remoto/windows'; [void][IO.Directory]::CreateDirectory($windows);
  foreach ($relative in (Get-PdvRemoteInstallFiles)) { [IO.File]::WriteAllText((Join-Path $package $relative), ('FIXTURE INATIVA ' + $relative)); }
  Write-InstallManifest $package;
  $common = Join-Path $path 'CommonData'; [void][IO.Directory]::CreateDirectory($common);
  $feirao = Join-Path $common 'Feirao'; $remote = Join-Path $feirao 'PdvMonitorRemoto';
  $script:Target = @{ Common = $common; Feirao = $feirao; Remote = $remote; App = (Join-Path $remote 'app') };
  $script:PdvRemoteInstallScriptDirectory = $windows; $script:Effects = @(); $script:LinksChecked = 0; $script:RejectLink = ''; $script:FailWrite = 0; $script:Writes = 0; $script:AdminDenied = $false; $script:UnsafeAcl = ''; $script:AlterAfterSnapshot = '';
  return @{ Path = $path; Package = $package; Target = $script:Target };
}
function Assert-PdvRemoteInstallAdministrator { if ($script:AdminDenied) { throw 'AdministratorRequired'; } }
function Initialize-PdvRemoteInstallNative { }
function Assert-PdvRemoteInstallSingleLink { param($Stream); $script:LinksChecked++; if ($script:RejectLink -and $Stream.Name.EndsWith($script:RejectLink)) { throw 'RemoteInstallLinkedFile'; } }
function Get-PdvRemoteInstallTarget { return $script:Target; }
function Assert-PdvRemoteInstallAcl { param($Path, $Ancestor = $false); if ($script:UnsafeAcl -and $Path -ceq $script:UnsafeAcl) { throw 'RemoteInstallUnsafeAcl'; } }
function New-PdvRemoteInstallDirectory { param($Path); if ([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) { throw 'DirectoryAlreadyExists'; }; $script:Effects += ('mkdir:' + $Path); [void][IO.Directory]::CreateDirectory($Path); }
function Write-PdvRemoteInstallFile { param($Path, $Bytes); $script:Writes++; if ($script:FailWrite -eq $script:Writes) { throw 'SimulatedWriteFailure'; }; $script:Effects += ('write:' + $Path); [IO.File]::WriteAllBytes($Path, $Bytes); }
function Get-PdvRemoteInstallTrustedSids { param($Ancestor = $false); $sids = @('S-1-5-18', 'S-1-5-32-544'); if ($Ancestor) { $sids += 'S-1-5-80-TEST'; }; return $sids; }
function Get-Acl { param($LiteralPath); return $script:FakeAcl; }
function New-InstallFakeAcl {
  param([string]$Owner, $Rules);
  $acl = New-Object PSObject -Property @{ OwnerSid = $Owner; Rules = @($Rules) };
  $acl | Add-Member ScriptMethod GetOwner { param($Type); return (New-Object PSObject -Property @{Value = $this.OwnerSid}); };
  $acl | Add-Member ScriptMethod GetAccessRules { param($Explicit, $Inherited, $Type); return $this.Rules; };
  return $acl;
}
function New-InstallRule {
  param([string]$Sid, $Rights, $Propagation = [Security.AccessControl.PropagationFlags]::None, $Type = [Security.AccessControl.AccessControlType]::Allow);
  return (New-Object PSObject -Property @{IdentityReference = (New-Object PSObject -Property @{Value = $Sid}); FileSystemRights = $Rights; PropagationFlags = $Propagation; AccessControlType = $Type});
}
try {
  Test-Install 'dot-source define funcoes sem executar instalacao ou APIs Windows' {
    Assert-Install ([IO.Directory]::GetFileSystemEntries($temporary).Length -eq 0) 'Dot-source teve efeitos';
    & $script:ActualNative;
    Assert-Install ($null -ne ('Conecta.PdvRemoteInstall.NativeV1' -as [type])) 'Interop C# nao compilou';
  }
  Test-Install 'pacote fechado com fontes da lista fechada e snapshot completo antes da copia' {
    $case = New-InstallCase; $files = Read-PdvRemoteInstallPackage $case.Package;
    Assert-Install ($files.Count -eq @(Get-PdvRemoteInstallFiles).Count -and $script:LinksChecked -eq (2 * (@(Get-PdvRemoteInstallFiles).Count + 1))) 'Nao validou todos os arquivos e manifesto';
    Assert-Install ($script:Effects.Count -eq 0) 'Leitura escreveu';
    Assert-Install ((@($files | ForEach-Object { $_.RelativePath }) -join '|') -ceq ((Get-PdvRemoteInstallFiles) -join '|')) 'Allowlist divergente';
  }
  Test-Install 'manifesto somente leitura e aceito sem modificar o pacote' {
    $case = New-InstallCase; $path = Join-Path $case.Package 'remoto-instalacao-sha256.xml'; $before = [IO.File]::ReadAllBytes($path); $attributes = [IO.File]::GetAttributes($path);
    try {
      [IO.File]::SetAttributes($path, ($attributes -bor [IO.FileAttributes]::ReadOnly)); $files = Read-PdvRemoteInstallPackage $case.Package;
      Assert-Install ($files.Count -eq @(Get-PdvRemoteInstallFiles).Count -and (Get-PdvRemoteInstallHash ([IO.File]::ReadAllBytes($path))) -ceq (Get-PdvRemoteInstallHash $before)) 'Modificou manifesto';
      Assert-Install ($script:Effects.Count -eq 0) 'Leitura produziu efeitos';
    } finally { [IO.File]::SetAttributes($path, $attributes); }
  }
  Test-Install 'manifesto rejeita campos extras, arquivo ativo, chave, travessia e duplicacao' {
    $case = New-InstallCase; $raw = [IO.File]::ReadAllText((Join-Path $case.Package 'remoto-instalacao-sha256.xml'));
    foreach ($invalid in @($raw.Replace('schemaVersion="1"', 'schemaVersion="1" command="run"'), $raw.Replace('PdvMonitor.Remoto.Windows.psm1', 'piloto-remoto/windows/remoto-piloto.xml'), $raw.Replace('PdvMonitor.Remoto.Windows.psm1', 'private.key'), $raw.Replace('PdvMonitor.Remoto.Windows.psm1', '../PdvMonitor.Remoto.Windows.psm1'), $raw.Replace('piloto-remoto/windows/RemoteWindowsNative.cs', 'PdvMonitor.Remoto.Windows.psm1'), $raw.Replace('</PdvRemoteInstallManifest>', '<File path="extra" sha256="'+('a'*64)+'" sizeBytes="1"/></PdvRemoteInstallManifest>'))) {
      Assert-InstallThrows { Read-PdvRemoteInstallManifest ([Text.Encoding]::UTF8.GetBytes($invalid)); } 'RemoteInstallManifestInvalid';
    }
  }
  Test-Install 'manifesto recusa DTD, entidades, encoding invalido e tamanhos fora do limite' {
    $case = New-InstallCase; $raw = [IO.File]::ReadAllText((Join-Path $case.Package 'remoto-instalacao-sha256.xml'));
    foreach ($invalid in @('<!DOCTYPE test [<!ENTITY x SYSTEM "file:///NONEXISTENT">]>'+$raw, $raw.Replace('sizeBytes="', 'unknown="'), '<!--SECRET-->'+$raw, ('x'*8193))) { Assert-InstallThrows { Read-PdvRemoteInstallManifest ([Text.Encoding]::UTF8.GetBytes($invalid)); } 'RemoteInstallManifestInvalid'; }
    Assert-InstallThrows { Read-PdvRemoteInstallManifest ([byte[]]@(255,255)); } 'RemoteInstallManifestInvalid';
  }
  Test-Install 'hash incorreto no ultimo arquivo impede todos os efeitos' {
    $case = New-InstallCase; [IO.File]::AppendAllText((Join-Path $case.Package 'piloto-remoto/windows/COMPATIBILIDADE-WINDOWS7.md'), 'alterado');
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'Pacote remoto incompleto ou alterado';
    Assert-Install ($script:Effects.Count -eq 0 -and -not [IO.Directory]::Exists($case.Target.Feirao)) 'Escreveu antes de validar';
  }
  Test-Install 'arquivo ausente, manifesto ausente e evidencia hardlink recusam antes da escrita' {
    $case = New-InstallCase; [IO.File]::Delete((Join-Path $case.Package 'piloto-remoto/windows/RemoteWindowsNative.cs'));
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallPathMissing'; Assert-Install ($script:Effects.Count -eq 0) 'Ausente teve efeito';
    $case = New-InstallCase; [IO.File]::Delete((Join-Path $case.Package 'remoto-instalacao-sha256.xml'));
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallPathMissing'; Assert-Install ($script:Effects.Count -eq 0) 'Sem manifesto teve efeito';
    $case = New-InstallCase; $script:RejectLink = 'RemoteWindowsNative.cs';
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallLinkedFile'; Assert-Install ($script:Effects.Count -eq 0) 'Hardlink teve efeito';
  }
  Test-Install 'arquivo fonte ou ancestral reparse e recusado' {
    $case = New-InstallCase; $target = Join-Path $case.Package 'PdvMonitor.Remoto.Windows.psm1'; $real = Join-Path $case.Package 'backup-source'; [IO.File]::Move($target, $real);
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { [void][IO.File]::CreateSymbolicLink($target, $real); Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallReparsePath'; Assert-Install ($script:Effects.Count -eq 0) 'Link teve efeito'; }
    else { Assert-Install ($true) 'Teste de fixture symlink requer plataforma do ensaio offline'; }
  }
  Test-Install 'administrador obrigatorio sem autoelevacao' {
    $case = New-InstallCase; $script:AdminDenied = $true;
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'AdministratorRequired'; Assert-Install ($script:Effects.Count -eq 0 -and $script:LinksChecked -eq 0) 'Falhou apos efeitos';
  }
  Test-Install 'instalacao existente e perfil ativo permanecem intactos' {
    $case = New-InstallCase; [void][IO.Directory]::CreateDirectory($case.Target.App); $active = Join-Path $case.Target.App 'remoto-piloto.xml'; [IO.File]::WriteAllText($active, 'CONFIGURACAO EXISTENTE');
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'Feche o monitor'; Assert-Install ($script:Effects.Count -eq 0 -and [IO.File]::ReadAllText($active) -ceq 'CONFIGURACAO EXISTENTE') 'Alterou instalacao existente';
  }
  Test-Install 'reparse no destino e ACL ampla recusam antes de criar pasta' {
    $case = New-InstallCase;
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { $other = Join-Path $case.Path 'other'; [void][IO.Directory]::CreateDirectory($other); [void][IO.Directory]::CreateSymbolicLink($case.Target.Feirao, $other); Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallReparsePath'; Assert-Install ($script:Effects.Count -eq 0 -and [IO.Directory]::GetFileSystemEntries($other).Length -eq 0) 'Reparse destino teve efeito'; }
    $case = New-InstallCase; [void][IO.Directory]::CreateDirectory($case.Target.Feirao); $script:UnsafeAcl = $case.Target.Feirao;
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'RemoteInstallUnsafeAcl'; Assert-Install ($script:Effects.Count -eq 0) 'ACL insegura teve efeito';
  }
  Test-Install 'leitores RX permitidos, escrita Users recusada e InheritOnly ignorado no ancestral' {
    $read = New-InstallRule 'S-1-5-32-545' ([Security.AccessControl.FileSystemRights]::ReadAndExecute);
    $script:FakeAcl = New-InstallFakeAcl 'S-1-5-32-544' @($read); & $script:ActualAcl 'fixture'; Assert-Install ($true) 'RX recusado';
    $write = New-InstallRule 'S-1-5-32-545' ([Security.AccessControl.FileSystemRights]::Write);
    $script:FakeAcl = New-InstallFakeAcl 'S-1-5-32-544' @($write); Assert-InstallThrows { & $script:ActualAcl 'fixture'; } 'RemoteInstallUnsafeAcl';
    $create = New-InstallRule 'S-1-5-32-545' ([Security.AccessControl.FileSystemRights]::CreateDirectories);
    $inherit = New-InstallRule 'S-1-3-0' ([Security.AccessControl.FileSystemRights]::FullControl) ([Security.AccessControl.PropagationFlags]::InheritOnly);
    $script:FakeAcl = New-InstallFakeAcl 'S-1-5-80-TEST' @($create, $inherit); & $script:ActualAcl 'fixture' $true; Assert-Install ($true) 'Ancestral legitimo recusado';
    $delete = New-InstallRule 'S-1-5-32-545' ([Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles);
    $script:FakeAcl = New-InstallFakeAcl 'S-1-5-80-TEST' @($delete); Assert-InstallThrows { & $script:ActualAcl 'fixture' $true; } 'RemoteInstallUnsafeAcl';
    $script:FakeAcl = New-InstallFakeAcl 'S-1-5-21-USER' @($read); Assert-InstallThrows { & $script:ActualAcl 'fixture'; } 'RemoteInstallUnsafeAcl';
  }
  Test-Install 'primeira copia contem apenas a lista de arquivos e nenhum perfil ou segredo' {
    $case = New-InstallCase; [IO.File]::WriteAllText((Join-Path $case.Package 'private.key'), 'CHAVE FALSA NAO COPIAR'); [IO.File]::WriteAllText((Join-Path $case.Package 'piloto-remoto/windows/remoto-piloto.xml'), 'ATIVO NAO COPIAR');
    $result = @(Invoke-PdvRemoteAdministrativeInstall); Assert-Install ($result[-1] -ceq $case.Target.App) 'Destino divergente';
    $copied = [IO.Directory]::GetFiles($case.Target.App, '*', [IO.SearchOption]::AllDirectories);
    Assert-Install ($copied.Length -eq @(Get-PdvRemoteInstallFiles).Count -and $script:Writes -eq @(Get-PdvRemoteInstallFiles).Count) 'Quantidade inesperada';
    foreach ($relative in (Get-PdvRemoteInstallFiles)) { Assert-Install ([IO.File]::ReadAllText((Join-Path $case.Target.App $relative)) -ceq ('FIXTURE INATIVA ' + $relative)) 'Copia divergente'; }
    Assert-Install (-not [IO.File]::Exists((Join-Path $case.Target.App 'private.key')) -and -not [IO.File]::Exists((Join-Path $case.Target.App 'piloto-remoto/windows/remoto-piloto.xml'))) 'Copiou segredo/configuracao ativa';
    Assert-Install ([IO.Directory]::GetDirectories($case.Target.Remote).Length -eq 1) 'Staging sobrou';
  }
  Test-Install 'falha parcial nao publica app incompleto e limpeza nao e recursiva' {
    $case = New-InstallCase; $script:FailWrite = 3;
    Assert-InstallThrows { Invoke-PdvRemoteAdministrativeInstall; } 'SimulatedWriteFailure';
    Assert-Install (-not [IO.Directory]::Exists($case.Target.App) -and -not [IO.Directory]::Exists($case.Target.Remote)) 'Falha deixou app parcial publicado';
  }
  Test-Install 'limpeza parcial preserva arquivo desconhecido em vez de excluir recursivamente' {
    $case = New-InstallCase; $stage = Join-Path $case.Target.Common 'app.preparando-fixture'; [void][IO.Directory]::CreateDirectory((Join-Path $stage 'piloto-remoto/windows'));
    $unknown = Join-Path $stage 'perfil-nao-criado-nesta-tentativa.xml'; [IO.File]::WriteAllText($unknown, 'DADO FALSO A PRESERVAR');
    $files = Read-PdvRemoteInstallPackage $case.Package;
    Assert-InstallThrows { Remove-PdvRemoteInstallStaging $stage $files; } '';
    Assert-Install ([IO.File]::Exists($unknown) -and [IO.File]::ReadAllText($unknown) -ceq 'DADO FALSO A PRESERVAR') 'Limpeza excluiu dado desconhecido';
  }
  if ($script:Failures.Count) { throw ($script:Failures -join "`n"); }
  Write-Output ('PASS: ' + $script:Cases + ' casos; ' + $script:Checks + ' verificacoes offline. Windows/ACL nativo nao foram executados.');
} finally {
  if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true); }
}
