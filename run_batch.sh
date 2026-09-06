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
# Match each output to its input image's aspect ratio while keeping roughly
# the default 1536x2048 pixel count (dimensions are rounded to 64 pixels):
#   MATCH_INPUT_ASPECT=1 bash /workspace/qwen_comfy_sh/run_batch.sh
#
# Inputs over 105% of 1536x2048 pixels are automatically downscaled to about
# that pixel count before being passed to the model. Their aspect ratio is kept.
#   DOWNSCALE_LARGE_INPUTS=0  Disable this behavior
#
# Optional preview settings:
#   PREVIEW_ENABLED=0        Disable browser preview
#   PREVIEW_PORT=8765        Local preview server port
#
# Browser preview security:
#   user     : qwen (fixed)
#   password : random 20-character alphanumeric string generated once per Vast workspace
#              and reused by later batch runs in the same rented instance
#   auth     : HTTP Basic Authentication over the HTTPS Cloudflare Quick Tunnel
#   secret   : stored only under /workspace/qwen_preview/ (outside this Git repo)
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
PREVIEW_USER="qwen"
PREVIEW_PASSWORD=""
PREVIEW_PASSWORD_FILE="$PREVIEW_ROOT/password.txt"
PREVIEW_URL_FILE="$PREVIEW_ROOT/url.txt"
PREVIEW_SERVER_VERSION="20260906-completion-alert-v1"

MATCH_INPUT_ASPECT="${MATCH_INPUT_ASPECT:-0}"
ASPECT_TARGET_PIXELS="${ASPECT_TARGET_PIXELS:-3145728}"
ASPECT_SIZE_STEP="${ASPECT_SIZE_STEP:-64}"
DOWNSCALE_LARGE_INPUTS="${DOWNSCALE_LARGE_INPUTS:-1}"
INPUT_RESIZE_TARGET_PIXELS="${INPUT_RESIZE_TARGET_PIXELS:-3145728}"
INPUT_RESIZE_TOLERANCE_PERCENT="${INPUT_RESIZE_TOLERANCE_PERCENT:-5}"

if [[ ! "$MATCH_INPUT_ASPECT" =~ ^[01]$ ]]; then
    echo "ERROR: MATCH_INPUT_ASPECT must be 0 or 1." >&2
    exit 1
fi
if [ "$MATCH_INPUT_ASPECT" = "1" ] && { [ -n "${WIDTH:-}" ] || [ -n "${HEIGHT:-}" ]; }; then
    echo "ERROR: MATCH_INPUT_ASPECT=1 cannot be combined with WIDTH or HEIGHT." >&2
    exit 1
