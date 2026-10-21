# Diagnostico/exportacao Nerus Service com fixtures e mocks. Nenhum SCM/WMI/COM/HTTP real.
$ErrorActionPreference = 'Stop'
$ErrorView = 'NormalView'
Set-StrictMode -Version 2.0
$moduleDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDirectory 'PdvMonitor.Runtime.psm1') -Force
$module = Get-Module PdvMonitor.Runtime
$script:assertions = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdv-nerus-service-runtime-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

& $module {
  $script:ServiceTestRecords = New-Object 'Collections.Generic.List[object]'
  $script:ServiceTestDiscovery = $null
  $script:ServiceTestDiscoveryFailure = $false
  $script:ServiceTestLogFailure = $false
  $script:ServiceTestAtomicFailure = $false
  $script:ServiceTestDiscoveryCalls = 0
  $script:ServiceTestSnapshotCalls = 0
  $script:ServiceTestNow = [DateTimeOffset]::Parse('2026-10-21T14:00:00-03:00')
  $script:ServiceTestRealAtomic = (Get-Command Write-PdvRuntimeAtomic).ScriptBlock
  $script:ServiceTestRealDiscovery = (Get-Command Get-PdvMonitorNerusServiceDiscovery).ScriptBlock
  $script:ServiceTestRealNerusModule = $script:nerusModule
  function script:Get-PdvMonitorNerusServiceDiscovery {
    param($Session)
    $script:ServiceTestDiscoveryCalls++
    if ($script:ServiceTestDiscoveryFailure) { throw 'TEST_DISCOVERY_UNAVAILABLE_SECRET_CANARY' }
    return $script:ServiceTestDiscovery
  }
  function script:Write-PdvMonitorRecord {
    param($Session,[string]$Kind,[string]$Detail='',$Device=$null,[string]$Role='',[string]$Reason='',$WindowsEvent=$null)
    if ($script:ServiceTestLogFailure) { throw 'TEST_LOG_FAILURE' }
    [void]$script:ServiceTestRecords.Add((New-Object PSObject -Property @{Kind=$Kind;Detail=$Detail;Role=$Role;Reason=$Reason}))
  }
  function script:Write-PdvRuntimeAtomic {
    param([string]$Path,[string]$Text)
    if ($script:ServiceTestAtomicFailure) { throw 'TEST_LOCAL_WRITE_FAILURE_SECRET_CANARY' }
    & $script:ServiceTestRealAtomic $Path $Text
  }
  function script:Get-PdvMonitorSnapshot { $script:ServiceTestSnapshotCalls++; throw 'TEST_REAL_COLLECTION_FORBIDDEN' }
}

function Assert-ServiceRuntime {
  param([bool]$Condition,[string]$Message)
  if (-not $Condition) { throw $Message }
  $script:assertions++
}

function New-ServiceRuntimeSession {
  $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($path)
  $logs = Join-Path $path 'logs'; [void][IO.Directory]::CreateDirectory($logs)
  & $module {
    $script:ServiceTestRecords.Clear()
    $script:ServiceTestDiscoveryFailure=$false; $script:ServiceTestLogFailure=$false; $script:ServiceTestAtomicFailure=$false
    $script:ServiceTestDiscoveryCalls=0; $script:ServiceTestSnapshotCalls=0
    $script:ServiceTestDiscovery=@{Complete=$true;Reason='';Candidates=@();Processes=@()}
  }
  return (New-Object PSObject -Property @{
    DataDirectory=$path;LogDirectory=$logs;Stopped=$false;TickBusy=$false;LoggingHealthy=$true
    LastNerusServiceAt=$null;NerusServiceSignatures=@{};NerusRestart=@{Busy=$false}
    Config=(New-Object PSObject -Property @{Profiles=@();BlockingProcessNames=@()})
    NerusService=@{Busy=$false;Binding=$null;Events=(New-Object Collections.Queue)}
  })
}

