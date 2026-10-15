# SaladCloud 共通イメージ

`salad/Dockerfile` は Vast.ai の `models/<モデル名>/setup.sh` をそのまま実行するための共通環境を作る。モデル本体はイメージに含まれない。コンテナ起動後に SaladCloud のターミナルでモデルを選ぶ。

## ビルドと起動

リポジトリのルートをビルド context にする。

```bash
docker build --platform linux/amd64 -f salad/Dockerfile -t salad:local .
```

Container Group は共通イメージを1つだけ使用し、Autostart を無効にする。ユーザーが Run を押し、レプリカが起動したら [SaladCloud のターミナル](https://docs.salad.com/container-engine/tutorials/development-tools/interactive-terminal)で次を実行する。

```bash
bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23
```

引数には以下のいずれかを指定できる。`select_model.sh` は対象の Vast `setup.sh` を変更せずに実行し、成功したときだけ ComfyUI を Gateway に接続する。

- `qwen-rapid-aio-nsfw-v19`
- `qwen-rapid-aio-nsfw-v23`
- `qwen-image-edit-2509`
- `qwen-image-edit-2511`
- `ltx-2.3-uncensored-v1.4-q4`
- `qwen-image-2.1-uncensored-gguf`

## 生成物の回収コマンド
WINで
```
uv run salad\tools\salad_comfy_output_sync_and_log.py
```
D:\po\NSFW_cos\tmpに 202610111859_Qwen-Rapid-AIO-v23のようなディレクトリを作り,画像と生成ログcsvを保存.


Container Group に `COMFY_GATEWAY_USER` と20文字以上の `COMFY_GATEWAY_PASSWORD` を設定する。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にし、コンテナ内の HTTP Basic 認証を使用する。ComfyUI は localhost の port 8188 で起動し、認証 proxy を経由して公開される。`GET /healthz` は認証不要。モデル未選択・取得中・取得失敗時は Gateway を開かない。ComfyUI が停止するとコンテナも終了する。

## 接続診断

起動済みコンテナのターミナルで、内部のComfyUI、認証proxy、Gatewayの待受とHTTP応答を確認する。

```bash
bash /workspace/qwen_vast_sh/scripts/comfy_diagnose.sh
```

この診断は読み取り専用で、ログ本文や認証情報は表示しない。外部からのGateway到達性は確認できない。

`main` の Salad・Vast モデル・セットアップスクリプト・ビルド workflow の変更をプッシュすると GitHub Actions が共通イメージ `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。手動起動も可能。従来のモデル別タグは発行しない。Salad の Container Group は自動起動しない。

## 環境と注意点

初期環境は PyTorch 2.11 / CUDA 13.0。`/workspace/qwen_vast_sh` に Vast 側の `models/` と `scripts/` を配置し、`/venv/main/bin/python` を用意する。setup.sh が依存を更新した後の環境はモデルごとのスクリプトに従う。別モデルに切り替える際はコンテナを再作成し、再度ターミナルから選ぶ。

モデル取得には数十 GB の空き容量と GPU が必要な場合がある。入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。Rapid 系 setup.sh は cloudflared 実行ファイルも用意するが、ComfyUI の公開経路は Salad の認証付き Gateway を使用する。

ローカル検証は `bash -n`、`python3 -m unittest discover -s salad/tests -v`、`git diff --check` で行う。GPU、巨大モデルのダウンロード、Gateway の実接続、画像生成は別途無料と確認できる環境でのみ検証する。
