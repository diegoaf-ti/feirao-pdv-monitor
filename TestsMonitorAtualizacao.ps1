#requires -Version 5.1
# Somente arquivos temporários e mocks. Nenhuma rede, DPAPI ou processo é iniciado.
$ErrorActionPreference='Stop';
Import-Module (Join-Path $PSScriptRoot 'PdvMonitor.Atualizacao.psm1') -Force;
$module=Get-Module PdvMonitor.Atualizacao;
$testTempRoot=[IO.Path]::GetTempPath(); if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and [IO.Directory]::Exists('/private/tmp')) { $testTempRoot='/private/tmp'; }
$temporary=Join-Path $testTempRoot ('pdv-update-test-'+[guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0;
function Assert-Update($Condition,[string]$Message) { if (-not $Condition) { throw $Message; }; $script:Checks++; }
function Assert-Rejected([scriptblock]$Action,[string]$Message) { $rejected=$false; try { & $Action; } catch { $rejected=$true; }; Assert-Update $rejected $Message; }
try {
  $rsa=& $module { $rsa=New-PdvUpdateRsa 2048; return ,$rsa; };
  $public=Join-Path $temporary 'public.xml'; [IO.File]::WriteAllText($public,$rsa.ToXmlString($false));
  $names=& $module { return ,$script:PdvUpdateProgramFiles; };
  Assert-Update ($names.Count -eq 22 -and $names -ccontains 'PdvMonitor.Remoto.psm1' -and $names -ccontains 'PdvMonitor.Remoto.Transporte.psm1' -and $names -cnotcontains 'PdvMonitor.Remoto.Windows.psm1') 'Core possui exatamente 22 arquivos; extensao administrativa fica separada';
  Add-Type -AssemblyName System.IO.Compression;
  function New-TestArchive([string]$Path,[string[]]$Entries=$names,[string]$Version='2.0.0',[string]$OversizeName='',[string]$LinkName='') {
    $stream=[IO.File]::Create($Path); $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true);
    try {
      foreach ($name in $Entries) {
        $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal);
        if ($name -ceq $LinkName) { $entry.ExternalAttributes=([int]0xA1FF -shl 16); }
        if ($name -ceq 'monitor-version.txt') { $text=$Version; }
        elseif ($name -ceq 'atualizacoes-chave-publica.xml') { $text=$rsa.ToXmlString($false); }
        elseif ($name -ceq $OversizeName) { $text='x'*4194305; }
        else { $text='# arquivo aprovado de teste'; }
        $bytes=[Text.Encoding]::UTF8.GetBytes($text); $output=$entry.Open(); try { $output.Write($bytes,0,$bytes.Length); } finally { $output.Close(); }
      }
    } finally { $zip.Dispose(); $stream.Close(); }
  }
  function New-TestManifest([string]$Archive,[string]$Version='2.0.0',[string]$Channel='piloto',[DateTimeOffset]$Issued=[DateTimeOffset]::UtcNow,[DateTimeOffset]$Expires=([DateTimeOffset]::UtcNow.AddDays(10)),[string]$PackagePath='') {
    if (-not $PackagePath) { $PackagePath='/api/pdv-monitor/agent/update/package/'+$Version; }
    $hash=& $module { param($p); Get-PdvUpdateSha256 $p; } $Archive;
    $r=New-Object Xml.XmlDocument; $root=$r.CreateElement('Release'); $root.SetAttribute('schemaVersion','1'); [void]$r.AppendChild($root);
    $fields=@(@('Version',$Version),@('Channel',$Channel),@('PackagePath',$PackagePath),@('Sha256',$hash),@('SizeBytes',([string](New-Object IO.FileInfo($Archive)).Length)),@('IssuedAt',$Issued.ToString('o')),@('ExpiresAt',$Expires.ToString('o')));
    foreach ($field in $fields) { $element=$r.CreateElement($field[0]); $element.InnerText=$field[1]; [void]$root.AppendChild($element); }
    $bytes=[Text.Encoding]::UTF8.GetBytes($r.OuterXml); $signature=$rsa.SignData($bytes,[Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'));
    return ,[Text.Encoding]::UTF8.GetBytes('<PdvMonitorUpdate schemaVersion="1"><Payload>'+[Convert]::ToBase64String($bytes)+'</Payload><Signature>'+[Convert]::ToBase64String($signature)+'</Signature></PdvMonitorUpdate>');
  }
  $zipPath=Join-Path $temporary 'good.zip'; New-TestArchive $zipPath;
  $manifest=New-TestManifest $zipPath;
  $release=& $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $manifest $public;
  Assert-Update ($release.Newer -and $release.Version -ceq '2.0.0') 'Manifesto assinado válido é aceito';
  $notNew=& $module { param($b,$p); Test-PdvUpdateManifest $b $p '2.0.0'; } $manifest $public;
  Assert-Update (-not $notNew.Newer) 'Mesmo número não reaplica';
  $notNew=& $module { param($b,$p); Test-PdvUpdateManifest $b $p '3.0.0'; } $manifest $public;
  Assert-Update (-not $notNew.Newer) 'Downgrade é recusado';
  $outer=[xml][Text.Encoding]::UTF8.GetString($manifest); $payload=[Convert]::FromBase64String($outer.PdvMonitorUpdate.Payload); $payload[20]=$payload[20] -bxor 1; $outer.PdvMonitorUpdate.Payload=[Convert]::ToBase64String($payload);
  $tampered=[Text.Encoding]::UTF8.GetBytes($outer.OuterXml);
  Assert-Rejected { & $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $tampered $public; } 'Alteração do payload invalida assinatura';
  $bad=New-TestManifest $zipPath -Channel 'producao';
  Assert-Rejected { & $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $bad $public; } 'Canal não fixado é rejeitado';
  $bad=New-TestManifest $zipPath -PackagePath 'https://outro.exemplo/arquivo.zip';
  Assert-Rejected { & $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $bad $public; } 'URL de pacote arbitrária é rejeitada';
  $bad=New-TestManifest $zipPath -Issued ([DateTimeOffset]::UtcNow.AddDays(-2)) -Expires ([DateTimeOffset]::UtcNow.AddDays(-1));
  Assert-Rejected { & $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $bad $public; } 'Manifesto expirado é rejeitado';
  $bad=New-TestManifest $zipPath -Issued ([DateTimeOffset]::UtcNow.AddHours(1));
  Assert-Rejected { & $module { param($b,$p); Test-PdvUpdateManifest $b $p '1.0.0'; } $bad $public; } 'Manifesto futuro é rejeitado';
  Assert-Rejected { & $module { Read-PdvUpdateXml ([Text.Encoding]::UTF8.GetBytes('<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><a>&x;</a>')); }; } 'DTD/entidade externa é rejeitada';
  $trustData=Join-Path $temporary 'pinning';
  Assert-Update ((Initialize-PdvMonitorUpdateTrust $trustData $public) -ceq 'Pinned') 'Bootstrap fixa chave uma vez';
  Assert-Update ((Initialize-PdvMonitorUpdateTrust $trustData $public) -ceq 'AlreadyPinned') 'Reinstalação com mesma chave preserva pin';
  $other=& $module { $k=New-PdvUpdateRsa 2048; return ,$k; }; $otherPath=Join-Path $temporary 'other.xml'; [IO.File]::WriteAllText($otherPath,$other.ToXmlString($false)); $other.Clear();
  Assert-Rejected { Initialize-PdvMonitorUpdateTrust $trustData $otherPath; } 'Bootstrap não substitui chave fixada';
  $validOutput=Join-Path $temporary 'expanded';
  & $module { param($z,$o,$p); Expand-PdvApprovedUpdate $z $o '2.0.0' $p; } $zipPath $validOutput $public;
  Assert-Update ([IO.Directory]::GetFiles($validOutput).Length -eq $names.Length) 'ZIP aprovado é expandido por allowlist';
  Assert-Update ([IO.File]::Exists((Join-Path $validOutput 'PdvMonitor.Remoto.psm1')) -and [IO.File]::Exists((Join-Path $validOutput 'PdvMonitor.Remoto.Transporte.psm1'))) 'Os dois modulos remotos do core sao extraidos';
  $legacyNames=@($names | Where-Object { @('PdvMonitor.Remoto.psm1','PdvMonitor.Remoto.Transporte.psm1') -cnotcontains $_; });
  $legacyOutput=Join-Path $temporary 'legacy-20';
  Assert-Rejected { [Feirao.PdvApprovedZip]::Extract($zipPath,$legacyOutput,$legacyNames); } 'Leitor legado de 20 arquivos recusa core 22: primeira migracao deve ser manual';
  Assert-Update (-not [IO.Directory]::Exists($legacyOutput)) 'Recusa legada ocorre antes de extrair qualquer arquivo';
  foreach ($case in @('traversal','duplicate','symlink','bomb','config','missing','native-extension','nested-extension')) {
    $entries=@($names); $oversize=''; $link='';
    switch ($case) {
      'traversal' { $entries[0]='../monitor.xml'; }
      'duplicate' { $entries[0]='MONITOR-VERSION.TXT'; }
      'symlink' { $link=$entries[0]; }
      'bomb' { $oversize=$entries[0]; }
      'config' { $entries[0]='central-credencial.bin'; }
      'missing' { $entries=@($entries | Select-Object -Skip 1); }
      'native-extension' { $entries[0]='PdvMonitor.Remoto.Windows.psm1'; }
      'nested-extension' { $entries[0]='piloto-remoto/windows/RemoteWindowsNative.cs'; }
    }
    $archive=Join-Path $temporary ($case+'.zip'); New-TestArchive $archive $entries -OversizeName $oversize -LinkName $link;
    $destination=Join-Path $temporary ('out-'+$case);
    Assert-Rejected { & $module { param($z,$o,$p); Expand-PdvApprovedUpdate $z $o '2.0.0' $p; } $archive $destination $public; } ('ZIP bloqueado: '+$case);
  }
  Assert-Rejected { & $module { param($z,$o,$p); Expand-PdvApprovedUpdate $z $o '2.0.1' $p; } $zipPath (Join-Path $temporary 'wrong-version') $public; } 'Versão interna divergente é rejeitada';
  Assert-Rejected { & $module { param($z,$o,$p); Expand-PdvApprovedUpdate $z $o '2.0.0' $p; } $zipPath (Join-Path $temporary 'wrong-key') $otherPath; } 'Pacote não pode trocar chave pública';

  # HTTP usa WebRequest falso: cabeçalhos, TLS, tamanho, truncamento e redirecionamento.
  & $module {
    $script:WebCode=200; $script:WebLength=3; $script:WebBody=[byte[]]@(1,2,3); $script:LastWebRequest=$null;
    function script:New-PdvUpdateWebRequest {
      param($Uri);
      $request=New-Object PSObject -Property @{Method='';AllowAutoRedirect=$true;Timeout=0;ReadWriteTimeout=0;UseDefaultCredentials=$true;Headers=@{};};
      $request | Add-Member -MemberType ScriptMethod -Name GetResponse -Value {
        $response=New-Object PSObject -Property @{StatusCode=$script:WebCode;ContentLength=$script:WebLength;};
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { return (New-Object IO.MemoryStream(,$script:WebBody)); };
        $response | Add-Member -MemberType ScriptMethod -Name Close -Value {}; return $response;
      }; $script:LastWebRequest=$request; return $request;
    }
  };
  $web=& $module { Invoke-PdvUpdateHttpGet 'https://mock.exemplo/teste' 'Bearer DEMO' 10; };
  $request=& $module { return $script:LastWebRequest; };
  Assert-Update ($web.StatusCode -eq 200 -and $web.Bytes.Length -eq 3 -and -not $request.AllowAutoRedirect -and -not $request.UseDefaultCredentials -and $request.Timeout -eq 10000 -and $request.Headers.Authorization -ceq 'Bearer DEMO') 'HTTP mantém validação padrão e desativa redirects/default credentials';
  & $module { $script:WebCode=302; };
  Assert-Rejected { & $module { Invoke-PdvUpdateHttpGet 'https://mock.exemplo/teste' 'Bearer DEMO' 10; }; } 'Redirect não é seguido';
  & $module { $script:WebCode=200; $script:WebLength=100; };
  Assert-Rejected { & $module { Invoke-PdvUpdateHttpGet 'https://mock.exemplo/teste' 'Bearer DEMO' 10; }; } 'ContentLength acima do limite é recusado';
  & $module { $script:WebLength=-1; $script:WebBody=[byte[]]@(1,2,3,4); };
  Assert-Rejected { & $module { Invoke-PdvUpdateHttpGet 'https://mock.exemplo/teste' 'Bearer DEMO' 3; }; } 'Corpo chunked acima do limite é recusado';
  & $module { $script:WebLength=10; $script:WebBody=[byte[]]@(1,2,3); };
  $partial=Join-Path $temporary 'partial.zip';
  Assert-Rejected { & $module { param($p); Invoke-PdvUpdateHttpGet 'https://mock.exemplo/teste' 'Bearer DEMO' 10 $p; } $partial; } 'Download truncado é recusado';
  Assert-Update (-not [IO.File]::Exists($partial)) 'Download parcial não fica disponível para aplicação';

  # Daqui em diante, rede, segredo e processos são apenas mocks em escopo do módulo.
  & $module {
    $script:Requests=New-Object Collections.ArrayList; $script:StartCount=0; $script:StopCount=0; $script:Healthy=$true; $script:HttpCode=200;
    function script:Get-PdvUpdateAuthorization { param($Session); return 'Bearer MOCK-NAO-SECRETO'; }
    function script:Invoke-PdvUpdateHttpGet {
      param($Uri,$Authorization,$MaximumBytes,$Destination='');
      [void]$script:Requests.Add((New-Object PSObject -Property @{Uri=$Uri;Authorization=$Authorization;MaximumBytes=$MaximumBytes;}));
      if ($Destination) { [IO.File]::Copy($script:Zip,$Destination); return (New-Object PSObject -Property @{StatusCode=200;Bytes=@();}); }
      return (New-Object PSObject -Property @{StatusCode=$script:HttpCode;Bytes=$script:Manifest;});
    }
    function script:Start-PdvUpdateHelperProcess { param($Script,$Data,$Program,$ParentPid); $script:StartCount++; return (New-Object PSObject -Property @{Id=999;}); }
    function script:Wait-PdvUpdateParent { param($ParentProcessId); return $true; }
    function script:Start-PdvUpdatedMonitorProcess {
      param($Program,$Data); $script:StartCount++; $process=New-Object PSObject -Property @{Id=999;HasExited=$false;StartTime=[DateTime]::UtcNow;};
      $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}; return $process;
    }
    function script:Wait-PdvUpdateHealth { param($Paths,$Process,$Token,$Version,$Hash); return $script:Healthy; }
    function script:Stop-PdvUpdatedMonitorProcess { param($Process,$ExpectedStart); $script:StopCount++; $Process.HasExited=$true; return $true; }
  };
  & $module { param($m,$z); $script:Manifest=$m; $script:Zip=$z; } $manifest $zipPath;
  function New-TestSession([string]$Name) {
    $data=Join-Path $temporary $Name; [void][IO.Directory]::CreateDirectory((Join-Path $data 'programa'));
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path (Join-Path $data 'programa') $name),'# versao anterior conhecida'); }
    [IO.File]::WriteAllText((Join-Path $data 'programa/monitor-version.txt'),'1.0.0');
    [IO.File]::WriteAllText((Join-Path $data 'central-credencial.bin'),'DPAPI-DEMO-NAO-SECRETO');
    [IO.File]::WriteAllText((Join-Path $data 'IniciarMonitorInstalado.ps1'),'# bootstrap antigo conhecido');
    Initialize-PdvMonitorUpdateTrust $data $public | Out-Null;
    return [pscustomobject]@{DataDirectory=$data;TickBusy=$false;LoggingHealthy=$true;Config=@{Central=@{Enabled=$true;Endpoint='https://central.exemplo/api/pdv-monitor/ingest';AgentId='11111111-1111-1111-1111-111111111111';StoreId='49';Terminal='CX4901';}}};
  }
  $session=New-TestSession 'normal'; $program=Join-Path $session.DataDirectory 'programa';
  $result=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $false;
  Assert-Update ($result.Reason -ceq 'UpdateDisabled' -and (& $module { $script:Requests.Count; }) -eq 0) 'Desabilitado não acessa rede';
  $result=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $true;
  Assert-Update ($result.Staged -and $result.Version -ceq '2.0.0') 'Manifesto+pacote válidos são preparados';
  Assert-Update (([IO.File]::ReadAllText((Join-Path $program 'monitor-version.txt'))) -ceq '1.0.0') 'Preparar não altera programa em execução';
  $requests=& $module { return ,$script:Requests.ToArray(); };
  Assert-Update ($requests.Count -eq 2 -and $requests[0].Uri -ceq 'https://central.exemplo/api/pdv-monitor/agent/update?version=1.0.0&channel=piloto' -and $requests[1].Uri -ceq 'https://central.exemplo/api/pdv-monitor/agent/update/package/2.0.0' -and $requests[1].Authorization -ceq 'Bearer MOCK-NAO-SECRETO') 'Manifesto e ZIP usam somente origem configurada e autenticação';
  $result=Start-PdvMonitorUpdateApply $session $program -Enabled $true -OperationsIdle $false;
  Assert-Update ($result.Reason -ceq 'UpdateWaitingMonitorIdle') 'Não reinicia monitor ocupado';
  $session.TickBusy=$true; $result=Start-PdvMonitorUpdateApply $session $program -Enabled $true -OperationsIdle $true;
  Assert-Update ($result.Reason -ceq 'UpdateWaitingMonitorIdle') 'Tick ativo impede atualização'; $session.TickBusy=$false;
  $result=Start-PdvMonitorUpdateApply $session (Join-Path $temporary 'portatil') -Enabled $true -OperationsIdle $true;
  Assert-Update ($result.Reason -ceq 'UpdateProgramMustBeInstalled') 'Diretório portátil não pode ser substituído';
  # Arquivos do executor de teste, sem executar seu conteúdo.
  foreach ($name in @('AplicarAtualizacao.ps1','PdvMonitor.Atualizacao.psm1')) { [IO.File]::WriteAllText((Join-Path $program $name),'# mock'); }
  $result=Start-PdvMonitorUpdateApply $session $program -Enabled $true -OperationsIdle $true;
  Assert-Update $result.Started 'Executor é lançado com monitor ocioso';
  $result=& $module { param($d,$p); Invoke-PdvUpdateApplyInternal $d $p 123; } $session.DataDirectory $program;
  Assert-Update ($result.Success -and $result.Reason -ceq 'UpdateInstalled' -and ([IO.File]::ReadAllText((Join-Path $program 'monitor-version.txt'))) -ceq '2.0.0') 'Versão aprovada substitui só programa e confirma saúde';
  Assert-Update (([IO.File]::ReadAllText((Join-Path $session.DataDirectory 'central-credencial.bin'))) -ceq 'DPAPI-DEMO-NAO-SECRETO') 'Credencial fora do programa é preservada';
  Assert-Update ([IO.File]::Exists((Join-Path $session.DataDirectory 'atualizacoes/backup/MonitorPdv.ps1'))) 'Backup da versão anterior é preservado';
  Assert-Update ([IO.Directory]::GetFiles((Join-Path $session.DataDirectory 'atualizacoes/backup')).Length -eq 22 -and [IO.File]::Exists((Join-Path $program 'PdvMonitor.Remoto.Transporte.psm1'))) 'Backup e candidata mantem o core completo de 22 arquivos';
  Assert-Update (([IO.File]::ReadAllText((Join-Path $session.DataDirectory 'IniciarMonitorInstalado.ps1'))) -ceq '# arquivo aprovado de teste') 'Bootstrap recebe versão aprovada somente após saúde confirmada';

  $session=New-TestSession 'rollback'; $program=Join-Path $session.DataDirectory 'programa';
  $null=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $true;
  & $module { $script:Healthy=$false; };
  $result=& $module { param($d,$p); Invoke-PdvUpdateApplyInternal $d $p 123; } $session.DataDirectory $program;
  Assert-Update ($result.Reason -ceq 'UpdateRolledBack' -and ([IO.File]::ReadAllText((Join-Path $program 'monitor-version.txt'))) -ceq '1.0.0') 'Sem saúde confirmada, versão anterior é restaurada';
  Assert-Update (([IO.File]::ReadAllText((Join-Path $session.DataDirectory 'IniciarMonitorInstalado.ps1'))) -ceq '# bootstrap antigo conhecido') 'Rollback mantém bootstrap estável anterior';
  Assert-Update ((& $module { $script:StopCount; }) -eq 1 -and ([IO.File]::ReadAllText((Join-Path $program 'MonitorPdv.ps1'))) -ceq '# versao anterior conhecida') 'Rollback para apenas filho simulado e restaura arquivo anterior';
  $result=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $true;
  Assert-Update ($result.Reason -ceq 'UpdateVersionPreviouslyRolledBack') 'Versão malsucedida não entra em repetição infinita';
  $healthSession=New-TestSession 'health'; $healthProgram=Join-Path $healthSession.DataDirectory 'programa';
  $null=Invoke-PdvMonitorUpdateCheck $healthSession $healthProgram -Enabled $true;
  [IO.File]::WriteAllText((Join-Path $healthProgram 'monitor-version.txt'),'2.0.0');
  $hash=& $module { param($z); Get-PdvUpdateSha256 $z; } $zipPath;
  $pending='<Health token="'+('a'*32)+'" version="2.0.0" hash="'+$hash+'" />';
  [IO.File]::WriteAllText((Join-Path $healthSession.DataDirectory 'atualizacoes/saude-pendente.xml'),$pending);
  Assert-Update (-not (Write-PdvMonitorUpdateHealth $healthSession $healthProgram -TickHealthy $false)) 'Abrir processo sem tick saudável não confirma atualização';
  $healthSession.LoggingHealthy=$false;
  Assert-Update (-not (Write-PdvMonitorUpdateHealth $healthSession $healthProgram -TickHealthy $true)) 'Falha de log impede confirmação de saúde';
  $healthSession.LoggingHealthy=$true;
  Assert-Update (Write-PdvMonitorUpdateHealth $healthSession $healthProgram -TickHealthy $true) 'Tick saudável confirma versão e hash assinados';
  $pending=$pending.Replace($hash,('0'*64)); [IO.File]::WriteAllText((Join-Path $healthSession.DataDirectory 'atualizacoes/saude-pendente.xml'),$pending);
  Assert-Update (-not (Write-PdvMonitorUpdateHealth $healthSession $healthProgram -TickHealthy $true)) 'Hash da versão incorreto não confirma saúde';

  $session.Config.Central.Endpoint='http://central.exemplo/api/pdv-monitor/ingest';
  $result=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $true;
  Assert-Update ($result.Reason -ceq 'UpdateEndpointInvalid') 'HTTP inseguro é rejeitado antes da rede';
  $session.Config.Central.Endpoint='https://central.exemplo/api/pdv-monitor/ingest';
  & $module { $script:HttpCode=204; };
  $result=Invoke-PdvMonitorUpdateCheck $session $program -Enabled $true;
  Assert-Update ($result.Success -and -not $result.Staged) '204 não altera instalação';
  # Simula queda de energia entre renomear programa para backup e mover candidata.
  . (Join-Path $PSScriptRoot 'IniciarMonitorInstalado.ps1');
  $script:BootstrapStarts=0;
  function Start-PdvStableMonitor { param($ProgramDirectory,$DataDirectory); $script:BootstrapStarts++; }
  function New-PowerGapFixture([string]$Name) {
    $s=New-TestSession $Name; $p=Join-Path $s.DataDirectory 'programa'; $u=Join-Path $s.DataDirectory 'atualizacoes'; [void][IO.Directory]::CreateDirectory($u);
    & $module { param($p,$d); $paths=Get-PdvUpdatePaths $d; Write-PdvUpdateBackupManifest $p $paths '2.0.0'; Write-PdvUpdateApplyState $paths 'applying' '2.0.0' 'UpdateReplacingMonitor'; } $p $s.DataDirectory;
    [IO.Directory]::Move($p,(Join-Path $u 'backup'));
    [IO.File]::WriteAllText((Join-Path $u 'saude-pendente.xml'),'<Health />');
    return $s;
  }
  $s=New-PowerGapFixture 'powergap-valid';
  $status=Invoke-PdvStableMonitorBootstrap $s.DataDirectory;
  Assert-Update ($status -ceq 'Recovered' -and [IO.File]::Exists((Join-Path $s.DataDirectory 'programa/MonitorPdv.ps1'))) 'Bootstrap estável restaura backup íntegro após queda entre renomeações';
  Assert-Update (-not [IO.File]::Exists((Join-Path $s.DataDirectory 'atualizacoes/saude-pendente.xml')) -and [IO.File]::ReadAllText((Join-Path $s.DataDirectory 'atualizacoes/versao-rejeitada.txt')).Trim() -ceq '2.0.0') 'Recuperação limpa saúde pendente e quarentena versão interrompida';
  Assert-Update ($script:BootstrapStarts -eq 1) 'Só inicia o monitor depois de validar e restaurar';
  Assert-Update ([IO.Directory]::GetFiles((Join-Path $s.DataDirectory 'programa')).Length -eq 22 -and [IO.File]::Exists((Join-Path $s.DataDirectory 'programa/PdvMonitor.Remoto.psm1'))) 'Recuperacao apos interrupcao inclui ambos os modulos remotos';
  $s=New-PowerGapFixture 'powergap-lock';
  $lock=New-Object IO.FileStream((Join-Path $s.DataDirectory 'atualizacoes/aplicando.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);
  try { Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Bootstrap não concorre com executor ainda ativo'; } finally { $lock.Close(); }
  Assert-Update (-not [IO.Directory]::Exists((Join-Path $s.DataDirectory 'programa')) -and $script:BootstrapStarts -eq 1) 'Lock preserva backup sem executar scripts';
  $s=New-PowerGapFixture 'powergap-corrupt'; [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'atualizacoes/backup/MonitorPdv.ps1'),'# CORROMPIDO');
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Backup alterado não pode ser executado';
  $s=New-PowerGapFixture 'powergap-remote-corrupt'; [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'atualizacoes/backup/PdvMonitor.Remoto.Transporte.psm1'),'# CORROMPIDO');
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Transporte remoto corrompido impede restauracao e execucao';
  $s=New-PowerGapFixture 'powergap-extra'; [IO.File]::WriteAllText((Join-Path $s.DataDirectory 'atualizacoes/backup/arquivo-extra.ps1'),'# desconhecido');
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Arquivo extra no backup invalida recuperação';
  $s=New-PowerGapFixture 'powergap-metadata'; [IO.File]::Delete((Join-Path $s.DataDirectory 'atualizacoes/backup-manifest.xml'));
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Sem metadados prévios não inventa recuperação';
  $s=New-PowerGapFixture 'powergap-journal'; $j=Join-Path $s.DataDirectory 'atualizacoes/estado.xml'; [IO.File]::WriteAllText($j,([IO.File]::ReadAllText($j)).Replace('applying','installed'));
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Journal sem troca em andamento não autoriza recuperar';
  $s=New-PowerGapFixture 'powergap-path'; $meta=Join-Path $s.DataDirectory 'atualizacoes/backup-manifest.xml'; [IO.File]::WriteAllText($meta,([IO.File]::ReadAllText($meta)).Replace('name="MonitorPdv.ps1"','name="../MonitorPdv.ps1"'));
  Assert-Rejected { Invoke-PdvStableMonitorBootstrap $s.DataDirectory; } 'Metadado com caminho relativo não permite execução';
  Assert-Update ($script:BootstrapStarts -eq 1) 'Nenhum backup inválido inicia um monitor';
  # Erro ao substituir apenas o bootstrap não derruba a versão já saudável.
  & $module { $script:Healthy=$true; $script:HttpCode=200; };
  $copySession=New-TestSession 'bootstrap-copy-failure'; $copyProgram=Join-Path $copySession.DataDirectory 'programa';
  $null=Invoke-PdvMonitorUpdateCheck $copySession $copyProgram -Enabled $true;
  & $module { function script:Update-PdvStableBootstrap { param($Program,$Paths); throw 'Erro de copia simulado'; } };
  $result=& $module { param($d,$p); Invoke-PdvUpdateApplyInternal $d $p 123; } $copySession.DataDirectory $copyProgram;
  $state=[xml][IO.File]::ReadAllText((Join-Path $copySession.DataDirectory 'atualizacoes/estado.xml'));
  Assert-Update ($result.Success -and $state.Update.reason -ceq 'UpdateHealthConfirmedBootstrapRetained') 'Falha na cópia do bootstrap registra retenção sem reverter monitor saudável';
  Assert-Update (([IO.File]::ReadAllText((Join-Path $copySession.DataDirectory 'IniciarMonitorInstalado.ps1'))) -ceq '# bootstrap antigo conhecido') 'Falha de cópia mantém iniciador anterior';
  Write-Host ('PASS: '+$script:Checks+' verificações de atualização assinada, ZIP seguro, preparação, aplicação, saúde e rollback. Somente mocks; sem rede, DPAPI ou processos reais.');
} finally { if ($null -ne $rsa) { $rsa.Clear(); }; Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue; }
