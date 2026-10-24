#requires -Version 5.1
# Arquivos temporários e mocks: sem Registro, WMI, Defender, rede ou equipamentos.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Runtime.psm1') -Force;
$module=Get-Module PdvMonitor.Runtime;
$temp=Join-Path ([IO.Path]::GetTempPath()) ('inventory-runtime-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($temp);$script:checks=0;
function Assert-InventoryRuntime($Value,$Message){if(-not $Value){throw $Message;};$script:checks++;}
& $module {
  $script:FixtureNow=[DateTimeOffset]::Parse('2026-10-22T18:00:00Z');
  $script:FixtureResult=$null;$script:FixtureHardware=$null;$script:QueueOk=$true;$script:Queued=0;$script:HardwareQueued=0;
  $script:UploadResult=@{Success=$false;Reason='SoftwareHttp404'};$script:Records=New-Object Collections.ArrayList;
  function script:Get-PdvRuntimeNow{return $script:FixtureNow;}
  function script:Get-PdvMonitorSoftwareInventory{return $script:FixtureResult;}
  function script:Get-PdvMonitorHardwareInventory{return $script:FixtureHardware;}
  function script:Set-PdvMonitorSoftwarePending{param($Session,$Software,$Fingerprint);$script:Queued++;return @{Success=$script:QueueOk;Queued=$script:QueueOk};}
  function script:Set-PdvMonitorHardwarePending{param($Session,$Hardware);$script:HardwareQueued++;return @{Success=$true;Queued=$true};}
  function script:Invoke-PdvMonitorSoftwareUpload{param($Session);return $script:UploadResult;}
  function script:Write-PdvMonitorRecord{param($Session,$Kind,$Detail='',$Device=$null,$Role='',$Reason='',$WindowsEvent=$null);[void]$script:Records.Add(@{Kind=$Kind;Reason=$Reason;Detail=$Detail});}
};
function New-InventorySoftware{
  return @{schemaVersion=1;snapshotId=[guid]::NewGuid().ToString();collectedAt='2026-10-21T18:00:00Z';complete=$true;coverage=@{machine=$true;currentUser=$true;otherUsers=$false;store=$false;portable=$false};apps=@(@{key='app-1';name='Aplicativo';version='1';publisher='Empresa';scope='machine';architecture='x64';reportedInstallDate=''});security=@{provider='Unavailable';status='unavailable';observedAt='2026-10-21T18:00:00Z';threats=@()};warnings=@()};
}
function Set-InventorySoftware($Software,$Fingerprint=('a'*64),$Success=$true){
  & $module {param($Software,$Fingerprint,$Success);$script:FixtureResult=@{Success=$Success;Software=$Software;Fingerprint=$Fingerprint;CoverageHealthy=$true};} $Software $Fingerprint $Success;
}
function Invoke-InventorySoftware($Session){& $module {param($Session);Update-PdvMonitorSoftware $Session $script:FixtureNow;$script:FixtureNow=$script:FixtureNow.AddMinutes(15);} $Session;}
function Count-InventoryRecords($Kind){return (& $module {param($Kind);@($script:Records|Where-Object{$_.Kind -ceq $Kind}).Count;} $Kind);}
try{
  $s=Start-PdvMonitorSession -DataDirectory (Join-Path $temp 'software');$s.Config.Central.Enabled=$true;
  $software=New-InventorySoftware;Set-InventorySoftware $software;Invoke-InventorySoftware $s;
  $full=Join-Path $s.DataDirectory 'inventario-software-completo.json';$first=[IO.File]::ReadAllText($full);
  Assert-InventoryRuntime ([IO.File]::Exists($full) -and (& $module {$script:Queued}) -eq 1 -and (Count-InventoryRecords 'SoftwareInventory') -eq 1) 'Primeira coleta completa persiste antes do envio, com um resumo';
  $software.collectedAt='2026-10-21T18:15:00Z';Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ((& $module {$script:Queued}) -eq 1 -and (Count-InventoryRecords 'SoftwareInventory') -eq 1) 'Horário novo com mesmo conteúdo não gera remessa ou evento repetido';
  $previousFull=[IO.File]::ReadAllText($full);$software.complete=$false;$software.apps=@();Set-InventorySoftware $software ('b'*64);Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ([IO.File]::ReadAllText($full) -ceq $previousFull -and $s.SoftwareStatus -match 'parcial') 'Consulta parcial preserva o último inventário completo';
  $software.complete=$true;$software.security=@{provider='MicrosoftDefender';status='available';observedAt='2026-10-21T18:30:00Z';threats=@(@{id='123';name='Threat de teste';severity='high';active=$true;actionSuccess=$false;lastSeenAt='2026-10-21T18:00:00Z';source='MicrosoftDefender'})};
  Set-InventorySoftware $software ('c'*64);Invoke-InventorySoftware $s;Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ((Count-InventoryRecords 'SecurityThreatDetected') -eq 1) 'Ameaça ativa do Defender gera um alerta por estado';
  $software.security.provider='Unavailable';$software.security.status='unavailable';$software.security.threats=@();Set-InventorySoftware $software ('d'*64);Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ((Count-InventoryRecords 'SecurityThreatStatusChanged') -eq 0 -and $s.SoftwareThreatSignatures.ContainsKey('123')) 'Proteção indisponível não presume ameaça resolvida';
  $software.security=@{provider='MicrosoftDefender';status='available';observedAt='2026-10-21T19:00:00Z';threats=@(@{id='123';name='Threat de teste';severity='high';active=$false;actionSuccess=$true;lastSeenAt='2026-10-21T18:00:00Z';source='MicrosoftDefender'})};
  Set-InventorySoftware $software ('e'*64);Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ((Count-InventoryRecords 'SecurityThreatStatusChanged') -eq 1) 'Atualização confirmada do antivírus registra mudança de estado';
  $queued=& $module {$script:Queued};$s=Start-PdvMonitorSession -DataDirectory $s.DataDirectory;
  Assert-InventoryRuntime ($s.SoftwareFingerprint -ceq ('e'*64) -and $s.SoftwareThreatSignatures.ContainsKey('123') -and $null -ne $s.SoftwareLastQueuedAt) 'Reabertura restaura resumo e assinaturas sem reler hardware ou proteção';
  Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ((& $module {$script:Queued}) -eq ($queued+1) -and (Count-InventoryRecords 'SecurityThreatStatusChanged') -eq 1) 'Reabertura consulta checkpoint do transporte uma vez e não duplica alerta do mesmo estado';
  $s.Config.Central.Enabled=$true;& $module {$script:QueueOk=$false};Set-InventorySoftware $software ('f'*64);Invoke-InventorySoftware $s;Invoke-InventorySoftware $s;
  $warnings=& $module {@($script:Records|Where-Object{$_.Reason -ceq 'SoftwareQueueFailed'}).Count};
  Assert-InventoryRuntime ($warnings -eq 1 -and $null -eq $s.SoftwareLastQueuedAt -and [IO.File]::Exists($full)) 'Falha da fila preserva inventário e alerta uma vez, com nova tentativa';
  $before=[IO.File]::ReadAllText((Join-Path $s.DataDirectory 'inventario-software.json'));$software.warnings=@('x'*140000);Set-InventorySoftware $software ('1'*64);Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ([IO.File]::ReadAllText((Join-Path $s.DataDirectory 'inventario-software.json')) -ceq $before) 'Documento excessivo não recorta JSON nem substitui os arquivos válidos';
  Set-InventorySoftware $null ('1'*64) $false;Invoke-InventorySoftware $s;
  Assert-InventoryRuntime ([IO.File]::ReadAllText((Join-Path $s.DataDirectory 'inventario-software.json')) -ceq $before) 'Indisponibilidade da coleta preserva os documentos anteriores';
  & $module {param($Session);Publish-PdvMonitorSoftwareUpload $Session;Publish-PdvMonitorSoftwareUpload $Session;} $s;
  $warnings=& $module {@($script:Records|Where-Object{$_.Reason -ceq 'SoftwareHttp404'}).Count};
  Assert-InventoryRuntime ($warnings -eq 1) 'API anterior gera somente um aviso por falha, sem interferir na fila de dispositivos';
  & $module {param($Session);$script:UploadResult=@{Success=$true;Reason='SoftwareAcknowledged'};Publish-PdvMonitorSoftwareUpload $Session;} $s;
  Assert-InventoryRuntime ((Count-InventoryRecords 'UploadResumed') -eq 1) 'Confirmação posterior registra retomada uma vez';

  # Hardware parcial: o servidor recebe as classes válidas e a cópia completa local permanece.
  $h=Start-PdvMonitorSession -DataDirectory (Join-Path $temp 'hardware');
  $hardware=@{schemaVersion=1;collectedAt='2026-10-21T12:00:00Z';machineId='';hostname='PC';manufacturer='Fabricante';model='Modelo';serialNumber='S1';os=@{caption='Windows';version='10';build='1';architecture='x64';lastBootAt=''};cpu=@{name='CPU';cores='4';logicalProcessors='8'};memory=@{totalBytes='8';modules=@()};disks=@();systemVolume=@{name='C:';totalBytes='100';freeBytes='50'};networkAdapters=@();warnings=@()};
  & $module {param($Session,$Hardware);$script:FixtureHardware=@{Success=$true;Hardware=$Hardware;CoverageHealthy=$true};Update-PdvMonitorHardware $Session $script:FixtureNow;} $h $hardware;
  $hpath=Join-Path $h.DataDirectory 'inventario-hardware.json';$old=[IO.File]::ReadAllText($hpath);$hash=$h.HardwareFingerprint;
  $hardware.schemaVersion=2;$hardware.baseboard=@{manufacturer='';product='';serialNumber='';version=''};$hardware.coverage=@{baseboard=$false;memoryModules=$true;cpu=$true;disks=$true;networkAdapters=$true};
  & $module {param($Session,$Hardware);$script:FixtureHardware=@{Success=$true;Hardware=$Hardware;CoverageHealthy=$false};Update-PdvMonitorHardware $Session $script:FixtureNow;Update-PdvMonitorHardware $Session $script:FixtureNow;} $h $hardware;
  Assert-InventoryRuntime ([IO.File]::ReadAllText($hpath) -ceq $old -and $h.HardwareFingerprint -ceq $hash -and [IO.File]::Exists((Join-Path $h.DataDirectory 'inventario-hardware-parcial.json'))) 'Hardware parcial não apaga a última visão completa nem inventa remoção';
  $partialWarnings=& $module {@($script:Records|Where-Object{$_.Reason -ceq 'MachineInventoryPartial'}).Count};
  Assert-InventoryRuntime ($partialWarnings -eq 1 -and (& $module {$script:HardwareQueued}) -eq 2 -and (Count-InventoryRecords 'HardwareChanged') -eq 0) 'Parte válida é enfileirada uma vez; cobertura incompleta não gera troca física';
  $hardware.coverage.baseboard=$true;$hardware.baseboard.serialNumber='BOARD1';
  & $module {param($Session,$Hardware);$script:FixtureHardware=@{Success=$true;Hardware=$Hardware;CoverageHealthy=$true};Update-PdvMonitorHardware $Session $script:FixtureNow;} $h $hardware;
  $extended=& $module {@($script:Records|Where-Object{$_.Reason -ceq 'MachineHardwareBaselineExtended'}).Count};
  Assert-InventoryRuntime ($extended -eq 1 -and (Count-InventoryRecords 'HardwareChanged') -eq 0 -and $h.HardwareStatus -ceq 'Inventário da máquina atualizado') 'Metadados novos de placa-mãe estendem a referência inicial, sem inventar substituição';
  $h2=Start-PdvMonitorSession -DataDirectory (Join-Path $temp 'upgrade-com-troca');$legacy=@{};
  foreach($key in $hardware.Keys){if(@('baseboard','coverage') -notcontains $key){$legacy[$key]=$hardware[$key];}};$legacy.schemaVersion=1;
  & $module {param($Session,$Hardware);$script:FixtureHardware=@{Success=$true;Hardware=$Hardware;CoverageHealthy=$true};Update-PdvMonitorHardware $Session $script:FixtureNow;} $h2 $legacy;
  $hardware.memory=@{totalBytes='16';modules=@()};
  & $module {param($Session,$Hardware);$script:FixtureHardware=@{Success=$true;Hardware=$Hardware;CoverageHealthy=$true};Update-PdvMonitorHardware $Session $script:FixtureNow;} $h2 $hardware;
  Assert-InventoryRuntime ((Count-InventoryRecords 'HardwareChanged') -eq 1) 'Troca real de RAM junto da atualização v1 para v2 continua registrada como mudança';
  Write-Output ('PASS: '+$script:checks+' verificações runtime: persistência, cobertura, proteção, hardware parcial e baseline ampliada; somente mocks.');
}finally{[IO.Directory]::Delete($temp,$true);}
