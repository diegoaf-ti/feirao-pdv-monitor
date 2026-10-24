import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('remote_bundle', HERE / 'remote_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class RemoteBundleTest(unittest.TestCase):
    def setUp(self):
        self.raw = (HERE / 'remoto-bundle-lock.xml').read_bytes()
        self.root = bundle.parse_manifest(self.raw)

    def test_checked_in_lock_has_only_x64_and_one_explicit_container_exception(self):
        self.assertEqual([n.get('id') for n in self.root.find('Profiles')], ['win7-sp1-x64', 'win10plus-x64'])
        covered = [n for n in self.root.find('Files') if n.get('authPolicy') == 'covered-by-signed-container']
        self.assertEqual([n.get('path') for n in covered], [bundle.COVERED_DLL])
        self.assertEqual(covered[0].get('sha256'), bundle.COVERED_SHA)

    def test_licences_are_complete_and_exact_in_versioned_lock(self):
        for node in self.root.find('Files'):
            if node.get('path').startswith('licenses/'):
                data = (HERE / 'remote-licenses' / Path(node.get('path')).name).read_bytes()
                self.assertEqual(node.get('sha256'), hashlib.sha256(data).hexdigest())
                self.assertEqual(int(node.get('sizeBytes')), len(data))

    def test_windows_git_checkout_preserves_approved_manifest_and_original_licence_bytes(self):
        # Reproduz core.autocrlf do runner Windows sem rede e sem alterar o repo real.
        with tempfile.TemporaryDirectory(prefix='pdv-bundle-git-eol-') as work:
            work = Path(work)
            source, checkout = work / 'source', work / 'checkout'
            (source / 'tools').mkdir(parents=True)
            shutil.copyfile(HERE.parent / '.gitattributes', source / '.gitattributes')
            shutil.copyfile(HERE / 'remoto-bundle-lock.xml', source / 'tools/remoto-bundle-lock.xml')
            shutil.copytree(HERE / 'remote-licenses', source / 'tools/remote-licenses')
            commands = [
                ['git', '-c', 'init.defaultBranch=main', 'init', '-q', str(source)],
                ['git', '-C', str(source), 'add', '-f', '.gitattributes', 'tools'],
                ['git', '-C', str(source), '-c', 'user.name=PDV isolated fixture', '-c', 'user.email=pdv-fixture@example.invalid', 'commit', '--no-gpg-sign', '-q', '-m', 'Fixture de bytes aprovados'],
                ['git', '-c', 'core.autocrlf=true', 'clone', '--no-hardlinks', '-q', str(source), str(checkout)],
            ]
            for command in commands:
                subprocess.run(command, check=True, capture_output=True, timeout=30)
            raw = (checkout / 'tools/remoto-bundle-lock.xml').read_bytes()
            audit = json.loads((HERE / 'remote-dependency-audit.json').read_bytes())
            self.assertEqual(hashlib.sha256(raw).hexdigest(), audit['manifestSha256'])
            self.assertEqual(raw, self.raw)
            for node in bundle.parse_manifest(raw).find('Files'):
                if node.get('path').startswith('licenses/'):
                    data = (checkout / 'tools/remote-licenses' / Path(node.get('path')).name).read_bytes()
                    self.assertEqual(hashlib.sha256(data).hexdigest(), node.get('sha256'))
                    self.assertEqual(len(data), int(node.get('sizeBytes')))

    def test_unknown_unsigned_dll_or_container_forgery_is_rejected(self):
        for attribute, value in [('path', 'bin/stunnel/other.dll'), ('sha256', '0' * 64), ('sourceArtifact', 'sources/unknown.exe')]:
            altered = copy.deepcopy(self.root)
            dll = next(n for n in altered.find('Files') if n.get('path') == bundle.COVERED_DLL)
            dll.set(attribute, value)
            with self.assertRaises(ValueError):
                bundle.parse_manifest(ET.tostring(altered))
        altered = copy.deepcopy(self.root)
        source = next(n for n in altered.find('Files') if n.get('path') == bundle.CONTAINER)
        source.set('sha256', '0' * 64)
        with self.assertRaises(ValueError):
            bundle.parse_manifest(ET.tostring(altered))

    def test_traversal_duplicate_case_architecture_publisher_and_private_data_refused(self):
        for field, value in [('path', '../private.key'), ('path', 'bin/ultravnc/secret.key'), ('machine', '332'), ('publisherThumbprint', '0' * 39), ('authPolicy', 'sha256')]:
            altered = copy.deepcopy(self.root)
            altered.find('Files')[0].set(field, value)
            with self.assertRaises(ValueError):
                bundle.parse_manifest(ET.tostring(altered))
        altered = copy.deepcopy(self.root)
        duplicate = copy.deepcopy(altered.find('Files')[0])
        duplicate.set('path', duplicate.get('path').upper())
        altered.find('Files').append(duplicate)
        with self.assertRaises(ValueError):
            bundle.parse_manifest(ET.tostring(altered))

    def test_x86_or_unknown_profile_cannot_be_marked_approved(self):
        for profile in ['win7-sp1-x86', 'win10plus-x86', 'windows-any']:
            altered = copy.deepcopy(self.root)
            altered.find('Profiles')[0].set('id', profile)
            with self.assertRaises(ValueError):
                bundle.parse_manifest(ET.tostring(altered))

    def test_dtd_entity_unknown_attributes_and_oversized_manifest_refused(self):
        for raw in [b'<!DOCTYPE x>' + self.raw, b'<!ENTITY x "secret">' + self.raw, b'x' * 32769]:
            with self.assertRaises(ValueError):
                bundle.parse_manifest(raw)
        altered = copy.deepcopy(self.root)
        altered.set('skipSignature', 'true')
        with self.assertRaises(ValueError):
            bundle.parse_manifest(ET.tostring(altered))

    def fixture(self, folder):
        """Somente bytes sintéticos, sem WMI, Win32, certificado ou executável real."""
        root = copy.deepcopy(self.root)
        files = root.find('Files')
        for node in list(files):
            if node.get('authPolicy') == 'covered-by-signed-container' or node.get('path').startswith('sources/'):
                files.remove(node)
        for node in files:
            name = node.get('path')
            if name.endswith(('.exe', '.dll')):
                data = bytearray(256)
                data[:2] = b'MZ'
                struct.pack_into('<I', data, 60, 128)
                data[128:132] = b'PE\0\0'
                struct.pack_into('<H', data, 132, 34404)
                data = bytes(data)
            else:
                data = b'SYNTHETIC TEST LICENCE'
            node.set('sha256', hashlib.sha256(data).hexdigest())
            node.set('sizeBytes', str(len(data)))
            target = folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        raw = ET.tostring(root)
        (folder / 'remoto-bundle.xml').write_bytes(raw)
        trusted = folder.parent / 'trusted.xml'
        trusted.write_bytes(raw)
        return trusted

    def test_exact_complete_content_calls_authenticode_and_does_not_accept_receipts(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / 'bundle'
            directory.mkdir()
            trusted = self.fixture(directory)
            with patch.object(bundle, 'verify_authenticode') as verify:
                result = bundle.validated_content(directory, trusted, HERE / 'ValidarBundleRemoto.ps1')
                self.assertIn('bin/stunnel/stunnel.exe', result)
                verify.assert_called_once()
            (directory / 'signature-approved.json').write_text('{}')
            with patch.object(bundle, 'verify_authenticode') as verify:
                with self.assertRaises(ValueError):
                    bundle.validated_content(directory, trusted, HERE / 'ValidarBundleRemoto.ps1')
                verify.assert_not_called()

    def test_tamper_missing_pe_symlink_and_hardlink_fail_before_authenticode(self):
        for kind in ['tamper', 'missing', 'pe', 'symlink', 'hardlink']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp) / 'bundle'
                directory.mkdir()
                trusted = self.fixture(directory)
                path = directory / 'bin/ultravnc/winvnc.exe'
                if kind == 'tamper':
                    path.write_bytes(b'wrong')
                elif kind == 'missing':
                    path.unlink()
                elif kind == 'pe':
                    data = path.read_bytes().replace(b'PE\0\0', b'XX\0\0')
                    path.write_bytes(data)
                    manifest = ET.fromstring(trusted.read_bytes())
                    manifest.find('Files')[0].set('sha256', hashlib.sha256(data).hexdigest())
                    raw = ET.tostring(manifest)
                    trusted.write_bytes(raw)
                    (directory / 'remoto-bundle.xml').write_bytes(raw)
                elif kind == 'symlink':
                    target = Path(tmp) / 'outside.exe'
                    target.write_bytes(path.read_bytes())
                    path.unlink()
                    try:
                        path.symlink_to(target)
                    except OSError:
                        continue
                else:
                    try:
                        (Path(tmp) / 'extra-link.exe').hardlink_to(path)
                    except OSError:
                        continue
                with patch.object(bundle, 'verify_authenticode') as verify:
                    with self.assertRaises(ValueError):
                        bundle.validated_content(directory, trusted, HERE / 'ValidarBundleRemoto.ps1')
                    verify.assert_not_called()

    def test_non_windows_has_no_authenticode_bypass(self):
        with patch.object(bundle.os, 'name', 'posix'):
            with self.assertRaisesRegex(ValueError, 'Windows'):
                bundle.verify_authenticode('bundle', 'manifest', 'validator')


if __name__ == '__main__':
    unittest.main()
