#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "$MODEL_ID"
UV="${UV:-$(command -v uv || true)}"
[ -n "$UV" ] && [ -x "$UV" ] || { echo 'uv is required' >&2; exit 1; }

runtime_clone_comfy "$MODEL_DIR/runtime.json"
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"
"$UV" pip install --python "$PYTHON" 'huggingface_hub[cli]>=0.34,<2'
mkdir -p "$SHARED_COMFY_DIR/models/diffusion_models" "$SHARED_COMFY_DIR/models/text_encoders" "$SHARED_COMFY_DIR/models/vae"
"$PYTHON" - "$HF_REPO" "$HF_REVISION" "$SHARED_HF_REPO" "$SHARED_COMFY_DIR" "$DIFFUSION_REL" "$TEXT_ENCODER_REL" "$VAE_REL" <<'PY'
import os
import shutil
import sys
from huggingface_hub import hf_hub_download

repo, revision, shared_repo, comfy, *files = sys.argv[1:]
for source, folder, source_repo, source_revision in zip(
    files,
    ('diffusion_models', 'text_encoders', 'vae'),
    (repo, shared_repo, shared_repo),
    (revision, 'main', 'main'),
):
    dest = os.path.join(comfy, 'models', folder)
    output = os.path.join(dest, os.path.basename(source))
    os.makedirs(dest, exist_ok=True)
    if os.path.isfile(output) and os.path.getsize(output) > 0:
        print('Present:', output, flush=True)
        continue
    cached = hf_hub_download(repo_id=source_repo, filename=source, revision=source_revision)
    tmp = output + '.part'
    shutil.copyfile(cached, tmp)
    os.replace(tmp, output)
    print('Downloaded:', output, flush=True)
PY

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
printf 'ComfyUI Gateway ready: http://127.0.0.1:8188\nWorkflow: %s\n' \
    "$SHARED_COMFY_DIR/user/default/workflows/Wan-2.2-TI2V-5B-Turbo.json"
