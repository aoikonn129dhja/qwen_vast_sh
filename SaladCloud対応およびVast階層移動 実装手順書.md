# SaladCloud対応およびVast階層移動 実装手順書

## 1．目的

現在のリポジトリを、Vast.ai用実装とSaladCloud用実装が共存できる構成へ変更する。

ユーザー側では既にモデルディレクトリを次のように移動済みである。

```text
repository-root/
├─ docs/
├─ local_tools/
├─ salad/
├─ scripts/
└─ vast/
   └─ models/
      ├─ ltx-2.3-uncensored-v1.4-q4/
      ├─ qwen-image-edit-2509/
      ├─ qwen-image-edit-2511/
      ├─ qwen-rapid-aio-nsfw-v19/
      └─ qwen-rapid-aio-v1-reference/
```

この移動を前提とし、旧`models/`を復活させてはならない。

今回の実装では次の2点を同時に行う。

1．既存Vast.ai実装を、新しい`vast/models/`階層で正常動作するよう修正する。

2．`salad/`以下にSaladCloud専用Docker実装を追加する。

既存Vast用`setup.sh`のロジックをSalad対応のために置換しないこと。VastとSaladは別実装として維持する。

---

# 2．作業開始時の確認

最初にローカルworking treeを確認する。

```bash
git status --short
git diff --stat
git diff --find-renames
```

ユーザーが既に行った`models/`から`vast/models/`への移動を変更として認識し、その変更を取り消さないこと。

GitHub mainよりローカルworking treeを優先すること。

画像ファイルは開かない、解析しない、移動しない、削除しない。

---

# 3．最終的なディレクトリ構成

実装後は概ね次の構成とする。

```text
repository-root/
├─ .github/
│  └─ workflows/
│     └─ build-salad-images.yml
│
├─ docs/
│  └─ codex-context/
│
├─ local_tools/
│
├─ salad/
│  ├─ README.md
│  │
│  ├─ common/
│  │  ├─ download_verified.sh
│  │  ├─ setup_qwen_edit_base.sh
│  │  └─ start_comfyui.sh
│  │
│  └─ models/
│     ├─ qwen-rapid-aio-nsfw-v19/
│     │  ├─ Dockerfile
│     │  ├─ setup.sh
│     │  ├─ prepare_models.sh
│     │  └─ start.sh
│     │
│     ├─ qwen-image-edit-2509/
│     │  ├─ Dockerfile
│     │  ├─ setup.sh
│     │  ├─ prepare_models.sh
│     │  └─ start.sh
│     │
│     ├─ qwen-image-edit-2511/
│     │  ├─ Dockerfile
│     │  ├─ setup.sh
│     │  ├─ prepare_models.sh
│     │  └─ start.sh
│     │
│     └─ ltx-2.3-uncensored-v1.4-q4/
│        ├─ Dockerfile
│        ├─ setup.sh
│        ├─ prepare_models.sh
│        └─ start.sh
│
├─ scripts/
│  ├─ setup_qwen_edit_model.sh
│  └─ flatten_output.sh
│
├─ vast/
│  └─ models/
│     ├─ README.md
│     ├─ ltx-2.3-uncensored-v1.4-q4/
│     ├─ qwen-image-edit-2509/
│     ├─ qwen-image-edit-2511/
│     ├─ qwen-rapid-aio-nsfw-v19/
│     └─ qwen-rapid-aio-v1-reference/
│
├─ .dockerignore
├─ AGENTS.md
├─ README.md
└─ comfyui_cli_batch_手順書.md
```

`qwen-rapid-aio-v1-reference`は参照workflow専用なのでSalad imageを作らない。

Salad対応対象は次の4モデルのみとする。

```text
qwen-rapid-aio-nsfw-v19
qwen-image-edit-2509
qwen-image-edit-2511
ltx-2.3-uncensored-v1.4-q4
```

---

# 4．まずVast側の階層移動を修正する

