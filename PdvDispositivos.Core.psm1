# Compatível com Windows PowerShell 5.1. Este módulo nunca abre portas seriais,
# escreve no Registro ou altera a reserva/numeração das portas COM.
Set-StrictMode -Version 2.0

function Get-PdvValue {
  param($InputObject, [string]$Name, $Default = $null)
  if ($null -eq $InputObject) { return $Default }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
  } else {
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
  }
  return $Default
}

function ConvertTo-PdvPort {
  param($Value)
  $port = ([string]$Value).Trim().ToUpperInvariant()
  if ($port -match '^COM([1-9][0-9]{0,3})$' -and [int]$Matches[1] -le 4096) {
    return $port
  }
  return $null
}

function Get-PdvWindowsInfo {
  param([System.Collections.Generic.List[string]]$Warnings)
  $isAdministrator = $false
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    $Warnings.Add('Não foi possível confirmar se a sessão possui permissão de administrador.')
  }
  $caption = 'Windows'
  $version = [Environment]::OSVersion.Version.ToString()
  $build = [Environment]::OSVersion.Version.Build
  try {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $caption = [string]$operatingSystem.Caption
    $version = [string]$operatingSystem.Version
    $build = [int]$operatingSystem.BuildNumber
  } catch {
    $Warnings.Add('Não foi possível consultar os detalhes do Windows: ' + $_.Exception.Message)
  }
  return [pscustomobject]@{
    Caption = $caption
    Version = $version
    Build = $build
    IsAdministrator = $isAdministrator
  }
}

