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

UV_VERSION="0.11.28"
UV="${UV:-$WORKSPACE/bin/uv}"
UV_ARCHIVE_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
UV_ARCHIVE_SHA256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_BIN_SHA256="1cb9cd0a1749debf6049d7d2bb933882cc52d81016326ee6d99a786d6c988b03"

HF_BASE="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"
}

sha256_matches() {
    local path="$1"
    local expected="$2"
    [ -s "$path" ] || return 1
    [ "$(sha256sum "$path" | awk '{print $1}')" = "$expected" ]
}

install_uv() {
    mkdir -p "$WORKSPACE/bin"
    if [ -x "$UV" ] && sha256_matches "$UV" "$UV_BIN_SHA256"; then
        return 0
    fi

    local archive="$WORKSPACE/bin/uv-$UV_VERSION.tar.gz"
    local extract_dir="$WORKSPACE/bin/.uv-$UV_VERSION-extract.$$"

    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
    wget -q -O "$archive" "$UV_ARCHIVE_URL"
    sha256_matches "$archive" "$UV_ARCHIVE_SHA256" \
        || die "uvアーカイブのSHA-256が一致しません。"

    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"

    local extracted="$extract_dir/uv-x86_64-unknown-linux-gnu/uv"
    [ -f "$extracted" ] || die "uv実行ファイルがアーカイブ内にありません。"
    sha256_matches "$extracted" "$UV_BIN_SHA256" \
        || die "uv実行ファイルのSHA-256が一致しません。"

    install -m 0755 "$extracted" "$UV"
    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
}

git_clone_or_update() {
    local url="$1"
    local dest="$2"

    if [ -d "$dest/.git" ]; then
        if ! git -C "$dest" diff --quiet || ! git -C "$dest" diff --cached --quiet; then
            git -C "$dest" status --short
            die "tracked変更があるため自動更新しません: $dest"
        fi
        log "更新: $dest"
        git -C "$dest" pull --ff-only
    elif [ -e "$dest" ]; then
        die "Git管理外の既存パスがあります: $dest"
    else
        log "clone: $url"
        git clone --depth 1 "$url" "$dest"
    fi
}

preflight_file() {
    local rel="$1"
    log "存在確認: $rel"
    wget --spider -q "$HF_BASE/$rel" \
        || die "Hugging Face上でファイルを確認できません: $HF_BASE/$rel"
}

download_file() {
    local rel="$1"
    local dest="$2"
    local dir

    dir="$(dirname "$dest")"
    mkdir -p "$dir"

    if [ -s "$dest" ]; then
        log "既存ファイルを使用: $dest"
        return 0
    fi

    log "ダウンロード: $(basename "$dest")"
    (
        cd "$dir"
        wget -c --progress=bar:force:noscroll "$HF_BASE/$rel"
    )

    [ -s "$dest" ] || die "ダウンロード後のファイルが空です: $dest"
}

need_cmd git
need_cmd wget
need_cmd tar
need_cmd install
need_cmd sha256sum
[ -x "$PYTHON" ] || die "$PYTHON が見つかりません。Vast.aiのPyTorch系テンプレートを確認してください。"

install_uv

log "ComfyUIを準備"
if [ -d "$COMFY_DIR/.git" ] && [ -f "$COMFY_DIR/main.py" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
    if ! git -C "$COMFY_DIR" diff --quiet || ! git -C "$COMFY_DIR" diff --cached --quiet; then
        git -C "$COMFY_DIR" status --short
        die "ComfyUIにtracked変更があるため自動更新しません。"
    fi
    git -C "$COMFY_DIR" pull --ff-only
elif [ -e "$COMFY_DIR" ]; then
    die "不完全またはGit管理外のComfyUIがあります: $COMFY_DIR"
else
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi

"$UV" pip install --python "$PYTHON" -r "$COMFY_DIR/requirements.txt"

log "CCTech GGUF Loaderを準備"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"
GGUF_LOADER_DIR="$CUSTOM_NODES_DIR/ComfyUI-GGUF-Loader"
mkdir -p "$CUSTOM_NODES_DIR"
git_clone_or_update "$GGUF_LOADER_REPO" "$GGUF_LOADER_DIR"
if [ -f "$GGUF_LOADER_DIR/requirements.txt" ]; then
    "$UV" pip install --python "$PYTHON" -r "$GGUF_LOADER_DIR/requirements.txt"
fi
"$UV" pip install --python "$PYTHON" opencv-python-headless

log "LTX-2.3 v1.4 Q4_K_M一式を配置"
DIFFUSION_DIR="$COMFY_DIR/models/diffusion_models"
TEXT_ENCODERS_DIR="$COMFY_DIR/models/text_encoders"
VAE_DIR="$COMFY_DIR/models/vae"

# 配布元のファイル構成変更を、数十GBのダウンロード開始前に検出する。
preflight_file "$TRANSFORMER_REL"
preflight_file "$TEXT_ENCODER_REL"
preflight_file "$PROJECTIONS_REL"
preflight_file "$VIDEO_VAE_REL"
preflight_file "$AUDIO_VAE_REL"

download_file "$TRANSFORMER_REL" "$DIFFUSION_DIR/$TRANSFORMER_FILE"
download_file "$TEXT_ENCODER_REL" "$TEXT_ENCODERS_DIR/$TEXT_ENCODER_FILE"
download_file "$PROJECTIONS_REL" "$TEXT_ENCODERS_DIR/$PROJECTIONS_FILE"
download_file "$VIDEO_VAE_REL" "$VAE_DIR/$VIDEO_VAE_FILE"
download_file "$AUDIO_VAE_REL" "$VAE_DIR/$AUDIO_VAE_FILE"

log "ComfyUIを再起動"
if pgrep -f "python.*main.py" >/dev/null 2>&1; then
    pkill -f "python.*main.py" || true
    sleep 2
fi

cd "$COMFY_DIR"
nohup "$PYTHON" main.py \
    --listen 127.0.0.1 \
    --port "$COMFY_PORT" \
    > "$COMFY_LOG" 2>&1 &

COMFY_PID=$!
echo "$COMFY_PID" > "$WORKSPACE/comfyui.pid"

log "ComfyUI API起動待ち"
READY=0
for _ in $(seq 1 90); do
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        tail -n 100 "$COMFY_LOG" || true
        die "ComfyUIが起動途中で終了しました。"
    fi

    if "$PYTHON" - <<PY >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:${COMFY_PORT}/system_stats", timeout=1).read(1)
PY
    then
        READY=1
        break
    fi
    sleep 2
done

if [ "$READY" -ne 1 ]; then
    tail -n 100 "$COMFY_LOG" || true
    die "ComfyUIが時間内に応答しませんでした。"
fi

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"
echo "Model       : $MODEL_NAME"
echo "ComfyUI     : http://127.0.0.1:$COMFY_PORT"
echo "Transformer : $DIFFUSION_DIR/$TRANSFORMER_FILE"
echo "TextEncoder : $TEXT_ENCODERS_DIR/$TEXT_ENCODER_FILE"
echo "Projection  : $TEXT_ENCODERS_DIR/$PROJECTIONS_FILE"
echo "Video VAE   : $VAE_DIR/$VIDEO_VAE_FILE"
echo "Audio VAE   : $VAE_DIR/$AUDIO_VAE_FILE"
echo
echo "CCTech nodes:"
echo "  $GGUF_LOADER_DIR"
echo
echo "ログ:"
echo "  tail -n 100 $COMFY_LOG"
echo "============================================================"