function New-ServiceRuntimeCandidate {
  param([string]$Name='NerusService',[string]$State='Running',[int]$ProcessId=700)
  return @{
    ServiceName=$Name;DisplayName='Nerus Service';State=$State;ServiceType='Own Process';ProcessId=$ProcessId
    Eligible=$true;Reason='';ExecutablePath='C:\Nerus\NerusService.exe';ModulesComplete=$true;TefModuleObserved=$false
    PrintModules=@(@{Name='MP2032.dll';Version='1.2.3';Arguments='SECRET_CANARY_MODULE_ARGS'})
    CommandLine='SECRET_CANARY_COMMAND_LINE';Arguments='SECRET_CANARY_ARGUMENTS';Password='SECRET_CANARY_PASSWORD'
    StartName='SECRET_CANARY_ACCOUNT';LicenseUuid='SECRET_CANARY_ACTIVATION';Unknown=@{Token='SECRET_CANARY_TOKEN'}
  }
}

function Set-ServiceRuntimeDiscovery {
  param([object[]]$Candidates=@(),[bool]$Complete=$true,[object[]]$Processes=@(),[string]$Reason='')
  $value=@{Complete=$Complete;Candidates=$Candidates;Processes=$Processes;Reason=$Reason}
  & $module {param($Value);$script:ServiceTestDiscovery=$Value} $value
}

function Invoke-ServiceRuntimeDiagnostic {
  param($Session)
  & $module {param($Session);Update-PdvMonitorNerusServiceDiagnostic -Session $Session -Now $script:ServiceTestNow;$script:ServiceTestNow=$script:ServiceTestNow.AddMinutes(1)} $Session
}

function Get-ServiceRuntimeRecords { return (& $module {return ,$script:ServiceTestRecords.ToArray()}) }
function Read-ServiceRuntimeDiagnostic {
  param($Session)
  return ([IO.File]::ReadAllText((Join-Path $Session.DataDirectory 'nerus-servico-diagnostico.json')) | ConvertFrom-Json)
}

