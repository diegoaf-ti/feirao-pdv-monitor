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
  $oldProtocol=[Net.ServicePointManager]::SecurityProtocol;
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
    if ($null -ne $request) { $request.Headers.Remove('Authorization'); }
    if ($null -ne $stream) { $stream.Dispose(); }
    if ($null -ne $memory) { $memory.Dispose(); }
    if ($null -ne $response) { $response.Close(); }
    [Net.ServicePointManager]::SecurityProtocol=$oldProtocol;
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
    if ($state.Samples.Count -ne 3 -or $now -lt $state.NextAttemptAt -or -not $Session.LoggingHealthy -or $Session.MaintenanceArmed) { return; }
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
  if ([bool](Get-PdvNerusValue $Session 'Stopped' $false) -or [bool](Get-PdvNerusValue $Session 'TickBusy' $false) -or [bool](Get-PdvNerusValue $Session 'UpdateStaged' $false) -or -not $Session.Config.Central.Enabled -or -not $Session.LoggingHealthy -or $Session.MaintenanceArmed -or -not $Session.NerusAutomation.Healthy -or $null -ne $Session.NerusAutomation.Pending) { throw 'NerusRestartNotReady'; }
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

Export-ModuleMember -Function Invoke-PdvMonitorNerusAutomation,Invoke-PdvMonitorNerusRestartProbe,Invoke-PdvMonitorNerusRestartApply;

