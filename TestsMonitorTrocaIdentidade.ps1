#requires -Version 5.1
# Offline: DPAPI e HTTP simulados; bytes/IDs reais de fixtures temporarias, sem coletar Windows.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Import-Module (Join-Path $directory 'PdvMonitor.Transporte.psm1') -Force;$module=Get-Module PdvMonitor.Transporte;
$root=[IO.Path]::GetTempPath();if([IO.Directory]::Exists('/private/tmp')){$root='/private/tmp';};$root=Join-Path $root ('pdv-identity-tests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);
$script:Checks=0;$script:Cases=0;
function Assert-Switch {param([bool]$Value,[string]$Name);$script:Checks++;if(-not $Value){throw $Name}}
function Hex-Switch {param([string]$Path);if(-not [IO.File]::Exists($Path)){return ''};return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))}
& $module {
  $script:RealMove=(Get-Command Move-PdvIdentitySwitchEntry).ScriptBlock;$script:RealAtomic=(Get-Command Write-PdvTransportAtomicBytes).ScriptBlock;$script:RealRecover=(Get-Command Recover-PdvIdentitySwitch).ScriptBlock;$script:RealDurable=(Get-Command Write-PdvIdentitySwitchDurableBytes).ScriptBlock;
  function script:Get-PdvInventoryStartupDelay {param($Central,$Kind);return 0}
  function script:Protect-PdvMonitorToken {param($Token,$Central);if($script:ProtectFailure){throw 'SIMULATED_PROTECTION_FAILURE'};$script:Tokens[$Central.AgentId]=$Token;$script:ProtectCalls++;$bytes=[Text.Encoding]::UTF8.GetBytes(($Central.AgentId+'|'+$Token+'|'+[Guid]::NewGuid().ToString()));$hash=[Security.Cryptography.SHA256]::Create();try{return ,([byte[]]@(17,42,99,7)+$hash.ComputeHash($bytes))}finally{$hash.Dispose()}}
  function script:Unprotect-PdvMonitorToken {param($Bytes,$Central);return $script:Tokens[$Central.AgentId]}
  function script:Invoke-PdvMonitorHttpPost {param($Endpoint,$Authorization,$Body);$script:Posts+=,@{Endpoint=$Endpoint;Authorization=$Authorization;Json=[Text.Encoding]::UTF8.GetString($Body)};return 204}
  function script:Move-PdvIdentitySwitchEntry {param($Source,$Destination,$Directory);& $script:RealMove $Source $Destination $Directory;$script:MoveCalls++;if($script:CrashMove -gt 0 -and $script:MoveCalls -eq $script:CrashMove){$script:BlockRecovery=$true;throw 'SIMULATED_CRASH_AFTER_MOVE'}}
  function script:Write-PdvIdentitySwitchDurableBytes {param($Path,$Bytes);if($script:FailWrite -and $Path -like $script:FailWrite){throw 'SIMULATED_WRITE_FAILURE'};& $script:RealDurable $Path $Bytes}
  function script:Write-PdvTransportAtomicBytes {param($Path,$Bytes);if($script:FailWrite -and $Path -like $script:FailWrite){throw 'SIMULATED_WRITE_FAILURE'};& $script:RealAtomic $Path $Bytes;if($script:CrashCommit -and $Path -ceq $script:RootConfig){$script:BlockRecovery=$true}}
  function script:Recover-PdvIdentitySwitch {param($Session);if($script:BlockRecovery -and [IO.File]::Exists((Join-Path $Session.DataDirectory 'identity-switch.xml'))){throw 'SIMULATED_PROCESS_UNAVAILABLE'};return (& $script:RealRecover $Session)}
}
function Reset-SwitchHooks {& $module {$script:CrashMove=0;$script:MoveCalls=0;$script:BlockRecovery=$false;$script:CrashCommit=$false;$script:FailWrite='';$script:ProtectFailure=$false;$script:Posts=@();$script:ProtectCalls=0;$script:Tokens=@{}}}
function New-SwitchRecord {param($Session,[string]$Kind='HardwareFault');$record=@{};& $module {return ,$script:PdvEventFields} | ForEach-Object {foreach($field in $_){$record[$field]=''}};$record.EventId=[Guid]::NewGuid().ToString('D');$record.SessionId=$Session.Id;$record.Timestamp='2026-10-24T10:00:00-03:00';$record.Sequence='1';$record.Kind=$Kind;$record.Role='Printer';$record.InstanceId='USB\BEMATECH\TEST';$record.DeviceName='Bematech fixture';$record.Port='COM8';return $record}
function New-SwitchFixture {
  Reset-SwitchHooks;$script:Cases++;$path=Join-Path $root ([Guid]::NewGuid().ToString('N'));$session=New-Object PSObject -Property @{DataDirectory=$path;Id=[Guid]::NewGuid().ToString('D');Config=@{}};
  Assert-Switch (Initialize-PdvMonitorCentral $session).Success 'Inicializacao da fixture';
  $old=[Guid]::NewGuid().ToString('D');$new=[Guid]::NewGuid().ToString('D');$oldToken=('0123456789abcdef'*4);$newToken=('fedcba9876543210'*4);
  Assert-Switch (Set-PdvMonitorCentralConfig $session 'https://conecta.example/api/pdv-monitor/ingest' '49' 'CX4901' $old $oldToken).Success 'Config antiga ficticia';
  & $module {param($Path);$script:RootConfig=Join-Path $Path 'central.xml'} $path;
  $record=New-SwitchRecord $session;Assert-Switch (Add-PdvMonitorOutboxRecord $session $record).Queued 'Evento antigo enfileirado';
  & $module {
    param($Session,$Old)
    $paths=Get-PdvTransportPaths $Session;$identity=@{AgentId=$Old;StoreId='49';Terminal='CX4901'}
    $hardware=$identity.Clone();$hardware.Fingerprint='a'*64;$hardware.HardwareJson='{"schemaVersion":1}';Write-PdvTransportAtomicBytes $paths.Hardware (New-PdvTransportXmlBytes 'PdvMonitorHardware' $hardware)
    $software=$identity.Clone();$software.Fingerprint='b'*64;$software.SnapshotId=[Guid]::NewGuid().ToString('D');$software.SoftwareJson='{"schemaVersion":1}';$software.PayloadHash=Get-PdvSoftwarePayloadHash $software.SoftwareJson;Write-PdvTransportAtomicBytes $paths.Software (New-PdvTransportXmlBytes 'PdvMonitorSoftware' $software)
    Save-PdvInventoryAcknowledged (Get-PdvCentralConfig $Session) $paths.HardwareAck ('c'*64);Save-PdvInventoryAcknowledged (Get-PdvCentralConfig $Session) $paths.SoftwareAck ('d'*64)
  } $session $old;
  $before=@{};foreach($name in @('central.xml','central-credencial.bin','hardware-pendente.xml','software-pendente.xml','hardware-confirmado.xml','software-confirmado.xml')){$before[$name]=Hex-Switch (Join-Path $path $name)}
  $before['outbox/'+$record.EventId+'.xml']=Hex-Switch (Join-Path (Join-Path $path 'outbox') ($record.EventId+'.xml'));
  return @{Session=$session;Old=$old;New=$new;Token=$newToken;OldToken=$oldToken;Before=$before;Record=$record}
}
function Invoke-SwitchFixture {param($Case,[bool]$Archive=$true);return (Set-PdvMonitorCentralConfig -Session $Case.Session -Endpoint 'https://conecta.example/api/pdv-monitor/ingest' -StoreId '49' -Terminal 'CX4901' -AgentId $Case.New -Token $Case.Token -ArchivePreviousIdentity:$Archive)}
function Assert-SwitchBytes {param($Before,[string]$Directory);foreach($key in $Before.Keys){Assert-Switch ((Hex-Switch (Join-Path $Directory $key)) -ceq $Before[$key]) ('Bytes preservados: '+$key)}}
function New-SwitchRestart {param($Case);& $module {$script:BlockRecovery=$false;$script:CrashCommit=$false;$script:CrashMove=0;$script:FailWrite=''};$session=New-Object PSObject -Property @{DataDirectory=$Case.Session.DataDirectory;Id=[Guid]::NewGuid().ToString('D');Config=@{}};$result=Initialize-PdvMonitorCentral $session;return @{Session=$session;Result=$result}}
try {
  $case=New-SwitchFixture;$result=Invoke-SwitchFixture $case $false;Assert-Switch (-not $result.Success -and $result.Reason -ceq 'PendingIdentityChange') 'Sem confirmacao explicita a troca permanece bloqueada';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;Assert-Switch (-not [IO.Directory]::Exists((Join-Path $case.Session.DataDirectory 'identidades-anteriores'))) 'Sem switch nao cria arquivo';
  $case=New-SwitchFixture;$result=Invoke-SwitchFixture $case;
  Assert-Switch ($result.Success -and $result.Reason -ceq 'ArquivoPreservado') 'Troca confirmada preserva arquivo';Assert-Switch ([IO.Directory]::Exists($result.ArchivePath)) 'Caminho de arquivo retornado';Assert-SwitchBytes $case.Before $result.ArchivePath;
  Assert-Switch ([IO.Directory]::GetFileSystemEntries($case.Session.OutboxPath).Length -eq 0) 'Nova fila comeca vazia';
  foreach($name in @('hardware-pendente.xml','software-pendente.xml','hardware-confirmado.xml','software-confirmado.xml')){Assert-Switch (-not [IO.File]::Exists((Join-Path $case.Session.DataDirectory $name))) 'Pendencias/checkpoints anteriores fora do escopo novo'}
  Assert-Switch ($case.Session.Config.Central.AgentId -ceq $case.New) 'Agente novo aplicado';
  Assert-Switch (-not [IO.File]::Exists((Join-Path $case.Session.DataDirectory 'identity-switch.xml')) -and [IO.File]::Exists((Join-Path $result.ArchivePath 'identity-switch.xml'))) 'Journal finalizado no arquivo';
  $public=$result | Out-String;Assert-Switch (-not $public.Contains($case.Token) -and -not $public.Contains($case.OldToken)) 'Resultado nao expoe credencial';
  $journal=[IO.File]::ReadAllText((Join-Path $result.ArchivePath 'identity-switch.xml'));Assert-Switch (-not $journal.Contains($case.Token) -and -not $journal.Contains($case.OldToken)) 'Journal nao expoe credencial';
  $newRecord=New-SwitchRecord $case.Session;Assert-Switch (Add-PdvMonitorOutboxRecord $case.Session $newRecord).Queued 'Nova fila recebe somente novo agente';Assert-Switch (Invoke-PdvMonitorUpload $case.Session).Success 'Nova fila enviada com ACK204 simulado';
  $posts=& $module {return ,$script:Posts};Assert-Switch ($posts.Count -eq 1 -and $posts[0].Json.Contains($newRecord.EventId) -and -not $posts[0].Json.Contains($case.Record.EventId) -and $posts[0].Authorization.StartsWith(('Bearer '+$case.New+'.'))) 'Eventos anteriores nao enviados sob outro agente';Assert-SwitchBytes $case.Before $result.ArchivePath;
  $again=Invoke-SwitchFixture $case;Assert-Switch ($again.Success -and $again.Reason -ceq 'Configured' -and [IO.Directory]::GetDirectories((Join-Path $case.Session.DataDirectory 'identidades-anteriores')).Length -eq 1) 'Repetir mesmo escopo nao duplica arquivo';
  $restart=New-SwitchRestart $case;Assert-Switch ($restart.Result.Success -and $restart.Session.Config.Central.AgentId -ceq $case.New) 'Reinicio mantem novo escopo';Assert-SwitchBytes $case.Before $result.ArchivePath;

  foreach($move in 1..5){
    $case=New-SwitchFixture;& $module {param($N);$script:CrashMove=$N} $move;$result=Invoke-SwitchFixture $case;Assert-Switch (-not $result.Success -and $result.Reason -ceq 'IdentitySwitchRecoveryRequired') ('Crash simulado apos movimento '+$move);
    Assert-Switch ([IO.File]::Exists((Join-Path $case.Session.DataDirectory 'identity-switch.xml'))) 'Journal sobrevive antes da recuperacao';
    $record=New-SwitchRecord $case.Session;Assert-Switch ((Add-PdvMonitorOutboxRecord $case.Session $record).Reason -ceq 'IdentitySwitchPending') 'Fila bloqueada durante recuperacao';Assert-Switch ((Invoke-PdvMonitorUpload $case.Session).Reason -ceq 'IdentitySwitchPending') 'Upload bloqueado durante recuperacao';Assert-Switch ((Invoke-PdvMonitorSoftwareUpload $case.Session).Reason -ceq 'IdentitySwitchPending') 'Software bloqueado durante recuperacao';
    $restart=New-SwitchRestart $case;Assert-Switch ($restart.Result.Success -and $restart.Session.Config.Central.AgentId -ceq $case.Old) 'Reinicio anterior a commit restaura escopo antigo';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;
    $again=Initialize-PdvMonitorCentral $restart.Session;Assert-Switch $again.Success 'Recuperacao repetida idempotente';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;
  }
  $case=New-SwitchFixture;& $module {$script:CrashMove=6};$result=Invoke-SwitchFixture $case;Assert-Switch ($result.Success -and $result.Reason -ceq 'ArquivoPreservado') 'Renomeacao final concluida nao e reportada como rollback';Assert-SwitchBytes $case.Before $result.ArchivePath;
  $case=New-SwitchFixture;& $module {$script:CrashCommit=$true};$result=Invoke-SwitchFixture $case;Assert-Switch (-not $result.Success -and $result.Reason -ceq 'IdentitySwitchRecoveryRequired') 'Crash apos cfg/cred novas conserva journal';
  $restart=New-SwitchRestart $case;Assert-Switch ($restart.Result.Success -and $restart.Session.Config.Central.AgentId -ceq $case.New) 'Reinicio apos commit finaliza sem desfazer config nova';
  $archives=[IO.Directory]::GetDirectories((Join-Path $case.Session.DataDirectory 'identidades-anteriores'));Assert-SwitchBytes $case.Before $archives[0];Assert-Switch ([IO.Directory]::GetFileSystemEntries($restart.Session.OutboxPath).Length -eq 0) 'Reinicio apos commit nao reativa fila antiga';

  $case=New-SwitchFixture;
  $hardware=@{schemaVersion=1;os=@{};systemVolume=@{};disks=@();networkAdapters=@();memory=@{totalBytes='0';modules=@()}};
  $fingerprint=& $module {param($Hardware);Get-PdvHardwareFingerprint $Hardware} $hardware;
  & $module {param($Session,$Fingerprint);$paths=Get-PdvTransportPaths $Session;Save-PdvInventoryAcknowledged (Get-PdvCentralConfig $Session) $paths.HardwareAck $Fingerprint} $case.Session $fingerprint;
  $case.Before['hardware-confirmado.xml']=Hex-Switch (Join-Path $case.Session.DataDirectory 'hardware-confirmado.xml');
  $result=Invoke-SwitchFixture $case;Assert-Switch $result.Success 'Troca com ACK patrimonial anterior';
  $queued=Set-PdvMonitorHardwarePending $case.Session $hardware;Assert-Switch ($queued.Success -and $queued.Reason -ceq 'HardwareQueued') 'ACK do agente anterior nao dispensa inventario do agente novo';
  Assert-SwitchBytes $case.Before $result.ArchivePath;
  $case=New-SwitchFixture;& $module {$script:CrashMove=1};[void](Invoke-SwitchFixture $case);
  $credential=Join-Path $case.Session.DataDirectory 'central-credencial.bin';[IO.File]::WriteAllBytes($credential,[byte[]]@(55,66,77));$beforeCredential=Hex-Switch $credential;
  $restart=New-SwitchRestart $case;Assert-Switch (-not $restart.Result.Success -and (Hex-Switch $credential) -ceq $beforeCredential) 'Credencial divergente bloqueia restauracao sem sobrescrever bytes';

  foreach($pattern in @('*identidades-anteriores*central.xml','*identity-switch.xml','*ROOT-CREDENTIAL*','*ROOT-CONFIG*')){
    $case=New-SwitchFixture;$fail=$pattern;if($pattern -ceq '*ROOT-CREDENTIAL*'){$fail=Join-Path $case.Session.DataDirectory 'central-credencial.bin'};if($pattern -ceq '*ROOT-CONFIG*'){$fail=Join-Path $case.Session.DataDirectory 'central.xml'};& $module {param($Pattern);$script:FailWrite=$Pattern} $fail;
    $result=Invoke-SwitchFixture $case;Assert-Switch (-not $result.Success) 'Falha de escrita nao informa sucesso';& $module {$script:FailWrite=''};$restart=New-SwitchRestart $case;Assert-Switch ($restart.Result.Success -and $restart.Session.Config.Central.AgentId -ceq $case.Old) 'Falha de escrita preserva/restaura escopo antigo';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;
  }
  $case=New-SwitchFixture;& $module {$script:ProtectFailure=$true};$result=Invoke-SwitchFixture $case;Assert-Switch (-not $result.Success) 'Falha de DPAPI impede mutacao';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;

  $case=New-SwitchFixture;& $module {$script:CrashMove=1};[void](Invoke-SwitchFixture $case);[void][IO.Directory]::CreateDirectory($case.Session.OutboxPath);$collision=Join-Path $case.Session.OutboxPath 'different.xml';[IO.File]::WriteAllText($collision,'DO NOT DELETE COLLISION');$beforeCollision=Hex-Switch $collision;
  $restart=New-SwitchRestart $case;Assert-Switch (-not $restart.Result.Success -and -not $restart.Session.Config.Central.Enabled) 'Colisao diferente bloqueia inicializacao/envio';Assert-Switch ((Hex-Switch $collision) -ceq $beforeCollision) 'Colisao diferente nao foi apagada';Assert-Switch ([IO.File]::Exists((Join-Path $case.Session.DataDirectory 'identity-switch.xml'))) 'Journal permanece para suporte';$archives=[IO.Directory]::GetDirectories((Join-Path $case.Session.DataDirectory 'identidades-anteriores'));Assert-Switch ((Hex-Switch (Join-Path $archives[0] ('outbox/'+$case.Record.EventId+'.xml'))) -ceq $case.Before['outbox/'+$case.Record.EventId+'.xml']) 'Fila antiga preservada apos colisao';
  $case=New-SwitchFixture;& $module {$script:CrashMove=1};[void](Invoke-SwitchFixture $case);$journalPath=Join-Path $case.Session.DataDirectory 'identity-switch.xml';[xml]$xml=[IO.File]::ReadAllText($journalPath);$xml.PdvMonitorIdentitySwitch.ArchiveId='../outside';[IO.File]::WriteAllText($journalPath,$xml.OuterXml);$restart=New-SwitchRestart $case;Assert-Switch (-not $restart.Result.Success) 'ArchiveId com traversal recusado';

  $case=New-SwitchFixture;$outside=Join-Path $root ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($outside);$link=Join-Path $case.Session.DataDirectory 'identidades-anteriores';$linked=$false;
  try{[void](New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop);$linked=$true}catch{}
  if($linked){$result=Invoke-SwitchFixture $case;Assert-Switch (-not $result.Success -and [IO.Directory]::GetFileSystemEntries($outside).Length -eq 0) 'Arquivo nao segue symlink';Assert-SwitchBytes $case.Before $case.Session.DataDirectory;[IO.Directory]::Delete($link)}
  Write-Output ('PASS: '+$script:Cases+' fixtures; '+$script:Checks+' verificacoes offline de troca de identidade; DPAPI/rede simulados.');
}finally{& $module {$script:PdvIdentitySwitchContext=$null};if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}}
