#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
INSTALL_PEPE_UTILS=1 INSTALL_QWEN_CROP_NODE=1 MODEL_CONFIG="$MODEL_DIR/model.conf" bash "$REPO_ROOT/scripts/setup_qwen_edit_model.sh"
bash "$MODEL_DIR/setup_pose_editor.sh"
