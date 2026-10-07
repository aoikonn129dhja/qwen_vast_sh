#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/salad/common/download_verified.sh
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
download_resume_verified "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/cb504a4090723e43f17ad01cec0359490e2de613/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" "$COMFY_DIR/models/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" "cb74113cb03faecd79611b01fd7fd642f0aa60d6f0b95086abee214d75eaa57d"
download_resume_verified "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/cb504a4090723e43f17ad01cec0359490e2de613/text_encoders/qwen3vl_8b_int8_convrot.safetensors" "$COMFY_DIR/models/text_encoders/qwen3vl_8b_int8_convrot.safetensors" "8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f"
download_resume_verified "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/cb504a4090723e43f17ad01cec0359490e2de613/vae/qwen_image_2.1_vae_bf16.safetensors" "$COMFY_DIR/models/vae/qwen_image_2.1_vae_bf16.safetensors" "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9"
download_resume_verified "https://huggingface.co/Alissonerdx/BFS-Best-Face-Swap/resolve/0ca3913ade4b4ada458d60c232354e8586c4c181/bfs_body_swap_v1.0_qwen_2.1.safetensors" "$COMFY_DIR/models/loras/bfs_body_swap_v1.0_qwen_2.1.safetensors" "7dc0a53aba4dbc70c204f498936a619d226559da11011f748c389189af46b664"
download_resume_verified "https://huggingface.co/Alissonerdx/BFS-Best-Face-Swap/resolve/0ca3913ade4b4ada458d60c232354e8586c4c181/bfs_head_v1.1_qwen_2.1.safetensors" "$COMFY_DIR/models/loras/bfs_head_v1.1_qwen_2.1.safetensors" "d1d748d5601077f3b6d05766f6823510e901970d916afa404a97e85dc92fa88e"
