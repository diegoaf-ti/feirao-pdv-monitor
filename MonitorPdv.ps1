#requires -Version 2.0
[CmdletBinding()]
param([switch]$StartHidden, [string]$DataDirectory = '')

$ErrorActionPreference = 'Stop';
$script:programDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path;
$script:runtimePath = Join-Path $script:programDirectory 'PdvMonitor.Runtime.psm1';
Add-Type -AssemblyName System.Windows.Forms;
Add-Type -AssemblyName System.Drawing;
[System.Windows.Forms.Application]::EnableVisualStyles();
Import-Module $script:runtimePath -Force;
Import-Module (Join-Path $script:programDirectory 'PdvMonitor.Atualizacao.psm1');

function Show-PdvMonitorMessage {
  param([string]$Message, [string]$Title = 'Monitor do PDV');
  [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Information');
}

function Get-PdvMonitorMutexName {
  param([string]$UserIdentity, [string]$Directory);
  $algorithm = [System.Security.Cryptography.SHA256]::Create();
  try {
    $canonical = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar).ToUpperInvariant();
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($UserIdentity + '|' + $canonical);
    $hash = [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '');
    return 'Local\Feirao.PdvMonitor.' + $hash;
  } finally { $algorithm.Dispose(); }
}

function Get-PdvMonitorProcessNames {
  param([string]$Text);
  $names = @();
  foreach ($part in @($Text -split '[;,\r\n]+')) {
    $name = $part.Trim();
    if (-not $name) { continue; }
    if ($name -match '[\\/:*?"<>|]' -or $name -match '\.exe$') {
      throw 'Informe somente os nomes exatos dos processos, sem .exe ou caminho. Separe os nomes por ponto e vírgula.';
    }
    if ($names -notcontains $name) { $names += $name; }
  }
  return $names;
}

function Add-PdvMonitorRow {
  param($View, [string[]]$Values, $Tag);
  $item = New-Object System.Windows.Forms.ListViewItem($Values[0]);
  for ($index = 1; $index -lt $Values.Count; $index++) { [void]$item.SubItems.Add([string]$Values[$index]); }
  $item.Tag = $Tag; [void]$View.Items.Add($item);
  return $item;
}

function New-PdvMonitorList {
  param([string[]]$Columns, [int[]]$Widths);
  $list = New-Object System.Windows.Forms.ListView;
  $list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true;
  $list.MultiSelect = $false; $list.HideSelection = $false; $list.GridLines = $true;
  for ($index = 0; $index -lt $Columns.Count; $index++) { [void]$list.Columns.Add($Columns[$index], $Widths[$index]); }
  return $list;
}

function Update-PdvMonitorView {
  $selectedId = '';
  if ($deviceList.SelectedItems.Count -eq 1) { $selectedId = $deviceList.SelectedItems[0].Tag.InstanceId; }
  $deviceList.BeginUpdate(); $deviceList.Items.Clear();
  foreach ($device in @($script:session.Snapshot.Devices)) {
    if ($null -eq $device) { continue; }
    $presence = 'Não confirmada';
    if ($device.PresenceKnown) {
      if ($device.Present) { $presence = 'Presente'; } else { $presence = 'Ausente'; }
    }
    $row = Add-PdvMonitorRow $deviceList @([string]$device.Name, [string]$device.Port, $presence, [string]$device.Status, [string]$device.ProblemCode, [string]$device.InstanceId) $device;
    if ($device.InstanceId -eq $selectedId) { $row.Selected = $true; }
  }
  $deviceList.EndUpdate();
  $profileList.Items.Clear();
  foreach ($profile in @($script:session.Config.Profiles)) {
    if ($null -eq $profile) { continue; }
    $actualPort = ''; $state = 'Não enumerado';
    foreach ($device in @($script:session.Snapshot.Devices)) {
      if ($null -eq $device -or $device.InstanceId -ne $profile.InstanceId) { continue; }
      $actualPort = [string]$device.Port;
      $problemCode = 0;
      $problemKnown = [int]::TryParse([string]$device.ProblemCode, [ref]$problemCode);
      if (-not $device.PresenceKnown) { $state = 'Presença não confirmada'; }
      elseif (-not $device.Present) { $state = 'Ausente'; }
      elseif (-not $problemKnown) { $state = 'Código Windows não confirmado'; }
      elseif ($problemCode -ne 0) { $state = 'Problema no Windows'; }
      elseif ($profile.ExpectedPort -and $actualPort -ne $profile.ExpectedPort) { $state = 'Porta divergente'; }
      else { $state = 'Conforme no Windows'; }
      break;
    }
    $recovery = 'Desativada'; if ($profile.RecoveryEnabled) { $recovery = 'Permitida em manutenção'; }
    [void](Add-PdvMonitorRow $profileList @([string]$profile.Role, [string]$profile.ExpectedPort, $actualPort, $state, $recovery, [string]$profile.InstanceId) $profile);
  }
  $statusLabel.Text = [string]$script:session.StatusText;
  if ($script:session.LastTickAt) { $statusLabel.Text += ' | Coleta: ' + [string]$script:session.LastTickAt; }
  $warnings = @($script:session.Snapshot.Warnings | Where-Object { $_ });
  if ($script:wmiWarning) { $warnings += $script:wmiWarning; }
  if (@($script:session.Config.Profiles).Count -eq 0) { $warnings += 'Para receber alertas de COM: selecione o pinpad e a impressora corretos, confirme a COM esperada e use Salvar vínculo. O inventário da máquina funciona sem vínculos.'; }
  $warningLabel.Text = $warnings -join ' | ';
  if (-not $warningLabel.Text) { $warningLabel.Text = 'Presença no Windows não comprova comunicação com o Nérus. O monitor não abre a porta COM nem lê dados de pagamentos.'; }
  $dataLabel.Text = 'Logs e configuração: ' + $script:dataDirectory + [Environment]::NewLine + 'Envio central: ' + [string]$script:session.UploadStatusText + ' | ' + [string]$script:session.HardwareStatus + ' | Versão ' + $script:session.MonitorVersion + ' | ' + $script:session.UpdateStatus;
}

function Test-PdvMonitorNerusServiceBusy {
  if ($null -ne $script:serviceWorker) { return $true; }
  if ($null -eq $script:session -or $null -eq $script:session.PSObject.Properties['NerusService'] -or $null -eq $script:session.NerusService) { return $false; }
  return [bool]$script:session.NerusService.Busy;
}

