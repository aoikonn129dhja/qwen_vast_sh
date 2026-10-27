"""Numbered download, reconstruction and local-copy progress for all Wan assets."""

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import threading
import time

MIB = 1024 * 1024
REPORT_SECONDS = 5


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
            os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def download_models(files, repo, revision, shared_repo, shared_dir, download=None):
    if download is None:
        from huggingface_hub import hf_hub_download
        download = hf_hub_download
    completed = 0
    for index, (relative, folder, size) in enumerate(files, 1):
        prefix = f'[{6 + index}/10] [{index}/{len(files)} files]'
        destination = shared_dir / 'models' / folder / Path(relative).name
        log(prefix, f'START {destination.name} | completed {completed}/{len(files)} files')
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_file() and destination.stat().st_size == size:
            completed += 1
            log(prefix, f'SKIP already present: {destination} | completed {completed}/{len(files)} files')
            continue
        source_repo, source_revision = (repo, revision) if index == 1 else (shared_repo, 'main')
        with activity(prefix, f'Download / cache reconstruction: {destination.name}'):
            cached = Path(download(repo_id=source_repo, filename=relative, revision=source_revision))
            if cached.stat().st_size != size:
                raise RuntimeError(f'Download size mismatch: {relative}')
        copy_model(cached, destination, size, prefix)
        completed += 1
        log(prefix, f'DONE placed: {destination} | completed {completed}/{len(files)} files')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--shared-repo', required=True)
    parser.add_argument('--shared-dir', type=Path, required=True)
    parser.add_argument('--file', nargs=3, action='append', required=True)
    args = parser.parse_args()
    if len(args.file) != 3:
        parser.error('Expected diffusion model, text encoder and VAE')
    files = [(relative, folder, int(size)) for relative, folder, size in args.file]
    if any(size <= 0 for _, _, size in files):
        parser.error('File sizes must be positive')
    download_models(files, args.repo, args.revision, args.shared_repo, args.shared_dir)


if __name__ == '__main__':
    main()
