#requires -Version 5.1
# Offline: mocks de Windows/processos/assinatura. Nao executa binarios nem Win32.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Import-Module (Join-Path $directory 'PdvMonitor.Remoto.Windows.psm1') -Force;$module=Get-Module PdvMonitor.Remoto.Windows;
$testRoot=[IO.Path]::GetTempPath();if([IO.Directory]::Exists('/private/tmp')){$testRoot='/private/tmp';};$temporary=Join-Path $testRoot ('pdv-remote-win-tests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporary);
$script:Checks=0;$script:Cases=0;$script:CaseId=0;$failures=New-Object 'Collections.Generic.List[string]';
function Assert-Win($Value,[string]$Message){$script:Checks++;if(-not $Value){throw $Message;}}
function Assert-WinThrows([scriptblock]$Body,[string]$Expected){$script:Checks++;try{& $Body | Out-Null;}catch{if($_.Exception.Message -ceq $Expected){return;};throw ('Erro '+$_.Exception.Message+' / esperado '+$Expected);};throw ('Faltou erro '+$Expected);}
function Test-Win([string]$Name,[scriptblock]$Body){$script:Cases++;try{& $Body;Write-Output ('OK: '+$Name);}catch{$failures.Add($Name+': '+$_.Exception.Message+' '+$_.ScriptStackTrace);Write-Output ('FALHOU: '+$Name+': '+$_.Exception.Message);}}
& $module {
  $script:RealNativeInitializer=(Get-Command Initialize-PdvRemoteWindowsNative).ScriptBlock;
  $script:RealBinary=(Get-Command Test-PdvRemoteWindowsBinary).ScriptBlock;
  $script:RealJournal=(Get-Command Write-PdvRemoteWindowsTransportJournal).ScriptBlock;
  $script:RealMutex=(Get-Command Enter-PdvRemoteWindowsMutex).ScriptBlock;
  function script:Get-PdvRemoteWindowsNow{return [DateTimeOffset]::Parse('2026-10-21T16:00:00Z');}
  function script:Test-PdvRemoteWindowsProtectedAcl {param($Path,$Private);return $true;}
  function script:Test-PdvRemoteWindowsAdministrativeAcl {param($Path);if(-not $script:TestAdministrative){throw 'RemoteWindowsAdministrativeProfileRequired';};return $true;}
  function script:Test-PdvRemoteWindowsAdministrativeAncestors {param($Path);if(-not $script:TestAdministrativeAncestors){throw 'RemoteWindowsAdministrativeProfileRequired';};return $true;}
  function script:Get-PdvRemoteWindowsConfigurationPath {param($DataDirectory);return (Join-Path $DataDirectory 'remoto-piloto.xml');}
  function script:Initialize-PdvRemoteWindowsNative {}
  function script:Get-PdvRemoteWindowsRuntimeEvidence {return $script:TestRuntimeEvidence;}
  function script:Get-PdvRemoteWindowsNativeEvidence {return $script:TestNativeEvidence;}
  function script:Test-PdvRemoteWindowsUiThread {return $true;}
  function script:Get-PdvMonitorRemoteWindowsInteractiveEvidence {return @{Supported=$true;Interactive=$true;Unlocked=$script:TestUnlocked;WindowsSessionId='1';UserSid='S-1-5-21-1-2-3-1001';HostInstanceId='22222222-2222-4222-8222-222222222222'};}
  function script:Test-PdvRemoteWindowsNoExistingVnc {if($script:TestExisting){throw 'RemoteWindowsExistingVncInstance';}}
  function script:Enter-PdvRemoteWindowsMutex {param($Transport);if($script:TestMutexDenied){throw 'RemoteWindowsExistingVncInstance';};& $script:RealMutex $Transport;}
  function script:Get-PdvRemoteWindowsCertificateHash {param($Path);return ('c'*64);}
  function script:Get-AuthenticodeSignature {param($LiteralPath);return @{Status=$script:SignatureStatus;SignerCertificate=@{Thumbprint=$script:SignatureThumbprint}};}
  function script:Wait-PdvRemoteWindowsTunnelListener {param($Supervisor,$Port,$ProcessId);return $script:TestListener;}
  function script:Show-PdvRemoteWindowsIndicator {param($Transport,$BrokerContext);return $null;}
  function script:Get-PdvRemoteWindowsLoopbackPort {return 55555;}
  function script:New-PdvRemoteWindowsSupervisor {
    param($Seconds,$Evidence);
    if($null -ne $script:TestSupervisorException){throw $script:TestSupervisorException;}
    $supervisor=New-Object PSObject -Property @{Closed=$false;ProcessesStopped=$false;CloseReason='';Children=@();HeartbeatCount=0;Starts=0;Disposed=$false;};
    $supervisor | Add-Member ScriptMethod StartChild {
      param($Executable,$Arguments,$WorkingDirectory);
      $this.Starts++;$expected=if($this.Starts -eq 1){'starting_tunnel'}else{'starting_vnc'};
      $journal=[IO.File]::ReadAllText($script:TestJournalPath);if(-not $journal.Contains('stage="'+$expected+'"')){throw 'EffectBeforeJournal';}
      $child=New-Object PSObject -Property @{ProcessId=(100+$this.Starts);Executable=$Executable;CreatedUtc='2026-10-21T16:00:00Z';Arguments=$Arguments;WorkingDirectory=$WorkingDirectory};$this.Children+=,$child;
      return $child;
    };
    $supervisor | Add-Member ScriptMethod Heartbeat {if($this.Closed){throw 'RemoteSupervisorClosed';};$this.HeartbeatCount++;};
    $supervisor | Add-Member ScriptMethod SetTunnelPort {param($Port);if($Port -ne 55555){throw 'UnexpectedTunnelPort';}};
    $supervisor | Add-Member ScriptMethod Stop {param($Reason);$this.Closed=$true;$this.ProcessesStopped=-not $script:TestCannotStop;$this.CloseReason=$Reason;};
    $supervisor | Add-Member ScriptMethod Dispose {$this.Disposed=$true;};
    $script:LastSupervisor=$supervisor;return $supervisor;
  }
  function script:Write-PdvRemoteWindowsTransportJournal {param($Transport,$Stage);if($Stage -ceq $script:TestFailJournalStage){throw 'RemoteWindowsJournalWriteFailed';};& $script:RealJournal $Transport $Stage;}
}
function New-WinCase {
  param([string]$Architecture='x64',[string]$PlatformProfile='');
  if(-not $PlatformProfile){$PlatformProfile='win10plus-'+$Architecture;}
  $script:CaseId++;$path=Join-Path $temporary ('case'+$script:CaseId);[void][IO.Directory]::CreateDirectory($path);$bin=Join-Path $path 'bin';[void][IO.Directory]::CreateDirectory($bin);
  $bytes=New-Object byte[] 512;$bytes[0]=77;$bytes[1]=90;[BitConverter]::GetBytes([int]128).CopyTo($bytes,60);[BitConverter]::GetBytes([uint32]17744).CopyTo($bytes,128);$machine=34404;$magic=523;if($Architecture -ceq 'x86'){$machine=332;$magic=267;};[BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes,132);[BitConverter]::GetBytes([uint16]$magic).CopyTo($bytes,152);
  foreach($leaf in @('stunnel.exe','winvnc.exe')){[IO.File]::WriteAllBytes((Join-Path $bin $leaf),$bytes);}
  $hash=& $module {param($Bytes);Get-PdvRemoteWindowsHash $Bytes;} $bytes;
  $required=@{'UseRegistry'='0';'SocketConnect'='0';'HTTPConnect'='0';'LoopbackOnly'='1';'AllowLoopback'='1';'AuthRequired'='1';'ReverseAuthRequired'='1';'MSLogonRequired'='0';'NewMSLogon'='0';'UseDSMPlugin'='0';'FileTransferEnabled'='0';'BlankMonitorEnabled'='0';'LocalInputsDisabled'='0';'InputsEnabled'='1';'DisableTrayIcon'='0';'AllowProperties'='0';'AllowEditClients'='0';'DebugMode'='0';'Avilog'='0';'service_commandline'=''};
  foreach($key in @('EnableTLS','cloudEnabled','UseBridge','AllowInjection','UseIpv6','rdpmode','clearconsole')){$required[$key]='0';}
  $lines=@('[admin]');foreach($key in $required.Keys){$lines+=($key+'='+$required[$key]);};$lines+=@('[ultravnc]','passwd=0102030405060708');
  $ini=Join-Path $bin 'ultravnc.ini';[IO.File]::WriteAllText($ini,($lines -join "`r`n"));$iniHash=& $module {param($Path);Get-PdvRemoteWindowsHash ([IO.File]::ReadAllBytes($Path));} $ini;
  $marker=Join-Path $bin 'ultravnc.portable';[IO.File]::WriteAllText($marker,'');
  foreach($leaf in @('cert.pem','private.key','ca.pem')){[IO.File]::WriteAllText((Join-Path $path $leaf),'NOT-A-REAL-KEY');}
  $config=@{SchemaVersion=2;Enabled=$true;ProfileApproved=$true;PlatformProfile=$PlatformProfile;AgentId='11111111-1111-4111-8111-111111111111';RepeaterId='4901';GatewayHost='pilot.company.example';GatewayPort=8443;CertificateFile=(Join-Path $path 'cert.pem');CertificateSha256=('c'*64);PrivateKeyFile=(Join-Path $path 'private.key');ServerCaFile=(Join-Path $path 'ca.pem');StunnelExe=(Join-Path $bin 'stunnel.exe');StunnelSha256=$hash;StunnelSignerThumbprint=('A'*40);UltraVncExe=(Join-Path $bin 'winvnc.exe');UltraVncSha256=$hash;UltraVncSignerThumbprint=('A'*40);UltraVncIniFile=$ini;UltraVncIniSha256=$iniHash;PortableMarkerFile=$marker};
  & $module {param($Path,$Architecture,$PlatformProfile);$script:TestRuntimeEvidence=@{Detected=$true;ClrMajor=4;DotNetRelease=528040};$version='10.0.19045';if($PlatformProfile.StartsWith('win7-sp1-')){$version='6.1.7601';};$script:TestNativeEvidence=@{Detected=$true;Supported=$true;CompatibilityReason='';CompatibilityProfile=$PlatformProfile;Architecture=$Architecture;ProcessArchitecture=$Architecture;WindowsVersion=$version};$script:TestUnlocked=$true;$script:TestExisting=$false;$script:TestMutexDenied=$false;$script:TestAdministrative=$true;$script:TestAdministrativeAncestors=$true;$script:SignatureStatus=[Management.Automation.SignatureStatus]::Valid;$script:SignatureThumbprint=('A'*40);$script:TestListener=$true;$script:TestCannotStop=$false;$script:TestFailJournalStage='';$script:TestJournalPath=(Join-Path $Path 'remoto-transporte.xml');$script:LastSupervisor=$null;$script:TestSupervisorException=$null;} $path $Architecture $PlatformProfile;
  return @{Path=$path;Configuration=$config};
}
function New-WinTransport($Case){return (New-PdvMonitorRemoteWindowsTransport $Case.Configuration $Case.Path $Case.Configuration.AgentId $true);}
function New-WinLease($Case){return @{SessionId=[Guid]::NewGuid().ToString('D');AgentId=$Case.Configuration.AgentId;RepeaterId='4901';CertificateSha256=('c'*64);State='pending';ExpiresAt='2026-10-21T16:15:00Z'};}
function New-WinBroker($Case,$Lease){$identity=& $module {Get-PdvRemoteWindowsIdentity;};return @{Enabled=$true;Healthy=$true;Paused=$false;Stage='authorized';AgentId=$Case.Configuration.AgentId;Active=@{Request=@{SessionId=$Lease.SessionId;SessionMaxSeconds=900;TechnicianName='Tecnico teste'};Record=@{decision='approved';sessionExpiresAt=[DateTimeOffset]::Parse($Lease.ExpiresAt)};ApprovedAt=[DateTimeOffset]::Parse('2026-10-21T16:00:00Z');LocalIdentity=$identity}};}
function Start-WinMock($Case){$transport=New-WinTransport $Case;$lease=New-WinLease $Case;$broker=New-WinBroker $Case $lease;[void](Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease);return @{Transport=$transport;Lease=$lease;Broker=$broker};}
try{
  Test-Win 'importacao e default OFF nao iniciam processos nem criam journal' {
    $case=New-WinCase;$transport=New-PdvMonitorRemoteWindowsTransport $null $case.Path $case.Configuration.AgentId;
    Assert-Win (-not $transport.Enabled -and $transport.Stage -ceq 'idle') 'OFF incorreto';Assert-Win (-not [IO.File]::Exists((Join-Path $case.Path 'remoto-transporte.xml'))) 'OFF escreveu';
    Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $null $null;} 'RemoteWindowsDisabled';
    $config=Read-PdvMonitorRemoteWindowsConfiguration $case.Path;Assert-Win (-not $config.Enabled) 'Sem arquivo ativou';
  }
  Test-Win 'modulo bloqueia Windows real nesta plataforma sem invocar bibliotecas nativas' {
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Assert-WinThrows {& $module {& $script:RealNativeInitializer;};} 'RemoteWindowsUnavailable';}
  }
  Test-Win 'schema rejeita comandos remotos, host injetado, credenciais e campo extra' {
    $case=New-WinCase;foreach($field in @('Command','Arguments','Password','Url')){$config=$case.Configuration.Clone();$config[$field]='SECRET';Assert-WinThrows {& $module {param($Config);Test-PdvRemoteWindowsConfigurationShape $Config;} $config;} 'RemoteWindowsConfigurationInvalid';}
    foreach($profile in @('win7','win7-sp1','win7-sp1-arm64','win10plus-x86;run','Win7-sp1-x86')){$config=$case.Configuration.Clone();$config.PlatformProfile=$profile;Assert-WinThrows {& $module {param($Config);Test-PdvRemoteWindowsConfigurationShape $Config;} $config;} 'RemoteWindowsConfigurationInvalid';}
    $config=$case.Configuration.Clone();$config.SchemaVersion=1;Assert-WinThrows {& $module {param($Config);Test-PdvRemoteWindowsConfigurationShape $Config;} $config;} 'RemoteWindowsConfigurationInvalid';
    foreach($hostValue in @('127.0.0.1','bad host.example','host.example;exec=x','host.example.invalid','host.example/path')){$config=$case.Configuration.Clone();$config.GatewayHost=$hostValue;Assert-WinThrows {& $module {param($Config);Test-PdvRemoteWindowsConfigurationShape $Config;} $config;} 'RemoteWindowsConfigurationInvalid';}
  }
  Test-Win 'parser XML local e fechado, limitado e nao resolve DTD nem campos remotos' {
    $case=New-WinCase;$xml=New-Object Xml.XmlDocument;$root=$xml.CreateElement('PdvRemoteWindowsPilot');[void]$xml.AppendChild($root);
    foreach($key in $case.Configuration.Keys){$node=$xml.CreateElement($key);$value=$case.Configuration[$key];if($value -is [bool]){$value=$value.ToString().ToLowerInvariant();};$node.InnerText=[string]$value;[void]$root.AppendChild($node);}
    $path=Join-Path $case.Path 'remoto-piloto.xml';$valid=$xml.OuterXml;[IO.File]::WriteAllText($path,$valid);$read=Read-PdvMonitorRemoteWindowsConfiguration $case.Path;Assert-Win ($read.Enabled -and $read.ProfileApproved -and $read.AgentId -ceq $case.Configuration.AgentId) 'Parser nao preservou';
    foreach($text in @($valid.Replace('</PdvRemoteWindowsPilot>','<Command>run</Command></PdvRemoteWindowsPilot>'),$valid.Replace('<Enabled>true</Enabled>','<Enabled>1</Enabled>'),$valid.Replace('<Enabled>true</Enabled>','<Enabled>true</Enabled><Enabled>true</Enabled>'),('<!DOCTYPE PdvRemoteWindowsPilot [<!ENTITY probe SYSTEM "file:///DO-NOT-READ">]>'+$valid),('<PdvRemoteWindowsPilot>'+('x'*16400)+'</PdvRemoteWindowsPilot>'))){[IO.File]::WriteAllText($path,$text);Assert-WinThrows {Read-PdvMonitorRemoteWindowsConfiguration $case.Path;} 'RemoteWindowsConfigurationInvalid';}
  }
  Test-Win 'hash PE e assinatura/publisher exatos obrigatorios' {
    $case=New-WinCase;Assert-Win (Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration) 'Config valida bloqueada';
    $config=$case.Configuration.Clone();$config.StunnelSha256=('0'*64);Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $config;} 'RemoteWindowsBinaryHashMismatch';
    & $module {$script:SignatureStatus=[Management.Automation.SignatureStatus]::NotSigned;};Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsBinarySignatureInvalid';
    & $module {$script:SignatureStatus=[Management.Automation.SignatureStatus]::Valid;$script:SignatureThumbprint=('B'*40);};Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsBinarySignatureInvalid';
  }
  Test-Win 'perfil administrativo exige aprovacao explicita por Windows e arquitetura' {
    $case=New-WinCase;$case.Configuration.ProfileApproved=$false;Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsProfileNotApproved';
    foreach($profile in @('win7-sp1-x86','win7-sp1-x64','win10plus-x86','win10plus-x64')){
      $architecture=$profile.Split('-')[-1];$case=New-WinCase $architecture $profile;
      Assert-Win (Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration) ('Perfil valido bloqueado: '+$profile);
    }
  }
  Test-Win 'PE32 e PE32+ devem corresponder a arquitetura exata sem mistura de cabecalhos' {
    foreach($architecture in @('x86','x64')){
      foreach($target in @('Stunnel','UltraVnc')){
        foreach($headers in @(@{Machine=332;Magic=523},@{Machine=34404;Magic=267},@{Machine=43620;Magic=523},@{Machine=0;Magic=0})){
          $case=New-WinCase $architecture;$exe=$case.Configuration[$target+'Exe'];$bytes=[IO.File]::ReadAllBytes($exe);[BitConverter]::GetBytes([uint16]$headers.Machine).CopyTo($bytes,132);[BitConverter]::GetBytes([uint16]$headers.Magic).CopyTo($bytes,152);[IO.File]::WriteAllBytes($exe,$bytes);$case.Configuration[$target+'Sha256']=& $module {param($Bytes);Get-PdvRemoteWindowsHash $Bytes;} $bytes;
          Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsBinaryArchitecture';
        }
        $case=New-WinCase $architecture;$other=if($architecture -ceq 'x86'){'x64'}else{'x86'};$otherCase=New-WinCase $other;$bytes=[IO.File]::ReadAllBytes($otherCase.Configuration[$target+'Exe']);[IO.File]::WriteAllBytes($case.Configuration[$target+'Exe'],$bytes);$case.Configuration[$target+'Sha256']=& $module {param($Bytes);Get-PdvRemoteWindowsHash $Bytes;} $bytes;
        & $module {param($Architecture,$Profile);$script:TestNativeEvidence.Architecture=$Architecture;$script:TestNativeEvidence.ProcessArchitecture=$Architecture;$script:TestNativeEvidence.CompatibilityProfile=$Profile;} $architecture $case.Configuration.PlatformProfile;
        Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsBinaryArchitecture';
      }
    }
  }
  Test-Win 'runtime desconhecido CLR2 e .NET sem evidencia ou anterior a4.6.2 ficam bloqueados' {
    foreach($probe in @(
      @{Evidence=$null;Reason='RemoteWindowsRuntimeUnknown'},
      @{Evidence=@{Detected=$true;DotNetRelease=528040};Reason='RemoteWindowsRuntimeUnknown'},
      @{Evidence=@{Detected='true';ClrMajor=4;DotNetRelease=528040};Reason='RemoteWindowsRuntimeUnknown'},
      @{Evidence=@{Detected=$true;ClrMajor=4;DotNetRelease='528040'};Reason='RemoteWindowsRuntimeUnknown'},
      @{Evidence=@{Detected=$false;ClrMajor=4;DotNetRelease=528040};Reason='RemoteWindowsRuntimeUnknown'},
      @{Evidence=@{Detected=$true;ClrMajor=2;DotNetRelease=528040};Reason='RemoteWindowsClr4Required'},
      @{Evidence=@{Detected=$true;ClrMajor=4;DotNetRelease=0};Reason='RemoteWindowsDotNetRequired'},
      @{Evidence=@{Detected=$true;ClrMajor=4;DotNetRelease=394801};Reason='RemoteWindowsDotNetRequired'})){
      $case=New-WinCase;& $module {param($Evidence);$script:TestRuntimeEvidence=$Evidence;} $probe.Evidence;
      Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} $probe.Reason;
    }
    foreach($release in @(394802,394806,528040)){
      $case=New-WinCase 'x86' 'win7-sp1-x86';& $module {param($Release);$script:TestRuntimeEvidence.DotNetRelease=$Release;} $release;
      Assert-Win (Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration) ('.NET suportado bloqueado: '+$release);
    }
  }
  Test-Win 'evidencia publica exige perfil compativel e runtime comprovado antes da homologacao' {
    foreach($profile in @('win7-sp1-x86','win7-sp1-x64','win10plus-x86','win10plus-x64')){
      $case=New-WinCase $profile.Split('-')[-1] $profile;
      $unverified=Get-PdvMonitorRemoteWindowsPlatformEvidence;
      Assert-Win ($unverified.Detected -and -not $unverified.CompatibilityVerified) 'Ausencia de perfil afirmou homologacao';
      $verified=Get-PdvMonitorRemoteWindowsPlatformEvidence $case.Configuration;
      Assert-Win ($verified.Detected -and $verified.CompatibilityVerified) 'Perfil valido nao comprovado';
      & $module {$script:TestRuntimeEvidence.DotNetRelease=0;};
      Assert-Win (-not (Get-PdvMonitorRemoteWindowsPlatformEvidence $case.Configuration).CompatibilityVerified) 'Runtime sem .NET afirmou homologacao';
    }
    $case=New-WinCase;$case.Configuration.PlatformProfile='win7-sp1-x64';
    Assert-Win (-not (Get-PdvMonitorRemoteWindowsPlatformEvidence $case.Configuration).CompatibilityVerified) 'Perfil errado afirmou homologacao';
  }
  Test-Win 'perfil aprovado de outro Windows ou arquitetura nao pode habilitar a maquina' {
    foreach($profile in @('win7-sp1-x86','win7-sp1-x64','win10plus-x86')){
      $case=New-WinCase;$case.Configuration.PlatformProfile=$profile;
      Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsPlatformProfileMismatch';
    }
    $case=New-WinCase;& $module {$script:TestNativeEvidence.Supported=$false;$script:TestNativeEvidence.CompatibilityReason='RemoteWindows7ServicePackRequired';};
    Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsPlatformUnsupported';
    foreach($mutation in @(@{Key='ProcessArchitecture';Value='x86'},@{Key='Architecture';Value='arm64'})){
      $case=New-WinCase;& $module {param($Mutation);$script:TestNativeEvidence[$Mutation.Key]=$Mutation.Value;} $mutation;
      Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsPlatformUnsupported';
    }
  }
  Test-Win 'perfil e dependencias em diretorio gravavel pelo usuario sao recusados' {
    $case=New-WinCase;& $module {$script:TestAdministrative=$false;};Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsAdministrativeProfileRequired';
    & $module {$script:TestAdministrative=$true;$script:TestAdministrativeAncestors=$false;};Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsAdministrativeProfileRequired';
  }
  Test-Win 'mascara ACL aceita leitura e execucao sem confundir Modify com escrita' {
    $mask=& $module {Get-PdvRemoteWindowsWriteRights;};
    Assert-Win (($mask -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq 0) 'Mascara recusa leitor';
    foreach($right in @([Security.AccessControl.FileSystemRights]::WriteData,[Security.AccessControl.FileSystemRights]::AppendData,[Security.AccessControl.FileSystemRights]::Delete,[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,[Security.AccessControl.FileSystemRights]::ChangePermissions,[Security.AccessControl.FileSystemRights]::TakeOwnership)){Assert-Win (($mask -band $right) -ne 0) 'Mascara deixou mutacao';}
  }
  Test-Win 'caminhos nao permitem UNC, escape de config e unicode convertido para ASCII' {
    $case=New-WinCase;foreach($path in @('\\server\private.key',($case.Path+'/a;exec=x'),($case.Path+"/a`nexec=x"),($case.Path+'/nao-é-ascii'),($case.Path+"/a`0b"),($case.Path+'/a"b'),'relative/path','')){Assert-WinThrows {& $module {param($Path);Test-PdvRemoteWindowsLocalPath $Path;} $path;} 'RemoteWindowsUnsafePath';}
  }
  Test-Win 'config portable impede fallback e entradas HTTP/LAN, DSM, arquivos ou sem autenticacao' {
    foreach($change in @(@{From='SocketConnect=0';To='SocketConnect=1'},@{From='ReverseAuthRequired=1';To='ReverseAuthRequired=0'},@{From='FileTransferEnabled=0';To='FileTransferEnabled=1'},@{From='UseDSMPlugin=0';To='UseDSMPlugin=1'},@{From='EnableTLS=0';To='EnableTLS=1'},@{From='cloudEnabled=0';To='cloudEnabled=1'},@{From='UseBridge=0';To='UseBridge=1'})){
      $case=New-WinCase;$text=[IO.File]::ReadAllText($case.Configuration.UltraVncIniFile).Replace($change.From,$change.To);[IO.File]::WriteAllText($case.Configuration.UltraVncIniFile,$text);$case.Configuration.UltraVncIniSha256=& $module {param($Path);Get-PdvRemoteWindowsHash ([IO.File]::ReadAllBytes($Path));} $case.Configuration.UltraVncIniFile;
      Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsVncConfigurationUnsafe';
    }
    $case=New-WinCase;[IO.File]::WriteAllText($case.Configuration.PortableMarkerFile,'unexpected');Assert-WinThrows {Test-PdvMonitorRemoteWindowsConfiguration $case.Configuration;} 'RemoteWindowsPortableConfigurationRequired';
  }
  Test-Win 'lease vincula agente, certificado, ID e janela absoluta900s sem URL/comando' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;
    foreach($change in @(@{Key='AgentId';Value='33333333-3333-4333-8333-333333333333'},@{Key='CertificateSha256';Value=('d'*64)},@{Key='RepeaterId';Value='4902'},@{Key='State';Value='closed'},@{Key='Command';Value='x'})){$changed=$lease.Clone();$changed[$change.Key]=$change.Value;Assert-WinThrows {& $module {param($Transport,$Lease);Test-PdvRemoteWindowsLease $Transport $Lease $true;} $transport $changed;} 'RemoteWindowsLeaseMismatch';}
    $changed=$lease.Clone();$changed.ExpiresAt='2026-10-21T16:15:01Z';Assert-WinThrows {& $module {param($Transport,$Lease);Test-PdvRemoteWindowsLease $Transport $Lease $true;} $transport $changed;} 'RemoteWindowsLeaseExpired';
  }
  Test-Win 'broker autorizado e mesma identidade local sao obrigatorios antes de efeito' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;
    foreach($change in @(@{Key='Enabled';Value=$false},@{Key='Healthy';Value=$false},@{Key='Paused';Value=$true},@{Key='Stage';Value='consent_approved'})){$changed=$broker.Clone();$changed[$change.Key]=$change.Value;Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $changed $lease;} 'RemoteWindowsLocalConsentRequired';}
    $broker.Active.LocalIdentity='other';Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsLocalConsentRequired';Assert-Win ($null -eq $transport.Supervisor) 'Criou supervisor antes consentimento';
  }
  Test-Win 'console bloqueada e instancia existente impedem tentativa sem encerrar terceiros' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;& $module {$script:TestUnlocked=$false;};Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsLocalSessionUnavailable';
    & $module {$script:TestUnlocked=$true;$script:TestExisting=$true;};Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsExistingVncInstance';Assert-Win ($null -eq (& $module {$script:LastSupervisor;})) 'Iniciou processo';
  }
  Test-Win 'journal e gravado antes de cada processo, sem segredos; mTLS e CLI fixos' {
    $case=New-WinCase;$active=Start-WinMock $case;$transport=$active.Transport;$supervisor=$transport.Supervisor;
    Assert-Win ($supervisor.Starts -eq 2 -and $transport.Stage -ceq 'active') 'Nao iniciou dois mocks';
    Assert-Win ($supervisor.Children[1].Arguments -ceq '-id:4901 -connect 127.0.0.1::55555 -run') 'Argumentos inseguros';
    foreach($child in $supervisor.Children){Assert-Win ($child.WorkingDirectory -ceq [IO.Path]::GetDirectoryName($child.Executable)) 'CWD nao e do bundle protegido';}
    $text=[IO.File]::ReadAllText((Join-Path $transport.SessionDirectory 'stunnel.conf'));
    foreach($part in @('accept = 127.0.0.1:55555','verifyChain = yes','checkHost = pilot.company.example','sni = pilot.company.example','sslVersionMin = TLSv1.2','sessionResume = no')){Assert-Win ($text.Contains($part)) ('Falta '+$part);}
    $journal=[IO.File]::ReadAllText($transport.JournalPath);foreach($secret in @('NOT-A-REAL-KEY','Tecnico teste','passwd','private.key','CertificateSha256')){Assert-Win (-not $journal.Contains($secret)) 'Journal vazou';}
    $snapshot=Get-PdvMonitorRemoteWindowsTransportSnapshot $transport;Assert-Win (-not $snapshot.Connected -and -not $snapshot.LocalProcessesStopped) 'Declarou desktop conectado';[void](Stop-PdvMonitorRemoteWindowsTransport $transport);
    Assert-Win ($supervisor.Closed -and $supervisor.Disposed -and -not [IO.File]::Exists($transport.JournalPath)) 'Nao limpou';
  }
  Test-Win 'diagnostico de inicio preserva codigos seguros encapsulados sem vazar segredo' {
    foreach($mapping in @(@{Native='RemoteNestedJobUnsupported';Expected='RemoteWindowsNestedJobUnsupported'},@{Native='RemoteJobInspectionFailed';Expected='RemoteWindowsJobInspectionFailed'})){
      $inner=New-Object InvalidOperationException($mapping.Native);$middle=New-Object Exception('Wrapper com PRIVATE-SECRET',$inner);$outer=New-Object Exception('Wrapper externo',$middle);
      $reason=& $module {param($Exception);Get-PdvRemoteWindowsStartFailureReason $Exception;} $outer;
      Assert-Win ($reason -ceq $mapping.Expected) 'Erro nativo encapsulado perdeu diagnostico';
    }
    $exception=New-Object Exception('RemoteWindowsBinarySignatureInvalid');
    Assert-Win ((& $module {param($Exception);Get-PdvRemoteWindowsStartFailureReason $Exception;} $exception) -ceq 'RemoteWindowsBinarySignatureInvalid') 'Codigo direto seguro nao preservado';
    foreach($message in @('PRIVATE-SECRET senha=nao-expor','RemoteWindowsNestedJobUnsupported PRIVATE-SECRET',('RemoteWindows'+('A'*81)))){
      $exception=New-Object Exception($message);$reason=& $module {param($Exception);Get-PdvRemoteWindowsStartFailureReason $Exception;} $exception;
      Assert-Win ($reason -ceq 'RemoteWindowsTransportStartFailed') 'Texto livre ou codigo fora do limite vazou';
    }
    $chain=New-Object Exception('RemoteNestedJobUnsupported');for($depth=0;$depth -lt 7;$depth++){$chain=New-Object Exception('Wrapper',$chain);};
    Assert-Win ((& $module {param($Exception);Get-PdvRemoteWindowsStartFailureReason $Exception;} $chain) -ceq 'RemoteWindowsNestedJobUnsupported') 'Oitavo nivel valido nao lido';
    $chain=New-Object Exception('Wrapper',$chain);
    Assert-Win ((& $module {param($Exception);Get-PdvRemoteWindowsStartFailureReason $Exception;} $chain) -ceq 'RemoteWindowsTransportStartFailed') 'Percorreu alem de oito niveis';
    Assert-Win ((& $module {Get-PdvRemoteWindowsStartFailureReason $null;}) -ceq 'RemoteWindowsTransportStartFailed') 'Excecao ausente nao recebeu erro generico';
  }
  Test-Win 'Start conserva motivo do job e limpa diario antes de qualquer processo' {
    foreach($mapping in @(@{Native='RemoteNestedJobUnsupported';Expected='RemoteWindowsNestedJobUnsupported'},@{Native='RemoteJobInspectionFailed';Expected='RemoteWindowsJobInspectionFailed'})){
      $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;
      $inner=New-Object InvalidOperationException($mapping.Native);$middle=New-Object Exception('Wrapper com PRIVATE-SECRET',$inner);$outer=New-Object Exception('Wrapper externo',$middle);
      & $module {param($Exception);$script:TestSupervisorException=$Exception;} $outer;
      Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} $mapping.Expected;
      Assert-Win ($null -eq $transport.Supervisor -and $transport.Stage -ceq 'closed' -and -not [IO.File]::Exists($transport.JournalPath)) 'Falha de job criou processo ou conservou sessao ativa';
    }
  }
  Test-Win 'listener deve pertencer ao stunnel criado antes de encaminhar UltraVNC' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;& $module {$script:TestListener=$false;};
    Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsTunnelListenerUnavailable';$supervisor=& $module {$script:LastSupervisor;};Assert-Win ($supervisor.Starts -eq 1 -and $supervisor.Closed) 'VNC iniciou sem tunnel proprio';
  }
  Test-Win 'falha journal antes de iniciar nao cria processos e perda journal para mesmo assim' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;& $module {$script:TestFailJournalStage='starting_tunnel';};
    Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsJournalWriteFailed';$supervisor=& $module {$script:LastSupervisor;};Assert-Win ($supervisor.Starts -eq 0 -and $supervisor.Closed) 'Falha iniciou processo';
    $case=New-WinCase;$active=Start-WinMock $case;$supervisor=$active.Transport.Supervisor;& $module {$script:TestFailJournalStage='closing';};[void](Stop-PdvMonitorRemoteWindowsTransport $active.Transport);Assert-Win ($supervisor.Closed -and $active.Transport.Stage -ceq 'interrupted') 'Disco impediu parada';
  }
  Test-Win 'segunda instancia sem exclusividade nao sobrescreve nem apaga journal da primeira' {
    $case=New-WinCase;$first=New-WinTransport $case;$second=New-WinTransport $case;$leaseA=New-WinLease $case;$brokerA=New-WinBroker $case $leaseA;
    [void](Start-PdvMonitorRemoteWindowsTransport $first $brokerA $leaseA);$before=[IO.File]::ReadAllText($first.JournalPath);$leaseB=New-WinLease $case;$brokerB=New-WinBroker $case $leaseB;
    & $module {$script:TestMutexDenied=$true;};Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $second $brokerB $leaseB;} 'RemoteWindowsExistingVncInstance';Assert-Win ([IO.File]::ReadAllText($first.JournalPath) -ceq $before) 'Sem mutex alterou journal';
    & $module {$script:TestMutexDenied=$false;};Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $second $brokerB $leaseB;} 'RemoteWindowsInterruptedTransport';Assert-Win ([IO.File]::ReadAllText($first.JournalPath) -ceq $before) 'Sem ownership apagou journal';
    Assert-Win ($first.JournalOwned -and $first.MutexAcquired -and -not $second.JournalOwned -and -not $second.MutexAcquired) 'Ownership misturado';[void](Stop-PdvMonitorRemoteWindowsTransport $first);
  }
  Test-Win 'cleanup bloqueado apos parada preserva journal e estado interrompido, nunca active' {
    $case=New-WinCase;$active=Start-WinMock $case;$transport=$active.Transport;$supervisor=$transport.Supervisor;$unexpected=Join-Path $transport.SessionDirectory 'arquivo-adicional';[IO.File]::WriteAllText($unexpected,'retain-for-review');
    $snapshot=Stop-PdvMonitorRemoteWindowsTransport $transport;Assert-Win ($supervisor.Closed -and $snapshot.LocalProcessesStopped -and $snapshot.Stage -ceq 'interrupted' -and [IO.File]::Exists($transport.JournalPath)) 'Cleanup declarou estado incorreto';Assert-Win (-not $transport.MutexAcquired -and $null -eq $transport.Supervisor) 'Nao liberou ownership';
    Assert-Win ([IO.File]::Exists($unexpected)) 'Apagou arquivo desconhecido';
  }
  Test-Win 'diretorio preexistente da sessao e recusado sem apagar configuracao alheia' {
    $case=New-WinCase;$transport=New-WinTransport $case;$lease=New-WinLease $case;$broker=New-WinBroker $case $lease;$existing=Join-Path $case.Path ('remoto-'+$lease.SessionId);[void][IO.Directory]::CreateDirectory($existing);$file=Join-Path $existing 'stunnel.conf';[IO.File]::WriteAllText($file,'DO-NOT-DELETE');
    Assert-WinThrows {Start-PdvMonitorRemoteWindowsTransport $transport $broker $lease;} 'RemoteWindowsSessionDirectoryExists';Assert-Win ([IO.File]::ReadAllText($file) -ceq 'DO-NOT-DELETE' -and -not $transport.SessionDirectoryOwned) 'Apagou pasta sem ownership';
  }
  Test-Win 'somente novo lease autenticado renova heartbeat e prazo nao aumenta' {
    $case=New-WinCase;$active=Start-WinMock $case;$supervisor=$active.Transport.Supervisor;[void](Get-PdvMonitorRemoteWindowsTransportSnapshot $active.Transport);Assert-Win ($supervisor.HeartbeatCount -eq 0) 'Snapshot renovou heartbeat';
    [void](Update-PdvMonitorRemoteWindowsTransport $active.Transport $active.Lease);Assert-Win ($supervisor.HeartbeatCount -eq 1) 'Lease nao renovou';
    $changed=$active.Lease.Clone();$changed.ExpiresAt='2026-10-21T16:14:00Z';Assert-WinThrows {Update-PdvMonitorRemoteWindowsTransport $active.Transport $changed;} 'RemoteWindowsAuthorizationLost';Assert-Win $supervisor.Closed 'Mudanca nao fechou';
  }
  Test-Win 'fechamento exige comprovacao local antes de closed e conserva journal se falhar' {
    $case=New-WinCase;$active=Start-WinMock $case;& $module {$script:TestCannotStop=$true;};Assert-WinThrows {Stop-PdvMonitorRemoteWindowsTransport $active.Transport;} 'RemoteWindowsProcessesStillRunning';Assert-Win (-not $active.Transport.LocalProcessesStopped -and [IO.File]::Exists($active.Transport.JournalPath)) 'Fechou sem confirmar';
    & $module {$script:TestCannotStop=$false;};[void](Stop-PdvMonitorRemoteWindowsTransport $active.Transport);
  }
  Test-Win 'interrupcao nao retoma, nao mata PID e exige estado terminal central' {
    $case=New-WinCase;$active=Start-WinMock $case;$old=$active.Transport;$supervisor=$old.Supervisor;$supervisor.Stop('HostClosed');foreach($lock in $old.Locks){$lock.Dispose();};$old.Locks=@();$old.Mutex.ReleaseMutex();$old.Mutex.Dispose();$old.Mutex=$null;
    $reloaded=New-WinTransport $case;Assert-Win ($reloaded.Stage -ceq 'interrupted' -and $reloaded.SessionId -ceq $active.Lease.SessionId -and $null -eq $reloaded.Supervisor) 'Retomou';
    Assert-WinThrows {Resolve-PdvMonitorRemoteWindowsInterruptedTransport $reloaded $reloaded.SessionId 'approved';} 'RemoteWindowsInterruptedAcknowledgementInvalid';
    & $module {$script:TestExisting=$true;};Assert-WinThrows {Resolve-PdvMonitorRemoteWindowsInterruptedTransport $reloaded $reloaded.SessionId 'closed';} 'RemoteWindowsExistingVncInstance';
    $unresolved=Stop-PdvMonitorRemoteWindowsTransport $reloaded;Assert-Win (-not $unresolved.LocalProcessesStopped -and $unresolved.Stage -ceq 'interrupted' -and [IO.File]::Exists($reloaded.JournalPath)) 'Stop resolveu interrupcao sem evidencia';
    & $module {$script:TestExisting=$false;};[void](Resolve-PdvMonitorRemoteWindowsInterruptedTransport $reloaded $reloaded.SessionId 'closed');Assert-Win ($reloaded.Stage -ceq 'closed' -and $reloaded.LocalProcessesStopped -and -not [IO.File]::Exists($reloaded.JournalPath)) 'Nao resolveu';
  }
  Test-Win 'diario corrompido bloqueia e nao e interpretado como comando' {
    $case=New-WinCase;[IO.File]::WriteAllText((Join-Path $case.Path 'remoto-transporte.xml'),'<PdvRemoteTransport command="kill"/>');$reloaded=New-WinTransport $case;Assert-Win ($reloaded.Stage -ceq 'blocked' -and -not $reloaded.LocalProcessesStopped) 'Journal corrompido liberou';
  }
  Test-Win 'supervisor nativo compila sem executar PInvoke no ambiente de desenvolvimento' {
    $path=Join-Path $directory 'piloto-remoto/windows/RemoteWindowsNative.cs';Add-Type -TypeDefinition ([IO.File]::ReadAllText($path)) -Language CSharp -ErrorAction Stop;Assert-Win ($null -ne ('Conecta.PdvRemotePilot.LeaseSupervisor' -as [type])) 'Nao compilou';
  }
  Test-Win 'politica nativa permite somente Win7SP1 e Win10/11 com processo CLR4 da mesma arquitetura' {
    foreach($row in @(
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='x86';Process='x86';Clr=4;Reason='';Profile='win7-sp1-x86'},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='x64';Process='x64';Clr=4;Reason='';Profile='win7-sp1-x64'},
      @{Major=10;Minor=0;Build=10240;Sp=0;Product=1;Native='x86';Process='x86';Clr=4;Reason='';Profile='win10plus-x86'},
      @{Major=10;Minor=0;Build=19045;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='';Profile='win10plus-x64'},
      @{Major=10;Minor=0;Build=22000;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='';Profile='win10plus-x64'},
      @{Major=6;Minor=1;Build=7600;Sp=0;Product=1;Native='x86';Process='x86';Clr=4;Reason='RemoteWindows7ServicePackRequired';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteWindows7ServicePackRequired';Profile=''},
      @{Major=6;Minor=1;Build=7600;Sp=1;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteWindows7ServicePackRequired';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=2;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteWindows7ServicePackRequired';Profile=''},
      @{Major=6;Minor=0;Build=6002;Sp=2;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedOperatingSystem';Profile=''},
      @{Major=6;Minor=2;Build=9200;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedOperatingSystem';Profile=''},
      @{Major=6;Minor=3;Build=9600;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedOperatingSystem';Profile=''},
      @{Major=10;Minor=0;Build=10239;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedOperatingSystem';Profile=''},
      @{Major=11;Minor=0;Build=26000;Sp=0;Product=1;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedOperatingSystem';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=3;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedWindowsProduct';Profile=''},
      @{Major=10;Minor=0;Build=20348;Sp=0;Product=3;Native='x64';Process='x64';Clr=4;Reason='RemoteUnsupportedWindowsProduct';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='arm64';Process='arm64';Clr=4;Reason='RemoteUnsupportedArchitecture';Profile=''},
      @{Major=10;Minor=0;Build=22000;Sp=0;Product=1;Native='unknown';Process='x64';Clr=4;Reason='RemoteUnsupportedArchitecture';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='x64';Process='x86';Clr=4;Reason='RemoteProcessArchitectureMismatch';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='x86';Process='x64';Clr=4;Reason='RemoteProcessArchitectureMismatch';Profile=''},
      @{Major=6;Minor=1;Build=7601;Sp=1;Product=1;Native='x64';Process='x64';Clr=2;Reason='RemoteUnsupportedClr';Profile=''},
      @{Major=10;Minor=0;Build=19045;Sp=0;Product=1;Native='x64';Process='x64';Clr=0;Reason='RemoteUnsupportedClr';Profile=''})){
      $reason=[Conecta.PdvRemotePilot.DesktopEvidence]::CompatibilityReason($row.Major,$row.Minor,$row.Build,$row.Sp,$row.Product,$row.Native,$row.Process,$row.Clr,0);
      $supported=[Conecta.PdvRemotePilot.DesktopEvidence]::IsSupportedPlatform($row.Major,$row.Minor,$row.Build,$row.Sp,$row.Product,$row.Native,$row.Process,$row.Clr,0);
      $profile=[Conecta.PdvRemotePilot.DesktopEvidence]::PlatformProfile($row.Major,$row.Minor,$row.Build,$row.Sp,$row.Product,$row.Native,$row.Process,$row.Clr,0);
      Assert-Win ($reason -ceq $row.Reason) ('Motivo plataforma inesperado: '+$reason+' / '+$row.Reason);
      Assert-Win ($supported -eq ($row.Reason -ceq '')) 'Booleano nao corresponde ao motivo';
      Assert-Win ($profile -ceq $row.Profile) ('Perfil plataforma inesperado: '+$profile);
    }
    Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::SupportsNestedJobs(6,1)) 'Windows7 recebeu jobs aninhados';
    Assert-Win ([Conecta.PdvRemotePilot.DesktopEvidence]::SupportsNestedJobs(10,0)) 'Windows10 perdeu politica de jobs';
  }
  Test-Win 'politica nativa de listeners rejeita IPv4 externo, qualquer IPv6 VNC e tabela invalida' {
    $table=New-Object byte[] 28;[BitConverter]::GetBytes([int]1).CopyTo($table,0);[BitConverter]::GetBytes([int]2).CopyTo($table,4);$table[8]=127;$table[11]=1;$table[12]=217;$table[13]=3;[BitConverter]::GetBytes([int]101).CopyTo($table,24);
    Assert-Win ([Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($table,$false,101,55555)) 'Loopback proprio bloqueado';
    Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($table,$false,101,0)) 'VNC listener foi permitido';
    Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($table,$false,101,55556)) 'Porta alheia permitida';
    $table[8]=0;$table[11]=0;Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($table,$false,101,55555)) 'Wildcard permitido';
    Assert-Win ([Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($table,$false,102,0)) 'Confundiu processo alheio';
    $v6=New-Object byte[] 60;[BitConverter]::GetBytes([int]1).CopyTo($v6,0);[BitConverter]::GetBytes([int]101).CopyTo($v6,56);Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($v6,$true,101,55555)) 'IPv6 foi permitido';
    foreach($bad in @((New-Object byte[] 3),([byte[]]@(255,255,255,127)),([byte[]]@(255,255,255,255)))){Assert-Win (-not [Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe($bad,$false,101,0)) 'Tabela invalida liberada';}
    Assert-Win ([Conecta.PdvRemotePilot.DesktopEvidence]::ListenerTableSafe((New-Object byte[] 4),$true,101,0)) 'Tabela vazia bloqueada';
  }
}finally{
  & $module {if($null -ne $script:LastSupervisor){$script:LastSupervisor.Stop('HostClosed');}};
  [IO.Directory]::Delete($temporary,$true);
}
if($failures.Count){foreach($failure in $failures){Write-Error $failure -ErrorAction Continue;};throw ($failures.Count.ToString()+' caso(s) falharam');}
Write-Output ('PASS: '+$script:Cases+' casos; '+$script:Checks+' verificacoes offline. Nenhum processo/Windows real.');
