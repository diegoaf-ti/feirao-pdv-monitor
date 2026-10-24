#requires -Version 2.0
# Primeira instalacao administrativa, opcional e somente de codigo/modelos inativos.
# Execute explicitamente como administrador. Nao baixa ou inicia programas e nao
# copia apenas codigo/modelos e CAs publicas; nao instala identidade privada,
# perfil ativo, servico, regra de firewall ou Startup.
# O SHA256 detecta corrupcao; obtenha o pacote por uma origem previamente conferida.
$script:PdvRemoteInstallScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path;

function Get-PdvRemoteInstallFiles {
  return @('PdvMonitor.Remoto.Windows.psm1', 'PdvMonitor.Remoto.Identidade.psm1', 'piloto-remoto/windows/ManterIdentidadeRemota.ps1', 'piloto-remoto/windows/InstalarRemotoCompleto.ps1', 'piloto-remoto/windows/InstalarRemotoCompleto.cmd', 'tools/ValidarBundleRemoto.ps1', 'tools/remoto-bundle-lock.xml', 'piloto-remoto/windows/RemoteWindowsNative.cs', 'piloto-remoto/windows/remoto-piloto.xml.example', 'piloto-remoto/windows/COMPATIBILIDADE-WINDOWS7.md', 'PdvMonitor.Remoto.Inscricao.psm1', 'piloto-remoto/windows/RemoteEnrollmentCrypto.cs', 'piloto-remoto/windows/RemoteEnrollmentStorage.cs', 'piloto-remoto/windows/AtivarCertificadoRemoto.ps1', 'piloto-remoto/windows/AtivarCertificadoRemotoBootstrap.ps1', 'piloto-remoto/windows/AtivarCertificadoRemoto.cmd', 'piloto-remoto/windows/inscricao-confianca.xml', 'piloto-remoto/windows/identity-server-ca.crt', 'piloto-remoto/windows/identity-device-ca.crt');
}

function Initialize-PdvRemoteInstallNative {
  if ($null -ne ('Conecta.PdvRemoteInstall.NativeV1' -as [type])) { return; }
  $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Conecta.PdvRemoteInstall {
  public static class NativeV1 {
    [StructLayout(LayoutKind.Sequential)] private struct Info {
      public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
      public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {
      public int Length; public IntPtr Descriptor; public int Inherit;
    }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CreateDirectoryW")] private static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static void AssertSingleLink(SafeFileHandle handle) {
      Info info; if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
      if (info.Links != 1 || (info.Attributes & 0x400) != 0) throw new InvalidOperationException("RemoteInstallLinkedFile");
    }
    public static void CreateProtectedDirectory(string path) {
      IntPtr descriptor; uint size;
      if (!ConvertStringSecurityDescriptorToSecurityDescriptor("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)", 1, out descriptor, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        SecurityAttributes attributes = new SecurityAttributes(); attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes)); attributes.Descriptor = descriptor;
        if (!CreateDirectory(path, ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
      } finally { LocalFree(descriptor); }
    }
  }
}
'@;
  Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop;
}

function Assert-PdvRemoteInstallAdministrator {
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'A preparacao administrativa deve ser executada no Windows.'; }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent();
  try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity);
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra PrepararRemoto.cmd com Executar como administrador. Nenhuma elevacao automatica foi solicitada.'; }
  } finally { $identity.Dispose(); }
}

