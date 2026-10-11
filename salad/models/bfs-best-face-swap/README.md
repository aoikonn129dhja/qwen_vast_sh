# BFS Best Face Swap の旧 Salad プロファイル

このディレクトリには旧専用イメージ用のワークフローとモデル取得設定を残している。単一 Dockerfile の共通イメージは Vast 側の `models/<モデル名>/setup.sh` を実行する構成のため、Vast 側に `models/bfs-best-face-swap/setup.sh` がない BFS は現在対象外。`MODEL=bfs-best-face-swap` は起動時に拒否される。

`workflows/head.json` は頭部参照、`workflows/body.json` は人物全体の参照用。将来 BFS を共通イメージに追加する場合は、Vast 側の setup.sh を整備してから、このワークフローと照合する。
