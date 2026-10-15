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

`select_model.sh` は指定した `models/<モデル名>/setup.sh` を実行し、成功したときだけ ComfyUI を Gateway に接続する。選択できる名前は `find /workspace/qwen_vast_sh/models -mindepth 2 -maxdepth 2 -type f -name setup.sh -printf '%h\n'` で確認できる。モデルごとの説明は [Vast.ai ComfyUI モデル利用手順書](../comfyui_vast_手順書.md) または各 `models/<モデル名>/README.md` を参照する。SaladCloud では上記の `select_model.sh` を使う。

別モデルへの切り替えは [モデルリセット手順](RESET_MODEL.md) に従う。

## 生成物の回収コマンド
WINで
```
uv run salad\tools\salad_comfy_output_sync_and_log.py
```
D:\po\NSFW_cos\tmpに 202610111859_Qwen-Rapid-AIO-v23のようなディレクトリを作り,画像と生成ログcsvを保存.


Container Group に `COMFY_GATEWAY_USER` と20文字以上の `COMFY_GATEWAY_PASSWORD` を設定する。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にし、コンテナ内の HTTP Basic 認証を使用する。ComfyUI は localhost の port 8188 で起動し、認証 proxy を経由して公開される。`GET /healthz` は認証不要。モデル未選択・取得中・取得失敗時は Gateway を開かない。ComfyUI が停止するとコンテナも終了する。

ComfyUI 内部の接続診断は [Vast.ai ComfyUI モデル利用手順書](../comfyui_vast_手順書.md) の「補助ツールの配置と使い方」を参照する。SaladCloud の Gateway は別経路のため、この診断だけでは外部からの到達性を確認できない。

`main` の Salad・Vast モデル・セットアップスクリプト・ビルド workflow の変更をプッシュすると GitHub Actions が共通イメージ `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。手動起動も可能。従来のモデル別タグは発行しない。Salad の Container Group は自動起動しない。

## 環境と注意点

共通イメージの初期環境は PyTorch 2.11 / CUDA 13.0。別モデルへ切り替えるときは、生成中のジョブがないことを確認してから [モデルリセット手順](RESET_MODEL.md) に従う。

入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。ComfyUI の公開経路は Salad の認証付き Gateway を使用する。

ローカル検証は `bash -n`、`python3 -m unittest discover -s salad/tests -v`、`git diff --check` で行う。GPU、巨大モデルのダウンロード、Gateway の実接続、画像生成は別途無料と確認できる環境でのみ検証する。
