# Testes offline. Credencial de teste fictícia; rede e DPAPI substituídos.
# Sintaxe PS2; a execução em Windows 7/PowerShell 2 ainda requer validação real.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$moduleDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDirectory 'PdvMonitor.Transporte.psm1') -Force
$module = Get-Module PdvMonitor.Transporte
$script:assertions = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdv-transporte-testes-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

& $module {
  $script:TestToken = 'a' * 64
  $script:TestNow = [DateTimeOffset]::Parse('2026-10-15T12:00:00-03:00')
  $script:TestStatus = 204
  $script:TestTimeout = $false
  $script:TestHardwareUnsupported = $false
  $script:TestCredentialFailure = $false
  $script:TestAfterPost=$null
  $script:TestPosts = New-Object 'Collections.Generic.List[object]'
  function script:Get-PdvMonitorTransportNow { return $script:TestNow }
  function script:Protect-PdvMonitorToken { param($Token, $Central); return ,[byte[]]@(7, 18, 29, 40) }
  function script:Unprotect-PdvMonitorToken { param($Bytes, $Central); if ($script:TestCredentialFailure) { throw 'Falha DPAPI simulada' }; return $script:TestToken }
  function script:Invoke-PdvMonitorHttpPost {
    param($Endpoint, $Authorization, $Body)
    $expected = 'Bearer ' + ($script:TestExpectedAgentId) + '.' + $script:TestToken
    if ($Authorization -cne $expected) { throw 'Cabeçalho de autenticação incorreto.' }
    $script:TestPosts.Add((New-Object PSObject -Property @{Endpoint=$Endpoint; Json=[Text.Encoding]::UTF8.GetString($Body); Bytes=$Body.Length}))
    if ($null -ne $script:TestAfterPost) { $hook=$script:TestAfterPost; $script:TestAfterPost=$null; & $hook }
    if ($script:TestTimeout) { throw 'Tempo de conexão simulado excedido' }
    if($script:TestHardwareUnsupported -and ([Text.Encoding]::UTF8.GetString($Body)).Contains('"hardware":')){return 400}
    return $script:TestStatus
  }
}

function Assert-Transport {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw $Name }
  $script:assertions++
}

function ConvertFrom-TestJson {
  param([string]$Json)
  if ($null -ne (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue)) { return (ConvertFrom-Json -InputObject $Json) }
  # Windows 7/PS2 inclui .NET 3.5; o teste não exige o cmdlet PS3.
  Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $serializer.MaxJsonLength = 1048576
  return $serializer.DeserializeObject($Json)
}

function New-TestSession {
  $session = New-Object PSObject -Property @{DataDirectory=(Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))); Id=[Guid]::NewGuid().ToString('D'); Config=@{} }
  $initialized = Initialize-PdvMonitorCentral $session
  Assert-Transport $initialized.Success 'Inicializa sessão sem credencial real'
  $agentId = [Guid]::NewGuid().ToString('D')
  $configured = Set-PdvMonitorCentralConfig -Session $session -Endpoint 'https://conecta.example/api/pdv-monitor/ingest' -StoreId '49' -Terminal 'CX4901' -AgentId $agentId -Token ('a' * 64)
  Assert-Transport $configured.Success ('Configura sessão offline: ' + $configured.Reason)
  & $module { param($ExpectedAgentId); $script:TestExpectedAgentId=$ExpectedAgentId; $script:TestStatus=204; $script:TestTimeout=$false; $script:TestHardwareUnsupported=$false; $script:TestCredentialFailure=$false; $script:TestPosts.Clear(); $script:TestAfterPost=$null } $agentId
  return $session
}

function New-TestRecord {
  param($Session, [int]$Sequence = 1)
  $record = @{}
  foreach ($field in @('EventId', 'Timestamp', 'SessionId', 'Sequence', 'Kind', 'Role', 'InstanceId', 'DeviceName', 'Port', 'Present', 'PresenceKnown', 'Status', 'ProblemCode', 'Reason', 'Detail', 'WindowsChannel', 'RecordId', 'Provider', 'WindowsEventId')) { $record[$field] = '' }
  $record.EventId = [Guid]::NewGuid().ToString('D')
  $record.SessionId = $Session.Id
  $record.Timestamp = '2026-10-15T12:00:00-03:00'
  $record.Sequence = [string]$Sequence
  $record.Kind = 'Snapshot'
  $record.Role = 'Pinpad'
  $record.InstanceId = 'USB\PINPAD\001'
  $record.DeviceName = 'Pinpad "teste" \ ação'
  $record.Port = 'COM4'
  $record.Detail = "Linha 1`r`nLinha 2`tçã"
  return $record
}

