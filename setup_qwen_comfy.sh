#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

REPO_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"
WORKFLOW_FILE="$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-SaveImage.json"
BATCH_ROOT="$WORKSPACE/qwen_batch"

COMFY_LOG="$WORKSPACE/comfyui.log"
TUNNEL_LOG="$WORKSPACE/cloudflared.log"
CLOUDFLARED="$WORKSPACE/bin/cloudflared"
MODEL_PATH="$COMFY_DIR/models/checkpoints/$MODEL_FILE"
COMFY_CLI="/venv/main/bin/comfy"

# Vast.ai は毎回Destroyしてモデルを再DLする運用なので、実回線速度を事前測定する。
# 10 MiB/s ≒ 84 Mbps。これ未満だと28.4GBのモデルだけで約45分以上かかる。
MIN_DOWNLOAD_MIB_S="${MIN_DOWNLOAD_MIB_S:-10}"
SPEED_TEST_BYTES="${SPEED_TEST_BYTES:-8388608}"   # 8 MiB
ALLOW_SLOW_DOWNLOAD="${ALLOW_SLOW_DOWNLOAD:-0}"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || die "git がありません。"
command -v wget >/dev/null 2>&1 || die "wget がありません。"
[ -x "$PYTHON" ] || die "/venv/main/bin/python が見つかりません。PyTorch (Vast) テンプレートか確認してください。"
[ -x "$PIP" ] || die "/venv/main/bin/pip が見つかりません。"
[ -f "$REPO_WORKFLOW" ] || die "リポジトリ内の workflow が見つかりません: $REPO_WORKFLOW"

log "GPU確認"
nvidia-smi || true

log "Disk確認"
df -h "$WORKSPACE" || true

# ------------------------------------------------------------
# Network preflight
# ------------------------------------------------------------
log "回線速度を事前確認（Hugging Faceから最大8MiBだけ試験DL）"

SPEED_RESULT="$(
    MODEL_URL="$MODEL_URL" SPEED_TEST_BYTES="$SPEED_TEST_BYTES" "$PYTHON" - <<'PY'
import os
import time
import urllib.request

url = os.environ["MODEL_URL"]
target = int(os.environ["SPEED_TEST_BYTES"])

req = urllib.request.Request(
    url,
    headers={
        "Range": f"bytes=0-{target - 1}",
        "User-Agent": "vast-qwen-setup-speed-test/1.0",
    },
)

start = time.monotonic()
downloaded = 0

try:
    with urllib.request.urlopen(req, timeout=15) as r:
        while downloaded < target:
            chunk = r.read(min(1024 * 1024, target - downloaded))
            if not chunk:
                break
            downloaded += len(chunk)
            if time.monotonic() - start >= 20:
                break
except Exception as e:
    print(f"ERROR|{type(e).__name__}: {e}")
    raise SystemExit(0)

elapsed = max(time.monotonic() - start, 0.001)
mib_s = downloaded / 1024 / 1024 / elapsed
mbps = mib_s * 8.388608
print(f"OK|{mib_s:.2f}|{mbps:.1f}|{elapsed:.2f}|{downloaded}")
PY
)"

if [[ "$SPEED_RESULT" == OK\|* ]]; then
    IFS='|' read -r _ DOWNLOAD_MIB_S DOWNLOAD_MBPS TEST_SECONDS TEST_BYTES <<< "$SPEED_RESULT"

    EST_MINUTES="$(
        "$PYTHON" - "$DOWNLOAD_MIB_S" <<'PY'
import sys
speed = max(float(sys.argv[1]), 0.001)
model_bytes = 28_431_843_583
minutes = model_bytes / (speed * 1024 * 1024) / 60
print(f"{minutes:.1f}")
PY
    )"

    log "実測: ${DOWNLOAD_MIB_S} MiB/s（約 ${DOWNLOAD_MBPS} Mbps）"
    echo "28.4GBモデルの推定DL時間: 約 ${EST_MINUTES} 分"

    IS_SLOW="$(
        "$PYTHON" - "$DOWNLOAD_MIB_S" "$MIN_DOWNLOAD_MIB_S" <<'PY'
