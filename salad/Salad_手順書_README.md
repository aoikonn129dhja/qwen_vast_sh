# SaladCloud 手順書

## 共通イメージと Container Group

リポジトリのルートをビルド context にして、SaladCloud 用の共通イメージを作る。モデル本体と `models/`・`scripts/` のコードはイメージに含まれない。

```bash
docker build --platform linux/amd64 -f salad/Dockerfile -t salad:local .
```

Container Group には共通イメージを設定し、Autostart を無効にする。`main` の Salad 関連ファイルをプッシュすると、既存の GitHub Actions が `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。Container Group は自動起動しない。

## 起動とモデルの切り替え

SaladCloud で Run を押し、レプリカが起動したら Codex にインスタンスの SSH コマンドを渡し、`remote-model-setup` スキルでモデルを選ぶ。Codex によるコード転送の完了後、返されたコマンドを自分の PowerShell で実行し、モデルのダウンロード状況を見る。

```bash
bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23
```

利用できるComfyUIモデル（必要なモデルの行を順に実行できる）:

- Qwen Rapid AIO NSFW v19: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v19`
- Qwen Rapid AIO NSFW v23: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23`
- Qwen Image Edit 2509: `bash /opt/salad/select_model.sh qwen-image-edit-2509`
- Qwen Image Edit 2511: `bash /opt/salad/select_model.sh qwen-image-edit-2511`
- LTX 2.3 Q4: `bash /opt/salad/select_model.sh ltx-2.3-uncensored-v1.4-q4`
- Qwen Image 2.1 GGUF: `bash /opt/salad/select_model.sh qwen-image-2.1-uncensored-gguf`
- Qwen Image 2.1 INT8 Lightning: `bash /opt/salad/select_model.sh qwen-image-2.1-int8-lightning`
- Qwen3-VL 8B: `bash /opt/salad/select_model.sh qwen3-vl-8b-instruct`
- Wan 2.2 TI2V 5B: `bash /opt/salad/select_model.sh wan2.2-ti2v-5b`
- Wan 2.2 TI2V 5B Turbo: `bash /opt/salad/select_model.sh wan2.2-ti2v-5b-turbo`
- Wan 2.2 Enhanced NSFW SVI FP8: `bash /opt/salad/select_model.sh wan2.2-enhanced-nsfw`

LightWan 2.2 A14B は LightX2V を使う CLI モデルであり、ComfyUI Gateway のモデル選択には対応しない。Vast 側でも推論用の標準実行コマンドと必要資産の検証は未整備。

別のモデルを使う場合はワークフローを開いてQueueする。不要になったモデルの登録だけ解除するときは名前を指定する。

```bash
bash /opt/salad/reset_model.sh <モデル名>
```

## Gateway

Container Group に `COMFY_GATEWAY_USER` と20文字以上の `COMFY_GATEWAY_PASSWORD` を設定する。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にする。コンテナ内の HTTP Basic 認証を経由して 8188 の共通Gatewayに接続する。`GET /healthz` は認証不要。モデル未登録時は外部プロキシを開かない。登録済みモデルがあればコンテナ再起動後にGatewayを復旧する。

## 生成物の回収

Windows 側で Vast.ai と共通の回収ツールを実行する。SaladCloud の Gateway URL を入力すると自動判定し、`.env` または環境変数の認証情報を利用する。SSH 転送の localhost URL を入力する場合は `--salad` を付ける。既存の Salad 回収履歴も引き継ぎ、画像と動画を回収する。

```powershell
python local_tools\vast_comfy_output_sync_and_log.py
```

従来の `python salad\tools\salad_comfy_output_sync_and_log.py` も同じ処理を呼び出す。画像・動画と生成ログ CSV は `D:\po\NSFW_cos\tmp` 以下に保存する。

## コンテナの保存領域

入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。
