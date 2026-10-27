#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

# Standard library only: check the host before cloning or installing packages.
PREFLIGHT_PYTHON="${BASE_PYTHON:-/venv/main/bin/python}"
if [ ! -x "$PREFLIGHT_PYTHON" ]; then
    PREFLIGHT_PYTHON="$(command -v python3 || true)"
fi
[ -n "$PREFLIGHT_PYTHON" ] || { echo 'Python is required' >&2; exit 1; }
printf '[1/5] GPU and disk\n'
nvidia-smi || true
df -h "${WORKSPACE:-/workspace}" || true
"$PREFLIGHT_PYTHON" "$MODEL_DIR/preflight.py" \
    --url "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$DIFFUSION_REL" \
    --shared-dir "${WORKSPACE:-/workspace}/ComfyUI" \
    --file "diffusion_models/${DIFFUSION_REL##*/}" "$DIFFUSION_BYTES" \
    --file "text_encoders/${TEXT_ENCODER_REL##*/}" "$TEXT_ENCODER_BYTES" \
    --file "vae/${VAE_REL##*/}" "$VAE_BYTES"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "$MODEL_ID"
UV="${UV:-${WORKSPACE}/bin/uv}"
if [ ! -x "$UV" ]; then UV="$(command -v uv || true)"; fi
[ -n "$UV" ] && [ -x "$UV" ] || { echo 'uv is required' >&2; exit 1; }

printf '[3/5] Dedicated ComfyUI and Python dependencies\n'
runtime_clone_comfy "$MODEL_DIR/runtime.json"
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"
"$UV" pip install --python "$PYTHON" 'huggingface_hub[cli]>=0.34,<2'
mkdir -p "$SHARED_COMFY_DIR/models/diffusion_models" "$SHARED_COMFY_DIR/models/text_encoders" "$SHARED_COMFY_DIR/models/vae"
printf '[4/5] Download missing models\n'
"$PYTHON" - "$HF_REPO" "$HF_REVISION" "$SHARED_HF_REPO" "$SHARED_COMFY_DIR" "$DIFFUSION_REL" "$TEXT_ENCODER_REL" "$VAE_REL" "$DIFFUSION_BYTES" "$TEXT_ENCODER_BYTES" "$VAE_BYTES" <<'PY'
import os
import shutil
import sys
from huggingface_hub import hf_hub_download

repo, revision, shared_repo, comfy = sys.argv[1:5]
files = sys.argv[5:8]
sizes = map(int, sys.argv[8:11])
for source, folder, source_repo, source_revision, size in zip(
    files,
    ('diffusion_models', 'text_encoders', 'vae'),
    (repo, shared_repo, shared_repo),
    (revision, 'main', 'main'),
    sizes,
):
    dest = os.path.join(comfy, 'models', folder)
    output = os.path.join(dest, os.path.basename(source))
    os.makedirs(dest, exist_ok=True)
    if os.path.isfile(output) and os.path.getsize(output) == size:
        print('Present:', output, flush=True)
        continue
    cached = hf_hub_download(repo_id=source_repo, filename=source, revision=source_revision)
    if os.path.getsize(cached) != size:
        raise SystemExit(f'Download size mismatch: {source}')
    tmp = output + f'.part.{os.getpid()}'
    shutil.copyfile(cached, tmp)
    os.replace(tmp, output)
    print('Downloaded:', output, flush=True)
PY

printf '[5/5] Start dedicated ComfyUI and Gateway\n'
RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
runtime_start "$RUNTIME_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
printf 'ComfyUI Gateway ready: http://127.0.0.1:8188\nWorkflow: %s\n' \
    "$SHARED_COMFY_DIR/user/default/workflows/Wan-2.2-TI2V-5B-Turbo.json"
