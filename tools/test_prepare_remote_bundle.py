import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prepare_remote_bundle', HERE / 'preparar-bundle-remoto.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
POWERSHELL = os.environ.get('PDV_TEST_PWSH') or shutil.which('pwsh') or shutil.which('powershell.exe')


class PrepareRemoteBundleDiagnosticTest(unittest.TestCase):
    def test_failed_authenticode_reports_public_status_thumbprint_and_reason_without_local_paths_or_command(self):
        public = 'PDV_BUNDLE_SIGNATURE Artifact=stunnel-5.82-win64-installer.exe Status=NotTrusted Thumbprint=52080A81F4A29130C44554D0264CC1E2786DEE85 StatusMessage=A certificate chain could not be built.'
        error = subprocess.CalledProcessError(1, ['never-print-command', 'dummy-credential'], output=('\x1b[31m' + public + '\x1b[0m\nC:\\runner-private\\temporary\\file.exe').encode(), stderr=b'::error::RemoteBundleSourceSignature\x00')
        text = prepare.command_diagnostic(error, 'Assinatura oficial', ['C:\\runner-private\\temporary'])
        self.assertIn(public, text)
        self.assertIn('RemoteBundleSourceSignature', text)
        self.assertIn('código de saída 1', text)
        self.assertNotIn('runner-private', text)
        self.assertNotIn('dummy-credential', text)
        self.assertNotIn('never-print-command', text)
        self.assertNotIn('::error::', text)
        self.assertNotIn('\x1b', text)
        self.assertNotIn('\x00', text)

    def test_diagnostics_are_bounded_and_timeout_preserves_verifier_reason(self):
        error = subprocess.TimeoutExpired(['never-print-command'], 120, output=b'PDV_BUNDLE_SIGNATURE Status=UnknownError\n' + b'a' * 20000, stderr=b'Certificate revocation server offline')
        text = prepare.command_diagnostic(error, 'Assinatura oficial')
        self.assertIn('prazo excedido', text)
        self.assertIn('revocation server offline', text)
        self.assertLess(len(text), 13000)
        self.assertNotIn('never-print-command', text)

    def test_checked_subprocess_never_accepts_failed_signature_or_retries_it(self):
        error = subprocess.CalledProcessError(1, ['powershell.exe'], output=b'PDV_BUNDLE_SIGNATURE Status=HashMismatch', stderr=b'RemoteBundleSourceSignature')
        with patch.object(prepare.subprocess, 'run', side_effect=error) as run:
            with self.assertRaisesRegex(ValueError, 'HashMismatch') as raised:
                prepare.run_checked(['powershell.exe'], 'Validacao', 120)
            run.assert_called_once_with(['powershell.exe'], check=True, capture_output=True, timeout=120)
            self.assertTrue(raised.exception.__suppress_context__)
        completed = subprocess.CompletedProcess(['powershell.exe'], 0)
        with patch.object(prepare.subprocess, 'run', return_value=completed):
            self.assertIs(prepare.run_checked(['powershell.exe'], 'Validacao', 120), completed)

    def test_final_bundle_validation_failure_also_keeps_authenticode_diagnostic(self):
        error = subprocess.CalledProcessError(1, ['powershell.exe'], output=b'PDV_BUNDLE_SIGNATURE Artifact=winvnc.exe Status=NotTrusted', stderr=b'RemoteBundleSignature:bin/ultravnc/winvnc.exe')
        with patch.object(prepare, 'validated_content', side_effect=error) as validate:
            with self.assertRaisesRegex(ValueError, 'winvnc.exe Status=NotTrusted'):
                prepare.validate_checked('synthetic-bundle', 'Copia final')
            validate.assert_called_once_with('synthetic-bundle', HERE / 'remoto-bundle-lock.xml', HERE / 'ValidarBundleRemoto.ps1')

    @unittest.skipUnless(POWERSHELL, 'Requer PowerShell somente para mocks, sem Authenticode ou arquivos reais')
    def test_powershell_diagnostics_do_not_accept_untrusted_signer_or_hide_chain_reason(self):
        validator = str(HERE / 'ValidarBundleRemoto.ps1').replace("'", "''")
        script = r"""
$ErrorActionPreference='Stop';
. 'VALIDATOR';
$script:status=[Management.Automation.SignatureStatus]::Valid;$script:thumb='52080A81F4A29130C44554D0264CC1E2786DEE85';$script:missing=$false;$script:invokeFailure=$false;
function Get-AuthenticodeSignature {
  param([string]$LiteralPath);
  if($script:invokeFailure){throw 'Synthetic chain lookup failed';}
  $signer=$null;if(-not $script:missing){$signer=@{Thumbprint=$script:thumb};}
  return @{Status=$script:status;SignerCertificate=$signer;StatusMessage="Synthetic chain could not be built`n::error::public metadata"};
}
$pinned='52080A81F4A29130C44554D0264CC1E2786DEE85';
Assert-PdvBundleAuthenticode 'synthetic.exe' $pinned 'SyntheticSignatureFailure';
foreach($status in @('NotTrusted','HashMismatch','UnknownError','NotSigned')){
  $script:status=[Management.Automation.SignatureStatus]$status;
  $captured=(& {try{Assert-PdvBundleAuthenticode 'synthetic.exe' $pinned 'SyntheticSignatureFailure';throw 'UnexpectedAccepted';}catch{if($_.Exception.Message -cne 'SyntheticSignatureFailure'){throw;}}} 6>&1 | Out-String);
  if($captured -notmatch ('Status='+$status) -or $captured -notmatch ('Thumbprint='+$pinned) -or $captured -notmatch 'StatusMessage=Synthetic chain could not be built' -or $captured.Contains('::error::')){throw 'DiagnosticMissingOrUnsafe';}
}
$script:status=[Management.Automation.SignatureStatus]::Valid;$script:missing=$true;
try{Assert-PdvBundleAuthenticode 'synthetic.exe' $pinned 'SyntheticSignatureFailure';throw 'UnexpectedAccepted';}catch{if($_.Exception.Message -cne 'SyntheticSignatureFailure'){throw;}}
$script:missing=$false;$script:thumb='0000000000000000000000000000000000000000';
try{Assert-PdvBundleAuthenticode 'synthetic.exe' $pinned 'SyntheticSignatureFailure';throw 'UnexpectedAccepted';}catch{if($_.Exception.Message -cne 'SyntheticSignatureFailure'){throw;}}
$script:invokeFailure=$true;
$captured=(& {try{Assert-PdvBundleAuthenticode 'synthetic.exe' $pinned 'SyntheticSignatureFailure';throw 'UnexpectedAccepted';}catch{if($_.Exception.Message -cne 'SyntheticSignatureFailure'){throw;}}} 6>&1 | Out-String);
if($captured -notmatch 'Status=InvocationFailed' -or $captured -notmatch 'Synthetic chain lookup failed'){throw 'InvocationDiagnosticMissing';}
Write-Output 'PASS signature diagnostic mocks; trust requirements preserved';
""".replace('VALIDATOR', validator)
        environment = dict(os.environ, POWERSHELL_TELEMETRY_OPTOUT='1')
        result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script], capture_output=True, text=True, timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS signature diagnostic mocks', result.stdout)

    @unittest.skipIf(sys.platform == 'win32', 'Este caso comprova a recusa imediata fora do Windows')
    def test_cli_reports_failure_without_traceback_and_has_no_non_windows_signature_bypass(self):
        result = subprocess.run([sys.executable, str(HERE / 'preparar-bundle-remoto.py'), '--output', 'never-created'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Preparação exige Windows', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(Path('never-created').exists())


if __name__ == '__main__':
    unittest.main()
