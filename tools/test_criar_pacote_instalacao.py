#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import subprocess
import ssl
import hashlib

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('install_packager', HERE / 'criar-pacote-instalacao.py')
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)
core = install.core_files(HERE.parent)


class InstallPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pki=tempfile.TemporaryDirectory(prefix='pdv-embedded-trust-fixture-')
        cls.public={}
        for name,pathlen in [('server',0),('device',1)]:
            folder=Path(cls.pki.name)
            cert=folder/(name+'.crt')
            subprocess.run(['openssl','req','-new','-x509','-batch','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=PDV TEST '+name,'-addext','basicConstraints=critical,CA:true,pathlen:'+str(pathlen),'-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',str(folder/(name+'.key')),'-out',str(cert)],capture_output=True,check=True)
            cls.public[name]=cert.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.pki.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pdv-install-package-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        for name in core + install.INSTALL_EXTRAS + install.REMOTE_SOURCES:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        tool = self.source / 'tools/criar-pacote-atualizacao.py'
        tool.parent.mkdir(exist_ok=True)
        tool.write_text('PROGRAM_FILES = ' + repr(core))
        (self.source / 'monitor-version.txt').write_text('0.7.0\r\n')
        (self.source / 'PdvMonitor.Version.psm1').write_text("function Get-PdvMonitorVersion { return '0.7.0'; }")
        (self.source / 'atualizacoes-chave-publica.xml').write_text('<RSAKeyValue><Modulus>TEST_ONLY</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>')
        (self.source / 'piloto-remoto/windows/remoto-piloto.xml.example').write_text('<PdvRemoteWindowsPilot><Enabled>false</Enabled><ProfileApproved>false</ProfileApproved></PdvRemoteWindowsPilot>')
        trust=ET.Element('PdvRemoteEnrollmentTrust',{'schemaVersion':'1'})
        for key,value in [('ApiEnrollmentUrl','https://pdv.example.test/api/pdv-monitor/remote-enrollment'),('GatewayHost','pdv.example.test'),('GatewayPort','5443')]: ET.SubElement(trust,key).text=value
        for label,name in [('ServerCa','server'),('DeviceCa','device')]:
            filename='identity-'+name+'-ca.crt'
            (self.source/'piloto-remoto/windows'/filename).write_bytes(self.public[name])
            ET.SubElement(trust,label+'File').text=filename
            ET.SubElement(trust,label+'Sha256').text=hashlib.sha256(ssl.PEM_cert_to_DER_cert(self.public[name].decode())).hexdigest()
        (self.source/'piloto-remoto/windows/inscricao-confianca.xml').write_bytes(ET.tostring(trust,encoding='utf-8'))

    def tearDown(self):
        self.temp.cleanup()

    def build(self):
        return install.create_install_package(self.source, self.root / 'output', '0.7.0')

    def test_complete_package_separates_application_and_remote_provisioning(self):
        (self.source / 'central-credencial.bin').write_text('DO_NOT_PACKAGE')
        (self.source / 'private.key').write_text('DO_NOT_PACKAGE')
        archive, metadata = self.build()
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
            self.assertEqual(len(names), len(set(names)))
            self.assertTrue(set(core).issubset(names))
            self.assertIn('Instalar.cmd', names)
            self.assertIn('piloto-remoto/windows/PrepararRemoto.cmd', names)
            self.assertNotIn('private.key', names)
            self.assertNotIn('central-credencial.bin', names)
            self.assertNotIn('piloto-remoto/windows/remoto-piloto.xml', names)
            manifest = ET.fromstring(package.read('remoto-instalacao-sha256.xml'))
            self.assertEqual(manifest.attrib, {'schemaVersion': '1'})
            self.assertEqual([n.attrib['path'] for n in manifest], list(install.REMOTE_SOURCES))
            for node in manifest:
                data = package.read(node.attrib['path'])
                self.assertEqual(node.attrib['sha256'], install.hashlib.sha256(data).hexdigest())
                self.assertEqual(int(node.attrib['sizeBytes']), len(data))
        self.assertTrue(metadata.is_file())

    def test_missing_required_source_refuses_package(self):
        (self.source / install.REMOTE_SOURCES[0]).unlink()
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse((self.root / 'output').exists())

    def test_active_profile_or_private_key_refused(self):
        example = self.source / 'piloto-remoto/windows/remoto-piloto.xml.example'
        before = example.read_bytes()
        example.write_text('<PdvRemoteWindowsPilot><Enabled>true</Enabled><ProfileApproved>false</ProfileApproved></PdvRemoteWindowsPilot>')
        with self.assertRaises(ValueError):
            self.build()
        example.write_bytes(before)
        (self.source / 'atualizacoes-chave-publica.xml').write_text('<RSAKeyValue><Modulus>TEST</Modulus><Exponent>AQAB</Exponent><D>DO_NOT_PACKAGE</D></RSAKeyValue>')
        with self.assertRaises(ValueError):
            self.build()

    def test_version_mismatch_or_overwrite_refused(self):
        (self.source / 'monitor-version.txt').write_text('0.6.0')
        with self.assertRaises(ValueError):
            self.build()
        (self.source / 'monitor-version.txt').write_text('0.7.0')
        archive, metadata = self.build()
        before = archive.read_bytes()
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(before, archive.read_bytes())

    def test_linked_source_refused(self):
        path = self.source / install.REMOTE_SOURCES[0]
        path.unlink()
        target = self.root / 'outside'
        target.write_text('NOT_A_SOURCE')
        try:
            path.symlink_to(target)
        except OSError:
            self.skipTest('Symlink unavailable on this test host')
        with self.assertRaises(ValueError):
            self.build()

    def test_private_identity_cannot_replace_embedded_public_ca(self):
        (self.source/'piloto-remoto/windows/identity-device-ca.crt').write_text('-----BEGIN PRIVATE KEY-----\nDO_NOT_DISTRIBUTE\n-----END PRIVATE KEY-----')
        with self.assertRaises(ValueError): self.build()
        self.assertFalse((self.root/'output').exists())

    def test_tampered_trust_pin_or_wrong_origin_refused(self):
        path=self.source/'piloto-remoto/windows/inscricao-confianca.xml'
        before=path.read_bytes()
        xml=ET.fromstring(before);xml.find('DeviceCaSha256').text='0'*64;path.write_bytes(ET.tostring(xml))
        with self.assertRaises(ValueError): self.build()
        xml=ET.fromstring(before);xml.find('ApiEnrollmentUrl').text='http://pdv.example.test/api/pdv-monitor/remote-enrollment';path.write_bytes(ET.tostring(xml))
        with self.assertRaises(ValueError): self.build()
        xml=ET.fromstring(before);xml.find('ServerCaFile').text='../private.key';path.write_bytes(ET.tostring(xml))
        with self.assertRaises(ValueError): self.build()


if __name__ == '__main__':
    unittest.main()
