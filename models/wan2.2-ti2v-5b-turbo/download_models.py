"""Numbered download, reconstruction and local-copy progress for all Wan assets."""

import argparse
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import threading
import time

MIB = 1024 * 1024
REPORT_SECONDS = 5


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8 * MIB), b''):
            digest.update(chunk)
    return digest.hexdigest()


def log(prefix, message):
    print(f'{prefix} {message}', flush=True)


@contextmanager
def activity(prefix, description, progress=None):
    started = time.monotonic()
    stopped = threading.Event()

    def status():
        elapsed = max(time.monotonic() - started, 0.001)
        if progress is None:
            return f'{description} (elapsed {elapsed:.0f}s)'
        done, total = progress()
        speed = done / elapsed
        eta = f'{(total - done) / speed:.0f}s' if speed > 0 else 'measuring'
        return (f'{description}: {done / MIB:.1f}/{total / MIB:.1f} MiB '
                f'({100 * done / total:.1f}%) | {speed / MIB:.1f} MiB/s | '
                f'ETA {eta} | elapsed {elapsed:.0f}s')

    def heartbeat():
        while not stopped.wait(REPORT_SECONDS):
            log(prefix, status())

    log(prefix, f'START {status()}')
    reporter = threading.Thread(target=heartbeat, daemon=True)
    reporter.start()
    try:
        yield
    except BaseException:
        stopped.set()
        reporter.join()
        log(prefix, f'FAILED {status()}')
        raise
    else:
        stopped.set()
        reporter.join()
        log(prefix, f'DONE {status()}')


def copy_model(source, destination, size, prefix):
    temporary = destination.with_name(destination.name + f'.part.{os.getpid()}')
    copied = 0
    try:
        with activity(prefix, 'Cache -> model directory copy', lambda: (copied, size)):
            with source.open('rb') as reader, temporary.open('wb') as writer:
                while chunk := reader.read(8 * MIB):
                    writer.write(chunk)
                    copied += len(chunk)
            if copied != size:
                raise RuntimeError(f'Copy size mismatch: {copied} != {size}')
            os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def download_models(files, repo, revision, shared_repo, shared_dir, download=None, shared_revision='main'):
    if download is None:
        from huggingface_hub import hf_hub_download
        download = hf_hub_download
    completed = 0
    for index, (relative, folder, size, expected) in enumerate(files, 1):
        prefix = f'[{6 + index}/10] [{index}/{len(files)} files]'
        destination = shared_dir / 'models' / folder / Path(relative).name
        log(prefix, f'START {destination.name} | completed {completed}/{len(files)} files')
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_file() or file_sha256(destination) != expected:
                raise RuntimeError(f'Existing model SHA-256 differs; preserved: {destination}')
            completed += 1
            log(prefix, f'Verified SHA-256; reuse: {destination} | completed {completed}/{len(files)} files')
            continue
        source_repo, source_revision = (repo, revision) if index == 1 else (shared_repo, shared_revision)
        with activity(prefix, f'Download / cache reconstruction: {destination.name}'):
            cached = Path(download(repo_id=source_repo, filename=relative, revision=source_revision))
            if cached.stat().st_size != size:
                raise RuntimeError(f'Download size mismatch: {relative}')
            if file_sha256(cached) != expected:
                raise RuntimeError(f'Download SHA-256 mismatch: {relative}')
        copy_model(cached, destination, size, prefix)
        completed += 1
        log(prefix, f'DONE placed: {destination} | completed {completed}/{len(files)} files')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--shared-repo', required=True)
    parser.add_argument('--shared-revision', required=True)
    parser.add_argument('--shared-dir', type=Path, required=True)
    parser.add_argument('--file', nargs=4, action='append', required=True)
    args = parser.parse_args()
    if len(args.file) != 3:
        parser.error('Expected diffusion model, text encoder and VAE')
    files = [(relative, folder, int(size), expected) for relative, folder, size, expected in args.file]
    if any(size <= 0 for _, _, size, _ in files):
        parser.error('File sizes must be positive')
    if any(len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected)
           for _, _, _, expected in files):
        parser.error('Expected a pinned SHA-256 for every file')
    download_models(files, args.repo, args.revision, args.shared_repo, args.shared_dir,
                    shared_revision=args.shared_revision)


if __name__ == '__main__':
    main()
