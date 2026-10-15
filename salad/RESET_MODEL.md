# SaladCloud 共通イメージ内でモデルを切り替える

生成中のジョブがないことを確認してから、コンテナのターミナルで実行する。

```bash
bash /opt/salad/reset_model.sh
bash /opt/salad/select_model.sh qwen-image-edit-2511
```

リセットは現在の ComfyUI を停止し、`/workspace/ComfyUI` 以下のモデル、カスタムノード、ComfyUI 本体を削除する。`/venv/main` はイメージ内に保存した初期状態に戻す。Gateway はリセット中に閉じ、次のセットアップが成功すると再開する。別の Docker イメージやコンテナは不要。

`ComfyUI/input`、`output`、`user` は削除前に `/workspace/salad-user-data/` 以下へ退避する。退避ファイルは容量を消費し続けるため、必要なものを回収した後の削除は利用者が行う。その他の ComfyUI 内ファイルは削除される。モデルのダウンロード途中で失敗した場合もリセットできる。
