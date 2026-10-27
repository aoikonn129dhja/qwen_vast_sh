"""V23-style host network preflight, using only the Python standard library."""

import argparse
import math
import os
from pathlib import Path
import sys
import time
import urllib.request

MIB = 1024 * 1024


def speed_probe(url, target):
    request = urllib.request.Request(url, headers={
        'Range': f'bytes=0-{target - 1}',
        'User-Agent': 'vast-wan-turbo-setup-speed-test/1.0',
    })
    started = time.monotonic()
    received = 0
    with urllib.request.urlopen(request, timeout=15) as response:
        while received < target:
            chunk = response.read(min(MIB, target - received))
            if not chunk:
                break
            received += len(chunk)
            if time.monotonic() - started >= 20:
                break
    if not received:
        raise OSError('No data received for the speed measurement')
    return received / MIB / max(time.monotonic() - started, 0.001)


def allow_download(speed, minimum, override, interactive, answer=input):
    if speed >= minimum or override:
        return True
    print(f'WARNING: Hugging Face speed is below {minimum:g} MiB/s.', flush=True)
    print('Consider another host. Set ALLOW_SLOW_DOWNLOAD=1 to continue.', flush=True)
    if not interactive:
        print('Non-interactive setup stopped.', flush=True)
        return False
    return answer('Continue on this host? [y/N]: ').strip().lower() in ('y', 'yes')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', required=True)
    parser.add_argument('--shared-dir', type=Path, required=True)
    parser.add_argument('--file', nargs=2, action='append', required=True)
    args = parser.parse_args()
    minimum = float(os.environ.get('MIN_DOWNLOAD_MIB_S', '10'))
    target = int(os.environ.get('SPEED_TEST_BYTES', str(8 * MIB)))
    if not math.isfinite(minimum) or minimum < 0 or target <= 0:
        parser.error('MIN_DOWNLOAD_MIB_S must be finite and >= 0; SPEED_TEST_BYTES must be > 0')
    remaining = 0
    for relative, size_text in args.file:
        size = int(size_text)
        destination = args.shared_dir / 'models' / relative
        if not destination.is_file() or destination.stat().st_size != size:
            remaining += size
    print(f'[2/5] Network preflight (up to {target / MIB:g} MiB)', flush=True)
    if not remaining:
        print('All model files have the expected sizes; no download or speed probe needed.', flush=True)
        return 0
    print(f'Missing models: {remaining / 1e9:.2f} GB', flush=True)
    try:
        speed = speed_probe(args.url, target)
    except Exception as error:
        # Match V23: a probe failure warns and does not block the actual download.
        print(f'WARNING: Network preflight failed: {type(error).__name__}: {error}', flush=True)
        print('Continuing without a speed decision.', flush=True)
        return 0
    print(f'Measured: {speed:.2f} MiB/s (about {speed * 8.388608:.1f} Mbps)', flush=True)
    print(f'Estimated missing-model download: {remaining / (speed * MIB) / 60:.1f} minutes', flush=True)
    permitted = allow_download(speed, minimum,
                               os.environ.get('ALLOW_SLOW_DOWNLOAD', '0') == '1',
                               sys.stdin.isatty())
    return 0 if permitted else 2


if __name__ == '__main__':
    raise SystemExit(main())
