#requires -Version 5.1
# Somente mocks: nenhum WMI, BIOS, rede ou hardware real é consultado.
$ErrorActionPreference='Stop';
Import-Module (Join-Path $PSScriptRoot 'PdvMonitor.Inventario.psm1') -Force;
$module=Get-Module PdvMonitor.Inventario;
& $module {
  $script:Data=@{
    Win32_ComputerSystem=@([pscustomobject]@{Name='CX4901';Manufacturer='Fabricante';Model='Caixa';TotalPhysicalMemory=8589934592;UserName='NUNCA-COLETAR';});
    Win32_ComputerSystemProduct=@([pscustomobject]@{UUID='5bf944a7-d15b-454f-b42b-43d36a98f439'});
    Win32_BIOS=@([pscustomobject]@{SerialNumber='SN-TESTE'});
    Win32_OperatingSystem=@([pscustomobject]@{Caption='Windows 10';Version='10.0.19045';BuildNumber='19045';OSArchitecture='64-bit';LastBootUpTime=[datetime]'2026-10-15T12:00:00Z';SystemDrive='C:';SerialNumber='SEGREDO-PRODUCT-KEY';});
    Win32_Processor=@([pscustomobject]@{Name='CPU de teste';NumberOfCores=4;NumberOfLogicalProcessors=8});
    Win32_PhysicalMemory=@([pscustomobject]@{Capacity=8589934592;Manufacturer='RAM';PartNumber='PN1';SerialNumber='RAM1';Speed=2666});
    Win32_DiskDrive=@([pscustomobject]@{DeviceID='\\.\PHYSICALDRIVE0';Model='SSD';SerialNumber='DISK1';Size=256000000000;InterfaceType='SATA';Status='OK'});
    Win32_LogicalDisk=@([pscustomobject]@{DeviceID='C:';Size=255000000000;FreeSpace=90000000000});
    Win32_NetworkAdapter=@([pscustomobject]@{Name='Ethernet';MACAddress='AA:BB:CC:DD:EE:FF';AdapterType='Ethernet';PhysicalAdapter=$true;IPAddress='SEGREDO-IP';},[pscustomobject]@{Name='VPN';MACAddress='11:22:33:44:55:66';PhysicalAdapter=$false});
  };
  function script:Read-PdvHardwareClass { param($Class); return @($script:Data[$Class]); }
};
function Assert-Inventory($Condition,$Message) { if (-not $Condition) { throw $Message; } }
$result=Get-PdvMonitorHardwareInventory;
Assert-Inventory $result.Success 'Inventário válido com mocks';
$hardware=$result.Hardware; $json=ConvertTo-PdvHardwareJson $hardware; $parsed=ConvertFrom-Json $json;
Assert-Inventory ($parsed.hostname -eq 'CX4901' -and $parsed.cpu.cores -ceq '4' -and $parsed.memory.totalBytes -ceq '8589934592' -and @($parsed.networkAdapters).Count -eq 1) 'Campos estruturados, números em string e adaptadores físicos';
Assert-Inventory ($json -notmatch 'NUNCA-COLETAR|SEGREDO|UserName|IPAddress|ProductKey') 'Não serializa WMI, usuário, product key ou IP';
$hash=Get-PdvHardwareFingerprint $hardware;
$hardware.collectedAt='2026-10-16T15:00:00-03:00'; $hardware.os.lastBootAt='2026-10-16T14:00:00-03:00'; $hardware.systemVolume.freeBytes='1'; $hardware.warnings=@('Aviso novo');
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -ceq $hash) 'Espaço livre, captura, boot e avisos não alteram hash estático';
$hardware.memory.totalBytes='17179869184';
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -cne $hash) 'Alteração de memória muda identidade do inventário';
$hardware.disks=@(@{id='2';model='SSD2';serialNumber='SN2';sizeBytes='2';interfaceType='USB';status='OK'},@{id='1';model='SSD1';serialNumber='SN1';sizeBytes='1';interfaceType='USB';status='OK'});
$hash=Get-PdvHardwareFingerprint $hardware; $hardware.disks=@($hardware.disks[1],$hardware.disks[0]);
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -ceq $hash) 'Ordenação dos discos não gera mudança de hardware';
# Empates nas antigas chaves, diferença de maiúsculas e duplicatas preservadas.
$hardware.disks=@(@{id='1';model='SSD';serialNumber='SN';sizeBytes='100';interfaceType='USB';status='OK'},@{id='1';model='SSD';serialNumber='SN';sizeBytes='200';interfaceType='USB';status='OK'},@{id='1';model='ssd';serialNumber='sn';sizeBytes='300';interfaceType='USB';status='OK'});
$hardware.memory.modules=@(@{capacityBytes='1';manufacturer='RAM';partNumber='PN';serialNumber='SN';speedMHz='100'},@{capacityBytes='1';manufacturer='ram';partNumber='PN';serialNumber='SN';speedMHz='100'});
$hardware.networkAdapters=@(@{name='Rede';macAddress='AA:BB';adapterType='Ethernet'},@{name='Rede';macAddress='AA:BB';adapterType='Outro'},@{name='rede';macAddress='aa:bb';adapterType='Ethernet'});
$hash=Get-PdvHardwareFingerprint $hardware;
$hardware.disks=@($hardware.disks[2],$hardware.disks[0],$hardware.disks[1]);
$hardware.memory.modules=@($hardware.memory.modules[1],$hardware.memory.modules[0]);
$hardware.networkAdapters=@($hardware.networkAdapters[2],$hardware.networkAdapters[1],$hardware.networkAdapters[0]);
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -ceq $hash) 'Empates e maiúsculas em discos/RAM/rede não tornam o hash dependente da ordem';
$hardware.disks+=@($hardware.disks[0]);
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -cne $hash) 'Duplicatas reais continuam fazendo parte do inventário';
$hardware.disks=@($hardware.disks[0],$hardware.disks[1],$hardware.disks[2]);
$hardware.networkAdapters[0].name='REDE';
Assert-Inventory ((Get-PdvHardwareFingerprint $hardware) -cne $hash) 'Alteração real de maiúsculas não é descartada pelo comparador';

