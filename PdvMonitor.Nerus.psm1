#requires -Version 2.0
# A única escrita no ERP pertence à API. Este módulo coleta evidências, persiste
# a operação antes do pedido e nunca abre COM, DLL ou conexão direta de banco.
$script:nerusRoot = Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $script:nerusRoot 'PdvMonitor.Inventario.psm1');
Import-Module (Join-Path $script:nerusRoot 'PdvMonitor.Coleta.psm1');

function Get-PdvNerusValue {
  param($Object, [string]$Name, $Default=$null);
  if ($null -eq $Object) { return ,$Default; }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return ,$Object[$Name]; }
  } else {
    $property=$Object.PSObject.Properties[$Name];
    if ($null -ne $property) { return ,$property.Value; }
  }
  return ,$Default;
}
function Get-PdvNerusNow { return [DateTimeOffset]::Now; }
function Get-PdvNerusProcesses { return @(Get-Process -ErrorAction Stop); }
function Get-PdvNerusJobs { return @(Get-WmiObject -Class Win32_PrintJob -ErrorAction Stop); }
function Get-PdvNerusFreshSnapshot { return (Get-PdvMonitorSnapshot); }
function Wait-PdvNerusFreshSample { Start-Sleep -Milliseconds 1100; }

function Read-PdvNerusXml {
  param([string]$Text,[string]$Root);
  if (-not $Text -or [Text.Encoding]::UTF8.GetByteCount($Text) -gt 65536 -or $Text -match '<!DOCTYPE|<!ENTITY') { throw 'NerusInvalidXml'; }
  $xml=New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.LoadXml($Text);
  if ($xml.DocumentElement.Name -cne $Root -or $xml.DocumentElement.NamespaceURI) { throw 'NerusInvalidXml'; }
  return ,$xml;
}
function Save-PdvNerusState {
  param($Session,$State);
  $xml=New-Object Xml.XmlDocument; $root=$xml.CreateElement('PdvNerusState'); [void]$xml.AppendChild($root);
  $values=@{AgentId=[string]$Session.Config.Central.AgentId;NextAttemptAt=$State.NextAttemptAt.ToString('o')};
  if ($null -ne $State.Pending) {
    foreach ($key in @('Phase','Body','RequestId','TicketId','ActualPort','BeforeValue','AfterValue')) { $values[$key]=[string]$State.Pending[$key]; }
    $expected=[string](Get-PdvNerusValue $State.Pending 'ExpectedBefore' ''); if ($expected) { $values.ExpectedBefore=$expected; }
  }
  foreach ($key in $values.Keys) { $node=$xml.CreateElement($key); $node.InnerText=$values[$key]; [void]$root.AppendChild($node); }
  $path=Join-Path $Session.DataDirectory 'nerus-automacao.xml'; $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';
  try {
    [IO.File]::WriteAllText($tmp,$xml.OuterXml,[Text.Encoding]::UTF8);
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp,$path,$path+'.bak'); } else { [IO.File]::Move($tmp,$path); }
  } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp); } }
}
function Save-PdvNerusLedger {
  param($Session,$State);
  try { Save-PdvNerusState -Session $Session -State $State; }
  catch { $State.Healthy=$false; throw 'NerusLocalStateWriteFailed'; }
}
function New-PdvNerusState {
  param($Session);
  $state=@{Policy=$null;NextPolicyAt=[DateTimeOffset]::MinValue;Samples=@();NextAttemptAt=[DateTimeOffset]::MinValue;Pending=$null;RetryAt=[DateTimeOffset]::MinValue;Healthy=$true;LastReason='';Events=(New-Object Collections.Queue)};
  $path=Join-Path $Session.DataDirectory 'nerus-automacao.xml';
  if ([IO.File]::Exists($path)) {
    try {
      if ((New-Object IO.FileInfo($path)).Length -gt 65536) { throw 'StateTooLarge'; }
      $xml=Read-PdvNerusXml ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)) 'PdvNerusState';
      $seen=@{}; foreach ($node in $xml.DocumentElement.ChildNodes) {
        if (@('AgentId','NextAttemptAt','Phase','Body','RequestId','TicketId','ActualPort','BeforeValue','AfterValue','ExpectedBefore') -notcontains $node.Name -or $seen.ContainsKey($node.Name) -or $node.Attributes.Count -or $node.SelectNodes('*').Count) { throw 'InvalidState'; }
        $seen[$node.Name]=$node.InnerText;
      }
      if ([string]$seen.AgentId -cne [string]$Session.Config.Central.AgentId) { throw 'StateIdentityMismatch'; }
      $state.NextAttemptAt=[DateTimeOffset]::Parse([string]$seen.NextAttemptAt,[Globalization.CultureInfo]::InvariantCulture);
      if ($state.NextAttemptAt -gt (Get-PdvNerusNow).AddMinutes(15)) { throw 'StateClockInvalid'; }
      if ($seen.ContainsKey('ExpectedBefore') -and (-not $seen.Phase -or [string]$seen.ExpectedBefore -notmatch '^(0|[1-9][0-9]{0,3})$')) { throw 'InvalidExpectedBefore'; }
      if ($seen.Phase) {
        if ([string]$seen.ActualPort -notmatch '^COM[1-9][0-9]{0,3}$' -or [string]$seen.AfterValue -notmatch '^(0|[1-9][0-9]{0,3})$' -or @('prepare','commit') -notcontains $seen.Phase -or -not $seen.Body -or $seen.Body.Length -gt 48000 -or $seen.RequestId -notmatch '^[0-9a-f-]{36}$' -or ($seen.Phase -eq 'commit' -and $seen.TicketId -notmatch '^[0-9a-f-]{36}$')) { throw 'InvalidPending'; }
        $state.Pending=@{Phase=$seen.Phase;Body=$seen.Body;RequestId=$seen.RequestId;TicketId=$seen.TicketId;ActualPort=$seen.ActualPort;BeforeValue=$seen.BeforeValue;AfterValue=$seen.AfterValue};
        if ($seen.ContainsKey('ExpectedBefore')) { if ([string]$seen.ExpectedBefore -notmatch '^(0|[1-9][0-9]{0,3})$') { throw 'InvalidExpectedBefore'; }; $state.Pending.ExpectedBefore=$seen.ExpectedBefore; }
      }
    } catch { $state.Healthy=$false; }
  }
  return $state;
}
function Add-PdvNerusNotice {
  param($State,[string]$Reason,[string]$Kind,[string]$Detail);
  if ($State.LastReason -cne $Reason) {
    $State.Events.Enqueue(@{Kind=$Kind;Reason=$Reason;Detail=$Detail});
    $State.LastReason=$Reason;
  }
}