function Set-PdvMonitorControls {
  param([bool]$Enabled);
  foreach ($control in @($refreshButton, $nerusRestartButton, $nerusServiceButton, $bindButton, $removeButton, $roleBox, $portBox, $recoveryBox, $processBox, $armButton, $disarmButton, $exportButton, $installButton, $centralButton)) {
    $control.Enabled = $Enabled;
  }
  $script:exportMenu.Enabled = $Enabled;
  $restartBusy = (($null -ne $script:session -and $null -ne $script:session.NerusRestart -and $script:session.NerusRestart.Busy) -or (Test-PdvMonitorNerusServiceBusy));
  $exitButton.Enabled = -not $restartBusy;
  $exitMenu.Enabled = -not $restartBusy;
}


function Show-PdvMonitorCentralConfiguration {
  $dialog = New-Object System.Windows.Forms.Form;
  $dialog.Text = 'Envio para a central de diagnóstico'; $dialog.Size = New-Object System.Drawing.Size(670, 360);
  $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog';
  $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false;
  $dialog.Font = $form.Font;
  $grid = New-Object System.Windows.Forms.TableLayoutPanel;
  $grid.Dock = 'Fill'; $grid.ColumnCount = 2; $grid.RowCount = 7; $grid.Padding = New-Object System.Windows.Forms.Padding(12);
  [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 115)));
  [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)));
  foreach ($height in @(40, 40, 40, 40, 40, 52, 40)) { [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $height))); }
  $dialog.Controls.Add($grid);
  $fields = @{};
  $definitions = @(
    @('Endpoint HTTPS', 'Endpoint'), @('Loja', 'StoreId'), @('Caixa', 'Terminal'), @('ID da instalação', 'AgentId'), @('Token da instalação', 'Token')
  );
  for ($index = 0; $index -lt $definitions.Count; $index++) {
    $label = New-Object System.Windows.Forms.Label; $label.Text = $definitions[$index][0]; $label.Dock = 'Fill';
    $field = New-Object System.Windows.Forms.TextBox; $field.Dock = 'Fill';
    $key = $definitions[$index][1];
    if ($key -eq 'Token') { $field.UseSystemPasswordChar = $true; }
    elseif ($null -ne $script:session.Config.Central) { $field.Text = [string]$script:session.Config.Central.$key; }
    $fields[$key] = $field; $grid.Controls.Add($label, 0, $index); $grid.Controls.Add($field, 1, $index);
  }
  $note = New-Object System.Windows.Forms.Label; $note.Dock = 'Fill';
  $note.Text = 'Use o endereço HTTPS fornecido pelo suporte. O token é protegido para este usuário do Windows e não é incluído na exportação. Ao salvar, informe o token da instalação.';
  $grid.Controls.Add($note, 0, 5); $grid.SetColumnSpan($note, 2);
  $buttons = New-Object System.Windows.Forms.FlowLayoutPanel; $buttons.Dock = 'Fill';
  $save = New-Object System.Windows.Forms.Button; $save.Text = 'Salvar';
  $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancelar'; $cancel.DialogResult = 'Cancel';
  $buttons.Controls.AddRange([System.Windows.Forms.Control[]]@($save, $cancel));
  $grid.Controls.Add($buttons, 1, 6); $dialog.CancelButton = $cancel;
  $save.add_Click({
    try {
      Set-PdvMonitorCentral -Session $script:session -Endpoint $fields['Endpoint'].Text.Trim() -StoreId $fields['StoreId'].Text.Trim() -Terminal $fields['Terminal'].Text.Trim() -AgentId $fields['AgentId'].Text.Trim() -Token $fields['Token'].Text;
      $fields['Token'].Text = '';
      $dialog.DialogResult = 'OK'; $dialog.Close();
    } catch { Show-PdvMonitorMessage $_.Exception.Message 'Envio central não configurado'; }
  });
  try {
    if ($dialog.ShowDialog($form) -eq 'OK') { Update-PdvMonitorView; }
  } finally { $fields['Token'].Text = ''; $dialog.Dispose(); }
}

function Receive-PdvMonitorDeviceSignals {
  if (-not $script:wmiSubscribed) { return; }
  foreach ($event in @(Get-Event -SourceIdentifier $script:wmiSource -ErrorAction SilentlyContinue)) {
    try {
      $eventType = [int]$event.SourceEventArgs.NewEvent.EventType;
      if ($eventType -eq 2 -or $eventType -eq 3) {
        $signal = New-Object PSObject -Property @{
          Time = $event.TimeGenerated.ToString('o'); Kind = 'WindowsDeviceChange'; EventType = $eventType;
          Message = 'Windows notificou chegada ou remoção de dispositivo; a notificação não identifica o equipamento.';
        };
        if ($script:session.Signals.Count -lt 1000) { $script:session.Signals.Enqueue($signal); }
        else {
          if ($null -eq $script:session.PSObject.Properties['SignalDropCount']) {
            $script:session | Add-Member -MemberType NoteProperty -Name SignalDropCount -Value 0;
          }
          $script:session.SignalDropCount++;
          $script:wmiWarning = 'A fila de notificações imediatas atingiu o limite; sinais descartados: ' + $script:session.SignalDropCount + '. A coleta periódica continua, com esta lacuna de cobertura.';
        }
      }
    } finally { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue; }
  }
}

function Start-PdvMonitorTickWorker {
  if ($null -ne $script:worker -or $null -ne $script:nerusWorker -or $script:closing -or $script:session.NerusRestart.Busy -or (Test-PdvMonitorNerusServiceBusy)) { return; }
  Set-PdvMonitorControls $false;
  $statusLabel.Text = 'Consultando dispositivos e gravando o diagnóstico...';
  $script:worker = [System.Management.Automation.PowerShell]::Create();
  [void]$script:worker.AddScript('param($runtimePath, $session) $ErrorActionPreference = "Stop"; Import-Module $runtimePath -Force; [void](Invoke-PdvMonitorTick -Session $session)');
  [void]$script:worker.AddArgument($script:runtimePath);
  [void]$script:worker.AddArgument($script:session);
  try { $script:workerResult = $script:worker.BeginInvoke(); }
  catch {
    $script:worker.Dispose(); $script:worker = $null;
    Set-PdvMonitorControls $true;
    $statusLabel.Text = 'Não foi possível iniciar a coleta: ' + $_.Exception.Message;
    $script:nextTickAt = (Get-Date).AddSeconds(15);
  }
}

