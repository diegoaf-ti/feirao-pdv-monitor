#requires -Version 5.1
# Offline: compila C# e exercita somente construcao pura do ambiente, sem Win32/EXEs.
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version 2.0;
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
Add-Type -Path (Join-Path $directory 'piloto-remoto/windows/RemoteWindowsNative.cs') -ErrorAction Stop;
$script:Checks = 0;
function Assert-Env { param([bool]$Value, [string]$Name); $script:Checks++; if (-not $Value) { throw $Name; } }
function Assert-EnvThrows { param([scriptblock]$Action, [string]$Expected); $script:Checks++; try { & $Action | Out-Null; } catch { if ($_.Exception.GetBaseException().Message -ceq $Expected) { return; }; throw; }; throw ('Faltou erro: ' + $Expected); }
function New-EnvironmentFixture { return ,@('C:\Windows','C:\Windows\System32','D:\ProgramData\Feirao\PdvMonitorRemoto\bundle\bin\stunnel','C:\Users\Operador','C:\Users\Operador\AppData\Roaming','C:\Users\Operador\AppData\Local'); }
function Invoke-EnvironmentFixture { param([string[]]$Paths); return [Conecta.PdvRemotePilot.LeaseSupervisor]::BuildChildEnvironmentBlock($Paths[0],$Paths[1],$Paths[2],$Paths[3],$Paths[4],$Paths[5]); }
$paths = New-EnvironmentFixture; $baseline = Invoke-EnvironmentFixture $paths;
Assert-Env ($baseline.EndsWith("`0`0", [StringComparison]::Ordinal)) 'Bloco deve terminar em dois NULs';
$entries = @($baseline.Split([char]0) | Where-Object { $_.Length -gt 0 });
Assert-Env ($entries.Count -eq 12) 'Whitelist deve ter exatamente doze entradas';
$values = @{}; $names = @();
foreach ($entry in $entries) {
  $separator = $entry.IndexOf('='); Assert-Env ($separator -gt 0) 'Entrada de ambiente invalida';
  $name = $entry.Substring(0,$separator); Assert-Env (-not $values.ContainsKey($name)) 'Variavel de ambiente duplicada';
  $names += $name; $values[$name] = $entry.Substring($separator+1);
}
$sorted = @($names); [Array]::Sort($sorted,[StringComparer]::OrdinalIgnoreCase);
Assert-Env (($names -join '|') -ceq ($sorted -join '|')) 'Bloco Windows precisa ter ordenacao deterministica';
Assert-Env ($values['OPENSSL_CONF'] -ceq 'NUL') 'Config OpenSSL externa nao foi desativada';
Assert-Env ($values['OPENSSL_ENGINES'] -ceq $paths[2] -and $values['OPENSSL_MODULES'] -ceq $paths[2]) 'Providers/engines precisam usar o binario protegido';
Assert-Env ($values['PATH'] -ceq 'C:\Windows\System32;C:\Windows') 'PATH nao deve conter usuario/bundle/PATH herdado';
Assert-Env ($values['SystemRoot'] -ceq 'C:\Windows' -and $values['WINDIR'] -ceq 'C:\Windows' -and $values['SystemDrive'] -ceq 'C:') 'Raizes do Windows incorretas';
Assert-Env ($values['TEMP'] -ceq 'C:\Users\Operador\AppData\Local\Temp' -and $values['TMP'] -ceq $values['TEMP']) 'TEMP/TMP devem vir do known-folder explicito';
foreach ($name in @('USERPROFILE','APPDATA','LOCALAPPDATA')) { Assert-Env ($values.ContainsKey($name)) 'Known-folder necessario ausente'; }
$malicious = @('OPENSSL_CONF','OPENSSL_CONF_INCLUDE','OPENSSL_MODULES','OPENSSL_ENGINES','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','COMPLUS_ReadyToRun','COMPLUS_ZapDisable','__COMPAT_LAYER','PATH','SystemRoot','WINDIR','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','COMSPEC','PYTHONPATH','LD_PRELOAD');
$previous = @{};
try {
  foreach ($name in $malicious) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process); [Environment]::SetEnvironmentVariable($name, ('ATTACKER_' + $name), [EnvironmentVariableTarget]::Process); }
  $underAttack = Invoke-EnvironmentFixture $paths;
  Assert-Env ($underAttack -ceq $baseline) 'Ambiente herdado mudou o bloco puro';
  Assert-Env (-not $underAttack.Contains('ATTACKER_')) 'Ambiente herdado vazou para o filho';
  foreach ($name in @('COR_ENABLE_PROFILING','COR_PROFILER','CORECLR_ENABLE_PROFILING','COMPLUS_ReadyToRun','__COMPAT_LAYER','COMSPEC','OPENSSL_CONF_INCLUDE','LD_PRELOAD')) { Assert-Env (-not (($underAttack.Split([char]0)) -match ('^' + [regex]::Escape($name) + '='))) 'Injetor herdado foi permitido'; }
} finally { foreach ($name in $malicious) { [Environment]::SetEnvironmentVariable($name,$previous[$name],[EnvironmentVariableTarget]::Process); } }
foreach ($bad in @('', 'relative\bin', '\\server\share\bin','C:relative','C:\Windows;C:\Attack','C:\Windows%PATH%','C:\Windows=Injected','C:\Windows\..\Attack','C:\Windows\.',"C:\Windows`0EVIL=x", "C:\Windows`r`nEVIL=x", 'C:/Windows','C:\Windows\bad?path','C:\Windows\bad.','C:\Windows\bad ')) {
  $altered = New-EnvironmentFixture; $altered[2] = $bad;
  Assert-EnvThrows { Invoke-EnvironmentFixture $altered } 'RemoteChildEnvironmentPath';
}
$altered = New-EnvironmentFixture; $altered[1]='D:\Attacker\System32';
Assert-EnvThrows { Invoke-EnvironmentFixture $altered } 'RemoteChildEnvironmentSystemPath';
$altered = New-EnvironmentFixture; $altered[4]='C:\Users\Manutenção\AppData\Roaming'; $altered[5]='C:\Users\Manutenção\AppData\Local';
$unicode = Invoke-EnvironmentFixture $altered;
Assert-Env ($unicode.Contains('Manutenção') -and $unicode.EndsWith("`0`0")) 'Ambiente Unicode perdeu nomes de pasta';
$altered = New-EnvironmentFixture; $altered[2] = 'C:\' + ('x' * 17000);
Assert-EnvThrows { Invoke-EnvironmentFixture $altered } 'RemoteChildEnvironmentTooLarge';
Write-Output ('PASS: ' + $script:Checks + ' verificacoes puras de ambiente de filhos, sem executar binarios Windows.');
