#requires -Version 2.0
# Fixed protected entry point for Task Scheduler. No arguments, credentials or arbitrary commands.
$ErrorActionPreference='Stop';$locks=New-Object Collections.Generic.List[IDisposable];
try{
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WindowsRequired';}
  $common=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData);$remote=Join-Path $common 'Feirao\PdvMonitorRemoto';$app=Join-Path $remote 'app';
  $entry=Join-Path $app 'piloto-remoto\windows\ManterIdentidadeRemota.ps1';if([IO.Path]::GetFullPath($MyInvocation.MyCommand.Path) -cne [IO.Path]::GetFullPath($entry)){throw 'AdministrativeInstalledCopyRequired';}
  # Validate ancestors before importing any installed source. Readers cannot replace this code.
  $trusted=@('S-1-5-18','S-1-5-32-544');$installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$ancestorTrusted=$trusted+$installer.Translate([Security.Principal.SecurityIdentifier]).Value;
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$principal=New-Object Security.Principal.WindowsPrincipal($identity);if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $identity.User.Value -cne 'S-1-5-18'){throw 'AdministratorRequired';}}finally{$identity.Dispose();}
  $files=@('piloto-remoto/windows/ManterIdentidadeRemota.ps1','PdvMonitor.Remoto.Identidade.psm1','PdvMonitor.Remoto.Inscricao.psm1','piloto-remoto/windows/RemoteEnrollmentCrypto.cs','piloto-remoto/windows/RemoteEnrollmentStorage.cs','piloto-remoto/windows/inscricao-confianca.xml','piloto-remoto/windows/identity-device-ca.crt','piloto-remoto/windows/identity-server-ca.crt');
  foreach($relative in $files){
    $path=Join-Path $app $relative;$probe=$path;$depth=0;
    while($probe){
      if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'UnsafeInstallation';}
      $acl=Get-Acl -LiteralPath $probe -ErrorAction Stop;$allowed=$trusted;$rights=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
      if($depth -gt 1){$allowed=$ancestorTrusted;$rights=$rights -band (-bnot [int][Security.AccessControl.FileSystemRights]::Write);}
      if($allowed -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'UnsafeInstallation';}
      foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;};if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $rights) -ne 0 -and $allowed -cnotcontains $rule.IdentityReference.Value){throw 'UnsafeInstallation';}}
      $parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;$depth++;
    }
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$locks.Add($stream);
  }
  Import-Module (Join-Path $app 'PdvMonitor.Remoto.Identidade.psm1') -Force;
  $outcome=Invoke-PdvIdentityMaintenance $remote;
  Write-Output $outcome;
}catch{Write-Output 'RemoteIdentityMaintenanceIncomplete';exit 1;}
finally{foreach($stream in $locks){$stream.Dispose();}}
