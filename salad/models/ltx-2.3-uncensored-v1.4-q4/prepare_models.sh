#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/profile/model.conf
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
PYTHON="${PYTHON:-/opt/venv/bin/python}"
"$PYTHON" /opt/salad/model/prepare_ltx.py "$COMFY_DIR" "$HF_REPO" "$HF_REVISION" \
    "$TRANSFORMER_REL" "models/diffusion_models/$TRANSFORMER_FILE" \
    "$TEXT_ENCODER_REL" "models/text_encoders/$TEXT_ENCODER_FILE" \
    "$PROJECTIONS_REL" "models/text_encoders/$PROJECTIONS_FILE" \
    "$VIDEO_VAE_REL" "models/vae/$VIDEO_VAE_FILE" \
    "$AUDIO_VAE_REL" "models/vae/$AUDIO_VAE_FILE"

source /opt/salad/common/download_verified.sh
download_resume_verified "$UPSCALER_URL" "$COMFY_DIR/models/latent_upscale_models/$UPSCALER_FILE" "$UPSCALER_SHA256"
