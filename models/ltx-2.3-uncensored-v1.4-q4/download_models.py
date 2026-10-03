"""Download the LTX model files with aggregate progress and a live ETA."""

import argparse
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path


MIB = 1024 ** 2
GIB = 1024 ** 3
PROBE_BYTES = 8 * MIB
REPORT_SECONDS = 5


def model_sizes(repo, revision, files):
    repo_path = urllib.parse.quote(repo, safe="/")
    revision_path = urllib.parse.quote(revision, safe="")
    url = f"https://huggingface.co/api/models/{repo_path}/tree/{revision_path}/split?recursive=true"
    with urllib.request.urlopen(url, timeout=30) as response:
        entries = json.load(response)
    available = {item["path"]: item.get("size") for item in entries}
    sizes = []
    for relative, _ in files:
        size = available.get(relative)
        if not isinstance(size, int) or size <= 0:
            raise RuntimeError(f"配布元でファイルとサイズを確認できません: {relative}")
        sizes.append(size)
    return sizes


def existing_bytes(files, sizes):
    total = 0
    for (_, destination), size in zip(files, sizes):
        current = destination.stat().st_size if destination.exists() else 0
        if current > size:
            raise RuntimeError(f"配布サイズより大きい既存ファイルがあります: {destination}")
        total += current
    return total


def speed_probe(url):
    request = urllib.request.Request(
        url,
        headers={"Range": f"bytes=0-{PROBE_BYTES - 1}", "User-Agent": "vast-ltx-setup/1.0"},
    )
    started = time.monotonic()
    received = 0
    with urllib.request.urlopen(request, timeout=30) as response:
        while received < PROBE_BYTES:
            chunk = response.read(min(MIB, PROBE_BYTES - received))
            if not chunk:
                break
            received += len(chunk)
            if time.monotonic() - started >= 20:
                break
    if not received:
        raise RuntimeError("速度測定用のデータを受信できませんでした")
    return received / max(time.monotonic() - started, 0.001)


def progress_line(done, total, speed):
    remaining = max(0, total - done)
    percent = 100 * done / total
    if speed > 0:
        eta = f"残り約{remaining / speed / 60:.1f}分"
        rate = f"{speed / MIB:.1f} MiB/s"
    else:
        eta = "残り時間は測定中"
        rate = "速度は測定中"
    return (
        f"モデル全体: {done / GIB:.2f}/{total / GIB:.2f} GiB "
        f"({percent:.1f}%) | 残り {remaining / GIB:.2f} GiB | {rate} | {eta}"
    )


def download(files, sizes, base_url, initial_speed):
    total = sum(sizes)
    initial_done = existing_bytes(files, sizes)
    started = time.monotonic()
    print(f"モデル{len(files)}ファイルの合計: {total / GIB:.2f} GiB", flush=True)
    print(progress_line(initial_done, total, initial_speed), flush=True)

    for index, ((relative, destination), size) in enumerate(zip(files, sizes), 1):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() and destination.stat().st_size == size:
            print(f"[{index}/{len(files)}] 既存ファイルを使用: {destination.name}", flush=True)
            continue

        url = f"{base_url}/{urllib.parse.quote(relative, safe='/')}"
        print(f"[{index}/{len(files)}] ダウンロード: {destination.name}", flush=True)
        process = subprocess.Popen(
            ["wget", "-c", "--progress=bar:force:noscroll", "-O", str(destination), url]
        )
        try:
            while True:
                try:
                    result = process.wait(timeout=REPORT_SECONDS)
                    break
                except subprocess.TimeoutExpired:
                    done = existing_bytes(files, sizes)
                    elapsed = max(time.monotonic() - started, 0.001)
                    live_speed = max(0, done - initial_done) / elapsed
                    print(progress_line(done, total, live_speed or initial_speed), flush=True)
        except BaseException:
            process.terminate()
            process.wait()
            raise
        if result != 0:
            raise RuntimeError(f"ダウンロードに失敗しました: {destination.name} (wget exit {result})")
        if destination.stat().st_size != size:
            raise RuntimeError(f"ダウンロードサイズが一致しません: {destination.name}")
        done = existing_bytes(files, sizes)
        elapsed = max(time.monotonic() - started, 0.001)
        live_speed = max(0, done - initial_done) / elapsed
        print(progress_line(done, total, live_speed or initial_speed), flush=True)

    print(f"モデル{len(files)}ファイルのダウンロード完了 ({len(files)}/{len(files)})", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--file", nargs=2, action="append", metavar=("REMOTE", "LOCAL"), required=True)
    args = parser.parse_args()
    files = [(remote, Path(local)) for remote, local in args.file]
    base_url = f"https://huggingface.co/{args.repo}/resolve/{urllib.parse.quote(args.revision, safe='')}"

    sizes = model_sizes(args.repo, args.revision, files)
    remaining = sum(sizes) - existing_bytes(files, sizes)
    initial_speed = 0
    if remaining:
        print("Hugging Faceから最大8 MiBを読み、回線速度を事前測定します。", flush=True)
        try:
            first_url = f"{base_url}/{urllib.parse.quote(files[0][0], safe='/')}"
            initial_speed = speed_probe(first_url)
            print(f"事前測定: {initial_speed / MIB:.1f} MiB/s", flush=True)
        except Exception as error:
            print(f"速度の事前測定を省略: {error}", flush=True)
    download(files, sizes, base_url, initial_speed)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, urllib.error.URLError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
