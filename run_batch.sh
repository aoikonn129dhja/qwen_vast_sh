#!/usr/bin/env bash
set -Eeuo pipefail

# Qwen / ComfyUI batch runner using official comfy-cli.
# Runs on the Vast.ai instance.
#
# Zero-argument usage after uploading files:
#   bash /workspace/qwen_comfy_sh/run_batch.sh
#
# Default input locations:
#   /workspace/qwen_batch/input/
#   /workspace/qwen_batch/prompts.json
#
# Output:
#   /workspace/qwen_batch/output/<RUN_ID>/
#
# Optional positional overrides:
#   bash run_batch.sh <input_dir> <prompts.json> [workflow.json]
#
# prompts.json format:
#   ["prompt 1", "prompt 2", "prompt 3"]
#
# Optional generation overrides:
#   DENOISE=0.9 STEPS=6 CFG=1 SAMPLER=er_sde SCHEDULER=beta \
#   WIDTH=1536 HEIGHT=2048 SEED=123 bash run_batch.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
BATCH_ROOT="${BATCH_ROOT:-/workspace/qwen_batch}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY="${COMFY_CLI:-/venv/main/bin/comfy}"
DEFAULT_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"

INPUT_RAW="${1:-$BATCH_ROOT/input}"
PROMPTS_RAW="${2:-$BATCH_ROOT/prompts.json}"
WORKFLOW_RAW="${3:-$DEFAULT_WORKFLOW}"

[ -d "$INPUT_RAW" ] || { echo "ERROR: input directory not found: $INPUT_RAW" >&2; exit 1; }
[ -f "$PROMPTS_RAW" ] || { echo "ERROR: prompts.json not found: $PROMPTS_RAW" >&2; exit 1; }
[ -f "$WORKFLOW_RAW" ] || { echo "ERROR: workflow not found: $WORKFLOW_RAW" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "ERROR: Python not found: $PYTHON" >&2; exit 1; }
[ -x "$COMFY" ] || { echo "ERROR: comfy-cli not found: $COMFY" >&2; exit 1; }

INPUT_DIR="$(realpath "$INPUT_RAW")"
PROMPTS_JSON="$(realpath "$PROMPTS_RAW")"
WORKFLOW="$(realpath "$WORKFLOW_RAW")"

"$PYTHON" - <<'PY'
import urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:8188/", timeout=3).read(1)
except Exception as e:
    raise SystemExit(f"ERROR: ComfyUI is not responding at 127.0.0.1:8188: {e}")
PY

RUN_ID="$(date '+%Y%m%d_%H%M%S')"

STAGE_REL="batch/$RUN_ID"
STAGE_DIR="$COMFY_DIR/input/$STAGE_REL"
TMP_DIR="$BATCH_ROOT/tmp/$RUN_ID"

# ComfyUIのSaveImageはいったんComfyUI/outputへ保存する。
# 各ジョブ完了後、/workspace/qwen_batch/output/<RUN_ID>/ へ即時移動する。
COMFY_OUTPUT_DIR="$COMFY_DIR/output/batch/$RUN_ID"
OUTPUT_DIR="$BATCH_ROOT/output/$RUN_ID"

mkdir -p \
    "$STAGE_DIR" \
    "$TMP_DIR" \
    "$COMFY_OUTPUT_DIR" \
    "$OUTPUT_DIR"

flush_outputs() {
    [ -d "$COMFY_OUTPUT_DIR" ] || return 0

    while IFS= read -r -d '' file; do
        mv -f -- "$file" "$OUTPUT_DIR/"
    done < <(find "$COMFY_OUTPUT_DIR" -maxdepth 1 -type f -print0)
}

cleanup() {
    flush_outputs || true
    rmdir "$COMFY_OUTPUT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mapfile -d '' IMAGES < <(
    find "$INPUT_DIR" -maxdepth 1 -type f \
      \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
      -print0 | sort -z
)

if [ "${#IMAGES[@]}" -eq 0 ]; then
    echo "ERROR: no input images found in: $INPUT_DIR" >&2
    exit 1
fi

mapfile -t PROMPTS_B64 < <("$PYTHON" - "$PROMPTS_JSON" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, list) or not data or not all(isinstance(x, str) and x.strip() for x in data):
    raise SystemExit("ERROR: prompts.json must be a non-empty JSON array of non-empty strings")
for s in data:
    print(base64.b64encode(s.encode("utf-8")).decode("ascii"))
PY
)

TOTAL=$(( ${#IMAGES[@]} * ${#PROMPTS_B64[@]} ))

echo "============================================================"
echo " QWEN BATCH"
echo "============================================================"
echo "Run ID   : $RUN_ID"
echo "Images   : ${#IMAGES[@]}"
echo "Prompts  : ${#PROMPTS_B64[@]}"
echo "Total    : $TOTAL"
echo "Workflow : $WORKFLOW"
echo "Output   : $OUTPUT_DIR"
echo "============================================================"
echo

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

        prompt="$("$PYTHON" -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8"))' "$prompt_b64")"

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

        "$COMFY" --no-json --where local workflow set-slot \
            "$WORKFLOW" "${overrides[@]}" --stdout > "$tmp_workflow"

        "$COMFY" --where local run \
            --workflow "$tmp_workflow" \
            --wait \
            --timeout 3600

        flush_outputs
    done
done

echo
echo "============================================================"
echo " COMPLETE"
echo "============================================================"
echo "Run ID : $RUN_ID"
echo "Output : $OUTPUT_DIR"
echo "Jobs   : $JOB/$TOTAL"
echo "============================================================"
