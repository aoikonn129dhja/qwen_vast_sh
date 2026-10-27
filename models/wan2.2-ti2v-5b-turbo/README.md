# Wan2.2-TI2V-5B-Turbo FP16

`models/wan2.2-ti2v-5b` の分離ランタイム、ComfyUI固定コミット、共有モデル配置を流用したTurbo版です。通常版の設定は変更しません。

## 本番環境での起動

```bash
cd /workspace/qwen_vast_sh
git pull --ff-only origin main
bash models/wan2.2-ti2v-5b-turbo/setup.sh
```

Gatewayは8188、Turbo専用ComfyUIは内部ポート18225です。
`/workspace/ComfyUI/user/default/workflows/Wan-2.2-TI2V-5B-Turbo.json` が追加されます。既存の同名ワークフローは上書きしません。

## ワークフロー

ComfyUIで `Wan-2.2-TI2V-5B-Turbo.json` を読み込み、`LoadImage` で入力画像を選び、正のプロンプトを編集して実行します。初期状態はI2Vです。

- 1280×704、121フレーム、24fps（約5秒）。
- 4ステップ、CFG 1.0、sampler `lcm`、scheduler `simple`、shift 8。
- `lcm` は各ステップの予測画像に次のsigmaのノイズを加え直すComfyUI標準実装です。配布元のfew-step処理に合わせています。
- CFG 1.0では負のプロンプトは使用されません。
- モデル名は `Wan2_2-TI2V-5B-Turbo_fp16.safetensors`。追加LoRA・カスタムノードは不要です。
- 通常版と同じ `umt5_xxl_fp8_e4m3fn_scaled.safetensors` と `wan2.2_vae.safetensors` を共有し、配置済みなら再取得しません。

元のTI2Vテンプレートの構成も残しています。T2Vを試す場合は `LoadImage` をCtrl+Bでバイパスします。ただしTurbo配布元の公開用途はI2Vであり、T2Vの品質は未確認です。

依頼によりテスト・GPU生成は実施していません。構文とJSONの静的確認のみで、本番GPUでのロード・画質・VRAM所要量は未確認です。

## 配布元

- Turbo: https://github.com/quanhaol/Wan2.2-TI2V-5B-Turbo
- ComfyUI用FP16: https://huggingface.co/Kijai/WanVideo_comfy/tree/8260d429d19fd7a72304cad059160b95d843913f/Wan22-Turbo
- VAE・テキストエンコーダ: https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged
- 元のワークフロー: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_5B_ti2v.json
