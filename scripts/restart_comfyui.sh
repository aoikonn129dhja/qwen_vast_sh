#!/usr/bin/env bash
# RESTART_ALL_QWEN_COMFYUI_V1
set -Eeuo pipefail

RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/.qwen_runtime}"
LOG_DIR="$RUNTIME_ROOT/logs"
mkdir -p "$RUNTIME_ROOT/locks" "$RUNTIME_ROOT/tmp"
exec 9>"$RUNTIME_ROOT/locks/manual-control.lock"
flock -x 9
TMP_DIR="$(mktemp -d "$RUNTIME_ROOT/tmp/restart.XXXXXX")"
trap 'rm -f "$TMP_DIR"/*.args; rmdir "$TMP_DIR"' EXIT

declare -a PIDS=()
declare -A WORKDIRS PORTS MODELS

# 稼働中のモデル別ComfyUIを検出する。
for proc in /proc/[0-9]*; do
  [[ -r "$proc/cmdline" ]] || continue

  argv=()
  mapfile -d '' -t argv < "$proc/cmdline" 2>/dev/null || continue
  [[ "${argv[1]:-}" == main.py ]] || continue

  workdir="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
  [[ "$workdir" == "$RUNTIME_ROOT/instances/"*/ComfyUI ]] || continue

  model="${workdir#"$RUNTIME_ROOT/instances/"}"
  model="${model%/ComfyUI}"

  [[ "$model" =~ ^[a-zA-Z0-9._-]+$ ]] || continue
  [[ -f "$workdir/main.py" ]] || continue

  port=''
  for ((i=0; i < ${#argv[@]} - 1; i++)); do
    if [[ "${argv[i]}" == --port ]]; then
      port="${argv[i+1]}"
      break
    fi
  done

  [[ "$port" =~ ^[0-9]+$ ]] || continue

  pid="${proc##*/}"

  printf '%s\0' "${argv[@]}" > "$TMP_DIR/$pid.args"

  PIDS+=("$pid")
  WORKDIRS[$pid]="$workdir"
  PORTS[$pid]="$port"
  MODELS[$pid]="$model"
done

if (( ${#PIDS[@]} == 0 )); then
  echo '稼働中のモデル別ComfyUIが見つかりません。変更はしていません。' >&2
  exit 1
fi

echo "再起動対象: ${#PIDS[@]}個"

for pid in "${PIDS[@]}"; do
  echo "  ${MODELS[$pid]}: PID=$pid, port=${PORTS[$pid]}"
done

# Check every queue before stopping any backend. The Gateway uses the same lock.
for pid in "${PIDS[@]}"; do
  "$RUNTIME_ROOT/environments/${MODELS[$pid]}/bin/python" - "${PORTS[$pid]}" <<'PY'
import json
import sys
import urllib.request
with urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/queue', timeout=5) as response:
    queue = json.load(response)
if queue.get('queue_running') or queue.get('queue_pending'):
    raise SystemExit('ERROR: ComfyUI has queued or running work; restart refused.')
PY
done

# 全プロセスに停止要求を送る。
for pid in "${PIDS[@]}"; do
  kill -TERM "$pid" 2>/dev/null || true
done

# 停止完了を待機する。
for ((i=0; i<40; i++)); do
  remaining=0

  for pid in "${PIDS[@]}"; do
    state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"

    if [[ -n "$state" && "$state" != Z* ]]; then
      remaining=1
    fi
  done

  (( remaining == 0 )) && break
  sleep 0.5
done

if (( remaining != 0 )); then
  echo '停止しないプロセスがあります。強制終了せず、中止します。' >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

# 全インスタンスを起動完了待ちなしで並行起動する。
for pid in "${PIDS[@]}"; do
  mapfile -d '' -t argv < "$TMP_DIR/$pid.args"

  log="$LOG_DIR/restart-${MODELS[$pid]}-$stamp-$pid.log"

  (
    cd "${WORKDIRS[$pid]}"
    nohup "${argv[@]}" > "$log" 2>&1 </dev/null 9>&- &
    printf '%s\n' "$!" > "$RUNTIME_ROOT/state/${MODELS[$pid]}.pid"
  )

  echo "起動要求: ${MODELS[$pid]} (log: $log)"
done

# 各ComfyUIの内部APIを確認する。
for ((i=0; i<60; i++)); do
  healthy=0

  for pid in "${PIDS[@]}"; do
    if curl -fsS --max-time 2 \
      "http://127.0.0.1:${PORTS[$pid]}/system_stats" \
      2>/dev/null | grep -q '"comfyui_version"'; then
      healthy=$((healthy + 1))
    fi
  done

  (( healthy == ${#PIDS[@]} )) && break
  sleep 1
done

echo "API確認: $healthy / ${#PIDS[@]}個"

(( healthy == ${#PIDS[@]} )) || exit 1
