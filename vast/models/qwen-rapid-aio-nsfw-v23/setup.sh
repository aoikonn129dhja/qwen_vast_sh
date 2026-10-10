#!/usr/bin/env bash
set -Eeuo pipefail

# v19 の固定済みセットアップを再利用し、モデル固有値のみ v23 に変更する。
# v19 のファイルは編集せず、生成した一時スクリプトも終了時に削除する。
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V19_DIR="$MODEL_DIR/../qwen-rapid-aio-nsfw-v19"
V19_SETUP="$V19_DIR/setup.sh"
V19_WORKFLOW="$V19_DIR/workflows/batch-save-image.json"
V19_BATCH="$V19_DIR/run_batch.sh"
V19_LOCK="$V19_DIR/requirements.lock"

for required in "$V19_SETUP" "$V19_WORKFLOW" "$V19_BATCH" "$V19_LOCK"; do
    if [ ! -f "$required" ]; then
        printf 'ERROR: v19 共通資産が見つかりません: %s\n' "$required" >&2
        exit 1
    fi
done

# 一時スクリプトは v23 ディレクトリ内に置き、元の MODEL_DIR 算出を維持する。
TEMP_SETUP="$(mktemp "$MODEL_DIR/.setup-v23.XXXXXXXX.sh")"
trap 'rm -f -- "$TEMP_SETUP"' EXIT

python3 - "$V19_SETUP" "$TEMP_SETUP" "$V19_DIR" <<'PY'
from pathlib import Path
import sys

source, destination, v19_dir = map(Path, sys.argv[1:])
s = source.read_text(encoding="utf-8")

replacements = {
    'Qwen Rapid AIO NSFW v19 + ComfyUI one-shot setup':
        'Qwen Rapid AIO NSFW v23 + ComfyUI one-shot setup',
    'DEPENDENCY_LOCK="$MODEL_DIR/requirements.lock"':
        f'DEPENDENCY_LOCK="{v19_dir}/requirements.lock"',
    'MODEL_FILE="Qwen-Rapid-AIO-NSFW-v19.safetensors"':
        'MODEL_FILE="Qwen-Rapid-AIO-NSFW-v23.safetensors"',
    'MODEL_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/$MODEL_REPO_COMMIT/v19/Qwen-Rapid-AIO-NSFW-v19.safetensors"':
        'MODEL_URL="https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/$MODEL_REPO_COMMIT/v23/Qwen-Rapid-AIO-NSFW-v23.safetensors"',
    'MODEL_SHA256="ba71575515709c9912560d1176b2386eaa49294fedc6ce57b9734aa57e91e5ac"':
        'MODEL_SHA256="fdb919fc81bea63f13759967fc92c9118142e5c70d4e6795199233a35eefa233"',
    'REPO_WORKFLOW="$MODEL_DIR/workflows/batch-save-image.json"':
        f'REPO_WORKFLOW="{v19_dir}/workflows/batch-save-image.json"',
    'WORKFLOW_FILE="$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-NSFW-v19-Batch.json"':
        'WORKFLOW_FILE="$COMFY_DIR/user/default/workflows/Qwen-Rapid-AIO-NSFW-v23-Batch.json"',
    'log "Qwen Rapid AIO NSFW v19固定版をダウンロード（約28.4GB）"':
        'log "Qwen Rapid AIO NSFW v23固定版をダウンロード（約28.4GB）"',
    'if [ -f "$MODEL_DIR/run_batch.sh" ]; then\n    chmod +x "$MODEL_DIR/run_batch.sh"\nfi':
        '',
    'echo "  bash $MODEL_DIR/run_batch.sh"':
        f'echo "  bash {v19_dir}/run_batch.sh {"$BATCH_ROOT/input"} {"$BATCH_ROOT/prompts.md"} {"$WORKFLOW_FILE"}"',
}

for before, after in replacements.items():
    count = s.count(before)
    if count != 1:
        raise SystemExit(f"ERROR: v19 setup.sh の想定箇所が変更されています: {before!r} (count={count})")
    s = s.replace(before, after, 1)

# モデル固定リビジョンは v19 と同じものを利用する（v23 のファイルも存在する）。
# ComfyUI の UI / バッチ両方で v23 を使うため、JSON 内のチェックポイント名を変更する。
old = 'cp -f "$REPO_WORKFLOW" "$WORKFLOW_FILE"'
new = '''"$PYTHON" - "$REPO_WORKFLOW" "$WORKFLOW_FILE" "$MODEL_FILE" <<'WORKFLOW_PY'
import json
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:3])
checkpoint = sys.argv[3]
data = json.loads(source.read_text(encoding="utf-8"))
loaders = [node for node in data.get("nodes", []) if node.get("type") == "CheckpointLoaderSimple"]
if len(loaders) != 1:
    raise SystemExit("ERROR: checkpoint loader node must occur exactly once")
node = loaders[0]
node["widgets_values"][0] = checkpoint
node.setdefault("widgets_values_named", {})["ckpt_name"] = checkpoint
destination.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")
WORKFLOW_PY'''
if s.count(old) != 1:
    raise SystemExit("ERROR: workflow コピー処理が見つからないか複数あります")
s = s.replace(old, new, 1)

# ComfyUI 起動前に v23 専用カスタムノードを導入する。
old = '# Stop previous ComfyUI / tunnel if this script is re-run'
new = '''# Load Image With Filename custom node
CUSTOM_NODE_DIR="$COMFY_DIR/custom_nodes/comfyui-load-image-with-filename"
CUSTOM_NODE_REPO="https://github.com/kymeraj/comfyui-load-image-with-filename.git"
if [ -e "$CUSTOM_NODE_DIR" ] || [ -L "$CUSTOM_NODE_DIR" ]; then
    if [ ! -d "$CUSTOM_NODE_DIR/.git" ] \\
        || [ ! -f "$CUSTOM_NODE_DIR/__init__.py" ] \\
        || [ ! -f "$CUSTOM_NODE_DIR/load_image_with_filename.py" ] \\
        || ! git -C "$CUSTOM_NODE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \\
        || [ "$(git -C "$CUSTOM_NODE_DIR" remote get-url origin 2>/dev/null || true)" != "$CUSTOM_NODE_REPO" ]; then
        die "不完全なカスタムノードを検出しました: $CUSTOM_NODE_DIR"
    fi
    log "カスタムノードを確認: $CUSTOM_NODE_DIR"
else
    log "カスタムノードを取得: $CUSTOM_NODE_REPO"
    mkdir -p "$COMFY_DIR/custom_nodes"
    git clone "$CUSTOM_NODE_REPO" "$CUSTOM_NODE_DIR"
fi

# Stop previous ComfyUI / tunnel if this script is re-run'''
if s.count(old) != 1:
    raise SystemExit("ERROR: ComfyUI 起動前の挿入箇所が見つからないか複数あります")
s = s.replace(old, new, 1)

destination.write_text(s, encoding="utf-8")
PY

bash -n "$TEMP_SETUP"
bash "$TEMP_SETUP" "$@"
