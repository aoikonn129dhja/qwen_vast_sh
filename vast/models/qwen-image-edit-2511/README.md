# Qwen Image Edit 2511

ComfyUIの公式系Qwen Image Edit 2511 FP8 mixedと、DWPose/AnimePoseを準備します。

さらに、この2511プロファイルでは次の2本のLoRAを自動で追加します。

- `fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA`
  - ファイル: `qwen-image-edit-2511-multiple-angles-lora.safetensors`
  - 用途: 2511向けのカメラ方位、仰角、距離の制御
  - 推奨strength: `0.8 - 1.0`
  - prompt形式: `<sks> [azimuth] [elevation] [distance]`
- `ScottzillaSystems/qwen-image-edit-plus-nsfw-lora`
  - ファイル: `qwen-image-edit-plus-nsfw-lora.safetensors`
  - 用途: Qwen-Image-Edit-2511向けのNSFW編集LoRA

既存のLightning 4steps LoRAも従来どおり導入します。

```bash
bash /workspace/qwen_vast_sh/vast/models/qwen-image-edit-2511/setup.sh
```

このモデルにはリポジトリ管理のバッチworkflowがないため、セットアップ後はComfyUIから操作します。

公式workflowは `workflows/official.json` に同梱しています。出典はComfy-Org `workflow_templates` のコミット `0e5c5efb32ba6f3365d6da07da64aaf668157042` です。setup時に、公式workflowのBF16モデル名だけを同梱のFP8 mixedモデル名へ置換してComfyUIへ配置します。

## LoRAの使い分け

ポーズ参照画像から人物のポーズや構図を合わせる検証では、最初はLightning LoRAをOFFにして比較してください。

Multiple Angles LoRAはカメラ位置を明示したい場合に使います。例:

```text
<sks> front-right quarter view low-angle shot medium shot
```

このLoRAは「参照画像そのものの骨格抽出」の代替ではありません。人物画像をimage1、DWPose/AnimePoseまたはポーズ参照画像をimage2へ入れる既存構成と併用し、カメラ方向の制御を補助する用途です。

NSFW LoRAは必要な生成時のみ有効化してください。複数LoRAを重ねる場合は、まず1本ずつ有効化して基準画像を取り、構図や人物同一性が崩れない範囲でstrengthを調整してください。

## インストール先

```text
ComfyUI/models/loras/
├── Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors
├── qwen-image-edit-2511-multiple-angles-lora.safetensors
└── qwen-image-edit-plus-nsfw-lora.safetensors
```

追加2本はSHA-256を検証してから使用します。
