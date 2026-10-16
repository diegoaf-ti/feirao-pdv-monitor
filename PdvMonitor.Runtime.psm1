#requires -Version 2.0
# Runtime compartilhado pelo host. Estado sempre recebido por argumento para
# permitir coleta em runspace separado, sem disputar a porta com Nerus/CliSiTef.
$script:runtimeDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $script:runtimeDirectory 'PdvMonitor.Coleta.psm1') -Force;
Import-Module (Join-Path $script:runtimeDirectory 'PdvMonitor.Politica.psm1') -Force;
Import-Module (Join-Path $script:runtimeDirectory 'PdvMonitor.Transporte.psm1') -Force;

function Get-PdvRuntimeNow { return [DateTimeOffset]::Now; }

function Get-PdvRuntimeValue {
  param($Object, [string]$Name, $Default = $null);
  if ($null -eq $Object) { return $Default; }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name]; }
    return $Default;
  }
  $property = $Object.PSObject.Properties[$Name];
  if ($null -ne $property -and $null -ne $property.Value) { return $property.Value; }
  return $Default;
}

function Write-PdvRuntimeAtomic {
  param([string]$Path, [string]$Text);
  $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp';
  try {
    [IO.File]::WriteAllText($temporary, $Text, [Text.Encoding]::UTF8);
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, ($Path + '.bak')); }
    else { [IO.File]::Move($temporary, $Path); }
  } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary); } }
}

function Read-PdvRuntimeXml {
  param([string]$Path);
  if ((New-Object IO.FileInfo($Path)).Length -gt 1MB) { throw 'Arquivo de configuração excede o limite de tamanho.'; }
  $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8);
  if ($text -match '<!DOCTYPE|<!ENTITY') { throw 'Declarações externas não são permitidas na configuração.'; }
  $document = New-Object Xml.XmlDocument;
  $document.XmlResolver = $null; $document.LoadXml($text);
  return ,$document;
}

function Save-PdvRuntimeConfig {
  param($Session);
  $xml = New-Object Xml.XmlDocument; $root = $xml.CreateElement('monitor');
  [void]$root.SetAttribute('version', '1'); [void]$xml.AppendChild($root);
  $processes = $xml.CreateElement('processes'); [void]$root.AppendChild($processes);
  foreach ($name in @($Session.Config.BlockingProcessNames)) {
    $node = $xml.CreateElement('process'); $node.SetAttribute('name', [string]$name); [void]$processes.AppendChild($node);
  }
  $profiles = $xml.CreateElement('profiles'); [void]$root.AppendChild($profiles);
  foreach ($profile in @($Session.Config.Profiles)) {
    $node = $xml.CreateElement('profile');
    foreach ($key in @('Role', 'InstanceId', 'ExpectedPort', 'Name', 'RecoveryEnabled')) { $node.SetAttribute($key, [string](Get-PdvRuntimeValue $profile $key '')); }
    [void]$profiles.AppendChild($node);
  }
  Write-PdvRuntimeAtomic (Join-Path $Session.DataDirectory 'monitor.xml') $xml.OuterXml;
}

function Get-PdvMonitorCsvFields {
  return @('EventId', 'Timestamp', 'SessionId', 'Sequence', 'Kind', 'Role', 'InstanceId', 'DeviceName', 'Port', 'Present', 'PresenceKnown', 'Status', 'ProblemCode', 'Reason', 'Detail', 'WindowsChannel', 'RecordId', 'Provider', 'WindowsEventId');
}

function ConvertTo-PdvProtocolText {
  param($Value, [int]$MaximumLength);
  $text = [string]$Value; $builder = New-Object Text.StringBuilder;
  for ($index = 0; $index -lt $text.Length; $index++) {
    $character = $text[$index];
    # Tabulação e quebras de linha são dados válidos no protocolo/CSV. Os
    # demais controles, incluindo DEL/C1, não devem contaminar logs ou lotes.
    if ([char]::IsControl($character) -and @([char]9, [char]10, [char]13) -notcontains $character) { continue; }
    if ([char]::IsHighSurrogate($character)) {
      if (($index + 1) -lt $text.Length -and [char]::IsLowSurrogate($text[$index + 1])) {
        if (($builder.Length + 2) -gt $MaximumLength) { break; }
        [void]$builder.Append($character); $index++; [void]$builder.Append($text[$index]); continue;
      }
      $character = [char]0xfffd;
    } elseif ([char]::IsLowSurrogate($character)) { $character = [char]0xfffd; }
    if ($builder.Length -ge $MaximumLength) { break; }
    [void]$builder.Append($character);
  }
  return $builder.ToString();
}

