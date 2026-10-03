#!/usr/bin/env bash
set -Eeuo pipefail

# Shared setup engine for official-base Qwen Image Edit profiles.
# Run a model directory's setup.sh instead of calling this file directly.

ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$ENGINE_DIR/.." && pwd)"
MODEL_CONFIG="${MODEL_CONFIG:-}"

if [ -z "$MODEL_CONFIG" ] || [ ! -f "$MODEL_CONFIG" ]; then
    echo "ERROR: MODEL_CONFIG must point to a model.conf file." >&2
    exit 2
fi

# model.conf is trusted repository code and contains assignments only.
# shellcheck source=/dev/null
source "$MODEL_CONFIG"

: "${MODEL_ID:?MODEL_ID is required}"
: "${MODEL_NAME:?MODEL_NAME is required}"
: "${QWEN_EDIT_VERSION:?QWEN_EDIT_VERSION is required}"
: "${DIFFUSION_FILE:?DIFFUSION_FILE is required}"
: "${DIFFUSION_URL:?DIFFUSION_URL is required}"
: "${DIFFUSION_SHA256:?DIFFUSION_SHA256 is required}"
: "${LORA_FILE:?LORA_FILE is required}"
: "${LORA_URL:?LORA_URL is required}"
: "${LORA_SHA256:?LORA_SHA256 is required}"
: "${WORKFLOW_FILE_NAME:?WORKFLOW_FILE_NAME is required}"
: "${WORKFLOW_URL:?WORKFLOW_URL is required}"
: "${APPROX_TOTAL_BYTES:?APPROX_TOTAL_BYTES is required}"

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_LOG="${COMFY_LOG:-$WORKSPACE/comfyui.log}"
VERIFY_SHA256="${VERIFY_SHA256:-1}"
INSTALL_DWPOSE="${INSTALL_DWPOSE:-1}"
INSTALL_ANIMEPOSE="${INSTALL_ANIMEPOSE:-1}"
MIN_DOWNLOAD_MIB_S="${MIN_DOWNLOAD_MIB_S:-10}"
SPEED_TEST_BYTES="${SPEED_TEST_BYTES:-8388608}"
ALLOW_SLOW_DOWNLOAD="${ALLOW_SLOW_DOWNLOAD:-0}"

UV_VERSION="0.11.28"
UV_ARCHIVE_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
UV_ARCHIVE_SHA256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_BIN_SHA256="1cb9cd0a1749debf6049d7d2bb933882cc52d81016326ee6d99a786d6c988b03"
UV="${UV:-$WORKSPACE/bin/uv}"

TEXT_ENCODER_FILE="qwen_2.5_vl_7b_fp8_scaled.safetensors"
TEXT_ENCODER_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/$TEXT_ENCODER_FILE"
TEXT_ENCODER_SHA256="cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4"

VAE_FILE="qwen_image_vae.safetensors"
VAE_URL="https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/$VAE_FILE"
VAE_SHA256="a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f"

DIFFUSION_PATH="$COMFY_DIR/models/diffusion_models/$DIFFUSION_FILE"
TEXT_ENCODER_PATH="$COMFY_DIR/models/text_encoders/$TEXT_ENCODER_FILE"
VAE_PATH="$COMFY_DIR/models/vae/$VAE_FILE"
LORA_PATH="$COMFY_DIR/models/loras/$LORA_FILE"
WORKFLOW_PATH="$COMFY_DIR/user/default/workflows/$WORKFLOW_FILE_NAME"
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"

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
    need_cmd sha256sum
    local actual
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}

sha256_verify() {
    local path="$1"
    local expected="$2"

    [ "$VERIFY_SHA256" = "1" ] || return 0
    log "SHA-256確認: $(basename "$path")"
    sha256_matches "$path" "$expected" || die "SHA-256が一致しません: $path"
}

install_verified_uv() {
    mkdir -p "$WORKSPACE/bin"
    if [ -x "$UV" ] && sha256_matches "$UV" "$UV_BIN_SHA256"; then
        return 0
    fi

    local archive="$WORKSPACE/bin/uv-$UV_VERSION.tar.gz"
    local extract_dir="$WORKSPACE/bin/.uv-$UV_VERSION-extract.$$"
    rm -f -- "$archive"
    wget -q -O "$archive" "$UV_ARCHIVE_URL" \
        || die "uv $UV_VERSION のダウンロードに失敗しました。"
    sha256_matches "$archive" "$UV_ARCHIVE_SHA256" \
        || die "uvアーカイブのSHA-256が一致しません。"
    rm -rf -- "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"
    local extracted="$extract_dir/uv-x86_64-unknown-linux-gnu/uv"
    [ -f "$extracted" ] || die "uvアーカイブ内に実行ファイルがありません。"
    sha256_matches "$extracted" "$UV_BIN_SHA256" \
        || die "展開したuvのSHA-256が一致しません。"
    install -m 0755 "$extracted" "$UV"
    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
}

