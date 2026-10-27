#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "ltx-2.3-uncensored-v1.4-q4"
COMFY_PORT="$("$PYTHON" - "$MODEL_DIR/runtime.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['port'])
PY
)"

UV_VERSION="0.11.28"
UV="${UV:-$WORKSPACE/bin/uv}"
UV_ARCHIVE_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
UV_ARCHIVE_SHA256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_BIN_SHA256="1cb9cd0a1749debf6049d7d2bb933882cc52d81016326ee6d99a786d6c988b03"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"
}

sha256_matches() {
    local path="$1"
    local expected="$2"
    [ -s "$path" ] || return 1
    [ "$(sha256sum "$path" | awk '{print $1}')" = "$expected" ]
}

install_uv() {
    mkdir -p "$WORKSPACE/bin"
    if [ -x "$UV" ] && sha256_matches "$UV" "$UV_BIN_SHA256"; then
        return 0
    fi

    local archive="$WORKSPACE/bin/uv-$UV_VERSION.tar.gz"
    local extract_dir="$WORKSPACE/bin/.uv-$UV_VERSION-extract.$$"

    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
    wget -q -O "$archive" "$UV_ARCHIVE_URL"
    sha256_matches "$archive" "$UV_ARCHIVE_SHA256" \
        || die "uvアーカイブのSHA-256が一致しません。"

    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"

    local extracted="$extract_dir/uv-x86_64-unknown-linux-gnu/uv"
    [ -f "$extracted" ] || die "uv実行ファイルがアーカイブ内にありません。"
    sha256_matches "$extracted" "$UV_BIN_SHA256" \
        || die "uv実行ファイルのSHA-256が一致しません。"

    install -m 0755 "$extracted" "$UV"
    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
}

need_cmd git
need_cmd wget
need_cmd tar
need_cmd install
need_cmd sha256sum
[ -x "$PYTHON" ] || die "$PYTHON が見つかりません。Vast.aiのPyTorch系テンプレートを確認してください。"

log "[1/5] uvを準備"
install_uv

log "[2/5] ComfyUIと依存を準備"
runtime_clone_comfy "$MODEL_DIR/runtime.json"
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"

log "[3/5] CCTech GGUF Loaderと依存を準備"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"
GGUF_LOADER_DIR="$CUSTOM_NODES_DIR/ComfyUI-GGUF-Loader"
mkdir -p "$CUSTOM_NODES_DIR"
runtime_clone_node "$GGUF_LOADER_REPO" "d8b3e2509603cafa1e470298599acd6bd980fe06" "$GGUF_LOADER_DIR"
if [ -f "$GGUF_LOADER_DIR/requirements.txt" ]; then
    "$UV" pip install --python "$PYTHON" -r "$GGUF_LOADER_DIR/requirements.txt"
fi
"$UV" pip install --python "$PYTHON" opencv-python-headless

log "[4/5] LTX-2.3 v1.4 Q4_K_Mの5ファイルとx2 upscalerを配置"
DIFFUSION_DIR="$SHARED_COMFY_DIR/models/diffusion_models"
TEXT_ENCODERS_DIR="$SHARED_COMFY_DIR/models/text_encoders"
VAE_DIR="$SHARED_COMFY_DIR/models/vae"

"$PYTHON" "$MODEL_DIR/download_models.py" \
    --repo "$HF_REPO" --revision "$HF_REVISION" \
    --file "$TRANSFORMER_REL" "$DIFFUSION_DIR/$TRANSFORMER_FILE" "$TRANSFORMER_SHA256" \
    --file "$TEXT_ENCODER_REL" "$TEXT_ENCODERS_DIR/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_SHA256" \
    --file "$PROJECTIONS_REL" "$TEXT_ENCODERS_DIR/$PROJECTIONS_FILE" "$PROJECTIONS_SHA256" \
    --file "$VIDEO_VAE_REL" "$VAE_DIR/$VIDEO_VAE_FILE" "$VIDEO_VAE_SHA256" \
    --file "$AUDIO_VAE_REL" "$VAE_DIR/$AUDIO_VAE_FILE" "$AUDIO_VAE_SHA256"

UPSCALER_PATH="$SHARED_COMFY_DIR/models/latent_upscale_models/$UPSCALER_FILE"
"$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" \
    "$UPSCALER_URL" "$UPSCALER_PATH" "$UPSCALER_SHA256"

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"
echo "Model       : $MODEL_NAME"
echo "ComfyUI     : http://127.0.0.1:$COMFY_PORT"
echo "Transformer : $DIFFUSION_DIR/$TRANSFORMER_FILE"
echo "TextEncoder : $TEXT_ENCODERS_DIR/$TEXT_ENCODER_FILE"
echo "Projection  : $TEXT_ENCODERS_DIR/$PROJECTIONS_FILE"
echo "Video VAE   : $VAE_DIR/$VIDEO_VAE_FILE"
echo "Audio VAE   : $VAE_DIR/$AUDIO_VAE_FILE"
echo
echo "CCTech nodes:"
echo "  $GGUF_LOADER_DIR"
echo
echo "ログ:"
echo "  tail -n 100 $COMFY_LOG"
echo "============================================================"
