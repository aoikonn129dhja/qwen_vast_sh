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
GGUF_NODE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-GGUF"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

need git
need wget
need sha256sum
need df
[ -x "$PYTHON" ] || die "$PYTHON がありません。Vast.ai PyTorch (Vast) テンプレートを使用してください。"
mkdir -p "$WORKSPACE"

log 'GPUとディスクを確認'
nvidia-smi || die 'NVIDIA GPUを検出できません。'
df -h "$WORKSPACE"
FREE_KB="$(df -Pk "$WORKSPACE" | awk 'NR==2 {print $4}')"
[ "$FREE_KB" -ge 25000000 ] || die '空きディスクが25GB未満です。追加ファイルを配置する余裕がありません。'

log 'ComfyUIを準備（既存インストールは変更しない）'
if [ -f "$COMFY_DIR/main.py" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
    log '既存のComfyUIを使用'
elif [ -e "$COMFY_DIR" ]; then
    die "既存のComfyUIディレクトリが不完全です: $COMFY_DIR"
else
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi

log 'ComfyUI依存を導入'
"$PYTHON" -m pip install -r "$COMFY_DIR/requirements.txt"

log 'GGUFノードを準備'
mkdir -p "$COMFY_DIR/custom_nodes"
if [ -d "$GGUF_NODE_DIR/.git" ]; then
    if ! git -C "$GGUF_NODE_DIR" diff --quiet || ! git -C "$GGUF_NODE_DIR" diff --cached --quiet; then
        die 'GGUFノードにtracked変更があるため、上書きしません。'
    fi
    git -C "$GGUF_NODE_DIR" pull --ff-only
elif [ -e "$GGUF_NODE_DIR" ]; then
    die "同名のGit管理外ノードが存在します: $GGUF_NODE_DIR"
else
    git clone --depth 1 "$GGUF_NODE_REPO" "$GGUF_NODE_DIR"
fi
if [ -f "$GGUF_NODE_DIR/requirements.txt" ]; then
    "$PYTHON" -m pip install -r "$GGUF_NODE_DIR/requirements.txt"
fi

# 固定コミットと既知のSHA-256でモデルを検証する。
# ハッシュはsalad/models/qwen-image-21-uncensored-gguf/prepare_models.shと共通。
fetch_model() {
    local relative="$1" dest="$2" pinned="${3:-}" url expected actual
    local revision="6b34e59458d3eb7ba6a6f86a116aed5253dc02c3"

    url="https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/$revision/$relative"
    case "$relative" in
        "$GGUF_REL")
            expected="e79c8a009f2ecbdb6c70fd663d9aea9ee304a0d91f347e4169a756b8ad141b41" ;;
        "$TEXT_ENCODER_REL")
            expected="8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f" ;;
        "$VAE_REL")
            expected="bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9" ;;
        *) die "未登録のモデル: $relative" ;;
    esac

    if [ -n "$pinned" ] && [ "$expected" != "$pinned" ]; then
        die "固定SHA-256が設定と一致しません: $relative"
    fi
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ]; then
        actual="$(sha256sum "$dest" | awk '{print $1}')"
        if [ "$actual" = "$expected" ]; then
            log "検証済み、スキップ: $(basename "$dest")"
            return 0
        fi
        die "既存ファイルのSHA-256が不一致です。削除せず中止: $dest"
    fi
    log "ダウンロード: $(basename "$dest")"
    wget --https-only --tries=3 --timeout=60 -c --progress=bar:force:noscroll -O "${dest}.part" "$url" \
        || die "ダウンロード失敗。再実行すればpartから再開: $relative"
    actual="$(sha256sum "${dest}.part" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || die "SHA-256が不一致です: ${dest}.part"
    mv -n -- "${dest}.part" "$dest"
}

log 'モデル3ファイルを配置'
fetch_model "$GGUF_REL" "$COMFY_DIR/models/diffusion_models/$GGUF_FILE" "$GGUF_SHA256"
fetch_model "$TEXT_ENCODER_REL" "$COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
fetch_model "$VAE_REL" "$COMFY_DIR/models/vae/$VAE_FILE"

log 'ComfyUIを起動、または既存プロセスを確認'
if "$PYTHON" - "$COMFY_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2)
PY
then
    if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui 2>/dev/null | grep -q 'RUNNING'; then
        log 'SupervisorでComfyUIを再起動'
        supervisorctl restart comfyui
    else
        log 'ComfyUIは既に起動中。ノードを反映するにはVast.aiの管理画面からComfyUIを再起動してください。'
    fi
else
    cd "$COMFY_DIR"
    nohup "$PYTHON" main.py --listen 127.0.0.1 --port "$COMFY_PORT" >"$COMFY_LOG" 2>&1 &
    COMFY_PID=$!
    echo "$COMFY_PID" > "$WORKSPACE/comfyui.pid"
    READY=0
    for _ in $(seq 1 90); do
        if ! kill -0 "$COMFY_PID" 2>/dev/null; then
            tail -n 80 "$COMFY_LOG" || true
            die 'ComfyUI起動に失敗しました。'
        fi
        if "$PYTHON" - "$COMFY_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2)
PY
        then
            READY=1
            break
        fi
        sleep 2
    done
    [ "$READY" -eq 1 ] || { tail -n 80 "$COMFY_LOG" || true; die 'ComfyUI APIが応答しません。'; }
fi

cat <<EOF2

============================================================
 SETUP COMPLETE: $MODEL_NAME
============================================================
ComfyUI : http://127.0.0.1:$COMFY_PORT
GGUF    : $COMFY_DIR/models/diffusion_models/$GGUF_FILE
Encoder : $COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE
VAE     : $COMFY_DIR/models/vae/$VAE_FILE
Node    : $GGUF_NODE_DIR
Log     : $COMFY_LOG

Vast.aiのTunnelsからComfyUIのポートを開いてください。
ComfyUIでUnet Loader (GGUF)、CLIPLoader、VAELoaderを使用します。
============================================================
EOF2
