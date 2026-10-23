#requires -Version 5.1
# Mocks de arquivos, atalhos, processos e janela; nao usa COM, WMI ou processos reais.
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
$helper=Join-Path (Split-Path -Parent $directory) 'PdvMonitor.NerusRestart.Helpers.ps1';
if ([IO.File]::Exists($helper)) { . $helper; }
else {
  $tokens=$null; $errors=$null;
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'PdvMonitor.Nerus.psm1'),[ref]$tokens,[ref]$errors);
  if (@($errors).Count) { throw 'Falha de sintaxe no modulo Nerus.'; }
  foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($definition.Name -match 'PdvNerusRestart|^Get-PdvNerusDesktopLaunch$|^Close-PdvNerusBoundWindow$|^Start-PdvNerusBoundLaunch$') { . ([scriptblock]::Create($definition.Extent.Text)); }
  }
}
$script:checks=0;
function Assert-Restart($Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw $Message; } }
function Assert-RestartError([scriptblock]$Action,[string]$Expected) {
  $message=''; try { & $Action | Out-Null; } catch { $message=[string]$_.Exception.Message; }
  Assert-Restart ($message -ceq $Expected) ('Motivo esperado: '+$Expected+'; recebido: '+$message);
  Assert-Restart ($message -notmatch 'opaque-argument|credential') 'Argumentos nunca aparecem em erros.';
}
function Reset-Restart {
  $script:desktops=@('C:\Users\Caixa\Desktop','C:\Users\Public\Desktop');
  $script:existing=@('C:\Users\Caixa\Desktop\Nerus.lnk');
  $script:pathFault=''; $script:pathFaultReason='NerusRestartReparsePath';
  $script:shortcut=@{TargetPath='C:\Nerus\nerus.exe';Arguments='--opaque-argument';WorkingDirectory='C:\Nerus'};
  $script:hashes=@{'C:\Users\Caixa\Desktop\Nerus.lnk'=('a'*64);'C:\Users\Public\Desktop\Nerus.lnk'=('a'*64);'C:\Nerus\nerus.exe'=('b'*64)};
  $script:identity=@{ProcessId=123;ProcessName='nerus';TargetPath='C:\Nerus\nerus.exe';StartTimeTicks=638900000000000000L;SessionId=2;OwnerSid='S-1-5-21-test';MainWindowHandle=999L};
  $script:context=@{SessionId=2;OwnerSid='S-1-5-21-test'};
  $script:processes=@((New-Object PSObject -Property @{Id=123;ProcessName='nerus'}));
  $script:readDenied=$false; $script:identityDenied=$false; $script:enumerationDenied=$false;
  $script:closeAccepted=$true; $script:exited=$true; $script:startDenied=$false;
  $script:startUnconfirmed=$false; $script:concurrentStart=$false; $script:closeCalls=0; $script:startCalls=0; $script:waitCalls=0;
  $script:shortcutReads=0; $script:changeShortcutAt=0; $script:pathInfoCalls=@();
}
function Get-PdvNerusRestartDesktopPaths { return @($script:desktops); }
function Test-PdvNerusRestartFileExists { param([string]$Path); return ($script:existing -icontains $Path); }
function Get-PdvNerusRestartPathInfo {
  param([string]$Path,[bool]$Directory=$false);
  $script:pathInfoCalls+=,@{Path=$Path;Directory=$Directory};
  if ($Path -eq $script:pathFault) { throw $script:pathFaultReason; }
  if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f\x7f]') { throw 'NerusRestartPathInvalid'; }
  return @{FullPath=$Path;Directory=$Directory};
}
function Get-PdvNerusRestartFileHash {
  param([string]$Path);
  if ($script:hashes.ContainsKey($Path)) { return $script:hashes[$Path]; }
  return ('c'*64);
}
function Read-PdvNerusRestartShortcut {
  param([string]$Path);
  if ($script:readDenied) { throw 'credential --opaque-argument'; }
  $script:shortcutReads++;
  if ($script:changeShortcutAt -eq $script:shortcutReads) { $script:hashes[$Path]=('f'*64); }
  return $script:shortcut;
}
function Get-PdvNerusRestartCurrentContext { return $script:context; }
function Get-PdvNerusRestartProcesses { if ($script:enumerationDenied) { throw 'denied credential'; }; return @($script:processes); }
function Get-PdvNerusRestartProcessIdentity { param($Process); if ($script:identityDenied) { throw 'denied credential'; }; return $script:identity; }
function Invoke-PdvNerusRestartCloseRequest { param($Binding); $script:closeCalls++; return $script:closeAccepted; }
function Wait-PdvNerusRestartExit { param($Binding,[int]$TimeoutMilliseconds); $script:waitCalls++; Assert-Restart ($TimeoutMilliseconds -eq 30000) 'Espera de fechamento limitada a30s.'; return $script:exited; }
function Invoke-PdvNerusRestartLaunchProcess {
  param($Launch); $script:startCalls++;
  if ($script:startDenied) { throw 'denied credential --opaque-argument'; }
  Assert-Restart ($Launch.Arguments -ceq '--opaque-argument') 'Argumentos aprovados do atalho preservados somente em memoria.';
  $script:processes=@((New-Object PSObject -Property @{Id=123;ProcessName='nerus'}));
  if ($script:concurrentStart) { $script:processes+=,(New-Object PSObject -Property @{Id=124;ProcessName='nerus'}); }
  return (New-Object PSObject -Property @{Id=123});
}
function Wait-PdvNerusRestartStarted {
  param($Process,$Launch,[int]$TimeoutMilliseconds);
  Assert-Restart ($TimeoutMilliseconds -eq 3000) 'Confirmacao de abertura limitada a3s.';
  if ($script:startUnconfirmed) { throw 'NerusRestartLaunchUnconfirmed'; }
  return $script:identity;
}

