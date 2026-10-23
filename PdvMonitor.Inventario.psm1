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
    if ($Value -is [DateTimeOffset]) { return $Value.ToString('o'); }
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

function Get-PdvHardwareCanonicalArray {
  param([object[]]$Items);
  # O hash compara conteúdo, nunca a ordem incidental retornada pelo WMI.
  # Sort-Object por nomes de propriedades não lê chaves de hashtable no PS5.1
  # e chaves primárias podem empatar. Comparar o JSON canônico inteiro com
  # Ordinal preserva duplicatas, distingue maiúsculas e independe da cultura.
  $canonical=New-Object 'Collections.Generic.List[string]';
  foreach ($item in @($Items)) { $canonical.Add((ConvertTo-PdvHardwareJson $item)); }
  $canonical.Sort([StringComparer]::Ordinal);
  return ,$canonical.ToArray();
}

function Get-PdvHardwareFingerprint {
  param([Collections.IDictionary]$Hardware);
  # Campos voláteis não alteram a identidade do patrimônio nem causam incidentes.
  $copy=@{}; foreach ($key in $Hardware.Keys) { if (@('collectedAt','warnings') -notcontains $key) { $copy[$key]=$Hardware[$key]; } }
  $copy.os=@{}; foreach ($key in $Hardware.os.Keys) { if ($key -ne 'lastBootAt') { $copy.os[$key]=$Hardware.os[$key]; } }
  $copy.systemVolume=@{}; foreach ($key in $Hardware.systemVolume.Keys) { if ($key -ne 'freeBytes') { $copy.systemVolume[$key]=$Hardware.systemVolume[$key]; } }
  $copy.disks=Get-PdvHardwareCanonicalArray @($Hardware.disks);
  $copy.networkAdapters=Get-PdvHardwareCanonicalArray @($Hardware.networkAdapters);
  $copy.memory=@{totalBytes=$Hardware.memory.totalBytes; modules=(Get-PdvHardwareCanonicalArray @($Hardware.memory.modules))};
  $sha=[Security.Cryptography.SHA256]::Create();
  try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-PdvHardwareJson $copy)))).Replace('-','').ToLowerInvariant(); }
  finally { $sha.Dispose(); }
}

