#requires -Version 5.1
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Transporte.psm1') -Force;
$module=Get-Module PdvMonitor.Transporte;
$temp=Join-Path ([IO.Path]::GetTempPath()) ('software-transport-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($temp);$script:checks=0;
function Assert-SoftwareTransport($Value,$Message){if(-not $Value){throw $Message;};$script:checks++;}
& $module {
  $script:Now=[DateTimeOffset]::Parse('2026-10-21T18:00:00Z');$script:Code=204;$script:Timeout=$false;$script:AfterPost=$null;$script:Posts=New-Object Collections.ArrayList;
  function script:Get-PdvMonitorTransportNow{return $script:Now;}
  function script:Protect-PdvMonitorToken{param($Token,$Central);return ,[byte[]]@(1,2,3);}
  function script:Unprotect-PdvMonitorToken{param($Bytes,$Central);return ('a'*64);}
  function script:Invoke-PdvMonitorHttpPost{
    param($Endpoint,$Authorization,$Body);
    if($Authorization -notmatch '^Bearer [0-9a-f-]{36}[.]a{64}$'){throw 'WrongAuthorization';}
    [void]$script:Posts.Add(@{Endpoint=$Endpoint;Body=[Text.Encoding]::UTF8.GetString($Body)});
    if($null -ne $script:AfterPost){$hook=$script:AfterPost;$script:AfterPost=$null;& $hook;}
    if($script:Timeout){throw 'MockTimeout';};return $script:Code;
  }
};
function New-SoftwareSession{
  $s=[pscustomobject]@{DataDirectory=(Join-Path $temp ([guid]::NewGuid().ToString('N')));Config=@{}};
  [void](Initialize-PdvMonitorCentral $s);
  $r=Set-PdvMonitorCentralConfig $s 'https://central.example/api/pdv-monitor/ingest' '49' 'CX4901' ([guid]::NewGuid().ToString()) ('a'*64);
  Assert-SoftwareTransport $r.Success 'Configuração de teste aceita';return $s;
}
function New-SoftwareDocument{
  return @{schemaVersion=1;snapshotId=[guid]::NewGuid().ToString();collectedAt='2026-10-21T18:00:00Z';complete=$true;coverage=@{machine=$true;currentUser=$true;otherUsers=$false;store=$false;portable=$false};apps=@(@{key='registry-1';name='App de teste';version='1';publisher='Empresa';scope='machine';architecture='x64';reportedInstallDate=''});security=@{provider='Unavailable';status='unavailable';observedAt='2026-10-21T18:00:00Z';threats=@()};warnings=@()};
}
function Reset-SoftwareBackoff($Session){$Session|Add-Member NoteProperty NextSoftwareUploadAt ([DateTimeOffset]::MinValue) -Force;}
try{
  $s=New-SoftwareSession;$doc=New-SoftwareDocument;
  $r=Set-PdvMonitorSoftwarePending $s $doc ('b'*64);Assert-SoftwareTransport $r.Queued 'Documento persiste antes do envio';
  $path=Join-Path $s.DataDirectory 'software-pendente.xml';$before=[IO.File]::ReadAllText($path);
  $again=New-SoftwareDocument;$r=Set-PdvMonitorSoftwarePending $s $again ('b'*64);
  Assert-SoftwareTransport ($r.Reason -eq 'SoftwareAlreadyQueued' -and [IO.File]::ReadAllText($path) -ceq $before) 'Mesmo estado conserva bytes e snapshotId';
  & $module {$script:Timeout=$true;};$r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport (-not $r.Success -and [IO.File]::ReadAllText($path) -ceq $before) 'Timeout conserva pendência';
  & $module {$script:Timeout=$false;};Reset-SoftwareBackoff $s;$r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport ($r.Success -and $r.Reason -eq 'SoftwareAcknowledged' -and -not [IO.File]::Exists($path)) 'Somente204 remove envio confirmado';
  $posts=& $module {return ,$script:Posts.ToArray();};
  Assert-SoftwareTransport ($posts[0].Endpoint -ceq 'https://central.example/api/pdv-monitor/agent/software') 'Endpoint derivado mantém mesma origemHTTPS';
  Assert-SoftwareTransport ($posts[0].Body -ceq $posts[1].Body) 'Reenvio usa mesmo documento';
  Assert-SoftwareTransport (-not $posts[0].Body.Contains(('a'*64))) 'Credencial não integra corpo';
  $s=New-SoftwareSession;$doc=New-SoftwareDocument;[void](Set-PdvMonitorSoftwarePending $s $doc ('b'*64));
  $path=Join-Path $s.DataDirectory 'software-pendente.xml';
  & $module {$script:Code=404;};$r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport ($r.Reason -eq 'SoftwareHttp404' -and [IO.File]::Exists($path)) 'API antiga preserva documento';
  $r=Invoke-PdvMonitorSoftwareUpload $s;Assert-SoftwareTransport ($r.Reason -eq 'BackoffActive') 'API antiga não provoca repetição imediata';
  $regular=Invoke-PdvMonitorUpload $s;Assert-SoftwareTransport ($regular.Success -and $regular.Reason -eq 'OutboxEmpty') 'Erro software não bloqueia transporte normal';
  & $module {$script:Code=204;};Reset-SoftwareBackoff $s;
  $new=New-SoftwareDocument;$new.apps[0].version='2';
  & $module {param($Session,$New);$script:AfterPost={ [void](Set-PdvMonitorSoftwarePending $Session $New ('c'*64)); }.GetNewClosure();} $s $new;
  $r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport ($r.Success -and [IO.File]::Exists($path)) 'ACK antigo não remove inventário novo';
  $pending=& $module {param($Path);Read-PdvSoftwarePending $Path;} $path;
  Assert-SoftwareTransport ($pending.SnapshotId -ceq $new.snapshotId) 'Novo snapshot permanece identificado';
  $r=Set-PdvMonitorCentralConfig $s 'https://central.example/api/pdv-monitor/ingest' '50' 'CX5001' ([guid]::NewGuid().ToString()) ('a'*64);
  Assert-SoftwareTransport ($r.Reason -eq 'PendingIdentityChange' -and $s.Config.Central.StoreId -ceq '49') 'Pendência impede trocar identificação do caixa';
  $before=[IO.File]::ReadAllText($path);$large=New-SoftwareDocument;$large.warnings=@('x'*140000);
  $r=Set-PdvMonitorSoftwarePending $s $large ('d'*64);
  Assert-SoftwareTransport (-not $r.Success -and [IO.File]::ReadAllText($path) -ceq $before) 'Excesso não recorta JSON nem substitui pendência';
  [IO.File]::WriteAllText($path,$before.Replace($pending.PayloadHash,('0'*64)));
  Reset-SoftwareBackoff $s;$n=& $module {$script:Posts.Count;};$r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport (-not $r.Success -and (& $module {$script:Posts.Count;}) -eq $n -and [IO.File]::Exists($path)) 'Hash inconsistente bloqueiaHTTP e preserva análise';
  $s=New-SoftwareSession;$doc=New-SoftwareDocument;$doc.apps=@();
  for($i=0;$i -lt 100;$i++){$doc.apps+=@(@{key=('app-'+$i);name=('&'*256);version=('&'*128);publisher=('&'*160);scope='machine';architecture='x64';reportedInstallDate=''});}
  $r=Set-PdvMonitorSoftwarePending $s $doc ('e'*64);$path=Join-Path $s.DataDirectory 'software-pendente.xml';
  Assert-SoftwareTransport ($r.Queued -and (New-Object IO.FileInfo($path)).Length -lt 262144) 'Texto válido com entidades XML não cria arquivo maior que o limite do leitor';
  Reset-SoftwareBackoff $s;$r=Invoke-PdvMonitorSoftwareUpload $s;
  Assert-SoftwareTransport ($r.Success -and -not [IO.File]::Exists($path)) 'Documento com muitos caracteres escapáveis é lido e confirmado sem travar fila';
  $posts=& $module {return ,$script:Posts.ToArray();};$last=ConvertFrom-Json $posts[$posts.Count-1].Body;
  Assert-SoftwareTransport ($last.apps[0].name -ceq ('&'*256) -and @($last.apps).Count -eq 100) 'XML protegido conserva conteúdo original e JSON completo para API';
  Write-Output ('PASS: '+$script:checks+' verificações de transporte de software, somente mocks e pastas temporárias.');
}finally{[IO.Directory]::Delete($temp,$true);}
