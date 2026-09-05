#!/usr/bin/env bash
set -Eeuo pipefail

# Qwen / ComfyUI batch runner using official comfy-cli.
# Runs on the Vast.ai instance, not on Windows.
#
# Usage:
#   bash run_batch.sh <input_dir> <prompts.json> [workflow.json]
#
# prompts.json format:
#   ["prompt 1", "prompt 2", "prompt 3"]
#
# Optional environment overrides:
#   DENOISE=0.9
#   STEPS=4
#   CFG=1
#   SAMPLER=sa_solver
#   SCHEDULER=beta
#   WIDTH=1536
#   HEIGHT=2048
#   NEGATIVE_PROMPT="..."
#   SEED=65454653
#
# By default jobs run sequentially with --wait. This avoids queue/output
# bookkeeping while still keeping the GPU continuously fed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY="${COMFY_CLI:-/venv/main/bin/comfy}"
DEFAULT_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: bash run_batch.sh <input_dir> <prompts.json> [workflow.json]" >&2
    exit 2
fi

INPUT_DIR="$(realpath "$1")"
PROMPTS_JSON="$(realpath "$2")"
WORKFLOW="$(realpath "${3:-$DEFAULT_WORKFLOW}")"

[ -d "$INPUT_DIR" ] || { echo "Input directory not found: $INPUT_DIR" >&2; exit 1; }
[ -f "$PROMPTS_JSON" ] || { echo "Prompts JSON not found: $PROMPTS_JSON" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "Workflow not found: $WORKFLOW" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "Python not found: $PYTHON" >&2; exit 1; }
[ -x "$COMFY" ] || { echo "comfy-cli not found: $COMFY" >&2; exit 1; }

# Verify ComfyUI responds before touching inputs.
"$PYTHON" - <<'PY'
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8188/", timeout=3).read(1)
PY

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
STAGE_REL="batch/$RUN_ID"
STAGE_DIR="$COMFY_DIR/input/$STAGE_REL"
TMP_DIR="/workspace/qwen_batch_tmp/$RUN_ID"
mkdir -p "$STAGE_DIR" "$TMP_DIR"

# Collect supported images safely.
mapfile -d '' IMAGES < <(
    find "$INPUT_DIR" -maxdepth 1 -type f \
      \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
      -print0 | sort -z
)

if [ "${#IMAGES[@]}" -eq 0 ]; then
    echo "No input images found in: $INPUT_DIR" >&2
    exit 1
fi

# Read JSON string array as base64 lines so arbitrary UTF-8 / quotes are safe in bash.
mapfile -t PROMPTS_B64 < <("$PYTHON" - "$PROMPTS_JSON" <<'PY'
import base64, json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, list) or not data or not all(isinstance(x, str) for x in data):
    raise SystemExit("prompts.json must be a non-empty JSON array of strings")
for s in data:
    print(base64.b64encode(s.encode("utf-8")).decode("ascii"))
PY
)

TOTAL=$(( ${#IMAGES[@]} * ${#PROMPTS_B64[@]} ))
echo "Run ID : $RUN_ID"
echo "Images : ${#IMAGES[@]}"
echo "Prompts: ${#PROMPTS_B64[@]}"
echo "Jobs   : $TOTAL"
echo

# Copy all source images into ComfyUI/input under a unique run directory.
for src in "${IMAGES[@]}"; do
    cp -f -- "$src" "$STAGE_DIR/$(basename "$src")"
done

json_string() {
    "$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

JOB=0
for src in "${IMAGES[@]}"; do
    filename="$(basename "$src")"
    stem="${filename%.*}"
    image_value="$STAGE_REL/$filename"

    pidx=0
    for prompt_b64 in "${PROMPTS_B64[@]}"; do
        pidx=$((pidx + 1))
        JOB=$((JOB + 1))
        prompt="$($PYTHON -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8"))' "$prompt_b64")"

        prefix="batch/$RUN_ID/${stem}_p$(printf '%03d' "$pidx")"
        tmp_workflow="$TMP_DIR/job_$(printf '%05d' "$JOB").json"

        overrides=(
            "8.image=$(json_string "$image_value")"
            "3.prompt=$(json_string "$prompt")"
            "10.filename_prefix=$(json_string "$prefix")"
        )

        if [ -n "${NEGATIVE_PROMPT:-}" ]; then
            overrides+=("4.prompt=$(json_string "$NEGATIVE_PROMPT")")
        fi
        [ -n "${SEED:-}" ]      && overrides+=("2.seed=$SEED")
        [ -n "${STEPS:-}" ]     && overrides+=("2.steps=$STEPS")
        [ -n "${CFG:-}" ]       && overrides+=("2.cfg=$CFG")
        [ -n "${SAMPLER:-}" ]   && overrides+=("2.sampler_name=$(json_string "$SAMPLER")")
        [ -n "${SCHEDULER:-}" ] && overrides+=("2.scheduler=$(json_string "$SCHEDULER")")
        [ -n "${DENOISE:-}" ]   && overrides+=("2.denoise=$DENOISE")
        [ -n "${WIDTH:-}" ]     && overrides+=("9.width=$WIDTH")
        [ -n "${HEIGHT:-}" ]    && overrides+=("9.height=$HEIGHT")

        echo "[$JOB/$TOTAL] $filename × prompt $pidx"

        "$COMFY" workflow set-slot "$WORKFLOW" "${overrides[@]}" --stdout > "$tmp_workflow"
        "$COMFY" run --workflow "$tmp_workflow" --where local --wait --timeout 3600
    done
done

echo
echo "Complete."
echo "Remote outputs: $COMFY_DIR/output/batch/$RUN_ID/"
echo "Run ID: $RUN_ID"