function Complete-PdvMonitorTickWorker {
  if ($null -eq $script:worker -or -not $script:workerResult.IsCompleted) { return; }
  $failure = '';
  try {
    [void]$script:worker.EndInvoke($script:workerResult);
    if ($script:worker.Streams.Error.Count) { $failure = [string]$script:worker.Streams.Error[0]; }
  } catch { $failure = $_.Exception.Message; }
  finally { $script:worker.Dispose(); $script:worker = $null; $script:workerResult = $null; }
  Update-PdvMonitorView;
  if ($failure) { $statusLabel.Text = 'Falha na coleta; nova tentativa em 15 segundos: ' + $failure; }
  $script:nextTickAt = (Get-Date).AddSeconds(15);
  Set-PdvMonitorControls (-not $script:closing);
  if (-not $script:closing -and -not $failure -and $script:session.UpdateStaged -and $script:session.AutoUpdateEnabled) {
    $idle=(-not $script:session.MaintenanceArmed -and ($null -eq $script:session.NerusAutomation -or $null -eq $script:session.NerusAutomation.Pending));
    if ($null -ne $script:session.PSObject.Properties['NerusRestart'] -and $null -ne $script:session.NerusRestart -and $script:session.NerusRestart.Busy) { $idle=$false; }
    if (Test-PdvMonitorNerusServiceBusy) { $idle=$false; }
    $apply=Start-PdvMonitorUpdateApply -Session $script:session -ProgramDirectory $script:programDirectory -Enabled $script:session.AutoUpdateEnabled -OperationsIdle $idle;
    $script:session.UpdateStatus=$apply.Reason;
    if ($apply.Started) { $script:closing=$true; }
  }
  if ($script:closing) { $form.Close(); }
}

function Get-PdvMonitorNerusRestartPrompt {
  param($Proposal);
  $terminal = [string]$Proposal.Terminal; $port = [string]$Proposal.ActualPort;
  $before = [string]$Proposal.BeforeValue; $after = [string]$Proposal.AfterValue;
  if ($terminal -notmatch '^[A-Za-z0-9_-]{1,8}$' -or $port -notmatch '^COM[1-9][0-9]{0,3}$' -or $before -notmatch '^[0-9]{1,4}$' -or $after -notmatch '^[0-9]{1,4}$') { throw 'InvalidRestartProposal'; }
  return ('Caixa: ' + $terminal + '. Impressora identificada no Windows em ' + $port + '. Parâmetro do Nerus: ' + $before + ' → ' + $after + ".`r`n`r`nAntes de continuar, finalize ou cancele qualquer venda e pagamento, e aguarde terminar as impressões. O monitor não identifica uma venda ativa.`r`n`r`nAo escolher Sim, você confirma que não há venda nem pagamento em andamento e autoriza fechar o Nerus normalmente, corrigir a porta e reabri-lo pelo atalho Nerus da Área de Trabalho. Se o Nerus pedir alguma confirmação, responda no próprio Nerus; o monitor não responderá por você.`r`n`r`nA impressão precisará ser testada depois. Deseja fazer esta tentativa agora?");
}

function Confirm-PdvMonitorNerusRestart {
  param($Proposal);
  $message = Get-PdvMonitorNerusRestartPrompt -Proposal $Proposal;
  return ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Corrigir e reabrir Nerus', 'YesNo', 'Warning', 'Button2') -eq 'Yes');
}

function Start-PdvMonitorNerusRestartWorker {
  param([string]$Mode = 'Check', [string]$ProposalId = '');
  if ($Mode -ne 'Check' -and $Mode -ne 'Apply') { return; }
  if ($script:closing -or $null -ne $script:worker -or $null -ne $script:nerusWorker -or $script:session.TickBusy -or (Test-PdvMonitorNerusServiceBusy)) { return; }
  $state = $script:session.NerusRestart;
  if ($Mode -eq 'Check' -and $state.Busy) { return; }
  if ($Mode -eq 'Apply' -and ($null -eq $state.Proposal -or [string]$state.Proposal.Id -cne $ProposalId)) { return; }
  $state.Busy = $true; $state.Result = ''; $state.Reason = '';
  if ($Mode -eq 'Check') { $state.Stage = 'Checking'; $state.Proposal = $null; $statusLabel.Text = 'Conferindo a impressora, a porta do Nerus e o atalho da Área de Trabalho...'; }
  else { $state.Stage = 'Applying'; $statusLabel.Text = 'Tentativa autorizada: aguardando o Nerus fechar e reabrir. Não inicie venda ou pagamento...'; }
  Set-PdvMonitorControls $false;
  $script:nerusWorkerMode = $Mode;
  try {
    $script:nerusWorker = [System.Management.Automation.PowerShell]::Create();
    [void]$script:nerusWorker.AddScript('param($runtimePath, $session, $mode, $proposalId) $ErrorActionPreference = "Stop"; Import-Module $runtimePath -Force; if ($mode -eq "Check") { [void](Invoke-PdvMonitorNerusRestartProbe -Session $session); } else { [void](Invoke-PdvMonitorNerusRestartApply -Session $session -ProposalId $proposalId); }');
    [void]$script:nerusWorker.AddArgument($script:runtimePath);
    [void]$script:nerusWorker.AddArgument($script:session);
    [void]$script:nerusWorker.AddArgument($Mode);
    [void]$script:nerusWorker.AddArgument($ProposalId);
    $script:nerusWorkerResult = $script:nerusWorker.BeginInvoke();
  } catch {
    if ($null -ne $script:nerusWorker) { $script:nerusWorker.Dispose(); }
    $script:nerusWorker = $null; $script:nerusWorkerResult = $null; $script:nerusWorkerMode = '';
    $state.Busy = $false; $state.Stage = 'Failed'; $state.Proposal = $null; $state.Reason = 'WorkerStartFailed';
    $state.Result = 'Não foi possível iniciar a tentativa. Confira se o Nerus está aberto antes de retomar o atendimento e consulte o suporte.';
    Set-PdvMonitorControls $true; Update-PdvMonitorView;
    Show-PdvMonitorMessage $state.Result 'Tentativa de correção do Nerus';
  }
}