Reset-Restart;
$launch=Get-PdvNerusDesktopLaunch;
Assert-Restart ($launch.TargetPath -ceq 'C:\Nerus\nerus.exe' -and $launch.ProcessName -ceq 'nerus') 'Resolve somente o atalho Nerus.lnk e seu executavel.';
Assert-Restart ($launch.Arguments -ceq '--opaque-argument' -and $launch.WorkingDirectory -ceq 'C:\Nerus') 'Preserva argumentos e diretorio do atalho em memoria.';
Assert-Restart ($script:pathInfoCalls.Count -eq 3) 'Valida caminho do atalho, executavel e diretorio de trabalho.';
$binding=Get-PdvNerusRestartBinding $launch;
Assert-Restart ($binding.ProcessId -eq 123 -and $binding.StartTimeTicks -eq $script:identity.StartTimeTicks) 'Vincula PID e inicio da unica instancia.';
Assert-Restart (-not $binding.ContainsKey('Arguments')) 'Binding de processo nao contem argumentos.';
$closed=Close-PdvNerusBoundWindow $launch $binding;
Assert-Restart ($closed.Exited -and $script:closeCalls -eq 1 -and $script:waitCalls -eq 1) 'Solicita um fechamento suave e aguarda saida.';
Assert-Restart (-not $closed.ContainsKey('Arguments')) 'Resultado de fechamento nao contem argumentos.';
$script:processes=@(); $opened=Start-PdvNerusBoundLaunch $launch;
Assert-Restart ($opened.Started -and $script:startCalls -eq 1) 'Reabre uma vez o executavel aprovado.';
Assert-Restart (-not $opened.ContainsKey('Arguments') -and -not $opened.ContainsKey('TargetPath')) 'Resultado publico nao inclui linha de comando.';
Assert-RestartError { Start-PdvNerusBoundLaunch $launch } 'NerusRestartAlreadyStarted';
Assert-Restart ($script:startCalls -eq 1) 'Nao reabre em duplicidade na mesma operacao.';

