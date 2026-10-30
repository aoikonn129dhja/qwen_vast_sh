#!/usr/bin/env bash
# Install the node packs used by the author's VNCCS PoseStudio GUI workflow.
set -Eeuo pipefail
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
expected_root="${RUNTIME_ROOT:-${WORKSPACE:-/workspace}/.qwen_runtime}"
if [[ "${COMFY_DIR:-}" != "$expected_root/instances/qwen-image-2.1-int8-lightning/ComfyUI" ||
      "${PYTHON:-}" != "$expected_root/environments/qwen-image-2.1-int8-lightning/bin/python" ]]; then
    runtime_prepare qwen-image-2.1-int8-lightning
fi
[[ -f "$COMFY_DIR/main.py" && -x "$PYTHON" ]] || {
    echo 'ERROR: Set up the Qwen Image 2.1 runtime first.' >&2
    exit 1
}
runtime_clone_node https://github.com/AHEKOT/ComfyUI_VNCCS_Utils.git \
    334eee549fba5025b97c4e0a6123b2b68a46f0fc "$COMFY_DIR/custom_nodes/ComfyUI_VNCCS_Utils"
runtime_clone_node https://github.com/rgthree/rgthree-comfy.git \
    bc48c6aaeca87bedbc14245d89f9bc6be37a630e "$COMFY_DIR/custom_nodes/rgthree-comfy"
# Keep the working CUDA/PyTorch stack while resolving optional node dependencies.
constraints="$(mktemp "$RUNTIME_ROOT/.vnccs-constraints.XXXXXXXX")"
trap 'rm -f -- "$constraints"' EXIT
"$PYTHON" - > "$constraints" <<'PY'
from importlib.metadata import PackageNotFoundError, version
for name in ('torch', 'torchvision', 'torchaudio'):
    try:
        print(f'{name}=={version(name)}')
    except PackageNotFoundError:
        pass
PY
"$PYTHON" -m pip install -c "$constraints" \
    -r "$COMFY_DIR/custom_nodes/ComfyUI_VNCCS_Utils/requirements.txt"
echo 'VNCCS GUI node packs installed. Restart this ComfyUI backend to load them.'
