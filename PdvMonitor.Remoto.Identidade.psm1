#requires -Version 2.0
# Imported only from the administrator-owned extension; no effects at import.
$script:PdvIdentityDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path;
$script:PdvIdentityEnrollment=Import-Module (Join-Path $script:PdvIdentityDirectory 'PdvMonitor.Remoto.Inscricao.psm1') -PassThru;
function Get-PdvIdentityNow {return [DateTimeOffset]::UtcNow;}
function Invoke-PdvIdentityEnrollment {param([scriptblock]$Body,$First=$null,$Second=$null,$Third=$null);return (& $script:PdvIdentityEnrollment $Body $First $Second $Third);}
function Initialize-PdvIdentity {Invoke-PdvIdentityEnrollment {Initialize-PdvEnrollmentCrypto;};}
function Assert-PdvIdentityPath {param([string]$Path,[string]$Sid='');return (Invoke-PdvIdentityEnrollment {param($P,$S);Assert-PdvEnrollmentAdministrativePath $P $S;} $Path $Sid);}
function Read-PdvIdentityXml {
  param([byte[]]$Bytes,[string]$Root,[string[]]$Fields);
  return (Invoke-PdvIdentityEnrollment {param($B,$R,$F);Read-PdvEnrollmentXml $B $R $F;} $Bytes $Root $Fields);
}
function ConvertTo-PdvIdentityXml {param([string]$Root,$Values);return ,(Invoke-PdvIdentityEnrollment {param($R,$V);New-PdvEnrollmentXml $R $V;} $Root $Values);}
function Read-PdvIdentityBytes {param([string]$Path);return ,(Invoke-PdvIdentityEnrollment {param($P);Read-PdvEnrollmentBytes $P;} $Path);}
function Read-PdvIdentityFile {param([string]$Path,[string]$Root,[string[]]$Fields,[string]$Sid='');[void](Assert-PdvIdentityPath $Path $Sid);return (Read-PdvIdentityXml (Read-PdvIdentityBytes $Path) $Root $Fields);}
function Write-PdvIdentityAtomic {
  param([string]$Path,[byte[]]$Bytes,[string]$Sid='');
  [void](Assert-PdvIdentityPath ([IO.Path]::GetDirectoryName($Path)));
  if([IO.File]::Exists($Path)){[void](Assert-PdvIdentityPath $Path $Sid);$guard=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($guard.SafeFileHandle);}finally{$guard.Close();}}
  $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';
  try{
    Invoke-PdvIdentityEnrollment {param($P,$B);Write-PdvEnrollmentNewFile $P $B;} $temporary $Bytes;
    [void](Assert-PdvIdentityPath $temporary);
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,$null);}else{[IO.File]::Move($temporary,$Path);}
  }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary);}}
}
function Read-PdvIdentityCertificate {
  param([string]$Directory,[string]$Sid,$Trust);
  $values=Read-PdvIdentityFile (Join-Path $Directory 'certificate.xml') 'PdvRemoteEnrollmentCertificate' @('AgentId','RequestId','CertificateFile','CertificateSha256','ExpiresAt','GatewayHost','GatewayPort','RepeaterId','PrivateKeyFile','ServerCaFile') $Sid;
  if($values.CertificateFile -cne (Join-Path $Directory 'client-certificate.pem') -or $values.PrivateKeyFile -cne (Join-Path $Directory 'client-private.key') -or $values.ServerCaFile -cne (Join-Path $Directory 'identity-server-ca.crt') -or $values.GatewayHost -cne $Trust.GatewayHost -or $values.GatewayPort -cne $Trust.GatewayPort){throw 'RemoteIdentityMetadataMismatch';}
  $pending=Read-PdvIdentityFile (Join-Path $Directory 'request.xml') 'PdvRemoteEnrollmentPending' @('AgentId','RequestId','MonitorUserSid','PublicKeySha256') $Sid;
  if($pending.AgentId -cne $values.AgentId -or $pending.RequestId -cne $values.RequestId -or $pending.MonitorUserSid -cne $Sid){throw 'RemoteIdentityMetadataMismatch';}
  [void](Assert-PdvIdentityPath $values.PrivateKeyFile $Sid);
  $pem=[Text.Encoding]::ASCII.GetString((Read-PdvIdentityBytes $values.CertificateFile));
  $verified=[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($pem,$Trust.DeviceCaPem,$Trust.DeviceCaSha256,$values.AgentId,$pending.PublicKeySha256,(Get-PdvIdentityNow).UtcDateTime);
  if($verified.CertificateSha256 -cne $values.CertificateSha256 -or [DateTimeOffset]::Parse($verified.NotAfter) -ne [DateTimeOffset]::Parse($values.ExpiresAt)){throw 'RemoteIdentityMetadataMismatch';}
  $values.PublicKeySha256=$pending.PublicKeySha256;$values.MonitorUserSid=$Sid;return $values;
}
function ConvertTo-PdvIdentityJson {
  param($Values);
  $pairs=@();foreach($key in @($Values.Keys|Sort-Object)){
    $value=$Values[$key];$encoded=Invoke-PdvIdentityEnrollment {param($V);ConvertTo-PdvEnrollmentJsonString ([string]$V);} $value;
    if($key -ceq 'schemaVersion'){$encoded='1';};$name=Invoke-PdvIdentityEnrollment {param($V);ConvertTo-PdvEnrollmentJsonString $V;} ([string]$key);$pairs+=($name+':'+$encoded);
  };return ,([Text.Encoding]::UTF8.GetBytes('{'+($pairs -join ',')+'}'));
}
function Invoke-PdvIdentityHttp {
  param($Trust,[string]$Operation,$Body);
  if(@('challenge','renew','confirm','profile','abort') -cnotcontains $Operation){throw 'RemoteIdentityInvalidOperation';}
  $base=[Uri]$Trust.ApiEnrollmentUrl;$endpoint=$base.GetLeftPart([UriPartial]::Authority)+'/api/pdv-monitor/remote-identity/'+$Operation;
  $bytes=ConvertTo-PdvIdentityJson $Body;
  try{return ,(Invoke-PdvIdentityEnrollment {param($U,$B);Invoke-PdvEnrollmentHttp $U $B;} $endpoint $bytes);}finally{[Array]::Clear($bytes,0,$bytes.Length);}
}
function Invoke-PdvIdentityProof {
  param($Trust,$Identity,[string]$Purpose,[string]$RequestId,[string]$CsrPem='');
  if(@('renew','confirm','profile','abort') -cnotcontains $Purpose -or $RequestId -cnotmatch '^[a-f0-9-]{36}$'){throw 'RemoteIdentityInvalidOperation';}
  $hash='';if($Purpose -ceq 'renew'){$CsrPem=$CsrPem.Replace("`r`n","`n").Trim()+"`n";$hash=[Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256([Text.Encoding]::UTF8.GetBytes($CsrPem));}
  $body=@{schemaVersion=1;agentId=$Identity.AgentId;purpose=$Purpose;requestId=$RequestId;certificateSha256=$Identity.CertificateSha256};if($hash){$body.csrSha256=$hash;}
  [void](Assert-PdvIdentityPath $Identity.PrivateKeyFile $Identity.MonitorUserSid);
  $random=New-Object Security.Cryptography.RNGCryptoServiceProvider;$nonceBytes=New-Object byte[] 32;try{$random.GetBytes($nonceBytes);$clientNonce=[Convert]::ToBase64String($nonceBytes).TrimEnd('=').Replace('+','-').Replace('/','_');}finally{$random.Dispose();[Array]::Clear($nonceBytes,0,$nonceBytes.Length);}
  $requestedAt=(Get-PdvIdentityNow).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ');
  $challengeProof=@('PDV-REMOTE-IDENTITY-CHALLENGE','1',$Purpose,$Identity.AgentId,$RequestId,$Identity.CertificateSha256,$hash,$clientNonce,$requestedAt) -join "`n";
  $body.clientNonce=$clientNonce;$body.requestedAt=$requestedAt;$body.signatureBase64=[Conecta.PdvRemoteEnrollment.CryptoV1]::SignIdentityPayload($Identity.PrivateKeyFile,$challengeProof,$Identity.PublicKeySha256);
  $challenge=Read-PdvIdentityXml (Invoke-PdvIdentityHttp $Trust 'challenge' $body) 'PdvRemoteIdentityChallenge' @('ChallengeId','Nonce','ExpiresAt','SigningPayload','Purpose','AgentId','RequestId','CertificateSha256','CsrSha256');
  if($challenge.ChallengeId -cnotmatch '^[a-f0-9-]{36}$' -or $challenge.Nonce -cnotmatch '^[A-Za-z0-9_-]{43}$' -or $challenge.ExpiresAt -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$' -or $challenge.Purpose -cne $Purpose -or $challenge.AgentId -cne $Identity.AgentId -or $challenge.RequestId -cne $RequestId -or $challenge.CertificateSha256 -cne $Identity.CertificateSha256 -or $challenge.CsrSha256 -cne $hash){throw 'RemoteIdentityChallengeMismatch';}
  $expiry=[DateTimeOffset]::Parse($challenge.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture);$now=Get-PdvIdentityNow;if($expiry -le $now -or $expiry -gt $now.AddMinutes(5)){throw 'RemoteIdentityChallengeExpired';}
  $canonical=@('PDV-REMOTE-IDENTITY','1',$Purpose,$Identity.AgentId,$RequestId,$challenge.ChallengeId,$challenge.Nonce,$Identity.CertificateSha256,$hash,$challenge.ExpiresAt) -join "`n";
  if($challenge.SigningPayload -cne $canonical){throw 'RemoteIdentityChallengeMismatch';}
  [void](Assert-PdvIdentityPath $Identity.PrivateKeyFile $Identity.MonitorUserSid);
  $signature=[Conecta.PdvRemoteEnrollment.CryptoV1]::SignIdentityPayload($Identity.PrivateKeyFile,$canonical,$Identity.PublicKeySha256);
  $request=@{schemaVersion=1;agentId=$Identity.AgentId;requestId=$RequestId;challengeId=$challenge.ChallengeId;certificateSha256=$Identity.CertificateSha256;signatureBase64=$signature};if($Purpose -ceq 'renew'){$request.csrPem=$CsrPem;}
  return ,(Invoke-PdvIdentityHttp $Trust $Purpose $request);
}
function Test-PdvIdentityRenewalDue {
  param([string]$ExpiresAt,[DateTimeOffset]$Now=(Get-PdvIdentityNow));
  try{$until=[DateTimeOffset]::Parse($ExpiresAt,[Globalization.CultureInfo]::InvariantCulture);}catch{throw 'RemoteIdentityInvalidExpiry';}
  if($until -le $Now){throw 'RemoteIdentityExpired';};return ($until -le $Now.AddDays(30));
}
function Assert-PdvIdentityNoRemoteProcesses {
  $processes=@(Get-WmiObject Win32_Process -Filter "Name='winvnc.exe' OR Name='stunnel.exe'" -ErrorAction Stop);if($processes.Count){throw 'RemoteIdentitySessionBusy';}
}
function Write-PdvIdentityProfileCertificate {
  param([string]$ProfilePath,$Identity);
  [void](Assert-PdvIdentityPath $ProfilePath);$bytes=Read-PdvIdentityBytes $ProfilePath;
  $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$text=[Text.Encoding]::UTF8.GetString($bytes);if($text -match '<!DOCTYPE|<!ENTITY'){throw 'RemoteIdentityInvalidProfile';};$xml.LoadXml($text.TrimStart([char]0xfeff));
  $root=$xml.DocumentElement;if($root.Name -cne 'PdvRemoteWindowsPilot' -or $root.AgentId -cne $Identity.AgentId){throw 'RemoteIdentityInvalidProfile';}
  foreach($key in @('CertificateFile','CertificateSha256','PrivateKeyFile','ServerCaFile')){if($root.SelectNodes($key).Count -ne 1){throw 'RemoteIdentityInvalidProfile';};$root.SelectSingleNode($key).InnerText=[string]$Identity[$key];}
  Write-PdvIdentityAtomic $ProfilePath ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml));
}
function Open-PdvIdentityMaintenanceLock {
  param([string]$RemoteRoot);
  $lock=New-Object IO.FileStream((Join-Path $RemoteRoot 'enrollment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);
  try{[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($lock.SafeFileHandle);return $lock;}catch{$lock.Close();throw;}
}
function Invoke-PdvIdentityMaintenance {
  param([string]$RemoteRoot);
  Initialize-PdvIdentity;[void](Assert-PdvIdentityPath $RemoteRoot);$lock=$null;$state=$null;$config=$null;$trust=$null;$statePath='';
  try{
    $lock=Open-PdvIdentityMaintenanceLock $RemoteRoot;
    $config=Read-PdvIdentityFile (Join-Path $RemoteRoot 'identity-maintenance.xml') 'PdvRemoteIdentityMaintenance' @('AgentId','MonitorUserSid','IdentityDirectory');
    if($config.AgentId -cnotmatch '^[a-f0-9-]{36}$' -or $config.MonitorUserSid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'RemoteIdentityInvalidMaintenance';}
    $identities=Join-Path $RemoteRoot 'identities';$prefix=$identities+[IO.Path]::DirectorySeparatorChar;if(-not $config.IdentityDirectory.StartsWith($prefix,[StringComparison]::Ordinal) -or [IO.Path]::GetDirectoryName($config.IdentityDirectory) -cne $identities){throw 'RemoteIdentityInvalidMaintenance';}
    $trust=Read-PdvMonitorRemoteEnrollmentTrust (Join-Path $script:PdvIdentityDirectory 'piloto-remoto/windows/inscricao-confianca.xml');
    $statePath=Join-Path $RemoteRoot 'renewal-state.xml';$state=$null;
    if([IO.File]::Exists($statePath)){$state=Read-PdvIdentityFile $statePath 'PdvRemoteIdentityRenewalState' @('AgentId','RequestId','Stage','StartedAt','PreparedUntil');if($state.AgentId -cne $config.AgentId -or $state.RequestId -cnotmatch '^[a-f0-9-]{36}$' -or @('requested','prepared','committed','aborted') -cnotcontains $state.Stage){throw 'RemoteIdentityInvalidMaintenance';}}
    $current=$null;if($null -eq $state -or $state.Stage -cne 'prepared'){$current=Read-PdvIdentityCertificate $config.IdentityDirectory $config.MonitorUserSid $trust;if($current.AgentId -cne $config.AgentId){throw 'RemoteIdentityInvalidMaintenance';}}
    if($null -eq $state -or @('committed','aborted') -ccontains $state.Stage){
      if(-not (Test-PdvIdentityRenewalDue $current.ExpiresAt)){return 'CertificateCurrent';}
      Assert-PdvIdentityNoRemoteProcesses;$state=@{AgentId=$config.AgentId;RequestId=[Guid]::NewGuid().ToString('D');Stage='requested';StartedAt=(Get-PdvIdentityNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ');PreparedUntil=''};Write-PdvIdentityAtomic $statePath (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityRenewalState' $state);
    }
    Assert-PdvIdentityNoRemoteProcesses;
    $nextPath=Join-Path $identities ($config.AgentId+'-'+$state.RequestId);
    $next=New-PdvMonitorRemoteEnrollmentRequest $nextPath $config.AgentId $state.RequestId $config.MonitorUserSid;
    if($state.Stage -ceq 'requested'){
      $response=Read-PdvIdentityXml (Invoke-PdvIdentityProof $trust $current 'renew' $state.RequestId $next.CsrPem) 'PdvRemoteIdentityRenewal' @('RequestId','AgentId','CertificatePem','CertificateSha256','ExpiresAt','GatewayHost','GatewayPort','RepeaterId','State','PreparedUntil');
      if($response.State -cne 'prepared' -or [DateTimeOffset]::Parse($response.PreparedUntil) -le (Get-PdvIdentityNow)){throw 'RemoteIdentityInvalidPreparation';};$state.PreparedUntil=$response.PreparedUntil;$response.Remove('State');$response.Remove('PreparedUntil');
      [void](Complete-PdvMonitorRemoteEnrollment $next $trust (ConvertTo-PdvIdentityXml 'PdvRemoteEnrollment' $response));
      $state.Stage='prepared';Write-PdvIdentityAtomic $statePath (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityRenewalState' $state);
    }
    $prepared=Read-PdvIdentityCertificate $nextPath $config.MonitorUserSid $trust;
    # Commit proves possession of the new key; repeat after a lost response is safe.
    $confirmation=Read-PdvIdentityXml (Invoke-PdvIdentityProof $trust $prepared 'confirm' $state.RequestId) 'PdvRemoteIdentityConfirmation' @('RequestId','AgentId','CertificateSha256','State');
    if($confirmation.RequestId -cne $state.RequestId -or $confirmation.AgentId -cne $config.AgentId -or $confirmation.CertificateSha256 -cne $prepared.CertificateSha256 -or $confirmation.State -cne 'committed'){throw 'RemoteIdentityConfirmationMismatch';}
    # A failed local write preserves both generations and the persisted request for retry.
    Write-PdvIdentityProfileCertificate (Join-Path $script:PdvIdentityDirectory 'piloto-remoto/windows/remoto-piloto.xml') $prepared;
    $config.IdentityDirectory=$nextPath;Write-PdvIdentityAtomic (Join-Path $RemoteRoot 'identity-maintenance.xml') (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityMaintenance' $config);
    $state.Stage='committed';Write-PdvIdentityAtomic $statePath (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityRenewalState' $state);
    return 'CertificateRenewed';
  }catch{
    if($null -ne $state -and @('requested','prepared') -ccontains $state.Stage -and (Get-PdvIdentityNow) -gt ([DateTimeOffset]::Parse($state.StartedAt)).AddHours(24)){
      try{
        $old=Read-PdvIdentityCertificate $config.IdentityDirectory $config.MonitorUserSid $trust;
        $aborted=Read-PdvIdentityXml (Invoke-PdvIdentityProof $trust $old 'abort' $state.RequestId) 'PdvRemoteIdentityConfirmation' @('RequestId','AgentId','CertificateSha256','State');
        if($aborted.State -cne 'aborted' -or $aborted.AgentId -cne $config.AgentId -or $aborted.RequestId -cne $state.RequestId -or $aborted.CertificateSha256 -cne $old.CertificateSha256){throw 'RemoteIdentityAbortMismatch';}
        $state.Stage='aborted';Write-PdvIdentityAtomic $statePath (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityRenewalState' $state);
      }catch{}
    };throw 'RemoteIdentityMaintenanceIncomplete';
  }finally{if($null -ne $lock){$lock.Close();}}
}

function Complete-PdvRemoteProvisioning {
  param($Enrollment,[string]$MonitorUserSid,$Trust);
  Initialize-PdvIdentity;
  $app=$script:PdvIdentityDirectory;$bundle=Join-Path $app 'piloto-remoto/windows/bundle';
  foreach($file in @('tools/ValidarBundleRemoto.ps1','tools/remoto-bundle-lock.xml','PdvMonitor.Remoto.Windows.psm1','piloto-remoto/windows/RemoteWindowsNative.cs')){[void](Assert-PdvIdentityPath (Join-Path $app $file));}
  . (Join-Path $app 'tools/ValidarBundleRemoto.ps1');
  $windows=Import-Module (Join-Path $app 'PdvMonitor.Remoto.Windows.psm1') -PassThru;
  $evidence=& $windows {Get-PdvRemoteWindowsNativeEvidence;};
  if(-not $evidence.Supported -or $evidence.ProcessArchitecture -cne $evidence.Architecture){throw 'RemoteInstallationPlatformUnsupported';}
  $provisioningPath=Join-Path ([IO.Path]::GetDirectoryName($app)) 'provisioning.xml';$resuming=[IO.File]::Exists($provisioningPath);
  if($resuming){$provisioning=Read-PdvIdentityFile $provisioningPath 'PdvRemoteProvisioning' @('AgentId','CertificateSha256','MonitorUserSid');if($provisioning.AgentId -cne $Enrollment.AgentId -or $provisioning.CertificateSha256 -cne $Enrollment.CertificateSha256 -or $provisioning.MonitorUserSid -cne $MonitorUserSid){throw 'RemoteInstallationProvisioningMismatch';}}
  # Validate vendor files in the unmodified bundle; on resume only our two generated paths may exist.
  $runtimePair=[IO.File]::Exists((Join-Path $bundle 'bin/ultravnc/ultravnc.ini')) -and [IO.File]::Exists((Join-Path $bundle 'bin/ultravnc/ultravnc.portable'));
  if($resuming -and -not $runtimePair){
    Assert-PdvIdentityNoRemoteProcesses;
    foreach($generated in @('bin/ultravnc/ultravnc.ini','bin/ultravnc/ultravnc.portable')){$owned=Join-Path $bundle $generated;if([IO.File]::Exists($owned)){[void](Assert-PdvIdentityPath $owned);[IO.File]::Delete($owned);}}
  }
  $approved=Assert-PdvRemoteBundle -BundleDirectory $bundle -TrustedManifestPath (Join-Path $app 'tools/remoto-bundle-lock.xml') -ProfileId $evidence.CompatibilityProfile -AllowRuntimeConfiguration:($resuming -and $runtimePair);
  $identity=Read-PdvIdentityCertificate ([IO.Path]::GetDirectoryName($Enrollment.CertificateFile)) $MonitorUserSid $Trust;
  $profileResponse=Read-PdvIdentityXml (Invoke-PdvIdentityProof $Trust $identity 'profile' ([Guid]::NewGuid().ToString('D'))) 'PdvRemoteIdentityProfile' @('AgentId','RepeaterId','CertificateSha256','VncPassword','GatewayHost','GatewayPort','ExpiresAt');
  if($profileResponse.AgentId -cne $identity.AgentId -or $profileResponse.ExpiresAt -cne $identity.ExpiresAt -or $profileResponse.RepeaterId -cne $identity.RepeaterId -or $profileResponse.CertificateSha256 -cne $identity.CertificateSha256 -or $profileResponse.GatewayHost -cne $Trust.GatewayHost -or $profileResponse.GatewayPort -cne $Trust.GatewayPort -or $profileResponse.VncPassword -cnotmatch '^[\x21-\x7e]{8}$'){throw 'RemoteInstallationProfileMismatch';}
  Assert-PdvIdentityNoRemoteProcesses;
  $ini=Join-Path $bundle 'bin/ultravnc/ultravnc.ini';$marker=Join-Path $bundle 'bin/ultravnc/ultravnc.portable';
  if(-not $resuming -and ([IO.File]::Exists($ini) -or [IO.File]::Exists($marker))){throw 'RemoteInstallationProfileAlreadyExists';}
  if(-not $resuming){Write-PdvIdentityAtomic $provisioningPath (ConvertTo-PdvIdentityXml 'PdvRemoteProvisioning' @{AgentId=$identity.AgentId;CertificateSha256=$identity.CertificateSha256;MonitorUserSid=$MonitorUserSid});}
  # Only reverse, authenticated, visible support; no external listener/file transfer.
  $settings=@('UseRegistry','SocketConnect','HTTPConnect','MSLogonRequired','NewMSLogon','UseDSMPlugin','FileTransferEnabled','BlankMonitorEnabled','LocalInputsDisabled','AllowProperties','AllowEditClients','DebugMode','Avilog','EnableTLS','CloudEnabled','UseBridge','AllowInjection','UseIPv6','RdpMode','ClearConsole');
  $lines=@('[admin]');foreach($setting in $settings){$lines+=($setting+'=0');};$lines+=@('LoopbackOnly=1','AllowLoopback=1','AuthRequired=1','ReverseAuthRequired=1','InputsEnabled=1','DisableTrayIcon=0','service_commandline=','[UltraVNC]');
  Write-PdvIdentityAtomic $ini ([Text.Encoding]::ASCII.GetBytes(($lines -join "`r`n")+"`r`n")) $MonitorUserSid;
  $secretAcl=New-Object Security.AccessControl.FileSecurity;$secretAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;'+$MonitorUserSid+')');Set-Acl -LiteralPath $ini -AclObject $secretAcl -ErrorAction Stop;
  [void](Assert-PdvIdentityPath $ini $MonitorUserSid);
  try{[Conecta.PdvRemoteEnrollment.CryptoV1]::WriteVncPassword($ini,$profileResponse.VncPassword);}finally{$profileResponse.VncPassword=$null;}
  # Empty portable marker is an application-owned file, not an imported profile.
  if(-not [IO.File]::Exists($marker)){$stream=New-Object IO.FileStream($marker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Flush($true);}finally{$stream.Close();}}else{[void](Assert-PdvIdentityPath $marker);if((New-Object IO.FileInfo($marker)).Length -ne 0){throw 'RemoteInstallationMarkerChanged';}}
  $stunnel=@($approved.Files|Where-Object{$_.RelativePath -ceq 'bin/stunnel/stunnel.exe'});$vnc=@($approved.Files|Where-Object{$_.RelativePath -ceq 'bin/ultravnc/winvnc.exe'});if($stunnel.Count -ne 1 -or $vnc.Count -ne 1){throw 'RemoteInstallationBundleIncomplete';}
  $configuration=@{SchemaVersion='2';Enabled='false';ProfileApproved='true';PlatformProfile=$evidence.CompatibilityProfile;AgentId=$identity.AgentId;RepeaterId=$identity.RepeaterId;GatewayHost=$Trust.GatewayHost;GatewayPort=$Trust.GatewayPort;CertificateFile=$identity.CertificateFile;CertificateSha256=$identity.CertificateSha256;PrivateKeyFile=$identity.PrivateKeyFile;ServerCaFile=$identity.ServerCaFile;StunnelExe=$stunnel[0].Path;StunnelSha256=$stunnel[0].Sha256;StunnelSignerThumbprint=$stunnel[0].PublisherThumbprint;UltraVncExe=$vnc[0].Path;UltraVncSha256=$vnc[0].Sha256;UltraVncSignerThumbprint=$vnc[0].PublisherThumbprint;UltraVncIniFile=$ini;UltraVncIniSha256=[Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256([IO.File]::ReadAllBytes($ini));PortableMarkerFile=$marker};
  $xml=New-Object Xml.XmlDocument;$node=$xml.CreateElement('PdvRemoteWindowsPilot');[void]$xml.AppendChild($node);foreach($key in @($configuration.Keys|Sort-Object)){$child=$xml.CreateElement([string]$key);$child.InnerText=[string]$configuration[$key];[void]$node.AppendChild($child);}
  $profilePath=Join-Path $app 'piloto-remoto/windows/remoto-piloto.xml';
  if([IO.File]::Exists($profilePath)){throw 'RemoteInstallationProfileAlreadyExists';}
  # Store renewal ownership before making the executable profile available.
  $remote=[IO.Path]::GetDirectoryName($app);$maintenance=@{AgentId=$identity.AgentId;MonitorUserSid=$MonitorUserSid;IdentityDirectory=[IO.Path]::GetDirectoryName($identity.CertificateFile)};
  Write-PdvIdentityAtomic (Join-Path $remote 'identity-maintenance.xml') (ConvertTo-PdvIdentityXml 'PdvRemoteIdentityMaintenance' $maintenance);
  Write-PdvIdentityAtomic $profilePath ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml));
  return @{AgentId=$identity.AgentId;ExpiresAt=$identity.ExpiresAt;PlatformProfile=$evidence.CompatibilityProfile};
}

Export-ModuleMember -Function Invoke-PdvIdentityMaintenance,Invoke-PdvIdentityProof,Read-PdvIdentityCertificate,Test-PdvIdentityRenewalDue,Complete-PdvRemoteProvisioning;
