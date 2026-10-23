#requires -Version 2.0
# Inscricao administrativa separada da telemetria. Importar nao faz alteracoes.
$script:PdvEnrollmentDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path;
function Get-PdvEnrollmentNow {return [DateTimeOffset]::UtcNow;}
function Test-PdvEnrollmentId {param($Value);return ($Value -is [string] -and $Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');}
function Assert-PdvEnrollmentPath {
  param([string]$Path,[bool]$MustExist=$true);
  if(-not $Path -or -not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path -match '[^\x20-\x7e]|["%=;#]' -or $Path.Length -gt 240){throw 'RemoteEnrollmentUnsafePath';}
  $full=[IO.Path]::GetFullPath($Path);$probe=$full;
  while($probe){if([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)){if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RemoteEnrollmentUnsafePath';}};$parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;}
  if($MustExist -and -not [IO.File]::Exists($full) -and -not [IO.Directory]::Exists($full)){throw 'RemoteEnrollmentMissingPath';};return $full;
}
function Assert-PdvEnrollmentAcl {
  param([string]$Path,[string]$MonitorUserSid='',[bool]$Ancestors=$false);
  $trusted=@('S-1-5-18','S-1-5-32-544');$write=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
  if($Ancestors){$account=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$trusted+= $account.Translate([Security.Principal.SecurityIdentifier]).Value;$write=$write -band (-bnot [int][Security.AccessControl.FileSystemRights]::Write);}
  $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop;if($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'RemoteEnrollmentUnsafeAcl';}
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
    if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;}
    if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $trusted -cnotcontains $rule.IdentityReference.Value){
      if(($rule.FileSystemRights -band $write) -ne 0 -or (-not $Ancestors -and $MonitorUserSid -and $rule.IdentityReference.Value -cne $MonitorUserSid -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -ne 0)){throw 'RemoteEnrollmentUnsafeAcl';}
    }
  }
}
function Assert-PdvEnrollmentAdministrativePath {
  param([string]$Path,[string]$MonitorUserSid='');
  $full=Assert-PdvEnrollmentPath $Path;Assert-PdvEnrollmentAcl $full $MonitorUserSid;
  $parent=[IO.Path]::GetDirectoryName($full);if($parent){Assert-PdvEnrollmentAcl $parent;$probe=[IO.Path]::GetDirectoryName($parent);while($probe){Assert-PdvEnrollmentAcl $probe '' $true;$next=[IO.Path]::GetDirectoryName($probe);if($next -ceq $probe){break;};$probe=$next;}}
  return $full;
}
function Assert-PdvEnrollmentAdministrator {
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Environment]::Version.Major -ne 4){throw 'RemoteEnrollmentWindowsClr4Required';}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$principal=New-Object Security.Principal.WindowsPrincipal($identity);if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'RemoteEnrollmentAdministratorRequired';}}finally{$identity.Dispose();}
  $runtime=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop;if($runtime.Release -lt 394802){throw 'RemoteEnrollmentDotNet462Required';}
}
function Initialize-PdvEnrollmentCrypto {
  Assert-PdvEnrollmentAdministrator;
  foreach($leaf in @('PdvMonitor.Remoto.Inscricao.psm1','piloto-remoto/windows/RemoteEnrollmentCrypto.cs','piloto-remoto/windows/RemoteEnrollmentStorage.cs')){[void](Assert-PdvEnrollmentAdministrativePath (Join-Path $script:PdvEnrollmentDirectory $leaf));}
  if($null -eq ('Conecta.PdvRemoteEnrollment.CryptoV1' -as [type])){Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:PdvEnrollmentDirectory 'piloto-remoto/windows/RemoteEnrollmentCrypto.cs'))) -Language CSharp -ErrorAction Stop;}
  if($null -eq ('Conecta.PdvRemoteEnrollment.StorageV1' -as [type])){Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:PdvEnrollmentDirectory 'piloto-remoto/windows/RemoteEnrollmentStorage.cs'))) -Language CSharp -ErrorAction Stop;}
}
function Read-PdvEnrollmentBytes {
  param([string]$Path,[int]$Maximum=32768);
  $stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($stream.SafeFileHandle);if($stream.Length -lt 1 -or $stream.Length -gt $Maximum){throw 'RemoteEnrollmentFileSize';};$bytes=New-Object byte[] ([int]$stream.Length);$offset=0;while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -le 0){throw 'RemoteEnrollmentReadFailed';};$offset+=$read;};[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($stream.SafeFileHandle);return ,$bytes;}finally{$stream.Close();}
}
function Write-PdvEnrollmentNewFile {
  param([string]$Path,[byte[]]$Bytes);
  $stream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($stream.SafeFileHandle);$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true);}finally{$stream.Close();}
}
function Read-PdvEnrollmentXml {
  param([byte[]]$Bytes,[string]$RootName,[string[]]$Fields,[int]$Maximum=32768);
  try{
    if($Bytes.Length -gt $Maximum){throw 'Invalid';};$encoding=New-Object Text.UTF8Encoding($false,$true);$text=$encoding.GetString($Bytes).TrimStart([char]0xfeff);if($text -match '<!DOCTYPE|<!ENTITY'){throw 'Invalid';}
    $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.LoadXml($text);$root=$xml.DocumentElement;
    foreach($child in $xml.ChildNodes){if(@([Xml.XmlNodeType]::XmlDeclaration,[Xml.XmlNodeType]::Element)-notcontains $child.NodeType){throw 'Invalid';}}
    if($root.Name -cne $RootName -or $root.NamespaceURI -or $root.Attributes.Count -ne 1 -or $root.GetAttribute('schemaVersion') -cne '1'){throw 'Invalid';}
    $values=@{};foreach($node in $root.ChildNodes){if($node.NodeType -eq [Xml.XmlNodeType]::Whitespace){continue;};if($node.NodeType -ne [Xml.XmlNodeType]::Element -or $node.NamespaceURI -or $Fields -cnotcontains $node.Name -or $values.Contains($node.Name) -or $node.Attributes.Count -ne 0 -or $node.ChildNodes.Count -gt 1 -or ($node.ChildNodes.Count -eq 1 -and $node.FirstChild.NodeType -ne [Xml.XmlNodeType]::Text)){throw 'Invalid';};$values[$node.Name]=$node.InnerText;}
    if($values.Count -ne $Fields.Count){throw 'Invalid';};return $values;
  }catch{throw 'RemoteEnrollmentInvalidXml';}
}
function New-PdvEnrollmentXml {
  param([string]$RootName,$Values);
  $xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement($RootName);$root.SetAttribute('schemaVersion','1');[void]$xml.AppendChild($root);foreach($key in @($Values.Keys | Sort-Object)){$node=$xml.CreateElement([string]$key);$node.InnerText=[string]$Values[$key];[void]$root.AppendChild($node);};return ,([Text.Encoding]::UTF8.GetBytes($xml.OuterXml));
}
function Read-PdvMonitorRemoteEnrollmentTrust {
  param([string]$Path);
  Initialize-PdvEnrollmentCrypto;[void](Assert-PdvEnrollmentAdministrativePath $Path);
  $fields=@('ApiEnrollmentUrl','GatewayHost','GatewayPort','ServerCaFile','ServerCaSha256','DeviceCaFile','DeviceCaSha256');$trust=Read-PdvEnrollmentXml (Read-PdvEnrollmentBytes $Path) 'PdvRemoteEnrollmentTrust' $fields;
  $uri=$null;if(-not [Uri]::TryCreate($trust.ApiEnrollmentUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/api/pdv-monitor/remote-enrollment' -or $uri.Port -ne 443 -or $trust.GatewayHost -cnotmatch '^(?=.{4,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$' -or $trust.GatewayHost.EndsWith('.invalid') -or $trust.GatewayHost -cmatch '^[0-9.]+$' -or $trust.GatewayPort -cnotmatch '^[1-9][0-9]{3,4}$' -or [int]$trust.GatewayPort -gt 65535){throw 'RemoteEnrollmentInvalidTrust';}
  if($trust.ServerCaFile -cne 'identity-server-ca.crt' -or $trust.DeviceCaFile -cne 'identity-device-ca.crt'){throw 'RemoteEnrollmentInvalidTrust';}
  foreach($kind in @('Server','Device')){
    $pin=[string]$trust[($kind+'CaSha256')];if($pin -cnotmatch '^[a-f0-9]{64}$'){throw 'RemoteEnrollmentInvalidTrust';};$caPath=Join-Path ([IO.Path]::GetDirectoryName($Path)) $trust[($kind+'CaFile')];[void](Assert-PdvEnrollmentAdministrativePath $caPath);$caPem=[Text.Encoding]::ASCII.GetString((Read-PdvEnrollmentBytes $caPath 16384));$der=[Conecta.PdvRemoteEnrollment.CryptoV1]::ReadPem($caPem,'CERTIFICATE',16384);if([Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256($der) -cne $pin){throw 'RemoteEnrollmentTrustPinMismatch';};$trust[($kind+'CaPem')]=$caPem;
  };return $trust;
}
function New-PdvMonitorRemoteEnrollmentRequest {
  param([string]$IdentityDirectory,[string]$AgentId,[string]$RequestId,[string]$MonitorUserSid);
  Initialize-PdvEnrollmentCrypto;
  if(-not (Test-PdvEnrollmentId $AgentId) -or -not (Test-PdvEnrollmentId $RequestId) -or $MonitorUserSid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'RemoteEnrollmentInvalidIdentity';}
  $full=Assert-PdvEnrollmentPath $IdentityDirectory $false;$parent=[IO.Path]::GetDirectoryName($full);[void](Assert-PdvEnrollmentAdministrativePath $parent);
  $statePath=Join-Path $full 'request.xml';$csrPath=Join-Path $full 'request.csr';$keyPath=Join-Path $full 'client-private.key';
  if([IO.Directory]::Exists($full)){
    [void](Assert-PdvEnrollmentAdministrativePath $full $MonitorUserSid);foreach($path in @($statePath,$csrPath,$keyPath)){[void](Assert-PdvEnrollmentAdministrativePath $path $MonitorUserSid);}
    $state=Read-PdvEnrollmentXml (Read-PdvEnrollmentBytes $statePath) 'PdvRemoteEnrollmentPending' @('AgentId','RequestId','MonitorUserSid','PublicKeySha256');
    if($state.AgentId -cne $AgentId -or $state.MonitorUserSid -cne $MonitorUserSid -or -not (Test-PdvEnrollmentId $state.RequestId)){throw 'RemoteEnrollmentIdentityMismatch';}
    $csr=[Text.Encoding]::ASCII.GetString((Read-PdvEnrollmentBytes $csrPath 8192));$hash=[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateRequest($csr,$AgentId);if($hash -cne $state.PublicKeySha256){throw 'RemoteEnrollmentPendingChanged';}
    # Nunca gera uma segunda chave apos timeout. O requestId existente e o idempotente.
    return @{AgentId=$AgentId;RequestId=$state.RequestId;CsrPem=$csr;PublicKeySha256=$hash;MonitorUserSid=$MonitorUserSid;IdentityDirectory=$full;PrivateKeyFile=$keyPath};
  }
  if([IO.File]::Exists($full)){throw 'RemoteEnrollmentUnsafePath';}
  [Conecta.PdvRemoteEnrollment.StorageV1]::CreateDirectoryForUser($full,$MonitorUserSid);[void](Assert-PdvEnrollmentAdministrativePath $full $MonitorUserSid);
  $request=[Conecta.PdvRemoteEnrollment.CryptoV1]::GenerateWindows($keyPath,$AgentId,$RequestId);
  Write-PdvEnrollmentNewFile $csrPath ([Text.Encoding]::ASCII.GetBytes($request.CsrPem));Write-PdvEnrollmentNewFile $statePath (New-PdvEnrollmentXml 'PdvRemoteEnrollmentPending' @{AgentId=$AgentId;RequestId=$RequestId;MonitorUserSid=$MonitorUserSid;PublicKeySha256=$request.PublicKeySha256});
  foreach($path in @($statePath,$csrPath,$keyPath)){[void](Assert-PdvEnrollmentAdministrativePath $path $MonitorUserSid);}
  return @{AgentId=$AgentId;RequestId=$RequestId;CsrPem=$request.CsrPem;PublicKeySha256=$request.PublicKeySha256;MonitorUserSid=$MonitorUserSid;IdentityDirectory=$full;PrivateKeyFile=$keyPath};
}
function ConvertTo-PdvEnrollmentJsonString {
  param([string]$Value);
  $builder=New-Object Text.StringBuilder;[void]$builder.Append('"');foreach($character in $Value.ToCharArray()){switch([int]$character){34{[void]$builder.Append('\"');break;}92{[void]$builder.Append('\\');break;}default{if([int]$character -lt 32){[void]$builder.Append(('\u{0:x4}' -f [int]$character));}else{[void]$builder.Append($character);}}}};[void]$builder.Append('"');return $builder.ToString();
}
function Invoke-PdvEnrollmentHttp {
  param([string]$Endpoint,[byte[]]$Body);
  $response=$null;$stream=$null;$reader=$null;$oldProtocol=[Net.ServicePointManager]::SecurityProtocol;$ownsTls=$false;$tlsLock=[Net.ServicePointManager];
  try{
    if($null -ne [Net.ServicePointManager]::ServerCertificateValidationCallback){throw 'RemoteEnrollmentTlsValidationOverride';}
    $ownsTls=[Threading.Monitor]::TryEnter($tlsLock,2000);if(-not $ownsTls){throw 'RemoteEnrollmentTransportUnavailable';};$oldProtocol=[Net.ServicePointManager]::SecurityProtocol;[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]3072;
    $request=[Net.WebRequest]::Create($Endpoint);$request.Method='POST';$request.Accept='application/xml';$request.ContentType='application/json; charset=utf-8';$request.AllowAutoRedirect=$false;$request.Timeout=15000;$request.ReadWriteTimeout=15000;$request.UseDefaultCredentials=$false;$request.ContentLength=$Body.Length;
    $stream=$request.GetRequestStream();$stream.Write($Body,0,$Body.Length);$stream.Close();$stream=$null;$response=$request.GetResponse();if(@(200,201) -notcontains [int]$response.StatusCode -or [string]$response.ContentType -notmatch '^application/xml(?:;|$)' -or $response.ContentLength -gt 32768){throw 'RemoteEnrollmentTransportRejected';}
    $reader=$response.GetResponseStream();$output=New-Object IO.MemoryStream;try{$buffer=New-Object byte[] 2048;while(($read=$reader.Read($buffer,0,$buffer.Length)) -gt 0){if($output.Length+$read -gt 32768){throw 'RemoteEnrollmentResponseTooLarge';};$output.Write($buffer,0,$read);};return ,$output.ToArray();}finally{$output.Close();}
  }catch [Net.WebException]{throw 'RemoteEnrollmentTransportRejectedOrUnavailable';}finally{if($null -ne $stream){$stream.Close();};if($null -ne $reader){$reader.Close();};if($null -ne $response){$response.Close();};if($ownsTls){try{[Net.ServicePointManager]::SecurityProtocol=$oldProtocol;}finally{[Threading.Monitor]::Exit($tlsLock);}}}
}
function Complete-PdvMonitorRemoteEnrollment {
  param($Request,$Trust,[byte[]]$ResponseBytes);
  Initialize-PdvEnrollmentCrypto;
  $response=Read-PdvEnrollmentXml $ResponseBytes 'PdvRemoteEnrollment' @('RequestId','AgentId','CertificatePem','CertificateSha256','ExpiresAt','GatewayHost','GatewayPort','RepeaterId');
  if($response.RequestId -cne $Request.RequestId -or $response.AgentId -cne $Request.AgentId -or $response.GatewayHost -cne $Trust.GatewayHost -or $response.GatewayPort -cne $Trust.GatewayPort -or $response.RepeaterId -cnotmatch '^[1-9][0-9]{0,8}$' -or $response.CertificateSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'RemoteEnrollmentResponseMismatch';}
  $verified=[Conecta.PdvRemoteEnrollment.CryptoV1]::ValidateCertificate($response.CertificatePem,$Trust.DeviceCaPem,$Trust.DeviceCaSha256,$Request.AgentId,$Request.PublicKeySha256,(Get-PdvEnrollmentNow).UtcDateTime);
  try{$expires=[DateTimeOffset]::ParseExact($response.ExpiresAt,'yyyy-MM-ddTHH:mm:ss.fffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal);}catch{throw 'RemoteEnrollmentInvalidExpiry';}
  if($verified.CertificateSha256 -cne $response.CertificateSha256 -or $expires.UtcDateTime -ne [DateTime]::Parse($verified.NotAfter,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()){throw 'RemoteEnrollmentCertificateMismatch';}
  [void](Assert-PdvEnrollmentAdministrativePath $Request.IdentityDirectory $Request.MonitorUserSid);[void](Assert-PdvEnrollmentAdministrativePath $Request.PrivateKeyFile $Request.MonitorUserSid);
  $certPath=Join-Path $Request.IdentityDirectory 'client-certificate.pem';$caPath=Join-Path $Request.IdentityDirectory 'identity-server-ca.crt';$resultPath=Join-Path $Request.IdentityDirectory 'certificate.xml';
  $result=@{AgentId=$response.AgentId;RequestId=$response.RequestId;CertificateFile=$certPath;CertificateSha256=$verified.CertificateSha256;ExpiresAt=$response.ExpiresAt;GatewayHost=$response.GatewayHost;GatewayPort=$response.GatewayPort;RepeaterId=$response.RepeaterId;PrivateKeyFile=$Request.PrivateKeyFile;ServerCaFile=$caPath};
  foreach($entry in @(@{Path=$certPath;Bytes=[Text.Encoding]::ASCII.GetBytes($response.CertificatePem)},@{Path=$caPath;Bytes=[Text.Encoding]::ASCII.GetBytes($Trust.ServerCaPem)},@{Path=$resultPath;Bytes=(New-PdvEnrollmentXml 'PdvRemoteEnrollmentCertificate' $result)})){
    if([IO.File]::Exists($entry.Path)){[void](Assert-PdvEnrollmentAdministrativePath $entry.Path $Request.MonitorUserSid);if([Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256((Read-PdvEnrollmentBytes $entry.Path)) -cne [Conecta.PdvRemoteEnrollment.CryptoV1]::Sha256($entry.Bytes)){throw 'RemoteEnrollmentExistingIdentityDifferent';}}
    else{Write-PdvEnrollmentNewFile $entry.Path $entry.Bytes;};[void](Assert-PdvEnrollmentAdministrativePath $entry.Path $Request.MonitorUserSid);
  }
  # Certificado pronto; nenhum perfil executavel foi modificado ou aprovado.
  return $result;
}
function Invoke-PdvMonitorRemoteEnrollment {
  param($Request,$Trust,[Security.SecureString]$ActivationCode);
  $pointer=[IntPtr]::Zero;$code=$null;$body=$null;
  try{
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($ActivationCode);$code=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);
    if($code -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.[A-Za-z0-9_-]{43}$' -or $code.Substring(0,36) -cne $Request.AgentId){throw 'RemoteEnrollmentActivationIdentityMismatch';}
    $json='{"schemaVersion":1,"requestId":'+(ConvertTo-PdvEnrollmentJsonString $Request.RequestId)+',"activationCode":'+(ConvertTo-PdvEnrollmentJsonString $code)+',"csrPem":'+(ConvertTo-PdvEnrollmentJsonString $Request.CsrPem)+'}';$body=[Text.Encoding]::UTF8.GetBytes($json);$json=$null;
    $response=Invoke-PdvEnrollmentHttp $Trust.ApiEnrollmentUrl $body;return (Complete-PdvMonitorRemoteEnrollment $Request $Trust $response);
  }finally{if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);};if($null -ne $body){[Array]::Clear($body,0,$body.Length);};$code=$null;}
}
Export-ModuleMember -Function Read-PdvMonitorRemoteEnrollmentTrust,New-PdvMonitorRemoteEnrollmentRequest,Invoke-PdvMonitorRemoteEnrollment,Complete-PdvMonitorRemoteEnrollment;
