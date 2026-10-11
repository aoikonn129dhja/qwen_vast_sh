#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${SALAD_REPO_ROOT:-/workspace/qwen_vast_sh}"
WORKSPACE="${WORKSPACE:-/workspace}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
AUTH_PORT="${AUTH_PORT:-8190}"
GATEWAY_PORT="${GATEWAY_PORT:-8189}"
MODEL="${MODEL:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail 'MODEL must name a model directory.'
SETUP="$REPO_ROOT/models/$MODEL/setup.sh"
[ -f "$SETUP" ] || fail "Unknown model: $MODEL"
for port in "$COMFY_PORT" "$AUTH_PORT" "$GATEWAY_PORT"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || fail 'Invalid port.'
done
COMFY_PORT=$((10#$COMFY_PORT))
AUTH_PORT=$((10#$AUTH_PORT))
GATEWAY_PORT=$((10#$GATEWAY_PORT))
((COMFY_PORT != AUTH_PORT && COMFY_PORT != GATEWAY_PORT && AUTH_PORT != GATEWAY_PORT)) || fail 'Ports must differ.'
password="${COMFY_GATEWAY_PASSWORD:-}"
[[ -n "${COMFY_GATEWAY_USER:-}" && "${COMFY_GATEWAY_USER}" != *:* && "${COMFY_GATEWAY_USER}" != *$'\n'* && "${COMFY_GATEWAY_USER}" != *$'\r'* && ${#password} -ge 20 ]] || fail 'Gateway credentials are required.'

bash "$SETUP"
PID_FILE="$WORKSPACE/comfyui.pid"
[ -f "$PID_FILE" ] || fail 'ComfyUI PID file is missing.'
read -r comfy_pid < "$PID_FILE"
comfy_running() {
    [[ "$comfy_pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$comfy_pid" 2>/dev/null || return 1
    [ -r "/proc/$comfy_pid/stat" ] || return 1
    local state
    state="$(sed -E 's/^.*\) ([A-Z]) .*/\1/' "/proc/$comfy_pid/stat")"
    [ "$state" != Z ] && [ "$state" != X ]
}
comfy_running || fail 'ComfyUI is not running.'

pids=()
cleanup() {
    trap - TERM INT
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
    kill "$comfy_pid" 2>/dev/null || true
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

"$PYTHON" /opt/salad/auth_proxy.py --comfy-port "$COMFY_PORT" --proxy-port "$AUTH_PORT" &
pids+=("$!")
socat "TCP6-LISTEN:${GATEWAY_PORT},bind=[::],ipv6only=1,reuseaddr,fork" "TCP4:127.0.0.1:${AUTH_PORT}" &
pids+=("$!")
while :; do
    comfy_running || fail 'ComfyUI stopped.'
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null || fail 'Gateway process stopped.'
    done
    sleep 2 &
    wait "$!"
done
