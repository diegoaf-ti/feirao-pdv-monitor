#requires -Version 5.1
# Apenas AST, mutex aleatorio de teste e objetos falsos. Nao executa instalacao,
# WinForms, WScript, coleta, rede ou encerramento de processos.
$ErrorActionPreference='Stop';
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;
$checks=0;
function Assert-Install($Value,[string]$Message){if(-not $Value){throw $Message;};$script:checks++;}
function Assert-InstallRejected([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null;}catch{$rejected=$true;};Assert-Install $rejected $Message;}
$tokens=$null;$errors=$null;
$installerPath=Join-Path $root 'InstalarMonitor.ps1';
$ast=[Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$tokens,[ref]$errors);
Assert-Install (@($errors).Count -eq 0) 'Instalador possui sintaxe valida';
$names=@('Get-PdvMonitorInstallMutexName','New-PdvMonitorInstallMutex','Get-PdvMonitorInstallFiles','Test-PdvMonitorInstallShortcut');
foreach($definition in $ast.FindAll({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst];},$false)){
  if($names -ccontains $definition.Name){. ([scriptblock]::Create($definition.Extent.Text));}
}
$hostAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'MonitorPdv.ps1'),[ref]$tokens,[ref]$errors);
foreach($definition in $hostAst.FindAll({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst];},$false)){
  if($definition.Name -ceq 'Get-PdvMonitorMutexName'){. ([scriptblock]::Create($definition.Extent.Text));}
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('pdv-install-'+[guid]::NewGuid().ToString('N'));
$identity='S-1-5-21-fixture';
$name=Get-PdvMonitorInstallMutexName $identity $directory;
Assert-Install ($name -ceq (Get-PdvMonitorMutexName $identity $directory)) 'Instalador reserva o mesmo mutex utilizado pelo host';
Assert-Install ($name -ceq (Get-PdvMonitorInstallMutexName $identity ($directory+[IO.Path]::DirectorySeparatorChar))) 'Barra final nao contorna exclusao';
Assert-Install ($name -cne (Get-PdvMonitorInstallMutexName 'outra-identidade' $directory)) 'Mutex pertence ao usuario de instalacao';
Assert-Install ($name -cne (Get-PdvMonitorInstallMutexName $identity ($directory+'-outra'))) 'Mutex pertence a pasta de dados';
$guard=$null;$reopened=$null;
try{
  $guard=New-PdvMonitorInstallMutex $name;
  Assert-Install ($null -ne $guard -and -not $guard.SafeWaitHandle.IsClosed) 'Instalacao reserva exclusao enquanto copia';
  Assert-InstallRejected {New-PdvMonitorInstallMutex $name;} 'Host ou outro instalador aberto bloqueia nova instalacao';
  Assert-Install (-not $guard.SafeWaitHandle.IsClosed) 'Recusa nao fecha o handle original de outro participante';
  $guard.ReleaseMutex();$guard.Dispose();$guard=$null;
  $reopened=New-PdvMonitorInstallMutex $name;
  Assert-Install ($null -ne $reopened) 'Depois do encerramento normal, a instalacao pode reservar novamente';
}finally{
  foreach($mutex in @($guard,$reopened)){if($null -ne $mutex){try{$mutex.ReleaseMutex();}finally{$mutex.Dispose();}}}
}
$files=@(Get-PdvMonitorInstallFiles);
Assert-Install ($files.Count -eq 22 -and @($files | Select-Object -Unique).Count -eq 22) 'Instalador exige todos os 22 arquivos do core sem repeticao';
Assert-Install ($files -ccontains 'PdvMonitor.Remoto.psm1' -and $files -ccontains 'PdvMonitor.Remoto.Transporte.psm1') 'Broker e transporte nao ficam fora da instalacao';
Assert-Install ($files -cnotcontains 'PdvMonitor.Remoto.Windows.psm1' -and $files -cnotcontains 'RemoteWindowsNative.cs' -and $files -cnotcontains 'remoto-piloto.xml') 'Extensao administrativa e segredos nao integram core gravavel';
foreach($file in $files){Assert-Install ([IO.File]::Exists((Join-Path $root $file))) ('Arquivo obrigatorio existe: '+$file);}
$arguments='-File "bootstrap conhecido.ps1"';$target='C:\Windows\powershell.exe';$legacy='"legado conhecido.vbs"';$legacyTarget='C:\Windows\wscript.exe';
$current=New-Object PSObject -Property @{Arguments=$arguments;TargetPath=$target;};
Assert-Install (Test-PdvMonitorInstallShortcut $current $arguments $target $legacy $legacyTarget) 'Atalho conhecido pode ser atualizado';
$current.TargetPath=$target.ToLowerInvariant();
Assert-Install (Test-PdvMonitorInstallShortcut $current $arguments $target $legacy $legacyTarget) 'Destino Windows pode variar somente caixa';
$current.Arguments+=' -Command outra-coisa';
Assert-Install (-not (Test-PdvMonitorInstallShortcut $current $arguments $target $legacy $legacyTarget)) 'Argumentos acrescentados impedem substituir atalho';
$current.Arguments=$arguments;$current.TargetPath='C:\Outro\programa.exe';
Assert-Install (-not (Test-PdvMonitorInstallShortcut $current $arguments $target $legacy $legacyTarget)) 'Atalho de outro programa e preservado';
$current.Arguments=$legacy;$current.TargetPath=$legacyTarget;
Assert-Install (Test-PdvMonitorInstallShortcut $current $arguments $target $legacy $legacyTarget) 'Atalho legado exato pode migrar para bootstrap';
$source=[IO.File]::ReadAllText($installerPath);
$guardPosition=$source.IndexOf('$guard=New-PdvMonitorInstallMutex ');
$copyPosition=$source.IndexOf('Copy-Item -LiteralPath');
Assert-Install ($guardPosition -gt 0 -and $copyPosition -gt $guardPosition) 'Nenhum arquivo e copiado antes da exclusao do host';
Assert-Install ($source.IndexOf('Test-PdvMonitorInstallShortcut $existing') -lt $copyPosition) 'Conflitos de atalhos sao conferidos antes da copia';
Assert-Install ($source.IndexOf("'Monitor do PDV.lnk'") -gt 0 -and $source.IndexOf("'Feirao-PdvMonitor.lnk'") -gt 0) 'Desktop e inicio automatico apontam ao bootstrap estavel';
$commands=@($ast.FindAll({param($node);$node -is [Management.Automation.Language.CommandAst];},$true) | ForEach-Object {$_.GetCommandName();});
Assert-Install (@($commands | Where-Object {@('Stop-Process','taskkill','taskkill.exe','Restart-Computer') -icontains $_;}).Count -eq 0) 'Instalador nunca encerra monitor, PDV ou Windows a forca';
$uninstallPath=Join-Path $root 'DesinstalarMonitor.ps1';
$uninstallAst=[Management.Automation.Language.Parser]::ParseFile($uninstallPath,[ref]$tokens,[ref]$errors);
Assert-Install (@($errors).Count -eq 0) 'Desinstalador possui sintaxe valida';
foreach($definition in $uninstallAst.FindAll({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst];},$false)){
  if(@('Test-PdvMonitorUninstallShortcut','Get-PdvMonitorUninstallTargets') -ccontains $definition.Name){. ([scriptblock]::Create($definition.Extent.Text));}
}
$targets=@(Get-PdvMonitorUninstallTargets (Join-Path $directory 'startup') (Join-Path $directory 'desktop'));
Assert-Install ($targets.Count -eq 2 -and [IO.Path]::GetFileName($targets[0].Path) -ceq 'Feirao-PdvMonitor.lnk' -and $targets[0].AllowLegacy) 'Desinstalador considera somente o alias de inicio automatico conhecido';
Assert-Install ([IO.Path]::GetFileName($targets[1].Path) -ceq 'Monitor do PDV.lnk' -and -not $targets[1].AllowLegacy) 'Desktop usa apenas o novo alias e exige bootstrap atual';
Assert-Install (@(Get-PdvMonitorUninstallTargets '' (Join-Path $directory 'desktop')).Count -eq 1) 'Desktop pode ser tratado sem inventar pasta Startup';
$current.Arguments=$arguments;$current.TargetPath=$target;
Assert-Install (Test-PdvMonitorUninstallShortcut $current $arguments $target) 'AtalhoDesktop do proprio bootstrap pode ser removido';
$current.Arguments+=' -Command outro';
Assert-Install (-not (Test-PdvMonitorUninstallShortcut $current $arguments $target)) 'Argumentos diferentes preservam o atalhoDesktop';
$current.Arguments=$arguments;$current.TargetPath='C:\Outro\programa.exe';
Assert-Install (-not (Test-PdvMonitorUninstallShortcut $current $arguments $target)) 'Destino diferente preserva o atalhoDesktop';
$current.Arguments=$legacy;$current.TargetPath=$legacyTarget;
Assert-Install (-not (Test-PdvMonitorUninstallShortcut $current $arguments $target $false $legacy $legacyTarget)) 'AtalhoDesktop legado nao e presumido como criado pelo core0.7';
Assert-Install (Test-PdvMonitorUninstallShortcut $current $arguments $target $true $legacy $legacyTarget) 'Startup legado exato permanece removivel';
$removeCommands=@($uninstallAst.FindAll({param($node);$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Remove-Item';},$true));
Assert-Install ($removeCommands.Count -eq 1 -and $removeCommands[0].Extent.Text -ceq 'Remove-Item -LiteralPath $entry.Path') 'Desinstalador remove somente atalhos enumerados, sem recursao ou pasta de dados';
$uninstallCommands=@($uninstallAst.FindAll({param($node);$node -is [Management.Automation.Language.CommandAst];},$true) | ForEach-Object {$_.GetCommandName();});
Assert-Install (@($uninstallCommands | Where-Object {@('Stop-Process','taskkill','taskkill.exe','Restart-Computer') -icontains $_;}).Count -eq 0) 'Desinstalador preserva processos abertos';
Write-Output ('PASS: '+$checks+' verificacoes do core22, mutex de instalacao, exclusao do host e preservacao de atalhos; nenhuma instalacao real.');
