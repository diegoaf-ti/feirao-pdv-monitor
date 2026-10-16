# Integração offline do runtime. Não usa PnP, WMI, processos, DPAPI ou HTTP reais.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$moduleDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDirectory 'PdvMonitor.Runtime.psm1') -Force
$module = Get-Module PdvMonitor.Runtime
$script:assertions = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdv-runtime-testes-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

& $module {
  $script:TestNow = [DateTimeOffset]::Parse('2026-10-15T12:00:00-03:00')
  $script:TestRecords = New-Object 'Collections.Generic.List[object]'
  $script:TestSnapshots = New-Object Collections.Queue
  $script:TestProcessBatches = New-Object Collections.Queue
  $script:TestPrintBatches = New-Object Collections.Queue
  $script:TestDefaultSnapshot = $null
  $script:TestProcessNames = @()
  $script:TestJobCount = 0
  $script:TestProcessCalls = 0
  $script:TestPrintCalls = 0
  $script:TestRestarts = 0
  $script:TestUploadCalls = 0
  $script:TestUploadResults = New-Object Collections.Queue
  $script:TestUploadThrow = $false
  $script:TestQueueFailure = $false
  $script:TestProcessFailure = $false
  $script:TestPrintFailure = $false
  $script:TestRestartFailure = $false
  $script:TestHistoryFailure = $false
  $script:TestAttemptLogFailure = $false
  $script:TestHistoryPersistedBeforeAction = $false
  $script:TestAttemptLoggedBeforeAction = $false
  $script:RealWriteRecord = (Get-Command Write-PdvMonitorRecord).ScriptBlock
  $script:RealWriteAtomic = (Get-Command Write-PdvRuntimeAtomic).ScriptBlock
  function script:Get-PdvRuntimeNow { return $script:TestNow }
  function script:Initialize-PdvMonitorCentral { param($Session); return (New-Object PSObject -Property @{Success=$true}) }
  function script:Add-PdvMonitorOutboxRecord { param($Session, $Record); $script:TestRecords.Add($Record); return (New-Object PSObject -Property @{Queued=(-not $script:TestQueueFailure)}) }
  function script:Invoke-PdvMonitorUpload {
    param($Session)
    $script:TestUploadCalls++
    if ($script:TestUploadThrow) { throw 'Exceção de transporte simulada; não deve parar coleta' }
    if ($script:TestUploadResults.Count -gt 0) { return $script:TestUploadResults.Dequeue() }
    return (New-Object PSObject -Property @{Success=$true; Reason='OutboxEmpty'; Sent=0})
  }
  function script:Get-PdvMonitorSnapshot {
    if ($script:TestSnapshots.Count -gt 0) { return $script:TestSnapshots.Dequeue() }
    return $script:TestDefaultSnapshot
  }
  function script:Get-PdvMonitorWindowsEvents {
    param($Cursors, $MaxEventsPerChannel)
    return (New-Object PSObject -Property @{Events=@(); Cursors=@{System=@{RecordId=42; AnchorRecordId=42; AnchorTime='2026-10-15T12:00:00-03:00'; OldestRecordId=1; LogEpoch='teste'; CoverageStart='2026-10-15T11:58:00-03:00'}}; ChannelStatus=@(); Warnings=@()})
  }
  function script:Get-Process {
    [CmdletBinding()]param()
    $script:TestProcessCalls++
    if ($script:TestProcessFailure) { throw 'Consulta de processos simulada indisponível' }
    $names = $script:TestProcessNames
    if ($script:TestProcessBatches.Count -gt 0) { $names = $script:TestProcessBatches.Dequeue() }
    foreach ($name in $names) { New-Object PSObject -Property @{ProcessName=$name} }
  }
  function script:Get-WmiObject {
    [CmdletBinding()]param([string]$Class)
    if ($Class -ne 'Win32_PrintJob') { throw 'Consulta WMI inesperada no teste' }
    $script:TestPrintCalls++
    if ($script:TestPrintFailure) { throw 'Consulta de impressão simulada indisponível' }
    $count = $script:TestJobCount
    if ($script:TestPrintBatches.Count -gt 0) { $count = $script:TestPrintBatches.Dequeue() }
    for ($i=0; $i -lt $count; $i++) { New-Object PSObject -Property @{Name='Job de teste'} }
  }
  function script:Write-PdvRuntimeAtomic {
    param([string]$Path, [string]$Text)
    if ($script:TestHistoryFailure -and $Path.EndsWith('recuperacoes.xml')) { throw 'Falha simulada de persistência do histórico' }
    & $script:RealWriteAtomic -Path $Path -Text $Text
  }
  function script:Write-PdvMonitorRecord {
    param($Session, [string]$Kind, [string]$Detail='', $Device=$null, [string]$Role='', [string]$Reason='', $WindowsEvent=$null)
    if ($script:TestAttemptLogFailure -and $Kind -eq 'RecoveryAttempt') { throw 'Falha simulada no log antes da recuperação' }
    & $script:RealWriteRecord -Session $Session -Kind $Kind -Detail $Detail -Device $Device -Role $Role -Reason $Reason -WindowsEvent $WindowsEvent
  }
  function script:Invoke-PdvMonitorRestart {
    param([string]$InstanceId)
    $script:TestRestarts++
    $path = Join-Path $script:TestCurrentSession.DataDirectory 'recuperacoes.xml'
    $history = Read-PdvRuntimeXml $path
    $script:TestHistoryPersistedBeforeAction = ($history.SelectNodes('/recovery/device/attempt').Count -gt 0)
    $script:TestAttemptLoggedBeforeAction = (@($script:TestRecords | Where-Object { $_.Kind -eq 'RecoveryAttempt' -and $_.InstanceId -eq $InstanceId }).Count -gt 0)
    if ($script:TestRestartFailure) { throw 'Reinício simulado recusado' }
    return (New-Object PSObject -Property @{ExitCode=0; RestartRequired=$false})
  }
}