Reset-Restart; $script:existing=@(); Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartShortcutMissing';
Reset-Restart; $script:existing+=,'C:\Users\Public\Desktop\Nerus.lnk'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartShortcutAmbiguous';
Reset-Restart; $script:desktops+=,'C:\Users\Caixa\Desktop'; Assert-Restart ((Get-PdvNerusDesktopLaunch).ProcessName -eq 'nerus') 'Pasta repetida nao cria falso atalho duplicado.';
Reset-Restart; $script:existing=@('C:\Users\Public\Desktop\Nerus.lnk'); Assert-Restart ((Get-PdvNerusDesktopLaunch).ShortcutPath -match 'Public') 'Aceita somente atalho comum quando e o unico.';
Reset-Restart; $script:readDenied=$true; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartShortcutUnavailable';
Reset-Restart; $script:pathFault=$script:existing[0]; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartReparsePath';
Reset-Restart; $script:pathFault=$script:shortcut.TargetPath; $script:pathFaultReason='NerusRestartPathMissing'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartPathMissing';
Reset-Restart; $script:shortcut.TargetPath='\\server\Nerus\nerus.exe'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartPathInvalid';
Reset-Restart; $script:shortcut.WorkingDirectory='\\server\Nerus'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartPathInvalid';
Reset-Restart; $script:shortcut.WorkingDirectory=''; Assert-Restart ((Get-PdvNerusDesktopLaunch).WorkingDirectory -ceq 'C:\Nerus') 'Diretorio vazio do atalho usa a pasta do executavel.';
Reset-Restart; $script:shortcut.TargetPath='C:\Nerus\nerus.bat'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartExecutableInvalid';
foreach ($name in @('cmd','powershell','pwsh','rundll32','wscript','mshta','chrome','msedge','mstsc','ssh','putty','CliSiTef','clienteSitef','sitef','paygo','pinpad','python3','javaw','node','AnyDesk')) {
  Reset-Restart; $script:shortcut.TargetPath='C:\Nerus\'+$name+'.exe'; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartTargetNotAllowed';
}
Reset-Restart; $script:shortcut.Arguments="first`nsecond"; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartArgumentsInvalid';
Reset-Restart; $script:shortcut.Arguments=('x'*8193); Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartArgumentsInvalid';
Reset-Restart; $script:changeShortcutAt=1; Assert-RestartError { Get-PdvNerusDesktopLaunch } 'NerusRestartShortcutChanged';
foreach ($field in @('ShortcutHash','TargetHash','Arguments','WorkingDirectory','TargetPath')) {
  Reset-Restart; $launch=Get-PdvNerusDesktopLaunch;
  if ($field -eq 'ShortcutHash') { $script:hashes[$launch.ShortcutPath]=('f'*64); }
  elseif ($field -eq 'TargetHash') { $script:hashes[$launch.TargetPath]=('f'*64); }
  elseif ($field -eq 'TargetPath') { $script:shortcut.TargetPath='C:\Nerus\other.exe'; }
  else { $script:shortcut[$field]=[string]$script:shortcut[$field]+'changed'; }
  Assert-RestartError { Get-PdvNerusRestartBinding $launch } 'NerusRestartLaunchChanged';
  Assert-Restart ($script:closeCalls -eq 0 -and $script:startCalls -eq 0) 'Arquivo ou parametros alterados bloqueiam acao.';
}
foreach ($fault in @('missing','multiple','path','session','owner','window','start','pid','identityDenied','enumerationDenied')) {
  Reset-Restart; $launch=Get-PdvNerusDesktopLaunch; $expected='NerusRestartProcessAmbiguous';
  switch ($fault) {
    'missing' { $script:processes=@(); }
    'multiple' { $script:processes+=,$script:processes[0]; }
    'path' { $script:identity.TargetPath='C:\Other\nerus.exe'; $expected='NerusRestartExecutableMismatch'; }
    'session' { $script:identity.SessionId=3; $expected='NerusRestartOtherSession'; }
    'owner' { $script:identity.OwnerSid='S-1-other'; $expected='NerusRestartOtherSession'; }
    'window' { $script:identity.MainWindowHandle=0; $expected='NerusRestartWindowUnavailable'; }
    'start' { $script:identity.StartTimeTicks=0; $expected='NerusRestartWindowUnavailable'; }
    'pid' { $script:identity.ProcessId=0; $expected='NerusRestartWindowUnavailable'; }
    'identityDenied' { $script:identityDenied=$true; $expected='NerusRestartIdentityUnavailable'; }
    'enumerationDenied' { $script:enumerationDenied=$true; $expected='NerusRestartIdentityUnavailable'; }
  }
  Assert-RestartError { Get-PdvNerusRestartBinding $launch } $expected;
  Assert-Restart ($script:closeCalls -eq 0) 'Identidade nao comprovada nao fecha processo.';
}
foreach ($field in @('ProcessId','StartTimeTicks','SessionId','OwnerSid','MainWindowHandle')) {
  Reset-Restart; $launch=Get-PdvNerusDesktopLaunch; $binding=(Get-PdvNerusRestartBinding $launch).Clone();
  if ($field -eq 'OwnerSid') { $binding[$field]='other'; } else { $binding[$field]=([long]$binding[$field])+1; }
  Assert-RestartError { Close-PdvNerusBoundWindow $launch $binding } 'NerusRestartProcessChanged';
  Assert-Restart ($script:closeCalls -eq 0) 'PID reutilizado ou janela trocada nao recebe fechamento.';
}
Reset-Restart; $launch=Get-PdvNerusDesktopLaunch; $binding=Get-PdvNerusRestartBinding $launch; $script:closeAccepted=$false;
Assert-RestartError { Close-PdvNerusBoundWindow $launch $binding } 'NerusRestartCloseRefused';
Assert-Restart ($script:closeCalls -eq 1 -and $script:waitCalls -eq 0 -and $script:startCalls -eq 0) 'Recusa de fechamento nao forca nem reabre.';
Reset-Restart; $launch=Get-PdvNerusDesktopLaunch; $binding=Get-PdvNerusRestartBinding $launch; $script:exited=$false;
Assert-RestartError { Close-PdvNerusBoundWindow $launch $binding } 'NerusRestartCloseTimeout';
Assert-Restart ($script:startCalls -eq 0) 'Timeout nao declara saida e nao inicia outra instancia.';
foreach ($fault in @('existing','enumerationDenied','startDenied','unconfirmed','concurrent')) {
  Reset-Restart; $launch=Get-PdvNerusDesktopLaunch; $script:processes=@(); $expected='';
  switch ($fault) {
    'existing' { $script:processes=@((New-Object PSObject -Property @{Id=400;ProcessName='nerus'})); $expected='NerusRestartProcessAlreadyRunning'; }
    'enumerationDenied' { $script:enumerationDenied=$true; $expected='NerusRestartLaunchUnavailable'; }
    'startDenied' { $script:startDenied=$true; $expected='NerusRestartLaunchUnavailable'; }
    'unconfirmed' { $script:startUnconfirmed=$true; $expected='NerusRestartLaunchUnconfirmed'; }
    'concurrent' { $script:concurrentStart=$true; $expected='NerusRestartLaunchAmbiguous'; }
  }
  Assert-RestartError { Start-PdvNerusBoundLaunch $launch } $expected;
  Assert-Restart ($script:startCalls -le 1) 'Falha nao gera segunda abertura.';
  if (@('startDenied','unconfirmed','concurrent') -contains $fault) { Assert-RestartError { Start-PdvNerusBoundLaunch $launch } 'NerusRestartAlreadyStarted'; }
}
Reset-Restart; [void](Get-PdvNerusDesktopLaunch); Assert-Restart ($script:closeCalls -eq 0 -and $script:startCalls -eq 0) 'Descoberta para proposta ainda nao consentida nao fecha nem inicia Nerus.';
Write-Host ('PASS: '+$script:checks+' verificacoes de atalho Nerus, identidade exata, fechamento suave e reabertura unica com mocks. Nao valida Windows, WScript, venda ativa ou impressao real.');
