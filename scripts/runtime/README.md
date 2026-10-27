# モデル別ランタイム

各 `models/<model>/setup.sh` が従来どおり入口になる。ComfyUI系モデルは `runtime.json` の固定コミットで専用コードを `/workspace/.qwen_runtime/instances/<model>/ComfyUI` に用意し、専用Python環境を `/workspace/.qwen_runtime/environments/<model>` に作る。`/workspace/ComfyUI/models`、`input`、`output`、`user` は共有したまま、専用インスタンスから参照する。

共通Gatewayは `127.0.0.1:8188`、モデル別ComfyUIは `runtime.json` の内部ポートで待ち受ける。各モデルのセットアップ後、ワークフローを開けば接続先を自動選択し、必要なら画面を再読み込みしてグラフを復元する。Gatewayが配信するフロントエンド拡張を使うため、既存ComfyUIのカスタムノードを再インストールする必要はない。モデルファイル名を優先し、`extra.qwen_model_id`、固有のノード種別でも判別する。判別できないワークフローには `extra.qwen_model_id` を指定する。複数の専用モデルが必要なワークフローは拒否する。

ComfyUIの起動・接続先選択と、モデル本体のVRAMへの読み込みは別になる。モデル本体は初回Queueで自動的に読み込まれるため、通常は `load` コマンドを使わない。生成APIへの直接送信とRapidのバッチ実行でも対象モデルを自動選択する。画面を表示するためのComfyUI起動では生成を実行しない。

モデルの退避は明示的なコマンドだけで行い、自動退避はしない。モデルを切り替える際は次のコマンドで管理対象のComfyUIモデルをまとめてアンロードし、その後で新モデルのワークフローを開いて実行する。モデル名の指定は不要。ダウンロード済みファイルは残る。実行中・待機中ジョブがある場合や状態を確認できない場合は、一括アンロードを開始しない。実行中モデルからの接続切り替えも拒否する。特定モデルだけを退避する従来の `unload MODEL_ID` も引き続き使える。CLIモデルや管理対象外のプロセスは停止しない。

```bash
python /workspace/qwen_vast_sh/scripts/runtime/runtime_control.py unload
```

アンロード後は、登録されたComfyUIモデルのうち、専用プロセスが停止済みで、登録上のモデル保存先がすべてSSDに存在するものを一覧表示する。モデルファイルの内容・完全性の検証や、管理対象外プロセスのVRAM確認は行わない。

更新を既存環境へ反映するときは、リポジトリ更新後にGatewayを再起動してブラウザを再読み込みする。

```bash
python /workspace/qwen_vast_sh/scripts/runtime/runtime_control.py restart-gateway
```

セットアップはワークスペース共通の `/workspace/.qwen-setup.lock` の `flock` を終了まで保持する。別モデルのsetupを同時に起動しても、後続は待機して順番に実行する。モデル別環境に加え、共有モデルの一時ファイル、workflow、`/workspace/bin/uv` への書き込みも保護する。起動した常駐ComfyUIとGatewayにはこのロックを引き継がせない。更新前から動いているsetupは共通ロックを持たないため、終了してから更新版を実行する。同時セットアップの排他と同時生成時のVRAM管理は別であり、モデル切り替え時は上記のアンロード手順を使う。

追加モデルは専用の `runtime.json` と `setup.sh` を用意し、`runtime_prepare`、`runtime_clone_comfy`、`runtime_register`、`runtime_start`、`runtime_gateway_start` を呼ぶ。`runtime.json` にはモデルID、実行種別、ComfyUI固定コミット、依存、モデル保存先、カスタムノード、ワークフロー、GPU予約、退避方式、内部ポート、識別用シグネチャを記録する。

LightX2VなどのCLIジョブは次のアダプターに、**終了までフォアグラウンドで動く**実際の推論コマンドを渡す。VRAM予約・自動退避は行わない。

```bash
python /workspace/qwen_vast_sh/scripts/runtime/cli_adapter.py lightwan2.2-a14b -- <推論コマンドと引数>
```

LightWanの既存 `setup.sh` は必要な推論資産や実行コマンドの妥当性までは確認しない。ComfyUIワークフローとしては公開しない。

ローカルの回帰試験は `python -m unittest discover -s scripts/runtime/tests`、WSLのシェル試験は `bash scripts/runtime/tests/test_bootstrap.sh`。実GPU・Vast.ai・SaladCloudを使う試験は別途実環境で確認する。
