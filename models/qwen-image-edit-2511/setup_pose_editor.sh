#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare qwen-image-edit-2511
[ -f "$COMFY_DIR/main.py" ] || runtime_die 'Run the 2511 setup first.'
runtime_clone_node https://github.com/Fannovel16/comfyui_controlnet_aux.git \
    a587a4c1594524c1d2de5cd1a86cd868ff448e1c "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux"
runtime_clone_node https://github.com/andreszs/comfyui-openpose-studio.git \
    2075fbe59b88c31fc16d602ca1ff66f81abd9e43 "$COMFY_DIR/custom_nodes/comfyui-openpose-studio"
"$WORKSPACE/bin/uv" pip install --python "$PYTHON" \
    -r "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux/requirements.txt"
mkdir -p "$COMFY_DIR/custom_nodes/ComfyUI-QwenPoseStages"
cp "$MODEL_DIR/custom_nodes/ComfyUI-QwenPoseStages/__init__.py" \
    "$COMFY_DIR/custom_nodes/ComfyUI-QwenPoseStages/__init__.py"
WORKFLOW_NAME=2511-pose-estimate-edit.json
mkdir -p "$SHARED_COMFY_DIR/user/default/workflows"
if [ ! -e "$SHARED_COMFY_DIR/user/default/workflows/$WORKFLOW_NAME" ]; then
    cp "$MODEL_DIR/workflows/$WORKFLOW_NAME" "$SHARED_COMFY_DIR/user/default/workflows/$WORKFLOW_NAME"
fi
printf '%s\n' 'Pose editor installed. Restart only the 2511 backend when its queue is idle.'
