#requires -Version 2.0
# Consultas locais somente leitura. Compatível com Windows PowerShell 2.0.
# Win32_PnPEntity.Present/PNPClass não são suportados no Windows 7.
# https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pnpentity

function Get-PdvLegacyValue {
  param($InputObject, [string]$Name, $Default = $null);
  if ($null -eq $InputObject) { return $Default; }
  $property = $InputObject.PSObject.Properties[$Name];
  if ($null -ne $property -and $null -ne $property.Value) { return $property.Value; }
  return $Default;
}

function ConvertTo-PdvLegacyPort {
  param($Value);
  $port = ([string]$Value).Trim().ToUpperInvariant();
  if ($port -match '^COM([1-9][0-9]{0,3})$' -and [int]$Matches[1] -le 4096) { return $port; }
  return $null;
}

function Get-PdvLegacySnapshot {
  $warnings = New-Object 'System.Collections.Generic.List[string]';
  $warnings.Add('Inventário legado WMI/Registro. Presença não confirmada não significa equipamento desconectado. Consultas somente leitura, sem teste de comunicação.');
  $caption = 'Windows (versão não consultada)';
  $windowsVersion = ''; $windowsBuild = 0; $inventoryComplete = $false;
  $driverById = @{};
  try {
    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop;
    $caption = [string](Get-PdvLegacyValue $os 'Caption' $caption);
    $windowsVersion = [string](Get-PdvLegacyValue $os 'Version' '');
    $windowsBuild = [int](Get-PdvLegacyValue $os 'BuildNumber' 0);
  } catch { $warnings.Add('Detalhes do Windows indisponíveis: ' + $_.Exception.Message); }

  $serialById = @{};
  $serials = @();
  try {
    $serials = @(Get-WmiObject -Class Win32_SerialPort -ErrorAction Stop);
    foreach ($serial in $serials) {
      $serialId = [string](Get-PdvLegacyValue $serial 'PNPDeviceID' '');
      if ($serialId) { $serialById[$serialId] = $serial; }
    }
  } catch { $warnings.Add('Consulta WMI de portas seriais indisponível: ' + $_.Exception.Message); }

  try {
    foreach ($driver in @(Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction Stop)) {
      $driverId = [string](Get-PdvLegacyValue $driver 'DeviceID' '');
      if ($driverId) { $driverById[$driverId] = [string](Get-PdvLegacyValue $driver 'DriverVersion' ''); }
    }
  } catch { $warnings.Add('Versões de drivers indisponíveis nesta coleta.'); }

  $pnpItems = @();
  try { $pnpItems = @(Get-WmiObject -Class Win32_PnPEntity -ErrorAction Stop); $inventoryComplete = $true; }
  catch { $warnings.Add('Consulta WMI de dispositivos indisponível; a lista pode estar vazia ou incompleta: ' + $_.Exception.Message); }

  $seenIds = @{};
  $devices = New-Object 'System.Collections.Generic.List[object]';
  foreach ($pnp in $pnpItems) {
    $id = [string](Get-PdvLegacyValue $pnp 'PNPDeviceID' (Get-PdvLegacyValue $pnp 'DeviceID' ''));
    $name = [string](Get-PdvLegacyValue $pnp 'Name' $id);
    $classGuid = [string](Get-PdvLegacyValue $pnp 'ClassGuid' '');
    $class = '';
    # PNPClass não existe no Win7. ClassGuid e a consulta serial identificam o
    # grupo sem deduzir presença por Status OK ou ConfigManagerErrorCode=0.
    if ($classGuid -eq '{4d36e978-e325-11ce-bfc1-08002be10318}' -or $serialById.ContainsKey($id)) { $class = 'Ports'; }
    elseif ($classGuid -eq '{4d36e979-e325-11ce-bfc1-08002be10318}' -or $id -match '^USBPRINT\\') { $class = 'Printer'; }
    elseif ($classGuid -eq '{1ed2bbf9-11f0-4084-b21f-ad83a8e6dcdc}') { $class = 'PrintQueue'; }
    elseif ($name -match '\((COM[1-9][0-9]{0,3})\)') { $class = 'Ports (pelo nome)'; }
    if (-not $class) { continue; }

    $port = $null;
    if ($id) {
      try {
        $registryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' + $id + '\Device Parameters';
        if (Test-Path -LiteralPath $registryPath -ErrorAction Stop) {
          $parameters = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop;
          $port = ConvertTo-PdvLegacyPort (Get-PdvLegacyValue $parameters 'PortName');
        }
      } catch { $warnings.Add('Porta registrada não pôde ser lida para "' + $id + '": ' + $_.Exception.Message); }
    }
    if (-not $port -and $serialById.ContainsKey($id)) { $port = ConvertTo-PdvLegacyPort (Get-PdvLegacyValue $serialById[$id] 'DeviceID'); }
    if (-not $port -and $name -match '\((COM[1-9][0-9]{0,3})\)') { $port = ConvertTo-PdvLegacyPort $Matches[1]; }

    $present = Get-PdvLegacyValue $pnp 'Present';
    $presence = 'Não confirmada';
    if ($null -ne $present -and $present -is [bool]) {
      if ($present) { $presence = 'Presente (WMI)'; } else { $presence = 'Ausente (WMI)'; }
    }
    $devices.Add((New-Object PSObject -Property @{
      Name = $name; Port = $port; Presence = $presence;
      Status = [string](Get-PdvLegacyValue $pnp 'Status' '');
      Class = $class; InstanceId = $id;
      ProblemCode = Get-PdvLegacyValue $pnp 'ConfigManagerErrorCode';
      Manufacturer = [string](Get-PdvLegacyValue $pnp 'Manufacturer' '');
      HardwareIds = @(Get-PdvLegacyValue $pnp 'HardwareID' @());
      DriverVersion = [string]$driverById[$id];
      Present = ($present -is [bool] -and $present); PresenceKnown = ($present -is [bool]);
      Source = 'Win32_PnPEntity; porta por Registro/Win32_SerialPort/nome';
    }));
    if ($id) { $seenIds[$id] = $true; }
  }
  # Win32_SerialPort complementa falhas/omissões de PnPEntity. Sua enumeração
  # isolada também não é prova de conexão física ou de disponibilidade da COM.
  foreach ($serial in $serials) {
    $id = [string](Get-PdvLegacyValue $serial 'PNPDeviceID' '');
    if ($id -and $seenIds.ContainsKey($id)) { continue; }
    $devices.Add((New-Object PSObject -Property @{
      Name = [string](Get-PdvLegacyValue $serial 'Name' (Get-PdvLegacyValue $serial 'DeviceID' 'Porta serial'));
      Port = ConvertTo-PdvLegacyPort (Get-PdvLegacyValue $serial 'DeviceID');
      Presence = 'Não confirmada'; Status = [string](Get-PdvLegacyValue $serial 'Status' '');
      Class = 'Ports'; InstanceId = $id;
      ProblemCode = Get-PdvLegacyValue $serial 'ConfigManagerErrorCode';
      Manufacturer = [string](Get-PdvLegacyValue $serial 'ProviderType' '');
      HardwareIds = @(); DriverVersion = [string]$driverById[$id];
      Present = $false; PresenceKnown = $false;
      Source = 'Win32_SerialPort (consulta complementar)';
    }));
  }

  $printers = @();
  try {
    $printers = @(Get-WmiObject -Class Win32_Printer -ErrorAction Stop | ForEach-Object {
      New-Object PSObject -Property @{
        Name = [string](Get-PdvLegacyValue $_ 'Name' '');
        PortName = [string](Get-PdvLegacyValue $_ 'PortName' '');
        DriverName = [string](Get-PdvLegacyValue $_ 'DriverName' '');
        WorkOffline = Get-PdvLegacyValue $_ 'WorkOffline';
        PrinterStatus = Get-PdvLegacyValue $_ 'PrinterStatus';
        PnpDeviceId = [string](Get-PdvLegacyValue $_ 'PNPDeviceID' '');
      };
    });
  } catch { $warnings.Add('Filas de impressão indisponíveis: ' + $_.Exception.Message); }

  $reservedPorts = @();
  try {
    $arbiter = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\COM Name Arbiter' -Name ComDB -ErrorAction Stop;
    $comDb = [byte[]]$arbiter.ComDB;
    $reservedPorts = @(
      for ($byteIndex = 0; $byteIndex -lt $comDb.Length; $byteIndex++) {
        for ($bit = 0; $bit -lt 8; $bit++) {
          if (($comDb[$byteIndex] -band (1 -shl $bit)) -ne 0) { 'COM' + (($byteIndex * 8) + $bit + 1); }
        }
      }
    );
  } catch { $warnings.Add('Reservas COM indisponíveis; nenhuma porta deve ser considerada livre: ' + $_.Exception.Message); }

  return (New-Object PSObject -Property @{
    CapturedAt = (Get-Date).ToString('o'); Windows = $caption;
    Devices = @($devices.ToArray()); Printers = $printers; ReservedPorts = $reservedPorts;
    Warnings = @($warnings.ToArray());
    WindowsDetails = New-Object PSObject -Property @{ Caption = $caption; Version = $windowsVersion; Build = $windowsBuild; IsAdministrator = $false };
    InventoryComplete = $inventoryComplete;
    PresenceComplete = (@($devices.ToArray() | Where-Object { -not $_.PresenceKnown }).Count -eq 0 -and $inventoryComplete);
  });
}

