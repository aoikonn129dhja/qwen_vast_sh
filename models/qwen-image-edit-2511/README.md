# Qwen Image Edit 2511

公式ベースモデルのFP8 mixed diffusion model、共通Text Encoder、VAE、ComfyUIと標準ノード、LoRA不要の公式系ワークフローをセットアップします。Lightning 4steps LoRAも毎回導入します。DWPoseとAnimePoseは導入しません。Multiple AnglesとNSFWは手動導入です。

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-edit-2511/setup.sh
```

ワークフローは `workflows/official.json` を `ComfyUI/user/default/workflows/Qwen-Image-Edit-2511-official.json` に配置します。Comfy-Org `workflow_templates` のコミット `0e5c5efb32ba6f3365d6da07da64aaf668157042` を基に、Lightning LoRAなしで使用できるよう変更しています。ワークフロー内のモデル名は導入するFP8 mixedファイル名に合わせています。

## 自動導入: Qwen Image Edit 2511 Lightning

2511専用の4ステップ高速化LoRAです。セットアップ時に既存ファイルのSHA-256を確認し、不足時だけ取得します。バニラワークフローで使用するときはComfyUIでノードを追加します。配布元: https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning

保存先: `/workspace/ComfyUI/models/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors`

`LoraLoaderModelOnly` のstrength `1.0`、サンプリング4ステップを目安に調整してください。

## 任意: Qwen Image Edit 2511 Multiple Angles

2511専用のカメラ方位、仰角、距離の制御LoRAです。配布元: https://huggingface.co/fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA

保存先: `/workspace/ComfyUI/models/loras/qwen-image-edit-2511-multiple-angles-lora.safetensors`

```bash
mkdir -p /workspace/ComfyUI/models/loras
wget -c -O /workspace/ComfyUI/models/loras/qwen-image-edit-2511-multiple-angles-lora.safetensors \
  "https://huggingface.co/fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA/resolve/main/qwen-image-edit-2511-multiple-angles-lora.safetensors"
```

strength `0.8-1.0` を目安に、プロンプトへ `<sks> [azimuth] [elevation] [distance]` 形式で指定します。ポーズ画像からの骨格抽出の代替ではありません。

## 任意: Qwen Image Edit Plus NSFW

2511向けのNSFW編集LoRAです。配布元: https://huggingface.co/ScottzillaSystems/qwen-image-edit-plus-nsfw-lora

保存先: `/workspace/ComfyUI/models/loras/qwen-image-edit-plus-nsfw-lora.safetensors`

```bash
mkdir -p /workspace/ComfyUI/models/loras
wget -c -O /workspace/ComfyUI/models/loras/qwen-image-edit-plus-nsfw-lora.safetensors \
  "https://huggingface.co/ScottzillaSystems/qwen-image-edit-plus-nsfw-lora/resolve/main/qwen-image-edit-plus-nsfw-lora.safetensors"
```

必要な生成時だけ有効化し、strengthは低めから調整してください。複数LoRAを使う場合は、まず1本ずつ確認してください。ワークフローはLoRAなしでも開けます。使用時はComfyUIでLoRAノードを追加します。
