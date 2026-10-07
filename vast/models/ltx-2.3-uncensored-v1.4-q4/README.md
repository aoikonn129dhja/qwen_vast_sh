# LTX-2.3 Uncensored Turbo v1.4 Q4_K_M

ChrisColeTech の `LTX-2.3-uncensored-v1.4-FP8` を、ComfyUI で画像から動画へ変換するための単一段I2Vと二段階T2V/I2Vの構成です。

## セットアップ

このディレクトリを `qwen_vast_sh/vast/models/ltx-2.3-uncensored-v1.4-q4/` として配置した後、このディレクトリで実行します。

```bash
cd /workspace/qwen_vast_sh/vast/models/ltx-2.3-uncensored-v1.4-q4
bash setup.sh
```

直接実行する場合は次です。

```bash
bash vast/models/ltx-2.3-uncensored-v1.4-q4/setup.sh
```

セットアップは次だけを追加します。

- `ltxv23_uncensored_v1.4_Q4_K_M.gguf`
- `gemma-3-12b-it-ablit-norms-biproj-Q4_K_M.gguf`
- `ltxv23_uncensored_v1.4_projections.safetensors`
- `ltxv23_uncensored_v1.4_video_vae.safetensors`
- `ltxv23_uncensored_v1.4_audio_vae.safetensors`
- `ChrisColeTech/ComfyUI-GGUF-Loader`

さらに公式 `ltx-2.3-spatial-upscaler-x2-1.1.safetensors`（約0.93 GiB）を `models/latent_upscale_models/` に配置します。固定revisionとSHA-256で検証し、途中取得を再開します。追加LoRAは不要です。

セットアップは `[1/5]` から `[5/5]` までの段階を表示します。モデル5ファイルのダウンロード前に Hugging Face から最大8 MiBを読み、回線速度を測定します。ダウンロード中は現在のファイル番号に加え、5ファイル合計の転送量、進捗率、実測速度、残り時間の目安を約5秒ごとに表示します。残り時間はモデルファイルの転送分で、ComfyUIやPython依存の導入時間は含みません。再実行時は配布サイズと一致する既存ファイルをスキップし、途中ファイルは続きから取得します。

## I2V の最小グラフ

`LTX-2.3_Uncensored_v1.4_Q4_I2V.json` を ComfyUI に読み込んでください。Lightricks の公式 two-stage workflow JSON をコピーして別名にし、追加モデルを要しない単一段 I2V グラフへ組み替えたものです。`LTX-2.3_T2V_I2V_Two_Stage_Distilled.json` も、このコンテナに導入済みのCCTechノードとv1.4 GGUFに合わせて組み直しています。読み込み後、`LoadImage` で入力画像を選択し、プロンプトを編集してください。

CCTech のノードを次の順で接続します。

```text
LTXV23ModelsLoader
  ├─ model ───────────────────────────────┐
  ├─ clip ───────┐                       │
  ├─ vae ────────┼─> LTXV23ImgToVideo ──┼─> LTXV23KSampler
  └─ audio_vae ──┘          ▲            │
                             │ image      │
                          LoadImage       │
                                          v
                                  LTXV23AVDecode
```

`LTXV23ModelsLoader` では、setup で配置した5ファイルをそれぞれ選択します。

`LTXV23ImgToVideo` の `image` に入力画像を接続します。現在の CCTech 実装の初期値は、`image_strength=0.7`、`length=121`、`frame_rate=24` です。

`LTXV23KSampler` は、v1.4 の DMD bake を使う場合、まず `schedule=dmd (8 steps)`、`steps=8`、`cfg=1.0`、`sampler_name=euler` から確認します。

## 公式 workflow JSON

Lightricks 公式の LTX-2.3 ComfyUI workflow です。

Single-stage distilled、T2V/I2V。

https://github.com/Lightricks/ComfyUI-LTXVideo/blob/master/example_workflows/2.3/LTX-2.3_T2V_I2V_Single_Stage_Distilled_Full.json

Two-stage distilled。

https://github.com/Lightricks/ComfyUI-LTXVideo/blob/master/example_workflows/2.3/LTX-2.3_T2V_I2V_Two_Stage_Distilled.json

上記は Lightricks 公式モデル向けの workflow です。この ChrisColeTech の split GGUF v1.4 では、モデル読み込み部分を `LTXV23ModelsLoader` に合わせる必要があります。JSONをそのまま無変更で実行できることは保証しません。

## モデル固有の注意

ChrisColeTech 側の配布リポジトリは、現在も `license: unknown` と表示されています。商用利用や再配布の可否は、このファイル群だけからは確定できません。

LTX-2.3 のフレーム数は `8k+1` の形に合わせます。例は `49`、`97`、`121` です。

モデル配布元。

https://huggingface.co/ChrisColeTech/LTX-2.3-uncensored-v1.4-FP8

CCTech GGUF Loader。

https://github.com/ChrisColeTech/ComfyUI-GGUF-Loader

## 二段階 T2V / I2V

`LTX-2.3_T2V_I2V_Two_Stage_Distilled.json` を読み込みます。これは公式グラフの無変更コピーではなく、v1.4 GGUF向けの二段階構成です。

1. I2Vでは `LoadImage` で画像を選択します。T2Vでは `LTXV23ImgToVideo` の `image` 接続を外します。未接続のLoadImageは実行対象になりません。
2. プロンプトを編集します。初期解像度384×256は生成後に2倍の768×512になります。121フレーム、24 fpsです。フレーム数は8k+1を維持します。
3. `LTXV23RefineSampler` がDMD 8ステップ生成、動画latentのx2拡大、3ステップ再調整を行います。CFG 1.0、Eulerです。
4. `LTXV23AVDecode` で動画・音声を復号し、`SaveVideo` で保存します。

Vastでは更新後にsetupを実行すると6ファイルが揃います。Saladでは更新後のDockerイメージに再ビルドする必要があります。既存イメージの再起動だけでは新しいワークフローとupscaler取得処理は反映されません。

ノード登録・配線・設定値は無課金のローカル検証対象です。GPUでのモデルロード、生成品質、VRAM所要量は実生成を行うまで未確認です。
