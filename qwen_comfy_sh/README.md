# qwen_comfy_sh

Vast.ai 上に Qwen Rapid AIO NSFW v19 + ComfyUI を構築し、保存済み ComfyUI workflow を使って **入力画像 × prompts.json の全組み合わせ**をバッチ生成するためのリポジトリ。

Windows 側に `comfy-cli` は導入しない。Windows は SSH / SCP だけを使い、画像生成は Vast 側の `comfy-cli` と ComfyUI で行う。

## リポジトリ構成

```text
qwen_comfy_sh/
├─ setup_qwen_comfy.sh
├─ run_batch.sh
├─ Qwen-Rapid-AIO-SaveImage.json
├─ comfyui_cli_batch_手順書.md
└─ README.md
```

## 基本設計

```text
Windows
  │
  ├─ SSH / SCP
  ▼
Vast.ai
  ├─ /workspace/qwen_comfy_sh/
  │    ├─ setup_qwen_comfy.sh
  │    ├─ run_batch.sh
  │    └─ Qwen-Rapid-AIO-SaveImage.json
  │
  ├─ /workspace/qwen_batch/
  │    ├─ prompts.json
  │    └─ input/
  │
  └─ /workspace/ComfyUI/
       ├─ models/checkpoints/
       ├─ input/
       ├─ output/
       └─ user/default/workflows/
```

## setup_qwen_comfy.sh が行うこと

Vast の新規インスタンスで次を一度実行する。

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

`setup_qwen_comfy.sh` は自動で次を行う。

1. GPU / Disk を確認する。
2. Hugging Face への実ダウンロード速度を事前測定する。
3. ComfyUI を `/workspace/ComfyUI` に clone / 修復する。
4. ComfyUI requirements をインストールする。
5. 公式 `comfy-cli` を Vast の `/venv/main` にインストールする。
6. `comfy set-default /workspace/ComfyUI` を設定する。
7. `Qwen-Rapid-AIO-NSFW-v19.safetensors` をダウンロードする。
8. Phr00t の `nodes_qwen.v2.py` を導入する。
9. リポジトリ内の `Qwen-Rapid-AIO-SaveImage.json` を次へコピーする。

```text
/workspace/ComfyUI/user/default/workflows/Qwen-Rapid-AIO-SaveImage.json
```

10. バッチ用ディレクトリを作成する。

```text
/workspace/qwen_batch/input/
/workspace/qwen_batch/tmp/
```

11. ComfyUI を `127.0.0.1:8188` で起動する。
12. Cloudflare Quick Tunnel を起動し、GUI用URLを表示する。

したがって、セットアップ後に `comfy-cli` や workflow を手動インストール・コピーする作業は不要。

## workflow

バッチのベースは次の GUI 保存形式 workflow。

```text
Qwen-Rapid-AIO-SaveImage.json
```

この workflow では、バッチ処理に使う主要な slot address が固定されている。

| address | 用途 |
|---|---|
| `8.image` | 編集元画像 |
| `3.prompt` | ポジティブプロンプト |
| `4.prompt` | ネガティブプロンプト |
| `2.seed` | seed |
| `2.steps` | steps |
| `2.cfg` | CFG |
| `2.sampler_name` | sampler |
| `2.scheduler` | scheduler |
| `2.denoise` | denoise |
| `9.width` | 出力幅 |
| `9.height` | 出力高さ |
| `10.filename_prefix` | 保存ファイル名 prefix |

`run_batch.sh` はこのアドレスを使用するため、実行のたびにノード ID を調査する必要はない。

確認したい場合のみ次を使う。

```bash
/venv/main/bin/comfy --where local workflow slots \
  /workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
```

## prompts.json

`prompts.json` は **JSON文字列配列**にする。

```json
[
  "prompt 1",
  "prompt 2",
  "prompt 3"
]
```

日本語、英語、空白、引用符などは JSON として正しくエスケープされていれば使用できる。

空配列、空文字列、文字列以外の要素は `run_batch.sh` がエラーにする。

## 入力画像

標準のアップロード先は次。

```text
/workspace/qwen_batch/input/
```

対応拡張子:

```text
.png
.jpg
.jpeg
.webp
```

`run_batch.sh` は実行開始時に、入力画像を一意な run ID の付いた ComfyUI input 以下へコピーする。

```text
/workspace/ComfyUI/input/batch/<RUN_ID>/
```

そのため、元の `/workspace/qwen_batch/input/` はジョブ投入用の受け皿として使える。

## バッチ実行

標準パスに `input/` と `prompts.json` がある場合は、引数なしで実行できる。

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

例えば画像10枚、prompt10個なら、次の100ジョブを順番に生成する。

```text
10 images × 10 prompts = 100 jobs
```

各ジョブは公式 `comfy-cli` の次の処理で実行される。

```text
comfy workflow set-slot
        ↓
comfy run --workflow ... --wait
```

独自の ComfyUI API クライアントや `/prompt` POST 実装は使用しない。

### パスを変更する場合

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh \
  /path/to/input \
  /path/to/prompts.json
