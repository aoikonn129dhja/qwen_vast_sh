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
#
# Optional preview config:
#   PREVIEW_PORT=8765 bash run_batch.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
BATCH_ROOT="${BATCH_ROOT:-/workspace/qwen_batch}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY="${COMFY_CLI:-/venv/main/bin/comfy}"
DEFAULT_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"
PREVIEW_ROOT="${PREVIEW_ROOT:-/workspace/qwen_preview}"
PREVIEW_PORT="${PREVIEW_PORT:-8765}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/workspace/bin/cloudflared}"

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
COMFY_OUTPUT_DIR="$COMFY_DIR/output/batch/$RUN_ID"
OUTPUT_DIR="$BATCH_ROOT/output/$RUN_ID"

PREVIEW_DIR="$PREVIEW_ROOT/$RUN_ID"
PREVIEW_SERVER="$PREVIEW_DIR/qwen_preview_server.py"
PREVIEW_STATE="$PREVIEW_DIR/state.json"
PREVIEW_LOG="$PREVIEW_DIR/http.log"
PREVIEW_TUNNEL_LOG="$PREVIEW_DIR/tunnel.log"
PREVIEW_INDEX="$PREVIEW_DIR/index.html"

mkdir -p \
    "$STAGE_DIR" \
    "$TMP_DIR" \
    "$COMFY_OUTPUT_DIR" \
    "$OUTPUT_DIR" \
    "$PREVIEW_DIR"

start_preview_server() {
    cat > "$PREVIEW_SERVER" <<'PY'
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import quote, unquote
import json
import sys

output_dir = Path(sys.argv[1]).resolve()
state_file = Path(sys.argv[2]).resolve()
port = int(sys.argv[3])

HTML = r"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Qwen Live Preview</title>
<style>
html, body {
    margin: 0;
    width: 100%;
    height: 100%;
    background: #111;
    color: #eee;
    font-family: system-ui, sans-serif;
}
body {
    display: flex;
    flex-direction: column;
}
#toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
    padding: 10px 12px;
    background: #1b1b1b;
    border-bottom: 1px solid #333;
}
button {
    background: #2b2b2b;
    color: #eee;
    border: 1px solid #555;
    padding: 8px 12px;
    cursor: pointer;
}
button:hover {
    background: #3a3a3a;
}
#status {
    margin-left: 6px;
    white-space: pre-wrap;
    font-size: 14px;
}
#viewer {
    flex: 1;
    min-height: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
}
#preview {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
}
#help {
    font-size: 13px;
    color: #bbb;
}
</style>
</head>
<body>
<div id="toolbar">
    <button id="prevBtn">Prev</button>
    <button id="nextBtn">Next</button>
    <button id="latestBtn">Latest</button>
    <button id="followBtn">Auto follow: ON</button>
    <span id="help">Left/Rightキーで移動。Latestで最新へ戻る。</span>
</div>
<div id="toolbar">
    <span id="status">Loading...</span>
</div>
<div id="viewer">
    <img id="preview" alt="preview">
</div>
<script>
let images = [];
let currentIndex = -1;
let latestIndex = -1;
let followLatest = true;

function setStatus(text) {
    document.getElementById('status').textContent = text;
}

function setImageByIndex(index) {
    if (!images.length) {
        setStatus('画像がありません。生成待ちです。');
        document.getElementById('preview').removeAttribute('src');
        currentIndex = -1;
        return;
    }
    if (index < 0) index = 0;
    if (index >= images.length) index = images.length - 1;
    currentIndex = index;
    const img = images[currentIndex];
    document.getElementById('preview').src = img.url + '?t=' + Date.now();
}

function updateFollowButton() {
    document.getElementById('followBtn').textContent = 'Auto follow: ' + (followLatest ? 'ON' : 'OFF');
}

async function poll() {
    try {
        const res = await fetch('/api/manifest?t=' + Date.now(), {cache: 'no-store'});
        const data = await res.json();

        images = data.images || [];
        latestIndex = typeof data.latest_index === 'number' ? data.latest_index : -1;

        if (followLatest && latestIndex >= 0) {
            setImageByIndex(latestIndex);
        } else if (currentIndex >= 0 && currentIndex < images.length) {
            const img = images[currentIndex];
            document.getElementById('preview').src = img.url + '?t=' + Date.now();
        } else if (images.length) {
            setImageByIndex(0);
        } else {
            setImageByIndex(-1);
        }

        const shown = currentIndex >= 0 ? currentIndex + 1 : 0;
        const latestShown = latestIndex >= 0 ? latestIndex + 1 : 0;
        setStatus(
            `Run ID: ${data.run_id || '-'}    Job: ${data.completed_jobs || 0} / ${data.total_jobs || 0}    ` +
            `Viewing: ${shown} / ${images.length}    Latest: ${latestShown} / ${images.length}\n` +
            `${currentIndex >= 0 && images[currentIndex] ? images[currentIndex].name : 'まだ画像なし'}`
        );
        updateFollowButton();
    } catch (e) {
        setStatus('Preview fetch error: ' + e);
    }
}

document.getElementById('prevBtn').addEventListener('click', () => {
    followLatest = false;
    if (!images.length) return;
    setImageByIndex(currentIndex <= 0 ? 0 : currentIndex - 1);
    updateFollowButton();
});

document.getElementById('nextBtn').addEventListener('click', () => {
    followLatest = false;
    if (!images.length) return;
    setImageByIndex(currentIndex < 0 ? 0 : Math.min(images.length - 1, currentIndex + 1));
    updateFollowButton();
});

