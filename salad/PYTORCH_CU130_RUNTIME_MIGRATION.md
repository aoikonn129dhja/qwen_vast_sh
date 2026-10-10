# Salad Qwen Image Edit 2511: PyTorch公式CUDA 13.0 runtimeへの統合記録

## 1. 文書の目的

この文書は、SaladCloud向け`qwen-image-edit-2511`イメージで重複していたCUDA/PyTorch実行環境を、PyTorch公式CUDA 13.0 runtimeへ統合した手順と判断根拠を記録する。

同じ変更を別のSaladモデルへ適用するときに、単に`FROM`だけを置き換えてPyTorchを二重インストールする失敗を避け、再現性と検証方法を維持できることを目的とする。

今回の対象は`salad/models/qwen-image-edit-2511`だけである。ControlNetノード、AnimePoseノード、ComfyUIテンプレート、音声・動画依存などの追加削減は行っていない。

## 2. 変更前に起きていたこと

変更前のDockerfileは、次のCUDA 12.8 + cuDNN runtimeをベースにしていた。

```dockerfile
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
```

デプロイ済みの旧イメージでは、その上に`uv`でPyTorch CUDA 12.8版をインストールしていた。

```text
torch==2.11.0+cu128
torchvision==0.26.0+cu128
torchaudio==2.11.0+cu128
```

その後の実機比較用として、ローカル作業ツリーにはPyTorch CUDA 13.0版へ切り替える未コミット変更も準備されていた。今回の変更は、その実機比較結果を採用しながら、ベースとPython側にCUDA実行ライブラリを重複して持たせない構成にしたものである。

旧GHCRイメージの圧縮転送サイズは8,435,455,625 bytes、約8.44GBだった。主な圧縮レイヤーは次のとおりだった。

| レイヤー | 圧縮サイズ | 内容 |
| --- | ---: | --- |
| Python/ComfyUI依存 | 約4.78GB | PyTorchとCUDA系Python依存を含む |
| CUDA 12.8 libraries | 約2.06GB | ベースイメージ由来 |
| cuDNN | 約0.70GB | ベースイメージ由来 |
| Qwen Edit追加セットアップ | 約0.56GB | カスタムノードなど |

CUDA 12.8 + cuDNN runtimeのベースライブラリと、PyTorch wheelが依存するCUDAライブラリが同居していたため、Saladノードが起動前に取得するイメージが大きくなっていた。ローカルで準備されていたcu130化をそのまま旧ベースへ重ねた場合も、同じ重複が残る構成だった。

## 3. CUDA 13.0を選んだ理由

RTX 3090 Ti実機で、PyTorch 2.11.0 CUDA 12.8版とCUDA 13.0版を比較した。

| 構成 | 観測したステップ時間 | `comfy_kitchen` CUDA backend |
| --- | ---: | --- |
| `torch 2.11.0+cu128` | 約9.44秒/step | 無効 |
| `torch 2.11.0+cu130` | 約8.77秒/step | 有効 |

CUDA 13.0版は約7%速く、`comfy_kitchen`の最適化CUDA backendも有効になった。対象インスタンスのNVIDIAドライバ591.86で動作確認済みだったため、CUDA 13.0を残す方針とした。

大幅な生成時間短縮はLightning LoRAによる40 stepから4 stepへの変更が主因であり、CUDA 13.0化による改善とは分けて評価する。

## 4. 採用したベースイメージ

次のPyTorch公式runtimeイメージを採用した。

```dockerfile
FROM pytorch/pytorch:2.11.0-cuda13.0-cudnn9-runtime@sha256:bfbb4a2b4fdba0fefdb428ea737e626d61bb3daf74a16e1ff935bdb03aa7c3f0
```

確認時点で、このmanifestの圧縮レイヤー合計は3,013,136,708 bytesだった。タグの内容が将来差し替わっても同じベースを再現できるよう、タグだけではなくmanifest digestも固定した。

このベースには次が含まれる。

- Python 3.12
- PyTorch 2.11.0 CUDA 13.0版
- torchvision 0.26.0 CUDA 13.0版
- torchaudio 2.11.0 CUDA 13.0版
- TritonとNVIDIA CUDA実行ライブラリ
- cuDNN 9 runtime

そのため、Dockerfileで`python3.12`と`python3.12-venv`をaptから追加する処理、および`/opt/venv`の作成を削除した。

## 5. PyTorchを二重インストールしない仕組み

公式runtimeへ`FROM`を変更しただけで従来のrequirementsをインストールすると、`torch`、`triton`、`nvidia-*`が新しいDockerレイヤーに再度書き込まれる可能性がある。これではベース統合の効果が失われる。

そこで2511専用に次の2ファイルを作成した。

```text
salad/models/qwen-image-edit-2511/requirements-runtime.in
salad/models/qwen-image-edit-2511/requirements-runtime.lock
```

`requirements-runtime.in`は既存環境の非CUDA依存を同じバージョンで維持し、次のパッケージを除外している。

```text
torch
torchvision
torchaudio
triton
nvidia-*
```

これらはすべて公式ベースイメージ側の責任範囲とした。

lockはWSL Ubuntu 24.04上で次のコマンドにより生成した。

```bash
uv pip compile \
  salad/models/qwen-image-edit-2511/requirements-runtime.in \
  --no-deps \
  --python-version 3.12 \
  --python-platform x86_64-manylinux_2_28 \
  --generate-hashes \
  --output-file salad/models/qwen-image-edit-2511/requirements-runtime.lock
```

