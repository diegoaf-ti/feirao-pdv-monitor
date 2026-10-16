# Política pura, compatível com a sintaxe do Windows PowerShell 2.0.
# Não consulta o Windows, não abre COM, não altera configurações e não reinicia
# dispositivos. O chamador coleta dados recentes e executa eventual ação.
Set-StrictMode -Version 2.0

function Get-PdvPolicyValue {
  param($InputObject, [string]$Name, $Default = $null)
  if ($null -eq $InputObject) { return ,$Default }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return ,$InputObject[$Name] }
  } else {
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
  }
  return ,$Default
}

function Test-PdvPolicyTrue {
  param($Value)
  # Uma string como "false" não pode armar recuperação por conversão booleana.
  return ($Value -is [bool] -and $Value -eq $true)
}

function ConvertTo-PdvPolicyPort {
  param($Value)
  $port = ([string]$Value).Trim().ToUpperInvariant()
  if ($port -match '^COM([1-9][0-9]{0,3})$' -and [int]$Matches[1] -le 4096) { return $port }
  return $null
}

function ConvertTo-PdvPolicyDate {
  param($Value)
  if ($null -eq $Value -or [string]$Value -eq '') { return $null }
  try {
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return (New-Object DateTimeOffset($Value)) }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
  } catch { return $null }
}

function New-PdvPolicyDecision {
  param([bool]$Allowed, [string]$Reason, [string]$FailureKind, [string]$Detail)
  return (New-Object PSObject -Property @{
    Allowed = $Allowed
    Reason = $Reason
    FailureKind = $FailureKind
    Detail = $Detail
  })
}

