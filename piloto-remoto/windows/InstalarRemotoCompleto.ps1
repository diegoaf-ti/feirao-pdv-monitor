#requires -Version 2.0
[CmdletBinding()]
param([string]$MonitorUserSid='');
$ErrorActionPreference='Stop';
$script:PdvFullRemoteDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path;
function Assert-PdvIdentitySystemPowerShell {
  param([string]$Path);
  $trusted=@('S-1-5-18','S-1-5-32-544');$installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$trusted+=$installer.Translate([Security.Principal.SecurityIdentifier]).Value;
  $probe=$Path;$depth=0;
  while($probe){
    if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RemoteIdentitySystemPowerShellInvalid';}
    $acl=Get-Acl -LiteralPath $probe -ErrorAction Stop;if($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'RemoteIdentitySystemPowerShellInvalid';}
    $rights=[Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
    if($depth -le 1){$rights=$rights -bor [Security.AccessControl.FileSystemRights]::Write;}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;};if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $rights) -ne 0 -and $trusted -cnotcontains $rule.IdentityReference.Value){throw 'RemoteIdentitySystemPowerShellInvalid';}}
    $parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;$depth++;
  }
}

function Get-PdvIdentitySystemPowerShellPath {return (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe');}
function Release-PdvIdentityComObject {param($Object);if($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object);}}
function Register-PdvIdentityMaintenanceTask {
  param([string]$AppDirectory);
  $path=Join-Path $AppDirectory 'piloto-remoto/windows/ManterIdentidadeRemota.ps1';$enrollmentModule=Import-Module (Join-Path $AppDirectory 'PdvMonitor.Remoto.Inscricao.psm1') -PassThru;[void](& $enrollmentModule {param($P);Assert-PdvEnrollmentAdministrativePath $P;} $path);
  $powerShell=Get-PdvIdentitySystemPowerShellPath;
  Assert-PdvIdentitySystemPowerShell $powerShell;$signature=Get-AuthenticodeSignature -LiteralPath $powerShell -ErrorAction Stop;if($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){throw 'RemoteIdentitySystemPowerShellInvalid';}
  $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'"';
  $service=$null;$folder=$null;$definition=$null;$task=$null;
  try{
    $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$folder=$service.GetFolder('\');
    # Task has a literal executable/script and no data/user-controlled executable input.
    $old=$null;try{$old=$folder.GetTask('Feirao-PdvMonitor-RenovarCertificado');}catch{}
    if($null -ne $old){try{if($old.Definition.Actions.Count -ne 1 -or $old.Definition.Actions.Item(1).Path -ine $powerShell -or $old.Definition.Actions.Item(1).Arguments -cne $arguments -or (@('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM') -inotcontains $old.Definition.Principal.UserId)){throw 'RemoteIdentityTaskNameOccupied';}}finally{Release-PdvIdentityComObject $old;}}
    $definition=$service.NewTask(0);$definition.RegistrationInfo.Description='Conecta: renovar somente a identidade remota deste computador; nao inicia atendimento.';$definition.Principal.UserId='SYSTEM';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1;
    $definition.Settings.Enabled=$true;$definition.Settings.StartWhenAvailable=$true;$definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false;$definition.Settings.MultipleInstances=2;$definition.Settings.ExecutionTimeLimit='PT5M';
    $trigger=$definition.Triggers.Create(2);$trigger.DaysInterval=1;$trigger.StartBoundary=[DateTime]::Now.AddMinutes(15).ToString('yyyy-MM-ddTHH:mm:ss');$trigger.RandomDelay='PT1H';$trigger.Repetition.Interval='PT1H';$trigger.Repetition.Duration='P1D';
    $action=$definition.Actions.Create(0);$action.Path=$powerShell;$action.Arguments=$arguments;$action.WorkingDirectory=$AppDirectory;
    $task=$folder.RegisterTaskDefinition('Feirao-PdvMonitor-RenovarCertificado',$definition,6,'SYSTEM',$null,5,'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)');
  }finally{foreach($item in @($task,$definition,$folder,$service)){Release-PdvIdentityComObject $item;}}
}
function Complete-PdvManagedRemoteSetup {
  param([string]$AppDirectory);
  Register-PdvIdentityMaintenanceTask $AppDirectory;
  $module=Import-Module (Join-Path $AppDirectory 'PdvMonitor.Remoto.Identidade.psm1') -PassThru;
  & $module {
    param($App);
    $path=Join-Path $App 'piloto-remoto/windows/remoto-piloto.xml';[void](Assert-PdvIdentityPath $path);
    $text=[Text.Encoding]::UTF8.GetString((Read-PdvIdentityBytes $path));if($text -match '<!DOCTYPE|<!ENTITY'){throw 'RemoteInstallationProfileInvalid';}
    $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.LoadXml($text.TrimStart([char]0xfeff));
    if($xml.DocumentElement.Name -cne 'PdvRemoteWindowsPilot' -or $xml.DocumentElement.SelectNodes('Enabled').Count -ne 1){throw 'RemoteInstallationProfileInvalid';}
    $xml.DocumentElement.SelectSingleNode('Enabled').InnerText='true';Write-PdvIdentityAtomic $path ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml));
  } $AppDirectory;
}

