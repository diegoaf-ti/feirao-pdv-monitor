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
import re
import shutil
import subprocess
import tempfile
from urllib.request import Request, urlopen
import zipfile

from remote_bundle import parse_manifest, regular, validated_content

HERE = Path(__file__).resolve().parent
STUNNEL_MEMBERS = ('bin/stunnel.exe', 'bin/libcrypto-3-x64.dll', 'bin/libssl-3-x64.dll', 'bin/libssp-0.dll')
ULTRA_MEMBERS = ('x64/winvnc.exe', 'x64/ddengine64.dll', 'x64/vnchooks.dll')


def command_diagnostic(error, phase, private_paths=()):
    """Mostra a falha dos verificadores, sem comando, ambiente ou traceback.

    Entradas desses subprocessos são somente distribuições públicas pinadas.
    Limitar/normalizar stdout e stderr impede controles de terminal/workflow e
    remove caminhos locais antes de incluir a resposta no log público do CI.
    """
    chunks = []
    for label, value in [('stdout', error.stdout), ('stderr', error.stderr)]:
        if not value:
            continue
        text = value.decode('utf-8', errors='replace') if isinstance(value, bytes) else str(value)
        text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
        for target in sorted((str(p) for p in private_paths if p), key=len, reverse=True):
            text = text.replace(target, '[local]')
        lines = []
        for line in text.splitlines():
            line = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', line).replace('::', ': :').strip()
            if line:
                lines.append(line[:2048])
        sanitized = '\n'.join(lines)
        if len(sanitized) > 6144:
            sanitized = sanitized[:3072] + '\n[saída limitada]\n' + sanitized[-3072:]
        if sanitized:
            chunks.append(label + ':\n' + sanitized)
    reason = ('prazo excedido' if isinstance(error, subprocess.TimeoutExpired)
              else 'código de saída ' + str(error.returncode))
    return phase + ' falhou (' + reason + ').' + ('\n' + '\n'.join(chunks) if chunks else ' O verificador não retornou diagnóstico.')


def run_checked(command, phase, timeout, private_paths=()):
    try:
        return subprocess.run(command, check=True, capture_output=True, timeout=timeout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError(command_diagnostic(error, phase, private_paths)) from None


def validate_checked(directory, phase, private_paths=()):
    try:
        return validated_content(directory, HERE / 'remoto-bundle-lock.xml', HERE / 'ValidarBundleRemoto.ps1')
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError(command_diagnostic(error, phase, private_paths)) from None


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
        private_paths = (work, HERE, output)
        run_checked(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(HERE / 'ValidarBundleRemoto.ps1'), '-SourceArtifactPath', str(container)], 'Assinatura do instalador oficial stunnel', 120, private_paths)
        extracted = work / 'stunnel'
        run_checked([sevenzip, 'x', '-y', '-o' + str(extracted), str(container), *STUNNEL_MEMBERS], 'Extração da distribuição oficial stunnel', 60, private_paths)
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
        validate_checked(staged, 'Assinaturas do bundle preparado', private_paths)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, output)
        # Conferir a cópia que será efetivamente usada pelo empacotador.
        try:
            validate_checked(output, 'Assinaturas da cópia final do bundle', private_paths)
        except BaseException:
            shutil.rmtree(output)
            raise
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sevenzip', default=shutil.which('7z') or r'C:\Program Files\7-Zip\7z.exe')
    args = parser.parse_args()
    try:
        print(prepare(args.output, args.sevenzip))
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