function Get-PdvMonitorHardwareInventory {
  [CmdletBinding()]
  param();
  $data=@{}; $querySucceeded=@{}; $queryFailure=$false; $warnings=New-Object 'Collections.Generic.List[string]';
  foreach ($class in @('Win32_ComputerSystem','Win32_ComputerSystemProduct','Win32_BIOS','Win32_BaseBoard','Win32_OperatingSystem','Win32_Processor','Win32_PhysicalMemory','Win32_DiskDrive','Win32_LogicalDisk','Win32_NetworkAdapter')) {
    try { $data[$class]=@(Read-PdvHardwareClass $class);$querySucceeded[$class]=$true; }
    catch { $queryFailure=$true;$querySucceeded[$class]=$false; $data[$class]=@(); $warnings.Add('Consulta indisponível: '+$class+'. Nenhuma mensagem livre foi coletada.'); }
  }
  if ($data.Win32_ComputerSystem.Count -ne 1 -or $data.Win32_OperatingSystem.Count -ne 1) {
    return (New-Object PSObject -Property @{Success=$false; Hardware=$null; Reason='MachineInventoryUnavailable'});
  }
  $computer=$data.Win32_ComputerSystem[0]; $os=$data.Win32_OperatingSystem[0];
  $product=$null; if ($data.Win32_ComputerSystemProduct.Count) { $product=$data.Win32_ComputerSystemProduct[0]; }
  $bios=$null; if ($data.Win32_BIOS.Count) { $bios=$data.Win32_BIOS[0]; }
  $board=$null;if($data.Win32_BaseBoard.Count){$board=@($data.Win32_BaseBoard | Sort-Object -Property SerialNumber,Product,Manufacturer,Version)[0];}
  $coverage=@{baseboard=([bool]$querySucceeded.Win32_BaseBoard -and $data.Win32_BaseBoard.Count -eq 1);memoryModules=([bool]$querySucceeded.Win32_PhysicalMemory -and $data.Win32_PhysicalMemory.Count -gt 0 -and $data.Win32_PhysicalMemory.Count -le 16);cpu=([bool]$querySucceeded.Win32_Processor -and $data.Win32_Processor.Count -eq 1);disks=([bool]$querySucceeded.Win32_DiskDrive -and $data.Win32_DiskDrive.Count -le 16);networkAdapters=[bool]$querySucceeded.Win32_NetworkAdapter};
  if(-not $coverage.baseboard){$warnings.Add('Identidade da placa-mãe não confirmada como única; ausência ou múltiplos resultados não comprovam troca.');}
  if(-not $coverage.cpu){$warnings.Add('Cobertura de CPU incompleta ou múltiplos soquetes; o objeto informa somente um processador e totais agregados.');}
  if(-not $coverage.memoryModules){$warnings.Add('Cobertura dos módulos de RAM incompleta; uma lista vazia não comprova remoção.');}
  $cpu=$null; if ($data.Win32_Processor.Count) { $cpu=@($data.Win32_Processor | Sort-Object -Property SocketDesignation,ProcessorId,Name)[0]; }
  $cores=0; $logical=0;
  foreach ($processor in $data.Win32_Processor) {
    $count=ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $processor 'NumberOfCores') 1024; if ($count) { $cores += [int]$count; }
    $count=ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $processor 'NumberOfLogicalProcessors') 1024; if ($count) { $logical += [int]$count; }
  }
  $modules=@();
  foreach ($module in @($data.Win32_PhysicalMemory | Select-Object -First 16)) {
    $modules += @{ capacityBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $module 'Capacity')); manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'Manufacturer') 120); partNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'PartNumber') 128); serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'SerialNumber') 128); speedMHz=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $module 'Speed') 100000);deviceLocator=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'DeviceLocator') 80);bankLabel=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $module 'BankLabel') 80); };
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
  if($physical.Count -gt 16){$coverage.networkAdapters=$false;}
  if ($data.Win32_PhysicalMemory.Count -gt 16 -or $data.Win32_DiskDrive.Count -gt 16 -or $physical.Count -gt 16) { $warnings.Add('Cobertura limitada aos primeiros 16 módulos, discos ou adaptadores físicos.'); }
  $hardware=@{
    schemaVersion=2; collectedAt=([DateTimeOffset]::Now.ToString('o'));
    coverage=$coverage;
    baseboard=@{manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $board 'Manufacturer') 120);product=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $board 'Product') 160);serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $board 'SerialNumber') 128);version=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $board 'Version') 128)};
    machineId=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $product 'UUID') 128);
    hostname=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Name') 64);
    manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Manufacturer') 120);
    model=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $computer 'Model') 160);
    serialNumber=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $bios 'SerialNumber') 128);
    os=@{caption=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'Caption') 160);version=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'Version') 80);build=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'BuildNumber') 40);architecture=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $os 'OSArchitecture') 40);lastBootAt=(ConvertTo-PdvHardwareTime (Get-PdvHardwareValue $os 'LastBootUpTime'));};
    cpu=@{name=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $cpu 'Name') 200);manufacturer=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $cpu 'Manufacturer') 120);processorId=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $cpu 'ProcessorId') 128);socketDesignation=(ConvertTo-PdvHardwareText (Get-PdvHardwareValue $cpu 'SocketDesignation') 80);cores=(ConvertTo-PdvHardwareNumber $cores 1024);logicalProcessors=(ConvertTo-PdvHardwareNumber $logical 1024);};
    memory=@{totalBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $computer 'TotalPhysicalMemory'));modules=@($modules | Sort-Object -CaseSensitive -Property { [string]($_['serialNumber']) },{ [string]($_['partNumber']) },{ [string]($_['capacityBytes']) },{ [string]($_['speedMHz']) },{ ConvertTo-PdvHardwareJson $_ });};
    disks=@($disks | Sort-Object -CaseSensitive -Property { [string]($_['id']) },{ [string]($_['serialNumber']) },{ [string]($_['model']) },{ ConvertTo-PdvHardwareJson $_ });
    systemVolume=@{name=$systemDrive;totalBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $volumeInfo 'Size'));freeBytes=(ConvertTo-PdvHardwareNumber (Get-PdvHardwareValue $volumeInfo 'FreeSpace'));};
    networkAdapters=@($adapters | Sort-Object -CaseSensitive -Property { [string]($_['macAddress']) },{ [string]($_['name']) },{ ConvertTo-PdvHardwareJson $_ }); warnings=@($warnings.ToArray() | Select-Object -First 16);
  };
  if ($hardware.systemVolume.totalBytes -and $hardware.systemVolume.freeBytes -and [UInt64]$hardware.systemVolume.freeBytes -gt [UInt64]$hardware.systemVolume.totalBytes) {
    $hardware.systemVolume.freeBytes=''; $hardware.warnings=@($hardware.warnings)+@('Espaço livre inconsistente no volume do sistema; valor omitido.');
    $hardware.warnings=@($hardware.warnings | Select-Object -First 16);
  }
  # Limite em bytes reais, nunca recortar JSON. Reduzir apenas listas e sinalizar
  # cobertura antes de aceitar a estrutura local/transporte.
  $limited=$false;
  while ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-PdvHardwareJson $hardware)) -gt 32768) {
    if ($hardware.networkAdapters.Count -gt 0) { $hardware.coverage.networkAdapters=$false;$hardware.networkAdapters=@($hardware.networkAdapters | Select-Object -First ($hardware.networkAdapters.Count-1)); }
    elseif ($hardware.disks.Count -gt 0) { $hardware.coverage.disks=$false;$hardware.disks=@($hardware.disks | Select-Object -First ($hardware.disks.Count-1)); }
    elseif ($hardware.memory.modules.Count -gt 0) { $hardware.coverage.memoryModules=$false;$hardware.memory.modules=@($hardware.memory.modules | Select-Object -First ($hardware.memory.modules.Count-1)); }
    else { return (New-Object PSObject -Property @{Success=$false;Hardware=$null;Reason='MachineInventoryTooLarge'}); }
    $limited=$true; $hardware.warnings=@('Inventário limitado a 32 KiB; parte das listas de hardware foi omitida.');
  }
  return (New-Object PSObject -Property @{Success=$true;Hardware=$hardware;Reason='Collected';CoverageHealthy=(-not $queryFailure -and -not $limited -and @($hardware.coverage.Values | Where-Object {-not $_}).Count -eq 0)});
}

