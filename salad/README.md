# SaladCloud ComfyUI Web UI

Salad版は通常のComfyUI Web UIをDocker containerで提供する。Vast版は `../vast/models/` を使用する。Rapidのバッチ、preview tunnel、Windows出力同期はSaladへ移植していない。

対応モデルは `qwen-rapid-aio-nsfw-v19`、`qwen-image-edit-2509`、`qwen-image-edit-2511`、`ltx-2.3-uncensored-v1.4-q4` の4種類。参照専用のRapid v1は対象外。

## ビルド

repository rootをcontextにして、モデルごとに実行する。

```bash
docker build --platform linux/amd64 \
  -f salad/models/qwen-rapid-aio-nsfw-v19/Dockerfile \
  -t qwen-salad:qwen-rapid-aio-nsfw-v19 .
```

他の3モデルも上記のモデル名を置換する。setup.shはbuild専用で、巨大モデルの取得・GPU確認・ComfyUI起動を行わない。start.shは起動時にprepare_models.shを実行し、成功したときだけComfyUIとsocatを起動する。

GitHub Actionsの **Build Salad images** を手動実行すると4モデルをGHCRへpushする。GITHUB_TOKENを使い、タグは `sha-<full commit SHA>`。成功したActionsのログに表示されたimage名とSHAタグをContainer Groupへ指定する。GHCR pushはローカル検証の対象外。private packageならPortalのregistry認証を設定する。公開packageを使う場合はGitHubのpackage visibilityを確認する。

## Container Group設定

| 項目 | 設定 |
|---|---|
| Container image | 成功したGHCR buildログの対象モデルimage・SHAタグ |
| Replica count | 1 |
| GPU | モデルに必要なVRAMを持つGPUを選択。実GPUで未検証 |
| Container Gateway | enabled |
| Container Gateway port | 8189 |
| Gateway authentication | disabled |
| Protocol | HTTPS |
| Disk Space | Qwenはモデル約30〜32GBに加えimageと作業領域が必要。初期目安として50GB級の空き領域を確保（実環境未検証） |

[SaladのContainer Gateway](https://salad.com/developers/)はIPv6受信を使用する。ComfyUIは `127.0.0.1:8188` にbindし、socatが `[::]:8189` から転送する。WebSocketを使用するWeb UIのためGatewayのAPI-key認証は無効とする。Gateway URLを知る第三者はアクセスできるので、秘密のprompt、入力画像、workflowを扱う際は公開範囲に注意する。独自認証proxyはv1に含めていない。

interactive Web UIはreplicaを1にして、ComfyUI状態が複数containerへ分散するのを避ける。モデル取得中はUIが起動しない。PortalのContainer logsで取得状況・失敗を確認し、準備完了後にGatewayのHTTPS URLをブラウザで開いてworkflowを選択する。初回は数十GBの取得に時間がかかり、回線によって待ち時間が変わる。

[readiness probe](https://salad-tech.readme.io/reference/create_container_group)を設定する場合はHTTP `GET /system_stats`、port `8189` を指定する。モデル取得中の失敗は正常な待機状態として扱い、短いliveness/startup timeoutでダウンロードを繰り返し中断しないよう設定する。

`COMFY_PORT`、`GATEWAY_PORT` は環境変数で変更できる。変更時はGateway portとprobeも一致させる。片方のプロセス終了、SIGTERM、SIGINTで両方を停止しcontainerを終了する。モデルDL失敗時はUIを起動せず非zeroで終了する。

## モデルと保存領域

巨大モデルはimageに含めず起動時に取得する。Qwenは既知SHA-256を検証し、正常な既存ファイルは再取得しない。LTXは既存Vast download_models.pyを再利用し配布元サイズを確認してから `.part` を最終名へ変更する。LTXはSHA-256が既存設定にないため、同サイズの破損の検出はできない。HF_REVISION=mainを維持しており再現性上の未固定点である。

入力、生成物、手動編集workflowはcontainer local filesystemに置かれ、停止・node reallocationで失われる可能性がある。再allocation後はモデルの再取得が必要になる。必要な生成物は利用中に回収する。R2/S3同期、Vastのflatten/output syncの流用は行わない。

## 固定環境

4モデルともlinux/amd64、Python 3.12、CUDA 12.8.1を使用する。

- base: `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04`
- amd64 digest: `sha256:9175fa92f96de35a8cfb9493f0dfcf9435c7a597e9d95ad41d2cae382a95e3f9`（Docker Registry manifest APIで存在確認）
- ComfyUI: `15eb748b3ec5f8a0a2d470b7fb280e2d7579f916`（既存Rapidと同じ）
- bootstrap uv: 0.11.28（配布アーカイブSHA-256検証）。Python lockにはuv 0.12.10が含まれ、依存導入後のPATHではこの固定版を使用する
- Rapid requirements.lockを共通基盤として使用: torch 2.11.0+cu128、torchvision 0.26.0+cu128、torchaudio 2.11.0+cu128、comfy-cli 1.20.0
- DWPose: `0cd290477128d42cdc3e76a826a402d866e8c684`
- AnimePose: `315e758b17a578a7efb9b3eb95fdf4061d256866`
- GGUF Loader: `142c614fe6852f18a513742cc098fd13d72320a9`

custom nodeの追加依存は各requirements.txtからuvで導入するため、全依存の完全なlockではない。Qwen設定・workflow、LTX設定・downloaderをVastからCOPYするが、Vast setupは実行しない。2511 workflowのfilename置換はbuild内のコピーだけに適用する。

## ローカル検証

```bash
find vast salad scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
python3 -m unittest discover -s salad/tests -v
python3 -m unittest discover -s vast/models/ltx-2.3-uncensored-v1.4-q4/tests -v
git diff --check
```

SaladCloudでのContainer Group作成、GPU認識、巨大モデル実DL、Gateway/WebSocket接続、実生成、GHCR pushは未検証。ローカルbuild成功はGPU実環境での動作保証ではない。

2026-10-07にWSL Ubuntu-24.04 / Docker Engine 29.8.2で4モデルのbuildを確認した。Docker inspectのサイズはRapid約21.6GB、2509/2511約23.3GB、LTX約22.6GB。ネットワーク無効のcontainer内で固定torch関連バージョン、workflow JSON、巨大モデル未同梱、uv pip checkを確認した。WSLで全shell構文検査、Python構文検査、LTX 4件・Salad 7件のオフラインテスト、JSON、Actions YAML、contextハッシュ、Vast変更範囲の検証を実施した。