function Complete-PdvMonitorNerusRestartWorker {
  if ($null -eq $script:nerusWorker -or -not $script:nerusWorkerResult.IsCompleted) { return; }
  $failed = $false; $mode = $script:nerusWorkerMode;
  try {
    [void]$script:nerusWorker.EndInvoke($script:nerusWorkerResult);
    if ($script:nerusWorker.Streams.Error.Count) { $failed = $true; }
  } catch { $failed = $true; }
  finally {
    $script:nerusWorker.Dispose(); $script:nerusWorker = $null;
    $script:nerusWorkerResult = $null; $script:nerusWorkerMode = '';
  }
  $state = $script:session.NerusRestart;
  if ($failed) {
    $state.Busy = $false; $state.Stage = 'Failed'; $state.Proposal = $null; $state.Reason = 'WorkerFailed';
    $state.Result = 'A tentativa foi interrompida. Confira se o Nerus está aberto antes de retomar o atendimento e consulte o suporte. O monitor não confirmou que a impressão voltou a funcionar.';
  } elseif ($mode -eq 'Check' -and $null -ne $state.Proposal -and -not $script:closing) {
    $proposal = $state.Proposal;
    if ($proposal.ExpiresAt -gt [DateTimeOffset]::Now) {
      $state.Stage = 'AwaitingConfirmation'; $state.Busy = $true;
      try { $confirmed = Confirm-PdvMonitorNerusRestart -Proposal $proposal; }
      catch { $confirmed = $false; $state.Reason = 'InvalidRestartProposal'; }
      if ($confirmed) {
        Start-PdvMonitorNerusRestartWorker -Mode 'Apply' -ProposalId ([string]$proposal.Id);
        return;
      }
      $state.Proposal = $null; $state.Busy = $false; $state.Stage = 'Idle';
      if (-not $state.Reason) { $state.Reason = 'OperatorCancelled'; }
      $state.Result = 'Tentativa cancelada. Nenhum pedido para fechar o Nerus ou alterar a porta foi enviado.';
    } else {
      $state.Proposal = $null; $state.Busy = $false; $state.Stage = 'Blocked'; $state.Reason = 'ProposalExpired';
      $state.Result = 'A conferência expirou. Solicite uma nova tentativa; nenhum pedido para fechar o Nerus ou alterar a porta foi enviado.';
    }
  }
  $state.Busy = $false;
  $script:nextTickAt = Get-Date;
  Set-PdvMonitorControls (-not $script:closing); Update-PdvMonitorView;
  $message = [string]$state.Result;
  if (-not $message) { $message = 'A tentativa terminou sem confirmação de correção. Confira o Nerus e teste a impressora antes de retomar o atendimento.'; }
  Show-PdvMonitorMessage $message 'Tentativa de correção do Nerus';
  if ($script:closing) { $form.Close(); }
}

function Get-PdvMonitorNerusServicePrompt {
  param($Proposal);
  $name=[string]$Proposal.ServiceName; $display=[string]$Proposal.DisplayName; $port=[string]$Proposal.ActualPort;
  if ($name -notmatch '^[^\x00-\x1f\x7f-\x9f]{1,256}$' -or $display -notmatch '^[^\x00-\x1f\x7f-\x9f]{1,256}$' -or $port -notmatch '^COM[1-9][0-9]{0,3}$') { throw 'InvalidServiceProposal'; }
  return ('Serviço: '+$display+' ('+$name+'). Impressora vinculada em '+$port+".`r`n`r`nFinalize ou cancele qualquer venda e pagamento e aguarde terminar as impressões. O monitor não identifica uma venda ativa.`r`n`r`nAo escolher Sim, você confirma que não há venda, pagamento ou impressão em andamento e autoriza uma tentativa de parar e iniciar somente este serviço. Todas as integrações atendidas por ele, inclusive o TEF se estiver no mesmo componente, ficarão temporariamente indisponíveis.`r`n`r`nA COM e o parâmetro do Nerus serão preservados. Não inicie atendimento durante a tentativa. Depois será necessário conferir a conexão no Nerus e testar a impressão.`r`n`r`nDeseja executar a tentativa agora?");
}

function Confirm-PdvMonitorNerusService {
  param($Proposal);
  $message=Get-PdvMonitorNerusServicePrompt $Proposal;
  return ([System.Windows.Forms.MessageBox]::Show($form,$message,'Recuperar comunicação do Nerus Service','YesNo','Warning','Button2') -eq 'Yes');
}

function Show-PdvMonitorNerusServiceDialog {
  $dialog=New-Object System.Windows.Forms.Form;
  $dialog.Text='Nerus Service | Caixa Web'; $dialog.Size=New-Object System.Drawing.Size(950,520);
  $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font; $dialog.MinimizeBox=$false;
  $grid=New-Object System.Windows.Forms.TableLayoutPanel; $grid.Dock='Fill'; $grid.Padding=New-Object System.Windows.Forms.Padding(12); $grid.ColumnCount=1; $grid.RowCount=5;
  foreach ($height in @(84,44,0,66,42)) { $row=New-Object System.Windows.Forms.RowStyle; if($height){$row.SizeType='Absolute';$row.Height=$height;}else{$row.SizeType='Percent';$row.Height=100;};[void]$grid.RowStyles.Add($row); }
  $dialog.Controls.Add($grid);
  $intro=New-Object System.Windows.Forms.Label; $intro.Dock='Fill';
  $intro.Text="Selecione o serviço do Caixa Web e use Vincular para registrar sua identidade. O vínculo não reinicia o serviço.`r`nA recuperação exige impressora vinculada na COM esperada e confirmação de venda e pagamento encerrados. O monitor pode precisar ser aberto como administrador.`r`nA lista abaixo distingue serviço do Windows de aplicativo de bandeja; o UUID do Nerus é diferente da identidade Windows usada pelo monitor.";
  $grid.Controls.Add($intro,0,0);
  $bindingLabel=New-Object System.Windows.Forms.Label; $bindingLabel.Dock='Fill'; $bindingLabel.Text='Nenhum serviço vinculado.';
  if($null -ne $script:session.NerusService.Binding){$bindingLabel.Text='Vinculado: '+$script:session.NerusService.Binding.DisplayName+' ('+$script:session.NerusService.Binding.ServiceName+').';}
  $grid.Controls.Add($bindingLabel,0,1);
  $list=New-PdvMonitorList @('Nome no Windows','Descrição','Estado','Recuperação','Processo','Executável') @(150,160,85,100,65,330);
  foreach($candidate in @($script:session.NerusService.Discovery.Candidates)) {
    if($null -eq $candidate){continue;}; $eligibility='Bloqueada';if($candidate.Eligible){$eligibility='Pode conferir';}
    [void](Add-PdvMonitorRow $list @([string]$candidate.ServiceName,[string]$candidate.DisplayName,[string]$candidate.State,$eligibility,[string]$candidate.ProcessId,[string]$candidate.ExecutablePath) $candidate);
  }
  $grid.Controls.Add($list,0,2);
  $note=New-Object System.Windows.Forms.Label; $note.Dock='Fill';
  $note.Text='Serviços compartilhados, dependentes ativos, processos auxiliares ou identificação incompleta impedem a tentativa. Os processos bloqueadores da tela principal são salvos ao vincular. A COM divergente precisa ser resolvida antes.';
  if(-not $list.Items.Count){$note.Text='Nenhum serviço do Windows elegível foi localizado. Se houver apenas o aplicativo Nerus na bandeja, o diagnóstico será registrado; o monitor não força seu encerramento. Use Exportar diagnóstico para o suporte.';}
  $grid.Controls.Add($note,0,3);
  $buttons=New-Object System.Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill';
  $bind=New-Object System.Windows.Forms.Button; $bind.Text='Vincular selecionado';$bind.AutoSize=$true;$bind.Enabled=$false;
  $recover=New-Object System.Windows.Forms.Button; $recover.Text='Tentar recuperar comunicação...';$recover.AutoSize=$true;$recover.Enabled=($null -ne $script:session.NerusService.Binding);
  $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Fechar';$cancel.DialogResult='Cancel';$cancel.AutoSize=$true;
  $buttons.Controls.AddRange([System.Windows.Forms.Control[]]@($bind,$recover,$cancel));$grid.Controls.Add($buttons,0,4);$dialog.CancelButton=$cancel;
  $list.add_SelectedIndexChanged({$bind.Enabled=($list.SelectedItems.Count -eq 1);});
  $bind.add_Click({if($list.SelectedItems.Count -ne 1){return;};$dialog.Tag=@{Mode='Bind';ServiceName=[string]$list.SelectedItems[0].Tag.ServiceName;};$dialog.DialogResult='OK';$dialog.Close();});
  $recover.add_Click({$dialog.Tag=@{Mode='Check';ServiceName='';};$dialog.DialogResult='OK';$dialog.Close();});
  try { if($dialog.ShowDialog($form) -eq 'OK'){return $dialog.Tag;} }
  finally {$dialog.Dispose();}
  return $null;
}