## 4.1 setup.shのREPO_ROOT

次の3ファイルを確認する。

```text
vast/models/qwen-rapid-aio-nsfw-v19/setup.sh
vast/models/qwen-image-edit-2509/setup.sh
vast/models/qwen-image-edit-2511/setup.sh
```

旧構造では、

```bash
MODEL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MODEL_DIR/../.." && pwd)"
```

でrepository rootへ到達できた。

新構造では、

```text
repository/
└─ vast/
   └─ models/
      └─ model/
```

となったため、`../..`では`repository/vast`までしか戻らない。

次へ変更する。

```bash
REPO_ROOT="$(cd -- "$MODEL_DIR/../../.." && pwd)"
```

特に2509と2511は、

```bash
"$REPO_ROOT/scripts/setup_qwen_edit_model.sh"
```

を呼ぶため、この修正がないと実際に壊れる。

Rapidについても現在`REPO_ROOT`の利用箇所が少なくても、新階層に合わせて正しく修正する。

LTXは現在`MODEL_DIR`から同一ディレクトリ内のファイルを参照する構造なので、不要なREPO_ROOT追加はしない。

---

# 5．Vast側の絶対パスを全面更新する

旧パス、

```text
/workspace/qwen_vast_sh/models/
```

はすべて、

```text
/workspace/qwen_vast_sh/vast/models/
```

へ変更する。

少なくとも次を確認する。

```text
README.md
comfyui_cli_batch_手順書.md
AGENTS.md

vast/models/README.md

vast/models/qwen-rapid-aio-nsfw-v19/README.md
vast/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
vast/models/qwen-rapid-aio-nsfw-v19/setup.sh

vast/models/qwen-image-edit-2509/README.md
vast/models/qwen-image-edit-2511/README.md
vast/models/ltx-2.3-uncensored-v1.4-q4/README.md
```

例えば、

```bash
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

は、

```bash
bash /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

とする。

Rapidの`run_batch.sh`は`MODEL_DIR`からworkflowを解決しているので実処理自体は移動後も動くが、冒頭コメント、使用例、READMEなどに旧絶対パスが残っているため修正する。

---

# 6．LTXテストのrepository root解決を修正する

次を確認する。

```text
vast/models/ltx-2.3-uncensored-v1.4-q4/tests/test_download_models.py
```

旧構造では、

```python
Path(__file__).resolve().parents[3]
```

がrepository rootだった。

階層が1つ深くなったため、現在は`vast/`を指す。

一時ファイルはrepository rootの`tmp/`を使うというAGENTS.mdの規約を維持するため、単純に必要な階層数を修正するか、repository rootをより堅牢に判定する。

最低限、

```python
Path(__file__).resolve().parents[4]
```

相当になる。

ただし、可能なら`.git`またはルート固有ファイルを上方向に探索する小さなhelperにして、今後の階層変更に強くしてよい。

大規模なリファクタリングは不要。

---

# 7．README.mdをマルチプロバイダ構成へ変更する

ルートREADMEの冒頭を「Vast.ai専用リポジトリ」ではなく、

```text
Vast.aiとSaladCloud上でComfyUI画像・動画モデルを利用するためのリポジトリ
```

という位置付けに変更する。

最初にプロバイダ選択を説明する。

```text
vast/
    Vast.ai用

salad/
    SaladCloud用
```

Vastの使用例は、

```bash
git clone https://github.com/aoikonn129dhja/qwen_vast_sh.git /workspace/qwen_vast_sh
cd /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v19
bash setup.sh
```

とする。

既存のRapidバッチ説明、入力、出力、preview等の仕様は削除しない。

Saladについては詳細をルートREADMEへ重複記載せず、

```text
SaladCloudについては salad/README.md を参照
```

とする。

---

# 8．comfyui_cli_batch_手順書.md

このファイルはVast.ai用手順書として維持する。

SaladCloudの詳細をここへ混ぜない。

