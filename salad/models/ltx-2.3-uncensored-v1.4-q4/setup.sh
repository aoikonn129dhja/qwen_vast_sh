#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/setup_base.sh
source /opt/profile/model.conf
clone_pinned "$GGUF_LOADER_REPO" "$COMFY_DIR/custom_nodes/ComfyUI-GGUF-Loader" 142c614fe6852f18a513742cc098fd13d72320a9
uv pip install --python "$PYTHON" -r "$COMFY_DIR/custom_nodes/ComfyUI-GGUF-Loader/requirements.txt"
uv pip install --python "$PYTHON" opencv-python-headless
cp /opt/profile/*.json "$COMFY_DIR/user/default/workflows/"