function Start-PdvMonitorNerusServiceWorker {
  param([string]$Mode='Discover',[string]$ProposalId='',[string]$ServiceName='');
  if(@('Discover','Bind','Check','Apply') -notcontains $Mode){return;}
  if($script:closing -or $null -ne $script:worker -or $null -ne $script:nerusWorker -or $null -ne $script:serviceWorker -or $script:session.TickBusy -or $script:session.NerusRestart.Busy){return;}
  $state=$script:session.NerusService;
  if($Mode -ne 'Apply' -and $state.Busy){return;}
  if($Mode -eq 'Apply' -and ($null -eq $state.Proposal -or [string]$state.Proposal.Id -cne $ProposalId)){return;}
  $names=@();
  if($Mode -eq 'Bind'){
    try{$names=@(Get-PdvMonitorProcessNames $processBox.Text);}
    catch{Show-PdvMonitorMessage 'Confira os nomes dos processos na tela principal antes de vincular o serviço.';return;}
  }
  $state.Busy=$true;$state.Result='';$state.Reason='';$state.Stage=$Mode;
  $statusLabel.Text='Conferindo o Nerus Service; aguarde antes de iniciar atendimento...';
  if($Mode -eq 'Apply'){$statusLabel.Text='Recuperação autorizada: aguardando parada e nova execução do Nerus Service. Não inicie venda ou pagamento...';}
  Set-PdvMonitorControls $false;$script:serviceWorkerMode=$Mode;
  try{
    $script:serviceWorker=[System.Management.Automation.PowerShell]::Create();
    [void]$script:serviceWorker.AddScript('param($runtimePath,$session,$mode,$proposalId,$serviceName,$processNames) $ErrorActionPreference="Stop"; Import-Module $runtimePath -Force; switch($mode){ "Discover"{$session.NerusService.Discovery=Get-PdvMonitorNerusServiceDiscovery -Session $session;} "Bind"{[void](Save-PdvMonitorNerusServiceBinding -Session $session -ServiceName $serviceName -BlockingProcessNames $processNames);} "Check"{[void](Invoke-PdvMonitorNerusServiceProbe -Session $session);} "Apply"{[void](Invoke-PdvMonitorNerusServiceApply -Session $session -ProposalId $proposalId);} }');
    foreach($argument in @($script:runtimePath,$script:session,$Mode,$ProposalId,$ServiceName)) {[void]$script:serviceWorker.AddArgument($argument);}
    [void]$script:serviceWorker.AddArgument($names);
    $script:serviceWorkerResult=$script:serviceWorker.BeginInvoke();
  }catch{
    if($null -ne $script:serviceWorker){$script:serviceWorker.Dispose();};$script:serviceWorker=$null;$script:serviceWorkerResult=$null;$script:serviceWorkerMode='';
    $state.Busy=$false;$state.Stage='Failed';$state.Proposal=$null;$state.Reason='NerusServiceWorkerStartFailed';
    $state.Result='Não foi possível iniciar a conferência do serviço. Nenhuma nova tentativa será executada automaticamente; consulte o diagnóstico antes de retomar o caixa.';
    Set-PdvMonitorControls $true;Show-PdvMonitorMessage $state.Result 'Nerus Service';
  }
}

function Complete-PdvMonitorNerusServiceWorker {
  if($null -eq $script:serviceWorker -or -not $script:serviceWorkerResult.IsCompleted){return;}
  $failed=$false;$mode=$script:serviceWorkerMode;
  try{[void]$script:serviceWorker.EndInvoke($script:serviceWorkerResult);if($script:serviceWorker.Streams.Error.Count){$failed=$true;}}
  catch{$failed=$true;}
  finally{$script:serviceWorker.Dispose();$script:serviceWorker=$null;$script:serviceWorkerResult=$null;$script:serviceWorkerMode='';}
  $state=$script:session.NerusService;$state.Busy=$false;
  if($failed){
    $state.Stage='Failed';$state.Proposal=$null;$state.Reason='NerusServiceWorkerFailed';
    $state.Result='A operação do Nerus Service foi interrompida. Confira se o serviço está em execução e consulte o diagnóstico antes de retomar venda ou pagamento. O monitor não confirmou a impressão e não repetirá a ação sozinho.';
  }elseif($mode -eq 'Discover' -and -not $script:closing){
    $state.Busy=$true;
    try{$action=Show-PdvMonitorNerusServiceDialog;}finally{$state.Busy=$false;}
    if($null -ne $action){Start-PdvMonitorNerusServiceWorker -Mode ([string]$action.Mode) -ServiceName ([string]$action.ServiceName);if($null -ne $script:serviceWorker){return;}}
  }elseif($mode -eq 'Check' -and $null -ne $state.Proposal -and -not $script:closing){
    $proposal=$state.Proposal;
    if($proposal.ExpiresAt -gt [DateTimeOffset]::Now){
      $state.Busy=$true;$state.Stage='AwaitingConfirmation';$confirmed=$false;
      try{$confirmed=Confirm-PdvMonitorNerusService $proposal;}catch{$state.Reason='NerusServiceInvalidProposal';}
      if($confirmed){Start-PdvMonitorNerusServiceWorker -Mode 'Apply' -ProposalId ([string]$proposal.Id);return;}
      $state.Busy=$false;$state.Proposal=$null;$state.Stage='Idle';$state.Reason='NerusServiceOperatorCancelled';$state.Result='Tentativa cancelada. Nenhum pedido de parada ou início foi enviado ao serviço.';
    }else{$state.Proposal=$null;$state.Stage='Blocked';$state.Reason='NerusServiceProposalExpired';$state.Result='A conferência expirou. Solicite outra tentativa; nenhum pedido de parada foi enviado.';}
  }
  $state.Busy=$false;$script:nextTickAt=Get-Date;Set-PdvMonitorControls (-not $script:closing);Update-PdvMonitorView;
  if($mode -eq 'Bind' -and -not $failed){Show-PdvMonitorMessage 'Vínculo salvo. Nenhum serviço foi reiniciado. Abra Nerus Service novamente para conferir e autorizar uma tentativa.' 'Nerus Service';}
  elseif($mode -ne 'Discover' -or $failed){$message=[string]$state.Result;if(-not $message){$message='Tentativa encerrada. Consulte o diagnóstico do serviço e valide a impressão no Nerus antes de retomar o atendimento.';};Show-PdvMonitorMessage $message 'Nerus Service';}
  if($script:closing){$form.Close();}
}

