#!/usr/bin/env bash
set -Eeuo pipefail

# Qwen3-VL-8B-Instruct image-to-text setup for Vast.ai and SaladCloud.
# Install target: /workspace/qwen_vast_sh/models/qwen3-vl-8b-instruct/setup.sh
# It preserves existing ComfyUI installations, other models and workflows.

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="${COMFY_DIR:-$WORKSPACE/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_LOG="${COMFY_LOG:-$WORKSPACE/comfyui.log}"
PID_FILE="$WORKSPACE/comfyui.pid"

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_COMMIT="ba994879b88d0ebd9950b1e5c1e923d928f216ba"
NODE_REPO="https://github.com/1038lab/ComfyUI-QwenVL.git"
NODE_COMMIT="1b67b443918801f571714bab636edc1845b7002a"
NODE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-QwenVL"

MODEL_ID="Qwen/Qwen3-VL-8B-Instruct"
MODEL_NAME="Qwen3-VL-8B-Instruct"
MODEL_PATH="$COMFY_DIR/models/LLM/Qwen-VL/$MODEL_NAME"
MODEL_REVISION="${MODEL_REVISION:-main}"
WORKFLOW_PATH="$COMFY_DIR/user/default/workflows/Qwen3-VL-8B-Pose-Analysis.json"

log() { printf '\n[%s] %s\n' "$(TZ=Asia/Tokyo date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

# Use the existing venv. Do not create a second PyTorch installation.
install_pip() {
    if command -v uv >/dev/null 2>&1; then
        uv pip install --python "$PYTHON" "$@"
    elif [ -x "$WORKSPACE/bin/uv" ]; then
        "$WORKSPACE/bin/uv" pip install --python "$PYTHON" "$@"
    elif "$PYTHON" -m pip --version >/dev/null 2>&1; then
        "$PYTHON" -m pip install "$@"
    else
        die "uv または pip が見つかりません。Vast PyTorch/SaladCloud共通環境を使用してください。"
    fi
}

# Install a deterministic version of a Git repository without modifying an existing checkout.
ensure_git_checkout() {
    local url="$1" target="$2" sha="$3"
    if [ -d "$target/.git" ]; then
        [ -f "$target/requirements.txt" ] || die "既存Git checkoutが不完全です: $target"
        log "既存のGit checkoutを使用: $target"
        return
    fi
    [ ! -e "$target" ] || die "Git管理外の既存ディレクトリがあります: $target"
    mkdir -p "$(dirname "$target")"
    log "Gitコミットを取得: $url @ $sha"
    git init -q "$target"
    git -C "$target" remote add origin "$url"
    git -C "$target" fetch --progress --depth 1 origin "$sha"
    git -C "$target" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$target" rev-parse HEAD)" = "$sha" ] || die "Git commitの検証に失敗しました: $target"
}

api_ready() {
    "$PYTHON" - "$COMFY_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/system_stats', timeout=2).read(1)
PY
}

node_ready() {
    "$PYTHON" - "$COMFY_PORT" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
with urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[1]}/object_info/AILab_QwenVL', timeout=4) as r:
    data = json.load(r)
assert 'AILab_QwenVL' in data
PY
}

stop_existing_comfy() {
    if ! api_ready; then
        return
    fi
    if [ ! -s "$PID_FILE" ]; then
        die "8188でComfyUIが稼働中ですがPIDファイルがありません。誤停止を防ぐため手動で停止してから再実行してください。"
    fi
    local pid command_line
    read -r pid < "$PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || die "PIDファイルが不正です: $PID_FILE"
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$command_line" == *main.py* ]] || die "PID $pid はComfyUIではありません。手動停止後に再実行してください。"
    log "既存のComfyUIを停止: $pid"
    kill "$pid"
    for _ in $(seq 1 40); do
        if ! api_ready; then return; fi
        sleep 1
    done
    die "既存のComfyUIが停止しませんでした。ログを確認してください。"
}

