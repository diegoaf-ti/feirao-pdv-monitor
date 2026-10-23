#requires -Version 7.0
# Offline: valida o bootstrap com fronteiras Windows simuladas; nao executa CLI real.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;. (Join-Path $directory 'piloto-remoto/windows/AtivarCertificadoRemotoBootstrap.ps1');$script:Checks=0;
function Assert-Bootstrap($Value,[string]$Message){$script:Checks++;if(-not $Value){throw $Message;}}
function Assert-BootstrapThrows([scriptblock]$Body,[string]$Expected){$script:Checks++;try{&$Body|Out-Null;}catch{if($_.Exception.Message -ceq $Expected){return;};throw $_;};throw 'Missing expected exception';}
$script:RealInvoke=(Get-Command Invoke-PdvEnrollmentBootstrap).ScriptBlock;
$script:RealPath=(Get-Command Assert-PdvEnrollmentBootstrapPath).ScriptBlock;
$script:RealNode=(Get-Command Assert-PdvEnrollmentBootstrapNode).ScriptBlock;
function Reset-BootstrapCase {
  $script:Events=New-Object Collections.Generic.List[string];$script:Handles=New-Object Collections.Generic.List[object];$script:Failure='';$script:PathChecks=0;$script:CliCalls=0;
}
function Assert-PdvEnrollmentBootstrapAdministrator {$script:Events.Add('admin');if($script:Failure -ceq 'not-admin'){throw 'NotAdmin';}}
function Initialize-PdvEnrollmentBootstrapNative {$script:Events.Add('native');}
function Assert-PdvEnrollmentBootstrapPath {param($Path);$script:PathChecks++;$script:Events.Add('validate');if($script:Failure -ceq 'unsafe-acl'){throw 'UnsafeAcl';};if($script:Failure -ceq 'missing'){throw 'Missing';};if($script:Failure -ceq 'revalidate' -and $script:PathChecks -gt 7){throw 'Changed';};return $Path;}
function Open-PdvEnrollmentBootstrapLockedFile {
  param($Path);$script:Events.Add('lock');if($script:Failure -ceq 'hardlink' -and $script:Handles.Count -eq 2){throw 'Hardlink';}
  $handle=New-Object PSObject -Property @{Disposed=$false};$handle|Add-Member ScriptMethod Dispose {$this.Disposed=$true;};
  # Adapter implementing IDisposable: PowerShell objects do not implement interfaces.
  $wrapper=[Conecta.PdvEnrollmentBootstrapTest.Disposable]::new();$script:Handles.Add($wrapper);return $wrapper;
}
function Invoke-PdvEnrollmentBootstrapInstalledCli {param($Path);$script:CliCalls++;Assert-Bootstrap ($script:PathChecks -eq 14 -and $script:Handles.Count -eq 7) 'CLI executed before complete validation/locking';Assert-Bootstrap (@($script:Handles|Where-Object{$_.Disposed}).Count -eq 0) 'File lock released before CLI';$script:Events.Add('cli');}
Add-Type -TypeDefinition 'namespace Conecta.PdvEnrollmentBootstrapTest { public sealed class Disposable : System.IDisposable { public bool Disposed; public void Dispose() { Disposed=true; } } }';
foreach($case in @('not-admin','missing','unsafe-acl','hardlink','revalidate')){
  Reset-BootstrapCase;$script:Failure=$case;$expected=@{'not-admin'='NotAdmin';missing='Missing';'unsafe-acl'='UnsafeAcl';hardlink='Hardlink';revalidate='Changed'}[$case];Assert-BootstrapThrows {& $script:RealInvoke;} $expected;Assert-Bootstrap ($script:CliCalls -eq 0) ('Unsafe case executed CLI: '+$case);Assert-Bootstrap (@($script:Handles|Where-Object{-not $_.Disposed}).Count -eq 0) ('Failed case leaked locks: '+$case);
}
Reset-BootstrapCase;& $script:RealInvoke;Assert-Bootstrap ($script:CliCalls -eq 1) 'Valid case did not execute CLI';Assert-Bootstrap (@($script:Handles|Where-Object{-not $_.Disposed}).Count -eq 0) 'Success leaked locks';Assert-Bootstrap ($script:Events[0] -ceq 'admin') 'No administrator gate';Assert-Bootstrap ($script:Events.IndexOf('lock') -eq 9) 'Code was opened before every path was validated';
$cmd=[IO.File]::ReadAllText((Join-Path $directory 'piloto-remoto/windows/AtivarCertificadoRemoto.cmd'));Assert-Bootstrap ($cmd.Contains('%~dp0AtivarCertificadoRemotoBootstrap.ps1')) 'CMD does not use package bootstrap';Assert-Bootstrap (-not $cmd.Contains('%ProgramData%')) 'CMD directly trusts installed code';
$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'piloto-remoto/windows/AtivarCertificadoRemotoBootstrap.ps1'),[ref]$null,[ref]$errors)|Out-Null;Assert-Bootstrap ($errors.Count -eq 0) 'Bootstrap parse errors';
Write-Output ('OK: '+$script:Checks+' verificacoes offline do bootstrap; nenhuma CLI instalada foi executada.');
