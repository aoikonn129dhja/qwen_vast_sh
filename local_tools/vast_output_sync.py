#!/usr/bin/env python3
"""Vast.aiの生成画像をWindowsへ定期回収する対話式ツール。

起動時にVast CLIのインスタンス一覧から対象を自動検出し、以後は10秒間隔で
Vast側の生成画像をWindowsへ回収する。Windows側の保存先は固定し、
Vast側の取得元はrun_batch.shのBATCH_ROOT設定から組み立てる。

事前準備:
    vastai set api-key YOUR_API_KEY

実行:
    python local_tools/vast_output_sync.py
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path, PurePosixPath


POLL_SECONDS = 10
REMOTE_LIST_TIMEOUT_SECONDS = 15
LOCAL_OUTPUT_DIR = Path(r"D:\po\NSFW_cos\temp_Auto_DL_vast")
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff"}
RUN_BATCH_PATH = Path(__file__).resolve().parents[1] / "run_batch.sh"
BATCH_ROOT_RE = re.compile(
    r'^\s*BATCH_ROOT="\$\{BATCH_ROOT:-([^"}]+)\}"',
    re.MULTILINE,
)
SSH_URL_RE = re.compile(
    r"ssh://(?P<user>[^@/:]+)@(?P<host>[^/:]+):(?P<port>\d+)"
)


def find_vastai() -> str | None:
    """Return the Vast CLI executable, including the uv tool default path."""

    executable = shutil.which("vastai")
    if executable:
        return executable

    candidates = [
        Path.home() / ".local" / "bin" / "vastai.exe",
        Path.home() / ".local" / "bin" / "vastai",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def find_scp() -> str | None:
    """Return scp from PATH or the standard Windows OpenSSH installation."""

    executable = shutil.which("scp")
    if executable:
        return executable

    candidates = [
        Path(r"C:\Windows\System32\OpenSSH\scp.exe"),
        Path(r"C:\Program Files\OpenSSH\scp.exe"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def find_ssh() -> str | None:
    """Return ssh from PATH or the standard Windows OpenSSH installation."""

    executable = shutil.which("ssh")
    if executable:
        return executable

    candidates = [
        Path(r"C:\Windows\System32\OpenSSH\ssh.exe"),
        Path(r"C:\Program Files\OpenSSH\ssh.exe"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def copy_environment(scp: str) -> dict[str, str]:
    """Make scp discoverable by the direct sync process on Windows."""

    environment = os.environ.copy()
    scp_dir = str(Path(scp).parent)
    path_entries = environment.get("PATH", "").split(os.pathsep)
    if scp_dir not in path_entries:
        environment["PATH"] = os.pathsep.join([scp_dir, *path_entries])
    return environment


def discover_ssh_endpoint(vastai: str, instance_id: str) -> tuple[str, str, int] | None:
    """Return the normal SSH endpoint for an instance.

    ``vastai copy`` uses an rsync-daemon style path internally.  That path is
    currently unreliable on Windows, so use the regular SSH endpoint exposed
    by ``vastai ssh-url`` and run scp directly instead.
    """

    result = subprocess.run(
        [vastai, "ssh-url", instance_id],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        print(f"SSH接続先を取得できませんでした: {detail}")
        return None

    match = SSH_URL_RE.search(result.stdout)
    if match is None:
        detail = result.stdout.strip() or "出力が空です"
        print(f"SSH接続先を解釈できませんでした: {detail}")
        return None

    return match.group("user"), match.group("host"), int(match.group("port"))


def parse_remote_file_list(output: str) -> list[tuple[str, int]]:
    """Parse find's relative-file and byte-size output, ignoring login text."""

    files: list[tuple[str, int]] = []
    for line in output.splitlines():
        relative_path, separator, size_text = line.rpartition("\t")
        if not separator or not relative_path or not size_text.isdigit():
            continue
        files.append((relative_path, int(size_text)))
    return files