function New-TestHardware {
  return @{schemaVersion=1;collectedAt='2026-10-19T12:00:00-03:00';machineId='5bf944a7-d15b-454f-b42b-43d36a98f439';hostname='CX4901';manufacturer='Ação';model='Caixa';serialNumber='SN1';os=@{caption='Windows 10';version='10.0';build='19045';architecture='64-bit';lastBootAt=''};cpu=@{name='CPU';cores='4';logicalProcessors='8'};memory=@{totalBytes='8589934592';modules=@()};disks=@(@{id='0';model='SSD';serialNumber='';sizeBytes='18446744073709551615';interfaceType='SATA';status='OK'});systemVolume=@{name='C:';totalBytes='';freeBytes=''};networkAdapters=@(@{name='Ethernet';macAddress='AA:BB:CC:DD:EE:FF';adapterType='Ethernet'});warnings=@()};
}

function Get-TestQueueCount {
  param($Session)
  return @([IO.Directory]::GetFiles($Session.OutboxPath, '*.xml')).Count
}

function Reset-TestBackoff {
  param($Session)
  $Session.NextUploadAt = [DateTimeOffset]::MinValue
}

try {
  $session = New-TestSession
  $session.Config.Central.Enabled = $false
  $record = New-TestRecord $session
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $result.Queued -and $result.Reason -eq 'CentralDisabled' -and (Get-TestQueueCount $session) -eq 0) 'Central desativada não enfileira'
  $session.Config.Central.Enabled = $true
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport ($result.Queued -and (Get-TestQueueCount $session) -eq 1) 'Enfileira um XML persistente'
  $again = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport ($again.Queued -and $again.Reason -eq 'AlreadyQueued' -and (Get-TestQueueCount $session) -eq 1) 'Mesmo EventId e conteúdo não duplica arquivo'
  $record.Detail = 'Conteúdo alterado no mesmo ID'
  $collision = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $collision.Queued -and (Get-TestQueueCount $session) -eq 1) 'Colisão de EventId não sobrescreve evento pendente'
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Success -and $result.Sent -eq 1 -and (Get-TestQueueCount $session) -eq 0) 'HTTP 204 confirma e remove apenas lote enviado'
  $posts = & $module { return ,$script:TestPosts.ToArray() }
  $json = ConvertFrom-TestJson $posts[0].Json
  Assert-Transport ($json.schemaVersion -eq 1 -and $json.storeId -is [string] -and $json.events[0].Sequence -is [string] -and $json.events[0].EventId -eq $record.EventId) 'Envelope JSON fixo usa strings em todos os campos de eventos'
  Assert-Transport ($json.events[0].DeviceName -eq 'Pinpad "teste" \ ação' -and $json.events[0].Detail -eq "Linha 1`r`nLinha 2`tçã") 'JSON preserva aspas, barras, Unicode e quebras de linha'
  Assert-Transport ($posts[0].Json -notlike ('*' + ('a' * 64) + '*')) 'Token ausente do corpo JSON'

  # Timeouts, limitação e redirecionamentos preservam os EventIds para dedup.
  $session = New-TestSession
  $record = New-TestRecord $session
  [void](Add-PdvMonitorOutboxRecord $session $record)
  & $module { $script:TestTimeout = $true }
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport (-not $result.Success -and (Get-TestQueueCount $session) -eq 1 -and $session.UploadFailureCount -eq 1) 'Timeout mantém evento e registra falha'
  $now = & $module { return $script:TestNow }
  Assert-Transport (($session.NextUploadAt - $now).TotalSeconds -eq 30) 'Primeiro backoff é de 30 segundos'
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Reason -eq 'BackoffActive') 'Intervalo de backoff não dispara nova conexão'
  Reset-TestBackoff $session
  & $module { $script:TestTimeout=$false; $script:TestStatus=429 }
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Reason -eq 'Http429' -and (Get-TestQueueCount $session) -eq 1 -and ($session.NextUploadAt - $now).TotalSeconds -eq 60) 'HTTP 429 mantém fila e aumenta backoff'
  Reset-TestBackoff $session
  & $module { $script:TestStatus=302 }
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Reason -eq 'Http302' -and (Get-TestQueueCount $session) -eq 1) 'Redirecionamento não é confirmação'
  Reset-TestBackoff $session
  & $module { $script:TestStatus=200 }
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Reason -eq 'Http200' -and (Get-TestQueueCount $session) -eq 1) 'HTTP 200 não confirma lote'
  Reset-TestBackoff $session
  & $module { $script:TestStatus=204 }
  $result = Invoke-PdvMonitorUpload $session
  $posts = & $module { return ,$script:TestPosts.ToArray() }
  $first = ConvertFrom-TestJson $posts[0].Json
  $last = ConvertFrom-TestJson $posts[$posts.Length - 1].Json
  Assert-Transport ($result.Success -and $first.events[0].EventId -eq $last.events[0].EventId -and $first.batchId -ne $last.batchId -and (Get-TestQueueCount $session) -eq 0) 'Reenvio conserva EventId para deduplicação no backend'

  $session = New-TestSession
  [void](Add-PdvMonitorOutboxRecord $session (New-TestRecord $session))
  & $module { $script:TestCredentialFailure = $true }
  $result = Invoke-PdvMonitorUpload $session
  $postCount = & $module { return $script:TestPosts.Count }
  Assert-Transport ($result.Reason -eq 'CredentialUnavailable' -and $postCount -eq 0 -and (Get-TestQueueCount $session) -eq 1 -and ($session.NextUploadAt - $now).TotalSeconds -eq 900) 'Falha de credencial não envia rede nem repete antes de 15 minutos'
  & $module { $script:TestCredentialFailure=$false; $script:TestStatus=401 }
  Reset-TestBackoff $session
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Reason -eq 'Http401' -and ($session.NextUploadAt - $now).TotalSeconds -eq 900 -and (Get-TestQueueCount $session) -eq 1) 'HTTP 401 reduz frequência sem descartar fila'

  # Alterar loja/terminal/agente com eventos pendentes é proibido.
  $session = New-TestSession
  [void](Add-PdvMonitorOutboxRecord $session (New-TestRecord $session))
  $oldAgent = $session.Config.Central.AgentId
  $result = Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '50' 'CX5001' ([Guid]::NewGuid().ToString('D')) ('a' * 64)
  Assert-Transport (-not $result.Success -and $result.Reason -eq 'PendingIdentityChange' -and $session.Config.Central.AgentId -eq $oldAgent -and (Get-TestQueueCount $session) -eq 1) 'Bloqueia troca de identidade antes de esvaziar fila'
  $result = Set-PdvMonitorCentralConfig $session 'https://nova.example/api/pdv-monitor/ingest' '49' 'CX4901' $oldAgent ('a' * 64)
  Assert-Transport $result.Success 'Permite trocar endpoint/credencial preservando identidade da fila'
  $session.Config.Central.Terminal = 'CX4902'
  $result = Invoke-PdvMonitorUpload $session
  $postCount = & $module { return $script:TestPosts.Count }
  Assert-Transport ($result.Reason -eq 'OutboxIdentityMismatch' -and $postCount -eq 0 -and (Get-TestQueueCount $session) -eq 1) 'Alteração em memória também não reatribui eventos a outro terminal'

  $session = New-TestSession
  foreach ($endpoint in @('http://conecta.example/api/pdv-monitor/ingest', 'https://user:password@conecta.example/api/pdv-monitor/ingest', 'https://conecta.example/api/pdv-monitor/ingest?token=x', 'https://conecta.example/api/pdv-monitor/ingest#fragment', 'https://conecta.example/outro')) {
    $result = Set-PdvMonitorCentralConfig $session $endpoint '49' 'CX4901' $session.Config.Central.AgentId ('a' * 64)
    Assert-Transport (-not $result.Success -and $result.Reason -eq 'InvalidConfiguration') 'Recusa destino sem HTTPS limpo e caminho esperado'
  }
  foreach ($store in @('0', '10000', '49x', '049')) {
    $result = Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' $store 'CX4901' $session.Config.Central.AgentId ('a' * 64)
    Assert-Transport (-not $result.Success) 'Loja deve estar no intervalo decimal 1..9999'
  }
  $result = Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '49' '../cx' $session.Config.Central.AgentId ('a' * 64)
  Assert-Transport (-not $result.Success) 'Recusa terminal inválido'
  $result = Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '49' 'CX4901' 'agent-invalid' ('a' * 64)
  Assert-Transport (-not $result.Success) 'Recusa agente fora de UUID'
  $result = Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '49' 'CX4901' $session.Config.Central.AgentId 'token-invalid'
  Assert-Transport (-not $result.Success) 'Recusa credencial fora de 64 hexadecimais'

  # Limites de lote por quantidade e bytes, sem descarte dos restantes.
  $session = New-TestSession
  for ($i=1; $i -le 51; $i++) { $result=Add-PdvMonitorOutboxRecord $session (New-TestRecord $session $i); if (-not $result.Queued) { throw 'Falha ao preparar lote de teste.' } }
  $result = Invoke-PdvMonitorUpload $session
  Assert-Transport ($result.Sent -eq 50 -and (Get-TestQueueCount $session) -eq 1) 'Lote contém no máximo 50 eventos'
  $session = New-TestSession
  for ($i=1; $i -le 3; $i++) { $record=New-TestRecord $session $i; $record.Detail='ç' * 60000; $result=Add-PdvMonitorOutboxRecord $session $record; if (-not $result.Queued) { throw ('Evento de teste grande rejeitado: '+$result.Reason) } }
  $result = Invoke-PdvMonitorUpload $session
  $posts = & $module { return ,$script:TestPosts.ToArray() }
  Assert-Transport ($result.Sent -eq 2 -and $posts[0].Bytes -le 262144 -and (Get-TestQueueCount $session) -eq 1) 'Lote JSON UTF-8 não ultrapassa 256 KB'

  # Quotas reais menores somente no teste evitam gerar 100 MB/20 mil arquivos.
  $session = New-TestSession
  & $module { $script:PdvOutboxMaxRecords=1 }
  [void](Add-PdvMonitorOutboxRecord $session (New-TestRecord $session))
  $result = Add-PdvMonitorOutboxRecord $session (New-TestRecord $session 2)
  Assert-Transport (-not $result.Queued -and $result.Reason -eq 'OutboxQuotaExceeded' -and (Get-TestQueueCount $session) -eq 1 -and $session.UploadStatusText -like '*cheia*') 'Quota de quantidade impede novo evento sem descartar pendente silenciosamente'
  & $module { $script:PdvOutboxMaxRecords=20000; $script:PdvOutboxMaxBytes=1 }
  $session = New-TestSession
  $result = Add-PdvMonitorOutboxRecord $session (New-TestRecord $session)
  Assert-Transport (-not $result.Queued -and $result.Reason -eq 'OutboxQuotaExceeded' -and (Get-TestQueueCount $session) -eq 0) 'Quota de bytes é aplicada antes de gravar'
  & $module { $script:PdvOutboxMaxBytes=104857600 }
  $record = New-TestRecord $session; $record.Detail='x' * 270000
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $result.Queued -and $result.Reason -eq 'RecordTooLarge') 'Evento individual excessivo deixa lacuna explícita'

  # Valores inesperados e XML adulterado falham sem executar conteúdo.
  $session = New-TestSession
  $record = New-TestRecord $session; $record.Sequence=42
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $result.Queued) 'Campos de evento precisam ser strings'
  $record = New-TestRecord $session; $record.EventId='../escape'
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $result.Queued) 'EventId inválido não vira caminho'
  $record = New-TestRecord $session; $record.Timestamp='2026-10-15 12:00:00'
  $result = Add-PdvMonitorOutboxRecord $session $record
  Assert-Transport (-not $result.Queued) 'Timestamp exige ISO com fuso explícito'
  $record = New-TestRecord $session; $record.Token=('a' * 64)
  [void](Add-PdvMonitorOutboxRecord $session $record)
  $xmlPath = [IO.Directory]::GetFiles($session.OutboxPath, '*.xml')[0]
  $xml = [IO.File]::ReadAllText($xmlPath)
  Assert-Transport ($xml -notlike '*<Token>*' -and $xml -notlike ('*'+('a' * 64)+'*')) 'Somente campos fixos vão para XML; propriedades extras não vazam token'
  $evil = '<!DOCTYPE PdvMonitorOutbox [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><PdvMonitorOutbox schemaVersion="1"><Detail>&xxe;</Detail></PdvMonitorOutbox>'
  [IO.File]::WriteAllText($xmlPath, $evil)
  $result = Invoke-PdvMonitorUpload $session
  $postCount = & $module { return $script:TestPosts.Count }
  Assert-Transport (-not $result.Success -and $postCount -eq 0 -and (Get-TestQueueCount $session) -eq 1) 'DTD/entidades externas são rejeitados sem rede nem apagar arquivo'

  # Inventário e eventos são confirmados juntos; somente o 204 remove ambos.
  $session=New-TestSession; $hardware=New-TestHardware;
  $queued=Set-PdvMonitorHardwarePending -Session $session -Hardware $hardware;
  $hardwarePath=Join-Path $session.DataDirectory 'hardware-pendente.xml';
  Assert-Transport ($queued.Queued -and [IO.File]::Exists($hardwarePath)) 'Inventário tem arquivo durável separado da fila histórica';
  $record=New-TestRecord $session; [void](Add-PdvMonitorOutboxRecord $session $record);
  & $module { $script:TestStatus=503 }; $result=Invoke-PdvMonitorUpload $session;
  Assert-Transport (-not $result.Success -and [IO.File]::Exists($hardwarePath) -and (Get-TestQueueCount $session) -eq 1) 'HTTP503 preserva inventário e evento sem ACK parcial';
  Reset-TestBackoff $session; & $module { $script:TestStatus=204 }; $result=Invoke-PdvMonitorUpload $session;
  $posts=& $module {return ,$script:TestPosts.ToArray()}; $first=ConvertFrom-TestJson $posts[0].Json; $last=ConvertFrom-TestJson $posts[1].Json;
  Assert-Transport ($result.Success -and -not [IO.File]::Exists($hardwarePath) -and (Get-TestQueueCount $session) -eq 0 -and $last.schemaVersion -eq 2 -and $last.events[0].EventId -ceq $record.EventId) 'ACK204 remove o par e v2 preserva EventId';
  Assert-Transport ($first.hardware.collectedAt -ceq $last.hardware.collectedAt -and $last.hardware.manufacturer -ceq 'Ação' -and $last.hardware.disks[0].sizeBytes -ceq '18446744073709551615' -and $posts[1].Bytes -le 262144) 'Reenvio preserva inventário, Unicode e UInt64 em string dentro dos limites';
  $session=New-TestSession; [void](Set-PdvMonitorHardwarePending $session (New-TestHardware));
  $changed=Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '50' 'CX5001' ([guid]::NewGuid().ToString()) ('a'*64);
  Assert-Transport ($changed.Reason -eq 'PendingIdentityChange') 'Inventário pendente também bloqueia troca da instalação';
  $result=Invoke-PdvMonitorUpload $session; $posts=& $module {return ,$script:TestPosts.ToArray()}; $body=ConvertFrom-TestJson $posts[0].Json;
  Assert-Transport ($result.Success -and $result.Sent -eq 0 -and $body.schemaVersion -eq 2 -and @($body.events).Count -eq 0 -and $body.hardware.hostname -ceq 'CX4901') 'Inventário sozinho usa v2 com array de eventos vazio sem heartbeat falso';
  $session=New-TestSession; $hardware=New-TestHardware; [void](Set-PdvMonitorHardwarePending $session $hardware);
  $path=Join-Path $session.DataDirectory 'hardware-pendente.xml'; $before=[IO.File]::ReadAllText($path);
  $hardware.model='x'*40000; $queued=Set-PdvMonitorHardwarePending $session $hardware;
  Assert-Transport (-not $queued.Queued -and [IO.File]::ReadAllText($path) -ceq $before) 'Inventário excessivo não trunca JSON nem destrói pendência anterior';
  $session=New-TestSession; $hardware=New-TestHardware; [void](Set-PdvMonitorHardwarePending $session $hardware);
  & $module {
    param($Session,$Hardware)
    $script:TestReplaceSession=$Session; $script:TestReplaceHardware=$Hardware;
    $script:TestAfterPost={ $script:TestReplaceHardware.collectedAt='2026-10-20T12:00:00-03:00'; [void](Set-PdvMonitorHardwarePending $script:TestReplaceSession $script:TestReplaceHardware) };
  } $session $hardware;
  $result=Invoke-PdvMonitorUpload $session;
  Assert-Transport ($result.Success -and [IO.File]::Exists((Join-Path $session.DataDirectory 'hardware-pendente.xml'))) 'ACK antigo não remove snapshot renovado durante a chamada, mesmo com o mesmo hash estático';
  Reset-TestBackoff $session; $result=Invoke-PdvMonitorUpload $session;
  Assert-Transport ($result.Success -and -not [IO.File]::Exists((Join-Path $session.DataDirectory 'hardware-pendente.xml'))) 'ACK do conteúdo exato conclui a nova pendência';
  $session=New-TestSession;$hardware=New-TestHardware;$hardware.schemaVersion=2;
  [void](Set-PdvMonitorHardwarePending $session $hardware);$hardwarePath=Join-Path $session.DataDirectory 'hardware-pendente.xml';$hardwareBytes=[IO.File]::ReadAllText($hardwarePath);
  [void](Add-PdvMonitorOutboxRecord $session (New-TestRecord $session));
  & $module {$script:TestHardwareUnsupported=$true};$result=Invoke-PdvMonitorUpload $session;
  $posts=& $module {return ,$script:TestPosts.ToArray()};
  Assert-Transport ($result.Success -and $result.Sent -eq 1 -and $posts.Count -eq 2 -and (Get-TestQueueCount $session) -eq 0) 'API antiga rejeita hardware e confirma somente os eventos em segundo envio';
  $first=ConvertFrom-TestJson $posts[0].Json;$fallback=ConvertFrom-TestJson $posts[1].Json;
  Assert-Transport ($first.schemaVersion -eq 2 -and $fallback.schemaVersion -eq 1 -and -not $fallback.PSObject.Properties['hardware'] -and $first.events[0].EventId -ceq $fallback.events[0].EventId) 'Fallback mantém EventId e remove apenas o documento incompatível';
  Assert-Transport ([IO.File]::ReadAllText($hardwarePath) -ceq $hardwareBytes) 'ACK só dos eventos conserva bytes do hardware sem confirmação falsa';
  Reset-TestBackoff $session;$result=Invoke-PdvMonitorUpload $session;
  Assert-Transport ($result.Reason -eq 'OutboxEmpty' -and (& $module {$script:TestPosts.Count}) -eq 2 -and [IO.File]::Exists($hardwarePath)) 'Espera compatibilidade por quinze minutos sem novas chamadas de hardware';
  [void](Add-PdvMonitorOutboxRecord $session (New-TestRecord $session 2));Reset-TestBackoff $session;$result=Invoke-PdvMonitorUpload $session;
  Assert-Transport ($result.Success -and $result.Sent -eq 1 -and [IO.File]::Exists($hardwarePath)) 'Eventos novos continuam durante a espera de integração';
  & $module {$script:TestHardwareUnsupported=$false;$script:TestNow=$script:TestNow.AddMinutes(16)};Reset-TestBackoff $session;$result=Invoke-PdvMonitorUpload $session;
  Assert-Transport ($result.Success -and -not [IO.File]::Exists($hardwarePath)) 'API atualizada confirma hardware na próxima tentativa elegível';

  # Configuração persiste sem segredo e reabre com mesma identificação.
  $session = New-TestSession
  $reopened = New-Object PSObject -Property @{DataDirectory=$session.DataDirectory; Id=[Guid]::NewGuid().ToString('D'); Config=@{} }
  $result = Initialize-PdvMonitorCentral $reopened
  Assert-Transport ($result.Success -and $reopened.Config.Central.AgentId -eq $session.Config.Central.AgentId -and $reopened.Config.Central.Enabled) 'Reabre configuração persistida sem solicitar token em claro'
  foreach ($path in [IO.Directory]::GetFiles($testRoot, '*', [IO.SearchOption]::AllDirectories)) {
    if ([IO.Path]::GetExtension($path) -eq '.xml') { Assert-Transport ([IO.File]::ReadAllText($path) -notlike ('*'+('a' * 64)+'*')) 'Exportáveis XML não contêm token' }
  }
  Assert-Transport ($session.UploadStatusText -notlike ('*'+('a' * 64)+'*')) 'Mensagem de status não contém token'
  $source = [IO.File]::ReadAllText((Join-Path $moduleDirectory 'PdvMonitor.Transporte.psm1'))
  Assert-Transport ($source -match 'AllowAutoRedirect = \$false' -and $source -match 'Timeout = 5000' -and $source -match 'ReadWriteTimeout = 5000' -and $source -match 'SecurityProtocolType\]3072' -and $source -notmatch 'ServerCertificateValidationCallback\s*=') 'Adaptador HTTP declara TLS 1.2, sem redirect, limites de 5 segundos e sem bypass de certificado'
  Write-Host ('PASS: ' + $script:assertions + ' verificações offline; fila persistente, 204/timeout/429/redirect, reenvio idempotente, quotas, identidade, XML seguro e ausência de token nos exportáveis. HTTP e DPAPI reais não foram executados. Runtime PowerShell ' + $PSVersionTable.PSVersion + '.')
} finally {
  & $module { $script:PdvOutboxMaxRecords=20000; $script:PdvOutboxMaxBytes=104857600 }
  if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}
