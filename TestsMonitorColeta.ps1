#requires -Version 5.1
# Testes sem hardware, sem mensagens de eventos e sem consultas reais.
$ErrorActionPreference = 'Stop';
Import-Module (Join-Path $PSScriptRoot 'PdvMonitor.Coleta.psm1') -Force;
$module = Get-Module PdvMonitor.Coleta;
& $module {
  function Assert-Coleta($Condition, [string]$Description) { if (-not $Condition) { throw $Description; } }
  function New-TestSnapshot {
    New-Object PSObject -Property @{
      CapturedAt = '2026-10-15T12:00:00Z'; Windows = 'Windows 7';
      Devices = @((New-Object PSObject -Property @{ InstanceId = 'USB\PINPAD\001'; Name = 'Pinpad'; Class = 'Ports'; Port = 'COM4'; Status = 'OK'; ProblemCode = 0; Present = $true }));
      Printers = @(); ReservedPorts = @('COM4'); Warnings = @(); InventoryComplete = $false;
    };
  }
  $converted = ConvertTo-PdvMonitorSnapshot (New-TestSnapshot) 'WMI-Legado';
  Assert-Coleta (-not $converted.Devices[0].PresenceKnown -and -not $converted.Devices[0].Present) 'Status OK e Present sem confirmação não provam presença';
  Assert-Coleta (-not $converted.InventoryComplete) 'Preserva inventário incompleto';
  Assert-Coleta ($converted.Windows.Caption -eq 'Windows 7') 'Normaliza Windows legado';
  Assert-Coleta (@($converted.Devices[0].HardwareIds).Count -eq 0) 'HardwareIds ausentes viram lista vazia';
  function Get-PdvMonitorPlatform { New-Object PSObject -Property @{ Major = 6; Build = 7601; PowerShellMajor = 2; PowerShellMinor = 0 }; }
  function Get-PdvLegacySnapshot { New-TestSnapshot; }
  $legacy = Get-PdvMonitorSnapshot;
  Assert-Coleta ($legacy.InventoryMode -eq 'WMI-Legado') 'Win7/PS2 não carrega módulo moderno';
  function Get-PdvMonitorPlatform { New-Object PSObject -Property @{ Major = 10; Build = 19045; PowerShellMajor = 5; PowerShellMinor = 1 }; }
  function Get-PnpDevice { throw 'Mock nunca deve ser consultado diretamente.'; }
  function Import-Module { param($Name, [switch]$Force) }
  function Get-PdvSnapshot { throw 'Falha moderna simulada.'; }
  $fallback = Get-PdvMonitorSnapshot;
  Assert-Coleta ($fallback.InventoryMode -eq 'WMI-Legado') 'Falha moderna recorre ao legado';
  Assert-Coleta (($fallback.Warnings -join '') -like '*moderna falhou*') 'Fallback informa falha';
  function Get-PdvSnapshot {
    $snapshot = New-TestSnapshot;
    $snapshot.InventoryComplete = $true;
    $snapshot.Devices[0] | Add-Member -NotePropertyName PresenceKnown -NotePropertyValue $true;
    $snapshot;
  }
  $modern = Get-PdvMonitorSnapshot;
  Assert-Coleta ($modern.InventoryMode -eq 'PnP' -and $modern.InventoryComplete -and $modern.Devices[0].Present) 'Coleta moderna preserva presença conhecida/completude';

  function New-TestEvent {
    param([long]$RecordId, [DateTime]$Time, [string]$Provider = 'Microsoft-Windows-Kernel-PnP', [string]$Service = '');
    $event = New-Object PSObject -Property @{ RecordId = $RecordId; TimeCreated = $Time; ProviderName = $Provider; Id = 219; Level = 3; Service = $Service };
    $event | Add-Member -MemberType ScriptProperty -Name Message -Value { throw 'Teste detectou leitura indevida de mensagem sensível.'; };
    $event | Add-Member -MemberType ScriptProperty -Name Properties -Value { throw 'Teste detectou leitura indevida de payload sensível.'; };
    return $event;
  }
  $script:history = @(); $script:failQuery = $false; $script:queryCalls = 0;
  $script:queryXml = ''; $script:printEnabled = $false;
  function Get-WinEvent {
    [CmdletBinding()]
    param([string]$ListLog, [string]$LogName, [string]$FilterXPath, [xml]$FilterXml, [long]$MaxEvents, [switch]$Oldest);
    if ($ListLog) { return (New-Object PSObject -Property @{ IsEnabled = ($ListLog -eq 'System' -or ($script:printEnabled -and $ListLog -eq 'Microsoft-Windows-PrintService/Operational')) }); }
    $script:queryCalls++;
    if ($script:failQuery) { throw 'Mensagem sensível que não deve aparecer no aviso.'; }
    if ($null -ne $FilterXml) { $script:queryXml = $FilterXml.OuterXml; }
    $items = @($script:history);
    if ($FilterXPath -or $null -ne $FilterXml) {
      $selectors = @($FilterXPath);
      if ($null -ne $FilterXml) { $selectors = @($FilterXml.QueryList.Query.Select | ForEach-Object { $_.InnerText }); }
      $items = @($items | Where-Object {
        $timeText = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ');
        $eventXml = [xml]('<Event><System><Provider Name="' + $_.ProviderName + '"/><EventID>' + $_.Id + '</EventID><EventRecordID>' + $_.RecordId + '</EventRecordID><TimeCreated SystemTime="' + $timeText + '"/></System><EventData><Data>' + $_.Service + '</Data></EventData></Event>');
        $selected = $false;
        foreach ($selector in $selectors) {
          # Standard XPath 1.0 só compara números com >= em strings. O Windows
          # trata SystemTime como timestamp; simula aqui só a semântica temporal.
          $effective = $selector;
          $timePass = $true;
          if ($effective -match " and TimeCreated\[@SystemTime >= '([^']+)'\]") {
            $timePass = ($_.TimeCreated -ge [DateTime]$Matches[1]);
            $effective = $effective -replace " and TimeCreated\[@SystemTime >= '[^']+'\]", '';
          }
          if ($timePass -and @($eventXml.SelectNodes($effective)).Count -gt 0) { $selected = $true; }
        }
        $selected;
      });
    }
    if ($Oldest) { $items = @($items | Sort-Object RecordId); }
    else { $items = @($items | Sort-Object RecordId -Descending); }
    if ($items.Count -eq 0) { Write-Error -Message 'none' -ErrorId NoMatchingEventsFound -Category ObjectNotFound; return; }
    return @($items | Select-Object -First $MaxEvents);
  }
  $now = [DateTime]'2026-10-15T12:00:00Z';
  $script:history = @(1..205 | ForEach-Object { New-TestEvent $_ $now });
  $first = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2);
  $firstStatus = @($first.ChannelStatus | Where-Object Channel -eq 'System')[0];
  Assert-Coleta ($first.Events.Count -eq 100 -and $first.Events[0].RecordId -eq 1 -and $first.Events[99].RecordId -eq 100) 'Backlog vem do mais antigo primeiro, limitado a 100';
  Assert-Coleta ($firstStatus.Truncated -and $firstStatus.Baseline -and $firstStatus.CoverageStart) 'Baseline e limite ficam explícitos';
  Assert-Coleta ($first.Cursors['System'].RecordId -eq 100) 'Cursor não pula backlog';
  Assert-Coleta ($script:queryXml -like '*Service Control Manager*' -and $script:queryXml -like '*Spooler*') 'System usa provedores e serviços limitados';
  $second = Get-PdvMonitorWindowsEvents -Cursors $first.Cursors;
  Assert-Coleta ($second.Events.Count -eq 100 -and $second.Events[0].RecordId -eq 101 -and $second.Events[99].RecordId -eq 200) 'Segunda rodada continua backlog';
  Assert-Coleta ($first.Cursors['System'].RecordId -eq 100) 'Cursors de entrada não sofrem mutação';
  $third = Get-PdvMonitorWindowsEvents -Cursors $second.Cursors;
  Assert-Coleta ($third.Events.Count -eq 5 -and $third.Cursors['System'].RecordId -eq 205) 'Última rodada conclui backlog';
  $idle = Get-PdvMonitorWindowsEvents -Cursors $third.Cursors;
  Assert-Coleta ($idle.Events.Count -eq 0 -and $idle.Cursors['System'].RecordId -eq 205) 'Rodada sem eventos preserva posição';
  $script:history = @($script:history) + @(New-TestEvent 206 $now 'Outro.Provedor'; New-TestEvent 207 $now 'Service Control Manager' 'Outro serviço'; New-TestEvent 208 $now 'Service Control Manager' 'Spooler');
  $filtered = Get-PdvMonitorWindowsEvents -Cursors $third.Cursors;
  Assert-Coleta ($filtered.Events.Count -eq 1 -and $filtered.Events[0].RecordId -eq 208) 'Ignora provedores gerais e SCM não relacionado';
  Assert-Coleta ($filtered.Events[0].MessageOmitted -and $filtered.Events[0].Message.Length -lt 2000) 'Eventos só contêm metadados, sem payload';
  $script:failQuery = $true;
  $failure = Get-PdvMonitorWindowsEvents -Cursors $filtered.Cursors;
  Assert-Coleta ($failure.Events.Count -eq 0 -and $failure.Cursors['System'].RecordId -eq 208) 'Falha de consulta não avança cursor';
  Assert-Coleta (($failure.Warnings -join '') -notlike '*sensível*') 'Erros brutos não vazam no diagnóstico';
  $script:failQuery = $false;
  $script:history = @(New-TestEvent 1 $now.AddMinutes(1); New-TestEvent 2 $now.AddMinutes(1));
  $reset = Get-PdvMonitorWindowsEvents -Cursors $filtered.Cursors;
  $resetStatus = @($reset.ChannelStatus | Where-Object Channel -eq 'System')[0];
  Assert-Coleta ($resetStatus.Reset -and $resetStatus.Gap -and $reset.Events.Count -eq 2 -and $reset.Cursors['System'].RecordId -eq 2) 'Limpeza/reinício do log reinicia sequência';
  $script:history = @(1..250 | ForEach-Object { New-TestEvent $_ $now.AddMinutes(2) });
  $reused = Get-PdvMonitorWindowsEvents -Cursors $filtered.Cursors;
  $reusedStatus = @($reused.ChannelStatus | Where-Object Channel -eq 'System')[0];
  Assert-Coleta ($reusedStatus.Reset -and $reused.Events[0].RecordId -eq 1) 'Anchor temporal reconhece limpeza mesmo com RecordId reutilizado e tail maior';
  $script:history = @(220..250 | ForEach-Object { New-TestEvent $_ $now });
  $rotated = Get-PdvMonitorWindowsEvents -Cursors $filtered.Cursors;
  $rotatedStatus = @($rotated.ChannelStatus | Where-Object Channel -eq 'System')[0];
  Assert-Coleta ($rotatedStatus.Gap -and -not $rotatedStatus.Reset -and $rotated.Events.Count -eq 31) 'Rotação registra lacuna e coleta registros restantes';
  $script:history = @(New-TestEvent 1 $now.AddHours(-1); New-TestEvent 2 $now);
  $baseline = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2);
  Assert-Coleta ($baseline.Events.Count -eq 1 -and $baseline.Events[0].RecordId -eq 2) 'Primeira execução limita cobertura aos últimos dois minutos';
  $script:printEnabled = $true;
  $print = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2);
  Assert-Coleta (@($print.Events | Where-Object Channel -eq 'Microsoft-Windows-PrintService/Operational').Count -eq 1) 'Coleta canal de impressão já habilitado sem mensagem';
  Assert-Coleta (@($print.ChannelStatus | Where-Object { -not $_.Enabled -and $_.Success }).Count -eq 0) 'Canais desabilitados não são habilitados nem tratados como sucesso';
  $script:history = @();
  $cleared = Get-PdvMonitorWindowsEvents -Cursors $baseline.Cursors;
  Assert-Coleta ($cleared.Cursors['System'].RecordId -eq 0 -and @($cleared.ChannelStatus | Where-Object Channel -eq 'System')[0].Reset) 'Log limpo e vazio reconhecido';
  Write-Host 'PASS: coleta, fallback Win7/10, presença/completude, baseline, cursor sem perda, filtros, falhas, rotação e limpeza. Mocks; não valida PowerShell 2/5.1, Event Log nativo nem hardware.';
};