ただし旧パスはすべて修正する。

例、

```text
models/qwen-image-edit-2511/
```

から、

```text
vast/models/qwen-image-edit-2511/
```

へ変更する。

詳細資料リンクも、

```text
./models/...
```

ではなく、

```text
./vast/models/...
```

へ変更する。

冒頭に短く、

```text
この手順書はVast.ai用である。
SaladCloud用は salad/README.md を参照する。
```

と明記する。

---

# 9．AGENTS.md

ルート`AGENTS.md`のVast実行コマンドを新パスへ変更する。

旧、

```bash
bash /workspace/qwen_vast_sh/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

を、

```bash
bash /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

へ変更する。

また外部環境テスト禁止の記述にSaladCloudも加える。

CodexはローカルでDocker build等を行ってよいが、ユーザーのSaladCloudアカウントへ勝手にデプロイしたりGPUインスタンスを起動したりしない。

---

# 10．docs/codex-context

`docs/codex-context/snapshot/`は過去のsnapshotなので変更しない。

一方、Codexへ現在のrepository layoutを教えるためのcontext文書は、新構成と矛盾しないよう更新する。

特に、

```text
docs/codex-context/AGENTS.md
docs/codex-context/CURRENT_TASK.md
docs/codex-context/memory/
```

内で現在の実装として旧`models/`や旧`qwen_comfy_sh`パスを説明している箇所を確認する。

履歴として残すべき記述は「historical」と明記して残してよい。

現在のパスとして使われている箇所は、

```text
vast/models/
salad/models/
```

へ更新する。

`manifest.json`でSHA-256管理されているcontextファイルを変更した場合は、変更後のSHA-256へ更新する。

`docs/codex-context/snapshot/**`自体のハッシュはsnapshotを変更していない限り変更しない。

---

# 11．SaladCloud実装の基本方針

SaladCloudはVMではなく、Docker containerを実行単位として扱う。

したがって、

```text
Dockerfile
setup.sh
prepare_models.sh
start.sh
```

へ責務を分離する。

各ファイルの役割は次の通り。

```text
Dockerfile
    OS、CUDA、Python環境を固定する。
    必要ファイルをCOPYする。
    setup.shをDocker build中に実行する。

setup.sh
    Docker build時専用。
    ComfyUI、Python依存、custom node、workflowを準備する。
    巨大モデルはダウンロードしない。
    ComfyUIも起動しない。

prepare_models.sh
    Container起動時専用。
    巨大モデルをHugging Face等から取得する。
    SHA-256が既知のものは必ず検証する。

start.sh
    prepare_models.shを実行する。
    完了後にcommon/start_comfyui.shをexecする。
```

---

# 12．manifest.yamlはv1では使わない

Salad公式のComfyUI API構成にはmanifestによるモデル取得機能がある。

しかし今回の目的はREST APIではなく通常のComfyUI Web UIである。

そのため初期実装では、

```text
manifest.yaml
comfyui-api
```

へ依存しない。

巨大モデル取得は、このrepository自身の、

```text
prepare_models.sh
```

で管理する。

将来API運用へ変更する場合だけmanifest化を検討する。

---

# 13．巨大モデルをDocker imageへ入れない

次のような処理をDockerfileやbuild-time setupへ入れてはならない。

```dockerfile
RUN wget .../Qwen-Rapid-AIO-NSFW-v19.safetensors
```

Rapid v19だけで約28.4GBある。

2509、2511も既存設定でモデル一式約31〜32GBである。

SaladCloudにはコンテナイメージサイズ制限があるため、モデル本体はContainer起動時に取得する。

Docker imageへ含めるのは、

```text
CUDA/PyTorch/Python
ComfyUI
Python dependencies
custom nodes
workflow JSON
shell scripts
```

までにする。

---

# 14．Docker base image

Dockerfileではfloating `latest`を使用しない。

CUDA、PyTorch、Python、ComfyUIについて固定versionまたは固定commitを使用する。

