#!/usr/bin/env python3
"""Run a manually requested CLI inference command without VRAM scheduling."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_id")
    parser.add_argument("--root", type=Path, default=Path("/workspace/.qwen_runtime"))
    parser.add_argument("--port", type=int, default=8188, help="Kept for command compatibility")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("Specify a foreground command after --")
    registry = args.root / "state" / "registered" / f"{args.model_id}.json"
    model = json.loads(registry.read_text(encoding="utf-8"))
    if model["runtime_type"] != "cli":
        parser.error("Model is not a CLI runtime")
    pid_file = Path(model["pid_file"])
    with subprocess.Popen(command, cwd=model["engine_dir"]) as process:
        pid_file.write_text(f"{process.pid}\n", encoding="ascii")
        try:
            return process.wait()
        finally:
            pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
