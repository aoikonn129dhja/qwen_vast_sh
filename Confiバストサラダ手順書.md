# Vast.ai・SaladCloud モデル利用手順書

## Codex スキル経由で使う場合（最初に読む）

1. Vast.ai では GPU インスタンスを RENT、SaladCloud では共通イメージの Container Group を Run して、SSH 接続コマンドを取得する。
2. このプロジェクトを開いた Codex に、SSH 接続コマンドを渡して「`remote-model-setup` スキルでセットアップしたい」と伝える。例: `ssh -p <ポート> root@<ホスト>`。SSH 鍵のパスや `-L` オプションを含む普段の接続コマンドも渡せる。
3. Codex に「今日はどのモデルを使いますか」と聞かれたらモデル名を選ぶ。Codex がこの Windows 側リポジトリから**コード・設定・ワークフローだけ**を SSH で転送・検証する。モデル本体は転送せず、リモートでの `git clone` も不要。
4. Codex が返す **PowerShell 用の `ssh -tt ...` セットアップコマンドを自分の端末で実行する**。モデルの試験ダウンロード、速度警告、本ダウンロード、SHA-256 検証、セットアップの進捗をその端末で確認する。Codex はこのセットアップコマンドを実行しない。

SaladCloud では LightWan 2.2 A14B を選べない。SaladCloud のコマンドはコンテナ内の `/opt/salad/select_model.sh`、Vast.ai のコマンドは選んだモデルの `setup.sh` を実行する。転送に失敗した場合、Codex はセットアップコマンドを提示しない。SaladCloud は SSH 単発コマンドが成功時にも終了コード `1` を返す場合があるため、末尾の `SETUP COMPLETE` / `Model setup complete` とエラー表示を確認する。

既存のモデルファイルは毎回 SHA-256 を計算し、一致すれば再利用する。不一致ならファイルを残して停止する。未取得モデルがある場合は Hugging Face から最大 8 MiB を試験取得し、既定の 10 MiB/s 未満なら警告して続行を確認する。速度測定に失敗した場合は警告して取得を続ける。SaladCloud は再配置でコンテナのローカルストレージが消える場合があり、その場合はモデルの再取得が必要になる。

以下の Vast.ai の clone・pull 手順は、Codex を使わず手動で配置する場合の手順。SaladCloud の共通イメージ、起動、Gateway、回収は後半の「SaladCloud」節にまとめた。

## 1. Vast.ai を手動でセットアップする場合

