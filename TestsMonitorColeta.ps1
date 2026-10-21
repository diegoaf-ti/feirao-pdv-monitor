#requires -Version 5.1
# Testes sem hardware, sem mensagens de eventos e sem consultas reais.
$ErrorActionPreference = 'Stop';
Import-Module (Join-Path $PSScriptRoot 'PdvMonitor.Coleta.psm1') -Force;
$module = Get-Module PdvMonitor.Coleta;
& $module {
  $script:coletaChecks = 0;
  function Assert-Coleta($Condition, [string]$Description) { $script:coletaChecks++; if (-not $Condition) { throw $Description; } }
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
    param([long]$RecordId, [DateTime]$Time, [string]$Provider = 'Microsoft-Windows-Kernel-PnP', [string]$Service = '', [int]$Id = 219, [int]$Level = 2);
    $event = New-Object PSObject -Property @{ RecordId = $RecordId; TimeCreated = $Time; ProviderName = $Provider; Id = $Id; Level = $Level; Service = $Service };
    $event | Add-Member -MemberType ScriptProperty -Name Message -Value { throw 'Teste detectou leitura indevida de mensagem sensível.'; };
    $event | Add-Member -MemberType ScriptProperty -Name Properties -Value { throw 'Teste detectou leitura indevida de payload sensível.'; };
    $event | Add-Member -MemberType ScriptProperty -Name UserData -Value { throw 'Teste detectou leitura indevida de UserData.'; };
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { throw 'Teste detectou leitura indevida de XML bruto.'; };
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
        $eventXml = [xml]('<Event><System><Provider Name="' + [Security.SecurityElement]::Escape($_.ProviderName) + '"/><EventID>' + $_.Id + '</EventID><Level>' + $_.Level + '</Level><EventRecordID>' + $_.RecordId + '</EventRecordID><TimeCreated SystemTime="' + $timeText + '"/></System><EventData><Data>' + [Security.SecurityElement]::Escape($_.Service) + '</Data></EventData></Event>');
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
  # Serviço Nerus: somente nomes exatos fornecidos pelo vínculo, eventos de
  # falha conhecidos e metadados; nunca texto livre ou payload do SCM.
  $script:printEnabled = $false;
  $failureIds = @(7000,7001,7009,7011,7022,7023,7024,7031,7032,7034,7043);
  $script:history = @(); $record = 0;
  foreach ($id in $failureIds) { $record++; $script:history += New-TestEvent $record $now 'Service Control Manager' 'NerusService' $id; }
  $script:history += New-TestEvent 12 $now 'Service Control Manager' 'Nerus Service Fiscal' 7031 1;
  $script:history += New-TestEvent 13 $now 'Service Control Manager' 'OutroServico' 7031;
  $script:history += New-TestEvent 14 $now 'Service Control Manager' 'NerusServiceAuxiliar' 7031;
  $script:history += New-TestEvent 15 $now 'Service Control Manager' 'NerusService' 7036;
  $script:history += New-TestEvent 16 $now 'Service Control Manager' 'NerusService' 7045;
  $script:history += New-TestEvent 17 $now 'Service Control Manager' 'NerusService' 7031 4;
  $script:history += New-TestEvent 18 $now 'Outro.Provedor' 'NerusService' 7031;
  $script:history += New-TestEvent 19 $now 'Service Control Manager' 'NerusService' 219;
  $withoutNerus = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2);
  Assert-Coleta ($withoutNerus.Events.Count -eq 0) 'Sem vínculo não descobre Nerus por substring nem coleta SCM geral';
  $service = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2) -NerusServiceNames @('NerusService','Nerus Service Fiscal');
  Assert-Coleta ($service.Events.Count -eq 12 -and ($service.Events.RecordId -join ',') -eq '1,2,3,4,5,6,7,8,9,10,11,12') 'SCM aceita todos os IDs de falha previstos e ambos os nomes vinculados, exclui rotina/outros serviços/provedores';
  Assert-Coleta ($service.Cursors['System'].RecordId -eq 19) 'Eventos SCM excluídos continuam respeitando o cursor geral do canal';
  Assert-Coleta (@($service.Events | Where-Object { -not $_.MessageOmitted -or $_.Message -ne 'Conteúdo omitido; somente metadados técnicos do evento.' }).Count -eq 0) 'Falhas do serviço não leem Message, Properties, UserData ou ToXml';
  Assert-Coleta (@($service.Events[0].PSObject.Properties.Name | Where-Object { $_ -in @('Service','ServiceName','Properties','UserData') }).Count -eq 0) 'Eventos enviados não incorporam payload nem nome livre do serviço';
  [xml]$serviceXml = $script:queryXml;
  Assert-Coleta (@($serviceXml.QueryList.Query.Select).Count -eq 7) 'Dois nomes usam quatro seleções adicionais separadas e limitadas';
  foreach ($select in @($serviceXml.QueryList.Query.Select)) {
    $predicates = @([regex]::Matches($select.InnerText, 'EventRecordID|@SystemTime|Level=|Provider\[|EventID=|Data='));
    Assert-Coleta ($predicates.Count -le 20) 'Cada seleção permanece abaixo de vinte expressões, incluindo baseline e intervalo';
  }
  $deduplicated = @(Get-PdvMonitorSystemEventXPath -NerusServiceNames @('NerusService','NerusService'));
  Assert-Coleta ($deduplicated.Count -eq 5) 'Nomes duplicados exatos não multiplicam seleções';
  $quotedNames = @("Nerus O'Brien",'Nerus "Fiscal"','Nerus & Fiscal',"Nerus' or 1=1 or Data='",'Nerus*');
  foreach ($name in $quotedNames) {
    $script:history = @(New-TestEvent 1 $now 'Service Control Manager' $name 7031; New-TestEvent 2 $now 'Service Control Manager' 'OutroServico' 7031; New-TestEvent 3 $now 'Service Control Manager' 'NerusService' 7031);
    $quoted = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2) -NerusServiceNames @($name);
    Assert-Coleta ($quoted.Events.Count -eq 1 -and $quoted.Events[0].RecordId -eq 1) 'Nome com aspas, XML, tentativa de injeção ou curinga só corresponde ao literal exato';
    Assert-Coleta ($quoted.Cursors['System'].RecordId -eq 3) 'Literal seguro não altera semântica de avanço do cursor';
  }
  $invalidNames = @(@(''), @(' NerusService'), @('NerusService '), @("Nerus`r`nService"), @("Nerus`0Service"), @('Nerus' + [char]0x85 + 'Service'), @('Nerus "Fiscal' + "'"), @(('N' * 257)), @(1..9 | ForEach-Object { 'Nerus' + $_ }));
  foreach ($invalid in $invalidNames) {
    $beforeCalls = $script:queryCalls; $rejected = $false; $errorText = '';
    try { $null = Get-PdvMonitorWindowsEvents -Cursors $service.Cursors -StartAfter $now.AddMinutes(-2) -NerusServiceNames $invalid; }
    catch { $rejected = $true; $errorText = [string]$_.Exception.Message; }
    Assert-Coleta ($rejected -and $errorText -eq 'InvalidNerusServiceNames') 'Nomes inválidos são rejeitados com mensagem fixa sem ecoar entrada';
    Assert-Coleta ($beforeCalls -eq $script:queryCalls -and $service.Cursors['System'].RecordId -eq 19) 'Validação ocorre antes da consulta e não altera cursor de entrada';
  }
  $script:history = @(New-TestEvent 1 $now 'Service Control Manager' 'Nerus1' 7031);
  $maximum = Get-PdvMonitorWindowsEvents -StartAfter $now.AddMinutes(-2) -NerusServiceNames @(1..8 | ForEach-Object { 'Nerus' + $_ });
  [xml]$maximumXml = $script:queryXml;
  Assert-Coleta ($maximum.Events.Count -eq 1 -and @($maximumXml.QueryList.Query.Select).Count -eq 19) 'Lista máxima gera seleções pequenas e mantém correspondência exata';
  Write-Host ('PASS: ' + $script:coletaChecks + ' verificações de coleta, fallback, cursores e eventos SCM Nerus com nomes exatos. Mocks; não valida PowerShell 2/5.1, Event Log nativo nem hardware.');
};
