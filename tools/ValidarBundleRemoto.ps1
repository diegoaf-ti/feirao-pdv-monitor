#requires -Version 2.0
# Somente leitura. Pode ser dot-sourced pelo instalador; nao inicia binarios.
param([string]$BundleDirectory, [string]$TrustedManifestPath, [string]$ProfileId, [switch]$AllowRuntimeConfiguration, [string]$SourceArtifactPath);

function Get-PdvBundleSha256 {
  param([byte[]]$Bytes);
  $hash = [Security.Cryptography.SHA256]::Create();
  try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant(); }
  finally { $hash.Dispose(); }
}
function Assert-PdvBundleRegularPath {
  param([string]$Path);
  $full = [IO.Path]::GetFullPath($Path); $probe = $full;
  while ($probe) {
    if ([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)) {
      if (([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'RemoteBundleReparsePoint'; }
    }
    $parent = [IO.Path]::GetDirectoryName($probe); if ($parent -ceq $probe) { break; }; $probe = $parent;
  }
  return $full;
}
function Assert-PdvBundleAttributes {
  param($Node, [string[]]$Allowed);
  if ($Node.Attributes.Count -ne $Allowed.Count) { throw 'RemoteBundleAttributes'; }
  foreach ($attribute in $Node.Attributes) { if ($Allowed -cnotcontains $attribute.Name) { throw 'RemoteBundleAttributes'; } }
}
function Assert-PdvRemoteSourceArtifact {
  param([string]$Path);
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'RemoteBundleAuthenticodeRequiresWindows'; }
  $full = Assert-PdvBundleRegularPath $Path;
  if (-not [IO.File]::Exists($full) -or ([IO.FileInfo]$full).Length -ne 4011024 -or (Get-PdvBundleSha256 ([IO.File]::ReadAllBytes($full))) -cne '722c1ad626919af2b0034666b4d19cc4795e925c32f60e8f3c59af4fb3ad2dfc') { throw 'RemoteBundleSourceArtifact'; }
  $signature = Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop;
  if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne '52080A81F4A29130C44554D0264CC1E2786DEE85') { throw 'RemoteBundleSourceSignature'; }
}
function Assert-PdvRemoteBundle {
  param([string]$BundleDirectory, [string]$TrustedManifestPath, [string]$ProfileId, [switch]$AllowRuntimeConfiguration);
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'RemoteBundleAuthenticodeRequiresWindows'; }
  $rootPath = Assert-PdvBundleRegularPath $BundleDirectory;
  $trustedPath = Assert-PdvBundleRegularPath $TrustedManifestPath;
  $manifestPath = Assert-PdvBundleRegularPath ([IO.Path]::Combine($rootPath, 'remoto-bundle.xml'));
  if (-not [IO.Directory]::Exists($rootPath) -or -not [IO.File]::Exists($trustedPath) -or -not [IO.File]::Exists($manifestPath)) { throw 'RemoteBundleMissing'; }
  if (([IO.FileInfo]$trustedPath).Length -lt 1 -or ([IO.FileInfo]$trustedPath).Length -gt 32768 -or ([IO.FileInfo]$manifestPath).Length -lt 1 -or ([IO.FileInfo]$manifestPath).Length -gt 32768) { throw 'RemoteBundleManifestSize'; }
  $raw = [IO.File]::ReadAllBytes($trustedPath);
  if ($raw.Length -lt 1 -or $raw.Length -gt 32768) { throw 'RemoteBundleManifestSize'; }
  $manifestBytes = [IO.File]::ReadAllBytes($manifestPath);
  $manifestHash = Get-PdvBundleSha256 $raw;
  if ($manifestBytes.Length -ne $raw.Length -or (Get-PdvBundleSha256 $manifestBytes) -cne $manifestHash) { throw 'RemoteBundleUnknownManifest'; }
  $text = [Text.Encoding]::UTF8.GetString($raw);
  if ($text.IndexOf('<!', [StringComparison]::Ordinal) -ge 0) { throw 'RemoteBundleXmlDeclaration'; }
  $settings = New-Object Xml.XmlReaderSettings; $settings.ProhibitDtd = $true; $settings.XmlResolver = $null;
  $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($text)), $settings);
  try { $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null; $xml.Load($reader); } finally { $reader.Close(); }
  $root = $xml.DocumentElement;
  Assert-PdvBundleAttributes $root @('schemaVersion', 'id');
  if ($root.Name -cne 'PdvRemoteBundle' -or $root.GetAttribute('schemaVersion') -cne '1' -or $root.GetAttribute('id') -cnotmatch '^[a-z0-9][a-z0-9.-]{1,100}$') { throw 'RemoteBundleSchema'; }
  $children = @($root.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element });
  if ($children.Count -ne 2 -or $children[0].Name -cne 'Profiles' -or $children[1].Name -cne 'Files' -or $children[0].Attributes.Count -ne 0 -or $children[1].Attributes.Count -ne 0) { throw 'RemoteBundleSchema'; }
  $profiles = @();
  foreach ($node in $children[0].ChildNodes) {
    if ($node.NodeType -eq [Xml.XmlNodeType]::Whitespace) { continue; }
    Assert-PdvBundleAttributes $node @('id');
    $id = $node.GetAttribute('id');
    if ($node.Name -cne 'Profile' -or $node.HasChildNodes -or @('win7-sp1-x64', 'win10plus-x64') -cnotcontains $id -or $profiles -ccontains $id) { throw 'RemoteBundleProfile'; }
    $profiles += $id;
  }
  if ($profiles.Count -lt 1 -or $profiles.Count -gt 4 -or ($ProfileId -and $profiles -cnotcontains $ProfileId)) { throw 'RemoteBundleUnsupportedProfile'; }
  $entries = @(); $names = @{}; $total = [long]0;
  foreach ($node in $children[1].ChildNodes) {
    if ($node.NodeType -eq [Xml.XmlNodeType]::Whitespace) { continue; }
    $name = $node.GetAttribute('path'); $policy = $node.GetAttribute('authPolicy');
    $allowed = @('path', 'sha256', 'sizeBytes', 'authPolicy');
    if ($policy -ceq 'authenticode') { $allowed += @('machine', 'publisherThumbprint'); }
    elseif ($policy -ceq 'covered-by-signed-container') { $allowed += @('machine', 'sourceArtifact'); }
    elseif ($policy -cne 'sha256') { throw 'RemoteBundleAuthenticationPolicy'; }
    Assert-PdvBundleAttributes $node $allowed;
    if ($node.Name -cne 'File' -or $node.HasChildNodes -or $name -cnotmatch '^(bin/(ultravnc|stunnel)/[A-Za-z0-9][A-Za-z0-9_.-]{0,80}|licenses/[A-Za-z0-9][A-Za-z0-9_.-]{0,100}|sources/stunnel-5\.82-win64-installer\.exe)$' -or $names.ContainsKey($name) -or $node.GetAttribute('sha256') -cnotmatch '^[0-9a-f]{64}$' -or $node.GetAttribute('sizeBytes') -cnotmatch '^[1-9][0-9]{0,8}$') { throw 'RemoteBundleFileEntry'; }
    $size = [long]$node.GetAttribute('sizeBytes'); $total += $size;
    if ($size -gt 33554432 -or $total -gt 67108864) { throw 'RemoteBundleSize'; }
    $isPe = $name.EndsWith('.exe', [StringComparison]::Ordinal) -or $name.EndsWith('.dll', [StringComparison]::Ordinal);
    if ($isPe) {
      $machine = $node.GetAttribute('machine');
      if ($machine -cne '34404' -and -not ($name -ceq 'sources/stunnel-5.82-win64-installer.exe' -and $machine -ceq '332')) { throw 'RemoteBundleMachine'; }
      if ($policy -ceq 'authenticode') {
        if ($node.GetAttribute('publisherThumbprint') -cnotmatch '^[0-9A-F]{40}$') { throw 'RemoteBundlePublisher'; }
      } elseif ($policy -ceq 'covered-by-signed-container') {
        if ($name -cne 'bin/stunnel/libssp-0.dll' -or $node.GetAttribute('sha256') -cne '43ac5e338e3e05d2da19c48eef21f65b3e1833be0bc9c5735465f2935b371754' -or $node.GetAttribute('sourceArtifact') -cne 'sources/stunnel-5.82-win64-installer.exe') { throw 'RemoteBundleContainerException'; }
      } else { throw 'RemoteBundleUnsignedExecutable'; }
    } elseif ($policy -cne 'sha256' -or -not $name.StartsWith('licenses/', [StringComparison]::Ordinal)) { throw 'RemoteBundleNonExecutable'; }
    $path = Assert-PdvBundleRegularPath ([IO.Path]::Combine($rootPath, $name.Replace('/', [IO.Path]::DirectorySeparatorChar)));
    if (-not [IO.File]::Exists($path)) { throw ('RemoteBundleFileMissing:' + $name); }
    if (([IO.FileInfo]$path).Length -ne $size) { throw ('RemoteBundleSizeMismatch:' + $name); }
    $bytes = [IO.File]::ReadAllBytes($path);
    if ($bytes.Length -ne $size -or (Get-PdvBundleSha256 $bytes) -cne $node.GetAttribute('sha256')) { throw ('RemoteBundleHashMismatch:' + $name); }
    if ($isPe) {
      if ($bytes.Length -lt 128 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw 'RemoteBundlePeHeader'; }
      $offset = [BitConverter]::ToUInt32($bytes, 60);
      if ($offset -gt ($bytes.Length - 26) -or [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or [BitConverter]::ToUInt16($bytes, ($offset + 4)) -ne [int]$machine) { throw 'RemoteBundlePeMachine'; }
      if ($policy -ceq 'authenticode') {
        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop;
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $node.GetAttribute('publisherThumbprint')) { throw ('RemoteBundleSignature:' + $name); }
      }
    }
    $names[$name] = $node; $entries += ,@{ RelativePath = $name; Path = $path; Sha256 = $node.GetAttribute('sha256'); SizeBytes = $size; AuthPolicy = $policy; PublisherThumbprint = $node.GetAttribute('publisherThumbprint') };
  }
  if ($entries.Count -lt 4 -or $entries.Count -gt 32) { throw 'RemoteBundleEntryCount'; }
  foreach ($required in @('bin/stunnel/stunnel.exe', 'bin/ultravnc/winvnc.exe', 'licenses/UltraVNC-LICENSE.txt', 'licenses/stunnel-COPYING.md')) { if (-not $names.ContainsKey($required)) { throw ('RemoteBundleRequiredFile:' + $required); } }
  if ($names.ContainsKey('bin/stunnel/libssp-0.dll')) {
    $source = $names['sources/stunnel-5.82-win64-installer.exe'];
    if ($null -eq $source -or $source.GetAttribute('authPolicy') -cne 'authenticode' -or $source.GetAttribute('sha256') -cne '722c1ad626919af2b0034666b4d19cc4795e925c32f60e8f3c59af4fb3ad2dfc') { throw 'RemoteBundleSignedContainerMissing'; }
  }
  $runtimeFiles = @{};
  if ($AllowRuntimeConfiguration) {
    foreach ($name in @('bin/ultravnc/ultravnc.ini', 'bin/ultravnc/ultravnc.portable')) {
      $path = Assert-PdvBundleRegularPath ([IO.Path]::Combine($rootPath, $name.Replace('/', [IO.Path]::DirectorySeparatorChar)));
      if (-not [IO.File]::Exists($path)) { throw 'RemoteBundleRuntimeConfigurationMissing'; }
      if ($name.EndsWith('.portable') -and ([IO.File]::ReadAllBytes($path)).Length -ne 0) { throw 'RemoteBundlePortableMarker'; }
      if ($name.EndsWith('.ini') -and (([IO.FileInfo]$path).Length -lt 1 -or ([IO.FileInfo]$path).Length -gt 65536)) { throw 'RemoteBundleIniSize'; }
      $runtimeFiles[$name] = $path;
    }
  }
  $allPaths = @([IO.Directory]::GetFileSystemEntries($rootPath));
  while ($allPaths.Count -gt 0) {
    $next = @();
    foreach ($path in $allPaths) {
      [void](Assert-PdvBundleRegularPath $path);
      if ([IO.Directory]::Exists($path)) { $next += [IO.Directory]::GetFileSystemEntries($path); }
      else {
        $relative = $path.Substring($rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/');
        if ($relative -cne 'remoto-bundle.xml' -and -not $names.ContainsKey($relative) -and -not $runtimeFiles.ContainsKey($relative)) { throw ('RemoteBundleUnknownFile:' + $relative); }
      }
    }
    $allPaths = $next;
  }
  return @{ BundleId = $root.GetAttribute('id'); Profiles = $profiles; Files = $entries; ManifestSha256 = $manifestHash; RuntimeFiles = $runtimeFiles };
}
if ($SourceArtifactPath) {
  if ($BundleDirectory -or $TrustedManifestPath -or $ProfileId -or $AllowRuntimeConfiguration) { throw 'RemoteBundleAmbiguousValidation'; }
  [void](Assert-PdvRemoteSourceArtifact $SourceArtifactPath);
}
elseif ($BundleDirectory -or $TrustedManifestPath -or $ProfileId) {
  if (-not $BundleDirectory -or -not $TrustedManifestPath) { throw 'Informe BundleDirectory e TrustedManifestPath.'; }
  [void](Assert-PdvRemoteBundle -BundleDirectory $BundleDirectory -TrustedManifestPath $TrustedManifestPath -ProfileId $ProfileId -AllowRuntimeConfiguration:$AllowRuntimeConfiguration);
}