function ConvertTo-PdvProtocolRecord {
  param($Record);
  # Manter este contrato alinhado ao EVENT_LIMITS do backend. Normalização
  # acontece somente na cópia para log/envio; nunca altera o Device utilizado
  # para identificar uma instância ou decidir recuperação.
  $limits = @{
    EventId=36; Timestamp=48; SessionId=36; Sequence=20; Kind=64; Role=64;
    InstanceId=1024; DeviceName=256; Port=8; Present=5; PresenceKnown=5;
    Status=120; ProblemCode=20; Reason=256; Detail=2000; WindowsChannel=180;
    RecordId=20; Provider=180; WindowsEventId=10;
  };
  $notes = New-Object 'Collections.Generic.List[string]';
  foreach ($field in @('ProblemCode', 'RecordId', 'WindowsEventId')) {
    $original = [string](Get-PdvRuntimeValue $Record $field '');
    $unsigned = [UInt64]0;
    $valid = ($original -match '^\d{1,20}$' -and [UInt64]::TryParse($original, [ref]$unsigned));
    if ($field -eq 'WindowsEventId' -and $unsigned -gt 65535) { $valid = $false; }
    if ($valid) { $Record.$field = $unsigned.ToString([Globalization.CultureInfo]::InvariantCulture); }
    else {
      $Record.$field = '';
      if ($original) { $notes.Add($field + ' original=' + (ConvertTo-PdvProtocolText $original 120)); }
    }
  }
  foreach ($field in @('Present', 'PresenceKnown')) {
    $original = [string](Get-PdvRuntimeValue $Record $field '');
    if ($original -match '^(true|false)$') { $Record.$field = $original.ToLowerInvariant(); }
    else { $Record.$field = ''; if ($original) { $notes.Add($field + ' original=' + (ConvertTo-PdvProtocolText $original 120)); } }
  }
  $originalPort = ([string]$Record.Port).Trim();
  if ($originalPort -match '^COM([1-9][0-9]{0,3})$' -and [int]$Matches[1] -le 4096) { $Record.Port = $originalPort.ToUpperInvariant(); }
  else { $Record.Port = ''; if ($originalPort) { $notes.Add('Port original=' + (ConvertTo-PdvProtocolText $originalPort 120)); } }
  if ([string]$Record.Kind -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') {
    $notes.Add('Kind original=' + (ConvertTo-PdvProtocolText $Record.Kind 120)); $Record.Kind = 'InvalidKind';
  }
  if ($Record.WindowsChannel -and [string]$Record.WindowsChannel -notmatch '^[A-Za-z0-9_ /.-]+$') {
    $notes.Add('WindowsChannel original=' + (ConvertTo-PdvProtocolText $Record.WindowsChannel 120)); $Record.WindowsChannel = '';
  }
  if ($notes.Count) { $Record.Detail = ([string]::Join(' | ', $notes.ToArray()) + ' | ' + [string]$Record.Detail); }
  foreach ($field in $limits.Keys) { $Record.$field = ConvertTo-PdvProtocolText (Get-PdvRuntimeValue $Record $field '') $limits[$field]; }
  return $Record;
}

function ConvertTo-PdvMonitorCsvValue {
  param($Value);
  $text = [string]$Value;
  return ('"' + $text.Replace('"', '""') + '"');
}

function Remove-PdvMonitorOldLogs {
  param($Session);
  $files = @(Get-ChildItem -LiteralPath $Session.LogDirectory -Filter 'monitor-*.csv' | Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTimeUtc);
  $size = 0L;
  foreach ($file in $files) { $size += $file.Length; }
  foreach ($file in $files) {
    if ($file.FullName -eq $Session.LogPath) { continue; }
    if ($file.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-30) -or $size -gt 100MB) {
      [IO.File]::Delete($file.FullName); $size -= $file.Length;
    }
  }
}

function Write-PdvMonitorRecord {
  param($Session, [string]$Kind, [string]$Detail = '', $Device = $null, [string]$Role = '', [string]$Reason = '', $WindowsEvent = $null);
  $record = New-Object PSObject -Property @{
    EventId = [guid]::NewGuid().ToString(); Timestamp = (Get-PdvRuntimeNow).ToString('o');
    SessionId = $Session.Id; Sequence = [string]($Session.Sequence + 1); Kind = $Kind;
    Role = $Role; InstanceId = [string](Get-PdvRuntimeValue $Device 'InstanceId' '');
    DeviceName = [string](Get-PdvRuntimeValue $Device 'Name' ''); Port = [string](Get-PdvRuntimeValue $Device 'Port' '');
    Present = [string](Get-PdvRuntimeValue $Device 'Present' ''); PresenceKnown = [string](Get-PdvRuntimeValue $Device 'PresenceKnown' '');
    Status = [string](Get-PdvRuntimeValue $Device 'Status' ''); ProblemCode = [string](Get-PdvRuntimeValue $Device 'ProblemCode' '');
    Reason = $Reason; Detail = $Detail; WindowsChannel = [string](Get-PdvRuntimeValue $WindowsEvent 'Channel' '');
    RecordId = [string](Get-PdvRuntimeValue $WindowsEvent 'RecordId' ''); Provider = [string](Get-PdvRuntimeValue $WindowsEvent 'Provider' '');
    WindowsEventId = [string](Get-PdvRuntimeValue $WindowsEvent 'Id' '');
  };
  $record = ConvertTo-PdvProtocolRecord $record;
  $date = Get-Date -Format 'yyyyMMdd';
  if (-not $Session.LogPath -or $Session.LogDate -ne $date -or ((New-Object IO.FileInfo($Session.LogPath)).Exists -and (New-Object IO.FileInfo($Session.LogPath)).Length -ge 5MB)) {
    $Session.LogPart++; $Session.LogDate = $date;
    $Session.LogPath = Join-Path $Session.LogDirectory ('monitor-' + $date + '-' + $Session.Id + '-' + $Session.LogPart.ToString('000') + '.csv');
  }
  $newFile = -not [IO.File]::Exists($Session.LogPath);
  $writer = New-Object IO.StreamWriter($Session.LogPath, $true, [Text.Encoding]::UTF8);
  try {
    $fields = @(Get-PdvMonitorCsvFields);
    if ($newFile) { $writer.WriteLine((@($fields | ForEach-Object { ConvertTo-PdvMonitorCsvValue $_ }) -join ',')); }
    $writer.WriteLine((@($fields | ForEach-Object { ConvertTo-PdvMonitorCsvValue (Get-PdvRuntimeValue $record $_ '') }) -join ','));
    $writer.Flush();
  } finally { $writer.Dispose(); }
  $Session.Sequence++; $Session.LoggingHealthy = $true;
  try {
    $queued = Add-PdvMonitorOutboxRecord -Session $Session -Record $record;
    if ($null -ne $queued -and (Get-PdvRuntimeValue $queued 'Queued' $true) -eq $false -and (Get-PdvRuntimeValue $Session.Config.Central 'Enabled' $false)) {
      $Session.OutboxGapCount++;
    }
  } catch {
    $Session.OutboxGapCount++;
    $Session.UploadStatusText = 'Falha na fila de envio. Logs locais preservados.';
  }
}

