# Testes puros: nenhum inventário real é consultado e nenhum dispositivo é aberto
# ou reiniciado. Não requer Pester, permissão de administrador ou equipamento.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PdvDispositivos.Core.psm1') -Force

function Assert-Equal {
  param($Actual, $Expected, [string]$Description)
  if ($Actual -ne $Expected) {
    throw ($Description + ': esperado "' + $Expected + '", obtido "' + $Actual + '".')
  }
}

function New-TestDevice {
  param([string]$Id = 'USB\VID_1234&PID_5678\PINPAD-001', [string]$Port = 'COM4', [bool]$Present = $true)
  [pscustomobject]@{
    InstanceId = $Id
    Name = 'Pinpad de teste (' + $Port + ')'
    Class = 'Ports'
    Present = $Present
    Port = $Port
    Status = 'OK'
    ProblemCode = 0
    HardwareIds = @('USB\VID_1234&PID_5678')
  }
}

function New-TestSnapshot {
  param([object[]]$Devices = @(), [string[]]$ReservedPorts = @())
  [pscustomobject]@{ Devices = $Devices; ReservedPorts = $ReservedPorts; Printers = @(); Warnings = @() }
}

$device = New-TestDevice
$profile = [pscustomobject]@{
  Role = 'TEF'
  Name = 'Pinpad do caixa'
  InstanceId = $device.InstanceId
  ExpectedPort = 'COM4'
}
$snapshot = New-TestSnapshot -Devices @($device) -ReservedPorts @('COM4')
$beforeSnapshot = ConvertTo-Json $snapshot -Depth 8 -Compress
$beforeProfile = ConvertTo-Json $profile -Depth 8 -Compress
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result.Count 1 'Um resultado por perfil'
Assert-Equal $result[0].State 'Ready' 'Reserva da própria porta não gera conflito'
Assert-Equal $result[0].ActualPort 'COM4' 'Porta atual preservada'
Assert-Equal (ConvertTo-Json $snapshot -Depth 8 -Compress) $beforeSnapshot 'Inventário não sofreu mutação'
Assert-Equal (ConvertTo-Json $profile -Depth 8 -Compress) $beforeProfile 'Perfil não sofreu mutação'

$profile.ExpectedPort = ' com5 '
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Mismatch' 'Porta diferente e sem reserva'
Assert-Equal $result[0].ExpectedPort 'COM5' 'Normalização da porta esperada'

$reservedSnapshot = New-TestSnapshot -Devices @($device) -ReservedPorts @('COM5')
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $reservedSnapshot)
Assert-Equal $result[0].State 'Conflict' 'Reserva sem dono deve bloquear classificação de porta livre'
Assert-Equal ($result[0].Conflicts.Count -gt 0) $true 'Conflito possui explicação'

$other = New-TestDevice -Id 'USB\VID_1234&PID_5678\OUTRO-002' -Port 'COM5'
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot (New-TestSnapshot -Devices @($device, $other)))
Assert-Equal $result[0].State 'Conflict' 'Outro dispositivo presente usa a porta desejada'
$other.Present = $false
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot (New-TestSnapshot -Devices @($device, $other)))
Assert-Equal $result[0].State 'Conflict' 'Dispositivo ausente ainda possui atribuição histórica'

$otherProfile = [pscustomobject]@{ Role = 'Impressora'; Name = 'Outra'; InstanceId = $other.InstanceId; ExpectedPort = 'COM5' }
$result = @(Get-PdvProfileStatus -Profiles @($profile, $otherProfile) -Snapshot $snapshot)
Assert-Equal $result.Count 2 'Quantidade de resultados preservada para múltiplos perfis'
Assert-Equal $result[0].State 'Conflict' 'Dois perfis não devem esperar a mesma COM em dispositivos diferentes'
Assert-Equal $result[1].State 'Missing' 'Dispositivo ausente no inventário não é substituído'

$profile.ExpectedPort = 'COM4'
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot (New-TestSnapshot -Devices @($other)))
Assert-Equal $result[0].State 'Missing' 'Mesmo VID/PID não substitui InstanceId'
$profile.InstanceId = 'USB\VID_1234&PID_5678\*'
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Missing' 'InstanceId não aceita correspondência por curinga'
$profile.InstanceId = $device.InstanceId.ToLowerInvariant()
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Ready' 'InstanceId segue comparação do Windows sem diferenciar maiúsculas'

$device.Present = $false
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Missing' 'Instância histórica não é dispositivo conectado'
$device.Present = $true
$device.ProblemCode = 10
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'DeviceProblem' 'Código de problema do Windows não pode ser classificado como pronto'
$device.ProblemCode = 0
$device.Status = 'Error'
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'DeviceProblem' 'Status de erro é preservado'
$device.Status = 'OK'
$device.Port = $null
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Conflict' 'Porta esperada reservada com atribuição indeterminada é conflito'
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot (New-TestSnapshot -Devices @($device)))
Assert-Equal $result[0].State 'NoPort' 'Nenhuma COM identificada'

