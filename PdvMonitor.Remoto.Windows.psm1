#requires -Version 2.0
# Adaptador LOCAL do piloto, separado da distribuicao e desabilitado por padrao.
# Nada e instalado, iniciado ou alterado ao importar este modulo.

$script:RemoteWindowsModuleDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path;

function Test-PdvRemoteWindowsFields {
  param($Object,[string[]]$Fields);
  if($Object -isnot [Collections.IDictionary] -or $Object.Count -ne $Fields.Count){return $false;}
  foreach($key in $Object.Keys){if($Fields -cnotcontains [string]$key){return $false;}};return $true;
}
function Test-PdvRemoteWindowsId {param($Value);return ($Value -is [string] -and $Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');}
function Get-PdvRemoteWindowsNow {return [DateTimeOffset]::UtcNow;}
function Test-PdvRemoteWindowsUiThread {return ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA);}
function ConvertTo-PdvRemoteWindowsDate {
  param($Value);
  if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$'){throw 'RemoteWindowsInvalidDate';}
  try{return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None).ToUniversalTime();}catch{throw 'RemoteWindowsInvalidDate';}
}
function Get-PdvRemoteWindowsHash {
  param([byte[]]$Bytes);
  $algorithm=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant();}finally{$algorithm.Dispose();}
}
function Test-PdvRemoteWindowsLocalPath {
  param([string]$Path,[bool]$Directory=$false);
  # Validate literal input before .NET Framework path APIs, which throw on controls.
  if(-not $Path -or $Path.StartsWith('\\') -or $Path -match '[^\x20-\x7e]|["%=;#]' -or $Path.Length -gt 240){throw 'RemoteWindowsUnsafePath';}
  try{if(-not [IO.Path]::IsPathRooted($Path)){throw 'RemoteWindowsUnsafePath';};$full=[IO.Path]::GetFullPath($Path);}catch{throw 'RemoteWindowsUnsafePath';}
  $probe=$full;
  while($probe){
    if([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)){
      if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RemoteWindowsUnsafePath';}
    };$parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;
  }
  if($Directory){if(-not [IO.Directory]::Exists($full)){throw 'RemoteWindowsDirectoryMissing';}}
  elseif(-not [IO.File]::Exists($full)){throw 'RemoteWindowsFileMissing';}
  return $full;
}
function Test-PdvRemoteWindowsProtectedAcl {
  param([string]$Path,[bool]$Private=$false);
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'RemoteWindowsUnavailable';}
  # O atual usuario, SYSTEM e administradores locais sao as unicas identidades com escrita.
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
  $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop;
  $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;
  if(@($identity,'S-1-5-18','S-1-5-32-544') -cnotcontains $owner){throw 'RemoteWindowsUnsafeAcl';}
  $write=Get-PdvRemoteWindowsWriteRights;
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
    if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and (($rule.FileSystemRights -band $write) -ne 0 -or ($Private -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -ne 0)) -and @($identity,'S-1-5-18','S-1-5-32-544') -cnotcontains $rule.IdentityReference.Value){throw 'RemoteWindowsUnsafeAcl';}
  };return $true;
}
function Get-PdvRemoteWindowsWriteRights {
  # Modify inclui leitura/execucao; usa-lo como mascara recusaria ate leitores autorizados.
  return ([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership);
}
function Test-PdvRemoteWindowsAdministrativeAcl {
  param([string]$Path);
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'RemoteWindowsUnavailable';}
  $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop;$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;
  if(@('S-1-5-18','S-1-5-32-544') -cnotcontains $owner){throw 'RemoteWindowsAdministrativeProfileRequired';}
  $write=Get-PdvRemoteWindowsWriteRights;
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $write) -ne 0 -and @('S-1-5-18','S-1-5-32-544') -cnotcontains $rule.IdentityReference.Value){throw 'RemoteWindowsAdministrativeProfileRequired';}}
  return $true;
}
function Test-PdvRemoteWindowsAdministrativeFile {
  param([string]$Path);
  [void](Test-PdvRemoteWindowsLocalPath $Path);[void](Test-PdvRemoteWindowsAdministrativeAcl $Path);[void](Test-PdvRemoteWindowsAdministrativeAcl ([IO.Path]::GetDirectoryName($Path)));[void](Test-PdvRemoteWindowsAdministrativeAncestors $Path);return $true;
}
function Test-PdvRemoteWindowsAdministrativeAncestors {
  param([string]$Path);
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'RemoteWindowsUnavailable';}
  # Um pai gravavel nao pode renomear/substituir o diretorio administrativo inteiro.
  # Raizes Windows podem pertencer ao TrustedInstaller; isso nao libera arquivos do perfil.
  $installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$installerSid=$installer.Translate([Security.Principal.SecurityIdentifier]).Value;
  $trusted=@('S-1-5-18','S-1-5-32-544',$installerSid);
  $mutate=[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
  $probe=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)));
  while($probe){
    $acl=Get-Acl -LiteralPath $probe -ErrorAction Stop;if($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'RemoteWindowsAdministrativeProfileRequired';}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
      if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;}
      if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $mutate) -ne 0 -and $trusted -cnotcontains $rule.IdentityReference.Value){throw 'RemoteWindowsAdministrativeProfileRequired';}
    };$parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;
  };return $true;
}
function Get-PdvRemoteWindowsConfigurationPath {
  param([string]$DataDirectory);
  # O diretorio de estado nunca fornece confianca para um perfil executavel.
  return (Join-Path $script:RemoteWindowsModuleDirectory 'piloto-remoto/windows/remoto-piloto.xml');
}
function Get-PdvRemoteWindowsRuntimeEvidence {
  # Leitura apenas: nao instala .NET/WMF nem altera Schannel/Registro.
  $evidence=@{Detected=$false;ClrMajor=[int][Environment]::Version.Major;DotNetRelease=0};
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){return $evidence;}
  try{
    $value=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop;
    if($value.Release -is [int] -and $value.Release -gt 0){$evidence.DotNetRelease=[int]$value.Release;$evidence.Detected=$true;}
  }catch{}
  return $evidence;
}
function Test-PdvRemoteWindowsRuntimeEvidence {
  param($Evidence);
  if(-not (Test-PdvRemoteWindowsFields $Evidence @('Detected','ClrMajor','DotNetRelease')) -or $Evidence.Detected -isnot [bool] -or -not $Evidence.Detected -or $Evidence.ClrMajor -isnot [int] -or $Evidence.DotNetRelease -isnot [int]){throw 'RemoteWindowsRuntimeUnknown';}
  if($Evidence.ClrMajor -ne 4){throw 'RemoteWindowsClr4Required';}
  # .NET Framework 4.6.2 ou posterior; recomendar 4.8 no perfil Windows 7 SP1.
  if($Evidence.DotNetRelease -lt 394802){throw 'RemoteWindowsDotNetRequired';}
  return $true;
}
function Initialize-PdvRemoteWindowsNative {
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or @(4,8) -notcontains [IntPtr]::Size){throw 'RemoteWindowsUnavailable';}
  [void](Test-PdvRemoteWindowsRuntimeEvidence (Get-PdvRemoteWindowsRuntimeEvidence));
  if($null -eq ('Conecta.PdvRemotePilot.DesktopEvidence' -as [type])){
    $source=Join-Path $script:RemoteWindowsModuleDirectory 'piloto-remoto/windows/RemoteWindowsNative.cs';
    [void](Test-PdvRemoteWindowsAdministrativeFile (Join-Path $script:RemoteWindowsModuleDirectory 'PdvMonitor.Remoto.Windows.psm1'));
    [void](Test-PdvRemoteWindowsAdministrativeFile $source);
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)) -Language CSharp -ErrorAction Stop;
  }
}
function Get-PdvRemoteWindowsNativeEvidence {
  Initialize-PdvRemoteWindowsNative;
  return [Conecta.PdvRemotePilot.DesktopEvidence]::Read();
}
function Get-PdvMonitorRemoteWindowsInteractiveEvidence {
  try{
    $evidence=Get-PdvRemoteWindowsNativeEvidence;
    return @{Supported=[bool]$evidence.Supported;Interactive=[bool]$evidence.Interactive;Unlocked=[bool]$evidence.Unlocked;WindowsSessionId=[string]$evidence.WindowsSessionId;UserSid=[string]$evidence.UserSid;HostInstanceId=[string]$evidence.HostInstanceId};
  }catch{return @{Supported=$false;Interactive=$false;Unlocked=$false;WindowsSessionId='';UserSid='';HostInstanceId=''};}
}
function Get-PdvMonitorRemoteWindowsPlatformEvidence {
  param($LocalConfiguration=$null);
  try{
    $evidence=Get-PdvRemoteWindowsNativeEvidence;$verified=$false;
    if($null -ne $LocalConfiguration -and $LocalConfiguration.Enabled -and $LocalConfiguration.ProfileApproved){[void](Test-PdvMonitorRemoteWindowsConfiguration $LocalConfiguration);$verified=[bool]$evidence.Supported;}
    return @{Detected=[bool]$evidence.Detected;WindowsVersion=[string]$evidence.WindowsVersion;Architecture=[string]$evidence.Architecture;CompatibilityVerified=$verified};
  }catch{return @{Detected=$false;WindowsVersion='';Architecture='';CompatibilityVerified=$false};}
}
function Get-PdvRemoteWindowsIdentity {
  $evidence=Get-PdvMonitorRemoteWindowsInteractiveEvidence;
  if(-not $evidence.Supported -or -not $evidence.Interactive -or -not $evidence.Unlocked -or -not $evidence.WindowsSessionId -or -not $evidence.UserSid -or -not $evidence.HostInstanceId){throw 'RemoteWindowsLocalSessionUnavailable';}
  return (Get-PdvRemoteWindowsHash ([Text.Encoding]::UTF8.GetBytes($evidence.WindowsSessionId+'|'+$evidence.UserSid+'|'+$evidence.HostInstanceId)));
}
function Get-PdvRemoteWindowsConfigurationFields {
  return @('SchemaVersion','Enabled','ProfileApproved','PlatformProfile','AgentId','RepeaterId','GatewayHost','GatewayPort','CertificateFile','CertificateSha256','PrivateKeyFile','ServerCaFile','StunnelExe','StunnelSha256','StunnelSignerThumbprint','UltraVncExe','UltraVncSha256','UltraVncSignerThumbprint','UltraVncIniFile','UltraVncIniSha256','PortableMarkerFile');
}
function Read-PdvMonitorRemoteWindowsConfiguration {
  param([string]$DataDirectory);
  $path=Get-PdvRemoteWindowsConfigurationPath $DataDirectory;
  if(-not [IO.File]::Exists($path)){return @{Enabled=$false;AgentId=''};}
  [void](Test-PdvRemoteWindowsAdministrativeFile $path);
  $reader=$null;
  try{
    if((New-Object IO.FileInfo($path)).Length -gt 16384){throw 'Invalid';}
    $settings=New-Object Xml.XmlReaderSettings;$settings.ProhibitDtd=$true;$settings.XmlResolver=$null;
    $reader=[Xml.XmlReader]::Create($path,$settings);$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);
    $root=$xml.DocumentElement;if($root.Name -cne 'PdvRemoteWindowsPilot' -or $root.NamespaceURI -cne '' -or $root.Attributes.Count -ne 0){throw 'Invalid';}
    $expected=@(Get-PdvRemoteWindowsConfigurationFields);$configuration=@{};
    foreach($child in $root.ChildNodes){
      if($child.NodeType -eq [Xml.XmlNodeType]::Whitespace -or $child.NodeType -eq [Xml.XmlNodeType]::Comment){continue;}
      if($child.NodeType -ne [Xml.XmlNodeType]::Element -or $expected -cnotcontains $child.Name -or $configuration.Contains($child.Name) -or $child.NamespaceURI -cne '' -or $child.Attributes.Count -ne 0 -or $child.ChildNodes.Count -gt 1 -or ($child.ChildNodes.Count -eq 1 -and $child.FirstChild.NodeType -ne [Xml.XmlNodeType]::Text)){throw 'Invalid';}
      $configuration[$child.Name]=$child.InnerText;
    }
    if(-not (Test-PdvRemoteWindowsFields $configuration $expected) -or $configuration.SchemaVersion -cne '2' -or @('true','false') -cnotcontains $configuration.Enabled -or @('true','false') -cnotcontains $configuration.ProfileApproved -or $configuration.GatewayPort -cnotmatch '^[1-9][0-9]{0,4}$'){throw 'Invalid';}
    $configuration.SchemaVersion=2;$configuration.Enabled=($configuration.Enabled -ceq 'true');$configuration.ProfileApproved=($configuration.ProfileApproved -ceq 'true');$configuration.GatewayPort=[int]$configuration.GatewayPort;
    [void](Test-PdvRemoteWindowsConfigurationShape $configuration);return $configuration;
  }catch{throw 'RemoteWindowsConfigurationInvalid';}finally{if($null -ne $reader){$reader.Dispose();}}
}
function Test-PdvRemoteWindowsConfigurationShape {
  param($Configuration);
  if(-not (Test-PdvRemoteWindowsFields $Configuration (Get-PdvRemoteWindowsConfigurationFields)) -or $Configuration.SchemaVersion -isnot [int] -or $Configuration.SchemaVersion -ne 2 -or $Configuration.Enabled -isnot [bool] -or $Configuration.ProfileApproved -isnot [bool] -or -not (Test-PdvRemoteWindowsId $Configuration.AgentId) -or $Configuration.RepeaterId -isnot [string] -or $Configuration.RepeaterId -cnotmatch '^[1-9][0-9]{0,8}$' -or $Configuration.GatewayPort -isnot [int] -or $Configuration.GatewayPort -lt 1024 -or $Configuration.GatewayPort -gt 65535 -or $Configuration.GatewayHost -isnot [string] -or $Configuration.GatewayHost.Length -gt 253 -or $Configuration.GatewayHost -cnotmatch '^(?=.{4,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$' -or $Configuration.GatewayHost.EndsWith('.invalid')){throw 'RemoteWindowsConfigurationInvalid';}
  if($Configuration.PlatformProfile -isnot [string] -or @('win7-sp1-x86','win7-sp1-x64','win10plus-x86','win10plus-x64') -cnotcontains $Configuration.PlatformProfile){throw 'RemoteWindowsConfigurationInvalid';}
  foreach($key in @('CertificateSha256','StunnelSha256','UltraVncSha256','UltraVncIniSha256')){if($Configuration[$key] -isnot [string] -or $Configuration[$key] -cnotmatch '^[0-9a-f]{64}$'){throw 'RemoteWindowsConfigurationInvalid';}}
  if($Configuration.GatewayHost -cmatch '^[0-9.]+$'){throw 'RemoteWindowsConfigurationInvalid';}
  foreach($key in @('StunnelSignerThumbprint','UltraVncSignerThumbprint')){if($Configuration[$key] -isnot [string] -or $Configuration[$key] -cnotmatch '^[0-9A-F]{40}$'){throw 'RemoteWindowsConfigurationInvalid';}}
  foreach($key in @('CertificateFile','PrivateKeyFile','ServerCaFile','StunnelExe','UltraVncExe','UltraVncIniFile','PortableMarkerFile')){if($Configuration[$key] -isnot [string] -or -not $Configuration[$key]){throw 'RemoteWindowsConfigurationInvalid';}}
  return $true;
}
function Test-PdvRemoteWindowsBinary {
  param([string]$Path,[string]$Sha256,[string]$SignerThumbprint,[string]$ExpectedArchitecture);
  if(@('x86','x64') -cnotcontains $ExpectedArchitecture){throw 'RemoteWindowsBinaryArchitecture';}
  $full=Test-PdvRemoteWindowsLocalPath $Path;[void](Test-PdvRemoteWindowsProtectedAcl $full);[void](Test-PdvRemoteWindowsProtectedAcl ([IO.Path]::GetDirectoryName($full)));
  [void](Test-PdvRemoteWindowsAdministrativeFile $full);
  $bytes=[IO.File]::ReadAllBytes($full);if($bytes.Length -lt 256 -or $bytes.Length -gt 104857600 -or (Get-PdvRemoteWindowsHash $bytes) -cne $Sha256){throw 'RemoteWindowsBinaryHashMismatch';}
  if($bytes[0] -ne 77 -or $bytes[1] -ne 90){throw 'RemoteWindowsBinaryArchitecture';}
  $offset=[BitConverter]::ToInt32($bytes,60);if($offset -lt 64 -or $offset -gt $bytes.Length-26 -or [BitConverter]::ToUInt32($bytes,$offset) -ne 17744){throw 'RemoteWindowsBinaryArchitecture';}
  $machine=34404;$magic=523;if($ExpectedArchitecture -ceq 'x86'){$machine=332;$magic=267;}
  if([BitConverter]::ToUInt16($bytes,$offset+4) -ne $machine -or [BitConverter]::ToUInt16($bytes,$offset+24) -ne $magic){throw 'RemoteWindowsBinaryArchitecture';}
  $signature=Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop;
  if($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -cne $SignerThumbprint){throw 'RemoteWindowsBinarySignatureInvalid';}
  return $true;
}
function Test-PdvRemoteWindowsVncIni {
  param([string]$Path,[string]$Sha256);
  $bytes=[IO.File]::ReadAllBytes($Path);if($bytes.Length -gt 16384 -or (Get-PdvRemoteWindowsHash $bytes) -cne $Sha256){throw 'RemoteWindowsVncConfigurationInvalid';}
  $text=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff);$section='';$values=@{};
  foreach($line in ($text -split "`n")){
    $trim=$line.Trim();if(-not $trim -or $trim.StartsWith(';') -or $trim.StartsWith('#')){continue;}
    if($trim -cmatch '^\[([A-Za-z_]+)\]$'){$section=$matches[1].ToLowerInvariant();continue;}
    if($trim -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$' -or -not $section){throw 'RemoteWindowsVncConfigurationInvalid';}
    $key=$section+'.'+$matches[1].ToLowerInvariant();if($values.Contains($key)){throw 'RemoteWindowsVncConfigurationInvalid';};$values[$key]=$matches[2].Trim();
  }
  $required=@{'admin.useregistry'='0';'admin.socketconnect'='0';'admin.httpconnect'='0';'admin.loopbackonly'='1';'admin.allowloopback'='1';'admin.authrequired'='1';'admin.reverseauthrequired'='1';'admin.mslogonrequired'='0';'admin.newmslogon'='0';'admin.usedsmplugin'='0';'admin.filetransferenabled'='0';'admin.blankmonitorenabled'='0';'admin.localinputsdisabled'='0';'admin.inputsenabled'='1';'admin.disabletrayicon'='0';'admin.allowproperties'='0';'admin.alloweditclients'='0';'admin.debugmode'='0';'admin.avilog'='0';'admin.service_commandline'=''};
  foreach($key in @('enabletls','cloudenabled','usebridge','allowinjection','useipv6','rdpmode','clearconsole')){$required['admin.'+$key]='0';}
  foreach($key in $required.Keys){if(-not $values.Contains($key) -or $values[$key] -cne $required[$key]){throw 'RemoteWindowsVncConfigurationUnsafe';}}
  if(-not $values.Contains('ultravnc.passwd') -or $values['ultravnc.passwd'] -cnotmatch '^[0-9a-fA-F]{16,18}$' -or $values['ultravnc.passwd'] -cmatch '^0+$'){throw 'RemoteWindowsVncPasswordMissing';}
  return $true;
}
function Get-PdvRemoteWindowsCertificateHash {
  param([string]$Path);
  $text=[IO.File]::ReadAllText($Path);if($text.Length -gt 65536){throw 'RemoteWindowsCertificateInvalid';}
  $match=[regex]::Match($text,'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----');if(-not $match.Success){throw 'RemoteWindowsCertificateInvalid';}
  try{$bytes=[Convert]::FromBase64String($match.Groups[1].Value);$certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$bytes);if($certificate.NotAfter.ToUniversalTime() -le (Get-PdvRemoteWindowsNow).UtcDateTime -or $certificate.NotBefore.ToUniversalTime() -gt (Get-PdvRemoteWindowsNow).UtcDateTime){throw 'Invalid';};return (Get-PdvRemoteWindowsHash $certificate.RawData);}catch{throw 'RemoteWindowsCertificateInvalid';}finally{if($null -ne $certificate){$certificate.Reset();}}
}
function Get-PdvRemoteWindowsBundleFiles {
  param($Configuration);
  $bundle=Join-Path $script:RemoteWindowsModuleDirectory 'piloto-remoto/windows/bundle';
  if(-not [IO.Directory]::Exists($bundle)){return @();} # Existing reviewed manual profiles remain supported.
  $helper=Join-Path $script:RemoteWindowsModuleDirectory 'tools/ValidarBundleRemoto.ps1';$lock=Join-Path $script:RemoteWindowsModuleDirectory 'tools/remoto-bundle-lock.xml';
  [void](Test-PdvRemoteWindowsAdministrativeFile $helper);[void](Test-PdvRemoteWindowsAdministrativeFile $lock);
  . $helper;
  $approved=Assert-PdvRemoteBundle -BundleDirectory $bundle -TrustedManifestPath $lock -ProfileId $Configuration.PlatformProfile -AllowRuntimeConfiguration;
  $paths=@($helper,$lock,(Join-Path $bundle 'remoto-bundle.xml'));
  foreach($entry in $approved.Files){[void](Test-PdvRemoteWindowsAdministrativeFile $entry.Path);$paths+=$entry.Path;}
  if($Configuration.StunnelExe -cne (Join-Path $bundle 'bin/stunnel/stunnel.exe') -or $Configuration.UltraVncExe -cne (Join-Path $bundle 'bin/ultravnc/winvnc.exe') -or $Configuration.UltraVncIniFile -cne (Join-Path $bundle 'bin/ultravnc/ultravnc.ini')){throw 'RemoteWindowsBundlePathMismatch';}
  return $paths;
}

