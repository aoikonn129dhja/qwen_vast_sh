# Validation commands

## Current verified snapshot

```bash
bash -n snapshot/run_batch.sh
wc -l snapshot/run_batch.sh
sha256sum snapshot/run_batch.sh
```

Expected for this handoff snapshot:

```text
864 lines
d85c47e7e88261aca2af4d1a999e2f18d51badaf0ed841dec5fa8765d4ee9d04
```

## Useful checks on a working repository

```bash
git status --short
git diff -- run_batch.sh
bash -n run_batch.sh
```

Confirm key features exist:

```bash
grep -nE 'prompts\.md|PREVIEW_PASSWORD_FILE|password\.txt|BaseHTTPRequestHandler|Authorization|--no-json|qwen_preview|completed_jobs|total_jobs' run_batch.sh
```

## Vast runtime checks

```bash
curl -fsS http://127.0.0.1:8188/system_stats >/dev/null
ls -lah /workspace/qwen_batch/input
ls -lah /workspace/qwen_batch/output
```

Preview process/port checks:

```bash
cat /workspace/qwen_preview/http.pid 2>/dev/null || true
cat /workspace/qwen_preview/tunnel.pid 2>/dev/null || true
ss -ltnp | grep -E ':8188|:8765' || true
```

## Do not overclaim
Static/syntax validation is not equivalent to a real GPU generation test. If Codex cannot run the Vast environment, state that limitation explicitly.
