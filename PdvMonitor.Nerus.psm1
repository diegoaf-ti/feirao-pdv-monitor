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
        if (@('AgentId','NextAttemptAt','Phase','Body','RequestId','TicketId','ActualPort','BeforeValue','AfterValue') -notcontains $node.Name -or $seen.ContainsKey($node.Name) -or $node.Attributes.Count -or $node.SelectNodes('*').Count) { throw 'InvalidState'; }
        $seen[$node.Name]=$node.InnerText;
      }
      if ([string]$seen.AgentId -cne [string]$Session.Config.Central.AgentId) { throw 'StateIdentityMismatch'; }
      $state.NextAttemptAt=[DateTimeOffset]::Parse([string]$seen.NextAttemptAt,[Globalization.CultureInfo]::InvariantCulture);
      if ($state.NextAttemptAt -gt (Get-PdvNerusNow).AddMinutes(15)) { throw 'StateClockInvalid'; }
      if ($seen.Phase) {
        if ([string]$seen.ActualPort -notmatch '^COM[1-9][0-9]{0,3}$' -or [string]$seen.AfterValue -notmatch '^(0|[1-9][0-9]{0,3})$' -or @('prepare','commit') -notcontains $seen.Phase -or -not $seen.Body -or $seen.Body.Length -gt 48000 -or $seen.RequestId -notmatch '^[0-9a-f-]{36}$' -or ($seen.Phase -eq 'commit' -and $seen.TicketId -notmatch '^[0-9a-f-]{36}$')) { throw 'InvalidPending'; }
        $state.Pending=@{Phase=$seen.Phase;Body=$seen.Body;RequestId=$seen.RequestId;TicketId=$seen.TicketId;ActualPort=$seen.ActualPort;BeforeValue=$seen.BeforeValue;AfterValue=$seen.AfterValue};
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
  if (@('/agent/policy','/agent/nerus/prepare','/agent/nerus/commit') -notcontains $Path) { throw 'NerusInvalidPath'; }
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
    $state.NextAttemptAt=$now.AddMinutes(15); $state.RetryAt=$now.AddMinutes(1);
    Save-PdvNerusLedger $Session $state;
    Add-PdvNerusNotice $state $requestId 'NerusRecoveryAttempt' 'Solicitando tentativa de correção do parâmetro da impressora, com equipamento estável e caixa fechado. A central repetirá suas validações antes de escrever.';
    [void](Complete-PdvNerusResponse $Session $state (Invoke-PdvNerusHttp $Session '/agent/nerus/prepare' 'POST' $body));
  } catch {
    $reason='NerusTransportUnavailable';
    if ([string]$_.Exception.Message -match '^Nerus[A-Za-z0-9]+$') { $reason=$_.Exception.Message; }
    if (@('NerusHttp400','NerusHttp409','NerusRecheckFailed') -contains $reason) {
      $state.Pending=$null; $state.Samples=@();
      try { Save-PdvNerusLedger $Session $state; } catch { $state.Healthy=$false; }
    }
    $kind='NerusRecoveryBlocked';
    if ($null -ne $state.Pending) { $kind='NerusRecoveryUncertain'; }
    if (@('NerusLocalStateInvalid','NerusLocalStateWriteFailed') -contains $reason) { $kind='NerusRecoveryFailed'; }
    Add-PdvNerusNotice $state $reason $kind ('Tentativa Nerus não confirmada; motivo='+$reason+'. Nenhuma nova operação será criada sem resolver a anterior. Conferir a política, o relógio e as tentativas na central.');
  }
}
Export-ModuleMember -Function Invoke-PdvMonitorNerusAutomation;
