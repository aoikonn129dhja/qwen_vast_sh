#!/usr/bin/env bash
# Read-only checks to run inside a SaladCloud container terminal.
set -uo pipefail

COMFY_PORT=${COMFY_PORT:-8188}
GATEWAY_PORT=${GATEWAY_PORT:-8189}
AUTH_PORT=${AUTH_PORT:-8190}

section() { printf '\n== %s ==\n' "$1"; }
run_limited() {
    if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi
}
probe() {
    local label=$1 url=$2 result
    if ! command -v curl >/dev/null 2>&1; then
        printf '%s: curl unavailable\n' "$label"
        return
    fi
    result=$(curl --noproxy '*' --silent --output /dev/null \
        --max-time 5 --write-out '%{http_code}' "$url") || true
    if [ "$result" = 000 ]; then
        printf '%s: connection failed or timed out\n' "$label"
    else
        printf '%s: HTTP %s\n' "$label" "$result"
    fi
}

section 'Time and container'
date -u '+UTC %Y-%m-%d %H:%M:%S' || true
hostname || true
section 'Processes'
ps -eo pid,ppid,stat,etime,%cpu,%mem,comm,args 2>/dev/null |
    awk 'BEGIN { print "PID PPID STAT ELAPSED CPU% MEM% ROLE" }
         $7 ~ /^python/ && /[m]ain.py/ { role="ComfyUI" }
         $7 == "socat" { role="socat" }
         $7 ~ /^python/ && /[a]uth_proxy.py/ { role="auth_proxy" }
         $7 == "bash" && /[p]repare_models.sh/ { role="prepare_models" }
         NR > 1 && role != "" { print $1, $2, $3, $4, $5, $6, role; role="" }' || true
section 'Listening ports'
if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v a=":$COMFY_PORT" -v b=":$GATEWAY_PORT" -v c=":$AUTH_PORT" \
        'NR == 1 || index($4,a) || index($4,b) || index($4,c)'
else
    echo 'ss unavailable'
fi
section 'Local HTTP'
probe "ComfyUI 127.0.0.1:$COMFY_PORT" "http://127.0.0.1:$COMFY_PORT/"
probe "Gateway health 127.0.0.1:$GATEWAY_PORT" "http://127.0.0.1:$GATEWAY_PORT/healthz"
section 'Resources'
free -h 2>/dev/null || true
df -h / /opt/ComfyUI /tmp 2>/dev/null || true
if command -v nvidia-smi >/dev/null 2>&1; then
    run_limited nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader 2>&1 || true
else
    echo 'nvidia-smi unavailable'
fi
if [ -r /proc/pressure/memory ]; then cat /proc/pressure/memory; fi
section 'Interpretation'
echo 'Local ComfyUI fails: inspect process, memory, disk and container logs in SaladCloud.'
echo 'Local ComfyUI works but gateway fails: inspect socat/proxy and ports.'
echo 'HTTP 401 on gateway can be normal when Basic authentication is enabled.'
echo 'No stop, restart, download or generation was performed.'
