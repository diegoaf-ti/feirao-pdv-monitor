#requires -Version 2.0
# Transporte opcional do piloto; material sensivel existe somente na memoria.
# Nenhum corpo HTTP, nonce, credencial ou objeto Work integra logs/exportacao.
Set-StrictMode -Version 2.0;
$script:remoteDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path;
$script:remoteCentralModule=Import-Module (Join-Path $script:remoteDirectory 'PdvMonitor.Transporte.psm1') -PassThru;
$script:remoteBrokerModule=Import-Module (Join-Path $script:remoteDirectory 'PdvMonitor.Remoto.psm1') -PassThru;

function Test-PdvRemoteTransportId {
  param($Value);
  return ($Value -is [string] -and $Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and $Value -cne '00000000-0000-0000-0000-000000000000');
}

function ConvertFrom-PdvRemoteWireXml {
  param([byte[]]$Bytes,[string]$Kind);
  if($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 8192){throw 'RemoteResponseInvalid';}
  $fields=@();$rootName='';$version='';
  switch($Kind){
    'Request'{$rootName='PdvRemoteRequest';$fields=@('SessionId','AgentId','RequestId','RequestedAt','ExpiresAt','SessionMaxSeconds','Mode','TechnicianId','TechnicianName','Reason','Nonce');}
    'Session'{$rootName='PdvRemoteSession';$fields=@('Id','Status','ExpiresAt','ConsentExpiresAt');}
    'Lease'{$rootName='PdvRemoteLease';$version='1';$fields=@('SessionId','AgentId','RepeaterId','CertificateSha256','ExpiresAt','State');}
    default{throw 'RemoteOperationInvalid';}
  }
  $stream=New-Object IO.MemoryStream(,$Bytes);$reader=$null;
  try{
    $settings=New-Object Xml.XmlReaderSettings;$settings.ProhibitDtd=$true;$settings.XmlResolver=$null;$settings.IgnoreWhitespace=$true;
    $reader=[Xml.XmlReader]::Create($stream,$settings);$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);
    $root=$xml.DocumentElement;$attributeCount=0;if($version){$attributeCount=1;}
    if($null -eq $root -or $root.Name -cne $rootName -or $root.NamespaceURI -or $root.Attributes.Count -ne $attributeCount -or ($version -and $root.GetAttribute('schemaVersion') -cne $version) -or $root.ChildNodes.Count -ne $fields.Count){throw 'Invalid';}
    $values=@{};
    foreach($node in $root.ChildNodes){
      if($node.NodeType -ne [Xml.XmlNodeType]::Element -or $node.NamespaceURI -or $fields -cnotcontains $node.Name -or $values.ContainsKey($node.Name) -or $node.Attributes.Count -ne 0){throw 'Invalid';}
      foreach($child in $node.ChildNodes){if($child.NodeType -ne [Xml.XmlNodeType]::Text){throw 'Invalid';}}
      $values[$node.Name]=[string]$node.InnerText;
    }
    if($Kind -ceq 'Request'){
      $seconds=0;if($values.SessionMaxSeconds -cnotmatch '^[0-9]{2,3}$' -or -not [int]::TryParse($values.SessionMaxSeconds,[ref]$seconds) -or $seconds -lt 30 -or $seconds -gt 900){throw 'Invalid';};$values.SessionMaxSeconds=$seconds;
      # Validacao completa de datas, texto e nonce pertence ao broker antes de gravar.
      if(-not (Test-PdvRemoteTransportId $values.SessionId) -or -not (Test-PdvRemoteTransportId $values.AgentId) -or $values.RequestId -cne $values.SessionId){throw 'Invalid';}
    }elseif($Kind -ceq 'Session'){
      if(-not (Test-PdvRemoteTransportId $values.Id) -or @('pending_consent','approved','active','ending','closed','ended','failed','cancelled','expired','denied') -cnotcontains $values.Status){throw 'Invalid';}
      foreach($key in @('ExpiresAt','ConsentExpiresAt')){if($values[$key]){[void](& $script:remoteBrokerModule {param($Value);ConvertTo-PdvRemoteDate $Value;} $values[$key]);}}
      if(-not $values.ConsentExpiresAt){throw 'Invalid';}
    }else{
      if(-not (Test-PdvRemoteTransportId $values.SessionId) -or -not (Test-PdvRemoteTransportId $values.AgentId) -or $values.RepeaterId -cnotmatch '^[1-9][0-9]{0,8}$' -or $values.CertificateSha256 -cnotmatch '^[0-9a-f]{64}$' -or @('pending','ready','connected','closed') -cnotcontains $values.State){throw 'Invalid';}
      [void](& $script:remoteBrokerModule {param($Value);ConvertTo-PdvRemoteDate $Value;} $values.ExpiresAt);
    }
    return $values;
  }catch{throw 'RemoteResponseInvalid';}finally{if($null -ne $reader){$reader.Close();};$stream.Close();}
}

