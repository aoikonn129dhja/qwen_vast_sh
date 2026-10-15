#!/usr/bin/env bash
set -Eeuo pipefail

# Qwen3-VL-8B-Instruct image-to-text setup for Vast.ai and SaladCloud.
# Install target: /workspace/qwen_vast_sh/models/qwen3-vl-8b-instruct/setup.sh
# It preserves existing ComfyUI installations, other models and workflows.

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
runtime_prepare "qwen3-vl-8b-instruct"
COMFY_PORT=18308
PID_FILE="$RUNTIME_PID_FILE"

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_COMMIT="ba994879b88d0ebd9950b1e5c1e923d928f216ba"
NODE_REPO="https://github.com/1038lab/ComfyUI-QwenVL.git"
NODE_COMMIT="1b67b443918801f571714bab636edc1845b7002a"
NODE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-QwenVL"

MODEL_ID="Qwen/Qwen3-VL-8B-Instruct"
MODEL_NAME="Qwen3-VL-8B-Instruct"
MODEL_PATH="$SHARED_COMFY_DIR/models/LLM/Qwen-VL/$MODEL_NAME"
MODEL_REVISION="${MODEL_REVISION:-0c351dd01ed87e9c1b53cbc748cba10e6187ff3b}"
WORKFLOW_PATH="$SHARED_COMFY_DIR/user/default/workflows/Qwen3-VL-8B-Pose-Analysis.json"

# Measure the actual Hugging Face route before downloading ComfyUI or the model.
MIN_DOWNLOAD_MIB_S="${MIN_DOWNLOAD_MIB_S:-10}"
SPEED_TEST_BYTES="${SPEED_TEST_BYTES:-8388608}"
ALLOW_SLOW_DOWNLOAD="${ALLOW_SLOW_DOWNLOAD:-0}"

log() { printf '\n[%s] %s\n' "$(TZ=Asia/Tokyo date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。"; }

check_download_speed() {
    local result speed mbps elapsed bytes minutes is_slow answer
    log "回線速度を事前確認（Hugging Faceから最大8MiBだけ試験DL）"
    result="$(MODEL_ID="$MODEL_ID" MODEL_REVISION="$MODEL_REVISION" SPEED_TEST_BYTES="$SPEED_TEST_BYTES" "$PYTHON" - <<'PY'
import os
import time
import urllib.parse
import urllib.request

revision = urllib.parse.quote(os.environ['MODEL_REVISION'], safe='')
url = f"https://huggingface.co/{os.environ['MODEL_ID']}/resolve/{revision}/model-00001-of-00004.safetensors"
target = int(os.environ['SPEED_TEST_BYTES'])
if target <= 0:
    print('ERROR|SPEED_TEST_BYTES must be positive')
    raise SystemExit(0)
request = urllib.request.Request(url, headers={
    'Range': f'bytes=0-{target - 1}',
    'User-Agent': 'vast-qwen3-vl-setup-speed-test/1.0',
})
start = time.monotonic()
downloaded = 0
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        while downloaded < target and time.monotonic() - start < 20:
            chunk = response.read(min(1024 * 1024, target - downloaded))
            if not chunk:
                break
            downloaded += len(chunk)
except Exception as exc:
    print(f'ERROR|{type(exc).__name__}: {exc}')
    raise SystemExit(0)
if downloaded == 0:
    print('ERROR|No data received')
else:
    elapsed = max(time.monotonic() - start, 0.001)
    speed = downloaded / 1024 / 1024 / elapsed
    print(f'OK|{speed:.2f}|{speed * 8.388608:.1f}|{elapsed:.2f}|{downloaded}')
PY
)"
    if [[ "$result" != OK\|* ]]; then
        printf 'WARNING: 回線速度の事前測定に失敗しました: %s\n' "${result#ERROR|}"
        printf '速度判定をスキップして続行します。\n'
        return
    fi

    IFS='|' read -r _ speed mbps elapsed bytes <<< "$result"
    minutes="$("$PYTHON" - "$speed" <<'PY'
import sys
print(f'{17_500_000_000 / (max(float(sys.argv[1]), 0.001) * 1024 * 1024) / 60:.1f}')
PY
)"
    log "実測: ${speed} MiB/s（約 ${mbps} Mbps、${bytes} bytes / ${elapsed} 秒）"
    printf '約17.5GBモデルの推定DL時間: 約 %s 分\n' "$minutes"
    is_slow="$("$PYTHON" - "$speed" "$MIN_DOWNLOAD_MIB_S" <<'PY'
