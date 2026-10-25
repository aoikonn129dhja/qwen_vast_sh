#!/usr/bin/env bash
set -Eeuo pipefail

# Called by local_tools/qwen_v23_batch.py after uploading one prompt and images.
V23_BATCH_PROTOCOL=2
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/.qwen_runtime}"
RUNTIME_INSTANCE="$RUNTIME_ROOT/instances/qwen-rapid-aio-nsfw-v23"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
BATCH_ROOT="${BATCH_ROOT:-/workspace/qwen_batch}"
PYTHON="${PYTHON:-$RUNTIME_ROOT/environments/qwen-rapid-aio-nsfw-v23/bin/python}"
COMFY="${COMFY_CLI:-$RUNTIME_ROOT/environments/qwen-rapid-aio-nsfw-v23/bin/comfy}"
WORKFLOW="$MODEL_DIR/workflows/v23-NSFW-アスペクト比維持or指定_1メガ縮小-名前保持.json"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: bash run_batch.sh <stage_dir> keep|custom [width:height]" >&2
    exit 2
fi
STAGE_DIR="$1"
ASPECT_MODE="$2"
RATIO_WIDTH=""
RATIO_HEIGHT=""
case "$ASPECT_MODE" in
    keep)
        [ "$#" -eq 2 ] || { echo "ERROR: keep mode takes no ratio" >&2; exit 2; }
        ;;
    custom)
        [ "$#" -eq 3 ] && [[ "$3" =~ ^([1-9][0-9]{0,4}):([1-9][0-9]{0,4})$ ]] \
            || { echo "ERROR: ratio must be width:height, such as 3:4" >&2; exit 2; }
        RATIO_WIDTH="${BASH_REMATCH[1]}"
        RATIO_HEIGHT="${BASH_REMATCH[2]}"
        ;;
    *) echo "ERROR: aspect mode must be keep or custom" >&2; exit 2 ;;
esac
case "$STAGE_DIR" in
    "$COMFY_DIR"/input/v23_batch/*) ;;
    *) echo "ERROR: unexpected input directory: $STAGE_DIR" >&2; exit 2 ;;
esac
RUN_ID="${STAGE_DIR##*/}"
if [[ ! "$RUN_ID" =~ ^[a-f0-9]{32}$ ]]; then
    echo "ERROR: invalid run ID" >&2
    exit 2
fi

TMP_DIR=""
cleanup() {
    if [ -n "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi
    # Only the exact upload directory validated above is removed.
    rm -rf -- "$STAGE_DIR"
}
trap cleanup EXIT

[ -d "$STAGE_DIR/images" ] || { echo "ERROR: uploaded images not found" >&2; exit 1; }
[ -s "$STAGE_DIR/prompt.txt" ] || { echo "ERROR: prompt not found" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "ERROR: workflow not found" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "ERROR: V23 Python not found; run setup.sh" >&2; exit 1; }
[ -x "$COMFY" ] || { echo "ERROR: comfy-cli not found; run setup.sh" >&2; exit 1; }

mapfile -d '' IMAGES < <(
    find "$STAGE_DIR/images" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
        -print0 | sort -z
)
[ "${#IMAGES[@]}" -gt 0 ] || { echo "ERROR: no supported images" >&2; exit 1; }

mkdir -p "$BATCH_ROOT/tmp"
TMP_DIR="$(mktemp -d "$BATCH_ROOT/tmp/v23.XXXXXXXX")"

export HOME="$RUNTIME_INSTANCE"
export XDG_CONFIG_HOME="$RUNTIME_INSTANCE/.config"
export COMFY_LOCAL_URL="http://127.0.0.1:8188"
source "$MODEL_DIR/../../scripts/runtime/bootstrap.sh"
runtime_gateway_start
"$PYTHON" - <<'PY'
import json
import urllib.request

request = urllib.request.Request(
    "http://127.0.0.1:8188/runtime/select",
    data=json.dumps({"model_id": "qwen-rapid-aio-nsfw-v23"}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=240) as response:
    json.load(response)
PY

PROMPT="$(cat "$STAGE_DIR/prompt.txt")"
PROMPT_JSON="$("$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$PROMPT")"
echo "Images: ${#IMAGES[@]}"
if [ "$ASPECT_MODE" = "keep" ]; then
    echo "Output aspect: keep each input image's ratio (about 1 megapixel)"
else
    echo "Output aspect: $RATIO_WIDTH:$RATIO_HEIGHT (about 1 megapixel)"
fi
echo "ComfyUI output: $COMFY_DIR/output"

index=0
for image in "${IMAGES[@]}"; do
    index=$((index + 1))
    name="${image##*/}"
    input_name="v23_batch/$RUN_ID/images/$name"
    job_workflow="$TMP_DIR/job_$(printf '%04d' "$index").json"
    image_json="$("$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$input_name")"
    echo "[$index/${#IMAGES[@]}] $name"
    overrides=("14.image=$image_json" "3.prompt=$PROMPT_JSON")
    if [ "$ASPECT_MODE" = "keep" ]; then
        overrides+=("19.switch=false")
    else
        overrides+=("19.switch=true" "17.width=$RATIO_WIDTH" "17.height=$RATIO_HEIGHT")
    fi
    "$COMFY" --no-json --where local workflow set-slot "$WORKFLOW" \
        "${overrides[@]}" --stdout > "$job_workflow"
    "$COMFY" --where local run --workflow "$job_workflow" --wait --timeout 3600
done

echo "Complete: ${#IMAGES[@]} images in $COMFY_DIR/output"