function Invoke-PdvNerusHttp {
  param($Session,[string]$Path,[string]$Method='GET',[string]$Body='');
  if (@('/agent/policy','/agent/nerus/configuration','/agent/nerus/prepare','/agent/nerus/commit') -notcontains $Path) { throw 'NerusInvalidPath'; }
  $transport=Get-Module PdvMonitor.Transporte;
  if ($null -eq $transport) { Import-Module (Join-Path $script:nerusRoot 'PdvMonitor.Transporte.psm1'); $transport=Get-Module PdvMonitor.Transporte; }
  $authorization=$null; $response=$null; $stream=$null; $memory=$null; $request=$null;
  $oldProtocol=[Net.ServicePointManager]::SecurityProtocol;$tlsLock=[Net.ServicePointManager];$ownsTls=$false;
  try {
    $authorization=& $transport { param($s)
      $c=Get-PdvCentralConfig $s;
      if (-not (Test-PdvCentralIdentity $c.Endpoint $c.StoreId $c.Terminal $c.AgentId) -or -not $c.Enabled) { throw 'CentralUnavailable'; }
      $paths=Get-PdvTransportPaths $s;
      $token=Unprotect-PdvMonitorToken ([IO.File]::ReadAllBytes($paths.Credential)) $c;
      if ($token -notmatch '^[a-fA-F0-9]{64}$') { throw 'CredentialInvalid'; }
      return 'Bearer '+$c.AgentId+'.'+$token;
    } $Session;
    $base=[string]$Session.Config.Central.Endpoint;
    if (-not $base.EndsWith('/ingest',[StringComparison]::Ordinal)) { throw 'CentralUnavailable'; }
    $ownsTls=[Threading.Monitor]::TryEnter($tlsLock,2000);if(-not $ownsTls){throw 'NerusTransportUnavailable';};$oldProtocol=[Net.ServicePointManager]::SecurityProtocol;
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]3072;
    $request=[Net.WebRequest]::Create($base.Substring(0,$base.Length-7)+$Path);
    $request.Method=$Method; $request.Accept='application/xml'; $request.ContentType='application/json; charset=utf-8';
    $request.AllowAutoRedirect=$false; $request.Timeout=4000; $request.ReadWriteTimeout=4000; $request.UseDefaultCredentials=$false;
    $request.Headers['Authorization']=$authorization;
    if ($Method -eq 'POST') {
      $bytes=[Text.Encoding]::UTF8.GetBytes($Body);
      if ($bytes.Length -gt 49152) { throw 'RequestTooLarge'; }
      $request.ContentLength=$bytes.Length; $stream=$request.GetRequestStream(); $stream.Write($bytes,0,$bytes.Length); $stream.Close(); $stream=$null;
    }
    try { $response=$request.GetResponse(); }
    catch [Net.WebException] { if ($null -eq $_.Exception.Response) { throw 'NerusTransportUnavailable'; }; $response=$_.Exception.Response; }
    $code=[int]$response.StatusCode;
    if ($code -ne 200) { throw ('NerusHttp'+$code); }
    $stream=$response.GetResponseStream(); $memory=New-Object IO.MemoryStream; $buffer=New-Object byte[] 4096;
    while (($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
      if ($memory.Length+$read -gt 65536) { throw 'ResponseTooLarge'; }
      $memory.Write($buffer,0,$read);
    }
    return [Text.Encoding]::UTF8.GetString($memory.ToArray());
  } catch {
    if ([string]$_.Exception.Message -match '^NerusHttp[0-9]{3}$') { throw $_.Exception.Message; }
    throw 'NerusTransportUnavailable';
  } finally {
    $authorization=$null;
    try {
      if ($null -ne $request) { $request.Headers.Remove('Authorization'); }
      if ($null -ne $stream) { $stream.Dispose(); }
      if ($null -ne $memory) { $memory.Dispose(); }
      if ($null -ne $response) { $response.Close(); }
    } finally {if($ownsTls){try{[Net.ServicePointManager]::SecurityProtocol=$oldProtocol;}finally{[Threading.Monitor]::Exit($tlsLock);}}}
  }
}
function ConvertFrom-PdvNerusPolicy {
  param([string]$Text);
  $xml=Read-PdvNerusXml $Text 'PdvMonitorPolicy'; $root=$xml.DocumentElement;
  if ($root.GetAttribute('schemaVersion') -cne '1') { throw 'InvalidPolicy'; }
  $policy=@{};
  foreach ($key in @('Enabled','AutoUpdateEnabled','WindowOpen')) {
    $nodes=@($root.SelectNodes($key)); if ($nodes.Count -ne 1 -or @('true','false') -cnotcontains $nodes[0].InnerText) { throw 'InvalidPolicy'; }
    $policy[$key]=($nodes[0].InnerText -ceq 'true');
  }
  foreach ($key in @('Revision','InstanceId','HardwareId','ServerTime')) { $policy[$key]=[string]$root.SelectSingleNode($key).InnerText; }
  $policy.BlockingProcessNames=@($root.SelectNodes('BlockingProcessNames/Name') | ForEach-Object {$_.InnerText});
  $policy.PortMappings=@{};
  foreach ($mapping in @($root.SelectNodes('PortMappings/Mapping'))) {
    $port=[string]$mapping.SelectSingleNode('Port').InnerText; $value=[string]$mapping.SelectSingleNode('FiscalDevice').InnerText;
    if ($port -notmatch '^COM[1-9][0-9]{0,3}$' -or [int]$port.Substring(3) -gt 4096 -or $value -notmatch '^(0|[1-9][0-9]{0,3})$' -or $policy.PortMappings.ContainsKey($port)) { throw 'InvalidPolicy'; }
    $policy.PortMappings[$port]=$value;
  }
  if ($policy.Enabled) {
    if ($policy.Revision -notmatch '^[0-9a-f-]{36}$' -or -not $policy.InstanceId -or $policy.InstanceId.Length -gt 1024 -or -not $policy.HardwareId -or $policy.HardwareId.Length -gt 1024 -or $policy.PortMappings.Count -lt 1 -or $policy.PortMappings.Count -gt 16 -or $policy.BlockingProcessNames.Count -lt 1 -or $policy.BlockingProcessNames.Count -gt 16) { throw 'InvalidPolicy'; }
    foreach ($name in $policy.BlockingProcessNames) { if ($name -notmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $name -match '\.exe$') { throw 'InvalidPolicy'; } }
  }
  return $policy;
}
function Get-PdvNerusSampleDiagnosis {
  # Diagnóstico puro: mantém as mesmas guardas da amostra e nunca deduz uma
  # identidade pelo modelo, nome, porta ou histórico de dispositivos ausentes.
  # Os motivos são textos fixos, sem payload, hostname ou identificador livre.
  param($Session,$Snapshot,$Policy,[DateTimeOffset]$ObservedAt);
  $result=@{Eligible=$false;Reason='';Detail='';Sample=$null};
  if (-not $Snapshot.InventoryComplete -or -not $Snapshot.PresenceComplete) {
    $result.Reason='NerusInventoryIncomplete'; $result.Detail='Correção aguardando inventário completo e presença confirmada. Uma consulta parcial não autoriza escolher outro dispositivo.'; return $result;
  }
  $profiles=@($Session.Config.Profiles | Where-Object {$_.InstanceId -ieq $Policy.InstanceId});
  if ($profiles.Count -eq 0) {
    $result.Reason='NerusPrinterProfileMissing'; $result.Detail='A impressora autorizada na central não tem vínculo local. O suporte precisa vincular a identidade exata; modelo e porta não criam vínculo automático.'; return $result;
  }
  if ($profiles.Count -ne 1) {
    $result.Reason='NerusPrinterProfileAmbiguous'; $result.Detail='Há mais de um perfil local para a identidade autorizada. Corrigir os vínculos antes de permitir a tentativa.'; return $result;
  }
  if ([string]$profiles[0].Role -notmatch 'impressora') {
    $result.Reason='NerusPrinterRoleInvalid'; $result.Detail='O vínculo local da identidade autorizada não está identificado como impressora. Nenhuma configuração do pinpad será alterada.'; return $result;
  }
  $devices=@($Snapshot.Devices | Where-Object {$_.InstanceId -ieq $Policy.InstanceId});
  if ($devices.Count -eq 0) {
    $result.Reason='NerusDeviceNotFound'; $result.Detail='A identidade exata autorizada não foi encontrada. Outro equipamento com mesmo modelo ou outra porta não será escolhido automaticamente.'; return $result;
  }
  if ($devices.Count -ne 1) {
    $result.Reason='NerusDeviceIdentityAmbiguous'; $result.Detail='A consulta retornou mais de um dispositivo para a identidade autorizada. Aguardar uma leitura sem ambiguidade.'; return $result;
  }
  $device=$devices[0];
  if ($device.Present -isnot [bool] -or $device.PresenceKnown -isnot [bool] -or -not $device.PresenceKnown) {
    $result.Reason='NerusDevicePresenceUnknown'; $result.Detail='A presença física da impressora autorizada não foi confirmada. Estado OK ou porta cadastrada isoladamente não provam conexão.'; return $result;
  }
  if (-not $device.Present) {
    $result.Reason='NerusDeviceAbsent'; $result.Detail='A identidade autorizada está ausente. Instâncias antigas mantidas pelo Windows não serão usadas, nem substituídas por outra impressora automaticamente.'; return $result;
  }
  if ([string]$device.ProblemCode -cne '0' -or [string]$device.Status -ine 'OK') {
    $result.Reason='NerusDeviceUnhealthy'; $result.Detail='O Windows não confirmou a impressora autorizada como saudável. A correção do parâmetro aguarda código zero e estado OK.'; return $result;
  }
  $port=([string]$device.Port).ToUpperInvariant();
  if (-not $Policy.PortMappings.ContainsKey($port)) {
    $result.Reason='NerusPortMappingMissing'; $result.Detail='A porta atual da impressora não tem correspondência fiscalDevice homologada na política. Nenhum valor será calculado a partir do número COM.'; return $result;
  }
  foreach ($other in @($Snapshot.Devices)) {
    if ($other.InstanceId -ine $Policy.InstanceId -and [string]$other.Port -ieq $port -and ($other.PresenceKnown -isnot [bool] -or -not $other.PresenceKnown -or $other.Present)) {
      $result.Reason='NerusPortConflict'; $result.Detail='Outra identidade presente ou com presença desconhecida usa a porta atual. A tentativa aguarda exclusão do conflito; instâncias comprovadamente ausentes não contam como ocupação.'; return $result;
    }
  }
  foreach ($other in @($Session.Config.Profiles)) {
    if ($other.InstanceId -ine $Policy.InstanceId -and [string]$other.ExpectedPort -ieq $port) {
      $result.Reason='NerusProfilePortConflict'; $result.Detail='Outro perfil local reserva a porta atual para uma identidade diferente. Conferir os vínculos antes de ajustar o parâmetro.'; return $result;
    }
  }
  $result.Eligible=$true;
  $result.Sample=@{observedAt=$ObservedAt.ToString('o');instanceId=$Policy.InstanceId;actualPort=$port;present=$true;presenceKnown=$true;healthy=$true;inventoryComplete=$true;problemCode='0'};
  return $result;
}
function Get-PdvNerusSample {
  param($Session,$Snapshot,$Policy,[DateTimeOffset]$ObservedAt);
  $diagnosis=Get-PdvNerusSampleDiagnosis $Session $Snapshot $Policy $ObservedAt;
  return $diagnosis.Sample;
}
function Get-PdvNerusEvidence {
  param($Session,$State);
  $policy=$State.Policy; $now=Get-PdvNerusNow;
  if ($State.Samples.Count -ne 3 -or ($now-[DateTimeOffset]::Parse($State.Samples[2].observedAt)).TotalSeconds -gt 3) { return $null; }
  $hardwareId=[string](Get-PdvNerusValue $Session 'HardwareMachineId' '');
  if (-not $hardwareId -or $hardwareId -cne $policy.HardwareId) { return $null; }
  try {
    $running=@(); foreach ($process in @(Get-PdvNerusProcesses)) {
      if ($policy.BlockingProcessNames -icontains [string]$process.ProcessName) { $running += [string]$process.ProcessName; }
    }
    $processAt=(Get-PdvNerusNow).ToString('o');
    if ($running.Count) { return $null; }
    $jobs=@(Get-PdvNerusJobs); $spoolAt=(Get-PdvNerusNow).ToString('o');
    if ($jobs.Count -gt 0 -or ((Get-PdvNerusNow)-$now).TotalSeconds -gt 3) { return $null; }
    return @{hardwareId=$hardwareId;samples=@($State.Samples);processes=@{observedAt=$processAt;complete=$true;checkedNames=@($policy.BlockingProcessNames);runningNames=@()};spooler=@{observedAt=$spoolAt;complete=$true;jobCount=0}};
  } catch { return $null; }
}
function Add-PdvNerusSample {
  param($State,$Sample);
  if ($null -eq $Sample) { $State.Samples=@(); return; }
  if ($State.Samples.Count -and ($State.Samples[-1].actualPort -cne $Sample.actualPort -or $State.Samples[-1].instanceId -cne $Sample.instanceId -or ([DateTimeOffset]::Parse($Sample.observedAt)-[DateTimeOffset]::Parse($State.Samples[-1].observedAt)).TotalSeconds -lt 1)) { $State.Samples=@(); }
  $State.Samples=@($State.Samples | Where-Object {([DateTimeOffset]::Parse($Sample.observedAt)-[DateTimeOffset]::Parse($_.observedAt)).TotalSeconds -le 120})+@($Sample);
  if ($State.Samples.Count -gt 3) { $State.Samples=@($State.Samples[-3..-1]); }
}
function Complete-PdvNerusResponse {
  param($Session,$State,[string]$Text);
  $xml=Read-PdvNerusXml $Text 'PdvMonitorRecovery'; $root=$xml.DocumentElement;
  if ($root.GetAttribute('schemaVersion') -cne '1' -or $null -eq $State.Pending) { throw 'NerusInvalidReply'; }
  $values=@{};
  foreach ($node in $root.ChildNodes) {
    if (@('Status','TicketId','ExpiresAt','ActualPort','BeforeValue','AfterValue','Message') -notcontains $node.Name -or $values.ContainsKey($node.Name) -or $node.Attributes.Count -or $node.SelectNodes('*').Count) { throw 'NerusInvalidReply'; }
    $values[$node.Name]=$node.InnerText;
  }
  $status=[string]$values.Status; $pending=$State.Pending;
  if ([string]$values.ActualPort -cne [string]$pending.ActualPort -or [string]$values.AfterValue -cne [string]$pending.AfterValue) { throw 'NerusInvalidReply'; }
  if ($status -eq 'configured_pending_restart' -and ($pending.Phase -cne 'commit' -or [string]$values.TicketId -cne [string]$pending.TicketId -or [string]$values.BeforeValue -cne [string]$pending.BeforeValue)) { throw 'NerusInvalidReply'; }
  if ($status -eq 'already_correct' -and ($pending.Phase -cne 'prepare' -or $values.TicketId -or [string]$values.BeforeValue -cne [string]$pending.AfterValue)) { throw 'NerusInvalidReply'; }
  if ($status -eq 'conflict' -and [string]$values.TicketId -ceq [string]$pending.TicketId -and $pending.Phase -ceq 'commit') {
    $State.Pending=$null; Save-PdvNerusLedger $Session $State;
    Add-PdvNerusNotice $State 'NerusConfigurationConflict' 'NerusRecoveryBlocked' 'O parâmetro Nerus mudou durante a tentativa. A central preservou a alteração concorrente; nenhuma correção aplicada por esta operação.';
    return $true;
  }
  if (@('already_correct','configured_pending_restart') -contains $status) {
    $State.Pending=$null; Save-PdvNerusLedger $Session $State;
    if ($status -eq 'configured_pending_restart') {
      Add-PdvNerusNotice $State 'ConfiguredPendingRestart' 'NerusRecoveryConfigured' ('Parâmetro fiscalDevice ajustado na central: '+[string]$root.SelectSingleNode('BeforeValue').InnerText+' para '+[string]$root.SelectSingleNode('AfterValue').InnerText+'; porta '+[string]$root.SelectSingleNode('ActualPort').InnerText+'. Será usado na próxima abertura do PDV. Impressão ainda não confirmada.');
    } else { Add-PdvNerusNotice $State 'AlreadyCorrect' 'NerusRecoveryBlocked' 'O parâmetro Nerus já corresponde à porta cadastrada; nenhuma escrita foi necessária.'; }
    return $true;
  }
  if ($status -ne 'prepared') { throw 'NerusInvalidReply'; }
  $ticket=[string]$root.SelectSingleNode('TicketId').InnerText;
  if ($ticket -notmatch '^[0-9a-f-]{36}$' -or [string]$values.BeforeValue -notmatch '^(0|[1-9][0-9]{0,3})$') { throw 'NerusInvalidReply'; }
  $expectedBefore=[string](Get-PdvNerusValue $State.Pending 'ExpectedBefore' '');
  if ($expectedBefore -and [string]$values.BeforeValue -cne $expectedBefore) {
    $State.Pending=$null;Save-PdvNerusLedger $Session $State;throw 'NerusRestartConfigurationChanged';
  }
  $State.Pending.BeforeValue=[string]$values.BeforeValue;
  # Antes de qualquer commit, uma coleta nova e independente substitui a última
  # evidência. Se um processo abriu ou a porta mudou, não enviar a escrita.
  if ($State.Pending.Phase -ne 'prepare') { throw 'NerusInvalidReply'; }
  Wait-PdvNerusFreshSample;
  $fresh=Get-PdvNerusFreshSnapshot; $at=Get-PdvNerusNow;
  $sample=Get-PdvNerusSample $Session $fresh $State.Policy $at;
  if ($null -eq $sample -or ($State.Samples.Count -and $State.Samples[-1].actualPort -cne $sample.actualPort)) { $State.Pending=$null; $State.Samples=@(); Save-PdvNerusLedger $Session $State; throw 'NerusRecheckFailed'; }
  Add-PdvNerusSample $State $sample; $evidence=Get-PdvNerusEvidence $Session $State;
  if ($null -eq $evidence) { $State.Pending=$null; Save-PdvNerusLedger $Session $State; throw 'NerusRecheckFailed'; }
  $body=ConvertTo-PdvHardwareJson @{ticketId=$ticket;evidence=$evidence};
  $State.Pending.Phase='commit'; $State.Pending.TicketId=$ticket; $State.Pending.Body=$body;
  Save-PdvNerusLedger $Session $State;
  return (Complete-PdvNerusResponse $Session $State (Invoke-PdvNerusHttp $Session '/agent/nerus/commit' 'POST' $body));
}
function Invoke-PdvMonitorNerusAutomation {
  [CmdletBinding()]
  param($Session,$Snapshot,[DateTimeOffset]$ObservedAt);
  if (-not $Session.Config.Central.Enabled) { return; }
  if ($null -eq (Get-PdvNerusValue $Session 'NerusAutomation')) {
    $Session | Add-Member -MemberType NoteProperty -Name NerusAutomation -Value (New-PdvNerusState $Session) -Force;
  }
  $state=$Session.NerusAutomation; $now=Get-PdvNerusNow;
  try {
    if ($now -ge $state.NextPolicyAt) {
      $state.NextPolicyAt=$now.AddSeconds(60);
      $previousRevision=''; if ($null -ne $state.Policy) { $previousRevision=$state.Policy.Revision; }
      try { $state.Policy=ConvertFrom-PdvNerusPolicy (Invoke-PdvNerusHttp $Session '/agent/policy'); }
      catch { $state.Policy=$null; $state.Samples=@(); $Session.AutoUpdateEnabled=$false; $state.NextPolicyAt=$now.AddMinutes(5); throw; }
      $Session.AutoUpdateEnabled=[bool]$state.Policy.AutoUpdateEnabled;
      if ($previousRevision -cne $state.Policy.Revision) { $state.Samples=@(); }
    }
    if (-not $state.Healthy) { throw 'NerusLocalStateInvalid'; }
    if ($null -ne $state.Pending) {
      if ($now -lt $state.RetryAt) { return; }; $state.RetryAt=$now.AddMinutes(1);
      $response=Invoke-PdvNerusHttp $Session ('/agent/nerus/'+$state.Pending.Phase) 'POST' $state.Pending.Body;
      [void](Complete-PdvNerusResponse $Session $state $response);
      return;
    }
    if ($null -eq $state.Policy -or -not $state.Policy.Enabled -or -not $state.Policy.WindowOpen) {
      $state.Samples=@();
      Add-PdvNerusNotice $state 'OutsideAutomaticWindow' 'NerusRecoveryBlocked' 'Correção Nerus aguardando política habilitada e horário autorizado. Coleta normal continua.';
      return;
    }
    $diagnosis=Get-PdvNerusSampleDiagnosis $Session $Snapshot $state.Policy $ObservedAt;
    Add-PdvNerusSample $state $diagnosis.Sample;
    if (-not $diagnosis.Eligible) {
      Add-PdvNerusNotice $state $diagnosis.Reason 'NerusRecoveryBlocked' $diagnosis.Detail;
      return;
    }
    if ([bool](Get-PdvNerusValue $Session 'RemoteBusy' $false) -or $state.Samples.Count -ne 3 -or $now -lt $state.NextAttemptAt -or -not $Session.LoggingHealthy -or $Session.MaintenanceArmed) { return; }
    $evidence=Get-PdvNerusEvidence $Session $state;
    if ($null -eq $evidence) {
      Add-PdvNerusNotice $state 'CashierNotConfirmedIdle' 'NerusRecoveryBlocked' 'Correção aguardando equipamento vinculado, identidade da máquina e ausência confirmada de processos PDV/TEF e impressão.';
      return;
    }
    $requestId=[guid]::NewGuid().ToString();
    $body=ConvertTo-PdvHardwareJson @{requestId=$requestId;policyRevision=$state.Policy.Revision;evidence=$evidence};
    $state.Pending=@{Phase='prepare';Body=$body;RequestId=$requestId;TicketId='';ActualPort=[string]$evidence.samples[-1].actualPort;BeforeValue='';AfterValue=[string]$state.Policy.PortMappings[[string]$evidence.samples[-1].actualPort]};
    $approvedBefore=[string](Get-PdvNerusValue $state 'RestartExpectedBefore' '');
    if ($approvedBefore) { if ($approvedBefore -notmatch '^(0|[1-9][0-9]{0,3})$') { throw 'NerusRestartConfigurationChanged'; };$state.Pending.ExpectedBefore=$approvedBefore; }
    $state.NextAttemptAt=$now.AddMinutes(15); $state.RetryAt=$now.AddMinutes(1);
    Save-PdvNerusLedger $Session $state;
    Add-PdvNerusNotice $state $requestId 'NerusRecoveryAttempt' 'Solicitando tentativa de correção do parâmetro da impressora, com equipamento estável e caixa fechado. A central repetirá suas validações antes de escrever.';
    [void](Complete-PdvNerusResponse $Session $state (Invoke-PdvNerusHttp $Session '/agent/nerus/prepare' 'POST' $body));
  } catch {
    $reason='NerusTransportUnavailable';
    if ([string]$_.Exception.Message -match '^Nerus[A-Za-z0-9]+$') { $reason=$_.Exception.Message; }
    if (@('NerusHttp400','NerusHttp409','NerusRecheckFailed','NerusRestartConfigurationChanged') -contains $reason) {
      $state.Pending=$null; $state.Samples=@();
      try { Save-PdvNerusLedger $Session $state; } catch { $state.Healthy=$false; }
    }
    $kind='NerusRecoveryBlocked';
    if ($null -ne $state.Pending) { $kind='NerusRecoveryUncertain'; }
    if (@('NerusLocalStateInvalid','NerusLocalStateWriteFailed') -contains $reason) { $kind='NerusRecoveryFailed'; }
    Add-PdvNerusNotice $state $reason $kind ('Tentativa Nerus não confirmada; motivo='+$reason+'. Nenhuma nova operação será criada sem resolver a anterior. Conferir a política, o relógio e as tentativas na central.');
  }
}
# Inserir neste modulo somente funcoes; argumentos do atalho existem apenas em memoria.
function Get-PdvNerusRestartDesktopPaths {
  return @([Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('CommonDesktopDirectory'));
}
function Test-PdvNerusRestartFileExists {
  param([string]$Path);
  return [IO.File]::Exists($Path);
}
function Get-PdvNerusRestartPathInfo {
  param([string]$Path, [bool]$Directory=$false);
  if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f\x7f]' -or $Path.Substring(2).Contains(':')) { throw 'NerusRestartPathInvalid'; }
  $full=[IO.Path]::GetFullPath($Path); $root=[IO.Path]::GetPathRoot($full);
  $drive=New-Object IO.DriveInfo($root);
  if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'NerusRestartPathNotLocal'; }
  if (($Directory -and -not [IO.Directory]::Exists($full)) -or (-not $Directory -and -not [IO.File]::Exists($full))) { throw 'NerusRestartPathMissing'; }
  $part=$full;
  while ($part) {
    $attributes=[IO.File]::GetAttributes($part);
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NerusRestartReparsePath'; }
    if ([string]::Equals($part.TrimEnd('\'),$root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { break; }
    $part=[IO.Path]::GetDirectoryName($part.TrimEnd('\'));
  }
  return @{FullPath=$full;Directory=$Directory};
}
function Get-PdvNerusRestartFileHash {
  param([string]$Path);
  $algorithm=[Security.Cryptography.SHA256]::Create(); $stream=$null;
  try { $stream=[IO.File]::OpenRead($Path); return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant(); }
  finally { if ($null -ne $stream) { $stream.Close(); }; $algorithm.Clear(); }
}
function Read-PdvNerusRestartShortcut {
  param([string]$Path);
  $shell=$null; $shortcut=$null;
  try {
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($Path);
    return @{TargetPath=[string]$shortcut.TargetPath;Arguments=[string]$shortcut.Arguments;WorkingDirectory=[string]$shortcut.WorkingDirectory};
  } finally {
    if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut); }
    if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell); }
  }
}
function Get-PdvNerusRestartLaunchFromShortcut {
  param([string]$Path);
  try {
    $shortcutInfo=Get-PdvNerusRestartPathInfo $Path;
    if ($shortcutInfo.FullPath -notmatch '\\Nerus\.lnk$') { throw 'NerusRestartShortcutInvalid'; }
    $shortcutHash=Get-PdvNerusRestartFileHash $shortcutInfo.FullPath;
    $entry=Read-PdvNerusRestartShortcut $shortcutInfo.FullPath;
    $target=Get-PdvNerusRestartPathInfo ([string]$entry.TargetPath);
    if ($target.FullPath -notmatch '\\([^\\]+)\.exe$') { throw 'NerusRestartExecutableInvalid'; }
    $name=$matches[1];
    if ($name -match '^(cmd|powershell|powershell_ise|pwsh|wscript|cscript|rundll32|regsvr32|mshta|conhost|explorer|msiexec|control|taskmgr|schtasks|reg|certutil|bitsadmin|curl|wget|ssh|sshd|sftp|scp|telnet|putty|plink|pscp|psftp|mstsc|msrdc|remoteapp|windowsTerminal|wt|chrome|msedge|microsoftedge|iexplore|firefox|brave|opera|browser|java|javaw|pythonw?[0-9.]*|py|perl|ruby|node|dotnet|msbuild|installutil|autohotkey|autoit3|bash|sh|zsh|wsl|busybox|start|runas)$' -or $name -match '^(clisitef|clientesitef|sitef|paygo|pinpad|mobaxterm|anydesk|teamviewer|rustdesk|vnc|psexec)') { throw 'NerusRestartTargetNotAllowed'; }
    $arguments=[string]$entry.Arguments;
    if ($arguments.Length -gt 8192 -or $arguments -match '[\x00-\x1f\x7f]') { throw 'NerusRestartArgumentsInvalid'; }
    $working=[string]$entry.WorkingDirectory;
    if (-not $working) { $lastSlash=$target.FullPath.LastIndexOf('\'); if ($lastSlash -eq 2) { $lastSlash=3; }; $working=$target.FullPath.Substring(0,$lastSlash); }
    $workingInfo=Get-PdvNerusRestartPathInfo $working $true;
    $targetHash=Get-PdvNerusRestartFileHash $target.FullPath;
    if ((Get-PdvNerusRestartFileHash $shortcutInfo.FullPath) -cne $shortcutHash) { throw 'NerusRestartShortcutChanged'; }
    return @{ShortcutPath=$shortcutInfo.FullPath;ShortcutHash=$shortcutHash;TargetPath=$target.FullPath;TargetHash=$targetHash;Arguments=$arguments;WorkingDirectory=$workingInfo.FullPath;ProcessName=$name;StartAttempted=$false};
  } catch {
    if ([string]$_.Exception.Message -match '^NerusRestart[A-Za-z]+$') { throw $_.Exception.Message; }
    throw 'NerusRestartShortcutUnavailable';
  }
}
function Get-PdvNerusDesktopLaunch {
  try {
    $paths=@();
    foreach ($directory in @(Get-PdvNerusRestartDesktopPaths)) {
      if (-not $directory) { continue; }
      $path=([string]$directory).TrimEnd('\')+'\Nerus.lnk';
      if ((Test-PdvNerusRestartFileExists $path) -and $paths -notcontains $path) { $paths+=,$path; }
    }
    if ($paths.Count -eq 0) { throw 'NerusRestartShortcutMissing'; }
    if ($paths.Count -ne 1) { throw 'NerusRestartShortcutAmbiguous'; }
    return (Get-PdvNerusRestartLaunchFromShortcut $paths[0]);
  } catch {
    if ([string]$_.Exception.Message -match '^NerusRestart[A-Za-z]+$') { throw $_.Exception.Message; }
    throw 'NerusRestartShortcutUnavailable';
  }
}
function Test-PdvNerusRestartLaunchUnchanged {
  param($Launch);
  if ($null -eq $Launch) { throw 'NerusRestartLaunchMissing'; }
  $fresh=Get-PdvNerusRestartLaunchFromShortcut ([string]$Launch.ShortcutPath);
  foreach ($key in @('ShortcutPath','TargetPath','WorkingDirectory','ProcessName')) {
    if (-not [string]::Equals([string]$fresh[$key],[string]$Launch[$key],[StringComparison]::OrdinalIgnoreCase)) { throw 'NerusRestartLaunchChanged'; }
  }
  foreach ($key in @('ShortcutHash','TargetHash','Arguments')) {
    if (-not [string]::Equals([string]$fresh[$key],[string]$Launch[$key],[StringComparison]::Ordinal)) { throw 'NerusRestartLaunchChanged'; }
  }
  return $true;
}
function Get-PdvNerusRestartCurrentContext {
  $current=[Diagnostics.Process]::GetCurrentProcess();
  try { return @{SessionId=$current.SessionId;OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}; }
  finally { $current.Dispose(); }
}
function Get-PdvNerusRestartProcesses { return @(Get-Process -ErrorAction Stop); }
function Get-PdvNerusRestartProcessById {
  param([int]$ProcessId);
  return [Diagnostics.Process]::GetProcessById($ProcessId);
}
function Get-PdvNerusRestartProcessIdentity {
  param($Process);
  $Process.Refresh();
  if ($Process.HasExited) { throw 'NerusRestartProcessExited'; }
  $rows=@(Get-WmiObject -Class Win32_Process -Filter ('ProcessId = '+[int]$Process.Id) -ErrorAction Stop);
  if ($rows.Count -ne 1) { throw 'NerusRestartIdentityUnavailable'; }
  $owner=$rows[0].GetOwnerSid();
  if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) { throw 'NerusRestartIdentityUnavailable'; }
  return @{ProcessId=[int]$Process.Id;ProcessName=[string]$Process.ProcessName;TargetPath=[string]$Process.MainModule.FileName;StartTimeTicks=$Process.StartTime.ToUniversalTime().Ticks;SessionId=[int]$Process.SessionId;OwnerSid=[string]$owner.Sid;MainWindowHandle=$Process.MainWindowHandle.ToInt64()};
}
function Test-PdvNerusRestartBindingIdentity {
  param($Identity,$Binding);
  foreach ($key in @('ProcessId','StartTimeTicks','SessionId','MainWindowHandle')) { if ([string]$Identity[$key] -cne [string]$Binding[$key]) { throw 'NerusRestartProcessChanged'; } }
  foreach ($key in @('ProcessName','TargetPath','OwnerSid')) { if (-not [string]::Equals([string]$Identity[$key],[string]$Binding[$key],[StringComparison]::OrdinalIgnoreCase)) { throw 'NerusRestartProcessChanged'; } }
  return $true;
}
function Get-PdvNerusRestartBinding {
  param($Launch);
  try {
    [void](Test-PdvNerusRestartLaunchUnchanged $Launch);
    $same=@(Get-PdvNerusRestartProcesses | Where-Object {[string]$_.ProcessName -ieq [string]$Launch.ProcessName});
    if ($same.Count -ne 1) { throw 'NerusRestartProcessAmbiguous'; }
    $identity=Get-PdvNerusRestartProcessIdentity $same[0]; $context=Get-PdvNerusRestartCurrentContext;
    if (-not [string]::Equals([string]$identity.TargetPath,[string]$Launch.TargetPath,[StringComparison]::OrdinalIgnoreCase) -or [string]$identity.ProcessName -ine [string]$Launch.ProcessName) { throw 'NerusRestartExecutableMismatch'; }
    if ($identity.SessionId -ne $context.SessionId -or [string]$identity.OwnerSid -cne [string]$context.OwnerSid) { throw 'NerusRestartOtherSession'; }
    if ([long]$identity.MainWindowHandle -eq 0 -or [long]$identity.StartTimeTicks -le 0 -or [int]$identity.ProcessId -le 0) { throw 'NerusRestartWindowUnavailable'; }
    return $identity;
  } catch {
    if ([string]$_.Exception.Message -match '^NerusRestart[A-Za-z]+$') { throw $_.Exception.Message; }
    throw 'NerusRestartIdentityUnavailable';
  }
}
function Invoke-PdvNerusRestartCloseRequest {
  param($Binding);
  $process=$null;
  try {
    $process=Get-PdvNerusRestartProcessById ([int]$Binding.ProcessId);
    [void](Test-PdvNerusRestartBindingIdentity (Get-PdvNerusRestartProcessIdentity $process) $Binding);
    # Solicita WM_CLOSE somente a janela exata; nunca encerra o processo a forca.
    return $process.CloseMainWindow();
  } finally { if ($null -ne $process) { $process.Dispose(); } }
}
function Wait-PdvNerusRestartExit {
  param($Binding,[int]$TimeoutMilliseconds=30000);
  $process=$null;
  try {
    try { $process=Get-PdvNerusRestartProcessById ([int]$Binding.ProcessId); }
    catch [ArgumentException] { return $true; }
    if ($process.HasExited) { return $true; }
    if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$Binding.StartTimeTicks) { return $true; }
    return $process.WaitForExit($TimeoutMilliseconds);
  } finally { if ($null -ne $process) { $process.Dispose(); } }
}
function Close-PdvNerusBoundWindow {
  param($Launch,$Binding);
  try {
    [void](Test-PdvNerusRestartLaunchUnchanged $Launch);
    $fresh=Get-PdvNerusRestartBinding $Launch;
    [void](Test-PdvNerusRestartBindingIdentity $fresh $Binding);
    # A leitura de identidade pode levar tempo; conferir os arquivos de novo.
    [void](Test-PdvNerusRestartLaunchUnchanged $Launch);
    if (-not (Invoke-PdvNerusRestartCloseRequest $Binding)) { throw 'NerusRestartCloseRefused'; }
    $exited=[bool](Wait-PdvNerusRestartExit $Binding 30000);
    if (-not $exited) { throw 'NerusRestartCloseTimeout'; }
    return @{Exited=$true;ProcessId=[int]$Binding.ProcessId;Reason='NerusRestartClosed'};
  } catch {
    if ([string]$_.Exception.Message -match '^NerusRestart[A-Za-z]+$') { throw $_.Exception.Message; }
    throw 'NerusRestartCloseUnavailable';
  }
}
function Invoke-PdvNerusRestartLaunchProcess {
  param($Launch);
  $start=New-Object Diagnostics.ProcessStartInfo;
  $start.UseShellExecute=$false; $start.FileName=[string]$Launch.TargetPath;
  $start.Arguments=[string]$Launch.Arguments; $start.WorkingDirectory=[string]$Launch.WorkingDirectory;
  return [Diagnostics.Process]::Start($start);
}
function Wait-PdvNerusRestartStarted {
  param($Process,$Launch,[int]$TimeoutMilliseconds=3000);
  $watch=[Diagnostics.Stopwatch]::StartNew();
  try {
    do {
      $Process.Refresh(); if ($Process.HasExited) { throw 'NerusRestartLaunchExited'; }
      $identity=Get-PdvNerusRestartProcessIdentity $Process; $context=Get-PdvNerusRestartCurrentContext;
      if (-not [string]::Equals([string]$identity.TargetPath,[string]$Launch.TargetPath,[StringComparison]::OrdinalIgnoreCase) -or $identity.SessionId -ne $context.SessionId -or [string]$identity.OwnerSid -cne [string]$context.OwnerSid) { throw 'NerusRestartLaunchIdentityMismatch'; }
      if ([long]$identity.MainWindowHandle -ne 0) { return $identity; }
      Start-Sleep -Milliseconds 150;
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds);
    throw 'NerusRestartLaunchUnconfirmed';
  } finally { $watch.Stop(); }
}
function Start-PdvNerusBoundLaunch {
  param($Launch);
  $process=$null;
  try {
    if ($Launch.StartAttempted -eq $true) { throw 'NerusRestartAlreadyStarted'; }
    [void](Test-PdvNerusRestartLaunchUnchanged $Launch);
    if (@(Get-PdvNerusRestartProcesses | Where-Object {[string]$_.ProcessName -ieq [string]$Launch.ProcessName}).Count -ne 0) { throw 'NerusRestartProcessAlreadyRunning'; }
    [void](Test-PdvNerusRestartLaunchUnchanged $Launch);
    # Nao tentar outra vez se Process.Start falhar depois de criar um processo.
    $Launch.StartAttempted=$true;
    $process=Invoke-PdvNerusRestartLaunchProcess $Launch;
    if ($null -eq $process) { throw 'NerusRestartLaunchUnconfirmed'; }
    $identity=Wait-PdvNerusRestartStarted $process $Launch 3000;
    $same=@(Get-PdvNerusRestartProcesses | Where-Object {[string]$_.ProcessName -ieq [string]$Launch.ProcessName});
    if ($same.Count -ne 1 -or [int]$same[0].Id -ne [int]$identity.ProcessId) { throw 'NerusRestartLaunchAmbiguous'; }
    return @{Started=$true;ProcessId=[int]$identity.ProcessId;StartTimeTicks=[long]$identity.StartTimeTicks;SessionId=[int]$identity.SessionId;Reason='NerusRestartReopened'};
  } catch {
    if ([string]$_.Exception.Message -match '^NerusRestart[A-Za-z]+$') { throw $_.Exception.Message; }
    throw 'NerusRestartLaunchUnavailable';
  } finally { if ($null -ne $process -and $process -is [IDisposable]) { $process.Dispose(); } }
}

function Initialize-PdvNerusRestartContext {
  param($Session);
  if ($null -eq (Get-PdvNerusValue $Session 'NerusRestart')) { $Session | Add-Member -MemberType NoteProperty -Name NerusRestart -Value @{Busy=$false;Stage='Idle';Proposal=$null;Reason='';Result=''} -Force; }
  if ($null -eq (Get-PdvNerusValue $Session 'NerusAutomation')) { $Session | Add-Member -MemberType NoteProperty -Name NerusAutomation -Value (New-PdvNerusState $Session) -Force; }
}
function Read-PdvNerusRestartJournal {
  param($Session);
  $path=Join-Path $Session.DataDirectory 'nerus-reabertura.xml'; $rows=@();
  if (-not [IO.File]::Exists($path)) { return ,$rows; }
  if ((New-Object IO.FileInfo($path)).Length -gt 65536) { throw 'NerusRestartJournalInvalid'; }
  try {
    $xml=Read-PdvNerusXml ([IO.File]::ReadAllText($path)) 'PdvNerusRestartJournal'; $r=$xml.DocumentElement;
    if ($r.GetAttribute('schemaVersion') -cne '1' -or $r.Attributes.Count -ne 1 -or $r.SelectNodes('AgentId').Count -ne 1 -or $r.SelectNodes('Attempts').Count -ne 1 -or $r.SelectNodes('*').Count -ne 2 -or $r.SelectSingleNode('AgentId').InnerText -cne [string]$Session.Config.Central.AgentId) { throw 'InvalidJournal'; }
    foreach ($n in @($r.SelectSingleNode('Attempts').ChildNodes)) {
      if ($n.Name -cne 'Attempt' -or $n.Attributes.Count -ne 3 -or $n.SelectNodes('*').Count -or $n.InnerText) { throw 'InvalidJournal'; }
      $id=$n.GetAttribute('id');$stage=$n.GetAttribute('stage');$at=[DateTimeOffset]::Parse($n.GetAttribute('at'),[Globalization.CultureInfo]::InvariantCulture);
      if ($id -notmatch '^[0-9a-f-]{36}$' -or @('close_requested','closed','repair_requested','repair_confirmed','reopen_requested','reopened','failed','uncertain') -cnotcontains $stage -or $at -gt (Get-PdvNerusNow).AddSeconds(30) -or @($rows | Where-Object {$_.Id -ceq $id}).Count) { throw 'InvalidJournal'; }
      $rows+=@{Id=$id;At=$at;Stage=$stage};
    }
    if ($rows.Count -gt 128) { throw 'InvalidJournal'; }
    return ,$rows;
  } catch { throw 'NerusRestartJournalInvalid'; }
}
function Save-PdvNerusRestartJournal {
  param($Session,[string]$OperationId,[string]$Stage);
  if ($OperationId -notmatch '^[0-9a-f-]{36}$' -or @('close_requested','closed','repair_requested','repair_confirmed','reopen_requested','reopened','failed','uncertain') -cnotcontains $Stage) { throw 'NerusRestartJournalInvalid'; }
  $now=Get-PdvNerusNow; $previous=Read-PdvNerusRestartJournal $Session; $rows=@($previous | Where-Object {$_.At -gt $now.AddDays(-2)});
  $found=$false;
  foreach ($row in $rows) { if ($row.Id -ceq $OperationId) { $row.Stage=$Stage;$found=$true; } }
  if (-not $found) { $rows+=@{Id=$OperationId;At=$now;Stage=$Stage}; }
  if ($rows.Count -gt 128) { throw 'NerusRestartJournalInvalid'; }
  $xml=New-Object Xml.XmlDocument; $r=$xml.CreateElement('PdvNerusRestartJournal');$r.SetAttribute('schemaVersion','1');[void]$xml.AppendChild($r);
  $a=$xml.CreateElement('AgentId');$a.InnerText=[string]$Session.Config.Central.AgentId;[void]$r.AppendChild($a);$list=$xml.CreateElement('Attempts');[void]$r.AppendChild($list);
  foreach ($row in $rows) { $n=$xml.CreateElement('Attempt');$n.SetAttribute('id',$row.Id);$n.SetAttribute('at',$row.At.ToString('o'));$n.SetAttribute('stage',$row.Stage);[void]$list.AppendChild($n); }
  $path=Join-Path $Session.DataDirectory 'nerus-reabertura.xml';$tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';
  try {
    [IO.File]::WriteAllText($tmp,$xml.OuterXml,[Text.Encoding]::UTF8);
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp,$path,$path+'.bak'); } else { [IO.File]::Move($tmp,$path); }
  } catch { throw 'NerusRestartJournalWriteFailed'; }
  finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp); } }
}
function Test-PdvNerusRestartLimit {
  param($Session);
  $now=Get-PdvNerusNow; $rows=Read-PdvNerusRestartJournal $Session; $recent=@($rows | Where-Object {$_.At -gt $now.AddHours(-1)});
  if ($recent.Count -ge 2 -or @($recent | Where-Object {$_.At -gt $now.AddMinutes(-15)}).Count) { throw 'NerusRestartRateLimited'; }
}
function Get-PdvNerusRestartPolicy {
  param($Session);
  if ([bool](Get-PdvNerusValue $Session 'RemoteBusy' $false) -or [bool](Get-PdvNerusValue $Session 'Stopped' $false) -or [bool](Get-PdvNerusValue $Session 'TickBusy' $false) -or [bool](Get-PdvNerusValue $Session 'UpdateStaged' $false) -or -not $Session.Config.Central.Enabled -or -not $Session.LoggingHealthy -or $Session.MaintenanceArmed -or -not $Session.NerusAutomation.Healthy -or $null -ne $Session.NerusAutomation.Pending) { throw 'NerusRestartNotReady'; }
  $p=ConvertFrom-PdvNerusPolicy (Invoke-PdvNerusHttp $Session '/agent/policy');
  if (-not $p.Enabled -or -not $p.WindowOpen) { throw 'NerusRestartWindowClosed'; }
  if (-not $Session.HardwareMachineId -or [string]$Session.HardwareMachineId -cne $p.HardwareId) { throw 'NerusRestartMachineMismatch'; }
  if ((Get-PdvNerusNow) -lt $Session.NerusAutomation.NextAttemptAt) { throw 'NerusRestartRateLimited'; }
  $Session.NerusAutomation.Policy=$p;$Session.NerusAutomation.NextPolicyAt=(Get-PdvNerusNow).AddSeconds(60);
  return $p;
}
function Get-PdvNerusConfigurationForRestart {
  param($Session,$Policy);
  $xml=Read-PdvNerusXml (Invoke-PdvNerusHttp $Session '/agent/nerus/configuration') 'PdvMonitorNerusConfiguration';$r=$xml.DocumentElement;
  if ($r.GetAttribute('schemaVersion') -cne '1' -or $r.Attributes.Count -ne 1 -or $r.SelectNodes('*').Count -ne 4) { throw 'NerusRestartInvalidConfiguration'; }
  $values=@{};
  foreach ($n in $r.ChildNodes) {
    if (@('ServerTime','PolicyRevision','FiscalDevice','Terminal') -cnotcontains $n.Name -or $values.ContainsKey($n.Name) -or $n.Attributes.Count -or $n.SelectNodes('*').Count -or $n.NamespaceURI) { throw 'NerusRestartInvalidConfiguration'; };$values[$n.Name]=$n.InnerText;
  }
  $at=[DateTimeOffset]::MinValue;
  if (-not [DateTimeOffset]::TryParse([string]$values.ServerTime,[ref]$at) -or [Math]::Abs(((Get-PdvNerusNow)-$at).TotalSeconds) -gt 30 -or [string]$values.PolicyRevision -cne $Policy.Revision -or [string]$values.Terminal -ine [string]$Session.Config.Central.Terminal -or [string]$values.FiscalDevice -notmatch '^(0|[1-9][0-9]{0,3})$') { throw 'NerusRestartInvalidConfiguration'; }
  return $values;
}
function Get-PdvNerusRestartSamples {
  param($Session,$Policy);
  $samples=@();$port='';
  for ($i=0;$i -lt 3;$i++) {
    if ($i) { Wait-PdvNerusFreshSample; }
    $snapshot=Get-PdvNerusFreshSnapshot;$at=Get-PdvNerusNow;$d=Get-PdvNerusSampleDiagnosis $Session $snapshot $Policy $at;
    if (-not $d.Eligible) { throw $d.Reason; }
    if ($port -and $port -cne $d.Sample.actualPort) { throw 'NerusRestartPortChanged'; }
    $port=$d.Sample.actualPort;$samples+=@($d.Sample);
  }
  return ,$samples;
}
function Get-PdvNerusRestartAssessment {
  param($Session);
  $p=Get-PdvNerusRestartPolicy $Session; Test-PdvNerusRestartLimit $Session;
  $samples=Get-PdvNerusRestartSamples $Session $p;
  $c=Get-PdvNerusConfigurationForRestart $Session $p;$port=[string]$samples[-1].actualPort;$target=[string]$p.PortMappings[$port];
  if ([string]$c.FiscalDevice -ceq $target) { throw 'NerusRestartAlreadyCorrect'; }
  $launch=Get-PdvNerusDesktopLaunch;$binding=Get-PdvNerusRestartBinding $launch;
  if ($p.BlockingProcessNames -inotcontains [string]$launch.ProcessName) { throw 'NerusRestartProcessNotAuthorized'; }
  foreach ($process in @(Get-PdvNerusProcesses)) { if ($p.BlockingProcessNames -icontains [string]$process.ProcessName -and [string]$process.ProcessName -ine [string]$launch.ProcessName) { throw 'NerusRestartOtherProcessRunning'; } }
  if (@(Get-PdvNerusJobs).Count) { throw 'NerusRestartPrinting'; }
  return @{Id=[guid]::NewGuid().ToString();CreatedAt=(Get-PdvNerusNow);ExpiresAt=(Get-PdvNerusNow).AddMinutes(2);AgentId=[string]$Session.Config.Central.AgentId;HardwareId=$p.HardwareId;PolicyRevision=$p.Revision;InstanceId=$p.InstanceId;ActualPort=$port;BeforeValue=[string]$c.FiscalDevice;AfterValue=$target;Terminal=[string]$c.Terminal;Launch=$launch;Binding=$binding};
}
function Set-PdvNerusRestartFailure {
  param($Session,[string]$Reason,[bool]$Closed=$false);
  $r=$Session.NerusRestart;$r.Reason=$Reason;
  if ($Closed) { $r.Result='O Nerus foi fechado, mas a correção ou a reabertura não foi confirmada. Confira a tentativa na central. Se houver resultado incerto, aguarde a confirmação antes de abrir o Nerus manualmente.'; }
  else { $r.Result='A tentativa foi interrompida antes do ajuste. O monitor não forçou o fechamento do Nerus. Confira o vínculo da impressora, o mapa da porta, a janela autorizada e o atalho Nerus; depois tente novamente.'; }
  switch ($Reason) {
    'NerusRestartAlreadyCorrect' {$r.Result='O parâmetro Nerus já corresponde à porta atual da impressora. O programa não foi fechado; esta tentativa atende somente à divergência de porta.';}
    'NerusRestartWindowClosed' {$r.Result='A correção não está habilitada ou está fora da janela autorizada na central. O Nerus permanece aberto.';}
    'NerusRestartRateLimited' {$r.Result='Aguarde pelo menos quinze minutos entre tentativas. São permitidas no máximo duas tentativas por hora.';}
    'NerusRestartProposalExpired' {$r.Result='A confirmação expirou ou os dados mudaram. Verifique novamente a porta antes de confirmar outra tentativa.';}
  }
  $kind='NerusRecoveryBlocked';if($Closed){$kind='NerusRecoveryFailed';};if($null -ne $Session.NerusAutomation.Pending){$kind='NerusRecoveryUncertain';}
  Add-PdvNerusNotice $Session.NerusAutomation $Reason $kind $r.Result;
}
function Invoke-PdvMonitorNerusRestartProbe {
  [CmdletBinding()]param($Session);
  Initialize-PdvNerusRestartContext $Session;$r=$Session.NerusRestart;$r.Busy=$true;$r.Stage='Checking';$r.Proposal=$null;$r.Result='';$r.Reason='';
  try { $r.Proposal=Get-PdvNerusRestartAssessment $Session;$r.Stage='AwaitingConfirmation'; }
  catch { $reason='NerusRestartCheckUnavailable';if([string]$_.Exception.Message -match '^Nerus[A-Za-z0-9]+$'){$reason=$_.Exception.Message;};Set-PdvNerusRestartFailure $Session $reason;$r.Stage='Idle'; }
  finally { $r.Busy=$false; }
}
function Invoke-PdvMonitorNerusRestartApply {
  [CmdletBinding()]param($Session,[string]$ProposalId);
  Initialize-PdvNerusRestartContext $Session;$r=$Session.NerusRestart;$approved=$r.Proposal;$r.Proposal=$null;$r.Busy=$true;$r.Stage='Applying';$r.Reason='';$r.Result='';$closed=$false;$journalStarted=$false;
  try {
    if ($null -eq $approved -or $ProposalId -cne [string]$approved.Id -or $ProposalId -notmatch '^[0-9a-f-]{36}$' -or (Get-PdvNerusNow) -gt $approved.ExpiresAt -or $approved.AgentId -cne [string]$Session.Config.Central.AgentId) { throw 'NerusRestartProposalExpired'; }
    # A proposta não é autorização reutilizável: repetir coleta, leitura e
    # identidade depois da confirmação local, sem confiar na tela antiga.
    $fresh=Get-PdvNerusRestartAssessment $Session;
    foreach ($key in @('AgentId','HardwareId','PolicyRevision','InstanceId','ActualPort','BeforeValue','AfterValue','Terminal')) { if ([string]$fresh[$key] -cne [string]$approved[$key]) { throw 'NerusRestartProposalExpired'; } }
    foreach ($key in @('ShortcutHash','TargetHash','TargetPath','WorkingDirectory','Arguments')) { if ([string]$fresh.Launch[$key] -cne [string]$approved.Launch[$key]) { throw 'NerusRestartProposalExpired'; } }
    foreach ($key in @('ProcessId','StartTimeTicks','SessionId','OwnerSid','TargetPath','ProcessName','MainWindowHandle')) { if ([string]$fresh.Binding[$key] -cne [string]$approved.Binding[$key]) { throw 'NerusRestartProposalExpired'; } }
    if ((Get-PdvNerusNow) -gt $approved.ExpiresAt) { throw 'NerusRestartProposalExpired'; }
    $beforeClosePolicy=Get-PdvNerusRestartPolicy $Session;
    if ($beforeClosePolicy.Revision -cne $approved.PolicyRevision) { throw 'NerusRestartPolicyChanged'; }
    $beforeCloseConfig=Get-PdvNerusConfigurationForRestart $Session $beforeClosePolicy;
    if ($beforeCloseConfig.FiscalDevice -ceq $approved.AfterValue) { throw 'NerusRestartAlreadyCorrect'; }
    if ($beforeCloseConfig.FiscalDevice -cne $approved.BeforeValue) { throw 'NerusRestartProposalExpired'; }
    Save-PdvNerusRestartJournal $Session $ProposalId 'close_requested';$journalStarted=$true;
    Add-PdvNerusNotice $Session.NerusAutomation ('RestartClose'+$ProposalId) 'NerusRecoveryAttempt' 'Operador confirmou ausência de venda e pagamento e autorizou uma tentativa. Solicitando fechamento normal da instância exata do Nerus, sem encerramento forçado.';
    $r.Stage='Closing';$close=Close-PdvNerusBoundWindow $fresh.Launch $fresh.Binding;
    if (-not $close.Exited) { throw 'NerusRestartCloseNotConfirmed'; };$closed=$true;
    Save-PdvNerusRestartJournal $Session $ProposalId 'closed';
    $p=Get-PdvNerusRestartPolicy $Session;
    if ($p.Revision -cne $approved.PolicyRevision) { throw 'NerusRestartPolicyChanged'; }
    $state=$Session.NerusAutomation;$state.Samples=@();$state.LastReason='';$r.Stage='Correcting';$state.RestartExpectedBefore=$approved.BeforeValue;
    Save-PdvNerusRestartJournal $Session $ProposalId 'repair_requested';
    for ($i=0;$i -lt 3;$i++) {
      if ($i) { Wait-PdvNerusFreshSample; }
      $snapshot=Get-PdvNerusFreshSnapshot;$at=Get-PdvNerusNow;$d=Get-PdvNerusSampleDiagnosis $Session $snapshot $p $at;
      if (-not $d.Eligible -or $d.Sample.actualPort -cne $approved.ActualPort) { throw 'NerusRestartPortChanged'; }
      Invoke-PdvMonitorNerusAutomation $Session $snapshot $at;
    }
    if ($null -ne $state.Pending) { throw 'NerusRestartOutcomeUncertain'; }
    if (-not $state.Healthy -or @('ConfiguredPendingRestart','AlreadyCorrect') -cnotcontains $state.LastReason) { throw 'NerusRestartRepairNotConfirmed'; }
    $verify=Get-PdvNerusConfigurationForRestart $Session $p;
    if ($verify.FiscalDevice -cne $approved.AfterValue) { throw 'NerusRestartRepairNotConfirmed'; }
    Save-PdvNerusRestartJournal $Session $ProposalId 'repair_confirmed';
    # Um ticket sem resultado impede reabrir e impede repetir fechamento.
    # A retomada idempotente normal poderá esclarecer a escrita, mas nunca
    # recebe autorização para relançar o programa após reinício do monitor.
    if ($null -ne $state.Pending) { throw 'NerusRestartOutcomeUncertain'; }
    foreach ($process in @(Get-PdvNerusProcesses)) { if ($p.BlockingProcessNames -icontains [string]$process.ProcessName) { throw 'NerusRestartOtherProcessRunning'; } }
    if (@(Get-PdvNerusJobs).Count) { throw 'NerusRestartPrinting'; }
    $r.Stage='Reopening';Save-PdvNerusRestartJournal $Session $ProposalId 'reopen_requested';
    $started=Start-PdvNerusBoundLaunch $fresh.Launch;
    if ($null -eq $started -or [int]$started.ProcessId -le 0) { throw 'NerusRestartReopenNotConfirmed'; }
    Save-PdvNerusRestartJournal $Session $ProposalId 'reopened';$r.Reason='NerusRestartReopened';
    $r.Result='A porta foi conferida e o Nerus foi reaberto pelo atalho autorizado. A nova execução poderá carregar suas DLLs novamente. Faça uma impressão de conferência; o monitor ainda não confirmou a impressão.';
    Add-PdvNerusNotice $state ('RestartReopened'+$ProposalId) 'NerusRecoveryConfigured' $r.Result;
  } catch {
    $reason='NerusRestartFailed';if([string]$_.Exception.Message -match '^Nerus[A-Za-z0-9]+$'){$reason=$_.Exception.Message;}
    if ($journalStarted) { try { $stage='failed';if($null -ne $Session.NerusAutomation.Pending){$stage='uncertain';};Save-PdvNerusRestartJournal $Session $ProposalId $stage; } catch { $reason='NerusRestartJournalWriteFailed'; } }
    Set-PdvNerusRestartFailure $Session $reason $closed;
  } finally { [void]$Session.NerusAutomation.Remove('RestartExpectedBefore');$r.Proposal=$null;$r.Busy=$false;$r.Stage='Idle'; }
}