```

別 workflow を指定する場合のみ第3引数を使う。

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh \
  /path/to/input \
  /path/to/prompts.json \
  /path/to/workflow.json
```

## 生成パラメータの上書き

何も指定しなければ、workflow JSON に保存されている値をそのまま使用する。

必要な値だけ環境変数で上書きできる。

```bash
DENOISE=0.9 \
STEPS=6 \
CFG=1 \
SAMPLER=er_sde \
SCHEDULER=beta \
WIDTH=1536 \
HEIGHT=2048 \
SEED=123456 \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

ネガティブプロンプトも全ジョブ共通で上書きできる。

```bash
NEGATIVE_PROMPT="negative prompt" \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

## 出力

生成結果は workflow の `SaveImage` ノードで次へ保存される。

```text
/workspace/ComfyUI/output/batch/<RUN_ID>/
```

ファイル名 prefix は次の形式。

```text
<入力画像stem>_p001
<入力画像stem>_p002
...
```

例えば:

```text
001_p001_00001_.png
001_p002_00001_.png
002_p001_00001_.png
```

実行完了時に `RUN_ID` と出力ディレクトリが表示される。

## Windows からのアップロード例

PowerShell:

```powershell
$HOST_IP = "<VAST_HOST_IP>"
$SSH_PORT = <VAST_SSH_PORT>
$REMOTE = "root@$HOST_IP"
$JOB = "D:\qwen_batch"

ssh -p $SSH_PORT $REMOTE "rm -rf /workspace/qwen_batch/input && mkdir -p /workspace/qwen_batch"
scp -P $SSH_PORT -r "$JOB\input" "$REMOTE`:/workspace/qwen_batch/"
scp -P $SSH_PORT "$JOB\prompts.json" "$REMOTE`:/workspace/qwen_batch/prompts.json"
```

PowerShell では `$REMOTE:` が変数名として解釈されるのを避けるため、例ではバッククォートを入れている。

## Windows から1コマンドでバッチ開始

アップロード後:

```powershell
ssh -p $SSH_PORT $REMOTE "bash /workspace/qwen_comfy_sh/run_batch.sh"
```

## 出力回収例

```powershell
New-Item -ItemType Directory -Force "$JOB\output" | Out-Null
scp -P $SSH_PORT -r "$REMOTE`:/workspace/ComfyUI/output/batch" "$JOB\output\"
```

## 回線速度判定

`setup_qwen_comfy.sh` は Vast.ai の表示上の Download 値ではなく、実際に Hugging Face のモデルURLから少量ダウンロードして速度を測る。

目安:

```text
20 MiB/s 以上   推奨
10–20 MiB/s     使用可能だがモデルDLに時間がかかる
10 MiB/s 未満   別ホストを推奨
```

低速判定時は setup が確認を求める。

強制続行:

```bash
ALLOW_SLOW_DOWNLOAD=1 bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

## comfy-cli について

`comfy-cli` は Windows ではなく Vast 側にだけ入る。

確認:

```bash
/venv/main/bin/comfy --version
/venv/main/bin/comfy --json env
```

現在の構成では `comfy run --workflow` が GUI 保存形式 workflow を実行時に API format へ変換する。

## UI → API 変換について

`comfy-cli` は GUI 保存形式 workflow を実行できるが、ComfyUI / comfy-cli の特定の multi-type input では UI → API 変換の既知不具合が報告されている。

現在の Qwen workflow はまずそのまま使用する。実際に `workflow_not_api_format` / `conversion_error` が発生した場合のみ、ComfyUI GUI の **Workflow → Export (API)** を使う fallback を検討する。

通常運用で事前に API JSON を別管理する必要はない。

## Public GitHub に置く場合の注意

GUI 保存形式 workflow には、最後に設定していた次のような値も含まれる。

- prompt
- negative prompt
- LoadImage のファイル名
- seed
- 各種 generation parameters

リポジトリが Public の場合、workflow JSON に残っている文字列も公開される。

公開したくない値がある場合は commit 前に workflow 内の prompt / input filename をダミー値へ変更する。

`run_batch.sh` は `3.prompt` と `8.image` を生成ごとに上書きするため、テンプレート上の prompt と入力画像名はバッチ実行時には使われない。

## トラブルシューティング

### `comfy-cli not found`

setup が完了していない。

```bash
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

### `ComfyUI is not responding`

```bash
tail -n 100 /workspace/comfyui.log
```

### 入力画像がない

```bash
ls -lah /workspace/qwen_batch/input
```

### prompts.json の確認

```bash
cat /workspace/qwen_batch/prompts.json
```

### ComfyUI のキュー確認

```bash
/venv/main/bin/comfy --where local jobs ls
```

### workflow slot の確認

```bash
/venv/main/bin/comfy --where local workflow slots \
  /workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
```

## 前提環境

この setup は Vast.ai の **PyTorch (Vast)** 系テンプレートを前提とし、次を使用する。

```text
/venv/main/bin/python
/venv/main/bin/pip
/workspace
```

他のテンプレートではパスが異なる可能性がある。
