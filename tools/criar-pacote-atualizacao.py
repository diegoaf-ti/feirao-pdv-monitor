#!/usr/bin/env python3
"""Cria uma versão aprovada offline. A chave privada nunca integra o ZIP.

Requer Python 3 e OpenSSL local. Não acessa a rede. Aceita RSAKeyValue privado
(XML exportado de RSA .NET) ou PEM privado; uma chave pública XML deve acompanhar
a pasta fonte. Mantém dados operacionais fora da allowlist.
"""
import argparse
import base64
import datetime as dt
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

PROGRAM_FILES = (
    'MonitorPdv.ps1', 'InicializarMonitor.ps1', 'Monitor.cmd', 'IniciarMonitor.vbs',
    'InstalarMonitor.ps1', 'DesinstalarMonitor.ps1', 'PdvMonitor.Runtime.psm1',
    'PdvMonitor.Inventario.psm1', 'PdvMonitor.Coleta.psm1', 'PdvMonitor.Politica.psm1',
    'PdvLegado.Core.psm1', 'PdvDispositivos.Core.psm1', 'PdvMonitor.Transporte.psm1',
    'PdvMonitor.Atualizacao.psm1', 'AplicarAtualizacao.ps1', 'monitor-version.txt',
    'PdvMonitor.Nerus.psm1', 'PdvMonitor.Version.psm1', 'atualizacoes-chave-publica.xml',
    'IniciarMonitorInstalado.ps1', 'PdvMonitor.Remoto.psm1',
    'PdvMonitor.Remoto.Transporte.psm1',
)
VERSION = re.compile(r'^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$')


