# ComfyUI Qwen Image Edit 2511: Missing Models 調査レポート

- 調査日: 2026-10-25
- 対象: Vast上のComfyUI (port 8188)
- 方法: SSHでの読み取り専用確認、モデル一覧API確認。修正時はモデルファイルへのシンボリックリンクを作成。

## 現象

ユーザー提示の画面に「Setup required」「4 Missing Models」と表示され、以下が列挙されていた。

- `Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors`
- `qwen_image_vae.safetensors`
- `qwen_2.5_vl_7b_fp8_scaled.safetensors`
- `qwen_image_edit_2511_fp8mixed.safetensors`

## SSHで確認した事実

### 稼働中プロセス

作業ディレクトリ:

```text
/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI
```

起動引数:

```text
["/workspace/.qwen_runtime/environments/qwen-image-edit-2511/bin/python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
```

### モデルファイルと検索パス

実ファイルはすべて `/workspace/ComfyUI/models/` 以下に存在していた。調査時、稼働中ComfyUIの検索先と一覧状態は次のとおりだった。

```text
loras roots= ['/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/loras']
  indexed= False
vae roots= ['/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/vae']
  indexed= False
text_encoders roots= ['/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/text_encoders', '/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/clip']
  indexed= False
diffusion_models roots= ['/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/unet', '/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/models/diffusion_models']
  indexed= False
```

共有モデル用の設定ファイル `/workspace/.qwen_runtime/instances/qwen-image-edit-2511/extra_model_paths.yaml` は存在し、`base_path: /workspace/ComfyUI` と各モデルカテゴリの相対パスが記載されていた。ComfyUIの `main.py` は既定設定をComfyUI自身のディレクトリにある `extra_model_paths.yaml` から読む。稼働中プロセスの起動引数には `--extra-model-paths-config` がなく、ComfyUI自身のディレクトリ内にも設定ファイルはなかった。

### 原因

稼働中ComfyUIの検索先と4ファイルの配置先が異なっていた。共有モデル用設定ファイルは別階層にあり、稼働中プロセスに読み込まれていなかった。

## 適用した修正と確認

実ファイルは移動・複製せず、次の4リンクを稼働中ComfyUIの対応フォルダに作成した。

| カテゴリ | リンク先ファイル名 | リンク元 |
| --- | --- | --- |
| loras | `Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors` | `/workspace/ComfyUI/models/loras/` |
| vae | `qwen_image_vae.safetensors` | `/workspace/ComfyUI/models/vae/` |
| text_encoders | `qwen_2.5_vl_7b_fp8_scaled.safetensors` | `/workspace/ComfyUI/models/text_encoders/` |
| diffusion_models | `qwen_image_edit_2511_fp8mixed.safetensors` | `/workspace/ComfyUI/models/diffusion_models/` |

修正後、ComfyUIの `/models/{folder}` APIで4ファイルすべてが一覧に含まれることを確認した。ComfyUIプロセスは再起動していない。

## 実ログ原文

ログファイル: `/workspace/comfyui.log`
サイズ: 6,958 bytes
更新時刻: 2026-10-25 02:54:05.441520133 UTC

以下は実ログの該当行。ANSIカラー制御コードは `\x1b` として表記している。

```text
8:  \x1b[1m\x1b[33m[WARNING]\x1b[0m WARNING: You need pytorch with cu130 or higher to use optimized CUDA operations.
9:  WARNING WARNING WARNING
32: \x1b[1m\x1b[33m[WARNING]\x1b[0m ****** User settings have been changed to be stored on the server instead of browser storage. ******
33: \x1b[1m\x1b[33m[WARNING]\x1b[0m ****** For multi-user setups add the --multi-user CLI argument to enable multiple user profiles. ******
51: \x1b[32m[INFO]\x1b[0m Starting server
53: \x1b[32m[INFO]\x1b[0m To see the GUI go to: http://0.0.0.0:8188
```

ログ全体を検索した結果、上記4モデル名および `extra_model_paths` を含む行は見つからなかった。ログに記録された警告は上記の内容で、Missing Modelsを直接示す行はなかった。

## 永続性に関する確認

Vastの状態出力は `workspace_is_volume=False`。このインスタンスの `/workspace` は永続ボリュームではない。Vastのインスタンスガイドでは、stop/startはファイルシステムを保持し、recycle/destroyではコンテナ内のファイルが失われるとされている。今回作成したリンクとモデルの配置は `/workspace` 内にある。
