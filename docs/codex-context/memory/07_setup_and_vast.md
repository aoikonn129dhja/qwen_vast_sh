# Setup and Vast.ai

## Environment assumptions
- Vast.ai PyTorch-type template.
- `/workspace` persistent for a stopped instance, but lost on Destroy.
- Python: `/venv/main/bin/python`
- pip: `/venv/main/bin/pip`
- target GPU in recent use: RTX 5090 32 GB; earlier planning also considered RTX 3090.

## Setup command
Typical fresh-instance flow:

```bash
git clone https://github.com/amamisa4/qwen_comfy_sh.git /workspace/qwen_comfy_sh && \
bash /workspace/qwen_comfy_sh/setup_qwen_comfy.sh
```

## Setup behavior known from current GitHub main
`setup_qwen_comfy.sh` does roughly the following:
- GPU/disk checks;
- Hugging Face real-download preflight (up to ~8 MiB) and slow-host warning;
- clone/repair ComfyUI;
- install requirements;
- install `comfy-cli>=1.16,<2`;
- set default ComfyUI workspace;
- download ~28.4 GB Qwen model if absent;
- replace `nodes_qwen.py` with Phr00t fixed v2;
- copy repository workflow into ComfyUI workflows;
- create batch directories;
- launch ComfyUI on `127.0.0.1:8188`;
- obtain/download `cloudflared` and launch a Quick Tunnel for ComfyUI GUI.

## Known setup drift
The current GitHub `setup_qwen_comfy.sh` still contains older display text referring to `prompts.json` even though the current batch runner uses `prompts.md`. This is documentation/output drift, not the intended current prompt format.

Also note there can be two tunnel concepts:
1. setup's tunnel to ComfyUI GUI (`8188`), and
2. run_batch's authenticated live-preview tunnel (`8765`).
Do not confuse them.

## Vast lifecycle
- Running: GPU billing continues even if idle.
- Stop: processes stop, storage persists and storage billing continues.
- Destroy: instance storage is removed; retrieve important outputs first.

Operationally, Destroy is treated as the boundary after which runtime preview password state must be regenerated.
