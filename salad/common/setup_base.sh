#!/usr/bin/env bash
set -Eeuo pipefail
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
PYTHON="${PYTHON:-/opt/venv/bin/python}"
COMFYUI_COMMIT=15eb748b3ec5f8a0a2d470b7fb280e2d7579f916
clone_pinned() {
    local repo="$1" destination="$2" commit="$3"
    git init -q "$destination"
    git -C "$destination" remote add origin "$repo"
    git -C "$destination" fetch -q --depth 1 origin "$commit"
    git -C "$destination" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ]
}
setup_base() {
    clone_pinned https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR" "$COMFYUI_COMMIT"
    uv pip install --python "$PYTHON" --require-hashes --torch-backend cu130 -r /opt/profile/requirements.lock
    mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/input" "$COMFY_DIR/output"
}
