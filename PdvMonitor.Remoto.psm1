#requires -Version 2.0
# Piloto isolado: decide consentimento local e produz mensagens tipadas.
# Nao abre rede, inicia processos, instala servicos ou controla o Windows.

function Get-PdvRemoteNow { return [DateTimeOffset]::UtcNow; }

function Test-PdvRemoteClock {
  param([DateTimeOffset]$Now,[DateTimeOffset]$Previous);
  if($Previous -eq [DateTimeOffset]::MinValue){return $true;}
  return ($Now -ge $Previous.AddSeconds(-5));
}

function Get-PdvRemoteValue {
  param($Object,[string]$Name,$Default=$null);
  if($null -eq $Object){return ,$Default;}
  if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return ,$Object[$Name];}}
  else{$property=$Object.PSObject.Properties[$Name];if($null -ne $property){return ,$property.Value;}}
  return ,$Default;
}

function Test-PdvRemoteFields {
  param($Object,[string[]]$Expected);
  if($null -eq $Object -or $Object -is [string] -or $Object -is [Array]){return $false;}
  $names=@();if($Object -is [Collections.IDictionary]){$names=@($Object.Keys);}else{$names=@($Object.PSObject.Properties | ForEach-Object {$_.Name});}
  if($names.Count -ne $Expected.Count){return $false;}
  foreach($name in $names){if($Expected -cnotcontains [string]$name){return $false;}}
  return $true;
}

function Test-PdvRemoteId {
  param($Value);
  if($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){return $false;}
  try{return ((New-Object Guid($Value)) -ne [Guid]::Empty);}catch{return $false;}
}

function Test-PdvRemoteText {
  param($Value,[int]$Minimum,[int]$Maximum);
  if($Value -isnot [string] -or $Value.Length -lt $Minimum -or $Value.Length -gt $Maximum -or $Value -cne $Value.Trim()){return $false;}
  # Controles, caracteres invisiveis e substitutos UTF-16 isolados nao chegam ao prompt.
  for($i=0;$i -lt $Value.Length;$i++){
    $category=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($Value,$i);
    if(@([Globalization.UnicodeCategory]::Control,[Globalization.UnicodeCategory]::Format,[Globalization.UnicodeCategory]::LineSeparator,[Globalization.UnicodeCategory]::ParagraphSeparator) -contains $category){return $false;}
    if([char]::IsHighSurrogate($Value[$i])){if($i+1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$i+1])){return $false;};$i++;}
    elseif([char]::IsLowSurrogate($Value[$i])){return $false;}
  }
  return $true;
}

function ConvertTo-PdvRemoteDate {
  param($Value);
  if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$'){throw 'RemoteInvalidDate';}
  try{return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None).ToUniversalTime();}catch{throw 'RemoteInvalidDate';}
}

function Get-PdvRemoteHash {
  param([string]$Value);
  $algorithm=[Security.Cryptography.SHA256]::Create();
  try{return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant();}finally{$algorithm.Dispose();}
}

