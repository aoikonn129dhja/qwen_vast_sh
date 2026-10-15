# SaladCloud のモデル登録と個別リセット

モデルの追加は既存のコマンドを繰り返す。登録済みの別モデル、共有モデルファイル、ワークフロー、Python環境は保持される。

```bash
bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23
bash /opt/salad/select_model.sh qwen3-vl-8b-instruct
```

対象モデルの登録だけを解除する場合はモデル名を指定する。実行中または待機中のジョブがある場合は拒否される。

```bash
bash /opt/salad/reset_model.sh qwen3-vl-8b-instruct
```

リセットは対象モデルの管理対象プロセスを停止し、登録を解除する。モデルファイル、ComfyUIデータ、専用Python環境、専用インスタンスは保持する。引数なしの一括削除はできない。

8189 の認証付き公開ポートと 8190 の認証プロキシは従来どおり。内部では 8188 の共通Gatewayがモデル別ComfyUIへ転送する。コンテナ再起動時は登録情報からGatewayを復旧し、モデル別ComfyUIは次の要求時に起動する。
