# ComfyUI 起動調査レポート

## 調査範囲

- 対象インスタンスへSSH接続し、ログ、プロセス、待受ポート、GPU、PyTorch、起動スクリプトを読み取り専用で確認した。
- 設定変更およびサービス再起動は行っていない。
- 以下の時刻はUTC。

## 失敗ログと環境値

`/workspace/.qwen_runtime/logs/qwen-image-edit-2511.log` の更新時刻は `2026-10-25 02:47:35.635761293 UTC`。同ログには次のCUDA初期化エラーがある。

```text
/workspace/.qwen_runtime/environments/qwen-image-edit-2511/lib/python3.12/site-packages/torch/cuda/__init__.py:228: UserWarning: CUDA initialization: The NVIDIA driver on your system is too old (found version 12020). Please update your GPU driver by downloading and installing a new version from the URL: http://www.nvidia.com/Download/index.aspx Alternatively, go to: https://pytorch.org to install a PyTorch version that has been compiled with your version of the CUDA driver. (Triggered internally at /__w/pytorch/pytorch/c10/cuda/CUDAFunctions.cpp:119.)
  return torch._C._cuda_getDeviceCount() > 0
Traceback (most recent call last):
  File "/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/main.py", line 261, in <module>
    import execution
  File "/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/execution.py", line 17, in <module>
    import comfy.model_management
  File "/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/comfy/model_management.py", line 364, in <module>
    total_vram = get_total_memory(get_torch_device()) / (1024 * 1024)
                                  ^^^^^^^^^^^^^^^^^^
  File "/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/comfy/model_management.py", line 213, in get_torch_device
    return torch.device(torch.cuda.current_device())
                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/workspace/.qwen_runtime/environments/qwen-image-edit-2511/lib/python3.12/site-packages/torch/cuda/__init__.py", line 1267, in current_device
    _lazy_init()
  File "/workspace/.qwen_runtime/environments/qwen-image-edit-2511/lib/python3.12/site-packages/torch/cuda/__init__.py", line 591, in _lazy_init
    torch._C._cuda_init()
RuntimeError: The NVIDIA driver on your system is too old (found version 12020). Please update your GPU driver by downloading and installing a new version from the URL: http://www.nvidia.com/Download/index.aspx Alternatively, go to: https://pytorch.org to install a PyTorch version that has been compiled with your version of the CUDA driver.
```

At the earlier environment check around `02:49:50 UTC`, the ComfyUI-specific Python environment reported:

```text
2.14.1+cu130
13.0
False
```

The GPU query reported `NVIDIA GeForce RTX 3090`, driver `535.161.07`, and CUDA `12.2`. `vast-capabilities` reported `driver_max_cuda` as `12.2`.

## 手動再起動スクリプト

`/workspace/qwen_vast_sh/scripts/restart_comfyui.sh` の既定値は次のとおり。

```bash
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
PYTHON="${PYTHON:-/venv/main/bin/python}"
```

実際のComfyUI本体は `/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI/main.py` に存在し、`/workspace/ComfyUI/main.py` は存在しなかった。02:49 UTCごろに確認した `/workspace/comfyui.log` の内容は次のとおり。

```text
/venv/main/bin/python: can't open file '/workspace/ComfyUI/main.py': [Errno 2] No such file or directory
```

## 後の起動ログと最終確認

`/workspace/comfyui.log` の更新時刻は `2026-10-25 02:54:05.441520133 UTC`。同ログには次の警告と起動記録がある。

```text
WARNING: You need pytorch with cu130 or higher to use optimized CUDA operations.
WARNING WARNING WARNING
If you are on nvidia 20 series and above it is required that you update your pytorch to cu130 or higher.
...
[INFO] pytorch version: 2.14.1+cu126
[INFO] Device: cuda:0 NVIDIA GeForce RTX 3090 : cudaMallocAsync
...
[INFO] Starting server
[INFO] To see the GUI go to: http://0.0.0.0:8188
```

最終確認時刻 `2026-10-25 02:55:05 UTC` の状態:

- 同じComfyUI専用環境のPyTorch確認結果: `2.14.1+cu126`、CUDA `12.6`、`torch.cuda.is_available() == True`
- ComfyUIプロセス: PID `36918`、引数 `main.py --listen 0.0.0.0 --port 8188`
- プロセスの作業ディレクトリ: `/workspace/.qwen_runtime/instances/qwen-image-edit-2511/ComfyUI`
- `http://127.0.0.1:8188/system_stats` の応答: HTTP `200`

## SSHポート転送

提示されたSSHオプションはリモート8080番へ転送する指定だった。ポート確認時、リモート8080番はJupyter、8188番はComfyUIプロセスが待ち受けていた。

## セットアップ指定の検索

対象モデルの `models/qwen-image-edit-2511`、`scripts`、および対象インスタンスの `qwen-runtime` にあるシェル/Python/requirements等のファイルを、`cu130`、`cu126`、PyTorch指定について検索した。結果は `ComfyUI-QwenCropWithFilename/nodes.py` の `import torch` のみで、CUDA版の固定指定は見つからなかった。cu130が導入された設定元は確認できていない。

## 確認できた事実

- 失敗ログには、CUDA初期化時の「driver is too old」例外が記録されている。
- 失敗時の環境確認ではPyTorchが `2.14.1+cu130`、GPUドライバー対応上限はCUDA `12.2` だった。
- 後の環境確認では同じComfyUI専用環境が `2.14.1+cu126` となり、CUDA利用可能、ComfyUI起動、8188番HTTP `200` を確認した。
- cu130からcu126へ変わった経緯は、確認したログと設定ファイル検索では特定できていない。
- 再起動スクリプトの既定ComfyUIパスと実際の配置先は一致していなかった。