`requirements-runtime.in`は、変更前の解決済み環境に存在した非CUDAパッケージを明示的に列挙している。そのため`--no-deps`でlockを生成し、インストール時にも`--no-deps`を指定する。これにより、依存解決がPyTorchやNVIDIA CUDAパッケージを再追加することを防ぐ。

インストールは公式イメージのPythonへ直接行う。

```bash
uv pip install \
  --python /usr/local/bin/python \
  --no-deps \
  --require-hashes \
  -r /opt/profile/requirements-runtime.lock
```

Pythonライブラリの導入には引き続き`uv`だけを使用している。

## 6. Dockerfile内の検証

Dockerビルド中に、非CUDA依存を入れた直後とカスタムノードを入れた直後の2回、次を実行する。

```bash
uv pip check --python "$PYTHON"
```

1回目は2511専用lockが公式ベースのPyTorch環境と整合することを確認する。2回目はカスタムノードのrequirementsを追加した後も依存関係が壊れていないことを確認する。

さらに、ビルド中に次の条件をassertする。

```python
torch.__version__ == "2.11.0+cu130"
torchvision.__version__ == "0.26.0+cu130"
torchaudio.__version__ == "2.11.0+cu130"
torch.version.cuda == "13.0"
```

カスタムノード導入後にもPyTorchとCUDAの版を再確認する。カスタムノード側の緩い`torch`依存によって、意図しないPyTorchへ置き換わった場合はビルドを失敗させる。

ビルド環境にはGPUがないため、ビルド中は`torch.cuda.is_available()`を合格条件にしない。GPU認識と`comfy_kitchen` CUDA backendは、GPUを持つ実行環境で確認する。

## 7. 静的回帰テスト

`salad/tests/test_qwen2511_runtime_image.py`を追加した。このテストは次を確認する。

- 公式PyTorch CUDA 13.0 runtimeのタグとdigestが固定されている
- `/usr/local/bin/python`を使用している
- `/opt/venv`を作成していない
- `python3.12-venv`をapt導入していない
- 2511専用requirementsとlockに`torch`、`torchvision`、`torchaudio`、`triton`、`nvidia-*`が入っていない
- `uv pip install`に`--no-deps`と`--require-hashes`がある
- `uv pip check`を依存導入前後で実行する
- PyTorch 2.11.0 CUDA 13.0をassertする

## 8. 別モデルへ適用する手順

別モデルへ適用するときは、次の順番で行う。

1. 対象モデルが必要とするPyTorch版、CUDA版、torchvision版、torchaudio版を実機で確認する。
2. 対応するPyTorch公式runtimeタグが存在することを公式レジストリで確認する。
3. linux/amd64のmanifest digestを取得し、`FROM`をdigestまで固定する。
4. 既存環境の依存一覧から、公式ベースが提供する`torch`、`torchvision`、`torchaudio`、`triton`、`nvidia-*`を除いたモデル専用入力ファイルを作る。
5. `uv pip compile --no-deps --generate-hashes`でモデル専用lockを生成する。
6. 公式ベースのPythonへ`uv pip install --no-deps --require-hashes`で導入する。
7. `uv pip check`を実行する。
8. カスタムノード導入後にもう一度`uv pip check`を実行する。
9. PyTorch、torchvision、torchaudio、`torch.version.cuda`をassertする。
10. Dockerビルド後、registry manifestから圧縮レイヤー合計を取得し、変更前と比較する。
11. GPU実環境でGPU認識、`comfy_kitchen` backend、ComfyUI HTTP応答、対象workflowを確認する。

モデルごとに追加ノードや依存が異なるため、2511のruntime lockを無条件で他モデルへコピーしない。モデル専用lockを作成し、`uv pip check`で不足を検出する。

## 9. ビルド後に確認する項目

GitHub ActionsのDockerビルドでは、次を確認する。

- 依存導入時にPyTorch/CUDAの巨大wheelをダウンロードしていない
- Dockerfile内の2回の`uv pip check`が成功している
- PyTorch/CUDA版のassertが成功している
- GHCRへ新しいSHAタグがpushされている
- 新イメージの圧縮サイズが旧イメージの約8.44GBより減っている
- 新イメージに4.78GB級のPyTorch再インストールレイヤーがない

GPU実環境では次を確認する。

```bash
/usr/local/bin/python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())'
/usr/local/bin/python -c 'import comfy_kitchen; print(comfy_kitchen.__version__)'
```

期待値はPyTorch `2.11.0+cu130`、CUDA `13.0`、GPU利用可能、`comfy_kitchen` CUDA backend有効である。

## 10. ロールバック

新イメージに問題がある場合、SaladのContainer Groupが参照するイメージを、変更前に使用していた次のSHAタグへ戻す。

```text
ghcr.io/aoikonn129dhja/qwen_vast_sh/salad-qwen-image-edit-2511:sha-22651bc9474f367711e0c2c31cef65708ce8c050
```

GitHub上では今回のコミットをrevertし、再ビルドする。タグを書き換えず、コミットSHAごとの不変タグを使う。

## 11. 今回の範囲外

次の削減候補は意図的に変更していない。

- `comfyui_controlnet_aux`
- `ComfyUI-AnimePose`
- `onnxruntime-gpu`
- ComfyUI workflow template media
- `comfy-cli`
- `torchaudio`
- ffmpegと動画関連依存

今回のサイズ差がPyTorch公式runtimeへの統合だけによるものと判断できるよう、追加の依存削減は別変更として扱う。
