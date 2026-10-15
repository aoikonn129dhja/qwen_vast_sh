#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$MODEL_DIR/model.conf"

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_LOG="${COMFY_LOG:-$WORKSPACE/comfyui.log}"
VERIFY_SHA256="${VERIFY_SHA256:-0}" # 1: optional full SHA-256 verification
UPDATE_COMFYUI="${UPDATE_COMFYUI:-1}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

need git
need wget
need stat
need df
need sha256sum
[ -x "$PYTHON" ] || die "Python がありません: $PYTHON（Vast PyTorch または Salad コンテナを確認）"
[ -f "$MODEL_DIR/workflows/$WORKFLOW_FILE" ] || die "workflow がありません: $MODEL_DIR/workflows/$WORKFLOW_FILE"
[[ "$VERIFY_SHA256" == 0 || "$VERIFY_SHA256" == 1 ]] || die 'VERIFY_SHA256 は 0 または 1 を指定してください。'
mkdir -p "$WORKSPACE"

log 'GPU・ディスク容量を確認'
nvidia-smi || die 'NVIDIA GPU が利用できません。'
df -h "$WORKSPACE"
free_kb="$(df -Pk "$WORKSPACE" | awk 'NR == 2 { print $4 }')"
[ "$free_kb" -ge 23000000 ] || die '空き容量が23GB未満です。モデル約17.4GBと一時ファイルの領域を確保してください。'

# Ensure a recent ComfyUI to support the native Qwen Image 2.1 nodes.
log 'ComfyUI の準備'
if [ -d "$COMFY_DIR/.git" ] && [ -f "$COMFY_DIR/main.py" ]; then
    if [ "$UPDATE_COMFYUI" = 1 ]; then
        # Never overwrite user changes to ComfyUI core files.
        git -C "$COMFY_DIR" diff --quiet || die 'ComfyUI に未コミット変更があります。バックアップしてから更新してください。'
        git -C "$COMFY_DIR" diff --cached --quiet || die 'ComfyUI にステージ済み変更があります。'
        git -C "$COMFY_DIR" pull --ff-only || die 'ComfyUI の fast-forward 更新に失敗しました。'
    else
        log '既存の ComfyUI をそのまま使用します。'
    fi
elif [ -e "$COMFY_DIR" ]; then
    die "不完全または Git 管理外の ComfyUI があります: $COMFY_DIR"
else
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi

log 'ComfyUI 依存パッケージを導入'
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"

HF_BASE="https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/$BASE_REVISION"
HF_LORA="https://huggingface.co/lightx2v/Qwen-Image-2.1-Lightning/resolve/$LORA_REVISION"

# Use temporary .part files so an interrupted download can be resumed.
# The source SHA-256 is optionally checked using VERIFY_SHA256=1.
fetch_model() {
    local url="$1" dest="$2" expected_sha="$3" min_bytes="$4"
    local partial="${dest}.part" size got_sha
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ]; then
        size="$(stat -c %s "$dest")"
        if [ "$size" -ge "$min_bytes" ]; then
            if [ "$VERIFY_SHA256" != 1 ]; then
                log "既存ファイルを再利用: $(basename "$dest")"
                return 0
            fi
            log "既存ファイルの SHA-256 を確認: $(basename "$dest")"
            got_sha="$(sha256sum "$dest" | awk '{print $1}')"
            [ "$got_sha" = "$expected_sha" ] && return 0
        fi
        die "既存モデルが不完全・不一致です。手動確認してください: $dest"
    fi
    log "ダウンロード: $(basename "$dest")"
    wget --https-only --tries=4 --timeout=60 -c --progress=bar:force:noscroll \
        -O "$partial" "$url" || die "ダウンロードに失敗しました。再実行で再開できます: $partial"
    [ -s "$partial" ] || die "空ファイルが取得されました: $partial"
    size="$(stat -c %s "$partial")"
    [ "$size" -ge "$min_bytes" ] || die "取得サイズが小さすぎます: $partial ($size bytes)"
    if [ "$VERIFY_SHA256" = 1 ]; then
        log "取得したファイルの SHA-256 を確認: $(basename "$dest")"
        got_sha="$(sha256sum "$partial" | awk '{print $1}')"
        [ "$got_sha" = "$expected_sha" ] || die "SHA-256 不一致: $partial"
    fi
    mv -n -- "$partial" "$dest"
}