function New-PdvRemoteWireWork {
  param([string]$Operation,$Payload=$null);
  $uri='';$method='GET';$kind='';$body='';
  switch($Operation){
    'Request'{$uri='/agent/remote/request';$kind='Request';if($null -ne $Payload){throw 'RemoteOperationInvalid';}}
    'Lease'{$uri='/agent/remote/lease';$kind='Lease';if($null -ne $Payload){throw 'RemoteOperationInvalid';}}
    'Session'{
      if($Payload -isnot [Collections.IDictionary] -or $Payload.Count -ne 1 -or -not $Payload.Contains('sessionId') -or -not (Test-PdvRemoteTransportId $Payload.sessionId)){throw 'RemoteOperationInvalid';}
      $uri='/agent/remote/sessions/'+$Payload.sessionId;$kind='Session';
    }
    'Consent'{
      if($Payload -isnot [Collections.IDictionary] -or $Payload.Count -ne 4){throw 'RemoteOperationInvalid';}
      foreach($key in @('sessionId','requestId','nonce','decision')){if(-not $Payload.Contains($key)){throw 'RemoteOperationInvalid';}}
      if(-not (Test-PdvRemoteTransportId $Payload.sessionId) -or $Payload.requestId -cne $Payload.sessionId -or @('approved','denied') -cnotcontains $Payload.decision -or -not (& $script:remoteBrokerModule {param($Value);Test-PdvRemoteNonce $Value;} $Payload.nonce)){throw 'RemoteOperationInvalid';}
      # Estes campos foram validados e nao admitem aspas/controle. Nao ha JSON livre.
      $body='{"sessionId":"'+$Payload.sessionId+'","requestId":"'+$Payload.requestId+'","nonce":"'+$Payload.nonce+'","decision":"'+$Payload.decision+'"}';
      $method='POST';$uri='/agent/remote/consent';$kind='Session';
    }
    'Closed'{
      if($Payload -isnot [Collections.IDictionary] -or $Payload.Count -ne 2 -or -not $Payload.Contains('sessionId') -or -not $Payload.Contains('status') -or -not (Test-PdvRemoteTransportId $Payload.sessionId) -or $Payload.status -cne 'closed'){throw 'RemoteOperationInvalid';}
      $body='{"sessionId":"'+$Payload.sessionId+'","status":"closed"}';$method='POST';$uri='/agent/remote/status';$kind='Session';
    }
    default{throw 'RemoteOperationInvalid';}
  }
  return @{RelativePath=$uri;Method=$method;Kind=$kind;Body=$body};
}

function Wait-PdvRemoteHttpBudget {
  param($Pending,$Clock);
  $remaining=4000-[int]$Clock.ElapsedMilliseconds;
  if($remaining -lt 1 -or -not $Pending.AsyncWaitHandle.WaitOne($remaining,$false)){throw 'RemoteTransportTimeout';}
}

function Invoke-PdvRemoteBoundedHttp {
  param([string]$Endpoint,[string]$Authorization,[string]$Method,[byte[]]$Body);
  $previous=[Net.ServicePointManager]::SecurityProtocol;$tlsLock=[Net.ServicePointManager];$ownsTls=$false;$response=$null;$stream=$null;$request=$null;$clock=New-Object Diagnostics.Stopwatch;$clock.Start();
  try{
    $ownsTls=[Threading.Monitor]::TryEnter($tlsLock,2000);if(-not $ownsTls){throw 'RemoteTransportUnavailable';};$previous=[Net.ServicePointManager]::SecurityProtocol;
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]3072;
    $request=[Net.WebRequest]::Create($Endpoint);$request.Method=$Method;$request.AllowAutoRedirect=$false;$request.Timeout=4000;$request.ReadWriteTimeout=4000;
    $request.UseDefaultCredentials=$false;$request.PreAuthenticate=$false;$request.AutomaticDecompression=[Net.DecompressionMethods]::None;
    $request.Accept='application/xml';$request.Headers['Authorization']=$Authorization;$request.Headers['Cache-Control']='no-store';$request.KeepAlive=$false;
    if($Method -ceq 'POST'){
      $request.ContentType='application/json; charset=utf-8';$request.ContentLength=$Body.Length;
      $pending=$request.BeginGetRequestStream($null,$null);try{Wait-PdvRemoteHttpBudget $pending $clock;$stream=$request.EndGetRequestStream($pending);}finally{$pending.AsyncWaitHandle.Close();}
      $pending=$stream.BeginWrite($Body,0,$Body.Length,$null,$null);try{Wait-PdvRemoteHttpBudget $pending $clock;$stream.EndWrite($pending);}finally{$pending.AsyncWaitHandle.Close();}
      $stream.Close();$stream=$null;
    }
    try{
      $pending=$request.BeginGetResponse($null,$null);try{Wait-PdvRemoteHttpBudget $pending $clock;$response=$request.EndGetResponse($pending);}finally{$pending.AsyncWaitHandle.Close();}
    }catch [Net.WebException]{if($null -ne $_.Exception.Response){$response=$_.Exception.Response;}else{throw 'RemoteTransportUnavailable';}}
    $status=[int]$response.StatusCode;if($status -ne 200){return @{Status=$status;Bytes=$null;ContentType=''};}
    if($response.ContentLength -gt 8192 -or $response.Headers['Content-Encoding']){throw 'RemoteResponseInvalid';}
    $contentType=[string]$response.ContentType;if($contentType -cnotmatch '^application/xml(\s*;\s*charset=(utf-8|UTF-8))?$'){throw 'RemoteResponseInvalid';}
    $stream=$response.GetResponseStream();$memory=New-Object IO.MemoryStream;$buffer=New-Object byte[] 1024;
    try{
      while($true){
        $pending=$stream.BeginRead($buffer,0,$buffer.Length,$null,$null);try{Wait-PdvRemoteHttpBudget $pending $clock;$read=$stream.EndRead($pending);}finally{$pending.AsyncWaitHandle.Close();}
        if($read -le 0){break;};if($memory.Length+$read -gt 8192){throw 'RemoteResponseInvalid';};$memory.Write($buffer,0,$read);
      };return @{Status=$status;Bytes=$memory.ToArray();ContentType=$contentType};
    }finally{$memory.Close();[Array]::Clear($buffer,0,$buffer.Length);}
  }catch{throw 'RemoteTransportUnavailable';}finally{
    # Abort encerra tambem DNS/conexao/leitura ainda pendente apos o prazo total.
    try{if($null -ne $request){$request.Abort();};if($null -ne $stream){$stream.Close();};if($null -ne $response){$response.Close();}}
    finally{if($ownsTls){try{[Net.ServicePointManager]::SecurityProtocol=$previous;}finally{[Threading.Monitor]::Exit($tlsLock);}}$Authorization=$null;$clock.Stop();}
  }
}

