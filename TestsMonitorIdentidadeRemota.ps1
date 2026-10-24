#requires -Version 7.0
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0;
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;Add-Type -Path (Join-Path $root 'piloto-remoto/windows/RemoteEnrollmentCrypto.cs');
Import-Module (Join-Path $root 'PdvMonitor.Remoto.Identidade.psm1') -Force;$module=Get-Module PdvMonitor.Remoto.Identidade;
$count=0;function Assert-Test($Value,$Message){$script:count++;if(-not $Value){throw $Message;}}
function Assert-Throws([scriptblock]$Body,$Code){$script:count++;try{&$Body|Out-Null;}catch{if($_.Exception.Message.Contains($Code)){return};throw};throw "Missing $Code"}
$temporary=Join-Path /private/tmp ('pdv-identity-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
$key=[Security.Cryptography.RSA]::Create(2048);$other=[Security.Cryptography.RSA]::Create(2048);
try{
 $agent='11111111-1111-4111-8111-111111111111';$request='22222222-2222-4222-8222-222222222222';
 $public=[Conecta.PdvRemoteEnrollment.CryptoV1]::CreateRequest($key,$agent,$request);
 $private=Join-Path $temporary 'synthetic.key';[IO.File]::WriteAllText($private,$key.ExportRSAPrivateKeyPem());
 $payload="PDV-REMOTE-IDENTITY`n1`nprofile";$signed=[Conecta.PdvRemoteEnrollment.CryptoV1]::SignIdentityPayload($private,$payload,$public.PublicKeySha256);
 Assert-Test ($key.VerifyData([Text.Encoding]::UTF8.GetBytes($payload),[Convert]::FromBase64String($signed),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'Signature not interoperable';
 Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::SignIdentityPayload($private,$payload,('a'*64))} 'RemoteIdentityPrivateKeyMismatch';
 Assert-Test (([BitConverter]::ToString([Conecta.PdvRemoteEnrollment.CryptoV1]::EncodeVncPassword('12345678'))) -ceq 'F0-E4-31-64-F6-C2-E3-73') 'VNC official vector differs';
 Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::EncodeVncPassword('short')} 'RemoteIdentityInvalidVncCredential';
 $now=[DateTimeOffset]::UtcNow;Assert-Test (Test-PdvIdentityRenewalDue $now.AddDays(30).ToString('o') $now) '30day boundary';Assert-Test (-not(Test-PdvIdentityRenewalDue $now.AddDays(31).ToString('o') $now)) '31day premature';Assert-Throws {Test-PdvIdentityRenewalDue $now.ToString('o') $now} 'RemoteIdentityExpired';
 $identity=@{AgentId=$agent;CertificateSha256=('a'*64);PublicKeySha256=$public.PublicKeySha256;PrivateKeyFile=$private;MonitorUserSid='S-1-5-21-1-2-3-1001'};
 & $module {
  function script:Assert-PdvIdentityPath {param($Path,$Sid);return $Path;}
  function script:Invoke-PdvIdentityHttp {
   param($Trust,$Operation,$Body);
   $script:HttpCalls++;$script:LastBody=$Body;
   if($Operation -ceq 'challenge'){
    $expiry=[DateTimeOffset]::UtcNow.AddMinutes(3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ');$id='33333333-3333-4333-8333-333333333333';$nonce='a'*43;$hash='';if($Body.Contains('csrSha256')){$hash=$Body.csrSha256;}
    $canonical=@('PDV-REMOTE-IDENTITY','1',$Body.purpose,$Body.agentId,$Body.requestId,$id,$nonce,$Body.certificateSha256,$hash,$expiry)-join "`n";
    if($script:Tamper){$canonical+='BAD';}
    return ,(ConvertTo-PdvIdentityXml 'PdvRemoteIdentityChallenge' @{ChallengeId=$id;Nonce=$nonce;ExpiresAt=$expiry;SigningPayload=$canonical;Purpose=$Body.purpose;AgentId=$Body.agentId;RequestId=$Body.requestId;CertificateSha256=$Body.certificateSha256;CsrSha256=$hash});
   }
   return ,([Text.Encoding]::UTF8.GetBytes('<OK/>'));
  };$script:HttpCalls=0;$script:Tamper=$false;
 }
 $result=& $module {param($I,$R);Invoke-PdvIdentityProof @{} $I 'profile' $R;} $identity $request;
 Assert-Test ([Text.Encoding]::UTF8.GetString($result) -ceq '<OK/>') 'Proof response bytes';
 Assert-Test ((&$module {$script:HttpCalls}) -eq 2) 'Challenge and proof calls';
 $sent=&$module {$script:LastBody};Assert-Test ($sent.signatureBase64.Length -eq 344 -and $sent.Count -eq 6) 'Proof contract not closed';
 & $module {$script:Tamper=$true;$script:HttpCalls=0;};Assert-Throws {&$module {param($I,$R);Invoke-PdvIdentityProof @{} $I 'profile' $R;} $identity $request} 'RemoteIdentityChallengeMismatch';Assert-Test ((&$module {$script:HttpCalls}) -eq 1) 'Signed tampered challenge';
 $json=&$module {ConvertTo-PdvIdentityJson @{schemaVersion=1;csrPem="a`nb";agentId='x'};};$parsed=[Text.Encoding]::UTF8.GetString($json)|ConvertFrom-Json;Assert-Test ($parsed.schemaVersion -eq 1 -and $parsed.csrPem -ceq "a`nb") 'JSON PS2 encoding';

 # Durable maintenance with synthetic files and mocked Windows/network boundaries.
 & $module {
  param($T,$Agent);
  $script:TestRoot=$T;$script:Agent=$Agent;$script:Now=[DateTimeOffset]::UtcNow;$script:Config=@{AgentId=$Agent;MonitorUserSid='S-1-5-21-1-2-3-1001';IdentityDirectory=(Join-Path $T 'identities/old')};$script:Calls=@();$script:Busy=$false;$script:ConfirmFail=$false;$script:ProfileFail=$false;$script:OldExpired=$false;$script:Due=$true;$script:ServerCommitted=$false;
  function script:Initialize-PdvIdentity {}
  function script:Open-PdvIdentityMaintenanceLock {param($Root);return [IO.File]::Open((Join-Path $Root 'enrollment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);}
  function script:Get-PdvIdentityNow {return $script:Now;}
  function script:Read-PdvMonitorRemoteEnrollmentTrust {param($Path);return @{};}
  function script:Read-PdvIdentityFile {param($Path,$Root,$Fields,$Sid);if([IO.Path]::GetFileName($Path) -ceq 'identity-maintenance.xml'){return $script:Config.Clone();};return (Read-PdvIdentityXml ([IO.File]::ReadAllBytes($Path)) $Root $Fields);}
  function script:Write-PdvIdentityAtomic {param($Path,$Bytes,$Sid);if([IO.Path]::GetFileName($Path) -ceq 'identity-maintenance.xml'){$script:Config=Read-PdvIdentityXml $Bytes 'PdvRemoteIdentityMaintenance' @('AgentId','MonitorUserSid','IdentityDirectory');};[IO.File]::WriteAllBytes($Path,$Bytes);}
  function script:Read-PdvIdentityCertificate {param($Directory,$Sid,$Trust);$isOld=$Directory.EndsWith('/old');if($isOld -and $script:OldExpired){throw 'OldMustNotBeRead';};$expiry=$script:Now.AddDays(90);if($isOld -and $script:Due){$expiry=$script:Now.AddDays(20);};return @{AgentId=$script:Agent;ExpiresAt=$expiry.ToString('o');CertificateSha256=$(if($isOld){'a'*64}else{'b'*64});PublicKeySha256=('c'*64);PrivateKeyFile='synthetic';MonitorUserSid=$Sid};}
  function script:Assert-PdvIdentityNoRemoteProcesses {if($script:Busy){throw 'SessionBusy';}}
  function script:New-PdvMonitorRemoteEnrollmentRequest {param($Path,$Agent,$Request,$Sid);$script:Calls+=('request:'+ $Request);return @{CsrPem='PUBLIC-SYNTHETIC';RequestId=$Request;AgentId=$Agent};}
  function script:Complete-PdvMonitorRemoteEnrollment {param($Request,$Trust,$Bytes);$script:Calls+='install-prepared';return @{};}
  function script:Invoke-PdvIdentityProof {
   param($Trust,$Identity,$Purpose,$Request,$Csr);
   $script:Calls+=$Purpose;
   if($Purpose -ceq 'renew'){return ,(ConvertTo-PdvIdentityXml 'PdvRemoteIdentityRenewal' @{RequestId=$Request;AgentId=$script:Agent;CertificatePem='PUBLIC-SYNTHETIC';CertificateSha256=('b'*64);ExpiresAt=$script:Now.AddDays(90).ToString('o');GatewayHost='example.test';GatewayPort='5443';RepeaterId='4901';State='prepared';PreparedUntil=$script:Now.AddDays(1).ToString('o')});}
   if($Purpose -ceq 'confirm'){$script:ServerCommitted=$true;if($script:ConfirmFail){throw 'LostConfirmResponse';};return ,(ConvertTo-PdvIdentityXml 'PdvRemoteIdentityConfirmation' @{RequestId=$Request;AgentId=$script:Agent;CertificateSha256=('b'*64);State='committed'});}
   throw 'UnexpectedNetworkOperation';
  }
  function script:Write-PdvIdentityProfileCertificate {param($Path,$Identity);$script:Calls+='profile';if($script:ProfileFail){throw 'ProfileLocked';}}
 } $temporary $agent;
 & $module {$script:Due=$false;};Assert-Test ((Invoke-PdvIdentityMaintenance $temporary) -ceq 'CertificateCurrent') 'Healthy identity maintenance';Assert-Test ((&$module {$script:Calls.Count}) -eq 0) 'Healthy identity made network request';
 & $module {$script:Due=$true;$script:Busy=$true;};Assert-Throws {Invoke-PdvIdentityMaintenance $temporary} 'RemoteIdentityMaintenanceIncomplete';Assert-Test ((&$module {$script:Calls.Count}) -eq 0) 'Busy session generated request';
 & $module {$script:Busy=$false;$script:ConfirmFail=$true;};Assert-Throws {Invoke-PdvIdentityMaintenance $temporary} 'RemoteIdentityMaintenanceIncomplete';
 $state=&$module {Read-PdvIdentityFile (Join-Path $script:TestRoot 'renewal-state.xml') 'PdvRemoteIdentityRenewalState' @('AgentId','RequestId','Stage','StartedAt','PreparedUntil');};Assert-Test ($state.Stage -ceq 'prepared') 'Lost ACK lost pending state';
 Assert-Test ((&$module {$script:Config.IdentityDirectory}) -ceq (Join-Path $temporary 'identities/old')) 'Unconfirmed identity replaced pointer';
 & $module {$script:OldExpired=$true;$script:ConfirmFail=$false;$script:ProfileFail=$true;};Assert-Throws {Invoke-PdvIdentityMaintenance $temporary} 'RemoteIdentityMaintenanceIncomplete';Assert-Test ((&$module {@($script:Calls|Where-Object{$_ -ceq 'renew'}).Count}) -eq 1) 'Retry issued another certificate';
 & $module {$script:ProfileFail=$false;};Assert-Test ((Invoke-PdvIdentityMaintenance $temporary) -ceq 'CertificateRenewed') 'Reconciliation after lost ACK/profile write';
 $final=&$module {Read-PdvIdentityFile (Join-Path $script:TestRoot 'renewal-state.xml') 'PdvRemoteIdentityRenewalState' @('AgentId','RequestId','Stage','StartedAt','PreparedUntil');};Assert-Test ($final.Stage -ceq 'committed' -and $final.RequestId -ceq $state.RequestId) 'Request ID changed or state not committed';
 Assert-Test ((Invoke-PdvIdentityMaintenance $temporary) -ceq 'CertificateCurrent') 'New confirmed identity renewed again';
 Assert-Test ((&$module {@($script:Calls|Where-Object{$_ -ceq 'renew'}).Count}) -eq 1) 'Confirmed identity was resent';

 Write-Output "PASS: $count identity crypto/protocol checks (synthetic files, no Windows/network).";
}finally{$key.Dispose();$other.Dispose();[IO.Directory]::Delete($temporary,$true);}
