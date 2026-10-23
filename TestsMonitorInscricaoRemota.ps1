#requires -Version 7.0
# Offline: chaves e autoridades EFEMERAS de teste. Nao consulta CAs reais nem Windows.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Add-Type -Path (Join-Path $directory 'piloto-remoto/windows/RemoteEnrollmentCrypto.cs');Import-Module (Join-Path $directory 'PdvMonitor.Remoto.Inscricao.psm1') -Force;$module=Get-Module PdvMonitor.Remoto.Inscricao;
$script:Count=0;function Assert-Test($Value,[string]$Message){$script:Count++;if(-not $Value){throw $Message;}}
function Assert-Throws([scriptblock]$Body,[string]$Code){$script:Count++;try{& $Body|Out-Null;}catch{if($_.Exception.Message.Contains($Code)){return;};throw ('Unexpected exception: '+$_.Exception.Message);};throw ('Missing exception: '+$Code);}
$agent='11111111-1111-4111-8111-111111111111';$requestId='22222222-2222-4222-8222-222222222222';$now=[DateTimeOffset]::UtcNow;
$key=[Security.Cryptography.RSA]::Create(2048);$testRoot=[IO.Path]::GetTempPath();if([IO.Directory]::Exists('/private/tmp')){$testRoot='/private/tmp';};$temporary=Join-Path $testRoot ('pdv-enrollment-tests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
try{
  $request=[Conecta.PdvRemoteEnrollment.CryptoV1]::CreateRequest($key,$agent,$requestId);Assert-Test ($request.CsrPem.StartsWith('-----BEGIN CERTIFICATE REQUEST-----')) 'CSR PEM';Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateRequest($request.CsrPem,$agent) -ceq $request.PublicKeySha256) 'CSR signature roundtrip';Assert-Test (-not $request.CsrPem.Contains('PRIVATE')) 'No private export';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateRequest($request.CsrPem,'33333333-3333-4333-8333-333333333333')} 'RemoteEnrollmentInvalidCsr';
  $csrDer=[Conecta.PdvRemoteEnrollment.CryptoV1]::ReadPem($request.CsrPem,'CERTIFICATE REQUEST',8192);$csrDer[$csrDer.Length-1]=$csrDer[$csrDer.Length-1] -bxor 1;Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateRequest([Conecta.PdvRemoteEnrollment.CryptoV1]::Pem('CERTIFICATE REQUEST',$csrDer),$agent)} 'RemoteEnrollmentInvalidCsr';
  [IO.File]::WriteAllText((Join-Path $temporary 'request.csr'),$request.CsrPem,[Text.Encoding]::ASCII);
  & python3 (Join-Path $directory 'tests/create_enrollment_fixtures.py') $temporary;if($LASTEXITCODE -ne 0){throw 'Ephemeral fixture generation failed';};$now=[DateTimeOffset]::UtcNow;
  $rootPem=[IO.File]::ReadAllText((Join-Path $temporary 'root.crt'));$rootPin=[Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256([Conecta.PdvRemoteEnrollment.CryptoV1]::ReadPem($rootPem,'CERTIFICATE',16384));
  $issuerPem=[IO.File]::ReadAllText((Join-Path $temporary 'intermediate.crt'));$leafPem=[IO.File]::ReadAllText((Join-Path $temporary 'leaf.crt'));$leafRaw=[Conecta.PdvRemoteEnrollment.CryptoV1]::ReadPem($leafPem,'CERTIFICATE',16384);$chainPem=$leafPem+$issuerPem;
  $valid=[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime);Assert-Test ($valid.CertificateSha256 -ceq [Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256($leafRaw)) 'Fullchain verified';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($leafPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentInvalidIssuer';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem,$rootPem,('a'*64),$agent,$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentIssuerPinMismatch';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem,$rootPem,$rootPin,$agent,('b'*64),$now.UtcDateTime)} 'RemoteEnrollmentCertificateKeyMismatch';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem,$rootPem,$rootPin,'33333333-3333-4333-8333-333333333333',$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentCertificateIdentityMismatch';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem+$rootPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentInvalidChain';
  Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($chainPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.AddDays(91).UtcDateTime)} 'RemoteEnrollmentCertificateValidity';
  $tampered=[byte[]]$leafRaw.Clone();$tampered[$tampered.Length-1]=$tampered[$tampered.Length-1] -bxor 1;Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate(([Conecta.PdvRemoteEnrollment.CryptoV1]::Pem('CERTIFICATE',$tampered))+$issuerPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentCertificateSignatureInvalid';
  foreach($option in @('server','extra')){$badPem=[IO.File]::ReadAllText((Join-Path $temporary ($option+'.crt')));Assert-Throws {[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($badPem+$issuerPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime)} 'RemoteEnrollmentInvalidCertificate';}
  $directPem=[IO.File]::ReadAllText((Join-Path $temporary 'direct.crt'));Assert-Test ([Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($directPem,$rootPem,$rootPin,$agent,$request.PublicKeySha256,$now.UtcDateTime).CertificateSha256.Length -eq 64) 'Direct root leaf accepted';
  $json=& $module {ConvertTo-PdvEnrollmentJsonString "test`r`n\`"value";};Assert-Test (($json|ConvertFrom-Json) -ceq "test`r`n\`"value") 'PS2 JSON escaping';
  $xml='<PdvRemoteEnrollment schemaVersion="1"><AgentId>x</AgentId></PdvRemoteEnrollment>';$values=& $module {param($Bytes);Read-PdvEnrollmentXml $Bytes 'PdvRemoteEnrollment' @('AgentId');} ([Text.Encoding]::UTF8.GetBytes($xml));Assert-Test ($values.AgentId -ceq 'x') 'Closed XML accepted';
  foreach($invalid in @($xml.Replace('</PdvRemoteEnrollment>','<Extra>bad</Extra></PdvRemoteEnrollment>'),$xml.Replace('</PdvRemoteEnrollment>','<AgentId>x</AgentId></PdvRemoteEnrollment>'),('<!DOCTYPE x [<!ENTITY attack SYSTEM "file:///NEVER-READ">]>'+$xml),$xml.Replace('<AgentId>x</AgentId>','<AgentId><Nested>x</Nested></AgentId>'))){Assert-Throws {& $module {param($Bytes);Read-PdvEnrollmentXml $Bytes 'PdvRemoteEnrollment' @('AgentId');} ([Text.Encoding]::UTF8.GetBytes($invalid));} 'RemoteEnrollmentInvalidXml';}
  # Fronteira Windows/rede e simulada: somente arquivos sinteticos em diretorio temporario.
  & $module {
    $script:NetworkCalls=0;$script:CompletionCalls=0;
    function script:Initialize-PdvEnrollmentCrypto {}
    function script:Assert-PdvEnrollmentAdministrativePath {param($Path,$MonitorUserSid);return $Path;}
    function script:Read-PdvEnrollmentBytes {param($Path,$Maximum);return ,([IO.File]::ReadAllBytes($Path));}
    function script:Write-PdvEnrollmentNewFile {param($Path,$Bytes);[IO.File]::WriteAllBytes($Path,$Bytes);}
  }
  $identityPath=Join-Path $temporary 'identity';[void][IO.Directory]::CreateDirectory($identityPath);$privatePath=Join-Path $identityPath 'client-private.key';[IO.File]::WriteAllText($privatePath,'NOT-A-REAL-PRIVATE-KEY');
  $pending=@{AgentId=$agent;RequestId=$requestId;CsrPem=$request.CsrPem;PublicKeySha256=$request.PublicKeySha256;MonitorUserSid='S-1-5-21-1-2-3-1001';IdentityDirectory=$identityPath;PrivateKeyFile=$privatePath};$trust=@{DeviceCaPem=$rootPem;DeviceCaSha256=$rootPin;GatewayHost='pilot.example.com';GatewayPort='5443';ServerCaPem=$rootPem;ApiEnrollmentUrl='https://pilot.example.com/api/pdv-monitor/remote-enrollment'};
  $leafCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($leafRaw);try{$expires=$leafCertificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ');}finally{$leafCertificate.Dispose();}
  $response=@{RequestId=$requestId;AgentId=$agent;CertificatePem=$chainPem;CertificateSha256=[Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256($leafRaw);ExpiresAt=$expires;GatewayHost='pilot.example.com';GatewayPort='5443';RepeaterId='4901'};
  function New-TestResponseBytes($Values){return ,(& $module {param($Values);New-PdvEnrollmentXml 'PdvRemoteEnrollment' $Values;} $Values);}
  foreach($field in @('RequestId','AgentId','GatewayHost','GatewayPort','RepeaterId','CertificateSha256','ExpiresAt')){
    $badResponse=$response.Clone();switch($field){'RequestId'{$badResponse[$field]='33333333-3333-4333-8333-333333333333';}'AgentId'{$badResponse[$field]='33333333-3333-4333-8333-333333333333';}'GatewayHost'{$badResponse[$field]='attacker.example.com';}'GatewayPort'{$badResponse[$field]='443';}'RepeaterId'{$badResponse[$field]='4901;exec';}'CertificateSha256'{$badResponse[$field]='f'*64;}'ExpiresAt'{$badResponse[$field]='2027-01-01T00:00:00.000Z';}}
    $expected='RemoteEnrollmentResponseMismatch';if(@('CertificateSha256','ExpiresAt') -contains $field){$expected='RemoteEnrollmentCertificateMismatch';}
    Assert-Throws {Complete-PdvMonitorRemoteEnrollment $pending $trust (New-TestResponseBytes $badResponse)} $expected;
    Assert-Test (-not [IO.File]::Exists((Join-Path $identityPath 'client-certificate.pem'))) 'Bad response wrote certificate';
  }
  $result=Complete-PdvMonitorRemoteEnrollment $pending $trust (New-TestResponseBytes $response);Assert-Test ([IO.File]::ReadAllText($result.CertificateFile) -ceq $chainPem) 'Valid certificate saved';Assert-Test ([IO.File]::ReadAllText($privatePath) -ceq 'NOT-A-REAL-PRIVATE-KEY') 'Private key was altered';Assert-Test (-not [IO.File]::Exists((Join-Path $identityPath 'remoto-piloto.xml'))) 'Certificate enabled executable profile';
  $repeat=Complete-PdvMonitorRemoteEnrollment $pending $trust (New-TestResponseBytes $response);Assert-Test ($repeat.CertificateSha256 -ceq $result.CertificateSha256) 'Idempotent certificate retry failed';
  $state=@{AgentId=$agent;RequestId=$requestId;MonitorUserSid=$pending.MonitorUserSid;PublicKeySha256=$request.PublicKeySha256};[IO.File]::WriteAllBytes((Join-Path $identityPath 'request.xml'),(& $module {param($State);New-PdvEnrollmentXml 'PdvRemoteEnrollmentPending' $State;} $state));[IO.File]::WriteAllText((Join-Path $identityPath 'request.csr'),$request.CsrPem,[Text.Encoding]::ASCII);
  $resume=New-PdvMonitorRemoteEnrollmentRequest $identityPath $agent '33333333-3333-4333-8333-333333333333' $pending.MonitorUserSid;Assert-Test ($resume.RequestId -ceq $requestId -and $resume.PublicKeySha256 -ceq $request.PublicKeySha256) 'Retry generated a different key or request';
  Assert-Throws {New-PdvMonitorRemoteEnrollmentRequest $identityPath '33333333-3333-4333-8333-333333333333' $requestId $pending.MonitorUserSid} 'RemoteEnrollmentIdentityMismatch';
  Assert-Throws {New-PdvMonitorRemoteEnrollmentRequest $identityPath $agent $requestId 'S-1-1-0'} 'RemoteEnrollmentInvalidIdentity';
  & $module {function script:Invoke-PdvEnrollmentHttp {param($Endpoint,$Body);$script:NetworkCalls++;throw 'UnexpectedNetwork';}}
  $wrongCode=ConvertTo-SecureString ('33333333-3333-4333-8333-333333333333.'+('a'*43)) -AsPlainText -Force;try{Assert-Throws {Invoke-PdvMonitorRemoteEnrollment $pending $trust $wrongCode} 'RemoteEnrollmentActivationIdentityMismatch';}finally{$wrongCode.Dispose();};Assert-Test ((& $module {$script:NetworkCalls;}) -eq 0) 'Invalid activation reached network';
  & $module {
    param($Response);
    $script:TestResponse=$Response;$script:BodyAfterRequest=$null;$script:SentPublic=$null;
    function script:Invoke-PdvEnrollmentHttp {param($Endpoint,$Body);$script:NetworkCalls++;$script:BodyAfterRequest=$Body;$parsed=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json);$script:SentPublic=@{Endpoint=$Endpoint;RequestId=$parsed.requestId;Schema=$parsed.schemaVersion;HasPublicCsr=$parsed.csrPem.StartsWith('-----BEGIN CERTIFICATE REQUEST-----');HasOnlyExpected=(@($parsed.PSObject.Properties.Name).Count -eq 4);CodeWellFormed=($parsed.activationCode -cmatch '^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$')};return ,$script:TestResponse;}
  } (New-TestResponseBytes $response);
  $code=ConvertTo-SecureString ($agent+'.'+('a'*43)) -AsPlainText -Force;try{$activated=Invoke-PdvMonitorRemoteEnrollment $pending $trust $code;}finally{$code.Dispose();}
  $sent=& $module {$script:SentPublic;};Assert-Test ($sent.Endpoint -ceq $trust.ApiEnrollmentUrl -and $sent.RequestId -ceq $requestId -and $sent.Schema -eq 1 -and $sent.HasPublicCsr -and $sent.HasOnlyExpected -and $sent.CodeWellFormed) 'Activation wire contract differs';Assert-Test ((& $module {@($script:BodyAfterRequest|Where-Object{$_ -ne 0}).Count;}) -eq 0) 'Activation request body retained code';Assert-Test ($activated.AgentId -ceq $agent) 'Activation result identity differs';
  $parseErrors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'PdvMonitor.Remoto.Inscricao.psm1'),[ref]$null,[ref]$parseErrors)|Out-Null;Assert-Test ($parseErrors.Count -eq 0) 'Module parse';
  Write-Output ('OK: '+$script:Count+' verificacoes offline. Windows/ACL/CSP/TLS reais ainda exigem homologacao no Windows 7/10.');
}finally{$key.Dispose();if([IO.Directory]::Exists($temporary)){[IO.Directory]::Delete($temporary,$true);}}
