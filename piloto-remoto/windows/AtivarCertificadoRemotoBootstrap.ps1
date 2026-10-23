#requires -Version 2.0
# Bootstrap do pacote conferido: valida a instalacao ANTES de executar seu codigo.
# Nao importa modulo nem executa fonte de ProgramData ate concluir a verificacao.
$ErrorActionPreference='Stop';
function Assert-PdvEnrollmentBootstrapAdministrator {
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'RemoteEnrollmentBootstrapWindowsRequired';}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$principal=New-Object Security.Principal.WindowsPrincipal($identity);if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'RemoteEnrollmentBootstrapAdministratorRequired';}}finally{$identity.Dispose();}
}
function Get-PdvEnrollmentBootstrapCodeFiles {
  return @('piloto-remoto/windows/AtivarCertificadoRemoto.ps1','PdvMonitor.Remoto.Inscricao.psm1','piloto-remoto/windows/RemoteEnrollmentCrypto.cs','piloto-remoto/windows/RemoteEnrollmentStorage.cs','piloto-remoto/windows/inscricao-confianca.xml','piloto-remoto/windows/identity-server-ca.crt','piloto-remoto/windows/identity-device-ca.crt');
}
function Assert-PdvEnrollmentBootstrapNode {
  param([string]$Path,[bool]$ExecutableFile=$false,[bool]$ImmediateParent=$false);
  if(([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RemoteEnrollmentBootstrapUnsafePath';}
  $trusted=@('S-1-5-18','S-1-5-32-544');
  if(-not $ExecutableFile){$installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$trusted+=$installer.Translate([Security.Principal.SecurityIdentifier]).Value;}
  $rights=[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
  if($ExecutableFile -or $ImmediateParent){$rights=$rights -bor [Security.AccessControl.FileSystemRights]::Write;}
  $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop;if($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'RemoteEnrollmentBootstrapUnsafeAcl';}
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;};if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $rights) -ne 0 -and $trusted -cnotcontains $rule.IdentityReference.Value){throw 'RemoteEnrollmentBootstrapUnsafeAcl';}}
}
function Assert-PdvEnrollmentBootstrapPath {
  param([string]$Path);
  $full=[IO.Path]::GetFullPath($Path);if(-not [IO.Path]::IsPathRooted($full) -or $full.StartsWith('\\') -or -not [IO.File]::Exists($full)){throw 'RemoteEnrollmentBootstrapMissingInstallation';}
  # Valida de fora para dentro, antes de abrir qualquer arquivo executavel instalado.
  $nodes=New-Object Collections.Generic.List[string];$probe=[IO.Path]::GetDirectoryName($full);while($probe){$nodes.Insert(0,$probe);$parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;}
  foreach($node in $nodes){Assert-PdvEnrollmentBootstrapNode $node $false ($node -ceq [IO.Path]::GetDirectoryName($full));};Assert-PdvEnrollmentBootstrapNode $full $true $false;return $full;
}
function Initialize-PdvEnrollmentBootstrapNative {
  if($null -ne ('Conecta.PdvRemoteEnrollmentBootstrap.FileGuardV1' -as [type])){return;}
  # Somente fonte literal deste bootstrap do pacote; nunca le codigo instalado aqui.
  $source=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Conecta.PdvRemoteEnrollmentBootstrap {
  public static class FileGuardV1 {
    [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written; public uint VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
    public static void AssertSingleLink(SafeFileHandle handle) { Info info; if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error()); if(info.Links!=1 || (info.Attributes&0x400)!=0) throw new InvalidOperationException("RemoteEnrollmentBootstrapUnsafeFile"); }
  }
}
'@;
  Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop;
}
function Open-PdvEnrollmentBootstrapLockedFile {
  param([string]$Path);
  $stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);
  try{[Conecta.PdvRemoteEnrollmentBootstrap.FileGuardV1]::AssertSingleLink($stream.SafeFileHandle);if($stream.Length -lt 1 -or $stream.Length -gt 1048576){throw 'RemoteEnrollmentBootstrapInvalidFile';};return $stream;}catch{$stream.Close();throw;}
}
function Invoke-PdvEnrollmentBootstrapInstalledCli {param([string]$Path);& $Path;}
function Invoke-PdvEnrollmentBootstrap {
  $locks=New-Object Collections.Generic.List[IDisposable];
  try{
    Assert-PdvEnrollmentBootstrapAdministrator;Initialize-PdvEnrollmentBootstrapNative;
    $common=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData);$app=Join-Path $common 'Feirao\PdvMonitorRemoto\app';$paths=@();
    foreach($relative in (Get-PdvEnrollmentBootstrapCodeFiles)){$paths+=,(Assert-PdvEnrollmentBootstrapPath (Join-Path $app $relative));}
    # Trava TODOS os fontes e a confianca antes da primeira execucao/importacao.
    foreach($path in $paths){$stream=Open-PdvEnrollmentBootstrapLockedFile $path;$locks.Add($stream);}
    foreach($path in $paths){[void](Assert-PdvEnrollmentBootstrapPath $path);}
    Invoke-PdvEnrollmentBootstrapInstalledCli (Join-Path $app 'piloto-remoto/windows/AtivarCertificadoRemoto.ps1');
  }finally{foreach($stream in $locks){$stream.Dispose();}}
}
if($MyInvocation.InvocationName -ne '.'){
  try{Invoke-PdvEnrollmentBootstrap;}catch{Write-Host 'Ativacao bloqueada: execute primeiro a preparacao administrativa do pacote conferido. A instalacao precisa pertencer a Administradores/SYSTEM e nao pode ser modificavel por usuarios comuns.';exit 1;}
}
