#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop';
Add-Type -AssemblyName System.Windows.Forms;
Add-Type -AssemblyName System.Drawing;
[System.Windows.Forms.Application]::EnableVisualStyles();
Import-Module (Join-Path $PSScriptRoot 'PdvDispositivos.Core.psm1') -Force;

$script:dataPath = Join-Path $env:LOCALAPPDATA 'Feirao\PdvDispositivos';
$script:profilesPath = Join-Path $script:dataPath 'perfis.json';
$script:logPath = Join-Path $script:dataPath 'historico.jsonl';
$script:profiles = @();
$script:events = @();
$script:snapshot = $null;
$script:previousDevices = @{};
$script:busy = $false;
$script:hasSnapshot = $false;
$script:logFailure = '';
$script:rendering = $false;
$script:stateNames = @{
  Ready = 'Conforme no Windows'; Missing = 'Ausente'; Mismatch = 'Porta divergente';
  Conflict = 'Conflito / reserva'; NoPort = 'Sem porta COM';
  InvalidProfile = 'Perfil inválido'; DeviceProblem = 'Problema no Windows';
};

function Show-PdvMessage {
  param([string]$Message, [string]$Title = 'Dispositivos do PDV');
  [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Information');
}

function Write-PdvEvent {
  param([string]$Kind, [string]$Message, [object]$Data = $null);
  $entry = [pscustomobject]@{ Time = (Get-Date).ToString('o'); Kind = $Kind; Message = $Message; Data = $Data };
  $script:events = @($script:events | Select-Object -Last 199) + @($entry);
  try {
    if ((Test-Path -LiteralPath $script:logPath) -and (Get-Item -LiteralPath $script:logPath).Length -gt 2MB) {
      Move-Item -LiteralPath $script:logPath -Destination ($script:logPath + '.anterior') -Force;
    }
    $entry | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $script:logPath -Encoding UTF8;
  } catch {
    $script:logFailure = 'Histórico em disco indisponível: ' + $_.Exception.Message;
  }
}

function Save-PdvProfiles {
  param([object[]]$Profiles);
  $temporary = Join-Path $script:dataPath ([guid]::NewGuid().ToString() + '.tmp');
  try {
    ConvertTo-Json -InputObject @($Profiles) -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8;
    Move-Item -LiteralPath $temporary -Destination $script:profilesPath -Force;
    $script:profiles = @($Profiles);
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary; }
  }
}

function New-PdvList {
  param([string[]]$Columns, [int[]]$Widths);
  $view = New-Object System.Windows.Forms.ListView;
  $view.Dock = 'Fill'; $view.View = 'Details'; $view.FullRowSelect = $true;
  $view.MultiSelect = $false; $view.HideSelection = $false; $view.GridLines = $true;
  for ($i = 0; $i -lt $Columns.Count; $i++) { [void]$view.Columns.Add($Columns[$i], $Widths[$i]); }
  return $view;
}

function Add-PdvRow {
  param($View, [string[]]$Values, $Tag);
  $item = New-Object System.Windows.Forms.ListViewItem($Values[0]);
  for ($i = 1; $i -lt $Values.Count; $i++) { [void]$item.SubItems.Add([string]$Values[$i]); }
  $item.Tag = $Tag;
  [void]$View.Items.Add($item);
  return $item;
}