function Get-PdvSnapshot {
  <#
  .SYNOPSIS
  Lê o inventário de dispositivos, portas reservadas e filas de impressão.
  .DESCRIPTION
  As reservas são lidas, sem modificações, de COM Name Arbiter. Elas não
  identificam o proprietário e não provam que um dispositivo esteja conectado.
  Devices inclui dispositivos presentes e históricos. Printers são filas do
  Windows e não são confundidas com as portas físicas dos dispositivos.
  #>
  [CmdletBinding()]
  param()
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $windows = Get-PdvWindowsInfo -Warnings $warnings
  $allPnpDevices = @()
  $inventoryComplete = $false
  $presentIds = @{}
  $presenceKnown = $false
  try {
    $allPnpDevices = @(Get-PnpDevice -ErrorAction Stop)
    $inventoryComplete = $true
  } catch {
    $warnings.Add('Inventário PnP indisponível; a lista de dispositivos está incompleta: ' + $_.Exception.Message)
  }
  try {
    foreach ($presentDevice in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) {
      $presentIds[[string]$presentDevice.InstanceId] = $true
    }
    $presenceKnown = $true
  } catch {
    $warnings.Add('Não foi possível confirmar a presença de todos os dispositivos. Itens sem confirmação não podem ser reiniciados: ' + $_.Exception.Message)
  }
  $serialById = @{}
  try {
    foreach ($serialDevice in @(Get-CimInstance -ClassName Win32_SerialPort -ErrorAction Stop)) {
      if ($serialDevice.PNPDeviceID) { $serialById[[string]$serialDevice.PNPDeviceID] = $serialDevice }
    }
  } catch {
    $warnings.Add('Consulta complementar das portas seriais indisponível: ' + $_.Exception.Message)
  }

  $devices = @(
    foreach ($pnpDevice in $allPnpDevices) {
      $instanceId = [string]$pnpDevice.InstanceId
      $class = [string]$pnpDevice.Class
      if ($class -notin @('Ports', 'Printer', 'PrintQueue') -and $instanceId -notmatch '^USBPRINT\\') { continue }
      $properties = @{}
      try {
        $propertyNames = @(
          'DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_ContainerId',
          'DEVPKEY_Device_LocationInfo', 'DEVPKEY_Device_Manufacturer',
          'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_ProblemCode',
          'DEVPKEY_Device_IsPresent'
        )
        # Uma propriedade não suportada não deve ocultar as demais.
        $propertyErrors = @()
        $deviceProperties = @(Get-PnpDeviceProperty -InstanceId $instanceId -KeyName $propertyNames -ErrorAction SilentlyContinue -ErrorVariable propertyErrors)
        foreach ($property in $deviceProperties) { $properties[[string]$property.KeyName] = $property.Data }
        if ($propertyErrors.Count -gt 0) {
          $warnings.Add('Algumas propriedades de "' + $instanceId + '" não puderam ser lidas; campos vazios indicam informação indisponível.')
        }
      } catch {
        $warnings.Add('Propriedades indisponíveis para "' + $instanceId + '": ' + $_.Exception.Message)
      }
      $port = $null
      $registryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' + $instanceId + '\Device Parameters'
      try {
        if (Test-Path -LiteralPath $registryPath -ErrorAction Stop) {
          $parameters = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
          $port = ConvertTo-PdvPort (Get-PdvValue $parameters 'PortName')
        }
      } catch {
        $warnings.Add('Não foi possível ler a porta registrada de "' + $instanceId + '": ' + $_.Exception.Message)
      }
      $name = [string]$pnpDevice.FriendlyName
      if (-not $name) { $name = $instanceId }
      if (-not $port -and $name -match '\((COM[1-9][0-9]{0,3})\)') {
        $port = ConvertTo-PdvPort $Matches[1]
      }
      if (-not $port -and $serialById.ContainsKey($instanceId)) {
        $port = ConvertTo-PdvPort $serialById[$instanceId].DeviceID
      }
      $present = $false
      if ($presenceKnown) {
        $present = $presentIds.ContainsKey($instanceId)
      } elseif ($properties.ContainsKey('DEVPKEY_Device_IsPresent')) {
        $present = [bool]$properties['DEVPKEY_Device_IsPresent']
      }
      $problemCode = $null
      if ($properties.ContainsKey('DEVPKEY_Device_ProblemCode')) {
        $problemCode = $properties['DEVPKEY_Device_ProblemCode']
      } else {
        $problemCode = Get-PdvValue $pnpDevice 'Problem'
      }
      [pscustomobject]@{
        InstanceId = $instanceId
        Name = $name
        Class = $class
        Present = $present
        PresenceKnown = ($presenceKnown -or $properties.ContainsKey('DEVPKEY_Device_IsPresent'))
        Port = $port
        Status = [string]$pnpDevice.Status
        ProblemCode = $problemCode
        HardwareIds = @($properties['DEVPKEY_Device_HardwareIds'] | Where-Object { $null -ne $_ })
        ContainerId = [string]$properties['DEVPKEY_Device_ContainerId']
        Location = [string]$properties['DEVPKEY_Device_LocationInfo']
        Manufacturer = [string]$properties['DEVPKEY_Device_Manufacturer']
        DriverVersion = [string]$properties['DEVPKEY_Device_DriverVersion']
      }
    }
  )

  $printers = @()
  try {
    $printers = @(
      Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
          Name = [string]$_.Name
          PortName = [string]$_.PortName
          DriverName = [string]$_.DriverName
          WorkOffline = [bool]$_.WorkOffline
          PrinterStatus = $_.PrinterStatus
          Default = [bool]$_.Default
          PnpDeviceId = [string]$_.PNPDeviceID
        }
      }
    )
  } catch {
    $warnings.Add('Filas de impressão indisponíveis: ' + $_.Exception.Message)
  }
  $reservedPorts = @()
  try {
    $arbiter = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\COM Name Arbiter' -Name ComDB -ErrorAction Stop
    $comDb = [byte[]]$arbiter.ComDB
    $reservedPorts = @(
      for ($byteIndex = 0; $byteIndex -lt $comDb.Length; $byteIndex++) {
        for ($bit = 0; $bit -lt 8; $bit++) {
          if (($comDb[$byteIndex] -band (1 -shl $bit)) -ne 0) {
            'COM' + (($byteIndex * 8) + $bit + 1)
          }
        }
      }
    )
  } catch {
    $warnings.Add('Reservas COM indisponíveis; não é possível afirmar que uma porta esteja livre: ' + $_.Exception.Message)
  }
  return [pscustomobject]@{
    CapturedAt = [DateTimeOffset]::Now.ToString('o')
    InventoryComplete = $inventoryComplete
    PresenceComplete = $presenceKnown
    Devices = $devices
    Printers = $printers
    ReservedPorts = $reservedPorts
    Warnings = @($warnings.ToArray())
    Windows = $windows
  }
}

