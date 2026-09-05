#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Qwen / ComfyUI batch runner
# ============================================================
#
# Zero-argument usage:
#   bash /workspace/qwen_comfy_sh/run_batch.sh
#
# Defaults:
#   input    : /workspace/qwen_batch/input/
#   prompts  : /workspace/qwen_batch/prompts.md
#   workflow : /workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
#   output   : /workspace/qwen_batch/output/<RUN_ID>/
#
# Optional positional overrides:
#   bash run_batch.sh <input_dir> <prompts.md> [workflow.json]
#
# prompts.md format:
#   # Qwen prompts
#
#   ## 1
#   first prompt...
#
#   ## anything
#   second prompt...
#
# The text after "##" is ignored. "##", "## 1", "## Prompt 3" etc. are all valid.
# Each level-2 heading starts one prompt section. Multi-line prompts are supported.
#
# Optional generation overrides:
#   DENOISE=0.9 STEPS=6 CFG=1 SAMPLER=er_sde SCHEDULER=beta \
#   WIDTH=1536 HEIGHT=2048 SEED=123 NEGATIVE_PROMPT="..." \
#   bash /workspace/qwen_comfy_sh/run_batch.sh
#
# Optional preview settings:
#   PREVIEW_ENABLED=0        Disable browser preview
#   PREVIEW_PORT=8765        Local preview server port
#
# Input images are read only from the top level of input/. Subdirectories such
# as input/archive/ are ignored.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
BATCH_ROOT="${BATCH_ROOT:-/workspace/qwen_batch}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY="${COMFY_CLI:-/venv/main/bin/comfy}"
DEFAULT_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"

PREVIEW_ENABLED="${PREVIEW_ENABLED:-1}"
PREVIEW_PORT="${PREVIEW_PORT:-8765}"
PREVIEW_ROOT="${PREVIEW_ROOT:-/workspace/qwen_preview}"
CLOUDFLARED="${CLOUDFLARED_BIN:-/workspace/bin/cloudflared}"

INPUT_RAW="${1:-$BATCH_ROOT/input}"
PROMPTS_RAW="${2:-$BATCH_ROOT/prompts.md}"
WORKFLOW_RAW="${3:-$DEFAULT_WORKFLOW}"

[ -d "$INPUT_RAW" ] || { echo "ERROR: input directory not found: $INPUT_RAW" >&2; exit 1; }
[ -f "$PROMPTS_RAW" ] || { echo "ERROR: prompts.md not found: $PROMPTS_RAW" >&2; exit 1; }
[ -f "$WORKFLOW_RAW" ] || { echo "ERROR: workflow not found: $WORKFLOW_RAW" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "ERROR: Python not found: $PYTHON" >&2; exit 1; }
[ -x "$COMFY" ] || { echo "ERROR: comfy-cli not found: $COMFY" >&2; exit 1; }

INPUT_DIR="$(realpath "$INPUT_RAW")"
PROMPTS_MD="$(realpath "$PROMPTS_RAW")"
WORKFLOW="$(realpath "$WORKFLOW_RAW")"

# ComfyUI must already be running; setup_qwen_comfy.sh starts it.
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

# SaveImage writes here first, then this script moves each finished image to
# /workspace/qwen_batch/output/<RUN_ID>/.
COMFY_OUTPUT_DIR="$COMFY_DIR/output/batch/$RUN_ID"
OUTPUT_DIR="$BATCH_ROOT/output/$RUN_ID"

mkdir -p \
    "$BATCH_ROOT/input" \
    "$BATCH_ROOT/output" \
    "$BATCH_ROOT/tmp" \
    "$STAGE_DIR" \
    "$TMP_DIR" \
    "$COMFY_OUTPUT_DIR" \
    "$OUTPUT_DIR"

# ------------------------------------------------------------
# Input images: top-level only
# ------------------------------------------------------------
mapfile -d '' IMAGES < <(
    find "$INPUT_DIR" -maxdepth 1 -type f \
      \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
      -print0 | sort -z
)

if [ "${#IMAGES[@]}" -eq 0 ]; then
    echo "ERROR: no input images found in: $INPUT_DIR" >&2
    exit 1
fi

