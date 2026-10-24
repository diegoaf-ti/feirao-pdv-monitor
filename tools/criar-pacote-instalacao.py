#!/usr/bin/env python3
"""Gera o aplicativo para instalacao manual, sem publicar nem ler credenciais.

O ZIP completo e diferente do ZIP plano usado pelo atualizador. Os executaveis
de terceiros exigem --remote-bundle validado no Windows. Configuracao ativa,
PKI, dados do usuario e servidor ficam fora.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import ssl
import subprocess
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
import zipfile

VERSION = re.compile(r'^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$')
REMOTE_SOURCES = (
    'PdvMonitor.Remoto.Windows.psm1',
    'piloto-remoto/windows/RemoteWindowsNative.cs',
    'piloto-remoto/windows/remoto-piloto.xml.example',
    'piloto-remoto/windows/COMPATIBILIDADE-WINDOWS7.md',
    'PdvMonitor.Remoto.Inscricao.psm1',
    'piloto-remoto/windows/RemoteEnrollmentCrypto.cs',
    'piloto-remoto/windows/RemoteEnrollmentStorage.cs',
    'piloto-remoto/windows/AtivarCertificadoRemoto.ps1',
    'piloto-remoto/windows/AtivarCertificadoRemotoBootstrap.ps1',
    'piloto-remoto/windows/AtivarCertificadoRemoto.cmd',
    'piloto-remoto/windows/inscricao-confianca.xml',
    'piloto-remoto/windows/identity-server-ca.crt',
    'piloto-remoto/windows/identity-device-ca.crt',
    'PdvMonitor.Remoto.Identidade.psm1',
    'piloto-remoto/windows/ManterIdentidadeRemota.ps1',
    'piloto-remoto/windows/InstalarRemotoCompleto.ps1',
    'piloto-remoto/windows/InstalarRemotoCompleto.cmd',
    'tools/ValidarBundleRemoto.ps1',
    'tools/remoto-bundle-lock.xml',
)
INSTALL_EXTRAS = (
    'Instalar.cmd', 'InstalarPacote.ps1', 'GUIA-REMOTO-0.8.md', 'REMOTO-BUNDLE.md', 'GUIA-INSTALACAO-0.7.md', 'README.md', 'CERTIFICADO-EMBUTIDO.md',
    'GUIA-REMOTO-INTEGRACAO.md', 'GUIA-INVENTARIO-EMPRESA.md',
    'GUIA-NERUS-SERVICE.md', 'GUIA-PILOTO-V3.md',
    'piloto-remoto/windows/InstalarComponenteRemoto.ps1',
    'piloto-remoto/windows/PrepararRemoto.cmd',
    'piloto-remoto/windows/README.md',
    'piloto-remoto/windows/INSCRICAO-CERTIFICADO.md',
)


def regular_bytes(root, name):
    path = root / name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Arquivo ausente ou link: ' + name)
    probe = path
    while probe != root:
        if probe.is_symlink():
            raise ValueError('Diretorio link: ' + name)
        probe = probe.parent
    data = path.read_bytes()
    if not data or len(data) > 4194304:
        raise ValueError('Tamanho invalido: ' + name)
    return data


def core_files(source):
    spec = importlib.util.spec_from_file_location('pdv_update_packager', source / 'tools/criar-pacote-atualizacao.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return tuple(module.PROGRAM_FILES)


def validate_embedded_trust(source, content):
    prefix = 'piloto-remoto/windows/'
    raw = content[prefix + 'inscricao-confianca.xml']
    if len(raw) > 8192 or b'<!DOCTYPE' in raw or b'<!ENTITY' in raw:
        raise ValueError('Confianca de inscricao invalida')
    root = ET.fromstring(raw)
    fields = ['ApiEnrollmentUrl', 'GatewayHost', 'GatewayPort', 'ServerCaFile', 'ServerCaSha256', 'DeviceCaFile', 'DeviceCaSha256']
    if root.tag != 'PdvRemoteEnrollmentTrust' or root.attrib != {'schemaVersion': '1'} or [n.tag for n in root] != fields or any(n.attrib or len(n) or not n.text for n in root):
        raise ValueError('Contrato de confianca invalido')
    values = {n.tag: n.text for n in root}
    url = urlsplit(values['ApiEnrollmentUrl'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path != '/api/pdv-monitor/remote-enrollment' or url.port not in [None, 443] or values['GatewayHost'] != url.hostname or values['GatewayPort'] != '5443':
        raise ValueError('Destino de inscricao invalido')
    fingerprints=[]
    for field, filename in [('ServerCa','identity-server-ca.crt'), ('DeviceCa','identity-device-ca.crt')]:
        data=content[prefix + filename]
        if values[field+'File'] != filename or not re.fullmatch(r'[0-9a-f]{64}',values[field+'Sha256']) or data.count(b'-----BEGIN CERTIFICATE-----') != 1 or b'PRIVATE KEY' in data:
            raise ValueError('Somente CA publica permitida no pacote')
        try:
            der=ssl.PEM_cert_to_DER_cert(data.decode('ascii'))
            if hashlib.sha256(der).hexdigest() != values[field+'Sha256']:
                raise ValueError('Pin de certificado divergente')
            with tempfile.TemporaryDirectory(prefix='pdv-public-trust-check-') as work:
                cert_path=Path(work)/'authority.crt'
                cert_path.write_bytes(data)
                result=subprocess.run(['openssl','x509','-in',str(cert_path),'-noout','-checkend','0','-ext','basicConstraints'],capture_output=True,timeout=10)
                if result.returncode or b'CA:TRUE' not in result.stdout or (field == 'DeviceCa' and b'pathlen:1' not in result.stdout):
                    raise ValueError('CA invalida, vencida ou sem permissao para o emissor')
                verified=subprocess.run(['openssl','verify','-CAfile',str(cert_path),str(cert_path)],capture_output=True,timeout=10)
                if verified.returncode:
                    raise ValueError('CA publica invalida')
        except (UnicodeError, ssl.SSLError, OSError, subprocess.SubprocessError) as error:
            raise ValueError('Nao foi possivel conferir CA publica') from error
        fingerprints.append(values[field+'Sha256'])
    if len(set(fingerprints)) != 2:
        raise ValueError('Autoridades de servidor e dispositivo devem ser distintas')


def create_install_package(source, output, version, remote_bundle=None):
    source = Path(source).resolve()
    output = Path(output).resolve()
    if not VERSION.fullmatch(version):
        raise ValueError('Versao x.y.z obrigatoria')
    names = core_files(source) + INSTALL_EXTRAS + REMOTE_SOURCES
    if len(names) != len(set(names)) or len(core_files(source)) != 22:
        raise ValueError('Lista de arquivos inconsistente')
    content = {name: regular_bytes(source, name) for name in names}
    if content['monitor-version.txt'].decode('ascii').strip() != version:
        raise ValueError('Versao do aplicativo divergente')
    module_version = content['PdvMonitor.Version.psm1'].decode('utf-8-sig')
    if not re.search(r"function\s+Get-PdvMonitorVersion\s*\{\s*return\s+'" + re.escape(version) + r"'\s*;?\s*\}", module_version, re.I):
        raise ValueError('Modulo de versao divergente')
    public = ET.fromstring(content['atualizacoes-chave-publica.xml'])
    if public.tag != 'RSAKeyValue' or [node.tag for node in public] != ['Modulus', 'Exponent']:
        raise ValueError('Pacote admite somente chave publica')
    example = ET.fromstring(content['piloto-remoto/windows/remoto-piloto.xml.example'])
    if example.findtext('Enabled') != 'false' or example.findtext('ProfileApproved') != 'false':
        raise ValueError('Modelo remoto deve permanecer inativo')
    validate_embedded_trust(source, content)
    remote_content = {}
    if remote_bundle is not None:
        spec = importlib.util.spec_from_file_location('pdv_remote_bundle', source / 'tools/remote_bundle.py')
        bundle_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bundle_module)
        remote_content = bundle_module.validated_content(remote_bundle, source / 'tools/remoto-bundle-lock.xml', source / 'tools/ValidarBundleRemoto.ps1')
        content.update({'piloto-remoto/windows/bundle/' + name: data for name, data in remote_content.items()})
    manifest = ET.Element('PdvRemoteInstallManifest', {'schemaVersion': '1'})
    for name in REMOTE_SOURCES:
        data = content[name]
        ET.SubElement(manifest, 'File', {'path': name, 'sha256': hashlib.sha256(data).hexdigest(), 'sizeBytes': str(len(data))})
    content['remoto-instalacao-sha256.xml'] = ET.tostring(manifest, encoding='utf-8', xml_declaration=True)
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}
    content['ARQUIVOS-SHA256.txt'] = ('\n'.join(f'{sha}  {name}' for name, sha in hashes.items()) + '\n').encode()
    output.mkdir(parents=True, exist_ok=True)
    package = output / f'Monitor-PDV-{version}-Windows.zip'
    metadata = output / 'pacote-instalacao.json'
    if package.exists() or metadata.exists():
        raise ValueError('Use diretorio de saida novo; pacote anterior preservado')
    try:
        with zipfile.ZipFile(package, 'x', zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=False) as archive:
            for name, data in content.items():
                entry = zipfile.ZipInfo(name, date_time=(2026, 10, 22, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, data)
        result = {
            'version': version, 'kind': 'manual-install-pilot', 'package': package.name,
            'sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'bytes': package.stat().st_size,
            'coreFiles': 22, 'archiveEntries': len(content), 'remoteConfigured': False,
            'thirdPartyExecutablesIncluded': bool(remote_content), 'privateKeysOrUserDataIncluded': False,
            'remoteBundleAuthenticodeValidatedOnBuildWindows': bool(remote_content),
            'remoteBundleArchitectures': ['x64'] if remote_content else [],
            'remoteIdentityOrConsentPreauthorized': False,
            'publicTrustCertificatesEmbedded': True, 'perComputerIdentity': 'created-locally-with-one-time-activation',
            'published': False, 'nativeWindowsOrAntivirusValidated': False, 'filesSha256': hashes,
        }
        metadata.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
        return package, metadata
    except BaseException:
        package.unlink(missing_ok=True)
        metadata.unlink(missing_ok=True)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--remote-bundle', type=Path, help='Bundle exato aprovado; exige Authenticode valido no Windows')
    args = parser.parse_args()
    for path in create_install_package(args.source, args.output, args.version, args.remote_bundle):
        print(path)