function Assert-PdvRemoteInstallPath {
  param([string]$Path, [bool]$MustExist = $true);
  $full = [IO.Path]::GetFullPath($Path);
  if ($MustExist -and -not [IO.File]::Exists($full) -and -not [IO.Directory]::Exists($full)) { throw 'RemoteInstallPathMissing'; }
  $probe = $full;
  while ($probe) {
    if ([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)) {
      if (([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RemoteInstallReparsePath'; }
    }
    $parent = [IO.Path]::GetDirectoryName($probe); if ($parent -ceq $probe) { break; }; $probe = $parent;
  }
  return $full;
}

function Assert-PdvRemoteInstallSingleLink {
  param($Stream);
  [Conecta.PdvRemoteInstall.NativeV1]::AssertSingleLink($Stream.SafeFileHandle);
}

function Get-PdvRemoteInstallHash {
  param([byte[]]$Bytes);
  $algorithm = New-Object Security.Cryptography.SHA256Managed;
  try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant(); }
  finally { $algorithm.Dispose(); }
}

function Read-PdvRemoteInstallFile {
  param([string]$Path, [int]$MaximumLength = 1048576);
  [void](Assert-PdvRemoteInstallPath $Path);
  $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read);
  try {
    Assert-PdvRemoteInstallSingleLink $stream;
    if ($stream.Length -lt 1 -or $stream.Length -gt $MaximumLength) { throw 'RemoteInstallFileSize'; }
    $bytes = New-Object byte[] ([int]$stream.Length); $offset = 0;
    while ($offset -lt $bytes.Length) { $read = $stream.Read($bytes, $offset, $bytes.Length - $offset); if ($read -le 0) { throw 'RemoteInstallReadFailed'; }; $offset += $read; }
    Assert-PdvRemoteInstallSingleLink $stream;
    return ,$bytes;
  } finally { $stream.Close(); }
}

function Read-PdvRemoteInstallManifest {
  param([byte[]]$Bytes);
  if ($Bytes.Length -gt 8192) { throw 'RemoteInstallManifestInvalid'; }
  try {
    $encoding = New-Object Text.UTF8Encoding($false, $true); $text = $encoding.GetString($Bytes).TrimStart([char]0xfeff);
    if ($text -match '<!DOCTYPE|<!ENTITY') { throw 'Invalid'; }
    $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null; $xml.LoadXml($text);
    foreach ($child in $xml.ChildNodes) { if (@([Xml.XmlNodeType]::XmlDeclaration, [Xml.XmlNodeType]::Element) -notcontains $child.NodeType) { throw 'Invalid'; } }
    $root = $xml.DocumentElement;
    if ($root.Name -cne 'PdvRemoteInstallManifest' -or $root.NamespaceURI -or $root.Attributes.Count -ne 1 -or $root.GetAttribute('schemaVersion') -cne '1') { throw 'Invalid'; }
    $files = @{};
    foreach ($node in $root.ChildNodes) {
      if ($node.NodeType -eq [Xml.XmlNodeType]::Whitespace) { continue; }
      if ($node.Name -cne 'File' -or $node.NamespaceURI -or $node.Attributes.Count -ne 3 -or $node.HasChildNodes) { throw 'Invalid'; }
      foreach ($attribute in $node.Attributes) { if (@('path', 'sha256', 'sizeBytes') -cnotcontains $attribute.Name -or $attribute.NamespaceURI) { throw 'Invalid'; } }
      $path = $node.GetAttribute('path'); $hash = $node.GetAttribute('sha256'); $length = $node.GetAttribute('sizeBytes');
      if ((Get-PdvRemoteInstallFiles) -cnotcontains $path -or $files.ContainsKey($path) -or $hash -cnotmatch '^[a-f0-9]{64}$' -or $length -cnotmatch '^[1-9][0-9]{0,6}$' -or [int]$length -gt 1048576) { throw 'Invalid'; }
      $files[$path] = @{ Sha256 = $hash; Length = [int]$length };
    }
    if ($files.Count -ne @(Get-PdvRemoteInstallFiles).Count) { throw 'Invalid'; }
    return $files;
  } catch { throw 'RemoteInstallManifestInvalid'; }
}

function Read-PdvRemoteInstallPackage {
  param([string]$PackageRoot);
  [void](Assert-PdvRemoteInstallPath $PackageRoot);
  $manifestBytes = Read-PdvRemoteInstallFile (Join-Path $PackageRoot 'remoto-instalacao-sha256.xml') 8192;
  $manifest = Read-PdvRemoteInstallManifest $manifestBytes; $files = @();
  foreach ($relativePath in (Get-PdvRemoteInstallFiles)) {
    $bytes = Read-PdvRemoteInstallFile (Join-Path $PackageRoot $relativePath);
    if ($bytes.Length -ne $manifest[$relativePath].Length -or (Get-PdvRemoteInstallHash $bytes) -cne $manifest[$relativePath].Sha256) { throw ('Pacote remoto incompleto ou alterado: ' + $relativePath); }
    $files += ,@{ RelativePath = $relativePath; Bytes = $bytes; Sha256 = $manifest[$relativePath].Sha256 };
  }
  # Os buffers da lista fechada validados sao a unica origem da copia; o fonte nao e executado.
  return ,$files;
}

function Get-PdvRemoteInstallTarget {
  $common = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData);
  if (-not $common -or $common -cnotmatch '^[A-Za-z]:\\') { throw 'RemoteInstallCommonDataUnavailable'; }
  $feirao = Join-Path $common 'Feirao'; $remote = Join-Path $feirao 'PdvMonitorRemoto';
  return @{ Common = $common; Feirao = $feirao; Remote = $remote; App = (Join-Path $remote 'app') };
}

