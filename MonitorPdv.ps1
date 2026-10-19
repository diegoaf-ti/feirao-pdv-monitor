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

function Set-PdvMonitorControls {
  param([bool]$Enabled);
  foreach ($control in @($refreshButton, $bindButton, $removeButton, $roleBox, $portBox, $recoveryBox, $processBox, $armButton, $disarmButton, $exportButton, $installButton, $centralButton)) {
    $control.Enabled = $Enabled;
  }
  $script:exportMenu.Enabled = $Enabled;
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
  if ($null -ne $script:worker -or $script:closing) { return; }
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
    $apply=Start-PdvMonitorUpdateApply -Session $script:session -ProgramDirectory $script:programDirectory -Enabled $script:session.AutoUpdateEnabled -OperationsIdle $idle;
    $script:session.UpdateStatus=$apply.Reason;
    if ($apply.Started) { $script:closing=$true; }
  }
  if ($script:closing) { $form.Close(); }
}

function Export-PdvMonitorFromWindow {
  if ($null -ne $script:worker) { return; }
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
  $disarmButton = New-Object System.Windows.Forms.Button; $disarmButton.Text = 'Desarmar recuperação'; $disarmButton.AutoSize = $true;
  $maintenanceBar.Controls.AddRange([System.Windows.Forms.Control[]]@($armButton, $disarmButton));
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
    $script:closing = $true;
    if ($null -eq $script:worker) { $form.Close(); }
    else { $form.Show(); $statusLabel.Text = 'Concluindo a coleta antes de encerrar...'; Set-PdvMonitorControls $false; }
  };
  $exitMenu.add_Click($exitMonitor); $exitButton.add_Click($exitMonitor);
  $form.add_FormClosing({
    param($sender, $eventArgs);
    if ($eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and -not $script:closing) {
      $eventArgs.Cancel = $true; $form.Hide();
    }
  });
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
    Complete-PdvMonitorTickWorker;
    if ($null -eq $script:worker -and -not $script:closing -and (Get-Date) -ge $script:nextTickAt) { Start-PdvMonitorTickWorker; }
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
  if ($null -ne $script:session) { try { Stop-PdvMonitorSession -Session $script:session; } catch { } }
  if ($null -ne $tray) { $tray.Visible = $false; $tray.Dispose(); }
  if ($null -ne $form) { $form.Dispose(); }
  try { $mutex.ReleaseMutex(); } catch { }
  $mutex.Dispose();
}
