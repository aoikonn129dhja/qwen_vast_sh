#!/usr/bin/env bash
set -Eeuo pipefail

PREVIEW_PORT="${PREVIEW_PORT:-8765}"
PREVIEW_ROOT="${PREVIEW_ROOT:-/workspace/qwen_preview}"
CLOUDFLARED="${CLOUDFLARED_BIN:-/workspace/bin/cloudflared}"

TUNNEL_PID_FILE="$PREVIEW_ROOT/tunnel.pid"
TUNNEL_URL_FILE="$PREVIEW_ROOT/url.txt"
TUNNEL_LOG="$PREVIEW_ROOT/tunnel.log"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

if [[ ! "$PREVIEW_PORT" =~ ^[0-9]+$ ]] || (( PREVIEW_PORT < 1 || PREVIEW_PORT > 65535 )); then
    die "invalid PREVIEW_PORT: $PREVIEW_PORT"
fi

[ -x "$CLOUDFLARED" ] || die "cloudflared not found or not executable: $CLOUDFLARED"
command -v curl >/dev/null 2>&1 || die "curl is required"

mkdir -p "$PREVIEW_ROOT"

# The tunnel is useful only while the authenticated local preview server is up.
# An unauthenticated probe should normally receive 401; 200 is accepted for
# forward compatibility with a deliberately unauthenticated local server.
local_status="$(
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --max-time 2 "http://127.0.0.1:$PREVIEW_PORT/" 2>/dev/null || true
)"
if [ "$local_status" != "401" ] && [ "$local_status" != "200" ]; then
    die "preview server is not responding on http://127.0.0.1:$PREVIEW_PORT/; run run_batch.sh first"
fi

expected_exe="$(readlink -f "$CLOUDFLARED" 2>/dev/null || true)"
[ -n "$expected_exe" ] || die "could not resolve cloudflared path: $CLOUDFLARED"

is_preview_tunnel_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    local actual_exe cmdline
    actual_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$actual_exe" = "$expected_exe" ] || return 1

    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *" tunnel "* ]] || return 1
    [[ "$cmdline" == *"--url http://127.0.0.1:$PREVIEW_PORT"* ]]
}

declare -a tunnel_pids=()

if [ -f "$TUNNEL_PID_FILE" ]; then
    recorded_pid="$(tr -d '\r\n' < "$TUNNEL_PID_FILE")"
    if [[ "$recorded_pid" =~ ^[0-9]+$ ]] && kill -0 "$recorded_pid" 2>/dev/null; then
        if ! is_preview_tunnel_pid "$recorded_pid"; then
            die "refusing to stop PID $recorded_pid because it is not the preview tunnel"
        fi
        tunnel_pids+=("$recorded_pid")
    fi
fi

# Also find matching preview tunnels whose PID file was lost or became stale.
for proc_dir in /proc/[0-9]*; do
    pid="${proc_dir##*/}"
    if is_preview_tunnel_pid "$pid"; then
        already_added=0
        for known_pid in "${tunnel_pids[@]:-}"; do
            if [ "$known_pid" = "$pid" ]; then
                already_added=1
                break
            fi
        done
        [ "$already_added" -eq 1 ] || tunnel_pids+=("$pid")
    fi
done

if [ "${#tunnel_pids[@]}" -gt 0 ]; then
    echo "Stopping existing preview tunnel..."
    kill "${tunnel_pids[@]}" 2>/dev/null || true
    for _ in $(seq 1 30); do
        any_running=0
        for pid in "${tunnel_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                any_running=1
                break
            fi
        done
        [ "$any_running" -eq 0 ] && break
        sleep 0.1
    done

    for pid in "${tunnel_pids[@]}"; do
        if is_preview_tunnel_pid "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
fi

rm -f -- "$TUNNEL_PID_FILE" "$TUNNEL_URL_FILE"
: > "$TUNNEL_LOG"

echo "Starting a new preview tunnel..."
nohup "$CLOUDFLARED" tunnel \
    --no-autoupdate \
    --url "http://127.0.0.1:$PREVIEW_PORT" \
    > "$TUNNEL_LOG" 2>&1 &
new_pid=$!

pid_tmp="${TUNNEL_PID_FILE}.tmp.$$"
printf '%s\n' "$new_pid" > "$pid_tmp"
chmod 600 "$pid_tmp"
mv -f -- "$pid_tmp" "$TUNNEL_PID_FILE"

new_url=""
public_status=""
for _ in $(seq 1 45); do
    if ! kill -0 "$new_pid" 2>/dev/null; then
        break
    fi

    new_url="$(
        grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null \
            | tail -n 1 || true
    )"
    if [ -n "$new_url" ]; then
        public_status="$(
            curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
                --max-time 5 "$new_url/" 2>/dev/null || true
        )"
        if [ "$public_status" = "401" ] || [ "$public_status" = "200" ]; then
            break
        fi
    fi
    sleep 1
done

if [ -z "$new_url" ] || { [ "$public_status" != "401" ] && [ "$public_status" != "200" ]; }; then
    kill "$new_pid" 2>/dev/null || true
    rm -f -- "$TUNNEL_PID_FILE" "$TUNNEL_URL_FILE"
    echo "ERROR: failed to create a reachable preview URL. Tunnel log:" >&2
    tail -n 20 "$TUNNEL_LOG" >&2 || true
    exit 1
fi

url_tmp="${TUNNEL_URL_FILE}.tmp.$$"
printf '%s\n' "$new_url" > "$url_tmp"
chmod 600 "$url_tmp"
mv -f -- "$url_tmp" "$TUNNEL_URL_FILE"

echo "Preview tunnel: restarted"
echo "Preview URL      : $new_url"
echo "Preview user     : qwen"
if [ -f "$PREVIEW_ROOT/password.txt" ]; then
    echo "Preview password : $(tr -d '\r\n' < "$PREVIEW_ROOT/password.txt")"
fi
