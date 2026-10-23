#requires -Version 2.0
# Nenhum segredo e aceito por argumento. Executar somente a copia administrativa.
$ErrorActionPreference='Stop';
$activation=$null;$pointer=[IntPtr]::Zero;$agentId='';$lock=$null;
try{
  if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WindowsRequired';}
  $common=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData);$remote=Join-Path $common 'Feirao\PdvMonitorRemoto';$app=Join-Path $remote 'app';$modulePath=Join-Path $app 'PdvMonitor.Remoto.Inscricao.psm1';$scriptPath=Join-Path $app 'piloto-remoto\windows\AtivarCertificadoRemoto.ps1';
  if([IO.Path]::GetFullPath($MyInvocation.MyCommand.Path) -cne [IO.Path]::GetFullPath($scriptPath)){throw 'AdministrativeInstalledCopyRequired';}
  # Verifica a fronteira antes de importar codigo de uma instalacao local.
  $trusted=@('S-1-5-18','S-1-5-32-544');$installer=New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller');$ancestorTrusted=$trusted+$installer.Translate([Security.Principal.SecurityIdentifier]).Value;
  foreach($path in @($modulePath,$scriptPath)){
    $probe=$path;$depth=0;while($probe){
      if(([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'AdministrativeInstalledCopyRequired';}
      $acl=Get-Acl -LiteralPath $probe -ErrorAction Stop;$allowed=$trusted;$rights=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;
      if($depth -gt 1){$allowed=$ancestorTrusted;$rights=[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership;}
      if($allowed -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'AdministrativeInstalledCopyRequired';}
      foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if(($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){continue;};if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ($rule.FileSystemRights -band $rights) -ne 0 -and $allowed -cnotcontains $rule.IdentityReference.Value){throw 'AdministrativeInstalledCopyRequired';}}
      $parent=[IO.Path]::GetDirectoryName($probe);if($parent -ceq $probe){break;};$probe=$parent;$depth++;
    }
  }
  Import-Module $modulePath -Force;
  $trust=Read-PdvMonitorRemoteEnrollmentTrust (Join-Path $app 'piloto-remoto\windows\inscricao-confianca.xml');
  Write-Host 'Certificado exclusivo do computador - Conecta';Write-Host 'Gere o codigo de ativacao na instalacao correta no Conecta. O codigo nao aparece na tela.';
  $activation=Read-Host 'Codigo de ativacao' -AsSecureString;
  $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($activation);$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);
  try{if($plain -cnotmatch '^([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.[A-Za-z0-9_-]{43}$'){throw 'InvalidActivationCode';};$agentId=$matches[1];}finally{$plain=$null;[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$pointer=[IntPtr]::Zero;}
  $accountName=Read-Host 'Conta Windows que executa o monitor (exemplo LOJA\Caixa; confirme com a manutencao)';$account=New-Object Security.Principal.NTAccount($accountName);$sid=$account.Translate([Security.Principal.SecurityIdentifier]).Value;if($sid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'InvalidMonitorUserSid';}
  $identities=Join-Path $remote 'identities';if(-not [IO.Directory]::Exists($identities)){[Conecta.PdvRemoteEnrollment.StorageV1]::CreateDirectoryForUser($identities,$sid);}
  # Exclusao mutua da ativacao; diretorio administrativo protege o arquivo de lock.
  $lockPath=Join-Path $remote 'enrollment.lock';$lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);[Conecta.PdvRemoteEnrollment.StorageV1]::AssertSingleLink($lock.SafeFileHandle);
  $request=New-PdvMonitorRemoteEnrollmentRequest (Join-Path $identities $agentId) $agentId ([Guid]::NewGuid().ToString('D')) $sid;
  $result=Invoke-PdvMonitorRemoteEnrollment $request $trust $activation;
  Write-Host ('Certificado instalado para a instalacao '+$result.AgentId+'.');Write-Host 'A chave foi gerada neste computador e permanece aqui. O acesso remoto aguarda perfil e componentes aprovados.';
}catch{
  # Nao imprime excecao HTTP, corpo recebido, CSR, codigo ou chave.
  Write-Host 'Nao foi possivel concluir a ativacao. Verifique elevacao, instalacao administrativa, codigo valido e conectividade. Uma tentativa incompleta e preservada para repetir com a mesma identidade.';
  exit 1;
}finally{if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);};if($null -ne $activation){$activation.Dispose();};if($null -ne $lock){$lock.Close();}}
