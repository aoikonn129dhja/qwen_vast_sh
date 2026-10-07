#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/download_verified.sh
source /opt/salad/common/qwen_edit_assets.sh
source /opt/profile/model.conf
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
download_resume_verified "$DIFFUSION_URL" "$COMFY_DIR/models/diffusion_models/$DIFFUSION_FILE" "$DIFFUSION_SHA256"
download_resume_verified "$TEXT_ENCODER_URL" "$COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_SHA256"
download_resume_verified "$VAE_URL" "$COMFY_DIR/models/vae/$VAE_FILE" "$VAE_SHA256"
download_resume_verified "$LORA_URL" "$COMFY_DIR/models/loras/$LORA_FILE" "$LORA_SHA256"
if [ "$QWEN_EDIT_VERSION" = 2511 ]; then
    download_resume_verified "$MULTI_ANGLE_LORA_URL" "$COMFY_DIR/models/loras/$MULTI_ANGLE_LORA_FILE" "$MULTI_ANGLE_LORA_SHA256"
    download_resume_verified "$NSFW_LORA_URL" "$COMFY_DIR/models/loras/$NSFW_LORA_FILE" "$NSFW_LORA_SHA256"
fi
