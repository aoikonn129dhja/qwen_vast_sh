#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$REPO_ROOT/models"

list_models() {
    local model_dir config
    for model_dir in "$MODELS_DIR"/*; do
        [ -d "$model_dir" ] || continue
        [ -x "$model_dir/setup.sh" ] || [ -f "$model_dir/setup.sh" ] || continue
        config="$model_dir/model.conf"
        [ -f "$config" ] || continue
        (
            # shellcheck source=/dev/null
            source "$config"
            printf '%-32s %s\n' "$MODEL_ID" "$MODEL_NAME"
        )
    done
}

usage() {
    echo "Usage: bash setup.sh <model-id>"
    echo
    echo "Available models:"
    list_models
}

if [ "${1:-}" = "--list" ] || [ "$#" -eq 0 ]; then
    usage
    exit 0
fi

if [ "$#" -ne 1 ] || [[ "$1" != [a-z0-9]* ]] || [[ "$1" == *[!a-z0-9-]* ]]; then
    echo "ERROR: invalid model id: ${1:-}" >&2
    usage >&2
    exit 2
fi

MODEL_ID="$1"
MODEL_DIR="$MODELS_DIR/$MODEL_ID"
SETUP_ENTRY="$MODEL_DIR/setup.sh"

if [ ! -f "$SETUP_ENTRY" ]; then
    echo "ERROR: unknown model id: $MODEL_ID" >&2
    usage >&2
    exit 2
fi

exec bash "$SETUP_ENTRY"
