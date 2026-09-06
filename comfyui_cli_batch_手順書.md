# Qwen ComfyUI バッチ生成 手順書

普段の画像生成で必要な操作だけを、実行順にまとめた手順書です。仕組みや詳しい仕様、トラブル対応は [README.md](./README.md) を参照してください。

## 1. コマンド早見表

コマンドはJupyter WebUIのTerminalで実行します。

普段使うコマンドは、リポジトリの更新と画像生成の2つです。

```sh
# リポジトリを更新
cd /workspace/qwen_comfy_sh && git pull --ff-only origin main

# 画像生成を開始
bash /workspace/qwen_comfy_sh/run_batch.sh

# 入力画像と同じアスペクト比で生成（約315万画素）
MATCH_INPUT_ASPECT=1 bash /workspace/qwen_comfy_sh/run_batch.sh

# 幅と高さを固定して生成
WIDTH=1536 HEIGHT=2048 bash /workspace/qwen_comfy_sh/run_batch.sh
```

`MATCH_INPUT_ASPECT=1` は入力画像ごとにサイズを計算し、入力とほぼ同じ縦横比で約315万画素になるよう、幅と高さを64px刻みに丸めます。`WIDTH` または `HEIGHT` とは同時に指定できません。

入力画像が約315万画素の105%を超える場合は、どの実行方法でもモデルへ渡す前に縦横比を保って約315万画素へ自動縮小されます。元画像は変更されません。

そのほかの確認や操作に使うコマンドです。

```sh
# 入力画像を確認
ls -lah /workspace/qwen_batch/input

# プロンプトを確認
sed -n '1,120p' /workspace/qwen_batch/prompts.md

# 生成結果を確認
find /workspace/qwen_batch/output -maxdepth 2 -type f | head -n 50

# 複数回の生成結果を1フォルダにまとめる
bash /workspace/qwen_comfy_sh/flatten_output.sh

# ComfyUIのログを確認
tail -n 100 /workspace/comfyui.log

# 初期セットアップ（初回のみ）
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

### ComfyUIのノード編集画面を開く

`run_batch.sh` を実行し、Terminalに `ComfyUI: already running` または `ComfyUI: ready` と表示されていることを確認します。

Vast.aiのInstance Portalで **Tunnels** を開き、次の固定アドレスを入力して **Create New Tunnel** を押します。

```text
http://localhost:8188
```

作成された `https://～.trycloudflare.com` のURLを開くと、ComfyUIのノード編集画面が表示されます。`localhost:8188` は固定ですが、外部公開用の `trycloudflare.com` URLはトンネルの再作成やインスタンスの再起動で変わる場合があります。

Terminalに表示される `Preview URL` は生成画像の確認専用であり、ノード編集画面ではありません。バッチ生成中にノード画面を開く場合は、実行中の処理を止めないよう **Queue** や **Cancel** を操作しないでください。

## 2. 画像生成のやり方と注意点

### 1. Vast.aiでインスタンスをRENTする

Vast.aiで使用するインスタンスの **RENT** をクリックします。

インスタンスが `Running` になったら、**Open** からJupyter WebUIを開き、Terminalを起動します。

- 初めて作成したインスタンスは、先に「3. 初期セットアップ」を実行してください。
- セットアップ済みのインスタンスをStop → Startした場合は、そのまま次へ進めます。

### 2. リポジトリを更新する

```bash
cd /workspace/qwen_comfy_sh
git pull --ff-only origin main
```

セットアップ済みのインスタンスでは、通常 `setup_qwen_comfy.sh` を再実行する必要はありません。

### 3. 入力画像とprompts.mdを配置する

Jupyterのファイルブラウザで、生成に使う画像を次のフォルダへアップロードします。

```text
/workspace/qwen_batch/input/
```

対応形式はPNG、JPG、JPEG、WebPです。サブフォルダ内の画像は処理されないため、画像は `input/` 直下へ置いてください。

プロンプトは次へ配置します。

```text
/workspace/qwen_batch/prompts.md
```

`##` で始まる見出しごとに1つのプロンプトとして読み込まれます。

```markdown
# Qwen prompts

## 1
first prompt

## 2
second prompt
```

### 4. 画像生成を開始する

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

ComfyUIが停止している場合は、`run_batch.sh` が自動で起動して準備完了を待ちます。

