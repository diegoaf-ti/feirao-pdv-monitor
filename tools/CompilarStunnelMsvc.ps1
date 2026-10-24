#requires -Version 5.1
# Compila em runner Windows isolado; nao instala, assina ou executa o produto.
param(
  [Parameter(Mandatory=$true)][ValidateSet('x86','x64')][string]$Architecture,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [ValidatePattern('^14\.29\.[0-9]{5}$')][string]$ToolchainVersion = '14.29.30133',
  [ValidatePattern('^10\.0\.19041\.0$')][string]$WindowsSdkVersion = '10.0.19041.0'
);
$ErrorActionPreference = 'Stop';
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'A compilacao exige MSVC no Windows.'; }
$output = [IO.Path]::GetFullPath($OutputDirectory);
if (Test-Path -LiteralPath $output) { throw 'Use diretorio de saida novo.'; }
$work = Join-Path ([IO.Path]::GetTempPath()) ('pdv-stunnel-build-' + [Guid]::NewGuid().ToString('N'));
if ($work -notmatch '^[A-Za-z]:[\\A-Za-z0-9 _.-]+$') { throw 'Diretorio de build deve usar caminho ASCII simples.'; }
[void][IO.Directory]::CreateDirectory($work);
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe';
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere oficial ausente.'; }
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1);
if (-not $vs -or $vs -match '["%\r\n]') { throw 'MSVC nao localizado.'; }
$devcmd = Join-Path $vs 'Common7/Tools/VsDevCmd.bat';
$sources = @(
  @{ Name='stunnel-5.82.tar.gz'; Url='https://www.stunnel.org/downloads/stunnel-5.82.tar.gz'; Sha='8e7438ccd6b3a2ab05182d0846e112a56a7f557ecdee40de07bf67820008bef7' },
  @{ Name='openssl-3.5.9.tar.gz'; Url='https://www.openssl.org/source/openssl-3.5.9.tar.gz'; Sha='603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a' }
);
try {
  foreach ($source in $sources) {
    $file = Join-Path $work $source.Name;
    Invoke-WebRequest -UseBasicParsing -Uri $source.Url -OutFile $file;
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $source.Sha) { throw ('Hash de fonte divergente: ' + $source.Name); }
    $listing = @(& tar -tf $file); if ($LASTEXITCODE -ne 0) { throw 'Fonte nao e tar valido.'; }
    foreach ($name in $listing) { if ($name -match '(^/|(^|/)\.\.(/|$)|\\|:)') { throw 'Caminho de fonte invalido.'; } }
    & tar -xf $file -C $work; if ($LASTEXITCODE -ne 0) { throw 'Falha na extracao de fonte.'; }
  }
  $ssl = Join-Path $work 'openssl-3.5.9'; $stunnel = Join-Path $work 'stunnel-5.82'; $prefix = Join-Path $work 'openssl-prefix';
  $opensslTarget = 'VC-WIN32'; $stunnelTarget = 'win32'; if ($Architecture -ceq 'x64') { $opensslTarget='VC-WIN64A'; $stunnelTarget='win64'; }
  $command = @(
    '@echo off', 'setlocal',
    ('call "' + $devcmd + '" -host_arch=x64 -arch=' + $Architecture + ' -vcvars_ver=14.29 -winsdk=' + $WindowsSdkVersion),
    'if errorlevel 1 exit /b 50',
    ('if not "%VCToolsVersion%"=="' + $ToolchainVersion + '" exit /b 51'),
    'where perl.exe >nul', 'if errorlevel 1 exit /b 52',
    'set SOURCE_DATE_EPOCH=1790640000',
    ('cd /d "' + $ssl + '"'),
    ('perl Configure ' + $opensslTarget + ' no-shared no-module no-tests no-asm --prefix="' + $prefix + '" --openssldir="' + $prefix + '\ssl" --libdir=lib -D_WIN32_WINNT=0x0601'),
    'if errorlevel 1 exit /b 53', 'nmake /nologo build_libs', 'if errorlevel 1 exit /b 54', 'nmake /nologo install_dev', 'if errorlevel 1 exit /b 55',
    ('cd /d "' + $stunnel + '\src"'),
    ('nmake /nologo /f vc.mak makedirs TARGET=' + $stunnelTarget), 'if errorlevel 1 exit /b 56',
    ('nmake /nologo /f vc.mak ..\bin\' + $stunnelTarget + '\stunnel.exe TARGET=' + $stunnelTarget + ' SSLDIR="' + $prefix + '" SSLLIBS="libcrypto.lib libssl.lib" CFLAGS="/MT /W3 /O2 /nologo /DUNICODE /D_UNICODE /DWINVER=0x0601 /D_WIN32_WINNT=0x0601 /I\"' + $prefix + '\include\"" LDFLAGS="/NOLOGO /Brepro /INCREMENTAL:NO /SUBSYSTEM:WINDOWS,6.01" SHAREDLIBS="ws2_32.lib user32.lib shell32.lib kernel32.lib bcrypt.lib crypt32.lib"'),
    'if errorlevel 1 exit /b 57',
    ('cl /Bv > "' + $work + '\compiler.txt" 2>&1'),
    ('dumpbin /dependents "' + $stunnel + '\bin\' + $stunnelTarget + '\stunnel.exe" > "' + $work + '\dependents.txt"'), 'if errorlevel 1 exit /b 58',
    ('dumpbin /imports "' + $stunnel + '\bin\' + $stunnelTarget + '\stunnel.exe" > "' + $work + '\imports.txt"'), 'if errorlevel 1 exit /b 59',
    ('(echo MSVC=%VCToolsVersion%&echo SDK=%WindowsSDKVersion%&echo TARGET=%VSCMD_ARG_TGT_ARCH%) > "' + $work + '\toolchain.txt"'),
    'exit /b 0'
  ) -join "`r`n";
  $cmd = Join-Path $work 'build.cmd'; [IO.File]::WriteAllText($cmd, ($command+"`r`n"), [Text.Encoding]::ASCII);
  & cmd.exe /d /c $cmd;
  if ($LASTEXITCODE -ne 0) { throw ('Build recusada (toolchain exata, fontes ou compilacao): ' + $LASTEXITCODE); }
  $exe = Join-Path $stunnel ('bin/' + $stunnelTarget + '/stunnel.exe');
  $imports = Get-Content -LiteralPath (Join-Path $work 'imports.txt') -Raw;
  if ($imports -match '(?im)^\s+(GetSystemTimePreciseAsFileTime|GetTempPath2[AW]|WaitOnAddress|WakeByAddressSingle|WakeByAddressAll|SetThreadDescription|GetThreadDescription|GetDpiForWindow|GetDpiForSystem)\s*$') { throw 'Import incompatível com Windows 7.'; }
  $dependents = @([regex]::Matches((Get-Content -LiteralPath (Join-Path $work 'dependents.txt') -Raw), '(?im)^\s+([A-Za-z0-9_.-]+\.dll)\s*$') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() });
  $system = @('advapi32.dll','bcrypt.dll','comdlg32.dll','crypt32.dll','gdi32.dll','kernel32.dll','psapi.dll','secur32.dll','shell32.dll','user32.dll','ws2_32.dll');
  foreach ($dll in $dependents) { if ($system -cnotcontains $dll) { throw ('Dependencia externa nao aprovada: ' + $dll); } }
  if ($dependents.Count -lt 3) { throw 'Inspecao de imports incompleta.'; }
  [void][IO.Directory]::CreateDirectory($output);
  Copy-Item -LiteralPath $exe -Destination (Join-Path $output 'stunnel.exe');
  foreach ($name in @('dependents.txt','imports.txt','toolchain.txt','compiler.txt','build.cmd')) { Copy-Item -LiteralPath (Join-Path $work $name) -Destination (Join-Path $output $name); }
  Copy-Item -LiteralPath (Join-Path $stunnel 'COPYING.md') -Destination (Join-Path $output 'stunnel-COPYING.md');
  Copy-Item -LiteralPath (Join-Path $stunnel 'COPYRIGHT.md') -Destination (Join-Path $output 'stunnel-GPL-2.md');
  Copy-Item -LiteralPath (Join-Path $ssl 'LICENSE.txt') -Destination (Join-Path $output 'OpenSSL-LICENSE.txt');
  $report = @{ schemaVersion=1; architecture=$Architecture; toolchain=$ToolchainVersion; windowsSdk=$WindowsSdkVersion; sourceDateEpoch=1790640000; sources=$sources; sha256Unsigned=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant(); dependencies=$dependents; staticOpenSsl=$true; signed=$false; nativeWindows7Validated=$false; distributable=$false; recipeSha256=(Get-FileHash -LiteralPath $MyInvocation.MyCommand.Path -Algorithm SHA256).Hash.ToLowerInvariant() };
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'build-provenance.json') -Encoding UTF8;
  Write-Output ('Candidato SEM ASSINATURA, nao distribuivel: ' + $output);
} finally { if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work, $true); } }