import sys
print(1 if float(sys.argv[1]) < float(sys.argv[2]) else 0)
PY
)"
    if [ "$is_slow" -eq 0 ]; then return; fi

    printf 'WARNING: このホストの実回線速度は遅いです。モデルDL推定: 約 %s 分\n' "$minutes"
    printf '目安: 20 MiB/s以上を推奨、10 MiB/s未満なら別ホストを推奨します。\n'
    if [ "$ALLOW_SLOW_DOWNLOAD" = 1 ]; then return; fi
    if [ ! -t 0 ]; then
        die "非対話実行のため中止します。続行する場合は ALLOW_SLOW_DOWNLOAD=1 を指定してください。"
    fi
    read -r -p 'それでもこのホストで続行しますか？ [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) die "セットアップを中止しました。" ;;
    esac
}

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
    local url="$1" target="$2" sha="$3" marker="$4"
    if [ -f "$target/$marker" ] && [ -d "$target/.git" ]; then
        [ "$(git -C "$target" rev-parse HEAD)" = "$sha" ] || die "Git checkout commit differs: $target"
        log "既存のGit checkoutを使用: $target"
        return
    fi
    if [ -d "$target/.git" ]; then
        [ "$(git -C "$target" remote get-url origin 2>/dev/null || true)" = "$url" ] \
            || die "取得途中のGit checkoutのリモートが異なります: $target"
        log "取得途中のGit checkoutを再開: $target"
    else
        [ ! -e "$target" ] || die "Git管理外の既存ディレクトリがあります: $target"
        mkdir -p "$(dirname "$target")"
        git init -q "$target"
        git -C "$target" remote add origin "$url"
    fi
    log "Gitコミットを取得: $url @ $sha"
    git -C "$target" fetch --progress --depth 1 origin "$sha"
    git -C "$target" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$target" rev-parse HEAD)" = "$sha" ] || die "Git commitの検証に失敗しました: $target"
    [ -f "$target/$marker" ] || die "取得したGit checkoutが不完全です: $target"
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


need git
need nvidia-smi
need df
[ -x "$PYTHON" ] || die "$PYTHON が存在しません。Vast.ai PyTorchテンプレートまたはSaladCloud共通環境が必要です。"
mkdir -p "$WORKSPACE"

log "GPU・ストレージの確認"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
df -h "$WORKSPACE"

check_download_speed

log "ComfyUIを準備"
if [ -f "$COMFY_DIR/main.py" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
    [ "$(git -C "$COMFY_DIR" rev-parse HEAD 2>/dev/null || true)" = "$COMFY_COMMIT" ] || die "専用ComfyUIコミットが異なります: $COMFY_DIR"
    log "既存ComfyUIを保持: $COMFY_DIR"
else
    ensure_git_checkout "$COMFY_REPO" "$COMFY_DIR" "$COMFY_COMMIT" "requirements.txt"
    [ -f "$COMFY_DIR/main.py" ] || die "ComfyUIのmain.pyがありません。"
    log "ComfyUI依存パッケージをインストール"
fi
runtime_link_data
# ComfyUI-QwenVL resolves downloads through folder_paths.models_dir directly.
# Keep its hard-coded LLM directory on the shared volume as well.
if [ -L "$COMFY_DIR/models/LLM" ]; then
    [ "$(readlink -f "$COMFY_DIR/models/LLM")" = "$(readlink -f "$SHARED_COMFY_DIR/models/LLM")" ] || die "予期しないLLMリンク: $COMFY_DIR/models/LLM"
elif [ -e "$COMFY_DIR/models/LLM" ]; then
    die "専用ComfyUIのLLMパスが既に存在します: $COMFY_DIR/models/LLM"
else
    mkdir -p "$SHARED_COMFY_DIR/models/LLM"
    ln -s "$SHARED_COMFY_DIR/models/LLM" "$COMFY_DIR/models/LLM"
fi
if [ ! -f "$RUNTIME_INSTANCE/.requirements-installed" ]; then
    install_pip -r "$COMFY_DIR/requirements.txt"
    touch "$RUNTIME_INSTANCE/.requirements-installed"
fi

log "ComfyUI-QwenVLを導入"
ensure_git_checkout "$NODE_REPO" "$NODE_DIR" "$NODE_COMMIT" "__init__.py"
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
"$PYTHON" - <<'PY'
from transformers import AutoModelForImageTextToText, AutoProcessor
from huggingface_hub import snapshot_download
print('Qwen3-VL Python imports: OK')
PY

log "Qwen3-VL-8B-Instruct公式モデルを取得（約17.5GB）"
mkdir -p "$MODEL_PATH" "$SHARED_COMFY_DIR/input" "$SHARED_COMFY_DIR/output" "$(dirname "$WORKFLOW_PATH")"
QWEN_MODEL_ID="$MODEL_ID" QWEN_MODEL_PATH="$MODEL_PATH" QWEN_MODEL_REVISION="$MODEL_REVISION" "$PYTHON" - <<'PY'
import os
from pathlib import Path
from huggingface_hub import snapshot_download
path = Path(os.environ['QWEN_MODEL_PATH'])
index = path / 'model.safetensors.index.json'
complete = False
if (path / 'config.json').is_file() and index.is_file():
    import json
    shards = set(json.loads(index.read_text(encoding='utf-8'))['weight_map'].values())
    complete = bool(shards) and all((path / shard).is_file() and (path / shard).stat().st_size > 0 for shard in shards)
if not complete:
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
if [ ! -e "$WORKFLOW_PATH" ]; then
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
    'groups': [], 'config': {}, 'extra': {'qwen_model_id': 'qwen3-vl-8b-instruct'}, 'version': 0.4,
}
tmp = out.with_suffix(out.suffix + '.tmp')
tmp.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
tmp.replace(out)
print(out)
PY
fi

RUNTIME_PORT="$(runtime_port "$MODEL_DIR/runtime.json")"
[ "$RUNTIME_PORT" = "$COMFY_PORT" ] || die "Runtime port mismatch"
runtime_start "$COMFY_PORT"
runtime_register "$MODEL_DIR/runtime.json" >/dev/null
runtime_gateway_start
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
