#requires -Version 5.1
# Fixtures offline. Nao acessa API, Windows, DPAPI real nem inicia processos.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Remoto.Transporte.psm1') -Force;
$module=Get-Module PdvMonitor.Remoto.Transporte;
$broker=& $module {$script:remoteBrokerModule;};$central=& $module {$script:remoteCentralModule;};
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('pdv-remote-http-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
$script:Cases=0;$script:Checks=0;$failures=New-Object 'Collections.Generic.List[string]';$script:CaseId=0;
function Assert-RemoteHttp($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Test-RemoteHttp([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
function Assert-RemoteHttpThrows([scriptblock]$Body,[string]$Reason){$script:Checks++;try{& $Body | Out-Null;}catch{if($_.Exception.Message -ceq $Reason){return;};throw ('Erro inesperado '+$_.Exception.Message);};throw ('Faltou '+$Reason);}
& $central {function script:Unprotect-PdvMonitorToken {param($Bytes,$Central);$script:CredentialReads++;return ('a'*64);}}
& $module {
  function script:Invoke-PdvRemoteBoundedHttp {
    param($Endpoint,$Authorization,$Method,$Body);
    [void]$script:WireCalls.Add(@{Endpoint=$Endpoint;Authorization=$Authorization;Method=$Method;Body=[Text.Encoding]::UTF8.GetString($Body)});
    if($script:WireReplies.Count -eq 0){throw 'PRIVATE-SECRET-TRANSPORT';};$reply=$script:WireReplies.Dequeue();if($reply -is [string]){throw $reply;};return $reply;
  }
  function script:Get-PdvRemoteControllerNow {return $script:ControllerNow;}
}
& $broker {
  function script:Get-PdvRemoteNow {return $script:BrokerNow;}
  function script:Get-PdvRemoteInteractiveEvidence {return @{Supported=$true;Interactive=$true;Unlocked=$script:Unlocked;WindowsSessionId='1';UserSid='S-1-5-21-1001';HostInstanceId='22222222-2222-4222-8222-222222222222'};}
  function script:Get-PdvRemotePlatformEvidence {return @{Detected=$true;WindowsVersion='10.0.19045';Architecture='x64';CompatibilityVerified=$true};}
}
$fixture=@'
function Get-PdvMonitorRemoteWindowsTransportSnapshot {param($Transport);return @{LocalProcessesStopped=$Transport.Stopped;CloseRequested=$Transport.CloseRequested;Stage=$Transport.Stage;SessionId=$Transport.SessionId;Reason=$Transport.Reason};}
function Start-PdvMonitorRemoteWindowsTransport {param($Transport,$BrokerContext,$Lease);if($BrokerContext.Stage -cne 'authorized'){throw 'NotAuthorized';};$Transport.Starts++;$Transport.LastExpiry=$Lease.ExpiresAt;$Transport.Stopped=$false;$Transport.Stage='running';}
function Update-PdvMonitorRemoteWindowsTransport {param($Transport,$Lease);$Transport.Heartbeats++;}
function Stop-PdvMonitorRemoteWindowsTransport {param($Transport,$Reason);$Transport.Stops++;if($Transport.FailStop){$Transport.Stopped=$false;throw 'PRIVATE-PID';};$Transport.Stopped=$true;$Transport.Stage='closed';}
function Resolve-PdvMonitorRemoteWindowsInterruptedTransport {param($Transport,$SessionId,$CentralStatus);if($Transport.Stage -cne 'interrupted' -or $SessionId -cne $Transport.SessionId -or @('closed','ended') -cnotcontains $CentralStatus){throw 'NoConfirmation';};$Transport.Resolved++;$Transport.Stage='closed';}
function Show-PdvMonitorRemoteWindowsConsent {param($Prompt);return @{SessionId=$Prompt.SessionId;ChallengeId=$Prompt.ChallengeId;Decision='approved';PaymentIdleConfirmed=$true};}
Export-ModuleMember -Function Resolve-PdvMonitorRemoteWindowsInterruptedTransport,Get-PdvMonitorRemoteWindowsTransportSnapshot,Start-PdvMonitorRemoteWindowsTransport,Update-PdvMonitorRemoteWindowsTransport,Stop-PdvMonitorRemoteWindowsTransport,Show-PdvMonitorRemoteWindowsConsent;
'@
$fixturePath=Join-Path $temporary 'RemoteWindowsFixture.psm1';[IO.File]::WriteAllText($fixturePath,$fixture,(New-Object Text.UTF8Encoding($true)));$windows=Import-Module $fixturePath -PassThru;
function New-RemoteHttpCase {
  $script:CaseId++;& $central {$script:CredentialReads=0;};$path=Join-Path $temporary ('case'+$script:CaseId);[void][IO.Directory]::CreateDirectory($path);[IO.File]::WriteAllBytes((Join-Path $path 'central-credencial.bin'),[byte[]]@(1,2,3));
  & $module {$script:WireReplies=New-Object Collections.Queue;$script:WireCalls=New-Object Collections.ArrayList;$script:ControllerNow=[DateTimeOffset]::Parse('2026-10-21T16:00:00Z');}
  & $broker {$script:BrokerNow=[DateTimeOffset]::Parse('2026-10-21T16:00:00Z');$script:Unlocked=$true;}
  return (New-Object PSObject -Property @{DataDirectory=$path;Config=@{Central=@{Enabled=$true;AgentId='11111111-1111-4111-8111-111111111111';StoreId='49';Terminal='CX4901';Endpoint='https://test.invalid/api/pdv-monitor/ingest';}}});
}
function Add-RemoteHttpReply([string]$Xml,[int]$Status=200){& $module {param($Text,$Code);$script:WireReplies.Enqueue(@{Status=$Code;Bytes=[Text.Encoding]::UTF8.GetBytes($Text);ContentType='application/xml'});} $Xml $Status;}
function New-RemoteHttpRequestXml {
  return ('<PdvRemoteRequest><SessionId>33333333-3333-4333-8333-333333333333</SessionId><AgentId>11111111-1111-4111-8111-111111111111</AgentId><RequestId>33333333-3333-4333-8333-333333333333</RequestId><RequestedAt>2026-10-21T16:00:00Z</RequestedAt><ExpiresAt>2026-10-21T16:02:00Z</ExpiresAt><SessionMaxSeconds>900</SessionMaxSeconds><Mode>control</Mode><TechnicianId>42</TechnicianId><TechnicianName>Tecnico fixture</TechnicianName><Reason>Investigar dispositivo de impressao</Reason><Nonce>'+('A'*43)+'</Nonce></PdvRemoteRequest>');
}
function New-RemoteHttpSessionXml([string]$Status='approved',[string]$Id='33333333-3333-4333-8333-333333333333') {return ('<PdvRemoteSession><Id>'+$Id+'</Id><Status>'+$Status+'</Status><ExpiresAt>2026-10-21T16:15:00Z</ExpiresAt><ConsentExpiresAt>2026-10-21T16:02:00Z</ConsentExpiresAt></PdvRemoteSession>');}
function New-RemoteHttpLeaseXml([string]$State='pending') {return ('<PdvRemoteLease schemaVersion="1"><SessionId>33333333-3333-4333-8333-333333333333</SessionId><AgentId>11111111-1111-4111-8111-111111111111</AgentId><RepeaterId>4901</RepeaterId><CertificateSha256>'+('b'*64)+'</CertificateSha256><ExpiresAt>2026-10-21T16:15:00Z</ExpiresAt><State>'+$State+'</State></PdvRemoteLease>');}
function New-RemoteHttpController($Session) {
  $context=& $broker {param($Path,$AgentId);New-PdvMonitorRemoteContext $Path $AgentId $true;} $Session.DataDirectory $Session.Config.Central.AgentId;
  return @{Enabled=$true;Reason='';Broker=$context;Windows=@{Stopped=$true;CloseRequested=$false;Starts=0;Stops=0;Heartbeats=0;Resolved=0;Stage='idle';SessionId='33333333-3333-4333-8333-333333333333';Reason='';FailStop=$false;};WindowsModule=$windows;NextPollAt=[DateTimeOffset]::MinValue;Lease=$null;LeaseVerifiedAt=$null;PromptBusy=$false;Paused=$false;Busy=$false;Stopping=$false;};
}
function Invoke-RemoteHttpWork($Controller,$Session) {
  $Controller.NextPollAt=[DateTimeOffset]::MinValue;$work=Get-PdvMonitorRemoteWork $Controller;if($null -eq $work){throw 'Nenhum work';}
  $result=Invoke-PdvMonitorRemoteExchange $Session $work.Operation $work.Payload;Complete-PdvMonitorRemoteWork $Controller $work $result;return $work.Operation;
}
function Start-RemoteHttpAuthorized($Session,$Controller) {
  Add-RemoteHttpReply (New-RemoteHttpRequestXml);[void](Invoke-RemoteHttpWork $Controller $Session);Update-PdvMonitorRemoteLocal $Controller;
  Add-RemoteHttpReply (New-RemoteHttpSessionXml);[void](Invoke-RemoteHttpWork $Controller $Session);
}
try{
  Test-RemoteHttp 'HTTPS autenticado reutiliza identidade e token; XML produz tipos fechados' {
    $session=New-RemoteHttpCase;Add-RemoteHttpReply (New-RemoteHttpRequestXml);$result=Invoke-PdvMonitorRemoteExchange $session 'Request';
    Assert-RemoteHttp ($result.Success -and $result.Value.SessionMaxSeconds -is [int] -and $result.Value.SessionMaxSeconds -eq 900) 'Contrato request nao tipado.';
    $call=& $module {$script:WireCalls[0];};Assert-RemoteHttp ($call.Endpoint -ceq 'https://test.invalid/api/pdv-monitor/agent/remote/request' -and $call.Method -ceq 'GET' -and $call.Authorization -ceq ('Bearer '+$session.Config.Central.AgentId+'.'+('a'*64))) 'Identidade/rota divergiu.';
    Assert-RemoteHttp ($call.Endpoint -notmatch 'nonce|token|sessionId|\?' -and $call.Body -ceq '') 'Segredo na URL/GET.';
    Assert-RemoteHttp (($result | ConvertTo-Json -Depth 5) -notmatch ('a'*64)) 'Retorno incluiu credencial.';
  }
  Test-RemoteHttp '204 e erros HTTP nao carregam corpo nem detalhes sensiveis' {
    $session=New-RemoteHttpCase;Add-RemoteHttpReply '' 204;$empty=Invoke-PdvMonitorRemoteExchange $session 'Request';Assert-RemoteHttp ($empty.Success -and $null -eq $empty.Value) '204 nao aceito.';
    foreach($code in @(301,302,307,308,401,403,404,429,500,503)){Add-RemoteHttpReply 'PRIVATE-ERROR-BODY' $code;$result=Invoke-PdvMonitorRemoteExchange $session 'Request';Assert-RemoteHttp (-not $result.Success -and $result.Status -eq $code -and ($result | ConvertTo-Json) -notmatch 'PRIVATE') 'HTTP nao foi redigido/rejeitado.';}
    & $module {$script:WireReplies.Enqueue('PRIVATE-URL-TOKEN');};$failed=Invoke-PdvMonitorRemoteExchange $session 'Request';Assert-RemoteHttp (-not $failed.Success -and $failed.Reason -ceq 'RemoteExchangeFailed' -and ($failed | ConvertTo-Json) -notmatch 'PRIVATE') 'Excecao vazou.';
  }
  Test-RemoteHttp 'parser rejeita DTD, namespace, duplicacao, CDATA, atributos e payload expansivo' {
    $session=New-RemoteHttpCase;$valid=New-RemoteHttpRequestXml;
    $variants=@(('<!DOCTYPE x [<!ENTITY x SYSTEM "file:///PRIVATE">]>'+$valid),$valid.Replace('<PdvRemoteRequest>','<PdvRemoteRequest xmlns="urn:evil">'),$valid.Replace('<Mode>control</Mode>','<Mode>control</Mode><Mode>control</Mode>'),$valid.Replace('<Mode>control</Mode>','<Mode><![CDATA[control]]></Mode>'),$valid.Replace('<Mode>','<Mode extra="1">'),('x'*8193),$valid.Replace('<TechnicianId>42</TechnicianId>','<TechnicianId><nested>42</nested></TechnicianId>'));
    foreach($xml in $variants){Add-RemoteHttpReply $xml;$result=Invoke-PdvMonitorRemoteExchange $session 'Request';Assert-RemoteHttp (-not $result.Success -and $null -eq $result.Value) 'XML invasivo aceito.';}
  }
  Test-RemoteHttp 'rejeita rota/comando arbitrarios e identidade de outra maquina/sessao' {
    $session=New-RemoteHttpCase;foreach($operation in @('Run','Start','https://evil.invalid','../lease')){$result=Invoke-PdvMonitorRemoteExchange $session $operation @{Executable='PRIVATE'};Assert-RemoteHttp (-not $result.Success) 'Operacao arbitraria aceita.';}
    $result=Invoke-PdvMonitorRemoteExchange $session 'Closed' @{sessionId='33333333-3333-4333-8333-333333333333';status='ready'};Assert-RemoteHttp (-not $result.Success) 'Ready aceito como closed.';
    Add-RemoteHttpReply ((New-RemoteHttpRequestXml).Replace($session.Config.Central.AgentId,'44444444-4444-4444-8444-444444444444'));$result=Invoke-PdvMonitorRemoteExchange $session 'Request';Assert-RemoteHttp (-not $result.Success) 'Outro agente aceito.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'approved' '44444444-4444-4444-8444-444444444444');$result=Invoke-PdvMonitorRemoteExchange $session 'Session' @{sessionId='33333333-3333-4333-8333-333333333333'};Assert-RemoteHttp (-not $result.Success) 'Outra sessao aceita.';
  }
  Test-RemoteHttp 'ciclo request consent lease heartbeat e fechamento exige confirmacoes independentes' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Add-RemoteHttpReply (New-RemoteHttpRequestXml);[void](Invoke-RemoteHttpWork $controller $session);
    Assert-RemoteHttp ($controller.Broker.Stage -ceq 'requested' -and $controller.Windows.Starts -eq 0) 'Pedido iniciou processo.';
    Update-PdvMonitorRemoteLocal $controller;Assert-RemoteHttp ($controller.Broker.Stage -ceq 'consent_approved' -and $controller.Windows.Starts -eq 0) 'Consentimento local iniciou processo.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml);Assert-RemoteHttp ((Invoke-RemoteHttpWork $controller $session) -ceq 'Consent') 'Nao enviou consentimento.';
    Assert-RemoteHttp ($controller.Broker.Stage -ceq 'authorized' -and $controller.Windows.Starts -eq 0) 'ACK iniciou sem lease.';
    Add-RemoteHttpReply (New-RemoteHttpLeaseXml);[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Windows.Starts -eq 1 -and $controller.Windows.Heartbeats -eq 0) 'Nao iniciou com lease.';
    Update-PdvMonitorRemoteLocal $controller;Update-PdvMonitorRemoteLocal $controller;Assert-RemoteHttp ($controller.Windows.Heartbeats -eq 0) 'Timer sem GET renovou watchdog.';
    Add-RemoteHttpReply (New-RemoteHttpLeaseXml 'connected');[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Windows.Starts -eq 1 -and $controller.Windows.Heartbeats -eq 1) 'Heartbeat reabriu sessao.';
    $snapshot=Get-PdvMonitorRemoteControllerSnapshot $controller;Assert-RemoteHttp ($snapshot.GatewayState -ceq 'connected' -and -not $snapshot.Contains('Connected')) 'TCP anunciado como tela pronta.';
    Update-PdvMonitorRemoteLocal $controller $true $true;Assert-RemoteHttp ($controller.Broker.Stage -ceq 'close_required' -and $controller.Windows.Stopped) 'Pausa nao encerrou local.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'ending');[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Broker.Stage -ceq 'close_required') 'Ending tratado como confirmado.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'ended');[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Broker.Stage -ceq 'closed' -and -not $controller.Busy) 'Fechamento nao concluiu.';
    $disk=[IO.File]::ReadAllText((Join-Path $session.DataDirectory 'remoto-consentimentos.xml'));foreach($secret in @(('A'*43),('a'*64),'Tecnico fixture','Investigar dispositivo de impressao')){Assert-RemoteHttp (-not $disk.Contains($secret) -and ($snapshot | ConvertTo-Json) -notmatch [Regex]::Escape($secret)) 'Journal/snapshot vazou segredo.';}
  }
  Test-RemoteHttp 'falha HTTP apos aprovacao interrompe e nao repete consentimento' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Add-RemoteHttpReply (New-RemoteHttpRequestXml);[void](Invoke-RemoteHttpWork $controller $session);Update-PdvMonitorRemoteLocal $controller;Add-RemoteHttpReply 'PRIVATE' 503;[void](Invoke-RemoteHttpWork $controller $session);
    Assert-RemoteHttp ($controller.Broker.Stage -ceq 'close_required' -and $controller.Broker.Active.Request.Nonce -ceq '' -and $controller.Windows.Starts -eq 0) 'Falha incerta reteve aprovacao.';
    $controller.NextPollAt=[DateTimeOffset]::MinValue;$next=Get-PdvMonitorRemoteWork $controller;Assert-RemoteHttp ($next.Operation -ceq 'Closed' -and -not $next.Payload.Contains('nonce')) 'Repetiu aprovacao apos erro.';
  }
  Test-RemoteHttp 'lease invalido, indisponivel ou console bloqueada fecham sem nova tentativa' {
    foreach($kind in @('unavailable','extended','wrongsession','closed','locked')){
      $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Start-RemoteHttpAuthorized $session $controller;
      switch($kind){'unavailable'{Add-RemoteHttpReply '' 204;}'extended'{Add-RemoteHttpReply ((New-RemoteHttpLeaseXml).Replace('16:15:00','16:16:00'));}'wrongsession'{Add-RemoteHttpReply ((New-RemoteHttpLeaseXml).Replace('33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444'));}'closed'{Add-RemoteHttpReply (New-RemoteHttpLeaseXml 'closed');}'locked'{Add-RemoteHttpReply (New-RemoteHttpLeaseXml);}}
      [void](Invoke-RemoteHttpWork $controller $session);if($kind -ceq 'locked'){& $broker {$script:Unlocked=$false;};Update-PdvMonitorRemoteLocal $controller;}
      Assert-RemoteHttp ($controller.Broker.Stage -ceq 'close_required' -and $controller.Windows.Stopped) ('Falha manteve transporte '+$kind);
    }
  }
  Test-RemoteHttp 'reinicio resolve pendencia por closed autenticado; nunca reaprova' {
    $session=New-RemoteHttpCase;$first=New-RemoteHttpController $session;Add-RemoteHttpReply (New-RemoteHttpRequestXml);[void](Invoke-RemoteHttpWork $first $session);Update-PdvMonitorRemoteLocal $first;
    $reloaded=New-RemoteHttpController $session;Assert-RemoteHttp ($reloaded.Broker.Stage -ceq 'interrupted' -and $null -eq $reloaded.Broker.Active) 'Retomou contexto secreto.';
    $work=Get-PdvMonitorRemoteWork $reloaded;Assert-RemoteHttp ($work.Operation -ceq 'Closed' -and $work.Interrupted -and $work.Payload.Count -eq 2) 'Reinicio tentou aprovar/pedir.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'ended');[void](Invoke-RemoteHttpWork $reloaded $session);Assert-RemoteHttp ($reloaded.Broker.Stage -ceq 'idle' -and $reloaded.Windows.Starts -eq 0) 'Reinicio abriu transporte.';
  }
  Test-RemoteHttp 'parada local nao comprovada impede anunciar closed a central' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Start-RemoteHttpAuthorized $session $controller;Add-RemoteHttpReply (New-RemoteHttpLeaseXml);[void](Invoke-RemoteHttpWork $controller $session);
    $controller.Windows.FailStop=$true;Update-PdvMonitorRemoteLocal $controller $true $true;$controller.NextPollAt=[DateTimeOffset]::MinValue;
    Assert-RemoteHttp ($controller.Broker.Stage -ceq 'close_required' -and $null -eq (Get-PdvMonitorRemoteWork $controller) -and $controller.Busy) 'Fechamento nao comprovado enviado.';
  }
  Test-RemoteHttp 'latencia do ACK nao amplia prazo local nem invalida lease legitimo' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Add-RemoteHttpReply (New-RemoteHttpRequestXml);[void](Invoke-RemoteHttpWork $controller $session);Update-PdvMonitorRemoteLocal $controller;
    Add-RemoteHttpReply ((New-RemoteHttpSessionXml).Replace('16:15:00','16:15:02'));[void](Invoke-RemoteHttpWork $controller $session);
    Add-RemoteHttpReply ((New-RemoteHttpLeaseXml).Replace('16:15:00','16:15:02'));[void](Invoke-RemoteHttpWork $controller $session);
    Assert-RemoteHttp ($controller.Windows.Starts -eq 1 -and [DateTimeOffset]::Parse($controller.Windows.LastExpiry) -eq [DateTimeOffset]::Parse('2026-10-21T16:15:00Z')) 'Latencia ampliou TTL ou bloqueou lease valido.';
  }
  Test-RemoteHttp 'journal nativo interrompido so limpa apos ACK terminal; Stop nao recebe PID antigo' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;$controller.Windows.Stage='interrupted';$controller.Windows.Reason='RemoteWindowsInterrupted';
    Update-PdvMonitorRemoteLocal $controller;
    Assert-RemoteHttp ($controller.Windows.Stops -eq 0 -and $controller.Busy) 'Interrupcao executou Stop ou liberou manutencao.';
    $controller.NextPollAt=[DateTimeOffset]::MinValue;$work=Get-PdvMonitorRemoteWork $controller;
    Assert-RemoteHttp ($work.Operation -ceq 'Closed' -and $work.NativeInterrupted -and -not $work.Interrupted) 'Journal nativo isolado nao pediu fechamento.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'ending');[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Windows.Resolved -eq 0 -and $controller.Windows.Stage -ceq 'interrupted') 'Ending resolveu journal.';
    Add-RemoteHttpReply (New-RemoteHttpSessionXml 'ended');[void](Invoke-RemoteHttpWork $controller $session);Assert-RemoteHttp ($controller.Windows.Resolved -eq 1 -and -not $controller.Busy -and $controller.Windows.Starts -eq 0) 'ACK terminal nao resolveu ou iniciou transporte.';
  }
  Test-RemoteHttp 'perda nativa nao e registrada como cancelamento voluntario' {
    $session=New-RemoteHttpCase;$controller=New-RemoteHttpController $session;Start-RemoteHttpAuthorized $session $controller;Add-RemoteHttpReply (New-RemoteHttpLeaseXml);[void](Invoke-RemoteHttpWork $controller $session);
    $controller.Windows.CloseRequested=$true;$controller.Windows.Reason='TransportProcessExited';Update-PdvMonitorRemoteLocal $controller;
    Assert-RemoteHttp ($controller.Broker.Active.Record.closeReason -ceq 'TransportFailed') 'Perda foi atribuida ao operador.';
  }
  Test-RemoteHttp 'orcamento HTTP usa tempo total monotonicamente; nao renova a cada leitura' {
    $event=New-Object Threading.ManualResetEvent($false);$pending=New-Object PSObject -Property @{AsyncWaitHandle=$event};$clock=New-Object PSObject -Property @{ElapsedMilliseconds=4000};
    try{Assert-RemoteHttpThrows {& $module {param($Pending,$Clock);Wait-PdvRemoteHttpBudget $Pending $Clock;} $pending $clock;} 'RemoteTransportTimeout';}finally{$event.Dispose();}
    $source=[IO.File]::ReadAllText((Join-Path $directory 'PdvMonitor.Remoto.Transporte.psm1'));
    Assert-RemoteHttp ($source -match 'AllowAutoRedirect=\$false' -and $source -match 'BeginRead' -and $source -match 'request.Abort\(\)' -and $source -notmatch 'ServerCertificateValidationCallback\s*=') 'Limites/certificado foram relaxados.';
  }
  Test-RemoteHttp 'ACL administrativa permite somente leitores e administradores; dono/ancestrais inseguros recusados' {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'PdvMonitor.Remoto.Transporte.psm1'),[ref]$tokens,[ref]$errors);
    Assert-RemoteHttp ($errors.Count -eq 0) 'Parser do modulo falhou.';
    $nativeSources=@($ast.FindAll({param($Node);$Node -is [Management.Automation.Language.StringConstantExpressionAst] -and $Node.Value -match 'namespace Conecta.PdvRemoteBootstrap'},$true));
    Assert-RemoteHttp ($nativeSources.Count -eq 1) 'Fonte nativo de contagem de links ausente/duplicado.';
    if($null -eq ('Conecta.PdvRemoteBootstrap.FileLinks' -as [type])){Add-Type -TypeDefinition $nativeSources[0].Value -Language CSharp;}
    Assert-RemoteHttp ($null -ne ('Conecta.PdvRemoteBootstrap.FileLinks' -as [type]).GetMethod('SingleLink')) 'Checker de hard links nao compila; nenhuma funcao Win32 foi chamada.';
    $admin=@{Sid='S-1-5-32-544';Allow=$true;Rights=[int][Security.AccessControl.FileSystemRights]::FullControl;InheritOnly=$false};
    $reader=@{Sid='S-1-5-32-545';Allow=$true;Rights=[int][Security.AccessControl.FileSystemRights]::ReadAndExecute;InheritOnly=$false};
    Assert-RemoteHttp (& $module {param($Rules);Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-18' $Rules;} @($admin,$reader)) 'Leitura do operador foi recusada.';
    Assert-RemoteHttpThrows {& $module {param($Rules);Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-21-1001' $Rules;} @($admin,$reader);} 'RemoteExtensionUntrusted';
    foreach($right in @('Write','Modify','FullControl','Delete','DeleteSubdirectoriesAndFiles','ChangePermissions','TakeOwnership')){
      $unsafe=@{Sid='S-1-5-21-1001';Allow=$true;Rights=[int][Security.AccessControl.FileSystemRights]::$right;InheritOnly=$false};
      Assert-RemoteHttpThrows {& $module {param($Rules);Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-32-544' $Rules;} @($admin,$unsafe);} 'RemoteExtensionUntrusted';
    }
    $creator=@{Sid='S-1-5-11';Allow=$true;Rights=[int][Security.AccessControl.FileSystemRights]::CreateDirectories;InheritOnly=$false};
    Assert-RemoteHttp (& $module {param($Rules);Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-18' $Rules $true 'S-1-5-80-123';} @($creator)) 'Pai do ProgramData nao pode liberar substituicao, mas criar outros filhos e permitido.';
    $unsafe=@{Sid='S-1-5-11';Allow=$true;Rights=[int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles;InheritOnly=$false};
    Assert-RemoteHttpThrows {& $module {param($Rules);Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-18' $Rules $true 'S-1-5-80-123';} @($unsafe);} 'RemoteExtensionUntrusted';
    Assert-RemoteHttp (& $module {Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-80-123' @() $true 'S-1-5-80-123';}) 'TrustedInstaller ancestral foi recusado.';
    Assert-RemoteHttpThrows {& $module {Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-80-123' @() $false 'S-1-5-80-123';};} 'RemoteExtensionUntrusted';
    Assert-RemoteHttpThrows {& $module {Test-PdvRemoteAdministrativeAclEvidence 'S-1-5-18' @(@{Sid='S-1-5-11';Allow=$true});};} 'RemoteExtensionUntrusted';
  }
  Test-RemoteHttp 'extensao fixa e checada antes da importacao; OFF nao le credencial, nao consulta rede e nao usa fallback' {
    $original=& $module {@{Path=${function:Get-PdvRemoteAdministrativeModulePath};Assert=${function:Assert-PdvRemoteAdministrativeModule};SingleLink=${function:Assert-PdvRemoteAdministrativeSingleLink};};};
    $administrativeFixture=$null;$global:RemoteUnsafeFixtureImported=$false;
    try{
      & $module {function script:Get-PdvRemoteAdministrativeModulePath {return $script:AdministrativeFixturePath;}}
      $session=New-RemoteHttpCase;$local=Join-Path $temporary 'PdvMonitor.Remoto.Windows.psm1';
      [IO.File]::WriteAllText($local,'$global:RemoteUnsafeFixtureImported=$true;',(New-Object Text.UTF8Encoding($true)));
      & $module {param($Path);$script:AdministrativeFixturePath=$Path;} (Join-Path $temporary 'missing-administrative-module.psm1');
      $controller=New-PdvMonitorRemoteController $session $temporary;
      Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemoteExtensionNotInstalled' -and -not $global:RemoteUnsafeFixtureImported -and $null -eq $controller.Broker -and $null -eq (Get-PdvMonitorRemoteWork $controller)) 'Sem extensao administrativa importou fallback do perfil do usuario.';
      & $module {param($Path);$script:AdministrativeFixturePath=$Path;function script:Assert-PdvRemoteAdministrativeModule {param($Path);throw 'RemoteExtensionUntrusted';}} $local;
      $controller=New-PdvMonitorRemoteController $session $temporary;
      Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemoteExtensionUntrusted' -and -not $global:RemoteUnsafeFixtureImported) 'Importacao ocorreu antes da validacao administrativa.';
      & $module {function script:Assert-PdvRemoteAdministrativeModule {param($Path);return $Path;};function script:Assert-PdvRemoteAdministrativeSingleLink {param($Stream);throw 'RemoteExtensionUntrusted';}};
      $controller=New-PdvMonitorRemoteController $session $temporary;
      Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemoteExtensionUntrusted' -and -not $global:RemoteUnsafeFixtureImported) 'Hard link/evidencia indisponivel foi importado.';
      & $module {function script:Assert-PdvRemoteAdministrativeSingleLink {param($Stream);return $true;}};
      $administrativePath=Join-Path $temporary 'AdministrativeWindowsFixture.psm1';
      $text=@'
$script:FixtureMode='off';$script:FixtureFailure='';$script:Reads=0;
function Read-PdvMonitorRemoteWindowsConfiguration {param($DataDirectory);$script:Reads++;if($script:FixtureMode -ceq 'off'){return @{Enabled=$false;AgentId=''};}if($script:FixtureMode -ceq 'error'){throw 'PRIVATE-FILE-PATH-AND-SECRET';};return @{Enabled=$true;AgentId='11111111-1111-4111-8111-111111111111'};}
function New-PdvMonitorRemoteWindowsTransport {param($LocalConfiguration,$DataDirectory,$AgentId,$Enabled);throw $script:FixtureFailure;}
Export-ModuleMember -Function Read-PdvMonitorRemoteWindowsConfiguration,New-PdvMonitorRemoteWindowsTransport;
'@
      [IO.File]::WriteAllText($administrativePath,$text,(New-Object Text.UTF8Encoding($true)));
      & $module {param($Path);$script:AdministrativeFixturePath=$Path;function script:Assert-PdvRemoteAdministrativeModule {param($Path);return $Path;}} $administrativePath;
      $controller=New-PdvMonitorRemoteController $session $temporary;$administrativeFixture=& $module {Get-Module AdministrativeWindowsFixture;};
      Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemoteDisabled' -and $null -eq $controller.Broker) 'Perfil inativo preparou transporte.';
      Assert-RemoteHttp ((& $central {$script:CredentialReads;}) -eq 0 -and (& $module {$script:WireCalls.Count;}) -eq 0) 'Extensao ausente, insegura ou inativa leu credencial/rede.';
      foreach($reason in @('RemoteWindowsClr4Required','RemoteWindowsDotNetRequired','RemoteWindowsRuntimeUnknown','RemoteWindowsPlatformUnsupported','RemoteWindowsPlatformProfileMismatch')){
        & $administrativeFixture {param($Reason);$script:FixtureMode='active';$script:FixtureFailure=$Reason;} $reason;
        $controller=New-PdvMonitorRemoteController $session $temporary;
        Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemotePrerequisitesMissing' -and $null -eq $controller.Broker) 'Requisito local nao virou estado fixo.';
      }
      & $administrativeFixture {$script:FixtureMode='error';};$controller=New-PdvMonitorRemoteController $session $temporary;
      Assert-RemoteHttp (-not $controller.Enabled -and $controller.Reason -ceq 'RemotePreparationBlocked' -and ($controller | ConvertTo-Json -Depth 5) -notmatch 'PRIVATE') 'Falha de perfil expos segredo.';
      Assert-RemoteHttp ((& $central {$script:CredentialReads;}) -eq 0 -and (& $module {$script:WireCalls.Count;}) -eq 0) 'Preparacao de prerequisito leu credencial/rede.';
    }finally{
      & $module {param($Saved);Set-Item Function:script:Get-PdvRemoteAdministrativeModulePath $Saved.Path;Set-Item Function:script:Assert-PdvRemoteAdministrativeModule $Saved.Assert;Set-Item Function:script:Assert-PdvRemoteAdministrativeSingleLink $Saved.SingleLink;} $original;
      if($null -ne $administrativeFixture){Remove-Module $administrativeFixture -ErrorAction SilentlyContinue;};Remove-Variable RemoteUnsafeFixtureImported -Scope Global -ErrorAction SilentlyContinue;
    }
  }
}finally{Remove-Module $windows -ErrorAction SilentlyContinue;if([IO.Directory]::Exists($temporary)){[IO.Directory]::Delete($temporary,$true);}}
Write-Output ('Casos: '+$script:Cases+'; verificacoes: '+$script:Checks+'; falhas: '+$failures.Count);
if($failures.Count){foreach($failure in $failures){Write-Output $failure;};exit 1;}
