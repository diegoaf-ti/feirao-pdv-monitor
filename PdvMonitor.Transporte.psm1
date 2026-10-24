# Transporte opcional. Sintaxe Windows PowerShell 2.0; sem módulos externos.
# Token nunca integra eventos, XML de configuração, retornos ou mensagens.
Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'PdvMonitor.Inventario.psm1')
$script:PdvEventFields = @('EventId', 'Timestamp', 'SessionId', 'Sequence', 'Kind', 'Role', 'InstanceId', 'DeviceName', 'Port', 'Present', 'PresenceKnown', 'Status', 'ProblemCode', 'Reason', 'Detail', 'WindowsChannel', 'RecordId', 'Provider', 'WindowsEventId')
$script:PdvOutboxMaxBytes = 104857600
$script:PdvOutboxMaxRecords = 20000
$script:PdvBatchMaxBytes = 262144
$script:PdvIdentitySwitchContext = $null

function Get-PdvTransportValue {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return ,$Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return ,$Object[$Name] }
  } else {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
  }
  return ,$Default
}

function Set-PdvTransportValue {
  param($Object, [string]$Name, $Value)
  if ($Object -is [Collections.IDictionary]) { $Object[$Name] = $Value }
  else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force }
}

function New-PdvTransportResult {
  param([bool]$Success, [string]$Reason, [bool]$Queued = $false, [int]$Sent = 0)
  return (New-Object PSObject -Property @{Success=$Success; Queued=$Queued; Reason=$Reason; Sent=$Sent})
}

function Get-PdvMonitorTransportNow { return [DateTimeOffset]::Now }

function Test-PdvTransportGuid {
  param($Value)
  return ([string]$Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Test-PdvCentralIdentity {
  param([string]$Endpoint, [string]$StoreId, [string]$Terminal, [string]$AgentId)
  if ($StoreId -notmatch '^[1-9][0-9]{0,3}$' -or $Terminal -notmatch '^[A-Za-z0-9_-]{1,64}$' -or -not (Test-PdvTransportGuid $AgentId)) { return $false }
  try {
    $uri = New-Object Uri($Endpoint, [UriKind]::Absolute)
    return ($Endpoint.Length -le 2048 -and $uri.Scheme -eq 'https' -and $uri.Host -and -not $uri.Query -and -not $uri.Fragment -and -not $uri.UserInfo -and $uri.AbsolutePath -eq '/api/pdv-monitor/ingest')
  } catch { return $false }
}

function Get-PdvTransportPaths {
  param($Session)
  $directory = [IO.Path]::GetFullPath([string](Get-PdvTransportValue $Session 'DataDirectory' ''))
  if (-not [string](Get-PdvTransportValue $Session 'DataDirectory' '')) { throw 'DataDirectoryRequired' }
  $outbox = [string](Get-PdvTransportValue $Session 'OutboxPath' '')
  if (-not $outbox) { $outbox = Join-Path $directory 'outbox'; Set-PdvTransportValue $Session 'OutboxPath' $outbox }
  $outbox = [IO.Path]::GetFullPath($outbox)
  $directoryPrefix = $directory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $outbox.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutboxMustBeInsideDataDirectory' }
  return (New-Object PSObject -Property @{Directory=$directory; Outbox=$outbox; Config=(Join-Path $directory 'central.xml'); Credential=(Join-Path $directory 'central-credencial.bin'); Hardware=(Join-Path $directory 'hardware-pendente.xml'); Software=(Join-Path $directory 'software-pendente.xml'); HardwareAck=(Join-Path $directory 'hardware-confirmado.xml'); SoftwareAck=(Join-Path $directory 'software-confirmado.xml')})
}

function Get-PdvOutboxFiles {
  param([string]$Path)
  if (-not [IO.Directory]::Exists($Path)) { return }
  foreach ($file in [IO.Directory]::GetFiles($Path, '*.xml')) { New-Object IO.FileInfo($file) }
}

function ConvertTo-PdvJsonString {
  param([string]$Value)
  $builder = New-Object Text.StringBuilder
  [void]$builder.Append('"')
  foreach ($character in $Value.ToCharArray()) {
    $code = [int]$character
    if ($code -eq 34) { [void]$builder.Append('\"') }
    elseif ($code -eq 92) { [void]$builder.Append('\\') }
    elseif ($code -lt 32 -or $code -eq 8232 -or $code -eq 8233) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
    else { [void]$builder.Append($character) }
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function ConvertTo-PdvEventJson {
  param($Record)
  $parts = New-Object 'Collections.Generic.List[string]'
  foreach ($field in $script:PdvEventFields) {
    $parts.Add((ConvertTo-PdvJsonString $field) + ':' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Record $field ''))))
  }
  return '{' + [string]::Join(',', $parts.ToArray()) + '}'
}

function New-PdvEnvelopeJson {
  param($Central, [string[]]$EventJson, [string]$BatchId, [string]$HardwareJson='')
  $version='1'; $hardwarePart=''
  if ($HardwareJson) { $version='2'; $hardwarePart=',"hardware":'+$HardwareJson }
  return '{"schemaVersion":'+$version+',"agentId":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'AgentId'))) + ',"storeId":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'StoreId'))) + ',"terminal":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'Terminal'))) + ',"batchId":' + (ConvertTo-PdvJsonString $BatchId) + ',"events":[' + [string]::Join(',', $EventJson) + ']'+$hardwarePart+'}'
}

# Somente incidentes e auditoria de ações saem da máquina. O CSV local guarda
# também a rotina; tipos futuros precisam ser classificados antes de enviar.
function Test-PdvMonitorCentralEvent {
  param($Record)
  $kind=[string](Get-PdvTransportValue $Record 'Kind' '')
  if (@('DeviceDisconnected','DeviceMissing','ComPortChanged','ComPortConflict','HardwareFault','DeviceRestored','HardwareChanged','SecurityThreatDetected','SecurityThreatStatusChanged','RecoveryAttempt','RecoveryResult','RecoveryFailed','NerusRecoveryAttempt','NerusRecoveryConfigured','NerusRecoveryFailed','NerusRecoveryUncertain','NerusServiceRestarted','LogGap','UpdateFailed','UpdateRollback','UpdateRolledBack','RemoteSupportStarted','RemoteSupportEnded','RemoteSupportFailed','RemoteSupportBlocked','RemoteSupportInterrupted','RemoteSupportConsentRequested','RemoteSupportConsentDecision','RemoteSupportConsentDenied','RemoteSupportCloseRequired','RemoteSupportClosed') -contains $kind) { return $true }
  # Estado inválido de recuperação, serviço vinculado indisponível e lacunas
  # merecem atenção; indisponibilidade transitória de uma consulta fica local.
  $reason=[string](Get-PdvTransportValue $Record 'Reason' '')
  return ($kind -eq 'CollectionWarning' -and (@('NerusServiceState','NerusServiceNotObserved') -contains $reason))
}

function Test-PdvMonitorLocalRoutine {
  param($Record)
  if (Test-PdvMonitorCentralEvent $Record) { return $false }
  return (@('Heartbeat','Started','Stopped','MonitorStopped','SessionStarted','SessionStopped','WindowsEvent','WindowsCritical','WindowsError','WindowsEventCoverage','PrinterSnapshot','PortReservations','Snapshot','DeviceSnapshot','MachineInventory','SoftwareInventory','SoftwareInventoryChanged','ServiceDiagnostic','UploadWarning','UploadResumed','RecoveryDecision','NerusRecoveryBlocked','RemoteSupportDiagnostic','CollectionWarning','CollectionRestored','ProfileChanged','CentralConfigured','MaintenanceArmed','MaintenanceDisarmed','UpdateStaged','UpdateApplied') -contains [string](Get-PdvTransportValue $Record 'Kind' ''))
}

function Remove-PdvMonitorRoutineOutbox {
  param($Session,$Paths,$Central)
  if (-not (Test-PdvCentralIdentity ([string]$Central.Endpoint) ([string]$Central.StoreId) ([string]$Central.Terminal) ([string]$Central.AgentId))) { return }
  foreach($file in @(Get-PdvOutboxFiles $Paths.Outbox)) {
    try {
      $record=Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId','StoreId','Terminal') + $script:PdvEventFields)
      $matches=$true
      foreach($field in @('AgentId','StoreId','Terminal')) { if($record[$field] -cne [string](Get-PdvTransportValue $Central $field '')) { $matches=$false } }
      # Só rotina conhecida é descartada da fila anterior. Registros inválidos,
      # tipos desconhecidos e incidentes permanecem para análise, sem expiração.
      if($matches -and (Test-PdvOutboxRecord $record) -and (Test-PdvMonitorLocalRoutine $record)) { [IO.File]::Delete($file.FullName) }
    } catch { }
  }
}

