# Qwen Rapid AIO v1 reference workflow

Qwen Rapid AIO v1向けの、2入力・PreviewImage出力の参照workflowです。

- workflow: `workflows/two-input-preview.json`
- checkpoint記録値: `Qwen\\Qwen-Rapid-AIO-v1.safetensors`
- `SaveImage` ノードはありません。
- ダウンロード元とSHA-256がリポジトリ内に存在しないため、セットアップ対象には含めません。

実行可能なモデルとして扱うには、モデル配布元、SHA-256、必要なComfyUIバージョンを確認したうえで、専用 `setup.sh` を追加してください。
