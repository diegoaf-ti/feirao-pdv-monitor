# Transporte opcional. Sintaxe Windows PowerShell 2.0; sem módulos externos.
# Token nunca integra eventos, XML de configuração, retornos ou mensagens.
Set-StrictMode -Version 2.0
$script:PdvEventFields = @('EventId', 'Timestamp', 'SessionId', 'Sequence', 'Kind', 'Role', 'InstanceId', 'DeviceName', 'Port', 'Present', 'PresenceKnown', 'Status', 'ProblemCode', 'Reason', 'Detail', 'WindowsChannel', 'RecordId', 'Provider', 'WindowsEventId')
$script:PdvOutboxMaxBytes = 104857600
$script:PdvOutboxMaxRecords = 20000
$script:PdvBatchMaxBytes = 262144

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
  return (New-Object PSObject -Property @{Directory=$directory; Outbox=$outbox; Config=(Join-Path $directory 'central.xml'); Credential=(Join-Path $directory 'central-credencial.bin')})
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
  param($Central, [string[]]$EventJson, [string]$BatchId)
  return '{"schemaVersion":1,"agentId":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'AgentId'))) + ',"storeId":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'StoreId'))) + ',"terminal":' + (ConvertTo-PdvJsonString ([string](Get-PdvTransportValue $Central 'Terminal'))) + ',"batchId":' + (ConvertTo-PdvJsonString $BatchId) + ',"events":[' + [string]::Join(',', $EventJson) + ']}'
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
    [IO.File]::WriteAllBytes($temporary, $Bytes)
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

