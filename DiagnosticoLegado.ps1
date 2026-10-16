#requires -Version 2.0
# Modo legado: apenas consultas locais WMI/Registro e exportação escolhida pelo
# operador. Não abre portas, não escreve no Registro e não reinicia dispositivos.
# Present/PNPClass não são suportados no Win7, conforme a documentação WMI:
# https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pnpentity
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop';

Import-Module (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'PdvLegado.Core.psm1') -Force;

function New-PdvLegacyList {
  param([string[]]$Columns, [int[]]$Widths);
  $view = New-Object System.Windows.Forms.ListView;
  $view.Dock = 'Fill'; $view.View = 'Details'; $view.FullRowSelect = $true;
  $view.GridLines = $true; $view.HideSelection = $false;
  for ($index = 0; $index -lt $Columns.Length; $index++) { [void]$view.Columns.Add($Columns[$index], $Widths[$index]); }
  return $view;
}

function Add-PdvLegacyListRow {
  param($List, [string[]]$Values);
  $item = New-Object System.Windows.Forms.ListViewItem($Values[0]);
  for ($index = 1; $index -lt $Values.Length; $index++) { [void]$item.SubItems.Add([string]$Values[$index]); }
  [void]$List.Items.Add($item);
}

function Update-PdvLegacyView {
  $form.UseWaitCursor = $true; $refresh.Enabled = $false;
  try {
    $script:legacySnapshot = Get-PdvLegacySnapshot;
    $devicesView.Items.Clear(); $printersView.Items.Clear(); $reservationsView.Items.Clear();
    foreach ($device in @($script:legacySnapshot.Devices)) {
      Add-PdvLegacyListRow $devicesView @($device.Name, $device.Port, $device.Presence, $device.Status, [string]$device.ProblemCode, $device.Class, $device.InstanceId);
    }
    foreach ($printer in @($script:legacySnapshot.Printers)) {
      Add-PdvLegacyListRow $printersView @($printer.Name, $printer.PortName, $printer.DriverName, [string]$printer.WorkOffline, [string]$printer.PrinterStatus);
    }
    foreach ($port in @($script:legacySnapshot.ReservedPorts)) { Add-PdvLegacyListRow $reservationsView @($port, 'Reserva não identifica proprietário e não prova presença.'); }
    $warningsBox.Text = $script:legacySnapshot.Warnings -join "`r`n";
    $statusLabel.Text = 'Consulta: ' + (Get-Date -Format 'HH:mm:ss') + ' | ' + $script:legacySnapshot.Windows + ' | Modo legado / somente leitura';
    $export.Enabled = $true;
  } catch {
    $statusLabel.Text = 'Consulta não concluída. Clique em Atualizar para tentar novamente.';
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Falha na consulta', 'OK', 'Error');
  } finally { $form.UseWaitCursor = $false; $refresh.Enabled = $true; }
}