Rapid v19については既存requirements.lockが、

```text
torch 2.11.0+cu128
torchvision 0.26.0+cu128
torchaudio 2.11.0+cu128
Python 3.12向けlock
```

であることを考慮し、これと互換性のあるbase imageを選ぶ。

適当な新しいCUDAへ上げない。

Docker image tagが実在することを、

```bash
docker manifest inspect IMAGE
```

等で確認してから採用する。

可能ならdigestも記録する。

Rapid以外も、最終的に使用したbase imageとComfyUI commitを`salad/README.md`へ記録する。

---

# 15．Salad common実装

## 15.1 download_verified.sh

```text
salad/common/download_verified.sh
```

を作成する。

最低限次を提供する。

```text
sha256_matches
download_verified
download_resume_verified
```

要件は、

```text
既存正常ファイルは再DLしない。
.partialまたは.partへダウンロードする。
完了後にSHA-256確認する。
正常時のみ最終名へrenameする。
エラー時に正常ファイルを上書きしない。
```

とする。

既存Vast実装の安全性を参考にする。

URLやtokenをログへ不用意に出さない。

---

# 16．ComfyUIの公開方法

ComfyUI本体は、

```text
127.0.0.1:8188
```

へbindする。

Salad Container GatewayはIPv6受信を必要とするため、

```text
[::]:8189
```

から、

```text
127.0.0.1:8188
```

へ`socat`でTCP転送する。

概念的には、

```text
Browser
    |
    | HTTPS
    v
Salad Container Gateway
    |
    | IPv6 :8189
    v
socat
    |
    | IPv4 127.0.0.1:8188
    v
ComfyUI
```

とする。

Docker imageへ`socat`を導入する。

ComfyUIを直接外部bindする実装にはしない。

---

# 17．start_comfyui.sh

```text
salad/common/start_comfyui.sh
```

を作成する。

単純に、

```bash
socat ... &
exec python main.py ...
```

だけではなく、ComfyUIまたはsocatのどちらかが異常終了した場合にcontainerも終了するよう簡単なprocess supervisionを実装する。

概念は、

```bash
python main.py ... &
COMFY_PID=$!

socat ... &
SOCAT_PID=$!

wait -n "$COMFY_PID" "$SOCAT_PID"
STATUS=$?

kill "$COMFY_PID" "$SOCAT_PID" 2>/dev/null || true
wait || true
exit "$STATUS"
```

とする。

SIGTERM、SIGINTも適切に処理する。

ポートはenvironment variableで上書き可能にする。

デフォルト、

```text
COMFY_PORT=8188
GATEWAY_PORT=8189
```

とする。

---

# 18．Salad Gatewayの前提

`salad/README.md`には次を明記する。

```text
Replica count: 1
Container Gateway: enabled
Container Gateway port: 8189
Gateway authentication: disabled
Protocol: HTTPS
```

ComfyUIはWebSocketを使用するため、Salad Gateway側API-key認証は使用しない。

そのためGateway URLを知る第三者からアクセス可能になる点を明記する。

秘密のprompt、入力画像、workflowを扱う場合、この公開方式にはリスクがある。

今回は既存のVast Web UI運用へ近づけることを優先し、独自認証proxyは追加しない。

後から認証proxyを導入できるよう、ComfyUI自体はlocalhost bindを維持する。

---

# 19．Qwen Rapid AIO NSFW v19

作成する。

```text
salad/models/qwen-rapid-aio-nsfw-v19/
├─ Dockerfile
├─ setup.sh
├─ prepare_models.sh
└─ start.sh
```

## setup.sh

既存、

```text
vast/models/qwen-rapid-aio-nsfw-v19/setup.sh
```

からbuild-timeで必要な部分だけ移植する。

実施するもの、

```text
ComfyUI固定commit取得
requirements.lock導入
comfy-cli導入
Phr00t nodes_qwen.v2.py導入
SHA-256検証
workflow配置
必要directory作成
```

