#!/usr/bin/env bash
set -Eeuo pipefail
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$MODEL_DIR/model.conf"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
UV="${UV:-$(command -v uv || true)}"
[ -x "$PYTHON" ] || { echo 'Python environment missing' >&2; exit 1; }
[ -n "$UV" ] && [ -x "$UV" ] || { echo 'uv is required' >&2; exit 1; }
if [ ! -f "$COMFY_DIR/main.py" ]; then
  [ ! -e "$COMFY_DIR" ] || { echo 'Incomplete ComfyUI directory' >&2; exit 1; }
  git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi
"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"
"$UV" pip install --python "$PYTHON" 'huggingface_hub[cli]>=0.34,<2'
mkdir -p "$COMFY_DIR/models/diffusion_models" "$COMFY_DIR/models/text_encoders" "$COMFY_DIR/models/vae" "$MODEL_DIR/workflows"
"$PYTHON" - "$HF_REPO" "$COMFY_DIR" "$DIFFUSION_REL" "$TEXT_ENCODER_REL" "$VAE_REL" <<'PY'
import os, sys
from huggingface_hub import hf_hub_download
repo, comfy, *files = sys.argv[1:]
for source, folder in zip(files, ('diffusion_models','text_encoders','vae')):
    dest = os.path.join(comfy,'models',folder)
    output = os.path.join(dest, os.path.basename(source))
    if os.path.getsize(output) > 0 if os.path.isfile(output) else False:
        print('Present:',output,flush=True); continue
    cached = hf_hub_download(repo_id=repo,filename=source)
    tmp=output+'.part'
    import shutil
    shutil.copyfile(cached,tmp)
    os.replace(tmp,output)
    print('Downloaded:',output,flush=True)
PY
curl -fL --retry 3 --output "$MODEL_DIR/workflows/official.json.part" "$WORKFLOW_URL"
mv "$MODEL_DIR/workflows/official.json.part" "$MODEL_DIR/workflows/official.json"
if [ -s "$WORKSPACE/comfyui.pid" ]; then
  read -r old_pid < "$WORKSPACE/comfyui.pid"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo 'ComfyUI is already running; restart it before using the new model.' >&2
    exit 1
  fi
fi
cd "$COMFY_DIR"
nohup "$PYTHON" main.py --listen 127.0.0.1 --port "${COMFY_PORT:-8188}" > "$WORKSPACE/comfyui.log" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" > "$WORKSPACE/comfyui.pid"
for _ in $(seq 1 90); do
  kill -0 "$pid" 2>/dev/null || { tail -80 "$WORKSPACE/comfyui.log" >&2; exit 1; }
  curl -fsS "http://127.0.0.1:${COMFY_PORT:-8188}/system_stats" >/dev/null 2>&1 && { echo 'ComfyUI ready'; exit 0; }
  sleep 2
done
echo 'ComfyUI readiness timeout' >&2
exit 1
