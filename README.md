# qwen_comfy_sh

Vast.ai 上に **Qwen Rapid AIO NSFW v19 + ComfyUI** を構築し、保存済み ComfyUI workflow を使って **入力画像 × `prompts.md` の全組み合わせ**をバッチ生成するためのリポジトリ。

現在の運用は Jupyter を中心にしている。Windows 側に `comfy-cli` を導入する必要はなく、画像生成・workflow 書き換え・ComfyUI 実行は Vast.ai 側で行う。

## 現在の主な機能

- `setup_qwen_comfy.sh` による ComfyUI / comfy-cli / Qwen モデルのセットアップ
- `prompts.md` による複数プロンプト管理
- 入力画像 × プロンプトの直積バッチ生成
- `run_batch.sh` 実行時の ComfyUI 生存確認と自動起動・復旧
- 生成画像を `/workspace/qwen_batch/output/<RUN_ID>/` に集約
- 生成中のブラウザライブプレビュー
- Cloudflare Quick Tunnel 経由のプレビューに HTTP Basic 認証を要求
- 固定ユーザー名 `qwen` + 実行ごとの20文字ランダムパスワード
- Prev / Next / Latest / Auto follow による生成画像確認
- `flatten_output.sh` による複数 RUN_ID フォルダの一括平坦化

---

## リポジトリ構成

```text
qwen_comfy_sh/
├─ setup_qwen_comfy.sh
├─ run_batch.sh
├─ flatten_output.sh
├─ Qwen-Rapid-AIO-SaveImage.json
├─ comfyui_cli_batch_手順書.md
└─ README.md
```

`prompts.md` は生成内容を含むため、通常は Git 管理せず `/workspace/qwen_batch/prompts.md` に配置する。

---

## 基本ディレクトリ

```text
/workspace/
├─ qwen_comfy_sh/
│  ├─ setup_qwen_comfy.sh
│  ├─ run_batch.sh
│  ├─ flatten_output.sh
│  └─ Qwen-Rapid-AIO-SaveImage.json
│
├─ qwen_batch/
│  ├─ prompts.md
│  ├─ input/
│  ├─ output/
│  │  ├─ <RUN_ID>/
│  │  └─ ...
│  └─ tmp/
│
├─ ComfyUI/
│  ├─ models/checkpoints/
│  ├─ input/batch/<RUN_ID>/
│  ├─ output/batch/<RUN_ID>/
│  └─ user/default/workflows/
│
└─ qwen_preview/
   ├─ state.json
   ├─ server.py
   └─ preview / tunnel logs
```

---

# セットアップ

## 新規 Vast.ai インスタンス

PyTorch (Vast) 系テンプレートを前提とする。

Jupyter の Terminal で以下を実行する。

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

`setup_qwen_comfy.sh` は主に以下を行う。

1. GPU / Disk の確認
2. Hugging Face への実ダウンロード速度の事前測定
3. ComfyUI の clone / 修復
4. ComfyUI requirements のインストール
5. `/venv/main` への公式 `comfy-cli` の導入
6. `comfy set-default /workspace/ComfyUI`
7. `Qwen-Rapid-AIO-NSFW-v19.safetensors` のダウンロード
8. Phr00t の `nodes_qwen.v2.py` の導入
9. workflow の配置
10. `/workspace/qwen_batch/` 以下の作業ディレクトリ作成
11. ComfyUI の起動
12. 必要な Cloudflare Tunnel の起動

モデルが既に存在する Stop → Start 後のインスタンスでは、通常はセットアップを再実行する必要はない。

---

# prompts.md

標準パス:

```text
/workspace/qwen_batch/prompts.md
```

各プロンプトは `##` で始める。

```markdown
# Qwen prompts

## 1
Change only the clothing while preserving the person, pose, framing and background.

## 2
Replace the outfit with another outfit while keeping the rest of the image unchanged.

## 任意のラベル
A multi-line prompt is also supported.
The text after the heading is ignored.
```

