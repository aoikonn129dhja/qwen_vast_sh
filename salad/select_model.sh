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
CONF="$REPO_ROOT/models/$MODEL/model.conf"
if [ -f "$CONF" ]; then
  usage="$(sed -nE 's/^MODEL_USAGE="([^"]+)"$/\1/p' "$CONF" | head -1)"
  if [ "$usage" = lightx2v-cli ]; then
    fail 'LightWan uses LightX2V, not ComfyUI. Run its setup.sh directly in the container. The Salad ComfyUI Gateway cannot serve this model.'
  fi
fi
LOCK="$WORKSPACE/.salad-setup-lock"
mkdir "$LOCK" 2>/dev/null || fail 'Another model setup is already running.'
trap 'rmdir "$LOCK"' EXIT
bash "$SETUP"
PID_FILE="$WORKSPACE/.qwen_runtime/state/gateway.pid"
[ -s "$PID_FILE" ] || fail 'Runtime Gateway PID file is missing.'
read -r gateway_pid < "$PID_FILE"
[[ "$gateway_pid" =~ ^[0-9]+$ ]] && kill -0 "$gateway_pid" 2>/dev/null || fail 'Runtime Gateway is not running.'
[ -r "/proc/$gateway_pid/cmdline" ] || fail 'Runtime Gateway PID cannot be verified.'
gateway_command="$(tr '\0' ' ' < "/proc/$gateway_pid/cmdline")"
[[ "$gateway_command" == *scripts/runtime/gateway.py* ]] || fail 'PID file does not identify the Runtime Gateway.'
if [ -s "$READY_FILE" ]; then
    grep -Fxq "$MODEL" "$READY_FILE" || { cat "$READY_FILE" > "$READY_FILE.part"; printf '%s\n' "$MODEL" >> "$READY_FILE.part"; mv -- "$READY_FILE.part" "$READY_FILE"; }
else
    printf '%s\n' "$MODEL" > "$READY_FILE.part"
    mv -- "$READY_FILE.part" "$READY_FILE"
fi
printf 'Model setup complete: %s\n' "$MODEL"