need git
need nvidia-smi
need df
[ -x "$PYTHON" ] || die "$PYTHON が存在しません。Vast.ai PyTorchテンプレートまたはSaladCloud共通環境が必要です。"
mkdir -p "$WORKSPACE"

log "GPU・ストレージの確認"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
df -h "$WORKSPACE"

TORCH_BEFORE="$("$PYTHON" -c 'import torch; print(torch.__version__)')"

log "ComfyUIを準備"
if [ -f "$COMFY_DIR/main.py" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
    log "既存ComfyUIを保持: $COMFY_DIR"
else
    if [ -e "$COMFY_DIR" ]; then
        die "既存ComfyUIが不完全です。安全のため削除・再作成しません: $COMFY_DIR"
    fi
    ensure_git_checkout "$COMFY_REPO" "$COMFY_DIR" "$COMFY_COMMIT"
    log "ComfyUI依存パッケージをインストール"
    install_pip -r "$COMFY_DIR/requirements.txt"
fi

log "ComfyUI-QwenVLを導入"
ensure_git_checkout "$NODE_REPO" "$NODE_DIR" "$NODE_COMMIT"
[ -s "$NODE_DIR/__init__.py" ] || die "ComfyUI-QwenVLの初期化ファイルがありません。"

# Pin Transformers 4.x for stable Qwen3-VL and compatibility with this node.
# Avoid installing a second torch build; check the installed build afterwards.
log "Qwen3-VL用ライブラリを導入。既存PyTorchは保持"
install_pip \
    'transformers==4.57.6' \
    'huggingface-hub>=0.34,<1.0' \
    'accelerate>=1.0,<2.0' \
    'hf_xet' \
    'psutil' \
    'bitsandbytes' \
    'opencv-python' \
    'Pillow' \
    'numpy'
TORCH_AFTER="$("$PYTHON" -c 'import torch; print(torch.__version__)')"
[ "$TORCH_BEFORE" = "$TORCH_AFTER" ] || die "PyTorchが変更されました: $TORCH_BEFORE -> $TORCH_AFTER。依存環境を確認してください。"
"$PYTHON" - <<'PY'
from transformers import AutoModelForImageTextToText, AutoProcessor
from huggingface_hub import snapshot_download
print('Qwen3-VL Python imports: OK')
PY

log "Qwen3-VL-8B-Instruct公式モデルを取得（約17.5GB）"
mkdir -p "$MODEL_PATH" "$COMFY_DIR/input" "$COMFY_DIR/output" "$(dirname "$WORKFLOW_PATH")"
QWEN_MODEL_ID="$MODEL_ID" QWEN_MODEL_PATH="$MODEL_PATH" QWEN_MODEL_REVISION="$MODEL_REVISION" "$PYTHON" - <<'PY'
import os
from pathlib import Path
from huggingface_hub import snapshot_download
path = Path(os.environ['QWEN_MODEL_PATH'])
snapshot_download(
    repo_id=os.environ['QWEN_MODEL_ID'],
    revision=os.environ['QWEN_MODEL_REVISION'],
    local_dir=str(path),
    ignore_patterns=['*.md', '.gitattributes'],
    max_workers=4,
)
if not (path / 'config.json').is_file() or not list(path.glob('*.safetensors')):
    raise SystemExit(f'Model download is incomplete: {path}')
print(f'Model downloaded to: {path}')
PY

# Self-contained GUI workflow: LoadImage -> QwenVL -> PreviewAny.
# The custom prompt describes the *reference pose*, not the identity of the person.
log "画像解析workflowを配置"
WORKFLOW_PATH="$WORKFLOW_PATH" MODEL_NAME="$MODEL_NAME" "$PYTHON" - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ['WORKFLOW_PATH'])
model = os.environ['MODEL_NAME']
prompt = (
    'Analyze the reference image for a pose-transfer editing task. '
    'Write an English description of the body pose, torso orientation, head direction, '
    'each arm and leg position, relative depth and overlaps, camera elevation, '
    'viewing direction, perspective, framing, and all physical contact/support points. '
    'Distinguish image-left/image-right from anatomical left/right. '
    'Describe any floor or furniture needed to physically support the pose. '
    'Do not copy the reference subject identity, face, clothing, or art style. '
    'Do not invent locations of hidden limbs; state uncertainty where needed. '
    'Output only the pose-and-camera editing instructions in English.'
)
workflow = {
    'last_node_id': 3, 'last_link_id': 2,
    'nodes': [
        {
            'id': 1, 'type': 'LoadImage', 'pos': [0, 100], 'size': [310, 340],
            'flags': {}, 'order': 0, 'mode': 0, 'inputs': [],
            'outputs': [
                {'name': 'IMAGE', 'type': 'IMAGE', 'links': [1], 'slot_index': 0},
                {'name': 'MASK', 'type': 'MASK', 'links': None, 'slot_index': 1}
            ],
            'properties': {'Node name for S&R': 'LoadImage'},
            'widgets_values': ['example.png', 'image'],
        },
        {
            'id': 2, 'type': 'AILab_QwenVL', 'pos': [370, 100], 'size': [450, 360],
            'flags': {}, 'order': 1, 'mode': 0,
            'inputs': [
                {'name': 'image', 'type': 'IMAGE', 'link': 1, 'shape': 7},
                {'name': 'video', 'type': 'IMAGE', 'link': None, 'shape': 7},
            ],
            'outputs': [{'name': 'RESPONSE', 'type': 'STRING', 'links': [2], 'slot_index': 0}],
            'properties': {'Node name for S&R': 'AILab_QwenVL'},
            'widgets_values': [model, 'None (FP16)', 'sdpa', '🖼️ Detailed Description', prompt, 1024, False, 1, 'fixed'],
        },
        {
            'id': 3, 'type': 'PreviewAny', 'pos': [880, 100], 'size': [600, 360],
            'flags': {}, 'order': 2, 'mode': 0,
            'inputs': [{'name': 'source', 'type': '*', 'link': 2}],
            'outputs': [],
            'properties': {'Node name for S&R': 'PreviewAny'},
            'widgets_values': [None, None, False],
        },
    ],
    'links': [[1, 1, 0, 2, 0, 'IMAGE'], [2, 2, 0, 3, 0, 'STRING']],
    'groups': [], 'config': {}, 'extra': {}, 'version': 0.4,
}
tmp = out.with_suffix(out.suffix + '.tmp')
tmp.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
tmp.replace(out)
print(out)
PY