try {
  # Referencia inicial, transicoes e ausencia de remessa periodica repetida.
  $session=New-ServiceRuntimeSession
  $candidate=New-ServiceRuntimeCandidate
  Set-ServiceRuntimeDiscovery @($candidate)
  Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords)
  Assert-ServiceRuntime ($records.Count -eq 2) 'Referencia inicial publica somente cobertura e servico'
  Assert-ServiceRuntime (@($records | Where-Object {$_.Reason -eq 'NerusServiceState'}).Count -eq 1) 'Servico inicial gera um evento proprio'
  $first=Read-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime ($first.schemaVersion -eq 1 -and $first.complete -and @($first.services).Count -eq 1) 'Diagnostico local tem versao e servico estruturado'
  Assert-ServiceRuntime ($first.services[0].serviceName -ceq 'NerusService' -and $first.services[0].state -ceq 'Running') 'Nome/estado do servico preservados'
  Assert-ServiceRuntime ($null -ne $session.LastNerusServiceAt) 'Consulta concluida atualiza a referencia de tempo'
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords).Count -eq 2) 'Mesmo estado nao gera spam na rodada seguinte'
  $candidate.State='Stopped';$candidate.ProcessId=0;$candidate.Eligible=$false;$candidate.Reason='NerusServiceNotRunning'
  $session.NerusService.Binding=@{ServiceName='NerusService';DisplayName='Nerus Service'}
  Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords)
  Assert-ServiceRuntime ($records.Count -eq 3 -and $records[2].Kind -ceq 'CollectionWarning') 'Servico vinculado parado gera aviso visivel'
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords).Count -eq 3) 'Estado parado persistente nao repete o aviso'
  $candidate.State='Running';$candidate.ProcessId=701;$candidate.Eligible=$true;$candidate.Reason=''
  Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords)
  Assert-ServiceRuntime ($records.Count -eq 4 -and $records[3].Kind -ceq 'ServiceDiagnostic') 'Nova execucao normal gera uma transicao informativa'
  $copy=$records[3].Detail | ConvertFrom-Json
  Assert-ServiceRuntime ($copy.processId -ceq '701') 'Transicao preserva PID como metadado, sem declarar impressao recuperada'
  foreach ($record in $records) {
    Assert-ServiceRuntime ($record.Detail.Length -le 1900) 'Registro de descoberta respeita folga do limite de transporte'
    Assert-ServiceRuntime ($record.Detail -notmatch 'SECRET_CANARY') 'Registro ignora argumentos e campos livres da descoberta'
    $parsed=$record.Detail | ConvertFrom-Json
    Assert-ServiceRuntime ($parsed.schemaVersion -eq 1) 'Detail de descoberta permanece JSON completo'
  }
  $localText=[IO.File]::ReadAllText((Join-Path $session.DataDirectory 'nerus-servico-diagnostico.json'))
  Assert-ServiceRuntime ($localText -notmatch 'SECRET_CANARY|CommandLine|Password|LicenseUuid|StartName|Arguments') 'Documento local aplica a mesma whitelist de metadados'

  # Listas e textos longos nao cortam um documento JSON ou vazam propriedades extras.
  $session=New-ServiceRuntimeSession;$candidate=New-ServiceRuntimeCandidate
  $candidate.DisplayName=('"' * 300);$candidate.ExecutablePath=('\' * 600);$candidate.PrintModules=@()
  for($i=0;$i -lt 30;$i++){$candidate.PrintModules+=@(@{Name=('"' * 150);Version=('\' * 150);Secret='SECRET_CANARY_LARGE_MODULE'})}
  Set-ServiceRuntimeDiscovery @($candidate)
  Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords)
  $serviceRecords=@($records | Where-Object {$_.Reason -ceq 'NerusServiceState'})
  Assert-ServiceRuntime ($serviceRecords.Count -eq 1) 'Campos grandes ainda geram um registro valido'
  $large=$serviceRecords[0].Detail | ConvertFrom-Json
  Assert-ServiceRuntime ($serviceRecords[0].Detail.Length -le 1900) 'JSON com caracteres escapados cabe antes da normalizacao'
  Assert-ServiceRuntime ($large.modulesOmitted -and @($large.modules).Count -eq 0 -and $large.executablePath -ceq '') 'Metadados opcionais sao omitidos integralmente quando excedem o limite'
  Assert-ServiceRuntime ($large.displayName.Length -eq 128) 'Texto de metadado recebe limite proprio antes da serializacao'
  Assert-ServiceRuntime ($serviceRecords[0].Detail -notmatch 'SECRET_CANARY') 'Omissao de campos grandes nao serializa dados livres'
  $local=Read-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime ($local.services[0].modulesOmitted -and @($local.services).Count -eq 1) 'Documento local preserva a omissao explicita'

  $session=New-ServiceRuntimeSession;$candidate=New-ServiceRuntimeCandidate
  $candidate.ExecutablePath='C:\' + ('x' * 500) + '\Nerus.exe';$candidate.PrintModules=@()
  for($i=0;$i -lt 12;$i++){$candidate.PrintModules+=@(@{Name=('m' * 80);Version=('v' * 80)})}
  Set-ServiceRuntimeDiscovery @($candidate);Invoke-ServiceRuntimeDiagnostic $session
  $local=Read-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime ($local.services[0].executablePath.Length -eq 256) 'Caminho tecnico de diagnostico e limitado a 256 caracteres'
  Assert-ServiceRuntime (@($local.services[0].modules).Count -le 8) 'Lista de bibliotecas no diagnostico tem limite de oito'
  foreach($entry in @($local.services[0].modules)){
    Assert-ServiceRuntime ($entry.name.Length -le 64 -and $entry.version.Length -le 48) 'Nome/versao da biblioteca respeitam limites proprios'
  }

  # Aplicativo de bandeja sem SCM tem diagnostico, sem qualquer acao automatica.
  $session=New-ServiceRuntimeSession
  $tray=@{ProcessName='NerusTray';ProcessId=987;IsWindowsService=$false;Diagnosis='NonWindowsService';Supported=$false;CommandLine='SECRET_CANARY_TRAY_COMMAND';Password='SECRET_CANARY_TRAY_PASSWORD'}
  Set-ServiceRuntimeDiscovery -Processes @($tray) -Reason 'NerusServiceTrayOnly'
  Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords);$trayRecords=@($records | Where-Object {$_.Reason -ceq 'NerusServiceProcess'})
  Assert-ServiceRuntime ($trayRecords.Count -eq 1) 'Aplicativo sem SCM gera evento central de diagnostico'
  $detail=$trayRecords[0].Detail | ConvertFrom-Json
  Assert-ServiceRuntime ($detail.scope -ceq 'process' -and -not $detail.isWindowsService -and $detail.processName -ceq 'NerusTray') 'Diagnostico distingue processo comum de servico Windows'
  $local=Read-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@($local.processes).Count -eq 1 -and $local.processes[0].processId -ceq '987') 'Processo de bandeja tambem fica no documento local'
  Assert-ServiceRuntime ($trayRecords[0].Detail -notmatch 'SECRET_CANARY') 'Diagnostico do aplicativo omite linha de comando e segredos'
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords).Count -eq 2) 'Processo de bandeja estavel nao gera remessas repetidas'

  # Consulta parcial nao conclui desaparecimento; consulta completa registra uma vez.
  $session=New-ServiceRuntimeSession
  Set-ServiceRuntimeDiscovery @((New-ServiceRuntimeCandidate)) -Processes @($tray)
  Invoke-ServiceRuntimeDiagnostic $session
  Set-ServiceRuntimeDiscovery -Complete $false -Reason 'NerusServiceDiscoveryIncomplete'
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords | Where-Object {$_.Reason -ceq 'NerusServiceNotObserved'}).Count -eq 0) 'Consulta incompleta nao infere remocao'
  Assert-ServiceRuntime ($session.NerusServiceSignatures.ContainsKey('NerusService') -and $session.NerusServiceSignatures.ContainsKey('process|987|NerusTray')) 'Consulta parcial preserva referencias anteriores'
  Set-ServiceRuntimeDiscovery
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords | Where-Object {$_.Reason -ceq 'NerusServiceNotObserved'}).Count -eq 2) 'Consulta completa informa desaparecimento do servico e processo'
  Assert-ServiceRuntime (-not $session.NerusServiceSignatures.ContainsKey('NerusService') -and -not $session.NerusServiceSignatures.ContainsKey('process|987|NerusTray')) 'Ausencias completas removem somente as referencias correspondentes'
  $count=@(Get-ServiceRuntimeRecords).Count;Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords).Count -eq $count) 'Ausencia persistente nao repete registros de remocao'

  # Falha de consulta e retomada nao vazam excecao livre nem geram aviso por rodada.
  $session=New-ServiceRuntimeSession
  & $module {$script:ServiceTestDiscoveryFailure=$true}
  Invoke-ServiceRuntimeDiagnostic $session;Invoke-ServiceRuntimeDiagnostic $session
  $records=@(Get-ServiceRuntimeRecords)
  Assert-ServiceRuntime ($records.Count -eq 1 -and $records[0].Kind -ceq 'CollectionWarning') 'Falha repetida de descoberta gera um aviso'
  Assert-ServiceRuntime ($records[0].Reason -ceq 'NerusServiceDiagnosticUnavailable' -and $records[0].Detail -notmatch 'SECRET_CANARY') 'Excecao livre vira motivo estavel sem segredo'
  Assert-ServiceRuntime ($null -ne $session.LastNerusServiceAt) 'Falha de descoberta respeita intervalo da coleta'
  & $module {$script:ServiceTestDiscoveryFailure=$false}
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords).Count -eq 2 -and (Read-ServiceRuntimeDiagnostic $session).complete) 'Retomada publica cobertura normal e documento valido'

  $session=New-ServiceRuntimeSession
  & $module {$script:ServiceTestAtomicFailure=$true}
  Invoke-ServiceRuntimeDiagnostic $session;Invoke-ServiceRuntimeDiagnostic $session
  $writeWarnings=@(Get-ServiceRuntimeRecords | Where-Object {$_.Kind -ceq 'CollectionWarning'})
  Assert-ServiceRuntime ($writeWarnings.Count -eq 1) 'Falha repetida ao persistir o diagnostico gera apenas um aviso de cobertura'
  Assert-ServiceRuntime ($writeWarnings[0].Detail -notmatch 'SECRET_CANARY') 'Falha de persistencia tambem omite a mensagem livre'
  & $module {$script:ServiceTestAtomicFailure=$false}
  Invoke-ServiceRuntimeDiagnostic $session
  Assert-ServiceRuntime ((Read-ServiceRuntimeDiagnostic $session).complete) 'Retomada da escrita restaura o documento local'

  # Nomes de SCM derivam exclusivamente do vinculo, nao de candidatos livres.
  $session=New-ServiceRuntimeSession
  $names=@(& $module {param($Session);Get-PdvRuntimeNerusServiceNames $Session} $session)
  Assert-ServiceRuntime ($names.Count -eq 0) 'Sem vinculo nao fornece nomes para eventos SCM'
  $session.NerusService.Binding=@{ServiceName='NerusService';DisplayName='Nerus Service'}
  $names=@(& $module {param($Session);Get-PdvRuntimeNerusServiceNames $Session} $session)
  Assert-ServiceRuntime ($names.Count -eq 2 -and $names -contains 'NerusService' -and $names -contains 'Nerus Service') 'Somente nome e nome de exibicao vinculados entram no filtro'
  $session.NerusService.Binding.DisplayName='NerusService'
  Assert-ServiceRuntime (@(& $module {param($Session);Get-PdvRuntimeNerusServiceNames $Session} $session).Count -eq 1) 'Nomes identicos sao deduplicados'
  foreach($bad in @(' NerusService','NerusService ',('Nerus'+[char]1+'Service'),('x' * 257),('Nerus"Service' + "'"))){
    $session.NerusService.Binding=@{ServiceName=$bad;DisplayName=$bad}
    Assert-ServiceRuntime (@(& $module {param($Session);Get-PdvRuntimeNerusServiceNames $Session} $session).Count -eq 0) 'Nome com espacos externos, controle, excesso ou duas aspas e rejeitado'
  }
  foreach($valid in @('Nerus"Service',("Nerus'Service"),'Nerus-Service_1')){
    $session.NerusService.Binding=@{ServiceName=$valid;DisplayName=$valid}
    Assert-ServiceRuntime (@(& $module {param($Session);Get-PdvRuntimeNerusServiceNames $Session} $session).Count -eq 1) 'Nome com uma classe de aspas ou pontuacao permitida permanece explicito'
  }

  # Consumir a fila exige a escrita do item; uma falha preserva o cabecalho.
  $session=New-ServiceRuntimeSession
  $session.NerusService.Events.Enqueue(@{Kind='RecoveryAttempt';Reason='NerusServiceStopRequested';Detail='Tentativa simulada'})
  $session.NerusService.Events.Enqueue(@{Kind='NerusServiceRestarted';Reason='NerusServiceRestarted';Detail='Nova execucao simulada; impressao nao confirmada'})
  & $module {$script:ServiceTestLogFailure=$true}
  $failure='';try{& $module {param($Session);Publish-PdvMonitorNerusServiceNotices $Session} $session}catch{$failure=[string]$_.Exception.Message}
  Assert-ServiceRuntime ($failure -ceq 'TEST_LOG_FAILURE' -and $session.NerusService.Events.Count -eq 2) 'Falha do log preserva todos os avisos pendentes'
  Assert-ServiceRuntime ($session.NerusService.Events.Peek().Kind -ceq 'RecoveryAttempt') 'Primeiro aviso nao e consumido antes da escrita'
  & $module {$script:ServiceTestLogFailure=$false}
  & $module {param($Session);Publish-PdvMonitorNerusServiceNotices $Session} $session
  $records=@(Get-ServiceRuntimeRecords)
  Assert-ServiceRuntime ($session.NerusService.Events.Count -eq 0 -and $records.Count -eq 2) 'Retomada esvazia a fila apos ambas as escritas'
  Assert-ServiceRuntime ($records[0].Kind -ceq 'RecoveryAttempt' -and $records[1].Kind -ceq 'NerusServiceRestarted') 'Ordem dos avisos e preservada'
  Assert-ServiceRuntime (@($records | Where-Object {$_.Role -cne 'Serviço Nerus'}).Count -eq 0) 'Avisos recebem a funcao correta no protocolo'

  # Filtro explicito da exportacao inclui os novos dados e exclui credencial/fila.
  $session=New-ServiceRuntimeSession
  foreach($name in @('nerus-servico.xml','nerus-servico-tentativas.xml','nerus-servico-diagnostico.json')){[IO.File]::WriteAllText((Join-Path $session.DataDirectory $name),'TECHNICAL_METADATA_ONLY')}
  [IO.File]::WriteAllText((Join-Path $session.LogDirectory 'monitor-fixture.csv'),'Kind,Detail')
  [IO.File]::WriteAllText((Join-Path $session.DataDirectory 'central-credencial.bin'),'SECRET_CANARY_CREDENTIAL')
  [void][IO.Directory]::CreateDirectory((Join-Path $session.DataDirectory 'outbox'))
  [IO.File]::WriteAllText((Join-Path (Join-Path $session.DataDirectory 'outbox') 'event.xml'),'SECRET_CANARY_OUTBOX')
  $destination=Export-PdvMonitorLogs $session $testRoot
  foreach($name in @('nerus-servico.xml','nerus-servico-tentativas.xml','nerus-servico-diagnostico.json','monitor-fixture.csv')){
    Assert-ServiceRuntime ([IO.File]::Exists((Join-Path $destination $name))) 'Exportacao inclui arquivo tecnico autorizado'
  }
  Assert-ServiceRuntime (-not [IO.File]::Exists((Join-Path $destination 'central-credencial.bin')) -and -not [IO.Directory]::Exists((Join-Path $destination 'outbox'))) 'Exportacao exclui credencial e fila historica'
  foreach($path in [IO.Directory]::GetFiles($destination)){Assert-ServiceRuntime ([IO.File]::ReadAllText($path) -notmatch 'SECRET_CANARY') 'Nenhum arquivo exportado contem os canarios de segredo'}

  # Serviço ocupado impede tick antes de consultar hardware ou descoberta.
  $session=New-ServiceRuntimeSession;$session.NerusService.Busy=$true
  Invoke-PdvMonitorTick $session
  $metrics=& $module {return @($script:ServiceTestDiscoveryCalls,$script:ServiceTestSnapshotCalls)}
  Assert-ServiceRuntime ($metrics[0] -eq 0 -and $metrics[1] -eq 0 -and -not $session.TickBusy) 'Recuperacao de servico ocupada bloqueia a rodada sem coleta nativa'

  # Wrappers delegam somente para um modulo falso, sempre publicando seus avisos.
  $fakeModule=New-Module -ScriptBlock {
    function Get-PdvMonitorNerusServiceDiscovery {param($Session);return @{Complete=$true;Candidates=@();Processes=@();Reason='MockModule'}}
    function Save-PdvMonitorNerusServiceBinding {param($Session,[string]$ServiceName);$Session.NerusService.Events.Enqueue(@{Kind='ServiceDiagnostic';Reason='MockBound';Detail='Vinculo simulado'});return @{ServiceName=$ServiceName}}
    function Invoke-PdvMonitorNerusServiceProbe {param($Session);$Session.NerusService.Events.Enqueue(@{Kind='ServiceDiagnostic';Reason='MockProbe';Detail='Proposta simulada'})}
    function Invoke-PdvMonitorNerusServiceApply {param($Session,[string]$ProposalId);$Session.NerusService.Events.Enqueue(@{Kind='RecoveryFailed';Reason='MockApply';Detail=$ProposalId});throw 'TEST_MOCK_APPLY_REFUSED'}
    Export-ModuleMember -Function Get-PdvMonitorNerusServiceDiscovery,Save-PdvMonitorNerusServiceBinding,Invoke-PdvMonitorNerusServiceProbe,Invoke-PdvMonitorNerusServiceApply
  }
  & $module {param($Fake);$script:nerusModule=$Fake} $fakeModule
  $session=New-ServiceRuntimeSession
  $found=& $module {param($Session);& $script:ServiceTestRealDiscovery -Session $Session} $session
  Assert-ServiceRuntime ($found.Reason -ceq 'MockModule') 'Wrapper descoberta delega para o modulo dedicado'
  $binding=& $module {param($Session);Save-PdvMonitorNerusServiceBinding -Session $Session -ServiceName 'NerusService' -BlockingProcessNames @('CliSiTef','NerusBridge','CliSiTef')} $session
  Assert-ServiceRuntime ($binding.ServiceName -ceq 'NerusService' -and $session.Config.BlockingProcessNames.Count -eq 2) 'Wrapper salva processos bloqueadores deduplicados e retorna vinculo'
  $xml=[xml][IO.File]::ReadAllText((Join-Path $session.DataDirectory 'monitor.xml'))
  Assert-ServiceRuntime ($xml.SelectNodes('/monitor/processes/process').Count -eq 2) 'Processos bloqueadores sao persistidos no arquivo proprio'
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords | Where-Object {$_.Reason -ceq 'MockBound'}).Count -eq 1 -and $session.NerusService.Events.Count -eq 0) 'Wrapper de vinculo publica os avisos apos delegar'
  foreach($bad in @('Nerus.exe','C:\Nerus\Nerus','Nerus*','Nerus name')){
    $failed=$false;try{& $module {param($Session,$Bad);Save-PdvMonitorNerusServiceBinding -Session $Session -ServiceName 'NerusService' -BlockingProcessNames @($Bad) | Out-Null} $session $bad}catch{$failed=$true}
    Assert-ServiceRuntime $failed 'Wrapper rejeita nome de bloqueador com extensao, caminho, curinga ou espaco'
  }
  & $module {param($Session);Invoke-PdvMonitorNerusServiceProbe -Session $Session} $session
  Assert-ServiceRuntime (@(Get-ServiceRuntimeRecords | Where-Object {$_.Reason -ceq 'MockProbe'}).Count -eq 1) 'Wrapper de proposta publica aviso da simulacao'
  $failed=$false;try{& $module {param($Session);Invoke-PdvMonitorNerusServiceApply -Session $Session -ProposalId 'proposal-simulated'} $session}catch{$failed=$true}
  Assert-ServiceRuntime ($failed -and @(Get-ServiceRuntimeRecords | Where-Object {$_.Reason -ceq 'MockApply' -and $_.Detail -ceq 'proposal-simulated'}).Count -eq 1) 'Wrapper de execucao publica aviso mesmo quando o modulo recusa a acao'

  Write-Host ('PASS: '+$script:assertions+' verificacoes offline Nerus Service/runtime: referencia/transicoes, metadados limitados, bandeja, cobertura parcial, fila, exportacao e wrappers. Nenhum SCM/WMI/COM/HTTP real. PowerShell '+$PSVersionTable.PSVersion+'.')
} finally {
  & $module {$script:nerusModule=$script:ServiceTestRealNerusModule}
  if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$true)}
}
