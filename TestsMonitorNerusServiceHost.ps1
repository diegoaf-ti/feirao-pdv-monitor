#requires -Version 5.1
# Testa o host por extração AST e runtime substituto em runspaces locais.
# Não abre WinForms, não enumera nem reinicia serviços reais.
$ErrorActionPreference = 'Stop';
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
$sourcePath = Join-Path $directory 'MonitorPdv.ps1';
$tokens=$null; $parseErrors=$null;
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors);
if (@($parseErrors).Count) { throw ($parseErrors | Out-String); }
$script:serviceChecks=0;
function Assert-ServiceHost($Condition,[string]$Description) { $script:serviceChecks++; if (-not $Condition) { throw $Description; } }
$functions=@('Get-PdvMonitorProcessNames','Test-PdvMonitorNerusServiceBusy','Get-PdvMonitorNerusServicePrompt','Start-PdvMonitorNerusServiceWorker','Complete-PdvMonitorNerusServiceWorker','Start-PdvMonitorTickWorker','Start-PdvMonitorNerusRestartWorker','Export-PdvMonitorFromWindow');
foreach ($name in $functions) {
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false);
  Assert-ServiceHost ($null -ne $definition) ('Host deve definir '+$name);
  . ([scriptblock]::Create($definition.Extent.Text));
}
$script:answer=$false; $script:prompts=0; $script:dialogs=0; $script:dialogAction=$null; $script:messages=@(); $script:controls=@();
$script:uiThread=[Threading.Thread]::CurrentThread.ManagedThreadId; $script:promptThreads=@();
function Set-PdvMonitorControls { param($Enabled); $script:controls += [bool]$Enabled; }
function Update-PdvMonitorView {}
function Show-PdvMonitorMessage { param($Message,$Title); $script:messages += [string]$Message; }
function Confirm-PdvMonitorNerusService {
  param($Proposal);
  $script:prompts++; $script:promptThreads += [Threading.Thread]::CurrentThread.ManagedThreadId;
  Assert-ServiceHost (Test-PdvMonitorNerusServiceBusy) 'Consentimento mantém exclusão enquanto modal processa eventos da UI';
  Start-PdvMonitorTickWorker; Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Export-PdvMonitorFromWindow;
  Assert-ServiceHost ($null -eq $script:worker -and $null -eq $script:nerusWorker) 'Timer e fluxo desktop não entram durante consentimento';
  [void](Get-PdvMonitorNerusServicePrompt -Proposal $Proposal);
  return $script:answer;
}
function Show-PdvMonitorNerusServiceDialog {
  $script:dialogs++;
  Assert-ServiceHost (Test-PdvMonitorNerusServiceBusy) 'Seleção de serviço mantém exclusão enquanto modal está aberto';
  Start-PdvMonitorTickWorker; Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Export-PdvMonitorFromWindow;
  Assert-ServiceHost ($null -eq $script:worker -and $null -eq $script:nerusWorker) 'Timer e fluxo desktop não entram durante seleção de serviço';
  return $script:dialogAction;
}
function Reset-ServiceHostSession {
  $script:closing=$false; $script:worker=$null; $script:workerResult=$null;
  $script:nerusWorker=$null; $script:nerusWorkerResult=$null; $script:nerusWorkerMode='';
  $script:serviceWorker=$null; $script:serviceWorkerResult=$null; $script:serviceWorkerMode='';
  $script:serviceProcessNames=@('caixaWeb','ClienteSiTef');
  $script:processBox=New-Object PSObject -Property @{Text='caixaWeb;ClienteSiTef'};
  $script:session=New-Object PSObject -Property @{
    Stopped=$false; TickBusy=$false; DiscoveryBehavior='normal'; ProbeBehavior='normal'; ApplyBehavior='normal';
    DiscoverCount=0; BindCount=0; ProbeCount=0; ApplyCount=0; TickCount=0;
    SavedServiceName=''; SavedBlockingNames=@(); AppliedProposalId='';
    NerusRestart=@{Busy=$false;Stage='Idle';Proposal=$null;Reason='';Result=''};
    NerusService=@{Busy=$false;Stage='Idle';Proposal=$null;Reason='';Result='';Discovery=$null;Binding=$null};
  };
}
function Wait-ServiceHostWorker {
  $deadline=[DateTimeOffset]::Now.AddSeconds(10);
  while ($null -ne $script:serviceWorker -and -not $script:serviceWorkerResult.IsCompleted -and [DateTimeOffset]::Now -lt $deadline) { Start-Sleep -Milliseconds 15; }
  Assert-ServiceHost ($null -ne $script:serviceWorker -and $script:serviceWorkerResult.IsCompleted) 'Worker do serviço deve terminar dentro do limite simulado';
}
$statusLabel=New-Object PSObject -Property @{Text=''};
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('pdv-service-host-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($testRoot);
$script:runtimePath=Join-Path $testRoot 'RuntimeMock.psm1';
$mock=@'
function Get-PdvMonitorNerusServiceDiscovery {
  param($Session);
  $Session.DiscoverCount++;
  if ($Session.DiscoveryBehavior -eq 'throw') { throw 'PRIVATE-SERVICE-PATH-ARGUMENTS'; }
  $Session.NerusService.Discovery=New-Object PSObject -Property @{Candidates=@((New-Object PSObject -Property @{ServiceName='NerusService';DisplayName='Nerus Service Fiscal';State='Running'}))};
  $Session.NerusService.Busy=$false;
  return $Session.NerusService.Discovery;
}
function Save-PdvMonitorNerusServiceBinding {
  param($Session,$ServiceName,$BlockingProcessNames);
  $Session.BindCount++; $Session.SavedServiceName=$ServiceName; $Session.SavedBlockingNames=@($BlockingProcessNames);
  $Session.NerusService.Binding=New-Object PSObject -Property @{ServiceName=$ServiceName;DisplayName='Nerus Service Fiscal'};
  $Session.NerusService.Busy=$false; $Session.NerusService.Result='Serviço vinculado no teste.';
  return $Session.NerusService.Binding;
}
function Invoke-PdvMonitorNerusServiceProbe {
  param($Session);
  $Session.ProbeCount++;
  if ($Session.ProbeBehavior -eq 'throw') { throw 'PRIVATE-SERVICE-PATH-ARGUMENTS'; }
  $Session.NerusService.Proposal=New-Object PSObject -Property @{
    Id='f772f509-cb48-4be2-a66e-345785fe349b';ServiceName='NerusService';DisplayName='Nerus Service Fiscal';
    ActualPort='COM9';ExpiresAt=[DateTimeOffset]::Now.AddMinutes(1);TefModuleObserved=$false;Secret='PRIVATE-DO-NOT-DISPLAY';
  };
  if ($Session.ProbeBehavior -eq 'expired') { $Session.NerusService.Proposal.ExpiresAt=[DateTimeOffset]::Now.AddSeconds(-1); }
  $Session.NerusService.Busy=$false;
}
function Invoke-PdvMonitorNerusServiceApply {
  param($Session,$ProposalId);
  $Session.ApplyCount++; $Session.AppliedProposalId=$ProposalId;
  if ($Session.ApplyBehavior -eq 'throw') { throw 'PRIVATE-SERVICE-PATH-ARGUMENTS'; }
  $Session.NerusService.Proposal=$null; $Session.NerusService.Busy=$false;
  $Session.NerusService.Result='Serviço reiniciado no teste; valide a impressão.';
}
function Invoke-PdvMonitorNerusRestartProbe { param($Session); throw 'Desktop não deve concorrer.'; }
function Invoke-PdvMonitorNerusRestartApply { param($Session,$ProposalId); throw 'Desktop não deve concorrer.'; }
function Invoke-PdvMonitorTick { param($Session); $Session.TickCount++; }
Export-ModuleMember -Function Get-PdvMonitorNerusServiceDiscovery,Save-PdvMonitorNerusServiceBinding,Invoke-PdvMonitorNerusServiceProbe,Invoke-PdvMonitorNerusServiceApply,Invoke-PdvMonitorNerusRestartProbe,Invoke-PdvMonitorNerusRestartApply,Invoke-PdvMonitorTick;
'@;
[IO.File]::WriteAllText($script:runtimePath,$mock,(New-Object Text.UTF8Encoding($true)));
try {
  Reset-ServiceHostSession;
  $script:session.NerusService.Busy=$true;
  Assert-ServiceHost (Test-PdvMonitorNerusServiceBusy) 'Busy persistido bloqueia interface mesmo sem runspace';
  Start-PdvMonitorTickWorker; Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Export-PdvMonitorFromWindow;
  Assert-ServiceHost ($null -eq $script:worker -and $null -eq $script:nerusWorker) 'Serviço ocupado impede coleta, fluxo desktop e exportação sem abrir interface nativa';
  $script:session.NerusService.Busy=$false;
  Assert-ServiceHost (-not (Test-PdvMonitorNerusServiceBusy)) 'Sessão livre não fica bloqueada';
  $script:session.NerusService=$null;
  Assert-ServiceHost (-not (Test-PdvMonitorNerusServiceBusy)) 'Guarda aceita sessão antiga sem estado do serviço';

  Reset-ServiceHostSession; $beforeDialogs=$script:dialogs; $script:dialogAction=$null;
  Start-PdvMonitorNerusServiceWorker -Mode 'Discover';
  Assert-ServiceHost ($null -ne $script:serviceWorker -and -not $script:controls[-1]) 'Descoberta usa runspace e desabilita controles';
  Wait-ServiceHostWorker;
  Assert-ServiceHost ($script:dialogs -eq $beforeDialogs -and (Test-PdvMonitorNerusServiceBusy)) 'Worker concluído aguarda UI sem abrir diálogo e continua exclusivo';
  Start-PdvMonitorTickWorker; Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Export-PdvMonitorFromWindow;
  Assert-ServiceHost ($null -eq $script:worker -and $null -eq $script:nerusWorker) 'Mesmo após computação, handle pendente mantém coleta e desktop bloqueados';
  Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($script:session.DiscoverCount -eq 1 -and $script:dialogs -eq ($beforeDialogs+1)) 'Descoberta só mostra candidatos depois do retorno à UI';
  Assert-ServiceHost ($script:session.BindCount -eq 0 -and $script:session.ApplyCount -eq 0 -and -not $script:session.NerusService.Busy -and $null -eq $script:serviceWorker) 'Fechar diálogo de descoberta não vincula nem recupera serviço';

  Reset-ServiceHostSession; $script:dialogAction=@{Mode='Bind';ServiceName='NerusService'};
  Start-PdvMonitorNerusServiceWorker -Mode 'Discover'; Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($null -ne $script:serviceWorker -and $script:serviceWorkerMode -eq 'Bind') 'Ação de vínculo do diálogo inicia runspace próprio';
  Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker; $script:dialogAction=$null;
  Assert-ServiceHost ($script:session.BindCount -eq 1 -and $script:session.SavedServiceName -eq 'NerusService' -and ($script:session.SavedBlockingNames -join ',') -eq 'caixaWeb,ClienteSiTef') 'Vínculo envia nome e bloqueadores como argumentos separados, preservando lista';
  Assert-ServiceHost ($script:session.ApplyCount -eq 0 -and $script:messages[-1] -match 'Nenhum serviço foi reiniciado') 'Salvar vínculo não representa autorização de recuperação';
  Reset-ServiceHostSession; $script:dialogAction=@{Mode='Check';ServiceName=''}; $script:answer=$false;
  Start-PdvMonitorNerusServiceWorker -Mode 'Discover'; Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($null -ne $script:serviceWorker -and $script:serviceWorkerMode -eq 'Check') 'Recuperação no diálogo inicia conferência, sem aplicar diretamente';
  Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker; $script:dialogAction=$null;
  Assert-ServiceHost ($script:session.ProbeCount -eq 1 -and $script:session.ApplyCount -eq 0) 'Recuperação pelo diálogo continua exigindo consentimento separado';
  Reset-ServiceHostSession; $literalServiceName='NerusService"; throw "PRIVATE-INJECTION';
  Start-PdvMonitorNerusServiceWorker -Mode 'Bind' -ServiceName $literalServiceName; Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($script:session.BindCount -eq 1 -and $script:session.SavedServiceName -ceq $literalServiceName) 'ServiceName é argumento literal e nunca vira código do runspace';
  Reset-ServiceHostSession; $processBox.Text='nerus.exe'; $beforeMessages=$script:messages.Count;
  Start-PdvMonitorNerusServiceWorker -Mode 'Bind' -ServiceName 'NerusService';
  Assert-ServiceHost ($null -eq $script:serviceWorker -and $script:session.BindCount -eq 0 -and $script:messages.Count -eq ($beforeMessages+1)) 'Nomes de bloqueadores inválidos impedem vínculo antes do runspace';

  Reset-ServiceHostSession; $script:answer=$false; $beforePrompts=$script:prompts;
  Start-PdvMonitorNerusServiceWorker -Mode 'Check'; Start-PdvMonitorTickWorker;
  Assert-ServiceHost ($null -eq $script:worker) 'Coleta não concorre com conferência do serviço';
  Wait-ServiceHostWorker;
  Assert-ServiceHost ($script:prompts -eq $beforePrompts) 'Conferência em segundo plano não pede consentimento';
  Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($script:prompts -eq ($beforePrompts+1) -and $script:session.ProbeCount -eq 1 -and $script:session.ApplyCount -eq 0) 'Não local faz somente conferência';
  Assert-ServiceHost ($null -eq $script:session.NerusService.Proposal -and -not $script:session.NerusService.Busy -and $script:session.NerusService.Reason -eq 'NerusServiceOperatorCancelled') 'Não descarta proposta e libera operação';
  Assert-ServiceHost ($script:promptThreads[-1] -eq $script:uiThread) 'Consentimento ocorre na thread da UI';
  Assert-ServiceHost ($script:messages[-1] -notmatch 'PRIVATE|f772f509') 'Resultado de cancelamento não vaza proposta ou identificador';

  Reset-ServiceHostSession; $script:answer=$true; $beforePrompts=$script:prompts;
  Start-PdvMonitorNerusServiceWorker -Mode 'Check'; Wait-ServiceHostWorker;
  Assert-ServiceHost ($script:prompts -eq $beforePrompts -and $script:session.ApplyCount -eq 0) 'Nenhuma recuperação antes da confirmação local';
  Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($null -ne $script:serviceWorker -and $script:serviceWorkerMode -eq 'Apply') 'Sim local inicia runspace independente de aplicação';
  Start-PdvMonitorTickWorker; Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Export-PdvMonitorFromWindow;
  Assert-ServiceHost ($null -eq $script:worker -and $null -eq $script:nerusWorker) 'Aplicação exclui coleta, desktop e exportação';
  Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker; Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($script:session.ApplyCount -eq 1 -and $script:session.AppliedProposalId -eq 'f772f509-cb48-4be2-a66e-345785fe349b') 'Aplicação recebe ID exato uma única vez';
  Assert-ServiceHost ($null -eq $script:serviceWorker -and -not $script:session.NerusService.Busy -and $script:controls[-1]) 'Conclusão libera runspace e controles';
  Assert-ServiceHost ($script:messages[-1] -eq 'Serviço reiniciado no teste; valide a impressão.') 'UI preserva resultado sem afirmar impressão confirmada';

  Reset-ServiceHostSession; $script:session.ProbeBehavior='expired'; $beforePrompts=$script:prompts;
  Start-PdvMonitorNerusServiceWorker -Mode 'Check'; Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
  Assert-ServiceHost ($script:prompts -eq $beforePrompts -and $script:session.ApplyCount -eq 0 -and $script:session.NerusService.Reason -eq 'NerusServiceProposalExpired') 'Proposta expirada não pede consentimento nem aplica';
  foreach ($failedMode in @('Discover','Check','Apply')) {
    Reset-ServiceHostSession; $script:answer=$true;
    if ($failedMode -eq 'Discover') { $script:session.DiscoveryBehavior='throw'; }
    elseif ($failedMode -eq 'Check') { $script:session.ProbeBehavior='throw'; }
    else {
      $script:session.ApplyBehavior='throw';
      Start-PdvMonitorNerusServiceWorker -Mode 'Check'; Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
    }
    if ($failedMode -ne 'Apply') { Start-PdvMonitorNerusServiceWorker -Mode $failedMode; }
    Wait-ServiceHostWorker; Complete-PdvMonitorNerusServiceWorker;
    Assert-ServiceHost ($null -eq $script:serviceWorker -and -not $script:session.NerusService.Busy -and $null -eq $script:session.NerusService.Proposal -and $script:session.NerusService.Reason -eq 'NerusServiceWorkerFailed') 'Falha libera worker, descarta proposta e registra razão fixa';
    Assert-ServiceHost ($script:messages[-1] -notmatch 'PRIVATE-SERVICE-PATH-ARGUMENTS' -and $script:messages[-1] -match 'não repetirá') 'Exceção não expõe segredos nem promete repetição automática';
  }

  foreach ($blocker in @('closing','tick','desktop','service','state')) {
    Reset-ServiceHostSession;
    if ($blocker -eq 'closing') { $script:closing=$true; }
    elseif ($blocker -eq 'tick') { $script:session.TickBusy=$true; }
    elseif ($blocker -eq 'desktop') { $script:session.NerusRestart.Busy=$true; }
    elseif ($blocker -eq 'service') { $script:serviceWorker=[Management.Automation.PowerShell]::Create(); }
    else { $script:session.NerusService.Busy=$true; }
    $existing=$script:serviceWorker;
    Start-PdvMonitorNerusServiceWorker -Mode 'Discover';
    Assert-ServiceHost ($script:session.DiscoverCount -eq 0 -and $script:serviceWorker -eq $existing) 'Operação concorrente ou encerramento bloqueia nova descoberta';
    if ($null -ne $existing) { $existing.Dispose(); $script:serviceWorker=$null; }
  }
  Reset-ServiceHostSession;
  Start-PdvMonitorNerusServiceWorker -Mode 'Unknown';
  Start-PdvMonitorNerusServiceWorker -Mode 'Apply' -ProposalId 'f772f509-cb48-4be2-a66e-345785fe349b';
  Assert-ServiceHost ($null -eq $script:serviceWorker -and $script:session.ApplyCount -eq 0) 'Modo desconhecido e aplicação sem proposta não criam worker';
  $script:session.NerusService.Proposal=New-Object PSObject -Property @{Id='f772f509-cb48-4be2-a66e-345785fe349b'};
  Start-PdvMonitorNerusServiceWorker -Mode 'Apply' -ProposalId 'outro-id';
  Assert-ServiceHost ($null -eq $script:serviceWorker) 'ID diferente não aplica proposta pendente';

  $proposal=New-Object PSObject -Property @{ServiceName='NerusService';DisplayName='Nerus Service Fiscal';ActualPort='COM9';Secret='PRIVATE-DO-NOT-DISPLAY';ExecutablePath='PRIVATE-PATH';Arguments='PRIVATE-ARGS';TefModuleObserved=$true};
  $prompt=Get-PdvMonitorNerusServicePrompt $proposal;
  Assert-ServiceHost ($prompt -match 'não há venda, pagamento ou impressão' -and $prompt -match 'NerusService' -and $prompt -match 'COM9' -and $prompt -match 'TEF' -and $prompt -match 'preservados' -and $prompt -notmatch 'PRIVATE') 'Prompt contém consentimento, impacto TEF e preservação da COM, expondo apenas campos permitidos';
  foreach ($field in @('ServiceName','DisplayName','ActualPort')) {
    $old=$proposal.$field; $proposal.$field="Nerus`nINJETADO"; $rejected=$false;
    try { [void](Get-PdvMonitorNerusServicePrompt $proposal); } catch { $rejected=$true; }
    Assert-ServiceHost $rejected 'Campos de proposta com quebra de linha não aparecem no consentimento';
    $proposal.$field=$old;
  }
  $confirm=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-PdvMonitorNerusService'},$false);
  Assert-ServiceHost ($confirm.Extent.Text -match "'YesNo'\s*,\s*'Warning'\s*,\s*'Button2'") 'Não é a resposta padrão do diálogo local';
  $workerDefinition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PdvMonitorNerusServiceWorker'},$false);
  Assert-ServiceHost ($workerDefinition.Extent.Text -notmatch 'MessageBox|Stop-Service|Start-Service|Restart-Service|CloseMainWindow|Stop-Process|taskkill|Get-PdvNerusDesktopLaunch') 'Host delega operação validada ao runtime sem ação nativa nem fechamento do navegador';
  $tickDefinition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-PdvMonitorTickWorker'},$false);
  Assert-ServiceHost ($tickDefinition.Extent.Text -match 'Test-PdvMonitorNerusServiceBusy' -and $tickDefinition.Extent.Text -match 'OperationsIdle \$idle') 'Aplicação de atualização recebe operação não ociosa enquanto serviço está ocupado';
} finally {
  foreach ($workerName in @('serviceWorker','worker','nerusWorker')) {
    $active=Get-Variable -Name $workerName -Scope Script -ValueOnly;
    if ($null -ne $active) { try { $active.Stop(); } catch {} $active.Dispose(); }
  }
  [IO.Directory]::Delete($testRoot,$true);
}
Write-Host ('PASS: '+$script:serviceChecks+' verificações do host Nerus Service com runtime simulado; não valida WinForms, serviços ou hardware Windows.');