function Test-PdvRemoteNonce {
  param($Value);
  if($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9_-]{43}$'){return $false;}
  try{
    $bytes=[Convert]::FromBase64String($Value.Replace('-','+').Replace('_','/')+'=');
    return ($bytes.Length -eq 32 -and [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') -ceq $Value);
  }catch{return $false;}
}

function Get-PdvRemoteInteractiveEvidence {
  # O Host futuro deve substituir este adaptador por evidencia verificada localmente.
  # Nao e possivel concluir que a console esta desbloqueada usando somente UserInteractive.
  return @{Supported=$false;Interactive=$false;Unlocked=$false;WindowsSessionId='';UserSid='';HostInstanceId=''};
}

function Get-PdvRemotePlatformEvidence {
  # Preparacao futura deve fornecer a versao/arquitetura verificadas pelo coletor WMI.
  # Environment.OSVersion isolado pode estar sujeito a compatibilidade de manifesto.
  return @{Detected=$false;WindowsVersion='';Architecture='';CompatibilityVerified=$false};
}

function Get-PdvMonitorRemotePreparationAssessment {
  $evidence=Get-PdvRemotePlatformEvidence;$reason='RemotePlatformUnknown';$eligible=$false;$version='';$architecture='';
  if(Test-PdvRemoteFields $evidence @('Detected','WindowsVersion','Architecture','CompatibilityVerified')){
    if($evidence.Detected -is [bool] -and $evidence.Detected -and $evidence.CompatibilityVerified -is [bool] -and $evidence.WindowsVersion -is [string] -and $evidence.WindowsVersion -cmatch '^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,10}(\.[0-9]{1,10})?$' -and @('x64','x86','arm64') -ccontains $evidence.Architecture){
      $version=$evidence.WindowsVersion;$architecture=$evidence.Architecture;
      $parts=$version.Split('.');$major=[int]$parts[0];$minor=[int]$parts[1];$build=[long]$parts[2];
      $supportedVersion=(($major -eq 6 -and $minor -eq 1 -and $build -eq 7601) -or ($major -eq 10 -and $minor -eq 0 -and $build -ge 10240));
      if(@('x64','x86') -cnotcontains $architecture){$reason='RemoteArchitectureNotHomologated';}
      elseif(-not $supportedVersion){$reason='RemoteWindowsNotSupported';}
      elseif(-not $evidence.CompatibilityVerified){$reason='RemoteDependenciesNotHomologated';}
      else{$reason='RemotePreparationEligible';$eligible=$true;}
    }
  }
  return @{EligibleForPreparation=$eligible;Reason=$reason;WindowsVersion=$version;Architecture=$architecture;TransportActivationSupported=$false;Connected=$false};
}

function Get-PdvRemoteLocalIdentity {
  $platform=Get-PdvMonitorRemotePreparationAssessment;if(-not $platform.EligibleForPreparation){throw $platform.Reason;}
  $evidence=Get-PdvRemoteInteractiveEvidence;
  if(-not (Test-PdvRemoteFields $evidence @('Supported','Interactive','Unlocked','WindowsSessionId','UserSid','HostInstanceId'))){throw 'RemoteLocalHostUnavailable';}
  foreach($key in @('Supported','Interactive','Unlocked')){if((Get-PdvRemoteValue $evidence $key) -isnot [bool] -or -not $evidence[$key]){throw 'RemoteLocalHostUnavailable';}}
  if($evidence.WindowsSessionId -isnot [string] -or $evidence.WindowsSessionId -cnotmatch '^(0|[1-9][0-9]{0,9})$' -or $evidence.UserSid -isnot [string] -or $evidence.UserSid -cnotmatch '^S-1-[0-9]+(-[0-9]+){1,15}$' -or -not (Test-PdvRemoteId $evidence.HostInstanceId)){throw 'RemoteLocalHostUnavailable';}
  return (Get-PdvRemoteHash ($evidence.WindowsSessionId+'|'+$evidence.UserSid+'|'+$evidence.HostInstanceId));
}

function Add-PdvRemoteNotice {
  param($Context,[string]$Reason,[string]$Kind='RemoteSupportDiagnostic');
  if($Context.LastReason -ceq $Reason){return;}
  while($Context.Events.Count -ge 64){[void]$Context.Events.Dequeue();}
  # Somente codigos fixos. Nome de tecnico, motivo livre, nonce e desafio nao sao logs.
  $Context.Events.Enqueue(@{Kind=$Kind;Reason=$Reason;Detail='Diagnostico do broker local de consentimento remoto.'});$Context.LastReason=$Reason;
}

function Get-PdvRemoteJournalPath {
  param($Context);
  return (Join-Path $Context.DataDirectory 'remoto-consentimentos.xml');
}

function Test-PdvRemotePath {
  param([string]$Path,[bool]$Directory=$false);
  if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')){throw 'RemoteLocalStateInvalid';}
  if($Directory -and -not [IO.Directory]::Exists($Path)){throw 'RemoteLocalStateUnavailable';}
  if([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)){
    if(([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RemoteLocalStateInvalid';}
  }
}

function Read-PdvRemoteJournal {
  param($Context);
  $path=Get-PdvRemoteJournalPath $Context;Test-PdvRemotePath $path;
  if(-not [IO.File]::Exists($path)){return @{Revision=[long]0;LastObservedAt=[DateTimeOffset]::MinValue;Records=@()};}
  try{
    if((New-Object IO.FileInfo($path)).Length -gt 65536){throw 'Invalid';}
    $decoder=New-Object Text.UTF8Encoding($false,$true);$text=$decoder.GetString([IO.File]::ReadAllBytes($path));
    if(-not $text -or $text -match '<!DOCTYPE|<!ENTITY'){throw 'Invalid';}
    $xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.LoadXml($text);$root=$xml.DocumentElement;
    if($root.Name -cne 'PdvRemoteConsentJournal' -or $root.NamespaceURI -or $root.Attributes.Count -ne 4 -or $root.GetAttribute('schemaVersion') -cne '1' -or $root.GetAttribute('agentId') -cne $Context.AgentId -or $root.GetAttribute('revision') -cnotmatch '^[1-9][0-9]{0,17}$'){throw 'Invalid';}
    foreach($attribute in $root.Attributes){if(@('schemaVersion','agentId','revision','lastObservedAt') -cnotcontains $attribute.Name -or $attribute.NamespaceURI){throw 'Invalid';}}
    $last=ConvertTo-PdvRemoteDate $root.GetAttribute('lastObservedAt');$records=@();$ids=@{};
    foreach($node in $root.ChildNodes){
      if($node.NodeType -ne [Xml.XmlNodeType]::Element -or $node.Name -cne 'Session' -or $node.NamespaceURI -or $node.Attributes.Count -ne 9 -or $node.ChildNodes.Count){throw 'Invalid';}
      $row=@{};foreach($attribute in $node.Attributes){if(@('id','requestHash','requestedAt','requestExpiresAt','sessionExpiresAt','stage','decision','updatedAt','closeReason') -cnotcontains $attribute.Name -or $attribute.NamespaceURI){throw 'Invalid';};$row[$attribute.Name]=$attribute.Value;}
      if(-not (Test-PdvRemoteId $row.id) -or $ids.ContainsKey($row.id) -or $row.requestHash -cnotmatch '^[0-9a-f]{64}$' -or @('requested','prompted','consent_approved','consent_denied','authorized','denied','close_required','closed') -cnotcontains $row.stage -or @('','approved','denied') -cnotcontains $row.decision -or @('','OperatorCancelled','ServerCancelled','LeaseExpired','LocalSessionChanged','Paused','HostClosed','ConsentExpired','TransportFailed','HostRestarted') -cnotcontains $row.closeReason){throw 'Invalid';}
      $row.requestedAt=ConvertTo-PdvRemoteDate $row.requestedAt;$row.requestExpiresAt=ConvertTo-PdvRemoteDate $row.requestExpiresAt;$row.updatedAt=ConvertTo-PdvRemoteDate $row.updatedAt;
      $row.sessionExpiresAt=ConvertTo-PdvRemoteDate $row.sessionExpiresAt;
      if($row.requestExpiresAt -le $row.requestedAt -or $row.requestExpiresAt -gt $row.requestedAt.AddSeconds(120) -or $row.updatedAt -gt $last -or $row.updatedAt -lt $row.requestedAt.AddSeconds(-5) -or $row.sessionExpiresAt -gt $row.updatedAt.AddSeconds(900) -or (@('consent_approved','authorized') -ccontains $row.stage -and $row.decision -cne 'approved') -or (@('consent_denied','denied') -ccontains $row.stage -and $row.decision -cne 'denied')){throw 'Invalid';}
      $ids[$row.id]=$true;$records+=,$row;
    }
    if($records.Count -gt 128){throw 'Invalid';}
    return @{Revision=[long]$root.GetAttribute('revision');LastObservedAt=$last;Records=$records};
  }catch{throw 'RemoteLocalStateInvalid';}
}

function Save-PdvRemoteJournal {
  param($Context,$Record);
  $lock=$null;$temporary='';$path=Get-PdvRemoteJournalPath $Context;
  try{
    Test-PdvRemotePath $Context.DataDirectory $true;Test-PdvRemotePath ($path+'.lock');Test-PdvRemotePath $path;
    $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);
    $previous=Read-PdvRemoteJournal $Context;
    if($previous.Revision -ne $Context.Revision){throw 'RemoteLocalStateConflict';}
    $now=Get-PdvRemoteNow;
    if(-not (Test-PdvRemoteClock $now $previous.LastObservedAt)){throw 'RemoteClockInvalid';}
    $rows=@();foreach($row in $previous.Records){if($row.id -cne $Record.id -and (@('closed','denied') -cnotcontains $row.stage -or $row.requestExpiresAt -gt $now.AddDays(-1))){$rows+=,$row;}}
    $rows+=,$Record;if($rows.Count -gt 128){throw 'RemoteLocalHistoryFull';}
    $xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement('PdvRemoteConsentJournal');[void]$xml.AppendChild($root);
    $revision=$previous.Revision+1;$root.SetAttribute('schemaVersion','1');$root.SetAttribute('agentId',$Context.AgentId);$root.SetAttribute('revision',[string]$revision);$root.SetAttribute('lastObservedAt',$now.ToString('o'));
    foreach($row in $rows){
      $node=$xml.CreateElement('Session');foreach($key in @('id','requestHash','requestedAt','requestExpiresAt','sessionExpiresAt','stage','decision','updatedAt','closeReason')){
        $value=$row[$key];if($value -is [DateTimeOffset]){$value=$value.ToString('o');};$node.SetAttribute($key,[string]$value);
      };[void]$root.AppendChild($node);
    }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($xml.OuterXml);if($bytes.Length -gt 65536){throw 'RemoteLocalHistoryFull';}
    $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';$stream=$null;
    try{$stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Write($bytes,0,$bytes.Length);$stream.Flush();}finally{if($null -ne $stream){$stream.Dispose();}}
    if([IO.File]::Exists($path)){Test-PdvRemotePath ($path+'.bak');[IO.File]::Replace($temporary,$path,$path+'.bak');}else{[IO.File]::Move($temporary,$path);}
    $Context.Revision=$revision;$Context.LastObservedAt=$now;$Context.Records=$rows;
  }catch{
    $reason=[string]$_.Exception.Message;if(@('RemoteLocalStateConflict','RemoteClockInvalid','RemoteLocalHistoryFull') -cnotcontains $reason){$reason='RemoteLocalStateWriteFailed';}
    $Context.Healthy=$false;$Context.Command=$null;$Context.Challenge=$null;Add-PdvRemoteNotice $Context $reason 'RemoteSupportBlocked';throw $reason;
  }finally{if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary);};if($null -ne $lock){$lock.Dispose();}}
}

function New-PdvRemoteRecord {
  param($Request,[string]$Hash);
  $now=Get-PdvRemoteNow;
  return @{id=$Request.SessionId;requestHash=$Hash;requestedAt=$Request.RequestedAt;requestExpiresAt=$Request.ExpiresAt;sessionExpiresAt=$Request.ExpiresAt;stage='requested';decision='';updatedAt=$now;closeReason=''};
}

function Set-PdvRemoteStage {
  param($Context,[string]$Stage,[string]$Decision='',[string]$CloseReason='',$ExpiresAt=$null);
  $record=@{};foreach($key in $Context.Active.Record.Keys){$record[$key]=$Context.Active.Record[$key];}
  $record.stage=$Stage;$record.updatedAt=Get-PdvRemoteNow;$record.decision=$Decision;$record.closeReason=$CloseReason;if($null -ne $ExpiresAt){$record.sessionExpiresAt=$ExpiresAt;}
  Save-PdvRemoteJournal $Context $record;$Context.Active.Record=$record;$Context.Stage=$Stage;
}

function New-PdvMonitorRemoteContext {
  param([string]$DataDirectory,[string]$AgentId,[bool]$Enabled=$false);
  if(-not (Test-PdvRemoteId $AgentId)){throw 'RemoteInvalidAgent';}
  $context=@{DataDirectory=[IO.Path]::GetFullPath($DataDirectory);AgentId=$AgentId;Enabled=$Enabled;Healthy=$true;Paused=$false;Revision=[long]0;LastObservedAt=[DateTimeOffset]::MinValue;Records=@();Active=$null;Stage='idle';Challenge=$null;Command=$null;Events=(New-Object Collections.Queue);LastReason='';TransportActivationSupported=$false};
  try{
    Test-PdvRemotePath $context.DataDirectory $true;$journal=Read-PdvRemoteJournal $context;$context.Revision=$journal.Revision;$context.LastObservedAt=$journal.LastObservedAt;$context.Records=@($journal.Records);
    if(-not (Test-PdvRemoteClock (Get-PdvRemoteNow) $context.LastObservedAt)){throw 'RemoteClockInvalid';}
    $unresolved=@($context.Records | Where-Object {@('closed','denied') -cnotcontains $_.stage});
    if($unresolved.Count){$context.Stage='interrupted';$context.Healthy=$false;Add-PdvRemoteNotice $context 'RemoteInterruptedSession' 'RemoteSupportInterrupted';}
    elseif(-not $Enabled){Add-PdvRemoteNotice $context 'RemoteDisabled';}
  }catch{$context.Healthy=$false;$context.Stage='blocked';Add-PdvRemoteNotice $context 'RemoteLocalStateInvalid' 'RemoteSupportBlocked';}
  return $context;
}

function Get-PdvMonitorRemoteSnapshot {
  param($Context);
  $sessionId='';$expiresAt='';if($null -ne $Context.Active){$sessionId=$Context.Active.Request.SessionId;$expiresAt=$Context.Active.Record.sessionExpiresAt.ToString('o');}
  return @{SchemaVersion=1;Enabled=[bool]$Context.Enabled;Healthy=[bool]$Context.Healthy;Stage=[string]$Context.Stage;Reason=[string]$Context.LastReason;SessionId=$sessionId;ExpiresAt=$expiresAt;TransportActivationSupported=$false;Connected=$false;UnresolvedSessionIds=@($Context.Records | Where-Object {@('closed','denied') -cnotcontains $_.stage} | ForEach-Object {$_.id})};
}

function Test-PdvRemoteContext {
  param($Context,[bool]$RequireEnabled=$true);
  if(-not $Context.Healthy){throw 'RemoteLocalStateBlocked';}
  if($RequireEnabled -and -not $Context.Enabled){throw 'RemoteDisabled';}
  if($Context.Paused){throw 'RemotePaused';}
  if(-not (Test-PdvRemoteClock (Get-PdvRemoteNow) $Context.LastObservedAt)){$Context.Healthy=$false;$Context.Command=$null;$Context.Challenge=$null;Add-PdvRemoteNotice $Context 'RemoteClockInvalid' 'RemoteSupportBlocked';throw 'RemoteClockInvalid';}
}

function ConvertFrom-PdvRemoteRequest {
  param($Context,$Request);
  if(-not (Test-PdvRemoteFields $Request @('SessionId','AgentId','RequestId','RequestedAt','ExpiresAt','SessionMaxSeconds','Mode','TechnicianId','TechnicianName','Reason','Nonce'))){throw 'RemoteInvalidRequest';}
  foreach($key in @('SessionId','AgentId','RequestId')){if(-not (Test-PdvRemoteId (Get-PdvRemoteValue $Request $key))){throw 'RemoteInvalidRequest';}}
  if($Request.AgentId -cne $Context.AgentId -or $Request.RequestId -cne $Request.SessionId -or $Request.Mode -isnot [string] -or $Request.Mode -cne 'control' -or $Request.TechnicianId -isnot [string] -or $Request.TechnicianId -cnotmatch '^[1-9][0-9]{0,19}$' -or -not (Test-PdvRemoteText $Request.TechnicianName 1 160) -or -not (Test-PdvRemoteText $Request.Reason 10 500) -or -not (Test-PdvRemoteNonce $Request.Nonce)){throw 'RemoteInvalidRequest';}
  $seconds=$Request.SessionMaxSeconds;if($null -eq $seconds -or @([int],[long],[double],[decimal]) -notcontains $seconds.GetType() -or $seconds -lt 30 -or $seconds -gt 900 -or [math]::Floor([double]$seconds) -ne $seconds){throw 'RemoteInvalidRequest';}
  $requested=ConvertTo-PdvRemoteDate $Request.RequestedAt;$expires=ConvertTo-PdvRemoteDate $Request.ExpiresAt;$now=Get-PdvRemoteNow;
  if($requested -gt $now.AddSeconds(5) -or $requested -lt $now.AddSeconds(-120) -or $expires -le $now -or $expires -le $requested -or $expires -gt $requested.AddSeconds(120)){throw 'RemoteRequestExpired';}
  $normalized=@{SessionId=$Request.SessionId;AgentId=$Request.AgentId;RequestId=$Request.RequestId;RequestedAt=$requested;ExpiresAt=$expires;SessionMaxSeconds=[int]$seconds;Mode='control';TechnicianId=$Request.TechnicianId;TechnicianName=$Request.TechnicianName;Reason=$Request.Reason;Nonce=$Request.Nonce};
  $parts=@();foreach($key in @('SessionId','AgentId','RequestId','RequestedAt','ExpiresAt','SessionMaxSeconds','Mode','TechnicianId','TechnicianName','Reason','Nonce')){$value=$normalized[$key];if($value -is [DateTimeOffset]){$value=$value.ToString('o');};$parts+=([string]$value).Length.ToString()+':'+[string]$value;}
  return @{Request=$normalized;Hash=(Get-PdvRemoteHash ($parts -join '|'))};
}

function Receive-PdvMonitorRemoteRequest {
  param($Context,$Request);
  Test-PdvRemoteContext $Context;$validated=ConvertFrom-PdvRemoteRequest $Context $Request;$normalized=$validated.Request;
  $previous=@($Context.Records | Where-Object {$_.id -ceq $normalized.SessionId});
  if($previous.Count){if($previous[0].requestHash -cne $validated.Hash){throw 'RemoteRequestChanged';};return @{Accepted=$false;Reason='RemoteRequestAlreadyObserved';};}
  if($null -ne $Context.Active -and @('closed','denied') -cnotcontains $Context.Stage){throw 'RemoteSessionBusy';}
  $record=New-PdvRemoteRecord $normalized $validated.Hash;Save-PdvRemoteJournal $Context $record;
  $Context.Active=@{Request=$normalized;Record=$record;ApprovedAt=$null;LocalIdentity=''};$Context.Command=$null;$Context.Challenge=$null;$Context.Stage='requested';Add-PdvRemoteNotice $Context 'RemoteConsentRequested' 'RemoteSupportConsentRequested';
  return @{Accepted=$true;Reason='RemoteConsentRequested';};
}

function Get-PdvMonitorRemoteConsentPrompt {
  param($Context);
  Test-PdvRemoteContext $Context;
  if($null -eq $Context.Active -or @('requested','prompted') -cnotcontains $Context.Stage){throw 'RemoteNoPendingConsent';}
  if((Get-PdvRemoteNow) -ge $Context.Active.Request.ExpiresAt){throw 'RemoteRequestExpired';}
  $identity=Get-PdvRemoteLocalIdentity;
  if($null -eq $Context.Challenge){Set-PdvRemoteStage $Context 'prompted';$Context.Challenge=@{Id=[Guid]::NewGuid().ToString('D');LocalIdentity=$identity};}
  elseif($Context.Challenge.LocalIdentity -cne $identity){throw 'RemoteLocalSessionChanged';}
  $request=$Context.Active.Request;
  return @{SessionId=$request.SessionId;ChallengeId=$Context.Challenge.Id;TechnicianId=$request.TechnicianId;TechnicianName=$request.TechnicianName;Reason=$request.Reason;Mode='control';ExpiresAt=$request.ExpiresAt.ToString('o');SessionMaxSeconds=$request.SessionMaxSeconds;DefaultDecision='denied';PaymentIdleConfirmationRequired=$true;Message='O suporte podera visualizar e controlar esta tela. Confirme somente sem venda ou pagamento em andamento. A autorizacao nao inicia uma conexao nesta versao de preparacao.'};
}

function Confirm-PdvMonitorRemoteConsent {
  param($Context,[string]$SessionId,[string]$ChallengeId,[string]$Decision,[bool]$PaymentIdleConfirmed=$false);
  Test-PdvRemoteContext $Context;
  if(@('approved','denied') -cnotcontains $Decision -or $null -eq $Context.Active -or $Context.Stage -cne 'prompted' -or $null -eq $Context.Challenge -or $SessionId -cne $Context.Active.Request.SessionId -or $ChallengeId -cne $Context.Challenge.Id){throw 'RemoteInvalidLocalDecision';}
  if((Get-PdvRemoteNow) -ge $Context.Active.Request.ExpiresAt){throw 'RemoteRequestExpired';}
  if((Get-PdvRemoteLocalIdentity) -cne $Context.Challenge.LocalIdentity){throw 'RemoteLocalSessionChanged';}
  if($Decision -ceq 'approved' -and -not $PaymentIdleConfirmed){throw 'RemotePaymentConfirmationRequired';}
  Set-PdvRemoteStage $Context ('consent_'+$Decision) $Decision;
  $Context.Active.LocalIdentity=$Context.Challenge.LocalIdentity;$Context.Challenge=$null;$Context.Active.ApprovedAt=Get-PdvRemoteNow;
  $request=$Context.Active.Request;$Context.Command=@{Kind='SubmitConsent';Payload=@{sessionId=$request.SessionId;requestId=$request.RequestId;nonce=$request.Nonce;decision=$Decision}};
  Add-PdvRemoteNotice $Context ('RemoteConsent'+$Decision) 'RemoteSupportConsentDecision';
  return @{DecisionRecorded=$true;Connected=$false;TransportActivationSupported=$false;};
}

function Get-PdvMonitorRemoteCommand {
  param($Context);
  if($null -eq $Context.Command -or $Context.Command.Kind -cne 'SubmitClosedStatus'){Test-PdvRemoteContext $Context;}elseif(-not $Context.Healthy){throw 'RemoteLocalStateBlocked';}
  if($null -eq $Context.Command){return $null;}
  if($Context.Command.Kind -ceq 'SubmitConsent' -and (Get-PdvRemoteNow) -ge $Context.Active.Request.ExpiresAt){throw 'RemoteRequestExpired';}
  $payload=@{};foreach($key in $Context.Command.Payload.Keys){$payload[$key]=$Context.Command.Payload[$key];}
  # Sensivel: somente transporte HTTPS do agente. Nunca enviar ao exportador/log.
  return @{Kind=$Context.Command.Kind;Payload=$payload};
}

function Complete-PdvMonitorRemoteConsent {
  param($Context,$Response);
  Test-PdvRemoteContext $Context;
  if(-not (Test-PdvRemoteFields $Response @('Id','Status','ExpiresAt','ConsentExpiresAt')) -or -not (Test-PdvRemoteId $Response.Id) -or $Response.Status -isnot [string] -or $null -eq $Context.Command -or $Context.Command.Kind -cne 'SubmitConsent' -or $Response.Id -cne $Context.Active.Request.SessionId -or $Response.Status -cne $Context.Command.Payload.decision){throw 'RemoteInvalidConsentAcknowledgement';}
  $request=$Context.Active.Request;$consentExpires=ConvertTo-PdvRemoteDate $Response.ConsentExpiresAt;
  if($consentExpires -ne $request.ExpiresAt){throw 'RemoteInvalidConsentAcknowledgement';}
  if($Response.Status -ceq 'approved'){
    $expires=ConvertTo-PdvRemoteDate $Response.ExpiresAt;
    if($expires -le (Get-PdvRemoteNow) -or $expires -gt (Get-PdvRemoteNow).AddSeconds($request.SessionMaxSeconds+5)){throw 'RemoteInvalidConsentAcknowledgement';}
    $localLimit=$Context.Active.ApprovedAt.AddSeconds($request.SessionMaxSeconds);if($expires -gt $localLimit){$expires=$localLimit;}
    Set-PdvRemoteStage $Context 'authorized' 'approved' '' $expires;
    Add-PdvRemoteNotice $Context 'RemoteTransportAdapterUnavailable';
  }else{if($null -ne $Response.ExpiresAt){if($Response.ExpiresAt -isnot [string]){throw 'RemoteInvalidConsentAcknowledgement';};if($Response.ExpiresAt -cne ''){[void](ConvertTo-PdvRemoteDate $Response.ExpiresAt);}};Set-PdvRemoteStage $Context 'denied' 'denied';Add-PdvRemoteNotice $Context 'RemoteConsentDenied' 'RemoteSupportConsentDenied';}
  $Context.Active.Request.Nonce='';$Context.Command=$null;return @{ConsentAcknowledged=$true;Connected=$false;TransportActivationSupported=$false;};
}

function Request-PdvMonitorRemoteClose {
  param($Context,[string]$SessionId,[string]$Reason='OperatorCancelled');
  if(@('OperatorCancelled','ServerCancelled','LeaseExpired','LocalSessionChanged','Paused','HostClosed','ConsentExpired','TransportFailed') -cnotcontains $Reason){throw 'RemoteInvalidCloseReason';}
  if($null -eq $Context.Active -or $SessionId -cne $Context.Active.Request.SessionId){throw 'RemoteUnknownSession';}
  if(@('closed','denied') -ccontains $Context.Stage){return @{CloseRequired=$false;Connected=$false;};}
  # Fechamento pode ser solicitado mesmo pausado/desabilitado; nunca amplia privilegios.
  if(-not $Context.Healthy){throw 'RemoteLocalStateBlocked';}
  Set-PdvRemoteStage $Context 'close_required' $Context.Active.Record.decision $Reason;$Context.Challenge=$null;$Context.Active.Request.Nonce='';
  $Context.Command=@{Kind='SubmitClosedStatus';Payload=@{sessionId=$SessionId;status='closed'}};
  Add-PdvRemoteNotice $Context ('RemoteClose'+$Reason) 'RemoteSupportCloseRequired';return @{CloseRequired=$true;Connected=$false;TransportActivationSupported=$false;};
}

function Complete-PdvMonitorRemoteClose {
  param($Context,$Response);
  if(-not $Context.Healthy){throw 'RemoteLocalStateBlocked';}
  if(-not (Test-PdvRemoteFields $Response @('Id','Status')) -or -not (Test-PdvRemoteId $Response.Id) -or $Response.Status -isnot [string] -or $null -eq $Context.Active -or $Context.Stage -cne 'close_required' -or $Response.Id -cne $Context.Active.Request.SessionId -or @('closed','ended','failed','cancelled','expired','denied') -cnotcontains $Response.Status){throw 'RemoteInvalidCloseAcknowledgement';}
  Set-PdvRemoteStage $Context 'closed' $Context.Active.Record.decision $Context.Active.Record.closeReason;$Context.Command=$null;$Context.Challenge=$null;Add-PdvRemoteNotice $Context 'RemoteSessionClosed' 'RemoteSupportClosed';return @{Closed=$true;Connected=$false;};
}

function Resolve-PdvMonitorRemoteInterruptedSession {
  param($Context,[string]$SessionId,$Response);
  # Este piloto nunca emite Start/Ready. Resolucao so encerra o registro central.
  # Se um adaptador de captura for adicionado, exigir tambem evidencia de parada local.
  if($Context.Stage -cne 'interrupted' -or $Context.Healthy -or -not (Test-PdvRemoteId $SessionId) -or -not (Test-PdvRemoteFields $Response @('Id','Status')) -or -not (Test-PdvRemoteId $Response.Id) -or $Response.Status -isnot [string] -or $Response.Id -cne $SessionId -or @('closed','ended','failed','cancelled','expired','denied') -cnotcontains $Response.Status){throw 'RemoteInvalidInterruptedAcknowledgement';}
  $rows=@($Context.Records | Where-Object {$_.id -ceq $SessionId -and @('closed','denied') -cnotcontains $_.stage});if($rows.Count -ne 1){throw 'RemoteUnknownSession';}
  $record=@{};foreach($key in $rows[0].Keys){$record[$key]=$rows[0][$key];};$record.stage='closed';$record.closeReason='HostRestarted';$record.updatedAt=Get-PdvRemoteNow;
  Save-PdvRemoteJournal $Context $record;
  if(@($Context.Records | Where-Object {@('closed','denied') -cnotcontains $_.stage}).Count -eq 0){$Context.Healthy=$true;$Context.Stage='idle';Add-PdvRemoteNotice $Context 'RemoteInterruptedSessionClosed' 'RemoteSupportClosed';}
  return @{Closed=$true;Connected=$false;};
}

function Update-PdvMonitorRemoteContext {
  param($Context,[bool]$Paused=$false);
  $Context.Paused=$Paused;
  if(-not $Context.Healthy){return (Get-PdvMonitorRemoteSnapshot $Context);}
  if($null -ne $Context.Active -and @('closed','denied','close_required') -cnotcontains $Context.Stage){
    $reason='';$now=Get-PdvRemoteNow;
    if($Paused -or -not $Context.Enabled){$reason='Paused';}
    elseif(-not (Test-PdvRemoteClock $now $Context.LastObservedAt)){$Context.Healthy=$false;$Context.Command=$null;$Context.Challenge=$null;Add-PdvRemoteNotice $Context 'RemoteClockInvalid' 'RemoteSupportBlocked';}
    elseif($Context.Stage -ceq 'authorized' -and $now -ge $Context.Active.Record.sessionExpiresAt){$reason='LeaseExpired';}
    elseif($Context.Stage -cne 'authorized' -and $now -ge $Context.Active.Request.ExpiresAt){$reason='ConsentExpired';}
    elseif($null -ne $Context.Challenge){try{if((Get-PdvRemoteLocalIdentity) -cne $Context.Challenge.LocalIdentity){$reason='LocalSessionChanged';}}catch{$reason='LocalSessionChanged';}}
    elseif($Context.Active.LocalIdentity){try{if((Get-PdvRemoteLocalIdentity) -cne $Context.Active.LocalIdentity){$reason='LocalSessionChanged';}}catch{$reason='LocalSessionChanged';}}
    if($reason){[void](Request-PdvMonitorRemoteClose $Context $Context.Active.Request.SessionId $reason);}
  }
  return (Get-PdvMonitorRemoteSnapshot $Context);
}

Export-ModuleMember -Function New-PdvMonitorRemoteContext,Get-PdvMonitorRemoteSnapshot,Get-PdvMonitorRemotePreparationAssessment,Receive-PdvMonitorRemoteRequest,Get-PdvMonitorRemoteConsentPrompt,Confirm-PdvMonitorRemoteConsent,Get-PdvMonitorRemoteCommand,Complete-PdvMonitorRemoteConsent,Request-PdvMonitorRemoteClose,Complete-PdvMonitorRemoteClose,Resolve-PdvMonitorRemoteInterruptedSession,Update-PdvMonitorRemoteContext;
