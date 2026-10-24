#!/usr/bin/env python3
"""Inspect or manually unload installed models; workflow selection is automatic."""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from urllib.request import urlopen

from scheduler import Scheduler


def gpu_memory() -> str:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.free,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, check=True, timeout=10,
        )
        return result.stdout.strip() + " MiB (used, free, total)"
    except (OSError, subprocess.SubprocessError):
        return "GPU memory unavailable"


def gateway_pid(root: Path) -> int | None:
    try:
        pid = int((root / "state" / "gateway.pid").read_text(encoding="ascii").strip())
        command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ")
    except (OSError, ValueError):
        return None
    script = str(Path(__file__).with_name("gateway.py")).encode()
    return pid if script in command else None


def restart_gateway(scheduler: Scheduler) -> None:
    for model_id, model in scheduler.models.items():
        if model["runtime_type"] == "comfyui" and scheduler.status(model_id)["state"] == "RUNNING":
            raise RuntimeError(f"Queue is busy: {model_id}")
    pid = gateway_pid(scheduler.root)
    if pid is not None:
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            if gateway_pid(scheduler.root) is None:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"Gateway PID {pid} did not stop; no forced kill was sent")
    candidates = [model for model in scheduler.models.values()
                  if model["runtime_type"] == "comfyui"]
    if not candidates:
        raise RuntimeError("No registered ComfyUI runtime")
    python = candidates[0]["python"]
    log_path = scheduler.root / "logs" / "gateway.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("ab") as log:
        process = subprocess.Popen(
            [python, str(Path(__file__).with_name("gateway.py")),
             "--root", str(scheduler.root), "--port", "8188"],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
    (scheduler.root / "state" / "gateway.pid").write_text(f"{process.pid}\n", encoding="ascii")
    for _ in range(100):
        try:
            with urlopen("http://127.0.0.1:8188/runtime/healthz", timeout=1):
                return
        except OSError:
            if process.poll() is not None:
                raise RuntimeError(f"Gateway exited; see {log_path}")
            time.sleep(0.1)
    raise RuntimeError(f"Gateway did not respond; see {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(os.environ.get("RUNTIME_ROOT", "/workspace/.qwen_runtime")))
    subcommands = parser.add_subparsers(dest="action", required=True)
    subcommands.add_parser("list", help="List installed models and global GPU memory")
    for name in ("load", "unload"):
        subcommands.add_parser(name).add_argument("model_id")
    subcommands.add_parser("restart-gateway", help="Restart the Gateway after a code update")
    args = parser.parse_args()
    root = args.root.resolve()
    (root / "locks").mkdir(parents=True, exist_ok=True)
    try:
        with (root / "locks" / "manual-control.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            scheduler = Scheduler(root)
            if args.action == "list":
                print("GPU:", gpu_memory())
                for model_id in sorted(scheduler.models):
                    info = scheduler.status(model_id)
                    marker = "*" if info["active"] else " "
                    print(f"{marker} {model_id}: {info['state']}")
                print("Workflows select their backend automatically; weights load on the first Queue.")
                print("BACKEND_READY means ComfyUI is running, not that weights are in VRAM.")
            elif args.action == "restart-gateway":
                restart_gateway(scheduler)
                print("Gateway restarted")
            elif args.action == "load":
                current = scheduler.active_model()
                if current and current != args.model_id and scheduler.status(current)["state"] == "RUNNING":
                    raise RuntimeError(f"Queue is busy: {current}")
                asyncio.run(scheduler.start(args.model_id))
                print(f"Selected {args.model_id}. Reload the browser; weights load on the first Queue.")
                print("Other backends were not unloaded. Use unload MODEL_ID if VRAM is insufficient.")
            else:
                asyncio.run(scheduler.unload(args.model_id))
                print(f"Stopped {args.model_id}; its files remain on SSD")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