function Invoke-PdvMonitorRemoteExchange {
  param($Session,[string]$Operation,$Payload=$null);
  $authorization=$null;$token=$null;$work=$null;$body=$null;
  try{
    $work=New-PdvRemoteWireWork $Operation $Payload;
    $identity=& $script:remoteCentralModule {
      param($CurrentSession);
      $central=Get-PdvCentralConfig $CurrentSession;
      if(-not (Get-PdvTransportValue $central 'Enabled' $false) -or -not (Test-PdvCentralIdentity ([string]$central.Endpoint) ([string]$central.StoreId) ([string]$central.Terminal) ([string]$central.AgentId))){throw 'Invalid';}
      $paths=Get-PdvTransportPaths $CurrentSession;$token=Unprotect-PdvMonitorToken ([IO.File]::ReadAllBytes($paths.Credential)) $central;
      if($token -cnotmatch '^[0-9a-fA-F]{64}$'){throw 'Invalid';}
      return @{Endpoint=([string]$central.Endpoint).Substring(0,([string]$central.Endpoint).Length-7);AgentId=[string]$central.AgentId;Token=$token};
    } $Session;
    $token=$identity.Token;$identity.Token=$null;$authorization='Bearer '+$identity.AgentId+'.'+$token;
    $body=[Text.Encoding]::UTF8.GetBytes([string]$work.Body);
    $result=Invoke-PdvRemoteBoundedHttp ($identity.Endpoint+$work.RelativePath) $authorization $work.Method $body;
    if($result.Status -eq 204 -and @('Request','Lease') -ccontains $Operation){return @{Success=$true;Reason='RemoteNoWork';Status=204;Value=$null};}
    if($result.Status -ne 200){return @{Success=$false;Reason='RemoteHttpFailure';Status=[int]$result.Status;Value=$null};}
    $value=ConvertFrom-PdvRemoteWireXml $result.Bytes $work.Kind;
    if($work.Kind -cne 'Session' -and $value.AgentId -cne $identity.AgentId){throw 'Invalid';}
    if($work.Kind -ceq 'Session' -and $value.Id -cne $Payload.sessionId){throw 'Invalid';}
    return @{Success=$true;Reason='RemoteAcknowledged';Status=200;Value=$value};
  }catch{return @{Success=$false;Reason='RemoteExchangeFailed';Status=0;Value=$null};}
  finally{$authorization=$null;$token=$null;$Payload=$null;if($null -ne $work){$work.Body='';};if($null -ne $body){[Array]::Clear($body,0,$body.Length);}}
}

function Get-PdvRemoteControllerNow { return [DateTimeOffset]::UtcNow; }

function Get-PdvRemoteControllerField {
  param($Object,[string]$Name,$Default=$null);
  if($null -eq $Object){return ,$Default;}
  if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return ,$Object[$Name];}}
  else{$property=$Object.PSObject.Properties[$Name];if($null -ne $property){return ,$property.Value;}}
  return ,$Default;
}

function Get-PdvRemoteAdministrativeModulePath {
  # Caminho unico e administrativo; nao procura uma copia gravavel no perfil do usuario.
  $root=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData);
  if(-not $root){throw 'RemoteExtensionUnavailable';}
  return (Join-Path $root 'Feirao\PdvMonitorRemoto\app\PdvMonitor.Remoto.Windows.psm1');
}

