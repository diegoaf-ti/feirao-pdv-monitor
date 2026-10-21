#requires -Version 5.1
# Testes offline: somente arquivos temporarios e mocks. Nunca consulta COM, WMI,
# processos, impressoras, DPAPI, HTTP ou banco reais.
$ErrorActionPreference='Stop';
Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Nerus.psm1') -Force;
$module=Get-Module PdvMonitor.Nerus;
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('pdv-nerus-test-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0; $script:Cases=0; $script:Failures=New-Object 'Collections.Generic.List[string]';
$instance='USB\VID_0B1B&PID_0003\PRINTER-DEMO';
$agentId='a1111111-1111-4111-8111-111111111111';
$revision='b2222222-2222-4222-8222-222222222222';
$ticket='c3333333-3333-4333-8333-333333333333';

function Assert-Nerus($Condition,[string]$Message) {
  $script:Checks++;
  if (-not $Condition) { throw $Message; }
}
function Test-NerusCase([string]$Name,[scriptblock]$Action) {
  $script:Cases++;
  try { & $Action; Write-Output ('OK: '+$Name); }
  catch { $script:Failures.Add($Name+': '+$_.Exception.Message+' ['+$_.ScriptStackTrace+']'); Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message); }
}
function New-TestDevice([string]$Id=$instance,[string]$Port='COM4',[bool]$Present=$true,[bool]$Known=$true) {
  return (New-Object PSObject -Property @{InstanceId=$Id;Port=$Port;Present=$Present;PresenceKnown=$Known;ProblemCode='0';Status='OK';Name='Bematech demonstracao'});
}
function New-TestSnapshot {
  return (New-Object PSObject -Property @{InventoryComplete=$true;PresenceComplete=$true;Devices=@((New-TestDevice))});
}
function New-TestComHistorySnapshot([bool]$ChangedIdentity=$false) {
  # Sequência inspirada no atendimento, com identidades e nomes fictícios.
  # Os oito registros antigos não representam oito equipamentos conectados.
  $devices=@();
  for ($i=0;$i -lt 8;$i++) {
    $oldId='USB\VID_0B1B&PID_0003\GHOST-DEMO-'+$i;
    if ($ChangedIdentity -and $i -eq 0) { $oldId=$instance; }
    $old=New-TestDevice $oldId 'COM8' $false $true; $old.ProblemCode='45'; $old.Status='Unknown';
    $devices+=@($old);
  }
  $activeId=$instance; $port='COM8';
  if ($ChangedIdentity) { $activeId='USB\VID_0B1B&PID_0003\OTHER-LOCATION-DEMO'; $port='COM9'; }
  $devices+=@((New-TestDevice $activeId $port));
  return (New-Object PSObject -Property @{InventoryComplete=$true;PresenceComplete=$true;Devices=$devices});
}
function Set-TestComHistoryPolicy {
  # 42 é valor sintético explícito: não representa COM menos um.
  $text=(New-TestPolicyXml).Replace('<Port>COM4</Port><FiscalDevice>3</FiscalDevice>','<Port>COM8</Port><FiscalDevice>42</FiscalDevice>');
  $fresh=New-TestComHistorySnapshot; $prepared=New-TestReply 'prepared' $ticket 'COM8' '42'; $configured=New-TestReply 'configured_pending_restart' $ticket 'COM8' '42';
  & $module {param($p,$s,$pr,$co);$script:TestPolicy=$p;$script:TestFreshSnapshot=$s;$script:TestPrepared=$pr;$script:TestConfigured=$co;} $text $fresh $prepared $configured;
}
function New-TestPolicyXml([bool]$Enabled=$true,[bool]$Updates=$false,[bool]$Window=$true) {
  $yes=([string]$Enabled).ToLowerInvariant(); $up=([string]$Updates).ToLowerInvariant(); $open=([string]$Window).ToLowerInvariant();
  return '<PdvMonitorPolicy schemaVersion="1"><ServerTime>2026-10-19T22:00:00-03:00</ServerTime><WindowOpen>'+ $open +'</WindowOpen><Enabled>'+$yes+'</Enabled><AutoUpdateEnabled>'+$up+'</AutoUpdateEnabled><Revision>'+$revision+'</Revision><InstanceId>'+[Security.SecurityElement]::Escape($instance)+'</InstanceId><HardwareId>machine-demo-001</HardwareId><PortMappings><Mapping><Port>COM4</Port><FiscalDevice>3</FiscalDevice></Mapping><Mapping><Port>COM5</Port><FiscalDevice>9</FiscalDevice></Mapping></PortMappings><BlockingProcessNames><Name>nerus</Name><Name>clisitef</Name></BlockingProcessNames><MaintenanceWindow><UtcOffsetMinutes>-180</UtcOffsetMinutes><Days><Day>1</Day></Days><Start>22:00</Start><End>23:00</End></MaintenanceWindow></PdvMonitorPolicy>';
}
function New-TestReply([string]$Status='configured_pending_restart',[string]$TicketId=$ticket,[string]$Port='COM4',[string]$After='3',[string]$Before='2') {
  return '<PdvMonitorRecovery schemaVersion="1"><Status>'+$Status+'</Status><TicketId>'+$TicketId+'</TicketId><ExpiresAt>2026-10-19T22:00:20-03:00</ExpiresAt><ActualPort>'+$Port+'</ActualPort><BeforeValue>'+$Before+'</BeforeValue><AfterValue>'+$After+'</AfterValue><Message>Resposta de teste; impressao nao confirmada.</Message></PdvMonitorRecovery>';
}

