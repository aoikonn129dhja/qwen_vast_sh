# SaladCloud 共通イメージ内でモデルを切り替える

生成中のジョブがないことを確認してから、コンテナのターミナルで実行する。

```bash
bash /opt/salad/reset_model.sh
bash /opt/salad/select_model.sh qwen-image-edit-2511
```

リセットは現在の ComfyUI を停止し、`/workspace/ComfyUI/models` 内のダウンロード済みモデルと `custom_nodes` 内の追加ノードを削除する。ComfyUI 本体は保持し、`/venv/main` はイメージ内に保存した初期状態に戻す。Gateway はリセット中に閉じ、次のセットアップが成功すると再開する。別の Docker イメージやコンテナは不要。

`ComfyUI/input`、`output`、`user` はそのまま残る。リセット前に生成中のジョブを終了し、必要な生成物を回収する。モデルのダウンロード途中で失敗した場合もリセットできる。次のモデルの setup が異なる ComfyUI コミットを要求する場合は、その setup 自身が ComfyUI を更新する可能性がある。
