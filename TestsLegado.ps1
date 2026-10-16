#requires -Version 5.1
# Testes isolados: importam o módulo legado e substituem WMI/
# Registro por objetos em memória. Não abrem a interface ou dispositivos reais.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PdvLegado.Core.psm1') -Force
$legacyModule = Get-Module PdvLegado.Core
& $legacyModule {
function Assert-Legacy($Condition, $Name) { if (-not $Condition) { throw $Name } }
$script:pnpFailure = $false
$script:allWmiFailure = $false
$script:explicitPresence = $false
function Get-WmiObject {
  [CmdletBinding()]
  param([string]$Class)
  if ($script:allWmiFailure) { throw 'WMI indisponível no teste.' }
  switch ($Class) {
    Win32_OperatingSystem { [pscustomobject]@{Caption='Windows 7 de teste'} }
    Win32_PnPEntity {
      if ($script:pnpFailure) { throw 'PnP indisponível no teste.' }
      $pinpad = [pscustomobject]@{PNPDeviceID='USB\PINPAD\001'; Name='Pinpad (COM4)'; ClassGuid='{4d36e978-e325-11ce-bfc1-08002be10318}'; Status='OK'; ConfigManagerErrorCode=0}
      if ($script:explicitPresence) { $pinpad | Add-Member -NotePropertyName Present -NotePropertyValue $false }
      $pinpad
      [pscustomobject]@{PNPDeviceID='USBPRINT\BEMATECH\002'; Name='Bematech'; ClassGuid='{4d36e979-e325-11ce-bfc1-08002be10318}'; Status='OK'; ConfigManagerErrorCode=0}
      [pscustomobject]@{PNPDeviceID='SYSTEM\OTHER'; Name='Outro hardware'; ClassGuid='{other}'; Status='OK'; ConfigManagerErrorCode=0}
    }
    Win32_SerialPort {
      [pscustomobject]@{PNPDeviceID='USB\PINPAD\001'; Name='Pinpad'; DeviceID='COM4'; Status='OK'; ConfigManagerErrorCode=0}
      [pscustomobject]@{PNPDeviceID='USB\SERIAL\ORPHAN'; Name='Serial complementar'; DeviceID='COM7'; Status='OK'; ConfigManagerErrorCode=0}
    }
    Win32_PnPSignedDriver { [pscustomobject]@{DeviceID='USB\PINPAD\001'; DriverVersion='1.2.3'} }
    Win32_Printer { [pscustomobject]@{Name='Fila Bematech'; PortName='USB001'; DriverName='Driver de teste'; WorkOffline=$false; PrinterStatus=3; PNPDeviceID='USBPRINT\BEMATECH\002'} }
    default { throw 'Classe WMI inesperada.' }
  }
}
function Test-Path { [CmdletBinding()] param($LiteralPath) return $true }
function Get-ItemProperty {
  [CmdletBinding()] param($LiteralPath, $Name)
  if ($LiteralPath -like '*COM Name Arbiter') { return [pscustomobject]@{ComDB=[byte[]]@(8)} }
  if ($LiteralPath -like '*PINPAD*') { return [pscustomobject]@{PortName='COM4'} }
  return [pscustomobject]@{}
}
$snapshot = Get-PdvLegacySnapshot
Assert-Legacy (@($snapshot.Devices).Count -eq 3) 'Filtra classes por GUID e complementa serial sem duplicar'
$pinpad = @($snapshot.Devices | Where-Object InstanceId -eq 'USB\PINPAD\001')[0]
Assert-Legacy ($pinpad.Port -eq 'COM4') 'Lê COM4'
Assert-Legacy (-not $pinpad.PresenceKnown) 'Presença desconhecida preservada no schema comum'
Assert-Legacy (-not $pinpad.Present) 'Presença desconhecida não vira presente'
Assert-Legacy ($snapshot.InventoryComplete) 'Sucesso PnP confirma completude do inventário'
Assert-Legacy ($pinpad.DriverVersion -eq '1.2.3') 'Versão do driver é ligada pelo InstanceId exato'
Assert-Legacy ($pinpad.Presence -eq 'Não confirmada') 'Status OK e código zero não afirmam presença'
Assert-Legacy (@($snapshot.Devices | Where-Object InstanceId -eq 'USB\SERIAL\ORPHAN')[0].Presence -eq 'Não confirmada') 'Serial complementar não afirma presença'
Assert-Legacy ($snapshot.ReservedPorts -contains 'COM4') 'Decodifica reserva COM4'
$rows = @(Get-PdvLegacyExportRows $snapshot | Select-Object Tipo, Nome, Porta, Presenca, Status, CodigoProblema, Identificador, Detalhes)
Assert-Legacy ($rows.Count -eq 7) 'Exporta coleta, dispositivos, fila, reserva e aviso'
$csvPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pdv-legado-[literal]-' + [Guid]::NewGuid().ToString('N') + '.csv')
$csvLines = @($rows | ConvertTo-Csv -NoTypeInformation)
try {
  [System.IO.File]::WriteAllLines($csvPath, [string[]]$csvLines, [System.Text.Encoding]::UTF8)
  $roundtrip = @([System.IO.File]::ReadAllLines($csvPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Csv)
} finally {
  if ([System.IO.File]::Exists($csvPath)) { [System.IO.File]::Delete($csvPath) }
}
Assert-Legacy ($roundtrip.Count -eq 7) 'CSV reabre com nome literal'
Assert-Legacy ($roundtrip[2].Tipo -eq 'Dispositivo') 'CSV preserva tipo e ordem'
$script:explicitPresence = $true
$snapshot = Get-PdvLegacySnapshot
Assert-Legacy (@($snapshot.Devices | Where-Object InstanceId -eq 'USB\PINPAD\001')[0].Presence -eq 'Ausente (WMI)') 'Presença explícita falsa é preservada'
$script:pnpFailure = $true
$snapshot = Get-PdvLegacySnapshot
Assert-Legacy (-not $snapshot.InventoryComplete) 'Falha PnP informa inventário incompleto'
Assert-Legacy (@($snapshot.Devices).Count -eq 2) 'Falha PnP preserva consulta serial complementar'
Assert-Legacy (($snapshot.Warnings -join ' ') -like '*incompleta*') 'Falha PnP é declarada parcial'
$script:allWmiFailure = $true
$snapshot = Get-PdvLegacySnapshot
Assert-Legacy (@($snapshot.Devices).Count -eq 0) 'WMI indisponível produz lista vazia'
Assert-Legacy (@($snapshot.Warnings).Count -ge 5) 'WMI indisponível preserva avisos de todas as fontes'
Write-Host ('PASS: parser PowerShell ' + $PSVersionTable.PSVersion + '; mocks de coleta WMI/Registro, presença desconhecida, falhas parciais e exportação CSV literal. Não valida execução em PowerShell 2, interface ou hardware.')

}
