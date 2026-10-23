#requires -Version 2.0
# Atualizações aprovadas: HTTPS + assinatura RSA/SHA256 + chave pública fixada.
Set-StrictMode -Version 2.0;
$script:PdvUpdateProgramFiles = @('MonitorPdv.ps1','InicializarMonitor.ps1','Monitor.cmd','IniciarMonitor.vbs','InstalarMonitor.ps1','DesinstalarMonitor.ps1','PdvMonitor.Runtime.psm1','PdvMonitor.Inventario.psm1','PdvMonitor.Coleta.psm1','PdvMonitor.Politica.psm1','PdvLegado.Core.psm1','PdvDispositivos.Core.psm1','PdvMonitor.Transporte.psm1','PdvMonitor.Atualizacao.psm1','AplicarAtualizacao.ps1','monitor-version.txt','PdvMonitor.Nerus.psm1','PdvMonitor.Version.psm1','atualizacoes-chave-publica.xml','IniciarMonitorInstalado.ps1','PdvMonitor.Remoto.psm1','PdvMonitor.Remoto.Transporte.psm1');

function Get-PdvUpdateValue {
  param($Object,[string]$Name,$Default=$null);
  if ($null -eq $Object) { return ,$Default; }
  if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return ,$Object[$Name]; } }
  else { $property=$Object.PSObject.Properties[$Name]; if ($null -ne $property) { return ,$property.Value; } }
  return ,$Default;
}
function New-PdvUpdateResult {
  param([bool]$Success,[string]$Reason,[string]$Version='', [bool]$Staged=$false,[bool]$Started=$false);
  return (New-Object PSObject -Property @{Success=$Success;Reason=$Reason;Version=$Version;Staged=$Staged;Started=$Started;});
}
function Get-PdvUpdateNow { return [DateTimeOffset]::UtcNow; }
function Write-PdvUpdateText {
  param([string]$Path,[string]$Text);
  $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';
  try { [IO.File]::WriteAllText($temporary,$Text,(New-Object Text.UTF8Encoding($false))); if ([IO.File]::Exists($Path)) { $backup=$temporary+'.bak'; try { [IO.File]::Replace($temporary,$Path,$backup); } finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup); } } } else { [IO.File]::Move($temporary,$Path); } }
  finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary); } }
}
function Read-PdvUpdateXml {
  param([byte[]]$Bytes,[int]$MaximumBytes=32768);
  if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $MaximumBytes) { throw 'UpdateXmlSize'; }
  $settings=New-Object Xml.XmlReaderSettings; $settings.ProhibitDtd=$true; $settings.XmlResolver=$null;
  $stream=New-Object IO.MemoryStream(,$Bytes); $reader=$null;
  try { $reader=[Xml.XmlReader]::Create($stream,$settings); $xml=New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.Load($reader); return ,$xml; }
  finally { if ($null -ne $reader) { $reader.Close(); }; $stream.Close(); }
}
function Get-PdvUpdatePaths {
  param([string]$DataDirectory);
  if (-not $DataDirectory) { throw 'UpdateDataDirectoryRequired'; }
  $data=[IO.Path]::GetFullPath($DataDirectory); $root=Join-Path $data 'atualizacoes';
  return (New-Object PSObject -Property @{Data=$data;Root=$root;Trust=(Join-Path $data 'atualizacoes-chave-publica.xml');Stage=(Join-Path $root 'stage');Runner=(Join-Path $root 'executor');State=(Join-Path $root 'estado.xml');Health=(Join-Path $root 'saude.xml');PendingHealth=(Join-Path $root 'saude-pendente.xml');Failure=(Join-Path $root 'versao-rejeitada.txt');});
}
function Get-PdvUpdateVersion {
  param([string]$ProgramDirectory);
  $path=Join-Path $ProgramDirectory 'monitor-version.txt';
  if (-not [IO.File]::Exists($path)) { return '0.2.0'; }
  if ((New-Object IO.FileInfo($path)).Length -gt 32) { throw 'UpdateCurrentVersionInvalid'; }
  $version=[IO.File]::ReadAllText($path).Trim();
  if (-not (Test-PdvUpdateVersion $version)) { throw 'UpdateCurrentVersionInvalid'; }
  return $version;
}
function Test-PdvUpdateVersion {
  param([string]$Version);
  return ($Version -cmatch '^(0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})[.](0|[1-9][0-9]{0,3})$');
}
function New-PdvUpdateRsa {
  param([int]$KeySize=2048);
  if ($KeySize -lt 2048 -or $KeySize -gt 4096 -or ($KeySize % 256) -ne 0) { throw 'UpdateRsaKeySizeInvalid'; }
  # No .NET Framework, o adaptador PowerShell expõe KeySize do CSP como somente
  # leitura. Definir o tamanho pelo construtor funciona em 5.1 e em .NET moderno.
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $parameters=New-Object Security.Cryptography.CspParameters(24);
    $rsa=New-Object -TypeName Security.Cryptography.RSACryptoServiceProvider -ArgumentList @($KeySize,$parameters);
  } else { $rsa=New-Object -TypeName Security.Cryptography.RSACryptoServiceProvider -ArgumentList @($KeySize); }
  $rsa.PersistKeyInCsp=$false; return ,$rsa;
}
function Read-PdvUpdatePublicKey {
  param([string]$Path);
  if (-not [IO.File]::Exists($Path)) { throw 'UpdateTrustNotInstalled'; }
  $xml=Read-PdvUpdateXml ([IO.File]::ReadAllBytes($Path)) 16384;
  $root=$xml.DocumentElement;
  if ($null -eq $root -or $root.Name -cne 'RSAKeyValue' -or $root.Attributes.Count -ne 0 -or $root.ChildNodes.Count -ne 2 -or $root.ChildNodes[0].Name -cne 'Modulus' -or $root.ChildNodes[1].Name -cne 'Exponent') { throw 'UpdatePublicKeyInvalid'; }
  $rsa=New-PdvUpdateRsa;
  try { $rsa.FromXmlString($root.OuterXml); if ($rsa.KeySize -lt 2048 -or $rsa.KeySize -gt 4096) { throw 'UpdatePublicKeyInvalid'; } }
  catch { $rsa.Clear(); throw 'UpdatePublicKeyInvalid'; }
  return ,$rsa;
}
function Initialize-PdvMonitorUpdateTrust {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$DataDirectory,[Parameter(Mandatory=$true)][string]$PublicKeyPath);
  $paths=Get-PdvUpdatePaths $DataDirectory; $rsa=Read-PdvUpdatePublicKey $PublicKeyPath;
  try {
    $public=$rsa.ToXmlString($false);
    if ([IO.File]::Exists($paths.Trust)) {
      $existing=Read-PdvUpdatePublicKey $paths.Trust;
      try { if ($existing.ToXmlString($false) -cne $public) { throw 'UpdateTrustAlreadyPinned'; }; return 'AlreadyPinned'; } finally { $existing.Clear(); }
    }
    [void][IO.Directory]::CreateDirectory($paths.Data);
    # Criação exclusiva: nunca substitui uma chave já fixada, mesmo em instalação concorrente.
    $stream=New-Object IO.FileStream($paths.Trust,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);
    try { $bytes=[Text.Encoding]::UTF8.GetBytes($public); $stream.Write($bytes,0,$bytes.Length); $stream.Flush(); } finally { $stream.Close(); }
    return 'Pinned';
  } finally { $rsa.Clear(); }
}
function Test-PdvUpdateManifest {
  param([byte[]]$Bytes,[string]$PublicKeyPath,[string]$CurrentVersion,[string]$Channel='piloto');
  if (-not (Test-PdvUpdateVersion $CurrentVersion) -or $Channel -cne 'piloto') { throw 'UpdateLocalPolicyInvalid'; }
  $xml=Read-PdvUpdateXml $Bytes; $root=$xml.DocumentElement;
  if ($null -eq $root -or $root.Name -cne 'PdvMonitorUpdate' -or $root.GetAttribute('schemaVersion') -cne '1' -or $root.Attributes.Count -ne 1 -or $root.ChildNodes.Count -ne 2 -or $root.ChildNodes[0].Name -cne 'Payload' -or $root.ChildNodes[1].Name -cne 'Signature') { throw 'UpdateManifestInvalid'; }
  try { $payload=[Convert]::FromBase64String($root.ChildNodes[0].InnerText); $signature=[Convert]::FromBase64String($root.ChildNodes[1].InnerText); } catch { throw 'UpdateSignatureInvalid'; }
  $rsa=Read-PdvUpdatePublicKey $PublicKeyPath;
  try { if (-not $rsa.VerifyData($payload,[Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'),$signature)) { throw 'UpdateSignatureInvalid'; } } finally { $rsa.Clear(); }
  $release=Read-PdvUpdateXml $payload 16384; $r=$release.DocumentElement;
  $names=@('Version','Channel','PackagePath','Sha256','SizeBytes','IssuedAt','ExpiresAt');
  if ($null -eq $r -or $r.Name -cne 'Release' -or $r.GetAttribute('schemaVersion') -cne '1' -or $r.Attributes.Count -ne 1 -or $r.ChildNodes.Count -ne $names.Count) { throw 'UpdateReleaseInvalid'; }
  $values=@{};
  for ($i=0;$i -lt $names.Count;$i++) { $node=$r.ChildNodes[$i]; if ($node.Name -cne $names[$i] -or $node.Attributes.Count -ne 0 -or $node.ChildNodes.Count -ne 1 -or $node.FirstChild.NodeType -ne [Xml.XmlNodeType]::Text) { throw 'UpdateReleaseInvalid'; }; $values[$names[$i]]=$node.InnerText; }
  if (-not (Test-PdvUpdateVersion $values.Version) -or $values.Channel -cne $Channel -or $values.PackagePath -cne ('/api/pdv-monitor/agent/update/package/'+$values.Version) -or $values.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or $values.SizeBytes -cnotmatch '^[1-9][0-9]{0,7}$') { throw 'UpdateReleaseInvalid'; }
  $size=[long]$values.SizeBytes; if ($size -gt 20971520) { throw 'UpdatePackageSize'; }
  $issued=[DateTimeOffset]::MinValue; $expires=[DateTimeOffset]::MinValue;
  if ($values.IssuedAt -notmatch '(Z|[+-][0-9]{2}:[0-9]{2})$' -or $values.ExpiresAt -notmatch '(Z|[+-][0-9]{2}:[0-9]{2})$' -or -not [DateTimeOffset]::TryParse($values.IssuedAt,[ref]$issued) -or -not [DateTimeOffset]::TryParse($values.ExpiresAt,[ref]$expires)) { throw 'UpdateDatesInvalid'; }
  $now=Get-PdvUpdateNow;
  if ($issued -gt $now.AddMinutes(10) -or $expires -le $now -or $expires -le $issued -or ($expires-$issued).TotalDays -gt 90) { throw 'UpdateManifestExpired'; }
  $values['Newer']=([Version]$values.Version -gt [Version]$CurrentVersion);
  return $values;
}
function Get-PdvUpdateSha256 {
  param([string]$Path);
  $sha=[Security.Cryptography.SHA256]::Create(); $stream=[IO.File]::OpenRead($Path);
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant(); } finally { $stream.Close(); $sha.Clear(); }
}
function Get-PdvUpdateAuthorization {
  param($Session);
  $central=Get-PdvUpdateValue (Get-PdvUpdateValue $Session 'Config') 'Central';
  if ((Get-PdvUpdateValue $central 'Enabled' $false) -ne $true) { throw 'UpdateCentralDisabled'; }
  $agent=[string](Get-PdvUpdateValue $central 'AgentId'); $store=[string](Get-PdvUpdateValue $central 'StoreId'); $terminal=[string](Get-PdvUpdateValue $central 'Terminal');
  if ($agent -notmatch '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' -or $store -notmatch '^[1-9][0-9]{0,3}$' -or $terminal -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'UpdateCentralIdentityInvalid'; }
  $credential=Join-Path ([string](Get-PdvUpdateValue $Session 'DataDirectory')) 'central-credencial.bin';
  if (-not [IO.File]::Exists($credential) -or (New-Object IO.FileInfo($credential)).Length -gt 8192) { throw 'UpdateCredentialUnavailable'; }
  $entropy=[Text.Encoding]::UTF8.GetBytes('FeiraoPdvMonitor|'+$agent+'|'+$store+'|'+$terminal); $plain=$null;
  try { $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($credential),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser); $token=[Text.Encoding]::UTF8.GetString($plain); if ($token -notmatch '^[a-fA-F0-9]{64}$') { throw 'UpdateCredentialUnavailable'; }; return ('Bearer '+$agent+'.'+$token); }
  catch { throw 'UpdateCredentialUnavailable'; }
  finally { if ($null -ne $plain) { [Array]::Clear($plain,0,$plain.Length); }; $token=$null; }
}
function New-PdvUpdateWebRequest { param([string]$Uri); return [Net.WebRequest]::Create($Uri); }
function Invoke-PdvUpdateHttpGet {
  param([string]$Uri,[string]$Authorization,[int]$MaximumBytes,[string]$Destination='');
  $previous=[Net.ServicePointManager]::SecurityProtocol;$tlsLock=[Net.ServicePointManager];$ownsTls=$false; $response=$null; $stream=$null; $output=$null; $memory=$null;
  try {
    $ownsTls=[Threading.Monitor]::TryEnter($tlsLock,2000);if(-not $ownsTls){throw 'UpdateTransportUnavailable';};$previous=[Net.ServicePointManager]::SecurityProtocol;
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]3072;
    $request=New-PdvUpdateWebRequest $Uri; $request.Method='GET'; $request.AllowAutoRedirect=$false; $request.Timeout=10000; $request.ReadWriteTimeout=10000; $request.UseDefaultCredentials=$false; $request.Headers['Authorization']=$Authorization;
    $response=$request.GetResponse(); $code=[int]$response.StatusCode;
    if ($code -eq 204) { return (New-Object PSObject -Property @{StatusCode=204;Bytes=(New-Object byte[] 0);}); }
    if ($code -ne 200 -or $response.ContentLength -gt $MaximumBytes) { throw 'UpdateHttpResponseRejected'; }
    $stream=$response.GetResponseStream();
    if ($Destination) { $output=New-Object IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); }
    else { $memory=New-Object IO.MemoryStream; $output=$memory; }
    $buffer=New-Object byte[] 8192; $total=0L; $started=Get-PdvUpdateNow;
    while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) { $total+=$count; if ($total -gt $MaximumBytes -or ((Get-PdvUpdateNow)-$started).TotalSeconds -gt 120) { throw 'UpdateDownloadLimit'; }; $output.Write($buffer,0,$count); }
    if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) { throw 'UpdateDownloadTruncated'; }
    $bytes=New-Object byte[] 0; if ($null -ne $memory) { $bytes=$memory.ToArray(); }
    return (New-Object PSObject -Property @{StatusCode=200;Bytes=$bytes;});
  } catch { if ($Destination -and [IO.File]::Exists($Destination)) { if ($null -ne $output) { $output.Close(); $output=$null; }; [IO.File]::Delete($Destination); }; throw 'UpdateDownloadUnavailable'; }
  finally { try{if ($null -ne $output) { $output.Close(); }; if ($null -ne $stream) { $stream.Close(); }; if ($null -ne $response) { $response.Close(); }}finally{if($ownsTls){try{[Net.ServicePointManager]::SecurityProtocol=$previous;}finally{[Threading.Monitor]::Exit($tlsLock);}} $Authorization=$null;} }
}