function Save-PdvMonitorCursors {
  param($Session, [hashtable]$Cursors);
  $xml = New-Object Xml.XmlDocument; $root = $xml.CreateElement('cursors'); [void]$xml.AppendChild($root);
  foreach ($name in $Cursors.Keys) {
    $node = $xml.CreateElement('channel'); $node.SetAttribute('name', [string]$name); [void]$root.AppendChild($node);
    foreach ($key in @('RecordId', 'AnchorRecordId', 'AnchorTime', 'OldestRecordId', 'LogEpoch', 'CoverageStart')) {
      $value = $xml.CreateElement('value'); $value.SetAttribute('name', $key);
      $value.InnerText = [string](Get-PdvRuntimeValue $Cursors[$name] $key ''); [void]$node.AppendChild($value);
    }
  }
  Write-PdvRuntimeAtomic (Join-Path $Session.DataDirectory 'cursores.xml') $xml.OuterXml;
  $Session.Cursors = $Cursors;
}

function Save-PdvMonitorRecoveryHistory {
  param($Session);
  $xml = New-Object Xml.XmlDocument; $root = $xml.CreateElement('recovery'); [void]$xml.AppendChild($root);
  foreach ($id in $Session.RecoveryStates.Keys) {
    $node = $xml.CreateElement('device'); $node.SetAttribute('id', [string]$id); [void]$root.AppendChild($node);
    foreach ($time in @($Session.RecoveryStates[$id].Attempts)) {
      $attempt = $xml.CreateElement('attempt'); $attempt.InnerText = $time.ToString('o'); [void]$node.AppendChild($attempt);
    }
  }
  Write-PdvRuntimeAtomic (Join-Path $Session.DataDirectory 'recuperacoes.xml') $xml.OuterXml;
}

function New-PdvMonitorRecoveryState {
  return (New-Object PSObject -Property @{ ConsecutiveFailures = 0; LastAttemptAt = $null; AttemptsInWindow = 0; SessionAttempts = 0; WindowStartedAt = (Get-PdvRuntimeNow); Attempts = @(); LastObservedSignature = ''; });
}