& $module { $script:Data.Win32_ComputerSystem[0].Name=('á'*63)+[char]0xd83d+[char]0xde80+[char]0; $script:Data.Win32_NetworkAdapter[0].MACAddress='INVÁLIDO/IP'; };
$result=Get-PdvMonitorHardwareInventory;
Assert-Inventory ($result.Hardware.hostname.Length -eq 63 -and $result.Hardware.networkAdapters[0].macAddress -ceq '') 'Sanitização de controles/MAC e truncamento sem cortar surrogate';
& $module { $script:Data.Win32_DiskDrive=@(1..30 | ForEach-Object { [pscustomobject]@{DeviceID=[string]$_;Model=('ç'*160);SerialNumber=('é'*128);Size=100;InterfaceType='SATA';Status='OK'} }); };
$result=Get-PdvMonitorHardwareInventory; $json=ConvertTo-PdvHardwareJson $result.Hardware;
Assert-Inventory ($result.Hardware.disks.Count -le 16 -and [Text.Encoding]::UTF8.GetByteCount($json) -le 32768 -and @($result.Hardware.warnings).Count -gt 0 -and (ConvertFrom-Json $json).schemaVersion -eq 2) 'Listas e bytes limitados mantendo JSON íntegro e cobertura explícita';
& $module { $script:Data.Win32_OperatingSystem=@(); };
$result=Get-PdvMonitorHardwareInventory;
Assert-Inventory (-not $result.Success -and $null -eq $result.Hardware) 'Falha essencial não entrega inventário vazio para substituir um válido';
Write-Host 'PASS: inventário estruturado com whitelist, strings, hash estático, ordenação, limites, Unicode e indisponibilidade. Nenhum hardware real consultado.';