function Test-PdvRemoteAdministrativeAclEvidence {
  param([string]$OwnerSid,$Rules,[bool]$Ancestor=$false,[string]$TrustedInstallerSid='');
  $trusted=@('S-1-5-18','S-1-5-32-544');if($Ancestor -and $TrustedInstallerSid){$trusted+=,$TrustedInstallerSid;}
  if($trusted -cnotcontains $OwnerSid){throw 'RemoteExtensionUntrusted';}
  $rights=[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
  if(-not $Ancestor){$rights=$rights -bor [Security.AccessControl.FileSystemRights]::Write;}
  foreach($rule in @($Rules)){
    if($null -eq $rule -or $rule -isnot [Collections.IDictionary] -or $rule.Count -ne 4 -or -not $rule.Contains('Sid') -or -not $rule.Contains('Allow') -or -not $rule.Contains('Rights') -or -not $rule.Contains('InheritOnly') -or $rule.Sid -isnot [string] -or $rule.Allow -isnot [bool] -or $rule.Rights -isnot [int] -or $rule.InheritOnly -isnot [bool]){throw 'RemoteExtensionUntrusted';}
    if(-not $rule.InheritOnly -and $rule.Allow -and ($rule.Rights -band $rights) -ne 0 -and $trusted -cnotcontains $rule.Sid){throw 'RemoteExtensionUntrusted';}
  };return $true;
}

function Assert-PdvRemoteAdministrativeModule {
  param([string]$Path);
  try{
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not $Path -or $Path.StartsWith('\\') -or -not [IO.Path]::IsPathRooted($Path)){throw 'Invalid';}
    $full=[IO.Path]::GetFullPath($Path);$expected=[IO.Path]::GetFullPath((Get-PdvRemoteAdministrativeModulePath));
    if($full -ine $expected -or -not [IO.File]::Exists($full) -or (New-Object IO.FileInfo($full)).Length -gt 1048576){throw 'Invalid';}
    $installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$installerSid=$installer.Translate([Security.Principal.SecurityIdentifier]).Value;
    $probe=$full;$depth=0;
    while($probe){
      if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Invalid';}
      $acl=Get-Acl -LiteralPath $probe -ErrorAction Stop;$rules=@();
      foreach($entry in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        $rules+=,@{Sid=[string]$entry.IdentityReference.Value;Allow=($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow);Rights=[int]$entry.FileSystemRights;InheritOnly=(($entry.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0)};
      }
      [void](Test-PdvRemoteAdministrativeAclEvidence ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) $rules ($depth -ge 2) $installerSid);
      $parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;$depth++;
    };return $full;
  }catch{throw 'RemoteExtensionUntrusted';}
}

function Assert-PdvRemoteAdministrativeSingleLink {
  param($Stream);
  try{
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Invalid';}
    if($null -eq ('Conecta.PdvRemoteBootstrap.FileLinks' -as [type])){
      $source=@'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Conecta.PdvRemoteBootstrap {
  public static class FileLinks {
    [StructLayout(LayoutKind.Sequential)] private struct FileInformation {
      public uint Attributes, CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
      public uint VolumeSerial, SizeHigh, SizeLow, NumberOfLinks, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
    public static bool SingleLink(SafeFileHandle handle) {
      FileInformation information;
      return handle != null && !handle.IsInvalid && GetFileInformationByHandle(handle, out information) && information.NumberOfLinks == 1;
    }
  }
}
'@
      Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop;
    }
    if(-not [Conecta.PdvRemoteBootstrap.FileLinks]::SingleLink($Stream.SafeFileHandle)){throw 'Invalid';};return $true;
  }catch{throw 'RemoteExtensionUntrusted';}
}

function Import-PdvRemoteAdministrativeWindowsModule {
  param([string]$Path);
  $full=Assert-PdvRemoteAdministrativeModule $Path;$stream=$null;
  try{
    # A verificacao vem antes da importacao e a trava impede substituicao durante a leitura.
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);
    [void](Assert-PdvRemoteAdministrativeSingleLink $stream);
    return (Import-Module $full -PassThru);
  }finally{if($null -ne $stream){$stream.Close();}}
}

function Get-PdvRemotePreparationReason {
  param($Exception);
  $reasons=@{
    'RemoteExtensionUntrusted'='RemoteExtensionUntrusted';
    'RemoteWindowsClr4Required'='RemotePrerequisitesMissing';
    'RemoteWindowsDotNetRequired'='RemotePrerequisitesMissing';
    'RemoteWindowsRuntimeUnknown'='RemotePrerequisitesMissing';
    'RemoteWindowsUnavailable'='RemotePrerequisitesMissing';
    'RemoteWindowsPlatformUnsupported'='RemotePrerequisitesMissing';
    'RemoteWindowsPlatformProfileMismatch'='RemotePrerequisitesMissing';
    'RemoteIdentityMismatch'='RemoteCentralConfigurationRequired';
  };
  $current=$Exception;
  for($index=0;$index -lt 8 -and $null -ne $current;$index++){
    $message=[string]$current.Message;if($reasons.Contains($message)){return $reasons[$message];};$current=$current.InnerException;
  };return 'RemotePreparationBlocked';
}