# Reinicio assistido do servico local: sem SQL, COM, hot reload ou descoberta por tentativa.
function Test-PdvNerusServiceNerusName {
  param([string]$Name);
  $plain=New-Object Text.StringBuilder;
  foreach($c in $Name.Normalize([Text.NormalizationForm]::FormD).ToCharArray()){if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark){[void]$plain.Append($c);}}
  return ($plain.ToString() -match 'nerus');
}
function Get-PdvNerusServiceProcessDiagnostics {
  $items=@();foreach($p in @(Get-Process -ErrorAction Stop)){if(Test-PdvNerusServiceNerusName ([string]$p.ProcessName)){$items+=,@{ProcessName=[string]$p.ProcessName;ProcessId=[int]$p.Id};if($items.Count -ge 16){break;}}};return $items;
}
function Get-PdvNerusServiceRows { return @(Get-WmiObject -Class Win32_Service -ErrorAction Stop); }
function Get-PdvNerusServiceProcessRows { return @(Get-WmiObject -Class Win32_Process -Property ProcessId,ParentProcessId -ErrorAction Stop); }
function Get-PdvNerusServiceProcessIdentity {
  param([int]$ProcessId);
  $p=$null;
  try {
    $p=[Diagnostics.Process]::GetProcessById($ProcessId);$p.Refresh();
    if($p.HasExited){throw 'NerusServiceProcessChanged';}
    return @{ProcessId=[int]$p.Id;StartTimeTicks=$p.StartTime.ToUniversalTime().Ticks;ExecutablePath=[string]$p.MainModule.FileName;ProcessName=[string]$p.ProcessName};
  } finally {if($null -ne $p){$p.Dispose();}}
}
function Get-PdvNerusServiceControllerState {
  param([string]$ServiceName);
  Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop;
  Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop;
  $c=New-Object ServiceProcess.ServiceController($ServiceName);
  try {
    $active=@();$required=@();
    foreach($d in @($c.DependentServices)){try{$d.Refresh();if($d.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped){$active+=,[string]$d.ServiceName;}}finally{$d.Dispose();}}
    foreach($d in @($c.ServicesDependedOn)){try{$d.Refresh();$required+=,@{Name=[string]$d.ServiceName;Running=($d.Status -eq [ServiceProcess.ServiceControllerStatus]::Running)};}finally{$d.Dispose();}}
    return @{ActiveDependents=@($active);RequiredServices=@($required)};
  } finally {$c.Dispose();}
}
function Get-PdvNerusServiceModules {
  param([int]$ProcessId);
  $p=$null;$items=@();
  try {
    $p=[Diagnostics.Process]::GetProcessById($ProcessId);
    foreach($m in @($p.Modules)){
      $name=[string]$m.ModuleName;
      if($name -match '^(mp2032|mp2064|e1_impressora[a-z0-9_.-]*|bemafi[a-z0-9_.-]*|siusbxp[a-z0-9_.-]*|clisitef[a-z0-9_.-]*)\.dll$'){
        if($items.Count -ge 16){return @{Complete=$false;Items=@($items);Reason='NerusServiceModulesLimited'};}
        $version=[string]$m.FileVersionInfo.FileVersion;if($version.Length -gt 80 -or $version -match '[\x00-\x1f\x7f]'){$version='';}
        $items+=,@{Name=$name;Version=$version;Observed=$true};
      }
    }
    return @{Complete=$true;Items=@($items);Reason=''};
  } catch {return @{Complete=$false;Items=@();Reason='NerusServiceModulesUnknown'};}
  finally {if($null -ne $p){$p.Dispose();}}
}
function Test-PdvNerusServicePermission {
  param([string]$ServiceName);
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();
  try {$principal=New-Object Security.Principal.WindowsPrincipal($identity);return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);}
  finally {$identity.Dispose();}
}
function Invoke-PdvNerusServiceStop {
  param([string]$ServiceName,$Expected);
  # ServiceController.Stop no .NET Framework pode parar dependentes. WMI envia
  # somente STOP ao nome exato e o SCM recusa se outro dependente surgir.
  $allRows=@(Get-PdvNerusServiceRows);$rows=@($allRows | Where-Object {[string]$_.Name -ceq $ServiceName});
  if($rows.Count -ne 1){throw 'NerusServiceIdentityChanged';}
  $view=Get-PdvNerusServiceView $ServiceName $allRows;if(-not $view.Eligible){throw $view.Reason;}
  if($null -eq $Expected -or [int]$rows[0].ProcessId -ne [int]$Expected.ProcessId -or [string]$rows[0].State -cne 'Running' -or (Get-PdvNerusServiceTextHash ([string]$rows[0].PathName)) -cne [string]$Expected.ConfigurationHash){throw 'NerusServiceIdentityChanged';}
  $identity=Get-PdvNerusServiceProcessIdentity ([int]$Expected.ProcessId);if([long]$identity.StartTimeTicks -ne [long]$Expected.StartTimeTicks -or -not [string]::Equals([string]$identity.ExecutablePath,[string]$Expected.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)){throw 'NerusServiceIdentityChanged';}
  $result=$rows[0].StopService();if([int]$result.ReturnValue -ne 0){throw 'NerusServiceStopRefused';}
}
function Invoke-PdvNerusServiceStart {
  param([string]$ServiceName);
  Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop;
  Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop;
  $c=New-Object ServiceProcess.ServiceController($ServiceName);
  try {$c.Start();}finally{$c.Dispose();}
}
function Wait-PdvNerusServiceStopped {
  param($Expected,[int]$TimeoutMilliseconds=30000);
  $watch=[Diagnostics.Stopwatch]::StartNew();
  try {
    do {
      $rows=@(Get-PdvNerusServiceRows | Where-Object {[string]$_.Name -ceq [string]$Expected.ServiceName});
      if($rows.Count -ne 1){throw 'NerusServiceIdentityChanged';}
      $row=$rows[0];
      if(([string]$row.PathName) -and (Get-PdvNerusServiceTextHash ([string]$row.PathName)) -cne [string]$Expected.ConfigurationHash){throw 'NerusServiceIdentityChanged';}
      $alive=$true;
      try {$identity=Get-PdvNerusServiceProcessIdentity ([int]$Expected.ProcessId);$alive=([long]$identity.StartTimeTicks -eq [long]$Expected.StartTimeTicks);}
      catch [ArgumentException] {$alive=$false;}
      if([string]$row.State -ceq 'Stopped' -and -not $alive){return $true;}
      if([int]$row.ProcessId -ne 0 -and [int]$row.ProcessId -ne [int]$Expected.ProcessId){throw 'NerusServiceIdentityChanged';}
      Start-Sleep -Milliseconds 200;
    } while($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds);
    return $false;
  } finally {$watch.Stop();}
}
function Wait-PdvNerusServiceRunning {
  param($Expected,[int]$TimeoutMilliseconds=30000);
  $watch=[Diagnostics.Stopwatch]::StartNew();
  try {
    do {
      $allRows=@(Get-PdvNerusServiceRows);$rows=@($allRows | Where-Object {[string]$_.Name -ceq [string]$Expected.ServiceName});
      if($rows.Count -ne 1){throw 'NerusServiceIdentityChanged';}
      if((Get-PdvNerusServiceTextHash ([string]$rows[0].PathName)) -cne [string]$Expected.ConfigurationHash){throw 'NerusServiceIdentityChanged';}
      if([string]$rows[0].State -ceq 'Running'){
        $view=Get-PdvNerusServiceView ([string]$Expected.ServiceName) $allRows;
        if(-not $view.Eligible){throw $view.Reason;}
        Test-PdvNerusServiceSameBinding $Expected $view;
        if([long]$view.StartTimeTicks -eq [long]$Expected.StartTimeTicks -or [long]$view.StartTimeTicks -le [long]$Expected.StartTimeTicks){throw 'NerusServiceOldProcess';}
        return $view;
      }
      Start-Sleep -Milliseconds 200;
    } while($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds);
    throw 'NerusServiceStartTimeout';
  } finally {$watch.Stop();}
}
function Get-PdvNerusServiceTextHash {
  param([string]$Text);
  $algorithm=[Security.Cryptography.SHA256]::Create();
  try{return [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant();}finally{$algorithm.Clear();}
}
function Get-PdvNerusServiceExecutable {
  param([string]$ImagePath);
  if(-not $ImagePath -or $ImagePath.Length -gt 8192 -or $ImagePath -match '[\x00-\x1f\x7f]'){throw 'NerusServicePathInvalid';}
  $path='';
  if($ImagePath -match '^"([^"\r\n]+\.exe)"(?:\s+.*)?$'){$path=$matches[1];}
  elseif($ImagePath -match '^([A-Za-z]:\\[^\s"]+\.exe)(?:\s+.*)?$'){$path=$matches[1];}
  else{throw 'NerusServicePathInvalid';}
  try{$info=Get-PdvNerusRestartPathInfo $path;}catch{throw 'NerusServicePathInvalid';}
  $name=([string]$info.FullPath -replace '^.*\\','') -replace '\.exe$','';
  if($name -match '^(svchost|services|cmd|powershell|pwsh|wscript|cscript|rundll32|regsvr32|java|javaw|dotnet|node|python.*|nssm|winsw.*|servicewrapper|srvany|clisitef.*|clientesitef.*|sitef.*|paygo.*)$'){throw 'NerusServiceWrapperNotSupported';}
  return @{ExecutablePath=$info.FullPath;ExecutableHash=(Get-PdvNerusRestartFileHash $info.FullPath);ConfigurationHash=(Get-PdvNerusServiceTextHash $ImagePath);ProcessName=$name};
}
function Get-PdvNerusServiceView {
  param([string]$ServiceName,$Rows);
  $view=@{ServiceName=$ServiceName;DisplayName='';State='Unknown';ServiceType='';StartMode='';ProcessId=0;StartTimeTicks=0;ExecutablePath='';ExecutableHash='';ConfigurationHash='';ProcessName='';Eligible=$false;Reason='NerusServiceDiscoveryIncomplete';PrintModules=@();ModulesComplete=$false;TefModuleObserved=$false};
  try {
    if($ServiceName -notmatch '^[\p{L}\p{Nd}_. -]{1,128}$' -or $ServiceName -notmatch '\S'){throw 'NerusServiceNameInvalid';}
    $same=@($Rows | Where-Object {[string]$_.Name -ceq $ServiceName});if($same.Count -ne 1){throw 'NerusServiceIdentityChanged';}
    $row=$same[0];$view.DisplayName=[string]$row.DisplayName;
    if($view.DisplayName.Length -gt 256 -or $view.DisplayName -match '[\x00-\x1f\x7f]' -or (-not (Test-PdvNerusServiceNerusName $ServiceName) -and -not (Test-PdvNerusServiceNerusName $view.DisplayName))){throw 'NerusServiceNameInvalid';}
    $view.State=[string]$row.State;$view.ServiceType=[string]$row.ServiceType;$view.StartMode=[string](Get-PdvNerusValue $row 'StartMode' '');$view.ProcessId=[int]$row.ProcessId;
    if($view.ProcessId -gt 0){
      try{$diagnosticIdentity=Get-PdvNerusServiceProcessIdentity $view.ProcessId;$view.ExecutablePath=[string]$diagnosticIdentity.ExecutablePath;$view.StartTimeTicks=[long]$diagnosticIdentity.StartTimeTicks;}catch{}
      $diagnosticModules=Get-PdvNerusServiceModules $view.ProcessId;$view.PrintModules=@($diagnosticModules.Items);$view.ModulesComplete=[bool]$diagnosticModules.Complete;$view.TefModuleObserved=(@($view.PrintModules | Where-Object {[string]$_.Name -match '^clisitef'}).Count -gt 0);
    }
    if($view.ServiceType -cne 'Own Process'){throw 'NerusServiceSharedProcess';}
    if(@('Auto','Manual') -cnotcontains $view.StartMode){throw 'NerusServiceDisabled';}
    if($view.State -cne 'Running' -or $view.ProcessId -le 0){throw 'NerusServiceNotRunning';}
    if($row.AcceptStop -isnot [bool] -or -not $row.AcceptStop){throw 'NerusServiceCannotStop';}
    if(@($Rows | Where-Object {[int]$_.ProcessId -eq $view.ProcessId -and [int]$_.ProcessId -gt 0}).Count -ne 1){throw 'NerusServiceSharedProcess';}
    $executable=Get-PdvNerusServiceExecutable ([string]$row.PathName);foreach($key in @('ExecutablePath','ExecutableHash','ConfigurationHash','ProcessName')){$view[$key]=$executable[$key];}
    $identity=Get-PdvNerusServiceProcessIdentity $view.ProcessId;
    if(-not [string]::Equals([string]$identity.ExecutablePath,$view.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or [long]$identity.StartTimeTicks -le 0 -or [int]$identity.ProcessId -ne $view.ProcessId){throw 'NerusServiceProcessChanged';}
    $view.StartTimeTicks=[long]$identity.StartTimeTicks;
    $controller=Get-PdvNerusServiceControllerState $ServiceName;
    if(@($controller.ActiveDependents).Count -gt 0){throw 'NerusServiceActiveDependents';}
    foreach($required in @($controller.RequiredServices)){if($required.Running -isnot [bool] -or -not $required.Running){throw 'NerusServiceDependencyNotRunning';}}
    $processRows=@(Get-PdvNerusServiceProcessRows);
    if(@($processRows | Where-Object {[int]$_.ParentProcessId -eq $view.ProcessId -and [int]$_.ProcessId -ne $view.ProcessId}).Count -gt 0){throw 'NerusServiceChildProcess';}
    $view.Eligible=$true;$view.Reason='';
  } catch {
    $reason=[string]$_.Exception.Message;if($reason -notmatch '^NerusService[A-Za-z]+$'){$reason='NerusServiceDiscoveryIncomplete';};$view.Reason=$reason;
  }
  return $view;
}
function Get-PdvMonitorNerusServiceDiscovery {
  param($Session);
  Initialize-PdvMonitorNerusServiceContext $Session;
  $result=@{Candidates=@();Processes=@();Complete=$false;Reason='NerusServiceDiscoveryIncomplete'};
  try {
    $rows=@(Get-PdvNerusServiceRows);$candidates=@();$limited=$false;
    foreach($row in $rows){if((Test-PdvNerusServiceNerusName ([string]$row.Name)) -or (Test-PdvNerusServiceNerusName ([string]$row.DisplayName))){if($candidates.Count -ge 16){$limited=$true;break;};$candidates+=,(Get-PdvNerusServiceView ([string]$row.Name) $rows);}}
    foreach($process in @(Get-PdvNerusServiceProcessDiagnostics)){$isService=(@($rows | Where-Object {[int]$_.ProcessId -gt 0 -and [int]$_.ProcessId -eq $process.ProcessId}).Count -gt 0);$diagnosis='WindowsService';if(-not $isService){$diagnosis='NonWindowsService';};$result.Processes+=,@{ProcessName=$process.ProcessName;ProcessId=$process.ProcessId;IsWindowsService=$isService;Diagnosis=$diagnosis;Supported=$isService};}
    $result.Candidates=@($candidates);$result.Complete=(-not $limited);$result.Reason='';if($limited){$result.Reason='NerusServiceDiscoveryLimited';}if($candidates.Count -eq 0){$result.Reason='NerusServiceNotFound';if(@($result.Processes).Count -gt 0){$result.Reason='NerusServiceTrayOnly';}}
  } catch {}
  $Session.NerusService.Discovery=$result;return $result;
}
function Get-PdvNerusServiceOwnPath {
  param($Session,[string]$Name);
  $path=Join-Path $Session.DataDirectory $Name;
  if(-not [IO.Directory]::Exists($Session.DataDirectory) -or (([IO.File]::GetAttributes($Session.DataDirectory) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'NerusServiceLocalStateInvalid';}
  if([IO.File]::Exists($path) -and (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'NerusServiceLocalStateInvalid';}
  return $path;
}
function Save-PdvNerusServiceXml {
  param($Session,[string]$Name,$Xml);
  $path=Get-PdvNerusServiceOwnPath $Session $Name;$token=[guid]::NewGuid().ToString('N');$tmp=$path+'.'+$token+'.tmp';$backup=$path+'.'+$token+'.bak';
  try {
    [IO.File]::WriteAllText($tmp,$Xml.OuterXml,[Text.Encoding]::UTF8);
    if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,$backup);}else{[IO.File]::Move($tmp,$path);}
  } catch {throw 'NerusServiceLocalStateWriteFailed';}
  finally {if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp);};if([IO.File]::Exists($backup)){[IO.File]::Delete($backup);}}
}
function Read-PdvNerusServiceBinding {
  param($Session);
  $path=Get-PdvNerusServiceOwnPath $Session 'nerus-servico.xml';if(-not [IO.File]::Exists($path)){return $null;}
  if((New-Object IO.FileInfo($path)).Length -gt 16384){throw 'NerusServiceBindingInvalid';}
  try {
    $xml=Read-PdvNerusXml ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)) 'PdvNerusServiceBinding';$root=$xml.DocumentElement;
    if($root.Attributes.Count -ne 1 -or $root.GetAttribute('schemaVersion') -cne '1'){throw 'Invalid';}
    $binding=@{};$keys=@('ServiceName','DisplayName','ExecutablePath','ExecutableHash','ConfigurationHash','MachineId','BoundAt');
    foreach($n in $root.ChildNodes){if($keys -cnotcontains $n.Name -or $binding.ContainsKey($n.Name) -or $n.Attributes.Count -or $n.SelectNodes('*').Count -or $n.NamespaceURI){throw 'Invalid';};$binding[$n.Name]=[string]$n.InnerText;}
    if($binding.Count -ne $keys.Count -or $binding.ServiceName -notmatch '^[\p{L}\p{Nd}_. -]{1,128}$' -or $binding.DisplayName.Length -gt 256 -or $binding.DisplayName -match '[\x00-\x1f\x7f]' -or (-not (Test-PdvNerusServiceNerusName $binding.ServiceName) -and -not (Test-PdvNerusServiceNerusName $binding.DisplayName)) -or $binding.ExecutablePath -notmatch '^[A-Za-z]:\\[^\r\n]+\.exe$' -or $binding.ExecutableHash -notmatch '^[0-9a-f]{64}$' -or $binding.ConfigurationHash -notmatch '^[0-9a-f]{64}$' -or -not $binding.MachineId -or $binding.MachineId.Length -gt 128 -or $binding.MachineId -match '[\x00-\x1f\x7f]'){throw 'Invalid';}
    $at=[DateTimeOffset]::Parse($binding.BoundAt,[Globalization.CultureInfo]::InvariantCulture);if($at -gt (Get-PdvNerusNow).AddSeconds(30)){throw 'Invalid';}
    return $binding;
  } catch {throw 'NerusServiceBindingInvalid';}
}
function Initialize-PdvMonitorNerusServiceContext {
  param($Session);
  if($null -ne (Get-PdvNerusValue $Session 'NerusService')){return;}
  $state=@{Busy=$false;Stage='Idle';Proposal=$null;Reason='';Result='';Discovery=$null;Binding=$null;Events=(New-Object Collections.Queue);Healthy=$true;OperationActive=$false};
  $Session | Add-Member -MemberType NoteProperty -Name NerusService -Value $state -Force;
  try{$state.Binding=Read-PdvNerusServiceBinding $Session;}catch{$state.Healthy=$false;$state.Reason='NerusServiceBindingInvalid';$state.Result=Get-PdvNerusServiceMessage $state.Reason;}
}
function Save-PdvMonitorNerusServiceBinding {
  param($Session,[string]$ServiceName);
  Initialize-PdvMonitorNerusServiceContext $Session;
  if($Session.NerusService.OperationActive){throw 'NerusServiceBusy';}
  # Trocar o vinculo nunca apaga uma tentativa que ficou pendente.
  Test-PdvNerusServiceLimit $Session $true;
  $machine=[string](Get-PdvNerusValue $Session 'HardwareMachineId' '');if(-not $machine -or $machine.Length -gt 128 -or $machine -match '[\x00-\x1f\x7f]'){throw 'NerusServiceMachineUnknown';}
  $discovery=Get-PdvMonitorNerusServiceDiscovery $Session;
  $matches=@($discovery.Candidates | Where-Object {$_.ServiceName -ceq $ServiceName});
  if(-not $discovery.Complete -or $matches.Count -ne 1){throw 'NerusServiceNotFound';}
  $view=$matches[0];if(-not $view.Eligible){throw $view.Reason;}
  $binding=@{ServiceName=$view.ServiceName;DisplayName=$view.DisplayName;ExecutablePath=$view.ExecutablePath;ExecutableHash=$view.ExecutableHash;ConfigurationHash=$view.ConfigurationHash;MachineId=$machine;BoundAt=(Get-PdvNerusNow).ToString('o')};
  $xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement('PdvNerusServiceBinding');$root.SetAttribute('schemaVersion','1');[void]$xml.AppendChild($root);
  foreach($key in @('ServiceName','DisplayName','ExecutablePath','ExecutableHash','ConfigurationHash','MachineId','BoundAt')){$n=$xml.CreateElement($key);$n.InnerText=[string]$binding[$key];[void]$root.AppendChild($n);}
  Save-PdvNerusServiceXml $Session 'nerus-servico.xml' $xml;
  $Session.NerusService.Binding=$binding;$Session.NerusService.Healthy=$true;$Session.NerusService.Proposal=$null;$Session.NerusService.Reason='';$Session.NerusService.Result='Serviço local vinculado. Nenhum serviço foi reiniciado.';
  return $binding;
}
function Read-PdvNerusServiceJournal {
  param($Session);
  $path=Get-PdvNerusServiceOwnPath $Session 'nerus-servico-tentativas.xml';if(-not [IO.File]::Exists($path)){return @();}
  if((New-Object IO.FileInfo($path)).Length -gt 65536){throw 'NerusServiceJournalInvalid';}
  try {
    $xml=Read-PdvNerusXml ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)) 'PdvNerusServiceJournal';$root=$xml.DocumentElement;
    if($root.Attributes.Count -ne 1 -or $root.GetAttribute('schemaVersion') -cne '1' -or $root.SelectNodes('*').Count -ne 1 -or $root.FirstChild.Name -cne 'Attempts' -or $root.FirstChild.Attributes.Count -ne 0){throw 'Invalid';}
    $rows=@();$seen=@{};
    foreach($n in $root.FirstChild.ChildNodes){
      if($n.Name -cne 'Attempt' -or $n.NamespaceURI -or $n.Attributes.Count -ne 7 -or $n.ChildNodes.Count -ne 0){throw 'Invalid';}
      foreach($a in $n.Attributes){if(@('id','stage','at','startedAt','serviceName','processId','startTimeTicks') -cnotcontains $a.Name){throw 'Invalid';}}
      $id=$n.GetAttribute('id');$stage=$n.GetAttribute('stage');$name=$n.GetAttribute('serviceName');
      $at=[DateTimeOffset]::Parse($n.GetAttribute('at'),[Globalization.CultureInfo]::InvariantCulture);$started=[DateTimeOffset]::Parse($n.GetAttribute('startedAt'),[Globalization.CultureInfo]::InvariantCulture);
      $pidText=$n.GetAttribute('processId');$ticks=$n.GetAttribute('startTimeTicks');
      if($id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $seen.ContainsKey($id) -or @('stop_requested','stopped','start_requested','running','failed','uncertain') -cnotcontains $stage -or $name -notmatch '^[\p{L}\p{Nd}_. -]{1,128}$' -or $at -gt (Get-PdvNerusNow).AddSeconds(30) -or $started -gt $at -or $pidText -notmatch '^[1-9][0-9]{0,9}$' -or [long]$pidText -gt [int]::MaxValue -or $ticks -notmatch '^[1-9][0-9]{0,18}$' -or [decimal]$ticks -gt [long]::MaxValue){throw 'Invalid';}
      $seen[$id]=$true;$rows+=,@{Id=$id;Stage=$stage;At=$at;StartedAt=$started;ServiceName=$name;ProcessId=[int]$pidText;StartTimeTicks=[long]$ticks};if($rows.Count -gt 128){throw 'Invalid';}
    }
    return $rows;
  } catch {throw 'NerusServiceJournalInvalid';}
}
function Save-PdvNerusServiceJournal {
  param($Session,$Proposal,[string]$Stage);
  if(@('stop_requested','stopped','start_requested','running','failed','uncertain') -cnotcontains $Stage){throw 'NerusServiceJournalInvalid';}
  $rows=@(Read-PdvNerusServiceJournal $Session);$now=Get-PdvNerusNow;$entries=@();$started=$now;
  foreach($r in $rows){if($r.Id -ceq $Proposal.Id){$started=$r.StartedAt;}elseif($r.StartedAt -gt $now.AddDays(-2) -or @('running','failed') -cnotcontains $r.Stage){$entries+=,$r;}}
  $entries+=,@{Id=$Proposal.Id;Stage=$Stage;At=$now;StartedAt=$started;ServiceName=$Proposal.ServiceName;ProcessId=$Proposal.ProcessId;StartTimeTicks=$Proposal.StartTimeTicks};if($entries.Count -gt 128){throw 'NerusServiceJournalInvalid';}
  $xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement('PdvNerusServiceJournal');$root.SetAttribute('schemaVersion','1');[void]$xml.AppendChild($root);$attempts=$xml.CreateElement('Attempts');[void]$root.AppendChild($attempts);
  foreach($r in $entries){$n=$xml.CreateElement('Attempt');foreach($pair in @(@('id',$r.Id),@('stage',$r.Stage),@('at',$r.At.ToString('o')),@('startedAt',$r.StartedAt.ToString('o')),@('serviceName',$r.ServiceName),@('processId',[string]$r.ProcessId),@('startTimeTicks',[string]$r.StartTimeTicks))){$n.SetAttribute($pair[0],[string]$pair[1]);};[void]$attempts.AppendChild($n);}
  Save-PdvNerusServiceXml $Session 'nerus-servico-tentativas.xml' $xml;
}
function Test-PdvNerusServiceLimit {
  param($Session,[bool]$OnlyUnresolved=$false);
  $now=Get-PdvNerusNow;$rows=@(Read-PdvNerusServiceJournal $Session);
  if(@($rows | Where-Object {@('running','failed') -cnotcontains $_.Stage}).Count -gt 0){throw 'NerusServicePreviousUncertain';}
  if($OnlyUnresolved){return;}
  $recent=@($rows | Where-Object {$_.StartedAt -gt $now.AddHours(-1)});
  if($recent.Count -ge 2 -or @($recent | Where-Object {$_.StartedAt -gt $now.AddMinutes(-15)}).Count -gt 0){throw 'NerusServiceRateLimited';}
}
function Test-PdvNerusServiceSession {
  param($Session);
  if([bool](Get-PdvNerusValue $Session 'RemoteBusy' $false) -or -not $Session.NerusService.Healthy -or -not $Session.LoggingHealthy -or [bool](Get-PdvNerusValue $Session 'Stopped' $false) -or [bool](Get-PdvNerusValue $Session 'TickBusy' $false) -or [bool](Get-PdvNerusValue $Session 'UpdateStaged' $false) -or [bool]$Session.MaintenanceArmed){throw 'NerusServiceNotReady';}
  $restart=Get-PdvNerusValue $Session 'NerusRestart';if($null -ne $restart -and [bool](Get-PdvNerusValue $restart 'Busy' $false)){throw 'NerusServiceNotReady';}
  $automation=Get-PdvNerusValue $Session 'NerusAutomation';if($null -ne $automation -and ($null -ne (Get-PdvNerusValue $automation 'Pending') -or -not [bool](Get-PdvNerusValue $automation 'Healthy' $false))){throw 'NerusServiceNotReady';}
  if($null -eq $Session.NerusService.Binding){throw 'NerusServiceBindingMissing';}
  $diskBinding=Read-PdvNerusServiceBinding $Session;if($null -eq $diskBinding){throw 'NerusServiceBindingMissing';}
  foreach($key in @('ServiceName','DisplayName','ExecutablePath','ExecutableHash','ConfigurationHash','MachineId','BoundAt')){if([string]$diskBinding[$key] -cne [string]$Session.NerusService.Binding[$key]){throw 'NerusServiceBindingChanged';}}
  if(-not [string](Get-PdvNerusValue $Session 'HardwareMachineId' '') -or [string]$diskBinding.MachineId -cne [string]$Session.HardwareMachineId){throw 'NerusServiceMachineUnknown';}
  if(-not (Test-PdvNerusServicePermission ([string]$diskBinding.ServiceName))){throw 'NerusServicePermissionRequired';}
}
function Test-PdvNerusServiceSameBinding {
  param($Binding,$View);
  foreach($key in @('ServiceName','ExecutablePath','ExecutableHash','ConfigurationHash')){if(-not [string]::Equals([string]$Binding[$key],[string]$View[$key],[StringComparison]::OrdinalIgnoreCase)){throw 'NerusServiceIdentityChanged';}}
}
function Get-PdvNerusServicePrinterEvidence {
  param($Session,[int]$Samples=3);
  $profiles=@($Session.Config.Profiles | Where-Object {[string]$_.Role -match 'impressora'});if($profiles.Count -ne 1){throw 'NerusServicePrinterProfileRequired';}
  $profile=$profiles[0];$port=([string]$profile.ExpectedPort).ToUpperInvariant();
  if(-not $profile.InstanceId -or $port -notmatch '^COM[1-9][0-9]{0,3}$'){throw 'NerusServicePrinterProfileRequired';}
  $maps=@{};$maps[$port]='0';$policy=@{InstanceId=[string]$profile.InstanceId;PortMappings=$maps};
  for($i=0;$i -lt $Samples;$i++){
    if($i){Wait-PdvNerusFreshSample;}
    $snapshot=Get-PdvNerusFreshSnapshot;$d=Get-PdvNerusSampleDiagnosis $Session $snapshot $policy (Get-PdvNerusNow);
    if(-not $d.Eligible -or $null -eq $d.Sample -or [string]$d.Sample.actualPort -cne $port){throw 'NerusServicePrinterNotReady';}
  }
  return @{InstanceId=[string]$profile.InstanceId;ActualPort=$port};
}
function Test-PdvNerusServiceIdle {
  param($Session,$View);
  $names=Get-PdvNerusValue $Session.Config 'BlockingProcessNames' @();
  $normalized=@();foreach($name in @($names)){$n=([string]$name).Trim();if($n.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)){$n=$n.Substring(0,$n.Length-4);};if(-not $n -or $n.Length -gt 120 -or $n -match '[*?\\/:;\x00-\x1f\x7f]'){throw 'NerusServiceBlockersRequired';};$normalized+=,$n;}
  foreach($p in @(Get-PdvNerusProcesses)){
    if($normalized -icontains [string]$p.ProcessName){if([string]$p.ProcessName -ine [string]$View.ProcessName -or [int]$p.Id -ne [int]$View.ProcessId){throw 'NerusServiceBlockingProcess';}}
  }
  if(@(Get-PdvNerusJobs).Count -gt 0){throw 'NerusServicePrinting';}
}
function Get-PdvNerusServiceAssessment {
  param($Session);
  Test-PdvNerusServiceSession $Session;Test-PdvNerusServiceLimit $Session;
  $binding=$Session.NerusService.Binding;$rows=@(Get-PdvNerusServiceRows);$view=Get-PdvNerusServiceView $binding.ServiceName $rows;if(-not $view.Eligible){throw $view.Reason;}
  Test-PdvNerusServiceSameBinding $binding $view;
  $evidence=Get-PdvNerusServicePrinterEvidence $Session;Test-PdvNerusServiceIdle $Session $view;
  # A coleta pode levar segundos; repetir identidade/configuracao depois dela.
  $rows=@(Get-PdvNerusServiceRows);$fresh=Get-PdvNerusServiceView $binding.ServiceName $rows;if(-not $fresh.Eligible){throw $fresh.Reason;};Test-PdvNerusServiceSameBinding $binding $fresh;
  if($fresh.ProcessId -ne $view.ProcessId -or $fresh.StartTimeTicks -ne $view.StartTimeTicks){throw 'NerusServiceIdentityChanged';}
  return @{Id=[guid]::NewGuid().ToString();CreatedAt=(Get-PdvNerusNow);ExpiresAt=(Get-PdvNerusNow).AddMinutes(2);ServiceName=$fresh.ServiceName;DisplayName=$fresh.DisplayName;ActualPort=$evidence.ActualPort;InstanceId=$evidence.InstanceId;ProcessId=$fresh.ProcessId;StartTimeTicks=$fresh.StartTimeTicks;ExecutablePath=$fresh.ExecutablePath;ExecutableHash=$fresh.ExecutableHash;ConfigurationHash=$fresh.ConfigurationHash;MachineId=$binding.MachineId;PrintModules=@($fresh.PrintModules);ModulesComplete=$fresh.ModulesComplete;TefModuleObserved=$fresh.TefModuleObserved;ProcessName=$fresh.ProcessName};
}
function Get-PdvNerusServiceMessage {
  param([string]$Reason);
  switch($Reason){
    'NerusServiceBindingMissing'{return 'Vincule o serviço Nerus identificado neste computador antes de tentar a reinicialização.';}
    'NerusServiceBindingInvalid'{return 'O vínculo local do serviço está inválido. O suporte deve conferir o arquivo antes de cadastrar novamente.';}
    'NerusServiceBindingChanged'{return 'O vínculo do serviço mudou. Consulte novamente antes de confirmar outra tentativa.';}
    'NerusServiceMachineUnknown'{return 'A identidade desta máquina ainda não foi confirmada ou difere do vínculo do serviço. Aguarde o inventário e confira o computador.';}
    'NerusServicePermissionRequired'{return 'Esta ação exige o monitor aberto como administrador. Nenhum serviço foi parado.';}
    'NerusServiceSharedProcess'{return 'O serviço compartilha processo ou não é um serviço de processo próprio. Esta versão não o reinicia.';}
    'NerusServiceActiveDependents'{return 'Há outros serviços ativos que dependem deste componente. A tentativa não para serviços dependentes.';}
    'NerusServiceDependencyNotRunning'{return 'Uma dependência do serviço não está em execução. Verifique o componente antes da tentativa.';}
    'NerusServiceChildProcess'{return 'O serviço possui processo auxiliar ativo. É necessário identificar o hospedeiro da impressão antes de reiniciar.';}
    'NerusServiceWrapperNotSupported'{return 'O serviço usa um hospedeiro ou iniciador genérico. Esta versão não confirma qual processo carrega a impressão.';}
    'NerusServiceNotRunning'{return 'O serviço não está em execução normal. Esta tentativa não inicia serviços previamente parados.';}
    'NerusServiceDisabled'{return 'O serviço está desabilitado ou seu modo de início não foi confirmado. A tentativa não altera sua configuração nem o para para depois tentar habilitar.';}
    'NerusServiceCannotStop'{return 'O serviço não aceita parada normal. O monitor não força seu encerramento.';}
    'NerusServicePrinterProfileRequired'{return 'Salve um único vínculo de impressora, com identidade exata e COM esperada confirmada.';}
    'NerusServicePrinterNotReady'{return 'A impressora não foi confirmada estável e saudável na COM esperada, ou há conflito. A tentativa não altera portas.';}
    'NerusServiceBlockersRequired'{return 'Cadastre os nomes exatos dos processos PDV/TEF que precisam estar fechados antes da manutenção.';}
    'NerusServiceBlockingProcess'{return 'Há processo PDV/TEF bloqueador em execução. Finalize a operação e feche esse componente antes de tentar.';}
    'NerusServicePrinting'{return 'Há impressão pendente no Windows. Aguarde a conclusão antes de reiniciar o serviço.';}
    'NerusServicePreviousUncertain'{return 'Uma tentativa anterior ficou incompleta ou incerta. Confira o serviço e o histórico; o monitor não repete parada ou início automaticamente.';}
    'NerusServiceJournalInvalid'{return 'O histórico local do serviço está inválido. Nenhuma nova tentativa será executada até revisão pelo suporte.';}
    'NerusServiceRateLimited'{return 'Aguarde quinze minutos entre tentativas. São permitidas no máximo duas tentativas por hora.';}
    'NerusServiceProposalExpired'{return 'A confirmação expirou, já foi utilizada ou os dados mudaram. Consulte novamente antes de outra tentativa.';}
    'NerusServiceStopTimeout'{return 'A saída do processo do serviço não foi confirmada no prazo. O monitor não forçou o encerramento nem enviou um novo início.';}
    'NerusServiceStopRefused'{return 'O Windows recusou a parada normal. Nenhum encerramento forçado será realizado.';}
    'NerusServiceStartTimeout'{return 'O novo processo do serviço não foi confirmado no prazo. Confira o serviço antes de retomar o atendimento.';}
    'NerusServiceOldProcess'{return 'O serviço não confirmou uma nova execução do processo. A comunicação da impressora não foi considerada recuperada.';}
    'NerusServiceLocalStateWriteFailed'{return 'Não foi possível registrar a etapa em disco. A sequência foi interrompida; confira o serviço e o histórico antes de retomar.';}
    'NerusServiceNotReady'{return 'O monitor está ocupado, pausado ou com outra manutenção pendente. Aguarde antes de tentar.';}
    'NerusServiceIdentityChanged'{return 'O executável, a configuração ou o processo do serviço mudou. Confira o vínculo antes de tentar novamente.';}
    'NerusServiceProcessChanged'{return 'A identidade do processo do serviço não pôde ser confirmada. Nenhum processo será encerrado à força.';}
    'NerusServiceTrayOnly'{return 'Foi encontrado um aplicativo Nerus em execução, mas nenhum serviço Windows correspondente. O componente de bandeja precisa de validação; esta versão não o fecha ou reinicia.';}
    'NerusServiceNotFound'{return 'Não foi encontrado um único serviço Nerus correspondente ao nome escolhido.';}
    default{return 'Não foi possível confirmar com segurança o serviço e as condições desta tentativa. Nenhuma correção de comunicação foi declarada.';}
  }
}
function Set-PdvNerusServiceFailure {
  param($Session,[string]$Reason,[bool]$AfterStop=$false);
  $s=$Session.NerusService;$s.Reason=$Reason;$s.Result=Get-PdvNerusServiceMessage $Reason;
  $kind='NerusServiceBlocked';if($AfterStop){$kind='RecoveryFailed';$s.Result+=' O serviço pode estar parado ou ter reiniciado; verifique o estado antes de retomar o caixa.';}
  $s.Events.Enqueue(@{Kind=$kind;Reason=$Reason;Detail=$s.Result});
}
function Invoke-PdvMonitorNerusServiceProbe {
  param($Session);
  Initialize-PdvMonitorNerusServiceContext $Session;$s=$Session.NerusService;if($s.OperationActive){return;}
  $s.Busy=$true;$s.OperationActive=$true;$s.Stage='Checking';$s.Proposal=$null;$s.Reason='';$s.Result='';
  try{$s.Proposal=Get-PdvNerusServiceAssessment $Session;$s.Stage='AwaitingConfirmation';}
  catch{$reason=[string]$_.Exception.Message;if($reason -notmatch '^NerusService[A-Za-z]+$'){$reason='NerusServiceCheckUnavailable';};Set-PdvNerusServiceFailure $Session $reason;$s.Stage='Idle';}
  finally{$s.Busy=$false;$s.OperationActive=$false;}
}
function Invoke-PdvMonitorNerusServiceApply {
  param($Session,[string]$ProposalId);
  Initialize-PdvMonitorNerusServiceContext $Session;$s=$Session.NerusService;if($s.OperationActive){return;}
  $approved=$s.Proposal;$s.Proposal=$null;$s.Busy=$true;$s.OperationActive=$true;$s.Stage='Checking';$s.Reason='';$s.Result='';$requested=$false;$journalStarted=$false;
  try {
    if($null -eq $approved -or $ProposalId -cne [string]$approved.Id -or (Get-PdvNerusNow) -gt $approved.ExpiresAt){throw 'NerusServiceProposalExpired';}
    $fresh=Get-PdvNerusServiceAssessment $Session;
    foreach($key in @('ServiceName','DisplayName','ActualPort','InstanceId','ProcessId','StartTimeTicks','ExecutablePath','ExecutableHash','ConfigurationHash','MachineId')){if([string]$approved[$key] -cne [string]$fresh[$key]){throw 'NerusServiceProposalExpired';}}
    if((Get-PdvNerusNow) -gt $approved.ExpiresAt){throw 'NerusServiceProposalExpired';}
    Test-PdvNerusServiceSession $Session;Test-PdvNerusServiceIdle $Session $fresh;
    $rows=@(Get-PdvNerusServiceRows);$last=Get-PdvNerusServiceView $fresh.ServiceName $rows;if(-not $last.Eligible){throw $last.Reason;};Test-PdvNerusServiceSameBinding $approved $last;
    if($last.ProcessId -ne $approved.ProcessId -or $last.StartTimeTicks -ne $approved.StartTimeTicks){throw 'NerusServiceIdentityChanged';}
    Save-PdvNerusServiceJournal $Session $approved 'stop_requested';$journalStarted=$true;
    $s.Events.Enqueue(@{Kind='RecoveryAttempt';Reason='NerusServiceStopRequested';Detail='Operador confirmou venda e pagamento finalizados e autorizou esta tentativa de reiniciar somente o serviço Nerus vinculado. Configuração COM e parâmetro Nerus serão preservados.';});
    $s.Stage='Stopping';$requested=$true;Invoke-PdvNerusServiceStop $approved.ServiceName $approved;
    if(-not (Wait-PdvNerusServiceStopped $approved 30000)){throw 'NerusServiceStopTimeout';}
    Save-PdvNerusServiceJournal $Session $approved 'stopped';
    # Somente iniciar depois de comprovar parada e saida. Revalidar arquivos e
    # configuracao sem exigir estado Running nesta fase.
    Test-PdvNerusServiceSession $Session;
    $rows=@(Get-PdvNerusServiceRows);$stopped=@($rows | Where-Object {[string]$_.Name -ceq $approved.ServiceName});
    if($stopped.Count -ne 1 -or [string]$stopped[0].State -cne 'Stopped' -or [int]$stopped[0].ProcessId -ne 0 -or [string]$stopped[0].ServiceType -cne 'Own Process'){throw 'NerusServiceIdentityChanged';}
    if(@('Auto','Manual') -cnotcontains [string]$stopped[0].StartMode){throw 'NerusServiceDisabled';}
    $exe=Get-PdvNerusServiceExecutable ([string]$stopped[0].PathName);Test-PdvNerusServiceSameBinding $approved @{ServiceName=$approved.ServiceName;ExecutablePath=$exe.ExecutablePath;ExecutableHash=$exe.ExecutableHash;ConfigurationHash=$exe.ConfigurationHash};
    $controller=Get-PdvNerusServiceControllerState $approved.ServiceName;if(@($controller.ActiveDependents).Count -gt 0){throw 'NerusServiceActiveDependents';};foreach($d in @($controller.RequiredServices)){if(-not $d.Running){throw 'NerusServiceDependencyNotRunning';}}
    if(@(Get-PdvNerusServiceProcessRows | Where-Object {[int]$_.ParentProcessId -eq [int]$approved.ProcessId}).Count -gt 0){throw 'NerusServiceChildProcess';}
    Test-PdvNerusServiceIdle $Session $fresh;$printer=Get-PdvNerusServicePrinterEvidence $Session 1;if([string]$printer.InstanceId -cne [string]$approved.InstanceId -or [string]$printer.ActualPort -cne [string]$approved.ActualPort){throw 'NerusServicePrinterNotReady';}
    Save-PdvNerusServiceJournal $Session $approved 'start_requested';$s.Stage='Starting';Invoke-PdvNerusServiceStart $approved.ServiceName;
    $new=Wait-PdvNerusServiceRunning $approved 30000;
    if($null -eq $new -or [long]$new.StartTimeTicks -le [long]$approved.StartTimeTicks){throw 'NerusServiceOldProcess';}
    Save-PdvNerusServiceJournal $Session $approved 'running';$s.Reason='NerusServiceRestarted';$s.Stage='Idle';
    $s.Result='O serviço Nerus foi reiniciado em uma nova execução. A COM e a configuração do Nerus foram preservadas. Confirme a impressão antes de retomar o atendimento; comunicação ainda não validada pelo monitor.';
    $s.Events.Enqueue(@{Kind='NerusServiceRestarted';Reason='NerusServiceRestarted';Detail=$s.Result;});
  } catch {
    $reason=[string]$_.Exception.Message;if($reason -notmatch '^NerusService[A-Za-z]+$'){$reason='NerusServiceActionUnavailable';}
    if($journalStarted){try{$stage='failed';if($requested){$stage='uncertain';};Save-PdvNerusServiceJournal $Session $approved $stage;}catch{$reason='NerusServiceLocalStateWriteFailed';$s.Healthy=$false;}}
    Set-PdvNerusServiceFailure $Session $reason $requested;
  } finally {$s.Proposal=$null;$s.Busy=$false;$s.OperationActive=$false;$s.Stage='Idle';}
}

Export-ModuleMember -Function Invoke-PdvMonitorNerusAutomation,Invoke-PdvMonitorNerusRestartProbe,Invoke-PdvMonitorNerusRestartApply,Get-PdvMonitorNerusServiceDiscovery,Save-PdvMonitorNerusServiceBinding,Initialize-PdvMonitorNerusServiceContext,Invoke-PdvMonitorNerusServiceProbe,Invoke-PdvMonitorNerusServiceApply;

