# Current status

## Repository
- GitHub: `https://github.com/amamisa4/qwen_comfy_sh`
- Expected Vast clone path: `/workspace/qwen_comfy_sh`
- Batch workspace: `/workspace/qwen_batch`
- ComfyUI: `/workspace/ComfyUI`

## Most recent verified run_batch snapshot
The handoff includes `snapshot/run_batch.sh`, copied from the latest password-persistent version stored in Google Drive during this conversation.

Verified locally when this bundle was created:
- line count: **864**
- `bash -n`: **OK**
- SHA-256: `d85c47e7e88261aca2af4d1a999e2f18d51badaf0ed841dec5fa8765d4ee9d04`

## Important divergence
GitHub `main` was observed to contain an older `run_batch.sh` (`20,798` bytes, blob SHA `8541ea461d51f60a737eea712be33074b7b65587`) that predates the persistent-preview-password change.

Therefore:
- Do **not** treat GitHub `main/run_batch.sh` as automatically newer than this bundle.
- When Codex is given the actual local repository, inspect `git status`, file hashes, and diffs before replacing anything.

## Additional source snapshots
The handoff also includes:
- `snapshot/setup_qwen_comfy.sh` — 407 lines, `bash -n` OK, SHA-256 `5ad304c15fc22f395fe3dbef9550759a37af5309b6e63b544aada81648e9afca`.

The workflow JSON is deliberately not duplicated in this handoff. Use the sanitized `Qwen-Rapid-AIO-SaveImage.json` at the repository root.

## Not yet implemented in this snapshot
- 5-second browser completion alert.
- per-output elapsed seconds + running average/throughput display.
See `10_pending_requirements.md`.
