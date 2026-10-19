#requires -Version 2.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DataDirectory,[Parameter(Mandatory=$true)][string]$ProgramDirectory,[Parameter(Mandatory=$true)][int]$ParentProcessId)
$ErrorActionPreference='Stop';
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'O atualizador deve executar no Windows do caixa.'; }
Import-Module (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'PdvMonitor.Atualizacao.psm1') -Force;
$module=Get-Module PdvMonitor.Atualizacao;
$result=& $module { param($data,$program,$parentId); Invoke-PdvUpdateApplyInternal $data $program $parentId; } $DataDirectory $ProgramDirectory $ParentProcessId;
if (-not $result.Success) { exit 1; }
exit 0;
