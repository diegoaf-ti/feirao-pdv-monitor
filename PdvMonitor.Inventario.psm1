#requires -Version 2.0
# Inventário empresarial somente leitura. Whitelist explícita; não serializa WMI.
function Get-PdvHardwareValue {
  param($Object, [string]$Name, $Default='');
  if ($null -eq $Object) { return $Default; }
  $property=$Object.PSObject.Properties[$Name]; if ($null -ne $property -and $null -ne $property.Value) { return $property.Value; }
  return $Default;
}

function ConvertTo-PdvHardwareText {
  param($Value, [int]$Maximum=160);
  $text=([string]$Value).Trim(); $builder=New-Object Text.StringBuilder;
  for ($i=0; $i -lt $text.Length; $i++) {
    $character=$text[$i]; if ([char]::IsControl($character)) { continue; }
    if ([char]::IsHighSurrogate($character)) {
      if (($i+1) -lt $text.Length -and [char]::IsLowSurrogate($text[$i+1])) {
        if (($builder.Length+2) -gt $Maximum) { break; }
        [void]$builder.Append($character); $i++; [void]$builder.Append($text[$i]); continue;
      }
      $character=[char]0xfffd;
    } elseif ([char]::IsLowSurrogate($character)) { $character=[char]0xfffd; }
    if ($builder.Length -ge $Maximum) { break; }; [void]$builder.Append($character);
  }
  return $builder.ToString();
}

function ConvertTo-PdvHardwareNumber {
  param($Value, [UInt64]$Maximum=[UInt64]::MaxValue);
  $text=[string]$Value; $number=[UInt64]0;
  if ($text -match '^\d{1,20}$' -and [UInt64]::TryParse($text,[ref]$number) -and $number -le $Maximum) { return $number.ToString([Globalization.CultureInfo]::InvariantCulture); }
  return '';
}

function ConvertTo-PdvHardwareTime {
  param($Value);
  if (-not $Value) { return ''; }
  try {
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToString('o'); }
    if ([string]$Value -match '^\d{14}\.\d{6}[+-]\d{3}$') {
      return ([DateTimeOffset][Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToString('o');
    }
    return ([DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)).ToString('o');
  } catch { return ''; }
}

function Read-PdvHardwareClass {
  param([string]$Class);
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { return @(Get-CimInstance -ClassName $Class -ErrorAction Stop); }
  return @(Get-WmiObject -Class $Class -ErrorAction Stop);
}

function ConvertTo-PdvHardwareJsonString {
  param([string]$Value);
  $builder=New-Object Text.StringBuilder; [void]$builder.Append('"');
  foreach ($character in $Value.ToCharArray()) {
    $code=[int]$character;
    if ($code -eq 34) { [void]$builder.Append('\"'); }
    elseif ($code -eq 92) { [void]$builder.Append('\\'); }
    elseif ($code -lt 32 -or $code -eq 8232 -or $code -eq 8233) { [void]$builder.Append(('\u{0:x4}' -f $code)); }
    else { [void]$builder.Append($character); }
  }
  [void]$builder.Append('"'); return $builder.ToString();
}

function ConvertTo-PdvHardwareJson {
  param($Value);
  if ($null -eq $Value) { return 'null'; }
  if ($Value -is [string]) { return (ConvertTo-PdvHardwareJsonString $Value); }
  if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant(); }
  if ($Value -is [ValueType]) { return ([string]$Value); }
  $parts=New-Object 'Collections.Generic.List[string]';
  if ($Value -is [Collections.IDictionary]) {
    foreach ($key in @($Value.Keys | Sort-Object)) { $parts.Add((ConvertTo-PdvHardwareJsonString ([string]$key))+':'+(ConvertTo-PdvHardwareJson $Value[$key])); }
    return '{'+[string]::Join(',',$parts.ToArray())+'}';
  }
  if ($Value -is [Collections.IEnumerable]) {
    foreach ($item in $Value) { $parts.Add((ConvertTo-PdvHardwareJson $item)); }; return '['+[string]::Join(',',$parts.ToArray())+']';
  }
  throw 'HardwareShapeUnsupported';
}