function Start-PdvMonitorSession {
  [CmdletBinding()]
  param([string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor'));
  $data = [IO.Path]::GetFullPath($DataDirectory);
  [void][IO.Directory]::CreateDirectory($data);
  $logDirectory = Join-Path $data 'logs'; [void][IO.Directory]::CreateDirectory($logDirectory);
  $config = New-Object PSObject -Property @{
    Profiles = @(); BlockingProcessNames = @(); AutoRecoveryEnabled = $false;
    Central = (New-Object PSObject -Property @{ Enabled = $false; Endpoint = ''; StoreId = ''; Terminal = ''; AgentId = '' });
  };
  $configPath = Join-Path $data 'monitor.xml';
  if ([IO.File]::Exists($configPath)) {
    $xml = Read-PdvRuntimeXml $configPath;
    $config.BlockingProcessNames = @($xml.SelectNodes('/monitor/processes/process') | ForEach-Object { $_.GetAttribute('name') });
    $config.Profiles = @($xml.SelectNodes('/monitor/profiles/profile') | ForEach-Object {
      New-Object PSObject -Property @{
        Role = $_.GetAttribute('Role'); InstanceId = $_.GetAttribute('InstanceId'); ExpectedPort = $_.GetAttribute('ExpectedPort');
        Name = $_.GetAttribute('Name'); RecoveryEnabled = ($_.GetAttribute('RecoveryEnabled') -eq 'True');
      };
    });
  }
  $snapshot = New-Object PSObject -Property @{
    Devices = @(); Printers = @(); ReservedPorts = @(); Warnings = @(); InventoryMode = 'Aguardando';
    InventoryComplete = $false; PresenceComplete = $false;
    Windows = (New-Object PSObject -Property @{ Caption = ''; Build = 0; IsAdministrator = $false });
  };
  $session = New-Object PSObject -Property @{
    Id = [guid]::NewGuid().ToString(); DataDirectory = $data; LogDirectory = $logDirectory; Config = $config;
    Snapshot = $snapshot; PreviousDevices = @{}; InventoryBaseline = @{}; RecoveryStates = @{}; PreviousWarnings = '';
    PreviousDecisions = @{}; Cursors = @{}; ChannelStatusSignature = ''; Sequence = 0L;
    LogPath = ''; LogDate = ''; LogPart = 0; LoggingHealthy = $true; OutboxGapCount = 0L;
    LastTickAt = $null; LastHeartbeatAt = $null; LastSnapshotAt = $null; LastEventsAt = $null;
    StatusText = 'Iniciando monitoramento'; UploadStatusText = 'Envio central não configurado';
    MaintenanceArmed = $false; MaintenanceExpiresAt = $null; Signals = [Collections.Queue]::Synchronized((New-Object Collections.Queue));
    Stopped = $false; TickBusy = $false; HasBaseline = $false; RecoveryHistoryHealthy = $true;
    SignalDropCount = 0L; LastLoggedSignalDropCount = 0L;
    PreviousUploadFailureReason = ''; LastLoggedOutboxGapCount = 0L;
  };
  Initialize-PdvMonitorCentral -Session $session | Out-Null;
  $historyPath = Join-Path $data 'recuperacoes.xml';
  if ([IO.File]::Exists($historyPath)) {
    try {
      $xml = Read-PdvRuntimeXml $historyPath;
      if ($null -eq $xml.DocumentElement -or $xml.DocumentElement.Name -ne 'recovery' -or $xml.DocumentElement.NamespaceURI -ne '') { throw 'Formato do histórico inválido.'; }
      $knownIds = @{};
      foreach ($child in $xml.DocumentElement.ChildNodes) { if ($child.Name -ne 'device') { throw 'Registro inesperado no histórico.'; } }
      foreach ($node in $xml.SelectNodes('/recovery/device')) {
        $historyId = $node.GetAttribute('id');
        if (-not $historyId -or $historyId.Length -gt 512 -or $knownIds.ContainsKey($historyId) -or $node.Attributes.Count -ne 1) { throw 'Identificador inválido ou repetido no histórico.'; }
        $knownIds[$historyId] = $true;
        $state = New-PdvMonitorRecoveryState;
        foreach ($child in $node.ChildNodes) { if ($child.Name -ne 'attempt' -or $child.Attributes.Count -ne 0 -or $child.SelectNodes('*').Count -gt 0) { throw 'Tentativa inválida no histórico.'; } }
        foreach ($attempt in $node.SelectNodes('attempt')) {
          $time = [DateTimeOffset]::Parse($attempt.InnerText, [Globalization.CultureInfo]::InvariantCulture);
          if ($time -gt (Get-PdvRuntimeNow).AddHours(-1)) { $state.Attempts += $time; }
        }
        $state.Attempts = @($state.Attempts | Sort-Object);
        if ($state.Attempts.Count) { $state.LastAttemptAt = $state.Attempts[$state.Attempts.Count - 1]; }
        $session.RecoveryStates[$historyId] = $state;
      }
    } catch {
      $session.RecoveryHistoryHealthy = $false;
      Write-PdvMonitorRecord $session 'CollectionWarning' 'Histórico de recuperações inválido. Recuperação automática bloqueada até análise técnica do arquivo recuperacoes.xml.';
    }
  }
  $cursorPath = Join-Path $data 'cursores.xml';
  if ([IO.File]::Exists($cursorPath)) {
    try {
      $xml = Read-PdvRuntimeXml $cursorPath;
      foreach ($node in $xml.SelectNodes('/cursors/channel')) {
        $values = @{}; foreach ($value in $node.SelectNodes('value')) { $values[$value.GetAttribute('name')] = $value.InnerText; }
        $session.Cursors[$node.GetAttribute('name')] = $values;
      }
    } catch { Write-PdvMonitorRecord $session 'CollectionWarning' 'Cursores anteriores inválidos. A nova coleta terá cobertura inicial limitada e explícita.'; }
  }
  Write-PdvMonitorRecord $session 'SessionStarted' ('Monitor iniciado; computador=' + $env:COMPUTERNAME + '; PowerShell=' + $PSVersionTable.PSVersion + '; recuperação desarmada.');
  Remove-PdvMonitorOldLogs $session;
  return $session;
}

function Save-PdvMonitorProfiles {
  [CmdletBinding()]
  param($Session, [object[]]$Profiles);
  $checked = @(); $ids = @{}; $roles = @{};
  if (@($Profiles).Count -gt 16) { throw 'O monitor admite no máximo 16 perfis por computador.'; }
  foreach ($profile in @($Profiles)) {
    $role = ([string](Get-PdvRuntimeValue $profile 'Role' '')).Trim(); $id = ([string](Get-PdvRuntimeValue $profile 'InstanceId' '')).Trim();
    $port = ([string](Get-PdvRuntimeValue $profile 'ExpectedPort' '')).Trim().ToUpperInvariant();
    if (-not $role -or $role.Length -gt 64 -or -not $id -or $id.Length -gt 512 -or $id -match '[*?\x00-\x1f]' -or $role -match '[\x00-\x1f]') { throw 'Perfil com papel ou identificador inválido.'; }
    if ($port -and ($port -notmatch '^COM([1-9][0-9]{0,3})$' -or [int]$port.Substring(3) -gt 4096)) { throw 'Use COM1 a COM4096, ou deixe em branco para impressora sem COM.'; }
    if ($ids.ContainsKey($id) -or $roles.ContainsKey($role)) { throw 'Cada papel e cada instância devem aparecer uma única vez.'; }
    $ids[$id] = $true; $roles[$role] = $true;
    $checked += (New-Object PSObject -Property @{
      Role = $role; InstanceId = $id; ExpectedPort = $port; Name = [string](Get-PdvRuntimeValue $profile 'Name' '');
      RecoveryEnabled = ((Get-PdvRuntimeValue $profile 'RecoveryEnabled' $false) -is [bool] -and (Get-PdvRuntimeValue $profile 'RecoveryEnabled' $false) -eq $true);
    });
  }
  $old = $Session.Config.Profiles; $Session.Config.Profiles = @($checked);
  try { Save-PdvRuntimeConfig $Session; } catch { $Session.Config.Profiles = $old; throw; }
  $Session.MaintenanceArmed = $false; $Session.Config.AutoRecoveryEnabled = $false;
  foreach ($state in $Session.RecoveryStates.Values) { $state.ConsecutiveFailures = 0; $state.LastObservedSignature = ''; }
  Write-PdvMonitorRecord $Session 'ProfileChanged' 'Referências de dispositivos atualizadas. Recuperação desarmada; nenhuma configuração do Windows ou Nerus foi alterada.';
}

function Set-PdvMonitorCentral {
  [CmdletBinding()]
  param($Session, [string]$Endpoint, [string]$StoreId, [string]$Terminal, [string]$AgentId, [string]$Token);
  $result = Set-PdvMonitorCentralConfig -Session $Session -Endpoint $Endpoint -StoreId $StoreId -Terminal $Terminal -AgentId $AgentId -Token $Token;
  if (-not $result.Success) { throw ('Não foi possível configurar o envio: ' + $result.Reason + '. ' + $Session.UploadStatusText); }
  $Session.LastSnapshotAt = $null;
  Write-PdvMonitorRecord $Session 'CentralConfigured' 'Destino central configurado para esta instalação; chave de envio protegida localmente.';
}

function Set-PdvMonitorMaintenance {
  [CmdletBinding()]
  param($Session, [int]$Minutes = 0, [string[]]$BlockingProcessNames = @());
  if ($Minutes -eq 0) {
    $Session.MaintenanceArmed = $false; $Session.MaintenanceExpiresAt = $null; $Session.Config.AutoRecoveryEnabled = $false;
    Write-PdvMonitorRecord $Session 'MaintenanceDisarmed' 'Recuperação automática desarmada.'; return;
  }
  if ($Minutes -lt 1 -or $Minutes -gt 15) { throw 'A janela de manutenção deve durar de 1 a 15 minutos.'; }
  if (-not $Session.RecoveryHistoryHealthy) { throw 'O histórico de recuperações precisa ser analisado pelo suporte antes de permitir novas tentativas.'; }
  $names = @();
  foreach ($name in @($BlockingProcessNames)) {
    $normalized = ([string]$name).Trim();
    if ($normalized.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $normalized = $normalized.Substring(0, $normalized.Length - 4); }
    if (-not $normalized -or $normalized.Length -gt 120 -or $normalized -match '[*?\\/:;]') { throw 'Informe nomes exatos dos processos do Nerus e TEF, sem caminho ou curinga.'; }
    $names += $normalized;
  }
  if ($names.Count -eq 0) { throw 'Cadastre os nomes dos processos do Nerus e do TEF antes de armar a manutenção.'; }
  if (@($Session.Config.Profiles | Where-Object { $_.RecoveryEnabled }).Count -eq 0) { throw 'Habilite a recuperação no perfil de um dispositivo identificado.'; }
  $Session.Config.BlockingProcessNames = @($names | Select-Object -Unique); Save-PdvRuntimeConfig $Session;
  $Session.MaintenanceExpiresAt = (Get-PdvRuntimeNow).AddMinutes($Minutes);
  $Session.MaintenanceArmed = $true; $Session.Config.AutoRecoveryEnabled = $true;
  Write-PdvMonitorRecord $Session 'MaintenanceArmed' ('Janela de recuperação autorizada até ' + $Session.MaintenanceExpiresAt.ToString('o') + '; só será executada se todas as condições forem atendidas.');
}

function Get-PdvMonitorRecoveryContext {
  param($Session, $Snapshot, [bool]$Conflict);
  $processOk = $false; $blocked = @(); $printOk = $false; $jobs = 0;
  # Coleta normal não precisa consultar a lista de processos ou a fila a cada
  # perfil. Essas verificações só são relevantes na janela autorizada.
  if ($Session.Config.AutoRecoveryEnabled -and $Session.MaintenanceArmed -and $null -ne $Session.MaintenanceExpiresAt -and $Session.MaintenanceExpiresAt -gt (Get-PdvRuntimeNow) -and @($Session.Config.BlockingProcessNames).Count -gt 0) {
    try {
      $processes = @(Get-Process -ErrorAction Stop);
      foreach ($process in $processes) { if (@($Session.Config.BlockingProcessNames) -contains $process.ProcessName) { $blocked += $process.ProcessName; } }
      $processOk = $true;
    } catch { }
    try { $jobs = @(Get-WmiObject -Class Win32_PrintJob -ErrorAction Stop).Count; $printOk = $true; } catch { }
  }
  return (New-Object PSObject -Property @{
    AutoRecoveryEnabled = $Session.Config.AutoRecoveryEnabled; MaintenanceArmed = $Session.MaintenanceArmed;
    MaintenanceExpiresAt = $Session.MaintenanceExpiresAt;
    WindowsBuild = [int](Get-PdvRuntimeValue $Snapshot.Windows 'Build' 0); IsAdministrator = [bool](Get-PdvRuntimeValue $Snapshot.Windows 'IsAdministrator' $false);
    ProcessCheckSucceeded = $processOk; BlockingProcessNames = @($blocked);
    PrintCheckSucceeded = $printOk; PendingPrintJobs = $jobs;
    SnapshotComplete = ([bool](Get-PdvRuntimeValue $Snapshot 'InventoryComplete' $false) -and [bool](Get-PdvRuntimeValue $Snapshot 'PresenceComplete' $false));
    ProcessListConfigured = (@($Session.Config.BlockingProcessNames).Count -gt 0); ProfileConflict = $Conflict;
  });
}

function Invoke-PdvMonitorRestart {
  param([string]$InstanceId);
  Import-Module (Join-Path $script:runtimeDirectory 'PdvDispositivos.Core.psm1') -Force;
  return (Restart-PdvDevice -InstanceId $InstanceId);
}

function Get-PdvRuntimeDeviceSignature {
  param($Device);
  return ('{0}|{1}|{2}|{3}|{4}' -f $Device.Present, $Device.PresenceKnown, $Device.Port, $Device.Status, $Device.ProblemCode);
}

function Invoke-PdvMonitorTick {
  [CmdletBinding()]
  param($Session);
  if ($Session.Stopped -or $Session.TickBusy) { return; }
  $Session.TickBusy = $true;
  try {
    # Conseguir gravar antes de avaliar qualquer ação também bloqueia recuperação
    # quando o disco está cheio ou o diretório de logs perdeu acesso.
    if (-not $Session.LoggingHealthy) { Write-PdvMonitorRecord $Session 'LogGap' 'Gravação retomada; houve intervalo sem cobertura confiável.'; }
    $now = Get-PdvRuntimeNow;
    if ($Session.MaintenanceArmed -and ($null -eq $Session.MaintenanceExpiresAt -or $now -ge $Session.MaintenanceExpiresAt)) { Set-PdvMonitorMaintenance $Session -Minutes 0; }
    $droppedSignals = [long](Get-PdvRuntimeValue $Session 'SignalDropCount' 0);
    if ($droppedSignals -gt $Session.LastLoggedSignalDropCount) {
      Write-PdvMonitorRecord $Session 'LogGap' ('Fila de notificações do Windows atingiu o limite; sinais descartados nesta sessão=' + $droppedSignals + '; novos desde o último registro=' + ($droppedSignals - $Session.LastLoggedSignalDropCount) + '. A coleta periódica continua.');
      $Session.LastLoggedSignalDropCount = $droppedSignals;
    }
    $signalCount = 0;
    while ($Session.Signals.Count -gt 0 -and $signalCount -lt 1000) {
      $signal = $Session.Signals.Dequeue(); $signalCount++;
      Write-PdvMonitorRecord $Session 'WindowsDeviceChange' ('Sinal genérico do Windows: tipo=' + (Get-PdvRuntimeValue $signal 'EventType' '') + '; horário=' + (Get-PdvRuntimeValue $signal 'Time' '') + '. Não identifica qual dispositivo mudou.');
    }
    $snapshot = Get-PdvMonitorSnapshot; $Session.Snapshot = $snapshot;
    $warningText = @($snapshot.Warnings) -join ' | ';
    if ($warningText -ne $Session.PreviousWarnings) {
      Write-PdvMonitorRecord $Session 'CollectionWarning' $(if ($warningText) { $warningText } else { 'As consultas desta rodada não retornaram avisos.'; });
      $Session.PreviousWarnings = $warningText;
    }
    $complete = [bool](Get-PdvRuntimeValue $snapshot 'InventoryComplete' $false);
    $nextDevices = @{};
    foreach ($device in @($snapshot.Devices)) {
      $id = [string]$device.InstanceId; if (-not $id) { continue; }
      $signature = Get-PdvRuntimeDeviceSignature $device; $nextDevices[$id] = $device;
      if (-not $Session.PreviousDevices.ContainsKey($id) -or (Get-PdvRuntimeDeviceSignature $Session.PreviousDevices[$id]) -ne $signature) {
        $kind = 'DeviceChanged'; if (-not $Session.HasBaseline) { $kind = 'Snapshot'; }
        Write-PdvMonitorRecord $Session $kind ('Inventário ' + $snapshot.InventoryMode + '; esta observação não testa comunicação com o PDV.') $device;
      }
    }
    if ($complete) {
      foreach ($id in $Session.InventoryBaseline.Keys) {
        if ($Session.HasBaseline -and -not $nextDevices.ContainsKey($id)) { Write-PdvMonitorRecord $Session 'DeviceMissing' 'Instância deixou de ser enumerada em uma consulta completa; não houve reassociação automática.' $Session.InventoryBaseline[$id]; }
      }
      # Somente inventários completos definem a base para afirmar remoção.
      $Session.InventoryBaseline = $nextDevices.Clone();
      $Session.PreviousDevices = $nextDevices; $Session.HasBaseline = $true;
    } else {
      # Não transformar uma falha da consulta em desaparecimento de todos os dispositivos.
      foreach ($id in $nextDevices.Keys) { $Session.PreviousDevices[$id] = $nextDevices[$id]; }
    }
    if ($null -eq $Session.LastSnapshotAt -or ($now - $Session.LastSnapshotAt).TotalMinutes -ge 10) {
      foreach ($device in @($snapshot.Devices)) { Write-PdvMonitorRecord $Session 'Snapshot' ('Modo=' + $snapshot.InventoryMode + '; fabricante=' + $device.Manufacturer + '; driver=' + $device.DriverVersion) $device; }
      foreach ($printer in @($snapshot.Printers)) { Write-PdvMonitorRecord $Session 'PrinterSnapshot' ('Fila=' + $printer.Name + '; porta=' + $printer.PortName + '; driver=' + $printer.DriverName + '; offline=' + $printer.WorkOffline); }
      Write-PdvMonitorRecord $Session 'PortReservations' (@($snapshot.ReservedPorts) -join ';');
      $Session.LastSnapshotAt = $now;
    }
    if ($null -eq $Session.LastEventsAt -or ($now - $Session.LastEventsAt).TotalSeconds -ge 60) {
      $events = Get-PdvMonitorWindowsEvents -Cursors $Session.Cursors -MaxEventsPerChannel 100;
      foreach ($event in @($events.Events)) { Write-PdvMonitorRecord $Session 'WindowsEvent' ('Ocorrência Windows em ' + $event.TimeCreated + '; nível=' + $event.Level + '; detalhes livres omitidos.') -WindowsEvent $event; }
      $coverage = @($events.ChannelStatus | ForEach-Object { $_.Channel + ':ok=' + $_.Success + ';enabled=' + $_.Enabled + ';gap=' + $_.Gap + ';reset=' + $_.Reset + ';backlog=' + $_.Truncated + ';início=' + $_.CoverageStart; }) -join ' | ';
      if ($coverage -ne $Session.ChannelStatusSignature) {
        Write-PdvMonitorRecord $Session 'WindowsEventCoverage' $coverage;
        foreach ($warning in @($events.Warnings)) { Write-PdvMonitorRecord $Session 'CollectionWarning' $warning; }
        $Session.ChannelStatusSignature = $coverage;
      }
      # Somente após gravar todos os eventos. Falha aqui permite repetição local,
      # mas nunca confirma um cursor cujo lote não foi escrito por completo.
      Save-PdvMonitorCursors $Session $events.Cursors; $Session.LastEventsAt = $now;
    }
    foreach ($profile in @($Session.Config.Profiles)) {
      $id = $profile.InstanceId;
      $found = @($snapshot.Devices | Where-Object { $_.InstanceId -eq $id });
      $device = $null; if ($found.Count -eq 1) { $device = $found[0]; }
      if (-not $Session.RecoveryStates.ContainsKey($id)) {
        $Session.RecoveryStates[$id] = New-PdvMonitorRecoveryState;
      }
      $state = $Session.RecoveryStates[$id];
      $problem = [string](Get-PdvRuntimeValue $device 'ProblemCode' '');
      if ($complete -and $snapshot.PresenceComplete -and $null -ne $device -and $device.Present -and $device.PresenceKnown -and $problem -match '^\d+$' -and [int]$problem -gt 0 -and [int]$problem -ne 22 -and [int]$problem -ne 45) {
        $failureSignature = $problem + '|' + $device.Port + '|' + $device.Status;
        if ($state.LastObservedSignature -eq $failureSignature) { $state.ConsecutiveFailures++; } else { $state.ConsecutiveFailures = 1; }
        $state.LastObservedSignature = $failureSignature;
      } else { $state.ConsecutiveFailures = 0; $state.LastObservedSignature = ''; }
      $state.Attempts = @($state.Attempts | Where-Object { ($now - $_).TotalHours -lt 1 });
      $state.AttemptsInWindow = $state.Attempts.Count;
      $state.WindowStartedAt = $now; if ($state.Attempts.Count) { $state.WindowStartedAt = $state.Attempts[0]; }
      $conflict = ($found.Count -gt 1);
      if ($profile.ExpectedPort) {
        foreach ($other in @($snapshot.Devices)) { if ($other.InstanceId -ne $id -and $other.Port -eq $profile.ExpectedPort) { $conflict = $true; } }
        foreach ($otherProfile in @($Session.Config.Profiles)) { if ($otherProfile.InstanceId -ne $id -and $otherProfile.ExpectedPort -eq $profile.ExpectedPort) { $conflict = $true; } }
      }
      $context = Get-PdvMonitorRecoveryContext $Session $snapshot $conflict;
      $decision = Get-PdvRecoveryDecision -Profile $profile -Device $device -Context $context -State $state -Now $now;
      if ($Session.PreviousDecisions[$id] -ne $decision.Reason) {
        Write-PdvMonitorRecord $Session 'RecoveryDecision' $decision.Detail $device $profile.Role $decision.Reason;
        $Session.PreviousDecisions[$id] = $decision.Reason;
      }
      if ($decision.Allowed -and $Session.LoggingHealthy) {
        # Reconsultar imediatamente antes de agir. Nenhuma decisão usa o estado
        # de uma rodada anterior para inferir que o caixa continua fechado.
        $fresh = Get-PdvMonitorSnapshot;
        $freshDevices = @($fresh.Devices | Where-Object { $_.InstanceId -eq $id });
        $freshDevice = $null; if ($freshDevices.Count -eq 1) { $freshDevice = $freshDevices[0]; }
        $freshConflict = ($freshDevices.Count -ne 1);
        if ($profile.ExpectedPort) { foreach ($other in @($fresh.Devices)) { if ($other.InstanceId -ne $id -and $other.Port -eq $profile.ExpectedPort) { $freshConflict = $true; } } }
        $freshContext = Get-PdvMonitorRecoveryContext $Session $fresh $freshConflict;
        $freshSignature = '';
        if ($null -ne $freshDevice) { $freshSignature = [string]$freshDevice.ProblemCode + '|' + [string]$freshDevice.Port + '|' + [string]$freshDevice.Status; }
        if ($freshSignature -ne $state.LastObservedSignature) {
          # A nova falha ainda não teve três leituras. Não herdar a contagem de
          # outro erro/porta, mesmo que ambas as situações pareçam recuperáveis.
          $state.ConsecutiveFailures = 0; $state.LastObservedSignature = '';
          Write-PdvMonitorRecord $Session 'RecoveryDecision' 'O dispositivo mudou durante a revalidação. Aguardar três novas leituras da mesma falha.' $freshDevice $profile.Role 'FailureChangedBeforeRecovery';
          continue;
        }
        $final = Get-PdvRecoveryDecision -Profile $profile -Device $freshDevice -Context $freshContext -State $state -Now (Get-PdvRuntimeNow);
        if ($final.Allowed) {
          Write-PdvMonitorRecord $Session 'RecoveryAttempt' 'Solicitando ao Windows o reinício da instância exata; caixa em manutenção autorizada.' $freshDevice $profile.Role $final.Reason;
          $state.LastAttemptAt = Get-PdvRuntimeNow; $state.Attempts += $state.LastAttemptAt; $state.SessionAttempts++;
          Save-PdvMonitorRecoveryHistory $Session;
          try {
            $result = Invoke-PdvMonitorRestart -InstanceId $id;
            Write-PdvMonitorRecord $Session 'RecoveryResult' ('Código Windows=' + $result.ExitCode + '; reinicialização manual do PC necessária=' + $result.RestartRequired + '. Comunicação no Nerus ainda precisa ser validada.') $freshDevice $profile.Role ('WindowsExit' + $result.ExitCode);
          } catch { Write-PdvMonitorRecord $Session 'RecoveryResult' ('Windows recusou ou não concluiu o pedido: ' + $_.Exception.Message) $freshDevice $profile.Role 'RestartFailed'; }
          $state.ConsecutiveFailures = 0;
        } else { Write-PdvMonitorRecord $Session 'RecoveryDecision' $final.Detail $freshDevice $profile.Role $final.Reason; }
      }
    }
    if ($null -eq $Session.LastHeartbeatAt -or ($now - $Session.LastHeartbeatAt).TotalSeconds -ge 60) {
      Write-PdvMonitorRecord $Session 'Heartbeat' ('Monitor ativo; modo=' + $snapshot.InventoryMode + '; inventário completo=' + $snapshot.InventoryComplete + '; presença completa=' + $snapshot.PresenceComplete + '; dispositivos=' + @($snapshot.Devices).Count + '; recuperação armada=' + $Session.MaintenanceArmed + '; eventos sem fila central=' + $Session.OutboxGapCount);
      $Session.LastHeartbeatAt = $now; Remove-PdvMonitorOldLogs $Session;
    }
    $Session.LastTickAt = Get-PdvRuntimeNow;
    $Session.StatusText = 'Coletando | última consulta ' + (Get-Date -Format 'HH:mm:ss') + ' | ' + $snapshot.InventoryMode;
    if ($Session.MaintenanceArmed) { $Session.StatusText += ' | manutenção até ' + $Session.MaintenanceExpiresAt.ToString('HH:mm:ss'); }
    if ($warningText) { $Session.StatusText += ' | consulta com limitações (ver logs)'; }
    Write-PdvRuntimeAtomic (Join-Path $Session.DataDirectory 'status.txt') ($Session.StatusText + [Environment]::NewLine + 'Sessão=' + $Session.Id + [Environment]::NewLine + 'Contato do monitor não comprova funcionamento do TEF/impressora.');
    try { $upload = Invoke-PdvMonitorUpload -Session $Session; }
    catch { $upload = New-Object PSObject -Property @{Success=$false; Reason='UploadFailed'; Sent=0}; }
    $uploadReason = [string](Get-PdvRuntimeValue $upload 'Reason' 'UploadFailed');
    # Somente códigos produzidos pelo transporte, nunca corpo HTTP, exceções ou
    # cabeçalhos de autenticação, integram este registro durável.
    if (@('CentralDisabled', 'BackoffActive') -notcontains $uploadReason) {
      if (@('Acknowledged', 'OutboxEmpty') -contains $uploadReason) {
        if ($Session.PreviousUploadFailureReason) {
          $detail = 'Fila central voltou ao estado normal: sem pendências; nenhum envio necessário nesta rodada.';
          if ($uploadReason -eq 'Acknowledged') { $detail = 'A central voltou a confirmar os lotes enviados. A coleta local continuou durante a indisponibilidade.'; }
          Write-PdvMonitorRecord $Session 'UploadResumed' $detail -Reason $uploadReason;
          $Session.PreviousUploadFailureReason = '';
        }
      } else {
        if (@('CredentialUnavailable', 'OutboxIdentityMismatch', 'UploadFailed') -notcontains $uploadReason -and $uploadReason -notmatch '^Http[0-9]{3}$') { $uploadReason = 'UploadFailed'; }
        if ($Session.PreviousUploadFailureReason -ne $uploadReason) {
          Write-PdvMonitorRecord $Session 'UploadWarning' ('Envio central não confirmado; motivo=' + $uploadReason + '. A coleta local continua e os eventos pendentes permanecem na fila. Conferir a configuração e a conectividade da central.') -Reason $uploadReason;
          $Session.PreviousUploadFailureReason = $uploadReason;
        }
      }
    }
    if ($Session.OutboxGapCount -gt $Session.LastLoggedOutboxGapCount) {
      Write-PdvMonitorRecord $Session 'LogGap' ('Eventos registrados localmente sem inclusão na fila central nesta sessão=' + $Session.OutboxGapCount + '; novos desde o último registro=' + ($Session.OutboxGapCount - $Session.LastLoggedOutboxGapCount) + '. Exportar os logs locais para analisar a lacuna.') -Reason 'OutboxQueueGap';
      # A tentativa de enfileirar este próprio LogGap também pode falhar. Salvar
      # o contador depois dela impede um ciclo de alertas causado pelo alerta.
      $Session.LastLoggedOutboxGapCount = $Session.OutboxGapCount;
    }
  } catch {
    $Session.LoggingHealthy = $false;
    $Session.MaintenanceArmed = $false; $Session.Config.AutoRecoveryEnabled = $false;
    $Session.StatusText = 'Coleta com falha; recuperação desarmada. ' + $_.Exception.Message;
    try { Write-PdvMonitorRecord $Session 'CollectionWarning' $Session.StatusText; } catch { }
  } finally { $Session.TickBusy = $false; }
}

function Export-PdvMonitorLogs {
  [CmdletBinding()]
  param($Session, [string]$DestinationDirectory);
  if (-not [IO.Directory]::Exists($DestinationDirectory)) { throw 'Escolha uma pasta de destino existente.'; }
  $destination = Join-Path $DestinationDirectory ('PDV-diagnostico-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6));
  [void][IO.Directory]::CreateDirectory($destination);
  foreach ($file in @(Get-ChildItem -LiteralPath $Session.LogDirectory -Filter 'monitor-*.csv' | Where-Object { -not $_.PSIsContainer })) { [IO.File]::Copy($file.FullName, (Join-Path $destination $file.Name)); }
  foreach ($name in @('monitor.xml', 'central.xml', 'cursores.xml', 'recuperacoes.xml', 'status.txt')) {
    $path = Join-Path $Session.DataDirectory $name;
    if ([IO.File]::Exists($path)) { [IO.File]::Copy($path, (Join-Path $destination $name)); }
  }
  [IO.File]::WriteAllText((Join-Path $destination 'LEIA-ME.txt'), 'Diagnóstico local do monitor. Contém identificadores de hardware, loja/caixa e metadados de eventos. Não contém a chave de envio, dados de pagamento nem mensagens completas dos eventos do Windows. Datas incluem o fuso do computador; o relógio local pode estar incorreto. Logs locais têm retenção de 30 dias e limite total de 100 MB. O monitor não lê a configuração do Nerus nem executa pagamentos de teste.', [Text.Encoding]::UTF8);
  return $destination;
}

function Stop-PdvMonitorSession {
  [CmdletBinding()]
  param($Session);
  if ($Session.Stopped) { return; }
  $Session.MaintenanceArmed = $false; $Session.Config.AutoRecoveryEnabled = $false;
  try { Write-PdvMonitorRecord $Session 'MonitorStopped' 'Monitor encerrado pelo usuário. A coleta termina até a próxima execução.'; }
  finally { $Session.Stopped = $true; }
}

Export-ModuleMember -Function Start-PdvMonitorSession, Invoke-PdvMonitorTick, Stop-PdvMonitorSession, Export-PdvMonitorLogs, Set-PdvMonitorMaintenance, Save-PdvMonitorProfiles, Set-PdvMonitorCentral;