function Assert-Runtime {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw $Name }
  $script:assertions++
}

function New-TestSnapshot {
  param([int]$Problem = 10, [bool]$Complete = $true, [bool]$IncludeDevice = $true, [string]$Port = 'COM4')
  $devices = @()
  if ($IncludeDevice) {
    $devices = @(New-Object PSObject -Property @{InstanceId='USB\PINPAD\001'; Name='Pinpad de teste'; Class='Ports'; Port=$Port; Present=$true; PresenceKnown=$true; Status=$(if($Problem -eq 0){'OK'}else{'Error'}); ProblemCode=$Problem; Manufacturer='Teste'; DriverVersion='1.0'})
  }
  return (New-Object PSObject -Property @{Devices=$devices; InventoryComplete=$Complete; PresenceComplete=$Complete; Warnings=@(); InventoryMode='Simulado'; Printers=@(); ReservedPorts=@(); Windows=(New-Object PSObject -Property @{Build=19045; IsAdministrator=$true; Caption='Windows de teste'})})
}

function New-TestSession {
  param([string]$DataDirectory = '')
  & $module {
    $script:TestRecords.Clear(); $script:TestSnapshots.Clear(); $script:TestProcessBatches.Clear(); $script:TestPrintBatches.Clear()
    $script:TestProcessNames=@(); $script:TestJobCount=0; $script:TestProcessCalls=0; $script:TestPrintCalls=0; $script:TestRestarts=0; $script:TestUploadCalls=0
    $script:TestProcessFailure=$false; $script:TestPrintFailure=$false; $script:TestRestartFailure=$false; $script:TestHistoryFailure=$false; $script:TestAttemptLogFailure=$false
    $script:TestUploadResults.Clear(); $script:TestUploadThrow=$false; $script:TestQueueFailure=$false
    $script:TestHistoryPersistedBeforeAction=$false; $script:TestAttemptLoggedBeforeAction=$false
    $script:TestNow=[DateTimeOffset]::Parse('2026-10-15T12:00:00-03:00')
  }
  if (-not $DataDirectory) { $DataDirectory=Join-Path $testRoot ([Guid]::NewGuid().ToString('N')) }
  $outputs = @(Start-PdvMonitorSession -DataDirectory $DataDirectory)
  Assert-Runtime ($outputs.Count -eq 1) 'Start retorna somente uma sessão, sem vazar retorno de InitializeCentral'
  $session = $outputs[0]
  $snapshot = New-TestSnapshot
  & $module { param($Session,$Snapshot); $script:TestCurrentSession=$Session; $script:TestDefaultSnapshot=$Snapshot } $session $snapshot
  return $session
}

