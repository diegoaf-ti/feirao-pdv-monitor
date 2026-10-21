#requires -Version 5.1
# Testes offline do coordenador. Todos os acessos nativos/HTTP sao simulados.
# Nao abre COM, DLL, ERP, processos reais, WMI, impressora, DPAPI ou banco.
$ErrorActionPreference='Stop';
Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Nerus.psm1') -Force;
$module=Get-Module PdvMonitor.Nerus;
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('pdv-nerus-restart-test-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0;$script:Cases=0;$script:Failures=New-Object 'Collections.Generic.List[string]';
$agent='a1111111-1111-4111-8111-111111111111';
$revision='b2222222-2222-4222-8222-222222222222';
$instance='USB\VID_0B1B&PID_0003\RESTART-DEMO';
function Assert-Flow($Condition,[string]$Message) { $script:Checks++;if(-not $Condition){throw $Message;} }
function Test-Flow([string]$Name,[scriptblock]$Action) {
  $script:Cases++;
  try{& $Action;Write-Output ('OK: '+$Name);}
  catch{$script:Failures.Add($Name+': '+$_.Exception.Message+' ['+$_.ScriptStackTrace+']');Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}
}
& $module {
  $script:FlowRealSaveJournal=(Get-Command Save-PdvNerusRestartJournal).ScriptBlock;
  function script:Get-PdvNerusNow{return $script:FlowNow;}
  function script:Wait-PdvNerusFreshSample{$script:FlowNow=$script:FlowNow.AddMilliseconds(1100);}
  function script:Get-PdvNerusFreshSnapshot {
    $script:FlowSnapshotCount++;
    if($script:FlowSnapshotFailure){throw 'NerusFixtureSnapshotFailure';}
    $d=New-Object PSObject -Property @{InstanceId=$script:FlowInstance;Port=$script:FlowPort;Present=$script:FlowPresent;PresenceKnown=$script:FlowPresenceKnown;ProblemCode='0';Status='OK';Name='Bematech teste offline'};
    return (New-Object PSObject -Property @{InventoryComplete=$script:FlowInventoryComplete;PresenceComplete=$true;Devices=@($d)});
  }
  function script:Get-PdvNerusProcesses {
    $script:FlowProcessChecks++;
    if($script:FlowProcessFailure){throw 'NerusFixtureProcessesUnavailable';}
    if(-not $script:FlowClosed){New-Object PSObject -Property @{ProcessName='nerus'};}
    if($script:FlowTefRunning){New-Object PSObject -Property @{ProcessName='clisitef'};}
  }
  function script:Get-PdvNerusJobs {
    if($script:FlowJobsFailure){throw 'NerusFixtureJobsUnavailable';}
    for($i=0;$i -lt $script:FlowJobs;$i++){New-Object PSObject -Property @{Name='Trabalho simulado'};}
  }
  function script:Get-PdvNerusDesktopLaunch {
    $result=@{};foreach($key in $script:FlowLaunch.Keys){$result[$key]=$script:FlowLaunch[$key];};return $result;
  }
  function script:Get-PdvNerusRestartBinding {
    param($Launch);
    if($script:FlowBindingFailure){throw 'NerusFixtureBindingInvalid';}
    $result=@{};foreach($key in $script:FlowBinding.Keys){$result[$key]=$script:FlowBinding[$key];};return $result;
  }
  function script:Save-PdvNerusRestartJournal {
    param($Session,[string]$OperationId,[string]$Stage);
    if($script:FlowJournalFailure -or $script:FlowJournalFailureStage -ceq $Stage){throw 'NerusRestartJournalWriteFailed';}
    & $script:FlowRealSaveJournal $Session $OperationId $Stage;
    $script:FlowTrace.Add('journal:'+ $Stage);
  }
  function script:Close-PdvNerusBoundWindow {
    param($Launch,$Binding);
    $script:FlowCloseCount++;
    $xml=[xml][IO.File]::ReadAllText((Join-Path $script:FlowSession.DataDirectory 'nerus-reabertura.xml'));
    if([string]$xml.PdvNerusRestartJournal.Attempts.Attempt.stage -cne 'close_requested'){throw 'NerusFixtureCloseBeforeJournal';}
    if($script:FlowSnapshotCount -lt 6 -or $script:FlowProcessChecks -lt 2){throw 'NerusFixtureCloseBeforeRecheck';}
    $script:FlowTrace.Add('close');
    if($script:FlowCloseMode -cne 'success'){return @{Exited=$false;Reason=$script:FlowCloseMode};}
    $script:FlowClosed=$true;
    if($script:FlowFiscalAfterClose){$script:FlowFiscal=$script:FlowFiscalAfterClose;}
    if($script:FlowChangeAfterClose){$script:FlowRevision='d4444444-4444-4444-8444-444444444444';}
    return @{Exited=$true};
  }
  function script:Start-PdvNerusBoundLaunch {
    param($Launch);
    $script:FlowStartCount++;
    $script:FlowTrace.Add('start');
    $xml=[xml][IO.File]::ReadAllText((Join-Path $script:FlowSession.DataDirectory 'nerus-reabertura.xml'));
    if([string]$xml.PdvNerusRestartJournal.Attempts.Attempt.stage -cne 'reopen_requested'){throw 'NerusFixtureStartBeforeJournal';}
    if($script:FlowFiscal -cne '42' -or -not $script:FlowConfigAfterCommit){throw 'NerusFixtureStartBeforeConfirmedConfiguration';}
    return @{ProcessId=444};
  }
  function script:Invoke-PdvNerusHttp {
    param($Session,[string]$Path,[string]$Method='GET',[string]$Body='');
    $script:FlowCalls.Add(@{Path=$Path;Method=$Method;Body=$Body;Closed=$script:FlowClosed});
    $script:FlowTrace.Add('http:'+ $Path);
    $escape=[Security.SecurityElement]::Escape($script:FlowInstance);
    $now=$script:FlowNow.ToString('o');
    switch($Path){
      '/agent/policy' {
        $enabled=([string]$script:FlowEnabled).ToLowerInvariant();$open=([string]$script:FlowWindow).ToLowerInvariant();
        return '<PdvMonitorPolicy schemaVersion="1"><ServerTime>'+$now+'</ServerTime><WindowOpen>'+$open+'</WindowOpen><Enabled>'+$enabled+'</Enabled><AutoUpdateEnabled>false</AutoUpdateEnabled><Revision>'+$script:FlowRevision+'</Revision><InstanceId>'+$escape+'</InstanceId><HardwareId>machine-flow-demo</HardwareId><PortMappings><Mapping><Port>COM8</Port><FiscalDevice>42</FiscalDevice></Mapping><Mapping><Port>COM9</Port><FiscalDevice>43</FiscalDevice></Mapping></PortMappings><BlockingProcessNames><Name>nerus</Name><Name>clisitef</Name></BlockingProcessNames><MaintenanceWindow><UtcOffsetMinutes>-180</UtcOffsetMinutes><Days><Day>3</Day></Days><Start>22:00</Start><End>23:00</End></MaintenanceWindow></PdvMonitorPolicy>';
      }
      '/agent/nerus/configuration' {
        $fiscal=$script:FlowFiscal;$terminal=$script:FlowConfigTerminal;$configRevision=$script:FlowRevision;
        if($script:FlowCommitCount -gt 0){$script:FlowConfigAfterCommit=$true;if($script:FlowBadConfigAfterCommit){$fiscal='17';}}
        if($script:FlowConfigurationFault -ceq 'revision'){$configRevision='d4444444-4444-4444-8444-444444444444';}
        if($script:FlowConfigurationFault -ceq 'clock'){$now=$script:FlowNow.AddMinutes(-5).ToString('o');}
        if($script:FlowConfigurationFault -ceq 'value'){$fiscal='COM8';}
        return '<PdvMonitorNerusConfiguration schemaVersion="1"><ServerTime>'+$now+'</ServerTime><PolicyRevision>'+$configRevision+'</PolicyRevision><FiscalDevice>'+$fiscal+'</FiscalDevice><Terminal>'+$terminal+'</Terminal></PdvMonitorNerusConfiguration>';
      }
      '/agent/nerus/prepare' {
        if(-not $script:FlowClosed){throw 'NerusFixturePostBeforeClose';}
        $script:FlowPrepareCount++;
        $state=[xml][IO.File]::ReadAllText((Join-Path $Session.DataDirectory 'nerus-automacao.xml'));
        if([string]$state.PdvNerusState.Phase -cne 'prepare' -or [string]$state.PdvNerusState.Body -cne $Body){throw 'NerusFixturePrepareNotPersisted';}
        if($script:FlowLosePrepare){throw 'NerusTransportUnavailable';}
        return '<PdvMonitorRecovery schemaVersion="1"><Status>prepared</Status><TicketId>c3333333-3333-4333-8333-333333333333</TicketId><ExpiresAt>'+$script:FlowNow.AddSeconds(10).ToString('o')+'</ExpiresAt><ActualPort>COM8</ActualPort><BeforeValue>'+$script:FlowPreparedBefore+'</BeforeValue><AfterValue>42</AfterValue><Message>Teste offline</Message></PdvMonitorRecovery>';
      }
      '/agent/nerus/commit' {
        if(-not $script:FlowClosed){throw 'NerusFixturePostBeforeClose';}
        $script:FlowCommitCount++;
        $state=[xml][IO.File]::ReadAllText((Join-Path $Session.DataDirectory 'nerus-automacao.xml'));
        if([string]$state.PdvNerusState.Phase -cne 'commit' -or [string]$state.PdvNerusState.Body -cne $Body){throw 'NerusFixtureCommitNotPersisted';}
        $script:FlowFiscal='42';
        if($script:FlowLoseCommit){throw 'NerusTransportUnavailable';}
        return '<PdvMonitorRecovery schemaVersion="1"><Status>configured_pending_restart</Status><TicketId>c3333333-3333-4333-8333-333333333333</TicketId><ExpiresAt>'+$script:FlowNow.AddSeconds(10).ToString('o')+'</ExpiresAt><ActualPort>COM8</ActualPort><BeforeValue>'+$script:FlowPreparedBefore+'</BeforeValue><AfterValue>42</AfterValue><Message>Teste offline</Message></PdvMonitorRecovery>';
      }
      default{throw 'NerusFixtureUnexpectedHttp';}
    }
  }
};
function Reset-Flow {
  param([string]$Path='');
  if(-not $Path){$Path=Join-Path $temporary ([guid]::NewGuid().ToString('N'));}
  [void][IO.Directory]::CreateDirectory($Path);
  & $module {param($a,$r,$i);
    $script:FlowNow=[DateTimeOffset]::Parse('2026-10-21T22:00:00-03:00');$script:FlowRevision=$r;$script:FlowInstance=$i;
    $script:FlowEnabled=$true;$script:FlowWindow=$true;$script:FlowFiscal='2';$script:FlowFiscalAfterClose='';$script:FlowPreparedBefore='2';$script:FlowLosePrepare=$false;$script:FlowPort='COM8';$script:FlowConfigTerminal='CX4901';$script:FlowConfigurationFault='';
    $script:FlowClosed=$false;$script:FlowTefRunning=$false;$script:FlowProcessFailure=$false;$script:FlowJobs=0;$script:FlowJobsFailure=$false;
    $script:FlowInventoryComplete=$true;$script:FlowPresenceKnown=$true;$script:FlowPresent=$true;$script:FlowSnapshotFailure=$false;$script:FlowBindingFailure=$false;
    $script:FlowJournalFailure=$false;$script:FlowJournalFailureStage='';$script:FlowCloseMode='success';$script:FlowLoseCommit=$false;$script:FlowChangeAfterClose=$false;$script:FlowBadConfigAfterCommit=$false;
    $script:FlowCloseCount=0;$script:FlowStartCount=0;$script:FlowSnapshotCount=0;$script:FlowProcessChecks=0;$script:FlowPrepareCount=0;$script:FlowCommitCount=0;$script:FlowConfigAfterCommit=$false;
    $script:FlowTrace=New-Object 'Collections.Generic.List[string]';$script:FlowCalls=New-Object 'Collections.Generic.List[object]';
    $script:FlowLaunch=@{ShortcutHash=('A'*64);TargetHash=('B'*64);TargetPath='C:\Nerus\nerus.exe';WorkingDirectory='C:\Nerus';Arguments='--PRIVATE-ARGUMENT-DEMO';ProcessName='nerus'};
    $script:FlowBinding=@{ProcessId=222;StartTimeTicks=1234567;SessionId=1;OwnerSid='S-1-5-21-123';TargetPath='C:\Nerus\nerus.exe';ProcessName='nerus';MainWindowHandle=555};
  } $agent $revision $instance;
  $s=New-FlowSession $Path;return $s;
}
function New-FlowSession([string]$Path){
  $s=New-Object PSObject -Property @{DataDirectory=$Path;LoggingHealthy=$true;MaintenanceArmed=$false;HardwareMachineId='machine-flow-demo';AutoUpdateEnabled=$false;Terminal='CX4901';Config=(New-Object PSObject -Property @{Central=(New-Object PSObject -Property @{Enabled=$true;AgentId=$agent;Terminal='CX4901'});Profiles=@((New-Object PSObject -Property @{Role='ImpressoraBematech';InstanceId=$instance;ExpectedPort='COM2'}))})};
  & $module {param($session);$script:FlowSession=$session;Initialize-PdvNerusRestartContext $session;} $s;
  return $s;
}
function Get-FlowMetric([string]$Name){return (& $module {param($n);Get-Variable -Name ('Flow'+$n) -Scope Script -ValueOnly;} $Name);}
function Get-FlowPosts {return @(& $module {foreach($c in $script:FlowCalls){if($c.Method -ceq 'POST'){$c;}}});}
function Assert-NoFlowAction($Session){
  Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 0) 'Fechou o Nerus sem condicoes';
  Assert-Flow ((Get-FlowMetric 'StartCount') -eq 0) 'Abriu o Nerus sem condicoes';
  Assert-Flow (@(Get-FlowPosts).Count -eq 0) 'Enviou POST sem condicoes';
}
function Get-Proposal($Session){Invoke-PdvMonitorNerusRestartProbe -Session $Session;Assert-Flow ($null -ne $Session.NerusRestart.Proposal) ('Nao criou proposta: '+$Session.NerusRestart.Reason);return [string]$Session.NerusRestart.Proposal.Id;}
try{
  Test-Flow 'probe propoe COM8 para 42 sem executar acao e apply conclui com ordem duravel' {
    $s=Reset-Flow;$id=Get-Proposal $s;
    Assert-Flow ($s.NerusRestart.Proposal.ActualPort -ceq 'COM8' -and $s.NerusRestart.Proposal.AfterValue -ceq '42') 'Mapa explicito ficticio nao foi preservado';
    Assert-NoFlowAction $s;
    Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartReopened') ('Resultado inesperado: '+$s.NerusRestart.Reason);
    Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 1) 'Fechamento/reabertura nao ocorreram uma vez';
    Assert-Flow ((Get-FlowMetric 'PrepareCount') -eq 1 -and (Get-FlowMetric 'CommitCount') -eq 1) 'Handshake nao foi unico';
    $trace=@(Get-FlowMetric 'Trace');
    Assert-Flow ($trace.IndexOf('journal:close_requested') -lt $trace.IndexOf('close')) 'Journal nao precede fechamento';
    Assert-Flow ($trace.IndexOf('close') -lt $trace.IndexOf('http:/agent/nerus/prepare') -and $trace.IndexOf('http:/agent/nerus/commit') -lt $trace.IndexOf('journal:repair_confirmed') -and $trace.IndexOf('journal:repair_confirmed') -lt $trace.IndexOf('start')) 'Ordem prepare/commit/reabertura incorreta';
    $journal=[IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-reabertura.xml'));
    Assert-Flow ($journal -match 'stage="reopened"' -and $journal -notmatch 'PRIVATE-ARGUMENT|nerus.exe|WorkingDirectory|TargetHash') 'Journal vazou detalhes do executavel';
    $eventText=(@($s.NerusAutomation.Events.ToArray() | ForEach-Object{$_.Detail}) -join '|');
    Assert-Flow ($eventText -notmatch 'PRIVATE-ARGUMENT|nerus.exe|C:\\Nerus') 'Evento vazou caminho/argumentos';
    Assert-Flow ($null -eq $s.NerusRestart.Proposal -and -not $s.NerusRestart.Busy -and $s.NerusRestart.Result -match 'impress.o') 'Estado ou ressalva final incorretos';
    Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 1) 'Reutilizou aprovacao apos sucesso';
  };
  Test-Flow 'sem proposta, ID errado e aprovacao expirada nao fecham nem escrevem' {
    foreach($case in @('missing','wrong','expired')){
      $s=Reset-Flow;$id='';if($case -ne 'missing'){$id=Get-Proposal $s;}
      if($case -ceq 'wrong'){$id=[guid]::NewGuid().ToString();}
      if($case -ceq 'expired'){& $module {$script:FlowNow=$script:FlowNow.AddMinutes(3);};}
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;Assert-NoFlowAction $s;
      Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartProposalExpired') ('Nao recusou aprovacao '+$case);
    }
  };
  Test-Flow 'parametro ja igual nao oferece fechamento' {
    $s=Reset-Flow;& $module {$script:FlowFiscal='42';};Invoke-PdvMonitorNerusRestartProbe -Session $s;
    Assert-Flow ($null -eq $s.NerusRestart.Proposal -and $s.NerusRestart.Reason -ceq 'NerusRestartAlreadyCorrect') 'Propos fechar sem divergencia';Assert-NoFlowAction $s;
  };
  Test-Flow 'mudancas de porta politica arquivo argumentos ou identidade do PID invalidam proposta' {
    foreach($case in @('port','revision','targetHash','shortcutHash','arguments','pid','ticks','owner','window')){
      $s=Reset-Flow;$id=Get-Proposal $s;
      & $module {param($c);switch($c){
        'port'{$script:FlowPort='COM9';}
        'revision'{$script:FlowRevision='d4444444-4444-4444-8444-444444444444';}
        'targetHash'{$script:FlowLaunch.TargetHash='C'*64;}
        'shortcutHash'{$script:FlowLaunch.ShortcutHash='D'*64;}
        'arguments'{$script:FlowLaunch.Arguments='--OTHER';}
        'pid'{$script:FlowBinding.ProcessId=333;}
        'ticks'{$script:FlowBinding.StartTimeTicks=7654321;}
        'owner'{$script:FlowBinding.OwnerSid='S-1-5-21-999';}
        'window'{$script:FlowBinding.MainWindowHandle=999;}
      }} $case;
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;Assert-NoFlowAction $s;
      Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartProposalExpired') ('Mudanca nao detectada: '+$case+' / '+$s.NerusRestart.Reason);
    }
  };
  Test-Flow 'TEF fila inventario desconhecido vinculo e janela bloqueiam o probe' {
    foreach($case in @('tef','jobs','jobsFailure','processFailure','inventory','presence','absent','snapshot','binding','disabled','window','machine','logging','manualMaintenance')){
      $s=Reset-Flow;
      & $module {param($c,$session);switch($c){
        'tef'{$script:FlowTefRunning=$true;}'jobs'{$script:FlowJobs=1;}'jobsFailure'{$script:FlowJobsFailure=$true;}'processFailure'{$script:FlowProcessFailure=$true;}
        'inventory'{$script:FlowInventoryComplete=$false;}'presence'{$script:FlowPresenceKnown=$false;}'absent'{$script:FlowPresent=$false;}'snapshot'{$script:FlowSnapshotFailure=$true;}
        'binding'{$script:FlowBindingFailure=$true;}'disabled'{$script:FlowEnabled=$false;}'window'{$script:FlowWindow=$false;}
        'machine'{$session.HardwareMachineId='other-machine';}'logging'{$session.LoggingHealthy=$false;}'manualMaintenance'{$session.MaintenanceArmed=$true;}
      }} $case $s;
      Invoke-PdvMonitorNerusRestartProbe -Session $s;Assert-Flow ($null -eq $s.NerusRestart.Proposal) ('Criou proposta em '+$case);Assert-NoFlowAction $s;
    }
  };
  Test-Flow 'TEF fila ou perda de inventario entre proposta e confirmacao bloqueiam fechamento' {
    foreach($case in @('tef','jobs','inventory','presence')){
      $s=Reset-Flow;$id=Get-Proposal $s;
      & $module {param($c);switch($c){'tef'{$script:FlowTefRunning=$true;}'jobs'{$script:FlowJobs=1;}'inventory'{$script:FlowInventoryComplete=$false;}'presence'{$script:FlowPresenceKnown=$false;}}} $case;
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;Assert-NoFlowAction $s;
      Assert-Flow ($s.NerusRestart.Reason -cne 'NerusRestartReopened') ('Nao revalidou '+$case+' antes de fechar');
    }
  };
  Test-Flow 'configuracao com terminal revisao relogio ou valor errado nao fecha' {
    foreach($case in @('terminal','revision','clock','value')){
      $s=Reset-Flow;& $module {param($c);if($c -ceq 'terminal'){$script:FlowConfigTerminal='CX9901';}else{$script:FlowConfigurationFault=$c;}} $case;
      Invoke-PdvMonitorNerusRestartProbe -Session $s;Assert-NoFlowAction $s;Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartInvalidConfiguration') ('Configuracao invalida aceita: '+$case);
    }
  };
  Test-Flow 'recusa ou timeout no fechamento impede POST e reabertura' {
    foreach($mode in @('cancelled','timeout')){
      $s=Reset-Flow;$id=Get-Proposal $s;& $module {param($m);$script:FlowCloseMode=$m;} $mode;
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
      Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 0 -and @(Get-FlowPosts).Count -eq 0) ('Continuou depois de '+$mode);
      Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartCloseNotConfirmed') 'Nao registrou falta de confirmacao do fechamento';
    }
  };
  Test-Flow 'falha ao persistir journal impede qualquer fechamento' {
    $s=Reset-Flow;$id=Get-Proposal $s;& $module {$script:FlowJournalFailure=$true;};Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-NoFlowAction $s;Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartJournalWriteFailed') 'Nao recusou journal indisponivel';
  };
  Test-Flow 'falha de journal em fases posteriores impede avancar ou reabrir' {
    foreach($stage in @('closed','repair_requested','repair_confirmed','reopen_requested')){
      $s=Reset-Flow;$id=Get-Proposal $s;& $module {param($v);$script:FlowJournalFailureStage=$v;} $stage;
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
      Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 0) ('Avancou apos journal falhar em '+$stage);
      if(@('closed','repair_requested') -ccontains $stage){Assert-Flow (@(Get-FlowPosts).Count -eq 0) ('Fez POST depois de journal falhar em '+$stage);}
      Assert-Flow ($s.NerusRestart.Reason -ceq 'NerusRestartJournalWriteFailed') ('Motivo incorreto ao persistir '+$stage);
    }
  };
  Test-Flow 'commit com resposta perdida fica pendente persistido e bloqueia nova proposta/reabertura' {
    $s=Reset-Flow;$id=Get-Proposal $s;& $module {$script:FlowLoseCommit=$true;};Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 0) 'Reabriu com commit incerto';
    Assert-Flow ($null -ne $s.NerusAutomation.Pending -and $s.NerusAutomation.Pending.Phase -ceq 'commit') 'Perdeu ticket pendente';
    $state=[xml][IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-automacao.xml'));
    Assert-Flow ([string]$state.PdvNerusState.Phase -ceq 'commit' -and [string]$state.PdvNerusState.Body -ceq $s.NerusAutomation.Pending.Body) 'Pendencia nao foi persistida';
    Assert-Flow ([IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-reabertura.xml')) -match 'stage="uncertain"') 'Journal nao marcou incerteza';
    Invoke-PdvMonitorNerusRestartProbe -Session $s;Assert-Flow ($null -eq $s.NerusRestart.Proposal -and $s.NerusRestart.Reason -ceq 'NerusRestartNotReady') 'Ofereceu novo fechamento com commit pendente';
    $fresh=New-FlowSession $s.DataDirectory;
    Assert-Flow ($null -ne $fresh.NerusAutomation.Pending -and $null -eq $fresh.NerusRestart.Proposal -and (Get-FlowMetric 'StartCount') -eq 0) 'Inicializacao repetiu acao ou perdeu incerteza';
    & $module {$script:FlowLoseCommit=$false;$script:FlowNow=$script:FlowNow.AddMinutes(1);};
    & $module {param($session);Invoke-PdvMonitorNerusAutomation $session (Get-PdvNerusFreshSnapshot) (Get-PdvNerusNow);} $fresh;
    Assert-Flow ($null -eq $fresh.NerusAutomation.Pending -and (Get-FlowMetric 'StartCount') -eq 0) 'Resolucao idempotente reabriu ERP sem confirmacao nova';
  };
  Test-Flow 'valor homologado na proposta difere de prepare apos alteracao durante fechamento e bloqueia commit' {
    $s=Reset-Flow;& $module {$script:FlowFiscal='7';$script:FlowFiscalAfterClose='6';$script:FlowPreparedBefore='6';};$id=Get-Proposal $s;
    Assert-Flow ($s.NerusRestart.Proposal.BeforeValue -ceq '7') 'Proposta nao guardou o valor aprovado';
    Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'PrepareCount') -eq 1 -and (Get-FlowMetric 'CommitCount') -eq 0 -and (Get-FlowMetric 'StartCount') -eq 0) 'Alteracao durante fechamento permitiu commit/reabertura';
    Assert-Flow ((Get-FlowMetric 'Fiscal') -ceq '6' -and $null -eq $s.NerusAutomation.Pending) 'Sobrescreveu mudanca externa ou reteve pendencia rejeitada';
    $state=[xml][IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-automacao.xml'));
    Assert-Flow ($state.PdvNerusState.SelectNodes('Phase').Count -eq 0 -and $state.PdvNerusState.SelectNodes('ExpectedBefore').Count -eq 0) 'Cancelamento da pendencia nao foi persistido';
    Assert-Flow (-not $s.NerusAutomation.ContainsKey('RestartExpectedBefore')) 'Guarda efemera escapou do finally';
  };
  Test-Flow 'resposta de prepare perdida preserva valor aprovado e replay apos reinicio nao contorna a comparacao' {
    $s=Reset-Flow;& $module {$script:FlowFiscal='7';$script:FlowFiscalAfterClose='6';$script:FlowPreparedBefore='6';$script:FlowLosePrepare=$true;};$id=Get-Proposal $s;
    Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    Assert-Flow ($null -ne $s.NerusAutomation.Pending -and $s.NerusAutomation.Pending.Phase -ceq 'prepare' -and $s.NerusAutomation.Pending.ExpectedBefore -ceq '7') 'Perdeu a guarda antes do timeout de prepare';
    $state=[xml][IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-automacao.xml'));
    Assert-Flow ([string]$state.PdvNerusState.ExpectedBefore -ceq '7') 'Guarda nao foi escrita antes do HTTP';
    $requestBody=[string]$s.NerusAutomation.Pending.Body;$fresh=New-FlowSession $s.DataDirectory;
    Assert-Flow ($fresh.NerusAutomation.Healthy -and $fresh.NerusAutomation.Pending.ExpectedBefore -ceq '7' -and $fresh.NerusAutomation.Pending.Body -ceq $requestBody) 'Reinicio nao recuperou pedido e guarda exatos';
    & $module {$script:FlowLosePrepare=$false;$script:FlowNow=$script:FlowNow.AddSeconds(1);};
    & $module {param($session);Invoke-PdvMonitorNerusAutomation $session (Get-PdvNerusFreshSnapshot) (Get-PdvNerusNow);} $fresh;
    Assert-Flow ((Get-FlowMetric 'PrepareCount') -eq 2 -and (Get-FlowMetric 'CommitCount') -eq 0 -and (Get-FlowMetric 'StartCount') -eq 0) 'Replay permitiu commit/reabertura com valor anterior diferente';
    Assert-Flow ($null -eq $fresh.NerusAutomation.Pending -and $fresh.NerusAutomation.LastReason -ceq 'NerusRestartConfigurationChanged' -and (Get-FlowMetric 'Fiscal') -ceq '6') 'Replay nao recusou a mudanca externa';
  };
  Test-Flow 'guarda ExpectedBefore adulterada duplicada ou sem pendencia invalida estado sem acao' {
    foreach($fault in @('invalid','duplicate','orphan')){
      $s=Reset-Flow;& $module {$script:FlowFiscal='7';$script:FlowLosePrepare=$true;};$id=Get-Proposal $s;Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
      $path=Join-Path $s.DataDirectory 'nerus-automacao.xml';$xml=[xml][IO.File]::ReadAllText($path);
      if($fault -ceq 'invalid'){$xml.PdvNerusState.ExpectedBefore='COM8';}
      if($fault -ceq 'duplicate'){$n=$xml.CreateElement('ExpectedBefore');$n.InnerText='8';[void]$xml.DocumentElement.AppendChild($n);}
      if($fault -ceq 'orphan'){
        foreach($name in @('Phase','Body','RequestId','TicketId','ActualPort','BeforeValue','AfterValue')){foreach($n in @($xml.DocumentElement.SelectNodes($name))){[void]$xml.DocumentElement.RemoveChild($n);}}
        $xml.PdvNerusState.ExpectedBefore='COM8';
      }
      [IO.File]::WriteAllText($path,$xml.OuterXml,[Text.Encoding]::UTF8);$fresh=New-FlowSession $s.DataDirectory;
      Assert-Flow (-not $fresh.NerusAutomation.Healthy) ('Estado com guarda '+$fault+' foi aceito');
      $posts=@(Get-FlowPosts).Count;Invoke-PdvMonitorNerusRestartProbe -Session $fresh;
      Assert-Flow ($null -eq $fresh.NerusRestart.Proposal -and @(Get-FlowPosts).Count -eq $posts -and (Get-FlowMetric 'StartCount') -eq 0) 'Estado adulterado permitiu continuar';
    }
  };
  Test-Flow 'configuracao nao confirmada apos commit ou politica alterada apos fechar impede reabrir' {
    foreach($case in @('badConfig','changedPolicy')){
      $s=Reset-Flow;$id=Get-Proposal $s;
      & $module {param($c);if($c -ceq 'badConfig'){$script:FlowBadConfigAfterCommit=$true;}else{$script:FlowChangeAfterClose=$true;}} $case;
      Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
      Assert-Flow ((Get-FlowMetric 'CloseCount') -eq 1 -and (Get-FlowMetric 'StartCount') -eq 0) ('Reabriu apos '+$case);
      Assert-Flow ($s.NerusRestart.Reason -cne 'NerusRestartReopened') 'Declarou sucesso apos validacao falhar';
    }
  };
  Test-Flow 'limites de quinze minutos e duas tentativas por hora sobrevivem nova sessao' {
    $s=Reset-Flow;$id=Get-Proposal $s;& $module {$script:FlowCloseMode='cancelled';};Invoke-PdvMonitorNerusRestartApply -Session $s -ProposalId $id;
    $fresh=New-FlowSession $s.DataDirectory;Invoke-PdvMonitorNerusRestartProbe -Session $fresh;
    Assert-Flow ($fresh.NerusRestart.Reason -ceq 'NerusRestartRateLimited' -and $null -eq $fresh.NerusRestart.Proposal) 'Reinicio burlou quinze minutos';
    $s=Reset-Flow;
    & $module {param($session);$script:FlowNow=$script:FlowNow.AddMinutes(-32);Save-PdvNerusRestartJournal $session ([guid]::NewGuid().ToString()) 'failed';$script:FlowNow=$script:FlowNow.AddMinutes(16);Save-PdvNerusRestartJournal $session ([guid]::NewGuid().ToString()) 'failed';$script:FlowNow=$script:FlowNow.AddMinutes(16);} $s;
    $fresh=New-FlowSession $s.DataDirectory;Invoke-PdvMonitorNerusRestartProbe -Session $fresh;Assert-NoFlowAction $fresh;
    Assert-Flow ($fresh.NerusRestart.Reason -ceq 'NerusRestartRateLimited') 'Reinicio burlou duas tentativas por hora';
  };
  Test-Flow 'journal interrompido nao concede aprovacao nem relanca ao iniciar' {
    $s=Reset-Flow;& $module {param($session);Save-PdvNerusRestartJournal $session ([guid]::NewGuid().ToString()) 'reopen_requested';} $s;
    $fresh=New-FlowSession $s.DataDirectory;Assert-NoFlowAction $fresh;
    Invoke-PdvMonitorNerusRestartApply -Session $fresh -ProposalId ([guid]::NewGuid().ToString());Assert-NoFlowAction $fresh;
    Assert-Flow ($null -eq $fresh.NerusRestart.Proposal -and $fresh.NerusRestart.Reason -ceq 'NerusRestartProposalExpired') 'Journal virou autorizacao de relancar';
  };
}finally{
  Remove-Module PdvMonitor.Nerus -Force -ErrorAction SilentlyContinue;
  if([IO.Directory]::Exists($temporary)){[IO.Directory]::Delete($temporary,$true);}
}
if($script:Failures.Count){foreach($failure in $script:Failures){Write-Output $failure;};throw ('Falharam '+$script:Failures.Count+' casos de reabertura assistida.');}
Write-Output ('Reabertura assistida: '+$script:Cases+' cenarios, '+$script:Checks+' verificacoes offline aprovadas.');