function Get-PdvProfileStatus {
  <#
  .SYNOPSIS
  Compara perfis com um inventário, sem acessar ou modificar o computador.
  .DESCRIPTION
  Só o InstanceId exato (sem diferenciar maiúsculas) identifica o dispositivo.
  VID/PID, nome, ContainerId e localização são informativos e nunca autorizam
  associar ou reiniciar outro dispositivo automaticamente. ExpectedPort vazio
  significa acompanhar apenas presença e estado, útil para impressoras USB.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Profiles,
    [Parameter(Mandatory = $true)]$Snapshot
  )
  $devices = @(Get-PdvValue $Snapshot 'Devices' @())
  $reservedPorts = @(Get-PdvValue $Snapshot 'ReservedPorts' @())
  foreach ($profile in $Profiles) {
    $role = [string](Get-PdvValue $profile 'Role' '')
    $name = [string](Get-PdvValue $profile 'Name' '')
    $instanceId = ([string](Get-PdvValue $profile 'InstanceId' '')).Trim()
    $expectedRaw = ([string](Get-PdvValue $profile 'ExpectedPort' '')).Trim()
    $expectedPort = ConvertTo-PdvPort $expectedRaw
    $matchesById = @($devices | Where-Object { [string](Get-PdvValue $_ 'InstanceId' '') -eq $instanceId })
    $device = $null
    $actualPort = $null
    $state = 'Ready'
    $message = 'Dispositivo presente. Isso não confirma a comunicação com o Nerus/TEF.'
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    if (-not $instanceId -or -not $role.Trim() -or ($expectedRaw -and -not $expectedPort)) {
      $state = 'InvalidProfile'
      $message = 'Perfil incompleto ou porta inválida. Use função, InstanceId e, opcionalmente, COM1 a COM4096.'
    } elseif ($matchesById.Count -eq 0) {
      $state = 'Missing'
      $message = 'O InstanceId salvo não foi encontrado. Não será substituído automaticamente por outro com mesmo nome ou VID/PID.'
    } elseif ($matchesById.Count -gt 1) {
      $state = 'Conflict'
      $message = 'Inventário ambíguo: mais de um item possui o mesmo InstanceId.'
    } else {
      $device = $matchesById[0]
      $actualPort = ConvertTo-PdvPort (Get-PdvValue $device 'Port')
      if ($expectedPort) {
        foreach ($other in $devices) {
          $otherId = [string](Get-PdvValue $other 'InstanceId' '')
          if ($otherId -ne $instanceId -and (ConvertTo-PdvPort (Get-PdvValue $other 'Port')) -eq $expectedPort) {
            $presenceText = 'ausente/histórico'
            if ([bool](Get-PdvValue $other 'Present' $false)) { $presenceText = 'presente' }
            $conflicts.Add($expectedPort + ' consta em outro dispositivo (' + $presenceText + '): ' + $otherId)
          }
        }
        foreach ($otherProfile in $Profiles) {
          $otherId = ([string](Get-PdvValue $otherProfile 'InstanceId' '')).Trim()
          if ($otherId -ne $instanceId -and (ConvertTo-PdvPort (Get-PdvValue $otherProfile 'ExpectedPort')) -eq $expectedPort) {
            $conflicts.Add($expectedPort + ' foi escolhida em outro perfil: ' + [string](Get-PdvValue $otherProfile 'Role' ''))
          }
        }
        if ($actualPort -ne $expectedPort -and $reservedPorts -contains $expectedPort) {
          $conflicts.Add($expectedPort + ' está reservada no Windows. A reserva não identifica o proprietário; não deve ser tomada automaticamente.')
        }
      }
      $problemCode = Get-PdvValue $device 'ProblemCode'
      $deviceStatus = [string](Get-PdvValue $device 'Status' '')
      if (-not [bool](Get-PdvValue $device 'Present' $false)) {
        $state = 'Missing'
        $message = 'Dispositivo salvo ausente ou presença não confirmada. Nome/VID/PID não permitem reassociação automática.'
      } elseif ($conflicts.Count -gt 0) {
        $state = 'Conflict'
        $message = 'Há conflito ou reserva na porta esperada. Nenhuma porta foi alterada.'
      } elseif (($null -ne $problemCode -and [string]$problemCode -notin @('', '0', 'CM_PROB_NONE')) -or $deviceStatus -in @('Error', 'Degraded', 'Unknown')) {
        $state = 'DeviceProblem'
        $message = 'O Windows informa problema ou estado desconhecido do dispositivo. Consulte Status e ProblemCode.'
      } elseif ($expectedPort -and -not $actualPort) {
        $state = 'NoPort'
        $message = 'Dispositivo presente, mas nenhuma porta COM foi identificada.'
      } elseif ($expectedPort -and $actualPort -ne $expectedPort) {
        $state = 'Mismatch'
        $message = 'O perfil espera ' + $expectedPort + ', mas o Windows informa ' + $actualPort + '. Nenhuma configuração foi alterada.'
      } elseif ($expectedPort) {
        $message = 'Porta ' + $expectedPort + ' confere. Isso não confirma a comunicação com o Nerus/TEF.'
      }
    }
    [pscustomobject]@{
      Role = $role
      Name = $name
      InstanceId = $instanceId
      ExpectedPort = $expectedPort
      ActualPort = $actualPort
      State = $state
      Message = $message
      Device = $device
      Conflicts = @($conflicts.ToArray())
    }
  }
}