function Initialize-PdvUpdateZipReader {
  if ($null -ne ('Feirao.PdvApprovedZip' -as [type])) { return; }
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
namespace Feirao {
 public static class PdvApprovedZip {
  static ushort U16(byte[] b,int p) { if(p<0 || p>b.Length-2) throw new InvalidDataException("ZipBounds"); return BitConverter.ToUInt16(b,p); }
  static uint U32(byte[] b,int p) { if(p<0 || p>b.Length-4) throw new InvalidDataException("ZipBounds"); return BitConverter.ToUInt32(b,p); }
  static uint Crc(byte[] b) { uint c=0xffffffff; foreach(byte x in b) { c^=x; for(int i=0;i<8;i++) c=(c&1)!=0 ? (c>>1)^0xedb88320 : c>>1; } return c^0xffffffff; }
  public static void Extract(string zip,string destination,string[] allowed) {
   FileInfo fi=new FileInfo(zip); if(fi.Length<22 || fi.Length>20971520) throw new InvalidDataException("ZipSize");
   byte[] b=File.ReadAllBytes(zip); int end=b.Length-22;
   // Pacote oficial não contém comentário, múltiplos discos, ZIP64 ou entradas de diretório.
   if(U32(b,end)!=0x06054b50 || U16(b,end+4)!=0 || U16(b,end+6)!=0 || U16(b,end+20)!=0) throw new InvalidDataException("ZipEnd");
   int count=U16(b,end+10); uint dirSize=U32(b,end+12),dirStart=U32(b,end+16);
   if(count!=allowed.Length || count!=U16(b,end+8) || dirStart+dirSize!=end || dirStart>int.MaxValue) throw new InvalidDataException("ZipDirectory");
   HashSet<string> white=new HashSet<string>(allowed,StringComparer.OrdinalIgnoreCase),seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   List<string> names=new List<string>(); List<byte[]> content=new List<byte[]>(); long total=0; int pos=(int)dirStart; uint localEnd=0;
   for(int index=0;index<count;index++) {
    if(U32(b,pos)!=0x02014b50) throw new InvalidDataException("ZipEntry");
    ushort flags=U16(b,pos+8),method=U16(b,pos+10); uint crc=U32(b,pos+16),compressed=U32(b,pos+20),size=U32(b,pos+24);
    int nl=U16(b,pos+28),extra=U16(b,pos+30),comment=U16(b,pos+32); uint offset=U32(b,pos+42),external=U32(b,pos+38);
    if(U16(b,pos+34)!=0 || (flags & ~0x800)!=0 || (method!=0 && method!=8) || size>4194304 || compressed>20971520 || offset>int.MaxValue || nl<1 || nl>100 || pos+46+nl+extra+comment>end) throw new InvalidDataException("ZipEntryPolicy");
    int unixType=(int)((external>>16)&0xf000); if(unixType!=0 && unixType!=0x8000) throw new InvalidDataException("ZipLinkOrDirectory");
    byte[] nameBytes=new byte[nl]; Array.Copy(b,pos+46,nameBytes,0,nl); foreach(byte c in nameBytes) if(c<33 || c>126) throw new InvalidDataException("ZipNameEncoding");
    string name=System.Text.Encoding.ASCII.GetString(nameBytes);
    if(name.IndexOf('/')>=0 || name.IndexOf('\\')>=0 || name.IndexOf(':')>=0 || !white.Contains(name) || !seen.Add(name)) throw new InvalidDataException("ZipNamePolicy");
    int local=(int)offset;
    if(offset!=localEnd || U32(b,local)!=0x04034b50 || U16(b,local+6)!=flags || U16(b,local+8)!=method || U32(b,local+14)!=crc || U32(b,local+18)!=compressed || U32(b,local+22)!=size || U16(b,local+26)!=nl) throw new InvalidDataException("ZipLocalHeader");
    int localExtra=U16(b,local+28); long start=(long)local+30+nl+localExtra;
    if(start+compressed>dirStart) throw new InvalidDataException("ZipOverlap");
    for(int n=0;n<nl;n++) if(b[local+30+n]!=nameBytes[n]) throw new InvalidDataException("ZipNameMismatch");
    localEnd=(uint)(start+compressed); total+=size; if(total>62914560) throw new InvalidDataException("ZipExpandedLimit");
    byte[] data;
    using(MemoryStream source=new MemoryStream(b,(int)start,(int)compressed,false)) {
     Stream input=source; if(method==8) input=new DeflateStream(source,CompressionMode.Decompress,true);
     using(MemoryStream output=new MemoryStream()) {
      byte[] buffer=new byte[8192]; int read;
      while((read=input.Read(buffer,0,buffer.Length))>0) { if(output.Length+read>size) throw new InvalidDataException("ZipExpansionMismatch"); output.Write(buffer,0,read); }
      data=output.ToArray();
     }
     if(method==8) input.Close();
    }
    if(data.Length!=size || Crc(data)!=crc) throw new InvalidDataException("ZipIntegrity");
    names.Add(name); content.Add(data); pos+=46+nl+extra+comment;
   }
   if(pos!=end || localEnd!=dirStart || seen.Count!=white.Count) throw new InvalidDataException("ZipTrailingData");
   if(Directory.Exists(destination)) throw new InvalidDataException("ZipDestinationExists");
   Directory.CreateDirectory(destination);
   try { for(int i=0;i<names.Count;i++) File.WriteAllBytes(Path.Combine(destination,names[i]),content[i]); }
   catch { Directory.Delete(destination,true); throw; }
  }
 }
}
'@;
}
function Expand-PdvApprovedUpdate {
  param([string]$Zip,[string]$Destination,[string]$Version,[string]$TrustPath);
  Initialize-PdvUpdateZipReader;
  [Feirao.PdvApprovedZip]::Extract($Zip,$Destination,$script:PdvUpdateProgramFiles);
  $versionPath=Join-Path $Destination 'monitor-version.txt';
  if ((New-Object IO.FileInfo($versionPath)).Length -gt 32 -or [IO.File]::ReadAllText($versionPath).Trim() -cne $Version) { throw 'UpdateVersionFileMismatch'; }
  $pinned=Read-PdvUpdatePublicKey $TrustPath; $newKey=Read-PdvUpdatePublicKey (Join-Path $Destination 'atualizacoes-chave-publica.xml');
  try { if ($pinned.ToXmlString($false) -cne $newKey.ToXmlString($false)) { throw 'UpdatePublicKeyChangeRejected'; } }
  finally { $pinned.Clear(); $newKey.Clear(); }
}
function Invoke-PdvMonitorUpdateCheck {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][string]$ProgramDirectory,[string]$CurrentVersion='',[bool]$Enabled=$false);
  if (-not $Enabled) { return (New-PdvUpdateResult $false 'UpdateDisabled'); }
  $authorization=$null; $temporary='';
  try {
    $paths=Get-PdvUpdatePaths ([string](Get-PdvUpdateValue $Session 'DataDirectory'));
    if (-not $CurrentVersion) { $CurrentVersion=Get-PdvUpdateVersion $ProgramDirectory; }
    if (-not (Test-PdvUpdateVersion $CurrentVersion)) { throw 'UpdateCurrentVersionInvalid'; }
    if (-not [IO.File]::Exists($paths.Trust)) { throw 'UpdateTrustNotInstalled'; }
    $central=Get-PdvUpdateValue (Get-PdvUpdateValue $Session 'Config') 'Central'; $endpoint=[string](Get-PdvUpdateValue $central 'Endpoint');
    $origin=New-Object Uri($endpoint,[UriKind]::Absolute);
    if ($origin.Scheme -cne 'https' -or -not $origin.Host -or $origin.UserInfo -or $origin.Query -or $origin.Fragment -or $origin.AbsolutePath -cne '/api/pdv-monitor/ingest') { throw 'UpdateEndpointInvalid'; }
    $authorization=Get-PdvUpdateAuthorization $Session;
    $manifestUri=$origin.GetLeftPart([UriPartial]::Authority)+'/api/pdv-monitor/agent/update?version='+$CurrentVersion+'&channel=piloto';
    $response=Invoke-PdvUpdateHttpGet $manifestUri $authorization 32768;
    if ($response.StatusCode -eq 204) { return (New-PdvUpdateResult $true 'UpdateUpToDate' $CurrentVersion); }
    $release=Test-PdvUpdateManifest $response.Bytes $paths.Trust $CurrentVersion;
    if (-not $release.Newer) { return (New-PdvUpdateResult $true 'UpdateUpToDate' $CurrentVersion); }
    if ([IO.File]::Exists($paths.Failure) -and [IO.File]::ReadAllText($paths.Failure).Trim() -ceq $release.Version) { return (New-PdvUpdateResult $false 'UpdateVersionPreviouslyRolledBack' $release.Version); }
    [void][IO.Directory]::CreateDirectory($paths.Root);
    if ([IO.Directory]::Exists($paths.Stage)) {
      $existing=Join-Path $paths.Stage 'manifest.xml';
      try { $staged=Test-PdvUpdateManifest ([IO.File]::ReadAllBytes($existing)) $paths.Trust $CurrentVersion; if ($staged.Version -ceq $release.Version -and $staged.Sha256 -ceq $release.Sha256) { return (New-PdvUpdateResult $true 'UpdateStaged' $release.Version $true); } } catch { }
      [IO.Directory]::Delete($paths.Stage,$true);
    }
    $temporary=Join-Path $paths.Root ('recebendo-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($temporary);
    $zip=Join-Path $temporary 'package.zip';
    $packageUri=$origin.GetLeftPart([UriPartial]::Authority)+$release.PackagePath;
    $download=Invoke-PdvUpdateHttpGet $packageUri $authorization ([int]$release.SizeBytes) $zip;
    if ($download.StatusCode -ne 200 -or (New-Object IO.FileInfo($zip)).Length -ne [long]$release.SizeBytes -or (Get-PdvUpdateSha256 $zip) -cne $release.Sha256) { throw 'UpdatePackageIntegrity'; }
    Expand-PdvApprovedUpdate $zip (Join-Path $temporary 'programa') $release.Version $paths.Trust;
    [IO.File]::WriteAllBytes((Join-Path $temporary 'manifest.xml'),$response.Bytes);
    [IO.Directory]::Move($temporary,$paths.Stage); $temporary='';
    return (New-PdvUpdateResult $true 'UpdateStaged' $release.Version $true);
  } catch {
    $reason=$_.Exception.Message; if ($reason -notmatch '^Update[A-Za-z]+$') { $reason='UpdateCheckFailed'; }
    return (New-PdvUpdateResult $false $reason);
  } finally { $authorization=$null; if ($temporary -and [IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary,$true); } }
}
function Start-PdvUpdateHelperProcess {
  param([string]$Script,[string]$Data,[string]$Program,[int]$ParentPid);
  foreach ($path in @($Script,$Data,$Program)) { if ($path.IndexOf('"') -ge 0 -or $path -match '[\r\n]') { throw 'UpdatePathInvalid'; } }
  $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
  return (Start-Process -FilePath $exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Script+'" -DataDirectory "'+$Data+'" -ProgramDirectory "'+$Program+'" -ParentProcessId '+$ParentPid) -WindowStyle Hidden -PassThru);
}
function Start-PdvMonitorUpdateApply {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][string]$ProgramDirectory,[bool]$Enabled=$false,[bool]$OperationsIdle=$false);
  if (-not $Enabled) { return (New-PdvUpdateResult $false 'UpdateDisabled'); }
  if ([bool](Get-PdvUpdateValue $Session 'RemoteBusy' $false) -or -not $OperationsIdle -or [bool](Get-PdvUpdateValue $Session 'TickBusy' $false)) { return (New-PdvUpdateResult $false 'UpdateWaitingMonitorIdle'); }
  try {
    $paths=Get-PdvUpdatePaths ([string](Get-PdvUpdateValue $Session 'DataDirectory'));
    if (-not [IO.Directory]::Exists($paths.Stage)) { return (New-PdvUpdateResult $false 'UpdateNotStaged'); }
    $program=[IO.Path]::GetFullPath($ProgramDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar);
    if ($program -cne [IO.Path]::GetFullPath((Join-Path $paths.Data 'programa')).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)) { throw 'UpdateProgramMustBeInstalled'; }
    $release=Test-PdvUpdateManifest ([IO.File]::ReadAllBytes((Join-Path $paths.Stage 'manifest.xml'))) $paths.Trust (Get-PdvUpdateVersion $program);
    if (-not $release.Newer) { throw 'UpdateNotNewer'; }
    if ((Get-PdvUpdateSha256 (Join-Path $paths.Stage 'package.zip')) -cne $release.Sha256) { throw 'UpdatePackageIntegrity'; }
    [void][IO.Directory]::CreateDirectory($paths.Runner);
    foreach ($file in @('AplicarAtualizacao.ps1','PdvMonitor.Atualizacao.psm1')) { [IO.File]::Copy((Join-Path $program $file),(Join-Path $paths.Runner $file),$true); }
    $process=Start-PdvUpdateHelperProcess (Join-Path $paths.Runner 'AplicarAtualizacao.ps1') $paths.Data $program $PID;
    if ($null -eq $process) { throw 'UpdateHelperNotStarted'; }
    return (New-PdvUpdateResult $true 'UpdateRestartingMonitor' $release.Version $true $true);
  } catch { $reason=$_.Exception.Message; if ($reason -notmatch '^Update[A-Za-z]+$') { $reason='UpdateApplyLaunchFailed'; }; return (New-PdvUpdateResult $false $reason); }
}
function Write-PdvMonitorUpdateHealth {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][string]$ProgramDirectory,[bool]$TickHealthy=$false);
  if (-not $TickHealthy -or -not [bool](Get-PdvUpdateValue $Session 'LoggingHealthy' $false)) { return $false; }
  try {
    $paths=Get-PdvUpdatePaths ([string](Get-PdvUpdateValue $Session 'DataDirectory'));
    if (-not [IO.File]::Exists($paths.PendingHealth)) { return $false; }
    $xml=Read-PdvUpdateXml ([IO.File]::ReadAllBytes($paths.PendingHealth)) 4096; $r=$xml.DocumentElement;
    if ($r.Name -cne 'Health' -or $r.Attributes.Count -ne 3 -or $r.ChildNodes.Count -ne 0 -or $r.GetAttribute('token') -notmatch '^[a-f0-9]{32}$' -or $r.GetAttribute('version') -cne (Get-PdvUpdateVersion $ProgramDirectory)) { return $false; }
    $manifest=Join-Path $paths.Stage 'manifest.xml'; $release=Test-PdvUpdateManifest ([IO.File]::ReadAllBytes($manifest)) $paths.Trust '0.0.0';
    if ($release.Version -cne $r.GetAttribute('version') -or $release.Sha256 -cne $r.GetAttribute('hash') -or $r.GetAttribute('hash') -notmatch '^[a-f0-9]{64}$') { return $false; }
    Write-PdvUpdateText $paths.Health $r.OuterXml; return $true;
  } catch { return $false; }
}
function Write-PdvUpdateApplyState {
  param($Paths,[string]$Status,[string]$Version,[string]$Reason);
  $xml=New-Object Xml.XmlDocument; $r=$xml.CreateElement('Update'); [void]$xml.AppendChild($r);
  foreach ($pair in @(@('status',$Status),@('version',$Version),@('reason',$Reason),@('at',(Get-PdvUpdateNow).ToString('o')))) { $r.SetAttribute($pair[0],$pair[1]); }
  Write-PdvUpdateText $Paths.State $xml.OuterXml;
}
function Wait-PdvUpdateParent {
  param([int]$ParentProcessId);
  try { $parent=[Diagnostics.Process]::GetProcessById($ParentProcessId); } catch { return $true; }
  try { return $parent.WaitForExit(45000); } finally { $parent.Dispose(); }
}
function Start-PdvUpdatedMonitorProcess {
  param([string]$Program,[string]$Data);
  foreach ($path in @($Program,$Data)) { if ($path.IndexOf('"') -ge 0 -or $path -match '[\r\n]') { throw 'UpdatePathInvalid'; } }
  $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';
  return (Start-Process -FilePath $exe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $Program 'MonitorPdv.ps1')+'" -StartHidden -DataDirectory "'+$Data+'"') -WorkingDirectory $Data -WindowStyle Hidden -PassThru);
}
function Wait-PdvUpdateHealth {
  param($Paths,$Process,[string]$Token,[string]$Version,[string]$Hash);
  $deadline=(Get-PdvUpdateNow).AddSeconds(90);
  while ((Get-PdvUpdateNow) -lt $deadline) {
    if ($Process.HasExited) { return $false; }
    if ([IO.File]::Exists($Paths.Health)) {
      try { $xml=Read-PdvUpdateXml ([IO.File]::ReadAllBytes($Paths.Health)) 4096; $r=$xml.DocumentElement; if ($r.Name -ceq 'Health' -and $r.ChildNodes.Count -eq 0 -and $r.Attributes.Count -eq 3 -and $r.GetAttribute('token') -ceq $Token -and $r.GetAttribute('version') -ceq $Version -and $r.GetAttribute('hash') -ceq $Hash) { return $true; } } catch { }
    }
    Start-Sleep -Milliseconds 500;
  }
  return $false;
}
function Stop-PdvUpdatedMonitorProcess {
  param($Process,[DateTime]$ExpectedStart);
  # Apenas o filho iniciado por este executor. O objeto Process mantém o handle original;
  # StartTime e executável também devem coincidir antes de encerrar o monitor novo.
  if ($null -eq $Process -or $Process.HasExited) { return $true; }
  $expectedExe=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'));
  if ($Process.StartTime -ne $ExpectedStart -or -not [string]::Equals($Process.MainModule.FileName,$expectedExe,[StringComparison]::OrdinalIgnoreCase)) { return $false; }
  $Process.Kill(); return $Process.WaitForExit(10000);
}
function Write-PdvUpdateBackupManifest {
  param([string]$Program,$Paths,[string]$TargetVersion);
  if (-not [IO.Directory]::Exists($Program) -or (([IO.File]::GetAttributes($Program) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or [IO.Directory]::GetDirectories($Program).Length -ne 0) { throw 'UpdateBackupDirectoryInvalid'; }
  $files=[IO.Directory]::GetFiles($Program);
  if ($files.Length -ne $script:PdvUpdateProgramFiles.Length) { throw 'UpdateBackupFilesInvalid'; }
  $xml=New-Object Xml.XmlDocument; $root=$xml.CreateElement('PdvMonitorBackup'); [void]$xml.AppendChild($root); $root.SetAttribute('schemaVersion','1'); $root.SetAttribute('version',(Get-PdvUpdateVersion $Program)); $root.SetAttribute('targetVersion',$TargetVersion);
  foreach ($name in $script:PdvUpdateProgramFiles) {
    $path=Join-Path $Program $name;
    if (-not [IO.File]::Exists($path) -or (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'UpdateBackupFilesInvalid'; }
    $size=(New-Object IO.FileInfo($path)).Length; if ($size -gt 4194304) { throw 'UpdateBackupFilesInvalid'; }
    $entry=$xml.CreateElement('File'); $entry.SetAttribute('name',$name); $entry.SetAttribute('sha256',(Get-PdvUpdateSha256 $path)); $entry.SetAttribute('sizeBytes',[string]$size); [void]$root.AppendChild($entry);
  }
  Write-PdvUpdateText (Join-Path $Paths.Root 'backup-manifest.xml') $xml.OuterXml;
}
function Update-PdvStableBootstrap {
  param([string]$Program,$Paths);
  $source=Join-Path $Program 'IniciarMonitorInstalado.ps1'; $destination=Join-Path $Paths.Data 'IniciarMonitorInstalado.ps1';
  $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'; $backup=$temporary+'.bak';
  try {
    # Preserva BOM/bytes da versão assinada. Troca atômica só depois da confirmação.
    [IO.File]::WriteAllBytes($temporary,[IO.File]::ReadAllBytes($source));
    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($temporary,$destination,$backup); } else { [IO.File]::Move($temporary,$destination); }
  } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary); }; if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup); } }
}
function Invoke-PdvUpdateApplyInternal {
  param([string]$DataDirectory,[string]$ProgramDirectory,[int]$ParentProcessId);
  $paths=Get-PdvUpdatePaths $DataDirectory; $lock=$null; $child=$null; $oldMoved=$false; $newMoved=$false; $version=''; $backup=Join-Path $paths.Root 'backup'; $candidate=Join-Path $paths.Root 'candidato';
  try {
    if ($ParentProcessId -le 0) { throw 'UpdateParentInvalid'; }
    $program=[IO.Path]::GetFullPath($ProgramDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar);
    if ($program -cne [IO.Path]::GetFullPath((Join-Path $paths.Data 'programa')).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)) { throw 'UpdateProgramMustBeInstalled'; }
    $lock=New-Object IO.FileStream((Join-Path $paths.Root 'aplicando.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);
    $release=Test-PdvUpdateManifest ([IO.File]::ReadAllBytes((Join-Path $paths.Stage 'manifest.xml'))) $paths.Trust (Get-PdvUpdateVersion $program); $version=$release.Version;
    if (-not $release.Newer) { throw 'UpdateNotNewer'; }
    $zip=Join-Path $paths.Stage 'package.zip';
    if ((New-Object IO.FileInfo($zip)).Length -ne [long]$release.SizeBytes -or (Get-PdvUpdateSha256 $zip) -cne $release.Sha256) { throw 'UpdatePackageIntegrity'; }
    if ([IO.Directory]::Exists($candidate)) { [IO.Directory]::Delete($candidate,$true); }
    Expand-PdvApprovedUpdate $zip $candidate $version $paths.Trust;
    if (-not (Wait-PdvUpdateParent $ParentProcessId)) { throw 'UpdateParentStillRunning'; }
    Set-Location -LiteralPath $paths.Data;
    if ([IO.Directory]::Exists($backup)) { [IO.Directory]::Delete($backup,$true); }
    if ([IO.File]::Exists($paths.Health)) { [IO.File]::Delete($paths.Health); }
    Write-PdvUpdateBackupManifest $program $paths $version;
    $token=[guid]::NewGuid().ToString('N'); $pending=New-Object Xml.XmlDocument; $r=$pending.CreateElement('Health'); [void]$pending.AppendChild($r); $r.SetAttribute('token',$token); $r.SetAttribute('version',$version); $r.SetAttribute('hash',$release.Sha256);
    Write-PdvUpdateText $paths.PendingHealth $pending.OuterXml;
    Write-PdvUpdateApplyState $paths 'applying' $version 'UpdateReplacingMonitor';
    [IO.Directory]::Move($program,$backup); $oldMoved=$true;
    [IO.Directory]::Move($candidate,$program); $newMoved=$true;
    $child=Start-PdvUpdatedMonitorProcess $program $paths.Data; $childStart=$child.StartTime;
    if (-not (Wait-PdvUpdateHealth $paths $child $token $version $release.Sha256)) {
      if (-not (Stop-PdvUpdatedMonitorProcess $child $childStart)) { throw 'UpdateChildIdentityUncertain'; }
      throw 'UpdateHealthNotConfirmed';
    }
    $installedReason='UpdateHealthConfirmed';
    try { Update-PdvStableBootstrap $program $paths; } catch { $installedReason='UpdateHealthConfirmedBootstrapRetained'; }
    Write-PdvUpdateApplyState $paths 'installed' $version $installedReason;
    [IO.File]::Delete($paths.PendingHealth); [IO.Directory]::Delete($paths.Stage,$true);
    if ([IO.File]::Exists($paths.Failure)) { [IO.File]::Delete($paths.Failure); }
    return (New-PdvUpdateResult $true 'UpdateInstalled' $version);
  } catch {
    $reason=$_.Exception.Message; if ($reason -notmatch '^Update[A-Za-z]+$') { $reason='UpdateApplyFailed'; }
    if ($oldMoved -and $reason -ne 'UpdateChildIdentityUncertain') {
      # A candidata só é removida depois que o processo filho parou ou nunca iniciou.
      if ($null -ne $child -and -not $child.HasExited) { $reason='UpdateChildIdentityUncertain'; }
      else {
        try {
          if ($newMoved -and [IO.Directory]::Exists($program)) { [IO.Directory]::Delete($program,$true); }
          [IO.Directory]::Move($backup,$program);
          Write-PdvUpdateText $paths.Failure $version;
          if ([IO.File]::Exists($paths.PendingHealth)) { [IO.File]::Delete($paths.PendingHealth); }
          Write-PdvUpdateApplyState $paths 'rolledBack' $version $reason;
          [void](Start-PdvUpdatedMonitorProcess $program $paths.Data);
          return (New-PdvUpdateResult $false 'UpdateRolledBack' $version);
        } catch { $reason='UpdateRollbackFailed'; }
      }
    }
    if ($null -ne $lock) { try { Write-PdvUpdateApplyState $paths 'failed' $version $reason; } catch { }; if (-not $oldMoved -and (Wait-PdvUpdateParent $ParentProcessId)) { try { [void](Start-PdvUpdatedMonitorProcess $program $paths.Data); } catch { } } }
    return (New-PdvUpdateResult $false $reason $version);
  } finally { if ($null -ne $lock) { $lock.Close(); }; if ($null -ne $child) { $child.Dispose(); } }
}
Export-ModuleMember -Function Initialize-PdvMonitorUpdateTrust, Invoke-PdvMonitorUpdateCheck, Start-PdvMonitorUpdateApply, Write-PdvMonitorUpdateHealth;