function New-PdvMonitorRemoteController {
  param($Session,[string]$ProgramDirectory);
  $controller=@{Enabled=$false;Reason='RemoteExtensionNotInstalled';Broker=$null;Windows=$null;WindowsModule=$null;NextPollAt=[DateTimeOffset]::MinValue;Lease=$null;LeaseVerifiedAt=$null;CentralExpiresAt='';PromptBusy=$false;Paused=$false;Busy=$false;Stopping=$false;};
  try{
    $path=Get-PdvRemoteAdministrativeModulePath;
    if(-not [IO.File]::Exists($path)){return $controller;}
    $windowsModule=Import-PdvRemoteAdministrativeWindowsModule $path;
    $configuration=& $windowsModule {param($Directory);Read-PdvMonitorRemoteWindowsConfiguration -DataDirectory $Directory;} $Session.DataDirectory;
    if(-not [bool](Get-PdvRemoteControllerField $configuration 'Enabled' $false)){$controller.Reason='RemoteDisabled';return $controller;}
    $central=& $script:remoteCentralModule {param($CurrentSession);Get-PdvCentralConfig $CurrentSession;} $Session;
    if(-not [bool]$central.Enabled -or -not (Test-PdvRemoteTransportId ([string]$central.AgentId)) -or [string]$central.AgentId -cne [string]$configuration.AgentId){throw 'RemoteIdentityMismatch';}
    $controller.Enabled=$true;$controller.WindowsModule=$windowsModule;
    $controller.Windows=& $windowsModule {param($Configuration,$Directory,$Id);New-PdvMonitorRemoteWindowsTransport -LocalConfiguration $Configuration -DataDirectory $Directory -AgentId $Id -Enabled $true;} $configuration $Session.DataDirectory ([string]$central.AgentId);
    & $script:remoteBrokerModule {
      param($Module,$Transport,$Configuration);
      $script:RemoteWindowsModule=$Module;$script:RemoteWindowsTransport=$Transport;$script:RemoteWindowsConfiguration=$Configuration;
      # Start revalida os hashes/configuracao antes do efeito; durante a sessao os arquivos ficam travados.
      $script:RemoteWindowsPlatformEvidence=& $Module {param($Current);Get-PdvMonitorRemoteWindowsPlatformEvidence -LocalConfiguration $Current;} $Configuration;
      function script:Get-PdvRemoteInteractiveEvidence {return (& $script:RemoteWindowsModule {param($Transport);Get-PdvMonitorRemoteWindowsInteractiveEvidence;} $script:RemoteWindowsTransport);}
      function script:Get-PdvRemotePlatformEvidence {return $script:RemoteWindowsPlatformEvidence;}
    } $windowsModule $controller.Windows $configuration;
    $controller.Broker=New-PdvMonitorRemoteContext -DataDirectory $Session.DataDirectory -AgentId ([string]$central.AgentId) -Enabled $true;
    $controller.Reason='RemotePilotConfigured';
    $controller.Busy=Test-PdvRemoteControllerBusy $controller;
    return $controller;
  }catch{$controller.Reason=Get-PdvRemotePreparationReason $_.Exception;$controller.Enabled=$false;return $controller;}
}

function Get-PdvRemoteControllerWindowsSnapshot {
  param($Controller);
  if($null -eq $Controller.Windows -or $null -eq $Controller.WindowsModule){return @{LocalProcessesStopped=$true;CloseRequested=$false;Stage='disabled'};}
  try{return (& $Controller.WindowsModule {param($Transport);Get-PdvMonitorRemoteWindowsTransportSnapshot -Transport $Transport;} $Controller.Windows);}
  catch{return @{LocalProcessesStopped=$false;CloseRequested=$true;Stage='blocked'};}
}

function Test-PdvRemoteControllerBusy {
  param($Controller);
  $local=Get-PdvRemoteControllerWindowsSnapshot $Controller;
  return ($null -ne $Controller.Broker -and (@('idle','closed','denied') -cnotcontains $Controller.Broker.Stage -or @('interrupted','blocked') -ccontains [string](Get-PdvRemoteControllerField $local 'Stage' '') -or -not [bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false)));
}

function Get-PdvMonitorRemoteControllerSnapshot {
  param($Controller);
  if($null -eq $Controller){return @{Enabled=$false;Stage='disabled';Reason='RemoteDisabled';Busy=$false;LocalProcessesStopped=$true;LocalTransportActive=$false;GatewayState='';};}
  $stage='disabled';if($null -ne $Controller.Broker){$stage=[string]$Controller.Broker.Stage;}
  $local=Get-PdvRemoteControllerWindowsSnapshot $Controller;$stopped=[bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false);
  $gateway='';if($null -ne $Controller.Lease){$gateway=[string]$Controller.Lease.State;}
  return @{Enabled=[bool]$Controller.Enabled;Stage=$stage;Reason=[string]$Controller.Reason;Busy=[bool]$Controller.Busy;LocalProcessesStopped=$stopped;LocalTransportActive=([string](Get-PdvRemoteControllerField $local 'Stage' '') -ceq 'active' -and -not $stopped);GatewayState=$gateway;};
}