function Initialize-PdvMonitorCentral {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Session)
  try {
    $paths = Get-PdvTransportPaths $Session
    [void][IO.Directory]::CreateDirectory($paths.Directory)
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    [void](Get-PdvCentralConfig $Session)
    if ([IO.File]::Exists($paths.Config)) {
      $values = Read-PdvTransportXml $paths.Config 'PdvMonitorCentral' @('Enabled', 'Endpoint', 'StoreId', 'Terminal', 'AgentId')
      if (-not (Test-PdvCentralIdentity $values.Endpoint $values.StoreId $values.Terminal $values.AgentId) -or @('true', 'false') -notcontains $values.Enabled) { throw 'InvalidCentralConfig' }
      $values.Enabled = ($values.Enabled -eq 'true')
      Set-PdvTransportValue (Get-PdvTransportValue $Session 'Config') 'Central' $values
    }
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
  param([Parameter(Mandatory=$true)]$Session, [string]$Endpoint, [string]$StoreId, [string]$Terminal, [string]$AgentId, [string]$Token)
  if (-not (Test-PdvCentralIdentity $Endpoint $StoreId $Terminal $AgentId) -or $Token -notmatch '^[a-fA-F0-9]{64}$') {
    Set-PdvTransportValue $Session 'UploadStatusText' 'Configuração central inválida: conferir HTTPS, loja, terminal, agente e credencial.'
    return (New-PdvTransportResult $false 'InvalidConfiguration')
  }
  try {
    $paths = Get-PdvTransportPaths $Session
    [void][IO.Directory]::CreateDirectory($paths.Directory)
    [void][IO.Directory]::CreateDirectory($paths.Outbox)
    $newCentral = @{Enabled=$true; Endpoint=$Endpoint; StoreId=$StoreId; Terminal=$Terminal; AgentId=$AgentId.ToLowerInvariant()}
    foreach ($file in @(Get-PdvOutboxFiles $paths.Outbox)) {
      $old = Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId', 'StoreId', 'Terminal') + $script:PdvEventFields)
      if ($old.AgentId -ne $newCentral.AgentId -or $old.StoreId -cne $StoreId -or $old.Terminal -cne $Terminal) {
        Set-PdvTransportValue $Session 'UploadStatusText' 'Há eventos pendentes de outra identificação. Envie a fila antes de trocar agente, loja ou terminal.'
        return (New-PdvTransportResult $false 'PendingIdentityChange')
      }
    }
    $protected = Protect-PdvMonitorToken $Token $newCentral
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
    Set-PdvTransportValue $Session 'NextUploadAt' ([DateTimeOffset]::MinValue)
    Set-PdvTransportValue $Session 'UploadFailureCount' 0
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
  $central = Get-PdvCentralConfig $Session
  $enabled = Get-PdvTransportValue $central 'Enabled'
  if ($enabled -isnot [bool] -or -not $enabled) { return (New-PdvTransportResult $false 'CentralDisabled') }
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
  $response = $null
  $stream = $null
  try {
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
    if ($null -ne $stream) { $stream.Close() }
    if ($null -ne $response) { $response.Close() }
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    $Authorization = $null
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
    if ($files.Count -eq 0) {
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
    $body = $null
    foreach ($file in $files) {
      if ($selected.Count -ge 50) { break }
      $record = Read-PdvTransportXml $file.FullName 'PdvMonitorOutbox' (@('AgentId', 'StoreId', 'Terminal') + $script:PdvEventFields)
      if ($record.AgentId -ne [string](Get-PdvTransportValue $central 'AgentId') -or $record.StoreId -cne [string](Get-PdvTransportValue $central 'StoreId') -or $record.Terminal -cne [string](Get-PdvTransportValue $central 'Terminal')) {
        Set-PdvUploadBackoff $Session $now $true
        Set-PdvTransportValue $Session 'UploadStatusText' 'Fila contém eventos de outra loja, terminal ou agente. Envio bloqueado para preservar a identificação original.'
        return (New-PdvTransportResult $false 'OutboxIdentityMismatch')
      }
      if (-not (Test-PdvOutboxRecord $record)) { throw 'InvalidQueuedRecord' }
      $candidateJson = ConvertTo-PdvEventJson $record
      $candidates = @($jsonEvents.ToArray()) + @($candidateJson)
      $candidateBody = [Text.Encoding]::UTF8.GetBytes((New-PdvEnvelopeJson $central $candidates $batchId))
      if ($candidateBody.Length -gt $script:PdvBatchMaxBytes) {
        if ($selected.Count -eq 0) { throw 'QueuedRecordTooLarge' }
        break
      }
      $jsonEvents.Add($candidateJson)
      $selected.Add($file.FullName)
      $body = $candidateBody
    }
    $authorization = 'Bearer ' + [string](Get-PdvTransportValue $central 'AgentId') + '.' + $token
    $statusCode = Invoke-PdvMonitorHttpPost ([string](Get-PdvTransportValue $central 'Endpoint')) $authorization $body
    $authorization = $null
    if ($statusCode -ne 204) {
      Set-PdvUploadBackoff $Session $now ($statusCode -eq 401 -or $statusCode -eq 403)
      Set-PdvTransportValue $Session 'UploadStatusText' ('Central não confirmou o lote (HTTP ' + [string]$statusCode + '). Todos os eventos permanecem na fila para nova tentativa.')
      return (New-PdvTransportResult $false ('Http' + [string]$statusCode))
    }
    $deleteFailed = $false
    foreach ($path in $selected) { try { [IO.File]::Delete($path) } catch { $deleteFailed = $true } }
    Set-PdvTransportValue $Session 'UploadFailureCount' 0
    Set-PdvTransportValue $Session 'NextUploadAt' $now.AddSeconds(5)
    $text = 'Central confirmou ' + [string]$selected.Count + ' eventos.'
    if ($deleteFailed) { $text += ' Limpeza local pendente; reenvio mantém os mesmos identificadores para evitar duplicação.' }
    Set-PdvTransportValue $Session 'UploadStatusText' $text
    return (New-PdvTransportResult $true 'Acknowledged' $false $selected.Count)
  } catch {
    Set-PdvUploadBackoff $Session $now
    Set-PdvTransportValue $Session 'UploadStatusText' 'Envio central indisponível ou fila inválida. Nenhum evento pendente foi descartado; coleta local continua.'
    return (New-PdvTransportResult $false 'UploadFailed')
  } finally { $token = $null; $authorization = $null }
}

Export-ModuleMember -Function Initialize-PdvMonitorCentral, Set-PdvMonitorCentralConfig, Add-PdvMonitorOutboxRecord, Invoke-PdvMonitorUpload
