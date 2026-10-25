#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$REPO_ROOT/tmp"
CASE_DIR="$(mktemp -d "$REPO_ROOT/tmp/runtime-test.XXXXXX")"
trap 'rm -r -- "$CASE_DIR"' EXIT

source "$REPO_ROOT/scripts/runtime/bootstrap.sh"
SHARED_COMFY_DIR="$CASE_DIR/ComfyUI"
RUNTIME_INSTANCE="$CASE_DIR/instances/model"
COMFY_DIR="$RUNTIME_INSTANCE/ComfyUI"
PYTHON="$(command -v python3)"
mkdir -p "$SHARED_COMFY_DIR/models/checkpoints" "$SHARED_COMFY_DIR/user/default/workflows"
mkdir -p "$COMFY_DIR/models" "$COMFY_DIR/custom_nodes"
printf 'code\n' > "$COMFY_DIR/main.py"
printf 'placeholder\n' > "$COMFY_DIR/models/README.md"
mkdir -p "$COMFY_DIR/models/configs" "$COMFY_DIR/input"
printf 'config\n' > "$COMFY_DIR/models/configs/keep.yaml"
printf 'input\n' > "$COMFY_DIR/input/keep.txt"
printf 'keep\n' > "$SHARED_COMFY_DIR/models/checkpoints/keep.bin"
printf '{}\n' > "$SHARED_COMFY_DIR/user/default/workflows/keep.json"
before_model="$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")"
before_workflow="$(sha256sum "$SHARED_COMFY_DIR/user/default/workflows/keep.json")"

runtime_link_data
runtime_link_data

SECOND_COMFY_DIR="$CASE_DIR/instances/second/ComfyUI"
mkdir -p "$SECOND_COMFY_DIR/models" "$SECOND_COMFY_DIR/custom_nodes"
printf 'code\n' > "$SECOND_COMFY_DIR/main.py"
printf 'placeholder\n' > "$SECOND_COMFY_DIR/models/README.md"
COMFY_DIR="$SECOND_COMFY_DIR"
RUNTIME_INSTANCE="$CASE_DIR/instances/second"
runtime_link_data

[ -f "$COMFY_DIR/models/README.md" ]
[ -f "$CASE_DIR/instances/model/ComfyUI/models/configs/keep.yaml" ]
[ -f "$CASE_DIR/instances/model/ComfyUI/input/keep.txt" ]
[ -f "$CASE_DIR/instances/model/extra_model_paths.yaml" ]
[ -f "$CASE_DIR/instances/second/extra_model_paths.yaml" ]
[ -L "$COMFY_DIR/custom_nodes/qwen-runtime" ]
[ "$before_model" = "$(sha256sum "$SHARED_COMFY_DIR/models/checkpoints/keep.bin")" ]
[ "$before_workflow" = "$(sha256sum "$SHARED_COMFY_DIR/user/default/workflows/keep.json")" ]

uv_mock() { printf '%s\n' "$@" > "$CASE_DIR/uv-args"; }
runtime_uv_install_requirements uv_mock /fake/python requirements.txt
[ "$(cat "$CASE_DIR/uv-args")" = $'pip\ninstall\n--python\n/fake/python\n-r\nrequirements.txt' ]
runtime_uv_install_requirements uv_mock /fake/python requirements.txt cu126 constraints.txt
[ "$(cat "$CASE_DIR/uv-args")" = $'pip\ninstall\n--python\n/fake/python\n--torch-backend\ncu126\n--constraint\nconstraints.txt\n-r\nrequirements.txt' ]
printf 'Non-destructive shared data path test passed\n'