$profile.ExpectedPort = ''
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'Ready' 'Perfil sem COM acompanha identidade e presença, útil para impressora USB'
foreach ($invalidPort in @('COM0', 'COM4097', 'COM01', 'LPT1', 'COM4;shutdown', 'COM-1')) {
  $profile.ExpectedPort = $invalidPort
  $result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
  Assert-Equal $result[0].State 'InvalidProfile' ('Porta inválida: ' + $invalidPort)
}
$profile.ExpectedPort = 'COM4'
$profile.InstanceId = ''
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'InvalidProfile' 'Perfil exige InstanceId'
$profile.InstanceId = $device.InstanceId
$profile.Role = ''
$result = @(Get-PdvProfileStatus -Profiles @($profile) -Snapshot $snapshot)
Assert-Equal $result[0].State 'InvalidProfile' 'Perfil exige função'

$result = @(Get-PdvProfileStatus -Profiles @() -Snapshot (New-TestSnapshot))
Assert-Equal $result.Count 0 'Lista vazia de perfis'
# Testes negativos do reinício. Todos os acessos externos são substituídos por
# funções em memória. Os cenários devem falhar ANTES de procurar/executar PnPUtil.
function Assert-Throws {
  param([scriptblock]$Action, [string]$ExpectedText, [string]$Description)
  $caught = $false
  try { & $Action | Out-Null } catch {
    $caught = $true
    if (-not $_.Exception.Message.Contains($ExpectedText)) {
      throw ($Description + ': mensagem inesperada: ' + $_.Exception.Message)
    }
  }
  if (-not $caught) { throw ($Description + ': a operação deveria ter sido recusada.') }
}

$module = Get-Module PdvDispositivos.Core
$restartDevice = New-TestDevice
& $module {
  param($TestDevice)
  $script:PdvTestWindows = [pscustomobject]@{ Build = 19041; IsAdministrator = $true }
  $script:PdvTestDevices = @($TestDevice)
  $script:PdvTestPnpError = $false
  function script:Get-PdvWindowsInfo {
    param($Warnings)
    return $script:PdvTestWindows
  }
  function script:Get-PnpDevice {
    [CmdletBinding()]
    param([switch]$PresentOnly)
    if (-not $PresentOnly) { throw 'TESTE: consulta deve exigir dispositivos presentes.' }
    if ($script:PdvTestPnpError) { throw 'TESTE: inventário indisponível.' }
    return $script:PdvTestDevices
  }
  function script:Get-ItemProperty {
    [CmdletBinding()]
    param($LiteralPath, $Name)
    return [pscustomobject]@{ PortName = 'LPT1' }
  }
  function script:Get-CimInstance {
    [CmdletBinding()]
    param($ClassName)
    if ($ClassName -ne 'Win32_SerialPort') { throw 'TESTE: consulta CIM inesperada.' }
    return @()
  }
  function script:Test-Path {
    [CmdletBinding()]
    param($LiteralPath, $PathType)
    throw 'TESTE: acesso nativo bloqueado; cenário deveria ser recusado antes.'
  }
} $restartDevice

Assert-Throws { Restart-PdvDevice -InstanceId 'USB\VID_1234&PID_5678\*' } 'InstanceId exato' 'Reinício recusa curinga'
Assert-Throws { Restart-PdvDevice -InstanceId 'USB\VID_1234&PID_5678\OUTRO' } 'InstanceId exato' 'Reinício recusa outro serial do mesmo VID/PID'
& $module { $script:PdvTestDevices = @($script:PdvTestDevices[0], $script:PdvTestDevices[0]) }
Assert-Throws { Restart-PdvDevice -InstanceId $restartDevice.InstanceId } 'InstanceId exato' 'Reinício recusa inventário duplicado'
& $module { $script:PdvTestPnpError = $true }
Assert-Throws { Restart-PdvDevice -InstanceId $restartDevice.InstanceId } 'inventário indisponível' 'Erro de inventário impede reinício'
& $module {
  $script:PdvTestPnpError = $false
  $script:PdvTestDevices = @([pscustomobject]@{ Class = 'USB'; InstanceId = 'USB\CONTROLADOR' })
}
Assert-Throws { Restart-PdvDevice -InstanceId 'USB\CONTROLADOR' } 'Hubs, controladores' 'Reinício recusa controlador USB'
& $module { $script:PdvTestDevices = @([pscustomobject]@{ Class = 'Ports'; InstanceId = 'ACPI\LPT'; FriendlyName = 'Porta de impressora (LPT1)' }) }
Assert-Throws { Restart-PdvDevice -InstanceId 'ACPI\LPT' } 'LPT/paralelas' 'Classe Ports com LPT não pode ser reiniciada como COM'
& $module { $script:PdvTestWindows.IsAdministrator = $false }
Assert-Throws { Restart-PdvDevice -InstanceId $restartDevice.InstanceId } 'administrador' 'Reinício exige administrador'
& $module {
  $script:PdvTestWindows.IsAdministrator = $true
  $script:PdvTestWindows.Build = 18363
}
Assert-Throws { Restart-PdvDevice -InstanceId $restartDevice.InstanceId } '19041' 'Reinício exige Windows compatível'
Write-Host 'Todos os testes de perfis, conflitos e recusas de reinício passaram (sem acessar dispositivos).' -ForegroundColor Green
