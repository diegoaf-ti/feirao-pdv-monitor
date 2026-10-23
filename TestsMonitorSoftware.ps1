#requires -Version 5.1
# Testes offline de normalizacao, limites e privacidade; nenhum Registro/Defender real.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Import-Module (Join-Path $directory 'PdvMonitor.Inventario.psm1') -Force;$module=Get-Module PdvMonitor.Inventario;
$script:Checks=0;$script:Cases=0;$failures=New-Object 'Collections.Generic.List[string]';
function Assert-Software($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Test-Software([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
& $module {
  function script:Get-PdvSoftwareNow{return $script:SoftwareNow;}
  function script:Get-PdvSoftwareRegistryEnvironment{return @{Os64=$script:SoftwareOs64;Process64=$true;HasRegistryView=$true};}
  function script:Read-PdvSoftwareRegistryView {
    param([string]$Scope,[string]$View,$Environment);
    $script:SoftwareCalls.Add($Scope+':'+$View);$entries=@();
    if($Scope -ceq 'machine' -and $View -ceq 'x64'){$entries=@($script:SoftwareEntries);}
    if(-not $script:SoftwareOs64 -and $Scope -ceq 'machine'){$entries=@($script:SoftwareEntries);}
    return @{Complete=($script:SoftwareFailedView -cne ($Scope+':'+$View));Entries=$entries;Reason='PRIVATE exception should never escape'};
  }
  function script:Read-PdvSoftwareDefender {return $script:SoftwareDefender;}
}
function Reset-Software {
  & $module {
    $script:SoftwareNow=[DateTimeOffset]::Parse('2026-10-21T15:00:00-03:00');$script:SoftwareOs64=$true;$script:SoftwareFailedView='';$script:SoftwareCalls=New-Object 'Collections.Generic.List[string]';
    $script:SoftwareEntries=@(@{SubKeyName='{GUID-PRIVATE-IDENTIFIER}';DisplayName='Aplicativo teste';DisplayVersion='1.2.3';Publisher='Empresa';InstallDate='20260228';UninstallString='SECRET_COMMAND';InstallSource='SECRET_PATH';ProductKey='SECRET_KEY'});
    $script:SoftwareDefender=@{ThreatsAvailable=$true;DetectionsAvailable=$true;Limited=$false;Threats=@();Detections=@()};
  };
}
function Get-SoftwareDocument {
  $r=Get-PdvMonitorSoftwareInventory;Assert-Software ($r.Success -and $null -ne $r.Software -and $r.Fingerprint -match '^[0-9a-f]{64}$') 'Documento nao valido';return $r;
}
try {
  Test-Software 'inventario 32/64 de maquina e usuario e whitelist sem comandos/segredos' {
    Reset-Software;$r=Get-SoftwareDocument;$s=$r.Software;$json=ConvertTo-PdvHardwareJson $s;
    Assert-Software ($s.complete -and $r.CoverageHealthy -and $s.coverage.machine -and $s.coverage.currentUser) 'Cobertura normal incorreta';
    Assert-Software (-not $s.coverage.otherUsers -and -not $s.coverage.store -and -not $s.coverage.portable) 'Inventou cobertura';
    Assert-Software (@($s.apps).Count -eq 1 -and $s.apps[0].reportedInstallDate -ceq '20260228' -and $s.apps[0].architecture -ceq 'x64') 'App normalizado errado';
    Assert-Software ($json -notmatch 'SECRET_|GUID-PRIVATE|UninstallString|InstallSource|ProductKey|Resources|ProcessName|UserName') 'Vazou dados fora whitelist';
    $calls=& $module {return @($script:SoftwareCalls.ToArray());};Assert-Software (@($calls).Count -eq 4 -and $calls -contains 'machine:x86' -and $calls -contains 'machine:x64' -and $calls -contains 'currentUser:x86' -and $calls -contains 'currentUser:x64') 'Nao leu visoes previstas';
    Assert-Software ($s.apps[0].key -match '^[0-9a-f]{64}$') 'Chave nao opaca';
  };
  Test-Software 'data calendario invalida, strings malformadas e valores nao string nao vazam' {
    Reset-Software;& $module {$script:SoftwareEntries[0].InstallDate='20260230';$script:SoftwareEntries[0].DisplayName="App`0ruim";$script:SoftwareEntries[0].Publisher=@('secret-invalid-array');};$r=Get-SoftwareDocument;
    Assert-Software (-not $r.Software.complete -and -not $r.CoverageHealthy -and $r.Software.apps[0].reportedInstallDate -ceq '' -and $r.Software.apps[0].name -ceq 'Appruim' -and $r.Software.apps[0].publisher -ceq '') 'Aceitou metadados invalidos';
    Assert-Software ((ConvertTo-PdvHardwareJson $r.Software) -notmatch 'secret-invalid-array|\\u0000') 'Vazou string invalida';
  };
  Test-Software 'falha de uma visao preserva outras e marca cobertura parcial' {
    Reset-Software;& $module {$script:SoftwareFailedView='currentUser:x86';};$r=Get-SoftwareDocument;
    Assert-Software (-not $r.Software.complete -and $r.Software.coverage.machine -and -not $r.Software.coverage.currentUser -and @($r.Software.apps).Count -eq 1) 'Falha parcial apagou demais ou virou completo';
    Assert-Software ((ConvertTo-PdvHardwareJson $r.Software) -notmatch 'PRIVATE exception') 'Excecao vazou';
  };
  Test-Software 'Defender indisponivel nao significa sem ameacas e nao invalida inventario apps' {
    Reset-Software;& $module {$script:SoftwareDefender.ThreatsAvailable=$false;$script:SoftwareDefender.DetectionsAvailable=$false;};$r=Get-SoftwareDocument;
    Assert-Software ($r.Software.complete -and $r.CoverageHealthy -and $r.Software.security.provider -ceq 'Unavailable' -and $r.Software.security.status -ceq 'unavailable') 'Confundiu cobertura apps/antivirus';
    Assert-Software ((@($r.Software.warnings) -join ' ') -match 'não significa ausência') 'Nao explicitou indisponibilidade';
  };
  Test-Software 'deteccao confirmada diferencia ativa e historica sem recursos privados' {
    Reset-Software;& $module {
      $script:SoftwareDefender.Threats=@(@{ThreatID=100;ThreatName='Trojan:Win32/Teste';SeverityID=4;IsActive=$true;Resources=@('SECRET_FILE');ProcessName='SECRET_PROCESS';DomainUser='SECRET_USER'},@{ThreatID=200;ThreatName='PUA:Win32/Historico';SeverityID=2;IsActive=$false});
      $script:SoftwareDefender.Detections=@(@{ThreatID=100;ActionSuccess=$false;LastThreatStatusChangeTime=$script:SoftwareNow.AddMinutes(-2);Resources=@('SECRET_FILE')},@{ThreatID=200;ActionSuccess=$true;LastThreatStatusChangeTime=$script:SoftwareNow.AddDays(-3)});
    };$r=Get-SoftwareDocument;$threats=@($r.Software.security.threats);
    Assert-Software ($r.Software.security.status -ceq 'available' -and $threats.Count -eq 2 -and $threats[0].active -and $threats[0].severity -ceq 'severe' -and -not $threats[0].actionSuccess) 'Ameaca ativa incorreta';
    Assert-Software (-not $threats[1].active -and $threats[1].actionSuccess -and $threats[1].severity -ceq 'moderate') 'Historico virou ameaca ativa';
    Assert-Software ((ConvertTo-PdvHardwareJson $r.Software) -notmatch 'SECRET_|Resources|DomainUser|ProcessName') 'Vazou dados antivirus';
  };
  Test-Software 'GetThreat sem detections informa parcial e actionSuccess nulo' {
    Reset-Software;& $module {$script:SoftwareDefender.DetectionsAvailable=$false;$script:SoftwareDefender.Threats=@(@{ThreatID=1;ThreatName='Teste';SeverityID=3;IsActive=$true});};$r=Get-SoftwareDocument;
    Assert-Software ($r.Software.security.status -ceq 'partial' -and $r.Software.security.threats[0].severity -ceq 'high' -and $null -eq $r.Software.security.threats[0].actionSuccess -and $r.Software.complete) 'Parcial tratado como sucesso ou falha global';
  };
  Test-Software 'estado ativo desconhecido e campo nome invalido nao confirmam ausencia' {
    Reset-Software;& $module {$script:SoftwareDefender.Threats=@(@{ThreatID=1;ThreatName='Teste';SeverityID=0;IsActive='false'},@{ThreatID=2;ThreatName=@('SECRET_WRONG_TYPE');SeverityID=0;IsActive=$true});};$r=Get-SoftwareDocument;
    Assert-Software ($r.Software.security.status -ceq 'partial' -and @($r.Software.security.threats).Count -eq 0 -and $r.Software.complete) 'Desconhecido virou negativo confirmado';
  };
  Test-Software 'fingerprint ignora IDs horarios e ordem incidental, detecta mudanca semantica' {
    Reset-Software;& $module {$script:SoftwareEntries+=@(@{SubKeyName='other';DisplayName='Outro';DisplayVersion='2';Publisher='Empresa';InstallDate=''});$script:SoftwareDefender.Threats=@(@{ThreatID=1;ThreatName='Teste';SeverityID=1;IsActive=$false});};$a=Get-SoftwareDocument;
    & $module {$script:SoftwareNow=$script:SoftwareNow.AddHours(1);[Array]::Reverse($script:SoftwareEntries);};$b=Get-SoftwareDocument;
    Assert-Software ($a.Software.snapshotId -cne $b.Software.snapshotId -and $a.Fingerprint -ceq $b.Fingerprint) 'Hash muda com ruido';
    & $module {$script:SoftwareDefender.Threats[0].IsActive=$true;};$c=Get-SoftwareDocument;Assert-Software ($b.Fingerprint -cne $c.Fingerprint) 'Hash perdeu status ativo';
  };
  Test-Software 'limite 500 apps explicito e documento UTF8 inteiro ate128KiB' {
    Reset-Software;& $module {$script:SoftwareEntries=@();for($i=0;$i -lt 510;$i++){$script:SoftwareEntries+=,@{SubKeyName=('app'+$i);DisplayName=('漢'*256);DisplayVersion=('v'*128);Publisher=('P'*160);InstallDate='20260101'};}};$r=Get-SoftwareDocument;$json=ConvertTo-PdvHardwareJson $r.Software;
    Assert-Software (-not $r.Software.complete -and -not $r.CoverageHealthy -and @($r.Software.apps).Count -le 500 -and [Text.Encoding]::UTF8.GetByteCount($json) -le 131072) 'Limite software nao respeitado';
    Assert-Software (($json | ConvertFrom-Json).schemaVersion -eq 1 -and (@($r.Software.warnings) -join ' ') -match '128 KiB') 'JSON recortado ou limite nao informado';
  };
  Test-Software 'limite64 antivirus prioriza ativas e informa parcial independente apps' {
    Reset-Software;& $module {$script:SoftwareDefender.Threats=@();for($i=1;$i -le 80;$i++){$script:SoftwareDefender.Threats+=,@{ThreatID=$i;ThreatName=('Threat'+$i);SeverityID=4;IsActive=($i -gt 70)};}};$r=Get-SoftwareDocument;
    Assert-Software (@($r.Software.security.threats).Count -eq 64 -and @($r.Software.security.threats | Where-Object {$_.active}).Count -eq 10 -and $r.Software.security.status -ceq 'partial' -and $r.Software.complete) 'Truncamento ocultou ativas ou invalidou apps';
  };
  Test-Software 'chave origem diferente, datas vazias e Windows32 sao tratados sem inferencias' {
    Reset-Software;& $module {$script:SoftwareOs64=$false;$script:SoftwareEntries[0].InstallDate='';};$a=Get-SoftwareDocument;$calls=& $module {return @($script:SoftwareCalls.ToArray());};
    Assert-Software (@($calls).Count -eq 2 -and $a.Software.apps[0].architecture -ceq 'x86' -and $a.Software.apps[0].reportedInstallDate -ceq '') 'Windows32 errou cobertura';
    & $module {$script:SoftwareEntries[0].SubKeyName='another-private-key';};$b=Get-SoftwareDocument;Assert-Software ($a.Software.apps[0].key -cne $b.Software.apps[0].key) 'Identidades diferentes colidiram';
  };
  Test-Software 'duplicata de cadastro nao duplica aplicativo e nao e declarada completa' {
    Reset-Software;& $module {$script:SoftwareEntries+=@($script:SoftwareEntries[0]);};$r=Get-SoftwareDocument;
    Assert-Software (@($r.Software.apps).Count -eq 1 -and -not $r.Software.complete) 'Duplicata foi contada ou ignorada sem cobertura';
  };
  Test-Software 'revisao estatica sem Win32Product ou comandos antivirus modificadores' {
    $source=[IO.File]::ReadAllText((Join-Path $directory 'PdvMonitor.Inventario.psm1'));
    Assert-Software ($source -notmatch '(?m)^\s*(Get-WmiObject|Get-CimInstance).*Win32_Product|(?m)^\s*(Start-MpScan|Remove-MpThreat|Set-MpPreference|Add-MpPreference|Start-Process)\b') 'Consulta alteraria estado';
    Assert-Software ($source -notmatch "GetValue\('(UninstallString|QuietUninstallString|InstallSource|InstallLocation|ProductID|ProductKey)'") 'Leu campos privados desnecessarios';
  };
  Test-Software 'datas de deteccao com fusos diferentes usam instante UTC e resultado da mais recente' {
    Reset-Software;
    $literalOffset=& $module {ConvertTo-PdvHardwareTime ([DateTimeOffset]::Parse('2026-10-21T12:00:00-03:00'));};
    Assert-Software ($literalOffset -ceq '2026-10-21T12:00:00.0000000-03:00') 'DateTimeOffset perdeu fuso ao ser convertido para string';
    & $module {
      $script:SoftwareDefender.Threats=@(@{ThreatID=9;ThreatName='Teste';SeverityID=1;IsActive=$false});
      $script:SoftwareDefender.Detections=@(@{ThreatID=9;ActionSuccess=$false;LastThreatStatusChangeTime=[DateTimeOffset]::Parse('2026-10-21T12:00:00-03:00')},@{ThreatID=9;ActionSuccess=$true;LastThreatStatusChangeTime=[DateTimeOffset]::Parse('2026-10-21T14:00:00+00:00')});
    };$r=Get-SoftwareDocument;
    Assert-Software ($r.Software.security.threats[0].lastSeenAt -ceq '2026-10-21T15:00:00.0000000+00:00' -and -not $r.Software.security.threats[0].actionSuccess) ('UTC/resultado divergente na fixture: '+(ConvertTo-PdvHardwareJson $r.Software.security));
    & $module {[Array]::Reverse($script:SoftwareDefender.Detections);};$reversed=Get-SoftwareDocument;
    Assert-Software ($r.Fingerprint -ceq $reversed.Fingerprint -and $reversed.Software.security.threats[0].lastSeenAt -ceq '2026-10-21T15:00:00.0000000+00:00' -and -not $reversed.Software.security.threats[0].actionSuccess) 'Ordem incidental alterou deteccao mais recente';
  };
  Test-Software 'sucesso nulo ou verdadeiro empatado nao depende da ordem e falha prevalece' {
    Reset-Software;& $module {
      $script:SoftwareDefender.Threats=@(@{ThreatID=9;ThreatName='Teste';SeverityID=1;IsActive=$false});
      $script:SoftwareDefender.Detections=@(@{ThreatID=9;ActionSuccess=$null;LastThreatStatusChangeTime=$script:SoftwareNow},@{ThreatID=9;ActionSuccess=$true;LastThreatStatusChangeTime=$script:SoftwareNow});
    };$a=Get-SoftwareDocument;& $module {[Array]::Reverse($script:SoftwareDefender.Detections);};$b=Get-SoftwareDocument;
    Assert-Software ($a.Fingerprint -ceq $b.Fingerprint -and $a.Software.security.threats[0].actionSuccess) 'Empate incidental alterou resultado';
    & $module {$script:SoftwareDefender.Detections+=,@{ThreatID=9;ActionSuccess=$false;LastThreatStatusChangeTime=$script:SoftwareNow};};$c=Get-SoftwareDocument;Assert-Software (-not $c.Software.security.threats[0].actionSuccess) 'Falha confirmada foi ocultada';
  };
  Test-Software 'catalogo indisponivel com detections disponiveis continua parcial e nao inventa ativa' {
    Reset-Software;& $module {$script:SoftwareDefender.ThreatsAvailable=$false;$script:SoftwareDefender.Detections=@(@{ThreatID=8;ActionSuccess=$false;LastThreatStatusChangeTime=$script:SoftwareNow});};$r=Get-SoftwareDocument;
    Assert-Software ($r.Software.complete -and $r.Software.security.status -ceq 'partial' -and @($r.Software.security.threats).Count -eq 0) 'Inventou classificacao de ameaca sem catalogo';
  };

} finally {}
if($failures.Count){foreach($f in $failures){Write-Output $f;};throw ($failures.Count.ToString()+' cenarios software falharam');}
Write-Output ('PASS Software: '+$script:Cases+' cenarios; '+$script:Checks+' verificacoes offline.');