if api_ready && node_ready && [ -s "$PID_FILE" ]; then
    log "ComfyUIは稼働中でQwenVLノードも認識済み。再起動を省略"
else
    stop_existing_comfy
    log "ComfyUIをlocalhostで起動"
    cd "$COMFY_DIR"
    nohup "$PYTHON" main.py --listen 127.0.0.1 --port "$COMFY_PORT" > "$COMFY_LOG" 2>&1 &
    echo "$!" > "$PID_FILE"
    READY=0
    for _ in $(seq 1 90); do
        if api_ready; then READY=1; break; fi
        if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            tail -n 80 "$COMFY_LOG" || true
            die "ComfyUI起動中に終了しました。"
        fi
        sleep 2
    done
    [ "$READY" = 1 ] || { tail -n 80 "$COMFY_LOG" || true; die "ComfyUI APIが起動しません。"; }
fi
node_ready || { tail -n 80 "$COMFY_LOG" || true; die "AILab_QwenVLノードが読み込まれていません。"; }

printf '\n============================================================\n'
printf ' QWEN3-VL SETUP COMPLETE\n'
printf '============================================================\n'
printf 'Model: %s\n' "$MODEL_PATH"
printf 'Node: %s\n' "$NODE_DIR"
printf 'Workflow: %s\n' "$WORKFLOW_PATH"
printf 'ComfyUI: http://127.0.0.1:%s (localhost only)\n' "$COMFY_PORT"
printf 'Log: %s\n' "$COMFY_LOG"
printf 'ComfyUIでワークフローを開き、LoadImageに参考画像を設定してQueueする。\n'
printf '============================================================\n'
