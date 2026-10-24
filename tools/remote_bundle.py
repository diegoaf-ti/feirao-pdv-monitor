"""Validação estrita do bundle remoto; nenhuma extração ou execução de EXEs."""
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess
import xml.etree.ElementTree as ET

MAX_FILE = 32 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
CONTAINER = 'sources/stunnel-5.82-win64-installer.exe'
CONTAINER_SHA = '722c1ad626919af2b0034666b4d19cc4795e925c32f60e8f3c59af4fb3ad2dfc'
COVERED_DLL = 'bin/stunnel/libssp-0.dll'
COVERED_SHA = '43ac5e338e3e05d2da19c48eef21f65b3e1833be0bc9c5735465f2935b371754'
PATH = re.compile(r'^(bin/(?:ultravnc|stunnel)/[A-Za-z0-9][A-Za-z0-9_.-]{0,80}|licenses/[A-Za-z0-9][A-Za-z0-9_.-]{0,100}|sources/stunnel-5\.82-win64-installer\.exe)$')


def regular(path, root, limit):
    path, root = Path(path), Path(root)
    if not path.is_relative_to(root) or not path.is_file() or path.is_symlink():
        raise ValueError('Bundle: arquivo ausente ou link')
    for parent in path.parents:
        if parent == root.parent:
            break
        if parent.is_symlink():
            raise ValueError('Bundle: diretório link')
    info = path.stat()
    if info.st_nlink != 1:
        raise ValueError('Bundle: hard link não permitido')
    if not 0 < info.st_size <= limit:
        raise ValueError('Bundle: tamanho inválido')
    data = path.read_bytes()
    if not 0 < len(data) <= limit:
        raise ValueError('Bundle: tamanho inválido')
    return data


def parse_manifest(raw):
    if len(raw) > 32768 or b'<!' in raw:
        raise ValueError('Bundle: manifesto inválido')
    root = ET.fromstring(raw)
    if root.tag != 'PdvRemoteBundle' or set(root.attrib) != {'schemaVersion', 'id'} or root.get('schemaVersion') != '1' or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,100}', root.get('id', '')) or [n.tag for n in root] != ['Profiles', 'Files']:
        raise ValueError('Bundle: contrato inválido')
    profiles = root.find('Profiles')
    if profiles.attrib or not 1 <= len(profiles) <= 4:
        raise ValueError('Bundle: perfis ausentes')
    ids = []
    for node in profiles:
        if node.tag != 'Profile' or set(node.attrib) != {'id'} or len(node) or (node.text or '').strip() or node.get('id') not in ['win7-sp1-x64', 'win10plus-x64'] or node.get('id') in ids:
            raise ValueError('Bundle: perfil não aprovado')
        ids.append(node.get('id'))
    files = root.find('Files')
    if files.attrib or not 4 <= len(files) <= 32:
        raise ValueError('Bundle: lista de arquivos inválida')
    names, total = set(), 0
    for node in files:
        attrs = node.attrib
        name = attrs.get('path', '')
        common = {'path', 'sha256', 'sizeBytes', 'authPolicy'}
        if node.tag != 'File' or len(node) or (node.text or '').strip() or not PATH.fullmatch(name) or name.lower() in names or not re.fullmatch(r'[0-9a-f]{64}', attrs.get('sha256', '')) or not re.fullmatch(r'[1-9][0-9]{0,8}', attrs.get('sizeBytes', '')):
            raise ValueError('Bundle: entrada inválida')
        names.add(name.lower())
        size = int(attrs['sizeBytes'])
        total += size
        if size > MAX_FILE or total > MAX_TOTAL:
            raise ValueError('Bundle: limite excedido')
        executable = name.endswith(('.exe', '.dll'))
        if not executable:
            if not name.startswith('licenses/') or attrs.get('authPolicy') != 'sha256' or set(attrs) != common:
                raise ValueError('Bundle: arquivo não executável inválido')
        elif attrs.get('authPolicy') == 'authenticode':
            if set(attrs) != common | {'machine', 'publisherThumbprint'} or not re.fullmatch(r'[0-9A-F]{40}', attrs['publisherThumbprint']) or attrs['machine'] != ('332' if name == CONTAINER else '34404'):
                raise ValueError('Bundle: editor/arquitetura inválidos')
        elif attrs.get('authPolicy') == 'covered-by-signed-container':
            if set(attrs) != common | {'machine', 'sourceArtifact'} or name != COVERED_DLL or attrs['sha256'] != COVERED_SHA or attrs['machine'] != '34404' or attrs['sourceArtifact'] != CONTAINER:
                raise ValueError('Bundle: exceção de contêiner não permitida')
        else:
            raise ValueError('Bundle: assinatura obrigatória')
    by_name = {n.get('path'): n for n in files}
    required = {'bin/stunnel/stunnel.exe', 'bin/ultravnc/winvnc.exe', 'licenses/UltraVNC-LICENSE.txt', 'licenses/stunnel-COPYING.md'}
    if not required.issubset(by_name):
        raise ValueError('Bundle: componentes/licenças obrigatórios ausentes')
    if COVERED_DLL in by_name and (CONTAINER not in by_name or by_name[CONTAINER].get('authPolicy') != 'authenticode' or by_name[CONTAINER].get('sha256') != CONTAINER_SHA):
        raise ValueError('Bundle: contêiner assinado obrigatório')
    return root


def verify_authenticode(bundle, trusted_manifest, validator):
    if os.name != 'nt':
        raise ValueError('Bundle completo exige validação Authenticode no Windows; não há bypass')
    subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(validator), '-BundleDirectory', str(bundle), '-TrustedManifestPath', str(trusted_manifest)], check=True, capture_output=True, timeout=120)


def validated_content(bundle, trusted_manifest, validator):
    bundle = Path(bundle).absolute()
    trusted_manifest = Path(trusted_manifest).absolute()
    raw = regular(trusted_manifest, trusted_manifest.parent, 32768)
    root = parse_manifest(raw)
    packaged = regular(bundle / 'remoto-bundle.xml', bundle, 32768)
    if raw != packaged:
        raise ValueError('Bundle: manifesto não corresponde à aprovação versionada')
    expected = {'remoto-bundle.xml'} | {node.get('path') for node in root.find('Files')}
    actual = set()
    for path in bundle.rglob('*'):
        if path.is_symlink():
            raise ValueError('Bundle: link não permitido')
        if not path.is_dir():
            actual.add(path.relative_to(bundle).as_posix())
    if actual != expected:
        raise ValueError('Bundle: arquivo extra ou ausente')
    content = {'remoto-bundle.xml': raw}
    for node in root.find('Files'):
        name = node.get('path')
        data = regular(bundle / name, bundle, MAX_FILE)
        if len(data) != int(node.get('sizeBytes')) or hashlib.sha256(data).hexdigest() != node.get('sha256'):
            raise ValueError('Bundle: conteúdo divergente: ' + name)
        if name.endswith(('.exe', '.dll')):
            if len(data) < 128 or data[:2] != b'MZ':
                raise ValueError('Bundle: PE inválido')
            offset = struct.unpack_from('<I', data, 60)[0]
            if offset + 26 > len(data) or data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != int(node.get('machine')):
                raise ValueError('Bundle: arquitetura PE divergente')
        content[name] = data
    verify_authenticode(bundle, trusted_manifest, validator)
    return content