import sys
print(1 if float(sys.argv[1]) < float(sys.argv[2]) else 0)
PY
    )"

    if [ "$IS_SLOW" -eq 1 ]; then
        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo " WARNING: このホストの実回線速度は遅いです。"
        echo " 実測: ${DOWNLOAD_MIB_S} MiB/s（約 ${DOWNLOAD_MBPS} Mbps）"
        echo " モデルDL推定: 約 ${EST_MINUTES} 分"
        echo
        echo " 毎回Destroyして再構築する運用では非効率です。"
        echo " Vast.aiの表示値ではなく、このHugging Face実測値を基準に判断してください。"
        echo " 目安: 20 MiB/s以上を推奨、10 MiB/s未満なら別ホストを推奨します。"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo

        if [ "$ALLOW_SLOW_DOWNLOAD" != "1" ]; then
            if [ -t 0 ]; then
                read -r -p "それでもこのホストで続行しますか？ [y/N]: " ANSWER
                case "$ANSWER" in
                    y|Y|yes|YES) ;;
                    *)
                        echo "セットアップを中止しました。Vast.aiで別ホストを選び、現在のインスタンスはDestroyしてください。"
                        exit 2
                        ;;
                esac
            else
                echo "非対話実行のため中止します。強制続行する場合は ALLOW_SLOW_DOWNLOAD=1 を指定してください。"
                exit 2
            fi
        fi
    fi
else
    echo
    echo "WARNING: 回線速度の事前測定に失敗しました: ${SPEED_RESULT#ERROR|}"
    echo "速度判定をスキップして続行します。"
fi

# ------------------------------------------------------------
# ComfyUI
# ------------------------------------------------------------
COMFY_VALID=0

if [ -d "$COMFY_DIR/.git" ] \
    && [ -f "$COMFY_DIR/requirements.txt" ] \
    && [ -f "$COMFY_DIR/main.py" ] \
    && git -C "$COMFY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    COMFY_VALID=1
fi

if [ "$COMFY_VALID" -eq 1 ]; then
    log "ComfyUIは正常に存在します。cloneをスキップ"
else
    RECOVERED_MODEL="$WORKSPACE/.${MODEL_FILE}.recover"

    if [ -e "$COMFY_DIR" ]; then
        log "不完全なComfyUIを検出しました。削除して再cloneします。"

        # checkpointだけ既に取得済みなら再DLを避けるため一時退避。
        if [ -s "$MODEL_PATH" ]; then
            log "既存モデルを一時退避"
            mv "$MODEL_PATH" "$RECOVERED_MODEL"
        fi

        rm -rf "$COMFY_DIR"
    fi

    log "ComfyUIをshallow clone"
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"

    if [ -s "$RECOVERED_MODEL" ]; then
        log "退避したモデルを復元"
        mkdir -p "$COMFY_DIR/models/checkpoints"
        mv "$RECOVERED_MODEL" "$MODEL_PATH"
    fi
fi

cd "$COMFY_DIR"

log "ComfyUI依存パッケージをインストール"
"$PIP" install -r requirements.txt

log "公式 comfy-cli をインストール"
"$PIP" install -U 'comfy-cli>=1.16.0,<2'
[ -x "$COMFY_CLI" ] || die "comfy-cli のインストールに失敗しました。"

log "comfy-cli のデフォルト ComfyUI workspace を設定"
"$COMFY_CLI" set-default "$COMFY_DIR"

mkdir -p \
    "$COMFY_DIR/models/checkpoints" \
    "$COMFY_DIR/input" \
    "$COMFY_DIR/output" \
    "$COMFY_DIR/user/default/workflows" \
    "$BATCH_ROOT/input" \
    "$BATCH_ROOT/tmp" \
    "$WORKSPACE/bin"

# ------------------------------------------------------------
# Model
# ------------------------------------------------------------
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
# Repository workflow
# ------------------------------------------------------------
log "リポジトリの workflow を ComfyUI に配置"
cp -f "$REPO_WORKFLOW" "$WORKFLOW_FILE"

if [ -f "$SCRIPT_DIR/run_batch.sh" ]; then
    chmod +x "$SCRIPT_DIR/run_batch.sh"
fi

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
echo "comfy-cli:"
"$COMFY_CLI" --version || true
echo
echo "Batch input:"
echo "  $BATCH_ROOT/input"
echo "Prompts JSON:"
echo "  $BATCH_ROOT/prompts.json"
echo "Batch command:"
echo "  bash $SCRIPT_DIR/run_batch.sh"
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
