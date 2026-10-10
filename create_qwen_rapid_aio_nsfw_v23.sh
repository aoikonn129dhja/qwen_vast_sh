#!/usr/bin/env bash
set -Eeuo pipefail

# Run at any location after cloning qwen_vast_sh.
REPO_ROOT="${1:-/workspace/qwen_vast_sh}"
SOURCE="$REPO_ROOT/vast/models/qwen-rapid-aio-nsfw-v19"
TARGET="$REPO_ROOT/vast/models/qwen-rapid-aio-nsfw-v23"

[ -d "$SOURCE" ] || { echo "ERROR: v19 source directory not found: $SOURCE" >&2; exit 1; }
[ ! -e "$TARGET" ] || { echo "ERROR: target already exists (will not overwrite): $TARGET" >&2; exit 1; }
for file in setup.sh run_batch.sh restart_preview_tunnel.sh requirements.in requirements.lock workflows/batch-save-image.json; do
    [ -s "$SOURCE/$file" ] || { echo "ERROR: missing v19 source file: $file" >&2; exit 1; }
done

STAGE="$(mktemp -d "$REPO_ROOT/vast/models/.qwen-rapid-aio-nsfw-v23.XXXXXXXX")"
cleanup() { if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then rm -rf -- "$STAGE"; fi; }
trap cleanup EXIT
cp -a "$SOURCE/." "$STAGE/"

python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
setup = root / "setup.sh"
s = setup.read_text(encoding="utf-8")
changes = {
    'Qwen-Rapid-AIO-NSFW-v19.safetensors': 'Qwen-Rapid-AIO-NSFW-v23.safetensors',
    'MODEL_REPO_COMMIT="691024f438640508f8aa86414863fc15edfb8a84"': 'MODEL_REPO_COMMIT="0758cce6dc3a0f5651de28369f56bad1c989d4a3"\nQWEN_NODE_REPO_COMMIT="691024f438640508f8aa86414863fc15edfb8a84"',
    '/resolve/$MODEL_REPO_COMMIT/v19/': '/resolve/$MODEL_REPO_COMMIT/v23/',
    'MODEL_SHA256="ba71575515709c9912560d1176b2386eaa49294fedc6ce57b9734aa57e91e5ac"': 'MODEL_SHA256="fdb919fc81bea63f13759967fc92c9118142e5c70d4e6795199233a35eefa233"',
    '/resolve/$MODEL_REPO_COMMIT/fixed-textencode-node/': '/resolve/$QWEN_NODE_REPO_COMMIT/fixed-textencode-node/',
    'NSFW v19': 'NSFW v23',
    'Qwen-Rapid-AIO-NSFW-v19-Batch.json': 'Qwen-Rapid-AIO-NSFW-v23-Batch.json',
}
for a,b in changes.items():
    if a not in s:
        raise SystemExit(f"ERROR: expected v19 setup content missing: {a}")
    s=s.replace(a,b)
setup.write_text(s,encoding="utf-8")

runner = root / "run_batch.sh"
s=runner.read_text(encoding="utf-8")
needle='qwen-rapid-aio-nsfw-v19'
if needle not in s:
    raise SystemExit("ERROR: expected v19 paths missing from batch script")
runner.write_text(s.replace(needle,'qwen-rapid-aio-nsfw-v23'),encoding="utf-8")

wf = root / "workflows/batch-save-image.json"
s=wf.read_text(encoding="utf-8")
needle='Qwen-Rapid-AIO-NSFW-v19.safetensors'
if needle not in s:
    raise SystemExit("ERROR: v19 checkpoint not found in workflow")
wf.write_text(s.replace(needle,'Qwen-Rapid-AIO-NSFW-v23.safetensors'),encoding="utf-8")

# Validate every generated workflow checkpoint reference.
import json
obj=json.loads(wf.read_text(encoding="utf-8"))
loaders=[n for n in obj['nodes'] if n.get('type')=='CheckpointLoaderSimple']
assert loaders and all('Qwen-Rapid-AIO-NSFW-v23.safetensors' in n.get('widgets_values',[]) for n in loaders)
assert 'v19' not in setup.read_text(encoding='utf-8')
assert 'v19' not in runner.read_text(encoding='utf-8')
PY

bash -n "$STAGE/setup.sh" "$STAGE/run_batch.sh" "$STAGE/restart_preview_tunnel.sh"
# Preserve v19 dependencies and node pin as-is; no new dependency resolution.
# Rename only when all validation has passed.
mv -- "$STAGE" "$TARGET"
STAGE=""
echo "Created: $TARGET"
echo "Next: bash $TARGET/setup.sh"
echo "Then: bash $TARGET/run_batch.sh"
