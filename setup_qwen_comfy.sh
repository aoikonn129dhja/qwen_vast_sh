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

COMFYUI_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFYUI_COMMIT="15eb748b3ec5f8a0a2d470b7fb280e2d7579f916"
DEPENDENCY_LOCK="$SCRIPT_DIR/requirements.lock"
COMFY_CLI_VERSION="1.20.0"

UV_VERSION="0.11.28"
UV_ARCHIVE_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
UV_ARCHIVE_SHA256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_BIN_SHA256="1cb9cd0a1749debf6049d7d2bb933882cc52d81016326ee6d99a786d6c988b03"
UV="$WORKSPACE/bin/uv"

MODEL_FILE="Qwen-Rapid-AIO-NSFW-v19.safetensors"
MODEL_REPO_COMMIT="691024f438640508f8aa86414863fc15edfb8a84"
MODEL_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/$MODEL_REPO_COMMIT/v19/Qwen-Rapid-AIO-NSFW-v19.safetensors"
MODEL_SHA256="ba71575515709c9912560d1176b2386eaa49294fedc6ce57b9734aa57e91e5ac"

QWEN_NODE_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/$MODEL_REPO_COMMIT/fixed-textencode-node/nodes_qwen.v2.py"
QWEN_NODE_SHA256="9df96288f466ca03f7d7fa8587ad53c8021b784f42daabdc1f59a61b71c40238"

REPO_WORKFLOW="$SCRIPT_DIR/Qwen-Rapid-AIO-SaveImage.json"
WORKFLOW_FILE="$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-SaveImage.json"
BATCH_ROOT="$WORKSPACE/qwen_batch"

COMFY_LOG="$WORKSPACE/comfyui.log"
CLOUDFLARED="$WORKSPACE/bin/cloudflared"
CLOUDFLARED_VERSION="2026.8.3"
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64"
CLOUDFLARED_SHA256="f29324fe934d1e100617484c78deef803c4dc2cd351d645bbde42e96b4fccc5e"
MODEL_PATH="$COMFY_DIR/models/checkpoints/$MODEL_FILE"
COMFY_CLI="/venv/main/bin/comfy"

# Vast.ai は毎回Destroyしてモデルを再DLする運用なので、実回線速度を事前測定する。
# 10 MiB/s ≒ 84 Mbps。これ未満だと28.4GBのモデルだけで約45分以上かかる。
MIN_DOWNLOAD_MIB_S="${MIN_DOWNLOAD_MIB_S:-10}"
SPEED_TEST_BYTES="${SPEED_TEST_BYTES:-8388608}"   # 8 MiB
ALLOW_SLOW_DOWNLOAD="${ALLOW_SLOW_DOWNLOAD:-0}"

log() {
    printf '\n[%s] %s\n' "$(TZ=Asia/Tokyo date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ]
}

fetch_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local label="$4"
    local temporary="${destination}.download.$$"

    rm -f -- "$temporary"
    wget -q -O "$temporary" "$url" || {
        rm -f -- "$temporary"
        die "$label のダウンロードに失敗しました。"
    }
    if ! verify_sha256 "$temporary" "$expected"; then
        rm -f -- "$temporary"
        die "$label のSHA-256が固定値と一致しません。"
    fi
    mv -f -- "$temporary" "$destination"
}

ensure_large_file_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local label="$4"
    local partial="${destination}.part"

    if [ -s "$destination" ]; then
        log "$label のSHA-256を確認"
        verify_sha256 "$destination" "$expected" \
            || die "$label のSHA-256が固定値と一致しません。破損または差し替えの可能性があります。"
        return 0
    fi

    wget -c -O "$partial" "$url" || die "$label のダウンロードに失敗しました。"
    log "$label のSHA-256を確認"
    if ! verify_sha256 "$partial" "$expected"; then
        rm -f -- "$partial"
        die "$label のSHA-256が固定値と一致しません。"
    fi
    mv -f -- "$partial" "$destination"
}

install_verified_uv() {
    mkdir -p "$WORKSPACE/bin"
    if [ -x "$UV" ] && verify_sha256 "$UV" "$UV_BIN_SHA256"; then
        return 0
    fi

    local archive="$WORKSPACE/bin/uv-$UV_VERSION.tar.gz"
    local extract_dir="$WORKSPACE/bin/.uv-$UV_VERSION-extract.$$"
    fetch_verified "$UV_ARCHIVE_URL" "$archive" "$UV_ARCHIVE_SHA256" "uv $UV_VERSION"
    rm -rf -- "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"
    local extracted="$extract_dir/uv-x86_64-unknown-linux-gnu/uv"
    [ -f "$extracted" ] || die "uvアーカイブ内に実行ファイルがありません。"
    verify_sha256 "$extracted" "$UV_BIN_SHA256" \
        || die "展開したuv実行ファイルのSHA-256が一致しません。"
    install -m 0755 "$extracted" "$UV"
    rm -rf -- "$extract_dir"
    rm -f -- "$archive"
}