function Stop-PdvRemoteControllerTransport {
  param($Controller,[string]$Reason);
  if($null -eq $Controller.Windows -or $null -eq $Controller.WindowsModule){return $true;}
  $prior=Get-PdvRemoteControllerWindowsSnapshot $Controller;
  if(@('interrupted','blocked') -ccontains [string](Get-PdvRemoteControllerField $prior 'Stage' '')){return [bool](Get-PdvRemoteControllerField $prior 'LocalProcessesStopped' $false);}
  if([bool](Get-PdvRemoteControllerField $prior 'LocalProcessesStopped' $false) -and @('idle','closed') -ccontains [string](Get-PdvRemoteControllerField $prior 'Stage' '')){return $true;}
  try{[void](& $Controller.WindowsModule {param($Transport,$Why);Stop-PdvMonitorRemoteWindowsTransport -Transport $Transport -Reason $Why;} $Controller.Windows $Reason);}catch{}
  $state=Get-PdvRemoteControllerWindowsSnapshot $Controller;
  return [bool](Get-PdvRemoteControllerField $state 'LocalProcessesStopped' $false);
}

function Request-PdvRemoteControllerClose {
  param($Controller,[string]$Reason='TransportFailed');
  # Persistir intencao antes do efeito normal. Se disco falhar, parar ainda e obrigatorio.
  try{
    if($null -ne $Controller.Broker -and $null -ne $Controller.Broker.Active -and @('closed','denied','close_required') -cnotcontains $Controller.Broker.Stage){
      [void](Request-PdvMonitorRemoteClose $Controller.Broker $Controller.Broker.Active.Request.SessionId $Reason);
    }
  }catch{$Controller.Reason='RemoteLocalStateBlocked';}
  [void](Stop-PdvRemoteControllerTransport $Controller $Reason);$Controller.Lease=$null;$Controller.LeaseVerifiedAt=$null;$Controller.CentralExpiresAt='';
  $Controller.NextPollAt=[DateTimeOffset]::MinValue;
}

function Update-PdvMonitorRemoteLocal {
  param($Controller,[bool]$OperationsIdle=$true,[bool]$Paused=$false,[bool]$HostClosing=$false);
  if($null -eq $Controller -or -not $Controller.Enabled -or $null -eq $Controller.Broker){return;}
  $Controller.Paused=$Paused;
  try{
    if($HostClosing){$Controller.Stopping=$true;Request-PdvRemoteControllerClose $Controller 'HostClosed';}
    elseif(-not $OperationsIdle){Request-PdvRemoteControllerClose $Controller 'Paused';}
    [void](Update-PdvMonitorRemoteContext $Controller.Broker ($Paused -or -not $OperationsIdle -or $HostClosing));
    if(-not $Controller.Broker.Healthy -or $Controller.Broker.Stage -ceq 'close_required'){
      [void](Stop-PdvRemoteControllerTransport $Controller 'TransportFailed');
    }
    $local=Get-PdvRemoteControllerWindowsSnapshot $Controller;
    if([bool](Get-PdvRemoteControllerField $local 'CloseRequested' $false) -and @('closed','denied','close_required') -cnotcontains $Controller.Broker.Stage){
      $nativeReason=[string](Get-PdvRemoteControllerField $local 'Reason' '');$reason='TransportFailed';
      if(@('OperatorCancelled','LeaseExpired','LocalSessionChanged') -ccontains $nativeReason){$reason=$nativeReason;}
      Request-PdvRemoteControllerClose $Controller $reason;
    }
    if(-not $Paused -and $OperationsIdle -and -not $HostClosing -and -not $Controller.PromptBusy -and @('requested','prompted') -ccontains $Controller.Broker.Stage){
      $Controller.PromptBusy=$true;
      try{
        $prompt=Get-PdvMonitorRemoteConsentPrompt $Controller.Broker;
        $prompt.Message='O suporte podera visualizar e controlar esta tela durante o prazo informado. Autorize somente sem venda ou pagamento em andamento. Voce podera encerrar a qualquer momento.';
        $decision=& $Controller.WindowsModule {param($Prompt);Show-PdvMonitorRemoteWindowsConsent -Prompt $Prompt;} $prompt;
        if($decision -isnot [Collections.IDictionary] -or $decision.Count -ne 4 -or @('approved','denied') -cnotcontains $decision.Decision -or $decision.PaymentIdleConfirmed -isnot [bool]){throw 'RemoteInvalidLocalDecision';}
        [void](Confirm-PdvMonitorRemoteConsent $Controller.Broker ([string]$decision.SessionId) ([string]$decision.ChallengeId) ([string]$decision.Decision) ([bool]$decision.PaymentIdleConfirmed));
        $Controller.NextPollAt=[DateTimeOffset]::MinValue;
      }catch{Request-PdvRemoteControllerClose $Controller 'LocalSessionChanged';}finally{$Controller.PromptBusy=$false;}
    }
    $Controller.Reason=[string]$Controller.Broker.LastReason;
  }catch{Request-PdvRemoteControllerClose $Controller 'TransportFailed';$Controller.Reason='RemoteLocalOperationFailed';}
  $Controller.Busy=Test-PdvRemoteControllerBusy $Controller;
}

