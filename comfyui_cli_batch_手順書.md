# Qwen ComfyUI バッチ生成 手順書

この手順書は、現在の `qwen_comfy_sh` を Vast.ai + Jupyter で日常運用するための手順をまとめたもの。

現在の標準仕様:

```text
入力画像   : /workspace/qwen_batch/input/
プロンプト : /workspace/qwen_batch/prompts.md
出力       : /workspace/qwen_batch/output/<RUN_ID>/
プレビュー : Cloudflare Quick Tunnel + Basic認証
user       : qwen
password   : run_batch.sh 実行ごとにランダム生成
```

---

# 第1章 初回セットアップ

## 1. Vast.ai でインスタンスを起動する

RTX 5090 32GB など、使用する GPU のインスタンスを RENT する。

インスタンスが `Running` になったら Vast.ai の **Open** から Jupyter を開く。

---

## 2. GitHub から clone + setup

Jupyter の Terminal で実行する。

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

セットアップでは主に以下が準備される。

```text
/workspace/ComfyUI/
/workspace/qwen_comfy_sh/
/workspace/qwen_batch/
/venv/main/bin/comfy
Qwen-Rapid-AIO-NSFW-v19.safetensors
```

モデルダウンロードを含むため、新規インスタンスでは時間がかかる。

---

## 3. Stop → Start した既存インスタンスの場合

`/workspace` が残っているなら、毎回 setup をやり直す必要はない。

スクリプトを更新している場合だけリポジトリを更新する。

```bash
cd /workspace/qwen_comfy_sh
git pull
```

ComfyUI プロセスが Stop によって消えていても、現在の `run_batch.sh` は実行開始時に自動検出して起動する。

---

# 第2章 入力を用意する

## 1. 入力画像

Jupyter のファイルブラウザで次を開く。

```text
/workspace/qwen_batch/input/
```

生成に使用する画像をドラッグ＆ドロップする。

例:

```text
/workspace/qwen_batch/input/
├─ 001.png
├─ 002.png
├─ 003.jpg
└─ archive/
   └─ old.png
```

`run_batch.sh` が読むのは直下だけなので、`archive/old.png` は処理されない。

対応形式:

```text
PNG
JPG / JPEG
WebP
```

---

## 2. prompts.md

Jupyter で次へ移動する。

```text
/workspace/qwen_batch/
```

`prompts.md` を配置する。

```text
/workspace/qwen_batch/prompts.md
```

形式:

```markdown
# Qwen prompts

## 1
first prompt

## 2
second prompt

## 任意
third prompt
can span multiple lines
```

ポイント:

- `##` ごとに1プロンプト
- 見出しの文字列は本文に入らない
- `##` / `## 1` / `## Prompt 3` などすべて有効
- `###` は新しいプロンプト開始ではない
- 最初の `##` より前は無視される

以前の `prompts.json` は使用しない。

---

# 第3章 バッチ生成

## 1. run_batch.sh を実行する

Jupyter Terminal で以下だけ実行する。

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

---

## 2. ComfyUI の自動確認

最初に ComfyUI の API を確認する。

既に起動済みなら:

```text
ComfyUI: already running
```

停止していた場合は自動起動する。

```text
ComfyUI: starting...
ComfyUI: waiting for API...
ComfyUI: ready
```

Stop → Start 後は、この2番目のパターンになることがある。

プロセスだけ残って API が応答しない場合も、待機後に stale process と判定して再起動する。

---

## 3. バッチ内容を確認する

開始時に以下のような概要が表示される。

```text
============================================================
 QWEN BATCH
============================================================
Run ID   : 20260905_211651
Images   : 10
Prompts  : 2
Total    : 20
Workflow : /workspace/qwen_comfy_sh/Qwen-Rapid-AIO-SaveImage.json
Output   : /workspace/qwen_batch/output/20260905_211651
Preview local    : http://127.0.0.1:8765/
Preview URL      : https://xxxxx.trycloudflare.com
Preview user     : qwen
Preview password : XXXXXXXXXXXXXXXXXXXX
============================================================
```

重要なのは `Total`。

```text
Total = Images × Prompts
```

例:

```text
画像100枚 × プロンプト20個 = 2,000 jobs
```

意図しない大量生成になっていないか、開始時に確認する。

---

# 第4章 ライブプレビュー

## 1. Preview URL を開く

Terminal に表示された HTTPS URL をブラウザで開く。

```text
https://xxxxx.trycloudflare.com
```

Basic 認証画面が出るので、同じ Terminal に表示された情報を入力する。

```text
user     : qwen
password : その run で生成された20文字パスワード
```

パスワードは `run_batch.sh` を実行するたびに変わる。

---

## 2. 操作

ライブプレビューには以下の操作がある。

```text
Prev        前の画像
Next        次の画像
Latest      最新画像へ移動
Auto follow ON/OFF
← / →       前後移動
L           最新へ戻る
```

`Auto follow: ON` なら、新しい画像が生成されるたびに最新画像を表示する。

---

## 3. 認証情報の扱い

URLだけでは画像を閲覧できず、正しい user / password が必要。

ただし URL と password は Terminal に表示されるため、以下を外部共有する場合は認証情報が写っていないか確認する。

```text
Terminal のスクリーンショット
Terminal ログ
コピーした実行結果
```

---

# 第5章 実行中に変更してよいもの / だめなもの

`run_batch.sh` は開始時に入力画像一覧と `prompts.md` を読み込んで固定する。

## prompts.md を途中で編集

現在のバッチには影響しない。

```text
現在の run → 起動時に読み込んだプロンプトを使用
次回の run → 編集後の prompts.md を使用
```

`QWEN BATCH` ヘッダが表示された後なら、次回用に編集して問題ない。

## input に画像を途中追加