開始時に次の数字を確認してください。

```text
Images   : 入力画像数
Prompts  : プロンプト数
Total    : Images × Prompts
```

意図しない大量生成を避けるため、特に `Total` を確認します。

生成が1枚完了するごとに、今回の生成時間と、完了済み画像の1枚あたりの平均時間が表示されます。

```text
[12/100] 完了: 今回 8.4秒 | 平均 1枚あたり 8.9秒
```

### 5. ライブプレビューを見る

Terminalに表示された `Preview URL` をブラウザで開きます。

```text
user     : qwen
password : Terminalに表示された20文字のパスワード
```

同じ `/workspace` を使っている間は、基本的に同じパスワードが再利用されます。

プレビューではPrev、Next、Latest、Auto followを使用できます。バッチ完了時には、ブラウザ側で許可されていれば約5秒間のアラート音が鳴ります。ブラウザの自動再生制限がある場合は鳴らないことがありますが、画像生成には影響しません。

#### Preview URLが開けない場合

`ERR_NAME_NOT_RESOLVED` などが表示されて `Preview URL` を開けない場合は、Jupyter WebUIのTerminalで次を実行します。

```bash
cd /workspace/qwen_comfy_sh
git pull --ff-only origin main
bash /workspace/qwen_comfy_sh/restart_preview_tunnel.sh
```

画像生成とローカルのプレビューサーバーは停止せず、Cloudflare Quick Tunnelだけが再起動されます。新しい `Preview URL`、ユーザー名、現在のパスワードがTerminalに表示されるので、新しいURLをブラウザで開いてください。古いURLは使用できなくなります。

Preview URLとパスワードを同時に外部共有しないでください。Terminalのスクリーンショットにも注意してください。

### 6. 生成中は出力を動かさない

`run_batch.sh` は1本ずつ実行してください。

入力画像一覧と `prompts.md` は開始時に読み込まれます。生成開始後に追加・編集した内容は、次回のバッチから反映されます。

生成中は次の操作をしないでください。

- 現在の `output/<RUN_ID>/` を移動または削除する
- `flatten_output.sh` を実行する
- 別の `run_batch.sh` を同時に起動する

### 7. 完了後に出力を1フォルダへまとめる

生成結果はrunごとに次へ保存されます。

```text
/workspace/qwen_batch/output/<RUN_ID>/
```

Terminalに `COMPLETE` が表示され、バッチが完全に終了してから実行します。

```bash
bash /workspace/qwen_comfy_sh/flatten_output.sh
```

複数のRUN_IDフォルダにあるPNGが、次のような1フォルダへまとめられます。

```text
/workspace/qwen_batch/output/yyyy_mmdd_hhmm/
```

既存画像は上書きされません。同名の場合はファイル名へ追加の番号が付きます。
過去に作成された `yyyy_mmdd_hhmm` フォルダは対象外なので、実行するたびに新しいまとめフォルダが並びます。

### 8. Jupyterから回収する

Jupyterのファイルブラウザで次を開きます。

```text
/workspace/qwen_batch/output/
```

`flatten_output.sh` が作成した `yyyy_mmdd_hhmm` フォルダをダウンロードします。平坦化済みなので、複数runの結果も1回で回収できます。

回収後の扱いは次のとおりです。

- 後で同じ環境を使う: Vast.ai画面で **Stop**
- 環境を完全に破棄する: 必要なファイルをすべて回収してから **Destroy**

**Destroyすると `/workspace` の内容も失われます。**

## 3. 初期セットアップ

新しくRENTした未セットアップのインスタンスで、Jupyter WebUIのTerminalから一度だけ実行します。

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

セットアップではComfyUI、comfy-cli、Qwenモデル、workflow、作業ディレクトリなどが準備されます。モデルをダウンロードするため時間がかかります。

セットアップが完了したら、「2. 画像生成のやり方と注意点」の「3. 入力画像とprompts.mdを配置する」から進めてください。

既に `/workspace/qwen_comfy_sh` が存在する場合は、cloneやsetupを繰り返さず、次の更新コマンドを使用します。

```bash
cd /workspace/qwen_comfy_sh
git pull --ff-only origin main
```

セットアップの詳細、ディレクトリ構成、環境変数、出力仕様、ログの確認方法は [README.md](./README.md) にまとめています。