function Update-PdvViews {
  $selectedId = '';
  if ($deviceList.SelectedItems.Count -eq 1) { $selectedId = $deviceList.SelectedItems[0].Tag.InstanceId; }
  $script:rendering = $true;
  $deviceList.BeginUpdate(); $deviceList.Items.Clear();
  foreach ($device in @($script:snapshot.Devices)) {
    if (-not $showAbsent.Checked -and -not $device.Present) { continue; }
    $presence = if (-not $device.PresenceKnown) { 'Não confirmada' } elseif ($device.Present) { 'Presente' } else { 'Desconectado' };
    $row = Add-PdvRow $deviceList @($device.Name, $device.Port, $presence, $device.Status, $device.Class, $device.InstanceId) $device;
    if (-not $device.Present) { $row.ForeColor = [System.Drawing.Color]::DimGray; }
    if ($device.InstanceId -eq $selectedId) { $row.Selected = $true; }
  }
  $deviceList.EndUpdate();
  $script:rendering = $false;

  $profileList.Items.Clear();
  $states = @(Get-PdvProfileStatus -Profiles $script:profiles -Snapshot $script:snapshot);
  foreach ($state in $states) {
    $stateName = $script:stateNames[$state.State];
    if (-not $stateName) { $stateName = $state.State; }
    $explanation = (@($state.Message) + @($state.Conflicts)) -join ' ';
    $row = Add-PdvRow $profileList @($state.Role, $state.ExpectedPort, $state.ActualPort, $stateName, $explanation) $state;
    if ($state.State -ne 'Ready') { $row.ForeColor = [System.Drawing.Color]::Firebrick; }
  }

  $printerList.Items.Clear();
  foreach ($printer in @($script:snapshot.Printers)) {
    [void](Add-PdvRow $printerList @($printer.Name, $printer.PortName, $printer.DriverName, [string]$printer.WorkOffline) $printer);
  }
  $reservationList.Items.Clear();
  foreach ($port in @($script:snapshot.ReservedPorts)) {
    $assigned = @($script:snapshot.Devices | Where-Object { $_.Port -eq $port });
    $description = (@($assigned | ForEach-Object {
      $presence = if ($_.Present) { 'presente' } else { 'desconectado / não confirmado' };
      $_.Name + ' (' + $presence + ')';
    }) -join '; ');
    if (-not $description) { $description = 'Sem atribuição identificada. Proprietário da reserva desconhecido; não assumir livre.'; }
    [void](Add-PdvRow $reservationList @($port, $description) $port);
  }
  $history.Text = (@($script:events | Select-Object -Last 100 | ForEach-Object {
    '{0} | {1} | {2}' -f $_.Time, $_.Kind, $_.Message;
  }) -join [Environment]::NewLine);
  $warnings = @($script:snapshot.Warnings);
  if ($script:logFailure) { $warnings += $script:logFailure; }
  $warningLabel.Text = if ($warnings.Count) { $warnings -join ' | ' } else {
    'Presente no Windows não comprova comunicação com o Nerus. Porta esperada é uma referência informada por você.';
  };
  $mode = if ($script:snapshot.Windows.IsAdministrator) { 'Administrador' } else { 'Consulta (sem administrador)' };
  $statusLabel.Text = 'Atualizado: {0} | {1} | {2} dispositivos | {3}' -f (Get-Date -Format 'HH:mm:ss'), $mode, @($script:snapshot.Devices).Count, $script:snapshot.Windows.Caption;
}

function Update-PdvSnapshot {
  if ($script:busy) { return; }
  $script:busy = $true; $form.UseWaitCursor = $true;
  try {
    $next = Get-PdvSnapshot;
    $nextMap = @{};
    foreach ($device in @($next.Devices)) {
      $signature = '{0}|{1}|{2}|{3}|{4}' -f $device.Present, $device.Port, $device.Status, $device.ProblemCode, $device.PresenceKnown;
      $nextMap[$device.InstanceId] = $signature;
      if ($script:hasSnapshot -and $script:previousDevices[$device.InstanceId] -ne $signature) {
        Write-PdvEvent 'Mudança' ('{0}: porta {1}; presente={2}; status={3}' -f $device.Name, $device.Port, $device.Present, $device.Status) $device;
      }
    }
    if ($script:hasSnapshot) {
      foreach ($id in $script:previousDevices.Keys) {
        if (-not $nextMap.ContainsKey($id)) { Write-PdvEvent 'Mudança' ('Instância deixou de ser enumerada: ' + $id); }
      }
    }
    $script:previousDevices = $nextMap; $script:snapshot = $next; $script:hasSnapshot = $true;
    Update-PdvViews;
  } catch {
    $monitor.Checked = $false;
    $statusLabel.Text = 'Falha ao consultar. O monitoramento foi pausado; clique em Atualizar para tentar novamente.';
    Write-PdvEvent 'Erro' $_.Exception.Message;
    Show-PdvMessage $_.Exception.Message 'Falha na consulta';
  } finally {
    $form.UseWaitCursor = $false; $script:busy = $false;
  }
}

