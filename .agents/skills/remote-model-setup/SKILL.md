---
name: remote-model-setup
description: Vast.ai または SaladCloud の SSH コマンドを受け取り、使うモデルを確認してローカルのコードを転送し、ユーザーが実行するセットアップコマンドを提示する。リモートでモデル導入を代行しない。
---

# リモートモデルの準備

ユーザーから SSH 接続コマンドを受け取ったら、まず `models/*/setup.sh` にあるモデルから今日使うモデルを聞く。LightWan は現状 SaladCloud の ComfyUI Gateway で扱えないので、SaladCloud の選択肢から外す。`setup.sh` のない資料用ディレクトリも選択肢に含めない。

モデルが決まったら、リポジトリルートで次を Codex が実行する。SSH 接続先を判定できない場合だけ Vast.ai か SaladCloud かを確認し、`--provider` に渡す。接続コマンドや鍵をログ・チャットに再掲する際は秘密情報を含めない。

```powershell
python .agents/skills/remote-model-setup/scripts/upload.py --ssh-command '<ユーザーのSSHコマンド>' --model <モデルID>
```

この処理はコード・設定・ワークフローだけを転送・検証する。モデル本体の転送、ダウンロード、セットアップ、Container Group の起動・停止はしない。転送成功の表示と配布版を確認してから、ヘルパーが出力した PowerShell 用セットアップコマンドをそのままユーザーに提示する。手で組み立て直さない。

進捗はユーザーの端末に表示される。SaladCloud は SSH 単発コマンドが成功時にも終了コード `1` を返すことがあるため、端末の `SETUP COMPLETE` / `Model setup complete` とその前のエラー表示で結果を判断する。転送に失敗したらセットアップコマンドを提示しない。再配置でコードが消えたときは、新しい SSH コマンドで再度転送する。
