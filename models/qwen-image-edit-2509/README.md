# Qwen Image Edit 2509

公式ベースモデルのFP8 diffusion model、共通Text Encoder、VAE、ComfyUIと標準ノード、LoRA不要の公式系ワークフローをセットアップします。DWPose、AnimePose、LoRAは任意です。

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-edit-2509/setup.sh
```

ワークフローは `workflows/official.json` を `ComfyUI/user/default/workflows/Qwen-Image-Edit-2509-official.json` に配置します。Comfy-Org `workflow_templates` のコミット `0e5c5efb32ba6f3365d6da07da64aaf668157042` を基に、Lightning LoRAなしで使用できるよう変更しています。入力画像を読み込み、通常のステップ数で開始してください。

## 任意: Qwen Image Edit 2509 Lightning

2509専用の4ステップ高速化LoRAです。構図や骨格の追従を比較するときは、まずLoRAなしで試してください。配布元: https://huggingface.co/lightx2v/Qwen-Image-Lightning/tree/main/Qwen-Image-Edit-2509

保存先: `/workspace/ComfyUI/models/loras/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors`

```bash
mkdir -p /workspace/ComfyUI/models/loras
wget -c -O /workspace/ComfyUI/models/loras/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors \
  "https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Edit-2509/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-bf16.safetensors"
```

ComfyUIで `LoraLoaderModelOnly` をモデル経路に追加し、strength `1.0`、サンプリング4ステップを目安に調整してください。バニラワークフローはこのLoRAを要求しません。
