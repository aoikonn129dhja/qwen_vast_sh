---
name: salad-cloud-cli
description: このリポジトリのSaladCloud Container GroupをCLIで確認・作成・起動・停止する。APIキーはローカル.envから読み込み、ブラウザ操作や毎回のコマンド調査なしで操作する。
---

# SaladCloud CLI

リポジトリルートから、Python標準ライブラリだけのCLIを実行する。パッケージ導入は不要。

```powershell
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py status qwen-edit-2511
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py list
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py gpus
```

CLIはルートの`.env`を読み込む。必要な値は`SALAD_API_KEY`、`SALAD_ORGANIZATION`、`SALAD_PROJECT`。`.env`は開いて表示しない。キー未設定の場合はユーザーにローカルで入力してもらう。キーをチャット、ログ、引数、コミットに含めない。

## 新しいGroupを作る

現在の基本設定は2511を基準にする。まずstatusで最新設定を確認する。prepareは読み取りとローカルJSON作成だけであり、外部の作成・起動は行わない。

```powershell
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py prepare qwen-rapid-v19 --model qwen-rapid-aio-nsfw-v19
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py prepare qwen-edit-2509 --model qwen-image-edit-2509
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py prepare ltx-23-q4 --model ltx-2.3-uncensored-v1.4-q4
```

イメージは`salad_image_references.txt`を使用し、既存2511からCPU・RAM・GPU候補・Gateway・priorityを取得する。DNS、ID、状態、キャッシュ、スケジュールはコピーしない。生成する`tmp/salad-<group>.json`をレビューする。追加Disk Spaceは基準Groupから継承できるフィールドがある場合だけコピーされる。必要容量の確認は別途行う。

ユーザーがGroup作成を依頼している場合、レビュー後に実行する。autostartは常にfalse。

```powershell
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py create qwen-rapid-v19
```

createは同名Groupを事前確認し、存在すれば作成せず終了する。作成後はGETで確認する。タイムアウトや結果不明の場合はPOSTを再実行せずstatusで照合する。

Qwen Image 2.1 GGUFとBFSには、成功した新規ビルドのSHAタグを`--image`で指定できる。RAMと保存領域もprepare時に指定する。

```powershell
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py prepare qwen-image-21-uncensored-gguf --model qwen-image-21-uncensored-gguf --image ghcr.io/OWNER/REPO/salad-qwen-image-21-uncensored-gguf:sha-COMMIT_SHA --memory 32768 --storage-gb 50
```

`OWNER/REPO`と`COMMIT_SHA`は実際のビルド結果に置き換える。BFSはGroup名とmodelを`bfs-best-face-swap`にする。既存の金銭使用禁止が有効な間は、下記startコマンドを実行しない。

## 起動・停止

```powershell
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py start qwen-edit-2511 --allow-paid
python .agents/skills/salad-cloud-cli/scripts/salad_cli.py stop qwen-edit-2511
```

`--allow-paid`はユーザーの課金を伴う起動の許可がある場合だけ付ける。スキルの使用やキー設定だけでは起動の許可にならない。停止はユーザーの停止指示または既に承認された終了条件に従う。停止でコンテナ内の生成物が失われ得るため、保存を先に済ませる。変更後は最新状態を確認し、遷移途中を完了扱いしない。

statusにはGateway URLが出る。ComfyUI表示確認はユーザーにURLを案内する。ブラウザ操作はAGENTS.mdの制限に従う。CLIではログ取得や生成を行わない。

## 保守・検証

```powershell
python -m unittest discover -s .agents/skills/salad-cloud-cli/scripts -p "test_*.py"
```

APIエラーはHTTPステータスだけを表示する。レスポンス本文や認証ヘッダーを出力しない。400/404などでスキーマ変更が疑われる場合だけ[公式API仕様](https://github.com/SaladTechnologies/salad-cloud-docs/blob/main/api-specs/salad-cloud.yaml)を確認する。Project一覧APIは存在しない。scopeはPortal URLの`/organizations/<name>/projects/<name>/`または.envから取得する。
