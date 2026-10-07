# Qwen Image 2.1 Uncensored GGUF — SaladCloud

人物をゼロから生成するためではなく、完成済み作品の人物性・外見を維持し、参照画像のポーズ・カメラアングル・構図・衣装を適用する画像編集用。

## 操作

1. SaladのContainer Group `qwen-image-21-uncensored-gguf` を使用する。構成作成時はAutostartを無効にする。
2. ユーザー自身がStartを押すとモデルをダウンロードし、その後ComfyUIが起動する。起動中は課金される。
3. Container Logsで `Starting server` を確認し、GatewayのHTTPS URLを開く。
4. 下記のJSONをComfyUIにドラッグ＆ドロップする。
5. 2つのLoadImageノードで素材を選び、プロンプトを編集する。必要な生成物を保存してからStopする。

- `workflows/edit.json`: Image 1は変更する完成済み作品、Image 2はポーズ・構図・衣装などの参照。プロンプトで今回変える要素だけを指定する。

場面を約2 MP、参照を約0.59 MPへ縦横比を保って縮小する。人物A/B/Cを個別に編集する場合は対象人物をプロンプトで明示し、人物ごとに参照を差し替えて作業する。参照順を逆にしない。本人らしさ、正確なポーズ、複数人物の完全な保持は保証しない。

## 構成

- NVIDIA RTX 5090 (32 GB)、CPU 4 vCPU、RAMは初期目安32 GB、Replicas 1。
- Gateway 8189、IPv6転送、認証なし。URLを知る人がアクセスできる。
- ComfyUI固定コミット: `c9d8a6e69c4b5ab7fa0f789e7b988c172cd31fc9`。
- 巨大モデルはDockerイメージに含めず、起動時に固定revisionから取得しSHA-256を検証する。詳細は `source_manifest.json`。
- `workflows/source/` は配布元から取得した原本。直接使用すると追加ノードや任意モデルが必要になる。上記の読み込み用JSONは原本の入力契約を参考に構成し、任意の8-step加速LoRAは使用せず25-stepで実行する。
- 保存領域はコンテナ内。停止・再配置に備えて生成物を手元へ保存する。

## ビルド

```bash
docker build --platform linux/amd64 -f salad/models/qwen-image-21-uncensored-gguf/Dockerfile -t salad-qwen-image-21-uncensored-gguf .
```

GitHub Actionsからビルド・GHCR公開後、そのSHAタグをSaladへ指定する。リポジトリのCLIで作成し、停止状態を確認する。Codexによる有料起動・生成は禁止。

## 出典と検証範囲

[GGUF配布元](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-GGUF)の推奨Q4_K_MとINT8テキストエンコーダ。[公式編集テンプレート](https://github.com/Comfy-Org/workflow_templates/blob/b4119d0fcecf78a376e087305ec4f485c66a03f5/templates/image_qwen_image_2_1_image_edit.json)を取得し、GGUF Loaderを使う参照編集グラフを同梱。

GPU起動・実画像生成は行っていない。素材による編集品質とRAM必要量は実機未検証。
