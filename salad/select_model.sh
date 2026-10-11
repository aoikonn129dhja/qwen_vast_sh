#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${SALAD_REPO_ROOT:-/workspace/qwen_vast_sh}"
WORKSPACE="${WORKSPACE:-/workspace}"
READY_FILE="${SALAD_READY_FILE:-$WORKSPACE/.salad-setup-ready}"
MODEL="${1:-}"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail 'Specify a valid model directory.'
[ "$#" -eq 1 ] || fail 'Specify exactly one model.'
SETUP="$REPO_ROOT/models/$MODEL/setup.sh"
[ -f "$SETUP" ] || fail "Unknown model: $MODEL"
[ ! -e "$READY_FILE" ] || fail 'A model is already configured in this container.'
LOCK="$WORKSPACE/.salad-setup-lock"
mkdir "$LOCK" 2>/dev/null || fail 'Another model setup is already running.'
trap 'rmdir "$LOCK"' EXIT

bash "$SETUP"
PID_FILE="$WORKSPACE/comfyui.pid"
[ -s "$PID_FILE" ] || fail 'ComfyUI PID file is missing.'
read -r comfy_pid < "$PID_FILE"
[[ "$comfy_pid" =~ ^[0-9]+$ ]] && kill -0 "$comfy_pid" 2>/dev/null || fail 'ComfyUI is not running.'
printf '%s %s\n' "$MODEL" "$comfy_pid" > "$READY_FILE.part"
mv -- "$READY_FILE.part" "$READY_FILE"
printf 'Model setup complete: %s\n' "$MODEL"
