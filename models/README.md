# Models

実行可能なモデルは、それぞれのディレクトリに `model.conf` と `setup.sh` を持ちます。

```bash
bash setup.sh --list
bash setup.sh qwen-rapid-aio-nsfw-v19
```

新しいモデルを追加するときは、新しいディレクトリにモデル固有の設定、setup、workflow、依存ファイルをまとめてください。ルートの `setup.sh` は自動検出するため、中央のモデル一覧を編集する必要はありません。

2509と2511の公式ComfyUI workflowは、それぞれの `workflows/official.json` に同梱しています。
