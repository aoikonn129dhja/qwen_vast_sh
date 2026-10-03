# Qwen Rapid AIO NSFW v19

入力画像と `prompts.md` の全組み合わせを生成するバッチ対応モデルです。

```bash
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/setup.sh
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

- `setup.sh`: ComfyUI、モデル、依存、workflow、cloudflaredを準備します。
- `run_batch.sh`: このモデル専用のバッチを実行します。
- `restart_preview_tunnel.sh`: 認証付きプレビューのURLを再作成します。
- `workflows/batch-save-image.json`: バッチ実行用workflowです。
- `requirements.lock`: このモデルが使用する固定依存です。