def discover_remote_files(
    ssh: str,
    endpoint: tuple[str, str, int],
    remote_path: str,
    environment: dict[str, str],
) -> list[tuple[str, int]] | None:
    """List remote files and sizes without transferring file contents."""

    user, host, port = endpoint
    remote_root = remote_path.rstrip("/")
    remote_command = (
        f"find '{remote_root}' -type f -printf '%P\\t%s\\n'"
    )
    try:
        result = subprocess.run(
            [
                ssh,
                "-T",
                "-p",
                str(port),
                "-o",
                "StrictHostKeyChecking=accept-new",
                "-o",
                "ConnectTimeout=10",
                "-o",
                "ServerAliveInterval=5",
                "-o",
                "ServerAliveCountMax=1",
                f"{user}@{host}",
                remote_command,
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=environment,
            timeout=REMOTE_LIST_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        print(
            f"リモート出力一覧の確認が{REMOTE_LIST_TIMEOUT_SECONDS}秒でタイムアウトしました。"
            "次回確認時に再試行します。"
        )
        return None
    except OSError as error:
        print(f"リモート出力一覧を確認できませんでした: {error}")
        return None

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        print(f"リモート出力一覧を取得できませんでした: {detail}")
        return None
    if result.stdout is None:
        print("リモート出力一覧が空でした。次回確認時に再試行します。")
        return None
    return parse_remote_file_list(result.stdout)


def local_file_path(relative_path: str) -> Path | None:
    """Map a remote file to the flat local image directory."""

    path = PurePosixPath(relative_path)
    if path.is_absolute() or ".." in path.parts or not path.name:
        return None
    if path.suffix.casefold() not in IMAGE_EXTENSIONS:
        return None
    return LOCAL_OUTPUT_DIR / path.name


def _available_flat_path(path: Path) -> Path:
    """Return a non-colliding path in the flat output directory."""

    if not path.exists():
        return path
    index = 2
    while True:
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists():
            return candidate
        index += 1


def flatten_existing_output() -> None:
    """Move existing images from session folders into the output directory."""

    if not LOCAL_OUTPUT_DIR.is_dir():
        return

    moved = 0
    for source in sorted(LOCAL_OUTPUT_DIR.rglob("*")):
        if not source.is_file() or source.parent == LOCAL_OUTPUT_DIR:
            continue
        if source.suffix.casefold() not in IMAGE_EXTENSIONS:
            continue
        destination = _available_flat_path(LOCAL_OUTPUT_DIR / source.name)
        source.replace(destination)
        moved += 1

    for directory in sorted(
        (path for path in LOCAL_OUTPUT_DIR.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        try:
            directory.rmdir()
        except OSError:
            pass

    if moved:
        print(f"既存画像を保存先直下へ移動しました: {moved}枚")


def read_remote_output_path() -> str:
    """Read the default BATCH_ROOT from run_batch.sh and append output/."""

    try:
        source = RUN_BATCH_PATH.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError(f"run_batch.shを読み込めません: {RUN_BATCH_PATH}: {error}") from error

    match = BATCH_ROOT_RE.search(source)
    if match is None:
        raise RuntimeError(
            "run_batch.shからBATCH_ROOTの既定値を見つけられません。"
        )

    batch_root = match.group(1).rstrip("/")
    return posixpath.join(batch_root, "output") + "/"


def _instance_rows(payload: object) -> list[dict[str, object]]:
    """Extract instance objects from the CLI's raw response."""

    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]

    if not isinstance(payload, dict):
        return []

    for key in ("instances", "data", "results"):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    return []


def _instance_id(row: dict[str, object]) -> str | None:
    """Read an instance/contract ID from one raw CLI instance object."""

    for key in ("id", "instance_id", "contract_id"):
        value = row.get(key)
        if isinstance(value, int) and value > 0:
            return str(value)
        if isinstance(value, str) and value.isdigit() and int(value) > 0:
            return value
    return None


def discover_instances(vastai: str) -> list[tuple[str, str]]:
    """Return (instance_id, status) pairs from Vast without requiring an ID."""

    result = subprocess.run(
        [vastai, "show", "instances", "--raw"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        print(f"インスタンス一覧を取得できませんでした: {detail}")
        return []

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        print(f"インスタンス一覧のJSONを解釈できませんでした: {error}")
        return []

    instances: list[tuple[str, str]] = []
    seen: set[str] = set()
    for row in _instance_rows(payload):
        instance_id = _instance_id(row)
        if instance_id is None or instance_id in seen:
            continue
        status = str(row.get("actual_status") or row.get("status") or "unknown")
        instances.append((instance_id, status))
        seen.add(instance_id)
    return instances


def choose_instance(instances: list[tuple[str, str]]) -> str:
    """Choose an instance only when the one-instance assumption is not met."""

    if len(instances) == 1:
        return instances[0][0]

    print("複数のVastインスタンスが見つかりました。")
    for instance_id, status in instances:
        print(f"  {instance_id} ({status})")

    while True:
        value = input("回収対象のInstance IDを入力してください（終了: q）: ").strip()
        if value.casefold() == "q":
            raise KeyboardInterrupt
        if any(instance_id == value for instance_id, _status in instances):
            return value
        print("一覧にあるInstance IDを入力してください。")


def copy_output(
    vastai: str,
    ssh: str,
    scp: str,
    instance_id: str,
    remote_path: str,
    environment: dict[str, str],
) -> int:
    LOCAL_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    endpoint = discover_ssh_endpoint(vastai, instance_id)
    if endpoint is None:
        return 1

    user, host, port = endpoint
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] コピーを確認します。")
    print(f"リモート一覧を確認します: {user}@{host}:{port}{remote_path}")
    remote_files = discover_remote_files(ssh, endpoint, remote_path, environment)
    if remote_files is None:
        return 1

    copied = 0
    skipped = 0
    remote_root = remote_path.rstrip("/")
    for relative_path, remote_size in remote_files:
        destination = local_file_path(relative_path)
        if destination is None:
            print(f"安全でない相対パスを無視しました: {relative_path}")
            continue
        if destination.is_file() and destination.stat().st_size == remote_size:
            skipped += 1
            continue

        destination.parent.mkdir(parents=True, exist_ok=True)
        relative_destination = Path(destination.name)
        source = f"{user}@{host}:{remote_root}/{relative_path}"
        command = [
            scp,
            "-p",
            "-P",
            str(port),
            "-o",
            "StrictHostKeyChecking=accept-new",
            source,
            str(relative_destination),
        ]
        print(f"転送: {relative_path}")
        try:
            result = subprocess.run(
                command,
                check=False,
                cwd=LOCAL_OUTPUT_DIR,
                env=environment,
            )
        except OSError as error:
            print(f"コピーを実行できませんでした: {error}")
            return 1
        if result.returncode != 0:
            print(
                f"コピーに失敗しました（終了コード: {result.returncode}）。"
                "次の確認時に再試行します。"
            )
            return result.returncode
        copied += 1

    print(f"コピー確認が完了しました（転送: {copied}、既存: {skipped}）。")
    return 0


def main() -> int:
    vastai = find_vastai()
    if vastai is None:
        print(
            "Vast CLIが見つかりません。先に次を実行してください:\n"
            "  uv tool install vastai\n"
            "  vastai set api-key YOUR_API_KEY",
            file=sys.stderr,
        )
        return 1

    scp = find_scp()
    if scp is None:
        print(
            "scpが見つかりません。ローカル同期にはWindows OpenSSHのscpが必要です。\n"
            "Windows OpenSSHをインストールしてPATHに追加してから、もう一度実行してください。",
            file=sys.stderr,
        )
        return 1
    ssh = find_ssh()
    if ssh is None:
        print(
            "sshが見つかりません。Windows OpenSSHをインストールしてPATHに追加してください。",
            file=sys.stderr,
        )
        return 1
    environment = copy_environment(scp)
    LOCAL_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    flatten_existing_output()

    try:
        remote_path = read_remote_output_path()
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Vast Output Sync")
    print(f"取得元: {remote_path}")
    print(f"保存先: {LOCAL_OUTPUT_DIR}")
    print(f"確認間隔: {POLL_SECONDS}秒（固定）")

    print("インスタンスを自動検出して同期します。終了するにはCtrl+Cを押してください。")
    selected_instance_id: str | None = None

    try:
        while True:
            instances = discover_instances(vastai)
            if not instances:
                print(f"インスタンスが見つかりません。{POLL_SECONDS}秒後に再確認します。")
            else:
                available_ids = {instance_id for instance_id, _status in instances}
                if selected_instance_id not in available_ids:
                    selected_instance_id = choose_instance(instances)
                    print(f"回収対象を自動選択しました: {selected_instance_id}")

                status = next(
                    status
                    for instance_id, status in instances
                    if instance_id == selected_instance_id
                )
                print(f"現在の状態: {status}")
                copy_output(
                    vastai,
                    ssh,
                    scp,
                    selected_instance_id,
                    remote_path,
                    environment,
                )
            print(f"次回確認まで{POLL_SECONDS}秒待機します。")
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        print("同期を終了しました。")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
