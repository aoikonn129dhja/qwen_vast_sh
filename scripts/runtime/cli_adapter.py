#!/usr/bin/env python3
"""Run a foreground CLI inference job under the shared VRAM scheduler."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import secrets
import subprocess
import sys
import threading
from urllib.request import Request, urlopen


def request(action: str, model_id: str, token: str, port: int) -> None:
    body = json.dumps({"model_id": model_id, "token": token}).encode("utf-8")
    req = Request(
        f"http://127.0.0.1:{port}/runtime/cli/{action}", data=body,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(req, timeout=3600 if action == "admit" else 10) as response:
        if response.status != 200:
            raise RuntimeError(f"CLI scheduler rejected {action}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_id")
    parser.add_argument("--root", type=Path, default=Path("/workspace/.qwen_runtime"))
    parser.add_argument("--port", type=int, default=8188)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("Specify a foreground command after --")
    registry = args.root / "state" / "registered" / f"{args.model_id}.json"
    model = json.loads(registry.read_text(encoding="utf-8"))
    if model["runtime_type"] != "cli":
        parser.error("Model is not a CLI runtime")
    token = secrets.token_hex(32)
    request("admit", args.model_id, token, args.port)
    stop = threading.Event()
    pid_file = Path(model["pid_file"])

    def heartbeat() -> None:
        while not stop.wait(30):
            try:
                request("heartbeat", args.model_id, token, args.port)
            except Exception as exc:
                print(f"CLI scheduler heartbeat failed: {exc}", file=sys.stderr)

    process = None
    thread = threading.Thread(target=heartbeat, daemon=True)
    try:
        process = subprocess.Popen(command, cwd=model["engine_dir"])
        pid_file.write_text(f"{process.pid}\n", encoding="ascii")
        thread.start()
        return process.wait()
    except KeyboardInterrupt:
        if process is not None and process.poll() is None:
            print(f"Job is still running under PID {process.pid}", file=sys.stderr)
        return 130
    finally:
        stop.set()
        if process is None or process.poll() is not None:
            try:
                request("release", args.model_id, token, args.port)
            finally:
                pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
