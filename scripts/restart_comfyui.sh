#!/usr/bin/env bash
set -Eeuo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_LOG="${COMFY_LOG:-/workspace/comfyui.log}"

[ -d "$COMFY_DIR" ] || { echo "ComfyUI directory not found: $COMFY_DIR" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "Python executable not found: $PYTHON" >&2; exit 1; }

pkill -f '[p]ython.*main.py' || true
sleep 2

cd "$COMFY_DIR"
nohup "$PYTHON" main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  > "$COMFY_LOG" 2>&1 </dev/null &

echo "ComfyUI started with PID $!; log: $COMFY_LOG"
