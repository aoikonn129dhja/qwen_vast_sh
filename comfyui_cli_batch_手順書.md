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

---

## 2. Jupyter Terminal を開く

Vast.ai のインスタンスが `Running` になったら **Open** を押し、Jupyter を開く。

Jupyter から Terminal を起動し、以降のセットアップコマンドはこの Terminal で実行する。

---

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

`prompts.json` の形式は以下.
```json
[
  "prompt1",
  "prompt2",
  "prompt3"
]
```

## 5. Jupyter から画像とプロンプトをドラッグ＆ドロップする

Vast.ai のインスタンス画面で **Open** を押し、Jupyter を開く。

セットアップ済みなら `/workspace/` に次のフォルダが存在する。

```text
/workspace/
├─ ComfyUI/
├─ qwen_batch/
├─ qwen_comfy_sh/
└─ bin/
```

### 5-1. 入力画像をアップロードする

Jupyter のファイルブラウザで次を開く。

```text
/workspace/qwen_batch/input/
```

ローカルで生成に使う画像を複数選択して Jupyter の `/workspace/qwen_batch/input/` へドラッグ＆ドロップする。

アップロード後、例えば次の状態になる。

```text
/workspace/qwen_batch/input/
├─ 001.png
├─ 002.png
├─ 003.jpg
└─ ...
```

### 5-2. prompts.json をアップロードする

Jupyter で次へ移動する。

```text
/workspace/qwen_batch/
```

ローカルのprompts.jsonをドラッグ＆ドロップする。

最終的に次の状態になればよい。

```text
/workspace/qwen_batch/
├─ prompts.json
├─ input/
│  ├─ 001.png
│  ├─ 002.png
│  ├─ 003.jpg
│  └─ ...
└─ tmp/
```

## 5. 1コマンドで画像 × prompt の二重ループを実行する

Jupyter で Terminal を開き、次を実行する。

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

例えば画像10枚、prompt10個なら100枚生成する。

実行完了時に出力先が表示される。

```text
/workspace/ComfyUI/output/batch/<RUN_ID>/
```

## 6. 生成画像をローカルへ回収する

Jupyter のファイルブラウザで次のディレクトリを開く。

```text
/workspace/ComfyUI/output/batch/
```

今回生成した `<RUN_ID>` フォルダを選び、Jupyter のダウンロード機能でローカルへ保存する。

フォルダ単位でのダウンロードが扱いにくい場合は、Jupyter Terminal で先に圧縮する。

```bash
cd /workspace/ComfyUI/output/batch
tar -czf /workspace/qwen_batch_results.tar.gz <RUN_ID>
```

その後、Jupyter のファイルブラウザで次のファイルを選び、ダウンロードする。

```text
/workspace/qwen_batch_results.tar.gz
```

## 8. 利用終了

環境を残す場合は Vast.ai で **Stop**、不要なら **Destroy** を行う。
