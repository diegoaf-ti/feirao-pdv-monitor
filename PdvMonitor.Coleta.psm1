#requires -Version 2.0
# Coleta local somente leitura. Não abre COM, não toca em arquivos SiTef,
# não consulta transações e não habilita canais do Windows.
# Get-WinEvent: XPath no servidor + Oldest evita perder backlog ao aplicar limite.
# https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-5.1
$script:PdvCollectionRoot = Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $script:PdvCollectionRoot 'PdvLegado.Core.psm1') -Force;

function Get-PdvCollectionValue {
  param($InputObject, [string]$Name, $Default = $null);
  if ($null -eq $InputObject) { return $Default; }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return $InputObject[$Name]; }
    return $Default;
  }
  $property = $InputObject.PSObject.Properties[$Name];
  if ($null -ne $property -and $null -ne $property.Value) { return $property.Value; }
  return $Default;
}

function Get-PdvMonitorPlatform {
  $major = [Environment]::OSVersion.Version.Major;
  $build = [Environment]::OSVersion.Version.Build;
  try {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
      $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop;
    } else { $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop; }
    $major = ([Version]([string]$os.Version)).Major;
    $build = [int]$os.BuildNumber;
  } catch { }
  return (New-Object PSObject -Property @{ Major = $major; Build = $build; PowerShellMajor = $PSVersionTable.PSVersion.Major; PowerShellMinor = $PSVersionTable.PSVersion.Minor });
}

function ConvertTo-PdvMonitorSnapshot {
  param($Snapshot, [string]$Mode);
  $devices = @(
    foreach ($device in @(Get-PdvCollectionValue $Snapshot 'Devices' @())) {
      $known = [bool](Get-PdvCollectionValue $device 'PresenceKnown' $false);
      $present = $false;
      if ($known) { $present = [bool](Get-PdvCollectionValue $device 'Present' $false); }
      New-Object PSObject -Property @{
        InstanceId = [string](Get-PdvCollectionValue $device 'InstanceId' '');
        Name = [string](Get-PdvCollectionValue $device 'Name' '');
        Class = [string](Get-PdvCollectionValue $device 'Class' '');
        Port = Get-PdvCollectionValue $device 'Port'; Present = $present; PresenceKnown = $known;
        Status = [string](Get-PdvCollectionValue $device 'Status' '');
        ProblemCode = Get-PdvCollectionValue $device 'ProblemCode';
        Manufacturer = [string](Get-PdvCollectionValue $device 'Manufacturer' '');
        DriverVersion = [string](Get-PdvCollectionValue $device 'DriverVersion' '');
        HardwareIds = @(Get-PdvCollectionValue $device 'HardwareIds' @());
        Source = [string](Get-PdvCollectionValue $device 'Source' $Mode);
      };
    }
  );
  $windows = Get-PdvCollectionValue $Snapshot 'WindowsDetails';
  if ($null -eq $windows) { $windows = Get-PdvCollectionValue $Snapshot 'Windows'; }
  if ($windows -is [string]) { $windows = New-Object PSObject -Property @{ Caption = $windows; Version = ''; Build = 0; IsAdministrator = $false }; }
  return (New-Object PSObject -Property @{
    CapturedAt = [string](Get-PdvCollectionValue $Snapshot 'CapturedAt' ((Get-Date).ToString('o')));
    Windows = $windows; Devices = $devices;
    Printers = @(Get-PdvCollectionValue $Snapshot 'Printers' @());
    ReservedPorts = @(Get-PdvCollectionValue $Snapshot 'ReservedPorts' @());
    Warnings = @(Get-PdvCollectionValue $Snapshot 'Warnings' @());
    InventoryMode = $Mode;
    InventoryComplete = [bool](Get-PdvCollectionValue $Snapshot 'InventoryComplete' $false);
    PresenceComplete = [bool](Get-PdvCollectionValue $Snapshot 'PresenceComplete' $false);
  });
}

