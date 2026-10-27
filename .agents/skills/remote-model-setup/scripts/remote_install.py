#!/usr/bin/env python3
"""Verify a staged code archive and activate code files only."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


SAFE_SUFFIXES = {'.sh', '.py', '.json', '.conf', '.lock', '.in', '.patch', '.js', '.txt'}


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def install(stage, target):
    stage = Path(stage)
    target = Path(target)
    if target.is_symlink():
        raise ValueError(f'Refusing symlinked code root: {target}')
    manifest = json.loads((stage / 'manifest.json').read_text(encoding='utf-8'))
    files = manifest['files']
    if not isinstance(files, dict) or not files:
        raise ValueError('Empty transfer manifest')
    for name, expected in files.items():
        relative = Path(name)
        if (relative.is_absolute() or '..' in relative.parts or
                relative.parts[0] not in ('models', 'scripts') or
                relative.suffix.lower() not in SAFE_SUFFIXES or len(expected) != 64):
            raise ValueError(f'Unsafe transfer entry: {name}')
        source = stage / relative
        if source.is_symlink() or not source.is_file() or digest(source) != expected:
            raise ValueError(f'Transfer verification failed: {name}')
    for name in files:
        relative = Path(name)
        source = stage / relative
        destination = target / relative
        parent = target
        for component in relative.parts[:-1]:
            parent = parent / component
            if parent.is_symlink():
                raise ValueError(f'Unsafe destination directory: {parent}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink() or (destination.exists() and not destination.is_file()):
            raise ValueError(f'Unsafe destination: {destination}')
        temporary = destination.with_name(destination.name + f'.transfer-new.{os.getpid()}')
        if temporary.exists() or temporary.is_symlink():
            raise ValueError(f'Previous transfer incomplete: {temporary}')
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    marker = target / '.codex-deployed.json'
    temporary = target / '.codex-deployed.json.transfer-new'
    temporary.write_text(json.dumps(manifest, sort_keys=True) + '\n', encoding='utf-8')
    os.replace(temporary, marker)
    print('TRANSFER_OK ' + manifest['version'], flush=True)


if __name__ == '__main__':
    install(sys.argv[1], sys.argv[2])