def der(tag, body):
    length = len(body)
    encoded = bytes([length]) if length < 128 else bytes([128 + (length.bit_length()+7)//8]) + length.to_bytes((length.bit_length()+7)//8, 'big')
    return bytes([tag]) + encoded + body


def integer(raw):
    raw = raw.lstrip(b'\0') or b'\0'
    if raw[0] & 128:
        raw = b'\0' + raw
    return der(2, raw)


def private_pem(path):
    data = path.read_bytes()
    if data.lstrip().startswith(b'-----BEGIN'):
        return data
    if b'<!DOCTYPE' in data or b'<!ENTITY' in data:
        raise ValueError('DTD não permitido na chave')
    root = ET.fromstring(data)
    fields = ('Modulus', 'Exponent', 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ')
    if root.tag != 'RSAKeyValue' or {n.tag for n in root} != set(fields):
        raise ValueError('Informe RSAKeyValue privado completo ou PEM privado')
    values = {k: base64.b64decode(root.findtext(k), validate=True) for k in fields}
    if not 256 <= len(values['Modulus']) <= 512:
        raise ValueError('RSA deve ter entre 2048 e 4096 bits')
    order = ('Modulus', 'Exponent', 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ')
    binary = der(0x30, integer(b'\0') + b''.join(integer(values[k]) for k in order))
    wrapped = base64.encodebytes(binary)
    return b'-----BEGIN RSA PRIVATE KEY-----\n' + wrapped + b'-----END RSA PRIVATE KEY-----\n'


def create_package(source, output, version, key_path, valid_days):
    if not VERSION.fullmatch(version) or not 1 <= valid_days <= 90:
        raise ValueError('Versão x.y.z e validade de 1 a 90 dias são obrigatórias')
    source = source.resolve()
    key_path = key_path.resolve()
    if key_path == source or source in key_path.parents:
        raise ValueError('Mantenha a chave privada fora da pasta fonte')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (version + '.zip')
    manifest = output / 'latest.xml'
    if archive.exists() or manifest.exists():
        raise ValueError('Saída já contém pacote/manifesto. Use uma pasta nova e aprove a publicação separadamente')
    public_path = source / 'atualizacoes-chave-publica.xml'
    if public_path.is_symlink() or not public_path.is_file() or public_path.stat().st_size > 16384:
        raise ValueError('Chave pública ausente, link ou grande')
    public_xml = public_path.read_bytes()
    if b'<!DOCTYPE' in public_xml or b'<!ENTITY' in public_xml:
        raise ValueError('Chave pública inválida')
    public_root = ET.fromstring(public_xml)
    if public_root.tag != 'RSAKeyValue' or [n.tag for n in public_root] != ['Modulus', 'Exponent']:
        raise ValueError('Somente Modulus/Exponent públicos podem integrar o pacote')
    expected_modulus = base64.b64decode(public_root.findtext('Modulus'), validate=True)
    if not 256 <= len(expected_modulus) <= 512:
        raise ValueError('Chave pública RSA deve ter entre 2048 e 4096 bits')
    for name in PROGRAM_FILES:
        path = source / name
        if name == 'monitor-version.txt':
            continue
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4194304:
            raise ValueError('Arquivo obrigatório ausente, link ou grande: ' + name)
    version_module = (source / 'PdvMonitor.Version.psm1').read_text(encoding='utf-8-sig')
    version_literal = re.search(r"function\s+Get-PdvMonitorVersion\s*\{\s*return\s+'([0-9]+\.[0-9]+\.[0-9]+)'\s*;?\s*\}", version_module, re.I)
    if not version_literal or version_literal.group(1) != version:
        raise ValueError('PdvMonitor.Version.psm1 deve retornar a mesma versão aprovada')
    total = 0
    try:
        with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=False) as z:
            for name in PROGRAM_FILES:
                data = (version + '\r\n').encode('ascii') if name == 'monitor-version.txt' else (source / name).read_bytes()
                total += len(data)
                if total > 62914560:
                    raise ValueError('Conteúdo expandido excede 60 MiB')
                info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                z.writestr(info, data)
        size = archive.stat().st_size
        if size > 20971520:
            raise ValueError('ZIP excede 20 MiB')
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        expires = now + dt.timedelta(days=valid_days)
        payload_root = ET.Element('Release', {'schemaVersion': '1'})
        fields = (
            ('Version', version), ('Channel', 'piloto'),
            ('PackagePath', '/api/pdv-monitor/agent/update/package/' + version),
            ('Sha256', hashlib.sha256(archive.read_bytes()).hexdigest()),
            ('SizeBytes', str(size)), ('IssuedAt', now.isoformat().replace('+00:00', 'Z')),
            ('ExpiresAt', expires.isoformat().replace('+00:00', 'Z')),
        )
        for name, value in fields:
            ET.SubElement(payload_root, name).text = value
        payload = ET.tostring(payload_root, encoding='utf-8', short_empty_elements=True)
        # Os temporários privados nascem com permissão 0600; nenhum deles é saída.
        with tempfile.TemporaryDirectory(prefix='pdv-release-sign-') as temp:
            temp_path = Path(temp)
            private_path = temp_path / 'private.pem'
            fd = os.open(str(private_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(private_pem(key_path))
            result = subprocess.run(['openssl', 'rsa', '-in', str(private_path), '-noout', '-modulus'], capture_output=True, check=True)
            modulus_hex = result.stdout.decode('ascii').strip().split('=', 1)[-1]
            if bytes.fromhex(modulus_hex) != expected_modulus:
                raise ValueError('Chave privada não corresponde à pública fixada no pacote')
            signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(private_path)], input=payload, capture_output=True, check=True).stdout
        outer = ET.Element('PdvMonitorUpdate', {'schemaVersion': '1'})
        ET.SubElement(outer, 'Payload').text = base64.b64encode(payload).decode('ascii')
        ET.SubElement(outer, 'Signature').text = base64.b64encode(signature).decode('ascii')
        xml = ET.tostring(outer, encoding='utf-8', xml_declaration=True)
        if len(xml) > 32768:
            raise ValueError('Manifesto excede 32 KiB')
        manifest.write_bytes(xml)
        return archive, manifest
    except BaseException:
        archive.unlink(missing_ok=True)
        manifest.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--valid-days', type=int, default=30)
    args = parser.parse_args()
    archive, manifest = create_package(args.source, args.output, args.version, args.private_key, args.valid_days)
    print('Pacote aprovado criado: ' + str(archive))
    print('Manifesto assinado: ' + str(manifest))
    print('Publique ambos no diretório de versões aprovadas da API. A chave privada não foi incluída.')

if __name__ == '__main__':
    main()