function Get-PdvMonitorSnapshot {
  [CmdletBinding()]
  param();
  $platform = Get-PdvMonitorPlatform;
  $modern = ($platform.PowerShellMajor -gt 5 -or ($platform.PowerShellMajor -eq 5 -and $platform.PowerShellMinor -ge 1));
  $modern = ($modern -and $platform.Major -ge 10 -and $null -ne (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue));
  if ($modern) {
    try {
      Import-Module (Join-Path $script:PdvCollectionRoot 'PdvDispositivos.Core.psm1') -Force -ErrorAction Stop;
      return (ConvertTo-PdvMonitorSnapshot (Get-PdvSnapshot) 'PnP');
    } catch {
      $fallback = ConvertTo-PdvMonitorSnapshot (Get-PdvLegacySnapshot) 'WMI-Legado';
      $fallback.Warnings = @($fallback.Warnings) + @('Coleta moderna falhou; consulta WMI legada usada nesta rodada.');
      return $fallback;
    }
  }
  return (ConvertTo-PdvMonitorSnapshot (Get-PdvLegacySnapshot) 'WMI-Legado');
}

function Get-PdvMonitorSystemEventXPath {
  # SCM é limitado a serviços relacionados à impressão/TEF. O payload é usado
  # somente pelo filtro nativo e nunca é materializado ou gravado pelo monitor.
  $providers = @('Microsoft-Windows-Kernel-PnP', 'Microsoft-Windows-UserPnp', 'Microsoft-Windows-DriverFrameworks-UserMode', 'Microsoft-Windows-USB-USBHUB3', 'Microsoft-Windows-USB-UCX', 'Microsoft-Windows-USB-USBPORT', 'Microsoft-Windows-USB-USBHUB', 'Microsoft-Windows-PrintService', 'Print', 'usbser', 'Serial');
  $providerTerms = @($providers | ForEach-Object { "Provider[@Name='" + $_ + "']" });
  $hardware = 'System[' + ($providerTerms -join ' or ') + ']';
  $service = "(System[Provider[@Name='Service Control Manager']] and EventData[Data='Spooler' or Data='Print Spooler' or Data='Spooler de Impressão' or Data='SiTef' or Data='CliSiTef' or Data='Cliente SiTef'])";
  $logLifecycle = "System[(Provider[@Name='Microsoft-Windows-Eventlog'] and EventID=104) or (Provider[@Name='EventLog'] and (EventID=6005 or EventID=6006))]";
  return @($hardware, $service, $logLifecycle);
}

function Read-PdvMonitorEventQuery {
  param([string]$Channel, [string]$XPath, [string]$FilterXml, [int]$MaxEvents = 100, [switch]$Oldest);
  # Get-WinEvent representa resultado vazio com erro NoMatchingEventsFound.
  # Outros erros são falhas reais e não devem avançar cursor.
  try {
    $arguments = @{ LogName = $Channel; MaxEvents = $MaxEvents; ErrorAction = 'Stop' };
    if ($FilterXml) {
      [void]$arguments.Remove('LogName'); $arguments['FilterXml'] = [xml]$FilterXml;
    } elseif ($XPath) { $arguments['FilterXPath'] = $XPath; }
    if ($Oldest) { $arguments['Oldest'] = $true; }
    return @(Get-WinEvent @arguments);
  } catch {
    if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @(); }
    throw;
  }
}

function ConvertTo-PdvMonitorEvent {
  param($Event, [string]$Channel);
  $time = Get-PdvCollectionValue $Event 'TimeCreated';
  $timeText = '';
  if ($null -ne $time) { $timeText = ([DateTime]$time).ToString('o'); }
  # Nem .Message, .Properties, .ToXml ou UserData são lidos. Mensagens de
  # impressão podem conter documentos/clientes; eventos de serviços podem ter
  # linhas de comando. Preservamos apenas metadados estáveis e não transacionais.
  return (New-Object PSObject -Property @{
    RecordId = [long](Get-PdvCollectionValue $Event 'RecordId' 0);
    TimeCreated = $timeText; Provider = [string](Get-PdvCollectionValue $Event 'ProviderName' '');
    Id = [int](Get-PdvCollectionValue $Event 'Id' 0);
    Level = Get-PdvCollectionValue $Event 'Level'; Channel = $Channel;
    Message = 'Conteúdo omitido; somente metadados técnicos do evento.';
    MessageOmitted = $true; MessageTruncated = $false;
  });
}

