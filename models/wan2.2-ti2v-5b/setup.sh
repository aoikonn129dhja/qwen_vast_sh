#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "$MODEL_ID"
UV="${UV:-$(command -v uv || true)}"
[ -n "$UV" ] && [ -x "$UV" ] || { echo 'uv is required' >&2; exit 1; }

"$PYTHON" "$REPO_ROOT/scripts/runtime/network_preflight.py" \
    --file "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$DIFFUSION_REL" \
      "$SHARED_COMFY_DIR/models/diffusion_models/${DIFFUSION_REL##*/}" "$DIFFUSION_SHA256" \
    --file "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$TEXT_ENCODER_REL" \
      "$SHARED_COMFY_DIR/models/text_encoders/${TEXT_ENCODER_REL##*/}" "$TEXT_ENCODER_SHA256" \
    --file "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$VAE_REL" \
      "$SHARED_COMFY_DIR/models/vae/${VAE_REL##*/}" "$VAE_SHA256"

runtime_clone_comfy "$MODEL_DIR/runtime.json"
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"
mkdir -p "$SHARED_COMFY_DIR/models/diffusion_models" "$SHARED_COMFY_DIR/models/text_encoders" "$SHARED_COMFY_DIR/models/vae"
for entry in \
  "$DIFFUSION_REL|diffusion_models|$DIFFUSION_SHA256" \
  "$TEXT_ENCODER_REL|text_encoders|$TEXT_ENCODER_SHA256" \
  "$VAE_REL|vae|$VAE_SHA256"; do
    IFS='|' read -r relative folder expected <<< "$entry"
    "$PYTHON" "$REPO_ROOT/scripts/runtime/model_files.py" \
      "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$relative" \
      "$SHARED_COMFY_DIR/models/$folder/${relative##*/}" "$expected"
done

WORKFLOW_PATH="$SHARED_COMFY_DIR/user/default/workflows/Wan-2.2-TI2V-5B.json"
if [ ! -e "$WORKFLOW_PATH" ]; then
    mkdir -p "$(dirname -- "$WORKFLOW_PATH")"
    curl -fL --retry 3 --output "$WORKFLOW_PATH.part" "$WORKFLOW_URL"
    mv -- "$WORKFLOW_PATH.part" "$WORKFLOW_PATH"
fi

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
printf 'ComfyUI Gateway ready: http://127.0.0.1:8188\nWorkflow: %s\n' "$WORKFLOW_PATH"