function Test-PdvMonitorRemoteWindowsConfiguration {
  param($Configuration);
  [void](Test-PdvRemoteWindowsConfigurationShape $Configuration);
  if(-not $Configuration.Enabled){throw 'RemoteWindowsDisabled';};if(-not $Configuration.ProfileApproved){throw 'RemoteWindowsProfileNotApproved';}
  [void](Test-PdvRemoteWindowsRuntimeEvidence (Get-PdvRemoteWindowsRuntimeEvidence));
  $native=Get-PdvRemoteWindowsNativeEvidence;
  if($null -eq $native -or $native.Supported -isnot [bool] -or -not $native.Supported -or @('x86','x64') -cnotcontains $native.Architecture -or $native.ProcessArchitecture -cne $native.Architecture -or @('win7-sp1-x86','win7-sp1-x64','win10plus-x86','win10plus-x64') -cnotcontains $native.CompatibilityProfile){throw 'RemoteWindowsPlatformUnsupported';}
  if($Configuration.PlatformProfile -cne $native.CompatibilityProfile){throw 'RemoteWindowsPlatformProfileMismatch';}

  foreach($key in @('CertificateFile','PrivateKeyFile','ServerCaFile','UltraVncIniFile','PortableMarkerFile')){$path=Test-PdvRemoteWindowsLocalPath $Configuration[$key];[void](Test-PdvRemoteWindowsAdministrativeFile $path);}
  foreach($key in @('PrivateKeyFile','UltraVncIniFile')){[void](Test-PdvRemoteWindowsProtectedAcl $Configuration[$key] $true);}
  if([IO.Path]::GetFileName($Configuration.UltraVncExe) -ine 'winvnc.exe' -or [IO.Path]::GetFileName($Configuration.StunnelExe) -ine 'stunnel.exe'){throw 'RemoteWindowsBinaryNameInvalid';}
  [void](Test-PdvRemoteWindowsBinary $Configuration.StunnelExe $Configuration.StunnelSha256 $Configuration.StunnelSignerThumbprint $native.Architecture);
  [void](Test-PdvRemoteWindowsBinary $Configuration.UltraVncExe $Configuration.UltraVncSha256 $Configuration.UltraVncSignerThumbprint $native.Architecture);
  $vncDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Configuration.UltraVncExe));
  if([IO.Path]::GetFullPath($Configuration.UltraVncIniFile) -ine (Join-Path $vncDirectory 'ultravnc.ini') -or [IO.Path]::GetFullPath($Configuration.PortableMarkerFile) -ine (Join-Path $vncDirectory 'ultravnc.portable') -or (New-Object IO.FileInfo($Configuration.PortableMarkerFile)).Length -ne 0){throw 'RemoteWindowsPortableConfigurationRequired';}
  [void](Test-PdvRemoteWindowsVncIni $Configuration.UltraVncIniFile $Configuration.UltraVncIniSha256);
  if((Get-PdvRemoteWindowsCertificateHash $Configuration.CertificateFile) -cne $Configuration.CertificateSha256){throw 'RemoteWindowsCertificateMismatch';}
  return $true;
}
function Show-PdvMonitorRemoteWindowsConsent {
  param($Prompt);
  $identity=Get-PdvRemoteWindowsIdentity;
  if(-not (Test-PdvRemoteWindowsUiThread)){throw 'RemoteWindowsStaRequired';}
  if(-not (Test-PdvRemoteWindowsFields $Prompt @('SessionId','ChallengeId','TechnicianId','TechnicianName','Reason','Mode','ExpiresAt','SessionMaxSeconds','DefaultDecision','PaymentIdleConfirmationRequired','Message')) -or -not (Test-PdvRemoteWindowsId $Prompt.SessionId) -or -not (Test-PdvRemoteWindowsId $Prompt.ChallengeId) -or $Prompt.DefaultDecision -cne 'denied' -or $Prompt.Mode -cne 'control' -or $Prompt.PaymentIdleConfirmationRequired -ne $true -or $Prompt.SessionMaxSeconds -lt 30 -or $Prompt.SessionMaxSeconds -gt 900){throw 'RemoteWindowsInvalidConsentPrompt';}
  foreach($key in @('TechnicianId','TechnicianName','Reason')){if($Prompt[$key] -isnot [string] -or $Prompt[$key].Length -gt 500 -or $Prompt[$key] -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]'){throw 'RemoteWindowsInvalidConsentPrompt';}}
  $expires=ConvertTo-PdvRemoteWindowsDate $Prompt.ExpiresAt;if($expires -le (Get-PdvRemoteWindowsNow) -or $expires -gt (Get-PdvRemoteWindowsNow).AddSeconds(120)){throw 'RemoteWindowsConsentExpired';}
  Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing;
  $form=New-Object Windows.Forms.Form;$timer=New-Object Windows.Forms.Timer;
  $decision=@{Value='denied';Payment=$false};
  try{
    $form.Text='Conecta - solicitacao de suporte remoto';$form.ClientSize=New-Object Drawing.Size(570,420);$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.TopMost=$true;
    $label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(20,15);$label.Size=New-Object Drawing.Size(530,60);
    $label.Text=('O suporte podera VER E CONTROLAR esta tela por ate '+[int][math]::Ceiling($Prompt.SessionMaxSeconds/60.0)+" minutos.`r`nVoce podera encerrar a qualquer momento.");$form.Controls.Add($label);
    $technician=New-Object Windows.Forms.TextBox;$technician.Location=New-Object Drawing.Point(20,82);$technician.Size=New-Object Drawing.Size(530,65);$technician.Multiline=$true;$technician.ReadOnly=$true;$technician.ScrollBars='Vertical';$technician.Text=('Tecnico: '+$Prompt.TechnicianName+' (ID '+$Prompt.TechnicianId+')');$form.Controls.Add($technician);
    $reason=New-Object Windows.Forms.TextBox;$reason.Location=New-Object Drawing.Point(20,157);$reason.Size=New-Object Drawing.Size(530,115);$reason.Multiline=$true;$reason.ReadOnly=$true;$reason.ScrollBars='Vertical';$reason.Text=('Motivo: '+$Prompt.Reason);$form.Controls.Add($reason);
    $check=New-Object Windows.Forms.CheckBox;$check.Location=New-Object Drawing.Point(20,285);$check.Size=New-Object Drawing.Size(530,42);$check.Text='Confirmo que nao ha venda nem pagamento em andamento.';$check.Checked=$false;$form.Controls.Add($check);
    $deny=New-Object Windows.Forms.Button;$deny.Text='Nao permitir';$deny.Location=New-Object Drawing.Point(280,357);$deny.Size=New-Object Drawing.Size(130,38);$deny.DialogResult=[Windows.Forms.DialogResult]::Cancel;$form.Controls.Add($deny);
    $approve=New-Object Windows.Forms.Button;$approve.Text='Permitir suporte';$approve.Location=New-Object Drawing.Point(420,357);$approve.Size=New-Object Drawing.Size(130,38);$approve.Enabled=$false;$form.Controls.Add($approve);
    $form.AcceptButton=$deny;$form.CancelButton=$deny;$form.ActiveControl=$deny;
    $check.add_CheckedChanged({$approve.Enabled=$check.Checked;});
    $approve.add_Click({try{if($check.Checked -and (Get-PdvRemoteWindowsNow) -lt $expires -and (Get-PdvRemoteWindowsIdentity) -ceq $identity){$decision.Value='approved';$decision.Payment=$true;$form.DialogResult=[Windows.Forms.DialogResult]::OK;$form.Close();}}catch{$form.Close();}});
    $timer.Interval=500;$timer.add_Tick({try{if((Get-PdvRemoteWindowsNow) -ge $expires -or (Get-PdvRemoteWindowsIdentity) -cne $identity){$form.Close();}}catch{$form.Close();}});$timer.Start();[void]$form.ShowDialog();
    return @{SessionId=$Prompt.SessionId;ChallengeId=$Prompt.ChallengeId;Decision=$decision.Value;PaymentIdleConfirmed=[bool]$decision.Payment};
  }finally{$timer.Stop();$timer.Dispose();$form.Dispose();}
}
function New-PdvMonitorRemoteWindowsTransport {
  param($LocalConfiguration,[string]$DataDirectory,[string]$AgentId,[bool]$Enabled=$false);
  if(-not (Test-PdvRemoteWindowsId $AgentId)){throw 'RemoteWindowsInvalidAgent';}
  $transport=@{Enabled=$Enabled;Configuration=$LocalConfiguration;AgentId=$AgentId;DataDirectory=[IO.Path]::GetFullPath($DataDirectory);Stage='idle';SessionId='';Lease=$null;Identity='';Supervisor=$null;Indicator=$null;Locks=@();Mutex=$null;MutexAcquired=$false;JournalOwned=$false;SessionDirectory='';SessionDirectoryOwned=$false;Reason='';LocalProcessesStopped=$true;JournalPath='';};
  if(-not $Enabled){return $transport;}
  [void](Test-PdvRemoteWindowsLocalPath $transport.DataDirectory $true);[void](Test-PdvRemoteWindowsProtectedAcl $transport.DataDirectory);[void](Test-PdvMonitorRemoteWindowsConfiguration $LocalConfiguration);
  if($LocalConfiguration.AgentId -cne $AgentId){throw 'RemoteWindowsAgentMismatch';}
  $transport.JournalPath=Join-Path $transport.DataDirectory 'remoto-transporte.xml';
  if([IO.File]::Exists($transport.JournalPath)){
    # Nunca interpretar parametros de processos do journal como uma ordem para retomar/matar.
    # O Job Object fecha filhos no crash. Mesmo assim, revisao central e local e obrigatoria.
    $transport.Stage='interrupted';$transport.Reason='RemoteWindowsInterruptedTransport';$transport.LocalProcessesStopped=$false;
    try{$transport.SessionId=Read-PdvRemoteWindowsInterruptedJournal $transport;}catch{$transport.Stage='blocked';$transport.Reason='RemoteWindowsJournalInvalid';}
  };return $transport;
}
function Read-PdvRemoteWindowsInterruptedJournal {
  param($Transport);
  [void](Test-PdvRemoteWindowsLocalPath $Transport.JournalPath);[void](Test-PdvRemoteWindowsProtectedAcl $Transport.JournalPath);
  if((New-Object IO.FileInfo($Transport.JournalPath)).Length -gt 8192){throw 'RemoteWindowsJournalInvalid';}
  $reader=$null;
  try{
    $settings=New-Object Xml.XmlReaderSettings;$settings.ProhibitDtd=$true;$settings.XmlResolver=$null;$reader=[Xml.XmlReader]::Create($Transport.JournalPath,$settings);
    $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);$root=$xml.DocumentElement;
    if($root.Name -cne 'PdvRemoteTransport' -or $root.NamespaceURI -or $root.Attributes.Count -ne 5 -or $root.GetAttribute('schemaVersion') -cne '1' -or $root.GetAttribute('agentId') -cne $Transport.AgentId -or -not (Test-PdvRemoteWindowsId $root.GetAttribute('sessionId')) -or @('prepared','starting_tunnel','starting_vnc','active','closing','closed') -cnotcontains $root.GetAttribute('stage')){throw 'Invalid';}
    foreach($attribute in $root.Attributes){if(@('schemaVersion','agentId','sessionId','stage','updatedAt') -cnotcontains $attribute.Name -or $attribute.NamespaceURI){throw 'Invalid';}}
    [void](ConvertTo-PdvRemoteWindowsDate $root.GetAttribute('updatedAt'));$count=0;$pids=@{};
    foreach($node in $root.ChildNodes){
      if($node.NodeType -ne [Xml.XmlNodeType]::Element -or $node.Name -cne 'OwnedProcess' -or $node.NamespaceURI -or $node.Attributes.Count -ne 3 -or $node.ChildNodes.Count -ne 0){throw 'Invalid';}
      foreach($attribute in $node.Attributes){if(@('pid','createdUtc','exeSha256') -cnotcontains $attribute.Name -or $attribute.NamespaceURI){throw 'Invalid';}}
      $pidText=$node.GetAttribute('pid');if($pidText -cnotmatch '^[1-9][0-9]{0,9}$' -or [long]$pidText -gt [int]::MaxValue -or $pids.Contains($pidText) -or @($Transport.Configuration.StunnelSha256,$Transport.Configuration.UltraVncSha256) -cnotcontains $node.GetAttribute('exeSha256')){throw 'Invalid';}
      [void](ConvertTo-PdvRemoteWindowsDate $node.GetAttribute('createdUtc'));$pids[$pidText]=$true;$count++;if($count -gt 2){throw 'Invalid';}
    };return $root.GetAttribute('sessionId');
  }catch{throw 'RemoteWindowsJournalInvalid';}finally{if($null -ne $reader){$reader.Dispose();}}
}
function Resolve-PdvMonitorRemoteWindowsInterruptedTransport {
  param($Transport,[string]$SessionId,[string]$CentralStatus);
  if($Transport.Stage -cne 'interrupted' -or $SessionId -cne $Transport.SessionId -or @('closed','ended','failed','cancelled','expired','denied') -cnotcontains $CentralStatus){throw 'RemoteWindowsInterruptedAcknowledgementInvalid';}
  if((Read-PdvRemoteWindowsInterruptedJournal $Transport) -cne $SessionId){throw 'RemoteWindowsJournalInvalid';}
  # A ausencia e consultada de leitura. Nunca encerrar PID carregado de um arquivo.
  Test-PdvRemoteWindowsNoExistingVnc;[IO.File]::Delete($Transport.JournalPath);$Transport.LocalProcessesStopped=$true;$Transport.Stage='closed';$Transport.Reason='RemoteWindowsInterruptedTransportClosed';
  return (Get-PdvMonitorRemoteWindowsTransportSnapshot $Transport);
}
function Test-PdvRemoteWindowsLease {
  param($Transport,$Lease,[bool]$Initial=$false);
  if(-not (Test-PdvRemoteWindowsFields $Lease @('SessionId','AgentId','RepeaterId','CertificateSha256','State','ExpiresAt')) -or -not (Test-PdvRemoteWindowsId $Lease.SessionId) -or $Lease.AgentId -cne $Transport.AgentId -or $Lease.RepeaterId -cne $Transport.Configuration.RepeaterId -or $Lease.CertificateSha256 -cne $Transport.Configuration.CertificateSha256 -or @('pending','ready','connected') -cnotcontains $Lease.State){throw 'RemoteWindowsLeaseMismatch';}
  $expires=ConvertTo-PdvRemoteWindowsDate $Lease.ExpiresAt;$now=Get-PdvRemoteWindowsNow;
  if($expires -le $now -or $expires -gt $now.AddSeconds(900)){throw 'RemoteWindowsLeaseExpired';}
  if(-not $Initial -and ($Lease.SessionId -cne $Transport.SessionId -or $Lease.ExpiresAt -cne $Transport.Lease.ExpiresAt)){throw 'RemoteWindowsLeaseChanged';}
  return $expires;
}
function Write-PdvRemoteWindowsTransportJournal {
  param($Transport,[string]$Stage);
  if(@('prepared','starting_tunnel','starting_vnc','active','closing','closed') -cnotcontains $Stage -or -not $Transport.JournalOwned -or -not $Transport.MutexAcquired){throw 'RemoteWindowsJournalInvalid';}
  if([IO.File]::Exists($Transport.JournalPath) -and (Read-PdvRemoteWindowsInterruptedJournal $Transport) -cne $Transport.SessionId){throw 'RemoteWindowsJournalInvalid';}
  $xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement('PdvRemoteTransport');[void]$xml.AppendChild($root);
  $root.SetAttribute('schemaVersion','1');$root.SetAttribute('sessionId',$Transport.SessionId);$root.SetAttribute('agentId',$Transport.AgentId);$root.SetAttribute('stage',$Stage);$root.SetAttribute('updatedAt',(Get-PdvRemoteWindowsNow).ToString('o'));
  if($null -ne $Transport.Supervisor){foreach($child in $Transport.Supervisor.Children){$node=$xml.CreateElement('OwnedProcess');$node.SetAttribute('pid',[string]$child.ProcessId);$node.SetAttribute('createdUtc',$child.CreatedUtc);$node.SetAttribute('exeSha256',$(if([IO.Path]::GetFullPath($child.Executable) -ieq [IO.Path]::GetFullPath($Transport.Configuration.StunnelExe)){$Transport.Configuration.StunnelSha256;}else{$Transport.Configuration.UltraVncSha256;}));[void]$root.AppendChild($node);}}
  $temporary=$Transport.JournalPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';
  try{
    [IO.File]::WriteAllText($temporary,$xml.OuterXml,(New-Object Text.UTF8Encoding($false)));[void](Test-PdvRemoteWindowsProtectedAcl $temporary);
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$stream.Flush($true);}finally{$stream.Dispose();}
    if([IO.File]::Exists($Transport.JournalPath)){
      [void](Test-PdvRemoteWindowsLocalPath $Transport.JournalPath);$backup=$Transport.JournalPath+'.bak';if([IO.File]::Exists($backup)){[void](Test-PdvRemoteWindowsLocalPath $backup);}
      [IO.File]::Replace($temporary,$Transport.JournalPath,$backup);if([IO.File]::Exists($backup)){[IO.File]::Delete($backup);}
    }else{[IO.File]::Move($temporary,$Transport.JournalPath);}
  }catch{throw 'RemoteWindowsJournalWriteFailed';}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary);}}
}
function New-PdvRemoteWindowsSupervisor {param([int]$Seconds,$Evidence);return (New-Object Conecta.PdvRemotePilot.LeaseSupervisor($Seconds,$Evidence.WindowsSessionId,$Evidence.UserSid));}
function Enter-PdvRemoteWindowsMutex {
  param($Transport);
  $Transport.Mutex=New-Object Threading.Mutex($false,'Local\Conecta.PdvRemotePilot.WinVnc');
  try{$Transport.MutexAcquired=$Transport.Mutex.WaitOne(0,$false);}catch [Threading.AbandonedMutexException]{$Transport.MutexAcquired=$true;throw 'RemoteWindowsInterruptedTransport';}
  if(-not $Transport.MutexAcquired){throw 'RemoteWindowsExistingVncInstance';}
}
function Get-PdvRemoteWindowsLoopbackPort {
  $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);try{$listener.Start();return ([Net.IPEndPoint]$listener.LocalEndpoint).Port;}finally{$listener.Stop();}
}
function Wait-PdvRemoteWindowsTunnelListener {
  param($Supervisor,[int]$Port,[int]$ProcessId);
  $waiting=[Diagnostics.Stopwatch]::StartNew();
  while($waiting.Elapsed.TotalSeconds -lt 3 -and -not $Supervisor.Closed){if([Conecta.PdvRemotePilot.DesktopEvidence]::LoopbackListenerOwnedBy($Port,$ProcessId)){return $true;};[Threading.Thread]::Sleep(50);};return $false;
}
function New-PdvRemoteWindowsTunnelConfiguration {
  param($Configuration,[int]$Port);
  if($Port -lt 1024 -or $Port -gt 65535){throw 'RemoteWindowsInvalidLoopbackPort';}
  return (@('debug = err','taskbar = yes','[conecta-pdv-lease]','client = yes',('accept = 127.0.0.1:'+$Port),('connect = '+$Configuration.GatewayHost+':'+$Configuration.GatewayPort),('cert = '+$Configuration.CertificateFile),('key = '+$Configuration.PrivateKeyFile),('CAfile = '+$Configuration.ServerCaFile),'verifyChain = yes',('checkHost = '+$Configuration.GatewayHost),('sni = '+$Configuration.GatewayHost),'sslVersionMin = TLSv1.2','sessionResume = no','TIMEOUTconnect = 5','TIMEOUTclose = 0') -join "`r`n")+"`r`n";
}
function Test-PdvRemoteWindowsNoExistingVnc {
  # UltraVNC pode encaminhar a CLI para instancia existente. Na duvida, nao iniciar.
  $processes=@(Get-WmiObject Win32_Process -Filter "Name='winvnc.exe' OR Name='stunnel.exe'" -ErrorAction Stop);if($processes.Count){throw 'RemoteWindowsExistingVncInstance';}
  $services=@(Get-WmiObject Win32_Service -ErrorAction Stop | Where-Object {$_.State -cne 'Stopped' -and $_.PathName -match '(?i)winvnc\.exe'});if($services.Count){throw 'RemoteWindowsExistingVncInstance';}
}
function Show-PdvRemoteWindowsIndicator {
  param($Transport,$BrokerContext);
  Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing;
  $form=New-Object Windows.Forms.Form;$form.Text='Suporte remoto - Conecta';$form.ClientSize=New-Object Drawing.Size(460,170);$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.StartPosition='CenterScreen';$form.TopMost=$true;
  $label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(15,15);$label.Size=New-Object Drawing.Size(430,85);$label.Text=('Suporte autorizado: '+$BrokerContext.Active.Request.TechnicianName+"`r`nA tela pode ser visualizada e controlada.`r`nEncerra automaticamente ate "+$Transport.Lease.ExpiresAt);$form.Controls.Add($label);
  $button=New-Object Windows.Forms.Button;$button.Text='Encerrar suporte agora';$button.Size=New-Object Drawing.Size(240,40);$button.Location=New-Object Drawing.Point(110,112);$form.Controls.Add($button);
  $button.add_Click({$Transport.Supervisor.Stop('OperatorCancelled');$form.Close();}.GetNewClosure());
  $form.add_FormClosing({if($null -ne $Transport.Supervisor -and -not $Transport.Supervisor.Closed){$Transport.Supervisor.Stop('OperatorCancelled');}}.GetNewClosure());
  $form.Show();return $form;
}
function Get-PdvRemoteWindowsStartFailureReason {
  param($Exception);
  # New-Object e chamadas .NET podem encapsular o erro; nunca copiar texto livre.
  $native=@{'RemoteNestedJobUnsupported'='RemoteWindowsNestedJobUnsupported';'RemoteJobInspectionFailed'='RemoteWindowsJobInspectionFailed';};
  $current=$Exception;
  for($depth=0;$depth -lt 8 -and $null -ne $current;$depth++){
    $message=[string]$current.Message;
    if($native.Contains($message)){return $native[$message];}
    if($message -cmatch '^RemoteWindows[A-Za-z]{1,80}$'){return $message;}
    $current=$current.InnerException;
  }
  return 'RemoteWindowsTransportStartFailed';
}
function Start-PdvMonitorRemoteWindowsTransport {
  param($Transport,$BrokerContext,$Lease);
  $identityLock=$null;
  try{
    $bundle=Join-Path $script:RemoteWindowsModuleDirectory 'piloto-remoto/windows/bundle';
    if([IO.Directory]::Exists($bundle)){
      # File sharing is cross-session: SYSTEM renewal and the interactive host coordinate.
      $path=Join-Path ([IO.Path]::GetDirectoryName($script:RemoteWindowsModuleDirectory)) 'enrollment.lock';[void](Test-PdvRemoteWindowsAdministrativeFile $path);
      $identityLock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);
      $latest=Read-PdvMonitorRemoteWindowsConfiguration $Transport.DataDirectory;
      foreach($key in $Transport.Configuration.Keys){if(@('CertificateFile','CertificateSha256','PrivateKeyFile','ServerCaFile') -cnotcontains $key -and $latest[$key] -cne $Transport.Configuration[$key]){throw 'RemoteWindowsIdentityUnexpectedChange';}}
      $Transport.Configuration=$latest;
    }
    $result=Start-PdvMonitorRemoteWindowsTransportInternal $Transport $BrokerContext $Lease;
    if($null -ne $identityLock){$Transport.Locks+=,$identityLock;$identityLock=$null;}
    return $result;
  }finally{if($null -ne $identityLock){$identityLock.Dispose();}}
}

