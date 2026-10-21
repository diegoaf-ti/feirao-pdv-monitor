#requires -Version 5.1
# Offline: todos os acessos WMI/SCM/processo/COM e elevacao sao simulados.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Nerus.psm1') -Force;$module=Get-Module PdvMonitor.Nerus;
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('pdv-service-tests-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0;$script:Cases=0;$failures=New-Object 'Collections.Generic.List[string]';
function Assert-Service($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Test-Service([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
& $module {
  $script:ServiceRealStop=(Get-Command Invoke-PdvNerusServiceStop).ScriptBlock;
  $script:ServiceRealJournal=(Get-Command Save-PdvNerusServiceJournal).ScriptBlock;
  $script:ServiceRealWaitRunning=(Get-Command Wait-PdvNerusServiceRunning).ScriptBlock;
  $script:ServiceRealWaitStopped=(Get-Command Wait-PdvNerusServiceStopped).ScriptBlock;
  $script:ServiceRealExecutable=(Get-Command Get-PdvNerusServiceExecutable).ScriptBlock;
  function script:Get-PdvNerusNow{return $script:ServiceNow;}
  function script:Wait-PdvNerusFreshSample{$script:ServiceNow=$script:ServiceNow.AddMilliseconds(1100);}
  function script:Get-PdvNerusServiceRows {
    if($script:ServiceRowsFailure){throw 'PRIVATE WMI FAILURE';}
    if(-not $script:ServiceAbsent){New-Object PSObject -Property @{Name='NerusService';DisplayName=$script:ServiceDisplay;State=$script:ServiceState;ProcessId=$script:ServicePid;ServiceType=$script:ServiceType;StartMode=$script:ServiceStartMode;AcceptStop=$script:ServiceCanStop;PathName=$script:ServicePath};}
    if($script:ServiceOtherPid){New-Object PSObject -Property @{Name='OtherService';DisplayName='Outro';State='Running';ProcessId=$script:ServicePid;ServiceType='Own Process';AcceptStop=$true;PathName='C:\Other\Other.exe'};}
  }
  function script:Get-PdvNerusServiceExecutable {
    param([string]$ImagePath);
    $hash=Get-PdvNerusServiceTextHash $ImagePath;if($ImagePath -cne '"C:\Nerus\NerusService.exe" --PRIVATE-PASSWORD=DEMO'){$hash='d'*64;}
    return @{ExecutablePath='C:\Nerus\NerusService.exe';ExecutableHash=$script:ServiceExeHash;ConfigurationHash=$hash;ProcessName='NerusService'};
  }
  function script:Get-PdvNerusRestartPathInfo {param([string]$Path);return @{FullPath=$Path};}
  function script:Get-PdvNerusRestartFileHash {param([string]$Path);return ('a'*64);}
  function script:Get-PdvNerusServiceProcessIdentity {
    param([int]$ProcessId);
    if($script:ServiceOldGone -and $ProcessId -eq 222){throw (New-Object ArgumentException('offline absent'));}
    return @{ProcessId=$ProcessId;StartTimeTicks=$script:ServiceTicks;ExecutablePath=$script:ServiceProcessPath;ProcessName='NerusService'};
  }
  function script:Get-PdvNerusServiceControllerState {param([string]$ServiceName);return @{ActiveDependents=@($script:ServiceDependents);RequiredServices=@(@{Name='RPCSS';Running=$script:ServiceDependencyRunning})};}
  function script:Get-PdvNerusServiceProcessRows {if($script:ServiceChild){New-Object PSObject -Property @{ProcessId=333;ParentProcessId=222};}}
  function script:Get-PdvNerusServiceProcessDiagnostics {if($script:ServiceTray){return @{ProcessName='NérusWeb';ProcessId=777};};return @();}
  function script:Get-PdvNerusServiceModules {param([int]$ProcessId);return @{Complete=$script:ServiceModulesComplete;Items=@(@{Name='MP2032.dll';Version='1.2.3';Observed=$true},@{Name='CliSiTef32.dll';Version='4.0.0';Observed=$true})};}
  function script:Test-PdvNerusServicePermission {param([string]$ServiceName);return $script:ServicePermission;}
  function script:Get-PdvNerusFreshSnapshot {
    $script:ServiceSamples++;
    return (New-Object PSObject -Property @{InventoryComplete=$script:ServiceInventory;PresenceComplete=$true;Devices=@((New-Object PSObject -Property @{InstanceId='USB\SERVICE-DEMO';Port=$script:ServicePort;Present=$script:ServicePresent;PresenceKnown=$true;ProblemCode='0';Status='OK'}))});
  }
  function script:Get-PdvNerusProcesses {
    if($script:ServiceProcessFailure){throw 'PRIVATE process failure';}
    if($script:ServiceState -ceq 'Running'){New-Object PSObject -Property @{ProcessName='NerusService';Id=$script:ServicePid};}
    if($script:ServiceTefProcess){New-Object PSObject -Property @{ProcessName='clisitef';Id=888};}
    if($script:ServiceDuplicateProcess){New-Object PSObject -Property @{ProcessName='NerusService';Id=889};}
  }
  function script:Get-PdvNerusJobs {if($script:ServiceJobs){New-Object PSObject -Property @{Id=1};}}
  function script:Save-PdvNerusServiceJournal {
    param($Session,$Proposal,[string]$Stage);
    if($script:ServiceJournalFailStage -ceq $Stage){throw 'NerusServiceLocalStateWriteFailed';}
    & $script:ServiceRealJournal $Session $Proposal $Stage;$script:ServiceTrace.Add('journal:'+ $Stage);
  }
  function script:Invoke-PdvNerusServiceStop {
    param([string]$ServiceName);
    if($ServiceName -cne 'NerusService'){throw 'Wrong service';}
    $xml=[xml][IO.File]::ReadAllText((Join-Path $script:ServiceSession.DataDirectory 'nerus-servico-tentativas.xml'));
    if([string]@($xml.PdvNerusServiceJournal.Attempts.Attempt)[-1].stage -cne 'stop_requested'){throw 'Stop before durable journal';}
    $script:ServiceStops++;$script:ServiceTrace.Add('stop');
    if($script:ServiceStopRefused){throw 'NerusServiceStopRefused';}
    if(-not $script:ServiceStopTimeout){$script:ServiceState='Stopped';$script:ServicePid=0;$script:ServiceOldGone=$true;if($script:ServiceChangePrinterAfterStop){$script:ServiceSession.Config.Profiles[0].ExpectedPort='COM9';$script:ServicePort='COM9';}}
  }
  function script:Wait-PdvNerusServiceStopped {param($Expected,[int]$TimeoutMilliseconds);return (-not $script:ServiceStopTimeout);}
  function script:Invoke-PdvNerusServiceStart {
    param([string]$ServiceName);
    $xml=[xml][IO.File]::ReadAllText((Join-Path $script:ServiceSession.DataDirectory 'nerus-servico-tentativas.xml'));
    if([string]@($xml.PdvNerusServiceJournal.Attempts.Attempt)[-1].stage -cne 'start_requested'){throw 'Start before durable journal';}
    $script:ServiceStarts++;$script:ServiceTrace.Add('start');
    if($script:ServiceStartFailure){throw 'PRIVATE start failure';}
    $script:ServiceState='Running';$script:ServicePid=444;if($script:ServiceSharedAfterStart){$script:ServiceOtherPid=$true;}if(-not $script:ServiceSameCreation){$script:ServiceTicks=2000000;}
  }
  function script:Wait-PdvNerusServiceRunning {
    param($Expected,[int]$TimeoutMilliseconds);
    if($script:ServiceStartTimeout){throw 'NerusServiceStartTimeout';}
    return (& $script:ServiceRealWaitRunning $Expected 1);
  }
}
function Reset-Service {
  param([string]$Path='');if(-not $Path){$Path=Join-Path $temporary ([guid]::NewGuid().ToString('N'));};[void][IO.Directory]::CreateDirectory($Path);
  & $module {
    $script:ServiceNow=[DateTimeOffset]::Parse('2026-10-21T22:00:00-03:00');$script:ServiceDisplay='Nérus Service';$script:ServiceState='Running';$script:ServicePid=222;$script:ServiceTicks=1000000;
    $script:ServicePath='"C:\Nerus\NerusService.exe" --PRIVATE-PASSWORD=DEMO';$script:ServiceExeHash='a'*64;$script:ServiceProcessPath='C:\Nerus\NerusService.exe';$script:ServiceType='Own Process';$script:ServiceStartMode='Auto';$script:ServiceCanStop=$true;
    $script:ServiceRowsFailure=$false;$script:ServiceAbsent=$false;$script:ServiceTray=$false;$script:ServiceOtherPid=$false;$script:ServiceDependents=@();$script:ServiceDependencyRunning=$true;$script:ServiceChild=$false;
    $script:ServicePermission=$true;$script:ServiceInventory=$true;$script:ServicePort='COM8';$script:ServicePresent=$true;$script:ServiceTefProcess=$false;$script:ServiceDuplicateProcess=$false;$script:ServiceJobs=$false;$script:ServiceProcessFailure=$false;
    $script:ServiceChangePrinterAfterStop=$false;$script:ServiceSharedAfterStart=$false;
    $script:ServiceStops=0;$script:ServiceStarts=0;$script:ServiceSamples=0;$script:ServiceOldGone=$false;$script:ServiceStopTimeout=$false;$script:ServiceStopRefused=$false;$script:ServiceStartFailure=$false;$script:ServiceStartTimeout=$false;$script:ServiceSameCreation=$false;$script:ServiceJournalFailStage='';$script:ServiceModulesComplete=$true;
    $script:ServiceTrace=New-Object 'Collections.Generic.List[string]';
  };
  $s=New-Object PSObject -Property @{DataDirectory=$Path;HardwareMachineId='windows-machine-demo';LoggingHealthy=$true;MaintenanceArmed=$false;TickBusy=$false;Stopped=$false;UpdateStaged=$false;Config=(New-Object PSObject -Property @{Profiles=@((New-Object PSObject -Property @{Role='Impressora';InstanceId='USB\SERVICE-DEMO';ExpectedPort='COM8';RecoveryEnabled=$false}));BlockingProcessNames=@('NerusService','clisitef')})};
  & $module {param($session);$script:ServiceSession=$session;} $s;
  Initialize-PdvMonitorNerusServiceContext $s;return $s;
}
function Get-ServiceMetric([string]$Name){return (& $module {param($n);Get-Variable -Scope Script -Name ('Service'+$n) -ValueOnly;} $Name);}
function Bind-Service($s){[void](Save-PdvMonitorNerusServiceBinding $s 'NerusService');}
function Get-ServiceProposal($s){Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($null -ne $s.NerusService.Proposal) ('Sem proposta: '+$s.NerusService.Reason);return [string]$s.NerusService.Proposal.Id;}
function Assert-NoServiceEffects{Assert-Service ((Get-ServiceMetric Stops) -eq 0 -and (Get-ServiceMetric Starts) -eq 0) 'Executou acao sem condicoes';}
try {
  Test-Service 'descoberta somente leitura, vinculo sem argumentos e COM correta permite reinicio assistido' {
    $s=Reset-Service;$s.NerusService.Busy=$true;
    $d=Get-PdvMonitorNerusServiceDiscovery $s;Assert-Service ($d.Complete -and @($d.Candidates).Count -eq 1 -and $d.Candidates[0].Eligible) 'Descoberta incorreta';Assert-NoServiceEffects;
    Bind-Service $s;$bindingText=[IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-servico.xml'));
    Assert-Service ($bindingText -notmatch 'PRIVATE-PASSWORD|Arguments|PathName' -and $bindingText -match 'windows-machine-demo') 'Vazou argumentos ou perdeu identidade Windows';
    $id=Get-ServiceProposal $s;Assert-Service ($s.NerusService.Proposal.ActualPort -ceq 'COM8' -and $s.NerusService.Proposal.TefModuleObserved) 'Proposta perdeu evidencia';Assert-NoServiceEffects;
    Invoke-PdvMonitorNerusServiceApply $s $id;
    Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceRestarted') ('Falha: '+$s.NerusService.Reason);
    Assert-Service ((Get-ServiceMetric Stops) -eq 1 -and (Get-ServiceMetric Starts) -eq 1) 'Acao nao foi unica';
    $trace=Get-ServiceMetric Trace;Assert-Service ($trace.IndexOf('journal:stop_requested') -lt $trace.IndexOf('stop') -and $trace.IndexOf('journal:stopped') -lt $trace.IndexOf('journal:start_requested') -and $trace.IndexOf('journal:start_requested') -lt $trace.IndexOf('start')) 'Ordem nao duravel';
    Assert-Service ($s.NerusService.Result -match 'Confirme a impress' -and $null -eq $s.NerusService.Proposal -and -not $s.NerusService.Busy) 'Sucesso prometeu impressao ou perdeu exclusao';
    $text=[IO.File]::ReadAllText((Join-Path $s.DataDirectory 'nerus-servico-tentativas.xml'));Assert-Service ($text -notmatch 'PRIVATE|Arguments|NerusService.exe') 'Journal vazou argumento/caminho';
    Invoke-PdvMonitorNerusServiceApply $s $id;Assert-Service ((Get-ServiceMetric Stops) -eq 1 -and (Get-ServiceMetric Starts) -eq 1) 'Repetiu aprovacao';
  };
  Test-Service 'servico compartilhado, PID compartilhado, dependentes, filhos e dependencia parada bloqueiam' {
    foreach($condition in @('type','sharedpid','dependents','child','dependency','stopped','cannotstop','disabled')){
      $s=Reset-Service;Bind-Service $s;
      & $module {param($c);switch($c){'disabled'{$script:ServiceStartMode='Disabled';}'type'{$script:ServiceType='Share Process';}'sharedpid'{$script:ServiceOtherPid=$true;}'dependents'{$script:ServiceDependents=@('Other');}'child'{$script:ServiceChild=$true;}'dependency'{$script:ServiceDependencyRunning=$false;}'stopped'{$script:ServiceState='Stopped';$script:ServicePid=0;}'cannotstop'{$script:ServiceCanStop=$false;}}} $condition;
      Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($null -eq $s.NerusService.Proposal) ('Propos condicao: '+$condition);Assert-NoServiceEffects;
    }
  };
  Test-Service 'identidade de exe, ImagePath, PID e criacao alteradas depois da aprovacao abortam' {
    foreach($condition in @('exe','config','pid','creation')){
      $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;
      & $module {param($c);switch($c){'exe'{$script:ServiceExeHash='c'*64;}'config'{$script:ServicePath='"C:\Nerus\NerusService.exe" --NEW';}'pid'{$script:ServicePid=333;}'creation'{$script:ServiceTicks=1000001;}}} $condition;
      Invoke-PdvMonitorNerusServiceApply $s $id;Assert-Service ($s.NerusService.Reason -cne 'NerusServiceRestarted') 'Ignorou alteracao';Assert-NoServiceEffects;
    }
  };
  Test-Service 'permissao, pausa, manutencao, update e SQL pendente bloqueiam' {
    foreach($condition in @('permission','tick','stopped','maintenance','update','sql','restart','logging')){
      $s=Reset-Service;Bind-Service $s;
      switch($condition){'permission'{& $module {$script:ServicePermission=$false;};}'tick'{$s.TickBusy=$true;}'stopped'{$s.Stopped=$true;}'maintenance'{$s.MaintenanceArmed=$true;}'update'{$s.UpdateStaged=$true;}'sql'{$s | Add-Member NoteProperty NerusAutomation @{Healthy=$true;Pending=@{Phase='commit'}};}'restart'{$s | Add-Member NoteProperty NerusRestart @{Busy=$true};}'logging'{$s.LoggingHealthy=$false;}}
      Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($null -eq $s.NerusService.Proposal) ('Propos: '+$condition);Assert-NoServiceEffects;
    }
  };
  Test-Service 'COM divergente, impressora ausente/inventario parcial, TEF, duplicado e fila impedem' {
    foreach($condition in @('port','absent','inventory','tef','duplicate','jobs','processfailure')){
      $s=Reset-Service;Bind-Service $s;& $module {param($c);switch($c){'port'{$script:ServicePort='COM9';}'absent'{$script:ServicePresent=$false;}'inventory'{$script:ServiceInventory=$false;}'tef'{$script:ServiceTefProcess=$true;}'duplicate'{$script:ServiceDuplicateProcess=$true;}'jobs'{$script:ServiceJobs=$true;}'processfailure'{$script:ServiceProcessFailure=$true;}}} $condition;
      Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($null -eq $s.NerusService.Proposal) ('Propos: '+$condition);Assert-NoServiceEffects;
    }
  };
  Test-Service 'lista vazia e metadados DLL desconhecidos permitem somente proposta assistida' {
    $s=Reset-Service;Bind-Service $s;$s.Config.BlockingProcessNames=@();& $module {$script:ServiceModulesComplete=$false;};[void](Get-ServiceProposal $s);
    Assert-Service (-not $s.NerusService.Proposal.ModulesComplete) 'Desconhecido virou confirmado';Assert-NoServiceEffects;
  };
  Test-Service 'timeout de parada nao envia inicio e bloqueia operacao futura ou novo vinculo' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {$script:ServiceStopTimeout=$true;};Invoke-PdvMonitorNerusServiceApply $s $id;
    Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceStopTimeout' -and (Get-ServiceMetric Starts) -eq 0) ('Timeout iniciou servico; motivo='+$s.NerusService.Reason);
    & $module {$script:ServiceNow=$script:ServiceNow.AddHours(2);};Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($s.NerusService.Reason -ceq 'NerusServicePreviousUncertain') 'Tentou apos resultado incerto';
    $blocked=$false;try{Bind-Service $s;}catch{$blocked=$true;};Assert-Service $blocked 'Novo vinculo apagou pendencia';
  };
  Test-Service 'falha ou timeout no inicio nao repete comando e nao anuncia recuperacao' {
    foreach($condition in @('failure','timeout','samecreation')){
      $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {param($c);switch($c){'failure'{$script:ServiceStartFailure=$true;}'timeout'{$script:ServiceStartTimeout=$true;}'samecreation'{$script:ServiceSameCreation=$true;}}} $condition;Invoke-PdvMonitorNerusServiceApply $s $id;
      Assert-Service ((Get-ServiceMetric Stops) -eq 1 -and (Get-ServiceMetric Starts) -eq 1 -and $s.NerusService.Reason -cne 'NerusServiceRestarted') ('Repetiu ou anunciou sucesso; motivo='+$s.NerusService.Reason);
      Assert-Service (@($s.NerusService.Events.ToArray() | Where-Object {$_.Kind -ceq 'RecoveryFailed'}).Count -eq 1) 'Falha nao visivel protocolo';
    }
  };
  Test-Service 'journal invalido e falha de gravacao antes da parada impedem efeitos' {
    $s=Reset-Service;Bind-Service $s;[IO.File]::WriteAllText((Join-Path $s.DataDirectory 'nerus-servico-tentativas.xml'),'<bad/>');Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceJournalInvalid') 'Aceitou journal invalido';Assert-NoServiceEffects;
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {$script:ServiceJournalFailStage='stop_requested';};Invoke-PdvMonitorNerusServiceApply $s $id;Assert-NoServiceEffects;
  };
  Test-Service 'falha de gravacao depois da parada impede inicio' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {$script:ServiceJournalFailStage='stopped';};Invoke-PdvMonitorNerusServiceApply $s $id;
    Assert-Service ((Get-ServiceMetric Stops) -eq 1 -and (Get-ServiceMetric Starts) -eq 0 -and $s.NerusService.Reason -ceq 'NerusServiceLocalStateWriteFailed') 'Avancou sem estado';
  };
  Test-Service 'limites persistem ao recriar contexto e no maximo duas tentativas por hora' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;Invoke-PdvMonitorNerusServiceApply $s $id;
    $s.NerusService=$null;Initialize-PdvMonitorNerusServiceContext $s;Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceRateLimited') ('Reiniciar removeu limite; motivo='+$s.NerusService.Reason);
    & $module {$script:ServiceNow=$script:ServiceNow.AddMinutes(16);$script:ServiceOldGone=$false;$script:ServicePid=222;$script:ServiceTicks=1000000;};$id=Get-ServiceProposal $s;Invoke-PdvMonitorNerusServiceApply $s $id;
    & $module {$script:ServiceNow=$script:ServiceNow.AddMinutes(16);$script:ServiceOldGone=$false;$script:ServicePid=222;$script:ServiceTicks=1000000;};Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceRateLimited') ('Permitiu terceira tentativa; motivo='+$s.NerusService.Reason+'; stops='+(Get-ServiceMetric Stops)+'; starts='+(Get-ServiceMetric Starts));
  };
  Test-Service 'somente app bandeja e nome com acento sao diagnostico, nao alvo SCM inventado' {
    $s=Reset-Service;& $module {$script:ServiceAbsent=$true;$script:ServiceTray=$true;};$d=Get-PdvMonitorNerusServiceDiscovery $s;
    Assert-Service ($d.Complete -and $d.Reason -ceq 'NerusServiceTrayOnly' -and @($d.Processes).Count -eq 1 -and -not $d.Processes[0].IsWindowsService) 'Inventou servico de app bandeja';Assert-NoServiceEffects;
    Assert-Service (& $module {Test-PdvNerusServiceNerusName 'Nérus Web';}) 'Acento nao identificado';
  };
  Test-Service 'proposta expirada, ausente e ID diferente nao param' {
    foreach($condition in @('missing','expired','wrong')){
      $s=Reset-Service;Bind-Service $s;$id='';if($condition -cne 'missing'){$id=Get-ServiceProposal $s;};if($condition -ceq 'expired'){& $module {$script:ServiceNow=$script:ServiceNow.AddMinutes(3);};};if($condition -ceq 'wrong'){$id=[guid]::NewGuid().ToString();};Invoke-PdvMonitorNerusServiceApply $s $id;Assert-NoServiceEffects;
    }
  };
  Test-Service 'vinculo estrito, identidade Windows diferente e dado extra sao recusados' {
    $s=Reset-Service;Bind-Service $s;$s.HardwareMachineId='other-machine';Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($null -eq $s.NerusService.Proposal) 'Aceitou outra maquina';Assert-NoServiceEffects;
    $path=Join-Path $s.DataDirectory 'nerus-servico.xml';$text=[IO.File]::ReadAllText($path).Replace('</PdvNerusServiceBinding>','<Arguments>PRIVATE</Arguments></PdvNerusServiceBinding>');[IO.File]::WriteAllText($path,$text);$s.NerusService=$null;Initialize-PdvMonitorNerusServiceContext $s;Assert-Service (-not $s.NerusService.Healthy) 'Aceitou atributo extra';
  };
  Test-Service 'parser de ImagePath permite exe local entre aspas, recusa wrappers e ambiguo' {
    $s=Reset-Service;
    $real=& $module {$script:ServiceRealExecutable;};
    $value=& $module {& $script:ServiceRealExecutable '"C:\Nerus\NerusService.exe" --PRIVATE-ARG=DEMO';};Assert-Service ($value.ExecutablePath -ceq 'C:\Nerus\NerusService.exe' -and $value.ConfigurationHash.Length -eq 64) 'Parser caminho errado';
    foreach($path in @('C:\Program Files\Nerus\NerusService.exe','\\server\Nerus.exe','"C:\Windows\System32\cmd.exe" /c private')){
      $blocked=$false;try{& $module {param($p);& $script:ServiceRealExecutable $p;} $path;}catch{$blocked=$true;};Assert-Service $blocked ('Aceitou caminho: '+$path);
    }
  };
  Test-Service 'saida real do processo antigo e identidade nova sao verificadas nos waiters' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;$p=$s.NerusService.Proposal;
    & $module {$script:ServiceState='Stopped';$script:ServicePid=0;$script:ServiceOldGone=$true;};$ok=& $module {param($x);& $script:ServiceRealWaitStopped $x 1;} $p;Assert-Service $ok 'Nao comprovou saida';
    & $module {$script:ServiceOldGone=$false;};$ok=& $module {param($x);& $script:ServiceRealWaitStopped $x 1;} $p;Assert-Service (-not $ok) 'Estado Stopped foi tratado como saida sem prova';
  };
  Test-Service 'mudanca de porta/perfil depois da parada impede inicio automatico' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {$script:ServiceChangePrinterAfterStop=$true;};Invoke-PdvMonitorNerusServiceApply $s $id;
    Assert-Service ((Get-ServiceMetric Stops) -eq 1 -and (Get-ServiceMetric Starts) -eq 0 -and $s.NerusService.Reason -ceq 'NerusServicePrinterNotReady') 'Iniciou com novo perfil nao aprovado';
  };
  Test-Service 'PID compartilhado que surge apos inicio nao e tratado como sucesso' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;& $module {$script:ServiceSharedAfterStart=$true;};Invoke-PdvMonitorNerusServiceApply $s $id;
    Assert-Service ((Get-ServiceMetric Starts) -eq 1 -and $s.NerusService.Reason -ceq 'NerusServiceSharedProcess') 'Ignorou servico compartilhado apos inicio';
  };
  Test-Service 'queda depois de STOP persistido nao repete operacao ao reabrir monitor' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;$proposal=$s.NerusService.Proposal;
    & $module {param($session,$p);& $script:ServiceRealJournal $session $p 'stop_requested';} $s $proposal;
    $s.NerusService=$null;Initialize-PdvMonitorNerusServiceContext $s;Invoke-PdvMonitorNerusServiceProbe $s;
    Assert-Service ($s.NerusService.Reason -ceq 'NerusServicePreviousUncertain') 'Repetiu apos queda';Assert-NoServiceEffects;
  };
  Test-Service 'consultas incompletas e historico com entidade XML ou atributos extras bloqueiam' {
    $s=Reset-Service;& $module {$script:ServiceRowsFailure=$true;};$d=Get-PdvMonitorNerusServiceDiscovery $s;Assert-Service (-not $d.Complete) 'Falha virou consulta completa';Assert-NoServiceEffects;
    foreach($text in @('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///private">]><PdvNerusServiceJournal schemaVersion="1"><Attempts/></PdvNerusServiceJournal>','<PdvNerusServiceJournal schemaVersion="1" extra="x"><Attempts/></PdvNerusServiceJournal>')){
      $s=Reset-Service;Bind-Service $s;[IO.File]::WriteAllText((Join-Path $s.DataDirectory 'nerus-servico-tentativas.xml'),$text);Invoke-PdvMonitorNerusServiceProbe $s;Assert-Service ($s.NerusService.Reason -ceq 'NerusServiceJournalInvalid') 'Aceitou XML livre';Assert-NoServiceEffects;
    }
  };
  Test-Service 'parada nativa recusa identidade que mudou antes do SCM' {
    $s=Reset-Service;Bind-Service $s;$id=Get-ServiceProposal $s;$p=$s.NerusService.Proposal;& $module {$script:ServicePath='"C:\Nerus\NerusService.exe" --CHANGED';};
    $blocked=$false;try{& $module {param($x);& $script:ServiceRealStop 'NerusService' $x;} $p;}catch{$blocked=$true;};Assert-Service $blocked 'Enviou STOP apos troca de ImagePath';Assert-NoServiceEffects;
  };

} finally {Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue;}
if($failures.Count){foreach($f in $failures){Write-Output $f;};throw ($failures.Count.ToString()+' cenarios falharam');}
Write-Output ('PASS Nerus Service: '+$script:Cases+' cenarios; '+$script:Checks+' verificacoes offline.');
