#!/usr/bin/env python3
"""Upload repository code over SSH; leave model installation to the user."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[4]
REMOTE_ROOT = '/workspace/qwen_vast_sh'
ALLOWED_SUFFIXES = {'.sh', '.py', '.json', '.conf', '.lock', '.in', '.patch', '.js', '.txt'}
MAX_SOURCE_BYTES = 10 * 1024 * 1024
# Sources whose installed names differ from their repository filenames.
# None means setup.sh creates or downloads the workflow; it is not bundled JSON.
SETUP_WORKFLOWS = {
    ('qwen-rapid-aio-nsfw-v19', 'Qwen-Rapid-AIO-NSFW-v19-Batch.json'): 'workflows/batch-save-image.json',
    ('qwen-rapid-aio-nsfw-v23', 'Qwen-Rapid-AIO-NSFW-v23-Batch.json'): 'workflows/batch-save-image.json',
    ('qwen3-vl-8b-instruct', 'Qwen3-VL-8B-Pose-Analysis.json'): None,
    ('wan2.2-ti2v-5b', 'Wan-2.2-TI2V-5B.json'): None,
}


def parse_ssh(value: str) -> tuple[list[str], str]:
    words = [word.strip('"') for word in shlex.split(value.strip(), posix=False)]
    if not words or Path(words[0]).name.lower() not in ('ssh', 'ssh.exe'):
        raise ValueError('SSH command must start with ssh')
    arguments = []
    target = None
    index = 1
    while index < len(words):
        word = words[index]
        if word in ('-p', '-i', '-L'):
            index += 1
            if index >= len(words):
                raise ValueError(f'Missing {word} value')
            if word != '-L':
                arguments.extend((word, words[index]))
        elif word.startswith('-p') and len(word) > 2:
            arguments.extend(('-p', word[2:]))
        elif word.startswith('-i') and len(word) > 2:
            arguments.extend(('-i', word[2:]))
        elif re.fullmatch(r'[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+', word):
            if target is not None:
                raise ValueError('Multiple SSH targets')
            target = word
        else:
            raise ValueError(f'Unsupported SSH argument: {word}')
        index += 1
    if target is None:
        raise ValueError('SSH user@host is missing')
    if '-p' in arguments:
        port = arguments[arguments.index('-p') + 1]
        if not port.isdecimal() or not 1 <= int(port) <= 65535:
            raise ValueError('Invalid SSH port')
    return arguments, target


def source_files(root: Path) -> list[Path]:
    paths = []
    for part in ('scripts', 'models'):
        for path in (root / part).rglob('*'):
            if path.suffix.lower() not in ALLOWED_SUFFIXES:
                continue
            relative = path.relative_to(root)
            if part == 'models' and (len(relative.parts) < 3 or
                                     not (root / 'models' / relative.parts[1] / 'setup.sh').is_file()):
                continue
            if path.suffix.lower() == '.txt' and not path.name.endswith('constraints.txt'):
                continue
            if path.name.startswith('.') or any(token in path.name.lower() for token in ('secret', 'api_key', 'token')):
                continue
            if any(component in ('tests', '__pycache__', 'tmp') for component in relative.parts):
                continue
            if path.is_symlink() or not path.is_file():
                continue
            if path.stat().st_size > MAX_SOURCE_BYTES:
                raise ValueError(f'Source file is unexpectedly large: {relative}')
            if path.suffix.lower() == '.json':
                try:
                    json.loads(path.read_text(encoding='utf-8'))
                except (UnicodeError, json.JSONDecodeError):
                    print(f'Skipping invalid optional JSON: {relative}')
                    continue
            paths.append(path)
    return sorted(paths)


def build_archive(root: Path, output: Path) -> dict:
    files = source_files(root)
    manifest = {'files': {}}
    with tarfile.open(output, 'w') as archive:
        for path in files:
            relative = path.relative_to(root).as_posix()
            data = path.read_bytes()
            # Archives bypass Git's eol=lf checkout rules. Windows working
            # copies can still contain CRLF, which breaks bash and sourced conf.
            if path.suffix.lower() in {'.sh', '.conf'}:
                data = data.replace(b'\r\n', b'\n')
            manifest['files'][relative] = hashlib.sha256(data).hexdigest()
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
        installer = Path(__file__).with_name('remote_install.py').read_bytes()
        info = tarfile.TarInfo('remote_install.py')
        info.size = len(installer)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(installer))
        version_source = json.dumps(manifest['files'], sort_keys=True).encode('utf-8')
        manifest['version'] = hashlib.sha256(version_source).hexdigest()
        body = json.dumps(manifest, sort_keys=True).encode('utf-8')
        info = tarfile.TarInfo('manifest.json')
        info.size = len(body)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(body))
    return manifest


def checked_marker(command: list[str], marker: str) -> str:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    for line in result.stdout.splitlines():
        if line.startswith(marker):
            return line
    raise RuntimeError(f'SSH verification failed: {result.stdout[-2000:]}')


def shell_command(script: str) -> str:
    # Salad's SSH gateway executes argv directly instead of using a login shell.
    # Quote the script so both that gateway and a regular SSH shell pass one
    # argument to bash, preserving conditionals, pipelines and command chains.
    return 'bash -c ' + shlex.quote(script)


def workflow_source(model_dir: Path, name: str) -> Path | None:
    """Resolve bundled JSON, or return None for explicitly setup-created files."""
    for path in (model_dir / 'workflows' / name, model_dir / name):
        if path.is_file():
            return path
    key = (model_dir.name, name)
    if key in SETUP_WORKFLOWS:
        source = SETUP_WORKFLOWS[key]
        if source is None:
            if not (model_dir / 'setup.sh').is_file():
                raise ValueError(f'Workflow setup script is missing: {model_dir.name}/{name}')
            return None
        path = model_dir / source
        if path.is_file():
            return path
        raise ValueError(f'Workflow source is missing: {model_dir.name}/{source}')
    # Qwen Edit installs official.json under WORKFLOW_FILE_NAME at setup time.
    # Read only literal assignments; never execute the shell configuration.
    config = model_dir / 'model.conf'
    values = {}
    if config.is_file():
        for line in config.read_text(encoding='utf-8').splitlines():
            match = re.fullmatch(r'(WORKFLOW_FILE_NAME|WORKFLOW_SOURCE)=(.*)', line.strip())
            if match:
                words = shlex.split(match[2], comments=True)
                if len(words) == 1:
                    values[match[1]] = words[0]
    if name == values.get('WORKFLOW_FILE_NAME') and values.get('WORKFLOW_SOURCE'):
        path = model_dir / values['WORKFLOW_SOURCE']
        if path.resolve().is_relative_to(model_dir.resolve()) and path.is_file():
            return path
    raise ValueError(f'Workflow source is missing: {model_dir.name}/{name}')


def upload(ssh_command: str, model: str, provider: str = 'auto') -> tuple[str, str]:
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*', model) or not (ROOT / 'models' / model / 'setup.sh').is_file():
        raise ValueError(f'Unknown runnable model: {model}')
    config = json.loads((ROOT / 'models' / model / 'runtime.json').read_text(encoding='utf-8'))
    for workflow in config.get('workflows', []):
        path = workflow_source(ROOT / 'models' / model, workflow)
        if path is not None:
            json.loads(path.read_text(encoding='utf-8'))
    arguments, target = parse_ssh(ssh_command)
    ssh = ['ssh', '-T', *arguments, target]
    if provider == 'auto':
        result = checked_marker(ssh + [shell_command(
            "if [ -f /opt/salad/start.sh ]; then echo PROVIDER=salad; "
            "elif [ -d /workspace ]; then echo PROVIDER=vast; fi"
        )], 'PROVIDER=')
        provider = result.split('=', 1)[1]
    if provider not in ('vast', 'salad'):
        raise ValueError('Provider must be vast or salad')
    if provider == 'salad' and model == 'lightwan2.2-a14b':
        raise ValueError('LightWan is not supported by the Salad ComfyUI Gateway')
    (ROOT / 'tmp').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='remote-code-', dir=ROOT / 'tmp') as temporary:
        archive = Path(temporary) / 'code.tar'
        manifest = build_archive(ROOT, archive)
        nonce = uuid.uuid4().hex
        remote_archive = f'/workspace/.codex-transfer-{nonce}.tar'
        remote_stage = f'/workspace/.codex-transfer-{nonce}'
        scp_arguments = []
        if '-p' in arguments:
            scp_arguments.extend(('-P', arguments[arguments.index('-p') + 1]))
        if '-i' in arguments:
            scp_arguments.extend(('-i', arguments[arguments.index('-i') + 1]))
        subprocess.run(['scp', *scp_arguments, str(archive), f'{target}:{remote_archive}'], check=True)
        remote = (
            f'mkdir -p {remote_stage} && '
            f'tar -xf {remote_archive} -C {remote_stage} && '
            f'python3 {remote_stage}/remote_install.py {remote_stage} {REMOTE_ROOT} && '
            f'rm -f {remote_archive} && rm -r {remote_stage}'
        )
        checked_marker(ssh + [shell_command(remote)], f"TRANSFER_OK {manifest['version']}")
    return provider, manifest['version']


def setup_command(ssh_command: str, provider: str, model: str) -> str:
    arguments, target = parse_ssh(ssh_command)
    tokens = ['ssh', '-tt']
    for index in range(0, len(arguments), 2):
        flag, value = arguments[index:index + 2]
        if flag == '-i':
            value = "'" + value.replace("'", "''") + "'"
        tokens.extend((flag, value))
    tokens.append(target)
    script = (f'bash /opt/salad/select_model.sh {model}' if provider == 'salad'
              else f'bash {REMOTE_ROOT}/models/{model}/setup.sh')
    tokens.append("'" + script + "'")
    return ' '.join(tokens)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--ssh-command', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--provider', choices=('auto', 'vast', 'salad'), default='auto')
    args = parser.parse_args()
    provider, version = upload(args.ssh_command, args.model, args.provider)
    print(f'Code transfer verified: provider={provider} model={args.model} version={version}')
    print('Run this in PowerShell to watch model setup:')
    print(setup_command(args.ssh_command, provider, args.model))


if __name__ == '__main__':
    main()