function Get-PdvHardwareFingerprint {
  param([Collections.IDictionary]$Hardware);
  # Campos voláteis não alteram a identidade do patrimônio nem causam incidentes.
  $copy=@{}; foreach ($key in $Hardware.Keys) { if (@('collectedAt','warnings') -notcontains $key) { $copy[$key]=$Hardware[$key]; } }
  $copy.os=@{}; foreach ($key in $Hardware.os.Keys) { if ($key -ne 'lastBootAt') { $copy.os[$key]=$Hardware.os[$key]; } }
  $copy.systemVolume=@{}; foreach ($key in $Hardware.systemVolume.Keys) { if ($key -ne 'freeBytes') { $copy.systemVolume[$key]=$Hardware.systemVolume[$key]; } }
  $copy.disks=@($Hardware.disks | Sort-Object id,serialNumber,model);
  $copy.networkAdapters=@($Hardware.networkAdapters | Sort-Object macAddress,name);
  $copy.memory=@{totalBytes=$Hardware.memory.totalBytes; modules=@($Hardware.memory.modules | Sort-Object serialNumber,partNumber,capacityBytes,speedMHz)};
  $sha=[Security.Cryptography.SHA256]::Create();
  try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-PdvHardwareJson $copy)))).Replace('-','').ToLowerInvariant(); }
  finally { $sha.Dispose(); }
}