command -v git >/dev/null 2>&1 || die "git がありません。"
command -v wget >/dev/null 2>&1 || die "wget がありません。"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum がありません。"
command -v awk >/dev/null 2>&1 || die "awk がありません。"
command -v tar >/dev/null 2>&1 || die "tar がありません。"
command -v install >/dev/null 2>&1 || die "install がありません。"
[ -x "$PYTHON" ] || die "/venv/main/bin/python が見つかりません。PyTorch (Vast) テンプレートか確認してください。"
[ -f "$REPO_WORKFLOW" ] || die "リポジトリ内の workflow が見つかりません: $REPO_WORKFLOW"
[ -f "$DEPENDENCY_LOCK" ] || die "依存ロックファイルが見つかりません: $DEPENDENCY_LOCK"

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
COMFY_CURRENT_COMMIT=""

if [ -d "$COMFY_DIR/.git" ] \
    && [ -f "$COMFY_DIR/requirements.txt" ] \
    && [ -f "$COMFY_DIR/main.py" ] \
    && git -C "$COMFY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    COMFY_CURRENT_COMMIT="$(git -C "$COMFY_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [ "$COMFY_CURRENT_COMMIT" = "$COMFYUI_COMMIT" ]; then
        COMFY_VALID=1
    fi
fi

if [ "$COMFY_VALID" -eq 1 ]; then
    log "固定済みComfyUIコミットを確認: $COMFYUI_COMMIT"
else
    RECOVERED_MODEL="$WORKSPACE/.${MODEL_FILE}.recover"

    if [ -e "$COMFY_DIR" ]; then
        if [ -n "$COMFY_CURRENT_COMMIT" ]; then
            log "ComfyUIを固定コミットへ置き換え: $COMFY_CURRENT_COMMIT -> $COMFYUI_COMMIT"
        else
            log "不完全なComfyUIを検出しました。固定コミットから再構築します。"
        fi

        # checkpointだけ既に取得済みなら再DLを避けるため一時退避。
        if [ -s "$MODEL_PATH" ]; then
            log "既存モデルを一時退避"
            mv "$MODEL_PATH" "$RECOVERED_MODEL"
        fi

        rm -rf "$COMFY_DIR"
    fi

    log "ComfyUI固定コミットを取得: $COMFYUI_COMMIT"
    git init -q "$COMFY_DIR"
    git -C "$COMFY_DIR" remote add origin "$COMFYUI_REPO"
    git -C "$COMFY_DIR" fetch -q --depth 1 origin "$COMFYUI_COMMIT"
    git -C "$COMFY_DIR" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$COMFY_DIR" rev-parse HEAD)" = "$COMFYUI_COMMIT" ] \
        || die "ComfyUIの取得コミットが固定値と一致しません。"

    if [ -s "$RECOVERED_MODEL" ]; then
        log "退避したモデルを復元"
        mkdir -p "$COMFY_DIR/models/checkpoints"
        mv "$RECOVERED_MODEL" "$MODEL_PATH"
    fi
fi

cd "$COMFY_DIR"

log "固定済みuvを準備"
install_verified_uv

log "SHA-256固定済みPython依存をインストール"
"$UV" pip install \
    --python "$PYTHON" \
    --require-hashes \
    --torch-backend cu128 \
    -r "$DEPENDENCY_LOCK"

[ -x "$COMFY_CLI" ] || die "comfy-cli のインストールに失敗しました。"
installed_comfy_cli="$("$PYTHON" -c 'import importlib.metadata; print(importlib.metadata.version("comfy-cli"))')"
[ "$installed_comfy_cli" = "$COMFY_CLI_VERSION" ] \
    || die "comfy-cliのバージョンが固定値と一致しません: $installed_comfy_cli"

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
    log "Qwen Rapid AIO NSFW v19固定版をダウンロード（約28.4GB）"
fi
ensure_large_file_verified "$MODEL_URL" "$MODEL_PATH" "$MODEL_SHA256" "Qwenモデル"

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
fetch_verified "$QWEN_NODE_URL" "$QWEN_NODE" "$QWEN_NODE_SHA256" "nodes_qwen.v2.py"

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
    log "旧ComfyUI公開Tunnelを停止"
    pkill -f "cloudflared tunnel.*8188" || true
    sleep 1
fi
rm -f -- "$WORKSPACE/cloudflared.pid"

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
# cloudflared (authenticated batch preview only; do not expose ComfyUI itself)
# ------------------------------------------------------------
if [ ! -x "$CLOUDFLARED" ] || ! verify_sha256 "$CLOUDFLARED" "$CLOUDFLARED_SHA256"; then
    log "cloudflared $CLOUDFLARED_VERSION 固定版を導入"
    fetch_verified "$CLOUDFLARED_URL" "$CLOUDFLARED" "$CLOUDFLARED_SHA256" "cloudflared"
    chmod 0755 "$CLOUDFLARED"
fi
verify_sha256 "$CLOUDFLARED" "$CLOUDFLARED_SHA256" \
    || die "cloudflaredのSHA-256が固定値と一致しません。"

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
echo "ComfyUI public tunnel: disabled"
echo "生成画像の確認にはrun_batch.shの認証付きPreview URLを使用する。"

echo
echo "ComfyUI log:"
echo "  $COMFY_LOG"
echo
echo "停止:"
echo '  pkill -f "python main.py"'
echo '  pkill -f "cloudflared tunnel"  # 認証付きPreviewのみ停止'
echo
echo "利用終了後は必要な生成画像を回収してVast.aiインスタンスをDestroyする。"
echo "============================================================"