DIFFUSION_PATH="$COMFY_DIR/models/diffusion_models/$DIFFUSION_FILE"
TEXT_ENCODER_PATH="$COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
VAE_PATH="$COMFY_DIR/models/vae/$VAE_FILE"
LORA_PATH="$COMFY_DIR/models/loras/$LORA_FILE"
WORKFLOW_PATH="$COMFY_DIR/user/default/workflows/$WORKFLOW_FILE"

# Do not download the optional Qwen 3.5 Prompt Enhancer: one image + one prompt only.
fetch_model "$HF_BASE/diffusion_models/$DIFFUSION_FILE" "$DIFFUSION_PATH" "$DIFFUSION_SHA256" 5000000000
fetch_model "$HF_BASE/text_encoders/$TEXT_ENCODER_FILE" "$TEXT_ENCODER_PATH" "$TEXT_ENCODER_SHA256" 7000000000
fetch_model "$HF_BASE/vae/$VAE_FILE" "$VAE_PATH" "$VAE_SHA256" 400000000
fetch_model "$HF_LORA/$LORA_SOURCE_FILE" "$LORA_PATH" "$LORA_SHA256" 40000000

mkdir -p "$(dirname "$WORKFLOW_PATH")" "$COMFY_DIR/input" "$COMFY_DIR/output"
cp -- "$MODEL_DIR/workflows/$WORKFLOW_FILE" "${WORKFLOW_PATH}.tmp"
mv -f -- "${WORKFLOW_PATH}.tmp" "$WORKFLOW_PATH"
log "1画像入力の Lightning workflow を配置: $WORKFLOW_PATH"

# Salad's select_model.sh expects a running ComfyUI PID in /workspace/comfyui.pid.
# Keep the instance-local restart behavior consistent with the other model scripts.
log 'ComfyUI を再起動'
if pgrep -f 'python.*main.py' >/dev/null 2>&1; then
    pkill -f 'python.*main.py' || true
    sleep 2
fi
cd "$COMFY_DIR"
nohup "$PYTHON" main.py --listen 127.0.0.1 --port "$COMFY_PORT" > "$COMFY_LOG" 2>&1 &
COMFY_PID=$!
echo "$COMFY_PID" > "$WORKSPACE/comfyui.pid"

log 'ComfyUI API を確認'
ready=0
for _ in $(seq 1 90); do
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        tail -n 100 "$COMFY_LOG" || true
        die 'ComfyUI が起動中に終了しました。'
    fi
    if "$PYTHON" - "$COMFY_PORT" <<'PY' >/dev/null 2>&1
import sys
import urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2).read(1)
PY
    then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" -eq 1 ] || { tail -n 100 "$COMFY_LOG" || true; die 'ComfyUI API が応答しません。'; }

cat <<EOF2

============================================================
 SETUP COMPLETE: $MODEL_NAME
============================================================
ComfyUI  : http://127.0.0.1:$COMFY_PORT
Diffusion: $DIFFUSION_PATH
Text     : $TEXT_ENCODER_PATH
VAE      : $VAE_PATH
Lightning: $LORA_PATH
Workflow : $WORKFLOW_PATH

操作:
  1. ComfyUIを開き、上記のworkflowを読み込む。
  2. Load Image に編集元画像を指定する。
  3. TextEncodeQwenImage21 に英語プロンプトを入力する。
  4. 実行する。ManualSigmas に 4step の推奨値を設定済み。
ログ: tail -n 100 "$COMFY_LOG"
============================================================
EOF2
