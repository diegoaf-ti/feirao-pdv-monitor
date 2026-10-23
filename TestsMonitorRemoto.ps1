#requires -Version 5.1
# Offline: nao inicia VNC, stunnel, rede, servico ou automacao do Windows.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;
Import-Module (Join-Path $directory 'PdvMonitor.Remoto.psm1') -Force;$module=Get-Module PdvMonitor.Remoto;
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('pdv-remote-tests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0;$script:Cases=0;$script:CaseId=0;$failures=New-Object 'Collections.Generic.List[string]';
function Assert-Remote($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Assert-RemoteThrows([scriptblock]$Body,[string]$Expected){$script:Checks++;try{& $Body | Out-Null;}catch{if($_.Exception.Message -ceq $Expected){return;};throw ('Erro inesperado: '+$_.Exception.Message+' / esperado '+$Expected);};throw ('Faltou erro '+$Expected);}
function Test-Remote([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
& $module {
  $script:RemoteRealEvidence=(Get-Command Get-PdvRemoteInteractiveEvidence).ScriptBlock;
  $script:RemoteRealPlatform=(Get-Command Get-PdvRemotePlatformEvidence).ScriptBlock;
  function script:Get-PdvRemoteNow{return $script:RemoteTestNow;}
  function script:Get-PdvRemoteInteractiveEvidence {return @{Supported=$script:RemoteSupported;Interactive=$script:RemoteInteractive;Unlocked=$script:RemoteUnlocked;WindowsSessionId=$script:RemoteWindowsSession;UserSid=$script:RemoteSid;HostInstanceId=$script:RemoteHostId};}
  function script:Get-PdvRemotePlatformEvidence {return @{Detected=$script:RemotePlatformDetected;WindowsVersion=$script:RemotePlatformVersion;Architecture=$script:RemotePlatformArchitecture;CompatibilityVerified=$script:RemotePlatformVerified};}
}
function New-RemoteCase([bool]$Enabled=$true){
  $script:CaseId++;$path=Join-Path $temporary ('case'+$script:CaseId);[void][IO.Directory]::CreateDirectory($path);
  & $module {$script:RemoteTestNow=[DateTimeOffset]::Parse('2026-10-21T16:00:00Z');$script:RemoteSupported=$true;$script:RemoteInteractive=$true;$script:RemoteUnlocked=$true;$script:RemoteWindowsSession='1';$script:RemoteSid='S-1-5-21-123-456-789-1001';$script:RemoteHostId='22222222-2222-4222-8222-222222222222';$script:RemotePlatformDetected=$true;$script:RemotePlatformVersion='10.0.19045';$script:RemotePlatformArchitecture='x64';$script:RemotePlatformVerified=$true;};
  return (New-PdvMonitorRemoteContext -DataDirectory $path -AgentId '11111111-1111-4111-8111-111111111111' -Enabled $Enabled);
}
function New-RemoteRequest($Context){
  $now=& $module {Get-PdvRemoteNow;};
  return @{SessionId=[Guid]::NewGuid().ToString('D');AgentId=$Context.AgentId;RequestId='';RequestedAt=$now.ToString('o');ExpiresAt=$now.AddSeconds(120).ToString('o');SessionMaxSeconds=900;Mode='control';TechnicianId='123';TechnicianName='Tecnico de teste';Reason='Verificar falha da impressora';Nonce=[Convert]::ToBase64String((New-Object byte[] 32)).TrimEnd('=').Replace('+','-').Replace('/','_')};
}
function Start-RemoteRequest($Context){$request=New-RemoteRequest $Context;$request.RequestId=$request.SessionId;[void](Receive-PdvMonitorRemoteRequest $Context $request);return $request;}
function Approve-RemoteRequest($Context){$request=Start-RemoteRequest $Context;$prompt=Get-PdvMonitorRemoteConsentPrompt $Context;[void](Confirm-PdvMonitorRemoteConsent $Context $request.SessionId $prompt.ChallengeId 'approved' $true);return $request;}
function New-RemoteAck($Context,[string]$Status='approved'){$request=$Context.Active.Request;$expires='';if($Status -ceq 'approved'){$expires=(& $module {Get-PdvRemoteNow;}).AddSeconds(900).ToString('o');};return @{Id=$request.SessionId;Status=$Status;ExpiresAt=$expires;ConsentExpiresAt=$request.ExpiresAt.ToString('o')};}

try{
  Test-Remote 'desabilitado por padrao e sem escrita ou comando' {
    $context=New-RemoteCase $false;$request=New-RemoteRequest $context;$request.RequestId=$request.SessionId;
    Assert-Remote (-not $context.Enabled -and $context.Healthy) 'Contexto deveria estar desabilitado e saudavel.';
    Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $request;} 'RemoteDisabled';
    Assert-Remote (-not [IO.File]::Exists((Join-Path $context.DataDirectory 'remoto-consentimentos.xml'))) 'Desabilitado gravou pedido.';
    Assert-Remote (-not (Get-PdvMonitorRemoteSnapshot $context).Connected) 'Declarou conexao.';
  }
  Test-Remote 'contrato fechado rejeita comando, host, campo extra e modo sem consentimento' {
    foreach($key in @('Executable','Arguments','Hostname','Port','OperatorConfirmed','Password')){
      $context=New-RemoteCase;$request=New-RemoteRequest $context;$request.RequestId=$request.SessionId;$request[$key]='PRIVATE-SECRET';
      Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $request;} 'RemoteInvalidRequest';
      Assert-Remote ($context.Records.Count -eq 0 -and $null -eq $context.Command) 'Pedido invalido criou estado.';
    }
    $context=New-RemoteCase;$request=New-RemoteRequest $context;$request.RequestId=$request.SessionId;$request.Mode='unattended';
    Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $request;} 'RemoteInvalidRequest';
    $request.Mode='control';$request.AgentId='33333333-3333-4333-8333-333333333333';Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $request;} 'RemoteInvalidRequest';
  }
  Test-Remote 'valida identidades, nonce canonico, controles e datas' {
    $context=New-RemoteCase;
    foreach($mutation in @(
      @{Key='Nonce';Value=('A'*42+'B')},@{Key='TechnicianName';Value=('Tecnico'+[char]27+'oculto')},
      @{Key='Reason';Value=('Falha'+[char]0+'PRIVATE')},@{Key='TechnicianId';Value='0'},@{Key='TechnicianId';Value='1e3'},
      @{Key='SessionMaxSeconds';Value=901},@{Key='SessionMaxSeconds';Value=30.5},@{Key='SessionMaxSeconds';Value=$null},
      @{Key='RequestedAt';Value='2026-02-30T16:00:00Z'},@{Key='ExpiresAt';Value='2026-10-21T16:02:01Z'})){
      $request=New-RemoteRequest $context;$request.RequestId=$request.SessionId;$request[$mutation.Key]=$mutation.Value;
      $script:Checks++;$failed=$false;try{Receive-PdvMonitorRemoteRequest $context $request | Out-Null;}catch{$failed=$true;Assert-Remote ($_.Exception.Message -cmatch '^Remote') 'Expos erro interno.';};if(-not $failed){throw ('Aceitou '+$mutation.Key);}
    }
    Assert-Remote ($context.Records.Count -eq 0) 'Entrada invalida alterou historico.';
  }
  Test-Remote 'diario e snapshot nao vazam nonce, desafio, nome ou motivo livre' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;
    $saved=[IO.File]::ReadAllText((Join-Path $context.DataDirectory 'remoto-consentimentos.xml'));
    $snapshot=Get-PdvMonitorRemoteSnapshot $context;$serialized=$snapshot | ConvertTo-Json -Depth 8;
    foreach($private in @($request.Nonce,$request.TechnicianName,$request.Reason,$prompt.ChallengeId)){
      Assert-Remote (-not $saved.Contains($private)) 'Diario vazou conteudo privado.';
      Assert-Remote (-not $serialized.Contains($private)) 'Snapshot vazou conteudo privado.';
    }
    Assert-Remote ($prompt.DefaultDecision -ceq 'denied' -and $prompt.PaymentIdleConfirmationRequired) 'Prompt nao exige decisao local segura.';
    Assert-Remote ($context.Command -eq $null) 'Mostrar prompt criou comando remoto.';
  }
  Test-Remote 'adaptador real indisponivel e console bloqueada impedem prompt' {
    $context=New-RemoteCase;[void](Start-RemoteRequest $context);
    $evidence=& $module {& $script:RemoteRealEvidence;};Assert-Remote (-not $evidence.Supported -and -not $evidence.Unlocked) 'Adaptador padrao fez inferencia de console.';
    & $module {$script:RemoteSupported=$false;};Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemoteLocalHostUnavailable';
    & $module {$script:RemoteSupported=$true;$script:RemoteUnlocked=$false;};Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemoteLocalHostUnavailable';
    Assert-Remote ($null -eq $context.Challenge -and $null -eq $context.Command) 'Sem console criou desafio/comando.';
  }
  Test-Remote 'preparo permite Win7SP1 e Win10/11 x86/x64 somente com dependencias homologadas' {
    foreach($version in @('6.1.7601','10.0.10240','10.0.19045','10.0.22000')){
      foreach($architecture in @('x86','x64')){
        $context=New-RemoteCase;[void](Start-RemoteRequest $context);
        & $module {param($Version,$Architecture);$script:RemotePlatformVersion=$Version;$script:RemotePlatformArchitecture=$Architecture;} $version $architecture;
        $assessment=Get-PdvMonitorRemotePreparationAssessment;
        Assert-Remote ($assessment.EligibleForPreparation -and -not $assessment.TransportActivationSupported -and -not $assessment.Connected) 'Preparo foi confundido com habilitacao remota.';
        $prompt=Get-PdvMonitorRemoteConsentPrompt $context;Assert-Remote ($prompt.DefaultDecision -ceq 'denied' -and $null -eq $context.Command) 'Plataforma aprovou sozinha ou criou comando.';
      }
    }
  }
  Test-Remote 'preparo rejeita plataformas desconhecidas Windows sem SP1 e dependencias nao homologadas' {
    $context=New-RemoteCase;[void](Start-RemoteRequest $context);
    $actual=& $module {& $script:RemoteRealPlatform;};Assert-Remote (-not $actual.Detected -and -not $actual.CompatibilityVerified) 'Adaptador padrao presumiu plataforma real.';
    & $module {$script:RemotePlatformDetected=$false;};Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemotePlatformUnknown';
    foreach($version in @('6.0.6002','6.1.7600','6.2.9200','6.3.9600','10.0.10239','11.0.26000')){
      & $module {param($Version);$script:RemotePlatformDetected=$true;$script:RemotePlatformVersion=$Version;} $version;
      Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemoteWindowsNotSupported';
    }
    & $module {$script:RemotePlatformVersion='10.0.19045';$script:RemotePlatformArchitecture='arm64';};Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemoteArchitectureNotHomologated';
    foreach($architecture in @('x86','x64')){
      & $module {param($Architecture);$script:RemotePlatformVersion='6.1.7601';$script:RemotePlatformArchitecture=$Architecture;$script:RemotePlatformVerified=$false;} $architecture;
      Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemoteDependenciesNotHomologated';
    }
    Assert-Remote ($null -eq $context.Command -and $null -eq $context.Challenge) 'Preflight criou comando ou desafio.';
  }
  Test-Remote 'aprovacao exige desafio unico, sessao local igual e pagamento encerrado' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;
    Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId ([Guid]::NewGuid().ToString('D')) 'approved' $true;} 'RemoteInvalidLocalDecision';
    Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved';} 'RemotePaymentConfirmationRequired';
    & $module {$script:RemoteWindowsSession='2';};Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved' $true;} 'RemoteLocalSessionChanged';
    & $module {$script:RemoteWindowsSession='1';};[void](Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved' $true);
    $command=Get-PdvMonitorRemoteCommand $context;Assert-Remote ($command.Kind -ceq 'SubmitConsent' -and $command.Payload.decision -ceq 'approved' -and $command.Payload.nonce -ceq $request.Nonce) 'Consentimento tipado incorreto.';
    Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved' $true;} 'RemoteInvalidLocalDecision';
    Assert-Remote (-not (Get-PdvMonitorRemoteSnapshot $context).Connected) 'Aprovacao local declarou conectado.';
  }
  Test-Remote 'negativa e ACK idempotente central nao abrem transporte' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;
    [void](Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'denied');
    $first=Get-PdvMonitorRemoteCommand $context;$second=Get-PdvMonitorRemoteCommand $context;Assert-Remote (($first | ConvertTo-Json -Compress) -ceq ($second | ConvertTo-Json -Compress)) 'Retry mudou payload idempotente.';
    [void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context 'denied'));
    Assert-Remote ($context.Stage -ceq 'denied' -and $null -eq (Get-PdvMonitorRemoteCommand $context)) 'Negativa nao finalizou.';
    Assert-Remote ($context.Active.Request.Nonce -ceq '') 'Nonce negado permaneceu em memoria.';
  }
  Test-Remote 'ACK deve corresponder ao pedido e nao pode declarar ready' {
    $context=New-RemoteCase;$request=Approve-RemoteRequest $context;$ack=New-RemoteAck $context;$ack.Id=[Guid]::NewGuid().ToString('D');
    Assert-RemoteThrows {Complete-PdvMonitorRemoteConsent $context $ack;} 'RemoteInvalidConsentAcknowledgement';
    $ack=New-RemoteAck $context;$ack.Status='ready';Assert-RemoteThrows {Complete-PdvMonitorRemoteConsent $context $ack;} 'RemoteInvalidConsentAcknowledgement';
    $ack=New-RemoteAck $context;$ack.ExpiresAt='2026-10-22T16:00:00Z';Assert-RemoteThrows {Complete-PdvMonitorRemoteConsent $context $ack;} 'RemoteInvalidConsentAcknowledgement';
    & $module {$script:RemoteTestNow=$script:RemoteTestNow.AddSeconds(10);};$ack=New-RemoteAck $context;[void](Complete-PdvMonitorRemoteConsent $context $ack);$snapshot=Get-PdvMonitorRemoteSnapshot $context;
    Assert-Remote ($snapshot.Stage -ceq 'authorized' -and -not $snapshot.Connected -and -not $snapshot.TransportActivationSupported -and $snapshot.Reason -ceq 'RemoteTransportAdapterUnavailable') 'ACK foi confundido com transporte pronto.';
    Assert-Remote ($null -eq (Get-PdvMonitorRemoteCommand $context)) 'ACK emitiu start/ready.';
    Assert-Remote ($context.Active.Record.sessionExpiresAt -eq $context.Active.ApprovedAt.AddSeconds(900) -and $context.Active.Request.Nonce -ceq '') 'ACK ampliou janela local ou manteve nonce desnecessario.';
  }
  Test-Remote 'pedido duplicado nao repete prompt e alteracao de pedido e bloqueada' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$duplicate=Receive-PdvMonitorRemoteRequest $context $request;
    Assert-Remote (-not $duplicate.Accepted -and $duplicate.Reason -ceq 'RemoteRequestAlreadyObserved') 'Duplicado reaprovavel.';
    $request.Reason='Outro motivo de atendimento';Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $request;} 'RemoteRequestChanged';
    $other=New-RemoteRequest $context;$other.RequestId=$other.SessionId;Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $context $other;} 'RemoteSessionBusy';
  }
  Test-Remote 'reinicio nao retoma e exige fechamento central da mesma sessao' {
    $context=New-RemoteCase;$request=Approve-RemoteRequest $context;
    $reloaded=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;$snapshot=Get-PdvMonitorRemoteSnapshot $reloaded;
    Assert-Remote (-not $snapshot.Healthy -and $snapshot.Stage -ceq 'interrupted' -and $snapshot.UnresolvedSessionIds[0] -ceq $request.SessionId -and $null -eq $reloaded.Command -and $null -eq $reloaded.Active) 'Reiniciou autorizacao/interrompido invisivel.';
    Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $reloaded $request;} 'RemoteLocalStateBlocked';
    Assert-RemoteThrows {Resolve-PdvMonitorRemoteInterruptedSession $reloaded $request.SessionId @{Id=$request.SessionId;Status='approved'};} 'RemoteInvalidInterruptedAcknowledgement';
    [void](Resolve-PdvMonitorRemoteInterruptedSession $reloaded $request.SessionId @{Id=$request.SessionId;Status='closed'});
    Assert-Remote ($reloaded.Healthy -and $reloaded.Stage -ceq 'idle') 'Fechamento confirmado nao liberou broker.';
    $duplicate=Receive-PdvMonitorRemoteRequest $reloaded $request;Assert-Remote (-not $duplicate.Accepted) 'Reutilizou consentimento depois do reinicio.';
  }
  Test-Remote 'TTL antes da decisao e TTL autorizado bloqueiam reuso' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;
    & $module {$script:RemoteTestNow=$script:RemoteTestNow.AddSeconds(120);};Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved' $true;} 'RemoteRequestExpired';
    [void](Update-PdvMonitorRemoteContext $context);$command=Get-PdvMonitorRemoteCommand $context;Assert-Remote ($command.Kind -ceq 'SubmitClosedStatus' -and $context.Active.Record.closeReason -ceq 'ConsentExpired') 'Pedido expirado nao pediu fechamento.';
    $context=New-RemoteCase;[void](Approve-RemoteRequest $context);[void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context));
    & $module {$script:RemoteTestNow=$script:RemoteTestNow.AddSeconds(900);};[void](Update-PdvMonitorRemoteContext $context);Assert-Remote ($context.Stage -ceq 'close_required' -and $context.Active.Record.closeReason -ceq 'LeaseExpired') 'Lease expirado nao bloqueou.';
  }
  Test-Remote 'pausa e troca de console revogam decisao e permitem so mensagem closed' {
    $context=New-RemoteCase;$request=Approve-RemoteRequest $context;[void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context));
    [void](Update-PdvMonitorRemoteContext $context $true);$command=Get-PdvMonitorRemoteCommand $context;Assert-Remote ($command.Kind -ceq 'SubmitClosedStatus' -and $command.Payload.status -ceq 'closed') 'Pausa reteve comando de aprovacao ou impediu fechamento.';
    Assert-RemoteThrows {Get-PdvMonitorRemoteConsentPrompt $context;} 'RemotePaused';
    [void](Complete-PdvMonitorRemoteClose $context @{Id=$request.SessionId;Status='closed'});Assert-Remote ($context.Stage -ceq 'closed') 'ACK de fechamento pausado falhou.';
    $context=New-RemoteCase;[void](Approve-RemoteRequest $context);[void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context));
    & $module {$script:RemoteUnlocked=$false;};[void](Update-PdvMonitorRemoteContext $context);Assert-Remote ($context.Active.Record.closeReason -ceq 'LocalSessionChanged') 'Console bloqueada manteve autorizacao.';
  }
  Test-Remote 'falha de escrita bloqueia antes de disponibilizar consentimento' {
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;
    $lock=[IO.File]::Open((Join-Path $context.DataDirectory 'remoto-consentimentos.xml.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);
    try{Assert-RemoteThrows {Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'approved' $true;} 'RemoteLocalStateWriteFailed';}finally{$lock.Dispose();}
    Assert-Remote (-not $context.Healthy -and $null -eq $context.Command -and $null -eq $context.Challenge) 'Falha de diario liberou acao.';
    $reloaded=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;Assert-Remote ($reloaded.Stage -ceq 'interrupted') 'Perdeu pendencia no disco.';
  }
  Test-Remote 'duas instancias nao sobrescrevem o mesmo diario' {
    $context=New-RemoteCase;$second=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;[void](Start-RemoteRequest $context);
    $request=New-RemoteRequest $second;$request.RequestId=$request.SessionId;Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $second $request;} 'RemoteLocalStateConflict';
    $reloaded=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;Assert-Remote ($reloaded.Records.Count -eq 1 -and $reloaded.Records[0].id -ceq $context.Active.Request.SessionId) 'Instancia concorrente sobrescreveu journal.';
  }
  Test-Remote 'XML invalido ou com DTD, namespace, tamanho e identidade errados bloqueia' {
    foreach($variant in @('doctype','namespace','attribute','oversize','agent')){
      $context=New-RemoteCase;[void](Start-RemoteRequest $context);$path=Join-Path $context.DataDirectory 'remoto-consentimentos.xml';$text=[IO.File]::ReadAllText($path);
      switch($variant){'doctype'{$text='<!DOCTYPE x [<!ENTITY leak SYSTEM "file:///PRIVATE-SECRET">]>'+ $text;}'namespace'{$text=$text.Replace('<PdvRemoteConsentJournal ','<PdvRemoteConsentJournal xmlns="urn:unexpected" ');}'attribute'{$text=$text.Replace('<Session ','<Session unexpected="PRIVATE-SECRET" ');}'oversize'{$text='x'*65537;}'agent'{$text=$text.Replace($context.AgentId,'99999999-9999-4999-8999-999999999999');}}
      [IO.File]::WriteAllText($path,$text);$reloaded=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;
      Assert-Remote (-not $reloaded.Healthy -and $reloaded.Stage -ceq 'blocked' -and $reloaded.LastReason -ceq 'RemoteLocalStateInvalid') 'Diario invalido foi aceito.';
      Assert-RemoteThrows {Receive-PdvMonitorRemoteRequest $reloaded (New-RemoteRequest $reloaded);} 'RemoteLocalStateBlocked';
    }
  }
  Test-Remote 'recuo de relogio nao alonga janela e diario terminal permanece valido' {
    $context=New-RemoteCase;$request=Approve-RemoteRequest $context;[void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context));
    & $module {$script:RemoteTestNow=$script:RemoteTestNow.AddSeconds(-6);};[void](Update-PdvMonitorRemoteContext $context);
    Assert-Remote (-not $context.Healthy -and $context.LastReason -ceq 'RemoteClockInvalid' -and $null -eq $context.Command) 'Recuo de relogio ampliou acesso.';
    $context=New-RemoteCase;$request=Start-RemoteRequest $context;$prompt=Get-PdvMonitorRemoteConsentPrompt $context;[void](Confirm-PdvMonitorRemoteConsent $context $request.SessionId $prompt.ChallengeId 'denied');[void](Complete-PdvMonitorRemoteConsent $context (New-RemoteAck $context 'denied'));
    $reloaded=New-PdvMonitorRemoteContext $context.DataDirectory $context.AgentId $true;Assert-Remote ($reloaded.Healthy -and $reloaded.Stage -ceq 'idle' -and $reloaded.Records.Count -eq 1) 'Diario terminal nao recarregou.';
  }
}finally{if([IO.Directory]::Exists($temporary)){[IO.Directory]::Delete($temporary,$true);}}
Write-Output ('Casos: '+$script:Cases+'; verificacoes: '+$script:Checks+'; falhas: '+$failures.Count);
if($failures.Count){foreach($failure in $failures){Write-Output $failure;};exit 1;}