現在のバッチには追加されない。次回 run から対象になる。

## output を途中で移動

行わない。

現在の RUN_ID の output はライブプレビューが参照しており、生成直後のファイル移動処理も動いている。

## flatten_output.sh を途中実行

行わない。

平坦化はバッチがすべて終わってから実行する。

---

# 第6章 出力

生成画像は最終的に以下へ入る。

```text
/workspace/qwen_batch/output/<RUN_ID>/
```

例:

```text
/workspace/qwen_batch/output/
├─ 20260905_200239/
├─ 20260905_202623/
├─ 20260905_203356/
├─ 20260905_211651/
└─ 20260905_212341/
```

1 run の中では PNG が並ぶ。

```text
20260905_211651/
├─ 001_p001_00001_.png
├─ 001_p002_00001_.png
├─ 002_p001_00001_.png
└─ ...
```

生成中も各画像が完成した時点で `/workspace/qwen_batch/output/<RUN_ID>/` へ移され、ライブプレビューに反映される。

---

# 第7章 複数 run の出力を1つにまとめる

## 1. 生成が完全に終わっていることを確認する

`run_batch.sh` がまだ生成中なら flatten しない。

---

## 2. flatten_output.sh を実行する

```bash
bash /workspace/qwen_comfy_sh/flatten_output.sh
```

複数の RUN_ID フォルダの PNG を1つへまとめる。

出力先は実行時刻から作られる。

```text
/workspace/qwen_batch/output/yyyymmddhhmm/
```

例:

```text
/workspace/qwen_batch/output/202609060715/
```

---

## 3. ファイル名

RUN_ID 間で同じ生成ファイル名が存在しても衝突しないように、元 RUN_ID を prefix に付ける。

元:

```text
20260905_200239/001_p001_00001_.png
20260905_202623/001_p001_00001_.png
```

平坦化後:

```text
202609060715/
├─ 20260905_200239__001_p001_00001_.png
└─ 20260905_202623__001_p001_00001_.png
```

それでも衝突する場合は追加 suffix を付け、既存ファイルを上書きしない。

---

# 第8章 Windows へ回収する

Jupyter のファイルブラウザで次を開く。

```text
/workspace/qwen_batch/output/
```

`flatten_output.sh` を使用した場合は、作成された1つの `yyyymmddhhmm` フォルダをダウンロードする。

```text
/workspace/qwen_batch/output/202609060715/
```

Jupyter 側でフォルダダウンロードが ZIP になる場合でも、平坦化済みなので ZIP は1個だけになる。

---

# 第9章 次のバッチ

次回は以下を更新する。

```text
/workspace/qwen_batch/input/
/workspace/qwen_batch/prompts.md
```

その後、再び:

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

新しい RUN_ID が作られるため、通常は前回出力を上書きしない。

---

# 第10章 一時ファイル

バッチごとに以下も作られる。

```text
/workspace/ComfyUI/input/batch/<RUN_ID>/
/workspace/qwen_batch/tmp/<RUN_ID>/
```

現行の `run_batch.sh` はこれらを自動削除しない。

ディスク整理を行う場合、バッチが動いていない状態で:

```bash
rm -rf /workspace/ComfyUI/input/batch/*
rm -rf /workspace/qwen_batch/tmp/*
```

生成結果の `/workspace/qwen_batch/output/` はこのコマンドでは消えない。

---

# 第11章 利用終了

## 後で再利用する

Vast.ai で:

```text
Stop
```

- GPU課金を止める
- `/workspace` とモデルは残す
- ディスク課金は継続
- 次回 Start 後に ComfyUI が停止していても `run_batch.sh` が自動起動する

## 完全に破棄する

```text
Destroy
```

`/workspace` のデータを失うため、必要な生成画像を先に回収する。

---

# 第12章 トラブルシューティング

## ComfyUI が起動しない

```bash
tail -n 100 /workspace/comfyui.log
```

## ComfyUI API 確認

```bash
curl -s http://127.0.0.1:8188/system_stats | head
```

## input 確認

```bash
ls -lah /workspace/qwen_batch/input
```

## prompts.md 確認

```bash
cat /workspace/qwen_batch/prompts.md
```

## output 確認

```bash
find /workspace/qwen_batch/output -maxdepth 2 -type f | head -n 50
```

## Preview server ログ

```bash
cat /workspace/qwen_preview/http.log
```

## Cloudflare preview tunnel ログ

```bash
cat /workspace/qwen_preview/tunnel.log
```

## ComfyUI queue

```bash
/venv/main/bin/comfy --where local jobs ls
```

---

# 注意事項まとめ

- `run_batch.sh` は1本ずつ実行する
- `Total = 画像数 × プロンプト数` を開始時に確認する
- バッチ途中で追加した画像は次回から
- バッチ途中の `prompts.md` 編集は次回から
- 実行中の output を移動・削除しない
- 実行中に `flatten_output.sh` を使わない
- Preview URL と password を同時に外部共有しない
- Destroy 前に生成画像を回収する
- `tmp/` と `ComfyUI/input/batch/` は長期運用で蓄積する

---

# 最短運用

## 新規インスタンス

```text
1. Vast.ai で RENT
2. Open → Jupyter
3. Terminal で clone + setup
4. qwen_batch/input/ に画像を D&D
5. qwen_batch/prompts.md を配置
6. run_batch.sh
7. Preview URL を開き qwen + password でログイン
8. 生成完了
9. 必要なら flatten_output.sh
10. output/yyyymmddhhmm を1回ダウンロード
11. Stop または Destroy
```

セットアップ:

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

生成:

```bash
bash /workspace/qwen_comfy_sh/run_batch.sh
```

平坦化:

```bash
bash /workspace/qwen_comfy_sh/flatten_output.sh
```
