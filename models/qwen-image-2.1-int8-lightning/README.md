# Qwen-Image-2.1 INT8 ConvRot + LightX2V Lightning 4steps

ComfyUI用の単一画像編集構成。入力は画像1枚とテキストプロンプト1つ。追加の参照画像やプロンプト補強モデルは不要。

- ベースモデル。Comfy-Org配布のQwen-Image-2.1 INT8 ConvRot。NSFW専用の派生モデルではない。
- 高速化。LightX2V Qwen-Image-2.1-Lightning 4steps LoRA。
- テキストエンコーダー。Qwen3-VL 8B INT8 ConvRot。
- VAE。Qwen-Image-2.1 BF16。
- インストール。Hugging Faceの固定リビジョンから取得。既存モデルは再利用、途中ファイルは再開。
- 不要なもの。Qwen 3.5 Prompt Enhancer、GGUFノード、追加LoRA。

## 配置

```text
qwen_vast_sh/
└── models/
    └── qwen-image-2.1-int8-lightning/
        ├── setup.sh
        ├── model.conf
        ├── README.md
        └── workflows/
            └── Qwen-Image-2.1-INT8-Lightning-4steps-1input.json
```

## Vast.ai上で実行

```bash
cd /workspace/qwen_vast_sh
bash models/qwen-image-2.1-int8-lightning/setup.sh
```

既存ComfyUIが最新でなく、更新を抑制したい場合。

```bash
UPDATE_COMFYUI=0 bash models/qwen-image-2.1-int8-lightning/setup.sh
```

追加でファイルのハッシュを検証したい場合。

```bash
VERIFY_SHA256=1 bash models/qwen-image-2.1-int8-lightning/setup.sh
```

ハッシュ確認は通常無効。既存のファイルはサイズの下限のみ検査する。配布ファイルのSHA-256値は`model.conf`に保存している。

セットアップ完了後、ComfyUIのワークフロー一覧から`Qwen-Image-2.1-INT8-Lightning-4steps-1input.json`を開き、`Load Image`に編集対象画像を指定する。`TextEncodeQwenImage21`のプロンプトを変更して実行する。

## SaladCloud

既存共通イメージの`/opt/salad/select_model.sh`が新ディレクトリを含んでいる場合。

```bash
bash /opt/salad/select_model.sh qwen-image-2.1-int8-lightning
```

コンテナ内部の`/workspace/qwen_vast_sh`に新しいディレクトリが入っていなければ実行できない。共通イメージの再ビルドまたはディレクトリ配置が必要。

## Lightning 4steps設定

- LoRA strength: `1.0`。
- CFG: `1.0`。
- Eulerサンプラー。
- `ManualSigmas`: `1.0, 0.75, 0.5, 0.25, 0.0`。末尾の0は最終ステップの終点で、4回の遷移を定義する。
- Lightning配布元の使用例に準拠し、追加の入力参照とプロンプト補強は省略している。

**動作保証の範囲。** モデル配布元はBF16 + Diffusersで4ステップ動作を説明している。INT8 ConvRot + ComfyUIでのLoRA適用・画質は実GPU環境で未検証。ワークフローはComfyUI標準ノードだけで組んでいるが、ComfyUIのバージョンに依存する。エラー時は`tail -n 100 /workspace/comfyui.log`および各ノードのエラー表示を確認する。

## ダウンロード元

- https://huggingface.co/Comfy-Org/Qwen-Image-2.1
- https://huggingface.co/lightx2v/Qwen-Image-2.1-Lightning
- https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_qwen_image_2_1_image_edit.json