function Get-PdvRecoveryDecision {
  <#
  .SYNOPSIS
  Avalia uma tentativa de recuperação sem executar qualquer ação.
  .DESCRIPTION
  Os booleanos precisam ser booleanos reais. BlockingProcessNames contém os
  processos encontrados nesta leitura; ProcessListConfigured confirma que o
  técnico cadastrou explicitamente todos os processos do PDV/TEF. O chamador
  deve repetir as verificações imediatamente antes de reiniciar o dispositivo.
  ConsecutiveFailures conta somente leituras consecutivas do mesmo problema no
  InstanceId exato; a contagem e os limites são mantidos pelo chamador. State
  nunca é modificado por esta função. Uma tentativa iniciada, mesmo malsucedida,
  deve consumir os limites. A autorização de manutenção não persiste ao fechar
  o monitor e não pode exceder 15 minutos.
  .OUTPUTS
  Allowed, Reason (código estável), FailureKind e Detail (explicação em PT-BR).
  #>
  [CmdletBinding()]
  param(
    $Profile,
    $Device,
    $Context,
    $State,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Now
  )

  $profileId = ([string](Get-PdvPolicyValue $Profile 'InstanceId' '')).Trim()
  $role = ([string](Get-PdvPolicyValue $Profile 'Role' '')).Trim()
  $expectedRaw = ([string](Get-PdvPolicyValue $Profile 'ExpectedPort' '')).Trim()
  $expectedPort = ConvertTo-PdvPolicyPort $expectedRaw
  if (-not $profileId -or -not $role -or ($expectedRaw -and -not $expectedPort)) {
    return (New-PdvPolicyDecision $false 'InvalidProfile' 'InvalidProfile' 'Perfil incompleto ou porta esperada inválida.')
  }
  if ($null -eq $Device) {
    return (New-PdvPolicyDecision $false 'DeviceMissing' 'Missing' 'Dispositivo não localizado pelo InstanceId exato. Nenhuma substituição automática é permitida.')
  }
  $deviceId = ([string](Get-PdvPolicyValue $Device 'InstanceId' '')).Trim()
  if (-not $deviceId -or $deviceId -ne $profileId) {
    return (New-PdvPolicyDecision $false 'IdentityMismatch' 'IdentityMismatch' 'O dispositivo não corresponde ao InstanceId exato do perfil.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'SnapshotComplete'))) {
    return (New-PdvPolicyDecision $false 'IncompleteSnapshot' 'Unknown' 'A coleta de dispositivos está incompleta. Apenas registrar o diagnóstico.')
  }
  $conflict = Get-PdvPolicyValue $Context 'ProfileConflict'
  if ($conflict -isnot [bool]) {
    return (New-PdvPolicyDecision $false 'ConflictCheckUnknown' 'Unknown' 'Não foi possível excluir conflito ou ambiguidade no perfil.')
  }
  if ($conflict) {
    return (New-PdvPolicyDecision $false 'ProfileConflict' 'Conflict' 'Há conflito de porta, perfil ou identidade. Nenhuma correção automática é permitida.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Device 'PresenceKnown'))) {
    return (New-PdvPolicyDecision $false 'PresenceUnknown' 'Unknown' 'A presença física do dispositivo não foi confirmada.')
  }
  $present = Get-PdvPolicyValue $Device 'Present'
  if ($present -isnot [bool]) {
    return (New-PdvPolicyDecision $false 'PresenceUnknown' 'Unknown' 'A informação de presença do dispositivo é inválida.')
  }
  if (-not $present) {
    return (New-PdvPolicyDecision $false 'DeviceMissing' 'Missing' 'Dispositivo ausente. O monitor não muda portas nem reinicia outro equipamento.')
  }

  $problemRaw = Get-PdvPolicyValue $Device 'ProblemCode'
  $problemCode = 0
  $problemKnown = ($null -ne $problemRaw -and [int]::TryParse([string]$problemRaw, [ref]$problemCode) -and $problemCode -ge 0)
  if ($problemKnown -and $problemCode -eq 22) {
    return (New-PdvPolicyDecision $false 'DeviceDisabled' 'Disabled' 'O dispositivo está desabilitado (código 22). O monitor nunca o habilita automaticamente.')
  }
  if ($problemKnown -and $problemCode -eq 45) {
    return (New-PdvPolicyDecision $false 'DeviceDisconnected' 'Missing' 'O Windows informa equipamento desconectado (código 45). Apenas registrar o diagnóstico.')
  }

  $actualPort = ConvertTo-PdvPolicyPort (Get-PdvPolicyValue $Device 'Port')
  if ($expectedPort -and -not $actualPort) {
    return (New-PdvPolicyDecision $false 'PortUnknown' 'Unknown' 'A porta COM esperada foi definida, mas a porta atual não foi identificada.')
  }
  if ($expectedPort -and $actualPort -ne $expectedPort) {
    return (New-PdvPolicyDecision $false 'PortMismatch' 'PortMismatch' ('Porta esperada ' + $expectedPort + '; atual ' + $actualPort + '. O monitor nunca renumera portas automaticamente.'))
  }
  $status = ([string](Get-PdvPolicyValue $Device 'Status' '')).Trim()
  if (-not $problemKnown -or $problemCode -eq 0) {
    if ($problemKnown -and $problemCode -eq 0 -and $status -eq 'OK') {
      return (New-PdvPolicyDecision $false 'NoDeviceProblem' 'Healthy' 'O Windows não informa falha concreta. Isso não confirma comunicação com Nerus ou SiTef.')
    }
    return (New-PdvPolicyDecision $false 'ProblemCodeUnknown' 'Unknown' 'Não há código numérico de falha concreto. Estado Error, Degraded ou Unknown isolado não autoriza reinício.')
  }
  $failureKind = 'DeviceProblem'
  $deviceClass = [string](Get-PdvPolicyValue $Device 'Class' '')
  if (@('Ports', 'Printer') -notcontains $deviceClass -and $deviceId -notmatch '^USBPRINT\\') {
    return (New-PdvPolicyDecision $false 'DeviceClassNotAllowed' $failureKind 'Recuperação restrita a portas COM e dispositivos físicos de impressora; hubs, controladores e filas virtuais são excluídos.')
  }
  if ($deviceClass -eq 'Ports' -and -not $actualPort) {
    return (New-PdvPolicyDecision $false 'PortUnknown' $failureKind 'Dispositivo da classe Ports sem COM confirmada; portas paralelas não são reiniciadas.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'AutoRecoveryEnabled'))) {
    return (New-PdvPolicyDecision $false 'AutomaticRecoveryDisabled' $failureKind 'Recuperação automática desativada. Coleta e registros continuam normalmente.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Profile 'RecoveryEnabled'))) {
    return (New-PdvPolicyDecision $false 'ProfileRecoveryDisabled' $failureKind 'O técnico não habilitou recuperação automática para este perfil.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'MaintenanceArmed'))) {
    return (New-PdvPolicyDecision $false 'MaintenanceNotArmed' $failureKind 'A janela de manutenção precisa ser armada explicitamente pelo técnico com o caixa fora de operação.')
  }
  $maintenanceExpiresAt = ConvertTo-PdvPolicyDate (Get-PdvPolicyValue $Context 'MaintenanceExpiresAt')
  if ($null -eq $maintenanceExpiresAt -or $maintenanceExpiresAt -le $Now -or $maintenanceExpiresAt -gt $Now.AddMinutes(15)) {
    return (New-PdvPolicyDecision $false 'MaintenanceWindowInvalid' $failureKind 'Janela de manutenção ausente, expirada ou superior a 15 minutos. Apenas registrar o diagnóstico.')
  }
  $build = 0
  if (-not [int]::TryParse([string](Get-PdvPolicyValue $Context 'WindowsBuild'), [ref]$build) -or $build -lt 19041) {
    return (New-PdvPolicyDecision $false 'WindowsNotSupported' $failureKind 'Reinício automático disponível somente no Windows 10 build 19041 ou superior; outros sistemas apenas coletam registros.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'IsAdministrator'))) {
    return (New-PdvPolicyDecision $false 'AdministratorRequired' $failureKind 'A sessão não confirmou permissão de administrador. Apenas registrar o diagnóstico.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'ProcessListConfigured'))) {
    return (New-PdvPolicyDecision $false 'ProcessListNotConfigured' $failureKind 'Cadastre explicitamente os nomes de todos os processos de Nerus e TEF antes de permitir recuperação.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'ProcessCheckSucceeded'))) {
    return (New-PdvPolicyDecision $false 'ProcessCheckFailed' $failureKind 'A consulta atual dos processos falhou. Não é possível excluir pagamento ou uso do dispositivo.')
  }
  $blockingNames = Get-PdvPolicyValue $Context 'BlockingProcessNames'
  if ($null -eq $blockingNames) {
    return (New-PdvPolicyDecision $false 'ProcessCheckUnknown' $failureKind 'O resultado da consulta dos processos não foi informado.')
  }
  if (@($blockingNames).Count -gt 0) {
    return (New-PdvPolicyDecision $false 'BlockingProcessesRunning' $failureKind 'Há processos do PDV ou TEF em execução. O monitor não fecha programas nem interrompe pagamentos.')
  }
  if (-not (Test-PdvPolicyTrue (Get-PdvPolicyValue $Context 'PrintCheckSucceeded'))) {
    return (New-PdvPolicyDecision $false 'PrintCheckFailed' $failureKind 'A consulta atual da fila de impressão falhou. Apenas registrar o diagnóstico.')
  }
  $pendingPrintJobs = 0
  if (-not [int]::TryParse([string](Get-PdvPolicyValue $Context 'PendingPrintJobs'), [ref]$pendingPrintJobs) -or $pendingPrintJobs -lt 0) {
    return (New-PdvPolicyDecision $false 'PrintStateUnknown' $failureKind 'A quantidade de trabalhos de impressão não foi confirmada.')
  }
  if ($pendingPrintJobs -gt 0) {
    return (New-PdvPolicyDecision $false 'PendingPrintJobs' $failureKind 'Há trabalhos na fila de impressão. O monitor não cancela documentos nem reinicia durante impressão pendente.')
  }

  $consecutiveFailures = 0
  $attemptsInWindow = 0
  $sessionAttempts = 0
  if (-not [int]::TryParse([string](Get-PdvPolicyValue $State 'ConsecutiveFailures'), [ref]$consecutiveFailures) -or $consecutiveFailures -lt 0 -or
      -not [int]::TryParse([string](Get-PdvPolicyValue $State 'AttemptsInWindow'), [ref]$attemptsInWindow) -or $attemptsInWindow -lt 0 -or
      -not [int]::TryParse([string](Get-PdvPolicyValue $State 'SessionAttempts'), [ref]$sessionAttempts) -or $sessionAttempts -lt 0) {
    return (New-PdvPolicyDecision $false 'RecoveryStateInvalid' $failureKind 'O histórico de tentativas ou de leituras está incompleto; recuperação bloqueada.')
  }
  if ($consecutiveFailures -lt 3) {
    return (New-PdvPolicyDecision $false 'InsufficientConsecutiveFailures' $failureKind 'Aguardar pelo menos três leituras consecutivas da mesma falha concreta.')
  }
  if ($sessionAttempts -ge 3) {
    return (New-PdvPolicyDecision $false 'SessionAttemptLimit' $failureKind 'Limite de três tentativas por sessão atingido; é necessária análise técnica.')
  }
  $lastAttemptRaw = Get-PdvPolicyValue $State 'LastAttemptAt'
  $lastAttemptAt = ConvertTo-PdvPolicyDate $lastAttemptRaw
  if ($null -ne $lastAttemptRaw -and [string]$lastAttemptRaw -ne '' -and $null -eq $lastAttemptAt) {
    return (New-PdvPolicyDecision $false 'RecoveryStateInvalid' $failureKind 'O horário da última tentativa é inválido.')
  }
  if ($null -ne $lastAttemptAt) {
    if ($lastAttemptAt -gt $Now) {
      return (New-PdvPolicyDecision $false 'ClockInconsistent' $failureKind 'O histórico contém tentativa no futuro. Conferir relógio antes de agir.')
    }
    if ($lastAttemptAt.AddMinutes(15) -gt $Now) {
      return (New-PdvPolicyDecision $false 'CooldownActive' $failureKind 'Aguardar ao menos 15 minutos após a última tentativa, mesmo que ela tenha falhado.')
    }
  } elseif ($sessionAttempts -gt 0 -or $attemptsInWindow -gt 0) {
    return (New-PdvPolicyDecision $false 'RecoveryStateInvalid' $failureKind 'Há tentativas registradas sem horário da última ação.')
  }
  $windowRaw = Get-PdvPolicyValue $State 'WindowStartedAt'
  $windowStartedAt = ConvertTo-PdvPolicyDate $windowRaw
  if ($null -ne $windowRaw -and [string]$windowRaw -ne '' -and $null -eq $windowStartedAt) {
    return (New-PdvPolicyDecision $false 'RecoveryStateInvalid' $failureKind 'O início da janela de tentativas é inválido.')
  }
  if ($null -ne $windowStartedAt -and $windowStartedAt -gt $Now) {
    return (New-PdvPolicyDecision $false 'ClockInconsistent' $failureKind 'O histórico contém janela de tentativas no futuro. Conferir relógio antes de agir.')
  }
  if ($attemptsInWindow -gt 0 -and $null -eq $windowStartedAt) {
    return (New-PdvPolicyDecision $false 'RecoveryStateInvalid' $failureKind 'Há tentativas registradas sem início da janela de uma hora.')
  }
  if ($attemptsInWindow -ge 2 -and $null -ne $windowStartedAt -and $windowStartedAt.AddHours(1) -gt $Now) {
    return (New-PdvPolicyDecision $false 'HourlyAttemptLimit' $failureKind 'Limite de duas tentativas nesta janela de uma hora atingido.')
  }
  return (New-PdvPolicyDecision $true 'RecoveryAllowed' $failureKind 'Falha concreta confirmada e verificações aprovadas dentro da janela de manutenção; refazer coleta imediatamente antes de agir.')
}

Export-ModuleMember -Function Get-PdvRecoveryDecision