function Export-PdvMonitorFromWindow {
  if ($null -ne $script:worker -or $null -ne $script:nerusWorker -or $script:session.NerusRestart.Busy -or (Test-PdvMonitorNerusServiceBusy)) { return; }
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog;
  $dialog.Description = 'Escolha uma pasta para receber uma cópia dos logs e do diagnóstico do monitor.';
  try {
    if ($dialog.ShowDialog() -ne 'OK') { return; }
    $destination = Export-PdvMonitorLogs -Session $script:session -DestinationDirectory $dialog.SelectedPath;
    Show-PdvMonitorMessage ('Diagnóstico exportado para:' + [Environment]::NewLine + [string]$destination);
  } catch { Show-PdvMonitorMessage $_.Exception.Message 'Falha ao exportar'; }
  finally { $dialog.Dispose(); }
}

if (-not $DataDirectory) { $DataDirectory = Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor'; }
$script:dataDirectory = [System.IO.Path]::GetFullPath($DataDirectory);
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
$mutexName = Get-PdvMonitorMutexName -UserIdentity $userSid -Directory $script:dataDirectory;
$createdNew = $false;
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew);
if (-not $createdNew) {
  Show-PdvMonitorMessage 'O monitor já está em execução para este usuário e esta pasta de dados. Abra-o pelo ícone ao lado do relógio do Windows.';
  $mutex.Dispose(); exit 0;
}

