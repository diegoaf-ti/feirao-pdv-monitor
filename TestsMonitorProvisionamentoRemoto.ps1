#requires -Version 5.1
# Offline: somente arquivos sinteticos e fronteiras Windows/PKI/HTTP simuladas.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;
$script:Checks=0;$script:Cases=0;$script:Failures=@();
function Assert-Test($Value,[string]$Message){$script:Checks++;if(-not $Value){throw $Message;}}
function Assert-Throws([scriptblock]$Body,[string]$Code){$script:Checks++;try{&$Body|Out-Null;}catch{if($_.Exception.Message.Contains($Code)){return;};throw;};throw ('Missing '+$Code);}
function Test-Case([string]$Name,[scriptblock]$Body){$script:Cases++;try{&$Body;Write-Output ('OK: '+$Name);}catch{$script:Failures+=($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FAIL: '+$Name+': '+$_.Exception.Message);}}
$base=[IO.Path]::GetTempPath();if([IO.Directory]::Exists('/private/tmp')){$base='/private/tmp';};$temporary=Join-Path $base ('pdv-provision-tests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
# Nomes equivalentes aos interops de producao, em processo isolado: nunca
# carregar os C# reais nem invocar CSP, WMI, COM, registro, rede ou P/Invoke.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
namespace Conecta.PdvRemoteEnrollment {
 public static class CryptoV1 {
  public static bool AclApplied=false; public static int SecretWrites=0;
  public static string Sha256(byte[] bytes) { using(SHA256 h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(bytes)).Replace("-","").ToLowerInvariant(); }
  public static void WriteVncPassword(string path,string password) {
   if(!AclApplied) throw new InvalidOperationException("SecretWrittenBeforeAcl");
   if(password!="S3cr3t!X") throw new InvalidOperationException("UnexpectedSyntheticSecret");
   SecretWrites++; File.AppendAllText(path,"passwd=SYNTHETIC-NOT-A-CREDENTIAL\n");
  }
 }
}
namespace Conecta.PdvRemotePilot {
 public sealed class TestEvidence { public bool Supported=true; public string Architecture="x64"; public string ProcessArchitecture="x64"; public string CompatibilityProfile="win10plus-x64"; }
 public static class DesktopEvidence { public static TestEvidence Evidence=new TestEvidence(); public static TestEvidence Read(){return Evidence;} }
}
'@;
$global:PdvProvisionEffects=@();$global:PdvProvisionCertificateIssues=0;
function Start-Process {throw 'UnexpectedRealProcess';}
function Get-WmiObject {throw 'UnexpectedRealWmi';}
try{
 Test-Case 'dot-source instalador completo nao instala nem acessa APIs Windows' {
  . (Join-Path $root 'piloto-remoto/windows/InstalarRemotoCompleto.ps1');
  Assert-Test ([IO.Directory]::GetFileSystemEntries($temporary).Count -eq 0) 'Dot-source escreveu arquivos';
  Assert-Test ($global:PdvProvisionEffects.Count -eq 0 -and $global:PdvProvisionCertificateIssues -eq 0) 'Dot-source executou efeitos';
  # Exportar as definicoes para o escopo do teste sem executar entrypoint.
  $script:ActualRegister=(Get-Command Register-PdvIdentityMaintenanceTask).ScriptBlock;
  $script:ActualFullInstall=(Get-Command Invoke-PdvFullRemoteInstall).ScriptBlock;
 }
 Import-Module (Join-Path $root 'PdvMonitor.Remoto.Identidade.psm1') -Force;
 $module=Get-Module PdvMonitor.Remoto.Identidade;
 & $module {
  function script:Initialize-PdvIdentity {}
  function script:Assert-PdvIdentityPath {param($Path,$Sid='');return $Path;}
  function script:Read-PdvIdentityFile {param($Path,$Root,$Fields,$Sid='');return (Read-PdvIdentityXml ([IO.File]::ReadAllBytes($Path)) $Root $Fields);}
  function script:Write-PdvIdentityAtomic {
   param($Path,$Bytes,$Sid='');$global:PdvProvisionEffects+=('write:'+([IO.Path]::GetFileName($Path)));
   if([IO.Path]::GetFileName($Path) -ceq 'ultravnc.ini'){[Conecta.PdvRemoteEnrollment.CryptoV1]::AclApplied=$false;}
   if($script:FailWrite -and [IO.Path]::GetFileName($Path) -ceq $script:FailWrite){throw 'SyntheticWriteInterrupted';}
   [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllBytes($Path,$Bytes);
  }
  function script:Read-PdvIdentityCertificate {param($Directory,$Sid,$Trust);return $script:Identity.Clone();}
  function script:Invoke-PdvIdentityProof {
   param($Trust,$Identity,$Purpose,$RequestId);$global:PdvProvisionEffects+=('http:'+ $Purpose);
   if($Purpose -cne 'profile'){throw 'UnexpectedHttpOperation';}
   $values=@{AgentId=$Identity.AgentId;RepeaterId=$Identity.RepeaterId;CertificateSha256=$Identity.CertificateSha256;VncPassword='S3cr3t!X';GatewayHost=$Trust.GatewayHost;GatewayPort=$Trust.GatewayPort;ExpiresAt=$Identity.ExpiresAt};if($script:WrongProfile){$values.AgentId='33333333-3333-4333-8333-333333333333';}
   return ,(ConvertTo-PdvIdentityXml 'PdvRemoteIdentityProfile' $values);
  }
  function script:Assert-PdvIdentityNoRemoteProcesses {if($script:Busy){throw 'SyntheticSessionBusy';}}
  function script:Set-Acl {param($LiteralPath,$AclObject,$ErrorAction);$global:PdvProvisionEffects+='acl';$script:LastSddl=$AclObject.Sddl;if($script:FailAcl){throw 'SyntheticAclDenied';};[Conecta.PdvRemoteEnrollment.CryptoV1]::AclApplied=$true;}
  function script:New-Object {
   param([string]$TypeName,[object[]]$ArgumentList,[hashtable]$Property);
   if($TypeName -ceq 'Security.AccessControl.FileSecurity'){$fake=[pscustomobject]@{Sddl=''};$fake|Add-Member ScriptMethod SetSecurityDescriptorSddlForm {param($Text);$this.Sddl=$Text;};return $fake;}
   return (Microsoft.PowerShell.Utility\New-Object @PSBoundParameters);
  }
 };
 function New-ProvisionCase {
  $path=Join-Path $temporary ([Guid]::NewGuid().ToString('N'));$app=Join-Path $path 'app';$bundle=Join-Path $app 'piloto-remoto/windows/bundle';[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'bin/ultravnc'));[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'bin/stunnel'));[void][IO.Directory]::CreateDirectory((Join-Path $app 'tools'));
  $validator=@'
function Assert-PdvRemoteBundle {
 param($BundleDirectory,$TrustedManifestPath,$ProfileId,[switch]$AllowRuntimeConfiguration);
 $global:PdvProvisionEffects+=('bundle:'+ $ProfileId+':'+[bool]$AllowRuntimeConfiguration);
 if(@('win7-sp1-x64','win10plus-x64') -cnotcontains $ProfileId){throw 'RemoteBundleUnsupportedProfile';}
 if($global:PdvProvisionRejectBundle){throw 'SyntheticBundleRejected';}
 return @{Files=@(@{RelativePath='bin/stunnel/stunnel.exe';Path=(Join-Path $BundleDirectory 'bin/stunnel/stunnel.exe');Sha256=('a'*64);PublisherThumbprint=('A'*40)},@{RelativePath='bin/ultravnc/winvnc.exe';Path=(Join-Path $BundleDirectory 'bin/ultravnc/winvnc.exe');Sha256=('b'*64);PublisherThumbprint=('B'*40)})};
}
'@;
  [IO.File]::WriteAllText((Join-Path $app 'tools/ValidarBundleRemoto.ps1'),$validator);
  [IO.File]::WriteAllText((Join-Path $app 'PdvMonitor.Remoto.Windows.psm1'),"function Get-PdvRemoteWindowsNativeEvidence {return [Conecta.PdvRemotePilot.DesktopEvidence]::Read();};Export-ModuleMember -Function Get-PdvRemoteWindowsNativeEvidence;");
  $identity=@{AgentId='11111111-1111-4111-8111-111111111111';CertificateSha256=('c'*64);CertificateFile=(Join-Path $path 'identities/first/client-certificate.pem');PrivateKeyFile=(Join-Path $path 'identities/first/client-private.key');ServerCaFile=(Join-Path $path 'identities/first/identity-server-ca.crt');ExpiresAt='2027-01-01T00:00:00.000Z';RepeaterId='4901'};
  $global:PdvProvisionEffects=@();$global:PdvProvisionRejectBundle=$false;[Conecta.PdvRemoteEnrollment.CryptoV1]::AclApplied=$false;[Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites=0;[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence=New-Object Conecta.PdvRemotePilot.TestEvidence;
  & $module {param($App,$Identity);$script:PdvIdentityDirectory=$App;$script:Identity=$Identity;$script:Busy=$false;$script:WrongProfile=$false;$script:FailWrite='';$script:FailAcl=$false;$script:LastSddl='';} $app $identity;
  return @{Path=$path;App=$app;Bundle=$bundle;Identity=$identity;Ini=(Join-Path $bundle 'bin/ultravnc/ultravnc.ini');Marker=(Join-Path $bundle 'bin/ultravnc/ultravnc.portable');Profile=(Join-Path $app 'piloto-remoto/windows/remoto-piloto.xml');Journal=(Join-Path $path 'provisioning.xml');Trust=@{GatewayHost='remote.example';GatewayPort='5443'}};
 }
 function Invoke-Provision($Case){return Complete-PdvRemoteProvisioning $Case.Identity 'S-1-5-21-1-2-3-1001' $Case.Trust;}
 Test-Case 'perfil e segredo somente apos bundle, identidade, resposta e ACL restrita' {
  $case=New-ProvisionCase;$result=Invoke-Provision $case;
  Assert-Test ($result.AgentId -ceq $case.Identity.AgentId -and [IO.File]::Exists($case.Profile)) 'Perfil nao foi preparado';
  Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites -eq 1 -and [Conecta.PdvRemoteEnrollment.CryptoV1]::AclApplied) 'Segredo escrito sem ACL';
  Assert-Test ((&$module {$script:LastSddl}) -ceq 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;S-1-5-21-1-2-3-1001)') 'ACL concedeu acesso indevido';
  Assert-Test ([IO.File]::ReadAllText($case.Ini).Contains('ReverseAuthRequired=1') -and [IO.File]::ReadAllText($case.Ini).Contains('SocketConnect=0')) 'Perfil permitiu listener sem autenticacao';
  Assert-Test ((New-Object IO.FileInfo($case.Marker)).Length -eq 0) 'Marker nao vazio';
  Assert-Test (-not [IO.File]::ReadAllText($case.Profile).Contains('S3cr3t!X') -and -not [IO.File]::ReadAllText($case.Journal).Contains('S3cr3t!X')) 'Segredo vazou em XML';
 }
 Test-Case 'falha de ACL impede escrita do segredo e nao publica perfil' {
  $case=New-ProvisionCase;&$module {$script:FailAcl=$true;};Assert-Throws {Invoke-Provision $case} 'SyntheticAclDenied';
  Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites -eq 0 -and -not [IO.File]::Exists($case.Profile)) 'Falha ACL publicou segredo/perfil';
 }
 Test-Case 'retoma INI parcial e marker parcial somente com journal vinculado' {
  foreach($partial in @('ini','marker')){
   $case=New-ProvisionCase;&$module {$script:FailWrite='remoto-piloto.xml';};Assert-Throws {Invoke-Provision $case} 'SyntheticWriteInterrupted';
   if($partial -ceq 'ini'){[IO.File]::Delete($case.Marker);}else{[IO.File]::Delete($case.Ini);}
   &$module {$script:FailWrite='';};$result=Invoke-Provision $case;
   Assert-Test ($result.AgentId -ceq $case.Identity.AgentId -and [IO.File]::Exists($case.Ini) -and [IO.File]::Exists($case.Marker) -and [IO.File]::Exists($case.Profile)) ('Nao retomou '+$partial);
  }
 }
 Test-Case 'journal de outra identidade e arquivo preexistente desconhecido nao sao adotados' {
  $case=New-ProvisionCase;[IO.File]::WriteAllText($case.Ini,'UNKNOWN PRESERVE');Assert-Throws {Invoke-Provision $case} 'RemoteInstallationProfileAlreadyExists';Assert-Test ([IO.File]::ReadAllText($case.Ini) -ceq 'UNKNOWN PRESERVE') 'INI desconhecido foi alterado';
  $case=New-ProvisionCase;$bytes=&$module {ConvertTo-PdvIdentityXml 'PdvRemoteProvisioning' @{AgentId='33333333-3333-4333-8333-333333333333';CertificateSha256=('c'*64);MonitorUserSid='S-1-5-21-1-2-3-1001'};};[IO.File]::WriteAllBytes($case.Journal,$bytes);
  Assert-Throws {Invoke-Provision $case} 'RemoteInstallationProvisioningMismatch';Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites -eq 0 -and -not [IO.File]::Exists($case.Ini)) 'Journal errado escreveu';
 }
 Test-Case 'bundle, sessao ativa e perfil divergente negam antes de segredo ou perfil executavel' {
  foreach($failure in @('bundle','busy','profile')){
   $case=New-ProvisionCase;if($failure -ceq 'bundle'){$global:PdvProvisionRejectBundle=$true;}elseif($failure -ceq 'busy'){&$module {$script:Busy=$true;};}else{&$module {$script:WrongProfile=$true;};}
   $code=@{bundle='SyntheticBundleRejected';busy='SyntheticSessionBusy';profile='RemoteInstallationProfileMismatch'}[$failure];Assert-Throws {Invoke-Provision $case} $code;
   Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites -eq 0 -and -not [IO.File]::Exists($case.Profile)) ('Falha publicou '+$failure);
  }
 }
 Test-Case 'Windows x86 e processo de arquitetura divergente nao recebem perfil ou segredo' {
  foreach($mode in @('x86','process')){
   $case=New-ProvisionCase;if($mode -ceq 'x86'){[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.Architecture='x86';[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.ProcessArchitecture='x86';[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.CompatibilityProfile='win10plus-x86';$code='RemoteBundleUnsupportedProfile';}else{[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.ProcessArchitecture='x86';$code='RemoteInstallationPlatformUnsupported';}
   Assert-Throws {Invoke-Provision $case} $code;Assert-Test (@($global:PdvProvisionEffects|Where-Object{$_ -like 'http:*'}).Count -eq 0 -and [Conecta.PdvRemoteEnrollment.CryptoV1]::SecretWrites -eq 0) 'Arquitetura negada acessou credencial';
  }
 }
 Test-Case 'instalador completo recusa x86 antes de instalar ou emitir certificado' {
  foreach($mode in @('x86','unsupported','wrong-process')){
   $package=Join-Path $temporary ('full-'+[Guid]::NewGuid().ToString('N'));$windows=Join-Path $package 'piloto-remoto/windows';[void][IO.Directory]::CreateDirectory($windows);[void][IO.Directory]::CreateDirectory((Join-Path $package 'tools'));
   [IO.File]::WriteAllText((Join-Path $windows 'InstalarComponenteRemoto.ps1'),@'
function Assert-PdvRemoteInstallAdministrator {}
function Read-PdvRemoteInstallPackage {param($Source);$global:PdvProvisionEffects+='manifest';return @();}
function Get-PdvRemoteInstallTarget {throw 'UnexpectedInstallMutation';}
function Invoke-PdvRemoteAdministrativeInstall {throw 'UnexpectedInstallMutation';}
'@);
   [IO.File]::WriteAllText((Join-Path $package 'tools/ValidarBundleRemoto.ps1'),@'
function Assert-PdvRemoteBundle {param($BundleDirectory,$TrustedManifestPath,$ProfileId,[switch]$AllowRuntimeConfiguration);if(@('win7-sp1-x64','win10plus-x64') -cnotcontains $ProfileId){throw 'RemoteBundleUnsupportedProfile';};throw 'UnexpectedApprovedInstall';}
'@);
   [IO.File]::WriteAllText((Join-Path $windows 'AtivarCertificadoRemoto.ps1'),'$global:PdvProvisionCertificateIssues++;throw "UnexpectedCertificateIssue";');
   $script:PdvFullRemoteDirectory=$windows;$global:PdvProvisionEffects=@();$global:PdvProvisionCertificateIssues=0;[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence=New-Object Conecta.PdvRemotePilot.TestEvidence;
   if($mode -ceq 'x86'){[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.Architecture='x86';[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.ProcessArchitecture='x86';[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.CompatibilityProfile='win10plus-x86';$code='RemoteBundleUnsupportedProfile';}elseif($mode -ceq 'unsupported'){[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.Supported=$false;$code='RemoteInstallationPlatformUnsupported';}else{[Conecta.PdvRemotePilot.DesktopEvidence]::Evidence.ProcessArchitecture='x86';$code='RemoteInstallationPlatformUnsupported';}
   Assert-Throws {&$script:ActualFullInstall 'S-1-5-21-1-2-3-1001'} $code;
   Assert-Test ($global:PdvProvisionCertificateIssues -eq 0 -and @($global:PdvProvisionEffects|Where-Object{$_ -cne 'manifest'}).Count -eq 0) 'Plataforma recusada instalou/emitiu';
  }
 }
 # Registro de tarefa: mock completo do agendador, sem COM nem Windows.
 function Get-PdvIdentitySystemPowerShellPath {return (Join-Path $temporary 'System32/WindowsPowerShell/v1.0/powershell.exe');}
 function Assert-PdvIdentitySystemPowerShell {param($Path);$global:PdvTaskCheckedPath=$Path;}
 function Get-AuthenticodeSignature {param($LiteralPath,$ErrorAction);return @{Status=$(if($global:PdvTaskTrustedSignature){[Management.Automation.SignatureStatus]::Valid}else{[Management.Automation.SignatureStatus]::NotSigned});SignerCertificate=@{Subject='CN=Microsoft Windows,O=Microsoft Corporation,C=US'}};}
 function Release-PdvIdentityComObject {param($Object);}
 function New-Object {
  param([string]$TypeName,[object[]]$ArgumentList,[hashtable]$Property,[string]$ComObject);
  if($ComObject){if($ComObject -cne 'Schedule.Service'){throw 'UnexpectedComObject';};return $global:PdvTaskService;}
  return (Microsoft.PowerShell.Utility\New-Object @PSBoundParameters);
 }
 function New-TaskCase([string]$Principal='SYSTEM'){
  $app=Join-Path $temporary ('task-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($app);[IO.File]::WriteAllText((Join-Path $app 'PdvMonitor.Remoto.Inscricao.psm1'),'function Assert-PdvEnrollmentAdministrativePath {param($Path);return $Path;};Export-ModuleMember -Function Assert-PdvEnrollmentAdministrativePath;');
  $global:PdvTaskAction=[pscustomobject]@{Path='';Arguments='';WorkingDirectory=''};$global:PdvTaskTrigger=[pscustomobject]@{DaysInterval=0;StartBoundary='';RandomDelay='';Repetition=[pscustomobject]@{Interval='';Duration=''}};
  $actions=[pscustomobject]@{Count=1};$actions|Add-Member ScriptMethod Create {param($Kind);return $global:PdvTaskAction;};$actions|Add-Member ScriptMethod Item {param($Index);return $global:PdvTaskOldAction;};$triggers=[pscustomobject]@{};$triggers|Add-Member ScriptMethod Create {param($Kind);return $global:PdvTaskTrigger;};
  $global:PdvTaskDefinition=[pscustomobject]@{RegistrationInfo=[pscustomobject]@{Description=''};Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=0};Settings=[pscustomobject]@{Enabled=$false;StartWhenAvailable=$false;DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true;MultipleInstances=0;ExecutionTimeLimit=''};Actions=$actions;Triggers=$triggers};
  $path=Join-Path $app 'piloto-remoto/windows/ManterIdentidadeRemota.ps1';$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'"';$global:PdvTaskOldAction=[pscustomobject]@{Path=(Get-PdvIdentitySystemPowerShellPath);Arguments=$arguments};
  $global:PdvTaskOld=[pscustomobject]@{Definition=[pscustomobject]@{Actions=$actions;Principal=[pscustomobject]@{UserId=$Principal}}};
  $global:PdvTaskFolder=[pscustomobject]@{};$global:PdvTaskFolder|Add-Member ScriptMethod GetTask {param($Name);return $global:PdvTaskOld;};$global:PdvTaskFolder|Add-Member ScriptMethod RegisterTaskDefinition {param($Name,$Definition,$Flags,$User,$Password,$Logon,$Sddl);$global:PdvTaskRegistered=@{Name=$Name;Definition=$Definition;Flags=$Flags;User=$User;Password=$Password;Logon=$Logon;Sddl=$Sddl};return $null;};
  $global:PdvTaskService=[pscustomobject]@{};$global:PdvTaskService|Add-Member ScriptMethod Connect {};$global:PdvTaskService|Add-Member ScriptMethod GetFolder {param($Name);return $global:PdvTaskFolder;};$global:PdvTaskService|Add-Member ScriptMethod NewTask {param($Flags);return $global:PdvTaskDefinition;};$global:PdvTaskRegistered=$null;$global:PdvTaskTrustedSignature=$true;return $app;
 }
 Test-Case 'tarefa SYSTEM aceita SID canonico e usa somente script e executavel fixos' {
  foreach($principal in @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')){
   $app=New-TaskCase $principal;&$script:ActualRegister $app;
   Assert-Test ($null -ne $global:PdvTaskRegistered -and $global:PdvTaskRegistered.User -ceq 'SYSTEM' -and $null -eq $global:PdvTaskRegistered.Password) 'Tarefa nao registrada SYSTEM sem senha';
   Assert-Test ($global:PdvTaskAction.Path -ceq (Get-PdvIdentitySystemPowerShellPath) -and $global:PdvTaskCheckedPath -ceq $global:PdvTaskAction.Path) 'Executavel da tarefa nao validado';
   Assert-Test ($global:PdvTaskAction.Arguments -ceq ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $app 'piloto-remoto/windows/ManterIdentidadeRemota.ps1')+'"')) 'Argumentos nao literais';
   Assert-Test ($global:PdvTaskRegistered.Sddl -ceq 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)' -and $global:PdvTaskDefinition.Settings.MultipleInstances -eq 2) 'Tarefa concedeu controle indevido ou concorrencia';
  }
 }
 Test-Case 'tarefa com outro usuario ou comando preexistente nao e substituida' {
  $app=New-TaskCase 'S-1-5-21-1-2-3-1001';Assert-Throws {&$script:ActualRegister $app} 'RemoteIdentityTaskNameOccupied';Assert-Test ($null -eq $global:PdvTaskRegistered) 'Tarefa de outro usuario foi substituida';
  $app=New-TaskCase;$global:PdvTaskOldAction.Arguments+=' -Command bad';Assert-Throws {&$script:ActualRegister $app} 'RemoteIdentityTaskNameOccupied';Assert-Test ($null -eq $global:PdvTaskRegistered) 'Comando extra foi substituido';
 }
 Test-Case 'executavel sem assinatura confiavel impede registro da tarefa SYSTEM' {
  $app=New-TaskCase;$global:PdvTaskTrustedSignature=$false;Assert-Throws {&$script:ActualRegister $app} 'RemoteIdentitySystemPowerShellInvalid';Assert-Test ($null -eq $global:PdvTaskRegistered) 'PowerShell nao assinado foi agendado';
 }
 if($script:Failures.Count){throw ($script:Failures -join "`n");}
 Write-Output ('PASS: '+$script:Cases+' casos; '+$script:Checks+' verificacoes offline de provisionamento e tarefa.');
}finally{if([IO.Directory]::Exists($temporary)){[IO.Directory]::Delete($temporary,$true);}}