function Get-PdvMonitorWindowsEvents {
  [CmdletBinding()]
  param([hashtable]$Cursors = @{}, [ValidateRange(1, 100)][int]$MaxEventsPerChannel = 100, [DateTime]$StartAfter = [DateTime]::MinValue);
  $channels = @('System', 'Microsoft-Windows-PrintService/Operational', 'Microsoft-Windows-PrintService/Admin', 'Microsoft-Windows-DriverFrameworks-UserMode/Operational', 'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-DeviceSetupManager/Admin', 'Microsoft-Windows-USB-USBHUB3/Operational', 'Microsoft-Windows-USB-UCX/Operational');
  $warnings = New-Object 'System.Collections.Generic.List[string]';
  $events = New-Object 'System.Collections.Generic.List[object]';
  $statuses = New-Object 'System.Collections.Generic.List[object]';
  $nextCursors = @{};
  foreach ($key in $Cursors.Keys) { $nextCursors[$key] = $Cursors[$key]; }
  if ($StartAfter -eq [DateTime]::MinValue) { $StartAfter = (Get-Date).AddMinutes(-2); }
  foreach ($channel in $channels) {
    $status = New-Object PSObject -Property @{
      Channel = $channel; Enabled = $false; Success = $false; Truncated = $false;
      Gap = $false; Reset = $false; Baseline = $false; CoverageStart = '';
      OldestRecordId = 0L; NewestRecordId = 0L; CursorRecordId = 0L; Error = '';
    };
    try {
      $logs = @(Get-WinEvent -ListLog $channel -ErrorAction Stop);
      if ($logs.Count -ne 1) { throw 'Canal indisponível.'; }
      if (-not [bool](Get-PdvCollectionValue $logs[0] 'IsEnabled' $false)) {
        $status.Error = 'Canal desabilitado; o monitor não o habilita.';
        $statuses.Add($status); continue;
      }
      $status.Enabled = $true;
      $tail = @(Read-PdvMonitorEventQuery -Channel $channel -MaxEvents 1);
      $head = @(Read-PdvMonitorEventQuery -Channel $channel -MaxEvents 1 -Oldest);
      $newestId = 0L; $oldestId = 0L; $anchorTime = '';
      if ($tail.Count -gt 0) {
        $newestId = [long]$tail[0].RecordId;
        $anchorTime = [string](ConvertTo-PdvMonitorEvent $tail[0] $channel).TimeCreated;
      }
      if ($head.Count -gt 0) { $oldestId = [long]$head[0].RecordId; }
      $status.OldestRecordId = $oldestId; $status.NewestRecordId = $newestId;
      $previous = $Cursors[$channel]; $afterId = 0L;
      $epoch = [Guid]::NewGuid().ToString('N'); $coverageStart = '';
      if ($null -ne $previous) {
        $afterId = [long](Get-PdvCollectionValue $previous 'RecordId' 0);
        $epoch = [string](Get-PdvCollectionValue $previous 'LogEpoch' $epoch);
        $coverageStart = [string](Get-PdvCollectionValue $previous 'CoverageStart' '');
        $oldAnchorId = [long](Get-PdvCollectionValue $previous 'AnchorRecordId' $afterId);
        $oldAnchorTime = [string](Get-PdvCollectionValue $previous 'AnchorTime' '');
        if ($newestId -lt $afterId -or $newestId -lt $oldAnchorId) { $status.Reset = $true; }
        elseif ($oldAnchorId -gt 0 -and $oldAnchorTime -and $oldestId -le $oldAnchorId) {
          $anchor = @(Read-PdvMonitorEventQuery -Channel $channel -XPath ('*[System[EventRecordID=' + $oldAnchorId + ']]') -MaxEvents 1);
          if ($anchor.Count -eq 0 -or [string](ConvertTo-PdvMonitorEvent $anchor[0] $channel).TimeCreated -ne $oldAnchorTime) { $status.Reset = $true; }
        }
        if ($status.Reset) {
          $status.Gap = $true; $afterId = 0L; $epoch = [Guid]::NewGuid().ToString('N');
          $warnings.Add('Canal ' + $channel + ': sequência reiniciada/limpa; retomada dos registros ainda disponíveis.');
        } elseif ($afterId -gt 0 -and $oldestId -gt ($afterId + 1)) {
          $status.Gap = $true;
          $warnings.Add('Canal ' + $channel + ': registros anteriores ao cursor já não estão disponíveis (rotação/limpeza).');
        }
      } else {
        $status.Baseline = $true;
        $coverageStart = $StartAfter.ToUniversalTime().ToString('o');
      }
      $status.CoverageStart = $coverageStart;
      $conditions = 'EventRecordID > ' + $afterId + ' and EventRecordID <= ' + $newestId;
      if ($status.Baseline) { $conditions += " and TimeCreated[@SystemTime >= '" + $StartAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + "']"; }
      $range = '*[System[' + $conditions + ']]';
      $xpath = $range; $queryXml = '';
      if ($channel -eq 'System') {
        $terms = @(Get-PdvMonitorSystemEventXPath);
        # Seleções estruturadas: cada XPath fica abaixo do limite de 20
        # expressões do Windows Event Log. Os três provedores são disjuntos.
        $selects = @($terms | ForEach-Object {
          '<Select Path="System">' + [Security.SecurityElement]::Escape(('*[System[' + $conditions + '] and ' + $_ + ']')) + '</Select>';
        });
        $queryXml = '<QueryList><Query Id="0" Path="System">' + ($selects -join '') + '</Query></QueryList>';
        $xpath = '';
      }
      $batch = @();
      if ($newestId -gt $afterId) { $batch = @(Read-PdvMonitorEventQuery -Channel $channel -XPath $xpath -FilterXml $queryXml -MaxEvents $MaxEventsPerChannel -Oldest); }
      $batch = @($batch | Sort-Object RecordId);
      $converted = @($batch | ForEach-Object { ConvertTo-PdvMonitorEvent $_ $channel });
      $cursorId = $newestId;
      if ($batch.Count -ge $MaxEventsPerChannel) {
        $status.Truncated = $true; $cursorId = [long]$batch[$batch.Count - 1].RecordId;
      }
      # Publica somente depois da consulta E transformação completas. Se falhar,
      # cursor anterior e nenhum evento deste canal são devolvidos.
      foreach ($entry in $converted) { $events.Add($entry); }
      $nextCursors[$channel] = New-Object PSObject -Property @{
        RecordId = $cursorId; AnchorRecordId = $newestId; AnchorTime = $anchorTime;
        OldestRecordId = $oldestId; LogEpoch = $epoch; CoverageStart = $coverageStart;
      };
      $status.CursorRecordId = $cursorId; $status.Success = $true;
    } catch {
      $status.Error = 'Consulta indisponível; cursor preservado.';
      # Não replica Exception.Message: provedores podem anexar payload ao erro.
      $warnings.Add('Canal ' + $channel + ': consulta indisponível; cursor preservado.');
    }
    $statuses.Add($status);
  }
  return (New-Object PSObject -Property @{
    Events = @($events.ToArray()); Cursors = $nextCursors;
    Warnings = @($warnings.ToArray()); ChannelStatus = @($statuses.ToArray());
  });
}

Export-ModuleMember -Function Get-PdvMonitorSnapshot, Get-PdvMonitorWindowsEvents;
