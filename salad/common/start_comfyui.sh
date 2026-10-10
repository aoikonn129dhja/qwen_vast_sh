#!/usr/bin/env bash
set -Eeuo pipefail
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
PYTHON="${PYTHON:-/opt/venv/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
GATEWAY_PORT="${GATEWAY_PORT:-8189}"
AUTH_PORT="${AUTH_PORT:-8190}"
for port in "$COMFY_PORT" "$GATEWAY_PORT" "$AUTH_PORT"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { echo 'ERROR: Invalid port.' >&2; exit 2; }
done
((10#$COMFY_PORT != 10#$GATEWAY_PORT && 10#$COMFY_PORT != 10#$AUTH_PORT && 10#$GATEWAY_PORT != 10#$AUTH_PORT)) || { echo 'ERROR: Ports must differ.' >&2; exit 2; }
COMFY_PORT=$((10#$COMFY_PORT))
GATEWAY_PORT=$((10#$GATEWAY_PORT))
AUTH_PORT=$((10#$AUTH_PORT))
COMFY_GATEWAY_USER="${COMFY_GATEWAY_USER:-}"
COMFY_GATEWAY_PASSWORD="${COMFY_GATEWAY_PASSWORD:-}"
if [ -z "$COMFY_GATEWAY_USER" ] || [[ "$COMFY_GATEWAY_USER" == *:* ]] || [ "${#COMFY_GATEWAY_PASSWORD}" -lt 20 ]; then
    echo 'ERROR: COMFY_GATEWAY_USER and a COMFY_GATEWAY_PASSWORD of at least 20 characters are required.' >&2
    exit 2
fi
cd "$COMFY_DIR"
pids=()
cleanup() {
    trap - TERM INT
    if ((${#pids[@]})); then
        kill "${pids[@]}" 2>/dev/null || true
        # Bound shutdown even if a child ignores TERM.
        (sleep 5; kill -KILL "${pids[@]}" 2>/dev/null || true) &
        local watchdog=$!
        wait "${pids[@]}" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
    fi
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT
"$PYTHON" main.py --listen 127.0.0.1 --port "$COMFY_PORT" &
pids+=("$!")
"$PYTHON" /opt/salad/common/auth_proxy.py --comfy-port "$COMFY_PORT" --proxy-port "$AUTH_PORT" &
pids+=("$!")
socat "TCP6-LISTEN:${GATEWAY_PORT},bind=[::],ipv6only=1,reuseaddr,fork" "TCP4:127.0.0.1:${AUTH_PORT}" &
pids+=("$!")
status=0
wait -n "${pids[@]}" || status=$?
# Both processes are long-lived: even a clean early exit is a failure.
if [ "$status" -eq 0 ]; then status=1; fi
exit "$status"