fi
if [[ ! "$ASPECT_TARGET_PIXELS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ASPECT_TARGET_PIXELS must be a positive integer." >&2
    exit 1
fi
if [[ ! "$ASPECT_SIZE_STEP" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ASPECT_SIZE_STEP must be a positive integer." >&2
    exit 1
fi
if [[ ! "$DOWNSCALE_LARGE_INPUTS" =~ ^[01]$ ]]; then
    echo "ERROR: DOWNSCALE_LARGE_INPUTS must be 0 or 1." >&2
    exit 1
fi
if [[ ! "$INPUT_RESIZE_TARGET_PIXELS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: INPUT_RESIZE_TARGET_PIXELS must be a positive integer." >&2
    exit 1
fi
if [[ ! "$INPUT_RESIZE_TOLERANCE_PERCENT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: INPUT_RESIZE_TOLERANCE_PERCENT must be a non-negative integer." >&2
    exit 1
fi

INPUT_RESIZE_MAX_PIXELS=$((
    INPUT_RESIZE_TARGET_PIXELS * (100 + INPUT_RESIZE_TOLERANCE_PERCENT) / 100
))

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

# Create the browser-preview password only once for this Vast workspace.
# Later run_batch.sh invocations reuse the same password. The secret is stored
# under /workspace/qwen_preview/, never inside this Git repository.
if [ "$PREVIEW_ENABLED" = "1" ]; then
    mkdir -p "$PREVIEW_ROOT"

    if [ -f "$PREVIEW_PASSWORD_FILE" ]; then
        PREVIEW_PASSWORD="$(tr -d '\r\n' < "$PREVIEW_PASSWORD_FILE")"
        if [[ ! "$PREVIEW_PASSWORD" =~ ^[A-Za-z0-9]{20}$ ]]; then
            echo "ERROR: invalid preview password file: $PREVIEW_PASSWORD_FILE" >&2
            echo "Delete that file to generate a new password." >&2
            exit 1
        fi
    else
        PREVIEW_PASSWORD="$("$PYTHON" - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(20)))
PY
)"

        password_tmp="${PREVIEW_PASSWORD_FILE}.tmp.$$"
        printf '%s\n' "$PREVIEW_PASSWORD" > "$password_tmp"
        chmod 600 "$password_tmp"
        mv -f -- "$password_tmp" "$PREVIEW_PASSWORD_FILE"
    fi
fi

# ------------------------------------------------------------
# Ensure ComfyUI is running
# ------------------------------------------------------------
COMFY_LOG="${COMFY_LOG:-/workspace/comfyui.log}"
COMFY_PID_FILE="${COMFY_PID_FILE:-/workspace/comfyui.pid}"

comfyui_ready() {
    "$PYTHON" - <<'PY' >/dev/null 2>&1
import urllib.request

with urllib.request.urlopen(
    "http://127.0.0.1:8188/system_stats",
    timeout=3,
) as response:
    if response.status != 200:
        raise SystemExit(1)
PY
}

start_comfyui() {
    echo "ComfyUI: starting..."

    (
        cd "$COMFY_DIR"
        nohup "$PYTHON" main.py \
            --listen 127.0.0.1 \
            --port 8188 \
            > "$COMFY_LOG" 2>&1 &
        echo $! > "$COMFY_PID_FILE"
    )
}

if comfyui_ready; then
    echo "ComfyUI: already running"
else
    # A process may already exist while ComfyUI is still starting. Give it a
    # short grace period before treating it as stale.
    if pgrep -f "main.py.*--port[ =]8188" >/dev/null 2>&1; then
        echo "ComfyUI: process exists but API is not ready. Waiting..."

        for _ in $(seq 1 10); do
            sleep 1
            if comfyui_ready; then
                break
            fi
        done
    fi

    if ! comfyui_ready; then
        # If a hung/stale ComfyUI process survived, remove it before restart.
        if pgrep -f "main.py.*--port[ =]8188" >/dev/null 2>&1; then
            echo "ComfyUI: stale process detected. Restarting..."
            pkill -f "main.py.*--port[ =]8188" || true
            sleep 2
        fi

        start_comfyui

        echo "ComfyUI: waiting for API..."
        COMFY_READY=0

        for _ in $(seq 1 90); do
            if comfyui_ready; then
                COMFY_READY=1
                break
            fi
            sleep 1
        done

        if [ "$COMFY_READY" -ne 1 ]; then
            echo "ERROR: ComfyUI failed to start within 90 seconds." >&2
            echo "----- $COMFY_LOG -----" >&2
            tail -n 100 "$COMFY_LOG" >&2 || true
            exit 1
        fi
    fi

    echo "ComfyUI: ready"
fi

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
COMPLETED_JOBS=0
CUMULATIVE_JOB_NS=0
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

pidfile_running() {
    local pidfile="$1"
    [ -f "$pidfile" ] || return 1

    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

preview_http_ready() {
    QWEN_PREVIEW_USER="$PREVIEW_USER" \
    QWEN_PREVIEW_PASSWORD="$PREVIEW_PASSWORD" \
    QWEN_PREVIEW_SERVER_VERSION="$PREVIEW_SERVER_VERSION" \
    "$PYTHON" - "$PREVIEW_PORT" <<'PY' >/dev/null 2>&1
import base64
import os
import sys
import urllib.request

user = os.environ["QWEN_PREVIEW_USER"]
password = os.environ["QWEN_PREVIEW_PASSWORD"]
server_version = os.environ["QWEN_PREVIEW_SERVER_VERSION"]
token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
request = urllib.request.Request(
    f"http://127.0.0.1:{sys.argv[1]}/",
    headers={"Authorization": f"Basic {token}"},
)
with urllib.request.urlopen(request, timeout=1) as response:
    if response.headers.get("X-Qwen-Preview-Version") != server_version:
        raise SystemExit(1)
    response.read(1)
PY
}

load_preview_url() {
    PREVIEW_PUBLIC_URL=""

    if [ -f "$PREVIEW_URL_FILE" ]; then
        PREVIEW_PUBLIC_URL="$(tr -d '\r\n' < "$PREVIEW_URL_FILE")"
    fi

    if [[ ! "$PREVIEW_PUBLIC_URL" =~ ^https://[-a-zA-Z0-9]+\.trycloudflare\.com$ ]]; then
        PREVIEW_PUBLIC_URL="$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$PREVIEW_TUNNEL_LOG" 2>/dev/null | tail -n 1 || true)"
    fi
}

save_preview_url() {
    [ -n "$PREVIEW_PUBLIC_URL" ] || return 0
    local url_tmp="${PREVIEW_URL_FILE}.tmp.$$"
    printf '%s\n' "$PREVIEW_PUBLIC_URL" > "$url_tmp"
    chmod 600 "$url_tmp"
    mv -f -- "$url_tmp" "$PREVIEW_URL_FILE"
}

write_preview_state() {
    local latest_rel="${1:-$LAST_OUTPUT_REL}"
    local completed="${2:-$COMPLETED_JOBS}"

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

    cat > "$PREVIEW_SERVER" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote
import base64
import hmac
import json
import os
import sys

state_file = Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
username = os.environ["QWEN_PREVIEW_USER"]
password = os.environ["QWEN_PREVIEW_PASSWORD"]
server_version = os.environ["QWEN_PREVIEW_SERVER_VERSION"]
expected_auth = "Basic " + base64.b64encode(
    f"{username}:{password}".encode("utf-8")
).decode("ascii")

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
let audioContext=null;
let observedRunId=null;
let previousRunComplete=null;
let alertedRunId=null;

const preview=document.getElementById('preview');
const status=document.getElementById('status');
const followBtn=document.getElementById('follow');

function getAudioContext(){
  const AudioContextClass=window.AudioContext||window.webkitAudioContext;
  if(!AudioContextClass)return null;
  if(!audioContext||audioContext.state==='closed')audioContext=new AudioContextClass();
  return audioContext;
}

async function unlockAudio(){
  try{
    const ctx=getAudioContext();
    if(!ctx)return;
    if(ctx.state==='suspended')await ctx.resume();
    if(ctx.state!=='running')return;

    // A silent, user-initiated pulse helps browsers remember that this page
    // may play the later completion alert without adding a setup step.
    const oscillator=ctx.createOscillator();
    const gain=ctx.createGain();
    gain.gain.setValueAtTime(0.0001,ctx.currentTime);
    oscillator.connect(gain).connect(ctx.destination);
    oscillator.start();
    oscillator.stop(ctx.currentTime+0.02);
  }catch(e){
    // Browser autoplay policy must never affect preview or batch operation.
  }
}

function playCompletionAlert(){
  try{
    const ctx=getAudioContext();
    if(!ctx)return;

    const schedule=()=>{
      if(ctx.state!=='running')return;
      const start=ctx.currentTime+0.05;

      // Schedule the full pattern up front so background-tab timer throttling
      // cannot shorten the roughly five-second alert after it starts.
      for(let offset=0,index=0;offset<5;offset+=0.4,index+=1){
        const oscillator=ctx.createOscillator();
        const gain=ctx.createGain();
        const onset=start+offset;
        oscillator.type='square';
        oscillator.frequency.setValueAtTime(index%2===0?880:660,onset);
        gain.gain.setValueAtTime(0.0001,onset);
        gain.gain.exponentialRampToValueAtTime(0.16,onset+0.02);
        gain.gain.setValueAtTime(0.16,onset+0.20);
        gain.gain.exponentialRampToValueAtTime(0.0001,onset+0.30);
        oscillator.connect(gain).connect(ctx.destination);
        oscillator.start(onset);
        oscillator.stop(onset+0.31);
      }
    };

    if(ctx.state==='suspended'){
      ctx.resume().then(schedule).catch(()=>{});
    }else{
      schedule();
    }
  }catch(e){
    // Unsupported or blocked audio is non-fatal by design.
  }
}

function observeCompletion(data){
  const runId=String(data.run_id||'');
  const completed=Number(data.completed_jobs)||0;
  const total=Number(data.total_jobs)||0;
  const complete=Boolean(runId&&total>0&&completed>=total);

  // Do not alert merely because a page was opened/refreshed after completion.
  if(observedRunId===null){
    observedRunId=runId;
    previousRunComplete=complete;
    return;
  }

  if(runId!==observedRunId){
    observedRunId=runId;
    previousRunComplete=complete;
    alertedRunId=null;

    // A throttled background tab may miss the new run's incomplete state.
    if(complete){
      alertedRunId=runId;
      playCompletionAlert();
    }
    return;
  }

  if(previousRunComplete===false&&complete&&alertedRunId!==runId){
    alertedRunId=runId;
    playCompletionAlert();
  }
  previousRunComplete=complete;
}

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
    observeCompletion(data);

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
document.addEventListener('pointerdown',unlockAudio,{once:true,passive:true});
document.addEventListener('touchstart',unlockAudio,{once:true,passive:true});
document.addEventListener('keydown',e=>{
  unlockAudio();
  if(e.key==='ArrowLeft')prev();
  else if(e.key==='ArrowRight')next();
  else if(e.key.toLowerCase()==='l')latest();
});

poll();
setInterval(poll,1000);
</script>
</body>
</html>'''

class Handler(BaseHTTPRequestHandler):
    def send_auth_required(self):
        body = b"Authentication required\n"
        self.send_response(401)
        self.send_header(
            "WWW-Authenticate",
            'Basic realm="Qwen Live Preview", charset="UTF-8"',
        )
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authenticated(self):
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, expected_auth):
            self.send_auth_required()
            return False
        return True

    def do_HEAD(self):
        # Do not inherit any filesystem-serving behavior. All preview routes
        # are explicitly handled by do_GET and require authentication.
        if not self.authenticated():
            return
        self.send_response(405)
        self.send_header("Allow", "GET")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.authenticated():
            return

        if self.path == "/" or self.path.startswith("/?") or self.path == "/index.html":
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("X-Qwen-Preview-Version", server_version)
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

    # Switch an already-open preview page to this run before generation starts.
    write_preview_state "" 0

    # Reuse the authenticated preview server when it is already alive.
    # This keeps the browser session valid across repeated batch runs.
    if preview_http_ready; then
        echo "Preview server: reusing existing server"
    else
        stop_pidfile "$PREVIEW_HTTP_PID_FILE"

        QWEN_PREVIEW_USER="$PREVIEW_USER" \
        QWEN_PREVIEW_PASSWORD="$PREVIEW_PASSWORD" \
        QWEN_PREVIEW_SERVER_VERSION="$PREVIEW_SERVER_VERSION" \
        nohup "$PYTHON" "$PREVIEW_SERVER" "$PREVIEW_STATE" "$PREVIEW_PORT" \
            > "$PREVIEW_HTTP_LOG" 2>&1 &
        echo $! > "$PREVIEW_HTTP_PID_FILE"

        local ready=0
        for _ in $(seq 1 30); do
            if preview_http_ready; then
                ready=1
                break
            fi
            sleep 0.2
        done

        if [ "$ready" -ne 1 ]; then
            echo "WARNING: preview server failed to start. Log: $PREVIEW_HTTP_LOG" >&2
            return 0
        fi

        echo "Preview server: started"
    fi

    if [ -x "$CLOUDFLARED" ]; then
        # Keep the same Quick Tunnel alive across repeated run_batch.sh calls.
        # As long as this process stays alive, the browser URL stays unchanged.
        if pidfile_running "$PREVIEW_TUNNEL_PID_FILE"; then
            load_preview_url
            if [ -n "$PREVIEW_PUBLIC_URL" ]; then
                echo "Preview tunnel: reusing existing tunnel"
            else
                for _ in $(seq 1 10); do
                    load_preview_url
                    [ -n "$PREVIEW_PUBLIC_URL" ] && break
                    sleep 0.5
                done
            fi
        fi

        # Start a new tunnel only when there is no usable existing one.
        if ! pidfile_running "$PREVIEW_TUNNEL_PID_FILE" || [ -z "$PREVIEW_PUBLIC_URL" ]; then
            stop_pidfile "$PREVIEW_TUNNEL_PID_FILE"
            rm -f "$PREVIEW_URL_FILE"
            PREVIEW_PUBLIC_URL=""
            : > "$PREVIEW_TUNNEL_LOG"

            nohup "$CLOUDFLARED" tunnel \
                --no-autoupdate \
                --url "http://127.0.0.1:$PREVIEW_PORT" \
                > "$PREVIEW_TUNNEL_LOG" 2>&1 &
            echo $! > "$PREVIEW_TUNNEL_PID_FILE"

            for _ in $(seq 1 30); do
                load_preview_url
                [ -n "$PREVIEW_PUBLIC_URL" ] && break
                sleep 1
            done

            save_preview_url
            [ -n "$PREVIEW_PUBLIC_URL" ] && echo "Preview tunnel: started"
        else
            save_preview_url
        fi
    fi
}

# ------------------------------------------------------------
# Output handling
# ------------------------------------------------------------
flush_outputs() {
    local completed="${1:-$COMPLETED_JOBS}"
    [ -d "$COMFY_OUTPUT_DIR" ] || return 0

    while IFS= read -r -d '' file; do
        local base dest
        base="$(basename "$file")"
        dest="$OUTPUT_DIR/$base"
        mv -f -- "$file" "$dest"
        LAST_OUTPUT_REL="$base"
    done < <(find "$COMFY_OUTPUT_DIR" -maxdepth 1 -type f -print0 | sort -z)

    write_preview_state "$LAST_OUTPUT_REL" "$completed"
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
if [ "$MATCH_INPUT_ASPECT" = "1" ]; then
    echo "Size     : input aspect, about $ASPECT_TARGET_PIXELS pixels (${ASPECT_SIZE_STEP}px steps)"
elif [ -n "${WIDTH:-}" ] || [ -n "${HEIGHT:-}" ]; then
    echo "Size     : WIDTH=${WIDTH:-workflow default}, HEIGHT=${HEIGHT:-workflow default}"
else
    echo "Size     : workflow default"
fi
if [ "$DOWNSCALE_LARGE_INPUTS" = "1" ]; then
    echo "Input    : downscale over $INPUT_RESIZE_MAX_PIXELS pixels to about $INPUT_RESIZE_TARGET_PIXELS"
else
    echo "Input    : automatic downscaling disabled"
fi
if [ "$PREVIEW_ENABLED" = "1" ]; then
    echo "Preview local    : http://127.0.0.1:$PREVIEW_PORT/"
    if [ -n "$PREVIEW_PUBLIC_URL" ]; then
        echo "Preview URL      : $PREVIEW_PUBLIC_URL"
    else
        echo "Preview URL      : unavailable (see $PREVIEW_TUNNEL_LOG)"
    fi
    echo "Preview user     : $PREVIEW_USER"
    echo "Preview password : $PREVIEW_PASSWORD"
fi
echo "============================================================"
echo

json_string() {
    "$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

calculate_aspect_size() {
    "$PYTHON" - "$1" "$ASPECT_TARGET_PIXELS" "$ASPECT_SIZE_STEP" <<'PY'
import math
import sys

from PIL import Image

image_path = sys.argv[1]
target_pixels = int(sys.argv[2])
step = int(sys.argv[3])

with Image.open(image_path) as source:
    input_width, input_height = source.size
    orientation = source.getexif().get(274, 1)

if orientation in {5, 6, 7, 8}:
    input_width, input_height = input_height, input_width

if input_width <= 0 or input_height <= 0:
    raise SystemExit(f"ERROR: invalid input image dimensions: {image_path}")

aspect = input_width / input_height
ideal_width = math.sqrt(target_pixels * aspect)
ideal_height = math.sqrt(target_pixels / aspect)

output_width = max(step, round(ideal_width / step) * step)
output_height = max(step, round(ideal_height / step) * step)

print(output_width, output_height)
PY
}

stage_input_image() {
    "$PYTHON" - \
        "$1" \
        "$2" \
        "$DOWNSCALE_LARGE_INPUTS" \
        "$INPUT_RESIZE_TARGET_PIXELS" \
        "$INPUT_RESIZE_MAX_PIXELS" <<'PY'
import math
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageOps

source_path = Path(sys.argv[1])
destination_path = Path(sys.argv[2])
downscale_enabled = sys.argv[3] == "1"
target_pixels = int(sys.argv[4])
max_pixels = int(sys.argv[5])

with Image.open(source_path) as source:
    input_width, input_height = source.size
    orientation = source.getexif().get(274, 1)
    if orientation in {5, 6, 7, 8}:
        input_width, input_height = input_height, input_width
    input_pixels = input_width * input_height

    if not downscale_enabled or input_pixels <= max_pixels:
        shutil.copy2(source_path, destination_path)
        print("kept", input_width, input_height, input_width, input_height)
        raise SystemExit(0)

    scale = math.sqrt(target_pixels / input_pixels)
    output_width = max(1, round(input_width * scale))
    output_height = max(1, round(input_height * scale))

    oriented = ImageOps.exif_transpose(source)
    resized = oriented.resize(
        (output_width, output_height),
        Image.Resampling.LANCZOS,
    )

    image_format = source.format
    save_options = {}
    if image_format == "JPEG":
        if resized.mode not in {"L", "RGB"}:
            resized = resized.convert("RGB")
        save_options.update(quality=95, subsampling=0)
    elif image_format == "WEBP":
        save_options.update(quality=95)

    icc_profile = source.info.get("icc_profile")
    if icc_profile:
        save_options["icc_profile"] = icc_profile

    resized.save(destination_path, format=image_format, **save_options)

print("resized", input_width, input_height, output_width, output_height)
PY
}

monotonic_ns() {
    "$PYTHON" -c 'import time; print(time.monotonic_ns())'
}

print_job_timing() {
    "$PYTHON" - "$JOB" "$TOTAL" "$1" "$2" "$COMPLETED_JOBS" <<'PY'
import sys

job = int(sys.argv[1])
total = int(sys.argv[2])
elapsed_seconds = int(sys.argv[3]) / 1_000_000_000
cumulative_seconds = int(sys.argv[4]) / 1_000_000_000
completed = int(sys.argv[5])
average_seconds = cumulative_seconds / completed if completed else 0.0
print(
    f"[{job}/{total}] 完了: 今回 {elapsed_seconds:.1f}秒 | "
    f"平均 1枚あたり {average_seconds:.1f}秒"
)
PY
}

# ------------------------------------------------------------
# image x prompt Cartesian product
# ------------------------------------------------------------
for src in "${IMAGES[@]}"; do
    filename="$(basename "$src")"
    stem="${filename%.*}"
    image_value="$STAGE_REL/$filename"
    staged_image="$STAGE_DIR/$filename"

    read -r input_action input_width input_height staged_width staged_height < <(
        stage_input_image "$src" "$staged_image"
    )
    if [ "$input_action" = "resized" ]; then
        echo "Input    : $filename ${input_width}x${input_height} -> ${staged_width}x${staged_height}"
    else
        echo "Input    : $filename ${input_width}x${input_height} (kept)"
    fi

    matched_width=""
    matched_height=""
    if [ "$MATCH_INPUT_ASPECT" = "1" ]; then
        read -r matched_width matched_height < <(calculate_aspect_size "$src")
    fi

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

        if [ "$MATCH_INPUT_ASPECT" = "1" ]; then
            overrides+=("9.width=$matched_width" "9.height=$matched_height")
        fi

        if [ "$MATCH_INPUT_ASPECT" = "1" ]; then
            echo "[$JOB/$TOTAL] $filename × prompt $pidx (${matched_width}x${matched_height})"
        else
            echo "[$JOB/$TOTAL] $filename × prompt $pidx"
        fi

        # --no-json is a global comfy-cli option. It is required here because
        # stdout is redirected to a file; without it comfy-cli may emit a JSON
        # response envelope instead of the raw modified workflow.
        "$COMFY" --no-json --where local workflow set-slot \
            "$WORKFLOW" "${overrides[@]}" --stdout > "$tmp_workflow"

        # Measure the complete runner-visible generation interval: immediately
        # before submission through the final output move and preview update.
        job_started_ns="$(monotonic_ns)"
        "$COMFY" --where local run \
            --workflow "$tmp_workflow" \
            --wait \
            --timeout 3600

        # Move the just-generated image(s) into qwen_batch/output and update
        # the browser preview immediately.
        next_completed=$((COMPLETED_JOBS + 1))
        flush_outputs "$next_completed"
        job_finished_ns="$(monotonic_ns)"
        job_elapsed_ns=$((job_finished_ns - job_started_ns))
        if [ "$job_elapsed_ns" -lt 0 ]; then
            job_elapsed_ns=0
        fi
        COMPLETED_JOBS="$next_completed"
        CUMULATIVE_JOB_NS=$((CUMULATIVE_JOB_NS + job_elapsed_ns))
        print_job_timing "$job_elapsed_ns" "$CUMULATIVE_JOB_NS"
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
