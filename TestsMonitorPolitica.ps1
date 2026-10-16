# Sintaxe compatível com Windows PowerShell 2.0; sem Pester ou acesso ao Windows.
# Executar: powershell.exe -NoProfile -File .\TestsMonitorPolitica.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$moduleDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleDirectory 'PdvMonitor.Politica.psm1') -Force
$script:assertions = 0

function New-PolicyFixture {
  $now = [DateTimeOffset]::Parse('2026-10-15T12:00:00-03:00', [Globalization.CultureInfo]::InvariantCulture)
  return (New-Object PSObject -Property @{
    Now = $now
    Profile = @{Role='Pinpad'; InstanceId='USB\PINPAD\001'; ExpectedPort='COM4'; RecoveryEnabled=$true}
    Device = @{InstanceId='USB\PINPAD\001'; Present=$true; PresenceKnown=$true; Port='COM4'; Class='Ports'; Status='Error'; ProblemCode=10}
    Context = @{
      AutoRecoveryEnabled=$true; MaintenanceArmed=$true; MaintenanceExpiresAt=$now.AddMinutes(10)
      WindowsBuild=19045; IsAdministrator=$true; SnapshotComplete=$true; ProfileConflict=$false
      ProcessListConfigured=$true; ProcessCheckSucceeded=$true; BlockingProcessNames=@()
      PrintCheckSucceeded=$true; PendingPrintJobs=0
    }
    State = @{ConsecutiveFailures=3; LastAttemptAt=$null; AttemptsInWindow=0; SessionAttempts=0; WindowStartedAt=$null; LastObservedSignature='10|Error|COM4'}
  })
}

function Assert-Policy {
  param($Fixture, [string]$ExpectedReason, [bool]$ExpectedAllowed = $false, [string]$ExpectedFailureKind = '')
  $decision = Get-PdvRecoveryDecision -Profile $Fixture.Profile -Device $Fixture.Device -Context $Fixture.Context -State $Fixture.State -Now $Fixture.Now
  if ($decision.Allowed -ne $ExpectedAllowed -or $decision.Reason -ne $ExpectedReason) {
    throw ('Esperado {0}, Allowed={1}; recebido {2}, Allowed={3}. {4}' -f $ExpectedReason, $ExpectedAllowed, $decision.Reason, $decision.Allowed, $decision.Detail)
  }
  if ($ExpectedFailureKind -and $decision.FailureKind -ne $ExpectedFailureKind) {
    throw ('FailureKind esperado {0}; recebido {1}.' -f $ExpectedFailureKind, $decision.FailureKind)
  }
  if (-not $decision.Detail) { throw 'A decisão precisa explicar o motivo em PT-BR.' }
  $script:assertions++
}

$f = New-PolicyFixture
Assert-Policy $f 'RecoveryAllowed' $true 'DeviceProblem'
# A decisão é pura e não incrementa contadores nem altera perfil/contexto.
Assert-Policy $f 'RecoveryAllowed' $true
if ($f.State.SessionAttempts -ne 0 -or $f.State.ConsecutiveFailures -ne 3 -or -not $f.Context.MaintenanceArmed -or $f.Profile.ExpectedPort -ne 'COM4') { throw 'A função modificou os dados de entrada.' }