function Add-TestProfile {
  param($Session)
  Save-PdvMonitorProfiles $Session @((New-Object PSObject -Property @{Role='Pinpad'; InstanceId='USB\PINPAD\001'; ExpectedPort='COM4'; RecoveryEnabled=$true}))
}

function Arm-TestSession {
  param($Session)
  Add-TestProfile $Session
  Set-PdvMonitorMaintenance $Session -Minutes 15 -BlockingProcessNames @('Nerus.exe', 'CliSiTef')
}

function Get-TestMetric {
  param([string]$Name)
  return (& $module { param($Name); Get-Variable -Name $Name -ValueOnly -Scope Script } $Name)
}

function Get-TestRecords {
  return (& $module { return ,$script:TestRecords.ToArray() })
}

try {
  $session = New-TestSession
  Add-TestProfile $session
  Invoke-PdvMonitorTick $session
  Assert-Runtime (-not $session.TickBusy -and $session.LastTickAt -and $session.LoggingHealthy) 'Rodada termina e atualiza a mesma sessão'
  Assert-Runtime ((Get-TestMetric 'TestProcessCalls') -eq 0 -and (Get-TestMetric 'TestPrintCalls') -eq 0 -and (Get-TestMetric 'TestRestarts') -eq 0) 'Monitoramento desarmado não consulta processos/fila nem reinicia dispositivos'
  Assert-Runtime ($session.Cursors.System.RecordId -eq 42 -and [IO.File]::Exists((Join-Path $session.DataDirectory 'cursores.xml'))) 'Cursores só avançam após logs locais e persistência'
  $session.SignalDropCount=3; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.LastLoggedSignalDropCount -eq 3 -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'LogGap' -and $_.Detail -like '*sinais descartados*' }).Count -eq 1)) 'Perda de sinais vira LogGap uma vez por aumento do contador'
  $before=$session.Sequence; $session.TickBusy=$true; Invoke-PdvMonitorTick $session; $session.TickBusy=$false
  Assert-Runtime ($session.Sequence -eq $before) 'TickBusy impede rodadas concorrentes'
  Stop-PdvMonitorSession $session; $before=$session.Sequence; Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.Stopped -and $session.Sequence -eq $before -and -not $session.MaintenanceArmed) 'Encerrar desarma e impede novas coletas'

  $session = New-TestSession
  Arm-TestSession $session
  Assert-Runtime ($session.MaintenanceArmed -and $session.Config.BlockingProcessNames -contains 'Nerus' -and $session.MaintenanceExpiresAt -eq ((Get-TestMetric 'TestNow').AddMinutes(15))) 'Arma exatamente 15 minutos e normaliza sufixo exe'
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and $session.RecoveryStates['USB\PINPAD\001'].ConsecutiveFailures -eq 2) 'Duas leituras não autorizam recuperação'
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 1 -and (Get-TestMetric 'TestHistoryPersistedBeforeAction') -and (Get-TestMetric 'TestAttemptLoggedBeforeAction')) 'Três leituras iguais exigem log e histórico persistidos antes da ação'
  Assert-Runtime ($session.RecoveryStates['USB\PINPAD\001'].SessionAttempts -eq 1 -and $session.RecoveryStates['USB\PINPAD\001'].ConsecutiveFailures -eq 0) 'Tentativa consome limite e zera leituras consecutivas'
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 1) 'Cooldown impede repetição imediata mesmo com falha persistente'
  $directory = $session.DataDirectory
  $reopened = New-TestSession $directory
  Assert-Runtime (-not $reopened.MaintenanceArmed -and -not $reopened.Config.AutoRecoveryEnabled -and $reopened.RecoveryStates['USB\PINPAD\001'].Attempts.Count -eq 1) 'Reabrir preserva tentativas e desarma manutenção'
  Set-PdvMonitorMaintenance $reopened -Minutes 15 -BlockingProcessNames @('Nerus', 'CliSiTef')
  Invoke-PdvMonitorTick $reopened; Invoke-PdvMonitorTick $reopened; Invoke-PdvMonitorTick $reopened
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'CooldownActive' }).Count -gt 0)) 'Cooldown persistido continua valendo após reiniciar monitor'

  $session = New-TestSession; Arm-TestSession $session
  Invoke-PdvMonitorTick $session
  & $module { $script:TestDefaultSnapshot.Devices[0].ProblemCode=28 }
  Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.RecoveryStates['USB\PINPAD\001'].ConsecutiveFailures -eq 1 -and (Get-TestMetric 'TestRestarts') -eq 0) 'Mudar código de falha reinicia contagem'
  & $module { $script:TestDefaultSnapshot.Devices[0].Port='COM2' }
  Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.RecoveryStates['USB\PINPAD\001'].ConsecutiveFailures -eq 1 -and (Get-TestMetric 'TestRestarts') -eq 0) 'Mudar porta reinicia contagem e não renumera COM'

  # Revalidações frescas podem bloquear uma decisão inicialmente permitida.
  $session = New-TestSession; Arm-TestSession $session
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  $same=New-TestSnapshot; $changed=New-TestSnapshot 28
  & $module { param($Same,$Changed); $script:TestSnapshots.Enqueue($Same); $script:TestSnapshots.Enqueue($Changed) } $same $changed
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and $session.RecoveryStates['USB\PINPAD\001'].ConsecutiveFailures -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'FailureChangedBeforeRecovery' }).Count -gt 0)) 'Erro diferente na revalidação não herda três leituras anteriores'

  $session = New-TestSession; Arm-TestSession $session
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  & $module { $script:TestProcessBatches.Enqueue(@()); $script:TestProcessBatches.Enqueue(@('Nerus')) }
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'BlockingProcessesRunning' }).Count -gt 0)) 'Processo que aparece na revalidação impede ação'

  $session = New-TestSession; Arm-TestSession $session
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  & $module { $script:TestPrintBatches.Enqueue(0); $script:TestPrintBatches.Enqueue(1) }
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'PendingPrintJobs' }).Count -gt 0)) 'Impressão que aparece na revalidação impede ação'

  $session = New-TestSession; Arm-TestSession $session
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  $same=New-TestSnapshot; $partial=New-TestSnapshot 10 $false
  & $module { param($Same,$Partial); $script:TestSnapshots.Enqueue($Same); $script:TestSnapshots.Enqueue($Partial) } $same $partial
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'IncompleteSnapshot' }).Count -gt 0)) 'Snapshot parcial na revalidação impede ação'

  foreach ($failure in @('TestProcessFailure','TestPrintFailure')) {
    $session = New-TestSession; Arm-TestSession $session
    & $module { param($Name); Set-Variable -Name $Name -Value $true -Scope Script } $failure
    Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
    Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0) 'Falha ao verificar processo ou impressão impede recuperação'
  }
  $session = New-TestSession; Arm-TestSession $session
  & $module { $script:TestAttemptLogFailure=$true }
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and -not $session.MaintenanceArmed -and -not [IO.File]::Exists((Join-Path $session.DataDirectory 'recuperacoes.xml'))) 'Falha no log anterior à ação desarma sem executar nem gravar tentativa'
  $session = New-TestSession; Arm-TestSession $session
  & $module { $script:TestHistoryFailure=$true }
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and -not $session.MaintenanceArmed) 'Falha ao persistir histórico desarma antes de reiniciar dispositivo'
  $session = New-TestSession; Arm-TestSession $session
  & $module { $script:TestRestartFailure=$true }
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 1 -and $session.RecoveryStates['USB\PINPAD\001'].SessionAttempts -eq 1 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'RestartFailed' }).Count -eq 1)) 'Falha do Windows também consome tentativa e fica no log'

  # Leituras incompletas nunca inventam ausência a partir de outra coleta parcial.
  $session=New-TestSession
  $partial=New-TestSnapshot 0 $false; $empty=New-TestSnapshot 0 $true $false
  & $module { param($Partial,$Empty); $script:TestSnapshots.Enqueue($Partial); $script:TestSnapshots.Enqueue($Empty) } $partial $empty
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.HasBaseline -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'DeviceMissing' }).Count -eq 0)) 'Coleta parcial antes da primeira completa não gera remoção falsa'
  $present=New-TestSnapshot 0; $partialEmpty=New-TestSnapshot 0 $false $false
  & $module { param($Present,$PartialEmpty,$Empty); $script:TestSnapshots.Enqueue($Present); $script:TestSnapshots.Enqueue($PartialEmpty); $script:TestSnapshots.Enqueue($Empty) } $present $partialEmpty $empty
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((@(Get-TestRecords | Where-Object { $_.Kind -eq 'DeviceMissing' }).Count -eq 0)) 'Rodada incompleta não informa remoção de dispositivo antes enumerado'
  Invoke-PdvMonitorTick $session
  Assert-Runtime ((@(Get-TestRecords | Where-Object { $_.Kind -eq 'DeviceMissing' }).Count -eq 1)) 'Somente duas bases completas permitem registrar remoção'

  # Perfis são normalizados e alterações rejeitadas não substituem referências.
  $session=New-TestSession
  Save-PdvMonitorProfiles $session @(@{Role=' Pinpad ';InstanceId=' USB\PINPAD\001 ';ExpectedPort=' com4 ';RecoveryEnabled='true'})
  Assert-Runtime ($session.Config.Profiles[0].Role -eq 'Pinpad' -and $session.Config.Profiles[0].InstanceId -eq 'USB\PINPAD\001' -and $session.Config.Profiles[0].ExpectedPort -eq 'COM4' -and -not $session.Config.Profiles[0].RecoveryEnabled) 'Normaliza perfil e não interpreta string true como autorização'
  foreach ($profiles in @(@(@{Role=' ';InstanceId='USB\A';ExpectedPort='COM4'}), @(@{Role='Pinpad';InstanceId='USB\*';ExpectedPort='COM4'}), @(@{Role='Pinpad';InstanceId='USB\A';ExpectedPort='COM4097'}), @(@{Role='Pinpad';InstanceId='USB\A';ExpectedPort='COM4'},@{Role='pinpad';InstanceId='USB\B';ExpectedPort='COM5'}), @(@{Role='A';InstanceId='USB\A';ExpectedPort='COM4'},@{Role='B';InstanceId='usb\a';ExpectedPort='COM5'}))) {
    $threw=$false; try { Save-PdvMonitorProfiles $session -Profiles $profiles } catch { $threw=$true }
    Assert-Runtime ($threw -and $session.Config.Profiles[0].InstanceId -eq 'USB\PINPAD\001') 'Perfil inválido ou duplicado mantém configuração anterior'
  }
  Add-TestProfile $session; Set-PdvMonitorMaintenance $session -Minutes 15 -BlockingProcessNames @('Nerus','CliSiTef')
  Save-PdvMonitorProfiles $session @()
  Assert-Runtime ($session.Config.Profiles.Count -eq 0 -and -not $session.MaintenanceArmed) 'Remover último perfil desarma e salva coleção vazia'
  foreach ($minutes in @(-1,16)) { $threw=$false; try { Set-PdvMonitorMaintenance $session -Minutes $minutes -BlockingProcessNames @('Nerus') } catch { $threw=$true }; Assert-Runtime $threw 'Recusa janela fora de 0..15 minutos' }
  $session=New-TestSession; Arm-TestSession $session; Set-PdvMonitorMaintenance $session -Minutes 0
  Assert-Runtime (-not $session.MaintenanceArmed -and $null -eq $session.MaintenanceExpiresAt -and -not $session.Config.AutoRecoveryEnabled) 'Janela zero desarma imediatamente'
  Arm-TestSession $session
  & $module { $script:TestNow=$script:TestNow.AddMinutes(15) }
  Invoke-PdvMonitorTick $session
  Assert-Runtime (-not $session.MaintenanceArmed -and (Get-TestMetric 'TestRestarts') -eq 0) 'Expiração automática desarma antes de avaliar dispositivo'

  $session=New-TestSession
  [IO.File]::WriteAllText((Join-Path $session.DataDirectory 'recuperacoes.xml'), '<unexpected/>')
  $reopened=New-TestSession $session.DataDirectory
  Assert-Runtime (-not $reopened.RecoveryHistoryHealthy -and -not $reopened.MaintenanceArmed) 'Histórico XML com formato inesperado bloqueia recuperação sem parar coleta'

  $session=New-TestSession
  $history='<recovery><device id="USB\PINPAD\001"><attempt>2026-10-15T11:10:00-03:00</attempt><attempt>2026-10-15T11:40:00-03:00</attempt></device></recovery>'
  [IO.File]::WriteAllText((Join-Path $session.DataDirectory 'recuperacoes.xml'),$history)
  $reopened=New-TestSession $session.DataDirectory
  # Sessão original não tinha perfil; salvar referência mantém o histórico.
  Add-TestProfile $reopened
  Set-PdvMonitorMaintenance $reopened -Minutes 15 -BlockingProcessNames @('Nerus','CliSiTef')
  Invoke-PdvMonitorTick $reopened; Invoke-PdvMonitorTick $reopened; Invoke-PdvMonitorTick $reopened
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 0 -and (@(Get-TestRecords | Where-Object { $_.Reason -eq 'HourlyAttemptLimit' }).Count -gt 0)) 'Duas tentativas persistidas na última hora bloqueiam nova ação'
  & $module { $script:TestNow=$script:TestNow.AddMinutes(11) }
  Invoke-PdvMonitorTick $reopened
  Assert-Runtime ((Get-TestMetric 'TestRestarts') -eq 1 -and $reopened.RecoveryStates['USB\PINPAD\001'].Attempts.Count -eq 2) 'Janela móvel expira apenas a tentativa com mais de uma hora'

  # Rotação e retenção trabalham apenas em logs, sem apagar fila de envio.
  $session=New-TestSession
  $oldLog=$session.LogPath
  $stream=[IO.File]::OpenWrite($oldLog); try { $stream.SetLength(5MB) } finally { $stream.Close() }
  & $module { param($Session); Write-PdvMonitorRecord $Session 'TestRotation' 'Nova parte do CSV' } $session
  Assert-Runtime ($session.LogPath -ne $oldLog -and [IO.File]::Exists($oldLog) -and ([IO.File]::ReadAllLines($session.LogPath)[0] -like '*EventId*')) 'Log de 5 MB roda para CSV novo com cabeçalho'
  $expired=Join-Path $session.LogDirectory 'monitor-expired.csv'; [IO.File]::WriteAllText($expired,'antigo'); [IO.File]::SetLastWriteTimeUtc($expired,[DateTime]::UtcNow.AddDays(-31))
  $oversized=Join-Path $session.LogDirectory 'monitor-oversized.csv'; $stream=[IO.File]::OpenWrite($oversized); try { $stream.SetLength(101MB) } finally { $stream.Close() }; [IO.File]::SetLastWriteTimeUtc($oversized,[DateTime]::UtcNow.AddDays(-1))
  & $module { param($Session); Remove-PdvMonitorOldLogs $Session } $session
  Assert-Runtime (-not [IO.File]::Exists($expired) -and -not [IO.File]::Exists($oversized) -and [IO.File]::Exists($session.LogPath)) 'Retenção remove antigos/excesso e preserva log ativo'
  [IO.File]::WriteAllText((Join-Path $session.DataDirectory 'central-credencial.bin'), 'FAKE-SECRET-MUST-NOT-EXPORT')
  [void][IO.Directory]::CreateDirectory((Join-Path $session.DataDirectory 'outbox'))
  [IO.File]::WriteAllText((Join-Path $session.DataDirectory 'outbox/pending.xml'), 'FAKE-OUTBOX-MUST-NOT-EXPORT')
  $destination=Export-PdvMonitorLogs $session $testRoot
  $exported=[IO.Directory]::GetFiles($destination,'*',[IO.SearchOption]::AllDirectories)
  Assert-Runtime (-not [IO.File]::Exists((Join-Path $destination 'central-credencial.bin')) -and -not [IO.Directory]::Exists((Join-Path $destination 'outbox')) -and $exported.Count -gt 0) 'Exportação inclui só lista permitida de logs/configurações, sem credencial nem fila'
  foreach ($path in $exported) { Assert-Runtime ([IO.File]::ReadAllText($path) -notmatch 'FAKE-SECRET-MUST-NOT-EXPORT|FAKE-OUTBOX-MUST-NOT-EXPORT') 'Nenhum arquivo exportado contém credencial ou payload da fila' }

  # O contrato é aplicado à cópia do log, sem mudar a evidência usada na política.
  $session=New-TestSession
  $device=New-Object PSObject -Property @{InstanceId=('USB\' + ('X' * 1100)); Name=('á' * 300); Port='COM4'; Present=$true; PresenceKnown=$false; Status=('Erro de driver ' + ('ç' * 140)); ProblemCode='CM_PROB_NONE'}
  $event=New-Object PSObject -Property @{Channel='Microsoft-Windows-USB-USBHUB3/Operational'; RecordId='18446744073709551615'; Provider=("Driver ação `"teste`"\linha1`r`n" + ('β' * 200)); Id=65535}
  $detail="Primeira linha`r`nSegunda linha`t" + [char]0 + [char]7 + [char]127 + [char]133 + ('texto ç ' * 500)
  & $module { param($Session,$Device,$Event,$Detail); Write-PdvMonitorRecord $Session 'DeviceChanged' $Detail $Device ('P' * 90) ('R' * 300) $Event } $session $device $event $detail
  $records=@(Get-TestRecords); $record=$records[$records.Count-1]
  Assert-Runtime ($record.ProblemCode -eq '' -and $record.Detail -like '*ProblemCode original=CM_PROB_NONE*' -and $device.ProblemCode -eq 'CM_PROB_NONE') 'Enum de ProblemCode vira vazio no protocolo e fica como evidência em Detail, sem alterar Device'
  Assert-Runtime ($record.DeviceName.Length -eq 256 -and $device.Name.Length -eq 300 -and $record.InstanceId.Length -eq 1024) 'Nome de 300 caracteres e identificação extensa são limitados apenas na cópia de log'
  Assert-Runtime ($record.Detail.Contains("`r`n") -and $record.Detail.Contains("`t") -and $record.Provider.Contains('ação') -and $record.Provider.Contains("`r`n")) 'Unicode, barras, aspas e quebras válidas de drivers são preservados'
  Assert-Runtime ($record.Present -ceq 'true' -and $record.PresenceKnown -ceq 'false' -and $record.RecordId -eq '18446744073709551615' -and $record.WindowsEventId -eq '65535') 'Booleanos e números unsigned obedecem o protocolo'
  $limits=@{EventId=36;Timestamp=48;SessionId=36;Sequence=20;Kind=64;Role=64;InstanceId=1024;DeviceName=256;Port=8;Present=5;PresenceKnown=5;Status=120;ProblemCode=20;Reason=256;Detail=2000;WindowsChannel=180;RecordId=20;Provider=180;WindowsEventId=10}
  foreach ($field in $limits.Keys) {
    Assert-Runtime ($record.$field -is [string] -and $record.$field.Length -le $limits[$field] -and $record.$field -notmatch '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]') ('Campo ' + $field + ' limitado e livre de controles não permitidos')
  }
  $device.Name=('á' * 255) + [char]0xd83d + [char]0xde80 + 'fim'; $device.ProblemCode='CM_PROB_FAILED_START'; $device.Port='LPT1'
  $event.RecordId='-1'; $event.Id=70000; $event.Channel='canal:inválido'
  & $module { param($Session,$Device,$Event); Write-PdvMonitorRecord $Session 'DeviceChanged' 'Falha concreta reportada como enum de driver.' $Device -WindowsEvent $Event } $session $device $event
  $records=@(Get-TestRecords); $record=$records[$records.Count-1]
  Assert-Runtime ($record.DeviceName.Length -eq 255 -and -not [char]::IsHighSurrogate($record.DeviceName[$record.DeviceName.Length-1])) 'Truncamento não corta par surrogate de caractere Unicode'
  Assert-Runtime ($record.ProblemCode -eq '' -and $record.Detail -like '*CM_PROB_FAILED_START*' -and $record.Port -eq '' -and $record.RecordId -eq '' -and $record.WindowsEventId -eq '' -and $record.WindowsChannel -eq '') 'Enum de erro, LPT e metadados fora do domínio não bloqueiam lote central'

  # Falhas e retomadas do envio são duráveis sem repetir avisos em backoff.
  $session=New-TestSession; $session.Config.Central.Enabled=$true
  & $module {
    foreach ($reason in @('Http503','Http503','BackoffActive','Http429','CentralDisabled','Acknowledged','OutboxEmpty')) {
      $script:TestUploadResults.Enqueue((New-Object PSObject -Property @{Success=(@('Acknowledged','OutboxEmpty') -contains $reason); Reason=$reason; Sent=2}))
    }
  }
  for ($i=0; $i -lt 5; $i++) { Invoke-PdvMonitorTick $session }
  Assert-Runtime ($session.PreviousUploadFailureReason -eq 'Http429' -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'UploadWarning' }).Count -eq 2) -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'UploadResumed' }).Count -eq 0)) 'Mesmo erro/backoff/desativação não repete aviso nem apaga falha anterior'
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.PreviousUploadFailureReason -eq '' -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'UploadResumed' -and $_.Reason -eq 'Acknowledged' }).Count -eq 1)) 'Confirmação posterior registra retomada uma vez'
  $session=New-TestSession
  & $module {
    $script:TestUploadResults.Enqueue((New-Object PSObject -Property @{Success=$false; Reason='CredentialUnavailable'; Sent=0}))
    $script:TestUploadResults.Enqueue((New-Object PSObject -Property @{Success=$true; Reason='OutboxEmpty'; Sent=0}))
  }
  Invoke-PdvMonitorTick $session; Invoke-PdvMonitorTick $session
  Assert-Runtime ((@(Get-TestRecords | Where-Object { $_.Kind -eq 'UploadResumed' -and $_.Reason -eq 'OutboxEmpty' -and $_.Detail -like '*sem pendências*' }).Count -eq 1)) 'Fila vazia após falha registra estado normal sem alegar confirmação HTTP'
  $session=New-TestSession
  & $module { $script:TestUploadThrow=$true }
  Invoke-PdvMonitorTick $session
  Assert-Runtime ($session.LastTickAt -and $session.LoggingHealthy -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'UploadWarning' -and $_.Reason -eq 'UploadFailed' }).Count -eq 1)) 'Exceção inesperada no transporte preserva coleta e gera aviso seguro'
  $session=New-TestSession; $session.Config.Central.Enabled=$true
  & $module { $script:TestQueueFailure=$true }
  Invoke-PdvMonitorTick $session
  $gaps=$session.OutboxGapCount; $sequence=$session.Sequence
  Invoke-PdvMonitorTick $session
  Assert-Runtime ($gaps -gt 0 -and $session.OutboxGapCount -eq $gaps -and $session.LastLoggedOutboxGapCount -eq $gaps -and $session.Sequence -eq $sequence -and (@(Get-TestRecords | Where-Object { $_.Kind -eq 'LogGap' -and $_.Reason -eq 'OutboxQueueGap' }).Count -eq 1)) 'Fila cheia gera LogGap durável e não cria ciclo ao falhar seu próprio enfileiramento'
  Write-Host ('PASS: ' + $script:assertions + ' verificações offline do runtime; sessão única, logs/rotação, perfis, manutenção, três leituras iguais, revalidação, histórico antes da ação e exportação sem credencial/fila. Nenhum hardware, WMI, processo ou HTTP real foi acessado. PowerShell ' + $PSVersionTable.PSVersion + '.')
} finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot,$true) } }
