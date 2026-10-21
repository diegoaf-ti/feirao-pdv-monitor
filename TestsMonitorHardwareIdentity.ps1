#requires -Version 5.1
# Offline: classes WMI simuladas; nao consulta nem altera equipamentos reais.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Import-Module (Join-Path $directory 'PdvMonitor.Inventario.psm1') -Force;$module=Get-Module PdvMonitor.Inventario;
$script:Checks=0;$script:Cases=0;$failures=New-Object 'Collections.Generic.List[string]';
function Assert-Identity($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Test-Identity([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
& $module {
  function script:Read-PdvHardwareClass {param([string]$Class);if($script:IdentityFail -ceq $Class){throw 'PRIVATE WMI FAILURE';};return $script:IdentityData[$Class];}
}
function Reset-Identity {
  & $module {
    $script:IdentityFail='';$script:IdentityData=@{
      Win32_ComputerSystem=@((New-Object PSObject -Property @{Name='DEMO';Manufacturer='Fabricante';Model='Caixa';TotalPhysicalMemory=17179869184;UserName='SECRET_USER'}));
      Win32_ComputerSystemProduct=@((New-Object PSObject -Property @{UUID='5bf944a7-d15b-454f-b42b-43d36a98f439'}));
      Win32_BIOS=@((New-Object PSObject -Property @{SerialNumber='BIOS-DEMO'}));
      Win32_BaseBoard=@((New-Object PSObject -Property @{Manufacturer='Placa fabricante';Product='Placa modelo';SerialNumber='BOARD-111';Version='1.0';OtherConfig='SECRET_OTHER'}));
      Win32_OperatingSystem=@((New-Object PSObject -Property @{Caption='Windows 10';Version='10.0';BuildNumber='19045';OSArchitecture='64-bit';LastBootUpTime=[datetime]'2026-10-21T10:00:00Z';SystemDrive='C:';SerialNumber='SECRET_WINDOWS_KEY'}));
      Win32_Processor=@((New-Object PSObject -Property @{Name='CPU';Manufacturer='CPU fabricante';ProcessorId='CPU-ID-NOT-UNIQUE';SocketDesignation='CPU0';NumberOfCores=4;NumberOfLogicalProcessors=8}));
      Win32_PhysicalMemory=@((New-Object PSObject -Property @{Capacity=8589934592;Manufacturer='RAM';PartNumber='PN1';SerialNumber='RAM-111';Speed=2666;DeviceLocator='DIMM0';BankLabel='BANK0'}),(New-Object PSObject -Property @{Capacity=8589934592;Manufacturer='RAM';PartNumber='PN1';SerialNumber='RAM-222';Speed=2666;DeviceLocator='DIMM1';BankLabel='BANK1'}));
      Win32_DiskDrive=@((New-Object PSObject -Property @{DeviceID='DISK0';Model='SSD';SerialNumber='SSD-111';Size=256000000000;InterfaceType='SATA';Status='OK'}));
      Win32_LogicalDisk=@((New-Object PSObject -Property @{DeviceID='C:';Size=255000000000;FreeSpace=90000000000}));
      Win32_NetworkAdapter=@((New-Object PSObject -Property @{Name='Ethernet';MACAddress='AA:BB:CC:DD:EE:FF';AdapterType='Ethernet';PhysicalAdapter=$true}));
    };
  }
}
function Get-IdentityDocument {$r=Get-PdvMonitorHardwareInventory;Assert-Identity ($r.Success -and $r.Hardware.schemaVersion -eq 2) 'Inventario v2 ausente';return $r;}
try {
  Test-Identity 'placa-mae, soqueteCPU e slotsRAM sao explicitos sem substituir SMBIOSUUID' {
    Reset-Identity;$r=Get-IdentityDocument;$h=$r.Hardware;
    Assert-Identity ($h.machineId -ceq '5bf944a7-d15b-454f-b42b-43d36a98f439' -and $h.baseboard.serialNumber -ceq 'BOARD-111' -and $h.baseboard.product -ceq 'Placa modelo') 'Identidade confundida';
    Assert-Identity ($h.cpu.processorId -ceq 'CPU-ID-NOT-UNIQUE' -and $h.cpu.socketDesignation -ceq 'CPU0' -and $h.cpu.manufacturer -ceq 'CPU fabricante') 'CPU perdeu metadados';
    Assert-Identity ($h.memory.modules[0].deviceLocator -ceq 'DIMM0' -and $h.memory.modules[1].bankLabel -ceq 'BANK1') 'Slots nao coletados';
    Assert-Identity ($r.CoverageHealthy -and $h.coverage.baseboard -and $h.coverage.memoryModules -and $h.coverage.cpu -and $h.coverage.disks -and $h.coverage.networkAdapters) 'Cobertura falsa';
    Assert-Identity ((ConvertTo-PdvHardwareJson $h) -notmatch 'SECRET_|UserName|OtherConfig') 'Vazou campos fora whitelist';
  };
  Test-Identity 'troca de RAM com mesma capacidade altera fingerprint pelo numero de serie' {
    Reset-Identity;$a=Get-IdentityDocument;$hash=Get-PdvHardwareFingerprint $a.Hardware;& $module {$script:IdentityData.Win32_PhysicalMemory[0].SerialNumber='RAM-333';};$b=Get-IdentityDocument;
    Assert-Identity ($a.Hardware.memory.totalBytes -ceq $b.Hardware.memory.totalBytes -and (Get-PdvHardwareFingerprint $b.Hardware) -cne $hash -and $a.Hardware.machineId -ceq $b.Hardware.machineId) 'Troca de RAM desapareceu ou mudou computador';
  };
  Test-Identity 'movimentar modulo de RAM muda slot sem depender da ordem da consulta' {
    Reset-Identity;$a=Get-IdentityDocument;$hash=Get-PdvHardwareFingerprint $a.Hardware;& $module {[Array]::Reverse($script:IdentityData.Win32_PhysicalMemory);};$b=Get-IdentityDocument;
    Assert-Identity ((Get-PdvHardwareFingerprint $b.Hardware) -ceq $hash) 'Ordem incidental gerou mudanca';
    & $module {$script:IdentityData.Win32_PhysicalMemory[0].DeviceLocator='DIMM2';$script:IdentityData.Win32_PhysicalMemory[0].BankLabel='BANK2';};$c=Get-IdentityDocument;
    Assert-Identity ((Get-PdvHardwareFingerprint $c.Hardware) -cne $hash) 'Mudanca de slot nao identificada';
  };
  Test-Identity 'placa e CPU sao evidencias diferentes de identidade permanente do cadastro' {
    Reset-Identity;$a=Get-IdentityDocument;$hash=Get-PdvHardwareFingerprint $a.Hardware;& $module {$script:IdentityData.Win32_Processor[0].ProcessorId='ANOTHER-CPU-ID';};$b=Get-IdentityDocument;
    Assert-Identity ((Get-PdvHardwareFingerprint $b.Hardware) -cne $hash -and $a.Hardware.machineId -ceq $b.Hardware.machineId) 'CPU virou chave do computador';
    & $module {$script:IdentityData.Win32_BaseBoard[0].SerialNumber='BOARD-222';};$c=Get-IdentityDocument;
    Assert-Identity ($c.Hardware.baseboard.serialNumber -ceq 'BOARD-222' -and $c.Hardware.machineId -ceq $a.Hardware.machineId) 'Placa nao registrada ou UUID inventado';
  };
  Test-Identity 'falhas por classe deixam cobertura falsa em vez de afirmar remocao' {
    foreach($pair in @(@('Win32_BaseBoard','baseboard'),@('Win32_PhysicalMemory','memoryModules'),@('Win32_Processor','cpu'),@('Win32_DiskDrive','disks'),@('Win32_NetworkAdapter','networkAdapters'))){
      Reset-Identity;& $module {param($c);$script:IdentityFail=$c;} $pair[0];$r=Get-IdentityDocument;
      Assert-Identity (-not $r.Hardware.coverage[$pair[1]] -and -not $r.CoverageHealthy) ('Cobertura falsa para '+$pair[0]);
      Assert-Identity ((ConvertTo-PdvHardwareJson $r.Hardware) -notmatch 'PRIVATE WMI FAILURE') 'Excecao livre vazou';
    }
  };
  Test-Identity 'placa ausente ou multipla e lista RAM vazia sao identidade nao confirmada' {
    Reset-Identity;& $module {$script:IdentityData.Win32_BaseBoard=@();$script:IdentityData.Win32_PhysicalMemory=@();};$r=Get-IdentityDocument;
    Assert-Identity (-not $r.Hardware.coverage.baseboard -and -not $r.Hardware.coverage.memoryModules -and $r.Hardware.baseboard.serialNumber -ceq '') 'Ausencia foi identidade valida';
    Reset-Identity;& $module {$script:IdentityData.Win32_BaseBoard+=@($script:IdentityData.Win32_BaseBoard[0]);};$r=Get-IdentityDocument;Assert-Identity (-not $r.Hardware.coverage.baseboard) 'Placa multipla virou unica';
  };
  Test-Identity 'limites das listas marcam exatamente as classes de hardware parciais' {
    Reset-Identity;& $module {$script:IdentityData.Win32_PhysicalMemory=@(1..17 | ForEach-Object {New-Object PSObject -Property @{Capacity=1024;SerialNumber=('R'+$_);DeviceLocator=('D'+$_);BankLabel='B';Speed=1000}});};$r=Get-IdentityDocument;
    Assert-Identity (@($r.Hardware.memory.modules).Count -eq 16 -and -not $r.Hardware.coverage.memoryModules -and $r.Hardware.coverage.baseboard -and -not $r.CoverageHealthy) 'Limite RAM nao marcou cobertura';
  };
  Test-Identity 'metadados novos respeitam limites Unicode e JSON integral32KiB' {
    Reset-Identity;& $module {$script:IdentityData.Win32_BaseBoard[0].SerialNumber=('漢'*180);$script:IdentityData.Win32_BaseBoard[0].Manufacturer=('A'*200);$script:IdentityData.Win32_PhysicalMemory[0].DeviceLocator=('S'*100);$script:IdentityData.Win32_Processor[0].ProcessorId=('P'*150);};$r=Get-IdentityDocument;$json=ConvertTo-PdvHardwareJson $r.Hardware;
    Assert-Identity ($r.Hardware.baseboard.serialNumber.Length -le 128 -and $r.Hardware.baseboard.manufacturer.Length -le 120 -and $r.Hardware.memory.modules[0].deviceLocator.Length -le 80 -and $r.Hardware.cpu.processorId.Length -le 128 -and [Text.Encoding]::UTF8.GetByteCount($json) -le 32768) 'Campos novos excederam contrato';
    Assert-Identity (($json | ConvertFrom-Json).schemaVersion -eq 2) 'JSON nao integro';
  };
} finally {}
if($failures.Count){foreach($f in $failures){Write-Output $f;};throw ($failures.Count.ToString()+' cenarios hardware falharam');}
Write-Output ('PASS Hardware Identity: '+$script:Cases+' cenarios; '+$script:Checks+' verificacoes offline.');