function Restart-PdvDevice {
  <#
  .SYNOPSIS
  Solicita ao Windows o reinício de exatamente um dispositivo presente.
  .DESCRIPTION
  Requer Windows 10 build 19041 ou superior e administrador. Não fecha o Nerus,
  não descarrega DLL de outros processos, não força a operação, não reinicia o
  computador e não reinicia hubs/controladores. Feche os aplicativos que usam
  o dispositivo e finalize pagamentos antes de chamar esta função.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$InstanceId)
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $windows = Get-PdvWindowsInfo -Warnings $warnings
  if ($windows.Build -lt 19041) { throw 'Reinício disponível apenas no Windows 10 versão 2004 (build 19041) ou superior.' }
  if (-not $windows.IsAdministrator) { throw 'Abra o utilitário como administrador para reiniciar o dispositivo.' }
  $exactDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { [string]$_.InstanceId -eq $InstanceId })
  if ($exactDevices.Count -ne 1) { throw 'O InstanceId exato não corresponde a um único dispositivo presente. Atualize o inventário.' }
  $device = $exactDevices[0]
  if ([string]$device.Class -notin @('Ports', 'Printer') -and [string]$device.InstanceId -notmatch '^USBPRINT\\') {
    throw 'Reinício permitido apenas para portas COM e dispositivos de impressora. Hubs, controladores e filas virtuais não são reiniciados.'
  }
  # A classe Ports também inclui portas paralelas (LPT). Só prosseguir se uma
  # COM válida puder ser identificada, sem abrir a porta ou escrever no Registro.
  if ([string]$device.Class -eq 'Ports') {
    $serialPort = $null
    $registryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' + [string]$device.InstanceId + '\Device Parameters'
    try {
      $parameters = Get-ItemProperty -LiteralPath $registryPath -Name PortName -ErrorAction Stop
      $serialPort = ConvertTo-PdvPort (Get-PdvValue $parameters 'PortName')
    } catch { }
    $friendlyName = [string](Get-PdvValue $device 'FriendlyName' '')
    if (-not $serialPort -and $friendlyName -match '\((COM[1-9][0-9]{0,3})\)') {
      $serialPort = ConvertTo-PdvPort $Matches[1]
    }
    if (-not $serialPort) {
      try {
        $serialDevices = @(Get-CimInstance -ClassName Win32_SerialPort -ErrorAction Stop | Where-Object { [string]$_.PNPDeviceID -eq [string]$device.InstanceId })
        if ($serialDevices.Count -eq 1) { $serialPort = ConvertTo-PdvPort $serialDevices[0].DeviceID }
      } catch { }
    }
    if (-not $serialPort) { throw 'Nenhuma porta COM foi confirmada para este dispositivo. Portas LPT/paralelas não são reiniciadas.' }
  }
  $toolDirectory = 'System32'
  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $toolDirectory = 'Sysnative' }
  $toolPath = Join-Path $env:WINDIR ($toolDirectory + '\pnputil.exe')
  if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) { throw 'PnPUtil não foi encontrado no diretório do Windows.' }
  # O ID vem do inventário validado; invocação direta, sem cmd.exe ou expressão.
  # Não acrescentar /deviceid, /force, /reboot nem operações de remoção.
  $nativeOutput = & $toolPath '/restart-device' ([string]$device.InstanceId) 2>&1
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{
    InstanceId = [string]$device.InstanceId
    ExitCode = $exitCode
    Output = (($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    RestartRequired = ($exitCode -eq 3010)
    Warnings = @($warnings.ToArray())
  }
}

Export-ModuleMember -Function Get-PdvSnapshot, Get-PdvProfileStatus, Restart-PdvDevice
