#requires -Version 5.1
$ErrorActionPreference='Stop';
Import-Module (Join-Path $PSScriptRoot 'PdvDispositivos.Core.psm1') -Force;
$module=Get-Module PdvDispositivos.Core;
& $module {
  $script:PresentQueryFails=$false;
  function script:Get-PdvWindowsInfo {param($Warnings);return [pscustomobject]@{Build=19045;IsAdministrator=$false};}
  function script:Get-PnpDevice {
    [CmdletBinding()]param([switch]$PresentOnly);
    if ($PresentOnly -and $script:PresentQueryFails) {throw 'Simulado';}
    return [pscustomobject]@{InstanceId='USB\PINPAD\001';Class='Ports';FriendlyName='Pinpad (COM6)';Status='OK';Problem='CM_PROB_NONE'};
  }
  function script:Get-PnpDeviceProperty {
    [CmdletBinding()]param($InstanceId,$KeyName);
    [pscustomobject]@{KeyName='DEVPKEY_Device_HardwareIds'};
    [pscustomobject]@{KeyName='DEVPKEY_Device_IsPresent'};
    [pscustomobject]@{KeyName='DEVPKEY_Device_ProblemCode';Data=0};
    [pscustomobject]@{KeyName='DEVPKEY_Device_Manufacturer';Data='Fabricante'};
  }
  function script:Get-CimInstance {[CmdletBinding()]param($ClassName);return @();}
  function script:Test-Path {[CmdletBinding()]param($LiteralPath);return $false;}
  function script:Get-ItemProperty {[CmdletBinding()]param($LiteralPath,$Name);return [pscustomobject]@{ComDB=[byte[]]@(0)};}
};
$snapshot=Get-PdvSnapshot;
if ($snapshot.Devices.Count -ne 1 -or $snapshot.Devices[0].ProblemCode -ne 0 -or $snapshot.Devices[0].Manufacturer -ne 'Fabricante' -or -not $snapshot.Devices[0].PresenceKnown -or -not $snapshot.Devices[0].Present -or $snapshot.Devices[0].Port -ne 'COM6') {throw 'Objeto sem Data não pode interromper leitura das propriedades seguintes';}
if (($snapshot.Warnings -join '') -match 'Data.*encontrada') {throw 'Sem exceção por propriedade Data ausente';}
& $module {$script:PresentQueryFails=$true};
$snapshot=Get-PdvSnapshot;
if ($snapshot.Devices[0].PresenceKnown -or $snapshot.PresenceComplete -or $snapshot.Devices[0].Present) {throw 'IsPresent sem Data não pode inventar presença após falha PresentOnly';}
Write-Host 'PASS: propriedades PnP sem Data preservam as demais propriedades e nunca inventam presença. Nenhum Windows real consultado.';
