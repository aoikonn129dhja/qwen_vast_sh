#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../../.." && pwd)"
MODEL_CONFIG="$MODEL_DIR/model.conf"

# Run the existing shared setup first. It installs/updates ComfyUI, the 2511
# base model, text encoder, VAE, Lightning LoRA, workflow, and pose nodes.
MODEL_CONFIG="$MODEL_CONFIG" bash "$REPO_ROOT/scripts/setup_qwen_edit_model.sh"

# The two LoRAs below are specific to this 2511 profile, so keep them here
# instead of changing the shared setup engine used by 2509.
# shellcheck source=/dev/null
source "$MODEL_CONFIG"

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_LOG="${COMFY_LOG:-$WORKSPACE/comfyui.log}"
VERIFY_SHA256="${VERIFY_SHA256:-1}"

: "${MULTI_ANGLE_LORA_FILE:?MULTI_ANGLE_LORA_FILE is required}"
: "${MULTI_ANGLE_LORA_URL:?MULTI_ANGLE_LORA_URL is required}"
: "${MULTI_ANGLE_LORA_SHA256:?MULTI_ANGLE_LORA_SHA256 is required}"
: "${NSFW_LORA_FILE:?NSFW_LORA_FILE is required}"
: "${NSFW_LORA_URL:?NSFW_LORA_URL is required}"
: "${NSFW_LORA_SHA256:?NSFW_LORA_SHA256 is required}"

LORA_DIR="$COMFY_DIR/models/loras"
MULTI_ANGLE_LORA_PATH="$LORA_DIR/$MULTI_ANGLE_LORA_FILE"
NSFW_LORA_PATH="$LORA_DIR/$NSFW_LORA_FILE"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

sha256_matches() {
    local path="$1"
    local expected="$2"
    [ -s "$path" ] || return 1
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum が見つかりません。"
    local actual
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}

download_verified() {
    local url="$1"
    local dest="$2"
    local expected="$3"
    local dir name
    dir="$(dirname "$dest")"
    name="$(basename "$dest")"
    mkdir -p "$dir"

    if [ -s "$dest" ]; then
        if [ "$VERIFY_SHA256" = "1" ]; then
            if sha256_matches "$dest" "$expected"; then
                log "既存LoRAは正常。スキップ: $name"
                return 0
            fi
            log "既存LoRAのSHA-256が不一致。wget -cで再取得: $name"
        else
            log "既存LoRAを使用。SHA確認は無効: $name"
            return 0
        fi
    else
        log "追加LoRAをダウンロード: $name"
    fi

    (
        cd "$dir"
        wget -c --progress=bar:force:noscroll "$url"
    )

    [ -s "$dest" ] || die "ダウンロード後のファイルが空です: $dest"

    if [ "$VERIFY_SHA256" = "1" ]; then
        log "SHA-256確認: $name"
        sha256_matches "$dest" "$expected" || die "SHA-256が一致しません: $dest"
    fi
}

log "Qwen Image Edit 2511 追加LoRAを準備"
download_verified \
    "$MULTI_ANGLE_LORA_URL" \
    "$MULTI_ANGLE_LORA_PATH" \
    "$MULTI_ANGLE_LORA_SHA256"

download_verified \
    "$NSFW_LORA_URL" \
    "$NSFW_LORA_PATH" \
    "$NSFW_LORA_SHA256"

# The shared setup starts ComfyUI before these profile-specific LoRAs are
# installed. Restart once so the new model list is immediately visible.
if pgrep -f "python.*main.py" >/dev/null 2>&1; then
    log "追加LoRAを反映するためComfyUIを再起動"
    pkill -f "python.*main.py" || true
    sleep 2
fi

cd "$COMFY_DIR"
nohup "$PYTHON" main.py \
    --listen 127.0.0.1 \
    --port "$COMFY_PORT" \
    > "$COMFY_LOG" 2>&1 &
COMFY_PID=$!
echo "$COMFY_PID" > "$WORKSPACE/comfyui.pid"

READY=0
for _ in $(seq 1 90); do
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        echo "ComfyUIが起動途中で終了しました。ログ:"
        tail -n 100 "$COMFY_LOG" || true
        exit 1
    fi

    if "$PYTHON" - <<PY >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:${COMFY_PORT}/system_stats", timeout=1).read(1)
PY
    then
        READY=1
        break
    fi
    sleep 2
done

if [ "$READY" -ne 1 ]; then
    echo "ComfyUIが時間内に応答しませんでした。ログ:"
    tail -n 100 "$COMFY_LOG" || true
    exit 1
fi

echo
echo "============================================================"
echo " 2511 EXTRA LORAS INSTALLED"
echo "============================================================"
echo "Multiple Angles:"
echo "  $MULTI_ANGLE_LORA_PATH"
echo "  推奨strength: 0.8 - 1.0"
echo "  prompt形式: <sks> [azimuth] [elevation] [distance]"
echo
echo "NSFW:"
echo "  $NSFW_LORA_PATH"
echo
echo "Lightning:"
echo "  $COMFY_DIR/models/loras/$LORA_FILE"
echo "  構図・骨格追従の比較時はまずOFF推奨"
echo
echo "Comfy local:"
echo "  http://127.0.0.1:$COMFY_PORT"
echo "============================================================"
