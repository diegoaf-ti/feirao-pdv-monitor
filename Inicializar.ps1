#requires -Version 2.0
# Este iniciador precisa continuar legível no PowerShell original do Windows 7.
$ErrorActionPreference = 'Stop';
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
$build = [Environment]::OSVersion.Version.Build;
try {
  if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
    try {
      $operatingSystem = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop;
      $build = [int]$operatingSystem.BuildNumber;
    } catch {
      $build = 0;
      Write-Host 'A versão do Windows não pôde ser consultada; será usado o modo legado de consulta.';
    }
  }
  $modernPowerShell = $PSVersionTable.PSVersion -ge [version]'5.1';
  $pnpCommand = $null;
  if ($modernPowerShell -and $build -ge 10240) {
    $pnpCommand = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue;
  }
  $global:LASTEXITCODE = 0;
  if ($modernPowerShell -and $build -ge 10240 -and $null -ne $pnpCommand) {
    Write-Host 'Abrindo o piloto de dispositivos para Windows 10/11.';
    & (Join-Path $directory 'PdvDispositivos.ps1');
  } else {
    Write-Host 'Abrindo o modo legado de consulta. Reinício de dispositivos indisponível neste modo.';
    & (Join-Path $directory 'DiagnosticoLegado.ps1');
  }
  exit $LASTEXITCODE;
} catch {
  Write-Host ('Não foi possível iniciar o aplicativo: ' + $_.Exception.Message) -ForegroundColor Red;
  exit 1;
}
