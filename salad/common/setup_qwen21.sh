#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/setup_base.sh
clone_pinned https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR" c9d8a6e69c4b5ab7fa0f789e7b988c172cd31fc9
uv pip install --python "$PYTHON" --require-hashes --torch-backend cu130 -r /opt/profile/requirements.lock
uv pip install --python "$PYTHON" --torch-backend cu130 -r "$COMFY_DIR/requirements.txt"
if [ -f /opt/salad/model/gguf.enabled ]; then
    clone_pinned https://github.com/leejet/ComfyUI-GGUF.git "$COMFY_DIR/custom_nodes/ComfyUI-GGUF" 373048b8403a7820620065210a691263d4da0a61
    uv pip install --python "$PYTHON" -r "$COMFY_DIR/custom_nodes/ComfyUI-GGUF/requirements.txt"
fi
mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/input" "$COMFY_DIR/output"
cp /opt/salad/model/workflows/*.json "$COMFY_DIR/user/default/workflows/"