function Assert-PdvRemoteInstallAcl {
  param([string]$Path, [bool]$Ancestor = $false);
  $trusted = Get-PdvRemoteInstallTrustedSids $Ancestor;
  $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop;
  if ($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw 'RemoteInstallUnsafeAcl'; }
  $write = [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
  if (-not $Ancestor) { $write = $write -bor [Security.AccessControl.FileSystemRights]::Write; }
  foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue; }
    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $write) -ne 0 -and $trusted -cnotcontains $rule.IdentityReference.Value) { throw 'RemoteInstallUnsafeAcl'; }
  }
}

function Get-PdvRemoteInstallTrustedSids {
  param([bool]$Ancestor = $false);
  $trusted = @('S-1-5-18', 'S-1-5-32-544');
  if ($Ancestor) { $account = New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller'); $trusted += $account.Translate([Security.Principal.SecurityIdentifier]).Value; }
  return $trusted;
}

function Assert-PdvRemoteInstallTarget {
  param($Target);
  # Nunca corrige ACLs ou sobrescreve uma instalacao existente, mesmo incompleta.
  [void](Assert-PdvRemoteInstallPath $Target.Remote $false);
  if ([IO.Directory]::Exists($Target.Remote) -or [IO.File]::Exists($Target.Remote)) { throw 'Ja existe preparacao administrativa remota. Feche o monitor e solicite uma atualizacao administrativa revisada; este instalador atende somente a primeira instalacao e nao substitui arquivos ou perfis existentes.'; }
  if ([IO.File]::Exists($Target.Feirao)) { throw 'RemoteInstallTargetOccupied'; }
  if ([IO.Directory]::Exists($Target.Feirao)) { Assert-PdvRemoteInstallAcl $Target.Feirao; }
  $probe = $Target.Common;
  while ($probe) {
    [void](Assert-PdvRemoteInstallPath $probe); Assert-PdvRemoteInstallAcl $probe $true;
    $parent = [IO.Path]::GetDirectoryName($probe); if ($parent -ceq $probe) { break; }; $probe = $parent;
  }
}

function New-PdvRemoteInstallDirectory {
  param([string]$Path);
  [void](Assert-PdvRemoteInstallPath $Path $false);
  [Conecta.PdvRemoteInstall.NativeV1]::CreateProtectedDirectory($Path);
  Assert-PdvRemoteInstallAcl $Path;
}

function Write-PdvRemoteInstallFile {
  param([string]$Path, [byte[]]$Bytes);
  $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None);
  try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush(); } finally { $stream.Close(); }
  $acl = New-Object Security.AccessControl.FileSecurity;
  $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))); $acl.SetAccessRuleProtection($true, $false);
  foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow); $acl.AddAccessRule($rule); }
  $reader = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.AccessControlType]::Allow); $acl.AddAccessRule($reader);
  [IO.File]::SetAccessControl($Path, $acl); Assert-PdvRemoteInstallAcl $Path;
}

function Assert-PdvRemoteInstallCopied {
  param([string]$Root, $Files);
  [void](Assert-PdvRemoteInstallPath $Root); Assert-PdvRemoteInstallAcl $Root;
  foreach ($entry in $Files) {
    $path = Join-Path $Root $entry.RelativePath; Assert-PdvRemoteInstallAcl $path;
    $bytes = Read-PdvRemoteInstallFile $path;
    if ($bytes.Length -ne $entry.Bytes.Length -or (Get-PdvRemoteInstallHash $bytes) -cne $entry.Sha256) { throw 'RemoteInstallCopyMismatch'; }
  }
}

