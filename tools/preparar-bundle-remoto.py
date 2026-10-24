#!/usr/bin/env python3
"""Prepara dependências oficiais pinadas, sem executar instaladores Windows.

Somente Windows: valida o contêiner stunnel antes da extração e cada PE depois.
Não gera perfil, identidade, licença administrativa ou autorização de sessão.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.request import Request, urlopen
import zipfile

from remote_bundle import parse_manifest, regular, validated_content

HERE = Path(__file__).resolve().parent
STUNNEL_MEMBERS = ('bin/stunnel.exe', 'bin/libcrypto-3-x64.dll', 'bin/libssl-3-x64.dll', 'bin/libssp-0.dll')
ULTRA_MEMBERS = ('x64/winvnc.exe', 'x64/ddengine64.dll', 'x64/vnchooks.dll')


def download(artifact, folder):
    target = folder / artifact['name']
    with urlopen(Request(artifact['url'], headers={'User-Agent': 'ConectaPDV-bundle/1.0'}), timeout=60) as response:
        if not response.url.startswith('https://'):
            raise ValueError('Redirecionamento sem HTTPS recusado')
        raw = response.read(32 * 1024 * 1024 + 1)
    if not raw or len(raw) > 32 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != artifact['sha256']:
        raise ValueError('Distribuição oficial divergente: ' + artifact['name'])
    target.write_bytes(raw)
    return target


def prepare(output, sevenzip):
    if os.name != 'nt':
        raise ValueError('Preparação exige Windows para conferir Authenticode; não há modo de ignorar assinatura')
    output = Path(output).absolute()
    if output.exists():
        raise ValueError('Use diretório de saída novo')
    manifest = regular(HERE / 'remoto-bundle-lock.xml', HERE, 32768)
    root = parse_manifest(manifest)
    audit = json.loads(regular(HERE / 'remote-dependency-audit.json', HERE, 32768))
    if hashlib.sha256(manifest).hexdigest() != audit['manifestSha256']:
        raise ValueError('Aprovação e auditoria divergentes')
    with tempfile.TemporaryDirectory(prefix='pdv-official-bundle-') as work:
        work = Path(work)
        sources = {a['name']: download(a, work) for a in audit['artifacts']}
        container = sources['stunnel-5.82-win64-installer.exe']
        subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(HERE / 'ValidarBundleRemoto.ps1'), '-SourceArtifactPath', str(container)], check=True, capture_output=True, timeout=120)
        extracted = work / 'stunnel'
        subprocess.run([sevenzip, 'x', '-y', '-o' + str(extracted), str(container), *STUNNEL_MEMBERS], check=True, capture_output=True, timeout=60)
        staged = work / 'bundle'
        staged.mkdir()
        with zipfile.ZipFile(sources['UltraVNC_1830.zip']) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError('ZIP UltraVNC com entradas repetidas')
            for member in ULTRA_MEMBERS:
                raw = archive.read(member)
                target = staged / 'bin/ultravnc' / Path(member).name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
        for member in STUNNEL_MEMBERS:
            source = extracted / member
            target = staged / 'bin/stunnel' / Path(member).name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(regular(source, extracted, 32 * 1024 * 1024))
        target = staged / 'sources' / container.name
        target.parent.mkdir(parents=True)
        target.write_bytes(container.read_bytes())
        for node in root.find('Files'):
            name = node.get('path')
            if name.startswith('licenses/'):
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(regular(HERE / 'remote-licenses' / Path(name).name, HERE / 'remote-licenses', 1024 * 1024))
        (staged / 'remoto-bundle.xml').write_bytes(manifest)
        validated_content(staged, HERE / 'remoto-bundle-lock.xml', HERE / 'ValidarBundleRemoto.ps1')
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, output)
        # Conferir a cópia que será efetivamente usada pelo empacotador.
        try:
            validated_content(output, HERE / 'remoto-bundle-lock.xml', HERE / 'ValidarBundleRemoto.ps1')
        except BaseException:
            shutil.rmtree(output)
            raise
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sevenzip', default=shutil.which('7z') or r'C:\Program Files\7-Zip\7z.exe')
    args = parser.parse_args()
    print(prepare(args.output, args.sevenzip))