document.getElementById('latestBtn').addEventListener('click', () => {
    followLatest = true;
    if (latestIndex >= 0) setImageByIndex(latestIndex);
    updateFollowButton();
});

document.getElementById('followBtn').addEventListener('click', () => {
    followLatest = !followLatest;
    if (followLatest && latestIndex >= 0) setImageByIndex(latestIndex);
    updateFollowButton();
});

document.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft') {
        followLatest = false;
        if (images.length) setImageByIndex(currentIndex <= 0 ? 0 : currentIndex - 1);
        updateFollowButton();
    }
    if (event.key === 'ArrowRight') {
        followLatest = false;
        if (images.length) setImageByIndex(currentIndex < 0 ? 0 : Math.min(images.length - 1, currentIndex + 1));
        updateFollowButton();
    }
    if (event.key.toLowerCase() === 'l') {
        followLatest = true;
        if (latestIndex >= 0) setImageByIndex(latestIndex);
        updateFollowButton();
    }
});

poll();
setInterval(poll, 1000);
</script>
</body>
</html>
"""

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(output_dir), **kwargs)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?") or self.path == "/index.html":
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/manifest"):
            exts = {".png", ".jpg", ".jpeg", ".webp"}
            files = sorted(
                p for p in output_dir.rglob("*")
                if p.is_file() and p.suffix.lower() in exts
            )

            latest_rel = None
            completed_jobs = 0
            total_jobs = 0
            run_id = output_dir.name
            if state_file.exists():
                try:
                    state = json.loads(state_file.read_text(encoding="utf-8"))
                    latest_rel = state.get("latest_rel") or None
                    completed_jobs = int(state.get("completed_jobs", 0))
                    total_jobs = int(state.get("total_jobs", 0))
                    run_id = state.get("run_id") or run_id
                except Exception:
                    pass

            images = []
            latest_index = -1
            for idx, p in enumerate(files):
                rel = p.relative_to(output_dir).as_posix()
                url = "/" + "/".join(quote(part) for part in rel.split("/"))
                images.append({"name": rel, "url": url})
                if latest_rel and rel == latest_rel:
                    latest_index = idx

            body = json.dumps(
                {
                    "run_id": run_id,
                    "completed_jobs": completed_jobs,
                    "total_jobs": total_jobs,
                    "latest_index": latest_index,
                    "images": images,
                },
                ensure_ascii=False,
            ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.path = unquote(self.path)
        super().do_GET()

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

    cat > "$PREVIEW_INDEX" <<EOF_HTML
<!doctype html><meta charset="utf-8"><title>Redirect</title>
<script>location.replace('http://127.0.0.1:${PREVIEW_PORT}/');</script>
EOF_HTML

    echo '{"run_id": "'$RUN_ID'", "completed_jobs": 0, "total_jobs": 0, "latest_rel": null}' > "$PREVIEW_STATE"

    pkill -f "$PREVIEW_SERVER" 2>/dev/null || true
    pkill -f "http.server ${PREVIEW_PORT}" 2>/dev/null || true
    pkill -f "--url http://127.0.0.1:${PREVIEW_PORT}" 2>/dev/null || true

    nohup "$PYTHON" "$PREVIEW_SERVER" "$OUTPUT_DIR" "$PREVIEW_STATE" "$PREVIEW_PORT" > "$PREVIEW_LOG" 2>&1 &

    local preview_url=""
    if [ -x "$CLOUDFLARED_BIN" ]; then
        nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:${PREVIEW_PORT}" > "$PREVIEW_TUNNEL_LOG" 2>&1 &
        for _ in $(seq 1 15); do
            sleep 1
            preview_url="$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$PREVIEW_TUNNEL_LOG" | tail -n 1 || true)"
            [ -n "$preview_url" ] && break
        done
    fi

    echo "Preview directory : $PREVIEW_DIR"
    echo "Preview local URL : http://127.0.0.1:${PREVIEW_PORT}/"
    if [ -n "$preview_url" ]; then
        echo "Preview public URL: $preview_url"
    else
        echo "Preview public URL: not available"
        echo "Preview tunnel log: $PREVIEW_TUNNEL_LOG"
    fi
    echo
}

update_preview_state() {
    local latest_rel="${1:-}"
    local completed_jobs="${2:-0}"
    local total_jobs="${3:-0}"
    "$PYTHON" - "$PREVIEW_STATE" "$RUN_ID" "$completed_jobs" "$total_jobs" "$latest_rel" <<'PY'
from pathlib import Path
import json
import sys
state_path = Path(sys.argv[1])
run_id = sys.argv[2]
completed_jobs = int(sys.argv[3])
total_jobs = int(sys.argv[4])
latest_rel = sys.argv[5] or None
state = {
    "run_id": run_id,
    "completed_jobs": completed_jobs,
    "total_jobs": total_jobs,
    "latest_rel": latest_rel,
}
state_path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
PY
}

flush_outputs() {
    [ -d "$COMFY_OUTPUT_DIR" ] || return 0

    local moved_any=0
    while IFS= read -r -d '' file; do
        local base rel
        base="$(basename "$file")"
        mv -f -- "$file" "$OUTPUT_DIR/$base"
        rel="$base"
        update_preview_state "$rel" "$JOB" "$TOTAL"
        moved_any=1
    done < <(find "$COMFY_OUTPUT_DIR" -maxdepth 1 -type f -print0 | sort -z)

    if [ "$moved_any" -eq 0 ]; then
        update_preview_state "" "$JOB" "$TOTAL"
    fi
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
JOB=0

start_preview_server
update_preview_state "" 0 "$TOTAL"

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