仕様:

- `##` / `## 1` / `## Prompt 3` / `##anything` はすべて有効
- `##` の後ろの見出し文字列はプロンプト本文には含まれない
- 次の `##` までが1プロンプト
- 複数行プロンプトに対応
- 最初の `##` より前のテキストは無視
- `###` は新しいプロンプト開始として扱わない

`run_batch.sh` は開始時に `prompts.md` を読み込み、メモリ上に固定する。そのため、バッチ開始後に `prompts.md` を編集しても現在のバッチには反映されず、次回実行から反映される。

---

# 入力画像

標準パス:

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

入力ディレクトリ直下のみを読む。

```text
input/
├─ a.png            ← 対象
├─ b.jpg            ← 対象
└─ archive/
   └─ old.png        ← 対象外
```

入力画像一覧も `run_batch.sh` 開始時に固定される。実行途中で `input/` に追加した画像は現在のバッチには入らず、次回実行から対象になる。

---

# バッチ実行

標準構成なら引数なしで実行できる。

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

## ComfyUI 自動起動

`run_batch.sh` は最初に `127.0.0.1:8188/system_stats` を確認する。

ComfyUI が既に動いている場合:

```text
ComfyUI: already running
```

ComfyUI が停止している場合:

```text
ComfyUI: starting...
ComfyUI: waiting for API...
ComfyUI: ready
```

プロセスだけ残り API が応答しない場合は短時間待機し、それでも復旧しなければ stale process として停止・再起動する。新規起動後は最大90秒 API 応答を待つ。

Stop → Start 後に ComfyUI プロセスが消えていても、通常は `run_batch.sh` の実行だけで復旧できる。

---

## 生成ジョブ数

画像数 × プロンプト数の全組み合わせを順番に生成する。

```text
10 images × 10 prompts = 100 jobs
```

開始時に必ず `Total` が表示される。

```text
============================================================
 QWEN BATCH
============================================================
Run ID   : 20260905_211651
Images   : 10
Prompts  : 10
Total    : 100
...
============================================================
```

---

# ライブプレビュー

バッチ開始時にプレビュー用 HTTP サーバーを `127.0.0.1:8765` に起動し、Cloudflare Quick Tunnel 経由の HTTPS URL を表示する。

表示例:

```text
Preview local    : http://127.0.0.1:8765/
Preview URL      : https://xxxxx.trycloudflare.com
Preview user     : qwen
Preview password : <20-character-random-password>
```

## 認証

プレビューは HTTP Basic 認証必須。

- ユーザー名: `qwen` 固定
- パスワード: `run_batch.sh` 実行ごとに20文字の英数字をランダム生成
- パスワードは preview state や生成画像メタデータには保存しない
- 認証なし / 誤った認証情報では `401 Unauthorized`
- 公開 URL への通信は Cloudflare の HTTPS を使用する

URL が漏れても、認証情報がなければプレビュー画像を取得できない構成になっている。ただし、URL とパスワードは Terminal に表示されるため、Terminal のスクリーンショットやログの共有には注意する。

## プレビュー操作

- `Prev`: 前の生成画像
- `Next`: 次の生成画像
- `Latest`: 最新生成画像へ戻る
- `Auto follow`: 新しい画像が生成されたら自動で最新画像へ移動
- `←` / `→`: 前後移動
- `L`: 最新へ戻る

プレビューは現在の RUN_ID の出力ディレクトリだけを表示する。

無効化する場合:

```bash
PREVIEW_ENABLED=0 bash /workspace/qwen_comfy_sh/run_batch.sh
```

プレビューポートを変更する場合:

```bash
PREVIEW_PORT=8877 bash /workspace/qwen_comfy_sh/run_batch.sh
```

---

# workflow

バッチのベース workflow:

```text
/workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
```

主要 slot address:

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
| `10.filename_prefix` | 保存 prefix |

