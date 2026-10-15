#!/usr/bin/env bash
set -Eeuo pipefail
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$MODEL_DIR/model.conf"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "$MODEL_ID"
UV="${UV:-$(command -v uv || true)}"
[ -x "$PYTHON" ] && [ -n "$UV" ] || { echo 'Python and uv required' >&2; exit 1; }
"${BASE_PYTHON:-/venv/main/bin/python}" - <<'PY'
import torch
assert torch.cuda.is_available(), 'CUDA GPU required'
major, _ = torch.cuda.get_device_capability()
assert major >= 10, 'LightWan NVFP4 needs Blackwell GPU (RTX 50 series)'
PY
ENGINE="$RUNTIME_INSTANCE/LightX2V"
if [ ! -d "$ENGINE/.git" ]; then
  [ ! -e "$ENGINE" ] || { echo 'Invalid existing LightX2V directory' >&2; exit 1; }
  git clone --depth 1 "$LIGHTX2V_REPO" "$ENGINE"
fi
"$UV" pip install --python "$PYTHON" -e "$ENGINE" 'huggingface_hub[cli]>=0.34,<2'
"$UV" pip install --python "$PYTHON" 'aiohttp==3.14.3'
MODEL_PATH="$WORKSPACE/models/LightWan2.2-A14B"
mkdir -p "$MODEL_PATH"
"$PYTHON" - "$HF_REPO" "$MODEL_PATH" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])
PY
runtime_register_cli "$MODEL_DIR/runtime.json" "$ENGINE"
runtime_gateway_start
cat <<MSG
Model downloaded: $MODEL_PATH
LightWan requires NVIDIA NVFP4 kernels and Wan T5/VAE support assets.
Official runtime is the LightX2V Blackwell image: lightx2v/lightx2v:26052801-cu130-5090
Use scripts/runtime/cli_adapter.py to reserve VRAM before a LightX2V inference command.
This setup does not validate LightWan inference or provide a default run command.
MSG
