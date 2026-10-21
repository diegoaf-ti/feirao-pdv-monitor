#!/usr/bin/env python3
"""Testes offline do empacotamento; usa RSA temporária sem qualquer credencial real."""
import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

MODULE = Path(__file__).with_name('criar-pacote-atualizacao.py')
spec = importlib.util.spec_from_file_location('pdv_release', MODULE)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pdv-package-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.key = self.root / 'private.pem'
        subprocess.run(['openssl', 'genrsa', '-out', str(self.key), '2048'], capture_output=True, check=True)
        raw = subprocess.run(['openssl', 'rsa', '-in', str(self.key), '-noout', '-modulus'], capture_output=True, check=True).stdout
        modulus = base64.b64encode(bytes.fromhex(raw.decode().strip().split('=')[-1])).decode()
        for name in release.PROGRAM_FILES:
            (self.source / name).write_text('# mock', encoding='utf-8')
        (self.source / 'PdvMonitor.Version.psm1').write_text("function Get-PdvMonitorVersion { return '0.3.0'; }", encoding='utf-8')
        (self.source / 'atualizacoes-chave-publica.xml').write_text('<RSAKeyValue><Modulus>'+modulus+'</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>')
        # Nunca devem vazar mesmo quando presentes no diretório de entrada.
        for name in ('central-credencial.bin', 'monitor.xml', 'central.xml', 'segredo.sql'):
            (self.source / name).write_text('NUNCA-INCLUIR')

    def tearDown(self):
        self.temp.cleanup()

    def test_signed_package_whitelist_and_version(self):
        archive, manifest = release.create_package(self.source, self.root/'output', '0.3.0', self.key, 30)
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(set(z.namelist()), set(release.PROGRAM_FILES))
            self.assertEqual(z.read('monitor-version.txt'), b'0.3.0\r\n')
            self.assertFalse(any('NUNCA-INCLUIR' in z.read(n).decode('utf-8') for n in z.namelist()))
        xml = ET.fromstring(manifest.read_bytes())
        payload = base64.b64decode(xml.findtext('Payload'))
        signature = base64.b64decode(xml.findtext('Signature'))
        public_pem = self.root/'public.pem'
        subprocess.run(['openssl','rsa','-in',str(self.key),'-pubout','-out',str(public_pem)], capture_output=True, check=True)
        signature_path = self.root/'signature'; signature_path.write_bytes(signature)
        result = subprocess.run(['openssl','dgst','-sha256','-verify',str(public_pem),'-signature',str(signature_path)], input=payload, capture_output=True, check=True)
        self.assertIn(b'Verified OK', result.stdout)
        fields = ET.fromstring(payload)
        self.assertEqual(fields.findtext('Version'), '0.3.0')
        self.assertRegex(fields.findtext('IssuedAt'), r'T[0-9:]+Z$')
        self.assertNotIn(b'PRIVATE KEY', archive.read_bytes())

    def test_no_private_key_inside_source(self):
        inside=self.source/'private.pem'; inside.write_bytes(self.key.read_bytes())
        with self.assertRaises(ValueError):
            release.create_package(self.source,self.root/'output','0.3.0',inside,30)

    def test_version_module_must_match(self):
        with self.assertRaises(ValueError):
            release.create_package(self.source,self.root/'output','0.4.0',self.key,30)

    def test_symlink_is_rejected(self):
        path=self.source/'MonitorPdv.ps1'; path.unlink(); path.symlink_to(self.key)
        with self.assertRaises(ValueError):
            release.create_package(self.source,self.root/'output','0.3.0',self.key,30)

    def test_different_private_key_is_rejected_and_cleaned(self):
        other=self.root/'other.pem'
        subprocess.run(['openssl','genrsa','-out',str(other),'2048'],capture_output=True,check=True)
        out=self.root/'output'
        with self.assertRaises(ValueError):
            release.create_package(self.source,out,'0.3.0',other,30)
        self.assertFalse((out/'0.3.0.zip').exists())
        self.assertFalse((out/'latest.xml').exists())

    def test_does_not_replace_existing_approved_release(self):
        out=self.root/'output'
        release.create_package(self.source,out,'0.3.0',self.key,30)
        before=(out/'latest.xml').read_bytes()
        with self.assertRaises(ValueError):
            release.create_package(self.source,out,'0.3.0',self.key,30)
        self.assertEqual((out/'latest.xml').read_bytes(),before)

if __name__=='__main__':
    unittest.main()
