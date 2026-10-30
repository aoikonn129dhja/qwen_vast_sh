#!/usr/bin/env bash
set -Eeuo pipefail
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$MODEL_DIR/model.conf"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "qwen-image-2.1-int8-lightning"
COMFY_PORT="$("$PYTHON" - "$MODEL_DIR/runtime.json" <<'PYJSON'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['port'])
PYJSON
)"
log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }
need git; need wget; need curl; need stat; need df; need sha256sum
[ -x "$PYTHON" ] || die "Python がありません: $PYTHON"
[ -f "$MODEL_DIR/workflows/$WORKFLOW_FILE" ] || die "workflow がありません。"
mkdir -p "$WORKSPACE"
log 'GPU・ディスク容量を確認'
nvidia-smi || die 'NVIDIA GPU が利用できません。'
df -h "$WORKSPACE"
free_kb="$(df -Pk "$WORKSPACE" | awk 'NR == 2 { print $4 }')"
[ "$free_kb" -ge 23000000 ] || die '空き容量が23GB未満です。'
HF_BASE="https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/$BASE_REVISION"
HF_LORA="https://huggingface.co/lightx2v/Qwen-Image-2.1-Lightning/resolve/$LORA_REVISION"
DIFFUSION_PATH="$SHARED_COMFY_DIR/models/diffusion_models/$DIFFUSION_FILE"
TEXT_ENCODER_PATH="$SHARED_COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
VAE_PATH="$SHARED_COMFY_DIR/models/vae/$VAE_FILE"
LORA_PATH="$SHARED_COMFY_DIR/models/loras/$LORA_FILE"
"$PYTHON" "$REPO_ROOT/scripts/runtime/network_preflight.py" \
    --file "$HF_BASE/diffusion_models/$DIFFUSION_FILE" "$DIFFUSION_PATH" "$DIFFUSION_SHA256" \
    --file "$HF_BASE/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_PATH" "$TEXT_ENCODER_SHA256" \
    --file "$HF_BASE/vae/$VAE_FILE" "$VAE_PATH" "$VAE_SHA256" \
    --file "$HF_LORA/$LORA_SOURCE_FILE" "$LORA_PATH" "$LORA_SHA256"
log 'ComfyUI の準備'
runtime_clone_comfy "$MODEL_DIR/runtime.json"
log 'ComfyUI 依存パッケージを導入'
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"
fetch_model() { "$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" "$1" "$2" "$3"; }
WORKFLOW_PATH="$SHARED_COMFY_DIR/user/default/workflows/$WORKFLOW_FILE"
fetch_model "$HF_BASE/diffusion_models/$DIFFUSION_FILE" "$DIFFUSION_PATH" "$DIFFUSION_SHA256"
fetch_model "$HF_BASE/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_PATH" "$TEXT_ENCODER_SHA256"
fetch_model "$HF_BASE/vae/$VAE_FILE" "$VAE_PATH" "$VAE_SHA256"
fetch_model "$HF_LORA/$LORA_SOURCE_FILE" "$LORA_PATH" "$LORA_SHA256"
mkdir -p "$(dirname "$WORKFLOW_PATH")" "$SHARED_COMFY_DIR/input" "$SHARED_COMFY_DIR/output"
[ -e "$WORKFLOW_PATH" ] || { cp -- "$MODEL_DIR/workflows/$WORKFLOW_FILE" "${WORKFLOW_PATH}.tmp"; mv -f -- "${WORKFLOW_PATH}.tmp" "$WORKFLOW_PATH"; }
log "既存 Lightning workflow を保持: $WORKFLOW_PATH"
# Dedicated pose-transfer path. Does not load the 4-step Lightning LoRA.
bash "$MODEL_DIR/setup_vnccs.sh"
bash "$MODEL_DIR/setup_vnccs_gui.sh"
RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
cat <<EOF2

============================================================
 SETUP COMPLETE: $MODEL_NAME
============================================================
ComfyUI     : http://127.0.0.1:$COMFY_PORT
Lightning   : $WORKFLOW_PATH
VNCCS LoRA  : $SHARED_COMFY_DIR/models/loras/VNCCS_QI2_PoseStudioV1.1.safetensors
Pose script : $MODEL_DIR/scripts/run_pose_transfer.py
Pose API wf : $MODEL_DIR/workflows/Qwen-Image-2.1-VNCCS-PoseTransfer-API.json

Pose transfer (existing 3D mannequin render):
  $PYTHON $MODEL_DIR/scripts/run_pose_transfer.py \
    --char /workspace/ComfyUI/input/character.png \
    --pose-ref /workspace/ComfyUI/input/mannequin.png \
    --out /workspace/ComfyUI/output/pose_result.png

Lightning uses 4 steps separately. VNCCS uses 25 steps, Euler/simple.
============================================================
EOF2
