#requires -Version 2.0
[CmdletBinding()]
param([switch]$StartHidden)
$ErrorActionPreference = 'Stop';
$directory = Split-Path -Parent $MyInvocation.MyCommand.Path;
try {
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Este monitor é destinado ao Windows 7, 10 ou 11.'; }
  & (Join-Path $directory 'MonitorPdv.ps1') -StartHidden:$StartHidden;
} catch {
  Add-Type -AssemblyName System.Windows.Forms;
  [void][System.Windows.Forms.MessageBox]::Show(('Não foi possível abrir o monitor: ' + $_.Exception.Message), 'Monitor do PDV', 'OK', 'Error');
  exit 1;
}
