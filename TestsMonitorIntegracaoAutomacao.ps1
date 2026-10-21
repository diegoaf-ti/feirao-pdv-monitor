#requires -Version 5.1
# Integração com módulos reais e adaptadores totalmente simulados.
# Não executa HTTP, DPAPI, processos, instalador, WinForms, SQL ou hardware.
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Runtime.psm1') -Force;
$runtime=Get-Module PdvMonitor.Runtime;
$nerus=& $runtime { Get-Module PdvMonitor.Nerus; };
if ($null -eq $nerus) { throw 'Módulo Nerus não foi importado pelo runtime'; }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('pdv-integracao-automacao-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($testRoot);
$script:Checks=0;
function Assert-Automation([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message; }; $script:Checks++; }
& $runtime {
  $script:TestNow=[DateTimeOffset]::Parse('2026-10-19T12:00:00-03:00');
  $script:Records=New-Object Collections.ArrayList; $script:UpdateChecks=New-Object Collections.ArrayList; $script:HealthCalls=New-Object Collections.ArrayList;
  $script:QueueFailure=$false; $script:LogFailureKind=''; $script:UpdateSucceeds=$true; $script:StageUpdate=$false;
  $script:InventoryComplete=$true;
  $script:RealWriteRecord=(Get-Command Write-PdvMonitorRecord).ScriptBlock;
  function script:Get-PdvRuntimeNow { return $script:TestNow; }
  function script:Initialize-PdvMonitorCentral {
    param($Session);
    $Session.Config.Central.Enabled=$true; $Session.Config.Central.Endpoint='https://mock.exemplo/api/pdv-monitor/ingest';
    $Session.Config.Central.AgentId='11111111-1111-1111-1111-111111111111'; $Session.Config.Central.StoreId='49'; $Session.Config.Central.Terminal='CX4901';
    return (New-Object PSObject -Property @{Success=$true;});
  }
  function script:Initialize-PdvMonitorUpdateTrust { param($DataDirectory,$PublicKeyPath); return 'MockPinned'; }
  function script:Get-PdvMonitorSnapshot {
    return (New-Object PSObject -Property @{Devices=@();Printers=@();ReservedPorts=@();Warnings=@();InventoryComplete=$script:InventoryComplete;PresenceComplete=$script:InventoryComplete;InventoryMode='Mock';Windows=(New-Object PSObject -Property @{Build=19045;IsAdministrator=$false;Caption='Windows mock';});});
  }
  function script:Get-PdvMonitorHardwareInventory { return (New-Object PSObject -Property @{Success=$false;Hardware=$null;}); }
  function script:Get-PdvMonitorNerusServiceDiscovery { param($Session); return @{Candidates=@();Processes=@();Complete=$true;Reason=''}; }
  function script:Update-PdvMonitorSoftware { param($Session,$Now); $Session.LastSoftwareAt=$Now; }
  function script:Publish-PdvMonitorSoftwareUpload { param($Session); }
  function script:Get-PdvMonitorWindowsEvents { param($Cursors,$MaxEventsPerChannel); return (New-Object PSObject -Property @{Events=@();Cursors=@{};ChannelStatus=@();Warnings=@();}); }
  function script:Invoke-PdvMonitorUpload { param($Session); return (New-Object PSObject -Property @{Success=$true;Reason='OutboxEmpty';Sent=0;}); }
  function script:Add-PdvMonitorOutboxRecord {
    param($Session,$Record);
    [void]$script:Records.Add($Record);
    if ($script:QueueFailure) { return (New-Object PSObject -Property @{Queued=$false;}); }
    $queue=Join-Path $Session.DataDirectory 'mock-outbox'; [void][IO.Directory]::CreateDirectory($queue);
    $xml=New-Object Xml.XmlDocument; $root=$xml.CreateElement('Event'); $root.SetAttribute('id',$Record.EventId); $root.SetAttribute('kind',$Record.Kind); [void]$xml.AppendChild($root);
    [IO.File]::WriteAllText((Join-Path $queue ($Record.EventId+'.xml')),$xml.OuterXml);
    return (New-Object PSObject -Property @{Queued=$true;});
  }
  function script:Write-PdvMonitorRecord {
    param($Session,$Kind,$Detail='',$Device=$null,$Role='',$Reason='',$WindowsEvent=$null);
    if ($Kind -ceq $script:LogFailureKind) { throw 'Falha de logger simulada'; }
    & $script:RealWriteRecord -Session $Session -Kind $Kind -Detail $Detail -Device $Device -Role $Role -Reason $Reason -WindowsEvent $WindowsEvent;
  }
  function script:Invoke-PdvMonitorUpdateCheck {
    param($Session,$ProgramDirectory,$CurrentVersion,$Enabled);
    [void]$script:UpdateChecks.Add((New-Object PSObject -Property @{At=$script:TestNow;Enabled=$Enabled;Version=$CurrentVersion;Program=$ProgramDirectory;}));
    return (New-Object PSObject -Property @{Success=$script:UpdateSucceeds;Reason=$(if($script:UpdateSucceeds){'UpdateUpToDate'}else{'UpdateDownloadUnavailable'});Version='0.3.1';Staged=$script:StageUpdate;});
  }
  function script:Write-PdvMonitorUpdateHealth { param($Session,$ProgramDirectory,$TickHealthy); [void]$script:HealthCalls.Add([bool]$TickHealthy); return [bool]$TickHealthy; }
  function script:Get-Process { throw 'Consulta real de processos proibida no teste'; }
  function script:Get-WmiObject { throw 'Consulta real WMI proibida no teste'; }
  function script:Invoke-PdvMonitorRestart { throw 'Reinício real proibido no teste'; }
};
& $nerus {
  $script:TestNow=[DateTimeOffset]::Parse('2026-10-19T12:00:00-03:00'); $script:PolicyEnabled=$true; $script:PolicyFailure=$false; $script:PolicyRequests=0;
  function script:Get-PdvNerusNow { return $script:TestNow; }
  function script:Invoke-PdvNerusHttp {
    param($Session,$Path,$Method='GET',$Body='');
    if ($Path -cne '/agent/policy') { throw 'Escrita/API inesperada no teste'; }
    $script:PolicyRequests++; if ($script:PolicyFailure) { throw 'NerusTransportUnavailable'; }
    $enabled='false'; if ($script:PolicyEnabled) { $enabled='true'; }
    return ('<PdvMonitorPolicy schemaVersion="1"><Enabled>false</Enabled><AutoUpdateEnabled>'+$enabled+'</AutoUpdateEnabled><WindowOpen>false</WindowOpen><Revision></Revision><InstanceId></InstanceId><HardwareId></HardwareId><ServerTime>'+$script:TestNow.ToString('o')+'</ServerTime><BlockingProcessNames></BlockingProcessNames><PortMappings></PortMappings></PdvMonitorPolicy>');
  }
  function script:Get-PdvNerusProcesses { throw 'Processos reais proibidos'; }
  function script:Get-PdvNerusJobs { throw 'Spooler real proibido'; }
  function script:Get-PdvNerusFreshSnapshot { throw 'Coleta real proibida'; }
};
function Set-TestTime([DateTimeOffset]$Now) { & $runtime { param($n); $script:TestNow=$n; } $Now; & $nerus { param($n); $script:TestNow=$n; } $Now; }
function Reset-TestMetrics {
  & $runtime { $script:Records.Clear();$script:UpdateChecks.Clear();$script:HealthCalls.Clear();$script:QueueFailure=$false;$script:LogFailureKind='';$script:UpdateSucceeds=$true;$script:StageUpdate=$false;$script:InventoryComplete=$true; };
  & $nerus { $script:PolicyEnabled=$true;$script:PolicyFailure=$false;$script:PolicyRequests=0; };
  Set-TestTime ([DateTimeOffset]::Parse('2026-10-19T12:00:00-03:00'));
}
function New-AutomationSession([string]$Name) {
  $data=Join-Path $testRoot $Name;
  return (Start-PdvMonitorSession -DataDirectory $data -ProgramDirectory (Join-Path $data 'programa'));
}
function Get-AutomationRecords([string]$Kind) {
  # Preserva explicitamente o array na saída da função: em 5.1/StrictMode um
  # único PSObject não fornece Count, e zero resultados normalmente vira null.
  $matches=@(& $runtime {
    param($k);
    foreach ($record in $script:Records) { if ($record.Kind -ceq $k) { $record; } }
  } $Kind);
  return ,$matches;
}
function Write-TestJournal($Session,[string]$Status='installed',[string]$Reason='UpdateHealthConfirmed') {
  $updates=Join-Path $Session.DataDirectory 'atualizacoes'; [void][IO.Directory]::CreateDirectory($updates);
  $xml=New-Object Xml.XmlDocument; $r=$xml.CreateElement('Update'); [void]$xml.AppendChild($r); $r.SetAttribute('status',$Status); $r.SetAttribute('version','0.3.1'); $r.SetAttribute('reason',$Reason); $r.SetAttribute('at','2026-10-19T12:00:00-03:00');
  [IO.File]::WriteAllText((Join-Path $updates 'estado.xml'),$xml.OuterXml);
}
try {
  Reset-TestMetrics;
  $none=Get-AutomationRecords 'ArrayContract';
  Assert-Automation ($none -is [object[]] -and $none.Count -eq 0) 'Helper de registros retorna array vazio em vez de null';
  & $runtime { [void]$script:Records.Add((New-Object PSObject -Property @{Kind='ArrayContract';})); };
  $one=Get-AutomationRecords 'ArrayContract';
  Assert-Automation ($one -is [object[]] -and $one.Count -eq 1 -and $one[0].Kind -ceq 'ArrayContract') 'Helper mantém array quando existe um único registro';
  & $runtime { [void]$script:Records.Add((New-Object PSObject -Property @{Kind='ArrayContract';})); };
  $many=Get-AutomationRecords 'ArrayContract';
  Assert-Automation ($many -is [object[]] -and $many.Count -eq 2) 'Helper mantém array para múltiplos registros';
  Reset-TestMetrics; $s=New-AutomationSession 'policy-six-hours';
  Assert-Automation (-not $s.AutoUpdateEnabled) 'Início não presume opt-in local';
  Invoke-PdvMonitorTick $s;
  Assert-Automation ($s.AutoUpdateEnabled -and (& $runtime {$script:UpdateChecks.Count;}) -eq 1) 'Política real parseada habilita consulta de atualização';
  $first=& $runtime {return $script:UpdateChecks[0];};
  Assert-Automation ($first.Enabled -and $first.Version -ceq $s.MonitorVersion -and $first.Program -ceq $s.ProgramDirectory) 'Runtime passa versão e caminho reais ao atualizador';
  Assert-Automation ($s.NextUpdateCheckAt -eq $first.At.AddHours(6)) 'Consulta bem-sucedida agenda seis horas';
  Set-TestTime $first.At.AddHours(5); Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:UpdateChecks.Count;}) -eq 1) 'Não repete consulta antes de seis horas';
  Set-TestTime $first.At.AddHours(6); Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:UpdateChecks.Count;}) -eq 2) 'Nova consulta ocorre na janela de seis horas';
  & $nerus { $script:PolicyEnabled=$false; }; Set-TestTime $first.At.AddHours(12); Invoke-PdvMonitorTick $s;
  Assert-Automation (-not $s.AutoUpdateEnabled -and (& $runtime {$script:UpdateChecks.Count;}) -eq 2) 'Revogar opt-in central impede consulta seguinte';

  Reset-TestMetrics; $s=New-AutomationSession 'policy-failure'; & $nerus {$script:PolicyFailure=$true;}; Invoke-PdvMonitorTick $s;
  Assert-Automation (-not $s.AutoUpdateEnabled -and (& $runtime {$script:UpdateChecks.Count;}) -eq 0) 'Falha na política não habilita atualização';
  Reset-TestMetrics; $s=New-AutomationSession 'update-backoff'; & $runtime {$script:UpdateSucceeds=$false;}; Invoke-PdvMonitorTick $s;
  $now=& $runtime {$script:TestNow;};
  Assert-Automation ($s.NextUpdateCheckAt -eq $now.AddMinutes(15)) 'Falha de download aguarda quinze minutos para nova consulta';

  Reset-TestMetrics; $s=New-AutomationSession 'maintenance'; $s.MaintenanceArmed=$true; $s.MaintenanceExpiresAt=([DateTimeOffset]::Parse('2026-10-19T12:15:00-03:00')); Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:UpdateChecks.Count;}) -eq 0) 'Manutenção manual impede consulta e preparação';
  Reset-TestMetrics; $s=New-AutomationSession 'pending-nerus'; Invoke-PdvMonitorTick $s;
  $s.NextUpdateCheckAt=[DateTimeOffset]::MinValue; $s.NerusAutomation.Pending=@{Phase='prepare';Body='{}';RequestId='22222222-2222-2222-2222-222222222222';}; $s.NerusAutomation.RetryAt=([DateTimeOffset]::Parse('2026-10-19T12:30:00-03:00')); Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:UpdateChecks.Count;}) -eq 1) 'Operação Nerus pendente impede consulta concorrente';

  Reset-TestMetrics; $s=New-AutomationSession 'health'; Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:HealthCalls.Count -eq 1 -and $script:HealthCalls[0];})) 'Rodada completa com log saudável confirma saúde';
  & $runtime {$script:InventoryComplete=$false;}; Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {-not $script:HealthCalls[$script:HealthCalls.Count-1];})) 'Inventário incompleto não confirma saúde';
  Reset-TestMetrics; $s=New-AutomationSession 'health-log-failure'; & $runtime {$script:LogFailureKind='Heartbeat';}; Invoke-PdvMonitorTick $s;
  Assert-Automation ((& $runtime {$script:HealthCalls.Count;}) -eq 0) 'Falha no logger antes de terminar rodada não confirma saúde';

  foreach ($pair in @(@('installed','UpdateHealthConfirmed','UpdateApplied'),@('rolledBack','UpdateHealthNotConfirmed','UpdateRollback'))) {
    Reset-TestMetrics; $s=New-AutomationSession ('journal-'+$pair[0]); Write-TestJournal $s $pair[0] $pair[1]; Invoke-PdvMonitorTick $s;
    $events=Get-AutomationRecords $pair[2];
    Assert-Automation ($events.Count -eq 1 -and [IO.File]::Exists((Join-Path $s.DataDirectory ('mock-outbox/'+$events[0].EventId+'.xml')))) ('Journal '+$pair[0]+' gera evento durável');
    $again=Start-PdvMonitorSession -DataDirectory $s.DataDirectory -ProgramDirectory $s.ProgramDirectory; Invoke-PdvMonitorTick $again;
    Assert-Automation ((Get-AutomationRecords $pair[2]).Count -eq 1) 'Reabrir monitor não repete resultado já persistido';
  }
  Reset-TestMetrics; $s=New-AutomationSession 'journal-log-failure'; Write-TestJournal $s; & $runtime {$script:LogFailureKind='UpdateApplied';}; Invoke-PdvMonitorTick $s;
  $marker=Join-Path $s.DataDirectory 'atualizacoes/ultimo-resultado-enviado.txt';
  Assert-Automation (-not [IO.File]::Exists($marker)) 'Falha de log não marca resultado como enviado';
  & $runtime {$script:LogFailureKind='';}; Invoke-PdvMonitorTick $s;
  Assert-Automation ((Get-AutomationRecords 'UpdateApplied').Count -eq 1 -and [IO.File]::Exists($marker)) 'Resultado é tentado novamente quando logger recupera';
  Reset-TestMetrics; $s=New-AutomationSession 'journal-queue-failure'; Write-TestJournal $s; & $runtime {$script:QueueFailure=$true;}; Invoke-PdvMonitorTick $s;
  $marker=Join-Path $s.DataDirectory 'atualizacoes/ultimo-resultado-enviado.txt';
  Assert-Automation (-not [IO.File]::Exists($marker)) 'Falha na fila central não marca resultado como enviado';
  & $runtime {$script:QueueFailure=$false;}; Invoke-PdvMonitorTick $s;
  $events=Get-AutomationRecords 'UpdateApplied';
  Assert-Automation ($events.Count -eq 2 -and [IO.File]::Exists((Join-Path $s.DataDirectory ('mock-outbox/'+$events[-1].EventId+'.xml')))) 'Fila recuperada recebe resultado preservado no journal';

  # Extrai somente a função do host; não executa o script da interface.
  $tokens=$null; $errors=$null; $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'MonitorPdv.ps1'),[ref]$tokens,[ref]$errors);
  $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Complete-PdvMonitorTickWorker'},$false);
  . ([scriptblock]::Create($definition.Extent.Text));
  $busyDefinition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-PdvMonitorNerusServiceBusy'},$false);
  . ([scriptblock]::Create($busyDefinition.Extent.Text)); $script:serviceWorker=$null;
  function Update-PdvMonitorView {};
  function Set-PdvMonitorControls { param($Enabled); };
  $script:ApplyCalls=New-Object Collections.ArrayList;
  function Start-PdvMonitorUpdateApply { param($Session,$ProgramDirectory,$Enabled,$OperationsIdle); [void]$script:ApplyCalls.Add([bool]$OperationsIdle); return [pscustomobject]@{Reason='MockWaiting';Started=$false;}; }
  $statusLabel=[pscustomobject]@{Text=''}; $form=[pscustomobject]@{}; $form | Add-Member -MemberType ScriptMethod -Name Close -Value { throw 'Não deve fechar interface no teste'; };
  foreach ($case in @('maintenance','pending','repair','idle')) {
    $script:closing=$false; $script:programDirectory='MOCK'; $script:session=[pscustomobject]@{UpdateStaged=$true;AutoUpdateEnabled=$true;MaintenanceArmed=($case -eq 'maintenance');NerusAutomation=@{Pending=$(if($case -eq 'pending'){@{Phase='prepare'}}else{$null})};UpdateStatus='';};
    if ($case -eq 'repair') { $script:session | Add-Member -MemberType NoteProperty -Name NerusRestart -Value @{Busy=$true}; }
    $script:worker=[pscustomobject]@{Streams=[pscustomobject]@{Error=@()}}; $script:worker | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value { param($r); }; $script:worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {};
    $script:workerResult=[pscustomobject]@{IsCompleted=$true}; Complete-PdvMonitorTickWorker;
    Assert-Automation ($script:ApplyCalls[$script:ApplyCalls.Count-1] -eq ($case -eq 'idle')) ('Host exige ociosidade: '+$case);
  }
  Assert-Automation ($null -eq $script:worker -and $null -eq $script:workerResult) 'Host libera worker antes de considerar aplicação';
  $before=$script:ApplyCalls.Count;
  $script:closing=$false; $script:session.AutoUpdateEnabled=$false;
  $script:worker=[pscustomobject]@{Streams=[pscustomobject]@{Error=@()}}; $script:worker | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {param($r);}; $script:worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {};
  $script:workerResult=[pscustomobject]@{IsCompleted=$true}; Complete-PdvMonitorTickWorker;
  Assert-Automation ($script:ApplyCalls.Count -eq $before) 'Host não aplica pacote quando política de atualização foi revogada';
  $script:session.AutoUpdateEnabled=$true;
  $script:worker=[pscustomobject]@{Streams=[pscustomobject]@{Error=@()}}; $script:worker | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {throw 'Worker ativo não pode terminar neste teste';}; $script:worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {throw 'Worker ativo não pode ser descartado';};
  $script:workerResult=[pscustomobject]@{IsCompleted=$false}; Complete-PdvMonitorTickWorker;
  Assert-Automation ($script:ApplyCalls.Count -eq $before -and $null -ne $script:worker) 'Coleta ainda em execução impede aplicar ou descartar worker';
  $script:worker=[pscustomobject]@{Streams=[pscustomobject]@{Error=@('Falha simulada de coleta')}}; $script:worker | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {param($r);}; $script:worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {};
  $script:workerResult=[pscustomobject]@{IsCompleted=$true}; Complete-PdvMonitorTickWorker;
  Assert-Automation ($script:ApplyCalls.Count -eq $before -and -not $script:closing) 'Coleta com erro mantém monitor aberto sem tentar atualização';


  # Exportação real com arquivos próprios; tokens/pendências nunca entram.
  Reset-TestMetrics; $s=New-AutomationSession 'export-secrets';
  $secret='TOKEN-DE-TESTE-NAO-EXPORTAR';
  [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'central-credencial.bin'),$secret);
  [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'nerus-automacao.xml'),$secret);
  [void][IO.Directory]::CreateDirectory((Join-Path $s.DataDirectory 'atualizacoes'));
  [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'atualizacoes/manifest.xml'),$secret);
  $out=Join-Path $testRoot 'exports'; [void][IO.Directory]::CreateDirectory($out); $exported=Export-PdvMonitorLogs $s $out;
  $exportNames=@([IO.Directory]::GetFiles($exported) | ForEach-Object {[IO.Path]::GetFileName($_)});
  Assert-Automation ($exportNames -notcontains 'central-credencial.bin' -and $exportNames -notcontains 'nerus-automacao.xml' -and $exportNames -notcontains 'manifest.xml') 'Exportação exclui credencial, pending Nerus e arquivos de atualização';
  foreach ($file in [IO.Directory]::GetFiles($exported)) { Assert-Automation (-not [IO.File]::ReadAllText($file).Contains($secret)) 'Nenhum arquivo exportado contém marcador de segredo'; }
  Write-Host ('PASS: '+$script:Checks+' verificações de integração entre política, runtime, host, atualização e exportação. HTTP/DPAPI/processos/SQL/hardware/interface/instalação reais não executados.');
} finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot,$true); } }
