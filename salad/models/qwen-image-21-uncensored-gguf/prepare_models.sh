#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/download_verified.sh
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
download_resume_verified "https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/6b34e59458d3eb7ba6a6f86a116aed5253dc02c3/qwen-image-2.1-UC-Q4_K_M.gguf" "$COMFY_DIR/models/diffusion_models/qwen-image-2.1-UC-Q4_K_M.gguf" "e79c8a009f2ecbdb6c70fd663d9aea9ee304a0d91f347e4169a756b8ad141b41"
download_resume_verified "https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/6b34e59458d3eb7ba6a6f86a116aed5253dc02c3/text_encoders/qwen3vl_8b_int8_convrot.safetensors" "$COMFY_DIR/models/text_encoders/qwen3vl_8b_int8_convrot.safetensors" "8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f"
download_resume_verified "https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF/resolve/6b34e59458d3eb7ba6a6f86a116aed5253dc02c3/vae/qwen_image_2.1_vae_bf16.safetensors" "$COMFY_DIR/models/vae/qwen_image_2.1_vae_bf16.safetensors" "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9"
