#requires -Version 5.1
# Isola os helpers e a passagem de estado ao coletor em segundo plano.
# Não abre WinForms, não instala início automático e não acessa o Windows real.
$ErrorActionPreference = 'Stop';
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
$sourcePath = Join-Path $directory 'MonitorPdv.ps1';
$tokens = $null; $errors = $null;
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors);
if (@($errors).Count) { throw ($errors | Out-String); }
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  if ($definition.Name -eq 'Get-PdvMonitorProcessNames' -or $definition.Name -eq 'Get-PdvMonitorMutexName') {
    . ([scriptblock]::Create($definition.Extent.Text));
  }
}
function Assert-Host($Condition, $Message) { if (-not $Condition) { throw $Message; } }
$names = @(Get-PdvMonitorProcessNames ' nerus ; clienteSitef;nerus;; ');
Assert-Host ($names.Count -eq 2 -and $names[0] -eq 'nerus' -and $names[1] -eq 'clienteSitef') 'Normaliza e remove repetições sem inventar nomes de processos.';
foreach ($invalid in @('nerus.exe', 'C:\Nerus\nerus', 'nerus*', 'pasta/processo', 'a|b')) {
  $rejected = $false;
  try { [void](Get-PdvMonitorProcessNames $invalid); } catch { $rejected = $true; }
  Assert-Host $rejected ('Rejeita caminho/extensão/coringa: ' + $invalid);
}
Assert-Host (@(Get-PdvMonitorProcessNames '').Count -eq 0) 'Entrada vazia não cria processo fictício.';
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'pdv-host-test';
$first = Get-PdvMonitorMutexName -UserIdentity 'test-user-one' -Directory $testDirectory;
$same = Get-PdvMonitorMutexName -UserIdentity 'test-user-one' -Directory $testDirectory;
$otherUser = Get-PdvMonitorMutexName -UserIdentity 'test-user-two' -Directory $testDirectory;
$otherDirectory = Get-PdvMonitorMutexName -UserIdentity 'test-user-one' -Directory ($testDirectory + '-other');
Assert-Host ($first -eq $same -and $first -ne $otherUser -and $first -ne $otherDirectory) 'Mutex vincula uma sessão ao usuário e à pasta de dados.';

$session = New-Object PSObject -Property @{ StatusText = 'before'; Config = (New-Object PSObject -Property @{ Value = 1 }); Signals = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)) };
$worker = [System.Management.Automation.PowerShell]::Create();
try {
  [void]$worker.AddScript('param($session) $session.StatusText = "after"; $session.Config.Value = 2; $session.Signals.Enqueue("signal")');
  [void]$worker.AddArgument($session);
  $result = $worker.BeginInvoke();
  [void]$worker.EndInvoke($result);
  Assert-Host ($session.StatusText -eq 'after' -and $session.Config.Value -eq 2 -and $session.Signals.Dequeue() -eq 'signal') 'Runspace local compartilha a mesma sessão e fila com a interface.';
} finally { $worker.Dispose(); }
Write-Host 'PASS: sintaxe do host, validação de nomes de processos, mutex e estado compartilhado com a coleta. Não valida interface, inicialização automática ou hardware Windows.';
