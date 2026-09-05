#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Vast.ai / PyTorch (Vast)
# Qwen Rapid AIO NSFW v19 + ComfyUI one-shot setup
# ============================================================

WORKSPACE="/workspace"
COMFY_DIR="$WORKSPACE/ComfyUI"
PYTHON="/venv/main/bin/python"
PIP="/venv/main/bin/pip"

MODEL_FILE="Qwen-Rapid-AIO-NSFW-v19.safetensors"
MODEL_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/v19/Qwen-Rapid-AIO-NSFW-v19.safetensors"

QWEN_NODE_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/fixed-textencode-node/nodes_qwen.v2.py"

WORKFLOW_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/Qwen-Rapid-AIO.json"
WORKFLOW_FILE="$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-v19-NSFW.json"

COMFY_LOG="$WORKSPACE/comfyui.log"
TUNNEL_LOG="$WORKSPACE/cloudflared.log"
CLOUDFLARED="$WORKSPACE/bin/cloudflared"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v wget >/dev/null 2>&1 || die "wget がありません。"
[ -x "$PYTHON" ] || die "/venv/main/bin/python が見つかりません。PyTorch (Vast) テンプレートか確認してください。"
[ -x "$PIP" ] || die "/venv/main/bin/pip が見つかりません。"

log "GPU確認"
nvidia-smi || true

log "Disk確認"
df -h "$WORKSPACE" || true

# ------------------------------------------------------------
# ComfyUI
# ------------------------------------------------------------
if [ ! -d "$COMFY_DIR/.git" ]; then
    log "ComfyUIをclone"
    cd "$WORKSPACE"
    git clone https://github.com/Comfy-Org/ComfyUI.git
else
    log "ComfyUIは既に存在します。cloneをスキップ"
fi

cd "$COMFY_DIR"

log "ComfyUI依存パッケージをインストール"
"$PIP" install -r requirements.txt

mkdir -p \
    "$COMFY_DIR/models/checkpoints" \
    "$COMFY_DIR/input" \
    "$COMFY_DIR/output" \
    "$COMFY_DIR/user/default/workflows" \
    "$WORKSPACE/bin"

# ------------------------------------------------------------
# Model
# ------------------------------------------------------------
MODEL_PATH="$COMFY_DIR/models/checkpoints/$MODEL_FILE"

if [ ! -s "$MODEL_PATH" ]; then
    log "Qwen Rapid AIO NSFW v19をダウンロード（約28.4GB）"
    wget -c -O "$MODEL_PATH" "$MODEL_URL"
else
    log "モデルは既に存在します。ダウンロードをスキップ"
fi

log "モデルサイズ"
ls -lh "$MODEL_PATH"

# ------------------------------------------------------------
# Phr00t fixed TextEncodeQwenImageEditPlus v2
# ------------------------------------------------------------
QWEN_NODE="$COMFY_DIR/comfy_extras/nodes_qwen.py"
QWEN_BACKUP="$COMFY_DIR/comfy_extras/nodes_qwen.py.bak"

if [ -f "$QWEN_NODE" ] && [ ! -f "$QWEN_BACKUP" ]; then
    log "標準nodes_qwen.pyをバックアップ"
    cp "$QWEN_NODE" "$QWEN_BACKUP"
fi

log "Phr00t nodes_qwen.v2.pyを導入"
wget -q -O "$QWEN_NODE" "$QWEN_NODE_URL"

# ------------------------------------------------------------
# Workflow
# ------------------------------------------------------------
log "Phr00t公式workflowを取得"
wget -q -O "$WORKFLOW_FILE" "$WORKFLOW_URL"

log "workflowをv19向けに自動調整"
WORKFLOW_FILE="$WORKFLOW_FILE" MODEL_FILE="$MODEL_FILE" "$PYTHON" - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["WORKFLOW_FILE"])
model_file = os.environ["MODEL_FILE"]

data = json.loads(path.read_text(encoding="utf-8"))