function Test-PdvInventoryAcknowledged {
  param($Central,[string]$Path,[string]$Fingerprint)
  if (-not [IO.File]::Exists($Path)) { return $false }
  try {
    $ack=Read-PdvTransportXml $Path 'PdvMonitorInventoryAcknowledged' @('AgentId','StoreId','Terminal','Endpoint','Fingerprint')
    foreach($field in @('AgentId','StoreId','Terminal','Endpoint')) { if($ack[$field] -cne [string](Get-PdvTransportValue $Central $field '')) { return $false } }
    return ($ack.Fingerprint -ceq $Fingerprint)
  } catch { return $false }
}

function Save-PdvInventoryAcknowledged {
  param($Central,[string]$Path,[string]$Fingerprint)
  if ($Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'InventoryAcknowledgmentInvalid' }
  $values=@{Fingerprint=$Fingerprint}
  foreach($field in @('AgentId','StoreId','Terminal','Endpoint')) { $values[$field]=[string](Get-PdvTransportValue $Central $field '') }
  # Só executar depois do ACK integral. Persistir antes de apagar a pendência:
  # uma queda entre as duas etapas conserva a prova de confirmação em disco.
  Write-PdvTransportAtomicBytes $Path (New-PdvTransportXmlBytes 'PdvMonitorInventoryAcknowledged' $values)
}

function Read-PdvHardwarePending {
  param([string]$Path)
  $values=Read-PdvTransportXml $Path 'PdvMonitorHardware' @('AgentId','StoreId','Terminal','Fingerprint','HardwareJson')
  if ($values.Fingerprint -notmatch '^[a-f0-9]{64}$' -or [Text.Encoding]::UTF8.GetByteCount($values.HardwareJson) -gt 32768 -or -not $values.HardwareJson.StartsWith('{') -or -not $values.HardwareJson.EndsWith('}')) { throw 'HardwarePendingInvalid' }
  return $values
}

function Set-PdvMonitorHardwarePending {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session, [Parameter(Mandatory=$true)][Collections.IDictionary]$Hardware)
  if(Test-PdvIdentitySwitchBlocked $Session){return (New-PdvTransportResult $false 'IdentitySwitchPending')}
  $central=Get-PdvCentralConfig $Session
  if (-not (Get-PdvTransportValue $central 'Enabled' $false)) { return (New-PdvTransportResult $false 'CentralDisabled') }
  try {
    if (-not (Test-PdvCentralIdentity ([string](Get-PdvTransportValue $central 'Endpoint')) ([string](Get-PdvTransportValue $central 'StoreId')) ([string](Get-PdvTransportValue $central 'Terminal')) ([string](Get-PdvTransportValue $central 'AgentId')))) { throw 'InvalidConfiguration' }
    $json=ConvertTo-PdvHardwareJson $Hardware
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw 'HardwareTooLarge' }
    $paths=Get-PdvTransportPaths $Session
    $values=@{AgentId=[string](Get-PdvTransportValue $central 'AgentId');StoreId=[string](Get-PdvTransportValue $central 'StoreId');Terminal=[string](Get-PdvTransportValue $central 'Terminal');Fingerprint=(Get-PdvHardwareFingerprint $Hardware);HardwareJson=$json}
    if ([IO.File]::Exists($paths.Hardware)) {
      $previous=Read-PdvHardwarePending $paths.Hardware
      foreach ($field in @('AgentId','StoreId','Terminal')) { if ($previous[$field] -cne $values[$field]) { throw 'HardwareIdentityMismatch' } }
      if ($previous.Fingerprint -ceq $values.Fingerprint) { return (New-PdvTransportResult $true 'HardwareAlreadyQueued' $true) }
    }
    if (-not [IO.File]::Exists($paths.Hardware) -and (Test-PdvInventoryAcknowledged $central $paths.HardwareAck $values.Fingerprint)) { return (New-PdvTransportResult $true 'HardwareAlreadyAcknowledged' $true) }
    # Inventário representa o estado mais recente. A substituição do único item
    # pendente é atômica e não altera a fila histórica de eventos.
    Write-PdvTransportAtomicBytes $paths.Hardware (New-PdvTransportXmlBytes 'PdvMonitorHardware' $values)
    return (New-PdvTransportResult $true 'HardwareQueued' $true)
  } catch {
    Set-PdvTransportValue $Session 'UploadStatusText' 'Não foi possível persistir o inventário para envio; inventário local preservado.'
    return (New-PdvTransportResult $false 'HardwareQueueFailed')
  }
}

function Get-PdvSoftwarePayloadHash {
  param([string]$Json)
  $hash=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}

function Read-PdvSoftwarePending {
  param([string]$Path)
  $values=Read-PdvTransportXml $Path 'PdvMonitorSoftware' @('AgentId','StoreId','Terminal','Fingerprint','SnapshotId','PayloadHash','SoftwareJson')
  if($values.SoftwareJson.StartsWith('base64:')){
    $bytes=[Convert]::FromBase64String($values.SoftwareJson.Substring(7))
    if($bytes.Length -gt 131072){throw 'SoftwarePendingInvalid'}
    $encoding=New-Object Text.UTF8Encoding($false,$true)
    $values.SoftwareJson=$encoding.GetString($bytes)
  }
  if($values.Fingerprint -notmatch '^[a-f0-9]{64}$' -or -not (Test-PdvTransportGuid $values.SnapshotId) -or $values.PayloadHash -notmatch '^[a-f0-9]{64}$' -or [Text.Encoding]::UTF8.GetByteCount($values.SoftwareJson) -gt 131072 -or -not $values.SoftwareJson.StartsWith('{') -or -not $values.SoftwareJson.EndsWith('}') -or (Get-PdvSoftwarePayloadHash $values.SoftwareJson) -cne $values.PayloadHash){throw 'SoftwarePendingInvalid'}
  return $values
}

function Set-PdvMonitorSoftwarePending {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session,[Parameter(Mandatory=$true)][Collections.IDictionary]$Software,[Parameter(Mandatory=$true)][string]$Fingerprint)
  if(Test-PdvIdentitySwitchBlocked $Session){return (New-PdvTransportResult $false 'IdentitySwitchPending')}
  $central=Get-PdvCentralConfig $Session
  if(-not (Get-PdvTransportValue $central 'Enabled' $false)){return (New-PdvTransportResult $false 'CentralDisabled')}
  try{
    if(-not (Test-PdvCentralIdentity ([string]$central.Endpoint) ([string]$central.StoreId) ([string]$central.Terminal) ([string]$central.AgentId)) -or $Fingerprint -notmatch '^[a-f0-9]{64}$' -or -not (Test-PdvTransportGuid $Software.snapshotId)){throw 'InvalidSoftwareIdentity'}
    $json=ConvertTo-PdvHardwareJson $Software
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 131072){throw 'SoftwareTooLarge'}
    $paths=Get-PdvTransportPaths $Session
    # Base64 limita a expansão dentro do XML; textos válidos com muitos '&'
    # não podem criar uma pendência maior que o próprio leitor admite.
    $values=@{AgentId=[string]$central.AgentId;StoreId=[string]$central.StoreId;Terminal=[string]$central.Terminal;Fingerprint=$Fingerprint;SnapshotId=[string]$Software.snapshotId;PayloadHash=(Get-PdvSoftwarePayloadHash $json);SoftwareJson=('base64:'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))}
    if([IO.File]::Exists($paths.Software)){
      $old=Read-PdvSoftwarePending $paths.Software
      foreach($field in @('AgentId','StoreId','Terminal')){if($old[$field] -cne $values[$field]){throw 'SoftwareIdentityMismatch'}}
      # O mesmo estado pendente conserva identidade e bytes para reenvio.
      if($old.Fingerprint -ceq $Fingerprint){return (New-PdvTransportResult $true 'SoftwareAlreadyQueued' $true)}
    }
    if (-not [IO.File]::Exists($paths.Software) -and (Test-PdvInventoryAcknowledged $central $paths.SoftwareAck $Fingerprint)) { return (New-PdvTransportResult $true 'SoftwareAlreadyAcknowledged' $true) }
    Write-PdvTransportAtomicBytes $paths.Software (New-PdvTransportXmlBytes 'PdvMonitorSoftware' $values)
    return (New-PdvTransportResult $true 'SoftwareQueued' $true)
  }catch{return (New-PdvTransportResult $false 'SoftwareQueueFailed')}
}

function Set-PdvSoftwareUploadBackoff {
  param($Session,[DateTimeOffset]$Now,[bool]$Long=$false)
  $count=[int](Get-PdvTransportValue $Session 'SoftwareUploadFailures' 0)+1
  $count=[Math]::Min(20,$count);$seconds=[Math]::Min(900,30*[Math]::Pow(2,$count-1))
  if($Long){$seconds=900}
  Set-PdvTransportValue $Session 'SoftwareUploadFailures' $count
  Set-PdvTransportValue $Session 'NextSoftwareUploadAt' $Now.AddSeconds($seconds)
}

