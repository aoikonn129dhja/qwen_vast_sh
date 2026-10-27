#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

PROGRESS_PID=""
CURRENT_STEP="1"
CURRENT_LABEL="GPU and disk"
stop_progress() {
    if [ -n "$PROGRESS_PID" ]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
}
finish_setup() {
    local result=$?
    stop_progress
    if [ "$result" -ne 0 ]; then
        printf '[%s/10] FAILED %s (exit %s)\n' "$CURRENT_STEP" "$CURRENT_LABEL" "$result" >&2
    fi
}
trap finish_setup EXIT
run_step() {
    local step="$1" label="$2" started="$SECONDS"
    shift 2
    CURRENT_STEP="$step"
    CURRENT_LABEL="$label"
    printf '[%s/10] START %s\n' "$step" "$label"
    (
        if [ -n "${RUNTIME_SETUP_LOCK:-}" ]; then exec {RUNTIME_SETUP_LOCK}>&-; fi
        while sleep 5; do
            printf '[%s/10] RUNNING %s (elapsed %ss)\n' "$step" "$label" "$((SECONDS - started))"
        done
    ) &
    PROGRESS_PID=$!
    "$@"
    stop_progress
    printf '[%s/10] DONE %s (elapsed %ss)\n' "$step" "$label" "$((SECONDS - started))"
}

# Standard library only: check the host before cloning or installing packages.
PREFLIGHT_PYTHON="${BASE_PYTHON:-/venv/main/bin/python}"
if [ ! -x "$PREFLIGHT_PYTHON" ]; then
    PREFLIGHT_PYTHON="$(command -v python3 || true)"
fi
[ -n "$PREFLIGHT_PYTHON" ] || { echo 'Python is required' >&2; exit 1; }
printf '[1/10] START GPU and disk\n'
nvidia-smi || true
df -h "${WORKSPACE:-/workspace}" || true
printf '[1/10] DONE GPU and disk\n'
run_step 2 'Hugging Face speed check' "$PREFLIGHT_PYTHON" "$MODEL_DIR/preflight.py" \
    --url "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$DIFFUSION_REL" \
    --shared-dir "${WORKSPACE:-/workspace}/ComfyUI" \
    --file "diffusion_models/${DIFFUSION_REL##*/}" "$DIFFUSION_BYTES" \
    --file "text_encoders/${TEXT_ENCODER_REL##*/}" "$TEXT_ENCODER_BYTES" \
    --file "vae/${VAE_REL##*/}" "$VAE_BYTES"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
run_step 3 'Workspace lock and dedicated Python environment' runtime_prepare "$MODEL_ID"
UV="${UV:-${WORKSPACE}/bin/uv}"
if [ ! -x "$UV" ]; then UV="$(command -v uv || true)"; fi
[ -n "$UV" ] && [ -x "$UV" ] || { echo 'uv is required' >&2; exit 1; }

run_step 4 'ComfyUI code and shared data paths' runtime_clone_comfy "$MODEL_DIR/runtime.json"
run_step 5 'ComfyUI Python dependencies' "$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"
run_step 6 'Hugging Face download dependencies' "$UV" pip install --python "$PYTHON" 'huggingface_hub>=0.34,<2'
mkdir -p "$SHARED_COMFY_DIR/models/diffusion_models" "$SHARED_COMFY_DIR/models/text_encoders" "$SHARED_COMFY_DIR/models/vae"
CURRENT_STEP="7-9"
CURRENT_LABEL="Model assets (see individual file progress)"
"$PYTHON" "$MODEL_DIR/download_models.py" \
    --repo "$HF_REPO" --revision "$HF_REVISION" --shared-repo "$SHARED_HF_REPO" --shared-revision "$SHARED_HF_REVISION" \
    --shared-dir "$SHARED_COMFY_DIR" \
    --file "$DIFFUSION_REL" diffusion_models "$DIFFUSION_BYTES" "$DIFFUSION_SHA256" \
    --file "$TEXT_ENCODER_REL" text_encoders "$TEXT_ENCODER_BYTES" "$TEXT_ENCODER_SHA256" \
    --file "$VAE_REL" vae "$VAE_BYTES" "$VAE_SHA256"

start_services() {
    RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
    runtime_start "$RUNTIME_PORT"
    runtime_register "$MODEL_DIR/runtime.json" >/dev/null
    runtime_gateway_start
}
run_step 10 'ComfyUI startup, workflow registration and Gateway' start_services
printf '[10/10] SETUP COMPLETE: http://127.0.0.1:8188\nWorkflow: %s\n' \
    "$SHARED_COMFY_DIR/user/default/workflows/Wan-2.2-TI2V-5B-Turbo.json"
