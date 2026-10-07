#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../../.." && pwd)"
MODEL_CONFIG="$MODEL_DIR/model.conf" exec bash "$REPO_ROOT/scripts/setup_qwen_edit_model.sh"
