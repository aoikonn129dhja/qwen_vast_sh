#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/setup_base.sh
source /opt/salad/common/download_verified.sh
source /opt/salad/model/assets.sh
/opt/venv/bin/comfy set-default "$COMFY_DIR"
download_verified "$QWEN_NODE_URL" "$COMFY_DIR/comfy_extras/nodes_qwen.py" "$QWEN_NODE_SHA256"
cp /opt/profile/workflows/batch-save-image.json "$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-NSFW-v19-Batch.json"