& $module {
  $script:RealSaveNerusState=(Get-Command Save-PdvNerusState).ScriptBlock;
  function script:Get-PdvNerusNow { return $script:TestNow; }
  function script:Get-PdvNerusProcesses {
    if ($script:TestProcessFailure) { throw 'Consulta simulada indisponivel'; }
    foreach ($name in $script:TestProcesses) { New-Object PSObject -Property @{ProcessName=$name}; }
  }
  function script:Get-PdvNerusJobs {
    if ($script:TestJobsFailure) { throw 'Spooler simulado indisponivel'; }
    for ($i=0;$i -lt $script:TestJobCount;$i++) { New-Object PSObject -Property @{Name='Trabalho de teste'}; }
  }
  function script:Get-PdvNerusFreshSnapshot {
    $script:TestFreshCalls++;
    return $script:TestFreshSnapshot;
  }
  function script:Wait-PdvNerusFreshSample {
    $script:TestWaits++;
    $script:TestNow=$script:TestNow.AddMilliseconds(1100);
    if ($script:TestOpenProcessAfterPrepare) { $script:TestProcesses=@('nerus'); }
    if ($script:TestQueueJobAfterPrepare) { $script:TestJobCount=1; }
  }
  function script:Save-PdvNerusState {
    param($Session,$State);
    if ($script:TestSaveFailure -or ($script:TestSaveFailurePhase -and $null -ne $State.Pending -and $State.Pending.Phase -ceq $script:TestSaveFailurePhase)) { throw 'Persistencia simulada indisponivel'; }
    & $script:RealSaveNerusState $Session $State;
  }
  function script:Invoke-PdvNerusHttp {
    param($Session,[string]$Path,[string]$Method='GET',[string]$Body='');
    $persisted=$false; $persistedBody=''; $persistedPhase='';
    $statePath=Join-Path $Session.DataDirectory 'nerus-automacao.xml';
    if ([IO.File]::Exists($statePath)) {
      try { $stateXml=[xml][IO.File]::ReadAllText($statePath); $persistedBody=[string]$stateXml.PdvNerusState.Body; $persistedPhase=[string]$stateXml.PdvNerusState.Phase; $persisted=($persistedBody -ceq $Body); } catch {}
    }
    $script:TestCalls.Add(@{Path=$Path;Method=$Method;Body=$Body;At=$script:TestNow;Persisted=$persisted;PersistedPhase=$persistedPhase});
    switch ($Path) {
      '/agent/policy' { if ($script:TestPolicyFailure) { throw $script:TestPolicyFailure; }; return $script:TestPolicy; }
      '/agent/nerus/prepare' {
        if ($script:TestPrepareResponses.Count) { $reply=$script:TestPrepareResponses.Dequeue(); if ($reply.ContainsKey('Throw')) { throw $reply.Throw; }; return $reply.Text; }
        return $script:TestPrepared;
      }
      '/agent/nerus/commit' {
        if ($script:TestCommitResponses.Count) { $reply=$script:TestCommitResponses.Dequeue(); if ($reply.ContainsKey('Throw')) { throw $reply.Throw; }; return $reply.Text; }
        return $script:TestConfigured;
      }
      default { throw 'Chamada HTTP inesperada no teste'; }
    }
  }
};
function Reset-NerusMocks {
  $policy=New-TestPolicyXml; $snapshot=New-TestSnapshot; $prepared=New-TestReply 'prepared'; $configured=New-TestReply;
  & $module {
    param($p,$s,$pr,$co);
    $script:TestNow=[DateTimeOffset]::Parse('2026-10-19T22:00:00-03:00');
    $script:TestPolicy=$p; $script:TestFreshSnapshot=$s; $script:TestPrepared=$pr; $script:TestConfigured=$co;
    $script:TestCalls=New-Object 'Collections.Generic.List[object]';
    $script:TestPrepareResponses=New-Object Collections.Queue; $script:TestCommitResponses=New-Object Collections.Queue;
    $script:TestProcesses=@();$script:TestJobCount=0;$script:TestProcessFailure=$false;$script:TestJobsFailure=$false;$script:TestSaveFailure=$false;
    $script:TestSaveFailurePhase='';$script:TestPolicyFailure='';$script:TestOpenProcessAfterPrepare=$false;$script:TestQueueJobAfterPrepare=$false;$script:TestWaits=0;$script:TestFreshCalls=0;
  } $policy $snapshot $prepared $configured;
}
function New-TestNerusSession([string]$Path='') {
  if (-not $Path) { $Path=Join-Path $temporary ([guid]::NewGuid().ToString('N')); }
  [void][IO.Directory]::CreateDirectory($Path);
  return (New-Object PSObject -Property @{
    DataDirectory=$Path;LoggingHealthy=$true;MaintenanceArmed=$false;HardwareMachineId='machine-demo-001';AutoUpdateEnabled=$false;
    Config=(New-Object PSObject -Property @{Central=(New-Object PSObject -Property @{Enabled=$true;AgentId=$agentId});Profiles=@((New-Object PSObject -Property @{Role='ImpressoraBematech';InstanceId=$instance;ExpectedPort='COM2'}))});
  });
}
function Invoke-NerusTicks($Session,$Snapshot,[int]$Count=3) {
  for ($i=0;$i -lt $Count;$i++) {
    & $module { param($s,$sn); $script:TestNow=$script:TestNow.AddSeconds(2); Invoke-PdvMonitorNerusAutomation $s $sn $script:TestNow; } $Session $Snapshot;
  }
}
function Get-NerusCalls([string]$Path='') {
  return @(& $module { param($p); foreach ($call in $script:TestCalls) { if (-not $p -or $call.Path -ceq $p) { $call; } }; } $Path);
}
function Get-NerusEvents($Session) { return @($Session.NerusAutomation.Events.ToArray()); }

