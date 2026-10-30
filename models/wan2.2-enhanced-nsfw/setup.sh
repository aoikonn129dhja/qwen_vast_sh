#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$MODEL_DIR/model.conf"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "$MODEL_ID"
UV="${UV:-$(command -v uv || true)}"
[ -n "$UV" ] && [ -x "$UV" ] || { printf 'ERROR: uv is required\n' >&2; exit 1; }
command -v wget >/dev/null 2>&1 || { printf 'ERROR: wget is required\n' >&2; exit 1; }

printf 'GPU and available disk:\n'
nvidia-smi
df -h "$WORKSPACE"
"$PYTHON" "$REPO_ROOT/scripts/runtime/network_preflight.py" \
  --file "https://huggingface.co/$WAN_REPO/resolve/$WAN_REVISION/$HIGH_FILE" \
    "$SHARED_COMFY_DIR/models/diffusion_models/$HIGH_FILE" "$HIGH_SHA256" \
  --file "https://huggingface.co/$WAN_REPO/resolve/$WAN_REVISION/$LOW_FILE" \
    "$SHARED_COMFY_DIR/models/diffusion_models/$LOW_FILE" "$LOW_SHA256" \
  --file "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/$TEXT_REVISION/split_files/text_encoders/$TEXT_FILE" \
    "$SHARED_COMFY_DIR/models/text_encoders/$TEXT_FILE" "$TEXT_SHA256" \
  --file "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/$VAE_REVISION/split_files/vae/$VAE_FILE" \
    "$SHARED_COMFY_DIR/models/vae/$VAE_FILE" "$VAE_SHA256" \
  --file "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/$RIFE_REVISION/frame_interpolation/$RIFE_FILE" \
    "$SHARED_COMFY_DIR/models/frame_interpolation/$RIFE_FILE" "$RIFE_SHA256"
runtime_clone_comfy "$MODEL_DIR/runtime.json"
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"


fetch_asset() {
    local url="$1" folder="$2" name="$3" expected="$4"
    "$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" \
        "$url" "$SHARED_COMFY_DIR/models/$folder/$name" "$expected"
}

fetch_asset "https://huggingface.co/$WAN_REPO/resolve/$WAN_REVISION/$HIGH_FILE" \
    diffusion_models "$HIGH_FILE" "$HIGH_SHA256"
fetch_asset "https://huggingface.co/$WAN_REPO/resolve/$WAN_REVISION/$LOW_FILE" \
    diffusion_models "$LOW_FILE" "$LOW_SHA256"
fetch_asset "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/$TEXT_REVISION/split_files/text_encoders/$TEXT_FILE" \
    text_encoders "$TEXT_FILE" "$TEXT_SHA256"
fetch_asset "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/$VAE_REVISION/split_files/vae/$VAE_FILE" \
    vae "$VAE_FILE" "$VAE_SHA256"
fetch_asset "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/$RIFE_REVISION/frame_interpolation/$RIFE_FILE" \
    frame_interpolation "$RIFE_FILE" "$RIFE_SHA256"

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
printf 'SETUP COMPLETE: %s\n' "$MODEL_NAME"