function New-PdvLegacyExportRow {
  param([string]$Type, [string]$Name, [string]$Port, [string]$Presence, [string]$Status, [string]$Code, [string]$Id, [string]$Details);
  return (New-Object PSObject -Property @{
    Tipo = $Type; Nome = $Name; Porta = $Port; Presenca = $Presence;
    Status = $Status; CodigoProblema = $Code; Identificador = $Id; Detalhes = $Details;
  });
}

function Get-PdvLegacyExportRows {
  param($Snapshot);
  New-PdvLegacyExportRow 'Coleta' $Snapshot.Windows '' '' '' '' '' ('Horário: ' + $Snapshot.CapturedAt + '; consultas locais somente leitura; dispositivos e filas não equivalem a testes de comunicação.');
  foreach ($device in @($Snapshot.Devices)) {
    New-PdvLegacyExportRow 'Dispositivo' $device.Name $device.Port $device.Presence $device.Status ([string]$device.ProblemCode) $device.InstanceId ($device.Class + '; ' + $device.Source + '; fabricante: ' + $device.Manufacturer);
  }
  foreach ($printer in @($Snapshot.Printers)) {
    New-PdvLegacyExportRow 'Fila de impressão' $printer.Name $printer.PortName 'Não confirmada pela fila' ([string]$printer.PrinterStatus) '' $printer.PnpDeviceId ('Driver: ' + $printer.DriverName + '; WorkOffline: ' + $printer.WorkOffline);
  }
  foreach ($port in @($Snapshot.ReservedPorts)) { New-PdvLegacyExportRow 'Reserva COM' '' $port 'Não informa presença' '' '' '' 'COM Name Arbiter; reserva sem identificação do proprietário.'; }
  foreach ($warning in @($Snapshot.Warnings)) { New-PdvLegacyExportRow 'Aviso' '' '' '' '' '' '' $warning; }
}

Export-ModuleMember -Function Get-PdvLegacyValue, ConvertTo-PdvLegacyPort, Get-PdvLegacySnapshot, New-PdvLegacyExportRow, Get-PdvLegacyExportRows;
