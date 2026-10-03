# Models

実行可能なモデルは、それぞれのディレクトリに `model.conf` と `setup.sh` を持ちます。

```bash
cd /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19
bash setup.sh
```

新しいモデルを追加するときは、新しいディレクトリにモデル固有の設定、setup、workflow、依存ファイルをまとめてください。セットアップはそのディレクトリ内の `setup.sh` を直接実行します。

2509と2511の公式ComfyUI workflowは、それぞれの `workflows/official.json` に同梱しています。
