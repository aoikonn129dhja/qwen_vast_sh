#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$REPO_ROOT/tmp"
CASE_DIR="$(mktemp -d "$REPO_ROOT/tmp/repair-test.XXXXXX")"
trap 'rm -r -- "$CASE_DIR"' EXIT

source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
WORKSPACE="$CASE_DIR/workspace"
RUNTIME_ROOT="$WORKSPACE/.qwen_runtime"
RUNTIME_INSTANCE="$RUNTIME_ROOT/instances/sample"
RUNTIME_ENV="$RUNTIME_ROOT/environments/sample"
COMFY_DIR="$RUNTIME_INSTANCE/ComfyUI"
SHARED_COMFY_DIR="$WORKSPACE/ComfyUI"
RUNTIME_PID_FILE="$RUNTIME_ROOT/state/sample.pid"
PYTHON="$RUNTIME_ENV/bin/python"
BASE_PYTHON="$(command -v python3)"
mkdir -p "$RUNTIME_ENV/bin" "$SHARED_COMFY_DIR/models/checkpoints" "$RUNTIME_INSTANCE"
ln -s "$BASE_PYTHON" "$PYTHON"
printf 'model-data\n' > "$SHARED_COMFY_DIR/models/checkpoints/keep.bin"
before="$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")"

seed="$CASE_DIR/seed"
mkdir -p "$seed"
git -C "$CASE_DIR" init -q seed
printf 'working\n' > "$seed/main.py"
printf 'requirements\n' > "$seed/requirements.txt"
git -C "$seed" add .
git -C "$seed" -c user.name=test -c user.email=test@example.invalid commit -qm seed
commit="$(git -C "$seed" rev-parse HEAD)"
printf '{"comfy_commit":"%s","port":18299}\n' "$commit" > "$CASE_DIR/runtime.json"
runtime_install_filename_node() { :; }
COMFY_SOURCE_URL="$seed"
export COMFY_SOURCE_URL
runtime_clone_comfy "$CASE_DIR/runtime.json"
runtime_clone_comfy "$CASE_DIR/runtime.json"
[ ! -d "$RUNTIME_ROOT/repair-backups" ]
printf 'damaged\n' > "$COMFY_DIR/main.py"
mkdir -p "$COMFY_DIR/models"
printf 'embedded-weight\n' > "$COMFY_DIR/models/embedded.safetensors"
if runtime_clone_comfy "$CASE_DIR/runtime.json"; then
    printf 'Expected embedded model guard\n' >&2
    exit 1
fi
[ "$(cat "$COMFY_DIR/models/embedded.safetensors")" = embedded-weight ]
rm -- "$COMFY_DIR/models/embedded.safetensors"
runtime_make_env() { mkdir -p "$RUNTIME_ENV/bin"; ln -s "$BASE_PYTHON" "$PYTHON"; }
runtime_clone_comfy "$CASE_DIR/runtime.json"
[ "$(cat "$COMFY_DIR/main.py")" = working ]
[ "$before" = "$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")" ]

node="$COMFY_DIR/custom_nodes/test-node"
runtime_clone_node "$seed" "$commit" "$node"
printf 'node-damaged\n' > "$node/main.py"
runtime_clone_node "$seed" "$commit" "$node"
[ "$(cat "$node/main.py")" = working ]
[ "$before" = "$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")" ]
compgen -G "$RUNTIME_ROOT/repair-backups/sample/*-ComfyUI/main.py" >/dev/null
compgen -G "$RUNTIME_ROOT/repair-backups/sample/*-environment/bin/python" >/dev/null

FORCE_COMFY_REPAIR=1 runtime_clone_comfy "$CASE_DIR/runtime.json"
[ "$(cat "$COMFY_DIR/main.py")" = working ]
[ "$before" = "$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")" ]

printf 'damaged-again\n' > "$COMFY_DIR/main.py"
COMFY_SOURCE_URL="$CASE_DIR/missing-source"
if runtime_clone_comfy "$CASE_DIR/runtime.json"; then
    printf 'Expected rebuild failure\n' >&2
    exit 1
fi
[ "$before" = "$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")" ]
compgen -G "$RUNTIME_ROOT/repair-backups/sample/*-ComfyUI/main.py" >/dev/null
printf 'ComfyUI repair preserves model data\n'