`run_batch.sh` は `comfy-cli workflow set-slot` で GUI 保存形式 workflow をジョブごとに上書きし、`comfy run --workflow ... --wait` で実行する。

`workflow set-slot --stdout` では global option の `--no-json` を使用し、JSON response envelope が workflow ファイルに混ざるのを防いでいる。

---

# 生成パラメータの上書き

何も指定しない値は workflow JSON に保存された値を使用する。

入力画像ごとに縦横比を合わせ、通常サイズの `1536 × 2048 = 3,145,728` 画素に近いサイズで生成する場合:

```bash
MATCH_INPUT_ASPECT=1 \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

画像のEXIF回転を考慮した縦横比を使い、モデルで扱いやすいよう幅と高さをそれぞれ64px刻みに丸める。そのため画素数と縦横比は僅かに誤差が出る。`MATCH_INPUT_ASPECT=1` と `WIDTH` / `HEIGHT` は同時に指定できない。

出力幅と高さを固定する場合:

```bash
DENOISE=0.8 \
STEPS=6 \
CFG=1 \
SAMPLER=er_sde \
SCHEDULER=beta \
WIDTH=1536 \
HEIGHT=2048 \
SEED=123456 \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

ネガティブプロンプトを全ジョブ共通で上書きする場合:

```bash
NEGATIVE_PROMPT="negative prompt" \
bash /workspace/qwen_comfy_sh/run_batch.sh
```

---

# 出力

ComfyUI の `SaveImage` は一度、以下へ生成する。

```text
/workspace/ComfyUI/output/batch/<RUN_ID>/
```

各ジョブ完了後、`run_batch.sh` が生成物をすぐに以下へ移動する。

```text
/workspace/qwen_batch/output/<RUN_ID>/
```

最終的に利用する出力先は **`/workspace/qwen_batch/output/<RUN_ID>/`**。

例:

```text
/workspace/qwen_batch/output/
├─ 20260905_200239/
├─ 20260905_202623/
├─ 20260905_211651/
└─ 20260905_212341/
```

通常の生成ファイル名は以下のようになる。

```text
001_p001_00001_.png
001_p002_00001_.png
002_p001_00001_.png
```

---

# 複数 RUN_ID の出力を1フォルダにまとめる

複数回バッチを回すと RUN_ID ごとにフォルダが増える。Jupyter から各フォルダを個別ダウンロードすると ZIP が複数になるため、回収前に `flatten_output.sh` で1フォルダへまとめる。

**バッチ生成が走っていない状態で実行する。**

```bash
bash /workspace/qwen_comfy_sh/flatten_output.sh
```

出力先:

```text
/workspace/qwen_batch/output/yyyy_mmdd_hhmm/
```

例:

```text
/workspace/qwen_batch/output/2026_0906_0715/
```

その直下に PNG が並ぶ。

```text
2026_0906_0715/
├─ 20260905_200239__001_p001_00001_.png
├─ 20260905_202623__001_p001_00001_.png
├─ 20260905_211651__002_p002_00001_.png
└─ ...
```

同名衝突を避けるため、基本的に元 RUN_ID をファイル名へ付加する。それでも同名になる場合は追加 suffix を付け、既存ファイルを上書きしない。

平坦化後は、この `yyyy_mmdd_hhmm` フォルダだけを Jupyter からダウンロードすればよい。

既存の `yyyy_mmdd_hhmm` フォルダは次回以降の平坦化対象から除外される。複数回実行すると、実行ごとのまとめフォルダが `/workspace/qwen_batch/output/` 直下に並ぶ。

---

# 実行中の変更について

`run_batch.sh` は開始時に次を固定する。

```text
入力画像一覧
prompts.md の全プロンプト
```

したがって開始後は:

| 操作 | 現在のバッチへの影響 |
|---|---|
| `input/` に画像を追加 | 反映されない。次回から使用 |
| `prompts.md` を編集 | 反映されない。次回から使用 |
| `output/<RUN_ID>` を移動・削除 | 非推奨。プレビュー・出力処理と競合する |
| `flatten_output.sh` を実行 | バッチ中は実行しない |

