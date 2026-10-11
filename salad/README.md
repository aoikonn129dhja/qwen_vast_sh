# SaladCloud 共通イメージ

`salad/Dockerfile` は Vast.ai の `models/<モデル名>/setup.sh` をそのまま実行するための共通環境を作る。モデル本体はイメージに含まれず、コンテナ起動時に選択した setup.sh が取得する。

## ビルドと起動

リポジトリのルートをビルド context にする。

```bash
docker build --platform linux/amd64 -f salad/Dockerfile -t salad:local .
```

Container Group では `MODEL` に以下のいずれかを指定する。

- `qwen-rapid-aio-nsfw-v19`
- `qwen-rapid-aio-nsfw-v23`
- `qwen-image-edit-2509`
- `qwen-image-edit-2511`
- `ltx-2.3-uncensored-v1.4-q4`
- `qwen-image-2.1-uncensored-gguf`

`COMFY_GATEWAY_USER` と20文字以上の `COMFY_GATEWAY_PASSWORD` も必須。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にし、コンテナ内の HTTP Basic 認証を使用する。ComfyUI は localhost の port 8188 で起動し、認証 proxy を経由して公開される。`GET /healthz` は認証不要の readiness probe に使える。モデルの取得中は Gateway を開かない。取得失敗や ComfyUI の停止時はコンテナが終了する。

`main` の Salad・Vast モデル・セットアップスクリプト・ビルド workflow の変更をプッシュすると GitHub Actions が共通イメージ `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。手動起動も可能。従来のモデル別タグは発行しない。Salad の Container Group は自動起動しない。

## 環境と注意点

初期環境は PyTorch 2.11 / CUDA 13.0。`/workspace/qwen_vast_sh` に Vast 側の `models/` と `scripts/` を配置し、`/venv/main/bin/python` を用意する。setup.sh が依存を更新した後の環境はモデルごとのスクリプトに従う。`MODEL` の切替時はコンテナを再作成する。

モデル取得には数十 GB の空き容量と GPU が必要な場合がある。入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。Rapid 系 setup.sh は cloudflared 実行ファイルも用意するが、ComfyUI の公開経路は Salad の認証付き Gateway を使用する。

ローカル検証は `bash -n`、`python3 -m unittest discover -s salad/tests -v`、`git diff --check` で行う。GPU、巨大モデルのダウンロード、Gateway の実接続、画像生成は別途無料と確認できる環境でのみ検証する。
