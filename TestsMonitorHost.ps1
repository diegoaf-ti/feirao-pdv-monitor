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
# A interface é isolada por funções substitutas; somente o runspace local real é usado.
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  if (@('Test-PdvMonitorNerusServiceBusy','Get-PdvMonitorNerusRestartPrompt','Start-PdvMonitorNerusRestartWorker','Complete-PdvMonitorNerusRestartWorker','Start-PdvMonitorTickWorker') -contains $definition.Name) { . ([scriptblock]::Create($definition.Extent.Text)); }
}
$script:Prompts = 0; $script:Answer = $false; $script:Messages = @(); $script:Controls = @();
function Confirm-PdvMonitorNerusRestart { param($Proposal); $script:Prompts++; [void](Get-PdvMonitorNerusRestartPrompt $Proposal); return $script:Answer; }
function Set-PdvMonitorControls { param($Enabled); $script:Controls += [bool]$Enabled; }
function Update-PdvMonitorView {}
function Show-PdvMonitorMessage { param($Message, $Title); $script:Messages += [string]$Message; }
function Wait-HostWorker {
  $deadline = [DateTimeOffset]::Now.AddSeconds(10);
  while ($null -ne $script:nerusWorker -and -not $script:nerusWorkerResult.IsCompleted -and [DateTimeOffset]::Now -lt $deadline) { Start-Sleep -Milliseconds 15; }
  Assert-Host ($null -ne $script:nerusWorker -and $script:nerusWorkerResult.IsCompleted) 'Worker assistido simulado deve terminar dentro do limite.';
}
function Reset-HostRestartSession {
  $script:closing = $false; $script:worker = $null; $script:workerResult = $null; $script:serviceWorker = $null;
  $script:nerusWorker = $null; $script:nerusWorkerResult = $null; $script:nerusWorkerMode = '';
  $script:session = New-Object PSObject -Property @{ TickBusy=$false; ProbeBehavior='normal'; ProbeCount=0; ApplyCount=0; TickCount=0; NerusRestart=@{Busy=$false;Stage='Idle';Proposal=$null;Reason='';Result=''}; };
}
$statusLabel = New-Object PSObject -Property @{ Text=''; };
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdv-host-restart-' + [guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($testRoot);
$script:runtimePath = Join-Path $testRoot 'RuntimeMock.psm1';
$mock = @'
function Invoke-PdvMonitorNerusRestartProbe {
  param($Session);
  $Session.ProbeCount++; if ($Session.ProbeBehavior -eq 'throw') { throw 'PRIVATE-PATH-AND-ARGUMENTS'; }
  $Session.NerusRestart.Proposal = New-Object PSObject -Property @{Id='mock-operation';ActualPort='COM9';BeforeValue=7;AfterValue=8;Terminal='CX4901';ExpiresAt=[DateTimeOffset]::Now.AddMinutes(1);Secret='PRIVATE-DO-NOT-DISPLAY';};
  if ($Session.ProbeBehavior -eq 'expired') { $Session.NerusRestart.Proposal.ExpiresAt=[DateTimeOffset]::Now.AddSeconds(-1); }
  $Session.NerusRestart.Busy=$false;
}
function Invoke-PdvMonitorNerusRestartApply {
  param($Session,$ProposalId);
  $Session.ApplyCount++; $Session.NerusRestart.Proposal=$null; $Session.NerusRestart.Busy=$false;
  $Session.NerusRestart.Result='Nerus reaberto no teste; valide a impressão.';
}
function Invoke-PdvMonitorTick { param($Session); $Session.TickCount++; }
Export-ModuleMember -Function Invoke-PdvMonitorNerusRestartProbe,Invoke-PdvMonitorNerusRestartApply,Invoke-PdvMonitorTick;
'@;
[IO.File]::WriteAllText($script:runtimePath, $mock, (New-Object Text.UTF8Encoding($true)));
try {
  Reset-HostRestartSession;
  Start-PdvMonitorNerusRestartWorker -Mode 'Check';
  Start-PdvMonitorTickWorker;
  Assert-Host ($null -eq $script:worker -and $null -ne $script:nerusWorker) 'Coleta normal não concorre com conferência assistida.';
  Wait-HostWorker; Complete-PdvMonitorNerusRestartWorker;
  Assert-Host ($script:Prompts -eq 1 -and $script:session.ProbeCount -eq 1 -and $script:session.ApplyCount -eq 0) 'Não local faz apenas conferência; não solicita aplicação.';
  Assert-Host (-not $script:session.NerusRestart.Busy -and $null -eq $script:session.NerusRestart.Proposal -and $script:session.NerusRestart.Reason -eq 'OperatorCancelled') 'Não descarta proposta e libera coleta.';
  Assert-Host ($script:Messages[-1] -notmatch 'PRIVATE|mock-operation') 'Resultado não expõe conteúdo sensível da proposta.';

  Reset-HostRestartSession; $script:Answer=$true;
  Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Wait-HostWorker;
  Assert-Host ($script:Prompts -eq 1) 'Worker de conferência não abre confirmação; ela aguarda a UI.';
  Complete-PdvMonitorNerusRestartWorker;
  Assert-Host ($null -ne $script:nerusWorker -and $script:nerusWorkerMode -eq 'Apply') 'Sim local inicia runspace separado de aplicação.';
  Start-PdvMonitorTickWorker;
  Assert-Host ($null -eq $script:worker) 'Coleta continua suspensa durante aplicação.';
  Wait-HostWorker; Complete-PdvMonitorNerusRestartWorker;
  Assert-Host ($script:session.ApplyCount -eq 1 -and $null -eq $script:nerusWorker -and -not $script:session.NerusRestart.Busy) 'Aplicação termina, libera runspace e não repete a operação.';
  Assert-Host ($script:Messages[-1] -eq 'Nerus reaberto no teste; valide a impressão.') 'UI exibe resultado amigável sem inventar sucesso de impressão.';

  Reset-HostRestartSession; $script:session.ProbeBehavior='expired'; $beforePrompts=$script:Prompts;
  Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Wait-HostWorker; Complete-PdvMonitorNerusRestartWorker;
  Assert-Host ($script:Prompts -eq $beforePrompts -and $script:session.ApplyCount -eq 0 -and $script:session.NerusRestart.Reason -eq 'ProposalExpired') 'Proposta vencida não abre consentimento nem fecha o Nerus.';
  Reset-HostRestartSession; $script:session.ProbeBehavior='throw';
  Start-PdvMonitorNerusRestartWorker -Mode 'Check'; Wait-HostWorker; Complete-PdvMonitorNerusRestartWorker;
  Assert-Host (-not $script:session.NerusRestart.Busy -and $null -eq $script:nerusWorker -and $script:session.NerusRestart.Reason -eq 'WorkerFailed') 'Exceção libera runspace e mantém a tentativa bloqueada.';
  Assert-Host ($script:Messages[-1] -notmatch 'PRIVATE-PATH-AND-ARGUMENTS') 'Exceção do worker não vaza caminho ou argumentos para a UI.';

  $proposal = New-Object PSObject -Property @{Terminal='CX4901';ActualPort='COM9';BeforeValue=7;AfterValue=8;Secret='PRIVATE-DO-NOT-DISPLAY'};
  $prompt = Get-PdvMonitorNerusRestartPrompt $proposal;
  Assert-Host ($prompt -match 'não há venda nem pagamento' -and $prompt -match 'CX4901' -and $prompt -match 'COM9' -and $prompt -notmatch 'PRIVATE') 'Texto de consentimento é explícito e permite apenas campos da operação.';
  $proposal.Terminal='CX4901`nINJECT'; $rejected=$false;
  try { [void](Get-PdvMonitorNerusRestartPrompt $proposal); } catch { $rejected=$true; }
  Assert-Host $rejected 'Campos inesperados não são exibidos no consentimento.';
  $confirmDefinition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-PdvMonitorNerusRestart'},$false);
  Assert-Host ($confirmDefinition.Extent.Text -match "'YesNo', 'Warning', 'Button2'") 'Diálogo local tem Não como resposta padrão.';
  $workerDefinition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-PdvMonitorNerusRestartWorker'},$false);
  Assert-Host ($workerDefinition.Extent.Text -notmatch 'MessageBox' -and $workerDefinition.Extent.Text -notmatch 'CloseMainWindow') 'Worker do host não mostra diálogo nem fecha processo por conta própria.';
} finally {
  if ($null -ne $script:nerusWorker) { try { $script:nerusWorker.Stop(); } catch {} $script:nerusWorker.Dispose(); }
  [IO.Directory]::Delete($testRoot,$true);
}
# Os comandos públicos do runtime delegam ao módulo Nerus, sem recursão nem
# chamada nativa; somente os coordenadores são substituídos nesta verificação.
Import-Module (Join-Path $directory 'PdvMonitor.Runtime.psm1') -Force;
$runtimeModule = Get-Module PdvMonitor.Runtime;
$nerusModule = & $runtimeModule { $script:nerusModule; };
$probeOriginal = & $nerusModule { (Get-Command Invoke-PdvMonitorNerusRestartProbe).ScriptBlock; };
$applyOriginal = & $nerusModule { (Get-Command Invoke-PdvMonitorNerusRestartApply).ScriptBlock; };
try {
  & $nerusModule {
    function script:Invoke-PdvMonitorNerusRestartProbe { param($Session); $Session.HostProbeCalls++; }
    function script:Invoke-PdvMonitorNerusRestartApply { param($Session,$ProposalId); $Session.HostApplyId=$ProposalId; }
  };
  $shared = New-Object PSObject -Property @{Stopped=$false;TickBusy=$false;NerusRestart=@{Busy=$true};HostProbeCalls=0;HostApplyId='';};
  Invoke-PdvMonitorNerusRestartProbe -Session $shared;
  Invoke-PdvMonitorNerusRestartApply -Session $shared -ProposalId 'test-delegation';
  Assert-Host ($shared.HostProbeCalls -eq 1 -and $shared.HostApplyId -eq 'test-delegation') 'Runtime reexporta os coordenadores e preserva sessão e ID recebidos por argumento.';
  Invoke-PdvMonitorTick -Session $shared;
  Assert-Host (-not $shared.TickBusy) 'Runtime ocupado com tentativa assistida não entra na coleta nem no atualizador.';
} finally {
  & $nerusModule { param($OriginalProbe,$OriginalApply); Set-Item Function:script:Invoke-PdvMonitorNerusRestartProbe -Value $OriginalProbe; Set-Item Function:script:Invoke-PdvMonitorNerusRestartApply -Value $OriginalApply; } $probeOriginal $applyOriginal;
}
Write-Host 'PASS: sintaxe do host, validação de nomes de processos, mutex, estado compartilhado, confirmação local e exclusão entre coleta e tentativa assistida. Não valida interface, inicialização automática ou hardware Windows.';