`QWEN BATCH` のヘッダと `Images / Prompts / Total` が表示された後で `prompts.md` を次回用に編集すること自体は問題ない。

---

# 同時実行について

`run_batch.sh` を2本同時に起動する運用は想定していない。

理由:

- Preview port `8765` を共有する
- preview PID / state / tunnel を共有する
- 後から起動したバッチが前のプレビューを停止・置換する可能性がある
- ComfyUI queue と output 管理が分かりにくくなる

1バッチずつ実行する。

---

# 一時ファイル

各 RUN_ID で以下が作成される。

```text
/workspace/ComfyUI/input/batch/<RUN_ID>/
/workspace/qwen_batch/tmp/<RUN_ID>/
```

現行 `run_batch.sh` は生成画像を output へ移動するが、`STAGE_DIR` と `TMP_DIR` は自動削除しない。そのため長期運用では一時ファイルが蓄積する。

バッチが動いていない状態で過去分を削除する場合:

```bash
rm -rf /workspace/ComfyUI/input/batch/*
rm -rf /workspace/qwen_batch/tmp/*
```

---

# Stop / Destroy

## Stop

- GPU プロセスは停止する
- `/workspace` のデータは残る
- モデル、入力、出力も残る
- ディスク料金は継続する
- 再 Start 後、ComfyUI が落ちていても `run_batch.sh` が自動起動できる

## Destroy

- インスタンスのローカルデータを失う
- 必要な生成画像を回収してから行う
- 次回は clone / setup / モデルダウンロードが必要

---

# セキュリティ上の注意

## ライブプレビュー

ライブプレビューは Cloudflare Quick Tunnel を通るが、現在は HTTP Basic 認証必須。

```text
URLを知っているだけ
→ 401 Unauthorized

URL + user + password
→ 閲覧可能
```

入力画像と `prompts.md` はプレビューサーバーから直接配信しない。プレビューサーバーが配信するのは現在の RUN_ID の生成画像と manifest のみ。

ただし以下は残る。

- 出力画像の通信は Vast.ai → Cloudflare → ブラウザを通る
- URL とパスワードは Terminal に表示される
- Vast.ai のホスト環境および導入した Python / ComfyUI コードへの信頼は必要
- `setup_qwen_comfy.sh` が ComfyUI GUI 用の別 Tunnel を起動している場合、ライブプレビューの Basic 認証とは別物

---

# Public GitHub に置く場合

GUI 保存形式 workflow には最後に設定していた値が含まれる場合がある。

例:

- prompt
- negative prompt
- LoadImage のファイル名
- seed
- generation parameters

Public repository に commit する前に、公開したくない prompt / filename が workflow に残っていないか確認する。

`prompts.md` は個別の生成内容を含むため `.gitignore` 対象にしておく。

---

# トラブルシューティング

## ComfyUI の起動状況

```bash
curl -s http://127.0.0.1:8188/system_stats | head
```

## ComfyUI 起動失敗

```bash
tail -n 100 /workspace/comfyui.log
```

## 入力画像確認

```bash
ls -lah /workspace/qwen_batch/input
```

## prompts.md 確認

```bash
cat /workspace/qwen_batch/prompts.md
```

## 出力確認

```bash
find /workspace/qwen_batch/output -maxdepth 2 -type f | head -n 50
```

## ComfyUI queue

```bash
/venv/main/bin/comfy --where local jobs ls
```

## workflow slot

```bash
/venv/main/bin/comfy --where local workflow slots \
  /workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
```

## Preview ログ

```bash
cat /workspace/qwen_preview/http.log
cat /workspace/qwen_preview/tunnel.log
```

---

# 前提環境

```text
Vast.ai PyTorch (Vast) 系テンプレート
/venv/main/bin/python
/venv/main/bin/pip
/workspace
```

他テンプレートではパスが異なる可能性がある。