function Invoke-PdvFullRemoteInstall {
  param([string]$Sid);
  if(-not $Sid){$Sid=Read-Host 'SID da conta Windows que executa o monitor';}
  if($Sid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'RemoteInstallationMonitorAccountRequired';}
  . (Join-Path $script:PdvFullRemoteDirectory 'InstalarComponenteRemoto.ps1');
  Assert-PdvRemoteInstallAdministrator;
  $source=[IO.Path]::GetFullPath((Join-Path $script:PdvFullRemoteDirectory '..\..'));
  . (Join-Path $source 'tools/ValidarBundleRemoto.ps1');
  # Validate complete vendor bundle before installing code or issuing a certificate.
  $bundle=Join-Path $script:PdvFullRemoteDirectory 'bundle';[void](Read-PdvRemoteInstallPackage $source);
  if($null -eq ('Conecta.PdvRemotePilot.DesktopEvidence' -as [type])){Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $source 'piloto-remoto/windows/RemoteWindowsNative.cs'))) -Language CSharp -ErrorAction Stop;}
  $native=[Conecta.PdvRemotePilot.DesktopEvidence]::Read();if(-not $native.Supported -or $native.ProcessArchitecture -cne $native.Architecture){throw 'RemoteInstallationPlatformUnsupported';}
  $approved=Assert-PdvRemoteBundle -BundleDirectory $bundle -TrustedManifestPath (Join-Path $source 'tools/remoto-bundle-lock.xml') -ProfileId $native.CompatibilityProfile;
  $target=Get-PdvRemoteInstallTarget;
  if([IO.Directory]::Exists($target.App)){
    # Resume only this exact code version; never overwrite an older/unknown administrative extension.
    $files=Read-PdvRemoteInstallPackage $source;Assert-PdvRemoteInstallCopied $target.App $files;
  }else{[void](Invoke-PdvRemoteAdministrativeInstall);}
  $installedBundle=Join-Path $target.App 'piloto-remoto/windows/bundle';if(-not [IO.Directory]::Exists($installedBundle)){New-PdvRemoteInstallDirectory $installedBundle;}else{Assert-PdvRemoteInstallAcl $installedBundle;}
  foreach($directory in @('bin','bin/ultravnc','bin/stunnel','licenses','sources')){$child=Join-Path $installedBundle $directory;if(-not [IO.Directory]::Exists($child)){New-PdvRemoteInstallDirectory $child;}else{Assert-PdvRemoteInstallAcl $child;}}
  foreach($entry in $approved.Files){$sourceFile=Join-Path $bundle $entry.RelativePath;$destination=Join-Path $installedBundle $entry.RelativePath;if([IO.File]::Exists($destination)){Assert-PdvRemoteInstallAcl $destination;if((Get-PdvRemoteInstallHash (Read-PdvRemoteInstallFile $destination 33554432)) -cne $entry.Sha256){throw 'RemoteInstallationExistingBundleChanged';}}else{Write-PdvRemoteInstallFile $destination ([IO.File]::ReadAllBytes($sourceFile));}}
  $manifest=Join-Path $installedBundle 'remoto-bundle.xml';if(-not [IO.File]::Exists($manifest)){Write-PdvRemoteInstallFile $manifest ([IO.File]::ReadAllBytes((Join-Path $bundle 'remoto-bundle.xml')));}
  $profile=Join-Path $target.App 'piloto-remoto/windows/remoto-piloto.xml';
  if([IO.File]::Exists($profile)){
    $identityModule=Import-Module (Join-Path $target.App 'PdvMonitor.Remoto.Identidade.psm1') -PassThru;
    $config=& $identityModule {param($P);Read-PdvIdentityFile $P 'PdvRemoteIdentityMaintenance' @('AgentId','MonitorUserSid','IdentityDirectory');} (Join-Path $target.Remote 'identity-maintenance.xml');if($config.MonitorUserSid -cne $Sid){throw 'RemoteInstallationIdentityMismatch';}
    [void](Assert-PdvRemoteBundle -BundleDirectory $installedBundle -TrustedManifestPath (Join-Path $target.App 'tools/remoto-bundle-lock.xml') -ProfileId $native.CompatibilityProfile -AllowRuntimeConfiguration);
    Complete-PdvManagedRemoteSetup $target.App;return;
  }
  if(-not [IO.File]::Exists((Join-Path $target.Remote 'provisioning.xml'))){[void](Assert-PdvRemoteBundle -BundleDirectory $installedBundle -TrustedManifestPath (Join-Path $target.App 'tools/remoto-bundle-lock.xml') -ProfileId $native.CompatibilityProfile);}
  $identities=Join-Path $target.Remote 'identities';
  if([IO.Directory]::Exists($identities)){
    $existing=@([IO.Directory]::GetDirectories($identities)|Where-Object{[IO.Path]::GetFileName($_) -cmatch '^[a-f0-9-]{36}$' -and [IO.File]::Exists((Join-Path $_ 'certificate.xml'))});
    if($existing.Count -eq 1){
      $identityModule=Import-Module (Join-Path $target.App 'PdvMonitor.Remoto.Identidade.psm1') -PassThru;
      & $identityModule {param($Directory,$Sid);$trust=Read-PdvMonitorRemoteEnrollmentTrust (Join-Path $script:PdvIdentityDirectory 'piloto-remoto/windows/inscricao-confianca.xml');$identity=Read-PdvIdentityCertificate $Directory $Sid $trust;[void](Complete-PdvRemoteProvisioning $identity $Sid $trust);} $existing[0] $Sid;
      Complete-PdvManagedRemoteSetup $target.App;return;
    };if($existing.Count -gt 1){throw 'RemoteInstallationMultipleIdentities';}
  }
  $global:LASTEXITCODE=0;
  & (Join-Path $target.App 'piloto-remoto/windows/AtivarCertificadoRemoto.ps1') -MonitorUserSid $Sid -ProvisionarRemoto;
  if($LASTEXITCODE -ne 0){throw 'RemoteInstallationActivationIncomplete';}
  Import-Module (Join-Path $target.App 'PdvMonitor.Remoto.Inscricao.psm1') -Force;
  Complete-PdvManagedRemoteSetup $target.App;
  Write-Host 'Suporte remoto preparado. A manutencao deve conferir o computador no Conecta; cada atendimento exige autorizacao e consentimento local.';
}
if($MyInvocation.InvocationName -ne '.'){
  try{Invoke-PdvFullRemoteInstall $MonitorUserSid;}catch{Write-Host 'Instalacao remota incompleta. Confira a conta do monitor, os componentes aprovados, a elevacao e o codigo do Conecta. Dados e identidades existentes foram preservados.';exit 1;}
}
