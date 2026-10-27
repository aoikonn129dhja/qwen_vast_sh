#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "qwen-image-2.1-uncensored-gguf"
COMFY_PORT="$("$PYTHON" - "$MODEL_DIR/runtime.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['port'])
PY
)"
GGUF_NODE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-GGUF"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

need git
need wget
need sha256sum
need df
[ -x "$PYTHON" ] || die "$PYTHON がありません。Vast.ai PyTorch (Vast) テンプレートを使用してください。"
mkdir -p "$WORKSPACE"

log 'GPUとディスクを確認'
nvidia-smi || die 'NVIDIA GPUを検出できません。'
df -h "$WORKSPACE"
FREE_KB="$(df -Pk "$WORKSPACE" | awk 'NR==2 {print $4}')"
[ "$FREE_KB" -ge 25000000 ] || die '空きディスクが25GB未満です。追加ファイルを配置する余裕がありません。'

GGUF_REVISION="6b34e59458d3eb7ba6a6f86a116aed5253dc02c3"
GGUF_BASE="https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/$GGUF_REVISION"
"$PYTHON" "$REPO_ROOT/scripts/runtime/network_preflight.py" \
    --file "$GGUF_BASE/$GGUF_REL" "$SHARED_COMFY_DIR/models/diffusion_models/$GGUF_FILE" "$GGUF_SHA256" \
    --file "$GGUF_BASE/$TEXT_ENCODER_REL" "$SHARED_COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_SHA256" \
    --file "$GGUF_BASE/$VAE_REL" "$SHARED_COMFY_DIR/models/vae/$VAE_FILE" "$VAE_SHA256"

log 'ComfyUIを準備（既存インストールは変更しない）'
runtime_clone_comfy "$MODEL_DIR/runtime.json"

log 'ComfyUI依存を導入'
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"

log 'GGUFノードを準備'
mkdir -p "$COMFY_DIR/custom_nodes"
runtime_clone_node "$GGUF_NODE_REPO" "373048b8403a7820620065210a691263d4da0a61" "$GGUF_NODE_DIR"
if [ -f "$GGUF_NODE_DIR/requirements.txt" ]; then
    "$PYTHON" -m pip install -r "$GGUF_NODE_DIR/requirements.txt"
fi

# 固定コミットと既知のSHA-256でモデルを検証する。
# 取得元の固定リビジョンと各ファイルのSHA-256を検証する。
fetch_model() {
    local relative="$1" dest="$2" pinned="${3:-}" url expected actual
    url="$GGUF_BASE/$relative"
    case "$relative" in
        "$GGUF_REL")
            expected="e79c8a009f2ecbdb6c70fd663d9aea9ee304a0d91f347e4169a756b8ad141b41" ;;
        "$TEXT_ENCODER_REL")
            expected="$TEXT_ENCODER_SHA256" ;;
        "$VAE_REL")
            expected="$VAE_SHA256" ;;
        *) die "未登録のモデル: $relative" ;;
    esac

    if [ -n "$pinned" ] && [ "$expected" != "$pinned" ]; then
        die "固定SHA-256が設定と一致しません: $relative"
    fi
    "$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" "$url" "$dest" "$expected"
}

log 'モデル3ファイルを配置'
fetch_model "$GGUF_REL" "$SHARED_COMFY_DIR/models/diffusion_models/$GGUF_FILE" "$GGUF_SHA256"
fetch_model "$TEXT_ENCODER_REL" "$SHARED_COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
fetch_model "$VAE_REL" "$SHARED_COMFY_DIR/models/vae/$VAE_FILE"

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start

cat <<EOF2

============================================================
 SETUP COMPLETE: $MODEL_NAME
============================================================
ComfyUI : http://127.0.0.1:$COMFY_PORT
GGUF    : $SHARED_COMFY_DIR/models/diffusion_models/$GGUF_FILE
Encoder : $SHARED_COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE
VAE     : $SHARED_COMFY_DIR/models/vae/$VAE_FILE
Node    : $GGUF_NODE_DIR
Log     : $COMFY_LOG

Vast.aiのTunnelsからComfyUIのポートを開いてください。
ComfyUIでUnet Loader (GGUF)、CLIPLoader、VAELoaderを使用します。
============================================================
EOF2