実施しないもの、

```text
GPU確認
nvidia-smi
回線速度test
28.4GBモデルdownload
ComfyUI起動
nohup
cloudflared
Vast.ai固有処理
interactive prompt
```

ComfyUI commitは既存Vast側と同じ固定commitを使用する。

workflowは、

```text
vast/models/qwen-rapid-aio-nsfw-v19/workflows/batch-save-image.json
```

をDocker build contextからCOPYしてよい。

## prepare_models.sh

Qwen Rapid checkpointを、

```text
/opt/ComfyUI/models/checkpoints/
```

へ取得する。

既存Vast setupにある、

```text
MODEL_URL
MODEL_SHA256
```

と同一値を使う。

既知SHA-256を省略してはならない。

既存正常ファイルがある場合は再DLしない。

## start.sh

```text
prepare_models.sh
↓
common/start_comfyui.sh
```

だけを担当する。

Rapid用`run_batch.sh`と`restart_preview_tunnel.sh`はSaladへ移植しない。

Salad v1はWeb UI利用のみとする。

---

# 20．Qwen Image Edit 2509

作成する。

```text
salad/models/qwen-image-edit-2509/
├─ Dockerfile
├─ setup.sh
├─ prepare_models.sh
└─ start.sh
```

モデル設定値は可能な限り、

```text
vast/models/qwen-image-edit-2509/model.conf
```

をbuild contextから参照する。

URL、filename、SHA-256をSalad側へ無意味に再定義しない。

ただしVastのsetup.sh自体を実行してはいけない。

## build-time

次を行う。

```text
ComfyUI
DWPose
AnimePose
必要Python packages
workflow配置
```

custom nodeは可能ならbranch名ではなくcommit SHAへ固定する。

## runtime

次を取得する。

```text
Qwen Image Edit diffusion model
Qwen 2.5 VL text encoder
Qwen VAE
Lightning LoRA
```

既存Vast側でSHA-256が定義されているファイルは同一SHAで検証する。

---

# 21．Qwen Image Edit 2511

2509と同じ基本構成にする。

runtime取得対象は、

```text
qwen_image_edit_2511_fp8mixed
text encoder
VAE
Lightning LoRA
Multiple Angles LoRA
NSFW LoRA
```

とする。

workflowについて、既存Vast setupと同じ、

```text
qwen_image_edit_2511_bf16.safetensors
```

から、

```text
qwen_image_edit_2511_fp8mixed.safetensors
```

へのfilename置換をbuild-timeで行う。

既存workflow原本は変更しない。

---

# 22．2509と2511の共通化

両者の重複処理は、

```text
salad/common/setup_qwen_edit_base.sh
```

へまとめてよい。

ただし、

```text
vast/scripts/setup_qwen_edit_model.sh
```

をSalad対応へ改造して共用してはならない。

Vast用shared engineとSalad用shared engineは別に維持する。

理由は、

```text
Vast
    /workspace
    /venv/main/bin/python
    VM lifecycle
    nohup

Salad
    /opt
    container lifecycle
    Docker build/runtime分離
```

と前提が異なるためである。

---

# 23．LTX 2.3

作成する。

```text
salad/models/ltx-2.3-uncensored-v1.4-q4/
├─ Dockerfile
├─ setup.sh
├─ prepare_models.sh
└─ start.sh
```

既存、

```text
vast/models/ltx-2.3-uncensored-v1.4-q4/model.conf
vast/models/ltx-2.3-uncensored-v1.4-q4/download_models.py
```

を再利用する。

## build-time

```text
ComfyUI
ComfyUI-GGUF-Loader
opencv-python-headless
workflow JSON
```

を準備する。

GGUF Loaderは可能ならcommit固定する。

## runtime

既存`download_models.py`のロジックを再利用して、

```text
transformer
text encoder
projections
video VAE
audio VAE
```