function Start-PdvMonitorRemoteWindowsTransportInternal {
  param($Transport,$BrokerContext,$Lease);
  if(-not $Transport.Enabled){throw 'RemoteWindowsDisabled';};if(@('idle','closed') -cnotcontains $Transport.Stage){throw 'RemoteWindowsTransportBusy';}
  if(-not (Test-PdvRemoteWindowsUiThread)){throw 'RemoteWindowsStaRequired';}
  [void](Test-PdvMonitorRemoteWindowsConfiguration $Transport.Configuration);Initialize-PdvRemoteWindowsNative;
  $expires=Test-PdvRemoteWindowsLease $Transport $Lease $true;$identity=Get-PdvRemoteWindowsIdentity;
  if(-not $BrokerContext.Enabled -or -not $BrokerContext.Healthy -or $BrokerContext.Paused -or $BrokerContext.Stage -cne 'authorized' -or $null -eq $BrokerContext.Active -or $BrokerContext.AgentId -cne $Transport.AgentId -or $BrokerContext.Active.Request.SessionId -cne $Lease.SessionId -or $BrokerContext.Active.Record.decision -cne 'approved' -or $BrokerContext.Active.LocalIdentity -cne $identity -or $BrokerContext.Active.Record.sessionExpiresAt -lt $expires){throw 'RemoteWindowsLocalConsentRequired';}
  if($expires -gt $BrokerContext.Active.ApprovedAt.AddSeconds($BrokerContext.Active.Request.SessionMaxSeconds)){throw 'RemoteWindowsLeaseExpired';}
  $Transport.SessionId=$Lease.SessionId;$Transport.Lease=@{};foreach($key in $Lease.Keys){$Transport.Lease[$key]=$Lease[$key];};$Transport.Identity=$identity;$Transport.Stage='starting';$Transport.LocalProcessesStopped=$false;
  try{
    Enter-PdvRemoteWindowsMutex $Transport;
    if([IO.File]::Exists($Transport.JournalPath)){throw 'RemoteWindowsInterruptedTransport';}
    Test-PdvRemoteWindowsNoExistingVnc;
    # Travas impedem troca/escrita dos executaveis/configuracao entre verificacao e CreateProcess.
    $bundleFiles=@(Get-PdvRemoteWindowsBundleFiles $Transport.Configuration);
    foreach($path in @($Transport.Configuration.StunnelExe,$Transport.Configuration.UltraVncExe,$Transport.Configuration.UltraVncIniFile,$Transport.Configuration.PortableMarkerFile,$Transport.Configuration.CertificateFile,$Transport.Configuration.PrivateKeyFile,$Transport.Configuration.ServerCaFile)+$bundleFiles){$Transport.Locks+=,[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);}
    [void](Test-PdvMonitorRemoteWindowsConfiguration $Transport.Configuration);
    $Transport.JournalOwned=$true;Write-PdvRemoteWindowsTransportJournal $Transport 'prepared';
    $seconds=[int][math]::Floor(($expires-(Get-PdvRemoteWindowsNow)).TotalSeconds);if($seconds -lt 1){throw 'RemoteWindowsLeaseExpired';}
    $evidence=Get-PdvMonitorRemoteWindowsInteractiveEvidence;$Transport.Supervisor=New-PdvRemoteWindowsSupervisor $seconds $evidence;
    $Transport.SessionDirectory=Join-Path $Transport.DataDirectory ('remoto-'+$Transport.SessionId);if([IO.Directory]::Exists($Transport.SessionDirectory)){throw 'RemoteWindowsSessionDirectoryExists';};[void][IO.Directory]::CreateDirectory($Transport.SessionDirectory);$Transport.SessionDirectoryOwned=$true;[void](Test-PdvRemoteWindowsProtectedAcl $Transport.SessionDirectory);
    $port=Get-PdvRemoteWindowsLoopbackPort;$Transport.Supervisor.SetTunnelPort($port);$tunnelPath=Join-Path $Transport.SessionDirectory 'stunnel.conf';[IO.File]::WriteAllText($tunnelPath,(New-PdvRemoteWindowsTunnelConfiguration $Transport.Configuration $port),(New-Object Text.ASCIIEncoding));[void](Test-PdvRemoteWindowsProtectedAcl $tunnelPath);
    $Transport.Locks+=,[IO.File]::Open($tunnelPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);
    Write-PdvRemoteWindowsTransportJournal $Transport 'starting_tunnel';
    $tunnelChild=$Transport.Supervisor.StartChild([IO.Path]::GetFullPath($Transport.Configuration.StunnelExe),('"'+$tunnelPath+'"'),[IO.Path]::GetDirectoryName($Transport.Configuration.StunnelExe));
    if(-not (Wait-PdvRemoteWindowsTunnelListener $Transport.Supervisor $port $tunnelChild.ProcessId)){throw 'RemoteWindowsTunnelListenerUnavailable';}
    # Nao sondar RFB nem abrir COM. Bind/listener e autenticacao mTLS serao comprovados no gateway.
    Write-PdvRemoteWindowsTransportJournal $Transport 'starting_vnc';
    $arguments='-id:'+$Transport.Configuration.RepeaterId+' -connect 127.0.0.1::'+$port+' -run';
    [void]$Transport.Supervisor.StartChild([IO.Path]::GetFullPath($Transport.Configuration.UltraVncExe),$arguments,[IO.Path]::GetDirectoryName($Transport.Configuration.UltraVncExe));
    $Transport.Indicator=Show-PdvRemoteWindowsIndicator $Transport $BrokerContext;
    Write-PdvRemoteWindowsTransportJournal $Transport 'active';$Transport.Stage='active';
    return (Get-PdvMonitorRemoteWindowsTransportSnapshot $Transport);
  }catch{$failure=Get-PdvRemoteWindowsStartFailureReason $_.Exception;try{[void](Stop-PdvMonitorRemoteWindowsTransport $Transport 'TransportFailed');}catch{};throw $failure;}
}
function Update-PdvMonitorRemoteWindowsTransport {
  param($Transport,$Lease);
  if($Transport.Stage -cne 'active' -or $null -eq $Transport.Supervisor){throw 'RemoteWindowsTransportInactive';}
  try{[void](Test-PdvRemoteWindowsLease $Transport $Lease);if((Get-PdvRemoteWindowsIdentity) -cne $Transport.Identity){throw 'RemoteWindowsLocalSessionChanged';};$Transport.Supervisor.Heartbeat();return (Get-PdvMonitorRemoteWindowsTransportSnapshot $Transport);}
  catch{[void](Stop-PdvMonitorRemoteWindowsTransport $Transport 'ServerCancelled');throw 'RemoteWindowsAuthorizationLost';}
}
function Get-PdvMonitorRemoteWindowsTransportSnapshot {
  param($Transport);
  if($null -ne $Transport.Indicator){[Windows.Forms.Application]::DoEvents();}
  $close=$false;$stopped=[bool]$Transport.LocalProcessesStopped;
  if(@('interrupted','blocked') -ccontains $Transport.Stage){$close=$true;$stopped=$false;if($Transport.Stage -ceq 'interrupted'){try{Test-PdvRemoteWindowsNoExistingVnc;$stopped=$true;}catch{}};}
  if($null -ne $Transport.Supervisor -and $Transport.Supervisor.Closed){$close=$true;$stopped=[bool]$Transport.Supervisor.ProcessesStopped;$Transport.Reason=[string]$Transport.Supervisor.CloseReason;}
  return @{Enabled=[bool]$Transport.Enabled;Stage=[string]$Transport.Stage;SessionId=[string]$Transport.SessionId;CloseRequested=$close;Reason=[string]$Transport.Reason;LocalProcessesStopped=$stopped;Connected=$false;TransportActivationSupported=[bool]$Transport.Enabled};
}
function Stop-PdvMonitorRemoteWindowsTransport {
  param($Transport,[string]$Reason='OperatorCancelled');
  if(@('OperatorCancelled','ServerCancelled','LeaseExpired','LocalSessionChanged','Paused','HostClosed','ConsentExpired','TransportFailed','AuthorizationLost') -cnotcontains $Reason){throw 'RemoteWindowsInvalidCloseReason';}
  if($null -eq $Transport.Supervisor -and @('interrupted','blocked') -ccontains $Transport.Stage){return (Get-PdvMonitorRemoteWindowsTransportSnapshot $Transport);}
  $Transport.Reason=$Reason;
  # Falha do disco nao pode impedir encerramento; nenhum closed e enviado antes de confirmar parada.
  $journalOk=$true;if($Transport.JournalOwned){try{Write-PdvRemoteWindowsTransportJournal $Transport 'closing';}catch{$journalOk=$false;}}
  $stopped=$true;
  if($null -ne $Transport.Supervisor){$Transport.Supervisor.Stop($Reason);$stopped=[bool]$Transport.Supervisor.ProcessesStopped;}
  if(-not $stopped){$Transport.Stage='closing';$Transport.LocalProcessesStopped=$false;throw 'RemoteWindowsProcessesStillRunning';}
  $Transport.LocalProcessesStopped=$true;
  if($null -ne $Transport.Indicator){$Transport.Indicator.Close();$Transport.Indicator.Dispose();$Transport.Indicator=$null;}
  if($null -ne $Transport.Supervisor){$Transport.Supervisor.Dispose();$Transport.Supervisor=$null;}
  foreach($lock in $Transport.Locks){$lock.Dispose();};$Transport.Locks=@();
  if($Transport.SessionDirectoryOwned -and $Transport.SessionDirectory -and [IO.Directory]::Exists($Transport.SessionDirectory)){
    try{
      # Arquivo proprio com caminhos de certificado, nunca copiar chaves/segredos para esta pasta.
      $ownConfig=Join-Path $Transport.SessionDirectory 'stunnel.conf';if([IO.File]::Exists($ownConfig)){[IO.File]::Delete($ownConfig);};[IO.Directory]::Delete($Transport.SessionDirectory,$false);$Transport.SessionDirectoryOwned=$false;
    }catch{$journalOk=$false;}
  }
  if($Transport.JournalOwned){try{Write-PdvRemoteWindowsTransportJournal $Transport 'closed';if($journalOk){[IO.File]::Delete($Transport.JournalPath);$Transport.JournalOwned=$false;}}catch{$journalOk=$false;}}
  if($null -ne $Transport.Mutex){if($Transport.MutexAcquired){try{$Transport.Mutex.ReleaseMutex();}catch{}};$Transport.Mutex.Dispose();$Transport.Mutex=$null;$Transport.MutexAcquired=$false;}
  $Transport.Stage='closed';if(-not $journalOk){$Transport.Stage='interrupted';$Transport.Reason='RemoteWindowsJournalWriteFailed';}
  return (Get-PdvMonitorRemoteWindowsTransportSnapshot $Transport);
}

Export-ModuleMember -Function Read-PdvMonitorRemoteWindowsConfiguration,Test-PdvMonitorRemoteWindowsConfiguration,Get-PdvMonitorRemoteWindowsPlatformEvidence,Get-PdvMonitorRemoteWindowsInteractiveEvidence,Show-PdvMonitorRemoteWindowsConsent,New-PdvMonitorRemoteWindowsTransport,Start-PdvMonitorRemoteWindowsTransport,Update-PdvMonitorRemoteWindowsTransport,Get-PdvMonitorRemoteWindowsTransportSnapshot,Stop-PdvMonitorRemoteWindowsTransport,Resolve-PdvMonitorRemoteWindowsInterruptedTransport;