[Vast.aiのダッシュボード](https://cloud.vast.ai/)


Vast.aiでPyTorch系インスタンスをRENTし、Jupyter WebUIのTerminalを開く。前提パスは `/workspace` と `/venv/main/bin/python`。GPUと十分なストレージが必要。モデルごとの ComfyUI と Python 環境は分離されるが、同時に実行する場合はモデルごとの VRAM 容量を確保する。

```bash
git clone https://github.com/aoikonn129dhja/qwen_vast_sh.git /workspace/qwen_vast_sh
```

clone済みの場合は次で更新する。未コミットの変更がある場合は先に確認する。

```bash
git -C /workspace/qwen_vast_sh pull --ff-only origin main
```

利用可能なセットアップスクリプトを確認する。

```bash
find /workspace/qwen_vast_sh/models -mindepth 2 -maxdepth 2 -type f -name setup.sh -printf '%h\n'
```

**使いたいモデルを1つ選び**、以下の該当コマンドだけを実行する。ルートにある共通 `setup.sh` にモデル名を渡す方式ではない。

```bash
# Qwen Rapid v19
cd /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19 && bash setup.sh

# Qwen Rapid v23
cd /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v23 && bash setup.sh

# Qwen Image Edit 2509
cd /workspace/qwen_vast_sh/models/qwen-image-edit-2509 && bash setup.sh

# Qwen Image Edit 2511
cd /workspace/qwen_vast_sh/models/qwen-image-edit-2511 && bash setup.sh

# LTX-2.3 Q4
cd /workspace/qwen_vast_sh/models/ltx-2.3-uncensored-v1.4-q4 && bash setup.sh

# Wan2.2 TI2V 5B Turbo
cd /workspace/qwen_vast_sh/models/wan2.2-ti2v-5b-turbo && bash setup.sh
```

モデル取得前に Hugging Face の速度を測り、既定 10 MiB/s 未満では続行確認する。非対話実行では停止するため、低速でも続けると決めた場合だけ `ALLOW_SLOW_DOWNLOAD=1 bash setup.sh` を使う。速度判定を無効化しても、ダウンロードそのものが速くなるわけではない。


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

### 自動画像回収スクリプト (Vast.ai)
Windowsでリポジトリのルートに移動して
```sh
python local_tools\vast_comfy_output_sync_and_log.py
```

を実行,comfy UIのURLを入力.例えば`https://but-fig-leading-sperm.trycloudflare.com/`
保存先はスクリプト内で指定された `D:\po\NSFW_cos\tmp`。

### タスクマネージャーの開き方
```bash
watch -n 1 nvidia-smi
```

見やすい版（GPU・VRAM・温度のバーと詳細情報を同時表示）:

```bash
bash /workspace/qwen_vast_sh/scripts/gpu_task_manager.sh
```

### ComfyUIの再起動
#### 再起動コマンド
```sh
bash /workspace/qwen_vast_sh/scripts/restart_comfyui.sh
```

中身は
```sh
pkill -f '[p]ython.*main.py' || true
sleep 2

cd /workspace/ComfyUI

nohup /venv/main/bin/python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  > /workspace/comfyui.log 2>&1 &
```

#### 再起動確認
```sh
tail -f /workspace/comfyui.log
```

### モデルをVRAMにロード/アンロード
モデルはワークフロー実行時に自動でVRAMへ読み込まれるため、ロードコマンドは不要。
別モデルへ切り替えるときは以下のアンロードコマンドを使用
```sh
python /workspace/qwen_vast_sh/scripts/runtime/runtime_control.py unload
```

### 補助ツールの配置と使い方

```text
qwen_vast_sh/
├─ scripts/                         # Vast.ai／SaladCloudのLinux環境で使う
│  ├─ gpu_task_manager.sh           # GPU監視
│  ├─ comfy_diagnose.sh             # ComfyUIの接続診断
│  └─ setup_qwen_edit_model.sh      # Qwen Image Editのセットアップ共通処理
└─ local_tools/                     # Windows側で使う
   └─ vast_comfy_output_sync_and_log.py  # ComfyUIの生成物とログを回収
```

- `gpu_task_manager.sh`: GPU・VRAM・温度のバー、GPUプロセス、CPU・RAMなどを1秒ごとに表示する。Vast.aiのターミナルで `bash /workspace/qwen_vast_sh/scripts/gpu_task_manager.sh` を実行し、`Ctrl+C` で終了する。
- `comfy_diagnose.sh`: ComfyUIのプロセス、ポート、ローカルHTTP応答、ログのエラー分類を読み取り専用で確認する。Vast.aiまたはSaladCloudのターミナルで `bash /workspace/qwen_vast_sh/scripts/comfy_diagnose.sh` を実行する。外部からの到達性は確認しない。
- `setup_qwen_edit_model.sh`: Qwen Image Editモデルのセットアップ共通処理。直接実行せず、対象モデルの `models/<モデル名>/setup.sh` から利用する。
- `vast_comfy_output_sync_and_log.py`: Windows側からComfyUIの生成物を回収し、生成条件をCSVに記録する。別途解説.

### Qwen Rapid v19のバッチ生成

```bash
# 入力画像とほぼ同じ縦横比、約315万画素で生成
MATCH_INPUT_ASPECT=1 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh

# 幅と高さを指定して生成
WIDTH=1536 HEIGHT=2048 bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh

# 標準の1536×2048で生成
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

### Qwen Rapid v23の対話式バッチ生成

Windows側のターミナルでリポジトリのルートに移動し、VastのSSH接続先を指定して起動します。SSH設定のホスト名、`ユーザー@ホスト`、またはVast CLIの `ssh-url` が返す `ssh://ユーザー@ホスト:ポート` を指定できます。

```powershell
python local_tools\qwen_v23_batch.py ssh://root@ホスト:ポート
```

普段のSSHコマンドも、そのまま後ろに指定できます。

```powershell
python local_tools\qwen_v23_batch.py ssh -p 40455 root@ssh.example.com -L 8080:localhost:8080
```

`-L` は接続コマンドとの互換性のため受け付けます。バッチの転送・実行には使わず、ポート転送を継続する必要がある場合は別のSSHターミナルで起動します。

起動時にVast側のバッチスクリプトが対応版か確認し、旧版なら画像転送前に停止します。確認後、出力の縦横比を「入力画像ごとに維持」か「比率を指定」から選びます。指定する場合は `3:4` や `16:9` のように入力します。その後、画像が入ったWindowsディレクトリのフルパスとプロンプトを入力します。プロンプトは複数行をそのまま貼り付けられ、最後に `.` だけの行を入力してEnterを押します。PNG、JPG、JPEG、WebPの画像をディレクトリ直下から読み取り、SSH経由でVastへ転送します。転送中はファイルごとの進捗を表示します。サブディレクトリは対象外です。

V23の参照workflowと同じく、入力画像はLanczosで約100万画素に調整してモデルへ渡し、出力も選んだ縦横比で約100万画素にします。小さい入力画像は拡大される場合があります。生成した各画像は入力ファイルの名前を保存名のプレフィックスとして使います。

生成画像は `/workspace/ComfyUI/output/` に残ります。Windowsへの回収は、従来どおり `python local_tools\vast_comfy_output_sync_and_log.py` を別のターミナルで起動し、ComfyUIのGateway URLまたはSSHポート転送URLを入力します。V23バッチの実行前から同期ツールを起動しても構いません。

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
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/flatten_output.sh
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

モデルによって ComfyUI 本体、カスタムノード、Python 依存関係の構成が異なる。現在のセットアップはモデル別の ComfyUI と Python 環境を使い、モデルファイル・入力・出力を共有する。複数モデルを同時実行する場合は GPU の VRAM 容量を確認する。

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

入力画像と複数のプロンプトの全組み合わせを、コマンド1つで順番に生成するモデルです。V23には別途、Windows側から起動する対話式バッチがあります。

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
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/flatten_output.sh
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

x2 spatial upscaler は初期セットアップで取得する。追加 LoRA と音声参照用素材は含まれない。

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

### 3.6 Wan2.2-TI2V-5B-Turbo FP16

通常版 `wan2.2-ti2v-5b` の構成を流用した、4ステップの画像から動画を生成するI2Vモデルです。

#### 更新・セットアップ

clone済みの本番環境では、次を実行します。

```bash
cd /workspace/qwen_vast_sh
git pull --ff-only origin main
bash models/wan2.2-ti2v-5b-turbo/setup.sh
```

Turbo用の `Wan2_2-TI2V-5B-Turbo_fp16.safetensors` を取得します。通常版と同じテキストエンコーダ `umt5_xxl_fp8_e4m3fn_scaled.safetensors` とVAE `wan2.2_vae.safetensors` を使用し、配置済みなら再取得しません。追加LoRA・カスタムノードは不要です。

最初にGPU・ディスクを表示し、ComfyUI取得や依存インストールの前にHugging Faceから最大8 MiBを読んで回線速度を測定します。v23と同じくMiB/s・Mbpsと未取得分の推定ダウンロード時間を表示します。既定10 MiB/s未満では続行確認し、非対話実行では停止します。低速でも続行する場合のみ `ALLOW_SLOW_DOWNLOAD=1 bash setup.sh` を指定します。測定失敗時は警告して続行します。

初回のモデル合計は約18.33 GB。既存ファイルは SHA-256 が一致すれば再取得せず、全モデルが揃っている場合は速度測定も省略する。

ログ先頭の `[1/10]` ～ `[10/10]` は、GPU・ディスク、速度確認、ロック・Python環境、ComfyUI本体、Python依存、Hugging Faceライブラリ、Turbo本体、テキストエンコーダ、VAE、サービス起動の順です。モデル関連は `[8/10] [2/3 files]` のようにファイル番号と、`completed 1/3 files` の配置完了数も表示します。既存ファイルは `SKIP`、各段階の完了は `DONE` と表示します。

時間のかかる処理では5秒ごとに実行中ログを表示します。ダウンロード・再構築後のローカルコピー中も、配置量・パーセント・速度・残り秒数を表示します。Hugging Faceのバーが100%でも、配置コピー完了までは処理中です。ログ例は [Turbo版READMEの進捗ログ](models/wan2.2-ti2v-5b-turbo/README.md#進捗ログ) を参照してください。

更新後のsetupは全モデル共通の `/workspace/.qwen-setup.lock` を使います。別ターミナルで他モデルのsetupを同時に起動しても、セットアップ本体は順番に進み、後続には待機メッセージを表示します。速度測定はロック取得前のため、ほかのダウンロードの影響を受けます。旧版のsetupが動いている場合は、終了してから更新版を実行してください。複数モデルの同時生成でのVRAM容量は別途必要です。

Gatewayの公開ポートは8188、Turbo専用ComfyUIの内部ポートは18225です。Vast.ai Tunnelには `http://localhost:8188` を指定します。

#### I2V workflowを読み込む

セットアップで次のworkflowが自動配置されます。既存の同名workflowは上書きしません。

```text
/workspace/ComfyUI/user/default/workflows/Wan-2.2-TI2V-5B-Turbo.json
```

1. ComfyUIの保存済みworkflow一覧から `Wan-2.2-TI2V-5B-Turbo.json` を開く。
2. `LoadImage` で実際の入力画像をアップロード・選択する。初期値 `example.png` は置き換える。
3. 正のプロンプトに、画像内の被写体をどう動かすか入力する。
4. 次の初期設定を確認し、Queueを実行する。

```text
KSampler
  steps          = 4
  cfg            = 1.0
  sampler_name   = lcm
  scheduler      = simple
  denoise        = 1.0

ModelSamplingSD3
  shift          = 8

Wan22ImageToVideoLatent
  width          = 1280
  height         = 704
  length         = 121
  batch_size     = 1

CreateVideo
  fps            = 24
```

約5秒の動画を生成し、`/workspace/ComfyUI/output/video/` 配下へ `Wan22-Turbo` を先頭に付けた名前で保存します。CFG 1.0では負のプロンプトは使用されません。

初期状態はI2Vです。`LoadImage` をCtrl+BでバイパスするとT2Vを試せますが、Turbo配布元の公開用途はI2Vであり、T2Vの品質は未確認です。

速度判定とセットアップ排他は外部サービスへ接続しないローカル・WSL確認の対象です。本番GPUでのロード・画質・VRAM所要量は未確認です。モデル固有の詳細と配布元は [Turbo版README](models/wan2.2-ti2v-5b-turbo/README.md) を参照してください。

## 4. SaladCloud

### 4.1 共通イメージと Container Group

SaladCloud の共通イメージにはモデル本体と `models/`・`scripts/` のコードを含めない。ローカルで確認する場合は、リポジトリのルートを build context にする。

```bash
docker build --platform linux/amd64 -f salad/Dockerfile -t salad:local .
```

Container Group に共通イメージを設定し、Autostart を無効にする。`main` の Salad 関連ファイルをプッシュすると、GitHub Actions が `ghcr.io/<owner>/<repo>/salad:sha-<commit>` をビルドする。Container Group は自動起動しない。

### 4.2 起動とモデルの切り替え

SaladCloud で Run を押し、レプリカが起動したら、冒頭の手順に沿って Codex に SSH コマンドを渡す。Codex がコードの転送を完了したら、返された PowerShell 用コマンドを自分の端末で実行する。コンテナ内で手動実行する場合のモデル選択コマンドは次の形式。

```bash
bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23
```

利用できる ComfyUI モデル（使うモデルごとに `select_model.sh` を実行する）:

- Qwen Rapid AIO NSFW v19: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v19`
- Qwen Rapid AIO NSFW v23: `bash /opt/salad/select_model.sh qwen-rapid-aio-nsfw-v23`
- Qwen Image Edit 2509: `bash /opt/salad/select_model.sh qwen-image-edit-2509`
- Qwen Image Edit 2511: `bash /opt/salad/select_model.sh qwen-image-edit-2511`
- LTX 2.3 Q4: `bash /opt/salad/select_model.sh ltx-2.3-uncensored-v1.4-q4`
- Qwen Image 2.1 GGUF: `bash /opt/salad/select_model.sh qwen-image-2.1-uncensored-gguf`
- Qwen Image 2.1 INT8 Lightning: `bash /opt/salad/select_model.sh qwen-image-2.1-int8-lightning`
- Qwen3-VL 8B: `bash /opt/salad/select_model.sh qwen3-vl-8b-instruct`
- Wan 2.2 TI2V 5B: `bash /opt/salad/select_model.sh wan2.2-ti2v-5b`
- Wan 2.2 TI2V 5B Turbo: `bash /opt/salad/select_model.sh wan2.2-ti2v-5b-turbo`
- Wan 2.2 Enhanced NSFW SVI FP8: `bash /opt/salad/select_model.sh wan2.2-enhanced-nsfw`

LightWan 2.2 A14B は LightX2V を使う CLI モデルであり、SaladCloud の ComfyUI Gateway では選べない。Vast.ai 側でも推論用の標準実行コマンドと必要資産の検証は未整備。

別のモデルを導入したら、そのモデルのワークフローを開いて Queue する。不要になったモデルの登録だけ解除する場合は、名前を指定する。

```bash
bash /opt/salad/reset_model.sh <モデル名>
```

### 4.3 Gateway

Container Group に `COMFY_GATEWAY_USER` と 20 文字以上の `COMFY_GATEWAY_PASSWORD` を設定する。Container Gateway は HTTPS、port 8189、Gateway 側の認証は無効にする。コンテナ内の HTTP Basic 認証を経由して 8188 の共通 Gateway に接続する。`GET /healthz` は認証不要。モデル未登録時は外部プロキシを開かない。登録済みモデルがあれば、コンテナ再起動後に Gateway を復旧する。

### 4.4 生成物の回収

Windows 側で Vast.ai と共通の回収ツールを実行する。SaladCloud の Gateway URL を入力すると自動判定し、`.env` または環境変数の認証情報を利用する。SSH 転送の localhost URL を入力する場合は `--salad` を付ける。既存の Salad 回収履歴も引き継ぎ、画像と動画を回収する。

```powershell
python local_tools\vast_comfy_output_sync_and_log.py
```

従来の `python salad\tools\salad_comfy_output_sync_and_log.py` も同じ処理を呼び出す。画像・動画と生成ログ CSV は `D:\po\NSFW_cos\tmp` 以下に保存する。

### 4.5 コンテナの保存領域

入力・生成物・取得済みモデルはコンテナのローカルストレージに置かれる。永続ボリュームを使わない場合、再配置時に失われる可能性がある。

## 5. 余談

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
