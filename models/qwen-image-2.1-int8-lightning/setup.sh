#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "qwen-image-2.1-int8-lightning"
COMFY_PORT="$("$PYTHON" - "$MODEL_DIR/runtime.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['port'])
PY
)"
UPDATE_COMFYUI="${UPDATE_COMFYUI:-1}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

need git
need wget
need stat
need df
need sha256sum
[ -x "$PYTHON" ] || die "Python がありません: $PYTHON（Vast PyTorch または Salad コンテナを確認）"
[ -f "$MODEL_DIR/workflows/$WORKFLOW_FILE" ] || die "workflow がありません: $MODEL_DIR/workflows/$WORKFLOW_FILE"
mkdir -p "$WORKSPACE"

log 'GPU・ディスク容量を確認'
nvidia-smi || die 'NVIDIA GPU が利用できません。'
df -h "$WORKSPACE"
free_kb="$(df -Pk "$WORKSPACE" | awk 'NR == 2 { print $4 }')"
[ "$free_kb" -ge 23000000 ] || die '空き容量が23GB未満です。モデル約17.4GBと一時ファイルの領域を確保してください。'

# Ensure a recent ComfyUI to support the native Qwen Image 2.1 nodes.
log 'ComfyUI の準備'
runtime_clone_comfy "$MODEL_DIR/runtime.json"

log 'ComfyUI 依存パッケージを導入'
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"

HF_BASE="https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/$BASE_REVISION"
HF_LORA="https://huggingface.co/lightx2v/Qwen-Image-2.1-Lightning/resolve/$LORA_REVISION"

fetch_model() {
    "$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" "$1" "$2" "$3"
}

DIFFUSION_PATH="$SHARED_COMFY_DIR/models/diffusion_models/$DIFFUSION_FILE"
TEXT_ENCODER_PATH="$SHARED_COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
VAE_PATH="$SHARED_COMFY_DIR/models/vae/$VAE_FILE"
LORA_PATH="$SHARED_COMFY_DIR/models/loras/$LORA_FILE"
WORKFLOW_PATH="$SHARED_COMFY_DIR/user/default/workflows/$WORKFLOW_FILE"

# Do not download the optional Qwen 3.5 Prompt Enhancer: one image + one prompt only.
fetch_model "$HF_BASE/diffusion_models/$DIFFUSION_FILE" "$DIFFUSION_PATH" "$DIFFUSION_SHA256" 5000000000
fetch_model "$HF_BASE/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_PATH" "$TEXT_ENCODER_SHA256" 7000000000
fetch_model "$HF_BASE/vae/$VAE_FILE" "$VAE_PATH" "$VAE_SHA256" 400000000
fetch_model "$HF_LORA/$LORA_SOURCE_FILE" "$LORA_PATH" "$LORA_SHA256" 40000000

mkdir -p "$(dirname "$WORKFLOW_PATH")" "$SHARED_COMFY_DIR/input" "$SHARED_COMFY_DIR/output"
[ -e "$WORKFLOW_PATH" ] || { cp -- "$MODEL_DIR/workflows/$WORKFLOW_FILE" "${WORKFLOW_PATH}.tmp"; mv -f -- "${WORKFLOW_PATH}.tmp" "$WORKFLOW_PATH"; }
log "1画像入力の Lightning workflow を配置: $WORKFLOW_PATH"

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start

cat <<EOF2

============================================================
 SETUP COMPLETE: $MODEL_NAME
============================================================
ComfyUI  : http://127.0.0.1:$COMFY_PORT
Diffusion: $DIFFUSION_PATH
Text     : $TEXT_ENCODER_PATH
VAE      : $VAE_PATH
Lightning: $LORA_PATH
Workflow : $WORKFLOW_PATH

操作:
  1. ComfyUIを開き、上記のworkflowを読み込む。
  2. Load Image に編集元画像を指定する。
  3. TextEncodeQwenImage21 に英語プロンプトを入力する。
  4. 実行する。ManualSigmas に 4step の推奨値を設定済み。
ログ: tail -n 100 "$COMFY_LOG"
============================================================
EOF2