function Get-PdvMonitorRemoteWork {
  param($Controller,[bool]$OperationsIdle=$true);
  if($null -eq $Controller -or -not $Controller.Enabled -or $null -eq $Controller.Broker -or $Controller.PromptBusy -or (Get-PdvRemoteControllerNow) -lt $Controller.NextPollAt){return $null;}
  $broker=$Controller.Broker;$local=Get-PdvRemoteControllerWindowsSnapshot $Controller;
  if([string](Get-PdvRemoteControllerField $local 'Stage' '') -ceq 'blocked'){return $null;}
  if([string](Get-PdvRemoteControllerField $local 'Stage' '') -ceq 'interrupted'){
    $nativeId=[string](Get-PdvRemoteControllerField $local 'SessionId' '');
    if(-not (Test-PdvRemoteTransportId $nativeId) -or -not [bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false)){return $null;}
    $unresolved=@((Get-PdvMonitorRemoteSnapshot $broker).UnresolvedSessionIds);
    return @{Operation='Closed';Payload=@{sessionId=$nativeId;status='closed'};Interrupted=($broker.Stage -ceq 'interrupted' -and $unresolved -ccontains $nativeId);NativeInterrupted=$true;};
  }
  if($broker.Stage -ceq 'interrupted'){
    if(-not [bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false)){return $null;}
    $ids=@((Get-PdvMonitorRemoteSnapshot $broker).UnresolvedSessionIds);
    if($ids.Count){return @{Operation='Closed';Payload=@{sessionId=[string]$ids[0];status='closed'};Interrupted=$true;};};return $null;
  }
  if(-not $broker.Healthy){return $null;}
  if($broker.Stage -ceq 'close_required'){
    if(-not [bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false)){return $null;}
    return @{Operation='Closed';Payload=@{sessionId=[string]$broker.Active.Request.SessionId;status='closed'};Interrupted=$false;};
  }
  if($Controller.Paused -or $Controller.Stopping -or -not $OperationsIdle){return $null;}
  $command=Get-PdvMonitorRemoteCommand $broker;
  if($null -ne $command -and $command.Kind -ceq 'SubmitConsent'){return @{Operation='Consent';Payload=$command.Payload;Interrupted=$false;};}
  if($broker.Stage -ceq 'authorized'){return @{Operation='Lease';Payload=$null;Interrupted=$false;};}
  if(@('requested','prompted') -ccontains $broker.Stage){return @{Operation='Session';Payload=@{sessionId=[string]$broker.Active.Request.SessionId};Interrupted=$false;};}
  if(@('idle','closed','denied') -ccontains $broker.Stage){return @{Operation='Request';Payload=$null;Interrupted=$false;};}
  return $null;
}