$script:session = $null; $script:worker = $null; $script:workerResult = $null;
$script:nerusWorker = $null; $script:nerusWorkerResult = $null; $script:nerusWorkerMode = '';
$script:serviceWorker = $null; $script:serviceWorkerResult = $null; $script:serviceWorkerMode = '';
$script:closing = $false; $script:nextTickAt = Get-Date;
$tray = $null; $timer = $null; $form = $null;
$script:wmiSource = 'Feirao.PdvMonitor.DeviceChange.' + [guid]::NewGuid().ToString('N');
$script:wmiSubscribed = $false; $script:wmiWarning = '';
try {
  $script:session = Start-PdvMonitorSession -DataDirectory $script:dataDirectory -ProgramDirectory $script:programDirectory;
  try {
    Register-WmiEvent -Class Win32_DeviceChangeEvent -SourceIdentifier $script:wmiSource -ErrorAction Stop | Out-Null;
    $script:wmiSubscribed = $true;
  } catch { $script:wmiWarning = 'Notificações imediatas do Windows indisponíveis; a coleta periódica continua. ' + $_.Exception.Message; }
  $form = New-Object System.Windows.Forms.Form;
  $form.Text = 'Feirão | Monitor do PDV ' + $script:session.MonitorVersion;
  $form.Size = New-Object System.Drawing.Size(1120, 790);
  $form.MinimumSize = New-Object System.Drawing.Size(940, 730);
  $form.StartPosition = 'CenterScreen'; $form.Font = New-Object System.Drawing.Font('Segoe UI', 9);
  $layout = New-Object System.Windows.Forms.TableLayoutPanel;
  $layout.Dock = 'Fill'; $layout.Padding = New-Object System.Windows.Forms.Padding(12);
  $layout.ColumnCount = 1; $layout.RowCount = 11;
  foreach ($height in @(48, 40, 0, 100, 40, 34, 40, 40, 42, 40, 36)) {
    $style = New-Object System.Windows.Forms.RowStyle;
    if ($height -eq 0) { $style.SizeType = 'Percent'; $style.Height = 100; }
    else { $style.SizeType = 'Absolute'; $style.Height = $height; }
    [void]$layout.RowStyles.Add($style);
  }
  $form.Controls.Add($layout);
  $intro = New-Object System.Windows.Forms.Label; $intro.Dock = 'Fill';
  $intro.Text = "COM e falhas graves: três leituras a cada 15 segundos. Inventário da máquina: início e a cada 6 horas. Fechar mantém o monitor na bandeja.`r`nA recuperação de dispositivos exige perfil autorizado, manutenção temporária e processos do caixa fechados.";
  $layout.Controls.Add($intro, 0, 0);
  $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Fill';
  $refreshButton = New-Object System.Windows.Forms.Button; $refreshButton.Text = 'Coletar agora'; $refreshButton.AutoSize = $true;
  $exportButton = New-Object System.Windows.Forms.Button; $exportButton.Text = 'Exportar diagnóstico...'; $exportButton.AutoSize = $true;
  $folderButton = New-Object System.Windows.Forms.Button; $folderButton.Text = 'Abrir pasta dos logs'; $folderButton.AutoSize = $true;
  $centralButton = New-Object System.Windows.Forms.Button; $centralButton.Text = 'Configurar envio central...'; $centralButton.AutoSize = $true;
  $toolbar.Controls.AddRange([System.Windows.Forms.Control[]]@($refreshButton, $exportButton, $folderButton, $centralButton));
  $layout.Controls.Add($toolbar, 0, 1);
  $deviceList = New-PdvMonitorList @('Dispositivo', 'COM', 'Presença', 'Status', 'Código', 'Identificador da instância') @(260, 65, 125, 90, 55, 420);
  $layout.Controls.Add($deviceList, 0, 2);
  $profileList = New-PdvMonitorList @('Perfil', 'Esperada', 'Atual', 'Situação', 'Recuperação', 'Identificador') @(150, 75, 65, 170, 170, 360);
  $layout.Controls.Add($profileList, 0, 3);
  $bindingBar = New-Object System.Windows.Forms.FlowLayoutPanel; $bindingBar.Dock = 'Fill';
  $roleBox = New-Object System.Windows.Forms.ComboBox; $roleBox.DropDownStyle = 'DropDownList'; $roleBox.Width = 150;
  [void]$roleBox.Items.AddRange([object[]]@('Pinpad TEF', 'Impressora Bematech')); $roleBox.SelectedIndex = 0;
  $portLabel = New-Object System.Windows.Forms.Label; $portLabel.Text = 'COM esperada:'; $portLabel.AutoSize = $true; $portLabel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0);
  $portBox = New-Object System.Windows.Forms.TextBox; $portBox.Width = 65;
  $recoveryBox = New-Object System.Windows.Forms.CheckBox; $recoveryBox.Text = 'Permitir recuperação deste dispositivo'; $recoveryBox.AutoSize = $true; $recoveryBox.Margin = New-Object System.Windows.Forms.Padding(5, 6, 8, 0);
  $bindButton = New-Object System.Windows.Forms.Button; $bindButton.Text = 'Salvar vínculo'; $bindButton.AutoSize = $true;
  $removeButton = New-Object System.Windows.Forms.Button; $removeButton.Text = 'Remover perfil'; $removeButton.AutoSize = $true;
  $bindingBar.Controls.AddRange([System.Windows.Forms.Control[]]@($roleBox, $portLabel, $portBox, $recoveryBox, $bindButton, $removeButton));
  $layout.Controls.Add($bindingBar, 0, 4);
  $processLabel = New-Object System.Windows.Forms.Label; $processLabel.Dock = 'Fill';
  $processLabel.Text = 'Para recuperar: informe os nomes exatos de todos os processos do PDV e TEF, sem .exe, separados por ; (confira na aba Detalhes do Gerenciador de Tarefas).';
  $layout.Controls.Add($processLabel, 0, 5);
  $processBox = New-Object System.Windows.Forms.TextBox; $processBox.Dock = 'Fill';
  $processBox.Text = @($script:session.Config.BlockingProcessNames) -join '; ';
  $layout.Controls.Add($processBox, 0, 6);
  $maintenanceBar = New-Object System.Windows.Forms.FlowLayoutPanel; $maintenanceBar.Dock = 'Fill';
  $armButton = New-Object System.Windows.Forms.Button; $armButton.Text = 'Armar recuperação por 15 minutos...'; $armButton.AutoSize = $true;
  $nerusRestartButton = New-Object System.Windows.Forms.Button; $nerusRestartButton.Text = 'Nerus instalado (atalho)...'; $nerusRestartButton.AutoSize = $true;
  $nerusServiceButton = New-Object System.Windows.Forms.Button; $nerusServiceButton.Text = 'Nerus Service (Caixa Web)...'; $nerusServiceButton.AutoSize = $true;
  $disarmButton = New-Object System.Windows.Forms.Button; $disarmButton.Text = 'Desarmar recuperação'; $disarmButton.AutoSize = $true;
  $maintenanceBar.Controls.AddRange([System.Windows.Forms.Control[]]@($nerusServiceButton, $armButton, $disarmButton, $nerusRestartButton));
  $layout.Controls.Add($maintenanceBar, 0, 7);
  $dataLabel = New-Object System.Windows.Forms.Label; $dataLabel.Dock = 'Fill'; $dataLabel.Text = 'Logs e configuração: ' + $script:dataDirectory;
  $layout.Controls.Add($dataLabel, 0, 8);
  $installBar = New-Object System.Windows.Forms.FlowLayoutPanel; $installBar.Dock = 'Fill';
  $installButton = New-Object System.Windows.Forms.Button; $installButton.Text = 'Iniciar automaticamente neste usuário...'; $installButton.AutoSize = $true;
  $exitButton = New-Object System.Windows.Forms.Button; $exitButton.Text = 'Encerrar monitor'; $exitButton.AutoSize = $true;
  $installBar.Controls.AddRange([System.Windows.Forms.Control[]]@($installButton, $exitButton));
  $layout.Controls.Add($installBar, 0, 9);
  $warningLabel = New-Object System.Windows.Forms.Label; $warningLabel.Dock = 'Fill';
  $layout.Controls.Add($warningLabel, 0, 10);
  $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel; $statusLabel.Spring = $true; $statusLabel.TextAlign = 'MiddleLeft';
  $statusBar = New-Object System.Windows.Forms.StatusStrip; [void]$statusBar.Items.Add($statusLabel); $form.Controls.Add($statusBar);

  $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip;
  $openMenu = $trayMenu.Items.Add('Abrir monitor');
  $script:exportMenu = $trayMenu.Items.Add('Exportar diagnóstico...');
  $exitMenu = $trayMenu.Items.Add('Encerrar monitor');
  $tray = New-Object System.Windows.Forms.NotifyIcon;
  $tray.Text = 'Feirão: monitor do PDV ativo'; $tray.Icon = [System.Drawing.SystemIcons]::Application;
  $tray.ContextMenuStrip = $trayMenu; $tray.Visible = $true;
  $showWindow = { $form.Show(); $form.WindowState = 'Normal'; $form.Activate(); };
  $openMenu.add_Click($showWindow); $tray.add_DoubleClick($showWindow);
  $script:exportMenu.add_Click({ Export-PdvMonitorFromWindow; });
  $exitMonitor = {
    if ($null -ne $script:nerusWorker -or $script:session.NerusRestart.Busy -or (Test-PdvMonitorNerusServiceBusy)) { $form.Show(); $statusLabel.Text = 'Aguarde concluir a tentativa de correção do Nerus antes de encerrar o monitor.'; return; }
    $script:closing = $true;
    if ($null -eq $script:worker) { $form.Close(); }
    else { $form.Show(); $statusLabel.Text = 'Concluindo a coleta antes de encerrar...'; Set-PdvMonitorControls $false; }
  };
  $exitMenu.add_Click($exitMonitor); $exitButton.add_Click($exitMonitor);
  $form.add_FormClosing({
    param($sender, $eventArgs);
    if ($null -ne $script:nerusWorker -or $script:session.NerusRestart.Busy -or (Test-PdvMonitorNerusServiceBusy)) {
      $eventArgs.Cancel = $true; $statusLabel.Text = 'Aguarde concluir a tentativa de correção do Nerus antes de fechar.'; return;
    }
    if ($eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:closing) {
      $eventArgs.Cancel = $true; $form.Hide();
    }
  });
  $nerusRestartButton.add_Click({ Start-PdvMonitorNerusRestartWorker -Mode 'Check'; });
  $nerusServiceButton.add_Click({ Start-PdvMonitorNerusServiceWorker -Mode 'Discover'; });
  $refreshButton.add_Click({ Start-PdvMonitorTickWorker; });
  $exportButton.add_Click({ Export-PdvMonitorFromWindow; });
  $centralButton.add_Click({ Show-PdvMonitorCentralConfiguration; });
  $folderButton.add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:dataDirectory + '"'); });
  $roleBox.add_SelectedIndexChanged({
    $portBox.Text = ''; $recoveryBox.Checked = $false;
    foreach ($profile in @($script:session.Config.Profiles)) {
      if ($profile.Role -eq [string]$roleBox.SelectedItem) { $portBox.Text = [string]$profile.ExpectedPort; $recoveryBox.Checked = [bool]$profile.RecoveryEnabled; }
    }
  });
  $bindButton.add_Click({
    try {
      if ($deviceList.SelectedItems.Count -ne 1) { throw 'Selecione o dispositivo correto na lista superior antes de salvar o vínculo.'; }
      $device = $deviceList.SelectedItems[0].Tag;
      $port = $portBox.Text.Trim().ToUpperInvariant();
      if ($port -and $port -notmatch '^COM[1-9][0-9]*$') { throw 'Informe a porta como COM4, por exemplo. Para uma impressora USB sem COM, deixe o campo vazio.'; }
      $profile = New-Object PSObject -Property @{ Role = [string]$roleBox.SelectedItem; InstanceId = [string]$device.InstanceId; ExpectedPort = $port; RecoveryEnabled = [bool]$recoveryBox.Checked };
      $profiles = @($script:session.Config.Profiles | Where-Object { $_.Role -ne $profile.Role });
      Save-PdvMonitorProfiles -Session $script:session -Profiles @($profiles + @($profile));
      Update-PdvMonitorView;
    } catch { Show-PdvMonitorMessage $_.Exception.Message 'Não foi possível salvar o perfil'; }
  });
  $removeButton.add_Click({
    try {
      $role = [string]$roleBox.SelectedItem;
      $profiles = @($script:session.Config.Profiles | Where-Object { $_.Role -ne $role });
      Save-PdvMonitorProfiles -Session $script:session -Profiles $profiles;
      Update-PdvMonitorView;
    } catch { Show-PdvMonitorMessage $_.Exception.Message; }
  });
  $armButton.add_Click({
    try {
      $names = @(Get-PdvMonitorProcessNames -Text $processBox.Text);
      if (-not $names.Count) { throw 'Informe os processos do PDV e TEF que devem bloquear qualquer recuperação.'; }
      if (-not @($script:session.Config.Profiles | Where-Object { $_.RecoveryEnabled }).Count) { throw 'Salve um perfil com recuperação permitida antes de armar a manutenção.'; }
      $message = "Confirme que o caixa está fechado, sem venda, pagamento ou impressão em andamento, e que todos os processos do PDV e TEF foram informados.`r`n`r`nDurante os próximos 15 minutos, o monitor poderá reiniciar somente os dispositivos autorizados, quando as verificações de segurança permitirem. O reinício interrompe a conexão do equipamento.`r`n`r`nProcessos que bloqueiam: " + ($names -join '; ') + "`r`n`r`nArmar a recuperação?";
      $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Manutenção do caixa', 'YesNo', 'Warning', 'Button2');
      if ($answer -ne 'Yes') { return; }
      Set-PdvMonitorMaintenance -Session $script:session -Minutes 15 -BlockingProcessNames $names;
      Update-PdvMonitorView; Start-PdvMonitorTickWorker;
    } catch { Show-PdvMonitorMessage $_.Exception.Message 'Recuperação não armada'; }
  });
  $disarmButton.add_Click({
    try { Set-PdvMonitorMaintenance -Session $script:session -Minutes 0; Update-PdvMonitorView; }
    catch { Show-PdvMonitorMessage $_.Exception.Message; }
  });
  $installButton.add_Click({
    try {
      if ($script:dataDirectory -ne (Join-Path $env:LOCALAPPDATA 'Feirao\PdvMonitor')) { throw 'A instalação automática usa a pasta padrão. Reabra Monitor.cmd sem pasta personalizada para ativá-la.'; }
      $installedPath = & (Join-Path $script:programDirectory 'InstalarMonitor.ps1');
      Show-PdvMonitorMessage ('Início automático ativado somente para este usuário. O monitor abrirá ao entrar no Windows, sem administrador e com recuperação desarmada.' + [Environment]::NewLine + [string]$installedPath);
    } catch { Show-PdvMonitorMessage $_.Exception.Message 'Falha na instalação'; }
  });
  $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 500;
  $timer.add_Tick({
    try { Receive-PdvMonitorDeviceSignals; }
    catch { $script:wmiWarning = 'Falha ao receber notificação imediata; a coleta periódica continua. ' + $_.Exception.Message; }
    Complete-PdvMonitorNerusRestartWorker;
    Complete-PdvMonitorNerusServiceWorker;
    Complete-PdvMonitorTickWorker;
    if ($null -eq $script:nerusWorker -and -not $script:session.NerusRestart.Busy -and -not (Test-PdvMonitorNerusServiceBusy) -and $null -eq $script:worker -and -not $script:closing -and (Get-Date) -ge $script:nextTickAt) { Start-PdvMonitorTickWorker; }
  });
  $form.add_Shown({
    if ($StartHidden) { $form.Hide(); }
    $roleBox.SelectedIndex = -1; $roleBox.SelectedIndex = 0;
    Update-PdvMonitorView; $timer.Start(); Start-PdvMonitorTickWorker;
  });
  [System.Windows.Forms.Application]::Run($form);
} catch {
  Show-PdvMonitorMessage ('O monitor não pôde continuar: ' + $_.Exception.Message) 'Falha no monitor do PDV';
  exit 1;
} finally {
  if ($null -ne $timer) { $timer.Stop(); $timer.Dispose(); }
  if ($script:wmiSubscribed) {
    Unregister-Event -SourceIdentifier $script:wmiSource -ErrorAction SilentlyContinue;
    Get-Event -SourceIdentifier $script:wmiSource -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue;
  }
  if ($null -ne $script:worker) {
    # No encerramento do Windows, não esperar indefinidamente por uma consulta WMI.
    try { $script:worker.Stop(); } catch { }
    $script:worker.Dispose();
  }
  if ($null -ne $script:nerusWorker) {
    try { $script:nerusWorker.Stop(); } catch { }
    $script:nerusWorker.Dispose();
  }
  if ($null -ne $script:serviceWorker) {
    try { $script:serviceWorker.Stop(); } catch { }
    $script:serviceWorker.Dispose();
  }
  if ($null -ne $script:session) { try { Stop-PdvMonitorSession -Session $script:session; } catch { } }
  if ($null -ne $tray) { $tray.Visible = $false; $tray.Dispose(); }
  if ($null -ne $form) { $form.Dispose(); }
  try { $mutex.ReleaseMutex(); } catch { }
  $mutex.Dispose();
}