download_file() {
    local url="$1"
    local dest="$2"
    local sha="$3"
    local dir name
    dir="$(dirname "$dest")"
    name="$(basename "$dest")"
    mkdir -p "$dir"

    if [ -s "$dest" ]; then
        if [ "$VERIFY_SHA256" = "1" ]; then
            log "既存ファイルを検査: $dest"
            if sha256_matches "$dest" "$sha"; then
                log "既存ファイルは正常。ダウンロードをスキップ: $name"
                return 0
            fi
            log "既存ファイルは未完了または不一致。wget -cで再開を試行: $name"
        else
            log "既存ファイルを使用。SHA確認は無効: $dest"
            return 0
        fi
    else
        log "ダウンロード: $name"
    fi

    # URL末尾と保存ファイル名を同一にして、wget -cのresumeを有効にする。
    (
        cd "$dir"
        wget -c --progress=bar:force:noscroll "$url"
    )

    [ -s "$dest" ] || die "ダウンロード後のファイルが空です: $dest"
    sha256_verify "$dest" "$sha"
}

git_clone_or_update() {
    local url="$1"
    local dest="$2"

    if [ -d "$dest/.git" ]; then
        log "更新: $dest"
        git -C "$dest" pull --ff-only
    elif [ -e "$dest" ]; then
        die "Git管理外の既存パスがあります: $dest"
    else
        log "clone: $url"
        git clone --depth 1 "$url" "$dest"
    fi
}

need_cmd git
need_cmd wget
need_cmd tar
need_cmd install
[ -x "$PYTHON" ] || die "$PYTHON が見つかりません。PyTorch (Vast) テンプレートか確認してください。"
install_verified_uv

log "設定"
echo "Qwen version : $QWEN_EDIT_VERSION"
echo "ComfyUI      : $COMFY_DIR"
echo "Diffusion    : $DIFFUSION_FILE"
echo "Text encoder : $TEXT_ENCODER_FILE"
echo "VAE          : $VAE_FILE"
echo "Lightning    : $LORA_FILE。インストールのみ。初回品質比較ではOFF推奨"
echo "Workflow     : $WORKFLOW_FILE_NAME"
echo "DWPose       : $INSTALL_DWPOSE"
echo "AnimePose    : $INSTALL_ANIMEPOSE"

log "GPU確認"
nvidia-smi || true

log "Disk確認"
df -h "$WORKSPACE" || true

# ------------------------------------------------------------
# Network preflight
# ------------------------------------------------------------
log "回線速度を事前確認。Hugging Faceから最大8 MiBだけ試験DL"

SPEED_RESULT="$(
    MODEL_URL="$DIFFUSION_URL" SPEED_TEST_BYTES="$SPEED_TEST_BYTES" "$PYTHON" - <<'PY'
import os
import time
import urllib.request

url = os.environ["MODEL_URL"]
target = int(os.environ["SPEED_TEST_BYTES"])
req = urllib.request.Request(
    url,
    headers={
        "Range": f"bytes=0-{target - 1}",
        "User-Agent": "vast-qwen-edit-keypoint-setup/1.0",
    },
)

start = time.monotonic()
downloaded = 0
try:
    with urllib.request.urlopen(req, timeout=20) as r:
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
        "$PYTHON" - "$DOWNLOAD_MIB_S" "$APPROX_TOTAL_BYTES" <<'PY'
import sys
speed = max(float(sys.argv[1]), 0.001)
size = int(sys.argv[2])
print(f"{size / (speed * 1024 * 1024) / 60:.1f}")
PY
    )"

    log "実測: ${DOWNLOAD_MIB_S} MiB/s。約 ${DOWNLOAD_MBPS} Mbps"
    echo "モデル一式約31 GBの推定DL時間: 約 ${EST_MINUTES} 分"

    IS_SLOW="$(
        "$PYTHON" - "$DOWNLOAD_MIB_S" "$MIN_DOWNLOAD_MIB_S" <<'PY'
