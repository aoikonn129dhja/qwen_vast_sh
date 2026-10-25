#!/usr/bin/env python3
"""Upload a Windows image directory and run the Qwen Rapid V23 batch over SSH."""

from __future__ import annotations

import argparse
from contextlib import suppress
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import uuid
from pathlib import Path
from urllib.parse import urlsplit


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
REMOTE_INPUT_ROOT = "/workspace/ComfyUI/input/v23_batch"
REMOTE_RUNNER = "/workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v23/run_batch.sh"


def ssh_executable() -> str:
    found = shutil.which("ssh")
    if found:
        return found
    for path in (Path(r"C:\Windows\System32\OpenSSH\ssh.exe"),
                 Path(r"C:\Program Files\OpenSSH\ssh.exe")):
        if path.is_file():
            return str(path)
    raise ValueError("ssh が見つかりません。Windows OpenSSH を確認してください。")


def parse_target(value: str, port_override: int | None) -> tuple[str, int | None]:
    value = value.strip()
    if value.startswith("ssh://"):
        parsed = urlsplit(value)
        if not parsed.hostname or not parsed.username or parsed.path or parsed.query or parsed.fragment:
            raise ValueError("SSH URL は ssh://ユーザー@ホスト:ポート の形式にしてください。")
        target = f"{parsed.username}@{parsed.hostname}"
        port = port_override if port_override is not None else parsed.port
    else:
        target = value
        port = port_override
    if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:@[A-Za-z0-9_.-]+)?", target) or target.startswith("-"):
        raise ValueError("接続先は SSH のホスト名または ユーザー@ホスト を入力してください。")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("SSH ポートは 1 から 65535 の範囲で指定してください。")
    return target, port


def image_directory(value: str) -> Path:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    directory = Path(value).expanduser()
    if not directory.is_absolute():
        raise ValueError("Windows のフルパスを入力してください。")
    if not directory.is_dir():
        raise ValueError(f"画像ディレクトリが見つかりません: {directory}")
    return directory


def list_images(directory: Path) -> list[Path]:
    images = sorted(
        (path for path in directory.iterdir()
         if path.is_file() and not path.is_symlink()
         and path.suffix.lower() in IMAGE_EXTENSIONS),
        key=lambda path: path.name.casefold(),
    )
    if not images:
        raise ValueError("ディレクトリ直下に PNG、JPG、JPEG、WebP 画像がありません。")
    return images


def ssh_command(executable: str, target: str, port: int | None, identity: str | None) -> list[str]:
    command = [executable, "-T"]
    if port is not None:
        command.extend(["-p", str(port)])
    if identity:
        command.extend(["-i", identity])
    command.append(target)
    return command


def read_prompt() -> str:
    print("プロンプトを入力してください。改行できます。最後に単独の行で . を入力すると開始します。")
    lines = []
    while True:
        line = input()
        if line == ".":
            break
        lines.append(line)
    prompt = "\n".join(lines).strip()
    if not prompt:
        raise ValueError("プロンプトが空です。")
    return prompt


def upload_images(command: list[str], stage: str, images: list[Path], prompt: str) -> None:
    remote = (f"mkdir -p {stage}/images && "
              f"trap 'rm -rf -- {stage}' EXIT && "
              f"tar -x -C {stage} && trap - EXIT")
    with subprocess.Popen([*command, remote], stdin=subprocess.PIPE) as process:
        assert process.stdin is not None
        archive = None
        try:
            archive = tarfile.open(fileobj=process.stdin, mode="w|")
            prompt_bytes = prompt.encode("utf-8")
            info = tarfile.TarInfo("prompt.txt")
            info.size = len(prompt_bytes)
            info.mode = 0o600
            archive.addfile(info, io.BytesIO(prompt_bytes))
            for index, path in enumerate(images, 1):
                print(f"転送中 [{index}/{len(images)}] {path.name}", flush=True)
                archive.add(path, arcname=f"images/{path.name}", recursive=False)
            archive.close()
            process.stdin.close()
        except BaseException:
            # tarfile leaves its stream open on KeyboardInterrupt. Close it
            # before the SSH pipe to avoid an ignored write-to-closed-file error.
            if archive is not None:
                with suppress(OSError, ValueError):
                    archive.fileobj.close()
            with suppress(OSError, ValueError):
                process.stdin.close()
            if process.poll() is None:
                with suppress(OSError):
                    process.terminate()
            raise
        if process.wait() != 0:
            raise RuntimeError("SSH 経由の画像転送に失敗しました。")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("connection", nargs="*", help="SSH 接続コマンド、ホスト名、または ssh:// URL")
    parser.add_argument("-p", "--port", type=int, help="SSH ポート")
    parser.add_argument("-i", "--identity", help="SSH 秘密鍵のパス")
    parser.add_argument("-L", "--local-forward", action="append", metavar="SPEC",
                        help="通常の SSH コマンドから受け付けます。バッチでは転送を使いません")
    args = parser.parse_intermixed_args(argv)
    connection = args.connection[1:] if args.connection and args.connection[0].lower() in {"ssh", "ssh.exe"} else args.connection
    if len(connection) > 1:
        parser.error("SSH 接続先は1つだけ指定してください。")

    try:
        target_raw = (connection[0] if connection else None) or os.environ.get("QWEN_V23_SSH_TARGET") or input("SSH 接続先: ")
        target, port = parse_target(target_raw, args.port)
        source = image_directory(input("編集する画像ディレクトリの Windows フルパス: "))
        images = list_images(source)
        prompt = read_prompt()
        command = ssh_command(ssh_executable(), target, port, args.identity)
        run_id = uuid.uuid4().hex
        stage = f"{REMOTE_INPUT_ROOT}/{run_id}"
        print(f"{len(images)} 枚を転送します。", flush=True)
        upload_images(command, stage, images, prompt)
        print("V23 の生成を開始します。", flush=True)
        return subprocess.run([*command, f"bash {REMOTE_RUNNER} {stage}"], check=False).returncode
    except (EOFError, KeyboardInterrupt):
        print("\n中断しました。", file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