$f = New-PolicyFixture; $f.Profile.Role = ''; Assert-Policy $f 'InvalidProfile'
$f = New-PolicyFixture; $f.Profile.InstanceId = ''; Assert-Policy $f 'InvalidProfile'
$f = New-PolicyFixture; $f.Profile.ExpectedPort = 'COM0'; Assert-Policy $f 'InvalidProfile'
$f = New-PolicyFixture; $f.Profile.ExpectedPort = 'COM4097'; Assert-Policy $f 'InvalidProfile'
$f = New-PolicyFixture; $f.Device = $null; Assert-Policy $f 'DeviceMissing' $false 'Missing'
$f = New-PolicyFixture; $f.Device.InstanceId = 'USB\PINPAD\002'; Assert-Policy $f 'IdentityMismatch'
$f = New-PolicyFixture; $f.Device.InstanceId = 'usb\pinpad\001'; Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.Context.SnapshotComplete = $false; Assert-Policy $f 'IncompleteSnapshot'
$f = New-PolicyFixture; $f.Context.Remove('SnapshotComplete'); Assert-Policy $f 'IncompleteSnapshot'
$f = New-PolicyFixture; $f.Context.ProfileConflict = $true; Assert-Policy $f 'ProfileConflict'
$f = New-PolicyFixture; $f.Context.Remove('ProfileConflict'); Assert-Policy $f 'ConflictCheckUnknown'
$f = New-PolicyFixture; $f.Device.PresenceKnown = $false; Assert-Policy $f 'PresenceUnknown'
$f = New-PolicyFixture; $f.Device.Present = 'true'; Assert-Policy $f 'PresenceUnknown'
$f = New-PolicyFixture; $f.Device.Present = $false; Assert-Policy $f 'DeviceMissing'
$f = New-PolicyFixture; $f.Device.ProblemCode = 22; Assert-Policy $f 'DeviceDisabled' $false 'Disabled'
$f = New-PolicyFixture; $f.Device.ProblemCode = 45; Assert-Policy $f 'DeviceDisconnected' $false 'Missing'
$f = New-PolicyFixture; $f.Device.Port = ''; Assert-Policy $f 'PortUnknown'
$f = New-PolicyFixture; $f.Device.Port = 'COM2'; Assert-Policy $f 'PortMismatch' $false 'PortMismatch'
$f = New-PolicyFixture; $f.Device.ProblemCode = 0; $f.Device.Status = 'OK'; Assert-Policy $f 'NoDeviceProblem' $false 'Healthy'
$f = New-PolicyFixture; $f.Device.ProblemCode = 0; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.ProblemCode = $null; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.ProblemCode = 'CM_PROB_FAILED_START'; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.ProblemCode = -1; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.ProblemCode = 0; $f.Device.Status = 'Unknown'; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.ProblemCode = 0; $f.Device.Status = 'Degraded'; Assert-Policy $f 'ProblemCodeUnknown'
$f = New-PolicyFixture; $f.Device.Class = 'USB'; Assert-Policy $f 'DeviceClassNotAllowed'
$f = New-PolicyFixture; $f.Device.Class = 'PrintQueue'; Assert-Policy $f 'DeviceClassNotAllowed'
$f = New-PolicyFixture; $f.Profile.ExpectedPort = ''; $f.Device.Port = 'LPT1'; Assert-Policy $f 'PortUnknown'
# Impressora física USB sem COM recebe as mesmas proteções de TEF e impressão.
$f = New-PolicyFixture; $f.Profile.Role = 'Impressora'; $f.Profile.InstanceId = 'USBPRINT\BEMATECH\001'; $f.Profile.ExpectedPort = ''; $f.Device.InstanceId = $f.Profile.InstanceId; $f.Device.Class = 'Printer'; $f.Device.Port = $null; Assert-Policy $f 'RecoveryAllowed' $true
$f.Context.BlockingProcessNames = @('Nerus'); Assert-Policy $f 'BlockingProcessesRunning'
$f = New-PolicyFixture; $f.Context.AutoRecoveryEnabled = $false; Assert-Policy $f 'AutomaticRecoveryDisabled'
$f = New-PolicyFixture; $f.Context.AutoRecoveryEnabled = 'true'; Assert-Policy $f 'AutomaticRecoveryDisabled'
$f = New-PolicyFixture; $f.Profile.RecoveryEnabled = $false; Assert-Policy $f 'ProfileRecoveryDisabled'
$f = New-PolicyFixture; $f.Context.MaintenanceArmed = $false; Assert-Policy $f 'MaintenanceNotArmed'
$f = New-PolicyFixture; $f.Context.MaintenanceArmed = 'false'; Assert-Policy $f 'MaintenanceNotArmed'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = $null; Assert-Policy $f 'MaintenanceWindowInvalid'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = 'horario-invalido'; Assert-Policy $f 'MaintenanceWindowInvalid'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = $f.Now; Assert-Policy $f 'MaintenanceWindowInvalid'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = $f.Now.AddSeconds(-1); Assert-Policy $f 'MaintenanceWindowInvalid'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = $f.Now.AddMinutes(15).AddSeconds(1); Assert-Policy $f 'MaintenanceWindowInvalid'
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = $f.Now.AddMinutes(15); Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.Context.MaintenanceExpiresAt = '2026-10-15T15:10:00Z'; Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.Context.WindowsBuild = 7601; Assert-Policy $f 'WindowsNotSupported'
$f = New-PolicyFixture; $f.Context.WindowsBuild = 18363; Assert-Policy $f 'WindowsNotSupported'
$f = New-PolicyFixture; $f.Context.WindowsBuild = 19041; Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.Context.IsAdministrator = $false; Assert-Policy $f 'AdministratorRequired'
$f = New-PolicyFixture; $f.Context.ProcessListConfigured = $false; Assert-Policy $f 'ProcessListNotConfigured'
$f = New-PolicyFixture; $f.Context.ProcessCheckSucceeded = $false; Assert-Policy $f 'ProcessCheckFailed'
$f = New-PolicyFixture; $f.Context.Remove('BlockingProcessNames'); Assert-Policy $f 'ProcessCheckUnknown'
$f = New-PolicyFixture; $f.Context.BlockingProcessNames = @('Nerus', 'CliSiTef'); Assert-Policy $f 'BlockingProcessesRunning'
$f = New-PolicyFixture; $f.Context.PrintCheckSucceeded = $false; Assert-Policy $f 'PrintCheckFailed'
$f = New-PolicyFixture; $f.Context.PendingPrintJobs = $null; Assert-Policy $f 'PrintStateUnknown'
$f = New-PolicyFixture; $f.Context.PendingPrintJobs = -1; Assert-Policy $f 'PrintStateUnknown'
$f = New-PolicyFixture; $f.Context.PendingPrintJobs = 1; Assert-Policy $f 'PendingPrintJobs'
$f = New-PolicyFixture; $f.State.ConsecutiveFailures = 2; Assert-Policy $f 'InsufficientConsecutiveFailures'
$f = New-PolicyFixture; $f.State.Remove('ConsecutiveFailures'); Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.SessionAttempts = -1; Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.SessionAttempts = 3; Assert-Policy $f 'SessionAttemptLimit'
$f = New-PolicyFixture; $f.State.LastAttemptAt = 'horario-invalido'; Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddSeconds(1); Assert-Policy $f 'ClockInconsistent'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-14); Assert-Policy $f 'CooldownActive'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-15); Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.State.SessionAttempts = 1; Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-20); $f.State.AttemptsInWindow = 1; Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.WindowStartedAt = 'horario-invalido'; Assert-Policy $f 'RecoveryStateInvalid'
$f = New-PolicyFixture; $f.State.WindowStartedAt = $f.Now.AddSeconds(1); Assert-Policy $f 'ClockInconsistent'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-20); $f.State.AttemptsInWindow = 2; $f.State.SessionAttempts = 2; $f.State.WindowStartedAt = $f.Now.AddMinutes(-40); Assert-Policy $f 'HourlyAttemptLimit'
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-20); $f.State.AttemptsInWindow = 2; $f.State.SessionAttempts = 2; $f.State.WindowStartedAt = $f.Now.AddHours(-1); Assert-Policy $f 'RecoveryAllowed' $true
$f = New-PolicyFixture; $f.State.LastAttemptAt = $f.Now.AddMinutes(-20); $f.State.AttemptsInWindow = 1; $f.State.SessionAttempts = 1; $f.State.WindowStartedAt = $f.Now.AddMinutes(-40); Assert-Policy $f 'RecoveryAllowed' $true
# Objetos PSObject também são aceitos, sem depender de hashtables.
$f = New-PolicyFixture
$f.Profile = New-Object PSObject -Property $f.Profile
$f.Device = New-Object PSObject -Property $f.Device
$f.Context = New-Object PSObject -Property $f.Context
$f.State = New-Object PSObject -Property $f.State
Assert-Policy $f 'RecoveryAllowed' $true
Write-Host ('PASS: ' + $script:assertions + ' decisões sintéticas; identidade, presença, portas, códigos, manutenção, processos, impressão e limites. Nenhum dispositivo ou processo real foi acessado. Execução com PowerShell ' + $PSVersionTable.PSVersion + '; compatibilidade PS2 requer validação no Windows 7.')