# ------------------------------------------------------------
# prompts.md parser
# ------------------------------------------------------------
# Any line beginning with exactly two '#' characters starts a new prompt.
# The heading text itself is ignored. Lines before the first ## are ignored.
mapfile -t PROMPTS_B64 < <("$PYTHON" - "$PROMPTS_MD" <<'PY'
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8-sig").splitlines()

prompts = []
current = None

for line in lines:
    # Accept: ##, ## , ## 1, ## Prompt 3, ##anything
    # Do not treat ### headings as a new prompt.
    if line.startswith("##") and not line.startswith("###"):
        if current is not None:
            text = "\n".join(current).strip()
            if text:
                prompts.append(text)
        current = []
        continue

    if current is not None:
        current.append(line)

if current is not None:
    text = "\n".join(current).strip()
    if text:
        prompts.append(text)

if not prompts:
    raise SystemExit(
        "ERROR: prompts.md contains no prompts. "
        "Start each prompt section with a line beginning with ##"
    )

for prompt in prompts:
    print(base64.b64encode(prompt.encode("utf-8")).decode("ascii"))
PY
)

TOTAL=$(( ${#IMAGES[@]} * ${#PROMPTS_B64[@]} ))
JOB=0
LAST_OUTPUT_REL=""

# ------------------------------------------------------------
# Browser live preview
# ------------------------------------------------------------
PREVIEW_STATE="$PREVIEW_ROOT/state.json"
PREVIEW_SERVER="$PREVIEW_ROOT/server.py"
PREVIEW_HTTP_LOG="$PREVIEW_ROOT/http.log"
PREVIEW_TUNNEL_LOG="$PREVIEW_ROOT/tunnel.log"
PREVIEW_HTTP_PID_FILE="$PREVIEW_ROOT/http.pid"
PREVIEW_TUNNEL_PID_FILE="$PREVIEW_ROOT/tunnel.pid"
PREVIEW_PUBLIC_URL=""

stop_pidfile() {
    local pidfile="$1"
    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 20); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
        fi
        rm -f "$pidfile"
    fi
}

write_preview_state() {
    local latest_rel="${1:-$LAST_OUTPUT_REL}"
    local completed="${2:-$JOB}"

    [ "$PREVIEW_ENABLED" = "1" ] || return 0

    "$PYTHON" - "$PREVIEW_STATE" "$RUN_ID" "$OUTPUT_DIR" "$latest_rel" "$completed" "$TOTAL" <<'PY'
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
state = {
    "run_id": sys.argv[2],
    "output_dir": sys.argv[3],
    "latest_rel": sys.argv[4] or None,
    "completed_jobs": int(sys.argv[5]),
    "total_jobs": int(sys.argv[6]),
}

tmp = state_path.with_suffix(".tmp")
tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
os.replace(tmp, state_path)
PY
}

start_preview() {
    [ "$PREVIEW_ENABLED" = "1" ] || return 0

    mkdir -p "$PREVIEW_ROOT"
    stop_pidfile "$PREVIEW_HTTP_PID_FILE"
    stop_pidfile "$PREVIEW_TUNNEL_PID_FILE"

    cat > "$PREVIEW_SERVER" <<'PY'
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import quote
import json
import sys

state_file = Path(sys.argv[1]).resolve()
port = int(sys.argv[2])

HTML = r'''<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Qwen Live Preview</title>
<style>
html,body{margin:0;width:100%;height:100%;background:#111;color:#eee;font-family:system-ui,sans-serif}
body{display:flex;flex-direction:column;overflow:hidden}
#top{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:10px 12px;background:#1b1b1b;border-bottom:1px solid #333}
button{background:#2b2b2b;color:#eee;border:1px solid #555;border-radius:5px;padding:7px 12px;cursor:pointer}
button:hover{background:#3a3a3a}
#status{padding:8px 12px;background:#171717;border-bottom:1px solid #333;font-size:13px;white-space:pre-wrap}
#viewer{flex:1;min-height:0;display:flex;align-items:center;justify-content:center;overflow:hidden}
#preview{max-width:100%;max-height:100%;object-fit:contain}
#hint{color:#aaa;font-size:13px}
</style>
</head>
<body>
<div id="top">
  <button id="prev">← Prev</button>
  <button id="next">Next →</button>
  <button id="latest">Latest</button>
  <button id="follow">Auto follow: ON</button>
  <span id="hint">←/→: 移動　L: 最新へ戻る</span>
</div>
<div id="status">生成待ち...</div>
<div id="viewer"><img id="preview" alt="preview"></div>
<script>
let images=[];
let currentIndex=-1;
let latestIndex=-1;
let followLatest=true;

const preview=document.getElementById('preview');
const status=document.getElementById('status');
const followBtn=document.getElementById('follow');

function updateFollowButton(){
  followBtn.textContent='Auto follow: '+(followLatest?'ON':'OFF');
}

function showIndex(i, refresh=false){
  if(!images.length){
    currentIndex=-1;
    preview.removeAttribute('src');
    return;
  }
  i=Math.max(0,Math.min(images.length-1,i));
  currentIndex=i;
  const item=images[i];
  preview.src=item.url+(refresh?'?t='+Date.now():'');
}

function renderStatus(data){
  const shown=currentIndex>=0?currentIndex+1:0;
  const latest=latestIndex>=0?latestIndex+1:0;
  const name=(currentIndex>=0&&images[currentIndex])?images[currentIndex].name:'まだ画像なし';
  status.textContent=`Run: ${data.run_id||'-'}    Completed: ${data.completed_jobs||0} / ${data.total_jobs||0}    Viewing: ${shown} / ${images.length}    Latest: ${latest} / ${images.length}\n${name}`;
}

async function poll(){
  try{
    const r=await fetch('/api/manifest?t='+Date.now(),{cache:'no-store'});
    const data=await r.json();
    const previousName=(currentIndex>=0&&images[currentIndex])?images[currentIndex].name:null;
    images=data.images||[];
    latestIndex=Number.isInteger(data.latest_index)?data.latest_index:-1;

    if(followLatest && latestIndex>=0){
      showIndex(latestIndex,true);
    }else if(previousName){
      const idx=images.findIndex(x=>x.name===previousName);
      if(idx>=0){
        currentIndex=idx;
      }else if(images.length){
        showIndex(Math.min(currentIndex,images.length-1));
      }
    }else if(images.length){
      showIndex(0);
    }

    renderStatus(data);
    updateFollowButton();
  }catch(e){
    status.textContent='Preview error: '+e;
  }
}

function prev(){
  if(!images.length)return;
  followLatest=false;
  showIndex(currentIndex<=0?0:currentIndex-1);
  updateFollowButton();
}
function next(){
  if(!images.length)return;
  followLatest=false;
  showIndex(currentIndex<0?0:Math.min(images.length-1,currentIndex+1));
  updateFollowButton();
}
function latest(){
  followLatest=true;
  if(latestIndex>=0)showIndex(latestIndex,true);
  updateFollowButton();
}

document.getElementById('prev').onclick=prev;
document.getElementById('next').onclick=next;
document.getElementById('latest').onclick=latest;
followBtn.onclick=()=>{followLatest=!followLatest;if(followLatest&&latestIndex>=0)showIndex(latestIndex,true);updateFollowButton();};
document.addEventListener('keydown',e=>{
  if(e.key==='ArrowLeft')prev();
  else if(e.key==='ArrowRight')next();
  else if(e.key.toLowerCase()==='l')latest();
});

poll();
setInterval(poll,1000);
</script>
</body>
</html>'''

class Handler(SimpleHTTPRequestHandler):
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
            try:
                state = json.loads(state_file.read_text(encoding="utf-8"))
            except Exception:
                state = {}

            output_dir = Path(state.get("output_dir") or "/nonexistent")
            latest_rel = state.get("latest_rel")
            exts = {".png", ".jpg", ".jpeg", ".webp"}

            files = []
            if output_dir.is_dir():
                files = [p for p in output_dir.rglob("*") if p.is_file() and p.suffix.lower() in exts]
                files.sort(key=lambda p: (p.stat().st_mtime_ns, p.name))

            images = []
            latest_index = -1
            for idx, p in enumerate(files):
                rel = p.relative_to(output_dir).as_posix()
                url = "/image/" + "/".join(quote(part) for part in rel.split("/"))
                images.append({"name": rel, "url": url})
                if latest_rel and rel == latest_rel:
                    latest_index = idx

            body = json.dumps({
                "run_id": state.get("run_id"),
                "completed_jobs": state.get("completed_jobs", 0),
                "total_jobs": state.get("total_jobs", 0),
                "latest_index": latest_index,
                "images": images,
            }, ensure_ascii=False).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/image/"):
            try:
                state = json.loads(state_file.read_text(encoding="utf-8"))
                output_dir = Path(state["output_dir"]).resolve()
            except Exception:
                self.send_error(404)
                return

            from urllib.parse import unquote, urlparse
            rel = unquote(urlparse(self.path).path[len("/image/"):])
            target = (output_dir / rel).resolve()
            try:
                target.relative_to(output_dir)
            except ValueError:
                self.send_error(403)
                return

            if not target.is_file():
                self.send_error(404)
                return

            data = target.read_bytes()
            suffix = target.suffix.lower()
            ctype = {
                ".png": "image/png",
                ".jpg": "image/jpeg",
                ".jpeg": "image/jpeg",
                ".webp": "image/webp",
            }.get(suffix, "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        self.send_error(404)

    def log_message(self, fmt, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

    write_preview_state "" 0

    nohup "$PYTHON" "$PREVIEW_SERVER" "$PREVIEW_STATE" "$PREVIEW_PORT" \
        > "$PREVIEW_HTTP_LOG" 2>&1 &
    echo $! > "$PREVIEW_HTTP_PID_FILE"

    # Wait until local preview server responds.
    local ready=0
    for _ in $(seq 1 30); do
        if "$PYTHON" - "$PREVIEW_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=1).read(1)
PY
        then
            ready=1
            break
        fi
        sleep 0.2
    done

    if [ "$ready" -ne 1 ]; then
        echo "WARNING: preview server failed to start. Log: $PREVIEW_HTTP_LOG" >&2
        return 0
    fi

    if [ -x "$CLOUDFLARED" ]; then
        : > "$PREVIEW_TUNNEL_LOG"
        nohup "$CLOUDFLARED" tunnel \
            --no-autoupdate \
            --url "http://127.0.0.1:$PREVIEW_PORT" \
            > "$PREVIEW_TUNNEL_LOG" 2>&1 &
        echo $! > "$PREVIEW_TUNNEL_PID_FILE"

        for _ in $(seq 1 30); do
            PREVIEW_PUBLIC_URL="$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$PREVIEW_TUNNEL_LOG" | tail -n 1 || true)"
            [ -n "$PREVIEW_PUBLIC_URL" ] && break
            sleep 1
        done
    fi
}

# ------------------------------------------------------------
# Output handling
# ------------------------------------------------------------
flush_outputs() {
    [ -d "$COMFY_OUTPUT_DIR" ] || return 0

    while IFS= read -r -d '' file; do
        local base dest
        base="$(basename "$file")"
        dest="$OUTPUT_DIR/$base"
        mv -f -- "$file" "$dest"
        LAST_OUTPUT_REL="$base"
    done < <(find "$COMFY_OUTPUT_DIR" -maxdepth 1 -type f -print0 | sort -z)

    write_preview_state "$LAST_OUTPUT_REL" "$JOB"
}

cleanup() {
    flush_outputs || true
    rmdir "$COMFY_OUTPUT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

start_preview

# ------------------------------------------------------------
# Batch summary
# ------------------------------------------------------------
echo "============================================================"
echo " QWEN BATCH"
echo "============================================================"
echo "Run ID   : $RUN_ID"
echo "Images   : ${#IMAGES[@]}"
echo "Prompts  : ${#PROMPTS_B64[@]}"
echo "Total    : $TOTAL"
echo "Workflow : $WORKFLOW"
echo "Output   : $OUTPUT_DIR"
if [ "$PREVIEW_ENABLED" = "1" ]; then
    echo "Preview local : http://127.0.0.1:$PREVIEW_PORT/"
    if [ -n "$PREVIEW_PUBLIC_URL" ]; then
        echo "Preview URL   : $PREVIEW_PUBLIC_URL"
    else
        echo "Preview URL   : unavailable (see $PREVIEW_TUNNEL_LOG)"
    fi
fi
echo "============================================================"
echo

# LoadImage reads only from ComfyUI/input, so stage all input images once.
for src in "${IMAGES[@]}"; do
    cp -f -- "$src" "$STAGE_DIR/$(basename "$src")"
done

json_string() {
    "$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

# ------------------------------------------------------------
# image x prompt Cartesian product
# ------------------------------------------------------------
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

        # Repository workflow node addresses:
        #   8.image             = LoadImage
        #   3.prompt            = positive TextEncodeQwenImageEditPlus
        #   4.prompt            = negative TextEncodeQwenImageEditPlus
        #   2.*                 = KSampler
        #   9.width/height      = EmptyLatentImage
        #   10.filename_prefix  = SaveImage
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

        # --no-json is a global comfy-cli option. It is required here because
        # stdout is redirected to a file; without it comfy-cli may emit a JSON
        # response envelope instead of the raw modified workflow.
        "$COMFY" --no-json --where local workflow set-slot \
            "$WORKFLOW" "${overrides[@]}" --stdout > "$tmp_workflow"

        "$COMFY" --where local run \
            --workflow "$tmp_workflow" \
            --wait \
            --timeout 3600

        # Move the just-generated image(s) into qwen_batch/output and update
        # the browser preview immediately.
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
if [ "$PREVIEW_ENABLED" = "1" ] && [ -n "$PREVIEW_PUBLIC_URL" ]; then
    echo "Preview: $PREVIEW_PUBLIC_URL"
fi
echo "============================================================"
