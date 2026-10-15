#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
AUTH_PORT="${AUTH_PORT:-8190}"
GATEWAY_PORT="${GATEWAY_PORT:-8189}"
READY_FILE="${SALAD_READY_FILE:-$WORKSPACE/.salad-setup-ready}"
RUNTIME_PID_FILE="$WORKSPACE/.qwen_runtime/state/gateway.pid"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
for port in "$COMFY_PORT" "$AUTH_PORT" "$GATEWAY_PORT"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || fail 'Invalid port.'
done
COMFY_PORT=$((10#$COMFY_PORT))
AUTH_PORT=$((10#$AUTH_PORT))
GATEWAY_PORT=$((10#$GATEWAY_PORT))
((COMFY_PORT != AUTH_PORT && COMFY_PORT != GATEWAY_PORT && AUTH_PORT != GATEWAY_PORT)) || fail 'Ports must differ.'
password="${COMFY_GATEWAY_PASSWORD:-}"
[[ -n "${COMFY_GATEWAY_USER:-}" && "${COMFY_GATEWAY_USER}" != *:* && "${COMFY_GATEWAY_USER}" != *$'\n'* && "${COMFY_GATEWAY_USER}" != *$'\r'* && ${#password} -ge 20 ]] || fail 'Gateway credentials are required.'

gateway_running() {
    [ -s "$RUNTIME_PID_FILE" ] || return 1
    local pid cmdline
    read -r pid < "$RUNTIME_PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] || return 1
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    [[ "$cmdline" == *scripts/runtime/gateway.py* ]]
}

restore_gateway() {
    gateway_running && return 0
    local registry="$WORKSPACE/.qwen_runtime/state/registered"
    [ -d "$registry" ] || return 0
    compgen -G "$registry/*.json" >/dev/null || return 0
    local script="${SALAD_REPO_ROOT:-/workspace/qwen_vast_sh}/scripts/runtime/gateway.py"
    [ -f "$script" ] || fail "Runtime Gateway code is missing: $script"
    mkdir -p "$WORKSPACE/.qwen_runtime/logs" "$WORKSPACE/.qwen_runtime/state"
    nohup "$PYTHON" "$script" --root "$WORKSPACE/.qwen_runtime" --port "$COMFY_PORT" \
        > "$WORKSPACE/.qwen_runtime/logs/gateway.log" 2>&1 &
    printf '%s\n' "$!" > "$RUNTIME_PID_FILE"
}

pids=()
cleanup() {
    trap - TERM INT
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

printf 'Waiting for model setup. Run: bash /opt/salad/select_model.sh <model-name>\n'
restore_gateway
while :; do
    if [ -s "$READY_FILE" ] && ! gateway_running; then
        restore_gateway
    fi
    if [ -s "$READY_FILE" ] && gateway_running; then
        if ((${#pids[@]} == 0)); then
            "$PYTHON" /opt/salad/auth_proxy.py --comfy-port "$COMFY_PORT" --proxy-port "$AUTH_PORT" &
            pids+=("$!")
            socat "TCP6-LISTEN:${GATEWAY_PORT},bind=[::],ipv6only=1,reuseaddr,fork" "TCP4:127.0.0.1:${AUTH_PORT}" &
            pids+=("$!")
        fi
    elif ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
        pids=()
    fi
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null || fail 'Authenticated proxy stopped.'
    done
    sleep 2 &
    wait "$!"
done