を取得する。

既存LTX設定の`HF_REVISION=main`について、勝手に存在しないSHAを作らない。

実装時にHugging Faceの実revision commitを確実に取得できる場合はSalad用として固定してよい。

取得できない場合は現在の`main`を維持し、`salad/README.md`へ再現性上の未固定点として記載する。

---

# 24．Dockerfile共通要件

すべて、

```text
linux/amd64
```

を対象とする。

Dockerfileでは、

```text
WORKDIR /opt
ComfyUI = /opt/ComfyUI
```

に統一する。

最低限必要なsystem packages、

```text
bash
git
wget
curl
ca-certificates
socat
```

を導入する。

モデルによって必要なら追加する。

Dockerfile内に、

```text
HF_TOKEN
Salad API key
GitHub PAT
password
```

を直接書いてはならない。

モデル本体をCOPYまたはRUN wgetしてimageへ焼いてはならない。

---

# 25．Docker build context

Docker buildはrepository rootをcontextにする。

例えば、

```bash
docker build \
  -f salad/models/qwen-rapid-aio-nsfw-v19/Dockerfile \
  -t qwen-salad:qwen-rapid-aio-nsfw-v19 \
  .
```

とする。

Dockerfileのあるdirectoryをbuild contextにしてはいけない。

理由は、

```text
vast/models/.../model.conf
vast/models/.../workflows/
scripts/
salad/common/
```

へアクセスする必要があるためである。

---

# 26．.dockerignore

repository rootへ`.dockerignore`を追加する。

最低限、

```text
.git
tmp
**/__pycache__
**/*.pyc
```

を除外する。

ユーザーのローカル生成物や秘密情報がDocker build contextへ入らないようにする。

既存ソースのうちDockerfileがCOPYする必要のある、

```text
salad/
vast/models/
scripts/
```

は除外しない。

---

# 27．Container起動時モデルDL

`prepare_models.sh`は再実行可能にする。

同一container内でrestartされた場合に正常ファイルが残っていれば再DLしない。

ただしSalad nodeがreallocateされた場合、ローカルファイルが残る前提にはしない。

再allocation後はモデルを再取得できる構成であること。

モデルDL失敗時はComfyUIを起動せずcontainerを非zeroで終了する。

壊れたmodel fileをそのまま使用してはいけない。

---

# 28．出力と入力の永続性

Salad版v1ではpersistent output同期を実装しない。

ComfyUIでアップロードした入力画像、生成物、手動で変更したworkflow等はcontainer local filesystem上に置かれる。

node reallocation等で失われる可能性があることを`salad/README.md`へ明記する。

Vast用、

```text
local_tools/vast_output_sync.py
scripts/flatten_output.sh
```

をSaladへ無理に流用しない。

Cloudflare R2、S3等への自動保存は別タスクとする。

---

# 29．Salad README

新規作成する。

```text
salad/README.md
```

最低限次を説明する。

```text
Salad版の目的
Vast版との違い
対応4モデル
Docker imageのbuild方法
GHCR imageの使い方
Container Group作成方法
replica = 1
Gateway port = 8189
Gateway authentication = disabled
モデルは起動時DLされる
初回起動に時間が掛かる理由
local filesystemは永続ではない
停止またはreallocation後に再DLが発生し得る
Container logsの確認方法
Web UI URLの開き方
```

Qwenモデルについてはmodel一式が約30GBあるため、Salad側Disk Spaceは十分な容量を指定するよう明記する。

初期値として50GB級の空き容量を確保する構成を推奨してよいが、実環境で未検証ならその旨を書く。

GPUについては実測していないGPUを「動作確認済み」と書かない。

---

# 30．GHCR build workflow

手作業を減らすため、

```text
.github/workflows/build-salad-images.yml
```

を追加する。

GitHub Actionsで4モデルのDocker imageをbuildし、GHCRへpushする。

matrix対象、