function Invoke-PdvMonitorSoftwareUpload {
  [CmdletBinding()]param([Parameter(Mandatory=$true)]$Session)
  if(Test-PdvIdentitySwitchBlocked $Session){return (New-PdvTransportResult $false 'IdentitySwitchPending')}
  $central=Get-PdvCentralConfig $Session
  if(-not (Get-PdvTransportValue $central 'Enabled' $false)){return (New-PdvTransportResult $false 'CentralDisabled')}
  $now=Get-PdvMonitorTransportNow;$next=Get-PdvTransportValue $Session 'NextSoftwareUploadAt' $null
  if($next -is [DateTimeOffset] -and $next -gt $now){return (New-PdvTransportResult $false 'BackoffActive')}
  $token=$null;$authorization=$null
  try{
    if(-not (Test-PdvCentralIdentity ([string]$central.Endpoint) ([string]$central.StoreId) ([string]$central.Terminal) ([string]$central.AgentId))){throw 'InvalidConfiguration'}
    $paths=Get-PdvTransportPaths $Session
    if(-not [IO.File]::Exists($paths.Software)){return (New-PdvTransportResult $true 'SoftwareOutboxEmpty')}
    $initialAt=Get-PdvTransportValue $Session 'SoftwareInitialUploadAt' $null
    if(-not [IO.File]::Exists($paths.SoftwareAck) -and $initialAt -is [DateTimeOffset] -and $initialAt -gt $now){return (New-PdvTransportResult $true 'SoftwareBaselineDeferred')}
    $pending=Read-PdvSoftwarePending $paths.Software
    foreach($field in @('AgentId','StoreId','Terminal')){if($pending[$field] -cne [string]$central.$field){Set-PdvSoftwareUploadBackoff $Session $now $true;return (New-PdvTransportResult $false 'SoftwareIdentityMismatch')}}
    try{$token=Unprotect-PdvMonitorToken ([IO.File]::ReadAllBytes($paths.Credential)) $central;if($token -notmatch '^[a-fA-F0-9]{64}$'){throw 'InvalidCredential'}}
    catch{Set-PdvSoftwareUploadBackoff $Session $now $true;return (New-PdvTransportResult $false 'SoftwareCredentialUnavailable')}
    $endpoint=([string]$central.Endpoint).Substring(0,([string]$central.Endpoint).Length-7)+'/agent/software'
    $authorization='Bearer '+[string]$central.AgentId+'.'+$token
    $status=Invoke-PdvMonitorHttpPost $endpoint $authorization ([Text.Encoding]::UTF8.GetBytes($pending.SoftwareJson))
    $authorization=$null
    if($status -ne 204){Set-PdvSoftwareUploadBackoff $Session $now (@(401,403,404,413,415,426,501,503) -contains $status);return (New-PdvTransportResult $false ('SoftwareHttp'+$status))}
    if([IO.File]::Exists($paths.Software)){
      $current=Read-PdvSoftwarePending $paths.Software
      if($current.PayloadHash -ceq $pending.PayloadHash -and $current.SoftwareJson -ceq $pending.SoftwareJson -and $current.SnapshotId -ceq $pending.SnapshotId){Save-PdvInventoryAcknowledged $central $paths.SoftwareAck $pending.Fingerprint;[IO.File]::Delete($paths.Software)}
    }
    Set-PdvTransportValue $Session 'SoftwareUploadFailures' 0
    Set-PdvTransportValue $Session 'NextSoftwareUploadAt' $now.AddSeconds(5)
    return (New-PdvTransportResult $true 'SoftwareAcknowledged' $false 1)
  }catch{Set-PdvSoftwareUploadBackoff $Session $now;return (New-PdvTransportResult $false 'SoftwareUploadFailed')}
  finally{$token=$null;$authorization=$null}
}

function Test-PdvOutboxRecord {
  param($Record)
  foreach ($field in $script:PdvEventFields) {
    $value = Get-PdvTransportValue $Record $field
    if ($value -isnot [string]) { return $false }
  }
  if (-not (Test-PdvTransportGuid (Get-PdvTransportValue $Record 'EventId')) -or -not (Test-PdvTransportGuid (Get-PdvTransportValue $Record 'SessionId'))) { return $false }
  if ([string](Get-PdvTransportValue $Record 'Sequence') -notmatch '^(0|[1-9][0-9]{0,18})$') { return $false }
  $timestamp = [string](Get-PdvTransportValue $Record 'Timestamp')
  if ($timestamp -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$') { return $false }
  try { [void][DateTimeOffset]::Parse($timestamp, [Globalization.CultureInfo]::InvariantCulture) } catch { return $false }
  return $true
}

function New-PdvTransportXmlBytes {
  param([string]$RootName, $Values)
  $memory = New-Object IO.MemoryStream
  $settings = New-Object Xml.XmlWriterSettings
  $settings.Encoding = New-Object Text.UTF8Encoding($false)
  $settings.NewLineHandling = [Xml.NewLineHandling]::Entitize
  $writer = [Xml.XmlWriter]::Create($memory, $settings)
  try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement($RootName)
    $writer.WriteAttributeString('schemaVersion', '1')
    foreach ($key in @($Values.Keys | Sort-Object)) { $writer.WriteElementString([string]$key, [string]$Values[$key]) }
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
    $writer.Flush()
    return ,$memory.ToArray()
  } finally { $writer.Close(); $memory.Close() }
}

function Read-PdvTransportXml {
  param([string]$Path, [string]$RootName, [string[]]$Fields)
  $file = New-Object IO.FileInfo($Path)
  if (-not $file.Exists -or $file.Length -gt $script:PdvBatchMaxBytes) { throw 'XmlSizeInvalid' }
  $settings = New-Object Xml.XmlReaderSettings
  $settings.ProhibitDtd = $true
  $settings.XmlResolver = $null
  $reader = [Xml.XmlReader]::Create($Path, $settings)
  try {
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($reader)
  } finally { $reader.Close() }
  $root = $document.DocumentElement
  if ($null -eq $root -or $root.Name -ne $RootName -or $root.NamespaceURI -ne '' -or $root.GetAttribute('schemaVersion') -ne '1' -or $root.Attributes.Count -ne 1 -or $root.ChildNodes.Count -ne $Fields.Count) { throw 'XmlSchemaInvalid' }
  $values = @{}
  foreach ($node in $root.ChildNodes) {
    if ($Fields -notcontains $node.Name -or $values.ContainsKey($node.Name) -or $node.Attributes.Count -ne 0 -or $node.SelectNodes('*').Count -gt 0) { throw 'XmlFieldInvalid' }
    $values[$node.Name] = [string]$node.InnerText
  }
  return $values
}

function Write-PdvTransportAtomicBytes {
  param([string]$Path, [byte[]]$Bytes)
  $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $backup = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.previous'
  try {
    $durableSwitch=$false
    if($null -ne $script:PdvIdentitySwitchContext){$switchPaths=Get-PdvTransportPaths $script:PdvIdentitySwitchContext.Session;$durableSwitch=([string]::Equals($Path,$switchPaths.Config,[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($Path,$switchPaths.Credential,[StringComparison]::OrdinalIgnoreCase))}
    if($durableSwitch){Write-PdvIdentitySwitchTempBytes $temporary $Bytes}else{[IO.File]::WriteAllBytes($temporary, $Bytes)}
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $backup) }
    else { [IO.File]::Move($temporary, $Path) }
  } finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    if ([IO.File]::Exists($backup)) { try { [IO.File]::Delete($backup) } catch { } }
  }
}

function Get-PdvCredentialEntropy {
  param($Central)
  return ,[Text.Encoding]::UTF8.GetBytes(('FeiraoPdvMonitor|' + [string](Get-PdvTransportValue $Central 'AgentId') + '|' + [string](Get-PdvTransportValue $Central 'StoreId') + '|' + [string](Get-PdvTransportValue $Central 'Terminal')))
}