function Remove-PdvRemoteInstallStaging {
  param([string]$Root, $Files);
  # Somente caminhos criados nesta tentativa, sem exclusao recursiva ou de perfil ativo.
  if (-not $Root -or -not [IO.Directory]::Exists($Root)) { return; }
  [void](Assert-PdvRemoteInstallPath $Root); Assert-PdvRemoteInstallAcl $Root;
  foreach ($entry in $Files) { $path = Join-Path $Root $entry.RelativePath; if ([IO.File]::Exists($path)) { [void](Assert-PdvRemoteInstallPath $path); [IO.File]::Delete($path); } }
  foreach ($relative in @('piloto-remoto/windows', 'piloto-remoto', 'tools', '')) {
    $path = $Root; if ($relative) { $path = Join-Path $Root $relative; }
    if ([IO.Directory]::Exists($path)) { [void](Assert-PdvRemoteInstallPath $path); [IO.Directory]::Delete($path, $false); }
  }
}

function Invoke-PdvRemoteAdministrativeInstall {
  $ErrorActionPreference = 'Stop'; Assert-PdvRemoteInstallAdministrator;
  Initialize-PdvRemoteInstallNative;
  $packageRoot = [IO.Path]::GetFullPath((Join-Path $script:PdvRemoteInstallScriptDirectory '../..'));
  # Completa todas as leituras, checks de links, tamanho e hashes antes de escrever.
  $files = Read-PdvRemoteInstallPackage $packageRoot;
  $target = Get-PdvRemoteInstallTarget; Assert-PdvRemoteInstallTarget $target;
  $staging = ''; $remoteCreated = $false; $published = $false;
  try {
    if (-not [IO.Directory]::Exists($target.Feirao)) { New-PdvRemoteInstallDirectory $target.Feirao; }
    Assert-PdvRemoteInstallAcl $target.Feirao;
    New-PdvRemoteInstallDirectory $target.Remote; $remoteCreated = $true;
    $staging = Join-Path $target.Remote ('app.preparando-' + [Guid]::NewGuid().ToString('N'));
    New-PdvRemoteInstallDirectory $staging;
    New-PdvRemoteInstallDirectory (Join-Path $staging 'tools');
    New-PdvRemoteInstallDirectory (Join-Path $staging 'piloto-remoto');
    New-PdvRemoteInstallDirectory (Join-Path $staging 'piloto-remoto/windows');
    foreach ($entry in $files) {
      if ((Get-PdvRemoteInstallHash $entry.Bytes) -cne $entry.Sha256) { throw 'RemoteInstallSourceChanged'; }
      Write-PdvRemoteInstallFile (Join-Path $staging $entry.RelativePath) $entry.Bytes;
    }
    Assert-PdvRemoteInstallCopied $staging $files;
    [void](Assert-PdvRemoteInstallPath $target.App $false);
    if ([IO.Directory]::Exists($target.App) -or [IO.File]::Exists($target.App)) { throw 'RemoteInstallTargetOccupied'; }
    [IO.Directory]::Move($staging, $target.App); $published = $true;
    Assert-PdvRemoteInstallCopied $target.App $files;
    Write-Output ('Componente preparado em ' + $target.App + '. Acesso remoto permanece aguardando perfil, dependencias e certificados aprovados. Feche e reabra o monitor apos a preparacao. Nenhum acesso foi iniciado.');
    return $target.App;
  } catch {
    if (-not $published) {
      try { Remove-PdvRemoteInstallStaging $staging $files; } catch { }
      if ($remoteCreated) { try { [void](Assert-PdvRemoteInstallPath $target.Remote); [IO.Directory]::Delete($target.Remote, $false); } catch { } }
    }
    throw;
  }
}

# Dot-source permite os testes puros; carregar definicoes nao executa instalacao.
if ($MyInvocation.InvocationName -ne '.') { Invoke-PdvRemoteAdministrativeInstall; }