```text
qwen-rapid-aio-nsfw-v19
qwen-image-edit-2509
qwen-image-edit-2511
ltx-2.3-uncensored-v1.4-q4
```

とする。

権限は最低限、

```yaml
permissions:
  contents: read
  packages: write
```

とする。

GitHub標準`GITHUB_TOKEN`を使用し、PATをrepositoryへ書かない。

platformは、

```text
linux/amd64
```

とする。

Docker imageへ巨大モデルは含めないため、Actions中に30GBモデルをdownloadしない。

image tagにはcommit SHA由来のimmutable tagを必ず付ける。

`latest`を追加してもよいが、Saladへの本番指定はSHA tagをREADMEで推奨する。

---

# 31．GitHub Actionsを実装できない場合

GitHub環境上の制約等でworkflowの実動作まで確認できない場合でも、Dockerfiles自体は完成させる。

未検証事項として、

```text
GHCR pushは未検証
```

と明示する。

成功したと推測で報告しない。

---

# 32．Salad Portal設定

`salad/README.md`へ次の設定例を書く。

```text
Container image
    GHCRの対象model image

Replica
    1

GPU
    対象modelで使用するGPUを選択

Container Gateway
    enabled

Port
    8189

Authentication
    disabled
```

WebSocketを使うComfyUI GUIのためGateway authを有効にしない。

replicaを複数にすると、同一ユーザーのComfyUI状態が複数containerへ分散する可能性があるため、interactive Web UI用途では1とする。

---

# 33．Health check

可能ならGateway経由のreadiness probeを、

```text
GET /system_stats
port 8189
```

へ設定できるようREADMEに記載する。

`prepare_models.sh`完了前はComfyUI自体が起動していないためReadyにならない構成とする。

モデルDL完了後、

```text
prepare_models.sh
↓
ComfyUI
↓
socat
↓
ready
```

の順で利用可能になる。

---

# 34．VastとSaladで共有してよいもの

共有してよいのは主にデータ、設定値、workflowである。

```text
model.conf
workflow JSON
requirements.lock
download_models.py
モデルURL
SHA-256
```

一方、provider lifecycleに依存するsetup処理は共有しない。

つまり、

```text
設定値は可能な範囲で共有
実行ロジックはVastとSaladで分離
```

とする。

---

# 35．変更してはいけないもの

今回のSalad対応を理由に、次のVast仕様を変更しない。

```text
Rapidバッチのprompt parser
Rapid output naming
Rapid preview Basic Auth
Rapid Cloudflare Quick Tunnel
Windows vast_output_sync履歴仕様
Vast Stop/Destroy運用
ComfyUI workflow内容
既存model SHA-256
```

必要なのはpath修正のみである。

---

# 36．静的検証

全shellを構文検査する。

WSLを使用してよい。

```bash
find vast salad scripts -type f -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n
```

Pythonを検査する。

```bash
python -m py_compile \
  local_tools/*.py \
  vast/models/ltx-2.3-uncensored-v1.4-q4/download_models.py \
  vast/models/ltx-2.3-uncensored-v1.4-q4/tests/test_download_models.py
```

LTX testを実行する。

```bash
python -m unittest \
  vast/models/ltx-2.3-uncensored-v1.4-q4/tests/test_download_models.py
```

JSONをPythonで読み込んで検証する。

workflow JSONを画像として開いたり解析したりしない。

---

# 37．旧path残存チェック

変更後にrepository全体を検索する。

```bash
git grep -n \
  -e '/workspace/qwen_vast_sh/models/' \
  -e 'cd models/' \
  -e 'bash models/' \
  -e './models/'
```

残ったものが、

```text
historical snapshot
過去仕様を説明する文書
```

以外に存在しないことを確認する。

現在仕様として旧pathが残っていれば修正する。

`docs/codex-context/snapshot/**`は除外してよい。

---

# 38．Docker build検証

Dockerが利用可能なら4 imageともbuildする。