$createdNew = $false;
$mutex = New-Object System.Threading.Mutex($true, 'Local\Feirao.PdvDispositivos', [ref]$createdNew);
if (-not $createdNew) { Show-PdvMessage 'O aplicativo já está aberto nesta sessão do Windows.'; $mutex.Dispose(); exit; }

try {
  [void](New-Item -ItemType Directory -Path $script:dataPath -Force);
  if (Test-Path -LiteralPath $script:profilesPath) {
    $storedProfiles = Get-Content -LiteralPath $script:profilesPath -Raw | ConvertFrom-Json;
    $script:profiles = @($storedProfiles | Where-Object { $null -ne $_ });
    foreach ($profile in $script:profiles) {
      if (-not $profile.Role -or -not $profile.InstanceId) { throw 'Arquivo de perfis inválido. Preserve perfis.json e procure o suporte antes de continuar.'; }
    }
  }
  if (Test-Path -LiteralPath $script:logPath) {
    foreach ($line in @(Get-Content -LiteralPath $script:logPath -Tail 100)) {
      try { $script:events += ($line | ConvertFrom-Json); } catch { }
    }
  }

  $form = New-Object System.Windows.Forms.Form;
  $form.Text = 'Feirão | Dispositivos do PDV — piloto';
  $form.Size = New-Object System.Drawing.Size(1120, 780);
  $form.MinimumSize = New-Object System.Drawing.Size(900, 650);
  $form.StartPosition = 'CenterScreen';
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9);

  $layout = New-Object System.Windows.Forms.TableLayoutPanel;
  $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 8; $layout.Padding = New-Object System.Windows.Forms.Padding(12);
  foreach ($height in @(54, 42, 0, 36, 42, 38, 58, 28)) {
    $style = New-Object System.Windows.Forms.RowStyle;
    if ($height -eq 0) { $style.SizeType = 'Percent'; $style.Height = 100; } else { $style.SizeType = 'Absolute'; $style.Height = $height; }
    [void]$layout.RowStyles.Add($style);
  }
  $form.Controls.Add($layout);

  $intro = New-Object System.Windows.Forms.Label;
  $intro.Dock = 'Fill';
  $intro.Text = "Confira a porta reconhecida pelo Windows e acompanhe mudanças do pinpad e da impressora.`r`nSalvar uma porta esperada não altera o Windows ou o Nerus. Reinícios são manuais, com o caixa fora de operação.";
  $layout.Controls.Add($intro, 0, 0);

  $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Fill';
  $refresh = New-Object System.Windows.Forms.Button; $refresh.Text = 'Atualizar'; $refresh.AutoSize = $true;
  $monitor = New-Object System.Windows.Forms.CheckBox; $monitor.Text = 'Acompanhar a cada 15 segundos'; $monitor.AutoSize = $true; $monitor.Margin = New-Object System.Windows.Forms.Padding(12, 8, 12, 0);
  $showAbsent = New-Object System.Windows.Forms.CheckBox; $showAbsent.Text = 'Mostrar ausentes / sem confirmação'; $showAbsent.AutoSize = $true; $showAbsent.Checked = $true; $showAbsent.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0);
  $toolbar.Controls.AddRange([System.Windows.Forms.Control[]]@($refresh, $monitor, $showAbsent));
  $layout.Controls.Add($toolbar, 0, 1);

  $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill';
  $deviceTab = New-Object System.Windows.Forms.TabPage; $deviceTab.Text = 'Dispositivos';
  $deviceList = New-PdvList @('Dispositivo', 'Porta', 'Presença', 'Status Windows', 'Classe', 'Identificador da instância') @(280, 65, 100, 110, 90, 400);
  $deviceTab.Controls.Add($deviceList);
  $profileTab = New-Object System.Windows.Forms.TabPage; $profileTab.Text = 'Mapeamentos esperados';
  $profileList = New-PdvList @('Papel', 'Esperada', 'Atual', 'Situação', 'Detalhes') @(150, 75, 75, 165, 540);
  $profileTab.Controls.Add($profileList);
  $printerTab = New-Object System.Windows.Forms.TabPage; $printerTab.Text = 'Filas de impressão';
  $printerList = New-PdvList @('Fila', 'Porta da fila', 'Driver', 'Modo offline') @(300, 180, 330, 100);
  $printerTab.Controls.Add($printerList);
  $reservationTab = New-Object System.Windows.Forms.TabPage; $reservationTab.Text = 'Reservas COM';
  $reservationList = New-PdvList @('COM reservada', 'Atribuições encontradas (a reserva não identifica seu proprietário)') @(120, 850);
  $reservationTab.Controls.Add($reservationList);
  $historyTab = New-Object System.Windows.Forms.TabPage; $historyTab.Text = 'Histórico';
  $history = New-Object System.Windows.Forms.TextBox; $history.Multiline = $true; $history.ReadOnly = $true;
  $history.Dock = 'Fill'; $history.ScrollBars = 'Both'; $history.WordWrap = $false;
  $historyTab.Controls.Add($history);
  $tabs.TabPages.AddRange([System.Windows.Forms.TabPage[]]@($deviceTab, $profileTab, $printerTab, $reservationTab, $historyTab));
  $layout.Controls.Add($tabs, 0, 2);

  $details = New-Object System.Windows.Forms.TextBox; $details.ReadOnly = $true; $details.Dock = 'Fill';
  $details.Text = 'Selecione um dispositivo para ver seu identificador.';
  $layout.Controls.Add($details, 0, 3);

  $mappingBar = New-Object System.Windows.Forms.FlowLayoutPanel; $mappingBar.Dock = 'Fill';
  $role = New-Object System.Windows.Forms.ComboBox; $role.DropDownStyle = 'DropDownList'; $role.Width = 155;
  [void]$role.Items.AddRange([object[]]@('Pinpad TEF', 'Impressora Bematech')); $role.SelectedIndex = 0;
  $expectedLabel = New-Object System.Windows.Forms.Label; $expectedLabel.Text = 'Porta esperada:'; $expectedLabel.AutoSize = $true; $expectedLabel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0);
  $expectedPort = New-Object System.Windows.Forms.TextBox; $expectedPort.Width = 70;
  $save = New-Object System.Windows.Forms.Button; $save.Text = 'Vincular selecionado'; $save.AutoSize = $true;
  $remove = New-Object System.Windows.Forms.Button; $remove.Text = 'Remover vínculo'; $remove.AutoSize = $true;
  $mappingBar.Controls.AddRange([System.Windows.Forms.Control[]]@($role, $expectedLabel, $expectedPort, $save, $remove));
  $layout.Controls.Add($mappingBar, 0, 4);

  $actions = New-Object System.Windows.Forms.FlowLayoutPanel; $actions.Dock = 'Fill';
  $restart = New-Object System.Windows.Forms.Button; $restart.Text = 'Reiniciar dispositivo...'; $restart.AutoSize = $true;
  $manager = New-Object System.Windows.Forms.Button; $manager.Text = 'Gerenciador de Dispositivos'; $manager.AutoSize = $true;
  $export = New-Object System.Windows.Forms.Button; $export.Text = 'Exportar diagnóstico'; $export.AutoSize = $true;
  $warningLabel = New-Object System.Windows.Forms.TextBox;
  $warningLabel.Multiline = $true; $warningLabel.ReadOnly = $true; $warningLabel.Dock = 'Fill'; $warningLabel.ScrollBars = 'Vertical';
  $warningLabel.ForeColor = [System.Drawing.Color]::DarkRed;
  $actions.Controls.AddRange([System.Windows.Forms.Control[]]@($restart, $manager, $export));
  $layout.Controls.Add($actions, 0, 5);
  $layout.Controls.Add($warningLabel, 0, 6);
  $statusLabel = New-Object System.Windows.Forms.Label; $statusLabel.Dock = 'Fill'; $statusLabel.Text = 'Consultando Windows...';
  $layout.Controls.Add($statusLabel, 0, 7);

  $deviceList.Add_SelectedIndexChanged({
    if (-not $script:rendering -and $deviceList.SelectedItems.Count -eq 1) {
      $device = $deviceList.SelectedItems[0].Tag;
      $details.Text = $device.InstanceId + ' | Local: ' + $device.Location + ' | Driver: ' + $device.DriverVersion;
      $expectedPort.Text = $device.Port;
    }
  });
  $refresh.Add_Click({ Update-PdvSnapshot; });
  $showAbsent.Add_CheckedChanged({ if ($script:snapshot) { Update-PdvViews; } });
  $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 15000;
  $timer.Add_Tick({ Update-PdvSnapshot; });
  $monitor.Add_CheckedChanged({ if ($monitor.Checked) { $timer.Start(); } else { $timer.Stop(); } });

  $save.Add_Click({
    try {
      if ($deviceList.SelectedItems.Count -ne 1) { throw 'Selecione o dispositivo físico na aba Dispositivos.'; }
      $device = $deviceList.SelectedItems[0].Tag;
      if (-not $device.Present) { throw 'Vincule um dispositivo presente para reduzir o risco de escolher uma instância antiga.'; }
      $port = $expectedPort.Text.Trim().ToUpperInvariant();
      if ($port -and ($port -notmatch '^COM([1-9][0-9]{0,3})$' -or [int]$port.Substring(3) -gt 4096)) { throw 'Informe uma porta de COM1 a COM4096, ou deixe em branco para uma impressora sem COM.'; }
      if ($role.SelectedItem -eq 'Pinpad TEF' -and -not $port) { throw 'Informe a porta configurada no Nerus para comparar com o pinpad.'; }
      if (@($script:profiles | Where-Object { $_.InstanceId -eq $device.InstanceId -and $_.Role -ne [string]$role.SelectedItem }).Count) {
        throw 'Esta instância já está vinculada ao outro papel. Confira a identificação física dos dispositivos.';
      }
      $newProfile = [pscustomobject]@{ Role = [string]$role.SelectedItem; InstanceId = $device.InstanceId; ExpectedPort = $port; Name = $device.Name };
      $nextProfiles = @($script:profiles | Where-Object { $_.Role -ne $newProfile.Role }) + @($newProfile);
      Save-PdvProfiles $nextProfiles;
      Write-PdvEvent 'Perfil' ('Referência salva: {0}, {1}, {2}. Windows e Nerus não foram alterados.' -f $newProfile.Role, $device.Name, $port) $newProfile;
      Update-PdvViews; $tabs.SelectedTab = $profileTab;
    } catch { Show-PdvMessage $_.Exception.Message; }
  });
  $remove.Add_Click({
    try {
      $selectedRole = [string]$role.SelectedItem;
      Save-PdvProfiles @($script:profiles | Where-Object { $_.Role -ne $selectedRole });
      Write-PdvEvent 'Perfil' ('Vínculo removido: ' + $selectedRole);
      Update-PdvViews;
    } catch { Show-PdvMessage $_.Exception.Message; }
  });
  $restart.Add_Click({
    if ($deviceList.SelectedItems.Count -ne 1) { Show-PdvMessage 'Selecione um dispositivo na aba Dispositivos.'; return; }
    if (-not $script:snapshot.Windows.IsAdministrator) { Show-PdvMessage 'Feche este aplicativo e execute Iniciar.cmd com o botão direito > Executar como administrador. As consultas funcionam sem essa permissão.'; return; }
    $device = $deviceList.SelectedItems[0].Tag;
    $question = "Dispositivo: $($device.Name)`r`nInstância: $($device.InstanceId)`r`n`r`nFeche o Nerus e os aplicativos que usam este dispositivo. Confirme que não há pagamento ou impressão em andamento.`r`n`r`nO Windows tentará reiniciar apenas esta instância. Isso interrompe sua comunicação e não recarrega a DLL do Nerus. O Windows poderá informar que precisa de reinicialização manual.`r`n`r`nO caixa está fora de operação e você deseja continuar?";
    $answer = [System.Windows.Forms.MessageBox]::Show($question, 'Reinício manual do dispositivo', 'YesNo', 'Warning', 'Button2');
    if ($answer -ne 'Yes') { return; }
    $timer.Stop(); $script:busy = $true; $form.UseWaitCursor = $true;
    try {
      Write-PdvEvent 'Reinício solicitado' $device.InstanceId;
      $result = Restart-PdvDevice -InstanceId $device.InstanceId;
      Write-PdvEvent 'Resultado do reinício' ('Código Windows: ' + $result.ExitCode) $result;
      if ($result.RestartRequired) { Show-PdvMessage 'O Windows solicitou reinicialização do computador. Planeje a reinicialização manual; o aplicativo não reinicia o PC.'; }
      elseif ($result.ExitCode -ne 0) { Show-PdvMessage ('O Windows não confirmou o reinício. Código: ' + $result.ExitCode + "`r`n" + $result.Output); }
      else { Show-PdvMessage 'O Windows aceitou o reinício. Abra o Nerus e valide a comunicação pelo procedimento do TEF ou da impressora. Isso não confirma que o problema foi resolvido.'; }
    } catch { Write-PdvEvent 'Erro no reinício' $_.Exception.Message; Show-PdvMessage $_.Exception.Message; }
    finally {
      $script:busy = $false; $form.UseWaitCursor = $false;
      Update-PdvSnapshot;
      if ($monitor.Checked) { $timer.Start(); }
    }
  });
  $manager.Add_Click({
    try { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\mmc.exe') -ArgumentList ('"' + (Join-Path $env:WINDIR 'System32\devmgmt.msc') + '"'); }
    catch { Show-PdvMessage $_.Exception.Message; }
  });
  $export.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog;
    $dialog.Filter = 'Diagnóstico JSON (*.json)|*.json'; $dialog.FileName = 'Diagnostico-PDV-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json';
    try {
      if (-not $script:snapshot) { throw 'Atualize o inventário antes de exportar.'; }
      if ($dialog.ShowDialog() -ne 'OK') { return; }
      $report = [ordered]@{
        Version = '0.1.0-piloto'; ExportedAt = (Get-Date).ToString('o');
        Scope = 'Inventário Windows; não testa pagamento, impressão ou disponibilidade da COM para abertura. Porta esperada informada pelo operador, sem ler configuração do Nerus.';
        Snapshot = $script:snapshot; Profiles = @($script:profiles);
        ProfileStatus = @(Get-PdvProfileStatus -Profiles $script:profiles -Snapshot $script:snapshot);
        RecentEvents = @($script:events); LogWarning = $script:logFailure;
      };
      $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8;
      Show-PdvMessage ('Diagnóstico salvo em ' + $dialog.FileName + '. Contém nomes e identificadores dos dispositivos; compartilhe apenas com o suporte autorizado.');
    } catch { Show-PdvMessage $_.Exception.Message; }
    finally { $dialog.Dispose(); }
  });

  Write-PdvEvent 'Aplicativo' 'Aplicativo iniciado. Monitoramento opcional; nenhuma porta é alterada automaticamente.';
  $form.Add_Shown({ Update-PdvSnapshot; });
  $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); });
  [void]$form.ShowDialog();
  $form.Dispose();
} catch {
  [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Não foi possível iniciar', 'OK', 'Error');
  exit 1;
} finally {
  $mutex.ReleaseMutex(); $mutex.Dispose();
}