try {
  Test-NerusCase 'politica valida preserva correspondencias explicitas' {
    Reset-NerusMocks;
    $p=& $module { param($text); ConvertFrom-PdvNerusPolicy $text; } (New-TestPolicyXml);
    Assert-Nerus ($p.Enabled -and $p.HardwareId -ceq 'machine-demo-001' -and $p.PortMappings['COM4'] -ceq '3' -and $p.PortMappings['COM5'] -ceq '9') 'Politica nao manteve portas e valores explicitos';
    foreach ($text in @('<!DOCTYPE a [<!ENTITY x SYSTEM "file:///inexistente">]><PdvMonitorPolicy>&x;</PdvMonitorPolicy>','<Other />',('x'*65537))) {
      $blocked=$false;try { & $module { param($x); Read-PdvNerusXml $x 'PdvMonitorPolicy'; } $text; } catch { $blocked=$true; }
      Assert-Nerus $blocked 'XML inseguro ou raiz/tamanho invalido foi aceito';
    }
  };
  Test-NerusCase 'exige tres leituras e recolhe antes de commit com estado duravel' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    Invoke-NerusTicks $s $sn 2;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Iniciou tentativa antes de tres leituras';
    Invoke-NerusTicks $s $sn 1;
    $pre=@(Get-NerusCalls '/agent/nerus/prepare');$com=@(Get-NerusCalls '/agent/nerus/commit');
    Assert-Nerus ($pre.Count -eq 1 -and $com.Count -eq 1) 'Handshake nao fez prepare e commit uma vez';
    Assert-Nerus ($pre[0].Persisted -and $pre[0].PersistedPhase -ceq 'prepare' -and $com[0].Persisted -and $com[0].PersistedPhase -ceq 'commit') 'HTTP enviado antes de persistir corpo/fase exatos';
    $pb=ConvertFrom-Json $pre[0].Body;$cb=ConvertFrom-Json $com[0].Body;
    Assert-Nerus ($pb.evidence.samples.Count -eq 3 -and $cb.evidence.samples.Count -eq 3) 'Quantidade de leituras nao corresponde ao contrato';
    Assert-Nerus ([DateTimeOffset]$cb.evidence.samples[2].observedAt -gt [DateTimeOffset]$pb.evidence.samples[2].observedAt) 'Commit reutilizou ultima leitura sem reconsulta';
    Assert-Nerus ($cb.ticketId -ceq $ticket -and $pb.evidence.hardwareId -ceq $s.HardwareMachineId) 'Ticket ou identidade da maquina nao foi preservado';
    Assert-Nerus ($null -eq $s.NerusAutomation.Pending) 'Resposta terminal nao concluiu pendencia';
    $notices=@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'});
    Assert-Nerus ($notices.Count -eq 1 -and $notices[0].Detail -match 'Impress.o ainda n.o confirmada') 'Resultado nao ressalva validacao de impressao';
  };
  Test-NerusCase 'leituras devem ser consecutivas completas e separadas por tempo' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    Invoke-NerusTicks $s $sn 2;
    $bad=New-TestSnapshot;$bad.InventoryComplete=$false;Invoke-NerusTicks $s $bad 1;
    Invoke-NerusTicks $s $sn 2;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Leitura incompleta nao zerou estabilidade';
    Invoke-NerusTicks $s $sn 1;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1) 'Tres leituras novas nao reconstruiram estabilidade';
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    for ($i=0;$i -lt 4;$i++) { & $module {param($session,$snapshot);Invoke-PdvMonitorNerusAutomation $session $snapshot $script:TestNow;} $s $sn; }
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Leituras com mesmo horario foram contadas como estaveis';
  };
  Test-NerusCase 'coleta desconhecida falha ou dispositivo ausente bloqueiam' {
    foreach ($case in @('inventory','presence','unknown','absent','stringbool','fault','status','unmapped','duplicate')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      switch ($case) {
        'inventory' {$sn.InventoryComplete=$false;}
        'presence' {$sn.PresenceComplete=$false;}
        'unknown' {$sn.Devices[0].PresenceKnown=$false;}
        'absent' {$sn.Devices[0].Present=$false;}
        'stringbool' {$sn.Devices[0].Present='True';}
        'fault' {$sn.Devices[0].ProblemCode='28';}
        'status' {$sn.Devices[0].Status='ERROR';}
        'unmapped' {$sn.Devices[0].Port='COM9';}
        'duplicate' {$sn.Devices=@($sn.Devices[0],(New-TestDevice));}
      }
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) ('Coleta insegura iniciou HTTP: '+$case);
    }
  };
  Test-NerusCase 'conflitos ativos desconhecidos e perfis locais bloqueiam; fantasma ausente nao' {
    foreach ($case in @('active','unknown','otherprofile','missingprofile','wrongrole','ghost')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      switch ($case) {
        'active' {$sn.Devices+=New-TestDevice 'USB\OTHER' 'COM4';}
        'unknown' {$sn.Devices+=New-TestDevice 'USB\OTHER' 'COM4' $false $false;}
        'otherprofile' {$s.Config.Profiles+=New-Object PSObject -Property @{Role='PinpadTEF';InstanceId='USB\OTHER';ExpectedPort='COM4'};}
        'missingprofile' {$s.Config.Profiles=@();}
        'wrongrole' {$s.Config.Profiles[0].Role='PinpadTEF';}
        'ghost' {$sn.Devices+=New-TestDevice 'USB\OLD' 'COM4' $false $true;}
      }
      Invoke-NerusTicks $s $sn;
      $expected=0;if ($case -ceq 'ghost') {$expected=1;}
      Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq $expected) ('Conflito/perfil/fantasma avaliado incorretamente: '+$case);
    }
  };
  Test-NerusCase 'diagnostico puro preserva amostra e explica cada bloqueio sem payload livre' {
    foreach ($case in @('inventory','presence','profilemissing','profileduplicate','role','identitymissing','identityduplicate','unknown','presentunknown','absent','fault','status','unmapped','activeconflict','unknownconflict','profileconflict')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;$expected='';
      switch ($case) {
        'inventory' {$sn.InventoryComplete=$false;$expected='NerusInventoryIncomplete';}
        'presence' {$sn.PresenceComplete=$false;$expected='NerusInventoryIncomplete';}
        'profilemissing' {$s.Config.Profiles=@();$expected='NerusPrinterProfileMissing';}
        'profileduplicate' {$s.Config.Profiles+=@($s.Config.Profiles[0]);$expected='NerusPrinterProfileAmbiguous';}
        'role' {$s.Config.Profiles[0].Role='PinpadTEF';$expected='NerusPrinterRoleInvalid';}
        'identitymissing' {$sn.Devices=@((New-TestDevice 'USB\OTHER-DEMO' 'COM4'));$expected='NerusDeviceNotFound';}
        'identityduplicate' {$sn.Devices+=@((New-TestDevice));$expected='NerusDeviceIdentityAmbiguous';}
        'unknown' {$sn.Devices[0].PresenceKnown=$false;$expected='NerusDevicePresenceUnknown';}
        'presentunknown' {$sn.Devices[0].Present='True';$expected='NerusDevicePresenceUnknown';}
        'absent' {$sn.Devices[0].Present=$false;$expected='NerusDeviceAbsent';}
        'fault' {$sn.Devices[0].ProblemCode='28';$expected='NerusDeviceUnhealthy';}
        'status' {$sn.Devices[0].Status='ERROR';$expected='NerusDeviceUnhealthy';}
        'unmapped' {$sn.Devices[0].Port='COM8';$expected='NerusPortMappingMissing';}
        'activeconflict' {$sn.Devices+=@((New-TestDevice 'USB\OTHER-DEMO' 'COM4'));$expected='NerusPortConflict';}
        'unknownconflict' {$sn.Devices+=@((New-TestDevice 'USB\OTHER-DEMO' 'COM4' $false $false));$expected='NerusPortConflict';}
        'profileconflict' {$s.Config.Profiles+=New-Object PSObject -Property @{Role='PinpadTEF';InstanceId='USB\OTHER-DEMO';ExpectedPort='COM4'};$expected='NerusProfilePortConflict';}
      }
      $sn.Devices[0].Name='PAYLOAD-LIVRE-NAO-ENVIAR';
      $policy=& $module {param($text);ConvertFrom-PdvNerusPolicy $text;} (New-TestPolicyXml);
      $diagnosis=& $module {param($session,$snapshot,$p);Get-PdvNerusSampleDiagnosis $session $snapshot $p $script:TestNow;} $s $sn $policy;
      $sample=& $module {param($session,$snapshot,$p);Get-PdvNerusSample $session $snapshot $p $script:TestNow;} $s $sn $policy;
      Assert-Nerus (-not $diagnosis.Eligible -and $null -eq $diagnosis.Sample -and $null -eq $sample -and $diagnosis.Reason -ceq $expected) ('Diagnostico/amostra nao preservou bloqueio: '+$case);
      Assert-Nerus (@(Get-NerusCalls).Count -eq 0) 'Helper puro iniciou HTTP';
      Invoke-NerusTicks $s $sn 6;
      $notices=@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryBlocked' -and $_.Reason -ceq $expected});
      Assert-Nerus ($notices.Count -eq 1 -and $notices[0].Detail -and $notices[0].Detail -notmatch 'PAYLOAD-LIVRE-NAO-ENVIAR') ('Bloqueio nao foi explicado/deduplicado com texto seguro: '+$case);
      Assert-Nerus (@(Get-NerusCalls | Where-Object {$_.Method -ceq 'POST'}).Count -eq 0 -and $s.NerusAutomation.Samples.Count -eq 0) ('Diagnostico bloqueado iniciou POST ou reteve estabilidade: '+$case);
    }
  };
  Test-NerusCase 'COM8 presente com oito fantasmas usa somente identidade e mapa explicitos' {
    Reset-NerusMocks;Set-TestComHistoryPolicy;$s=New-TestNerusSession;$sn=New-TestComHistorySnapshot;
    $s.Config.Profiles[0].ExpectedPort='COM8';
    $s.Config.Central | Add-Member -MemberType NoteProperty -Name Terminal -Value 'CXDEMO01';
    $s | Add-Member -MemberType NoteProperty -Name Hostname -Value 'WINDOWS-DEMO-OUTRO-NOME';
    $policy=& $module {$p=ConvertFrom-PdvNerusPolicy $script:TestPolicy;return $p;};
    $diagnosis=& $module {param($session,$snapshot,$p);Get-PdvNerusSampleDiagnosis $session $snapshot $p $script:TestNow;} $s $sn $policy;
    $sample=& $module {param($session,$snapshot,$p);Get-PdvNerusSample $session $snapshot $p $script:TestNow;} $s $sn $policy;
    Assert-Nerus ($sn.Devices.Count -eq 9 -and $diagnosis.Eligible -and $sample.actualPort -ceq 'COM8' -and $sample.instanceId -ceq $instance) 'Fantasmas bloquearam a identidade presente ou amostra mudou de contrato';
    Invoke-NerusTicks $s $sn;
    $prepare=@(Get-NerusCalls '/agent/nerus/prepare');$commit=@(Get-NerusCalls '/agent/nerus/commit');
    Assert-Nerus ($prepare.Count -eq 1 -and $commit.Count -eq 1) 'Identidade presente e mapa explicito nao chegaram ao handshake simulado';
    $body=ConvertFrom-Json $prepare[0].Body;
    Assert-Nerus ($body.evidence.hardwareId -ceq 'machine-demo-001' -and $body.evidence.samples[2].actualPort -ceq 'COM8' -and $s.Hostname -cne $s.Config.Central.Terminal) 'Nome Windows diferente do caixa impediu identidade fisica valida';
    Assert-Nerus ($s.NerusAutomation.Policy.PortMappings['COM8'] -ceq '42' -and @(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'}).Count -eq 1) 'Valor sintetico explicito foi substituido por formula de porta';
  };
  Test-NerusCase 'historico COM8 para outra identidade COM9 exige vinculo e mapa sem aliases' {
    foreach ($case in @('missingprofile','oldidentity','oldidentitymissing','unmapped')) {
      Reset-NerusMocks;Set-TestComHistoryPolicy;$s=New-TestNerusSession;$sn=New-TestComHistorySnapshot;$expected='';
      switch ($case) {
        'missingprofile' {$s.Config.Profiles=@();$expected='NerusPrinterProfileMissing';}
        'oldidentity' {$sn=New-TestComHistorySnapshot $true;$expected='NerusDeviceAbsent';}
        'oldidentitymissing' {$sn=New-TestComHistorySnapshot $true;$sn.Devices=@($sn.Devices | Where-Object {$_.InstanceId -cne $instance});$expected='NerusDeviceNotFound';}
        'unmapped' {& $module {$script:TestPolicy=$script:TestPolicy.Replace('<Port>COM8</Port><FiscalDevice>42</FiscalDevice>','<Port>COM4</Port><FiscalDevice>3</FiscalDevice>');};$expected='NerusPortMappingMissing';}
      }
      Invoke-NerusTicks $s $sn 6;
      $notices=@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryBlocked' -and $_.Reason -ceq $expected});
      Assert-Nerus ($notices.Count -eq 1 -and $s.NerusAutomation.Samples.Count -eq 0) ('Sequencia COM8/COM9 nao gerou bloqueio auditavel: '+$case);
      Assert-Nerus (@(Get-NerusCalls | Where-Object {$_.Method -ceq 'POST'}).Count -eq 0) ('Sequencia COM8/COM9 iniciou alteracao sem vinculo/mapa: '+$case);
      Assert-Nerus ($s.NerusAutomation.Policy.InstanceId -ceq $instance -and ($s.Config.Profiles.Count -eq 0 -or $s.Config.Profiles[0].InstanceId -ceq $instance)) 'Modelo/porta criou alias ou trocou identidade automaticamente';
    }
  };
  Test-NerusCase 'PDV aberto impressao pendente consultas falhas e manutencao impedem tentativa' {
    foreach ($case in @('process','jobs','processfailure','jobfailure','logging','maintenance','hardware','emptyhardware')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      switch ($case) {
        'process' {& $module {$script:TestProcesses=@('NeRuS');};}
        'jobs' {& $module {$script:TestJobCount=1;};}
        'processfailure' {& $module {$script:TestProcessFailure=$true;};}
        'jobfailure' {& $module {$script:TestJobsFailure=$true;};}
        'logging' {$s.LoggingHealthy=$false;}
        'maintenance' {$s.MaintenanceArmed=$true;}
        'hardware' {$s.HardwareMachineId='another-machine';}
        'emptyhardware' {$s.HardwareMachineId='';}
      }
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) ('Guarda ignorada: '+$case);
    }
  };
  Test-NerusCase 'nova consulta apos prepare bloqueia mudanca de porta processo e fila' {
    foreach ($case in @('port','unknown','process','jobs')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      switch ($case) {
        'port' {$fresh=New-TestSnapshot;$fresh.Devices[0].Port='COM5';& $module {param($v);$script:TestFreshSnapshot=$v;} $fresh;}
        'unknown' {$fresh=New-TestSnapshot;$fresh.Devices[0].PresenceKnown=$false;& $module {param($v);$script:TestFreshSnapshot=$v;} $fresh;}
        'process' {& $module {$script:TestOpenProcessAfterPrepare=$true;};}
        'jobs' {& $module {$script:TestQueueJobAfterPrepare=$true;};}
      }
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1 -and @(Get-NerusCalls '/agent/nerus/commit').Count -eq 0) ('Commit ignorou nova condicao: '+$case);
      Assert-Nerus ($null -eq $s.NerusAutomation.Pending) 'Rechecagem insegura deixou operacao pronta para repetir commit';
    }
  };
  Test-NerusCase 'atualizacao pode estar habilitada com correcao desativada' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    $text=New-TestPolicyXml $false $true $false;
    $text=$text -replace '<InstanceId>.*?</InstanceId>','<InstanceId />' -replace '<HardwareId>.*?</HardwareId>','<HardwareId />' -replace '<PortMappings>.*?</PortMappings>','<PortMappings />' -replace '<BlockingProcessNames>.*?</BlockingProcessNames>','<BlockingProcessNames />';& $module {param($v);$script:TestPolicy=$v;} $text;
    Invoke-NerusTicks $s $sn;
    Assert-Nerus ($s.AutoUpdateEnabled -and @(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Opt-in de update foi confundido com autorizacao de SQL';
    Reset-NerusMocks;$s=New-TestNerusSession;$text=New-TestPolicyXml $true $false $false;& $module {param($v);$script:TestPolicy=$v;} $text;
    Invoke-NerusTicks $s $sn;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Janela fechada nao bloqueou tentativa';
  };
  Test-NerusCase 'timeout de commit persiste operacao e reinicio consulta mesmo ticket e corpo' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    & $module {$script:TestCommitResponses.Enqueue(@{Throw='NerusTransportUnavailable'});};
    Invoke-NerusTicks $s $sn;
    $first=@(Get-NerusCalls '/agent/nerus/commit');
    Assert-Nerus ($first.Count -eq 1 -and $null -ne $s.NerusAutomation.Pending -and $s.NerusAutomation.Pending.Phase -ceq 'commit') 'Timeout perdeu ticket pendente';
    Assert-Nerus (@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'}).Count -eq 0) 'Timeout foi anunciado como configuracao aplicada';
    $restarted=New-TestNerusSession $s.DataDirectory;
    & $module {$script:TestNow=$script:TestNow.AddSeconds(61);};
    Invoke-NerusTicks $restarted $sn 1;
    $all=@(Get-NerusCalls '/agent/nerus/commit');
    Assert-Nerus ($all.Count -eq 2 -and $all[0].Body -ceq $all[1].Body -and @(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1) 'Reinicio criou outra operacao ou mudou o ticket/evidencia incertos';
    Assert-Nerus ($null -eq $restarted.NerusAutomation.Pending) 'Resposta idempotente nao concluiu estado';
  };
  Test-NerusCase 'estado pendente de outra instalacao nao pode ser reutilizado com nova chave' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    & $module {$script:TestCommitResponses.Enqueue(@{Throw='NerusTransportUnavailable'});};
    Invoke-NerusTicks $s $sn;
    $other=New-TestNerusSession $s.DataDirectory;$other.Config.Central.AgentId='e5555555-5555-4555-8555-555555555555';
    & $module {$script:TestNow=$script:TestNow.AddSeconds(61);};
    Invoke-NerusTicks $other $sn 1;
    Assert-Nerus (-not $other.NerusAutomation.Healthy -and @(Get-NerusCalls '/agent/nerus/commit').Count -eq 1) 'Ticket de outro AgentId foi reenviado com nova identidade';
    Assert-Nerus (@(Get-NerusEvents $other | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'}).Count -eq 0) 'Ticket de outra instalacao gerou sucesso local';
  };
  Test-NerusCase '401 e 403 nao significam parametro aplicado e nao criam novo ticket' {
    foreach ($code in @('NerusHttp401','NerusHttp403')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      & $module {param($v);$script:TestCommitResponses.Enqueue(@{Throw=$v});} $code;
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'}).Count -eq 0) ('Erro de autorizacao virou sucesso: '+$code);
      Assert-Nerus ($null -ne $s.NerusAutomation.Pending -and @(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1) ('Erro de autorizacao esqueceu operacao incerta: '+$code);
      Invoke-NerusTicks $s $sn 3;
      Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1 -and @(Get-NerusCalls '/agent/nerus/commit').Count -eq 1) 'Tentou nova operacao antes de consultar a pendente';
    }
  };
  Test-NerusCase 'estado danificado de outro agente ou prazo local futuro falha fechado' {
    foreach ($case in @('xml','otheragent','future','dtd')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      switch ($case) {
        'xml' {$text='<PdvNerusState><invalid>' ;}
        'otheragent' {$text='<PdvNerusState><AgentId>another-agent</AgentId><NextAttemptAt>2026-10-19T22:00:00-03:00</NextAttemptAt></PdvNerusState>';}
        'future' {$text='<PdvNerusState><AgentId>'+$agentId+'</AgentId><NextAttemptAt>2026-10-20T22:00:00-03:00</NextAttemptAt></PdvNerusState>';}
        'dtd' {$text='<!DOCTYPE a [<!ENTITY x SYSTEM "file:///inexistente">]><PdvNerusState>&x;</PdvNerusState>';}
      }
      [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'nerus-automacao.xml'),$text);
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (-not $s.NerusAutomation.Healthy -and @(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) ('Estado invalido permitiu tentativa: '+$case);
    }
  };
  Test-NerusCase 'resposta terminal com outro ticket porta ou valor nunca confirma escrita' {
    foreach ($case in @('ticket','port','value','schema')) {
      Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
      $reply=New-TestReply;
      switch ($case) {
        'ticket' {$reply=New-TestReply 'configured_pending_restart' 'd4444444-4444-4444-8444-444444444444';}
        'port' {$reply=New-TestReply 'configured_pending_restart' $ticket 'COM5';}
        'value' {$reply=New-TestReply 'configured_pending_restart' $ticket 'COM4' '9';}
        'schema' {$reply=$reply.Replace('schemaVersion="1"','schemaVersion="2"');}
      }
      & $module {param($v);$script:TestCommitResponses.Enqueue(@{Text=$v});} $reply;
      Invoke-NerusTicks $s $sn;
      Assert-Nerus (@(Get-NerusEvents $s | Where-Object {$_.Kind -ceq 'NerusRecoveryConfigured'}).Count -eq 0) ('Resposta nao vinculada foi aceita: '+$case);
      Assert-Nerus ($null -ne $s.NerusAutomation.Pending) ('Resposta nao vinculada descartou ticket incerto: '+$case);
    }
  };
  Test-NerusCase 'falha persistente ao gravar estado nunca envia prepare inclusive em retry' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    & $module {$script:TestSaveFailure=$true;};
    Invoke-NerusTicks $s $sn;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Enviou prepare antes de gravar estado';
    & $module {$script:TestNow=$script:TestNow.AddSeconds(61);};
    Invoke-NerusTicks $s $sn 1;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 0) 'Retry enviou prepare cujo estado nao foi persistido';
  };
  Test-NerusCase 'falha ao persistir transicao de prepare para commit impede envio e retry' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    & $module {$script:TestSaveFailurePhase='commit';};
    Invoke-NerusTicks $s $sn;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1 -and @(Get-NerusCalls '/agent/nerus/commit').Count -eq 0) 'Commit enviado sem gravar sua evidencia exata';
    Assert-Nerus (-not $s.NerusAutomation.Healthy) 'Falha da transicao nao bloqueou automacao local';
    & $module {$script:TestNow=$script:TestNow.AddSeconds(61);};
    Invoke-NerusTicks $s $sn 1;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/commit').Count -eq 0) 'Retry enviou commit cujo corpo duravel ainda era prepare';
  };
  Test-NerusCase 'cooldown local sobrevive reinicio sem nova tentativa em quinze minutos' {
    Reset-NerusMocks;$s=New-TestNerusSession;$sn=New-TestSnapshot;
    Invoke-NerusTicks $s $sn;
    $restarted=New-TestNerusSession $s.DataDirectory;
    Invoke-NerusTicks $restarted $sn 4;
    Assert-Nerus (@(Get-NerusCalls '/agent/nerus/prepare').Count -eq 1) 'Reinicio ignorou cooldown duravel';
  };
  Write-Output ('Nerus: '+$script:Cases+' cenarios; '+$script:Checks+' verificacoes; '+$script:Failures.Count+' falhas.');
  if ($script:Failures.Count -gt 0) { throw ($script:Failures -join [Environment]::NewLine); }
} finally {
  if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary,$true); }
  Remove-Module PdvMonitor.Nerus -ErrorAction SilentlyContinue;
}
