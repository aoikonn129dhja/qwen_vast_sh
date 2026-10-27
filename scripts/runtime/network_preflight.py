#!/usr/bin/env python3
"""Measure the Hugging Face route before downloading missing model assets."""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import sys
import time
import urllib.request

from model_files import verify


MIB = 1024 * 1024


def speed_probe(url: str, target: int) -> float:
    request = urllib.request.Request(url, headers={
        "Range": f"bytes=0-{target - 1}",
        "User-Agent": "vast-model-setup-speed-test/1.0",
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
        raise OSError("No data received for the speed measurement")
    return received / MIB / max(time.monotonic() - started, 0.001)


def allow_download(speed: float, minimum: float, override: bool,
                   interactive: bool, answer=input) -> bool:
    if speed >= minimum:
        return True
    print(f"WARNING: Hugging Face の実測速度は {speed:.2f} MiB/s です。"
          f"基準の {minimum:g} MiB/s 未満です。", flush=True)
    print("別ホストの利用を検討してください。", flush=True)
    if override:
        return True
    if not interactive:
        print("非対話実行のため中止します。続行する場合は ALLOW_SLOW_DOWNLOAD=1 を指定してください。", flush=True)
        return False
    return answer("このホストで続行しますか？ [y/N]: ").strip().lower() in ("y", "yes")


def preflight(files: list[tuple[str, Path, str]], minimum: float, target: int,
              override: bool, interactive: bool) -> int:
    missing = []
    for url, path, expected in files:
        if not verify(path, expected):
            missing.append(url)
    if not missing:
        print("全モデルファイルを SHA-256 検証済み。速度試験は不要です。", flush=True)
        return 0
    print(f"Hugging Face から最大 {target / MIB:g} MiB を試験取得して回線速度を測定します。", flush=True)
    try:
        speed = speed_probe(missing[0], target)
    except Exception as error:
        print(f"WARNING: 速度測定に失敗しました: {type(error).__name__}: {error}", flush=True)
        print("速度判定をスキップしてセットアップを続行します。", flush=True)
        return 0
    print(f"実測: {speed:.2f} MiB/s（約 {speed * 8.388608:.1f} Mbps）", flush=True)
    return 0 if allow_download(speed, minimum, override, interactive) else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", nargs=3, action="append", required=True,
                        metavar=("URL", "PATH", "SHA256"))
    args = parser.parse_args()
    minimum = float(os.environ.get("MIN_DOWNLOAD_MIB_S", "10"))
    target = int(os.environ.get("SPEED_TEST_BYTES", str(8 * MIB)))
    if not math.isfinite(minimum) or minimum < 0 or target <= 0:
        parser.error("MIN_DOWNLOAD_MIB_S must be finite and >= 0; SPEED_TEST_BYTES must be > 0")
    files = [(url, Path(path), expected) for url, path, expected in args.file]
    if any(not url.startswith("https://huggingface.co/") for url, _, _ in files):
        parser.error("All probe URLs must use Hugging Face HTTPS")
    return preflight(files, minimum, target,
                     os.environ.get("ALLOW_SLOW_DOWNLOAD", "0") == "1",
                     sys.stdin.isatty())


if __name__ == "__main__":
    raise SystemExit(main())