try {
  Add-Type -AssemblyName System.Windows.Forms;
  Add-Type -AssemblyName System.Drawing;
  [System.Windows.Forms.Application]::EnableVisualStyles();
  $script:legacySnapshot = $null;
  $form = New-Object System.Windows.Forms.Form;
  $form.Text = 'Dispositivos do PDV - consulta legada'; $form.Width = 1080; $form.Height = 720;
  $form.MinimumSize = New-Object System.Drawing.Size(800, 580); $form.StartPosition = 'CenterScreen';
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9);
  $layout = New-Object System.Windows.Forms.TableLayoutPanel;
  $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 5;
  $layout.Padding = New-Object System.Windows.Forms.Padding(12);
  foreach ($height in @(76, 40, -1, 100, 26)) {
    $row = New-Object System.Windows.Forms.RowStyle;
    if ($height -eq -1) { $row.SizeType = 'Percent'; $row.Height = 100; }
    else { $row.SizeType = 'Absolute'; $row.Height = $height; }
    [void]$layout.RowStyles.Add($row);
  }
  $form.Controls.Add($layout);
  $intro = New-Object System.Windows.Forms.Label;
  $intro.Dock = 'Fill';
  $intro.Text = "MODO LEGADO - consultas locais WMI e Registro, sem alterações nos dispositivos.`r`nNo Windows 7, a presença física pode não ser confirmada. Status OK e código 0 não comprovam conexão ou comunicação com o Nerus/SiTef. Filas e reservas COM também não provam presença. Piloto ainda sem validação em Windows e nos equipamentos.";
  $layout.Controls.Add($intro, 0, 0);
  $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Fill';
  $refresh = New-Object System.Windows.Forms.Button; $refresh.Text = 'Atualizar consulta'; $refresh.AutoSize = $true;
  $export = New-Object System.Windows.Forms.Button; $export.Text = 'Exportar diagnóstico CSV...'; $export.AutoSize = $true; $export.Enabled = $false;
  $toolbar.Controls.AddRange([System.Windows.Forms.Control[]]@($refresh, $export));
  $layout.Controls.Add($toolbar, 0, 1);
  $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill';
  $devicesTab = New-Object System.Windows.Forms.TabPage; $devicesTab.Text = 'Dispositivos / portas';
  $devicesView = New-PdvLegacyList @('Dispositivo', 'COM', 'Presença', 'Status WMI', 'Código', 'Classe', 'Identificador') @(245, 60, 120, 90, 60, 100, 420);
  $devicesTab.Controls.Add($devicesView);
  $printersTab = New-Object System.Windows.Forms.TabPage; $printersTab.Text = 'Filas de impressão';
  $printersView = New-PdvLegacyList @('Fila', 'Porta configurada', 'Driver', 'WorkOffline', 'Status WMI') @(260, 150, 300, 110, 110);
  $printersTab.Controls.Add($printersView);
  $reservationsTab = New-Object System.Windows.Forms.TabPage; $reservationsTab.Text = 'Reservas COM';
  $reservationsView = New-PdvLegacyList @('Porta', 'Interpretação') @(90, 800);
  $reservationsTab.Controls.Add($reservationsView);
  $tabs.TabPages.AddRange([System.Windows.Forms.TabPage[]]@($devicesTab, $printersTab, $reservationsTab));
  $layout.Controls.Add($tabs, 0, 2);
  $warningsBox = New-Object System.Windows.Forms.TextBox;
  $warningsBox.Dock = 'Fill'; $warningsBox.Multiline = $true; $warningsBox.ReadOnly = $true; $warningsBox.ScrollBars = 'Vertical';
  $warningsBox.ForeColor = [System.Drawing.Color]::DarkRed;
  $layout.Controls.Add($warningsBox, 0, 3);
  $statusLabel = New-Object System.Windows.Forms.Label; $statusLabel.Dock = 'Fill'; $statusLabel.Text = 'Consultando...';
  $layout.Controls.Add($statusLabel, 0, 4);
  $refresh.Add_Click({ Update-PdvLegacyView; });
  $export.Add_Click({
    if ($null -eq $script:legacySnapshot) { return; }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog;
    $dialog.Filter = 'Diagnóstico CSV (*.csv)|*.csv'; $dialog.FileName = 'PDV-legado-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv';
    $dialog.OverwritePrompt = $true;
    try {
      if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return; }
      $csvLines = @(Get-PdvLegacyExportRows $script:legacySnapshot | Select-Object Tipo, Nome, Porta, Presenca, Status, CodigoProblema, Identificador, Detalhes | ConvertTo-Csv -NoTypeInformation);
      # Gravação literal pelo .NET evita depender de parâmetros de Export-Csv
      # acrescentados depois do PowerShell 2.0 ou interpretar curingas no nome.
      [System.IO.File]::WriteAllLines($dialog.FileName, [string[]]$csvLines, [System.Text.Encoding]::UTF8);
      [void][System.Windows.Forms.MessageBox]::Show('Diagnóstico salvo localmente. Contém identificadores de hardware; revise antes de compartilhar.', 'Exportação concluída', 'OK', 'Information');
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Falha na exportação', 'OK', 'Error'); }
    finally { $dialog.Dispose(); }
  });
  $form.Add_Shown({ Update-PdvLegacyView; });
  [void]$form.ShowDialog();
  $form.Dispose();
} catch {
  Write-Error ('Não foi possível iniciar o modo legado: ' + $_.Exception.Message);
  exit 1;
}
