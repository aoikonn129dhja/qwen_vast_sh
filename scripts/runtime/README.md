# モデル別ランタイム

各 `models/<model>/setup.sh` が従来どおり入口になる。ComfyUI系モデルは `runtime.json` の固定コミットで専用コードを `/workspace/.qwen_runtime/instances/<model>/ComfyUI` に用意し、専用Python環境を `/workspace/.qwen_runtime/environments/<model>` に作る。`/workspace/ComfyUI/models`、`input`、`output`、`user` は共有したまま、専用インスタンスから参照する。

共通Gatewayは `127.0.0.1:8188`、モデル別ComfyUIは `runtime.json` の内部ポートで待ち受ける。ComfyUIのワークフローを開いた時点でフロントエンド拡張がモデルを特定し、必要なら接続を切り替えてグラフを復元する。ワークフローに `extra.qwen_model_id` がない場合はノード種別またはモデルファイル名を使う。識別が曖昧ならモデル名の入力を求める。

VRAM管理はGPUの空き容量と管理対象プロセスの使用量を `nvidia-smi` から取得する。要求モデルに必要な余裕がなければ、実行・待機ジョブのないモデルを最終使用時刻の古い順に退避する。`POST /free` 後にもメモリが残る場合、対象PIDの実行ディレクトリを検証してから専用ComfyUIだけを停止する。実行中ジョブは退避せず、要求は終了まで待つ。未知のモデルの初回VRAMは `gpu_policy.reserve_mb` で保守的に見積もる。

セットアップはモデル別の `flock` を保持し、共有ファイルの上書きや別モデルのプロセス停止を避ける。追加モデルは専用の `runtime.json` と `setup.sh` を用意し、`runtime_prepare`、`runtime_clone_comfy`、`runtime_register`、`runtime_start`、`runtime_gateway_start` を呼ぶ。`runtime.json` にはモデルID、実行種別、ComfyUI固定コミット、依存、モデル保存先、カスタムノード、ワークフロー、GPU予約、退避方式、内部ポート、識別用シグネチャを記録する。

LightX2VなどのCLIジョブは次のアダプターで予約してから、**終了までフォアグラウンドで動く**実際の推論コマンドを渡す。

```bash
python /workspace/qwen_vast_sh/scripts/runtime/cli_adapter.py lightwan2.2-a14b -- <推論コマンドと引数>
```

LightWanの既存 `setup.sh` は必要な推論資産や実行コマンドの妥当性までは確認しない。ComfyUIワークフローとしては公開しない。

GPU容量に依存しないスケジューラ試験にはGatewayの `--free-limit-mb` を使える。ローカルの回帰試験は `python -m unittest discover -s scripts/runtime/tests`、WSLのシェル試験は `bash scripts/runtime/tests/test_bootstrap.sh`。実GPU・Vast.ai・SaladCloudを使う試験は別途実環境で確認する。
