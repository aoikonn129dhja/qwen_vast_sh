# Qwen ComfyUI バッチ生成 手順書

# 第1章 最初にやること

## 1. リポジトリのファイルを揃える

ローカル:

```text
qwen_comfy_sh
├─ setup_qwen_comfy.sh
├─ run_batch.sh
├─ Qwen-Rapid-AIO-SaveImage.json
├─ comfyui_cli_batch_手順書.md
└─ README.md
```

## 2. GitHubへpushする

PowerShell:

```powershell
git add setup_qwen_comfy.sh run_batch.sh Qwen-Rapid-AIO-SaveImage.json comfyui_cli_batch_手順書.md README.md
git commit -m "Simplify Qwen batch workflow"
git push
```

以降、Vast側の環境構築はGitHubから `clone → setup_qwen_comfy.sh` で行う。

---

# 第2章 画像生成時にやること

## 1. Vast.aiでRENTする

RTX 5090 32GBなど、使用するインスタンスで **RENT** を押す。

インスタンスが `Running` になったら、Vast.ai に表示されている次の情報を控える。

```text
SSH Host / IP
SSH Port
```

## 2. VastへSSH接続する

Windows PowerShell:

```powershell
$HOST_IP = "<VAST_HOST_IP>"
$SSH_PORT = <VAST_SSH_PORT>
$REMOTE = "root@$HOST_IP"

ssh -p $SSH_PORT $REMOTE
```

## 3. GitHubからcloneしてセットアップする

SSH先で一度だけ実行する。

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

セットアップ完了まで待つ。

これで workflow の配置、`comfy-cli`、ComfyUI、モデル、バッチ用ディレクトリまで準備される。

## 4. Windows側で今回の入力を用意する

例:

```text
D:\qwen_batch\
├─ prompts.json
└─ input\
   ├─ 001.png
   ├─ 002.png
   └─ ...
```

`prompts.json` の形式は README.md を参照する。

## 5. 入力画像と prompts.json をまとめてアップロードする

SSHターミナルとは別の Windows PowerShell で実行する。

```powershell
$HOST_IP = "<VAST_HOST_IP>"
$SSH_PORT = <VAST_SSH_PORT>
$REMOTE = "root@$HOST_IP"
$JOB = "D:\qwen_batch"

ssh -p $SSH_PORT $REMOTE "rm -rf /workspace/qwen_batch/input && mkdir -p /workspace/qwen_batch"
scp -P $SSH_PORT -r "$JOB\input" "$REMOTE`:/workspace/qwen_batch/"
scp -P $SSH_PORT "$JOB\prompts.json" "$REMOTE`:/workspace/qwen_batch/prompts.json"
```

## 6. 1コマンドで画像 × prompt の二重ループを実行する

Windows PowerShellからそのまま実行できる。

```powershell
ssh -p $SSH_PORT $REMOTE "bash /workspace/qwen_comfy_sh/run_batch.sh"
```

例えば画像10枚、prompt10個なら100枚生成する。

実行完了時に出力先が表示される。

```text
/workspace/ComfyUI/output/batch/<RUN_ID>/
```

## 7. 生成画像をWindowsへ回収する

```powershell
New-Item -ItemType Directory -Force "$JOB\output" | Out-Null
scp -P $SSH_PORT -r "$REMOTE`:/workspace/ComfyUI/output/batch" "$JOB\output\"
```

## 8. 利用終了

環境を残す場合は Vast.ai で **Stop**、不要なら **Destroy** を行う。