function Protect-PdvMonitorToken {
  param([string]$Token, $Central)
  Add-Type -AssemblyName System.Security -ErrorAction Stop
  $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
  try { return ,[Security.Cryptography.ProtectedData]::Protect($bytes, (Get-PdvCredentialEntropy $Central), [Security.Cryptography.DataProtectionScope]::CurrentUser) }
  finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-PdvMonitorToken {
  param([byte[]]$Bytes, $Central)
  Add-Type -AssemblyName System.Security -ErrorAction Stop
  $plain = [Security.Cryptography.ProtectedData]::Unprotect($Bytes, (Get-PdvCredentialEntropy $Central), [Security.Cryptography.DataProtectionScope]::CurrentUser)
  try { return [Text.Encoding]::UTF8.GetString($plain) }
  finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Get-PdvCentralConfig {
  param($Session)
  $config = Get-PdvTransportValue $Session 'Config'
  if ($null -eq $config) { $config = @{}; Set-PdvTransportValue $Session 'Config' $config }
  $central = Get-PdvTransportValue $config 'Central'
  if ($null -eq $central) { $central = @{Enabled=$false; Endpoint=''; StoreId=''; Terminal=''; AgentId=''}; Set-PdvTransportValue $config 'Central' $central }
  return $central
}

function Get-PdvInventoryStartupDelay {
  param($Central,[string]$Kind)
  $id=[string](Get-PdvTransportValue $Central 'AgentId' '')
  if (-not (Test-PdvTransportGuid $id)) { return 0 }
  $offset=0; if($Kind -eq 'Software'){$offset=23}
  return (([Convert]::ToInt32($id.Substring(0,4),16)+$offset) % 61)
}

function Set-PdvInventoryStartupWindow {
  param($Session)
  $central=Get-PdvCentralConfig $Session; $now=Get-PdvMonitorTransportNow
  Set-PdvTransportValue $Session 'HardwareInitialUploadAt' $now.AddSeconds((Get-PdvInventoryStartupDelay $central 'Hardware'))
  Set-PdvTransportValue $Session 'SoftwareInitialUploadAt' $now.AddSeconds((Get-PdvInventoryStartupDelay $central 'Software'))
}

# A troca de identidade preserva a fila anterior; arquivar nao e ACK nem remapeia IDs.
function Write-PdvIdentitySwitchTempBytes {
  param([string]$Path,[byte[]]$Bytes)
  $stream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
  try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush();if([Environment]::Version.Major -ge 4){$stream.Flush($true)}}finally{$stream.Dispose()}
}
function Sync-PdvIdentitySwitchCommittedFiles {
  param($Paths)
  foreach($path in @($Paths.Config,$Paths.Credential)){
    [void](Assert-PdvIdentitySwitchPath $path)
    $stream=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try{$stream.Flush();if([Environment]::Version.Major -ge 4){$stream.Flush($true)}}finally{$stream.Dispose()}
  }
}
function Write-PdvIdentitySwitchDurableBytes {
  param([string]$Path,[byte[]]$Bytes)
  [void](Assert-PdvIdentitySwitchPath $Path)
  if([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)){throw 'IdentitySwitchStateAlreadyExists'}
  $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.switch-tmp';$stream=$null
  try{
    Write-PdvIdentitySwitchTempBytes $temporary $Bytes
    [IO.File]::Move($temporary,$Path)
  }finally{if($null -ne $stream){$stream.Dispose()};if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function New-PdvIdentitySwitchSuccess {
  param($Session,[string]$ArchivePath)
  $result=New-PdvTransportResult $true 'ArquivoPreservado'
  $result | Add-Member NoteProperty ArchivePath $ArchivePath
  $result | Add-Member NoteProperty Message 'Central configurada. Fila e credencial protegida da identificação anterior preservadas em arquivo local, sem envio pela nova identificação.'
  Set-PdvTransportValue $Session 'UploadStatusText' $result.Message
  return $result
}
function Get-PdvIdentitySwitchHash {
  param([byte[]]$Bytes)
  $hash=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Assert-PdvIdentitySwitchPath {
  param([string]$Path)
  $full=[IO.Path]::GetFullPath($Path);$probe=$full
  while($probe){
    if([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)){
      if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'IdentitySwitchLinkedPath'}
    }
    $parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break};$probe=$parent
  }
  return $full
}
function Get-PdvIdentitySwitchFileHash {
  param([string]$Path)
  [void](Assert-PdvIdentitySwitchPath $Path)
  if(-not [IO.File]::Exists($Path)){if([IO.Directory]::Exists($Path)){throw 'IdentitySwitchFileExpected'};return ''}
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $hash=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose();$stream.Dispose()}
}
function Get-PdvIdentitySwitchTreeHash {
  param([string]$Path)
  [void](Assert-PdvIdentitySwitchPath $Path)
  if(-not [IO.Directory]::Exists($Path)){if([IO.File]::Exists($Path)){throw 'IdentitySwitchDirectoryExpected'};return ''}
  $prefix=$Path.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
  $pending=@($Path);$lines=New-Object 'Collections.Generic.List[string]';$count=0;$bytes=0L
  while($pending.Count -gt 0){
    $next=@()
    foreach($directory in $pending){
      foreach($entry in [IO.Directory]::GetFileSystemEntries($directory)){
        [void](Assert-PdvIdentitySwitchPath $entry);$count++;if($count -gt 40000){throw 'IdentitySwitchQueueTooLarge'}
        $relative=$entry.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
        if([IO.Directory]::Exists($entry)){$lines.Add(('D|'+(ConvertTo-PdvJsonString $relative)));$next+=,$entry}
        else{$length=(New-Object IO.FileInfo($entry)).Length;$bytes+=$length;if($bytes -gt 104857600){throw 'IdentitySwitchQueueTooLarge'};$lines.Add(('F|'+(ConvertTo-PdvJsonString $relative)+'|'+$length+'|'+(Get-PdvIdentitySwitchFileHash $entry)))}
      }
    }
    $pending=$next
  }
  $lines.Sort([StringComparer]::Ordinal)
  return (Get-PdvIdentitySwitchHash ([Text.Encoding]::UTF8.GetBytes([string]::Join("`n",$lines.ToArray()))))
}
function Get-PdvIdentitySwitchLocations {
  param($Session,[string]$ArchiveId='')
  $paths=Get-PdvTransportPaths $Session
  [void](Assert-PdvIdentitySwitchPath $paths.Directory)
  if(-not [string]::Equals($paths.Outbox,[IO.Path]::GetFullPath((Join-Path $paths.Directory 'outbox')),[StringComparison]::OrdinalIgnoreCase)){throw 'IdentitySwitchOutboxPathInvalid'}
  $parent=Join-Path $paths.Directory 'identidades-anteriores';[void](Assert-PdvIdentitySwitchPath $parent)
  $archive='';if($ArchiveId){if($ArchiveId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'){throw 'IdentitySwitchArchiveInvalid'};$archive=Join-Path $parent $ArchiveId;[void](Assert-PdvIdentitySwitchPath $archive)}
  return @{Paths=$paths;Parent=$parent;Archive=$archive;Journal=(Join-Path $paths.Directory 'identity-switch.xml')}
}
function Get-PdvIdentitySwitchItems {
  param($Paths)
  return @(@{Name='outbox';Source=$Paths.Outbox;Field='OutboxSha256';Directory=$true},@{Name='hardware-pendente.xml';Source=$Paths.Hardware;Field='HardwareSha256';Directory=$false},@{Name='software-pendente.xml';Source=$Paths.Software;Field='SoftwareSha256';Directory=$false},@{Name='hardware-confirmado.xml';Source=$Paths.HardwareAck;Field='HardwareAckSha256';Directory=$false},@{Name='software-confirmado.xml';Source=$Paths.SoftwareAck;Field='SoftwareAckSha256';Directory=$false})
}
function Move-PdvIdentitySwitchEntry {
  param([string]$Source,[string]$Destination,[bool]$Directory)
  [void](Assert-PdvIdentitySwitchPath $Source);[void](Assert-PdvIdentitySwitchPath $Destination)
  if($Directory){[IO.Directory]::Move($Source,$Destination)}else{[IO.File]::Move($Source,$Destination)}
}
function Test-PdvIdentitySwitchInternal {
  param($Session)
  return ($null -ne $script:PdvIdentitySwitchContext -and [object]::ReferenceEquals($script:PdvIdentitySwitchContext.Session,$Session))
}
function Test-PdvIdentitySwitchBlocked {
  param($Session)
  if(Get-PdvTransportValue $Session 'IdentitySwitchBlocked' $false){return $true}
  try{$paths=Get-PdvTransportPaths $Session;return ([IO.File]::Exists((Join-Path $paths.Directory 'identity-switch.xml')) -or [IO.Directory]::Exists((Join-Path $paths.Directory 'identity-switch.xml')))}catch{return $true}
}
function Read-PdvIdentitySwitchJournal {
  param($Session)
  $locations=Get-PdvIdentitySwitchLocations $Session
  [void](Assert-PdvIdentitySwitchPath $locations.Journal)
  $fields=@('ArchiveId','TargetEndpoint','TargetStoreId','TargetTerminal','TargetAgentId','TargetConfigSha256','TargetCredentialSha256','PreviousConfigSha256','PreviousCredentialSha256','OutboxSha256','HardwareSha256','SoftwareSha256','HardwareAckSha256','SoftwareAckSha256')
  $journal=Read-PdvTransportXml $locations.Journal 'PdvMonitorIdentitySwitch' $fields
  $locations=Get-PdvIdentitySwitchLocations $Session $journal.ArchiveId
  if(-not (Test-PdvCentralIdentity $journal.TargetEndpoint $journal.TargetStoreId $journal.TargetTerminal $journal.TargetAgentId) -or -not [IO.Directory]::Exists($locations.Archive)){throw 'IdentitySwitchJournalInvalid'}
  foreach($field in $fields){if($field.EndsWith('Sha256') -and $journal[$field] -cnotmatch '^[a-f0-9]{64}$' -and $journal[$field] -cne ''){throw 'IdentitySwitchJournalInvalid'}}
  if(-not $journal.TargetConfigSha256 -or -not $journal.TargetCredentialSha256 -or -not $journal.OutboxSha256){throw 'IdentitySwitchJournalInvalid'}
  $allowed=@('central.xml','central-credencial.bin','outbox','hardware-pendente.xml','software-pendente.xml','hardware-confirmado.xml','software-confirmado.xml','identity-switch.xml')
  foreach($path in [IO.Directory]::GetFileSystemEntries($locations.Archive)){[void](Assert-PdvIdentitySwitchPath $path);if($allowed -cnotcontains [IO.Path]::GetFileName($path)){throw 'IdentitySwitchArchiveCollision'}}
  foreach($pair in @(@{Name='central.xml';Field='PreviousConfigSha256'},@{Name='central-credencial.bin';Field='PreviousCredentialSha256'})){
    if((Get-PdvIdentitySwitchFileHash (Join-Path $locations.Archive $pair.Name)) -cne $journal[$pair.Field]){throw 'IdentitySwitchSnapshotCollision'}
  }
  return @{Locations=$locations;Journal=$journal}
}
function Complete-PdvIdentitySwitchJournal {
  param($Locations)
  $destination=Join-Path $Locations.Archive 'identity-switch.xml'
  [void](Assert-PdvIdentitySwitchPath $destination)
  if([IO.File]::Exists($destination)){
    if((Get-PdvIdentitySwitchFileHash $destination) -cne (Get-PdvIdentitySwitchFileHash $Locations.Journal)){throw 'IdentitySwitchJournalCollision'}
    [IO.File]::Delete($Locations.Journal)
  }else{Move-PdvIdentitySwitchEntry $Locations.Journal $destination $false}
}
function Recover-PdvIdentitySwitch {
  param($Session)
  $paths=Get-PdvTransportPaths $Session;$journalPath=Join-Path $paths.Directory 'identity-switch.xml'
  if(-not [IO.File]::Exists($journalPath) -and -not [IO.Directory]::Exists($journalPath)){Set-PdvTransportValue $Session 'IdentitySwitchBlocked' $false;return @{Committed=$false;Recovered=$false;ArchivePath=''}}
  Set-PdvTransportValue $Session 'IdentitySwitchBlocked' $true
  $state=Read-PdvIdentitySwitchJournal $Session;$locations=$state.Locations;$journal=$state.Journal
  $configHash=Get-PdvIdentitySwitchFileHash $paths.Config;$credentialHash=Get-PdvIdentitySwitchFileHash $paths.Credential
  $committed=($configHash -ceq $journal.TargetConfigSha256 -and $credentialHash -ceq $journal.TargetCredentialSha256)
  $plans=@()
  foreach($item in @(Get-PdvIdentitySwitchItems $paths)){
    $destination=Join-Path $locations.Archive $item.Name
    if($item.Directory){$archived=Get-PdvIdentitySwitchTreeHash $destination;$current=Get-PdvIdentitySwitchTreeHash $item.Source}else{$archived=Get-PdvIdentitySwitchFileHash $destination;$current=Get-PdvIdentitySwitchFileHash $item.Source}
    $expected=$journal[$item.Field]
    if($committed){if($archived -cne $expected){throw 'IdentitySwitchArchiveCollision'};continue}
    if($archived -and $archived -cne $expected){throw 'IdentitySwitchArchiveCollision'}
    if(-not $expected){if($current -or $archived){throw 'IdentitySwitchRestoreCollision'};continue}
    if($current -ceq $expected){continue}
    if($archived -ceq $expected -and -not $current){$plans+=,@{Item=$item;Archived=$destination;RemoveEmpty=$false};continue}
    if($archived -ceq $expected -and $item.Directory -and [IO.Directory]::Exists($item.Source) -and [IO.Directory]::GetFileSystemEntries($item.Source).Length -eq 0){$plans+=,@{Item=$item;Archived=$destination;RemoveEmpty=$true};continue}
    throw 'IdentitySwitchRestoreCollision'
  }
  if(-not $committed){
    if(($configHash -and $configHash -cne $journal.PreviousConfigSha256 -and $configHash -cne $journal.TargetConfigSha256) -or ($credentialHash -and $credentialHash -cne $journal.PreviousCredentialSha256 -and $credentialHash -cne $journal.TargetCredentialSha256)){throw 'IdentitySwitchConfigurationCollision'}
    # Preflight completo antes de restaurar qualquer caminho. Colisao diferente
    # bloqueia a central, preservando ambas as copias para o suporte.
    foreach($plan in $plans){if($plan.RemoveEmpty){[IO.Directory]::Delete($plan.Item.Source,$false)};Move-PdvIdentitySwitchEntry $plan.Archived $plan.Item.Source $plan.Item.Directory}
    foreach($pair in @(@{Source=$paths.Config;Name='central.xml';Hash=$journal.PreviousConfigSha256},@{Source=$paths.Credential;Name='central-credencial.bin';Hash=$journal.PreviousCredentialSha256})){
      if($pair.Hash){if((Get-PdvIdentitySwitchFileHash $pair.Source) -cne $pair.Hash){Write-PdvTransportAtomicBytes $pair.Source ([IO.File]::ReadAllBytes((Join-Path $locations.Archive $pair.Name)))}}
      elseif([IO.File]::Exists($pair.Source)){[IO.File]::Delete($pair.Source)}
    }
  }
  if($committed){Sync-PdvIdentitySwitchCommittedFiles $paths}
  Complete-PdvIdentitySwitchJournal $locations
  Set-PdvTransportValue $Session 'IdentitySwitchBlocked' $false
  return @{Committed=$committed;Recovered=$true;ArchivePath=$locations.Archive}
}
function Test-PdvCentralIdentityNeedsArchive {
  param($Session,$NewCentral,$Paths)
  $previous=Get-PdvCentralConfig $Session
  if([string](Get-PdvTransportValue $previous 'AgentId' '')){foreach($field in @('AgentId','StoreId','Terminal')){if([string](Get-PdvTransportValue $previous $field '') -cne [string]$NewCentral[$field]){return $true}}}
  foreach($file in @(Get-PdvOutboxFiles $Paths.Outbox)){$record=Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId','StoreId','Terminal')+$script:PdvEventFields);foreach($field in @('AgentId','StoreId','Terminal')){if($record[$field] -cne $NewCentral[$field]){return $true}}}
  foreach($path in @($Paths.Hardware,$Paths.Software)){if([IO.File]::Exists($path)){if($path -ceq $Paths.Hardware){$record=Read-PdvHardwarePending $path}else{$record=Read-PdvSoftwarePending $path};foreach($field in @('AgentId','StoreId','Terminal')){if($record[$field] -cne $NewCentral[$field]){return $true}}}}
  return $false
}
function Invoke-PdvCentralIdentitySwitch {
  param($Session,$NewCentral,[string]$Token)
  $paths=Get-PdvTransportPaths $Session
  $protected=Protect-PdvMonitorToken $Token $NewCentral
  $configBytes=New-PdvTransportXmlBytes 'PdvMonitorCentral' @{Enabled='true';Endpoint=$NewCentral.Endpoint;StoreId=$NewCentral.StoreId;Terminal=$NewCentral.Terminal;AgentId=$NewCentral.AgentId}
  $locations=Get-PdvIdentitySwitchLocations $Session ([Guid]::NewGuid().ToString('D'))
  $journal=@{ArchiveId=[IO.Path]::GetFileName($locations.Archive);TargetEndpoint=$NewCentral.Endpoint;TargetStoreId=$NewCentral.StoreId;TargetTerminal=$NewCentral.Terminal;TargetAgentId=$NewCentral.AgentId;TargetConfigSha256=(Get-PdvIdentitySwitchHash $configBytes);TargetCredentialSha256=(Get-PdvIdentitySwitchHash $protected);PreviousConfigSha256=(Get-PdvIdentitySwitchFileHash $paths.Config);PreviousCredentialSha256=(Get-PdvIdentitySwitchFileHash $paths.Credential)}
  foreach($item in @(Get-PdvIdentitySwitchItems $paths)){if($item.Directory){$journal[$item.Field]=Get-PdvIdentitySwitchTreeHash $item.Source}else{$journal[$item.Field]=Get-PdvIdentitySwitchFileHash $item.Source}}
  [void][IO.Directory]::CreateDirectory($locations.Parent)
  if([IO.Directory]::Exists($locations.Archive) -or [IO.File]::Exists($locations.Archive)){throw 'IdentitySwitchArchiveCollision'}
  [void][IO.Directory]::CreateDirectory($locations.Archive)
  foreach($pair in @(@{Source=$paths.Config;Name='central.xml';Hash=$journal.PreviousConfigSha256},@{Source=$paths.Credential;Name='central-credencial.bin';Hash=$journal.PreviousCredentialSha256})){
    if($pair.Hash){Write-PdvIdentitySwitchDurableBytes (Join-Path $locations.Archive $pair.Name) ([IO.File]::ReadAllBytes($pair.Source));if((Get-PdvIdentitySwitchFileHash (Join-Path $locations.Archive $pair.Name)) -cne $pair.Hash){throw 'IdentitySwitchSnapshotCollision'}}
  }
  Write-PdvIdentitySwitchDurableBytes $locations.Journal (New-PdvTransportXmlBytes 'PdvMonitorIdentitySwitch' $journal)
  Set-PdvTransportValue $Session 'IdentitySwitchBlocked' $true
  try{
    foreach($item in @(Get-PdvIdentitySwitchItems $paths)){if($journal[$item.Field]){Move-PdvIdentitySwitchEntry $item.Source (Join-Path $locations.Archive $item.Name) $item.Directory}}
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    $script:PdvIdentitySwitchContext=@{Session=$Session;Protected=$protected}
    try{$result=Set-PdvMonitorCentralConfig -Session $Session -Endpoint $NewCentral.Endpoint -StoreId $NewCentral.StoreId -Terminal $NewCentral.Terminal -AgentId $NewCentral.AgentId -Token $Token}finally{$script:PdvIdentitySwitchContext=$null}
    if(-not $result.Success){throw 'IdentitySwitchConfigurationFailed'}
    $recovered=Recover-PdvIdentitySwitch $Session
    if(-not $recovered.Committed){throw 'IdentitySwitchCommitUnconfirmed'}
    return (New-PdvIdentitySwitchSuccess $Session $locations.Archive)
  }catch{
    $script:PdvIdentitySwitchContext=$null
    try{
      $recovered=Recover-PdvIdentitySwitch $Session
      $completed=Join-Path $locations.Archive 'identity-switch.xml'
      if($recovered.Committed -or ((Get-PdvIdentitySwitchFileHash $paths.Config) -ceq $journal.TargetConfigSha256 -and (Get-PdvIdentitySwitchFileHash $paths.Credential) -ceq $journal.TargetCredentialSha256 -and (Get-PdvIdentitySwitchFileHash $completed) -ceq (Get-PdvIdentitySwitchHash (New-PdvTransportXmlBytes 'PdvMonitorIdentitySwitch' $journal)))){return (New-PdvIdentitySwitchSuccess $Session $locations.Archive)}
      Read-PdvCentralSessionConfig $Session $paths;return (New-PdvTransportResult $false 'IdentityArchiveRolledBack')
    }
    catch{Set-PdvTransportValue $Session 'IdentitySwitchBlocked' $true;Set-PdvTransportValue (Get-PdvCentralConfig $Session) 'Enabled' $false;return (New-PdvTransportResult $false 'IdentitySwitchRecoveryRequired')}
  }finally{$Token=$null;$protected=$null}
}

function Read-PdvCentralSessionConfig {
  param($Session,$Paths)
  [void](Get-PdvCentralConfig $Session)
  if([IO.File]::Exists($Paths.Config)){
    $values=Read-PdvTransportXml $Paths.Config 'PdvMonitorCentral' @('Enabled','Endpoint','StoreId','Terminal','AgentId')
    if(-not (Test-PdvCentralIdentity $values.Endpoint $values.StoreId $values.Terminal $values.AgentId) -or @('true','false') -notcontains $values.Enabled){throw 'InvalidCentralConfig'}
    $values.Enabled=($values.Enabled -eq 'true');Set-PdvTransportValue (Get-PdvTransportValue $Session 'Config') 'Central' $values
  }
}

function Initialize-PdvMonitorCentral {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session)
  try {
    $paths = Get-PdvTransportPaths $Session
    [void][IO.Directory]::CreateDirectory($paths.Directory)
    $identityRecovery=Recover-PdvIdentitySwitch $Session
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    Read-PdvCentralSessionConfig $Session $paths
    # A recuperacao restaura os bytes originais antes de retomar a coleta.
    # Nao drenar rotina durante a propria recuperacao de uma troca interrompida.
    if(-not $identityRecovery.Recovered){Remove-PdvMonitorRoutineOutbox $Session $paths (Get-PdvCentralConfig $Session)}
    Set-PdvInventoryStartupWindow $Session
    Set-PdvTransportValue $Session 'NextUploadAt' ([DateTimeOffset]::MinValue)
    Set-PdvTransportValue $Session 'UploadFailureCount' 0
    Set-PdvTransportValue $Session 'UploadStatusText' 'Central pronta; nenhum envio confirmado nesta sessão.'
    return (New-PdvTransportResult $true 'Initialized')
  } catch {
    Set-PdvTransportValue (Get-PdvCentralConfig $Session) 'Enabled' $false
    Set-PdvTransportValue $Session 'UploadStatusText' 'Configuração central indisponível. A coleta local continua; procurar o suporte.'
    return (New-PdvTransportResult $false 'InitializationFailed')
  }
}

function Set-PdvMonitorCentralConfig {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session, [string]$Endpoint, [string]$StoreId, [string]$Terminal, [string]$AgentId, [string]$Token, [switch]$ArchivePreviousIdentity)
  if (-not (Test-PdvCentralIdentity $Endpoint $StoreId $Terminal $AgentId) -or $Token -notmatch '^[a-fA-F0-9]{64}$') {
    Set-PdvTransportValue $Session 'UploadStatusText' 'Configuração central inválida: conferir HTTPS, loja, terminal, agente e credencial.'
    return (New-PdvTransportResult $false 'InvalidConfiguration')
  }
  try {
    $paths = Get-PdvTransportPaths $Session
    [void][IO.Directory]::CreateDirectory($paths.Directory)
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    if(-not (Test-PdvIdentitySwitchInternal $Session)){[void](Recover-PdvIdentitySwitch $Session)}
    $newCentral = @{Enabled=$true; Endpoint=$Endpoint; StoreId=$StoreId; Terminal=$Terminal; AgentId=$AgentId.ToLowerInvariant()}
    if($ArchivePreviousIdentity -and (Test-PdvCentralIdentityNeedsArchive $Session $newCentral $paths)){return (Invoke-PdvCentralIdentitySwitch $Session $newCentral $Token)}
    foreach ($file in @(Get-PdvOutboxFiles $paths.Outbox)) {
      $old = Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId', 'StoreId', 'Terminal') + $script:PdvEventFields)
      if ($old.AgentId -ne $newCentral.AgentId -or $old.StoreId -cne $StoreId -or $old.Terminal -cne $Terminal) {
        Set-PdvTransportValue $Session 'UploadStatusText' 'Há eventos pendentes de outra identificação. Envie a fila antes de trocar agente, loja ou terminal.'
        return (New-PdvTransportResult $false 'PendingIdentityChange')
      }
    }
    if ([IO.File]::Exists($paths.Hardware)) {
      $pendingHardware=Read-PdvHardwarePending $paths.Hardware
      if ($pendingHardware.AgentId -ne $newCentral.AgentId -or $pendingHardware.StoreId -cne $StoreId -or $pendingHardware.Terminal -cne $Terminal) {
        Set-PdvTransportValue $Session 'UploadStatusText' 'Há inventário pendente de outra identificação. Envie a fila antes de trocar agente, loja ou terminal.'
        return (New-PdvTransportResult $false 'PendingIdentityChange')
      }
    }
    if([IO.File]::Exists($paths.Software)){
      $pendingSoftware=Read-PdvSoftwarePending $paths.Software
      if($pendingSoftware.AgentId -ne $newCentral.AgentId -or $pendingSoftware.StoreId -cne $StoreId -or $pendingSoftware.Terminal -cne $Terminal){return (New-PdvTransportResult $false 'PendingIdentityChange')}
    }
    if(Test-PdvIdentitySwitchInternal $Session){$protected=$script:PdvIdentitySwitchContext.Protected}else{$protected = Protect-PdvMonitorToken $Token $newCentral}
    $configValues = @{Enabled='true'; Endpoint=$Endpoint; StoreId=$StoreId; Terminal=$Terminal; AgentId=$newCentral.AgentId}
    $configBytes = New-PdvTransportXmlBytes 'PdvMonitorCentral' $configValues
    $previousCredential = $null
    if ([IO.File]::Exists($paths.Credential)) { $previousCredential = [IO.File]::ReadAllBytes($paths.Credential) }
    Write-PdvTransportAtomicBytes $paths.Credential $protected
    try { Write-PdvTransportAtomicBytes $paths.Config $configBytes }
    catch {
      if ($null -ne $previousCredential) { Write-PdvTransportAtomicBytes $paths.Credential $previousCredential }
      elseif ([IO.File]::Exists($paths.Credential)) { [IO.File]::Delete($paths.Credential) }
      throw
    }
    Set-PdvTransportValue (Get-PdvTransportValue $Session 'Config') 'Central' $newCentral
    Set-PdvInventoryStartupWindow $Session
    # O checkpoint patrimonial pertence ao destino/agente. Revalidar em disco
    # mesmo quando esta funcao e chamada sem o wrapper do runtime.
    Set-PdvTransportValue $Session 'HardwareQueueChecked' $false
    Set-PdvTransportValue $Session 'SoftwareQueueChecked' $false
    Set-PdvTransportValue $Session 'LastHardwareAt' $null
    Set-PdvTransportValue $Session 'LastSoftwareAt' $null
    Set-PdvTransportValue $Session 'NextUploadAt' ([DateTimeOffset]::MinValue)
    Set-PdvTransportValue $Session 'UploadFailureCount' 0
    Set-PdvTransportValue $Session 'NextSoftwareUploadAt' ([DateTimeOffset]::MinValue)
    Set-PdvTransportValue $Session 'SoftwareUploadFailures' 0
    Set-PdvTransportValue $Session 'HardwareCompatibilityRetryAt' ([DateTimeOffset]::MinValue)
    Set-PdvTransportValue $Session 'UploadStatusText' 'Central configurada. Credencial protegida para este usuário do Windows; aguardando envio.'
    return (New-PdvTransportResult $true 'Configured')
  } catch {
    Set-PdvTransportValue $Session 'UploadStatusText' 'Não foi possível salvar a configuração ou proteger a credencial. A coleta local continua.'
    return (New-PdvTransportResult $false 'ConfigurationFailed')
  } finally { $Token = $null }
}

function Add-PdvMonitorOutboxRecord {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session, [Parameter(Mandatory=$true)]$Record)
  if(Test-PdvIdentitySwitchBlocked $Session){return (New-PdvTransportResult $false 'IdentitySwitchPending')}
  $central = Get-PdvCentralConfig $Session
  $enabled = Get-PdvTransportValue $central 'Enabled'
  if ($enabled -isnot [bool] -or -not $enabled) { return (New-PdvTransportResult $false 'CentralDisabled') }
  if (-not (Test-PdvMonitorCentralEvent $Record)) { return (New-PdvTransportResult $true 'LocalOnly') }
  try {
    if (-not (Test-PdvCentralIdentity ([string](Get-PdvTransportValue $central 'Endpoint')) ([string](Get-PdvTransportValue $central 'StoreId')) ([string](Get-PdvTransportValue $central 'Terminal')) ([string](Get-PdvTransportValue $central 'AgentId'))) -or -not (Test-PdvOutboxRecord $Record)) { throw 'InvalidRecord' }
    $paths = Get-PdvTransportPaths $Session
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    $values = @{AgentId=[string](Get-PdvTransportValue $central 'AgentId'); StoreId=[string](Get-PdvTransportValue $central 'StoreId'); Terminal=[string](Get-PdvTransportValue $central 'Terminal')}
    foreach ($field in $script:PdvEventFields) { $values[$field] = [string](Get-PdvTransportValue $Record $field) }
    $xml = New-PdvTransportXmlBytes 'PdvMonitorOutbox' $values
    $json = New-PdvEnvelopeJson $central @((ConvertTo-PdvEventJson $Record)) ([Guid]::NewGuid().ToString('D'))
    if ($xml.Length -gt $script:PdvBatchMaxBytes -or [Text.Encoding]::UTF8.GetByteCount($json) -gt $script:PdvBatchMaxBytes) {
      Set-PdvTransportValue $Session 'UploadStatusText' 'Evento excede o limite de transporte. Registro local preservado; existe lacuna na fila central.'
      return (New-PdvTransportResult $false 'RecordTooLarge')
    }
    $target = Join-Path $paths.Outbox ($values.EventId.ToLowerInvariant() + '.xml')
    if ([IO.File]::Exists($target)) {
      $existing = Read-PdvTransportXml $target 'PdvMonitorOutbox' (@('AgentId', 'StoreId', 'Terminal') + $script:PdvEventFields)
      foreach ($field in $values.Keys) { if ($existing[$field] -cne $values[$field]) { throw 'EventIdCollision' } }
      return (New-PdvTransportResult $true 'AlreadyQueued' $true)
    }
    $files = @(Get-PdvOutboxFiles $paths.Outbox)
    $totalBytes = 0L
    foreach ($file in $files) { $totalBytes += $file.Length }
    if ($files.Count -ge $script:PdvOutboxMaxRecords -or ($totalBytes + $xml.Length) -gt $script:PdvOutboxMaxBytes) {
      Set-PdvTransportValue $Session 'UploadStatusText' 'Fila central cheia. Nenhum evento pendente foi descartado; novos eventos continuam somente no registro local.'
      return (New-PdvTransportResult $false 'OutboxQuotaExceeded')
    }
    Write-PdvTransportAtomicBytes $target $xml
    return (New-PdvTransportResult $true 'Queued' $true)
  } catch {
    Set-PdvTransportValue $Session 'UploadStatusText' 'Falha ao enfileirar evento central. Registros locais preservados; procurar o suporte para a lacuna.'
    return (New-PdvTransportResult $false 'QueueWriteFailed')
  }
}

function Invoke-PdvMonitorHttpPost {
  param([string]$Endpoint, [string]$Authorization, [byte[]]$Body)
  $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
  $tlsLock=[Net.ServicePointManager];$ownsTls=$false
  $response = $null
  $stream = $null
  try {
    $ownsTls=[Threading.Monitor]::TryEnter($tlsLock,2000);if(-not $ownsTls){throw 'TransportUnavailable'}
    $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
    # Em .NET antigo a atribuição pode falhar. Isso bloqueia apenas o envio;
    # nunca habilitar TLS obsoleto ou ignorar validação do certificado.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072
    $request = [Net.WebRequest]::Create($Endpoint)
    $request.Method = 'POST'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.UseDefaultCredentials = $false
    $request.Headers['Authorization'] = $Authorization
    $request.ContentLength = $Body.Length
    $stream = $request.GetRequestStream()
    $stream.Write($Body, 0, $Body.Length)
    $stream.Close(); $stream = $null
    $response = $request.GetResponse()
    return [int]$response.StatusCode
  } catch [Net.WebException] {
    if ($null -ne $_.Exception.Response) { $response = $_.Exception.Response; return [int]$response.StatusCode }
    throw 'TransportUnavailable'
  } finally {
    try {
      if ($null -ne $stream) { $stream.Close() }
      if ($null -ne $response) { $response.Close() }
    } finally {
      if($ownsTls){try{[Net.ServicePointManager]::SecurityProtocol = $previousProtocol}finally{[Threading.Monitor]::Exit($tlsLock)}}
      $Authorization = $null
    }
  }
}

function Set-PdvUploadBackoff {
  param($Session, [DateTimeOffset]$Now, [bool]$CredentialError = $false)
  $failureCount = 0
  [void][int]::TryParse([string](Get-PdvTransportValue $Session 'UploadFailureCount' 0), [ref]$failureCount)
  $failureCount = [Math]::Min(20, [Math]::Max(0, $failureCount) + 1)
  $seconds = [Math]::Min(900, 30 * [Math]::Pow(2, $failureCount - 1))
  if ($CredentialError) { $seconds = 900 }
  Set-PdvTransportValue $Session 'UploadFailureCount' $failureCount
  Set-PdvTransportValue $Session 'NextUploadAt' $Now.AddSeconds($seconds)
}

function Invoke-PdvMonitorUpload {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session)
  if(Test-PdvIdentitySwitchBlocked $Session){return (New-PdvTransportResult $false 'IdentitySwitchPending')}
  $central = Get-PdvCentralConfig $Session
  $enabled = Get-PdvTransportValue $central 'Enabled'
  if ($enabled -isnot [bool] -or -not $enabled) { return (New-PdvTransportResult $false 'CentralDisabled') }
  $now = Get-PdvMonitorTransportNow
  $next = Get-PdvTransportValue $Session 'NextUploadAt'
  if ($next -is [DateTimeOffset] -and $next -gt $now) { return (New-PdvTransportResult $false 'BackoffActive') }
  $token = $null
  try {
    $paths = Get-PdvTransportPaths $Session
    if (-not (Test-PdvCentralIdentity ([string](Get-PdvTransportValue $central 'Endpoint')) ([string](Get-PdvTransportValue $central 'StoreId')) ([string](Get-PdvTransportValue $central 'Terminal')) ([string](Get-PdvTransportValue $central 'AgentId')))) { throw 'InvalidConfiguration' }
    $files = @(Get-PdvOutboxFiles $paths.Outbox | Sort-Object LastWriteTimeUtc, Name)
    $hardwarePending=$null; $hardwareJson=''; $hardwareFingerprint=''
    $hardwareRetryAt=Get-PdvTransportValue $Session 'HardwareCompatibilityRetryAt'
    $initialAt=Get-PdvTransportValue $Session 'HardwareInitialUploadAt' $null
    $baselineDeferred=(-not [IO.File]::Exists($paths.HardwareAck) -and $initialAt -is [DateTimeOffset] -and $initialAt -gt $now)
    if ([IO.File]::Exists($paths.Hardware) -and -not $baselineDeferred -and -not ($hardwareRetryAt -is [DateTimeOffset] -and $hardwareRetryAt -gt $now)) {
      $hardwarePending=Read-PdvHardwarePending $paths.Hardware
      if ($hardwarePending.AgentId -ne [string](Get-PdvTransportValue $central 'AgentId') -or $hardwarePending.StoreId -cne [string](Get-PdvTransportValue $central 'StoreId') -or $hardwarePending.Terminal -cne [string](Get-PdvTransportValue $central 'Terminal')) {
        Set-PdvUploadBackoff $Session $now $true
        return (New-PdvTransportResult $false 'OutboxIdentityMismatch')
      }
      $hardwareJson=$hardwarePending.HardwareJson; $hardwareFingerprint=$hardwarePending.Fingerprint
    }
    if ($files.Count -eq 0 -and -not $hardwareJson) {
      Set-PdvTransportValue $Session 'UploadStatusText' 'Fila central vazia; nenhum envio necessário nesta leitura.'
      return (New-PdvTransportResult $true 'OutboxEmpty')
    }
    try {
      if (-not [IO.File]::Exists($paths.Credential)) { throw 'CredentialMissing' }
      $token = Unprotect-PdvMonitorToken ([IO.File]::ReadAllBytes($paths.Credential)) $central
      if ($token -notmatch '^[a-fA-F0-9]{64}$') { throw 'CredentialInvalid' }
    } catch {
      Set-PdvUploadBackoff $Session $now $true
      Set-PdvTransportValue $Session 'UploadStatusText' 'Credencial central indisponível para este usuário. Coleta local continua; nova tentativa em até 15 minutos.'
      return (New-PdvTransportResult $false 'CredentialUnavailable')
    }
    $batchId = [Guid]::NewGuid().ToString('D')
    $jsonEvents = New-Object 'Collections.Generic.List[string]'
    $selected = New-Object 'Collections.Generic.List[string]'
    $body = [Text.Encoding]::UTF8.GetBytes((New-PdvEnvelopeJson $central @() $batchId $hardwareJson))
    foreach ($file in $files) {
      if ($selected.Count -ge 50) { break }
      $record = Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId', 'StoreId', 'Terminal') + $script:PdvEventFields)
      if ($record.AgentId -ne [string](Get-PdvTransportValue $central 'AgentId') -or $record.StoreId -cne [string](Get-PdvTransportValue $central 'StoreId') -or $record.Terminal -cne [string](Get-PdvTransportValue $central 'Terminal')) {
        Set-PdvUploadBackoff $Session $now $true
        Set-PdvTransportValue $Session 'UploadStatusText' 'Fila contém eventos de outra loja, terminal ou agente. Envio bloqueado para preservar a identificação original.'
        return (New-PdvTransportResult $false 'OutboxIdentityMismatch')
      }
      if (-not (Test-PdvOutboxRecord $record)) { throw 'InvalidQueuedRecord' }
      # Drena somente rotina de versões anteriores, já registrada no CSV local.
      # Incidentes nunca expiram por idade nem são removidos por rotação.
      if (-not (Test-PdvMonitorCentralEvent $record)) { if(Test-PdvMonitorLocalRoutine $record){[IO.File]::Delete($file.FullName)}; continue }
      $candidateJson = ConvertTo-PdvEventJson $record
      $candidates = @($jsonEvents.ToArray()) + @($candidateJson)
      $candidateBody = [Text.Encoding]::UTF8.GetBytes((New-PdvEnvelopeJson $central $candidates $batchId $hardwareJson))
      if ($candidateBody.Length -gt $script:PdvBatchMaxBytes) {
        if ($selected.Count -eq 0) { throw 'QueuedRecordTooLarge' }
        break
      }
      $jsonEvents.Add($candidateJson)
      $selected.Add($file.FullName)
      $body = $candidateBody
    }
    if ($selected.Count -eq 0 -and -not $hardwareJson) { return (New-PdvTransportResult $true 'OutboxEmpty') }
    $authorization = 'Bearer ' + [string](Get-PdvTransportValue $central 'AgentId') + '.' + $token
    $statusCode = Invoke-PdvMonitorHttpPost ([string](Get-PdvTransportValue $central 'Endpoint')) $authorization $body
    if($statusCode -eq 400 -and $hardwarePending){
      # Uma API anterior pode aceitar os eventos e rejeitar o novo documento
      # patrimonial. O segundo envio contém apenas eventos; nunca confirma
      # nem apaga o hardware que não foi aceito.
      Set-PdvTransportValue $Session 'HardwareCompatibilityRetryAt' $now.AddMinutes(15)
      if($selected.Count -gt 0){
        $eventBody=[Text.Encoding]::UTF8.GetBytes((New-PdvEnvelopeJson $central @($jsonEvents.ToArray()) $batchId))
        $statusCode=Invoke-PdvMonitorHttpPost ([string](Get-PdvTransportValue $central 'Endpoint')) $authorization $eventBody
        $hardwarePending=$null;$hardwareJson='';$hardwareFingerprint=''
      }
    }
    $authorization = $null
    if ($statusCode -ne 204) {
      Set-PdvUploadBackoff $Session $now ($statusCode -eq 401 -or $statusCode -eq 403)
      Set-PdvTransportValue $Session 'UploadStatusText' ('Central não confirmou o lote (HTTP ' + [string]$statusCode + '). Todos os eventos permanecem na fila para nova tentativa.')
      return (New-PdvTransportResult $false ('Http' + [string]$statusCode))
    }
    $deleteFailed = $false
    if ($hardwarePending -and [IO.File]::Exists($paths.Hardware)) {
      Set-PdvTransportValue $Session 'HardwareCompatibilityRetryAt' ([DateTimeOffset]::MinValue)
      # O ACK pertence ao conteúdo exato enviado. Não remover um inventário
      # mais recente caso tenha sido gravado enquanto a chamada estava em voo.
      try {
        $currentHardware=Read-PdvHardwarePending $paths.Hardware
        if ($currentHardware.Fingerprint -ceq $hardwareFingerprint -and $currentHardware.HardwareJson -ceq $hardwareJson) { Save-PdvInventoryAcknowledged $central $paths.HardwareAck $hardwareFingerprint; [IO.File]::Delete($paths.Hardware) }
      } catch { $deleteFailed=$true }
    }
    foreach ($path in $selected) { try { [IO.File]::Delete($path) } catch { $deleteFailed = $true } }
    Set-PdvTransportValue $Session 'UploadFailureCount' 0
    Set-PdvTransportValue $Session 'NextUploadAt' $now.AddSeconds(5)
    $text = 'Central confirmou ' + [string]$selected.Count + ' eventos.'
    if ($hardwarePending) { $text += ' Inventário da máquina confirmado.' }
    if ($deleteFailed) { $text += ' Limpeza local pendente; reenvio mantém os mesmos identificadores para evitar duplicação.' }
    Set-PdvTransportValue $Session 'UploadStatusText' $text
    return (New-PdvTransportResult $true 'Acknowledged' $false $selected.Count)
  } catch {
    Set-PdvUploadBackoff $Session $now
    Set-PdvTransportValue $Session 'UploadStatusText' 'Envio central indisponível ou fila inválida. Nenhum evento pendente foi descartado; coleta local continua.'
    return (New-PdvTransportResult $false 'UploadFailed')
  } finally { $token = $null; $authorization = $null }
}

Export-ModuleMember -Function Test-PdvMonitorCentralEvent, Initialize-PdvMonitorCentral, Set-PdvMonitorCentralConfig, Add-PdvMonitorOutboxRecord, Invoke-PdvMonitorUpload, Set-PdvMonitorHardwarePending, Set-PdvMonitorSoftwarePending, Invoke-PdvMonitorSoftwareUpload