def patch(obj):
    if isinstance(obj, dict):
        return {k: patch(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [patch(v) for v in obj]
    if isinstance(obj, str):
        # 作者workflow内の旧Rapid-AIO checkpoint名をv19 NSFWへ置換
        if "Qwen-Rapid-AIO" in obj and obj.endswith(".safetensors"):
            return model_file
        # v19の作者推奨samplerへ変更
        if obj == "sa_solver":
            return "er_sde"
        return obj
    return obj

patched = patch(data)
path.write_text(json.dumps(patched, ensure_ascii=False, indent=2), encoding="utf-8")
print(path)
PY

# ------------------------------------------------------------
# Stop previous ComfyUI / tunnel if this script is re-run
# ------------------------------------------------------------
if pgrep -f "python main.py.*8188" >/dev/null 2>&1; then
    log "既存ComfyUIを停止"
    pkill -f "python main.py.*8188" || true
    sleep 2
fi

if pgrep -f "cloudflared tunnel.*8188" >/dev/null 2>&1; then
    log "既存Cloudflare Tunnelを停止"
    pkill -f "cloudflared tunnel.*8188" || true
    sleep 1
fi

# ------------------------------------------------------------
# Launch ComfyUI
# ------------------------------------------------------------
log "ComfyUIをバックグラウンド起動"
cd "$COMFY_DIR"
nohup "$PYTHON" main.py \
    --listen 127.0.0.1 \
    --port 8188 \
    > "$COMFY_LOG" 2>&1 &

COMFY_PID=$!
echo "$COMFY_PID" > "$WORKSPACE/comfyui.pid"

log "ComfyUI起動待ち"

READY=0
for _ in $(seq 1 90); do
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        echo
        echo "ComfyUIが起動途中で終了しました。ログ:"
        tail -n 80 "$COMFY_LOG" || true
        exit 1
    fi

    if "$PYTHON" - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8188/", timeout=1)
PY
    then
        READY=1
        break
    fi

    sleep 2
done

if [ "$READY" -ne 1 ]; then
    echo
    echo "ComfyUIが時間内に応答しませんでした。ログ:"
    tail -n 80 "$COMFY_LOG" || true
    exit 1
fi

log "ComfyUI起動成功: http://127.0.0.1:8188"

# ------------------------------------------------------------
# cloudflared
# ------------------------------------------------------------
if [ ! -x "$CLOUDFLARED" ]; then
    log "cloudflaredをダウンロード"
    wget -q -O "$CLOUDFLARED" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    chmod +x "$CLOUDFLARED"
fi

log "Cloudflare Quick Tunnelを起動"
: > "$TUNNEL_LOG"

nohup "$CLOUDFLARED" tunnel \
    --no-autoupdate \
    --url http://127.0.0.1:8188 \
    > "$TUNNEL_LOG" 2>&1 &

TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$WORKSPACE/cloudflared.pid"

PUBLIC_URL=""

for _ in $(seq 1 60); do
    PUBLIC_URL="$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$TUNNEL_LOG" | tail -n 1 || true)"

    if [ -n "$PUBLIC_URL" ]; then
        break
    fi

    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        break
    fi

    sleep 1
done

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"
echo
echo "Model:"
echo "  $MODEL_PATH"
echo
echo "Workflow:"
echo "  $WORKFLOW_FILE"
echo
echo "ComfyUI local:"
echo "  http://127.0.0.1:8188"
echo

if [ -n "$PUBLIC_URL" ]; then
    echo "ComfyUI public URL:"
    echo
    echo "  $PUBLIC_URL"
    echo
    echo "↑ このURLをPCのブラウザで開く。"
else
    echo "Cloudflare Quick TunnelのURL取得に失敗しました。"
    echo "Vast.ai Instance Portal → Tunnels から"
    echo
    echo "  http://localhost:8188"
    echo
    echo "を手動で公開してください。"
    echo
    echo "Tunnel log:"
    echo "  $TUNNEL_LOG"
fi

echo
echo "ComfyUI log:"
echo "  $COMFY_LOG"
echo
echo "停止:"
echo '  pkill -f "python main.py"'
echo '  pkill -f "cloudflared tunnel"'
echo
echo "利用終了後は必要な生成画像を回収してVast.aiインスタンスをDestroyする。"
echo "============================================================"
