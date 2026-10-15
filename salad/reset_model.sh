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

# Preserve user files outside the ComfyUI tree. This is a same-filesystem move.
if [ -d "$COMFY_DIR" ]; then
    [ ! -L "$COMFY_DIR" ] || fail 'ComfyUI path is a symlink.'
    archive="$WORKSPACE/salad-user-data/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    for name in input output user; do
        if [ -e "$COMFY_DIR/$name" ] && [ ! -L "$COMFY_DIR/$name" ]; then
            mkdir -p -- "$archive"
            mv -- "$COMFY_DIR/$name" "$archive/$name"
        fi
    done
    rm -rf -- "$COMFY_DIR"
    [ ! -d "$archive" ] || printf 'Saved input, output and user data: %s\n' "$archive"
fi

rm -rf -- "$VENV_DIR"
cp -a -- "$BASE_VENV" "$VENV_DIR"
rm -f -- "$PID_FILE" "$WORKSPACE/cloudflared.pid"
printf 'Reset complete. Run bash /opt/salad/select_model.sh <model-name>\n'
