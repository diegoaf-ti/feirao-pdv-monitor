#requires -Version 5.1
# Exclusao local sem WinForms/Windows/HTTP/processos reais.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;$checks=0;
function Assert-RemoteHost($Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message;}}
function Assert-RemoteHostThrows([scriptblock]$Body,[string]$Expected){$script:checks++;try{& $Body|Out-Null;}catch{if($_.Exception.Message -ceq $Expected){return;};throw ('Erro inesperado '+$_.Exception.Message);};throw ('Faltou erro '+$Expected);}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'MonitorPdv.ps1'),[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Host parse';}
foreach($definition in $ast.FindAll({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
 if(@('Start-PdvMonitorNerusRestartWorker','Start-PdvMonitorNerusServiceWorker','Get-PdvMonitorRemoteStatusText') -contains $definition.Name){. ([scriptblock]::Create($definition.Extent.Text));}
}
function Test-PdvMonitorNerusServiceBusy {return $false;}
$script:closing=$false;$script:worker=$null;$script:nerusWorker=$null;$script:serviceWorker=$null;
$script:session=New-Object PSObject -Property @{RemoteBusy=$true;TickBusy=$false;NerusRestart=@{Busy=$false};};
Start-PdvMonitorNerusRestartWorker -Mode 'Check';Start-PdvMonitorNerusServiceWorker -Mode 'Discover';
Assert-RemoteHost ($null -eq $script:nerusWorker -and $null -eq $script:serviceWorker) 'Host iniciou recovery durante suporte.';
Import-Module (Join-Path $directory 'PdvMonitor.Runtime.psm1') -Force;$runtime=Get-Module PdvMonitor.Runtime;
& $runtime {param($Session);Invoke-PdvMonitorNerusRestartProbe $Session;Invoke-PdvMonitorNerusRestartApply $Session 'untrusted';} $script:session;
Assert-RemoteHostThrows {Invoke-PdvMonitorNerusServiceProbe $script:session;} 'RemoteSupportBusy';
Assert-RemoteHostThrows {Invoke-PdvMonitorNerusServiceApply $script:session 'untrusted';} 'RemoteSupportBusy';
Assert-RemoteHostThrows {Set-PdvMonitorMaintenance $script:session -Minutes 15;} 'Encerre o suporte remoto antes de armar uma recuperação.';
$nerus=& $runtime {$script:nerusModule;};
Assert-RemoteHostThrows {& $nerus {param($Session);Get-PdvNerusRestartPolicy $Session;} $script:session;} 'NerusRestartNotReady';
Assert-RemoteHostThrows {& $nerus {param($Session);Test-PdvNerusServiceSession $Session;} $script:session;} 'NerusServiceNotReady';
Import-Module (Join-Path $directory 'PdvMonitor.Atualizacao.psm1') -Force;
$result=Start-PdvMonitorUpdateApply $script:session $directory $true $true;
Assert-RemoteHost ($result.Reason -ceq 'UpdateWaitingMonitorIdle' -and -not $result.Started) 'Atualizador iniciou durante suporte.';
# Consistencia do lock CLR entre runspaces: ninguem restaura TLS enquanto outra requisicao usa.
$lock=[Net.ServicePointManager];[Threading.Monitor]::Enter($lock);$worker=[Management.Automation.PowerShell]::Create();
try{
 [void]$worker.AddScript('$target=[Net.ServicePointManager];$owned=[Threading.Monitor]::TryEnter($target,50);if($owned){[Threading.Monitor]::Exit($target)};return $owned');$pending=$worker.BeginInvoke();$items=@($worker.EndInvoke($pending));
 Assert-RemoteHost ($items.Count -eq 1 -and -not [bool]$items[0]) 'Lock TLS nao e compartilhado entre runspaces.';
}finally{$worker.Dispose();[Threading.Monitor]::Exit($lock);}
$transport=[IO.File]::ReadAllText((Join-Path $directory 'PdvMonitor.Atualizacao.psm1'));
$match=[regex]::Match($transport,'PdvUpdateProgramFiles = @\(([^\r\n]*)\)');$names=@([regex]::Matches($match.Groups[1].Value,"'([^']+)'"));
Assert-RemoteHost ($names.Count -eq 22 -and $match.Value -match 'PdvMonitor.Remoto.psm1' -and $match.Value -match 'PdvMonitor.Remoto.Transporte.psm1' -and $match.Value -notmatch 'Remoto.Windows|RemoteWindowsNative|remoto-piloto') 'Core deve incluir broker/transporte; extensao administrativa permanece fora da atualizacao do usuario.';
foreach($file in @('PdvMonitor.Remoto.Transporte.psm1','MonitorPdv.ps1','PdvMonitor.Runtime.psm1','PdvMonitor.Transporte.psm1','PdvMonitor.Nerus.psm1','PdvMonitor.Atualizacao.psm1')){
 $bytes=[IO.File]::ReadAllBytes((Join-Path $directory $file));$text=[Text.Encoding]::UTF8.GetString($bytes);
 Assert-RemoteHost ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $text -notmatch '(?<!\r)\n') ('Codificacao CRLF+BOM '+$file);
}
foreach($case in @(
 @{Controller=$null;Expected='aguardando preparação'},
 @{Controller=@{Enabled=$false;Reason='RemoteExtensionNotInstalled'};Expected='instalação da extensão administrativa'},
 @{Controller=@{Enabled=$false;Reason='RemoteDisabled'};Expected='desativado'},
 @{Controller=@{Enabled=$false;Reason='RemotePrerequisitesMissing'};Expected='pré-requisitos'},
 @{Controller=@{Enabled=$false;Reason='RemoteExtensionUntrusted'};Expected='permissões da extensão'},
 @{Controller=@{Enabled=$false;Reason='RemoteCentralConfigurationRequired'};Expected='vínculo válido'},
 @{Controller=@{Enabled=$false;Reason='PRIVATE-SECRET';Secret='PRIVATE-URL-TOKEN'};Expected='preparação pendente'},
 @{Controller=@{Enabled=$true;Reason='';Paused=$false;Broker=$null};Expected='cada acesso exige confirmação'},
 @{Controller=@{Enabled=$true;Reason='';Paused=$true;Broker=$null};Expected='pedidos suspensos'},
 @{Controller=@{Enabled=$true;Reason='';Paused=$false;Broker=@{Stage='requested'}};Expected='aguardando confirmação'},
 @{Controller=@{Enabled=$true;Reason='';Paused=$false;Broker=@{Stage='close_required'}};Expected='confirmando a parada'}
)){
 $status=Get-PdvMonitorRemoteStatusText $case.Controller;
 Assert-RemoteHost ($status -like ('*'+$case.Expected+'*') -and $status -notmatch 'PRIVATE') 'Status remoto ausente, incorreto ou expos segredo.';
}
$source=[IO.File]::ReadAllText((Join-Path $directory 'MonitorPdv.ps1'));
Assert-RemoteHost ($source -match 'dataLabel.Text \+= \[Environment\]::NewLine \+ \(Get-PdvMonitorRemoteStatusText' -and $source -notmatch 'installedPath = &') 'Estado remoto precisa ser visivel; instalar nao pode copiar arquivos dentro do Host ativo.';
Write-Output ('PASS: '+$checks+' verificacoes host/exclusao/TLS/allowlist; sem Windows ou HTTP reais.');