function Get-PdvMonitorHardwareInventory {
  [CmdletBinding()]
  param();
  $data=@{}; $queryFailure=$false; $warnings=New-Object 'Collections.Generic.List[string]';
  foreach ($class in @('Win32_ComputerSystem','Win32_ComputerSystemProduct','Win32_BIOS','Win32_OperatingSystem','Win32_Processor','Win32_PhysicalMemory','Win32_DiskDrive','Win32_LogicalDisk','Win32_NetworkAdapter')) {
    try { $data[$class]=@(Read-PdvHardwareClass $class); }
    catch { $queryFailure=$true; $data[$class]=@(); $warnings.Add('Consulta indisponível: '+$class+'. Nenhuma mensagem livre foi coletada.'); }
  }
  if ($data.Win32_ComputerSystem.Count -ne 1 -or $data.Win32_OperatingSystem.Count -ne 1) {
    return (New-Object PSObject -Property @{Success=$false; Hardware=$null; Reason='MachineInventoryUnavailable'});
  }
  $computer=$data.Win32_ComputerSystem[0]; $os=$data.Win32_OperatingSystem[0];
  $product=$null; if ($data.Win32_ComputerSystemProduct.Count) { $product=$data.Win32_ComputerSystemProduct[0]; }
  $bios=$null; if ($data.Win32_BIOS.Count) { $bios=$data.Win32_BIOS[0]; }
  $cpu=$null; if ($data.Win32_Processor.Count) { $cpu=$data.Win32_Processor[0]; }
  $cores=0; $logical=0;
  foreach ($processor in $data.Win32_Processor) {
    $count=ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $processor 'NumberOfCores') 1024; if ($count) { $cores += [int]$count; }
    $count=ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $processor 'NumberOfLogicalProcessors') 1024; if ($count) { $logical += [int]$count; }
  }
  $modules=@();
  foreach ($module in @($data.Win32_PhysicalMemory | Select-Object -First 16)) {
    $modules += @{ capacityBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $module 'Capacity')); manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'Manufacturer') 120); partNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'PartNumber') 128); serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'SerialNumber') 128); speedMHz=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $module 'Speed') 100000); };
  }
  $disks=@();
  foreach ($disk in @($data.Win32_DiskDrive | Select-Object -First 16)) {
    $disks += @{ id=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $disk 'DeviceID') 128); model=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $disk 'Model') 160); serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $disk 'SerialNumber') 128); sizeBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $disk 'Size')); interfaceType=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $disk 'InterfaceType') 40); status=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $disk 'Status') 80); };
  }
  $adapters=@(); $physical=@($data.Win32_NetworkAdapter | Where-Object { (Get-PdvHardwareValue $_ 'PhysicalAdapter' $false) -eq $true });
  foreach ($adapter in @($physical | Select-Object -First 16)) {
    $mac=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $adapter 'MACAddress') 32); if ($mac -notmatch '^[A-Fa-f0-9:.-]*$') { $mac=''; }
    $adapters += @{ name=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $adapter 'Name') 160); macAddress=$mac; adapterType=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $adapter 'AdapterType') 80); };
  }
  $systemDrive=ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'SystemDrive') 2;
  if ($systemDrive -notmatch '^[A-Za-z]:$') { $systemDrive=''; }
  $volume=@($data.Win32_LogicalDisk | Where-Object { (Get-PdvHardwareValue $_ 'DeviceID') -eq $systemDrive -and $systemDrive });
  $volumeInfo=$null; if ($volume.Count -eq 1) { $volumeInfo=$volume[0]; }
  if ($data.Win32_PhysicalMemory.Count -gt 16 -or $data.Win32_DiskDrive.Count -gt 16 -or $physical.Count -gt 16) { $warnings.Add('Cobertura limitada aos primeiros 16 módulos, discos ou adaptadores físicos.'); }
  $hardware=@{
    schemaVersion=1; collectedAt=([DateTimeOffset]::Now.ToString('o'));
    machineId=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $product 'UUID') 128);
    hostname=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Name') 64);
    manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Manufacturer') 120);
    model=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Model') 160);
    serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $bios 'SerialNumber') 128);
    os=@{caption=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'Caption') 160);version=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'Version') 80);build=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'BuildNumber') 40);architecture=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'OSArchitecture') 40);lastBootAt=(ConvertTo-PdvHardwareTime (Get-PdvHardwareValue $os 'LastBootUpTime'));};
    cpu=@{name=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $cpu 'Name') 200);cores=(ConvertTo-PdvHardwareNumber $cores 1024);logicalProcessors=(ConvertTo-PdvHardwareNumber $logical 1024);};
    memory=@{totalBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $computer 'TotalPhysicalMemory'));modules=@($modules | Sort-Object serialNumber,partNumber,capacityBytes,speedMHz);};
    disks=@($disks | Sort-Object id,serialNumber,model);
    systemVolume=@{name=$systemDrive;totalBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $volumeInfo 'Size'));freeBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $volumeInfo 'FreeSpace'));};
    networkAdapters=@($adapters | Sort-Object macAddress,name); warnings=@($warnings.ToArray() | Select-Object -First 16);
  };
  if ($hardware.systemVolume.totalBytes -and $hardware.systemVolume.freeBytes -and [UInt64]$hardware.systemVolume.freeBytes -gt [UInt64]$hardware.systemVolume.totalBytes) {
    $hardware.systemVolume.freeBytes=''; $hardware.warnings=@($hardware.warnings)+@('Espaço livre inconsistente no volume do sistema; valor omitido.');
    $hardware.warnings=@($hardware.warnings | Select-Object -First 16);
  }
  # Limite em bytes reais, nunca recortar JSON. Reduzir apenas listas e sinalizar
  # cobertura antes de aceitar a estrutura local/transporte.
  $limited=$false;
  while ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-PdvHardwareJson $hardware)) -gt 32768) {
    if ($hardware.networkAdapters.Count -gt 0) { $hardware.networkAdapters=@($hardware.networkAdapters | Select-Object -First ($hardware.networkAdapters.Count-1)); }
    elseif ($hardware.disks.Count -gt 0) { $hardware.disks=@($hardware.disks | Select-Object -First ($hardware.disks.Count-1)); }
    elseif ($hardware.memory.modules.Count -gt 0) { $hardware.memory.modules=@($hardware.memory.modules | Select-Object -First ($hardware.memory.modules.Count-1)); }
    else { return (New-Object PSObject -Property @{Success=$false;Hardware=$null;Reason='MachineInventoryTooLarge'}); }
    $limited=$true; $hardware.warnings=@('Inventário limitado a 32 KiB; parte das listas de hardware foi omitida.');
  }
  return (New-Object PSObject -Property @{Success=$true;Hardware=$hardware;Reason='Collected';CoverageHealthy=(-not $queryFailure)});
}

Export-ModuleMember -Function Get-PdvMonitorHardwareInventory, ConvertTo-PdvHardwareJson, Get-PdvHardwareFingerprint;
