#!/usr/bin/env bash
# Install pose-transfer support without affecting the existing Lightning workflow.
set -Eeuo pipefail
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
# Main setup owns runtime_prepare, model verification, and shared setup lock.
SHARED_COMFY_DIR="${SHARED_COMFY_DIR:-/workspace/ComfyUI}"
POSE_LORA="VNCCS_QI2_PoseStudioV1.1.safetensors"
LORA_DIR="$SHARED_COMFY_DIR/models/loras"
WF_DIR="$SHARED_COMFY_DIR/user/default/workflows"
mkdir -p "$LORA_DIR" "$WF_DIR"
URL="https://huggingface.co/MIUProject/VNCCS_PoseStudio_QI2.1/resolve/main/$POSE_LORA"
DEST="$LORA_DIR/$POSE_LORA"
if [[ -s "$DEST" ]]; then
  echo "VNCCS LoRA already present: $DEST"
else
  # Never replace an existing partial file without an explicit decision.
  [[ ! -e "$DEST" ]] || { echo "ERROR: empty existing LoRA: $DEST" >&2; exit 1; }
  tmp="$(mktemp "$LORA_DIR/.vnccs-download.XXXXXXXX")"
  trap 'rm -f -- "$tmp"' EXIT
  curl -fL --retry 3 --connect-timeout 20 --output "$tmp" "$URL"
  test "$(stat -c%s "$tmp")" -ge 100000000 || { echo 'ERROR: VNCCS download appears incomplete.' >&2; exit 1; }
  # Concurrency handled by parent setup's workspace lock.
  mv -n -- "$tmp" "$DEST"
  trap - EXIT
  echo "Downloaded VNCCS LoRA: $DEST"
fi
WF_SOURCE="$MODEL_DIR/workflows/Qwen-Image-2.1-VNCCS-PoseTransfer-API.json"
WF_TARGET="$WF_DIR/Qwen-Image-2.1-VNCCS-PoseTransfer-API.json"
if [[ ! -e "$WF_TARGET" ]]; then
  cp "$WF_SOURCE" "$WF_TARGET"
  echo "Installed pose-transfer API workflow: $WF_TARGET"
else
  echo "Preserved existing workflow: $WF_TARGET"
fi
