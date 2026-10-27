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

起動直後にGPU・ディスクを表示し、ComfyUI取得や依存インストールより前に、Turbo配布元から最大8 MiBを読み取って速度を測定します。v23と同じくMiB/s・Mbps・未取得モデルの推定ダウンロード時間を表示します。既定10 MiB/s未満では対話実行なら続行確認、非対話なら停止します。測定失敗時は警告して続行します。必要な場合のみ `ALLOW_SLOW_DOWNLOAD=1 bash setup.sh` で低速でも続行できます。`MIN_DOWNLOAD_MIB_S` と `SPEED_TEST_BYTES` も指定できます。

初回のモデル合計は約18.33 GB（Turbo約10.18 GB、テキストエンコーダ約6.74 GB、VAE約1.41 GB）です。配布サイズと一致する既存ファイルは再取得せず、全部揃っている場合は速度測定も省略します。取得後もサイズを確認してからプロセス固有の一時ファイル経由で配置します。Hugging Faceのキャッシュと配置先の両方に空き容量が必要です。

### 別モデルとのセットアップ

更新後の全モデルのsetupは、共通の `/workspace/.qwen-setup.lock` を取得します。別ターミナルから同時に実行しても、セットアップ本体は先行処理の終了を待って順番に進みます。共有モデル・workflow・uvへの同時書き込みを避け、ComfyUI本体・Python環境・内部ポートはモデル別に保持します。速度測定はロック取得前なので、他のダウンロードが走っている間の測定値はその通信の影響を受けます。

旧版のsetup実行中に更新しても、実行中プロセスへ新しいロックは追加されません。旧版のsetupが終了してから、更新後のsetupを実行してください。複数モデルの同時生成でVRAMが足りることは保証しません。生成モデルを切り替える場合は共通ランタイムのアンロード手順に従ってください。

## ワークフロー

ComfyUIで `Wan-2.2-TI2V-5B-Turbo.json` を読み込み、`LoadImage` で入力画像を選び、正のプロンプトを編集して実行します。初期状態はI2Vです。

- 1280×704、121フレーム、24fps（約5秒）。
- 4ステップ、CFG 1.0、sampler `lcm`、scheduler `simple`、shift 8。
- `lcm` は各ステップの予測画像に次のsigmaのノイズを加え直すComfyUI標準実装です。配布元のfew-step処理に合わせています。
- CFG 1.0では負のプロンプトは使用されません。
- モデル名は `Wan2_2-TI2V-5B-Turbo_fp16.safetensors`。追加LoRA・カスタムノードは不要です。
- 通常版と同じ `umt5_xxl_fp8_e4m3fn_scaled.safetensors` と `wan2.2_vae.safetensors` を共有し、配置済みなら再取得しません。

元のTI2Vテンプレートの構成も残しています。T2Vを試す場合は `LoadImage` をCtrl+Bでバイパスします。ただしTurbo配布元の公開用途はI2Vであり、T2Vの品質は未確認です。

速度判定とセットアップ排他は外部サービスへ接続しないローカル・WSL確認の対象です。本番GPUでのロード・画質・VRAM所要量は未確認です。

## 配布元

- Turbo: https://github.com/quanhaol/Wan2.2-TI2V-5B-Turbo
- ComfyUI用FP16: https://huggingface.co/Kijai/WanVideo_comfy/tree/8260d429d19fd7a72304cad059160b95d843913f/Wan22-Turbo
- VAE・テキストエンコーダ: https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged
- 元のワークフロー: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_5B_ti2v.json