# Software: somente chaves de desinstalacao do Windows e metadados Defender.
# Nao usa Win32_Product, nao executa instaladores/antivirus e nao le comandos,
# arquivos, recursos detectados, usuarios, origens ou chaves de produto.
function Get-PdvSoftwareValue {
  param($Object,[string]$Name,$Default=$null);
  if($null -eq $Object){return ,$Default;}
  if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return ,$Object[$Name];}}
  else{$p=$Object.PSObject.Properties[$Name];if($null -ne $p){return ,$p.Value;}}
  return ,$Default;
}
function Get-PdvSoftwareNow {return [DateTimeOffset]::Now;}
function Get-PdvSoftwareRegistryEnvironment {
  $os64=([IntPtr]::Size -eq 8 -or [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432') -match '64' -or [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') -match '64');
  $hasView=(@([Microsoft.Win32.RegistryKey].GetMethods() | Where-Object {$_.Name -ceq 'OpenBaseKey'}).Count -gt 0);
  return @{Os64=$os64;Process64=([IntPtr]::Size -eq 8);HasRegistryView=$hasView};
}
function Read-PdvSoftwareRegistryView {
  param([string]$Scope,[string]$View,$Environment);
  $base=$null;$baseOwned=$false;$uninstall=$null;$items=New-Object 'Collections.Generic.List[object]';$complete=$true;
  try {
    if(@('machine','currentUser') -cnotcontains $Scope -or @('x86','x64') -cnotcontains $View){throw 'Unsupported';}
    $path='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';
    if($Environment.HasRegistryView){
      $hive=[Microsoft.Win32.RegistryHive]::LocalMachine;if($Scope -ceq 'currentUser'){$hive=[Microsoft.Win32.RegistryHive]::CurrentUser;}
      $registryView=[Microsoft.Win32.RegistryView]::Registry32;if($View -ceq 'x64'){$registryView=[Microsoft.Win32.RegistryView]::Registry64;}
      $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$registryView);$baseOwned=$true;
    } else {
      if($Environment.Os64 -and $Scope -ceq 'currentUser' -and $Environment.Process64 -and $View -ceq 'x86'){return @{Complete=$false;Entries=@();Reason='SoftwareRegistryViewUnavailable'};}
      if($Environment.Os64 -and -not $Environment.Process64 -and $View -ceq 'x64'){return @{Complete=$false;Entries=@();Reason='SoftwareRegistryViewUnavailable'};}
      if($Scope -ceq 'machine'){$base=[Microsoft.Win32.Registry]::LocalMachine;}else{$base=[Microsoft.Win32.Registry]::CurrentUser;}
      if($Environment.Os64 -and $Environment.Process64 -and $View -ceq 'x86'){$path='SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall';}
    }
    $uninstall=$base.OpenSubKey($path,$false);
    if($null -eq $uninstall){return @{Complete=$true;Entries=@();Reason=''};}
    foreach($name in @($uninstall.GetSubKeyNames() | Sort-Object -CaseSensitive)){
      if($items.Count -ge 501){$complete=$false;break;}
      $key=$null;
      try {
        $key=$uninstall.OpenSubKey([string]$name,$false);if($null -eq $key){$complete=$false;continue;}
        # Lista fechada. Nao usar Get-ItemProperty sem selecao ou serializar a chave.
        $options=[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames;
        $entry=@{SubKeyName=[string]$name;DisplayName=$key.GetValue('DisplayName',$null,$options);DisplayVersion=$key.GetValue('DisplayVersion',$null,$options);Publisher=$key.GetValue('Publisher',$null,$options);InstallDate=$key.GetValue('InstallDate',$null,$options)};
        if($null -ne $entry.DisplayName -and [string]$entry.DisplayName -ne ''){$items.Add($entry);}
      } catch {$complete=$false;}
      finally {if($null -ne $key){$key.Close();}}
    }
    return @{Complete=$complete;Entries=@($items.ToArray());Reason=''};
  } catch {return @{Complete=$false;Entries=@($items.ToArray());Reason='SoftwareRegistryReadUnavailable'};}
  finally {if($null -ne $uninstall){$uninstall.Close();};if($null -ne $base -and $baseOwned){$base.Close();}}
}
function Read-PdvSoftwareDefender {
  $result=@{Threats=@();Detections=@();ThreatsAvailable=$false;DetectionsAvailable=$false;Limited=$false};
  if(Get-Command Get-MpThreat -ErrorAction SilentlyContinue){try{$result.Threats=@(Get-MpThreat -ErrorAction Stop | Select-Object ThreatID,ThreatName,SeverityID,IsActive | Sort-Object -Property @{Expression={$_.IsActive};Descending=$true},ThreatID | Select-Object -First 257);$result.ThreatsAvailable=$true;if($result.Threats.Count -gt 256){$result.Limited=$true;}}catch{}}
  if(Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue){try{$result.Detections=@(Get-MpThreatDetection -ErrorAction Stop | Select-Object ThreatID,ActionSuccess,LastThreatStatusChangeTime,InitialDetectionTime | Sort-Object -Property LastThreatStatusChangeTime -Descending | Select-Object -First 257);$result.DetectionsAvailable=$true;if($result.Detections.Count -gt 256){$result.Limited=$true;}}catch{}}
  return $result;
}
function Get-PdvSoftwareHash {
  param([string]$Text);
  $sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant();}finally{$sha.Clear();}
}
function ConvertTo-PdvSoftwareApp {
  param($Entry,[string]$Scope,[string]$View);
  $result=@{App=$null;Complete=$true};$subkey=Get-PdvSoftwareValue $Entry 'SubKeyName';$name=Get-PdvSoftwareValue $Entry 'DisplayName';
  if($subkey -isnot [string] -or -not $subkey -or $subkey.Length -gt 1024 -or $subkey -match '[\x00-\x1f\x7f]' -or $name -isnot [string] -or -not $name.Trim()){$result.Complete=$false;return $result;}
  $app=@{key=(Get-PdvSoftwareHash ($Scope+'|'+$View+'|'+$subkey.ToUpperInvariant()));name='';version='';publisher='';scope=$Scope;architecture=$View;reportedInstallDate=''};
  foreach($pair in @(@('DisplayName','name',256),@('DisplayVersion','version',128),@('Publisher','publisher',160))){
    $raw=Get-PdvSoftwareValue $Entry $pair[0] '';
    if($null -eq $raw){$raw='';};if($raw -isnot [string]){$result.Complete=$false;continue;}
    $app[$pair[1]]=ConvertTo-PdvHardwareText $raw ([int]$pair[2]);if($app[$pair[1]] -cne $raw.Trim()){$result.Complete=$false;}
  }
  if(-not $app.name){$result.Complete=$false;return $result;}
  $date=Get-PdvSoftwareValue $Entry 'InstallDate' '';
  if($null -ne $date -and [string]$date -ne ''){
    $parsed=[DateTime]::MinValue;
    if($date -is [string] -and $date -cmatch '^[0-9]{8}$' -and [DateTime]::TryParseExact($date,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){$app.reportedInstallDate=$date;}
    else{$result.Complete=$false;}
  }
  $result.App=$app;return $result;
}
function ConvertTo-PdvSoftwareThreats {
  param($Raw,[DateTimeOffset]$Now);
  $available=[bool](Get-PdvSoftwareValue $Raw 'ThreatsAvailable' $false);$detectionsAvailable=[bool](Get-PdvSoftwareValue $Raw 'DetectionsAvailable' $false);
  $security=@{provider='Unavailable';status='unavailable';observedAt=$Now.ToString('o');threats=@()};$complete=($available -and $detectionsAvailable -and -not [bool](Get-PdvSoftwareValue $Raw 'Limited' $false));
  if($available -or $detectionsAvailable){$security.provider='MicrosoftDefender';$security.status='partial';if($complete){$security.status='available';}}
  $latest=@();$detected=Get-PdvSoftwareValue $Raw 'Detections' @();$count=0;
  foreach($d in @($detected)){
    $count++;if($count -gt 256){$complete=$false;break;}
    $id=[string](Get-PdvSoftwareValue $d 'ThreatID' '');if($id -cnotmatch '^[0-9]{1,20}$'){$complete=$false;continue;}
    $time=ConvertTo-PdvHardwareTime (Get-PdvSoftwareValue $d 'LastThreatStatusChangeTime');if(-not $time){$time=ConvertTo-PdvHardwareTime (Get-PdvSoftwareValue $d 'InitialDetectionTime');}
    if($time){try{$parsedTime=[DateTimeOffset]::Parse($time);if($parsedTime -gt $Now.AddMinutes(5)){$time='';$complete=$false;}else{$time=$parsedTime.ToUniversalTime().ToString('o');}}catch{$time='';$complete=$false;}}
    $success=Get-PdvSoftwareValue $d 'ActionSuccess';if($success -isnot [bool]){$success=$null;}
    $latest+=,@{Id=$id;Time=$time;Success=$success};
  }
  $threats=Get-PdvSoftwareValue $Raw 'Threats' @();$unique=@{};$count=0;
  if($available){foreach($t in @($threats)){
    $count++;if($count -gt 256){$complete=$false;break;}
    $id=[string](Get-PdvSoftwareValue $t 'ThreatID' '');$name=Get-PdvSoftwareValue $t 'ThreatName';$active=Get-PdvSoftwareValue $t 'IsActive';
    if($id -cnotmatch '^[0-9]{1,20}$' -or $name -isnot [string] -or -not $name.Trim() -or $active -isnot [bool]){$complete=$false;continue;}
    $safeName=ConvertTo-PdvHardwareText $name 160;if($safeName -cne $name.Trim()){$complete=$false;}
    $severity='unknown';switch([string](Get-PdvSoftwareValue $t 'SeverityID' '')){'1'{$severity='low';}'2'{$severity='moderate';}'3'{$severity='high';}'4'{$severity='severe';}}
    $seen='';$success=$null;$matches=@($latest | Where-Object {$_.Id -ceq $id} | Sort-Object -Property Time -Descending);
    if($matches.Count){$seen=[string]$matches[0].Time;foreach($m in $matches){if($m.Time -ceq $seen -and $m.Success -is [bool]){if(-not $m.Success){$success=$false;break;};if($null -eq $success){$success=$true;}}}}
    $record=@{id=$id;name=$safeName;severity=$severity;active=$active;actionSuccess=$success;lastSeenAt=$seen;source='MicrosoftDefender'};
    if($unique.ContainsKey($id)){
      $complete=$false;$previous=$unique[$id];if($previous.active){$record.active=$true;};
      if([StringComparer]::Ordinal.Compare((ConvertTo-PdvHardwareJson $previous),(ConvertTo-PdvHardwareJson $record)) -lt 0){$chosen=$previous;}else{$chosen=$record;};$chosen.active=($previous.active -or $record.active);$unique[$id]=$chosen;
    }else{$unique[$id]=$record;}
  }}
  $security.threats=@($unique.Values | Sort-Object -Property @{Expression={$_.active};Descending=$true},@{Expression={switch($_.severity){'severe'{4;}'high'{3;}'moderate'{2;}'low'{1;}default{0;}}};Descending=$true},@{Expression={$_.id};Descending=$false});
  if($security.threats.Count -gt 64){$security.threats=@($security.threats | Select-Object -First 64);$complete=$false;}
  if(-not $complete -and $security.provider -ceq 'MicrosoftDefender'){$security.status='partial';}
  return @{Security=$security;Complete=$complete};
}
function Get-PdvSoftwareFingerprint {
  param([Collections.IDictionary]$Software);
  $security=@{provider=$Software.security.provider;status=$Software.security.status;threats=(Get-PdvHardwareCanonicalArray @($Software.security.threats))};
  $static=@{schemaVersion=$Software.schemaVersion;complete=$Software.complete;coverage=$Software.coverage;apps=(Get-PdvHardwareCanonicalArray @($Software.apps));security=$security};
  return (Get-PdvSoftwareHash (ConvertTo-PdvHardwareJson $static));
}
function Get-PdvMonitorSoftwareInventory {
  $warnings=New-Object 'Collections.Generic.List[string]';$apps=New-Object 'Collections.Generic.List[object]';$complete=$true;$now=Get-PdvSoftwareNow;
  $coverage=@{machine=$true;currentUser=$true;otherUsers=$false;store=$false;portable=$false};
  try {
    $environment=Get-PdvSoftwareRegistryEnvironment;$views=@('x86');if($environment.Os64){$views=@('x86','x64');}
    foreach($scope in @('machine','currentUser')){foreach($view in $views){
      $raw=Read-PdvSoftwareRegistryView $scope $view $environment;
      if(-not $raw.Complete){$complete=$false;$coverage[$scope]=$false;}
      foreach($entry in @($raw.Entries)){$converted=ConvertTo-PdvSoftwareApp $entry $scope $view;if(-not $converted.Complete){$complete=$false;};if($null -ne $converted.App){$apps.Add($converted.App);}}
    }}
  } catch {$complete=$false;$coverage.machine=$false;$coverage.currentUser=$false;}
  if(-not $coverage.machine -or -not $coverage.currentUser){$warnings.Add('A leitura de uma ou mais visões do Registro ficou incompleta; o inventário não comprova ausência de aplicativos.');}
  $warnings.Add('Cobertura limitada às chaves de instalação da máquina e do usuário atual; outros usuários, Store e portáteis não são enumerados.');
  $warnings.Add('Data de instalação é a informada pelo aplicativo e pode representar atualização; arquitetura indica a visão do Registro.');
  $rawDefender=$null;try{$rawDefender=Read-PdvSoftwareDefender;}catch{$rawDefender=@{ThreatsAvailable=$false;DetectionsAvailable=$false;Threats=@();Detections=@();Limited=$false};}
  $defender=ConvertTo-PdvSoftwareThreats $rawDefender $now;
  if(-not $defender.Complete){$warnings.Add('A consulta Microsoft Defender está indisponível ou parcial; isto não significa ausência de ameaça nem cobre outro antivírus.');}
  $unique=@{};foreach($app in $apps){if($unique.ContainsKey($app.key)){$complete=$false;}else{$unique[$app.key]=$app;}}
  $ordered=@($unique.Values | Sort-Object -Property @{Expression={$_.key}});
  if($ordered.Count -gt 500){$ordered=@($ordered | Select-Object -First 500);$complete=$false;$warnings.Add('O inventário foi limitado a 500 aplicativos; a cobertura está incompleta.');}
  $software=@{schemaVersion=1;snapshotId=[guid]::NewGuid().ToString();collectedAt=$now.ToString('o');complete=$complete;coverage=$coverage;apps=@($ordered);security=$defender.Security;warnings=@($warnings.ToArray())};
  if(-not $software.complete -and $software.warnings.Count -lt 16){$software.warnings=@($software.warnings)+@('Consulte a cobertura: itens inválidos, indisponíveis ou além dos limites podem ter sido omitidos.');}
  $limited=$false;
  while([Text.Encoding]::UTF8.GetByteCount((ConvertTo-PdvHardwareJson $software)) -gt 131072){
    $software.complete=$false;
    if(-not $limited){$limited=$true;$software.warnings=@($software.warnings)+@('Listas reduzidas para respeitar 128 KiB; nenhum JSON foi recortado e a cobertura ficou incompleta.');}
    if($software.apps.Count){$keep=[int][Math]::Floor($software.apps.Count*0.8);$software.apps=@($software.apps | Select-Object -First $keep);}
    elseif($software.security.threats.Count){$software.security.threats=@($software.security.threats | Select-Object -First ($software.security.threats.Count-1));$software.security.status='partial';}
    else{return (New-Object PSObject -Property @{Success=$false;Software=$null;Fingerprint='';CoverageHealthy=$false;Reason='SoftwareDocumentTooLarge'});}
  }
  return (New-Object PSObject -Property @{Success=$true;Software=$software;Fingerprint=(Get-PdvSoftwareFingerprint $software);CoverageHealthy=[bool]$software.complete;Reason='Collected'});
}

Export-ModuleMember -Function Get-PdvMonitorHardwareInventory, ConvertTo-PdvHardwareJson, Get-PdvHardwareFingerprint, Get-PdvMonitorSoftwareInventory, Get-PdvSoftwareFingerprint;
