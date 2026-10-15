# SaladCloud 手順書

## 共通イメージと Container Group

リポジトリのルートをビルド context にして、SaladCloud 用の共通イメージを作る。モデル本体はイメージに含まれない。

```bash
docker build --platform linux/amd64 -f salad/Dockerfile -t salad:local .
```

Container Group には共通イメージを設定し、Autostart を無効にする。`main` の Salad 関連ファイルをプッシュすると、既存の GitHub Actions が `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。Container Group は自動起動しない。

## 起動とモデルの切り替え

SaladCloud で Run を押し、レプリカが起動したらコンテナのターミナルでモデルを選ぶ。

```bash
bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23
```

利用できるモデル（次のうち1行だけ実行）:

- Qwen Rapid AIO NSFW v19: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v19`
- Qwen Rapid AIO NSFW v23: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23`
- Qwen Image Edit 2509: `bash /opt/salad/select_model.sh qwen-image-edit-2509`
- Qwen Image Edit 2511: `bash /opt/salad/select_model.sh qwen-image-edit-2511`
- LTX 2.3 Q4: `bash /opt/salad/select_model.sh ltx-2.3-uncensored-v1.4-q4`
- Qwen Image 2.1 GGUF: `bash /opt/salad/select_model.sh qwen-image-2.1-uncensored-gguf`

別のモデルへ切り替えるときは、生成中のジョブがないことを確認してから、同じコンテナで次を実行する。

```bash
bash /opt/salad/reset_model.sh
bash /opt/salad/select_model.sh <モデル名>
```

## Gateway

Container Group に `COMFY_GATEWAY_USER` と20文字以上の `COMFY_GATEWAY_PASSWORD` を設定する。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にする。コンテナ内の HTTP Basic 認証を経由して ComfyUI に接続する。`GET /healthz` は認証不要。モデル未選択・取得中・取得失敗時は Gateway を開かず、ComfyUI が停止した場合は Gateway を閉じる。

## 生成物の回収

Windows 側で SaladCloud 用の回収ツールを実行する。

```powershell
uv run salad\tools\salad_comfy_output_sync_and_log.py
```

画像と生成ログ CSV は `D:\po\NSFW_cos\tmp` 以下に保存する。

## コンテナの保存領域

入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。
