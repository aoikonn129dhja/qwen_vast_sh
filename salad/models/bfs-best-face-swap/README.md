# BFS Best Face Swap — SaladCloud

完成済み作品のポーズ・構図・背景を利用し、別の人物写真から頭部または人物全体を反映する。

## 操作

1. SaladのContainer Group `bfs-best-face-swap` を使用する。構成作成時はAutostartを無効にする。
2. ユーザー自身がStartを押すとモデルをダウンロードし、その後ComfyUIが起動する。起動中は課金される。
3. Container Logsで `Starting server` を確認し、GatewayのHTTPS URLを開く。
4. 下記のJSONをComfyUIにドラッグ＆ドロップする。
5. 2つのLoadImageノードで素材を選び、プロンプトを編集する。必要な生成物を保存してからStopする。

- `workflows/head.json`: Image 1は元作品、Image 2は人物A/B/Cの頭部参照。顔・髪型を反映する。
- `workflows/body.json`: Image 1は元作品、Image 2は人物全体の参照。顔・体型・衣装を反映する。全身正面・単純な背景の参照が作者の推奨。

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
docker build --platform linux/amd64 -f salad/models/bfs-best-face-swap/Dockerfile -t salad-bfs-best-face-swap .
```

GitHub Actionsからビルド・GHCR公開後、そのSHAタグをSaladへ指定する。リポジトリのCLIで作成し、停止状態を確認する。Codexによる有料起動・生成は禁止。

## 出典と検証範囲

[BFS作者配布元](https://huggingface.co/Alissonerdx/BFS-Best-Face-Swap)。頭部V1.1とBody Swap V1.0はQwen Image 2.1用LoRAで、2511用とは別。ベースは[Comfy-Org/Qwen-Image-2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)のINT8。

GPU起動・実画像生成は行っていない。素材による編集品質とRAM必要量は実機未検証。