function Complete-PdvMonitorRemoteWork {
  param($Controller,$Work,$Result);
  if($null -eq $Controller -or $null -eq $Controller.Broker){return;}
  $Controller.NextPollAt=(Get-PdvRemoteControllerNow).AddSeconds(3);
  try{
    if($Result -isnot [Collections.IDictionary] -or -not [bool]$Result.Success){throw 'RemoteExchangeFailed';}
    if($Work.Operation -ceq 'Request'){
      $Controller.NextPollAt=(Get-PdvRemoteControllerNow).AddSeconds(15);
      if($Result.Status -eq 200){[void](Receive-PdvMonitorRemoteRequest $Controller.Broker $Result.Value);}
    }elseif($Work.Operation -ceq 'Consent'){
      [void](Complete-PdvMonitorRemoteConsent $Controller.Broker $Result.Value);if($Result.Value.Status -ceq 'approved'){$Controller.CentralExpiresAt=[string]$Result.Value.ExpiresAt;};$Controller.NextPollAt=[DateTimeOffset]::MinValue;
    }elseif($Work.Operation -ceq 'Closed'){
      if($Result.Status -ne 200 -or @('closed','ended','failed','cancelled','expired','denied') -cnotcontains $Result.Value.Status){throw 'RemoteClosureUnconfirmed';}
      if(-not [bool](Get-PdvRemoteControllerField (Get-PdvRemoteControllerWindowsSnapshot $Controller) 'LocalProcessesStopped' $false)){throw 'RemoteClosureUnconfirmed';}
      $ack=@{Id=[string]$Result.Value.Id;Status=[string]$Result.Value.Status};
      $native=Get-PdvRemoteControllerWindowsSnapshot $Controller;
      if([string](Get-PdvRemoteControllerField $native 'Stage' '') -ceq 'interrupted'){
        [void](& $Controller.WindowsModule {param($Transport,$Id,$Status);Resolve-PdvMonitorRemoteWindowsInterruptedTransport -Transport $Transport -SessionId $Id -CentralStatus $Status;} $Controller.Windows ([string]$Work.Payload.sessionId) $ack.Status);
      }
      if($Work.Interrupted){[void](Resolve-PdvMonitorRemoteInterruptedSession $Controller.Broker ([string]$Work.Payload.sessionId) $ack);}
      elseif($Controller.Broker.Stage -ceq 'close_required'){[void](Complete-PdvMonitorRemoteClose $Controller.Broker $ack);}
      elseif(-not [bool](Get-PdvRemoteControllerField $Work 'NativeInterrupted' $false)){throw 'RemoteClosureUnconfirmed';}
      $Controller.Lease=$null;$Controller.LeaseVerifiedAt=$null;$Controller.CentralExpiresAt='';
    }elseif($Work.Operation -ceq 'Session'){
      if(@('closed','ended','failed','cancelled','expired','denied','ending') -ccontains $Result.Value.Status){Request-PdvRemoteControllerClose $Controller 'ServerCancelled';}
    }elseif($Work.Operation -ceq 'Lease'){
      if($Result.Status -ne 200 -or $null -eq $Result.Value -or $Controller.Broker.Stage -cne 'authorized'){throw 'RemoteLeaseUnavailable';}
      $lease=$Result.Value;
      if($lease.AgentId -cne $Controller.Broker.AgentId -or $lease.SessionId -cne $Controller.Broker.Active.Request.SessionId -or $lease.State -ceq 'closed'){throw 'RemoteLeaseUnavailable';}
      $expiry=& $script:remoteBrokerModule {param($Value);ConvertTo-PdvRemoteDate $Value;} $lease.ExpiresAt;
      $expected=& $script:remoteBrokerModule {param($Value);ConvertTo-PdvRemoteDate $Value;} ([string](Get-PdvRemoteControllerField $Controller 'CentralExpiresAt' ''));
      if($expiry -le (Get-PdvRemoteControllerNow) -or $expiry -ne $expected){throw 'RemoteLeaseUnavailable';}
      # O gateway conserva seu prazo; o supervisor local nunca ultrapassa900s desde o clique.
      $effective=@{};foreach($key in $lease.Keys){$effective[$key]=$lease[$key];}
      if($expiry -gt $Controller.Broker.Active.Record.sessionExpiresAt){$effective.ExpiresAt=$Controller.Broker.Active.Record.sessionExpiresAt.ToString('o');}
      $lease=$effective;
      $local=Get-PdvRemoteControllerWindowsSnapshot $Controller;
      if([bool](Get-PdvRemoteControllerField $local 'LocalProcessesStopped' $false) -and $null -eq $Controller.Lease){
        [void](& $Controller.WindowsModule {param($Transport,$Broker,$Lease);Start-PdvMonitorRemoteWindowsTransport -Transport $Transport -BrokerContext $Broker -Lease $Lease;} $Controller.Windows $Controller.Broker $lease);
      }else{
        [void](& $Controller.WindowsModule {param($Transport,$Lease);Update-PdvMonitorRemoteWindowsTransport -Transport $Transport -Lease $Lease;} $Controller.Windows $lease);
      }
      $Controller.Lease=$lease;$Controller.LeaseVerifiedAt=Get-PdvRemoteControllerNow;
    }else{throw 'RemoteOperationInvalid';}
    $Controller.Reason=[string]$Controller.Broker.LastReason;
  }catch{
    $Controller.Reason='RemoteExchangeBlocked';$Controller.NextPollAt=(Get-PdvRemoteControllerNow).AddSeconds(15);
    if(@('idle','closed','denied','interrupted','close_required') -cnotcontains $Controller.Broker.Stage){Request-PdvRemoteControllerClose $Controller 'TransportFailed';}
  }finally{
    # Evitar nonce retido no objeto compartilhado com o runspace terminado.
    if($null -ne $Work -and $null -ne $Work.Payload -and $Work.Payload.Contains('nonce')){$Work.Payload.nonce='';}
    $Controller.Busy=Test-PdvRemoteControllerBusy $Controller;
  }
}

function Close-PdvMonitorRemoteController {
  param($Controller,$Session);
  if($null -eq $Controller -or -not $Controller.Enabled){return;}
  [void](Update-PdvMonitorRemoteLocal $Controller $false $true $true);
  try{
    $Controller.NextPollAt=[DateTimeOffset]::MinValue;$work=Get-PdvMonitorRemoteWork $Controller $false;
    if($null -ne $work -and $work.Operation -ceq 'Closed'){$result=Invoke-PdvMonitorRemoteExchange $Session $work.Operation $work.Payload;[void](Complete-PdvMonitorRemoteWork $Controller $work $result);}
  }catch{}
}

Export-ModuleMember -Function Invoke-PdvMonitorRemoteExchange,New-PdvMonitorRemoteController,Get-PdvMonitorRemoteControllerSnapshot,Update-PdvMonitorRemoteLocal,Get-PdvMonitorRemoteWork,Complete-PdvMonitorRemoteWork,Close-PdvMonitorRemoteController;

