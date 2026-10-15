#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
VENV_DIR="${SALAD_VENV_DIR:-/venv/main}"
BASE_VENV="${SALAD_BASE_VENV:-/opt/salad/base-venv}"
READY_FILE="${SALAD_READY_FILE:-$WORKSPACE/.salad-setup-ready}"
LOCK="$WORKSPACE/.salad-setup-lock"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
[[ "$WORKSPACE" == /* && "$WORKSPACE" != / && "$COMFY_DIR" == "$WORKSPACE/ComfyUI" ]] || fail 'Unsafe workspace path.'
[[ "$VENV_DIR" == /* && "$VENV_DIR" != / && "$BASE_VENV" == /* && "$BASE_VENV" != / && "$VENV_DIR" != "$BASE_VENV" ]] || fail 'Unsafe Python path.'
[ -x "$BASE_VENV/bin/python" ] || fail 'Base Python environment is missing.'
mkdir "$LOCK" 2>/dev/null || fail 'Another model setup or reset is running.'
trap 'rmdir "$LOCK"' EXIT
[ ! -s "$READY_FILE" ] || [ -s "$WORKSPACE/comfyui.pid" ] || fail 'ComfyUI PID file is missing.'

# Withdraw readiness before stopping ComfyUI so the gateway closes during reset.
rm -f -- "$READY_FILE" "$READY_FILE.part"
PID_FILE="$WORKSPACE/comfyui.pid"
if [ -s "$PID_FILE" ]; then
    read -r pid < "$PID_FILE" || true
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        [ -d "/proc/$pid" ] || fail 'Cannot verify the ComfyUI process.'
        cwd="$(readlink -f -- "/proc/$pid/cwd")"
        command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
        [[ "$cwd" == "$COMFY_DIR" && "$command_line" == *main.py* ]] || fail 'PID file does not identify this ComfyUI process.'
        kill "$pid"
        for _ in {1..30}; do
            kill -0 "$pid" 2>/dev/null || break
            [ "$(sed -E 's/^.*\) ([A-Z]) .*/\1/' "/proc/$pid/stat" 2>/dev/null || true)" == Z ] && break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            state="$(sed -E 's/^.*\) ([A-Z]) .*/\1/' "/proc/$pid/stat" 2>/dev/null || true)"
            [[ "$state" == Z || "$state" == X ]] || fail 'ComfyUI did not stop.'
        fi
    fi
fi

# Keep ComfyUI itself and user data. Remove downloaded models and model-specific nodes.
if [ -d "$COMFY_DIR" ]; then
    [ ! -L "$COMFY_DIR" ] || fail 'ComfyUI path is a symlink.'
    if [ -d "$COMFY_DIR/models" ] && [ ! -L "$COMFY_DIR/models" ]; then
        find "$COMFY_DIR/models" -mindepth 2 -maxdepth 2 ! -name 'README*' ! -name 'put_*_here' -exec rm -rf -- {} +
    fi
    if [ -d "$COMFY_DIR/custom_nodes" ] && [ ! -L "$COMFY_DIR/custom_nodes" ]; then
        find "$COMFY_DIR/custom_nodes" -mindepth 1 -maxdepth 1 ! -name 'example_node.py.example' -exec rm -rf -- {} +
    fi
fi

rm -rf -- "$VENV_DIR"
cp -a -- "$BASE_VENV" "$VENV_DIR"
rm -f -- "$PID_FILE" "$WORKSPACE/cloudflared.pid"
printf 'Model reset complete; ComfyUI and user data remain. Run bash /opt/salad/select_model.sh <model-name>\n'
