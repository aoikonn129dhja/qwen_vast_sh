# Vast.ai ComfyUI モデル利用手順書

Vast.aiでGPUインスタンスを借り、このリポジトリから使用するモデルを選んでセットアップするための手順書です。

基本方針は「インスタンスをRENTする → リポジトリをcloneする → 使うモデルのディレクトリへ移動する → そのディレクトリの `setup.sh` を実行する」です。モデルごとのファイルは `models/<モデル名>/` に分離されています。ルートの `setup.sh` にモデル名を渡す手順は使いません。

## 1. コマンド早見表

[Vast.aiのダッシュボード](https://cloud.vast.ai/)


Vast.aiでPyTorch系インスタンスをRENTし、Jupyter WebUIのTerminalを開く。前提パスは `/workspace` と `/venv/main/bin/python`。GPUと十分なストレージが必要。モデル間で依存関係とComfyUIの変更があり得るため、安定運用では1インスタンス1モデルを基本とする。

```bash
git clone https://github.com/aoikonn129dhja/qwen_vast_sh.git /workspace/qwen_vast_sh
```

clone済みの場合は次で更新する。未コミットの変更がある場合は先に確認する。

```bash
git -C /workspace/qwen_vast_sh pull --ff-only origin main
```

利用可能なセットアップスクリプトを確認する。旧手順書の `find models ...` は現在のディレクトリ構成と一致しない。

```bash
find /workspace/qwen_vast_sh/vast/models -mindepth 2 -maxdepth 2 -type f -name setup.sh -printf '%h\n'
```

**使いたいモデルを1つ選び**、以下の該当コマンドだけを実行する。ルートにある共通 `setup.sh` にモデル名を渡す方式ではない。

```bash
# Qwen Rapid v19
cd /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v19 && bash setup.sh

# Qwen Rapid v23
cd /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v23 && bash setup.sh

# Qwen Image Edit 2509
cd /workspace/qwen_vast_sh/vast/models/qwen-image-edit-2509 && bash setup.sh

# Qwen Image Edit 2511
cd /workspace/qwen_vast_sh/vast/models/qwen-image-edit-2511 && bash setup.sh

# LTX-2.3 Q4
cd /workspace/qwen_vast_sh/vast/models/ltx-2.3-uncensored-v1.4-q4 && bash setup.sh
```

モデルのダウンロード元への事前速度測定を行うセットアップがある。Qwen系列では既定10 MiB/s未満の場合に続行確認または非対話実行の停止が発生し得る。必要な場合のみ `ALLOW_SLOW_DOWNLOAD=1 bash setup.sh` を使う。速度判定を無効化しても、ダウンロードそのものが速くなるわけではない。


### Comfy UI 開き方
Create tunnelで
```
http://localhost:8188
```
を追加,URLをコピーして開く.

bad gatewayの場合,以下で確認.JSONが返却されれば,Comfyは起動済み
```
curl --fail --silent http://127.0.0.1:8188/system_stats
```


### リポジトリを更新

```bash
cd /workspace/qwen_vast_sh
git pull --ff-only origin main
```

### /workspace/ComfyUI/output/の生成物の回収
```
cd /workspace/ComfyUI
zip -r "output/videos_$(date +%Y%m%d_%H%M%S).zip" output -x "output/videos_*.zip"
```

### Qwen Rapid v19のバッチ生成

```bash
# 入力画像とほぼ同じ縦横比、約315万画素で生成
MATCH_INPUT_ASPECT=1 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh

# 幅と高さを指定して生成
WIDTH=1536 HEIGHT=2048 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh

# 標準の1536×2048で生成
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

### よく使う確認コマンド

```bash
# ComfyUIのログ
tail -n 100 /workspace/comfyui.log

# ComfyUIの起動確認
curl --fail --silent http://127.0.0.1:8188/system_stats >/dev/null && echo "ComfyUI is ready"

# Rapid v19の入力画像
ls -lah /workspace/qwen_batch/input

# Rapid v19のプロンプト
sed -n '1,120p' /workspace/qwen_batch/prompts.md

# Rapid v19の生成結果
find /workspace/qwen_batch/output -maxdepth 2 -type f | head -n 50

# Rapid v19の複数回分の出力を1フォルダへまとめる
bash /workspace/qwen_vast_sh/scripts/flatten_output.sh
```

## 2. 共通セットアップ

### 2.1 Vast.aiでインスタンスをRENTする

Vast.aiでGPUインスタンスをRENTします。インスタンスが `Running` になったら、`Open` からJupyter WebUIを開き、Terminalを起動します。

セットアップスクリプトは `/workspace`、`/venv/main/bin/python`、NVIDIA GPUが利用できるVast.aiのPyTorch系環境を前提としています。モデル本体は数十GBになるため、十分なディスク容量があるインスタンスを選んでください。

### 2.2 リポジトリをcloneする

新しくRENTしたインスタンスでは、最初に次を実行します。

```bash
git clone https://github.com/aoikonn129dhja/qwen_vast_sh.git /workspace/qwen_vast_sh
cd /workspace/qwen_vast_sh
```

すでにclone済みなら、cloneし直さず更新します。

```bash
cd /workspace/qwen_vast_sh
git pull --ff-only origin main
```

### 2.3 セットアップスクリプトがあるモデルを確認する

```bash
cd /workspace/qwen_vast_sh
find models -mindepth 2 -maxdepth 2 -type f -name setup.sh -printf '%h\n'
```

表示されたパスがセットアップ可能なモデルのディレクトリです。`models/` 直下には参照用workflowだけのディレクトリもあるため、`setup.sh` があるディレクトリを選びます。

### 2.4 モデルのディレクトリへ移動してセットアップする

```bash
cd /workspace/qwen_vast_sh/models/<モデルのディレクトリ名>
bash setup.sh
```

例として、Qwen Image Edit 2511を使う場合:

```bash
cd /workspace/qwen_vast_sh/models/qwen-image-edit-2511
bash setup.sh
```

モデルによってComfyUI本体、カスタムノード、Python依存関係の構成が異なります。同じインスタンスへ複数モデルを順番に導入すると、後から実行したsetupがComfyUIや依存関係を更新することがあります。安定性を優先する場合は、1インスタンスにつき1モデルを使用してください。

### 2.5 ComfyUIを開く

setupが完了したら、Vast.aiのインスタンス画面で `Tunnels (Open New Ports)` を開きます。

1. `Manage Tunnels` の入力欄へ `http://localhost:8188` と入力する。
2. `Create New Tunnel` をクリックする。
3. 一覧に追加された行の `Tunnel URL` を開く。

ノードが並ぶComfyUI画面はポート `8188` です。`1111`、`8080`、`8384`、`6006` など、最初から表示される別ポートではありません。

この方法で作成したComfyUIのTunnel URLには認証がありません。URLを他人へ共有せず、作業終了後は対象行の `Manage` からトンネルを削除してください。

## 3. モデル別の概要と使い方

### 3.1 Qwen Rapid AIO NSFW v19

モデルディレクトリ名:

```text
qwen-rapid-aio-nsfw-v19
```

入力画像と複数のプロンプトの全組み合わせを、コマンド1つで順番に生成するモデルです。このリポジトリでバッチ生成に対応しているのはこのモデルだけです。

#### セットアップ

```bash
cd /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19
bash setup.sh
```

ComfyUI、モデル、固定済み依存関係、バッチ用workflow、認証付きプレビューに必要なファイルが準備されます。

#### 入力画像を配置

Jupyterのファイルブラウザから、画像を次へアップロードします。

```text
/workspace/qwen_batch/input/
```

対応形式はPNG、JPG、JPEG、WebPです。サブディレクトリ内の画像は処理されないため、`input/` 直下へ置きます。

#### prompts.mdを編集

```text
/workspace/qwen_batch/prompts.md
```

複数行プロンプトは、`##` で始まる見出しごとに分けます。

```markdown
# Qwen prompts

## 1
first prompt

## 2
second prompt
```

有効な `##` 見出しが1つもなければ、Markdown見出しと空行を除く各行が1プロンプトとして扱われます。

#### バッチ生成を開始

```bash
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

開始時に表示される `Images`、`Prompts`、`Total` を確認してください。`Total` は `Images × Prompts` です。

`MATCH_INPUT_ASPECT=1` を指定すると、入力画像ごとに縦横比を計算し、約315万画素になるよう幅と高さを64px刻みに丸めます。

```bash
MATCH_INPUT_ASPECT=1 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

`WIDTH` と `HEIGHT` で出力サイズを固定することもできます。

```bash
WIDTH=1536 HEIGHT=2048 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

`MATCH_INPUT_ASPECT=1` と `WIDTH` または `HEIGHT` は同時に指定できません。入力画像が基準画素数の105%を超える場合は、元画像を変更せず、モデルへ渡す直前に縦横比を保って縮小されます。

#### ライブプレビュー

Terminalに表示される `Preview URL` をブラウザで開きます。

```text
user     : qwen
password : Terminalに表示された20文字のパスワード
```

このプレビューは認証付きで、ComfyUI本体のポート8188とは別です。Preview URLが開けなくなった場合は、生成処理を止めずにQuick Tunnelだけを再起動できます。

```bash
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/restart_preview_tunnel.sh
```

#### 生成中の注意

- `run_batch.sh` は同時に複数起動しない。
- 現在生成中の `/workspace/qwen_batch/output/<RUN_ID>/` を移動または削除しない。
- 生成中に `flatten_output.sh` を実行しない。
- 入力画像一覧と `prompts.md` は開始時に固定される。開始後の変更は次回のバッチから反映される。

#### 結果をまとめて回収

Terminalに `COMPLETE` が表示されてから実行します。

```bash
bash /workspace/qwen_vast_sh/scripts/flatten_output.sh
```

複数のRUN_IDに分かれた画像が、次へまとめられます。

```text
/workspace/qwen_batch/output/yyyy_mmdd_hhmm/
```

既存画像は上書きされません。Jupyterのファイルブラウザから、このフォルダをダウンロードします。

### 3.2 Qwen Image Edit 2509

モデルディレクトリ名:

```text
qwen-image-edit-2509
```

ComfyUIの画面上で操作するQwen Image Edit 2509です。DWPoseとAnimePoseも準備されます。リポジトリ管理のバッチ実行には対応していません。

#### セットアップ

```bash
cd /workspace/qwen_vast_sh/models/qwen-image-edit-2509
bash setup.sh
```

同梱している公式系workflowが、次の名前でComfyUIへ配置されます。

```text
Qwen-Image-Edit-2509-official.json
```

セットアップ後にComfyUIを開き、このworkflowを読み込みます。人物画像を `image1`、DWPoseまたはAnimePoseで作成した骨格画像を `image2` へ接続して使用します。

### 3.3 Qwen Image Edit 2511

モデルディレクトリ名:

```text
qwen-image-edit-2511
```

ComfyUIの画面上で操作するQwen Image Edit 2511 FP8 mixedです。DWPoseとAnimePoseも準備されます。リポジトリ管理のバッチ実行には対応していません。

#### セットアップ

```bash
cd /workspace/qwen_vast_sh/models/qwen-image-edit-2511
bash setup.sh
```

同梱している公式系workflowが、次の名前でComfyUIへ配置されます。

```text
Qwen-Image-Edit-2511-official.json
```

セットアップ時に、公式workflow内のBF16モデル名が、実際に導入するFP8 mixedモデル名へ置換されます。セットアップ後にComfyUIを開き、このworkflowを読み込みます。

### 3.4 LTX-2.3 Uncensored Turbo v1.4 Q4_K_M

モデルディレクトリ名:

```text
ltx-2.3-uncensored-v1.4-q4
```

ChrisColeTech配布のLTX-2.3 Uncensored Turbo v1.4を、Q4_K_MのGGUF構成で動かす画像・動画生成モデルです。このリポジトリでは、主に入力画像から動画を生成するI2V用途を想定しています。

#### セットアップ

```bash
cd /workspace/qwen_vast_sh/models/ltx-2.3-uncensored-v1.4-q4
bash setup.sh
```

次のモデルファイルと `ComfyUI-GGUF-Loader` が導入されます。

- `ltxv23_uncensored_v1.4_Q4_K_M.gguf`
- `gemma-3-12b-it-ablit-norms-biproj-Q4_K_M.gguf`
- `ltxv23_uncensored_v1.4_projections.safetensors`
- `ltxv23_uncensored_v1.4_video_vae.safetensors`
- `ltxv23_uncensored_v1.4_audio_vae.safetensors`
- `ChrisColeTech/ComfyUI-GGUF-Loader`

x2 spatial upscaler、追加LoRA、音声参照用素材は初期セットアップに含まれません。

セットアップは `[1/5]` から `[5/5]` まで段階を表示します。モデルファイルの取得前に Hugging Face から最大8 MiBを読み、回線速度を測定します。取得中は現在のファイル番号（例: `[2/5]`）と、5ファイル合計の進捗率・実測速度・残り時間の目安が約5秒ごとに表示されます。この残り時間はモデルファイルの転送分のみで、ComfyUIや依存ライブラリの導入時間は含みません。再実行すると、完了済みファイルはスキップし、途中ファイルは続きから取得します。

#### I2V workflowを読み込む

このモデル用の最小I2V workflowは次です。

```text
/workspace/qwen_vast_sh/models/ltx-2.3-uncensored-v1.4-q4/LTX-2.3_Uncensored_v1.4_Q4_I2V.json
```

LTXのsetupは、このJSONをComfyUIの保存済みworkflow一覧へ自動コピーしません。JupyterのファイルブラウザからJSONを手元へダウンロードし、ComfyUI画面へドラッグ＆ドロップするか、ComfyUIの `Load` から読み込んでください。

読み込み後は、`LoadImage` で入力画像を選択してプロンプトを編集します。`LTXV23ModelsLoader` の各欄では、setupで導入された上記5つのモデルファイルを選択します。

最初に試す値の目安:

```text
LTXV23ImgToVideo
  image_strength = 0.7
  length         = 121
  frame_rate     = 24

LTXV23KSampler
  schedule       = dmd (8 steps)
  steps          = 8
  cfg            = 1.0
  sampler_name   = euler
```

フレーム数は `8k+1` の形にします。例は49、97、121です。

次のJSONはLightricks公式のtwo-stage workflowを保存した参照用ファイルです。ChrisColeTechのsplit GGUF構成でそのまま動作することを保証するものではありません。

```text
/workspace/qwen_vast_sh/models/ltx-2.3-uncensored-v1.4-q4/LTX-2.3_T2V_I2V_Two_Stage_Distilled.json
```

モデル配布元ではライセンスが `unknown` と表示されています。商用利用や再配布を行う場合は、利用者自身で最新のライセンス条件を確認してください。

### 3.5 Qwen Rapid AIO v1 reference

```text
models/qwen-rapid-aio-v1-reference/
```

これは2入力参照workflowの保管場所で、セットアップ可能なモデルではありません。このディレクトリには `setup.sh` がありません。モデル配布元とSHA-256が未定義で、workflowにSaveImageノードもないため、実行用workflowと混同しないでください。

## 4. 余談

### 旧リポジトリ名からの移行

旧リポジトリを `/workspace/qwen_comfy_sh` にclone済みの場合は、最初の1回だけ次を実行します。

```bash
mv /workspace/qwen_comfy_sh /workspace/qwen_vast_sh
git -C /workspace/qwen_vast_sh remote set-url origin https://github.com/aoikonn129dhja/qwen_vast_sh.git
git -C /workspace/qwen_vast_sh pull --ff-only origin main
```

### StopとDestroy

- 後で同じ環境を使う場合は、Vast.ai画面で `Stop` を選ぶ。
- 環境を完全に破棄する場合は、必要な生成物を回収してから `Destroy` を選ぶ。
- `Destroy` すると `/workspace` の内容も失われる。

### セキュリティ

- ComfyUIのポート8188をVast.ai Tunnelで公開した場合、そのURLには認証がない。
- Rapid v19の `Preview URL` は認証付きだが、URLとパスワードを同時に共有しない。
- Terminalのスクリーンショットには、URLやパスワードが写り込む可能性がある。
- 作業終了後は、不要になったTunnelを削除する。

### 詳細資料

- リポジトリ全体とRapid v19の詳細: [README.md](./README.md)
- モデルディレクトリの規約: [models/README.md](./models/README.md)
- Rapid v19: [models/qwen-rapid-aio-nsfw-v19/README.md](./models/qwen-rapid-aio-nsfw-v19/README.md)
- Qwen Image Edit 2509: [models/qwen-image-edit-2509/README.md](./models/qwen-image-edit-2509/README.md)
- Qwen Image Edit 2511: [models/qwen-image-edit-2511/README.md](./models/qwen-image-edit-2511/README.md)
- LTX-2.3 v1.4 Q4: [models/ltx-2.3-uncensored-v1.4-q4/README.md](./models/ltx-2.3-uncensored-v1.4-q4/README.md)