import sys
print(1 if float(sys.argv[1]) < float(sys.argv[2]) else 0)
PY
    )"

    if [ "$IS_SLOW" -eq 1 ] && [ "$ALLOW_SLOW_DOWNLOAD" != "1" ]; then
        echo
        echo "WARNING: Hugging Face実測が ${MIN_DOWNLOAD_MIB_S} MiB/s 未満です。"
        if [ -t 0 ]; then
            read -r -p "このホストで続行しますか。 [y/N]: " ANSWER
            case "$ANSWER" in
                y|Y|yes|YES) ;;
                *) exit 2 ;;
            esac
        else
            die "非対話実行では中止します。続行する場合は ALLOW_SLOW_DOWNLOAD=1 を指定してください。"
        fi
    fi
else
    echo "WARNING: 回線速度測定に失敗しました。速度判定をスキップします: ${SPEED_RESULT#ERROR|}"
fi

# ------------------------------------------------------------
# ComfyUI
# ------------------------------------------------------------
if [ -d "$COMFY_DIR/.git" ] && [ -f "$COMFY_DIR/main.py" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
    log "既存ComfyUIを使用"

    # Older project setup replaced this core file with Phr00t's custom version.
    # For official Qwen-Image-Edit, restore ComfyUI's own core node first.
    if [ -f "$COMFY_DIR/comfy_extras/nodes_qwen.py" ] && ! git -C "$COMFY_DIR" diff --quiet -- comfy_extras/nodes_qwen.py; then
        BACKUP_DIR="$WORKSPACE/qwen_setup_backup/$(date '+%Y%m%d_%H%M%S')"
        mkdir -p "$BACKUP_DIR"
        log "変更済みnodes_qwen.pyをバックアップしてComfyUI標準版へ戻す"
        cp "$COMFY_DIR/comfy_extras/nodes_qwen.py" "$BACKUP_DIR/nodes_qwen.py"
        git -C "$COMFY_DIR" restore --source=HEAD -- comfy_extras/nodes_qwen.py
        echo "backup: $BACKUP_DIR/nodes_qwen.py"
    fi

    if ! git -C "$COMFY_DIR" diff --quiet || ! git -C "$COMFY_DIR" diff --cached --quiet; then
        git -C "$COMFY_DIR" status --short
        die "ComfyUIに上記のtracked変更があります。安全のため自動更新しません。"
    fi

    log "ComfyUIをfast-forward更新"
    git -C "$COMFY_DIR" pull --ff-only
else
    if [ -e "$COMFY_DIR" ]; then
        die "不完全またはGit管理外のComfyUIがあります: $COMFY_DIR"
    fi
    log "ComfyUIをshallow clone"
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
fi

cd "$COMFY_DIR"

log "ComfyUI依存パッケージをインストール"
"$UV" pip install --python "$PYTHON" -r requirements.txt

mkdir -p \
    "$COMFY_DIR/models/diffusion_models" \
    "$COMFY_DIR/models/text_encoders" \
    "$COMFY_DIR/models/vae" \
    "$COMFY_DIR/models/loras" \
    "$COMFY_DIR/input" \
    "$COMFY_DIR/output" \
    "$COMFY_DIR/user/default/workflows" \
    "$CUSTOM_NODES_DIR"

# ------------------------------------------------------------
# Official-base Qwen models for native ComfyUI
# ------------------------------------------------------------
log "Qwen-Image-Editモデルを準備"
download_file "$DIFFUSION_URL" "$DIFFUSION_PATH" "$DIFFUSION_SHA256"
download_file "$TEXT_ENCODER_URL" "$TEXT_ENCODER_PATH" "$TEXT_ENCODER_SHA256"
download_file "$VAE_URL" "$VAE_PATH" "$VAE_SHA256"
download_file "$LORA_URL" "$LORA_PATH" "$LORA_SHA256"

# ------------------------------------------------------------
# Official ComfyUI workflow template
# ------------------------------------------------------------
log "Comfy-Org公式workflow templateを取得"
wget -q -O "$WORKFLOW_PATH.tmp" "$WORKFLOW_URL"
[ -s "$WORKFLOW_PATH.tmp" ] || die "workflow templateの取得に失敗しました。"
mv -f "$WORKFLOW_PATH.tmp" "$WORKFLOW_PATH"

# The official 2511 template points to BF16 by default. For a 32 GB GPU this
# setup downloads fp8mixed instead, so rewrite only that model filename.
if [ -n "${WORKFLOW_REPLACE_FROM:-}" ]; then
    WORKFLOW_REPLACE_FROM="$WORKFLOW_REPLACE_FROM" \
    WORKFLOW_REPLACE_TO="${WORKFLOW_REPLACE_TO:-}" \
    "$PYTHON" - "$WORKFLOW_PATH" <<'PYWF'
from pathlib import Path
import os
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = os.environ["WORKFLOW_REPLACE_FROM"]
new = os.environ["WORKFLOW_REPLACE_TO"]
if old not in s:
    raise SystemExit(f"expected model name not found in workflow: {old}")
p.write_text(s.replace(old, new), encoding="utf-8")
PYWF
fi

# ------------------------------------------------------------
# Pose / keypoint preprocessors
# ------------------------------------------------------------
if [ "$INSTALL_DWPOSE" = "1" ]; then
    DWPOSE_DIR="$CUSTOM_NODES_DIR/comfyui_controlnet_aux"
    git_clone_or_update "https://github.com/Fannovel16/comfyui_controlnet_aux.git" "$DWPOSE_DIR"
    if [ -f "$DWPOSE_DIR/requirements.txt" ]; then
        log "comfyui_controlnet_aux依存をインストール"
        "$UV" pip install --python "$PYTHON" -r "$DWPOSE_DIR/requirements.txt"
    fi
fi

if [ "$INSTALL_ANIMEPOSE" = "1" ]; then
    ANIMEPOSE_DIR="$CUSTOM_NODES_DIR/ComfyUI-AnimePose"
    git_clone_or_update "https://github.com/dalai2/ComfyUI-AnimePose.git" "$ANIMEPOSE_DIR"
    if [ -f "$ANIMEPOSE_DIR/requirements.txt" ]; then
        log "ComfyUI-AnimePose依存をインストール"
        "$UV" pip install --python "$PYTHON" -r "$ANIMEPOSE_DIR/requirements.txt"
    fi
fi

# ------------------------------------------------------------
# Restart ComfyUI
# ------------------------------------------------------------
if pgrep -f "python.*main.py.*--port[ =]?$COMFY_PORT" >/dev/null 2>&1 || pgrep -f "python.*main.py" >/dev/null 2>&1; then
    log "既存ComfyUIを停止"
    pkill -f "python.*main.py" || true
    sleep 2
fi

log "ComfyUIをバックグラウンド起動"
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
        echo "ComfyUIが起動途中で終了しました。ログ:"
        tail -n 100 "$COMFY_LOG" || true
        exit 1
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
    echo "ComfyUIが時間内に応答しませんでした。ログ:"
    tail -n 100 "$COMFY_LOG" || true
    exit 1
fi

COMFY_COMMIT="$(git -C "$COMFY_DIR" rev-parse --short HEAD 2>/dev/null || true)"

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"
echo "Qwen version : $QWEN_EDIT_VERSION"
echo "Comfy commit : $COMFY_COMMIT"
echo "Comfy local  : http://127.0.0.1:$COMFY_PORT"
echo
echo "Diffusion:"
echo "  $DIFFUSION_PATH"
echo "Text encoder:"
echo "  $TEXT_ENCODER_PATH"
echo "VAE:"
echo "  $VAE_PATH"
echo "Lightning LoRA。初回の骨格追従テストではOFF推奨:"
echo "  $LORA_PATH"
echo "Workflow:"
echo "  $WORKFLOW_PATH"
echo
echo "Pose nodes:"
[ "$INSTALL_DWPOSE" = "1" ] && echo "  DWPose: $CUSTOM_NODES_DIR/comfyui_controlnet_aux"
[ "$INSTALL_ANIMEPOSE" = "1" ] && echo "  AnimePose: $CUSTOM_NODES_DIR/ComfyUI-AnimePose"
echo
echo "次の操作:"
echo "  1. Vast.aiのTunnelsから http://localhost:$COMFY_PORT を開く。"
echo "  2. ComfyUIで $WORKFLOW_FILE_NAME を読み込む。"
echo "  3. 人物画像をimage1、DWPose/AnimePoseの骨格IMAGEをimage2へ接続して試す。"
echo
echo "ログ:"
echo "  tail -n 100 $COMFY_LOG"
echo "============================================================"
