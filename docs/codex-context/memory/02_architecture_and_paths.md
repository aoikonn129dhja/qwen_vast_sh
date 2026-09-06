# Architecture and paths

## Main components

### `setup_qwen_comfy.sh`
One-shot Vast.ai setup script. It installs/repairs ComfyUI, dependencies, `comfy-cli`, the Qwen model, patched Qwen node, workflow, directories, and launches ComfyUI.

### `run_batch.sh`
Batch runner and current authenticated live-preview host. It:
- validates paths/tools;
- ensures ComfyUI is alive (auto-start/restart logic);
- snapshots input images and prompts at startup;
- runs every image × prompt combination through `comfy-cli`;
- moves generated files into the batch output tree;
- serves a live preview and creates/reuses a Cloudflare Quick Tunnel.

### ComfyUI
- local bind: `127.0.0.1:8188`
- expected Python: `/venv/main/bin/python`
- expected comfy-cli: `/venv/main/bin/comfy`

### Live preview
- local bind: `127.0.0.1:8765` by default
- preview root: `/workspace/qwen_preview`
- Cloudflare Quick Tunnel exposes the preview HTTP server.

## Important filesystem layout

```text
/workspace/
├─ ComfyUI/
│  ├─ input/batch/<RUN_ID>/
│  ├─ output/batch/<RUN_ID>/          # transient ComfyUI SaveImage location
│  ├─ models/checkpoints/
│  └─ user/default/workflows/
├─ qwen_comfy_sh/
│  ├─ setup_qwen_comfy.sh
│  ├─ run_batch.sh
│  └─ Qwen-Rapid-AIO-SaveImage.json
├─ qwen_batch/
│  ├─ input/                          # user uploads
│  ├─ prompts.md
│  ├─ tmp/<RUN_ID>/                   # generated workflow files
│  └─ output/<RUN_ID>/                # final per-run outputs
└─ qwen_preview/
   ├─ password.txt
   ├─ url.txt
   ├─ state.json
   ├─ server.py
   ├─ http.pid
   ├─ tunnel.pid
   └─ logs...
```

## Model/workflow facts
- model: `Qwen-Rapid-AIO-NSFW-v19.safetensors`
- model source family: `Phr00t/Qwen-Image-Edit-Rapid-AIO`
- patched Qwen node source: Phr00t fixed `nodes_qwen.v2.py`
- workflow: `Qwen-Rapid-AIO-SaveImage.json`

## Fixed workflow slot addresses used by the batch design
- LoadImage: node `8`
- positive prompt: node `3`
- negative prompt: node `4`
- KSampler: node `2`
- latent width/height: node `9`
- SaveImage: node `10`