```bash
docker build \
  -f salad/models/qwen-rapid-aio-nsfw-v19/Dockerfile \
  -t qwen-salad:qwen-rapid-aio-nsfw-v19 \
  .

docker build \
  -f salad/models/qwen-image-edit-2509/Dockerfile \
  -t qwen-salad:qwen-image-edit-2509 \
  .

docker build \
  -f salad/models/qwen-image-edit-2511/Dockerfile \
  -t qwen-salad:qwen-image-edit-2511 \
  .

docker build \
  -f salad/models/ltx-2.3-uncensored-v1.4-q4/Dockerfile \
  -t qwen-salad:ltx-2.3-uncensored-v1.4-q4 \
  .
```

build中に巨大model downloadが始まった場合は設計ミスなので修正する。

Docker buildでGPUを要求してはいけない。

---

# 39．Docker image確認

build後、

```bash
docker image ls
```

でimage sizeを確認する。

35GB付近まで膨らんでいた場合は、モデルや不要cacheがimageに入っていないか確認する。

`apt`、`pip`、`uv`等のdownload cacheも可能な範囲で削除する。

---

# 40．GPU実環境テストについて

CodexはSaladCloud上で実GPUインスタンスを勝手に作成しない。

ローカルで、

```text
Docker build
shell syntax
Python tests
config validation
```

まで行う。

次はユーザー側実環境テストとして残す。

```text
SaladでContainer Group作成
GPU認識
モデルdownload
ComfyUI起動
Gateway URL表示
ブラウザからWeb UI表示
workflow load
実生成
```

実GPU生成を行っていない場合は、動作確認済みと報告しない。

---

# 41．git diff確認

最後に、

```bash
git status --short
git diff --check
git diff --stat
git diff
```

を確認する。

ユーザーが行ったdirectory moveを正しく含んでいることを確認する。

今回無関係の変更や未追跡ファイルをcommitしない。

秘密情報がないことを確認する。

---

# 42．完了条件

次をすべて満たした時点で実装完了とする。

```text
1．旧models/が復活していない。
2．Vastモデルがvast/models/にある。
3．Vastのsetup.shからroot scriptsを正しく参照できる。
4．READMEとVast手順書のpathが新構成へ更新されている。
5．Rapid run_batchの使用例も新pathになっている。
6．LTX testのrepository root判定が新階層に対応している。
7．salad/models/に4モデル分のDockerfileがある。
8．各Salad modelにsetup.sh、prepare_models.sh、start.shがある。
9．巨大modelがDocker imageに含まれていない。
10．既知SHA-256はSalad側でも検証される。
11．ComfyUIは127.0.0.1:8188で動く。
12．socatがIPv6 :8189からComfyUIへ転送する。
13．Salad READMEにGateway設定が書かれている。
14．Salad READMEにephemeral storageの注意が書かれている。
15．4 Docker imageがローカルbuild可能、または未build理由が明示されている。
16．shell構文検査が通る。
17．LTX unit testが通る。
18．git diff --checkが通る。
19．画像ファイルには一切触れていない。
20．秘密情報をcommitしていない。
```

---

# 43．commit

既存AGENTS.mdのGit運用ルールに従う。

ユーザーの既存変更を消さない。

今回の変更だけをcommitする。

commit message例、

```text
Add SaladCloud containers and update Vast model paths
```

push成功後は、

```text
commit hash
commit message
変更ファイル
実施した検証
実施できなかった検証
```

を報告する。

Vast側の更新後、ユーザーへ最低限次を案内する。

```bash
cd /workspace/qwen_vast_sh
git pull --ff-only origin main
```

Rapidを実行する場合は新pathで、

```bash
bash /workspace/qwen_vast_sh/vast/models/qwen-rapid-aio-nsfw-v19/run_batch.sh
```

と案内する。

Salad側については、GHCR buildが成功した場合だけ、生成された正確なimage名とtagを案内する。推測したimage URLを書かない。