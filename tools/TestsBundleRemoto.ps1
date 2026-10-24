#requires -Version 5.1
# Testes isolados: bytes sinteticos e Authenticode simulado; nunca executa binarios.
$ErrorActionPreference = 'Stop';
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Execute estes testes isolados no runner Windows.'; }
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'ValidarBundleRemoto.ps1');
$script:Count = 0; $script:SignatureCount = 0; $script:SignatureValid = $true;
function Assert-Test { param([bool]$Condition, [string]$Name); if (-not $Condition) { throw ('FAIL: ' + $Name); }; $script:Count++; }
function Assert-Refused { param([scriptblock]$Action, [string]$Name); $refused = $false; try { & $Action; } catch { $refused = $true; }; Assert-Test $refused $Name; }
$work = Join-Path ([IO.Path]::GetTempPath()) ('pdv-bundle-unit-' + [Guid]::NewGuid().ToString('N'));
[void][IO.Directory]::CreateDirectory($work); $directory = Join-Path $work 'bundle'; [void][IO.Directory]::CreateDirectory($directory);
try {
  $xml = New-Object Xml.XmlDocument; $xml.Load((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'remoto-bundle-lock.xml'));
  foreach ($node in @($xml.DocumentElement.Files.File)) {
    if ($node.GetAttribute('authPolicy') -ceq 'covered-by-signed-container' -or $node.GetAttribute('path').StartsWith('sources/')) { [void]$node.ParentNode.RemoveChild($node); continue; }
    $name = $node.GetAttribute('path');
    if ($name.EndsWith('.exe') -or $name.EndsWith('.dll')) {
      $bytes = New-Object byte[] 256; $bytes[0] = 77; $bytes[1] = 90; $bytes[60] = 128; $bytes[128] = 80; $bytes[129] = 69; $bytes[132] = 100; $bytes[133] = 134;
    } else { $bytes = [Text.Encoding]::ASCII.GetBytes('SYNTHETIC LICENSE FIXTURE'); }
    $node.SetAttribute('sha256', (Get-PdvBundleSha256 $bytes)); $node.SetAttribute('sizeBytes', [string]$bytes.Length);
    $path = Join-Path $directory $name; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)); [IO.File]::WriteAllBytes($path, $bytes);
  }
  $trusted = Join-Path $work 'trusted.xml'; $manifest = Join-Path $directory 'remoto-bundle.xml';
  function Save-FixtureManifest { [IO.File]::WriteAllBytes($trusted,[Text.Encoding]::UTF8.GetBytes($xml.OuterXml)); [IO.File]::WriteAllBytes($manifest, [IO.File]::ReadAllBytes($trusted)); }
  Save-FixtureManifest;
  function Get-AuthenticodeSignature {
    param([string]$LiteralPath);
    $script:SignatureCount++;
    $relative = $LiteralPath.Substring($directory.Length + 1).Replace('\', '/');
    $entry = @($xml.DocumentElement.Files.File | Where-Object { $_.GetAttribute('path') -ceq $relative })[0];
    $status = [Management.Automation.SignatureStatus]::Valid; if (-not $script:SignatureValid) { $status = [Management.Automation.SignatureStatus]::HashMismatch; }
    return @{ Status = $status; SignerCertificate = @{ Thumbprint = $entry.GetAttribute('publisherThumbprint') } };
  }
  $result = Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -ProfileId 'win10plus-x64';
  Assert-Test ($result.Files.Count -eq 13) 'todos os arquivos e licencas';
  Assert-Test ($script:SignatureCount -eq 6) 'cada PE usa Authenticode';
  Assert-Refused { Assert-PdvRemoteBundle $directory $trusted 'win7-sp1-x86' } 'x86 nao aprovado';
  $script:SignatureValid = $false;
  Assert-Refused { Assert-PdvRemoteBundle $directory $trusted } 'assinatura invalida recusa';
  $script:SignatureValid = $true;
  $exe = Join-Path $directory 'bin/ultravnc/winvnc.exe'; $before = [IO.File]::ReadAllBytes($exe); [IO.File]::WriteAllText($exe, 'tamper');
  Assert-Refused { Assert-PdvRemoteBundle $directory $trusted } 'hash adulterado recusa'; [IO.File]::WriteAllBytes($exe, $before);
  $ini = Join-Path $directory 'bin/ultravnc/ultravnc.ini'; $portable = Join-Path $directory 'bin/ultravnc/ultravnc.portable';
  [IO.File]::WriteAllText($ini, '[UltraVNC]'); [IO.File]::WriteAllBytes($portable, (New-Object byte[] 0));
  Assert-Refused { Assert-PdvRemoteBundle $directory $trusted } 'pacote com perfil ativo recusa';
  $result = Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -AllowRuntimeConfiguration;
  Assert-Test ($result.RuntimeFiles.Count -eq 2) 'runtime aceita somente os dois arquivos proprios';
  [IO.File]::WriteAllText($portable, 'not empty');
  Assert-Refused { Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -AllowRuntimeConfiguration } 'portable precisa ser vazio';
  [IO.File]::WriteAllBytes($portable, (New-Object byte[] 0));
  $unknown = Join-Path $directory 'bin/ultravnc/evil.dll'; [IO.File]::WriteAllText($unknown, 'unknown');
  Assert-Refused { Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -AllowRuntimeConfiguration } 'runtime recusa DLL desconhecida';
  [IO.File]::Delete($unknown);
  $first = @($xml.DocumentElement.Files.File)[0]; $beforePolicy = $first.GetAttribute('authPolicy'); $first.SetAttribute('authPolicy', 'sha256'); Save-FixtureManifest;
  Assert-Refused { Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -AllowRuntimeConfiguration } 'PE sem assinatura nao vira arquivo de dados';
  $first.SetAttribute('authPolicy', $beforePolicy); Save-FixtureManifest;
  [IO.File]::AppendAllText($manifest, 'tamper');
  Assert-Refused { Assert-PdvRemoteBundle -BundleDirectory $directory -TrustedManifestPath $trusted -AllowRuntimeConfiguration } 'manifesto divergente recusa';
  Write-Output ('PASS: ' + $script:Count + ' verificacoes isoladas de bundle (assinaturas simuladas).');
} finally { if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work, $true); } }
