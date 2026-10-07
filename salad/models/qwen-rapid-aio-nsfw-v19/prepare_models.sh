#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/download_verified.sh
source /opt/salad/model/assets.sh
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
download_resume_verified "$MODEL_URL" "$COMFY_DIR/models/checkpoints/$MODEL_FILE" "$MODEL_SHA256"
